//! `tag_presence_invalid`: fields a claimed specification requires in an IFD,
//! or excludes from it (owner decisions 2 and 3, 2026-11-04; validate's
//! rulings, 2026-11-05; design in docs/plan_context/presence-findings.md).
//!
//! Scope: every walked image IFD, that is, the next chain and SubIFDs (option
//! A). The walk never visits the non-image IFDs (Exif, GPS, Interoperability,
//! MakerNote, DNG camera profiles). An IFD located only by
//! JPEGInterchangeFormat/Length, with no strip or tile field, is the Exif
//! compressed-thumbnail form: its presence check is deferred until an
//! interchange-format rule exists (ISO 12234-2, Exif), and `check` reports it
//! as deferred rather than passing it.
//!
//! Requirements, each citing its clause (TIFF 6.0, June 3, 1992):
//! 1. Baseline required fields without a default (the lists from p. 21 on):
//!    ImageWidth, ImageLength, PhotometricInterpretation, and StripOffsets
//!    and StripByteCounts in an untiled IFD. XResolution and YResolution are
//!    in the same lists ("No default", p. 41); their rows are held for the
//!    owner (`Options.resolution`).
//! 2. Tile replacement (p. 66): the tile fields "replace the StripOffsets,
//!    StripByteCounts, and RowsPerStrip fields". A tiled IFD needs
//!    TileOffsets and TileByteCounts, and a strip field beside tile fields is
//!    excluded.
//! 3. Tile dependency (pp. 67-68): TileWidth and TileLength have no default,
//!    so any tile field requires both.
//!
//! An IFD is tiled when it has any tile field. The related tag of a tile
//! record is the first tile field present in tag order (validate).
//!
//! Pure: reads only the parsed `Ifd`'s entry tags.

const std = @import("std");
const parser = @import("tiffz-parser");
const ifd_mod = parser.ifd;
const tags = parser.tags;

const Ifd = ifd_mod.Ifd;

/// Wire values for the payload.
pub const Reason = enum(u16) {
    /// A field the requirement needs is absent. Anchored on the IFD.
    required_absent = 1,
    /// A field the requirement excludes is present. Anchored on that entry.
    excluded_present = 2,
    /// An entry requires a field that is absent. Anchored on that entry.
    dependency_absent = 3,
};

/// The clause a record enforces. Exhaustive: each value cites its text, and a
/// later batch adds a value with its own corpus report.
pub const Requirement = enum(u16) {
    tiff6_baseline_required = 1,
    tiff6_tile_replacement = 2,
    tiff6_tile_dependency = 3,
};

pub const Record = struct {
    /// The absent tag (reasons 1 and 3) or the present one (reason 2).
    tag: u16,
    reason: Reason,
    requirement: Requirement,
    /// The present tag that creates the dependency (reason 3), or the
    /// conflicting tag (reason 2); 0 when none.
    related: u16 = 0,
    /// The anchoring entry; null when the record is anchored on the IFD.
    entry_index: ?u32,
};

pub const Options = struct {
    /// The XResolution and YResolution rows, held until the owner signs off
    /// (validate, 2026-11-05). The decoder passes false.
    resolution: bool,
};

/// More than any one IFD can produce: 7 baseline rows, 2 tile arrays, 3
/// excluded strip fields and 2 tile dimensions.
pub const max_records = 14;

pub const Result = struct {
    /// True when the IFD is located only by JPEGInterchangeFormat, so its
    /// presence check was not run. `records` is then empty.
    deferred: bool = false,
    len: usize = 0,
    records: [max_records]Record = undefined,

    pub fn items(self: *const Result) []const Record {
        return self.records[0..self.len];
    }

    fn add(self: *Result, record: Record) void {
        self.records[self.len] = record;
        self.len += 1;
    }
};

const tile_fields = [_]u16{ tags.tile_width, tags.tile_length, tags.tile_offsets, tags.tile_byte_counts };
const strip_fields = [_]u16{ tags.strip_offsets, tags.rows_per_strip, tags.strip_byte_counts };

pub fn check(dir: *const Ifd, opts: Options) Result {
    var result: Result = .{};
    var any_tile = false;
    for (tile_fields) |t| any_tile = any_tile or has(dir, t);
    const any_strip_array = has(dir, tags.strip_offsets) or has(dir, tags.strip_byte_counts);
    if (!any_tile and !any_strip_array and
        (has(dir, tags.jpeg_interchange_format) or has(dir, tags.jpeg_interchange_format_length)))
    {
        result.deferred = true;
        return result;
    }

    // Records in tag order within each requirement.
    for ([_]u16{ tags.image_width, tags.image_length, tags.photometric }) |t| {
        if (!has(dir, t)) result.add(.{ .tag = t, .reason = .required_absent, .requirement = .tiff6_baseline_required, .entry_index = null });
    }
    if (opts.resolution) {
        for ([_]u16{ tags.x_resolution, tags.y_resolution }) |t| {
            if (!has(dir, t)) result.add(.{ .tag = t, .reason = .required_absent, .requirement = .tiff6_baseline_required, .entry_index = null });
        }
    }
    if (!any_tile) {
        for ([_]u16{ tags.strip_offsets, tags.strip_byte_counts }) |t| {
            if (!has(dir, t)) result.add(.{ .tag = t, .reason = .required_absent, .requirement = .tiff6_baseline_required, .entry_index = null });
        }
        return result;
    }

    // The first tile field present, in tag order (`tile_fields` is sorted).
    var first_tile: u16 = 0;
    for (tile_fields) |t| if (has(dir, t)) {
        first_tile = t;
        break;
    };
    for ([_]u16{ tags.tile_offsets, tags.tile_byte_counts }) |t| {
        if (!has(dir, t)) result.add(.{ .tag = t, .reason = .required_absent, .requirement = .tiff6_tile_replacement, .entry_index = null });
    }
    for (strip_fields) |t| {
        if (indexOf(dir, t)) |i| result.add(.{ .tag = t, .reason = .excluded_present, .requirement = .tiff6_tile_replacement, .related = first_tile, .entry_index = i });
    }
    for ([_]u16{ tags.tile_width, tags.tile_length }) |t| {
        if (has(dir, t)) continue;
        // The dependency comes from the first other tile field present.
        var dep: ?u16 = null;
        for (tile_fields) |o| if (o != t and has(dir, o)) {
            dep = o;
            break;
        };
        const d = dep orelse continue;
        result.add(.{ .tag = t, .reason = .dependency_absent, .requirement = .tiff6_tile_dependency, .related = d, .entry_index = indexOf(dir, d) });
    }
    return result;
}

fn indexOf(dir: *const Ifd, tag: u16) ?u32 {
    for (dir.entries, 0..) |entry, i| {
        if (entry.tag == tag) return @intCast(i);
    }
    return null;
}

fn has(dir: *const Ifd, tag: u16) bool {
    return indexOf(dir, tag) != null;
}

/// Payload, little-endian, 24 bytes: u32 IFD index, u32 entry index
/// (`0xFFFFFFFF` when anchored on the IFD), u64 absolute anchor offset (the
/// IFD's or the entry's), u16 tag, u16 reason, u16 requirement, u16 related
/// tag (0 when none).
pub const payload_len = 24;
pub const ifd_anchor: u32 = 0xFFFF_FFFF;

pub fn encodePayload(r: Record, ifd_index: u32, anchor_offset: u64, buf: *[payload_len]u8) []const u8 {
    std.mem.writeInt(u32, buf[0..4], ifd_index, .little);
    std.mem.writeInt(u32, buf[4..8], r.entry_index orelse ifd_anchor, .little);
    std.mem.writeInt(u64, buf[8..16], anchor_offset, .little);
    std.mem.writeInt(u16, buf[16..18], r.tag, .little);
    std.mem.writeInt(u16, buf[18..20], @intFromEnum(r.reason), .little);
    std.mem.writeInt(u16, buf[20..22], @intFromEnum(r.requirement), .little);
    std.mem.writeInt(u16, buf[22..24], r.related, .little);
    return buf[0..payload_len];
}

// ---- tests ----

const testing = std.testing;
const Entry = ifd_mod.Entry;

fn testEntry(tag: u16) Entry {
    return .{ .tag = tag, .field_type = .short, .raw_type = 3, .count = 1, .raw_value_or_offset = [_]u8{0} ** 8 };
}

/// The records for an IFD holding exactly `present` (sorted tags).
fn run(comptime present: []const u16, opts: Options) Result {
    var entries: [present.len]Entry = undefined;
    for (present, 0..) |t, i| entries[i] = testEntry(t);
    var cached = [_]?[]u8{null} ** present.len;
    const dir = Ifd{ .entries = &entries, .next_offset = 0, .offset_width = .classic, .allocator = testing.allocator, .cached_values = &cached };
    return check(&dir, opts);
}

const Want = struct { tag: u16, reason: Reason, requirement: Requirement, related: u16 = 0, entry_index: ?u32 = null };

fn expectRecords(result: Result, want: []const Want) !void {
    try testing.expect(!result.deferred);
    if (result.len != want.len) {
        std.debug.print("got {any}\n", .{result.items()});
        return error.TestExpectedEqual;
    }
    for (result.items(), want) |got, w| {
        try testing.expectEqual(w.tag, got.tag);
        try testing.expectEqual(w.reason, got.reason);
        try testing.expectEqual(w.requirement, got.requirement);
        try testing.expectEqual(w.related, got.related);
        try testing.expectEqual(w.entry_index, got.entry_index);
    }
}

const full_strips = [_]u16{ 256, 257, 262, 273, 279, 282, 283 };

test "a complete strip IFD has no records" {
    try expectRecords(run(&full_strips, .{ .resolution = true }), &.{});
    // RowsPerStrip and the other defaulted fields are not required.
    try expectRecords(run(&.{ 256, 257, 262, 273, 279 }, .{ .resolution = false }), &.{});
}

test "requirement 1: each baseline field without a default, anchored on the IFD" {
    try expectRecords(run(&.{ 256, 257, 273, 279 }, .{ .resolution = false }), &.{
        .{ .tag = 262, .reason = .required_absent, .requirement = .tiff6_baseline_required },
    });
    // No image fields at all (a container IFD): every row, strips included.
    try expectRecords(run(&.{330}, .{ .resolution = false }), &.{
        .{ .tag = 256, .reason = .required_absent, .requirement = .tiff6_baseline_required },
        .{ .tag = 257, .reason = .required_absent, .requirement = .tiff6_baseline_required },
        .{ .tag = 262, .reason = .required_absent, .requirement = .tiff6_baseline_required },
        .{ .tag = 273, .reason = .required_absent, .requirement = .tiff6_baseline_required },
        .{ .tag = 279, .reason = .required_absent, .requirement = .tiff6_baseline_required },
    });
    // Half a strip pair.
    try expectRecords(run(&.{ 256, 257, 262, 273 }, .{ .resolution = false }), &.{
        .{ .tag = 279, .reason = .required_absent, .requirement = .tiff6_baseline_required },
    });
}

test "the held X/YResolution rows apply only when enabled" {
    const no_res = [_]u16{ 256, 257, 262, 273, 279 };
    try expectRecords(run(&no_res, .{ .resolution = false }), &.{});
    try expectRecords(run(&no_res, .{ .resolution = true }), &.{
        .{ .tag = 282, .reason = .required_absent, .requirement = .tiff6_baseline_required },
        .{ .tag = 283, .reason = .required_absent, .requirement = .tiff6_baseline_required },
    });
}

test "requirements 2 and 3: tiles replace strips and need both dimensions" {
    // A complete tiled IFD.
    try expectRecords(run(&.{ 256, 257, 262, 322, 323, 324, 325 }, .{ .resolution = false }), &.{});
    // Tiles stored in strip tags (libtiff quad-tile shape): the tile arrays
    // are required and the strip fields excluded, related to TileWidth.
    try expectRecords(run(&.{ 256, 257, 262, 273, 278, 279, 322, 323 }, .{ .resolution = false }), &.{
        .{ .tag = 324, .reason = .required_absent, .requirement = .tiff6_tile_replacement },
        .{ .tag = 325, .reason = .required_absent, .requirement = .tiff6_tile_replacement },
        .{ .tag = 273, .reason = .excluded_present, .requirement = .tiff6_tile_replacement, .related = 322, .entry_index = 3 },
        .{ .tag = 278, .reason = .excluded_present, .requirement = .tiff6_tile_replacement, .related = 322, .entry_index = 4 },
        .{ .tag = 279, .reason = .excluded_present, .requirement = .tiff6_tile_replacement, .related = 322, .entry_index = 5 },
    });
    // Tile arrays without TileWidth: a dependency on the first other tile
    // field present, anchored on it.
    try expectRecords(run(&.{ 256, 257, 262, 323, 324, 325 }, .{ .resolution = false }), &.{
        .{ .tag = 322, .reason = .dependency_absent, .requirement = .tiff6_tile_dependency, .related = 323, .entry_index = 3 },
    });
    try expectRecords(run(&.{ 256, 257, 262, 324, 325 }, .{ .resolution = false }), &.{
        .{ .tag = 322, .reason = .dependency_absent, .requirement = .tiff6_tile_dependency, .related = 324, .entry_index = 3 },
        .{ .tag = 323, .reason = .dependency_absent, .requirement = .tiff6_tile_dependency, .related = 324, .entry_index = 3 },
    });
}

test "an IFD located only by JPEGInterchangeFormat is deferred, not passed" {
    const r = run(&.{ 259, 513, 514 }, .{ .resolution = true });
    try testing.expect(r.deferred);
    try testing.expectEqual(@as(usize, 0), r.len);
    try testing.expect(run(&.{513}, .{ .resolution = false }).deferred);
    // A strip-located Compression 6 IFD (the Canon CR2 IFD0 shape) is checked.
    const canon = run(&.{ 256, 257, 259, 273, 279, 513, 514 }, .{ .resolution = false });
    try testing.expect(!canon.deferred);
    try expectRecords(canon, &.{.{ .tag = 262, .reason = .required_absent, .requirement = .tiff6_baseline_required }});
}

test "payload layout" {
    var buf: [payload_len]u8 = undefined;
    const p = encodePayload(.{ .tag = 278, .reason = .excluded_present, .requirement = .tiff6_tile_replacement, .related = 322, .entry_index = 4 }, 2, 0x1234, &buf);
    try testing.expectEqual(@as(usize, 24), p.len);
    try testing.expectEqualSlices(u8, &.{ 2, 0, 0, 0, 4, 0, 0, 0 }, p[0..8]);
    try testing.expectEqual(@as(u64, 0x1234), std.mem.readInt(u64, p[8..16], .little));
    try testing.expectEqualSlices(u8, &.{ 0x16, 0x01, 2, 0, 2, 0, 0x42, 0x01 }, p[16..24]);
    const q = encodePayload(.{ .tag = 262, .reason = .required_absent, .requirement = .tiff6_baseline_required, .entry_index = null }, 0, 8, &buf);
    try testing.expectEqual(ifd_anchor, std.mem.readInt(u32, q[4..8], .little));
}
