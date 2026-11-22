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
//! Tier 1 record already describes it. Key values (rules 30-36) are judged
//! against the edition the directory declares (GeoTIFF 1.0 or 1.1).
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

    // Key values (the key-value batch). Requirement numbers are 19-008r4's.
    /// A Table E.1 key at a TIFFTagLocation its type does not allow: SHORT
    /// at 0 (or 34735, Requirement 4.1), DOUBLE at 34736, ASCII at 34737
    /// (Requirements 7.2, 8.3, 12.2, 13.2, 14.2, 15.2, 16.2, 17.2, 18.2 to
    /// 27.2, 28.2 to 31.2). Observed the location; related the location the
    /// type requires (0 for SHORT).
    key_location_mismatch = 30,
    /// A SHORT key's value in its reserved range (Requirements 7.4, 8.5,
    /// 12.3, 13.3, 14.3, 16.3, 18.3, 19.3, 21.3, 25.3, 26.3, 27.4).
    /// Observed the value. 0 (undefined, 3.1) and 32767 (user-defined, 3.2)
    /// are never reserved; private values (32768 and up) are never faults.
    value_reserved = 31,
    /// VerticalUnitsGeoKey is 32767 (Requirement 16.9, "SHALL not be
    /// used"). Observed 32767.
    vertical_units_user_defined = 32,
    /// A GeoKeyDirectory without GTModelTypeGeoKey (Requirement 8.1).
    /// No key; observed 1024, the absent KeyID.
    model_type_absent = 33,
    /// GTModelType 1 without ProjectedCRSGeoKey, or 2 or 3 without
    /// GeodeticCRSGeoKey (Requirements 8.7, 8.8, 8.9). Key GTModelType;
    /// observed the absent KeyID.
    crs_key_absent = 34,
    /// A key is 32767 (user-defined) and a key its requirement says SHALL be
    /// populated is absent (Requirements 8.10, 12.5, 13.5, 14.5, 16.6, 16.7,
    /// 16.8, 18.5, 19.5, 21.5, 25.5, 26.5, 27.5). One record per absent key
    /// (an either-or pair is one); key the user-defined key; observed the
    /// absent KeyID (the first of a pair).
    user_defined_incomplete = 35,
    /// GeoAsciiParams with no key referencing it (Requirement 6.2). Tag
    /// 34737, anchored on its entry; no key.
    ascii_params_unreferenced = 36,

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
            .key_location_mismatch,
            .value_reserved,
            .vertical_units_user_defined,
            => .invalid,
            .georeference_absent,
            .pixel_scale_with_transformation,
            .pixel_scale_without_tiepoint,
            .key_unsorted,
            .ascii_terminator_missing,
            .ascii_nul_inside,
            .model_type_absent,
            .crs_key_absent,
            .user_defined_incomplete,
            .ascii_params_unreferenced,
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
    var seen: Seen = .{};
    var ascii_referenced = false;
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
        seen.note(id, k, location, count, offset);
        if (location == tags.geo_ascii_params) ascii_referenced = true;

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

    try checkKeyValues(allocator, gkd_rec, dir_values, &seen, out);
    // Rule 36, Requirement 6.2: new in 1.1 (1.0 only says the tag holds the
    // ASCII keys).
    if (ascii) |a| if (!ascii_referenced and editionOf(dir_values) == .v1_1)
        try out.append(allocator, .{ .tag = tags.geo_ascii_params, .rule = .ascii_params_unreferenced, .entry_index = a });
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

// ---- key values (rules 30-36) ----

/// The GeoTIFF edition a directory declares: KeyDirectoryVersion 1 and
/// KeyRevision 1 with MinorRevision 0 (GeoTIFF 1.0) or 1 (GeoTIFF 1.1,
/// 19-008r4). validate ruled 2026-11-22 that each key-value rule is judged
/// against the declared edition; with no edition (rules 10-12 fire) only
/// rule 30, which both editions state alike, runs.
pub const Edition = enum { v1_0, v1_1 };

fn editionOf(dir_values: UnsignedArray) ?Edition {
    if (dir_values.at(0) != 1 or dir_values.at(1) != 1) return null;
    return switch (dir_values.at(2)) {
        0 => .v1_0,
        1 => .v1_1,
        else => null,
    };
}

const KeyKind = enum { short, double, ascii };

/// Table E.1 of 19-008r4 (GeoTIFF 1.0 section 6.2 gives the same IDs and
/// types): every specified key and its type.
const known_keys = [_]struct { id: u16, kind: KeyKind }{
    .{ .id = 1024, .kind = .short },  .{ .id = 1025, .kind = .short },  .{ .id = 1026, .kind = .ascii },
    .{ .id = 2048, .kind = .short },  .{ .id = 2049, .kind = .ascii },  .{ .id = 2050, .kind = .short },
    .{ .id = 2051, .kind = .short },  .{ .id = 2052, .kind = .short },  .{ .id = 2053, .kind = .double },
    .{ .id = 2054, .kind = .short },  .{ .id = 2055, .kind = .double }, .{ .id = 2056, .kind = .short },
    .{ .id = 2057, .kind = .double }, .{ .id = 2058, .kind = .double }, .{ .id = 2059, .kind = .double },
    .{ .id = 2060, .kind = .short },  .{ .id = 2061, .kind = .double }, .{ .id = 3072, .kind = .short },
    .{ .id = 3073, .kind = .ascii },  .{ .id = 3074, .kind = .short },  .{ .id = 3075, .kind = .short },
    .{ .id = 3076, .kind = .short },  .{ .id = 3077, .kind = .double }, .{ .id = 3078, .kind = .double },
    .{ .id = 3079, .kind = .double }, .{ .id = 3080, .kind = .double }, .{ .id = 3081, .kind = .double },
    .{ .id = 3082, .kind = .double }, .{ .id = 3083, .kind = .double }, .{ .id = 3084, .kind = .double },
    .{ .id = 3085, .kind = .double }, .{ .id = 3086, .kind = .double }, .{ .id = 3087, .kind = .double },
    .{ .id = 3088, .kind = .double }, .{ .id = 3089, .kind = .double }, .{ .id = 3090, .kind = .double },
    .{ .id = 3091, .kind = .double }, .{ .id = 3092, .kind = .double }, .{ .id = 3093, .kind = .double },
    .{ .id = 3094, .kind = .double }, .{ .id = 3095, .kind = .double }, .{ .id = 4096, .kind = .short },
    .{ .id = 4097, .kind = .ascii },  .{ .id = 4098, .kind = .short },  .{ .id = 4099, .kind = .short },
};

fn knownIndex(id: u32) ?usize {
    for (known_keys, 0..) |k, i| if (k.id == id) return i;
    return null;
}

const Range = struct { lo: u16, hi: u16 };

/// Reserved values of a SHORT key in an edition. 1.1: Requirements 7.4,
/// 8.5, 12.3, 13.3, 14.3, 16.3, 18.3, 19.3, 21.3, 25.3, 26.3, 27.4. 1.0:
/// the "Reserved" rows of the section 6.3 code tables; its "Obsolete" rows
/// are not faults (validate, 2026-11-22), its "Reserved EPSG" row for
/// vertical CS codes (5200-5999) is an EPSG allocation, and its PCS and
/// Projection tables reserve nothing.
fn reservedRanges(edition: Edition, id: u16) []const Range {
    return switch (edition) {
        .v1_1 => switch (id) {
            1024 => &.{.{ .lo = 4, .hi = 32766 }},
            1025 => &.{.{ .lo = 3, .hi = 32766 }},
            3075 => &.{.{ .lo = 28, .hi = 32766 }},
            2048, 2050, 2051, 2052, 2054, 2056, 2060, 3072, 3074, 3076, 4096, 4098, 4099 => &.{.{ .lo = 1, .hi = 1023 }},
            else => &.{},
        },
        .v1_0 => switch (id) {
            1024 => &.{.{ .lo = 4, .hi = 32766 }}, // 6.3.1.1: 1-3 defined
            1025 => &.{.{ .lo = 1024, .hi = 32766 }}, // 6.3.1.2
            2052, 2054, 2060, 3076, 4099 => &.{.{ .lo = 2001, .hi = 8999 }}, // 6.3.1.3, 6.3.1.4
            2048 => &.{ .{ .lo = 1001, .hi = 3999 }, .{ .lo = 5000, .hi = 32766 } }, // 6.3.2.1
            2050 => &.{ .{ .lo = 1001, .hi = 5999 }, .{ .lo = 7000, .hi = 32766 } }, // 6.3.2.2
            2056 => &.{ .{ .lo = 1001, .hi = 6999 }, .{ .lo = 8000, .hi = 32766 } }, // 6.3.2.3
            2051 => &.{ .{ .lo = 101, .hi = 7999 }, .{ .lo = 9000, .hi = 32766 } }, // 6.3.2.4
            3075 => &.{.{ .lo = 16384, .hi = 32766 }}, // 6.3.3.3
            4096 => &.{ .{ .lo = 1, .hi = 4999 }, .{ .lo = 6000, .hi = 32766 } }, // 6.3.4.1
            4098 => &.{.{ .lo = 16384, .hi = 32766 }}, // 6.3.4.2
            else => &.{},
        },
    };
}

/// The keys a user-defined (32767) key requires, each an alternative set of
/// which one suffices. 1.1: Requirements 8.10, 12.5, 13.5, 14.5, 16.6-16.8,
/// 18.5, 19.5, 21.5, 25.5, 26.5, 27.5 (its per-method parameters are not
/// named, so only the citation). 1.0: the "GeoKey Requirements for
/// User-Defined" lists of section 2.7; conditional entries ("if not
/// degrees", "if not Greenwich") are not checked.
fn userDefinedNeeds(edition: Edition, id: u16) []const []const u16 {
    return switch (edition) {
        .v1_1 => switch (id) {
            1024 => &.{&.{1026}},
            3072 => &.{ &.{3073}, &.{2048}, &.{3074} },
            2048 => &.{ &.{2049}, &.{2050}, &.{ 2054, 2052 } },
            4096 => &.{ &.{4097}, &.{4099}, &.{4098} },
            2054, 2060 => &.{ &.{2049}, &.{2055} },
            2052 => &.{ &.{2049}, &.{2053} },
            3076 => &.{ &.{3073}, &.{3077} },
            2050 => &.{ &.{2049}, &.{2051}, &.{2056} },
            2051 => &.{ &.{2049}, &.{2061} },
            2056 => &.{ &.{1026}, &.{2057}, &.{ 2058, 2059 } },
            4098 => &.{&.{4097}},
            3074 => &.{ &.{3073}, &.{3075}, &.{3076} },
            3075 => &.{&.{3073}},
            else => &.{},
        },
        .v1_0 => switch (id) {
            1024 => &.{&.{1026}},
            2048 => &.{ &.{2049}, &.{2050} },
            2050 => &.{ &.{2049}, &.{2056} },
            2054 => &.{ &.{2049}, &.{2055} },
            2056 => &.{ &.{2049}, &.{2057}, &.{ 2058, 2059 } },
            3072 => &.{ &.{3073}, &.{3074} },
            3074 => &.{ &.{3073}, &.{3075}, &.{3076} },
            3075 => &.{&.{3073}},
            else => &.{},
        },
    };
}

/// The first entry of each Table E.1 key in a directory.
const Seen = struct {
    const Key = struct { index: u16, location: u32, count: u32, offset: u32 };
    keys: [known_keys.len]?Key = [_]?Key{null} ** known_keys.len,

    fn note(self: *Seen, id: u32, k: usize, location: u32, count: u32, offset: u32) void {
        const i = knownIndex(id) orelse return;
        if (self.keys[i] == null) self.keys[i] = .{ .index = @intCast(k), .location = location, .count = count, .offset = offset };
    }

    fn get(self: *const Seen, id: u16) ?Key {
        return self.keys[knownIndex(id).?];
    }
};

/// A SHORT key's value and the index of the SHORT holding it in the
/// GeoKeyDirectory: inline (location 0) or a parameter after the entries
/// (location 34735, in bounds).
fn shortValue(key: Seen.Key, dir_values: UnsignedArray) ?struct { value: u32, element: u32 } {
    if (key.location == 0) return .{ .value = key.offset, .element = 4 + 4 * @as(u32, key.index) + 3 };
    if (key.location == tags.geo_key_directory and key.count >= 1 and @as(u64, key.offset) + key.count <= dir_values.len)
        return .{ .value = dir_values.at(key.offset), .element = key.offset };
    return null;
}

/// Rules 30-35 for the keys walked, in key order, then GTModelType's.
fn checkKeyValues(allocator: std.mem.Allocator, gkd_rec: Record, dir_values: UnsignedArray, seen: *const Seen, out: *std.ArrayListUnmanaged(Record)) error{OutOfMemory}!void {
    const edition = editionOf(dir_values);
    var order: [known_keys.len]?usize = [_]?usize{null} ** known_keys.len;
    var n: usize = 0;
    for (seen.keys, 0..) |maybe, i| if (maybe != null) {
        order[n] = i;
        n += 1;
    };
    std.mem.sort(?usize, order[0..n], seen, struct {
        fn less(s: *const Seen, a: ?usize, b: ?usize) bool {
            return s.keys[a.?].?.index < s.keys[b.?].?.index;
        }
    }.less);

    for (order[0..n]) |slot| {
        const pos = slot.?;
        const key = seen.keys[pos].?;
        const known = known_keys[pos];
        var r = gkd_rec;
        r.key_index = key.index;
        r.key_id = known.id;

        // Rule 30, both editions (1.0 section 2.7 gives each key's type).
        const required: u32 = switch (known.kind) {
            .short => 0,
            .double => tags.geo_double_params,
            .ascii => tags.geo_ascii_params,
        };
        const location_specified = key.location == 0 or key.location == tags.geo_key_directory or
            key.location == tags.geo_double_params or key.location == tags.geo_ascii_params;
        const allowed = key.location == required or (known.kind == .short and key.location == tags.geo_key_directory);
        if (location_specified and !allowed) {
            r.rule = .key_location_mismatch;
            r.element = 4 + 4 * @as(u32, key.index) + 1;
            r.observed = key.location;
            r.related = @intCast(required);
            try out.append(allocator, r);
            continue;
        }

        const ed = edition orelse continue;
        if (known.kind != .short) continue;
        const v = shortValue(key, dir_values) orelse continue;
        r.element = v.element;
        r.observed = v.value;
        for (reservedRanges(ed, known.id)) |range| if (v.value >= range.lo and v.value <= range.hi) {
            r.rule = .value_reserved;
            try out.append(allocator, r);
        };
        if (ed == .v1_1 and known.id == 4099 and v.value == 32767) {
            r.rule = .vertical_units_user_defined;
            try out.append(allocator, r);
        }
        if (v.value == 32767) for (userDefinedNeeds(ed, known.id)) |alternatives| {
            const present = for (alternatives) |id| {
                if (seen.get(id) != null) break true;
            } else false;
            if (!present) {
                r.rule = .user_defined_incomplete;
                r.observed = alternatives[0];
                try out.append(allocator, r);
            }
        };
    }

    // Rules 33 and 34: new in 1.1 (Requirements 8.1, 8.7-8.9).
    if (edition != .v1_1) return;
    const model = seen.get(1024) orelse {
        var r = gkd_rec;
        r.rule = .model_type_absent;
        r.observed = 1024;
        try out.append(allocator, r);
        return;
    };
    const m = shortValue(model, dir_values) orelse return;
    const needed: ?u16 = switch (m.value) {
        1 => 3072,
        2, 3 => 2048,
        else => null,
    };
    if (needed) |id| if (seen.get(id) == null) {
        var r = gkd_rec;
        r.rule = .crs_key_absent;
        r.key_index = model.index;
        r.key_id = 1024;
        r.element = m.element;
        r.observed = id;
        try out.append(allocator, r);
    };
}

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

/// As `expectRules`, ignoring the key-value rules (30 and up), which the
/// structural tests' minimal directories trip and their own tests cover.
fn expectStructural(rows: []const Row, want: []const Rule) !void {
    var out = try runRows(rows);
    defer out.deinit(testing.allocator);
    var got: [32]Rule = undefined;
    var n: usize = 0;
    for (out.items) |r| if (@intFromEnum(r.rule) < 30) {
        got[n] = r.rule;
        n += 1;
    };
    try testing.expectEqualSlices(Rule, want, got[0..n]);
}

// A well-formed directory: version 1.1.1, keys 1024 (geographic), 1025 and
// 2048 inline, 2049 in GeoAsciiParams ("WGS 84|"), 2057 in GeoDoubleParams.
const good_ascii = "WGS 84|\x00";
const good_gkd = gkdRow(&.{ 1, 1, 1, 5, 1024, 0, 1, 2, 1025, 0, 1, 1, 2048, 0, 1, 4326, 2049, 34737, 7, 0, 2057, 34736, 1, 0 });
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
    try expectStructural(&.{gkdRow(&.{ 1, 1, 1, 0 })}, &.{.georeference_absent});
    try expectStructural(&.{ t_scale, t_tie, t_xform }, &.{.pixel_scale_with_transformation});
    try expectStructural(&.{t_scale}, &.{.pixel_scale_without_tiepoint});
    try expectStructural(&.{ t_scale, t_xform, gkdRow(&.{ 1, 1, 1, 0 }) }, &.{ .pixel_scale_with_transformation, .pixel_scale_without_tiepoint });
    var out = try runRows(&.{ t_scale, t_xform });
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 0), out.items[0].entry_index);
    try testing.expectEqual(tags.model_transformation, out.items[0].related);
    try testing.expectEqual(tags.model_tiepoint, out.items[1].related);
}

test "geokey rules 10-13: the header (Requirements 2.5, 2.7, 2.9, 2.11)" {
    try expectStructural(&.{ t_tie, gkdRow(&.{ 2, 1, 1, 0 }) }, &.{.key_directory_version});
    try expectStructural(&.{ t_tie, gkdRow(&.{ 1, 0, 1, 0 }) }, &.{.key_revision});
    try expectStructural(&.{ t_tie, gkdRow(&.{ 1, 1, 2, 0 }) }, &.{.minor_revision});
    try expectStructural(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1024, 0, 1, 1 }) }, &.{.key_entries_truncated});
    var out = try runRows(&.{ t_tie, gkdRow(&.{ 1, 1, 7, 3, 1024, 0, 1, 1 }) });
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(?u32, 2), out.items[0].element);
    try testing.expectEqual(@as(u32, 7), out.items[0].observed);
    try testing.expectEqual(@as(?u32, 3), out.items[1].element);
    try testing.expectEqual(@as(u32, 3), out.items[1].observed);
    // Fewer than four values is Tier 1's count fault: no Tier 3 walk.
    try expectStructural(&.{ t_tie, gkdRow(&.{ 2, 0, 9 }) }, &.{});
    // A non-integer type is Tier 1's type fault: no Tier 3 walk.
    try expectStructural(&.{ t_tie, .{ .tag = tags.geo_key_directory, .ft = .ascii, .count = 8, .bytes = "12345678" } }, &.{});
}

test "geokey rules 14 and 15: KeyIDs ascending (Requirement 1.6)" {
    try expectStructural(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 3, 1025, 0, 1, 1, 1024, 0, 1, 1, 3072, 0, 1, 1 }) }, &.{.key_unsorted});
    try expectStructural(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1024, 0, 1, 1, 1024, 0, 1, 1 }) }, &.{.key_duplicate});
    var out = try runRows(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1025, 0, 1, 1, 1024, 0, 1, 1 }) });
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(?u16, 1), out.items[0].key_index);
    try testing.expectEqual(@as(u16, 1024), out.items[0].key_id);
    try testing.expectEqual(@as(?u32, 8), out.items[0].element);
}

test "geokey rules 16-19: TIFFTagLocation, Count and ValueOffset (Requirements 2.14, 2.16, 4.2)" {
    try expectStructural(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 1024, 33550, 1, 0 }) }, &.{.tag_location_invalid});
    try expectStructural(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 2057, 34736, 1, 0 }) }, &.{.location_tag_absent});
    try expectStructural(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 2049, 34737, 4, 0 }) }, &.{.location_tag_absent});
    try expectStructural(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 2057, 34736, 2, 0 }), good_doubles }, &.{.value_out_of_bounds});
    try expectStructural(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 2049, 34737, 9, 0 }), good_ascii_row }, &.{.value_out_of_bounds});
    // Short parameters after the last key entry are fine (Requirement 4.2);
    // inside the entries they are not; past the end they are out of bounds.
    try expectStructural(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 3073, 34735, 2, 8, 7, 9 }) }, &.{});
    try expectStructural(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 3073, 34735, 2, 4, 7, 9 }) }, &.{.short_params_inside_entries});
    try expectStructural(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 3073, 34735, 3, 8, 7, 9 }) }, &.{.value_out_of_bounds});
    var out = try runRows(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 2057, 34736, 2, 0 }), good_doubles });
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), out.items[0].observed);
    try testing.expectEqual(tags.geo_double_params, out.items[0].related);
}

test "geokey rules 20 and 21: GeoAsciiParams terminators (Requirements 6.3, 6.4)" {
    const no_pipe = "WGS 84.\x00";
    try expectStructural(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 2049, 34737, 7, 0 }), .{ .tag = tags.geo_ascii_params, .ft = .ascii, .count = 8, .bytes = no_pipe } }, &.{.ascii_terminator_missing});
    const inner_nul = "WGS\x0084|\x00";
    try expectStructural(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 2049, 34737, 7, 0 }), .{ .tag = tags.geo_ascii_params, .ft = .ascii, .count = 8, .bytes = inner_nul } }, &.{.ascii_nul_inside});
    var out = try runRows(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 2049, 34737, 7, 0 }), .{ .tag = tags.geo_ascii_params, .ft = .ascii, .count = 8, .bytes = no_pipe } });
    defer out.deinit(testing.allocator);
    try testing.expectEqual(tags.geo_ascii_params, out.items[0].tag);
    try testing.expectEqual(@as(?u32, 2), out.items[0].entry_index);
    try testing.expectEqual(@as(?u32, 6), out.items[0].element);
    try testing.expectEqual(@as(u32, '.'), out.items[0].observed);
    try testing.expectEqual(@as(u16, 2049), out.items[0].key_id);
}

test "geokey rule 30: a key at a location its type does not allow (both editions)" {
    // 1.1 with GTModelType 0 (undefined), so rules 33 and 34 stay quiet.
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1024, 0, 1, 0, 1025, 34736, 1, 0 }), good_doubles }, &.{.key_location_mismatch});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 1, 2057, 0, 1, 5 }) }, &.{.key_location_mismatch});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 1, 2049, 34736, 1, 0 }), good_doubles }, &.{.key_location_mismatch});
    // A SHORT in the directory's own parameters (Requirement 4.1) is allowed;
    // an unspecified location is rule 16's, not 30's; a key outside Table E.1
    // is not checked.
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 1, 1025, 34735, 1, 8, 1 }) }, &.{});
    try expectStructural(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 1, 1025, 33550, 1, 0 }) }, &.{.tag_location_invalid});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 1, 1025, 33550, 1, 0 }) }, &.{.tag_location_invalid});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 1, 5000, 34736, 1, 0 }), good_doubles }, &.{});
    var out = try runRows(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 1, 2057, 0, 1, 5 }) });
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(?u16, 0), out.items[0].key_index);
    try testing.expectEqual(@as(u16, 2057), out.items[0].key_id);
    try testing.expectEqual(@as(?u32, 5), out.items[0].element);
    try testing.expectEqual(@as(u32, 0), out.items[0].observed);
    try testing.expectEqual(tags.geo_double_params, out.items[0].related);
}

test "geokey rule 31: reserved values, by the declared edition" {
    // 1.1 reserves 1-1023 for GeodeticCRS; 1.0 calls 1-1000 obsolete and
    // reserves 1001-3999.
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1024, 0, 1, 0, 2048, 0, 1, 500 }) }, &.{.value_reserved});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 1, 2048, 0, 1, 500 }) }, &.{});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 1, 2048, 0, 1, 2000 }) }, &.{.value_reserved});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1024, 0, 1, 0, 2048, 0, 1, 2000 }) }, &.{});
    // ProjMethod: 1.1 reserves 28-32766, 1.0 16384-32766.
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1024, 0, 1, 0, 3075, 0, 1, 28 }) }, &.{.value_reserved});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 1, 3075, 0, 1, 28 }) }, &.{});
    // 1.0's "Reserved EPSG" vertical CS row is an EPSG allocation (EGM96 5773).
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 1, 4096, 0, 1, 5773 }) }, &.{});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 1, 4096, 0, 1, 6000 }) }, &.{.value_reserved});
    // 0 (undefined), private values and an unknown edition are never reserved.
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1024, 0, 1, 0, 2048, 0, 1, 0 }) }, &.{});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1024, 0, 1, 0, 2048, 0, 1, 40000 }) }, &.{});
    try expectStructural(&.{ t_tie, gkdRow(&.{ 1, 1, 5, 1, 2048, 0, 1, 500 }) }, &.{.minor_revision});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 5, 1, 2048, 0, 1, 500 }) }, &.{.minor_revision});
    // A value held in the directory's parameters (location 34735).
    var out = try runRows(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1024, 0, 1, 0, 2048, 34735, 1, 12, 500 }) });
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(Rule.value_reserved, out.items[0].rule);
    try testing.expectEqual(@as(?u32, 12), out.items[0].element);
    try testing.expectEqual(@as(u32, 500), out.items[0].observed);
    try testing.expectEqual(@as(u16, 2048), out.items[0].key_id);
}

test "geokey rule 32: VerticalUnits user-defined (1.1 only)" {
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1024, 0, 1, 0, 4099, 0, 1, 32767 }) }, &.{.vertical_units_user_defined});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 1, 4099, 0, 1, 32767 }) }, &.{});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1024, 0, 1, 0, 4099, 0, 1, 9001 }) }, &.{});
}

test "geokey rules 33 and 34: GTModelType and the CRS key it names (1.1 only)" {
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 1025, 0, 1, 1 }) }, &.{.model_type_absent});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 1, 1025, 0, 1, 1 }) }, &.{});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 1024, 0, 1, 1 }) }, &.{.crs_key_absent});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 1024, 0, 1, 3 }) }, &.{.crs_key_absent});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1024, 0, 1, 1, 3072, 0, 1, 32610 }) }, &.{});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1024, 0, 1, 3, 2048, 0, 1, 4978 }) }, &.{});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 1, 1024, 0, 1, 1 }) }, &.{});
    var out = try runRows(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1024, 0, 1, 2, 1025, 0, 1, 1 }) });
    defer out.deinit(testing.allocator);
    try testing.expectEqual(Rule.crs_key_absent, out.items[0].rule);
    try testing.expectEqual(@as(?u16, 0), out.items[0].key_index);
    try testing.expectEqual(@as(u16, 1024), out.items[0].key_id);
    try testing.expectEqual(@as(?u32, 7), out.items[0].element);
    try testing.expectEqual(@as(u32, 2048), out.items[0].observed);
    var absent = try runRows(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 0 }) });
    defer absent.deinit(testing.allocator);
    try testing.expectEqual(Rule.model_type_absent, absent.items[0].rule);
    try testing.expectEqual(@as(?u16, null), absent.items[0].key_index);
    try testing.expectEqual(@as(u32, 1024), absent.items[0].observed);
}

test "geokey rule 35: a user-defined key without the keys its edition requires" {
    // 1.1, Requirement 12.5: ProjectedCitation, GeodeticCRS and Projection.
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1024, 0, 1, 1, 3072, 0, 1, 32767 }) }, &.{ .user_defined_incomplete, .user_defined_incomplete, .user_defined_incomplete });
    // 1.0: PCSCitation and Projection only.
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 1, 3072, 0, 1, 32767 }) }, &.{ .user_defined_incomplete, .user_defined_incomplete });
    var out = try runRows(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 1, 3072, 0, 1, 32767 }) });
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3073), out.items[0].observed);
    try testing.expectEqual(@as(u32, 3074), out.items[1].observed);
    try testing.expectEqual(@as(u16, 3072), out.items[0].key_id);
    try testing.expectEqual(@as(?u32, 7), out.items[0].element);
    // An either-or pair is satisfied by either key: 1.1 GeodeticCRS 32767
    // with a citation, a datum and linear (not angular) units.
    const ascii = "x|\x00";
    const ascii_row = Row{ .tag = tags.geo_ascii_params, .ft = .ascii, .count = ascii.len, .bytes = ascii };
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 5, 1024, 0, 1, 3, 2048, 0, 1, 32767, 2049, 34737, 2, 0, 2050, 0, 1, 6326, 2052, 0, 1, 9001 }), ascii_row }, &.{});
    // GeodeticDatum 32767 needs a prime meridian in 1.1, not in 1.0.
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 4, 1024, 0, 1, 0, 2049, 34737, 2, 0, 2050, 0, 1, 32767, 2056, 0, 1, 7030 }), ascii_row }, &.{.user_defined_incomplete});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 3, 2049, 34737, 2, 0, 2050, 0, 1, 32767, 2056, 0, 1, 7030 }), ascii_row }, &.{});
}

test "geokey rule 36: GeoAsciiParams with no ASCII key (1.1 only)" {
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 1024, 0, 1, 0 }), good_ascii_row }, &.{.ascii_params_unreferenced});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 0, 1, 1024, 0, 1, 0 }), good_ascii_row }, &.{});
    try expectRules(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 2, 1024, 0, 1, 0, 1026, 34737, 7, 0 }), good_ascii_row }, &.{});
    var out = try runRows(&.{ t_tie, gkdRow(&.{ 1, 1, 1, 1, 1024, 0, 1, 0 }), good_ascii_row });
    defer out.deinit(testing.allocator);
    try testing.expectEqual(tags.geo_ascii_params, out.items[0].tag);
    try testing.expectEqual(@as(?u32, 2), out.items[0].entry_index);
    try testing.expectEqual(@as(?u16, null), out.items[0].key_index);
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

test "geokey: each rule's class is validate's split (2026-11-07; 30-36 2026-11-22)" {
    const invalid = [_]u16{ 10, 11, 12, 13, 15, 16, 17, 18, 19, 30, 31, 32 };
    const deviation = [_]u16{ 1, 2, 3, 14, 20, 21, 33, 34, 35, 36 };
    try testing.expectEqual(@typeInfo(Rule).@"enum".fields.len, invalid.len + deviation.len);
    for (invalid) |v| try testing.expectEqual(Class.invalid, @as(Rule, @enumFromInt(v)).class());
    for (deviation) |v| try testing.expectEqual(Class.deviation, @as(Rule, @enumFromInt(v)).class());
}
