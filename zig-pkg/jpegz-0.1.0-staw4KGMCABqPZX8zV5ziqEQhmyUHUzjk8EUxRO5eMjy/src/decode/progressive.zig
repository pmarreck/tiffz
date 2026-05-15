//! Cleanroom 8-bit progressive JPEG decoder (T.81 SOF2).
//!
//! Progressive JPEG is fundamentally a different decoding model than
//! baseline: each scan carries only a *subset* of the DCT coefficients
//! (a contiguous spectral range Ss..Se in zig-zag order), and a single
//! file may have many scans interleaved. Each coefficient may also be
//! delivered in multiple "successive approximation" passes — first as
//! the upper bits (Ah=0, Al=k means "shift this value left by k"),
//! then refined by additional bits in subsequent scans (Ah>0).
//!
//! The decoder keeps a persistent coefficient buffer (per-component,
//! per-block, 64 i16 each) and updates it as each scan arrives. After
//! EOI, dequantize + un-zig-zag + IDCT every block to produce pixels.
//!
//! Reference: ITU-T T.81 §G (progressive DCT-based mode).
//!
//! v1 scope:
//!   - 8-bit precision (T.81 §A.4)
//!   - 1 component (grayscale) or 3 components (RGB / YCbCr)
//!   - Sampling factors: 1..4 each (handles 4:4:4, 4:2:0, 4:2:2)
//!   - No restart markers (DRI = 0)
//!
//! Out of scope here, falls back to libjpeg_wrapper:
//!   - Restart markers in progressive scans (rare; v1.x follow-up)
//!   - 12-bit (SOF1 extended; separate codec mode)

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../core/errors.zig");
const types = @import("../core/types.zig");
const bitstream = @import("bitstream.zig");
const huffman = @import("huffman.zig");
const idct = @import("idct.zig");
const color = @import("color.zig");

const PROG_DEBUG: bool = false;
inline fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (comptime PROG_DEBUG) std.debug.print(fmt, args);
}

/// JPEG zig-zag scan order (T.81 Figure A.6). Same table baseline uses.
const ZIGZAG: [64]u8 = .{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

pub const ComponentInfo = struct {
    id: u8,
    h_factor: u4,
    v_factor: u4,
    qt_index: u8,
    dc_table: u8 = 0, // set per scan
    ac_table: u8 = 0,
};

pub const FrameInfo = struct {
    precision: u8,
    height: u16,
    width: u16,
    num_components: u8,
    components: [4]ComponentInfo,
};

pub const ScanInfo = struct {
    num_components: u8,
    /// component_index_in_frame[i] for each scan-component i in 0..num_components
    comp_indices: [4]usize,
    ss: u8,
    se: u8,
    ah: u4,
    al: u4,
};

pub const Error = errors.DecodeError;

/// Diagnostic-only: progressive decode result with natural-order quantized
/// coefficients per component (post-entropy, pre-IDCT). For byte-level diff
/// against libjpeg-turbo's `jpeg_read_coefficients()` output (which is also
/// natural-order). Caller must `freeCoefDump(allocator, dump)` after use.
pub const CoefDump = struct {
    num_components: u8,
    blocks_w: [3]u32,
    blocks_h: [3]u32,
    coefs: [3][]i16, // natural-order, length blocks_w[i]*blocks_h[i]*64

    pub fn deinit(self: *CoefDump, allocator: Allocator) void {
        var i: usize = 0;
        while (i < self.num_components) : (i += 1) {
            if (self.coefs[i].len > 0) allocator.free(self.coefs[i]);
        }
        self.* = undefined;
    }
};

/// Decode the bitstream as far as `decode()` does, but instead of running
/// IDCT + color conversion, return the per-block dequantized coefficients
/// in NATURAL order (un-zig-zagged). The dequantization step IS applied
/// (matching libjpeg's `jpeg_read_coefficients` output, which is also
/// post-entropy but PRE-dequant — so the caller of this function should
/// know which one they want; here we dequant for parity with our own
/// `assembleProgressive` intermediate state).
///
/// Actually: libjpeg's `jpeg_read_coefficients` returns RAW (post-entropy,
/// PRE-dequant) coefficients in natural order. To match, we skip the
/// dequant step here and return the raw zig-zag-then-natural-permuted
/// coefficients.
pub fn decodeAndDumpCoefs(allocator: Allocator, data: []const u8) Error!CoefDump {
    // Same body as decode() up through the SOS scan-loop, but skip the
    // assembleProgressive step. Then un-zig-zag the per-block coefficients
    // into natural order to match libjpeg's `jpeg_read_coefficients`.
    if (data.len < 4) return error.TruncatedStream;
    if (data[0] != 0xFF or data[1] != 0xD8) return error.InvalidMarker;

    var pos: usize = 2;
    var frame: ?FrameInfo = null;
    var quant_tables: [4]?[64]u16 = .{ null, null, null, null };
    var dc_tables: [4]?huffman.HuffmanTable = .{ null, null, null, null };
    var ac_tables: [4]?huffman.HuffmanTable = .{ null, null, null, null };
    var coefs: [3][]i16 = .{ &.{}, &.{}, &.{} };
    var blocks_w: [3]u32 = .{ 0, 0, 0 };
    var blocks_h: [3]u32 = .{ 0, 0, 0 };
    var max_h: u32 = 1;
    var max_v: u32 = 1;
    var saw_eoi = false;
    var seen_sof = false;
    var restart_interval: u16 = 0;

    errdefer {
        var i: usize = 0;
        while (i < 3) : (i += 1) if (coefs[i].len > 0) allocator.free(coefs[i]);
    }

    while (pos + 1 < data.len and !saw_eoi) {
        if (data[pos] != 0xFF) return error.InvalidMarker;
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        const marker = data[pos + 1];
        pos += 2;
        switch (marker) {
            0xD9 => { saw_eoi = true; break; },
            0xC2 => {
                frame = try parseSof(data, pos);
                // T.81 §G.1 progressive: 8-bit and 12-bit are both spec
                // and both produced by libjpeg-turbo (12-bit via
                // -progressive -precision 12). A3 (2026-05-13) closes
                // the 12-bit row via assembleProgressiveGeneric(12).
                if (frame.?.precision != 8 and frame.?.precision != 12)
                    return error.UnsupportedPrecision;
                if (frame.?.num_components != 1 and frame.?.num_components != 3) return error.NotImplemented;
                seen_sof = true;
                var i: usize = 0;
                while (i < frame.?.num_components) : (i += 1) {
                    const c = &frame.?.components[i];
                    if (c.h_factor < 1 or c.h_factor > 4 or c.v_factor < 1 or c.v_factor > 4)
                        return error.NotImplemented;
                    if (@as(u32, c.h_factor) > max_h) max_h = @intCast(c.h_factor);
                    if (@as(u32, c.v_factor) > max_v) max_v = @intCast(c.v_factor);
                }
                const mcu_pixel_w: u32 = max_h * 8;
                const mcu_pixel_h: u32 = max_v * 8;
                const mcu_cols: u32 = (frame.?.width + mcu_pixel_w - 1) / mcu_pixel_w;
                const mcu_rows: u32 = (frame.?.height + mcu_pixel_h - 1) / mcu_pixel_h;
                i = 0;
                while (i < frame.?.num_components) : (i += 1) {
                    const c = &frame.?.components[i];
                    blocks_w[i] = mcu_cols * @as(u32, c.h_factor);
                    blocks_h[i] = mcu_rows * @as(u32, c.v_factor);
                    const total: usize = @as(usize, blocks_w[i]) * @as(usize, blocks_h[i]) * 64;
                    coefs[i] = try allocator.alloc(i16, total);
                    @memset(coefs[i], 0);
                }
                pos += parseSegmentLength(data, pos);
            },
            0xC0, 0xC1, 0xC3 => return error.NotImplemented,
            0xC9, 0xCA, 0xCB => return error.NotImplemented,
            0xC4 => { try parseDht(data, pos, &dc_tables, &ac_tables); pos += parseSegmentLength(data, pos); },
            0xDB => { try parseDqt(data, pos, &quant_tables); pos += parseSegmentLength(data, pos); },
            0xDD => { // DRI — restart interval
                const seg_len = parseSegmentLength(data, pos);
                if (seg_len != 4 or pos + seg_len > data.len) return error.TruncatedStream;
                restart_interval = (@as(u16, data[pos + 2]) << 8) | data[pos + 3];
                pos += seg_len;
            },
            0xDA => {
                if (!seen_sof) return error.InvalidMarker;
                const scan = try parseSos(data, pos, &frame.?);
                pos += parseSegmentLength(data, pos);
                pos = try decodeOneScan(data, pos, &frame.?, &dc_tables, &ac_tables, &coefs, &blocks_w, &blocks_h, max_h, max_v, &scan, restart_interval);
            },
            0x01, 0xD0...0xD7 => continue,
            else => pos += parseSegmentLength(data, pos),
        }
    }
    if (!seen_sof) return error.InvalidMarker;

    // Un-zig-zag each block in place: coefs[ci][block_off..+64] is in
    // zig-zag order; rewrite as natural order so it matches libjpeg's
    // `jpeg_read_coefficients` output (which IS in natural order).
    var ci: u8 = 0;
    while (ci < frame.?.num_components) : (ci += 1) {
        const total_blocks: usize = @as(usize, blocks_w[ci]) * @as(usize, blocks_h[ci]);
        var bi: usize = 0;
        while (bi < total_blocks) : (bi += 1) {
            const off = bi * 64;
            var zz: [64]i16 = undefined;
            @memcpy(&zz, coefs[ci][off..][0..64]);
            var n: usize = 0;
            while (n < 64) : (n += 1) {
                coefs[ci][off + ZIGZAG[n]] = zz[n];
            }
        }
    }

    return CoefDump{
        .num_components = frame.?.num_components,
        .blocks_w = blocks_w,
        .blocks_h = blocks_h,
        .coefs = coefs,
    };
}

/// Decode an 8-bit progressive JPEG (T.81 SOF2). Returns
/// `error.NotImplemented` for any feature this v1 cleanroom doesn't
/// support so the dispatcher in `src/jpegz.zig` can fall back to
/// the libjpeg-turbo wrapper.
pub fn decode(allocator: Allocator, data: []const u8) Error!types.Image {
    if (data.len < 4) return error.TruncatedStream;
    if (data[0] != 0xFF or data[1] != 0xD8) return error.InvalidMarker;

    var pos: usize = 2;
    var frame: ?FrameInfo = null;
    var quant_tables: [4]?[64]u16 = .{ null, null, null, null };
    var dc_tables: [4]?huffman.HuffmanTable = .{ null, null, null, null };
    var ac_tables: [4]?huffman.HuffmanTable = .{ null, null, null, null };
    var coefs: [3][]i16 = .{ &.{}, &.{}, &.{} };
    var blocks_w: [3]u32 = .{ 0, 0, 0 };
    var blocks_h: [3]u32 = .{ 0, 0, 0 };
    var max_h: u32 = 1;
    var max_v: u32 = 1;
    var saw_eoi = false;
    var seen_sof = false;
    // EOB-run state persists ACROSS blocks within a single scan (T.81
    // §G.1.2.2 EOBRUN counter). Reset to zero at scan start.
    var eob_run: u32 = 0;
    _ = &eob_run; // populated inside scan-decoders
    var restart_interval: u16 = 0;

    errdefer {
        var i: usize = 0;
        while (i < 3) : (i += 1) if (coefs[i].len > 0) allocator.free(coefs[i]);
    }

    while (pos + 1 < data.len and !saw_eoi) {
        if (data[pos] != 0xFF) return error.InvalidMarker;
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos + 1 >= data.len) return error.TruncatedStream;
        const marker = data[pos + 1];
        pos += 2;

        switch (marker) {
            0xD9 => { // EOI
                saw_eoi = true;
                break;
            },
            0xC2 => { // SOF2 — progressive DCT
                frame = try parseSof(data, pos);
                // T.81 §G.1 progressive at 8-bit OR 12-bit precision.
                // 12-bit support is A3 (2026-05-13); dispatch on
                // precision at assemble time via Phase 2 comptime
                // specialization.
                if (frame.?.precision != 8 and frame.?.precision != 12)
                    return error.UnsupportedPrecision;
                if (frame.?.num_components != 1 and frame.?.num_components != 3)
                    return error.NotImplemented;
                seen_sof = true;
                // Compute max sampling factors and per-component block grid.
                var i: usize = 0;
                while (i < frame.?.num_components) : (i += 1) {
                    const c = &frame.?.components[i];
                    if (c.h_factor < 1 or c.h_factor > 4 or c.v_factor < 1 or c.v_factor > 4)
                        return error.NotImplemented;
                    if (@as(u32, c.h_factor) > max_h) max_h = @intCast(c.h_factor);
                    if (@as(u32, c.v_factor) > max_v) max_v = @intCast(c.v_factor);
                }
                const mcu_pixel_w: u32 = max_h * 8;
                const mcu_pixel_h: u32 = max_v * 8;
                const mcu_cols: u32 = (frame.?.width + mcu_pixel_w - 1) / mcu_pixel_w;
                const mcu_rows: u32 = (frame.?.height + mcu_pixel_h - 1) / mcu_pixel_h;

                // Allocate persistent zig-zag-ordered coefficient buffers
                // for every block of every component. Size: blocks_w *
                // blocks_h * 64 i16 entries each.
                i = 0;
                while (i < frame.?.num_components) : (i += 1) {
                    const c = &frame.?.components[i];
                    blocks_w[i] = mcu_cols * @as(u32, c.h_factor);
                    blocks_h[i] = mcu_rows * @as(u32, c.v_factor);
                    const total: usize = @as(usize, blocks_w[i]) * @as(usize, blocks_h[i]) * 64;
                    coefs[i] = try allocator.alloc(i16, total);
                    @memset(coefs[i], 0);
                }
                pos += parseSegmentLength(data, pos);
            },
            0xC0, 0xC1, 0xC3 => return error.NotImplemented, // not progressive
            0xC9, 0xCA, 0xCB => return error.NotImplemented, // arithmetic
            0xC4 => { // DHT
                try parseDht(data, pos, &dc_tables, &ac_tables);
                pos += parseSegmentLength(data, pos);
            },
            0xDB => { // DQT
                try parseDqt(data, pos, &quant_tables);
                pos += parseSegmentLength(data, pos);
            },
            0xDD => { // DRI — restart interval
                const seg_len = parseSegmentLength(data, pos);
                if (seg_len != 4 or pos + seg_len > data.len) return error.TruncatedStream;
                restart_interval = (@as(u16, data[pos + 2]) << 8) | data[pos + 3];
                pos += seg_len;
            }, // DRI in progressive — v1.x follow-up
            0xDA => { // SOS
                if (!seen_sof) return error.InvalidMarker;
                const scan = try parseSos(data, pos, &frame.?);
                pos += parseSegmentLength(data, pos);
                // Decode this scan into coefficient buffers; return the
                // byte position past the entropy data (just before the
                // next marker's 0xFF).
                pos = try decodeOneScan(
                    data,
                    pos,
                    &frame.?,
                    &dc_tables,
                    &ac_tables,
                    &coefs,
                    &blocks_w,
                    &blocks_h,
                    max_h,
                    max_v,
                    &scan,
                    restart_interval,
                );
            },
            // Standalone markers we can skip safely.
            0x01, 0xD0...0xD7 => continue,
            // Length-prefixed markers we can skip (APPn, COM, etc.).
            else => pos += parseSegmentLength(data, pos),
        }
    }

    if (!seen_sof) return error.InvalidMarker;

    // ── Final pass: dequant + IDCT each block, emit pixels ────────
    // Dispatch on precision at comptime via the generic Phase 2.
    return switch (frame.?.precision) {
        8 => try assembleProgressiveGeneric(8, allocator, &frame.?, &quant_tables, &coefs, &blocks_w, &blocks_h, max_h, max_v),
        12 => try assembleProgressiveGeneric(12, allocator, &frame.?, &quant_tables, &coefs, &blocks_w, &blocks_h, max_h, max_v),
        else => unreachable, // gated above
    };
}

pub fn parseSegmentLength(data: []const u8, pos: usize) usize {
    if (pos + 1 >= data.len) return 0;
    return (@as(usize, data[pos]) << 8) | data[pos + 1];
}

pub fn parseSof(data: []const u8, pos: usize) Error!FrameInfo {
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
            .qt_index = data[off + 2],
        };
    }
    return fi;
}

pub fn parseDqt(
    data: []const u8,
    pos: usize,
    quant_tables: *[4]?[64]u16,
) Error!void {
    const seg_len = parseSegmentLength(data, pos);
    if (seg_len < 2 or pos + seg_len > data.len) return error.TruncatedStream;
    var off: usize = pos + 2;
    const seg_end = pos + seg_len;
    while (off < seg_end) {
        if (off >= data.len) return error.TruncatedStream;
        const pq_tq = data[off];
        const precision_id: u8 = pq_tq >> 4;
        const tq: u8 = pq_tq & 0x0F;
        if (tq > 3) return error.InvalidMarker;
        off += 1;
        var table: [64]u16 = undefined;
        if (precision_id == 0) {
            if (off + 64 > seg_end) return error.TruncatedStream;
            var i: usize = 0;
            while (i < 64) : (i += 1) table[i] = data[off + i];
            off += 64;
        } else if (precision_id == 1) {
            if (off + 128 > seg_end) return error.TruncatedStream;
            var i: usize = 0;
            while (i < 64) : (i += 1) {
                table[i] = (@as(u16, data[off + i * 2]) << 8) | data[off + i * 2 + 1];
            }
            off += 128;
        } else return error.InvalidMarker;
        quant_tables[tq] = table;
    }
}

fn parseDht(
    data: []const u8,
    pos: usize,
    dc_tables: *[4]?huffman.HuffmanTable,
    ac_tables: *[4]?huffman.HuffmanTable,
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
        if (tc > 1 or th > 3) return error.InvalidMarker;
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
        if (tc == 0) dc_tables[th] = t else ac_tables[th] = t;
        off += total;
    }
}

pub fn parseSos(data: []const u8, pos: usize, frame: *FrameInfo) Error!ScanInfo {
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
                frame.components[j].ac_table = td_ta & 0x0F;
                info.comp_indices[i] = j;
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidMarker;
    }
    const tail_off = pos + 3 + info.num_components * 2;
    info.ss = data[tail_off];
    info.se = data[tail_off + 1];
    const ah_al = data[tail_off + 2];
    info.ah = @intCast(ah_al >> 4);
    info.al = @intCast(ah_al & 0x0F);
    return info;
}

/// T.81 §F.2.1.3.2: at every restart-interval boundary, the entropy
/// stream is realigned: bit buffer flushed to the next byte boundary,
/// the upcoming RSTm marker (FF D0..D7) consumed, predictors reset.
/// For progressive scans, we additionally reset `eob_run` (an
/// EOB-run state that persists ACROSS blocks within a scan but
/// MUST NOT cross a restart marker).
fn handleRestart(
    br: *bitstream.BitReader,
    prev_dc: *[3]i16,
    eob_run: *u32,
    expected_rst: *u8,
) Error!void {
    br.seekToMarker();
    if (!br.marker_seen) return error.InvalidMarker;
    if (br.marker_byte != expected_rst.*) return error.InvalidMarker;
    prev_dc.* = .{ 0, 0, 0 };
    eob_run.* = 0;
    expected_rst.* = 0xD0 + ((expected_rst.* - 0xD0 + 1) & 0x07);
    br.skipPastMarker();
}

/// Decode one progressive scan and return the byte position immediately
/// after the entropy data (at the next marker's 0xFF byte).
fn decodeOneScan(
    data: []const u8,
    entropy_start: usize,
    frame: *const FrameInfo,
    dc_tables: *const [4]?huffman.HuffmanTable,
    ac_tables: *const [4]?huffman.HuffmanTable,
    coefs: *[3][]i16,
    blocks_w: *const [3]u32,
    blocks_h: *const [3]u32,
    max_h: u32,
    max_v: u32,
    scan: *const ScanInfo,
    restart_interval: u16,
) Error!usize {
    var br = bitstream.BitReader.init(data[entropy_start..]);
    var prev_dc: [3]i16 = .{ 0, 0, 0 };
    var eob_run: u32 = 0;
    // RST handling state. T.81 §F.2.1.3: every `restart_interval` MCUs
    // (or blocks for single-component scans), the encoder emits an
    // RSTm marker (FF D0..D7), the decoder flushes the bit buffer to a
    // byte boundary, resets `prev_dc` (and our progressive `eob_run`),
    // and consumes the RST marker. RSTm cycles 0..7.
    var units_since_rst: u32 = 0;
    var expected_rst: u8 = 0xD0;

    // Two iteration shapes:
    //   - Multi-component (interleaved) scan: walk MCUs the same way
    //     baseline does, decoding (h_factor × v_factor) blocks per
    //     component per MCU. Per T.81 §G.1.1.1.1: only the DC scans
    //     are typically multi-component (Ss=0, Se=0).
    //   - Single-component scan: the more common case for AC scans.
    //     Walk all blocks of that component in row-major order
    //     (block-by-block, not MCU-by-MCU).
    if (scan.num_components > 1) {
        const mcu_cols: u32 = blocks_w[0] / @as(u32, frame.components[0].h_factor);
        const mcu_rows: u32 = blocks_h[0] / @as(u32, frame.components[0].v_factor);
        var my: u32 = 0;
        while (my < mcu_rows) : (my += 1) {
            var mx: u32 = 0;
            while (mx < mcu_cols) : (mx += 1) {
                if (restart_interval > 0 and units_since_rst == restart_interval) {
                    try handleRestart(&br, &prev_dc, &eob_run, &expected_rst);
                    units_since_rst = 0;
                }
                var ci: usize = 0;
                while (ci < scan.num_components) : (ci += 1) {
                    const comp_idx = scan.comp_indices[ci];
                    const comp = &frame.components[comp_idx];
                    const bh: u32 = @intCast(comp.h_factor);
                    const bv: u32 = @intCast(comp.v_factor);
                    var bv_i: u32 = 0;
                    while (bv_i < bv) : (bv_i += 1) {
                        var bh_i: u32 = 0;
                        while (bh_i < bh) : (bh_i += 1) {
                            const block_x: u32 = mx * bh + bh_i;
                            const block_y: u32 = my * bv + bv_i;
                            const off: usize = (@as(usize, block_y) *
                                @as(usize, blocks_w[comp_idx]) +
                                @as(usize, block_x)) * 64;
                            const block = coefs[comp_idx][off .. off + 64];
                            try decodeProgressiveBlock(
                                &br, comp, dc_tables, ac_tables,
                                &prev_dc, &eob_run, comp_idx, block, scan,
                            );
                        }
                    }
                }
                units_since_rst += 1;
            }
        }
    } else {
        const comp_idx = scan.comp_indices[0];
        const comp = &frame.components[comp_idx];
        // T.81 §A.2.4: For single-component (Ns=1) scans, the iteration
        // bounds use the COMPONENT's own image-aligned block grid, NOT
        // the MCU-padded grid used by multi-component scans:
        //   xi = ceil(W * Hi / (8 * Hmax))
        //   yi = ceil(H * Vi / (8 * Vmax))
        // For 4:2:0 luma at 549×304: blocks_w[0]=70 (MCU-padded) but
        // single-component xi=69. Walking all 70 columns mis-syncs the
        // bitstream because the encoder only wrote 69 blocks per row in
        // this scan — the 70th column gets coefficient updates ONLY in
        // multi-component (DC interleaved) scans. Iteration: stride is
        // still `blocks_w[comp_idx]` (the buffer width), but the inner
        // loop bound is the per-spec component image extent.
        const W: u32 = frame.width;
        const H_full: u32 = frame.height;
        const xi: u32 = (W * @as(u32, comp.h_factor) + (8 * max_h) - 1) / (8 * max_h);
        const yi: u32 = (H_full * @as(u32, comp.v_factor) + (8 * max_v) - 1) / (8 * max_v);
        const bw: u32 = xi;
        const bh: u32 = yi;
        const stride: u32 = blocks_w[comp_idx];
        var by: u32 = 0;
        while (by < bh) : (by += 1) {
            var bx: u32 = 0;
            while (bx < bw) : (bx += 1) {
                if (restart_interval > 0 and units_since_rst == restart_interval) {
                    try handleRestart(&br, &prev_dc, &eob_run, &expected_rst);
                    units_since_rst = 0;
                }
                const off: usize = (@as(usize, by) * @as(usize, stride) +
                    @as(usize, bx)) * 64;
                const block = coefs[comp_idx][off .. off + 64];
                try decodeProgressiveBlock(
                    &br, comp, dc_tables, ac_tables,
                    &prev_dc, &eob_run, comp_idx, block, scan,
                );
                units_since_rst += 1;
            }
        }
    }

    // After the scan's blocks are decoded, the bit buffer may still hold
    // padding bits from the last byte that the encoder inserted before
    // emitting the next marker. `markerHit` won't be true unless the
    // refill logic walked into the marker. Force-look-ahead with
    // `seekToMarker` — drops the padding bits, then peeks at byte_pos
    // to detect `FF NN` (NN != 00). This mirrors baseline's RST handling
    // at restart-interval boundaries (src/decode/baseline.zig:451).
    br.seekToMarker();
    if (!br.marker_seen) {
        dbg("[prog:scan_end] no marker after scan: byte_pos={d} bits_valid={d}\n", .{ br.byte_pos, br.bits_valid });
        return error.TruncatedStream;
    }
    return entropy_start + br.byte_pos;
}

fn decodeProgressiveBlock(
    br: *bitstream.BitReader,
    comp: *const ComponentInfo,
    dc_tables: *const [4]?huffman.HuffmanTable,
    ac_tables: *const [4]?huffman.HuffmanTable,
    prev_dc: *[3]i16,
    eob_run: *u32,
    comp_idx: usize,
    block: []i16,
    scan: *const ScanInfo,
) Error!void {
    // libjpeg-turbo `insufficient_data` parity: if the entropy stream has
    // already hit the next marker and the bit buffer is empty, leave this
    // and all remaining blocks at their current value (zero for first-pass
    // scans, prior coefficients for refinement scans). Per
    // libjpeg-turbo/jdphuff.c decode_mcu_AC_first: "If we've run out of
    // data, just leave the MCU set to zeroes."
    if (br.markerHit() and br.bits_valid == 0) return;
    if (scan.ss == 0) {
        // DC scan
        if (scan.ah == 0) try decodeProgressiveDcFirst(br, comp, dc_tables, prev_dc, comp_idx, block, scan)
        else try decodeProgressiveDcRefine(br, block, scan);
    } else {
        // AC scan (single-component)
        if (scan.ah == 0) try decodeProgressiveAcFirst(br, comp, ac_tables, eob_run, block, scan)
        else try decodeProgressiveAcRefine(br, comp, ac_tables, eob_run, block, scan);
    }
}

/// T.81 §G.1.2.1 — DC, first pass (Ah=0).
/// The DC differential is decoded normally, then shifted left by Al
/// before storing. prev_dc tracks across blocks of the same component.
fn decodeProgressiveDcFirst(
    br: *bitstream.BitReader,
    comp: *const ComponentInfo,
    dc_tables: *const [4]?huffman.HuffmanTable,
    prev_dc: *[3]i16,
    comp_idx: usize,
    block: []i16,
    scan: *const ScanInfo,
) Error!void {
    const dc_t = dc_tables[comp.dc_table] orelse return error.InvalidMarker;
    const dc_size: u8 = dc_t.decode(br) catch |e| {
        if (br.markerHit()) return; // insufficient_data tolerance
        dbg("[prog:dc_first] huff fail comp={d} dc_table={d} byte_pos={d} bits_valid={d} buf=0x{x} err={s}\n", .{ comp_idx, comp.dc_table, br.byte_pos, br.bits_valid, br.buf, @errorName(e) });
        return error.BackendError;
    };
    if (dc_size > 11) {
        if (br.markerHit()) return; // garbage bits from past-marker buffer
        dbg("[prog:dc_first] dc_size>11 ({d}) comp={d} byte_pos={d}\n", .{ dc_size, comp_idx, br.byte_pos });
        return error.BackendError;
    }
    var dc_diff: i16 = 0;
    if (dc_size > 0) {
        const bits = br.readBits(@intCast(dc_size)) catch {
            if (br.markerHit()) return;
            return error.TruncatedStream;
        };
        dc_diff = huffman.extendSign(bits, @intCast(dc_size));
    }
    prev_dc[comp_idx] += dc_diff;
    block[0] = @as(i16, @intCast(@as(i32, prev_dc[comp_idx]) << @intCast(scan.al)));
}

/// T.81 §G.1.2.3 — DC refinement pass (Ah>0). Read 1 bit, shift-OR into
/// the DC coefficient at bit position Al.
fn decodeProgressiveDcRefine(
    br: *bitstream.BitReader,
    block: []i16,
    scan: *const ScanInfo,
) Error!void {
    const bit = br.readBits(1) catch {
        if (br.markerHit()) return;
        return error.TruncatedStream;
    };
    if (bit == 1) {
        block[0] = @as(i16, @intCast(@as(i32, block[0]) | (@as(i32, 1) << @intCast(scan.al))));
    }
}

/// T.81 §G.1.2.2 — AC first pass (Ah=0). Like baseline AC decode but:
///  - EOB run extension: RS values 0x10..0xE0 mean "end-of-band run for
///    2^run additional blocks" (skip `eob_run` more blocks at end-of-block).
///  - Decoded value shifted left by Al before storing.
fn decodeProgressiveAcFirst(
    br: *bitstream.BitReader,
    comp: *const ComponentInfo,
    ac_tables: *const [4]?huffman.HuffmanTable,
    eob_run: *u32,
    block: []i16,
    scan: *const ScanInfo,
) Error!void {
    if (eob_run.* > 0) {
        eob_run.* -= 1;
        return;
    }
    const ac_t = ac_tables[comp.ac_table] orelse return error.InvalidMarker;

    var k: u8 = scan.ss;
    while (k <= scan.se) {
        const rs: u8 = ac_t.decode(br) catch |e| {
            if (br.markerHit()) return; // insufficient_data tolerance
            dbg("[prog:ac_first] huff fail ac_table={d} k={d} ss={d} se={d} byte_pos={d} bits_valid={d} buf=0x{x} err={s}\n", .{ comp.ac_table, k, scan.ss, scan.se, br.byte_pos, br.bits_valid, br.buf, @errorName(e) });
            return error.BackendError;
        };
        const run: u8 = rs >> 4;
        const size: u8 = rs & 0x0F;
        if (size == 0) {
            if (run == 15) {
                // ZRL — 16 zeros
                k += 16;
                continue;
            } else {
                // EOB run: 2^run + extra `run` bits more blocks
                eob_run.* = (@as(u32, 1) << @intCast(run));
                if (run > 0) {
                    const extra = br.readBits(@intCast(run)) catch {
                        if (br.markerHit()) return;
                        return error.TruncatedStream;
                    };
                    eob_run.* += @intCast(extra);
                }
                eob_run.* -= 1;
                break;
            }
        }
        k += run;
        if (k > scan.se) {
            if (br.markerHit()) return;
            dbg("[prog:ac_first] k>se after run k={d} se={d} byte_pos={d}\n", .{ k, scan.se, br.byte_pos });
            return error.BackendError;
        }
        const bits = br.readBits(@intCast(size)) catch {
            if (br.markerHit()) return;
            return error.TruncatedStream;
        };
        const val = huffman.extendSign(bits, @intCast(size));
        block[k] = @as(i16, @intCast(@as(i32, val) << @intCast(scan.al)));
        k += 1;
    }
}

/// T.81 §G.1.2.3 — AC refinement pass (Ah>0). Per the procedure:
///   While k ≤ Se:
///     Read RS = (run, size).
///     Determine new_val (size != 0) or set ZRL/EOB run state.
///     Walk forward across `run` zero positions (and any number of
///     existing nonzeros), refining each existing nonzero by 1 bit.
///     If a new_val is pending, place it at the position after the
///     last walked zero. ZRL = "16 zeros, no new nonzero".
///     EOB run takes effect for SUBSEQUENT blocks; in the current
///     block, refine remaining nonzeros and stop.
fn decodeProgressiveAcRefine(
    br: *bitstream.BitReader,
    comp: *const ComponentInfo,
    ac_tables: *const [4]?huffman.HuffmanTable,
    eob_run: *u32,
    block: []i16,
    scan: *const ScanInfo,
) Error!void {
    const ac_t = ac_tables[comp.ac_table] orelse return error.InvalidMarker;
    const positive: i16 = @as(i16, @intCast(@as(i32, 1) << @intCast(scan.al)));
    const negative: i16 = -positive;

    var k: u8 = scan.ss;

    if (eob_run.* > 0) {
        // EOB-run carry-over from a previous block: just refine
        // remaining nonzeros in this block, no new nonzeros.
        while (k <= scan.se) : (k += 1) {
            try refineExistingNonzero(br, block, k, positive, negative);
        }
        eob_run.* -= 1;
        return;
    }

    while (k <= scan.se) {
        const rs: u8 = ac_t.decode(br) catch |e| {
            if (br.markerHit()) return;
            const remaining: usize = if (br.byte_pos < br.data.len) br.data.len - br.byte_pos else 0;
            const next3: [3]u8 = if (br.byte_pos + 2 < br.data.len) .{ br.data[br.byte_pos], br.data[br.byte_pos + 1], br.data[br.byte_pos + 2] } else .{ 0, 0, 0 };
            dbg("[prog:ac_refine] huff fail ac_table={d} k={d} byte_pos={d} bytes_left={d} next3={x:0>2}{x:0>2}{x:0>2} buf=0x{x} bits_valid={d} marker_seen={} err={s}\n", .{ comp.ac_table, k, br.byte_pos, remaining, next3[0], next3[1], next3[2], br.buf, br.bits_valid, br.marker_seen, @errorName(e) });
            return error.BackendError;
        };
        const run_field: u8 = rs >> 4;
        const size: u8 = rs & 0x0F;
        var zeros_remaining: u8 = run_field;
        var has_pending_new: bool = false;
        var new_val: i16 = 0;

        if (size != 0) {
            if (size != 1) {
                if (br.markerHit()) return;
                dbg("[prog:ac_refine] size!=1 (size={d}) k={d} se={d} byte_pos={d}\n", .{ size, k, scan.se, br.byte_pos });
                return error.BackendError; // refinement always ±1 LSB
            }
            const bit = br.readBits(1) catch {
                if (br.markerHit()) return;
                return error.TruncatedStream;
            };
            new_val = if (bit == 1) positive else negative;
            has_pending_new = true;
        } else if (run_field == 15) {
            // ZRL: 16 zeros, no new value.
            zeros_remaining = 16;
        } else {
            // EOB run: 2^run blocks (current + future), refine remaining
            // nonzeros in this block, mark eob_run for following blocks.
            var count: u32 = (@as(u32, 1) << @intCast(run_field));
            if (run_field > 0) {
                const extra = br.readBits(@intCast(run_field)) catch {
                    if (br.markerHit()) return;
                    return error.TruncatedStream;
                };
                count += @intCast(extra);
            }
            eob_run.* = count - 1; // current block consumed inline below
            while (k <= scan.se) : (k += 1) {
                try refineExistingNonzero(br, block, k, positive, negative);
            }
            return;
        }

        // Walk forward refining existing nonzeros, decrement zeros_remaining
        // for each zero seen. Per libjpeg-turbo jdphuff.c
        // decode_mcu_AC_refine, the inner loop breaks when `--r < 0` —
        // i.e., AFTER decrementing on the (run+1)-th zero. For ZRL
        // (run=15, size=0) this is the 16th zero. For non-ZRL with new
        // value, this is the (R+1)-th zero where the new value is
        // placed.
        //
        // Critical: for ZRL, we must break IMMEDIATELY after the 16th
        // zero is decremented — without iterating once more. Otherwise,
        // a nonzero appearing right after the 16-zero window would be
        // refined here even though the encoder wrote no refinement bit
        // for it (it belongs to the NEXT RS code).
        const is_zrl = (size == 0 and run_field == 15);
        while (k <= scan.se) {
            if (block[k] != 0) {
                try refineExistingNonzero(br, block, k, positive, negative);
            } else {
                if (zeros_remaining == 0) {
                    if (has_pending_new) {
                        block[k] = new_val;
                        k += 1;
                    }
                    break;
                }
                zeros_remaining -= 1;
                if (is_zrl and zeros_remaining == 0) {
                    // 16th zero just decremented for ZRL — break before
                    // refining any nonzero that follows. Advance past
                    // this zero so the outer RS loop resumes after it.
                    k += 1;
                    break;
                }
            }
            k += 1;
        }
    }
}

inline fn refineExistingNonzero(
    br: *bitstream.BitReader,
    block: []i16,
    k: u8,
    positive: i16,
    negative: i16,
) Error!void {
    if (block[k] == 0) return;
    const bit = br.readBits(1) catch {
        if (br.markerHit()) return;
        return error.TruncatedStream;
    };
    if (bit == 0) return;
    // Refinement: add ±positive in the direction of the existing sign.
    if (block[k] > 0) {
        block[k] = @as(i16, @intCast(@as(i32, block[k]) + @as(i32, positive)));
    } else {
        block[k] = @as(i16, @intCast(@as(i32, block[k]) + @as(i32, negative)));
    }
}

/// Thin wrapper preserving the 8-bit entry-point API. Calls into the
/// comptime-P-generic version below at P=8.
fn assembleProgressive(
    allocator: Allocator,
    frame: *const FrameInfo,
    quant_tables: *const [4]?[64]u16,
    coefs: *[3][]i16,
    blocks_w: *const [3]u32,
    blocks_h: *const [3]u32,
    max_h: u32,
    max_v: u32,
) Error!types.Image {
    return assembleProgressiveGeneric(8, allocator, frame, quant_tables, coefs, blocks_w, blocks_h, max_h, max_v);
}

/// Phase 2 of progressive decode, generic over precision P ∈ {8, 12}.
///
/// Inputs: per-component i16 quantized DCT coefficient buffers (the
/// output of Phase 1, which is the multi-scan entropy decoder — its
/// shape is precision-agnostic because the SSSS limits and amplitude
/// ranges are derived from T.81 §F.1.4 / Table F.1 and work for any
/// P in {8, 12} given an i16 storage slot per coefficient).
///
/// Outputs: an `Image` with `bits_per_sample = P`. At P=8 the pixel
/// buffer is `[]u8` and the result is byte-identical to the previous
/// (non-generic) implementation. At P=12 the pixel buffer is `[]u8`
/// holding a host-endian `[]u16` view, range [0, 4095] per sample;
/// consumer reads via `image.pixelsU16()`.
///
/// Per-precision specialization (chosen at comptime, so each
/// instantiation gets one concrete code path with no runtime branch):
///   - IDCT: `idct.idct8x8Generic(P, ...)`
///   - Chroma upsample: `color.fancyUpsample` (P=8) or
///     `color.fancyUpsample12` (P=12)
///   - YCbCr→RGB: `color.ycbcrRowToRgb` (P=8) or `ycbcrRowToRgb12`
///     (P=12)
///
/// 12-bit support is the A3 milestone (2026-05-13). The 8-bit path
/// is unchanged behaviorally.
pub fn assembleProgressiveGeneric(
    comptime P: u8,
    allocator: Allocator,
    frame: *const FrameInfo,
    quant_tables: *const [4]?[64]u16,
    coefs: *[3][]i16,
    blocks_w: *const [3]u32,
    blocks_h: *const [3]u32,
    max_h: u32,
    max_v: u32,
) Error!types.Image {
    const Sample = idct.Sample(P); // u8 for P=8, u16 for P=12.
    const channels: u8 = frame.num_components;
    const width: u32 = frame.width;
    const height: u32 = frame.height;

    var planes: [3][]Sample = .{ &.{}, &.{}, &.{} };
    var plane_w: [3]u32 = .{ 0, 0, 0 };
    var plane_h: [3]u32 = .{ 0, 0, 0 };
    var i: usize = 0;
    while (i < channels) : (i += 1) {
        plane_w[i] = blocks_w[i] * 8;
        plane_h[i] = blocks_h[i] * 8;
        planes[i] = try allocator.alloc(Sample, plane_w[i] * plane_h[i]);
    }
    errdefer {
        var j: usize = 0;
        while (j < channels) : (j += 1) if (planes[j].len > 0) allocator.free(planes[j]);
    }

    // Per block: dequant in zig-zag space, un-zig-zag, IDCT, copy.
    i = 0;
    while (i < channels) : (i += 1) {
        const comp = &frame.components[i];
        const qt = quant_tables[comp.qt_index] orelse return error.InvalidMarker;
        const bw = blocks_w[i];
        const bh = blocks_h[i];

        var by: u32 = 0;
        while (by < bh) : (by += 1) {
            var bx: u32 = 0;
            while (bx < bw) : (bx += 1) {
                const off: usize = (@as(usize, by) * @as(usize, bw) +
                    @as(usize, bx)) * 64;
                var zz: [64]i16 = undefined;
                @memcpy(&zz, coefs[i][off .. off + 64]);
                // Dequantize (zig-zag space).
                var n: usize = 0;
                while (n < 64) : (n += 1) {
                    zz[n] = @as(i16, @intCast(@as(i32, zz[n]) * @as(i32, qt[n])));
                }
                var natural: [64]i32 = undefined;
                n = 0;
                while (n < 64) : (n += 1) {
                    natural[ZIGZAG[n]] = @as(i32, zz[n]);
                }
                var block_pix: [64]Sample = undefined;
                idct.idct8x8Generic(P, &natural, &block_pix);
                // Copy 8×8 spatial block into plane.
                var py: u32 = 0;
                while (py < 8) : (py += 1) {
                    var px: u32 = 0;
                    while (px < 8) : (px += 1) {
                        const dst_x: u32 = bx * 8 + px;
                        const dst_y: u32 = by * 8 + py;
                        planes[i][dst_y * plane_w[i] + dst_x] = block_pix[py * 8 + px];
                    }
                }
            }
        }
    }

    // Free coefficient buffers (no longer needed).
    {
        var k: usize = 0;
        while (k < channels) : (k += 1) if (coefs[k].len > 0) allocator.free(coefs[k]);
    }

    // Allocate output as []u8. For P=8 each sample is 1 byte. For P=12
    // it's 2 bytes (host-endian u16 byte view). Same shape as the
    // baseline 12-bit paths.
    const bytes_per_sample: usize = if (P == 8) 1 else 2;
    const out_samples: usize = @as(usize, width) * @as(usize, height) * @as(usize, channels);
    const pixels = try allocator.alloc(u8, out_samples * bytes_per_sample);
    errdefer allocator.free(pixels);

    if (channels == 1) {
        // Grayscale passthrough — copy Y plane directly into output.
        if (P == 8) {
            var y: u32 = 0;
            while (y < height) : (y += 1) {
                var x: u32 = 0;
                while (x < width) : (x += 1) {
                    pixels[y * width + x] = planes[0][y * plane_w[0] + x];
                }
            }
        } else {
            const out_u16: []align(1) u16 = std.mem.bytesAsSlice(u16, pixels);
            var y: u32 = 0;
            while (y < height) : (y += 1) {
                var x: u32 = 0;
                while (x < width) : (x += 1) {
                    out_u16[y * width + x] = planes[0][y * plane_w[0] + x];
                }
            }
        }
    } else {
        // Three-component path: produce a canvas at MCU resolution
        // (canvas_w/canvas_h), upsample each chroma plane via IJG fancy
        // upsampling so it lines up with Y, then convert row-by-row to
        // RGB using libjpeg-turbo's fixed-point math. Mirrors baseline
        // cleanroom's `assembleOutput` / `decodeScan12Rgb` so the two
        // paths produce byte-equal output for the same coefficient buf.
        const c1 = &frame.components[1];
        const c2 = &frame.components[2];
        const canvas_w: u32 = plane_w[0];
        const canvas_h: u32 = plane_h[0];

        const active_w1: u32 = (width * @as(u32, c1.h_factor) + max_h - 1) / max_h;
        const active_h1: u32 = (height * @as(u32, c1.v_factor) + max_v - 1) / max_v;
        const active_w2: u32 = (width * @as(u32, c2.h_factor) + max_h - 1) / max_h;
        const active_h2: u32 = (height * @as(u32, c2.v_factor) + max_v - 1) / max_v;

        const h_ratio_1: u32 = max_h / @as(u32, c1.h_factor);
        const v_ratio_1: u32 = max_v / @as(u32, c1.v_factor);
        const h_ratio_2: u32 = max_h / @as(u32, c2.h_factor);
        const v_ratio_2: u32 = max_v / @as(u32, c2.v_factor);

        // Upsample helpers diverge by precision; pick at comptime.
        const upsample = if (P == 8) color.fancyUpsample else color.fancyUpsample12;

        const cb_canvas: []const Sample = if (h_ratio_1 == 1 and v_ratio_1 == 1)
            planes[1]
        else
            try upsample(allocator, planes[1], plane_w[1], plane_h[1], canvas_w, canvas_h, active_w1, active_h1, h_ratio_1, v_ratio_1);
        defer if (h_ratio_1 != 1 or v_ratio_1 != 1) allocator.free(@constCast(cb_canvas));

        const cr_canvas: []const Sample = if (h_ratio_2 == 1 and v_ratio_2 == 1)
            planes[2]
        else
            try upsample(allocator, planes[2], plane_w[2], plane_h[2], canvas_w, canvas_h, active_w2, active_h2, h_ratio_2, v_ratio_2);
        defer if (h_ratio_2 != 1 or v_ratio_2 != 1) allocator.free(@constCast(cr_canvas));

        if (P == 8) {
            var y: u32 = 0;
            while (y < height) : (y += 1) {
                color.ycbcrRowToRgb(planes[0], cb_canvas, cr_canvas, canvas_w, width, pixels, y);
            }
        } else {
            const pixels_u16: []align(1) u16 = std.mem.bytesAsSlice(u16, pixels);
            var y: u32 = 0;
            while (y < height) : (y += 1) {
                color.ycbcrRowToRgb12(planes[0], cb_canvas, cr_canvas, canvas_w, width, pixels_u16, y);
            }
        }
    }

    var p: usize = 0;
    while (p < channels) : (p += 1) allocator.free(planes[p]);

    return types.Image{
        .pixels = pixels,
        .width = width,
        .height = height,
        .channels = channels,
        .bits_per_sample = P,
        .source_color_space = if (channels == 1) .grayscale else .ycbcr,
        .layout = if (channels == 1) .grayscale else .rgb,
    };
}

