//! Compression scheme 50000 (ZSTD-in-TIFF, GDAL/libtiff extension).
//!
//! Each strip/tile is an independent ZSTD frame; we hand the whole
//! compressed buffer to ZSTD_decompress and write the result into the
//! caller-owned destination buffer.
//!
//! Backed by pmarreck/zstdz, which vendors the Facebook zstd C library
//! and exposes a thin Zig wrapper with the C API reachable as `zstd.c.*`.

const std = @import("std");
const zstd = @import("zstd");

const errors = @import("../errors.zig");

/// Decode one ZSTD strip/tile into `dest`. `src` is the on-disk
/// compressed byte stream; `dest` must be at least the expected
/// uncompressed strip size (validated by the caller).
///
/// Returns the number of bytes written to `dest`.
pub fn decode(src: []const u8, dest: []u8) errors.Error!usize {
    const written = zstd.c.ZSTD_decompress(
        @ptrCast(dest.ptr),
        dest.len,
        @ptrCast(src.ptr),
        src.len,
    );
    if (zstd.c.ZSTD_isError(written) != 0) {
        // zstd reports a wide range of decompression errors via its
        // ZSTD_ErrorCode enum. tiffz collapses them all to Malformed
        // (the codec found the input structurally invalid). A future
        // findings-callback pass can preserve the specific error name
        // for routing — at v1 we just refuse the file.
        return error.Malformed;
    }
    if (written > dest.len) return error.DestTooSmall;
    return written;
}

// ---- tests ----

test "zstd.decode: round-trips a small payload" {
    const allocator = std.testing.allocator;
    const original = "The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog.";
    // Compress with the C API to manufacture a valid frame.
    const max_compressed = zstd.c.ZSTD_compressBound(original.len);
    const compressed = try allocator.alloc(u8, max_compressed);
    defer allocator.free(compressed);
    const compressed_len = zstd.c.ZSTD_compress(
        @ptrCast(compressed.ptr),
        compressed.len,
        @ptrCast(original.ptr),
        original.len,
        3, // default compression level
    );
    try std.testing.expect(zstd.c.ZSTD_isError(compressed_len) == 0);

    var dest_buf: [256]u8 = undefined;
    const n = try decode(compressed[0..compressed_len], &dest_buf);
    try std.testing.expectEqualSlices(u8, original, dest_buf[0..n]);
}

test "zstd.decode: rejects corrupted frame" {
    // Random bytes that don't look like a zstd frame header.
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0xCA, 0xFE };
    var dest_buf: [32]u8 = undefined;
    try std.testing.expectError(error.Malformed, decode(&garbage, &dest_buf));
}
