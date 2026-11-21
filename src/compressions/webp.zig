//! Compression scheme 50001 (WebP; libtiff tif_webp.c, written by GDAL and
//! libtiff's tiffcp -c webp).
//!
//! Each strip or tile is one complete WebP file (a RIFF container), lossy
//! (VP8) or lossless (VP8L), whose dimensions equal the strip's or tile's.
//! The raster is 8-bit unsigned, chunky, with 3 (RGB) or 4 (RGBA) samples.
//! As in libtiff, a WebP without alpha is accepted in a 4-sample raster
//! (the alpha channel decodes as fully opaque); every other band mismatch,
//! a size mismatch or an animated WebP is Malformed.
//!
//! Backed by libwebp 1.6.0 (BSD-3-Clause), decoder only, built by
//! deps/libwebp from the pinned upstream release.

const std = @import("std");
const webp = @import("webp").c;

const errors = @import("tiffz-parser").errors;

/// Decode one WebP strip or tile of `width` x `rows` pixels with `samples`
/// (3 or 4) 8-bit samples into `dest`. Returns the bytes written,
/// width * rows * samples.
pub fn decode(src: []const u8, dest: []u8, width: u32, rows: u32, samples: u16) errors.Error!usize {
    if (samples != 3 and samples != 4) return error.Malformed;
    var features: webp.WebPBitstreamFeatures = undefined;
    if (webp.WebPGetFeatures(src.ptr, src.len, &features) != webp.VP8_STATUS_OK) return error.Malformed;
    if (features.has_animation != 0) return error.Malformed;
    if (features.width <= 0 or features.height <= 0) return error.Malformed;
    if (@as(u32, @intCast(features.width)) != width or @as(u32, @intCast(features.height)) != rows) return error.Malformed;
    const bands: u16 = if (features.has_alpha != 0) 4 else 3;
    if (bands != samples and !(bands == 3 and samples == 4)) return error.Malformed;

    const stride = std.math.mul(usize, width, samples) catch return error.Malformed;
    const size = std.math.mul(usize, stride, rows) catch return error.Malformed;
    if (dest.len < size) return error.DestTooSmall;
    const out = if (samples == 4)
        webp.WebPDecodeRGBAInto(src.ptr, src.len, dest.ptr, size, @intCast(stride))
    else
        webp.WebPDecodeRGBInto(src.ptr, src.len, dest.ptr, size, @intCast(stride));
    if (out == null) return error.Malformed;
    return size;
}

// ---- tests ----
//
// Vectors made with libwebp 1.6.0's cwebp -lossless -exact from 4x2 images:
// pixel i (row-major) is R = 30i, G = 255 - 20i, B = 53i mod 256, and in
// rgba_webp A = 40 + 25i.

const rgb_webp = [_]u8{ 0x52, 0x49, 0x46, 0x46, 0x30, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x4c, 0x24, 0x00, 0x00, 0x00, 0x2f, 0x03, 0x40, 0x00, 0x00, 0x3f, 0xa0, 0x90, 0x6d, 0x04, 0xc8, 0xdf, 0x75, 0x0e, 0xf7, 0x42, 0x8c, 0xc7, 0xd4, 0xcc, 0x7f, 0x8a, 0xec, 0x21, 0x10, 0x20, 0x63, 0x0b, 0x5a, 0xb4, 0x68, 0x11, 0xd1, 0xff, 0xc0, 0x06 };
const rgba_webp = [_]u8{ 0x52, 0x49, 0x46, 0x46, 0x32, 0x00, 0x00, 0x00, 0x57, 0x45, 0x42, 0x50, 0x56, 0x50, 0x38, 0x4c, 0x25, 0x00, 0x00, 0x00, 0x2f, 0x03, 0x40, 0x00, 0x10, 0x3f, 0xa0, 0x90, 0x6d, 0x04, 0xc8, 0xdf, 0x75, 0x0e, 0xf7, 0x42, 0x8c, 0xc7, 0xd4, 0x3c, 0x03, 0x25, 0x45, 0xf6, 0x10, 0x08, 0x90, 0xb1, 0x05, 0x2d, 0x5a, 0xb4, 0x88, 0xe8, 0x7f, 0x60, 0x03, 0x00 };

fn expectPixels(dest: []const u8, samples: u16, alpha: ?u8) !void {
    for (0..8) |i| {
        const p = dest[i * samples ..][0..samples];
        try std.testing.expectEqual(@as(u8, @intCast((30 * i) & 0xff)), p[0]);
        try std.testing.expectEqual(@as(u8, @intCast(255 - 20 * i)), p[1]);
        try std.testing.expectEqual(@as(u8, @intCast((53 * i) % 256)), p[2]);
        if (samples == 4) try std.testing.expectEqual(alpha orelse @as(u8, @intCast(40 + 25 * i)), p[3]);
    }
}

test "webp.decode: lossless RGB and RGBA strips decode to their exact pixels" {
    var dest: [32]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 24), try decode(&rgb_webp, &dest, 4, 2, 3));
    try expectPixels(&dest, 3, null);
    try std.testing.expectEqual(@as(usize, 32), try decode(&rgba_webp, &dest, 4, 2, 4));
    try expectPixels(&dest, 4, null);
}

test "webp.decode: a WebP without alpha in a 4-sample raster decodes opaque, as libtiff accepts" {
    var dest: [32]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 32), try decode(&rgb_webp, &dest, 4, 2, 4));
    try expectPixels(&dest, 4, 0xff);
}

test "webp.decode: alpha in a 3-sample raster, a size mismatch, or a truncated file is Malformed" {
    var dest: [64]u8 = undefined;
    try std.testing.expectError(error.Malformed, decode(&rgba_webp, &dest, 4, 2, 3));
    try std.testing.expectError(error.Malformed, decode(&rgb_webp, &dest, 4, 3, 3));
    try std.testing.expectError(error.Malformed, decode(&rgb_webp, &dest, 2, 2, 3));
    try std.testing.expectError(error.Malformed, decode(rgb_webp[0 .. rgb_webp.len - 4], &dest, 4, 2, 3));
    try std.testing.expectError(error.Malformed, decode("RIFF\x00\x00\x00\x00WEBPjunk", &dest, 4, 2, 3));
}

test "webp.decode: a destination smaller than the strip is DestTooSmall" {
    var small: [23]u8 = undefined;
    try std.testing.expectError(error.DestTooSmall, decode(&rgb_webp, &small, 4, 2, 3));
}
