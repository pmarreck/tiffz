//! M1.6 — JPEG 2000 decode wrap (openjpeg).
//!
//! Tests start TDD-red because `jpegz.jpeg2000.decode` is still a stub
//! returning `error.NotImplemented`. They go green when the openjpeg
//! wrapper lands in `src/ffi/openjpeg_wrapper.zig`.

const std = @import("std");
const jpegz = @import("jpegz");

/// 8×8 RGB JP2 file (lossy, 9/7 wavelet, 3 resolution levels).
/// Generated with `opj_compress -n 3 -r 5` from a uniform-color PPM.
const fixture_jp2_8x8_rgb = @embedFile("fixtures/jp2_8x8_rgb.jp2");

test "jpeg2000.decode 8x8 RGB JP2 produces an 8x8 RGB Image" {
    const allocator = std.testing.allocator;

    var image = try jpegz.jpeg2000.decode(allocator, fixture_jp2_8x8_rgb);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 8), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
    try std.testing.expectEqual(@as(usize, 8 * 8 * 3), image.pixels.len);

    // Source was a uniform color (R=0x80, G=0x40, B=0xA0). Lossy at -r 5
    // is mild compression; pixel (0,0) should be close to input.
    const r = image.pixels[0];
    const g = image.pixels[1];
    const b = image.pixels[2];
    try std.testing.expect(@abs(@as(i16, r) - 0x80) < 16);
    try std.testing.expect(@abs(@as(i16, g) - 0x40) < 16);
    try std.testing.expect(@abs(@as(i16, b) - 0xA0) < 16);
}

/// 8×8 RGB JP2 lossless (reversible 5/3 wavelet).
const fixture_jp2_lossless_5x3 = @embedFile("fixtures/jp2_8x8_lossless_5x3.jp2");

test "jpeg2000.decode 8x8 RGB lossless 5/3 wavelet" {
    const allocator = std.testing.allocator;
    var image = try jpegz.jpeg2000.decode(allocator, fixture_jp2_lossless_5x3);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 8), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);

    // Lossless: every pixel must round-trip exactly to (0x80, 0x40, 0xA0).
    var i: usize = 0;
    while (i < image.pixels.len) : (i += 3) {
        try std.testing.expectEqual(@as(u8, 0x80), image.pixels[i]);
        try std.testing.expectEqual(@as(u8, 0x40), image.pixels[i + 1]);
        try std.testing.expectEqual(@as(u8, 0xA0), image.pixels[i + 2]);
    }
}

/// 8×8 RGB JP2 lossy 9/7 wavelet (irreversible).
const fixture_jp2_lossy_9x7 = @embedFile("fixtures/jp2_8x8_lossy_9x7.jp2");

test "jpeg2000.decode 8x8 RGB lossy 9/7 wavelet" {
    const allocator = std.testing.allocator;
    var image = try jpegz.jpeg2000.decode(allocator, fixture_jp2_lossy_9x7);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 8), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    // Lossy at -r 5: should land within 16/255 of input on every channel.
    try std.testing.expect(@abs(@as(i16, image.pixels[0]) - 0x80) < 16);
    try std.testing.expect(@abs(@as(i16, image.pixels[1]) - 0x40) < 16);
    try std.testing.expect(@abs(@as(i16, image.pixels[2]) - 0xA0) < 16);
}

/// T1.6: 8×8 RGB JP2 with all components at dx=2, dy=2 (subsampled
/// internally; canvas is 8×8). Generated via ImageMagick
/// `convert ... -sampling-factor 4:2:0`. The current wrapper uses
/// `comps[0].w/h` for output dimensions, which reports 4×4 instead
/// of the actual 8×8 canvas. opj_decompress correctly emits 8×8 PPM.
const fixture_jp2_8x8_subsampled = @embedFile("fixtures/jp2_8x8_subsampled.jp2");

test "jpeg2000.decode 8x8 RGB JP2 with subsampled components (canvas size)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.jpeg2000.decode(allocator, fixture_jp2_8x8_subsampled);
    defer image.deinit(allocator);

    // Canvas is 8×8; components are 4×4 (dx=2,dy=2). Wrapper must
    // report canvas dims, not component dims.
    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 8), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(@as(usize, 8 * 8 * 3), image.pixels.len);
}

/// T1.6 hard case: 8×8 RGB JP2 with asymmetric chroma subsampling
/// (Y at dx=1/dy=1, Cb/Cr at dx=2/dy=2 — true 4:2:0). Generated via
/// ffmpeg `-pix_fmt yuv420p -c:v jpeg2000`. The current wrapper
/// errors with BackendError because its all-comps-must-be-same-size
/// check fires. Implementation needs nearest-neighbor upsample of
/// subsampled components to canvas dims.
const fixture_jp2_8x8_yuv420_asym = @embedFile("fixtures/jp2_8x8_yuv420_asym.jp2");

test "jpeg2000.decode 8x8 RGB JP2 with asymmetric 4:2:0 chroma subsampling" {
    const allocator = std.testing.allocator;
    var image = try jpegz.jpeg2000.decode(allocator, fixture_jp2_8x8_yuv420_asym);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 8), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(@as(usize, 8 * 8 * 3), image.pixels.len);
}

test "jpeg2000.decode rejects empty input" {
    const empty: []const u8 = &[_]u8{};
    try std.testing.expectError(
        error.TruncatedStream,
        jpegz.jpeg2000.decode(std.testing.allocator, empty),
    );
}

test "jpeg2000.decode rejects non-JP2 input" {
    const garbage = "this is not a JPEG 2000 file at all";
    try std.testing.expectError(
        error.InvalidJp2Codestream,
        jpegz.jpeg2000.decode(std.testing.allocator, garbage),
    );
}
