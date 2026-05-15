//! Cleanroom 8-bit lossless JPEG decoder (T.81 SOF3).
//!
//! T.81 §H — predictive lossless coding. No DCT, no quantization, no
//! IDCT rounding: each sample is reconstructed exactly as
//! `(predictor + diff) mod 2^precision`, where `diff` is the
//! Huffman-coded difference between the actual sample and the
//! predictor. The decoder uses one of seven predictor formulas
//! (selected via Ss in the SOS) computed from neighbors a (left),
//! b (above), and c (above-left).
//!
//! v1 scope:
//!   - 8-bit precision (T.81 §H, Pt=0).
//!   - 1 component (grayscale) only — most lossless JPEGs in the wild
//!     are single-component (DICOM, DNG, Lossless JPEG2000-substitute).
//!   - All 7 predictors (Ss = 1..7).
//!   - No restart markers (DRI=0) — the wrapper backstops if needed.
//!
//! Out of scope here, falls back to libjpeg_wrapper:
//!   - 12/16-bit precision (precision 9..16; the wrapper has a separate
//!     `jpeg12_/jpeg16_` API path).
//!   - Multi-component lossless (rare; tiff-with-jpeg-compression uses
//!     it occasionally).
//!   - DRI / restart markers in lossless scans.
//!   - Point transform Al > 0 (sample is shifted up by Al; trivial to
//!     add when needed).
//!
//! Reference: ITU-T T.81 §H.1 (Lossless mode, Annex H).

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../core/errors.zig");
const types = @import("../core/types.zig");
const bitstream = @import("bitstream.zig");
const huffman = @import("huffman.zig");

pub const Error = errors.DecodeError;

/// State threaded into decodeScan for restart-marker handling.
const RestartCtx = struct {
    interval: u16, // 0 = no restarts
    samples_since: u32 = 0,
    expected_rst: u8 = 0xD0,
    /// True when the next sample(s) — one per scan-component for the
    /// MCU after RST — must use the initial predictor 2^(P-Pt-1) per
    /// T.81 §H.1.2.2. Cleared after each component's first sample of
    /// the next restart interval is emitted.
    force_initial: bool = false,
};

const ComponentInfo = struct {
    id: u8,
    h_factor: u4,
    v_factor: u4,
    dc_table: u8 = 0,
};

const FrameInfo = struct {
    precision: u8,
    height: u16,
    width: u16,
    num_components: u8,
    components: [4]ComponentInfo,
};

const ScanInfo = struct {
    num_components: u8,
    comp_indices: [4]usize,
    predictor: u8, // Ss; 1..7
    point_transform: u4, // Al
};

/// Decode an 8-bit lossless JPEG (T.81 SOF3). Returns
/// `error.NotImplemented` for any feature this v1 doesn't support
/// (12-bit precision, multi-component, restart markers) so the
/// dispatcher in `src/jpegz.zig` falls back to the wrapper.
pub fn decode(allocator: Allocator, data: []const u8) Error!types.Image {
    if (data.len < 4) return error.TruncatedStream;
    if (data[0] != 0xFF or data[1] != 0xD8) return error.InvalidMarker;

    var pos: usize = 2;
    var frame: ?FrameInfo = null;
    var dc_tables: [4]?huffman.HuffmanTable = .{ null, null, null, null };
    var saw_eoi = false;
    var seen_sof = false;
    var pixels: ?[]u8 = null;
    var restart_interval: u16 = 0;
    errdefer if (pixels) |p| allocator.free(p);

    while (pos + 1 < data.len and !saw_eoi) {
        if (data[pos] != 0xFF) return error.InvalidMarker;
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        const marker = data[pos + 1];
        pos += 2;
        switch (marker) {
            0xD9 => { saw_eoi = true; break; },
            0xC3 => { // SOF3 — lossless predictive
                frame = try parseSof(data, pos);
                // v1 supports 8/12/14/16-bit precision (any P in 2..16
                // per T.81 §H.1, but cjpeg only emits 8/12/16; 14 lands
                // via DNG raw). Output is u8-packed for P≤8 and
                // u16 host-endian for P>8.
                if (frame.?.precision < 2 or frame.?.precision > 16)
                    return error.NotImplemented;
                if (frame.?.num_components != 1 and frame.?.num_components != 3)
                    return error.NotImplemented;
                seen_sof = true;
                var i: usize = 0;
                while (i < frame.?.num_components) : (i += 1) {
                    const c = &frame.?.components[i];
                    if (c.h_factor != 1 or c.v_factor != 1) return error.NotImplemented;
                }
                pos += parseSegmentLength(data, pos);
            },
            0xC0, 0xC1, 0xC2 => return error.NotImplemented, // not lossless
            0xC9, 0xCA, 0xCB => return error.NotImplemented, // arithmetic
            0xC4 => { // DHT — only DC tables matter for lossless
                try parseDht(data, pos, &dc_tables);
                pos += parseSegmentLength(data, pos);
            },
            0xDB => { // DQT — irrelevant for lossless; skip body
                pos += parseSegmentLength(data, pos);
            },
            0xDD => { // DRI — restart interval (T.81 §F.2.1.3)
                const seg_len = parseSegmentLength(data, pos);
                if (seg_len != 4 or pos + seg_len > data.len) return error.TruncatedStream;
                restart_interval = (@as(u16, data[pos + 2]) << 8) | data[pos + 3];
                pos += seg_len;
            },
            0xDA => { // SOS
                if (!seen_sof) return error.InvalidMarker;
                const scan = try parseSos(data, pos, &frame.?);
                // Scan must cover all frame components in a single pass
                // (no progressive concept of "scan refines a subset"
                // exists in lossless; T.81 §H.1.2.1).
                if (scan.num_components != frame.?.num_components) return error.NotImplemented;
                if (scan.predictor < 1 or scan.predictor > 7) return error.NotImplemented;
                pos += parseSegmentLength(data, pos);
                pixels = try decodeScan(allocator, data, pos, &frame.?, &dc_tables, &scan, restart_interval);
                // Lossless decode is single-pass; assume EOI follows.
                break;
            },
            0x01, 0xD0...0xD7 => continue, // standalone markers
            else => pos += parseSegmentLength(data, pos), // skip APPn/COM/etc.
        }
    }

    if (!seen_sof) return error.InvalidMarker;
    if (pixels == null) return error.TruncatedStream;

    const nc = frame.?.num_components;
    return types.Image{
        .pixels = pixels.?,
        .width = frame.?.width,
        .height = frame.?.height,
        .channels = nc,
        .bits_per_sample = frame.?.precision,
        // For lossless, libjpeg-turbo does NO YCbCr→RGB conversion: the
        // raw component samples ARE the output. cjpeg with PPM input
        // writes R, G, B as-is. Mark as RGB for 3 components, grayscale
        // for 1; consumers reading `image.layout` get the right shape.
        .source_color_space = if (nc == 1) .grayscale else .rgb,
        .layout = if (nc == 1) .grayscale else .rgb,
    };
}

fn parseSegmentLength(data: []const u8, pos: usize) usize {
    if (pos + 1 >= data.len) return 0;
    return (@as(usize, data[pos]) << 8) | data[pos + 1];
}

fn parseSof(data: []const u8, pos: usize) Error!FrameInfo {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 8 or pos + seg_len > data.len) return error.TruncatedStream;
    var fi: FrameInfo = undefined;
    fi.precision = data[pos + 2];
    fi.height = (@as(u16, data[pos + 3]) << 8) | data[pos + 4];
    fi.width = (@as(u16, data[pos + 5]) << 8) | data[pos + 6];
    fi.num_components = data[pos + 7];
    if (fi.num_components == 0 or fi.num_components > 4) return error.InvalidMarker;
    if (seg_len < 8 + @as(usize, fi.num_components) * 3) return error.TruncatedStream;
    var i: usize = 0;
    while (i < fi.num_components) : (i += 1) {
        const off = pos + 8 + i * 3;
        fi.components[i] = .{
            .id = data[off],
            .h_factor = @intCast(data[off + 1] >> 4),
            .v_factor = @intCast(data[off + 1] & 0x0F),
            // qt_index byte is at off+2 but is unused for lossless.
        };
    }
    return fi;
}

fn parseDht(
    data: []const u8,
    pos: usize,
    dc_tables: *[4]?huffman.HuffmanTable,
) Error!void {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 2 or pos + seg_len > data.len) return error.TruncatedStream;
    var off: usize = pos + 2;
    const seg_end = pos + seg_len;
    while (off < seg_end) {
        if (off + 17 > seg_end) return error.TruncatedStream;
        const tc_th = data[off];
        const tc: u8 = tc_th >> 4;
        const th: u8 = tc_th & 0x0F;
        if (tc != 0 or th > 3) return error.InvalidMarker; // lossless uses DC tables only
        off += 1;
        var bits: [16]u8 = undefined;
        var total: u16 = 0;
        for (0..16) |i| {
            bits[i] = data[off + i];
            total += bits[i];
        }
        off += 16;
        if (off + total > seg_end) return error.TruncatedStream;
        const values = data[off .. off + total];
        const t = huffman.HuffmanTable.buildFromDht(bits, values) catch
            return error.InvalidMarker;
        dc_tables[th] = t;
        off += total;
    }
}

fn parseSos(data: []const u8, pos: usize, frame: *FrameInfo) Error!ScanInfo {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 6 or pos + seg_len > data.len) return error.TruncatedStream;
    var info: ScanInfo = undefined;
    info.num_components = data[pos + 2];
    if (info.num_components == 0 or info.num_components > 4)
        return error.InvalidMarker;
    var i: usize = 0;
    while (i < info.num_components) : (i += 1) {
        const off = pos + 3 + i * 2;
        const cs = data[off];
        const td_ta = data[off + 1];
        var found: bool = false;
        var j: usize = 0;
        while (j < frame.num_components) : (j += 1) {
            if (frame.components[j].id == cs) {
                frame.components[j].dc_table = td_ta >> 4;
                info.comp_indices[i] = j;
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidMarker;
    }
    const tail_off = pos + 3 + @as(usize, info.num_components) * 2;
    info.predictor = data[tail_off];
    // Se byte at tail_off+1 is unused per T.81 §H.1.
    const ah_al = data[tail_off + 2];
    info.point_transform = @intCast(ah_al & 0x0F);
    return info;
}

/// Decode the entropy-coded scan into a `width*height`-byte pixel
/// buffer. Sample reconstruction per T.81 §H.1.2:
///   sample[x,y] = (predictor(x,y) + diff[x,y]) mod 2^precision
/// with predictor selected by Ss (1..7) and special handling for the
/// first sample of the image and the first sample of each row.
fn decodeScan(
    allocator: Allocator,
    data: []const u8,
    entropy_start: usize,
    frame: *const FrameInfo,
    dc_tables: *const [4]?huffman.HuffmanTable,
    scan: *const ScanInfo,
    restart_interval: u16,
) Error![]u8 {
    const width: usize = frame.width;
    const height: usize = frame.height;
    const nc: usize = scan.num_components;
    const sample_bytes: usize = if (frame.precision <= 8) 1 else 2;
    // Output is interleaved per-pixel: pixel(x,y) starts at
    // out[(y*width + x)*nc*sample_bytes]. For P>8 each sample is
    // u16 host-endian — same shape libjpeg-turbo's jpeg16_ path emits.
    const out = try allocator.alloc(u8, width * height * nc * sample_bytes);
    errdefer allocator.free(out);
    @memset(out, 0);

    // Per-component Huffman table pointers (indexed by scan-component
    // position 0..nc-1, NOT by frame component index). Predictor state
    // is per-component too.
    var dc_tables_per_comp: [4]*const huffman.HuffmanTable = undefined;
    {
        var i: usize = 0;
        while (i < nc) : (i += 1) {
            const ci = scan.comp_indices[i];
            const comp = &frame.components[ci];
            // Take a pointer to the optional's payload after verifying
            // it's set. Lifetime is the parent decode function's locals.
            if (dc_tables[comp.dc_table] == null) return error.InvalidMarker;
            dc_tables_per_comp[i] = &dc_tables[comp.dc_table].?;
        }
    }

    // Initial predictor for the very first sample: 2^(P - Pt - 1).
    // For 8-bit Pt=0: initial = 128.
    const precision: u8 = frame.precision;
    const pt: u4 = scan.point_transform;
    const initial_pred: i32 = @as(i32, 1) << @intCast(@as(u8, precision) - @as(u8, pt) - 1);
    const sample_mask: i32 = (@as(i32, 1) << @intCast(precision)) - 1;

    var br = bitstream.BitReader.init(data[entropy_start..]);
    var rst: RestartCtx = .{ .interval = restart_interval };

    // For multi-component scans, per T.81 §A.2.4 / §H.1.2.1, samples are
    // interleaved per-MCU. With 1×1 sampling everywhere (our v1 limit),
    // each MCU = 1 sample per component, in scan-component order. So the
    // outer iteration is the same as single-component (per-pixel walk),
    // with an inner loop over components.
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            // Per T.81 §F.2.1.3: every `restart_interval` MCUs the
            // entropy stream realigns. For lossless 1×1, each MCU = 1
            // sample per component. After RST, the next MCU's first
            // sample uses the initial predictor (per §H.1.2.2).
            if (rst.interval > 0 and rst.samples_since == rst.interval) {
                br.seekToMarker();
                if (!br.marker_seen) return error.InvalidMarker;
                if (br.marker_byte != rst.expected_rst) return error.InvalidMarker;
                rst.expected_rst = 0xD0 + ((rst.expected_rst - 0xD0 + 1) & 0x07);
                br.skipPastMarker();
                rst.samples_since = 0;
                rst.force_initial = true;
            }
            var ci_scan: usize = 0;
            while (ci_scan < nc) : (ci_scan += 1) {
                const pred: i32 = if ((x == 0 and y == 0) or rst.force_initial)
                    initial_pred
                else if (y == 0)
                    sampleAt(out, sample_bytes, y, x - 1, width, nc, ci_scan)
                else if (x == 0)
                    sampleAt(out, sample_bytes, y - 1, x, width, nc, ci_scan)
                else
                    computePredictorAt(scan.predictor, out, sample_bytes, x, y, width, nc, ci_scan);

                const ssss: u8 = dc_tables_per_comp[ci_scan].decode(&br) catch return error.BackendError;
                if (ssss > 16) return error.BackendError;
                var diff: i32 = 0;
                if (ssss == 16) {
                    // T.81 §H.1.2.1: SSSS=16 represents diff = 32768 with
                    // no extra bits. Only legal at 16-bit precision.
                    if (frame.precision != 16) return error.BackendError;
                    diff = 32768;
                } else if (ssss > 0) {
                    const bits = br.readBits(@intCast(ssss)) catch return error.TruncatedStream;
                    diff = @intCast(huffman.extendSign(bits, @intCast(ssss)));
                }
                const sample: i32 = (pred + diff) & sample_mask;
                writeSample(out, sample_bytes, y, x, width, nc, ci_scan, @intCast(sample));
            }
            // After the MCU's components are all decoded, clear the
            // initial-predictor flag and bump the per-RST counter.
            rst.force_initial = false;
            rst.samples_since += 1;
        }
    }

    return out;
}

/// Read a single sample from the interleaved output buffer at (y, x, ci).
/// Sample is u8 for sample_bytes==1, u16 host-endian for sample_bytes==2.
inline fn sampleAt(
    out: []const u8,
    sample_bytes: usize,
    y: usize,
    x: usize,
    w: usize,
    nc: usize,
    ci: usize,
) i32 {
    const off = ((y * w + x) * nc + ci) * sample_bytes;
    if (sample_bytes == 1) return @intCast(out[off]);
    // Host-endian u16 read
    const lo: u16 = out[off];
    const hi: u16 = out[off + 1];
    const v: u16 = lo | (hi << 8);
    _ = .{}; // silence
    return @intCast(v);
}

inline fn writeSample(
    out: []u8,
    sample_bytes: usize,
    y: usize,
    x: usize,
    w: usize,
    nc: usize,
    ci: usize,
    value: u16,
) void {
    const off = ((y * w + x) * nc + ci) * sample_bytes;
    if (sample_bytes == 1) {
        out[off] = @intCast(value & 0xFF);
    } else {
        out[off] = @intCast(value & 0xFF);
        out[off + 1] = @intCast(value >> 8);
    }
}

inline fn computePredictorAt(
    selector: u8,
    out: []const u8,
    sample_bytes: usize,
    x: usize,
    y: usize,
    w: usize,
    nc: usize,
    ci: usize,
) i32 {
    const a: i32 = sampleAt(out, sample_bytes, y, x - 1, w, nc, ci);
    const b: i32 = sampleAt(out, sample_bytes, y - 1, x, w, nc, ci);
    const c: i32 = sampleAt(out, sample_bytes, y - 1, x - 1, w, nc, ci);
    return switch (selector) {
        1 => a,
        2 => b,
        3 => c,
        4 => a + b - c,
        5 => a + ((b - c) >> 1),
        6 => b + ((a - c) >> 1),
        7 => (a + b) >> 1,
        else => unreachable,
    };
}

