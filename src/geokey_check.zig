//! GeoTIFF Tier 2 (which model tags an IFD must or must not carry together)
//! and Tier 3 (the structure of the GeoKeyDirectory and the parameter tags
//! it points into), cited to OGC GeoTIFF 1.1 (19-008r4). Each rule reports
//! under one of two findings by its class (`Rule.class`): `geokey_invalid`
//! (InfoFinding 21, corrupt) or `geokey_deviation` (InfoFinding 24, a
//! warning). Design and corpus report: docs/plan_context/geokey-invalid.md.
//!
//! Scope: every walked IFD. Tier 1 (the six tags' types and counts) stays in
//! `ifd_conformance` as finding 18. A GeoKeyDirectory that Tier 1 rejects
//! for its type or for fewer than four values gets no Tier 3 walk; the
//! Tier 1 record already describes it. Key values (GTModelTypeGeoKey
//! presence, CRS keys, Requirement 6.2) belong to a later key-value batch.
//!
//! Model tags without a GeoKeyDirectory are not a violation (validate,
//! 2026-11-04, Q1b), so rule 1 runs only where a GeoKeyDirectory is present.
//! Rules 2 and 3 are about the model tags themselves and run in any IFD.
//!
//! Pure: reads only the parsed `Ifd` (entries and eagerly cached values).

const std = @import("std");
const parser = @import("tiffz-parser");
const ifd_mod = parser.ifd;
const header_mod = parser.header;
const tags = parser.tags;

const Ifd = ifd_mod.Ifd;
const Endian = header_mod.Endian;

/// Wire values for the payload. Exhaustive: each value cites its
/// requirement; a new value is registered with validate by note.
pub const Rule = enum(u16) {
    // Tier 2, Requirement 1.2 (DataGeoTags), the conditional tags.
    /// A GeoKeyDirectory, but neither ModelTiepoint nor ModelTransformation
    /// ("One of ModelTiepointTag or ModelTransformationTag SHALL be
    /// included"). Anchored on the GeoKeyDirectory entry.
    georeference_absent = 1,
    /// ModelPixelScale beside ModelTransformation ("a ModelPixelScaleTag
    /// SHALL NOT be included"). Anchored on ModelPixelScale; related 34264.
    pixel_scale_with_transformation = 2,
    /// ModelPixelScale without ModelTiepoint ("a ModelTiepointTag SHALL also
    /// be included"). Anchored on ModelPixelScale; related 33922.
    pixel_scale_without_tiepoint = 3,

    // Tier 3, the GeoKeyDirectory header (Requirements 2.5, 2.7, 2.9).
    /// KeyDirectoryVersion is not 1. Element 0, observed the value.
    key_directory_version = 10,
    /// KeyRevision is not 1. Element 1, observed the value.
    key_revision = 11,
    /// MinorRevision is neither 0 nor 1. Element 2, observed the value.
    minor_revision = 12,
    /// Fewer than NumberOfKeys complete key entries (Requirement 2.11).
    /// Element 3, observed NumberOfKeys. Only the complete entries present
    /// are walked.
    key_entries_truncated = 13,

    // Tier 3, the key entries.
    /// A KeyID below the one before it (Requirement 1.6). Element: the
    /// entry's KeyID; observed the KeyID.
    key_unsorted = 14,
    /// A KeyID equal to the one before it (Requirement 1.6, ascending).
    key_duplicate = 15,
    /// TIFFTagLocation is neither 0 nor a GeoTIFF parameter tag (34735,
    /// 34736, 34737) (Requirement 2.14). Observed the location.
    tag_location_invalid = 16,
    /// TIFFTagLocation names 34736 or 34737 and the IFD lacks that tag
    /// (Requirement 2.16, an index into that tag). Related the location.
    location_tag_absent = 17,
    /// ValueOffset + Count runs past the named tag's values (Requirement
    /// 2.16). Observed ValueOffset + Count; related the location.
    value_out_of_bounds = 18,
    /// TIFFTagLocation 34735 with a ValueOffset inside the header or key
    /// entries (Requirement 4.2, "after the last Key Entry"). Observed the
    /// ValueOffset.
    short_params_inside_entries = 19,

    // Tier 3, GeoAsciiParams (Requirements 6.3, 6.4).
    /// An ASCII key's last character is not the pipe terminator
    /// (Requirement 6.3). Tag 34737; element the index of that byte;
    /// observed the byte.
    ascii_terminator_missing = 20,
    /// A NUL inside the string content of GeoAsciiParams, before its final
    /// byte (Requirement 6.4). Tag 34737; element the first such byte; no
    /// key.
    ascii_nul_inside = 21,

    /// The finding a rule reports under (validate, 2026-11-07). Corrupt:
    /// an edition, location or reference with no specified decode, missing
    /// entries, a duplicate KeyID, or parameters overlapping the entries.
    /// Deviation: a writer violation where every key still decodes.
    pub fn class(rule: Rule) Class {
        return switch (rule) {
            .key_directory_version,
            .key_revision,
            .minor_revision,
            .key_entries_truncated,
            .key_duplicate,
            .tag_location_invalid,
            .location_tag_absent,
            .value_out_of_bounds,
            .short_params_inside_entries,
            => .invalid,
            .georeference_absent,
            .pixel_scale_with_transformation,
            .pixel_scale_without_tiepoint,
            .key_unsorted,
            .ascii_terminator_missing,
            .ascii_nul_inside,
            => .deviation,
        };
    }
};

/// Which finding a rule reports under. Rule numbers keep their values in
/// both, and both use the same payload.
pub const Class = enum {
    /// InfoFinding 21 `geokey_invalid`, verdict corrupt.
    invalid,
    /// InfoFinding 24 `geokey_deviation`, verdict valid with a warning.
    deviation,
};

pub const Record = struct {
    /// The tag the record is about: 34735 for header and key records, 34737
    /// for rules 20 and 21, 34735 or 33550 for Tier 2.
    tag: u16,
    rule: Rule,
    /// The anchoring entry (the `tag`'s entry); null when anchored on the IFD.
    entry_index: ?u32,
    /// The key entry, counted from 0 after the header; null when none.
    key_index: ?u16 = null,
    /// That key's KeyID (0 when `key_index` is null).
    key_id: u16 = 0,
    /// Index into `tag`'s value array of the offending value, in its natural
    /// unit (a SHORT for 34735, a byte for 34737); null when none.
    element: ?u32 = null,
    /// The offending value as read; 0 when none.
    observed: u32 = 0,
    /// The other tag involved; 0 when none.
    related: u16 = 0,
};

/// Payload, little-endian, 36 bytes: u32 IFD index, u32 entry index
/// (`0xFFFFFFFF` on the IFD), u64 absolute anchor offset (the entry's), u16
/// tag, u16 rule, u16 key index (`0xFFFF` when none), u16 KeyID (0 when
/// none), u32 element (`0xFFFFFFFF` when none), u32 observed, u16 related tag
/// (0 when none), u16 reserved (0).
pub const payload_len = 36;
pub const none_u32: u32 = 0xFFFF_FFFF;
pub const none_u16: u16 = 0xFFFF;

pub fn encodePayload(r: Record, ifd_index: u32, anchor_offset: u64, buf: *[payload_len]u8) []const u8 {
    std.mem.writeInt(u32, buf[0..4], ifd_index, .little);
    std.mem.writeInt(u32, buf[4..8], r.entry_index orelse none_u32, .little);
    std.mem.writeInt(u64, buf[8..16], anchor_offset, .little);
    std.mem.writeInt(u16, buf[16..18], r.tag, .little);
    std.mem.writeInt(u16, buf[18..20], @intFromEnum(r.rule), .little);
    std.mem.writeInt(u16, buf[20..22], r.key_index orelse none_u16, .little);
    std.mem.writeInt(u16, buf[22..24], r.key_id, .little);
    std.mem.writeInt(u32, buf[24..28], r.element orelse none_u32, .little);
    std.mem.writeInt(u32, buf[28..32], r.observed, .little);
    std.mem.writeInt(u16, buf[32..34], r.related, .little);
    std.mem.writeInt(u16, buf[34..36], 0, .little);
    return buf[0..payload_len];
}

/// Append every record for one IFD to `out`, Tier 2 first, then the header,
/// the key entries in order, and GeoAsciiParams.
pub fn check(allocator: std.mem.Allocator, dir: *const Ifd, endian: Endian, out: *std.ArrayListUnmanaged(Record)) error{OutOfMemory}!void {
    const gkd = indexOf(dir, tags.geo_key_directory);
    const tiepoint = indexOf(dir, tags.model_tiepoint);
    const transformation = indexOf(dir, tags.model_transformation);
    const scale = indexOf(dir, tags.model_pixel_scale);

    // Tier 2.
    if (gkd) |g| if (tiepoint == null and transformation == null) {
        try out.append(allocator, .{ .tag = tags.geo_key_directory, .rule = .georeference_absent, .entry_index = g });
    };
    if (scale) |s| {
        if (transformation != null)
            try out.append(allocator, .{ .tag = tags.model_pixel_scale, .rule = .pixel_scale_with_transformation, .entry_index = s, .related = tags.model_transformation });
        if (tiepoint == null)
            try out.append(allocator, .{ .tag = tags.model_pixel_scale, .rule = .pixel_scale_without_tiepoint, .entry_index = s, .related = tags.model_tiepoint });
    }

    // Tier 3.
    const g = gkd orelse return;
    const dir_values = UnsignedArray.of(dir, g, endian) orelse return;
    if (dir_values.len < 4) return;
    const gkd_rec = Record{ .tag = tags.geo_key_directory, .rule = .key_directory_version, .entry_index = g };

    const header = [3]struct { rule: Rule, ok: []const u32 }{
        .{ .rule = .key_directory_version, .ok = &.{1} },
        .{ .rule = .key_revision, .ok = &.{1} },
        .{ .rule = .minor_revision, .ok = &.{ 0, 1 } },
    };
    for (header, 0..) |h, i| {
        const v = dir_values.at(i);
        if (std.mem.indexOfScalar(u32, h.ok, v) == null) {
            var r = gkd_rec;
            r.rule = h.rule;
            r.element = @intCast(i);
            r.observed = v;
            try out.append(allocator, r);
        }
    }

    const declared = dir_values.at(3);
    const present: u64 = (dir_values.len - 4) / 4;
    if (present < declared) {
        var r = gkd_rec;
        r.rule = .key_entries_truncated;
        r.element = 3;
        r.observed = declared;
        try out.append(allocator, r);
    }
    const walk: usize = @intCast(@min(present, declared));
    const entries_end: u64 = 4 + 4 * @as(u64, declared);

    const doubles = indexOf(dir, tags.geo_double_params);
    const ascii = indexOf(dir, tags.geo_ascii_params);
    const ascii_bytes: []const u8 = if (ascii) |a| (if (dir.entries[a].field_type == .ascii) dir.entryValueSlice(a) else &.{}) else &.{};

    var prev_id: ?u32 = null;
    for (0..walk) |k| {
        const base = 4 + 4 * k;
        const id = dir_values.at(base);
        const location = dir_values.at(base + 1);
        const count = dir_values.at(base + 2);
        const offset = dir_values.at(base + 3);
        var key = gkd_rec;
        key.key_index = @intCast(k);
        key.key_id = @truncate(id);

        if (prev_id) |p| if (id <= p) {
            var r = key;
            r.rule = if (id == p) .key_duplicate else .key_unsorted;
            r.element = @intCast(base);
            r.observed = id;
            try out.append(allocator, r);
        };
        prev_id = id;

        if (location == 0) continue;
        if (location != tags.geo_key_directory and location != tags.geo_double_params and location != tags.geo_ascii_params) {
            var r = key;
            r.rule = .tag_location_invalid;
            r.element = @intCast(base + 1);
            r.observed = location;
            try out.append(allocator, r);
            continue;
        }
        const target: ?u32 = if (location == tags.geo_key_directory) g else if (location == tags.geo_double_params) doubles else ascii;
        const t = target orelse {
            var r = key;
            r.rule = .location_tag_absent;
            r.element = @intCast(base + 1);
            r.observed = location;
            r.related = @intCast(location);
            try out.append(allocator, r);
            continue;
        };
        const end = @as(u64, offset) + count;
        if (end > dir.entries[t].count) {
            var r = key;
            r.rule = .value_out_of_bounds;
            r.element = @intCast(base + 3);
            r.observed = @intCast(@min(end, std.math.maxInt(u32)));
            r.related = @intCast(location);
            try out.append(allocator, r);
            continue;
        }
        if (location == tags.geo_key_directory and offset < entries_end) {
            var r = key;
            r.rule = .short_params_inside_entries;
            r.element = @intCast(base + 3);
            r.observed = offset;
            try out.append(allocator, r);
        }
        if (location == tags.geo_ascii_params and count > 0 and end <= ascii_bytes.len) {
            const last = ascii_bytes[@intCast(end - 1)];
            if (last != '|') {
                try out.append(allocator, .{
                    .tag = tags.geo_ascii_params,
                    .rule = .ascii_terminator_missing,
                    .entry_index = ascii,
                    .key_index = @intCast(k),
                    .key_id = @truncate(id),
                    .element = @intCast(end - 1),
                    .observed = last,
                });
            }
        }
    }

    // Requirement 6.4: no NUL in the content, which is everything before
    // the final byte (TIFF's own terminator).
    if (ascii_bytes.len > 1) {
        if (std.mem.indexOfScalar(u8, ascii_bytes[0 .. ascii_bytes.len - 1], 0)) |i| {
            try out.append(allocator, .{ .tag = tags.geo_ascii_params, .rule = .ascii_nul_inside, .entry_index = ascii, .element = @intCast(i) });
        }
    }
}

/// An unsigned integer array (BYTE, SHORT or LONG, the kinds Tier 1 lets a
/// SHORT array hold) read from the eager cache.
const UnsignedArray = struct {
    bytes: []const u8,
    width: u8,
    len: u64,
    endian: Endian,

    fn of(dir: *const Ifd, index: u32, endian: Endian) ?UnsignedArray {
        const entry = dir.entries[index];
        const width: u8 = switch (entry.field_type) {
            .byte => 1,
            .short => 2,
            .long => 4,
            else => return null,
        };
        const bytes = dir.entryValueSlice(index);
        // A value the cache does not fully hold is an extent fault (23); walk
        // only what is there.
        return .{ .bytes = bytes, .width = width, .len = @min(entry.count, bytes.len / width), .endian = endian };
    }

    fn at(self: UnsignedArray, i: u64) u32 {
        const off: usize = @intCast(i * self.width);
        return switch (self.width) {
            1 => self.bytes[off],
            2 => header_mod.readU16(self.bytes[off..][0..2], self.endian),
            else => header_mod.readU32(self.bytes[off..][0..4], self.endian),
        };
    }
};

fn indexOf(dir: *const Ifd, tag: u16) ?u32 {
    for (dir.entries, 0..) |entry, i| {
        if (entry.tag == tag) return @intCast(i);
    }
    return null;
}

// ---- tests ----

const testing = std.testing;
const Entry = ifd_mod.Entry;

/// A little-endian IFD from (tag, type, count, bytes) rows, every value held
/// in the cache.
const Row = struct { tag: u16, ft: ifd_mod.FieldType, count: u64, bytes: []const u8 = &.{} };

fn runRows(rows: []const Row) !std.ArrayListUnmanaged(Record) {
    var entries: [16]Entry = undefined;
    var cached: [16]?[]u8 = undefined;
    for (rows, 0..) |row, i| {
        entries[i] = .{ .tag = row.tag, .field_type = row.ft, .raw_type = 0, .count = row.count, .raw_value_or_offset = [_]u8{0} ** 8 };
        cached[i] = @constCast(row.bytes);
    }
    const dir = Ifd{ .entries = entries[0..rows.len], .next_offset = 0, .offset_width = .classic, .allocator = testing.allocator, .cached_values = cached[0..rows.len] };
    var out: std.ArrayListUnmanaged(Record) = .empty;
    try check(testing.allocator, &dir, .little, &out);
    return out;
}

fn shorts(comptime values: []const u16) [values.len * 2]u8 {
    var b: [values.len * 2]u8 = undefined;
    for (values, 0..) |v, i| std.mem.writeInt(u16, b[i * 2 ..][0..2], v, .little);
    return b;
}

fn gkdRow(comptime values: []const u16) Row {
    const b = comptime shorts(values);
    return .{ .tag = tags.geo_key_directory, .ft = .short, .count = values.len, .bytes = &b };
}

const t_tie = Row{ .tag = tags.model_tiepoint, .ft = .double, .count = 6 };
const t_scale = Row{ .tag = tags.model_pixel_scale, .ft = .double, .count = 3 };
const t_xform = Row{ .tag = tags.model_transformation, .ft = .double, .count = 16 };

fn expectRules(rows: []const Row, want: []const Rule) !void {
    var out = try runRows(rows);
    defer out.deinit(testing.allocator);
    var got: [32]Rule = undefined;
    for (out.items, 0..) |r, i| got[i] = r.rule;
    try testing.expectEqualSlices(Rule, want, got[0..out.items.len]);
}

// A well-formed directory: version 1.1.1, keys 1024, 1025 inline, 2049 in
// GeoAsciiParams ("WGS 84|"), 2057 in GeoDoubleParams, 3072 inline.
const good_ascii = "WGS 84|\x00";
const good_gkd = gkdRow(&.{ 1, 1, 1, 5, 1024, 0, 1, 2, 1025, 0, 1, 1, 2049, 34737, 7, 0, 2057, 34736, 1, 0, 3072, 0, 1, 4326 });
const good_doubles = Row{ .tag = tags.geo_double_params, .ft = .double, .count = 1 };
const good_ascii_row = Row{ .tag = tags.geo_ascii_params, .ft = .ascii, .count = good_ascii.len, .bytes = good_ascii };

test "geokey: a well-formed GeoTIFF directory has no record" {
    try expectRules(&.{ t_scale, t_tie, good_gkd, good_doubles, good_ascii_row }, &.{});
    try expectRules(&.{ t_xform, good_gkd, good_doubles, good_ascii_row }, &.{});
    // Model tags alone, with no GeoKeyDirectory, are not a violation (Q1b).
    try expectRules(&.{ t_scale, t_tie }, &.{});
    // MinorRevision 0 (GeoTIFF 1.0) is accepted.
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 0 }) }, &.{});
}

test "geokey rules 1-3: the conditional model tags (Requirement 1.2)" {
    try expectRules(&.{gkdRow(&.{ 1, 1, 1, 0 })}, &.{.georeference_absent});
    try expectRules(&.{ t_scale, t_tie, t_xform }, &.{.pixel_scale_with_transformation});
    try expectRules(&.{t_scale}, &.{.pixel_scale_without_tiepoint});
    try expectRules(&.{ t_scale, t_xform, gkdRow(&.{ 1, 1, 1, 0 }) }, &.{ .pixel_scale_with_transformation, .pixel_scale_without_tiepoint });
    var out = try runRows(&.{ t_scale, t_xform });
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 0), out.items[0].entry_index);
    try testing.expectEqual(tags.model_transformation, out.items[0].related);
    try testing.expectEqual(tags.model_tiepoint, out.items[1].related);
}

test "geokey rules 10-13: the header (Requirements 2.5, 2.7, 2.9, 2.11)" {
    try expectRules(&.{ t_tie, gkdRow(&.{ 2, 1, 1, 0 }) }, &.{.key_directory_version});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 0, 1, 0 }) }, &.{.key_revision});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 2, 0 }) }, &.{.minor_revision});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1024, 0, 1, 1 }) }, &.{.key_entries_truncated});
    var out = try runRows(&.{ t_tie, gkdRow(&.{ 1, 1, 7, 3, 1024, 0, 1, 1 }) });
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(?u32, 2), out.items[0].element);
    try testing.expectEqual(@as(u32, 7), out.items[0].observed);
    try testing.expectEqual(@as(?u32, 3), out.items[1].element);
    try testing.expectEqual(@as(u32, 3), out.items[1].observed);
    // Fewer than four values is Tier 1's count fault: no Tier 3 walk.
    try expectRules(&.{ t_tie, gkdRow(&.{ 2, 0, 9 }) }, &.{});
    // A non-integer type is Tier 1's type fault: no Tier 3 walk.
    try expectRules(&.{ t_tie, .{ .tag = tags.geo_key_directory, .ft = .ascii, .count = 8, .bytes = "12345678" } }, &.{});
}

test "geokey rules 14 and 15: KeyIDs ascending (Requirement 1.6)" {
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 3, 1025, 0, 1, 1, 1024, 0, 1, 1, 3072, 0, 1, 1 }) }, &.{.key_unsorted});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1024, 0, 1, 1, 1024, 0, 1, 1 }) }, &.{.key_duplicate});
    var out = try runRows(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1025, 0, 1, 1, 1024, 0, 1, 1 }) });
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(?u16, 1), out.items[0].key_index);
    try testing.expectEqual(@as(u16, 1024), out.items[0].key_id);
    try testing.expectEqual(@as(?u32, 8), out.items[0].element);
}

test "geokey rules 16-19: TIFFTagLocation, Count and ValueOffset (Requirements 2.14, 2.16, 4.2)" {
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 1024, 33550, 1, 0 }) }, &.{.tag_location_invalid});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 2057, 34736, 1, 0 }) }, &.{.location_tag_absent});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 2049, 34737, 4, 0 }) }, &.{.location_tag_absent});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 2057, 34736, 2, 0 }), good_doubles }, &.{.value_out_of_bounds});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 2049, 34737, 9, 0 }), good_ascii_row }, &.{.value_out_of_bounds});
    // Short parameters after the last key entry are fine (Requirement 4.2);
    // inside the entries they are not; past the end they are out of bounds.
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 3073, 34735, 2, 8, 7, 9 }) }, &.{});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 3073, 34735, 2, 4, 7, 9 }) }, &.{.short_params_inside_entries});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 3073, 34735, 3, 8, 7, 9 }) }, &.{.value_out_of_bounds});
    var out = try runRows(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 2057, 34736, 2, 0 }), good_doubles });
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), out.items[0].observed);
    try testing.expectEqual(tags.geo_double_params, out.items[0].related);
}

test "geokey rules 20 and 21: GeoAsciiParams terminators (Requirements 6.3, 6.4)" {
    const no_pipe = "WGS 84.\x00";
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 2049, 34737, 7, 0 }), .{ .tag = tags.geo_ascii_params, .ft = .ascii, .count = 8, .bytes = no_pipe } }, &.{.ascii_terminator_missing});
    const inner_nul = "WGS\x0084|\x00";
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 2049, 34737, 7, 0 }), .{ .tag = tags.geo_ascii_params, .ft = .ascii, .count = 8, .bytes = inner_nul } }, &.{.ascii_nul_inside});
    var out = try runRows(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 2049, 34737, 7, 0 }), .{ .tag = tags.geo_ascii_params, .ft = .ascii, .count = 8, .bytes = no_pipe } });
    defer out.deinit(testing.allocator);
    try testing.expectEqual(tags.geo_ascii_params, out.items[0].tag);
    try testing.expectEqual(@as(?u32, 2), out.items[0].entry_index);
    try testing.expectEqual(@as(?u32, 6), out.items[0].element);
    try testing.expectEqual(@as(u32, '.'), out.items[0].observed);
    try testing.expectEqual(@as(u16, 2049), out.items[0].key_id);
}

test "geokey: the payload layout" {
    var buf: [payload_len]u8 = undefined;
    const p = encodePayload(.{ .tag = 34735, .rule = .key_unsorted, .entry_index = 5, .key_index = 1, .key_id = 1024, .element = 8, .observed = 1024 }, 2, 0x1234, &buf);
    try testing.expectEqual(@as(usize, 36), p.len);
    try testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, p[0..4], .little));
    try testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, p[4..8], .little));
    try testing.expectEqual(@as(u64, 0x1234), std.mem.readInt(u64, p[8..16], .little));
    try testing.expectEqual(@as(u16, 34735), std.mem.readInt(u16, p[16..18], .little));
    try testing.expectEqual(@as(u16, 14), std.mem.readInt(u16, p[18..20], .little));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, p[20..22], .little));
    try testing.expectEqual(@as(u16, 1024), std.mem.readInt(u16, p[22..24], .little));
    try testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, p[24..28], .little));
    try testing.expectEqual(@as(u32, 1024), std.mem.readInt(u32, p[28..32], .little));
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, p[32..34], .little));
    const q = encodePayload(.{ .tag = 33550, .rule = .pixel_scale_without_tiepoint, .entry_index = null, .related = 33922 }, 0, 8, &buf);
    try testing.expectEqual(none_u32, std.mem.readInt(u32, q[4..8], .little));
    try testing.expectEqual(none_u16, std.mem.readInt(u16, q[20..22], .little));
    try testing.expectEqual(none_u32, std.mem.readInt(u32, q[24..28], .little));
    try testing.expectEqual(@as(u16, 33922), std.mem.readInt(u16, q[32..34], .little));
}

test "geokey: each rule's class is validate's 2026-11-07 split" {
    const invalid = [_]u16{ 10, 11, 12, 13, 15, 16, 17, 18, 19 };
    const deviation = [_]u16{ 1, 2, 3, 14, 20, 21 };
    try testing.expectEqual(@typeInfo(Rule).@"enum".fields.len, invalid.len + deviation.len);
    for (invalid) |v| try testing.expectEqual(Class.invalid, @as(Rule, @enumFromInt(v)).class());
    for (deviation) |v| try testing.expectEqual(Class.deviation, @as(Rule, @enumFromInt(v)).class());
}
