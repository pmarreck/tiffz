//! IFD (Image File Directory) parser.
//!
//! Per TIFF 6.0 §2 (sections 1-3), classic TIFF:
//!
//!   IFD = [u16 entry_count] [Entry × N] [u32 next_ifd_offset]
//!   Entry = [u16 tag] [u16 type] [u32 count] [u32 value_or_offset]
//!
//! The 4-byte value_or_offset slot holds the value inline if the
//! total value size (count × bytes-per-element) is ≤ 4; otherwise
//! it's an offset into the file where the values live.
//!
//! BigTIFF widens the wire format:
//!
//!   IFD = [u64 entry_count] [Entry × N] [u64 next_ifd_offset]
//!   Entry = [u16 tag] [u16 type] [u64 count] [u64 value_or_offset]
//!
//! The 8-byte value_or_offset slot raises the inline-fit cap to 8.
//! parse() takes an `OffsetWidth` discriminator and normalizes both
//! variants into the unified Entry shape (u64 count, [8]u8 slot).

const std = @import("std");
const Allocator = std.mem.Allocator;

const errors = @import("errors.zig");
const Limits = @import("limits.zig").Limits;
const Source = @import("source.zig").Source;
const header_mod = @import("header.zig");
const Endian = header_mod.Endian;

/// TIFF tag-value type codes per §2 + TIFF 6.0 Table 2 + BigTIFF
/// extensions (LONG8/SLONG8/IFD8 added 2002).
pub const FieldType = enum(u16) {
    byte = 1,
    ascii = 2,
    short = 3,
    long = 4,
    rational = 5,
    sbyte = 6,
    undefined = 7,
    sshort = 8,
    slong = 9,
    srational = 10,
    float = 11,
    double = 12,
    /// 8-byte unsigned integer. BigTIFF-only by spec; some classic
    /// TIFF writers emit it too (libtiff with BigTIFF flag).
    long8 = 16,
    /// 8-byte signed integer.
    slong8 = 17,
    /// 8-byte IFD offset (BigTIFF analogue of TIFF Tech Note 1's IFD = 13).
    ifd8 = 18,
    /// Anything outside the known set — we surface it but don't synthesize values.
    unknown = 0,

    pub fn fromU16(v: u16) FieldType {
        return switch (v) {
            1 => .byte,
            2 => .ascii,
            3 => .short,
            4 => .long,
            5 => .rational,
            6 => .sbyte,
            7 => .undefined,
            8 => .sshort,
            9 => .slong,
            10 => .srational,
            11 => .float,
            12 => .double,
            16 => .long8,
            17 => .slong8,
            18 => .ifd8,
            else => .unknown,
        };
    }

    /// Bytes per element for this field type. Returns 0 for unknown.
    pub fn elementBytes(self: FieldType) u8 {
        return switch (self) {
            .byte, .ascii, .sbyte, .undefined => 1,
            .short, .sshort => 2,
            .long, .slong, .float => 4,
            .rational, .srational, .double, .long8, .slong8, .ifd8 => 8,
            .unknown => 0,
        };
    }
};

/// Whether IFD offsets/counts in this file are 32-bit (classic TIFF)
/// or 64-bit (BigTIFF). Threads through the parser + readEntryValue
/// because the inline-fit slot width (4 vs 8 bytes) and out-of-line
/// pointer width follow from it.
pub const OffsetWidth = enum {
    classic,
    big,

    pub fn inlineCap(self: OffsetWidth) usize {
        return switch (self) {
            .classic => 4,
            .big => 8,
        };
    }

    pub fn pointerBytes(self: OffsetWidth) usize {
        return switch (self) {
            .classic => 4,
            .big => 8,
        };
    }
};

/// A single IFD entry — one row of the directory.
///
/// Storage shape is uniform across classic TIFF and BigTIFF: `count`
/// is widened to u64 (classic u32 zero-extends), and the inline value
/// slot is 8 bytes (classic uses only the low 4, zero-padded). The
/// per-entry overhead delta is negligible (~80 bytes per IFD) and the
/// uniform shape eliminates a sum-type ripple through every consumer.
pub const Entry = struct {
    tag: u16,
    field_type: FieldType,
    count: u64,
    /// Raw value/offset slot, in file byte order. Width is 8 bytes for
    /// BigTIFF; classic TIFF zero-fills bytes 4-7. Resolve via
    /// `readEntryValue` (handles inline-vs-offset and reads from the
    /// Source if needed).
    raw_value_or_offset: [8]u8,
};

pub const Ifd = struct {
    entries: []Entry,
    /// Offset of the next IFD in the chain, or 0 for the last IFD.
    next_offset: u64,
    /// Source offset width (4 bytes for classic TIFF, 8 for BigTIFF).
    /// Threaded through so consumers know the inline-fit cap.
    offset_width: OffsetWidth,
    allocator: Allocator,

    pub fn deinit(self: *Ifd) void {
        self.allocator.free(self.entries);
    }

    /// Look up an entry by tag number. Returns null if not present.
    /// Linear scan — IFDs are small (typically 10-50 entries).
    pub fn get(self: *const Ifd, tag: u16) ?*const Entry {
        for (self.entries) |*e| {
            if (e.tag == tag) return e;
        }
        return null;
    }

    /// Total bytes required for an entry's value array.
    pub fn entryValueBytes(entry: Entry) u64 {
        return @as(u64, entry.field_type.elementBytes()) * entry.count;
    }

    /// Read an entry's value bytes into `dest`. If the value fits
    /// inline (≤ inline-cap), returns the inline bytes from
    /// `raw_value_or_offset`. Otherwise dereferences the offset
    /// stored there (u32 for classic, u64 for BigTIFF) and reads
    /// from the Source.
    ///
    /// `dest.len` must equal `entryValueBytes(entry)`.
    pub fn readEntryValue(
        entry: Entry,
        endian: Endian,
        source: Source,
        offset_width: OffsetWidth,
        dest: []u8,
    ) errors.Error!void {
        const total = entryValueBytes(entry);
        if (total != dest.len) return error.InvalidArgument;

        if (total <= offset_width.inlineCap()) {
            std.mem.copyForwards(u8, dest, entry.raw_value_or_offset[0..@intCast(total)]);
            return;
        }
        const offset: u64 = switch (offset_width) {
            .classic => header_mod.readU32(entry.raw_value_or_offset[0..4], endian),
            .big => header_mod.readU64(&entry.raw_value_or_offset, endian),
        };
        const n = source.readAt(dest, offset) catch return error.Io;
        if (n < dest.len) return error.SourceShortRead;
    }
};

/// Parse the IFD at `offset` in the source. Allocates `entries`
/// from `allocator`; caller must `deinit()` the returned Ifd.
///
/// Wire format differs by offset_width:
///   classic: u16 entry_count + N × 12-byte entries + u32 next_offset
///   big:     u64 entry_count + N × 20-byte entries + u64 next_offset
/// Entries also differ: classic uses u32 count + 4-byte slot; big
/// uses u64 count + 8-byte slot. We normalize both into the unified
/// Entry shape (u64 count, [8]u8 slot) so consumers don't care.
pub fn parse(
    allocator: Allocator,
    source: Source,
    endian: Endian,
    offset: u64,
    limits: Limits,
    offset_width: OffsetWidth,
) errors.Error!Ifd {
    const count_bytes: usize = switch (offset_width) {
        .classic => 2,
        .big => 8,
    };
    const entry_bytes: usize = switch (offset_width) {
        .classic => 12,
        .big => 20,
    };

    var count_buf: [8]u8 = undefined;
    const got = source.readAt(count_buf[0..count_bytes], offset) catch return error.Io;
    if (got < count_bytes) return error.SourceTooShort;
    const entry_count_u64: u64 = switch (offset_width) {
        .classic => header_mod.readU16(count_buf[0..2], endian),
        .big => header_mod.readU64(count_buf[0..8], endian),
    };

    if (entry_count_u64 > limits.max_tags_per_ifd) {
        return error.LimitExceededTagCount;
    }
    // entry_count fits in u32 after the cap check.
    const entry_count: u32 = @intCast(entry_count_u64);

    const entries_bytes_total: u64 = @as(u64, entry_count) * entry_bytes;
    const entries = allocator.alloc(Entry, entry_count) catch return error.OutOfMemory;
    errdefer allocator.free(entries);

    // Read all entries in one shot. For very large IFDs this is much
    // friendlier on the source than per-entry reads.
    const entries_buf = allocator.alloc(u8, @intCast(entries_bytes_total)) catch return error.OutOfMemory;
    defer allocator.free(entries_buf);

    if (entries_bytes_total > 0) {
        const e_got = source.readAt(entries_buf, offset + count_bytes) catch return error.Io;
        if (e_got < entries_bytes_total) return error.SourceShortRead;
    }

    for (entries, 0..) |*entry, i| {
        const base = i * entry_bytes;
        var slot: [8]u8 = .{0} ** 8;
        switch (offset_width) {
            .classic => @memcpy(slot[0..4], entries_buf[base + 8 ..][0..4]),
            .big => @memcpy(&slot, entries_buf[base + 12 ..][0..8]),
        }
        entry.* = .{
            .tag = header_mod.readU16(entries_buf[base..][0..2], endian),
            .field_type = FieldType.fromU16(
                header_mod.readU16(entries_buf[base + 2 ..][0..2], endian),
            ),
            .count = switch (offset_width) {
                .classic => @as(u64, header_mod.readU32(entries_buf[base + 4 ..][0..4], endian)),
                .big => header_mod.readU64(entries_buf[base + 4 ..][0..8], endian),
            },
            .raw_value_or_offset = slot,
        };

        // Check tag value byte cap before any later read of the value array.
        // errdefer above handles cleanup of `entries` on the error path.
        if (Ifd.entryValueBytes(entry.*) > limits.max_tag_value_bytes) {
            return error.LimitExceededTagValueBytes;
        }
    }

    // After the entries: next_ifd_offset (u32 classic, u64 big).
    const next_bytes: usize = offset_width.pointerBytes();
    var next_buf: [8]u8 = undefined;
    const next_offset_pos = offset + count_bytes + entries_bytes_total;
    const n_got = source.readAt(next_buf[0..next_bytes], next_offset_pos) catch return error.Io;
    const next_offset: u64 = if (n_got < next_bytes) 0 else switch (offset_width) {
        .classic => @as(u64, header_mod.readU32(next_buf[0..4], endian)),
        .big => header_mod.readU64(next_buf[0..8], endian),
    };

    return .{
        .entries = entries,
        .next_offset = next_offset,
        .offset_width = offset_width,
        .allocator = allocator,
    };
}

// ---- tests ----

const BufferHandle = @import("source.zig").BufferHandle;

/// Build a minimal little-endian classic TIFF in memory:
///   header (8 bytes) + IFD0 (entry_count + N×12-byte entries + next_offset)
fn fakeTiff(comptime N: comptime_int, entries: [N][12]u8) [8 + 2 + N * 12 + 4]u8 {
    var out: [8 + 2 + N * 12 + 4]u8 = undefined;
    // Header: II 0x002A, ifd0_offset = 8
    out[0] = 'I';
    out[1] = 'I';
    out[2] = 0x2A;
    out[3] = 0x00;
    out[4] = 0x08;
    out[5] = 0x00;
    out[6] = 0x00;
    out[7] = 0x00;
    // entry_count
    out[8] = @intCast(N & 0xFF);
    out[9] = @intCast((N >> 8) & 0xFF);
    inline for (entries, 0..) |e, i| {
        @memcpy(out[10 + i * 12 ..][0..12], &e);
    }
    // next_offset = 0
    @memset(out[10 + N * 12 ..][0..4], 0);
    return out;
}

test "ifd.parse: zero entries returns empty IFD" {
    const bytes = fakeTiff(0, .{});

    var handle = BufferHandle.init(&bytes);
    const src = Source.fromBuffer(&handle);

    var ifd = try parse(std.testing.allocator, src, .little, 8, .{}, .classic);
    defer ifd.deinit();

    try std.testing.expectEqual(@as(usize, 0), ifd.entries.len);
    try std.testing.expectEqual(@as(u32, 0), ifd.next_offset);
}

test "ifd.parse: one entry with inline SHORT value" {
    // ImageWidth (256) tag=0x0100, type=SHORT (3), count=1, value=512 inline
    const entry: [12]u8 = .{
        0x00, 0x01, // tag = 256
        0x03, 0x00, // type = 3 (SHORT)
        0x01, 0x00, 0x00, 0x00, // count = 1
        0x00, 0x02, 0x00, 0x00, // value = 512 (low 2 bytes used for SHORT)
    };
    const bytes = fakeTiff(1, .{entry});

    var handle = BufferHandle.init(&bytes);
    const src = Source.fromBuffer(&handle);

    var ifd = try parse(std.testing.allocator, src, .little, 8, .{}, .classic);
    defer ifd.deinit();

    try std.testing.expectEqual(@as(usize, 1), ifd.entries.len);
    const e = ifd.get(256) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FieldType.short, e.field_type);
    try std.testing.expectEqual(@as(u64, 1), e.count);

    var value_bytes: [2]u8 = undefined;
    try Ifd.readEntryValue(e.*, .little, src, .classic, &value_bytes);
    try std.testing.expectEqual(@as(u16, 512), header_mod.readU16(&value_bytes, .little));
}

test "ifd.parse: tag count over limit is rejected" {
    // entry_count = 0x0003, but limits cap at 2.
    const entry: [12]u8 = .{0x00} ** 12;
    const bytes = fakeTiff(3, .{ entry, entry, entry });

    var handle = BufferHandle.init(&bytes);
    const src = Source.fromBuffer(&handle);

    const limits: Limits = .{ .max_tags_per_ifd = 2 };
    try std.testing.expectError(
        error.LimitExceededTagCount,
        parse(std.testing.allocator, src, .little, 8, limits, .classic),
    );
}

test "ifd.parse: tag value bytes over limit rejected" {
    // count = huge for SHORT (2 bytes each) → trivially blows the cap.
    const entry: [12]u8 = .{
        0x00, 0x01,
        0x03, 0x00, // SHORT (2 bytes/elem)
        0x00, 0x00, 0x10, 0x00, // count = 0x00100000 = 1048576
        0x00, 0x00, 0x00, 0x00,
    };
    const bytes = fakeTiff(1, .{entry});

    var handle = BufferHandle.init(&bytes);
    const src = Source.fromBuffer(&handle);

    const limits: Limits = .{ .max_tag_value_bytes = 1024 };
    try std.testing.expectError(
        error.LimitExceededTagValueBytes,
        parse(std.testing.allocator, src, .little, 8, limits, .classic),
    );
}

/// Build a minimal little-endian BigTIFF in memory:
///   header (16 bytes) + IFD0 (u64 entry_count + N×20-byte entries + u64 next_offset)
/// Header layout: II 0x002B / offset-byte-size=8 / reserved=0 / IFD0 offset @ 16.
fn fakeBigTiff(comptime N: comptime_int, entries: [N][20]u8) [16 + 8 + N * 20 + 8]u8 {
    var out: [16 + 8 + N * 20 + 8]u8 = .{0} ** (16 + 8 + N * 20 + 8);
    // Header — II 0x002B, offset-size=8, reserved=0, ifd0_offset=16.
    out[0] = 'I';
    out[1] = 'I';
    out[2] = 0x2B;
    out[3] = 0x00;
    out[4] = 0x08;
    out[5] = 0x00;
    out[6] = 0x00;
    out[7] = 0x00;
    out[8] = 0x10; // ifd0 offset = 16 (little-endian u64)
    // entry_count u64 at offset 16
    out[16] = @intCast(N & 0xFF);
    out[17] = @intCast((N >> 8) & 0xFF);
    inline for (entries, 0..) |e, i| {
        @memcpy(out[24 + i * 20 ..][0..20], &e);
    }
    // next_offset u64 (zero) after the entries
    return out;
}

test "ifd.parse: BigTIFF one entry with inline SHORT value (8-byte slot)" {
    // ImageWidth (256) tag=0x0100, type=SHORT (3), count=1, value=512
    // inline in the 8-byte value slot (low 2 bytes used for SHORT).
    const entry: [20]u8 = .{
        0x00, 0x01, // tag = 256
        0x03, 0x00, // type = 3 (SHORT)
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // count = 1 (u64)
        0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // value = 512 inline (low 2 bytes)
    };
    const bytes = fakeBigTiff(1, .{entry});

    var handle = BufferHandle.init(&bytes);
    const src = Source.fromBuffer(&handle);

    var ifd = try parse(std.testing.allocator, src, .little, 16, .{}, .big);
    defer ifd.deinit();

    try std.testing.expectEqual(@as(usize, 1), ifd.entries.len);
    const e = ifd.get(256) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FieldType.short, e.field_type);
    try std.testing.expectEqual(@as(u64, 1), e.count);

    var value_bytes: [2]u8 = undefined;
    try Ifd.readEntryValue(e.*, .little, src, .big, &value_bytes);
    try std.testing.expectEqual(@as(u16, 512), header_mod.readU16(&value_bytes, .little));
}

test "ifd.parse: BigTIFF inline-fit cap is 8 bytes, not 4" {
    // BitsPerSample tag=0x0102, type=SHORT, count=3 → 6 bytes total.
    // In classic TIFF this would need to be out-of-line (>4); in
    // BigTIFF it fits inline in the 8-byte value slot.
    const entry: [20]u8 = .{
        0x02, 0x01, // tag = 258
        0x03, 0x00, // type = SHORT
        0x03, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // count = 3 (u64)
        // 3 × u16 = 6 bytes inline: 8, 8, 8 (low 6 bytes of slot)
        0x08, 0x00, 0x08, 0x00, 0x08, 0x00, 0x00, 0x00,
    };
    const bytes = fakeBigTiff(1, .{entry});

    var handle = BufferHandle.init(&bytes);
    const src = Source.fromBuffer(&handle);

    var ifd = try parse(std.testing.allocator, src, .little, 16, .{}, .big);
    defer ifd.deinit();

    const e = ifd.get(258) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 3), e.count);
    try std.testing.expectEqual(@as(u64, 6), Ifd.entryValueBytes(e.*));

    var value_bytes: [6]u8 = undefined;
    try Ifd.readEntryValue(e.*, .little, src, .big, &value_bytes);
    try std.testing.expectEqual(@as(u16, 8), header_mod.readU16(value_bytes[0..2], .little));
    try std.testing.expectEqual(@as(u16, 8), header_mod.readU16(value_bytes[2..4], .little));
    try std.testing.expectEqual(@as(u16, 8), header_mod.readU16(value_bytes[4..6], .little));
}

test "ifd.parse: BigTIFF LONG8 element type recognized" {
    // A single LONG8 (type=16) value, e.g. a StripOffsets u64 inline.
    // tag = 273 (StripOffsets), type = 16, count = 1, value = 0x1234567890ABCDEF.
    const entry: [20]u8 = .{
        0x11, 0x01, // tag = 273
        0x10, 0x00, // type = 16 (LONG8)
        0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // count = 1
        0xEF, 0xCD, 0xAB, 0x90, 0x78, 0x56, 0x34, 0x12, // value (little-endian)
    };
    const bytes = fakeBigTiff(1, .{entry});

    var handle = BufferHandle.init(&bytes);
    const src = Source.fromBuffer(&handle);

    var ifd = try parse(std.testing.allocator, src, .little, 16, .{}, .big);
    defer ifd.deinit();

    const e = ifd.get(273) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(FieldType.long8, e.field_type);
    try std.testing.expectEqual(@as(u64, 1), e.count);
    try std.testing.expectEqual(@as(u8, 8), FieldType.long8.elementBytes());
}

test "ifd.parse: out-of-line value resolves through the source" {
    // BitsPerSample (258) tag=0x0102, type=SHORT, count=3 → 6 bytes (>4),
    // so value is an offset. Lay the values out at offset 0x40.
    const entry: [12]u8 = .{
        0x02, 0x01, // tag = 258 (BitsPerSample)
        0x03, 0x00, // type = SHORT
        0x03, 0x00, 0x00, 0x00, // count = 3
        0x40, 0x00, 0x00, 0x00, // offset = 0x40
    };

    // We can't use fakeTiff for the full picture because we need to
    // place 6 bytes at offset 0x40. Build manually.
    var bytes: [0x40 + 6]u8 = undefined;
    @memset(&bytes, 0);
    // header
    bytes[0] = 'I';
    bytes[1] = 'I';
    bytes[2] = 0x2A;
    bytes[3] = 0x00;
    bytes[4] = 0x08;
    bytes[5] = 0x00;
    bytes[6] = 0x00;
    bytes[7] = 0x00;
    // entry_count = 1
    bytes[8] = 0x01;
    bytes[9] = 0x00;
    // entry
    @memcpy(bytes[10..22], &entry);
    // next_offset (4 bytes, zero) at 22..26
    @memset(bytes[22..26], 0);
    // values: u16 8, u16 8, u16 8 little-endian
    bytes[0x40] = 0x08;
    bytes[0x41] = 0x00;
    bytes[0x42] = 0x08;
    bytes[0x43] = 0x00;
    bytes[0x44] = 0x08;
    bytes[0x45] = 0x00;

    var handle = BufferHandle.init(&bytes);
    const src = Source.fromBuffer(&handle);

    var ifd = try parse(std.testing.allocator, src, .little, 8, .{}, .classic);
    defer ifd.deinit();

    const e = ifd.get(258) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 3), e.count);
    try std.testing.expectEqual(@as(u64, 6), Ifd.entryValueBytes(e.*));

    var value_bytes: [6]u8 = undefined;
    try Ifd.readEntryValue(e.*, .little, src, .classic, &value_bytes);
    try std.testing.expectEqual(@as(u16, 8), header_mod.readU16(value_bytes[0..2], .little));
    try std.testing.expectEqual(@as(u16, 8), header_mod.readU16(value_bytes[2..4], .little));
    try std.testing.expectEqual(@as(u16, 8), header_mod.readU16(value_bytes[4..6], .little));
}
