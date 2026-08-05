//! Compression scheme 1 (None / Uncompressed). Strip bytes on disk
//! are the raw decoded pixel bytes; "decode" is just a memcpy from
//! Source.read_at into the caller's dest.

const std = @import("std");

const parser = @import("tiffz-parser");
const errors = parser.errors;
const Source = parser.Source;

/// Read `byte_count` bytes from `source` at `offset` into `dest`.
/// Returns the number of bytes written. dest.len must be ≥ byte_count.
pub fn decode(
    source: Source,
    offset: u64,
    byte_count: u32,
    dest: []u8,
) errors.Error!usize {
    if (byte_count > dest.len) return error.DestTooSmall;
    const n = source.readAt(dest[0..byte_count], offset) catch return error.Io;
    if (n < byte_count) return error.SourceShortRead;
    return n;
}

test "none.decode: round-trips a slice of the source" {
    const BufferHandle = parser.source.BufferHandle;

    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x42, 0x13, 0x37 };
    var handle = BufferHandle.init(&data);
    const src = Source.fromBuffer(&handle);

    var dest: [16]u8 = undefined;
    const n = try decode(src, 2, 4, &dest);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualSlices(u8, &.{ 0xBE, 0xEF, 0x42, 0x13 }, dest[0..4]);
}

test "none.decode: rejects undersized dest" {
    const BufferHandle = parser.source.BufferHandle;
    const data = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    var handle = BufferHandle.init(&data);
    const src = Source.fromBuffer(&handle);

    var dest: [2]u8 = undefined;
    try std.testing.expectError(error.DestTooSmall, decode(src, 0, 4, &dest));
}

test "none.decode: short read at EOF surfaces SourceShortRead" {
    const BufferHandle = parser.source.BufferHandle;
    const data = [_]u8{ 0x01, 0x02 };
    var handle = BufferHandle.init(&data);
    const src = Source.fromBuffer(&handle);

    var dest: [10]u8 = undefined;
    try std.testing.expectError(error.SourceShortRead, decode(src, 0, 5, &dest));
}
