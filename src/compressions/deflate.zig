//! Deflate compression (TIFF compression=8 / compression=32946).
//!
//! TIFF stores DEFLATE-compressed strips as zlib-framed streams (with
//! the 2-byte zlib header and trailing 4-byte Adler-32) per TIFF/EP
//! and TIFF Technical Note 2. Compression code 8 was the original
//! "Deflate" tag; 32946 is "AdobeDeflate" — same bytes-on-disk
//! format, registered separately for legacy reasons. We treat them
//! identically.
//!
//! Backed by `allyourcodebase/zlib` (community Zig wrapper around
//! upstream C zlib, zlib license). Same dep validate ships with;
//! consistent with the project portfolio's posture. No Peter-fork
//! exists — falling back to upstream per the dogfood rule's order.
//!
//! The Zig std library does have `std.compress.flate` / `.zlib`,
//! but they have known correctness bugs (ziglang/zig#24963) per
//! validate's experience. We use the C library to side-step that.

const std = @import("std");

const errors = @import("tiffz-parser").errors;

const c = @cImport({
    @cInclude("zlib.h");
});

/// Decode zlib-framed deflate from `src` into `dest`. Returns bytes
/// written. TIFF compression=8 / compression=32946 → use this.
pub fn decode(src: []const u8, dest: []u8) errors.Error!usize {
    var stream: c.z_stream = .{
        .next_in = @constCast(src.ptr),
        .avail_in = @intCast(src.len),
        .next_out = dest.ptr,
        .avail_out = @intCast(dest.len),
        .zalloc = null,
        .zfree = null,
        .@"opaque" = null,
        .total_in = 0,
        .total_out = 0,
        .msg = null,
        .state = null,
        .data_type = 0,
        .adler = 0,
        .reserved = 0,
    };

    // windowBits = 15 selects zlib-framed format (with header + Adler-32).
    // Negative values would select raw deflate (TIFF doesn't use raw).
    const init_ret = c.inflateInit2(&stream, 15);
    if (init_ret != c.Z_OK) return error.Io;
    defer _ = c.inflateEnd(&stream);

    const ret = c.inflate(&stream, c.Z_FINISH);
    return switch (ret) {
        c.Z_STREAM_END => @intCast(stream.total_out),
        // Z_OK means the codec wants more output room — caller's dest is
        // too small. Z_BUF_ERROR is the same condition with no progress.
        c.Z_OK, c.Z_BUF_ERROR => error.DestTooSmall,
        c.Z_DATA_ERROR => error.Malformed,
        c.Z_MEM_ERROR => error.OutOfMemory,
        else => error.Bug,
    };
}

// ---- tests ----

test "deflate.decode: round-trips a known zlib-framed stream" {
    // "hello" zlib-compressed (the canonical 13-byte fixture libtiff
    // and others use for smoke tests).
    const compressed = [_]u8{
        0x78, 0x9c,
        0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07,
        0x00,
        0x06, 0x2c, 0x02, 0x15, // Adler-32 trailer
    };
    var dest: [16]u8 = undefined;
    const n = try decode(&compressed, &dest);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", dest[0..n]);
}

test "deflate.decode: dest too small surfaces DestTooSmall" {
    const compressed = [_]u8{
        0x78, 0x9c,
        0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07,
        0x00,
        0x06, 0x2c, 0x02, 0x15,
    };
    var dest: [2]u8 = undefined;
    try std.testing.expectError(error.DestTooSmall, decode(&compressed, &dest));
}

test "deflate.decode: garbage data surfaces Malformed" {
    const garbage = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    var dest: [16]u8 = undefined;
    try std.testing.expectError(error.Malformed, decode(&garbage, &dest));
}
