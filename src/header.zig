//! TIFF header parser. The first 8 bytes of every TIFF file:
//!
//!   bytes 0-1  byte order: "II" (0x4949) = little, "MM" (0x4D4D) = big
//!   bytes 2-3  magic: 42 (classic TIFF) or 43 (BigTIFF) in declared endian
//!   bytes 4-7  offset to IFD0 (in declared endian)
//!
//! BigTIFF (magic=43) extends the header to 16 bytes — bytes 4-5 carry
//! offset width (always 8), 6-7 are reserved, and 8-15 are the IFD0
//! offset as u64. We parse the magic but currently reject BigTIFF
//! (UnsupportedCompression-equivalent at higher level); BigTIFF lands
//! in M7 with a comptime offset-width abstraction.

const std = @import("std");

const errors = @import("errors.zig");
const Source = @import("source.zig").Source;

pub const Endian = enum { little, big };

pub const Header = struct {
    endian: Endian,
    bigtiff: bool,
    /// Byte offset to IFD0. For classic TIFF this is u32; for BigTIFF
    /// it's u64. Stored widened so downstream code can treat them the
    /// same.
    ifd0_offset: u64,
};

/// Parse the 8-byte (classic) or 16-byte (BigTIFF) header from a Source.
/// Returns Malformed if magic / byte order / structure is invalid;
/// SourceTooShort if the source is shorter than the header.
pub fn parse(source: Source) errors.Error!Header {
    var buf: [16]u8 = undefined;
    // Read 8 bytes minimum; we'll try to grab the BigTIFF tail too,
    // but tolerate short reads on classic TIFF where bytes 8-15
    // legitimately don't exist or are part of the IFD payload.
    const n = source.readAt(buf[0..], 0) catch return error.Io;
    if (n < 8) return error.SourceTooShort;

    const endian: Endian = if (buf[0] == 'I' and buf[1] == 'I')
        .little
    else if (buf[0] == 'M' and buf[1] == 'M')
        .big
    else
        return error.Malformed;

    const magic = readU16(buf[2..4], endian);
    return switch (magic) {
        42 => .{
            .endian = endian,
            .bigtiff = false,
            .ifd0_offset = readU32(buf[4..8], endian),
        },
        43 => parseBigTiffTail(buf[0..n], endian),
        else => error.Malformed,
    };
}

fn parseBigTiffTail(buf: []const u8, endian: Endian) errors.Error!Header {
    if (buf.len < 16) return error.SourceTooShort;
    // bytes 4-5: offset byte size (must be 8); bytes 6-7: reserved (must be 0).
    const offset_bytes = readU16(buf[4..6], endian);
    const reserved = readU16(buf[6..8], endian);
    if (offset_bytes != 8 or reserved != 0) return error.Malformed;
    return .{
        .endian = endian,
        .bigtiff = true,
        .ifd0_offset = readU64(buf[8..16], endian),
    };
}

pub fn readU16(bytes: []const u8, endian: Endian) u16 {
    std.debug.assert(bytes.len >= 2);
    return switch (endian) {
        .little => std.mem.readInt(u16, bytes[0..2], .little),
        .big => std.mem.readInt(u16, bytes[0..2], .big),
    };
}

pub fn readU32(bytes: []const u8, endian: Endian) u32 {
    std.debug.assert(bytes.len >= 4);
    return switch (endian) {
        .little => std.mem.readInt(u32, bytes[0..4], .little),
        .big => std.mem.readInt(u32, bytes[0..4], .big),
    };
}

pub fn readU64(bytes: []const u8, endian: Endian) u64 {
    std.debug.assert(bytes.len >= 8);
    return switch (endian) {
        .little => std.mem.readInt(u64, bytes[0..8], .little),
        .big => std.mem.readInt(u64, bytes[0..8], .big),
    };
}

// ---- tests ----

const BufferHandle = @import("source.zig").BufferHandle;

fn sourceFromBytes(handle: *BufferHandle, bytes: []const u8) Source {
    handle.* = BufferHandle.init(bytes);
    return Source.fromBuffer(handle);
}

test "parse: classic TIFF, little-endian" {
    var handle: BufferHandle = undefined;
    const bytes = [_]u8{
        'I', 'I',
        0x2A, 0x00, // magic 42, little-endian
        0x08, 0x00, 0x00, 0x00, // ifd0_offset = 8
    };
    const h = try parse(sourceFromBytes(&handle, &bytes));
    try std.testing.expectEqual(Endian.little, h.endian);
    try std.testing.expectEqual(false, h.bigtiff);
    try std.testing.expectEqual(@as(u64, 8), h.ifd0_offset);
}

test "parse: classic TIFF, big-endian" {
    var handle: BufferHandle = undefined;
    const bytes = [_]u8{
        'M', 'M',
        0x00, 0x2A, // magic 42, big-endian
        0x00, 0x00, 0x00, 0x10, // ifd0_offset = 16
    };
    const h = try parse(sourceFromBytes(&handle, &bytes));
    try std.testing.expectEqual(Endian.big, h.endian);
    try std.testing.expectEqual(false, h.bigtiff);
    try std.testing.expectEqual(@as(u64, 16), h.ifd0_offset);
}

test "parse: BigTIFF, little-endian" {
    var handle: BufferHandle = undefined;
    const bytes = [_]u8{
        'I', 'I',
        0x2B, 0x00, // magic 43
        0x08, 0x00, // offset-byte-size = 8
        0x00, 0x00, // reserved = 0
        0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // ifd0_offset = 16
    };
    const h = try parse(sourceFromBytes(&handle, &bytes));
    try std.testing.expectEqual(Endian.little, h.endian);
    try std.testing.expectEqual(true, h.bigtiff);
    try std.testing.expectEqual(@as(u64, 16), h.ifd0_offset);
}

test "parse: malformed byte-order marker rejected" {
    var handle: BufferHandle = undefined;
    const bytes = [_]u8{ 'X', 'Y', 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00 };
    try std.testing.expectError(
        error.Malformed,
        parse(sourceFromBytes(&handle, &bytes)),
    );
}

test "parse: wrong magic rejected" {
    var handle: BufferHandle = undefined;
    const bytes = [_]u8{ 'I', 'I', 0xAA, 0xBB, 0x08, 0x00, 0x00, 0x00 };
    try std.testing.expectError(
        error.Malformed,
        parse(sourceFromBytes(&handle, &bytes)),
    );
}

test "parse: BigTIFF with wrong offset-byte-size rejected" {
    var handle: BufferHandle = undefined;
    const bytes = [_]u8{
        'I', 'I',
        0x2B, 0x00,
        0x04, 0x00, // offset-byte-size = 4 (must be 8)
        0x00, 0x00,
        0x10, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    try std.testing.expectError(
        error.Malformed,
        parse(sourceFromBytes(&handle, &bytes)),
    );
}

test "parse: source shorter than 8 bytes is rejected" {
    var handle: BufferHandle = undefined;
    const bytes = [_]u8{ 'I', 'I', 0x2A, 0x00 };
    try std.testing.expectError(
        error.SourceTooShort,
        parse(sourceFromBytes(&handle, &bytes)),
    );
}

test "parse: BigTIFF magic but only classic-length input is rejected" {
    var handle: BufferHandle = undefined;
    const bytes = [_]u8{ 'I', 'I', 0x2B, 0x00, 0x08, 0x00, 0x00, 0x00 };
    try std.testing.expectError(
        error.SourceTooShort,
        parse(sourceFromBytes(&handle, &bytes)),
    );
}
