//! Compression scheme 34925 (LZMA2 in the .xz container; libtiff
//! tif_lzma.c, written by GDAL and libtiff's tiffcp -c lzma).
//!
//! Each strip or tile is one complete .xz stream. libtiff writes the filter
//! chain Delta then LZMA2 with no integrity check (LZMA_CHECK_NONE); other
//! writers may declare CRC32, CRC64 or SHA-256, and a declared check that
//! fails is a decode failure, not a pass.
//!
//! Backed by liblzma (xz 5.8.3, 0BSD), decoder subset, built by
//! deps/liblzma from the pinned upstream release. Zig 0.16's
//! std.compress.xz was ruled out: it rejects multi-filter blocks such as
//! libtiff's Delta + LZMA2, does not verify block checks, and panics in
//! `discard`.

const std = @import("std");
const lzma = @import("lzma").c;

const errors = @import("tiffz-parser").errors;

/// Decode one .xz stream from `src` into `dest`, allowing liblzma at most
/// `memlimit` bytes (the decoder's `max_codec_scratch`). Returns the bytes
/// written. The stream must fill `src` exactly: bytes after the stream
/// footer are Malformed, and output that would exceed `dest` is
/// DestTooSmall.
pub fn decode(src: []const u8, dest: []u8, memlimit: u64) errors.Error!usize {
    var limit: u64 = memlimit;
    var in_pos: usize = 0;
    var out_pos: usize = 0;
    const ret = lzma.lzma_stream_buffer_decode(
        &limit,
        lzma.LZMA_TELL_UNSUPPORTED_CHECK,
        null,
        src.ptr,
        &in_pos,
        src.len,
        dest.ptr,
        &out_pos,
        dest.len,
    );
    return switch (ret) {
        lzma.LZMA_OK => if (in_pos != src.len) error.Malformed else out_pos,
        // liblzma restores both positions on error, so they cannot tell a
        // full `dest` from a truncated stream; isOutputFull decides.
        lzma.LZMA_BUF_ERROR => if (isOutputFull(src, dest.len, memlimit)) error.DestTooSmall else error.Malformed,
        lzma.LZMA_FORMAT_ERROR, lzma.LZMA_DATA_ERROR => error.Malformed,
        // A filter this build lacks (BCJ and the like) or a reserved check.
        lzma.LZMA_OPTIONS_ERROR, lzma.LZMA_UNSUPPORTED_CHECK => error.UnsupportedCompression,
        lzma.LZMA_MEMLIMIT_ERROR => error.LimitExceededCodecScratch,
        lzma.LZMA_MEM_ERROR => error.OutOfMemory,
        else => error.Bug,
    };
}

/// LZMA_BUF_ERROR means either "dest too small" or "input ended early";
/// liblzma does not say which. Decode again into a sink one byte larger: if
/// it then gets past `dest_len`, the output really was longer than `dest`.
fn isOutputFull(src: []const u8, dest_len: usize, memlimit: u64) bool {
    var strm: lzma.lzma_stream = std.mem.zeroes(lzma.lzma_stream);
    if (lzma.lzma_stream_decoder(&strm, memlimit, 0) != lzma.LZMA_OK) return false;
    defer lzma.lzma_end(&strm);
    var sink: [4096]u8 = undefined;
    var total: usize = 0;
    strm.next_in = src.ptr;
    strm.avail_in = src.len;
    while (true) {
        strm.next_out = &sink;
        strm.avail_out = sink.len;
        const r = lzma.lzma_code(&strm, lzma.LZMA_FINISH);
        total += sink.len - strm.avail_out;
        if (total > dest_len) return true;
        if (r != lzma.LZMA_OK) return false;
    }
}

// ---- tests ----
//
// Vectors made with xz 5.8.3 from the 67-byte `payload`:
//   crc64_xz: --check=crc64 --delta=dist=1 --lzma2=preset=6 (libtiff's chain)
//   none_xz:  --check=none  --delta=dist=1 --lzma2=preset=6 (libtiff's check)
//   sha_xz:   --check=sha256, LZMA2 alone
// The CRC64 field of crc64_xz is bytes 84..92.

const crc64_xz = [_]u8{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00, 0x00, 0x04, 0xe6, 0xd6, 0xb4, 0x46, 0x04, 0xc1, 0x32, 0x43, 0x03, 0x01, 0x00, 0x21, 0x01, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3a, 0x18, 0xcc, 0xa4, 0xe0, 0x00, 0x42, 0x00, 0x2a, 0x5d, 0x00, 0x3a, 0x3d, 0x5b, 0xa0, 0x00, 0xa2, 0x72, 0xcb, 0x96, 0x86, 0x46, 0xb5, 0x39, 0x5e, 0xe1, 0xbc, 0x2c, 0xdc, 0x47, 0x50, 0xdf, 0x37, 0x15, 0x79, 0xb0, 0x15, 0xb0, 0x48, 0xdd, 0x7d, 0x39, 0x5f, 0xd8, 0xab, 0xd2, 0xcb, 0x52, 0xb8, 0xbf, 0xfb, 0x58, 0x00, 0x00, 0x00, 0x00, 0x50, 0x2b, 0x39, 0x87, 0x92, 0x09, 0x84, 0x4a, 0x00, 0x01, 0x4e, 0x43, 0x8a, 0xc7, 0xa9, 0xa1, 0x1f, 0xb6, 0xf3, 0x7d, 0x01, 0x00, 0x00, 0x00, 0x00, 0x04, 0x59, 0x5a };
const none_xz = [_]u8{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00, 0x00, 0x00, 0xff, 0x12, 0xd9, 0x41, 0x04, 0xc1, 0x32, 0x43, 0x03, 0x01, 0x00, 0x21, 0x01, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x3a, 0x18, 0xcc, 0xa4, 0xe0, 0x00, 0x42, 0x00, 0x2a, 0x5d, 0x00, 0x3a, 0x3d, 0x5b, 0xa0, 0x00, 0xa2, 0x72, 0xcb, 0x96, 0x86, 0x46, 0xb5, 0x39, 0x5e, 0xe1, 0xbc, 0x2c, 0xdc, 0x47, 0x50, 0xdf, 0x37, 0x15, 0x79, 0xb0, 0x15, 0xb0, 0x48, 0xdd, 0x7d, 0x39, 0x5f, 0xd8, 0xab, 0xd2, 0xcb, 0x52, 0xb8, 0xbf, 0xfb, 0x58, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x46, 0x43, 0x82, 0x4d, 0x70, 0x69, 0x06, 0x72, 0x9e, 0x7a, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x59, 0x5a };
const sha_xz = [_]u8{ 0xfd, 0x37, 0x7a, 0x58, 0x5a, 0x00, 0x00, 0x0a, 0xe1, 0xfb, 0x0c, 0xa1, 0x04, 0xc0, 0x39, 0x43, 0x21, 0x01, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x7d, 0x73, 0x9b, 0xd1, 0xe0, 0x00, 0x42, 0x00, 0x31, 0x5d, 0x00, 0x3a, 0x1a, 0x49, 0x0a, 0x25, 0x8e, 0xc4, 0x09, 0x8c, 0x2b, 0xef, 0x46, 0xe5, 0x4c, 0x7b, 0x36, 0x9d, 0x98, 0x6d, 0xe4, 0xd9, 0x5c, 0xbe, 0x94, 0xaa, 0x85, 0x5a, 0x19, 0xaa, 0xef, 0x3f, 0x5c, 0xbb, 0x93, 0x21, 0x06, 0xc2, 0x0f, 0x72, 0x64, 0xee, 0x4d, 0xf5, 0xf2, 0x7d, 0x2b, 0x8d, 0xd1, 0x00, 0x00, 0x00, 0x00, 0x00, 0x88, 0x2a, 0xaa, 0x05, 0xf3, 0x7d, 0x4a, 0xd4, 0x11, 0x09, 0xec, 0x0a, 0x20, 0x22, 0x3b, 0xab, 0x36, 0xb4, 0xce, 0x45, 0x88, 0xb6, 0xeb, 0x95, 0x9e, 0xb5, 0xa0, 0xce, 0xfd, 0x39, 0xeb, 0x8f, 0x00, 0x01, 0x6d, 0x43, 0xeb, 0xb0, 0x00, 0x1f, 0x18, 0x9b, 0x4b, 0x9a, 0x01, 0x00, 0x00, 0x00, 0x00, 0x0a, 0x59, 0x5a };
const payload = "tiffz lzma test payload, tiffz lzma test payload, 0123456789abcdef\n";

const test_memlimit: u64 = 256 << 20;

test "lzma.decode: libtiff's Delta + LZMA2 chain, with CRC64, no check and SHA-256" {
    inline for (.{ &crc64_xz, &none_xz, &sha_xz }) |v| {
        var dest: [payload.len]u8 = undefined;
        const n = try decode(v, &dest, test_memlimit);
        try std.testing.expectEqualStrings(payload, dest[0..n]);
    }
}

test "lzma.decode: a damaged CRC64 fails even though the data decodes" {
    var bad = crc64_xz;
    bad[84] ^= 0x01;
    var dest: [payload.len]u8 = undefined;
    try std.testing.expectError(error.Malformed, decode(&bad, &dest, test_memlimit));
}

test "lzma.decode: output longer than dest is DestTooSmall; a truncated stream is Malformed" {
    var small: [payload.len - 1]u8 = undefined;
    try std.testing.expectError(error.DestTooSmall, decode(&crc64_xz, &small, test_memlimit));
    var dest: [payload.len]u8 = undefined;
    try std.testing.expectError(error.Malformed, decode(crc64_xz[0 .. crc64_xz.len - 13], &dest, test_memlimit));
}

test "lzma.decode: bytes after the stream, and a non-xz strip, are Malformed" {
    var dest: [payload.len]u8 = undefined;
    const trailing = crc64_xz ++ [_]u8{0};
    try std.testing.expectError(error.Malformed, decode(&trailing, &dest, test_memlimit));
    try std.testing.expectError(error.Malformed, decode("not an xz stream at all", &dest, test_memlimit));
}

test "lzma.decode: a dictionary above the memory limit is LimitExceededCodecScratch" {
    var dest: [payload.len]u8 = undefined;
    try std.testing.expectError(error.LimitExceededCodecScratch, decode(&crc64_xz, &dest, 1 << 20));
}
