//! Finding 19 `jpeg_segment_geometry_invalid`: a JPEG-in-TIFF (Compression 7)
//! segment whose frame header (SOF) disagrees with the TIFF fields TIFF
//! Technical Note 2 binds it to (owner-approved 2026-11-04; design in
//! docs/plan_context/jpeg-segment-geometry.md):
//!
//! 1. DCT SOF in a multi-strip image: RowsPerStrip is a multiple of 8 * Vmax.
//! 2. DCT SOF in a tiled image: TileWidth is a multiple of 8 * Hmax.
//! 3. DCT SOF in a tiled image: TileLength is a multiple of 8 * Vmax.
//! 4. PlanarConfiguration 1: for YCbCr, luma factors are YCbCrSubSampling
//!    times the chroma factors and both chroma components agree; otherwise
//!    every component has the same factors.
//! 5. PlanarConfiguration 2: every factor is 1.
//! 6. In a DNG of known version (DNG 1.6.0.0 Chapter 3, Compression; owner,
//!    2026-11-04): YCbCr with BitsPerSample 8/8/8 or BlackIsZero with
//!    BitsPerSample 8 must be baseline DCT JPEG (SOF0); anything else must
//!    be lossless Huffman JPEG (SOF3). The record cites Compression, its TIFF
//!    value is the PhotometricInterpretation and its required value the SOF
//!    type the rule requires.
//!
//! Lossless SOFs (3, 7, 11, 15) are exempt from rules 1 to 3. Every segment
//! is examined; one record per IFD per violated rule carries the first
//! violating segment and the counts. A segment whose frame header cannot be
//! read is not examined (jpegz reports why) and never counts as a pass.
//!
//! Pure: the decoder feeds it parsed frame headers and TIFF field values.

const std = @import("std");
const jpegz = @import("jpegz");

pub const Rule = enum(u16) {
    rows = 1,
    tile_width = 2,
    tile_length = 3,
    sampling_factors = 4,
    planar_factors = 5,
    dng_variant = 6,
};
const rule_count = @typeInfo(Rule).@"enum".fields.len;

/// The SOF classes of T.81 Table B.1, exact (validate, 2026-11-04). null for
/// 4 (DHT), 8 (JPG) and 12 (DAC), which are not frame headers.
pub const SofClass = enum { dct, lossless };
pub fn sofClass(sof_type: u4) ?SofClass {
    const kind = jpegz.frameKind(sof_type) orelse return null;
    return if (kind.isDct()) .dct else .lossless;
}

/// The TIFF fields one IFD's segments are checked against, with the
/// absolute offset of the entry each rule cites.
pub const Fields = struct {
    tiled: bool,
    /// More than one strip per plane: RowsPerStrip < ImageLength.
    multi_strip: bool,
    rows_per_strip: u32,
    tile_width: u32,
    tile_length: u32,
    /// PlanarConfiguration, default 1.
    planar: u16,
    /// PhotometricInterpretation, if present and readable.
    photometric: ?u16,
    /// YCbCrSubSampling, default [2, 2].
    subsampling: [2]u16,
    /// False when YCbCrSubSampling is present but malformed (its own
    /// finding 18): rule 4 is then not checked against a guess.
    sampling_known: bool = true,
    rows_entry: u64,
    tile_width_entry: u64,
    tile_length_entry: u64,
    /// YCbCrSubSampling's entry, or PhotometricInterpretation's when the
    /// default subsampling applies or the image is not YCbCr.
    sampling_entry: u64,
    planar_entry: u64,
    /// Rule 6: true when DNG requires baseline DCT, false when it requires
    /// lossless Huffman JPEG, null when the rule does not apply (not a DNG
    /// of known version, or a field it needs is absent or malformed).
    dng_baseline: ?bool = null,
    compression_entry: u64 = 0,
};

pub const Record = struct {
    rule: Rule,
    first_segment: u32,
    entry_offset: u64,
    sof_offset: u64,
    sof_type: u4,
    tiff_value: u32,
    /// Rules 1-3: the required multiple. Rules 4 and 5: the disagreeing
    /// component's index << 16 | H << 8 | V.
    required: u32,
    violating: u32,
    examined: u32,
};

pub const Accumulator = struct {
    fields: Fields,
    examined: u32 = 0,
    last_segment: ?u32 = null,
    records: [rule_count]?Record = .{null} ** rule_count,

    /// Examine one segment's frame header. A segment seen again (the
    /// decoder retries with a larger buffer) is not counted twice.
    pub fn add(self: *Accumulator, segment: u32, sof_host_offset: u64, header: *const jpegz.FrameHeader) void {
        if (self.last_segment) |last| if (last == segment) return;
        self.last_segment = segment;
        self.examined += 1;
        const f = self.fields;
        if (f.dng_baseline) |baseline| {
            const want: u4 = if (baseline) baseline_sof else lossless_huffman_sof;
            if (header.sof_type != want)
                self.note(.dng_variant, segment, sof_host_offset, header.sof_type, f.compression_entry, f.photometric orelse 0, want);
        }
        const comps = header.components();
        if (comps.len == 0) return;
        var hmax: u32 = 0;
        var vmax: u32 = 0;
        for (comps) |c| {
            hmax = @max(hmax, c.h);
            vmax = @max(vmax, c.v);
        }
        const dct = header.kind.isDct();
        // Factors outside 1..4 are jpegz's finding; no MCU size exists then.
        const mcu_ok = hmax >= 1 and hmax <= 4 and vmax >= 1 and vmax <= 4;
        if (dct and mcu_ok) {
            if (!f.tiled and f.multi_strip and f.rows_per_strip % (8 * vmax) != 0)
                self.note(.rows, segment, sof_host_offset, header.sof_type, f.rows_entry, f.rows_per_strip, 8 * vmax);
            if (f.tiled and f.tile_width % (8 * hmax) != 0)
                self.note(.tile_width, segment, sof_host_offset, header.sof_type, f.tile_width_entry, f.tile_width, 8 * hmax);
            if (f.tiled and f.tile_length % (8 * vmax) != 0)
                self.note(.tile_length, segment, sof_host_offset, header.sof_type, f.tile_length_entry, f.tile_length, 8 * vmax);
        }
        if (f.planar == 2) {
            for (comps, 0..) |c, i| if (c.h != 1 or c.v != 1) {
                self.note(.planar_factors, segment, sof_host_offset, header.sof_type, f.planar_entry, 2, packComponent(i, c));
                break;
            };
        } else if (!f.sampling_known) {
            // Rule 4 needs a readable YCbCrSubSampling.
        } else if (samplingMismatch(f, comps)) |i| {
            const tiff_value: u32 = if (f.photometric == ycbcr)
                @as(u32, f.subsampling[0]) << 16 | f.subsampling[1]
            else
                f.photometric orelse 0;
            self.note(.sampling_factors, segment, sof_host_offset, header.sof_type, f.sampling_entry, tiff_value, packComponent(i, comps[i]));
        }
    }

    fn note(self: *Accumulator, rule: Rule, segment: u32, sof: u64, sof_type: u4, entry: u64, tiff_value: u32, required: u32) void {
        const slot = &self.records[@intFromEnum(rule) - 1];
        if (slot.*) |*r| {
            r.violating += 1;
            return;
        }
        slot.* = .{
            .rule = rule,
            .first_segment = segment,
            .entry_offset = entry,
            .sof_offset = sof,
            .sof_type = sof_type,
            .tiff_value = tiff_value,
            .required = required,
            .violating = 1,
            .examined = 0,
        };
    }

    /// The record for `rule`, with the examined count as it stands now.
    pub fn record(self: *const Accumulator, rule: Rule) ?Record {
        var r = self.records[@intFromEnum(rule) - 1] orelse return null;
        r.examined = self.examined;
        return r;
    }
};

const ycbcr: u16 = 6;
/// T.81 Table B.1: SOF0 is baseline DCT, SOF3 lossless sequential Huffman.
const baseline_sof: u4 = 0;
const lossless_huffman_sof: u4 = 3;

fn packComponent(index: usize, c: jpegz.FrameComponent) u32 {
    return @as(u32, @intCast(index)) << 16 | @as(u32, c.h) << 8 | c.v;
}

/// The index of the first component whose factors break rule 4, or null.
/// YCbCr with three components: chroma 1 and 2 must agree, and luma must be
/// YCbCrSubSampling times chroma (index 2 is reported for a chroma
/// disagreement, index 0 for a luma ratio mismatch). Any other photometric,
/// or YCbCr with another component count: every component equals the first.
fn samplingMismatch(f: Fields, comps: []const jpegz.FrameComponent) ?usize {
    if (f.photometric == ycbcr and comps.len == 3) {
        const y = comps[0];
        const cb = comps[1];
        const cr = comps[2];
        if (cb.h != cr.h or cb.v != cr.v) return 2;
        if (@as(u32, y.h) != @as(u32, f.subsampling[0]) * cb.h or
            @as(u32, y.v) != @as(u32, f.subsampling[1]) * cb.v) return 0;
        return null;
    }
    for (comps[1..], 1..) |c, i| {
        if (c.h != comps[0].h or c.v != comps[0].v) return i;
    }
    return null;
}

/// Payload of finding 19, little-endian: u32 IFD index, u32 first violating
/// segment, u64 absolute TIFF entry offset, u64 absolute SOF offset, u16
/// rule, u16 SOF type, u32 TIFF value, u32 required value or component
/// (index << 16 | H << 8 | V), u32 violating segments, u32 examined segments.
pub const payload_len = 44;

pub fn encodePayload(r: Record, ifd_index: u32, buf: *[payload_len]u8) []const u8 {
    std.mem.writeInt(u32, buf[0..4], ifd_index, .little);
    std.mem.writeInt(u32, buf[4..8], r.first_segment, .little);
    std.mem.writeInt(u64, buf[8..16], r.entry_offset, .little);
    std.mem.writeInt(u64, buf[16..24], r.sof_offset, .little);
    std.mem.writeInt(u16, buf[24..26], @intFromEnum(r.rule), .little);
    std.mem.writeInt(u16, buf[26..28], r.sof_type, .little);
    std.mem.writeInt(u32, buf[28..32], r.tiff_value, .little);
    std.mem.writeInt(u32, buf[32..36], r.required, .little);
    std.mem.writeInt(u32, buf[36..40], r.violating, .little);
    std.mem.writeInt(u32, buf[40..44], r.examined, .little);
    return buf[0..payload_len];
}

// ---- tests ----

const testing = std.testing;

test "SOF classes are exactly DCT 0, 1, 2, 5, 6, 9, 10, 13, 14 and lossless 3, 7, 11, 15" {
    const dct = [_]u4{ 0, 1, 2, 5, 6, 9, 10, 13, 14 };
    const lossless = [_]u4{ 3, 7, 11, 15 };
    var n: u5 = 0;
    while (n < 16) : (n += 1) {
        const t: u4 = @intCast(n);
        const want: ?SofClass = if (std.mem.indexOfScalar(u4, &dct, t) != null)
            .dct
        else if (std.mem.indexOfScalar(u4, &lossless, t) != null)
            .lossless
        else
            null;
        try testing.expectEqual(want, sofClass(t));
    }
}

fn frameOf(sof_type: u4, factors: []const [2]u4) jpegz.FrameHeader {
    var h: jpegz.FrameHeader = .{
        .sof_offset = 2,
        .sof_type = sof_type,
        .kind = jpegz.frameKind(sof_type).?,
        .precision = 8,
        .height = 16,
        .width = 16,
        .component_count = @intCast(factors.len),
        .component_storage = undefined,
    };
    for (factors, 0..) |f, i| h.component_storage[i] = .{ .id = @intCast(i + 1), .h = f[0], .v = f[1], .tq = 0 };
    return h;
}

fn stripFields(rows: u32) Fields {
    return .{
        .tiled = false,
        .multi_strip = true,
        .rows_per_strip = rows,
        .tile_width = 0,
        .tile_length = 0,
        .planar = 1,
        .photometric = ycbcr,
        .subsampling = .{ 2, 2 },
        .rows_entry = 100,
        .tile_width_entry = 0,
        .tile_length_entry = 0,
        .sampling_entry = 200,
        .planar_entry = 300,
    };
}

test "rule 1: a multi-strip DCT image needs RowsPerStrip in whole MCU rows" {
    const h = frameOf(0, &.{ .{ 2, 2 }, .{ 1, 1 }, .{ 1, 1 } });
    var ok = Accumulator{ .fields = stripFields(32) };
    ok.add(0, 1000, &h);
    try testing.expectEqual(@as(?Record, null), ok.record(.rows));
    var bad = Accumulator{ .fields = stripFields(24) };
    bad.add(0, 1000, &h);
    bad.add(0, 1000, &h); // a retry of the same segment is not counted again
    bad.add(1, 2000, &h);
    const r = bad.record(.rows).?;
    try testing.expectEqual(Rule.rows, r.rule);
    try testing.expectEqual(@as(u32, 0), r.first_segment);
    try testing.expectEqual(@as(u64, 1000), r.sof_offset);
    try testing.expectEqual(@as(u32, 24), r.tiff_value);
    try testing.expectEqual(@as(u32, 16), r.required);
    try testing.expectEqual(@as(u32, 2), r.violating);
    try testing.expectEqual(@as(u32, 2), r.examined);
    // One strip per plane: no constraint.
    var single = Accumulator{ .fields = stripFields(24) };
    single.fields.multi_strip = false;
    single.add(0, 1000, &h);
    try testing.expectEqual(@as(?Record, null), single.record(.rows));
    // Lossless is exempt from rules 1 to 3.
    const lossless = frameOf(3, &.{ .{ 1, 1 }, .{ 1, 1 }, .{ 1, 1 } });
    var exempt = Accumulator{ .fields = stripFields(5) };
    exempt.fields.photometric = 2;
    exempt.add(0, 1000, &lossless);
    try testing.expectEqual(@as(?Record, null), exempt.record(.rows));
}

test "rules 2 and 3: tile sizes in whole MCUs" {
    const h = frameOf(1, &.{ .{ 2, 1 }, .{ 1, 1 }, .{ 1, 1 } }); // MCU 16x8
    var f = stripFields(0);
    f.tiled = true;
    f.multi_strip = false;
    f.subsampling = .{ 2, 1 };
    f.tile_width = 24;
    f.tile_length = 8;
    var acc = Accumulator{ .fields = f };
    acc.add(0, 10, &h);
    try testing.expectEqual(@as(u32, 16), acc.record(.tile_width).?.required);
    try testing.expectEqual(@as(?Record, null), acc.record(.tile_length));
    f.tile_width = 16;
    f.tile_length = 12;
    acc = .{ .fields = f };
    acc.add(0, 10, &h);
    try testing.expectEqual(@as(?Record, null), acc.record(.tile_width));
    try testing.expectEqual(@as(u32, 8), acc.record(.tile_length).?.required);
}

test "rule 4: YCbCr luma is YCbCrSubSampling times chroma, chroma agree; others are uniform" {
    const cases = [_]struct { photometric: u16, sub: [2]u16, factors: []const [2]u4, bad: ?usize }{
        .{ .photometric = ycbcr, .sub = .{ 2, 2 }, .factors = &.{ .{ 2, 2 }, .{ 1, 1 }, .{ 1, 1 } }, .bad = null },
        .{ .photometric = ycbcr, .sub = .{ 2, 1 }, .factors = &.{ .{ 2, 2 }, .{ 1, 1 }, .{ 1, 1 } }, .bad = 0 },
        .{ .photometric = ycbcr, .sub = .{ 2, 2 }, .factors = &.{ .{ 2, 2 }, .{ 1, 1 }, .{ 2, 1 } }, .bad = 2 },
        .{ .photometric = ycbcr, .sub = .{ 1, 1 }, .factors = &.{ .{ 2, 2 }, .{ 2, 2 }, .{ 2, 2 } }, .bad = null },
        // Asymmetric subsampling, so each axis is checked against its own
        // YCbCrSubSampling value (a controlled red that swapped them passed
        // the symmetric cases above).
        .{ .photometric = ycbcr, .sub = .{ 2, 1 }, .factors = &.{ .{ 2, 1 }, .{ 1, 1 }, .{ 1, 1 } }, .bad = null },
        .{ .photometric = ycbcr, .sub = .{ 1, 2 }, .factors = &.{ .{ 1, 2 }, .{ 1, 1 }, .{ 1, 1 } }, .bad = null },
        .{ .photometric = ycbcr, .sub = .{ 1, 2 }, .factors = &.{ .{ 2, 1 }, .{ 1, 1 }, .{ 1, 1 } }, .bad = 0 },
        .{ .photometric = 2, .sub = .{ 2, 2 }, .factors = &.{ .{ 1, 1 }, .{ 1, 1 }, .{ 1, 1 } }, .bad = null },
        .{ .photometric = 2, .sub = .{ 2, 2 }, .factors = &.{ .{ 2, 2 }, .{ 1, 1 }, .{ 1, 1 } }, .bad = 1 },
        .{ .photometric = 1, .sub = .{ 2, 2 }, .factors = &.{.{ 2, 2 }}, .bad = null },
    };
    for (cases) |c| {
        var f = stripFields(16);
        f.photometric = c.photometric;
        f.subsampling = c.sub;
        var acc = Accumulator{ .fields = f };
        const h = frameOf(0, c.factors);
        acc.add(0, 5, &h);
        if (c.bad) |i| {
            const r = acc.record(.sampling_factors).?;
            try testing.expectEqual(@as(u32, @intCast(i)), r.required >> 16);
            try testing.expectEqual(@as(u64, 200), r.entry_offset);
        } else try testing.expectEqual(@as(?Record, null), acc.record(.sampling_factors));
    }
}

test "rule 5: separate planes need factors of 1" {
    var f = stripFields(16);
    f.planar = 2;
    f.photometric = 2;
    var acc = Accumulator{ .fields = f };
    acc.add(0, 5, &frameOf(0, &.{.{ 1, 1 }}));
    try testing.expectEqual(@as(?Record, null), acc.record(.planar_factors));
    acc.add(1, 6, &frameOf(0, &.{.{ 2, 1 }}));
    const r = acc.record(.planar_factors).?;
    try testing.expectEqual(@as(u32, 1), r.first_segment);
    try testing.expectEqual(@as(u32, 0x0201), r.required);
    try testing.expectEqual(@as(u32, 2), r.examined);
}

test "rule 6: DNG requires baseline DCT or lossless Huffman JPEG, by photometric and depth" {
    const ycc = [_][2]u4{ .{ 2, 2 }, .{ 1, 1 }, .{ 1, 1 } };
    const cases = [_]struct { baseline: ?bool, sof: u4, required: ?u32 }{
        .{ .baseline = true, .sof = 0, .required = null },
        .{ .baseline = true, .sof = 1, .required = 0 },
        .{ .baseline = true, .sof = 3, .required = 0 },
        .{ .baseline = false, .sof = 3, .required = null },
        .{ .baseline = false, .sof = 0, .required = 3 },
        .{ .baseline = false, .sof = 7, .required = 3 },
        .{ .baseline = false, .sof = 11, .required = 3 },
        // Not a DNG of known version: no rule 6.
        .{ .baseline = null, .sof = 1, .required = null },
        .{ .baseline = null, .sof = 3, .required = null },
    };
    for (cases) |c| {
        var f = stripFields(16);
        f.dng_baseline = c.baseline;
        f.compression_entry = 400;
        var acc = Accumulator{ .fields = f };
        const factors: []const [2]u4 = if (sofClass(c.sof) == .lossless) &.{ .{ 1, 1 }, .{ 1, 1 }, .{ 1, 1 } } else &ycc;
        if (sofClass(c.sof) == .lossless) acc.fields.photometric = 2;
        acc.add(0, 7, &frameOf(c.sof, factors));
        acc.add(1, 8, &frameOf(c.sof, factors));
        if (c.required) |want| {
            const r = acc.record(.dng_variant).?;
            try testing.expectEqual(want, r.required);
            try testing.expectEqual(@as(u4, c.sof), r.sof_type);
            try testing.expectEqual(@as(u64, 400), r.entry_offset);
            try testing.expectEqual(@as(u32, acc.fields.photometric.?), r.tiff_value);
            try testing.expectEqual(@as(u32, 2), r.violating);
            try testing.expectEqual(@as(u32, 2), r.examined);
        } else try testing.expectEqual(@as(?Record, null), acc.record(.dng_variant));
    }
}

test "payload layout" {
    var buf: [payload_len]u8 = undefined;
    const p = encodePayload(.{
        .rule = .tile_length,
        .first_segment = 3,
        .entry_offset = 0x11,
        .sof_offset = 0x22,
        .sof_type = 1,
        .tiff_value = 12,
        .required = 8,
        .violating = 4,
        .examined = 9,
    }, 2, &buf);
    try testing.expectEqual(@as(usize, 44), p.len);
    try testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0, 3, 0, 0, 0 }, p[0..8]);
    try testing.expectEqual(@as(u64, 0x11), std.mem.readInt(u64, p[8..16], .little));
    try testing.expectEqual(@as(u64, 0x22), std.mem.readInt(u64, p[16..24], .little));
    try testing.expectEqualSlices(u8, &.{ 3, 0, 1, 0 }, p[24..28]);
    try testing.expectEqual(@as(u32, 12), std.mem.readInt(u32, p[28..32], .little));
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, p[32..36], .little));
    try testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, p[36..40], .little));
    try testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, p[40..44], .little));
}
