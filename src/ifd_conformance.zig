//! Directory-level TIFF "must"s that decoding does not otherwise depend on.
//!
//! A violation here is corrupt, even when every sample still decodes
//! (validate's ruling, 2026-11-03: a proven violation is never a tolerated
//! deviation, however many readers accept it; tolerance belongs in the
//! decoder, not the verdict). Two checks:
//!
//! - Entries in strictly ascending tag order (TIFF 6.0 p. 15). A flipped
//!   bit in a tag ID usually shows up only here: the lost tag's default
//!   then stands in for its value.
//! - Each tag in `rules` has an allowed type, count and value set.
//!
//! Two boundaries from the same ruling. BYTE, SHORT and LONG are all
//! acceptable for any unsigned-integer field, scalar or array: "TIFF
//! readers should accept BYTE, SHORT, or LONG values for any unsigned
//! integer field", and "all fields are actually one-dimensional arrays"
//! (TIFF 6.0 p. 16; validate, corrected 2026-11-04). Each value must still
//! be in range, and a field defined as SHORT holds 16-bit values however
//! it is stored. Values from 32768 up to 65535 are reserved for private
//! use (TIFF 6.0 p. 8), so they are not violations. Tags without a rule,
//! including every private tag, are skipped.
//!
//! Pure: reads only the parsed `Ifd`, whose out-of-line values are already
//! cached.

const std = @import("std");
const parser = @import("tiffz-parser");
const ifd_mod = parser.ifd;
const header_mod = parser.header;
const tags = parser.tags;

const Endian = header_mod.Endian;
const Ifd = ifd_mod.Ifd;
const Entry = ifd_mod.Entry;
const FieldType = ifd_mod.FieldType;

/// Why a field is invalid. Wire values for the finding payload.
pub const Reason = enum(u16) {
    type = 1,
    count = 2,
    value = 3,
};

pub const Fault = union(enum) {
    /// Entry `entry_index` does not have a larger tag than the entry before it.
    unsorted: struct { entry_index: u32, tag: u16, prev_tag: u16 },
    field_invalid: struct {
        entry_index: u32,
        tag: u16,
        reason: Reason,
        raw_type: u16,
        raw_count: u64,
        /// The value/offset slot read as an unsigned integer in the file's
        /// byte order: u32 for classic TIFF, u64 for BigTIFF.
        raw_slot: u64,
    },

    pub fn entryIndex(self: Fault) u32 {
        return switch (self) {
            .unsorted => |f| f.entry_index,
            .field_invalid => |f| f.entry_index,
        };
    }
};

/// The field type a rule's tag is defined with.
const Kind = enum {
    /// Defined as SHORT. Stored as BYTE, SHORT or LONG, scalar or array
    /// (TIFF 6.0 p. 16); every value must fit in 16 bits.
    unsigned_short,
};

const Count = enum {
    one,
    samples_per_pixel,
    /// {1 or 3} * 2**BitsPerSample.
    transfer_function,
};

const Rule = struct {
    tag: u16,
    kind: Kind,
    count: Count,
    /// Inclusive public-range value ranges, or null when unconstrained.
    values: ?[]const [2]u16,
    /// Where the rule comes from, so an omission is auditable.
    citation: []const u8,
};

/// One row per constrained tag. Growing this table to every tag a claimed
/// specification constrains is tracked in PLAN.md.
pub const rules = [_]Rule{
    .{ .tag = tags.subfile_type, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 3 }}, .citation = "TIFF 6.0 pp. 40-41" },
    .{ .tag = tags.threshholding, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 3 }}, .citation = "TIFF 6.0 p. 41" },
    .{ .tag = tags.fill_order, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 2 }}, .citation = "TIFF 6.0 p. 32" },
    .{ .tag = tags.orientation, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 8 }}, .citation = "TIFF 6.0 pp. 36-37" },
    .{ .tag = tags.gray_response_unit, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 5 }}, .citation = "TIFF 6.0 pp. 33-34" },
    .{ .tag = tags.resolution_unit, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 3 }}, .citation = "TIFF 6.0 p. 38" },
    .{ .tag = tags.transfer_function, .kind = .unsigned_short, .count = .transfer_function, .values = null, .citation = "TIFF 6.0 p. 84" },
    .{ .tag = tags.ink_set, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 2 }}, .citation = "TIFF 6.0 p. 70" },
    .{ .tag = tags.sample_format, .kind = .unsigned_short, .count = .samples_per_pixel, .values = &.{.{ 1, 4 }}, .citation = "TIFF 6.0 p. 80" },
    .{ .tag = tags.ycbcr_positioning, .kind = .unsigned_short, .count = .one, .values = &.{.{ 1, 2 }}, .citation = "TIFF 6.0 p. 92" },
};

comptime {
    // Strictly ascending, so a duplicated row cannot shadow another.
    for (rules[1..], 0..) |rule, i| {
        if (rule.tag <= rules[i].tag) @compileError("ifd_conformance.rules must be sorted by tag without duplicates");
    }
}

fn ruleFor(tag: u16) ?*const Rule {
    for (&rules) |*rule| {
        if (rule.tag == tag) return rule;
    }
    return null;
}

/// Append every fault in `dir` to `out`, in entry order.
pub fn check(
    allocator: std.mem.Allocator,
    dir: *const Ifd,
    endian: Endian,
    out: *std.ArrayListUnmanaged(Fault),
) error{OutOfMemory}!void {
    for (dir.entries, 0..) |entry, i| {
        const index: u32 = @intCast(i);
        if (i > 0 and entry.tag <= dir.entries[i - 1].tag) {
            try out.append(allocator, .{ .unsorted = .{
                .entry_index = index,
                .tag = entry.tag,
                .prev_tag = dir.entries[i - 1].tag,
            } });
        }
        const rule = ruleFor(entry.tag) orelse continue;
        if (fieldReason(dir, i, rule.*, endian)) |reason| {
            try out.append(allocator, .{ .field_invalid = .{
                .entry_index = index,
                .tag = entry.tag,
                .reason = reason,
                .raw_type = entry.raw_type,
                .raw_count = entry.count,
                .raw_slot = rawSlot(entry, dir.offset_width, endian),
            } });
        }
    }
}

fn rawSlot(entry: Entry, width: ifd_mod.OffsetWidth, endian: Endian) u64 {
    return switch (width) {
        .classic => header_mod.readU32(entry.raw_value_or_offset[0..4], endian),
        .big => header_mod.readU64(&entry.raw_value_or_offset, endian),
    };
}

fn fieldReason(dir: *const Ifd, index: usize, rule: Rule, endian: Endian) ?Reason {
    const entry = dir.entries[index];
    const type_ok = switch (rule.kind) {
        .unsigned_short => entry.field_type == .byte or entry.field_type == .short or entry.field_type == .long,
    };
    if (!type_ok) return .type;

    const count_ok = switch (rule.count) {
        .one => entry.count == 1,
        // A missing or malformed SamplesPerPixel is its own problem; do not
        // let it cascade into a count fault here.
        .samples_per_pixel => if (scalar(dir, tags.samples_per_pixel, endian)) |spp| entry.count == spp else true,
        .transfer_function => blk: {
            const bps = firstElement(dir, tags.bits_per_sample, endian) orelse 1;
            if (bps == 0 or bps > 16) break :blk false;
            const per_channel = @as(u64, 1) << @intCast(bps);
            break :blk entry.count == per_channel or entry.count == 3 * per_channel;
        },
    };
    if (!count_ok) return .count;

    const max: u64 = switch (rule.kind) {
        .unsigned_short => std.math.maxInt(u16),
    };
    const bytes = dir.entryValueSlice(index);
    var i: usize = 0;
    while (i < entry.count) : (i += 1) {
        const value = element(bytes, entry.field_type, i, endian) orelse return .count;
        if (value > max) return .value;
        const ranges = rule.values orelse continue;
        if (value >= 32768) continue; // private range, not a violation
        if (!inRanges(@intCast(value), ranges)) return .value;
    }
    return null;
}

fn inRanges(value: u16, ranges: []const [2]u16) bool {
    for (ranges) |range| {
        if (value >= range[0] and value <= range[1]) return true;
    }
    return false;
}

/// Element `i` of an unsigned BYTE, SHORT or LONG array, or null if the
/// bytes are too short.
fn element(bytes: []const u8, field_type: FieldType, i: usize, endian: Endian) ?u64 {
    const width: usize = switch (field_type) {
        .byte => 1,
        .short => 2,
        .long => 4,
        else => return null,
    };
    const at = i * width;
    if (at + width > bytes.len) return null;
    return switch (field_type) {
        .byte => bytes[at],
        .short => header_mod.readU16(bytes[at..], endian),
        .long => header_mod.readU32(bytes[at..], endian),
        else => unreachable,
    };
}

/// The value of an unsigned scalar tag with count 1, or null.
fn scalar(dir: *const Ifd, tag: u16, endian: Endian) ?u64 {
    for (dir.entries, 0..) |entry, i| {
        if (entry.tag != tag) continue;
        if (entry.count != 1) return null;
        return element(dir.entryValueSlice(i), entry.field_type, 0, endian);
    }
    return null;
}

/// The first element of an unsigned array tag, or null.
fn firstElement(dir: *const Ifd, tag: u16, endian: Endian) ?u64 {
    for (dir.entries, 0..) |entry, i| {
        if (entry.tag != tag) continue;
        if (entry.count == 0) return null;
        return element(dir.entryValueSlice(i), entry.field_type, 0, endian);
    }
    return null;
}

/// Payload of finding 17 `ifd_entries_unsorted`, little-endian: u32 IFD
/// index, u32 entry index, u64 absolute entry offset, u16 tag, u16 tag of
/// the preceding entry.
pub const unsorted_payload_len = 20;

/// Payload of finding 18 `tag_field_invalid`, little-endian: u32 IFD index,
/// u32 entry index, u64 absolute entry offset, u16 tag, u16 reason, u16 raw
/// type, u64 raw count, u64 raw value/offset slot (see `Fault`).
pub const field_invalid_payload_len = 38;

/// Absolute offset of entry `entry_index` in the IFD at `ifd_offset`.
pub fn entryOffset(ifd_offset: u64, entry_index: u32, width: ifd_mod.OffsetWidth) u64 {
    return switch (width) {
        .classic => ifd_offset + 2 + @as(u64, entry_index) * 12,
        .big => ifd_offset + 8 + @as(u64, entry_index) * 20,
    };
}

/// Write `fault`'s payload into `buf` and return the used prefix.
pub fn encodePayload(fault: Fault, ifd_index: u32, entry_offset: u64, buf: *[field_invalid_payload_len]u8) []const u8 {
    std.mem.writeInt(u32, buf[0..4], ifd_index, .little);
    std.mem.writeInt(u32, buf[4..8], fault.entryIndex(), .little);
    std.mem.writeInt(u64, buf[8..16], entry_offset, .little);
    switch (fault) {
        .unsorted => |f| {
            std.mem.writeInt(u16, buf[16..18], f.tag, .little);
            std.mem.writeInt(u16, buf[18..20], f.prev_tag, .little);
            return buf[0..unsorted_payload_len];
        },
        .field_invalid => |f| {
            std.mem.writeInt(u16, buf[16..18], f.tag, .little);
            std.mem.writeInt(u16, buf[18..20], @intFromEnum(f.reason), .little);
            std.mem.writeInt(u16, buf[20..22], f.raw_type, .little);
            std.mem.writeInt(u64, buf[22..30], f.raw_count, .little);
            std.mem.writeInt(u64, buf[30..38], f.raw_slot, .little);
            return buf[0..field_invalid_payload_len];
        },
    }
}

// ---- tests ----

const testing = std.testing;

/// A little-endian classic entry with an inline value.
fn inline16(tag: u16, field_type: FieldType, count: u64, value: u32) Entry {
    var slot = [_]u8{0} ** 8;
    std.mem.writeInt(u32, slot[0..4], value, .little);
    return .{ .tag = tag, .field_type = field_type, .raw_type = @intFromEnum(field_type), .count = count, .raw_value_or_offset = slot };
}

fn faultsOf(entries: []Entry, cached: []?[]u8) !std.ArrayListUnmanaged(Fault) {
    const dir = Ifd{
        .entries = entries,
        .next_offset = 0,
        .offset_width = .classic,
        .allocator = testing.allocator,
        .cached_values = cached,
    };
    var out: std.ArrayListUnmanaged(Fault) = .empty;
    try check(testing.allocator, &dir, .little, &out);
    return out;
}

fn expectFaults(entries: []Entry, expected: []const Fault) !void {
    var cached = [_]?[]u8{null} ** 16;
    var out = try faultsOf(entries, cached[0..entries.len]);
    defer out.deinit(testing.allocator);
    try testing.expectEqualDeep(expected, out.items);
}

test "sorted entries with valid fields have no faults" {
    var entries = [_]Entry{
        inline16(256, .short, 1, 8),
        inline16(258, .short, 1, 8),
        inline16(tags.fill_order, .short, 1, 2),
        inline16(tags.orientation, .short, 1, 8),
        inline16(tags.samples_per_pixel, .short, 1, 1),
        inline16(tags.sample_format, .short, 1, 4),
    };
    try expectFaults(&entries, &.{});
}

test "a tag not larger than its predecessor is unsorted, duplicates included" {
    var entries = [_]Entry{
        inline16(256, .short, 1, 8),
        inline16(8476, .short, 1, 1), // a PlanarConfiguration whose tag ID was hit
        inline16(296, .short, 1, 2),
        inline16(296, .short, 1, 2),
    };
    try expectFaults(&entries, &.{
        .{ .unsorted = .{ .entry_index = 2, .tag = 296, .prev_tag = 8476 } },
        .{ .unsorted = .{ .entry_index = 3, .tag = 296, .prev_tag = 296 } },
    });
}

test "BYTE, SHORT and LONG are all acceptable for an unsigned scalar, other types are not" {
    for ([_]FieldType{ .byte, .short, .long }) |t| {
        var entries = [_]Entry{inline16(tags.fill_order, t, 1, 1)};
        try expectFaults(&entries, &.{});
    }
    for ([_]FieldType{ .float, .sshort, .slong, .rational, .ascii, .undefined, .sbyte }) |t| {
        var entries = [_]Entry{inline16(tags.fill_order, t, 1, 1)};
        try expectFaults(&entries, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.fill_order, .reason = .type, .raw_type = @intFromEnum(t), .raw_count = 1, .raw_slot = 1 } }});
    }
}

test "every single-value rule accepts its range ends and rejects the values just outside" {
    var checked: usize = 0;
    for (rules) |rule| {
        if (rule.count != .one) continue;
        const ranges = rule.values orelse continue;
        for (ranges) |range| {
            for ([_]u16{ range[0], range[1] }) |v| {
                var ok = [_]Entry{inline16(rule.tag, .short, 1, v)};
                try expectFaults(&ok, &.{});
            }
            for ([_]u32{ range[0] -% 1, range[1] + 1 }) |v| {
                if (v >= 32768) continue; // private, never a fault
                var inside = false;
                for (ranges) |other| inside = inside or (v >= other[0] and v <= other[1]);
                if (inside) continue;
                var bad = [_]Entry{inline16(rule.tag, .short, 1, v)};
                try expectFaults(&bad, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = rule.tag, .reason = .value, .raw_type = 3, .raw_count = 1, .raw_slot = v } }});
            }
            checked += 1;
        }
        var two = [_]Entry{inline16(rule.tag, .short, 2, ranges[0][0] | (@as(u32, ranges[0][0]) << 16))};
        try expectFaults(&two, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = rule.tag, .reason = .count, .raw_type = 3, .raw_count = 2, .raw_slot = ranges[0][0] | (@as(u32, ranges[0][0]) << 16) } }});
    }
    try testing.expect(checked >= 8);
}

test "out-of-range public values are invalid; private-range values are not" {
    var bad = [_]Entry{inline16(tags.orientation, .short, 1, 257)};
    try expectFaults(&bad, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.orientation, .reason = .value, .raw_type = 3, .raw_count = 1, .raw_slot = 257 } }});
    var zero = [_]Entry{inline16(tags.fill_order, .short, 1, 0)};
    try expectFaults(&zero, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.fill_order, .reason = .value, .raw_type = 3, .raw_count = 1, .raw_slot = 0 } }});
    var private = [_]Entry{inline16(tags.orientation, .short, 1, 40000)};
    try expectFaults(&private, &.{});
    // A LONG above the SHORT range is a value fault, not a private value.
    var wide = [_]Entry{inline16(tags.orientation, .long, 1, 65537)};
    try expectFaults(&wide, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.orientation, .reason = .value, .raw_type = 4, .raw_count = 1, .raw_slot = 65537 } }});
}

test "SampleFormat needs one value per sample, each 1 to 4" {
    var ok = [_]Entry{ inline16(tags.samples_per_pixel, .short, 1, 2), inline16(tags.sample_format, .short, 2, 0x0003_0003) };
    try expectFaults(&ok, &.{});
    var count = [_]Entry{ inline16(tags.samples_per_pixel, .short, 1, 1), inline16(tags.sample_format, .short, 2, 0x0001_0001) };
    try expectFaults(&count, &.{.{ .field_invalid = .{ .entry_index = 1, .tag = tags.sample_format, .reason = .count, .raw_type = 3, .raw_count = 2, .raw_slot = 0x0001_0001 } }});
    var value = [_]Entry{ inline16(tags.samples_per_pixel, .short, 1, 2), inline16(tags.sample_format, .short, 2, 0x0005_0001) };
    try expectFaults(&value, &.{.{ .field_invalid = .{ .entry_index = 1, .tag = tags.sample_format, .reason = .value, .raw_type = 3, .raw_count = 2, .raw_slot = 0x0005_0001 } }});
    // Without SamplesPerPixel the default is 1.
    var absent = [_]Entry{inline16(tags.sample_format, .short, 1, 2)};
    try expectFaults(&absent, &.{});
}

test "TransferFunction count is one or three tables of 2**BitsPerSample" {
    inline for (.{ 256, 768 }) |n| {
        var entries = [_]Entry{ inline16(tags.bits_per_sample, .short, 1, 8), inline16(tags.transfer_function, .short, n, 0x40) };
        var table = [_]u8{0} ** (2 * n);
        var cached = [_]?[]u8{ null, &table };
        var out = try faultsOf(&entries, &cached);
        defer out.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), out.items.len);
    }
    var entries = [_]Entry{ inline16(tags.bits_per_sample, .short, 1, 8), inline16(tags.transfer_function, .short, 272, 0x40) };
    try expectFaults(&entries, &.{.{ .field_invalid = .{ .entry_index = 1, .tag = tags.transfer_function, .reason = .count, .raw_type = 3, .raw_count = 272, .raw_slot = 0x40 } }});
}

test "an unsigned-integer array may be BYTE, SHORT or LONG, but holds 16-bit values" {
    // SampleFormat for two samples, widened and narrowed (TIFF 6.0 p. 16).
    var byte = [_]Entry{ inline16(tags.samples_per_pixel, .short, 1, 2), inline16(tags.sample_format, .byte, 2, 0x0301) };
    try expectFaults(&byte, &.{});
    var long_values = [_]u8{ 1, 0, 0, 0, 3, 0, 0, 0 };
    var long = [_]Entry{ inline16(tags.samples_per_pixel, .short, 1, 2), inline16(tags.sample_format, .long, 2, 0x200) };
    var cached = [_]?[]u8{ null, &long_values };
    var out = try faultsOf(&long, &cached);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    out.deinit(testing.allocator);
    // A LONG above 65535 is a value fault even where the low half is valid.
    var wide = [_]Entry{inline16(tags.sample_format, .long, 1, 0x1_0001)};
    try expectFaults(&wide, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.sample_format, .reason = .value, .raw_type = 4, .raw_count = 1, .raw_slot = 0x1_0001 } }});
    // Other types stay type faults for an array.
    for ([_]FieldType{ .sshort, .slong, .float, .rational, .ascii, .undefined }) |t| {
        var bad = [_]Entry{inline16(tags.sample_format, t, 1, 1)};
        try expectFaults(&bad, &.{.{ .field_invalid = .{ .entry_index = 0, .tag = tags.sample_format, .reason = .type, .raw_type = @intFromEnum(t), .raw_count = 1, .raw_slot = 1 } }});
    }
}

test "TransferFunction may be BYTE or LONG, and a LONG entry above 65535 is a value fault" {
    // BitsPerSample 2 gives tables of 4 entries.
    var byte = [_]Entry{ inline16(tags.bits_per_sample, .short, 1, 2), inline16(tags.transfer_function, .byte, 4, 0x0302_0100) };
    try expectFaults(&byte, &.{});

    var long_table = [_]u8{0} ** 16;
    for (0..4) |k| std.mem.writeInt(u32, long_table[4 * k ..][0..4], @intCast(k * 21845), .little);
    var long = [_]Entry{ inline16(tags.bits_per_sample, .short, 1, 2), inline16(tags.transfer_function, .long, 4, 0x100) };
    var cached = [_]?[]u8{ null, &long_table };
    var out = try faultsOf(&long, &cached);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    out.deinit(testing.allocator);

    std.mem.writeInt(u32, long_table[12..16], 65536, .little);
    out = try faultsOf(&long, &cached);
    defer out.deinit(testing.allocator);
    try testing.expectEqualDeep(&[_]Fault{.{ .field_invalid = .{ .entry_index = 1, .tag = tags.transfer_function, .reason = .value, .raw_type = 4, .raw_count = 4, .raw_slot = 0x100 } }}, out.items);
}

test "entry offsets and payload layout" {
    try testing.expectEqual(@as(u64, 8 + 2 + 3 * 12), entryOffset(8, 3, .classic));
    try testing.expectEqual(@as(u64, 16 + 8 + 3 * 20), entryOffset(16, 3, .big));
    var buf: [field_invalid_payload_len]u8 = undefined;
    const unsorted = encodePayload(.{ .unsorted = .{ .entry_index = 2, .tag = 296, .prev_tag = 8476 } }, 1, 34, &buf);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0, 2, 0, 0, 0, 34, 0, 0, 0, 0, 0, 0, 0, 0x28, 0x01, 0x1c, 0x21 }, unsorted);
    const invalid = encodePayload(.{ .field_invalid = .{ .entry_index = 5, .tag = 274, .reason = .value, .raw_type = 3, .raw_count = 1, .raw_slot = 257 } }, 0, 70, &buf);
    try testing.expectEqual(@as(usize, field_invalid_payload_len), invalid.len);
    try testing.expectEqualSlices(u8, &.{ 0x12, 0x01, 3, 0, 3, 0 }, invalid[16..22]);
    try testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, invalid[22..30], .little));
    try testing.expectEqual(@as(u64, 257), std.mem.readInt(u64, invalid[30..38], .little));
}
