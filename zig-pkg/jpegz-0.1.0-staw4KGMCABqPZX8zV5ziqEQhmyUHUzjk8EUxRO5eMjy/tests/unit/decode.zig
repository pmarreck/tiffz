//! M1.3 — baseline + progressive wrap (libjpeg-turbo).
//!
//! TDD-red marker: these tests fail today because `jpegz.decode` returns
//! `error.NotImplemented`. They go green when the libjpeg-turbo wrapper
//! lands in `src/ffi/libjpeg_wrapper.zig`.

const std = @import("std");
const jpegz = @import("jpegz");

/// 2×2 RGB baseline JPEG (Y'CbCr internally, decoded to RGB by libjpeg-turbo).
/// Generated via `cjpeg -quality 90 -baseline` from a 2×2 PPM with
/// red/green/blue/white pixels. Roughly 690 bytes.
const fixture_baseline_2x2_rgb = @embedFile("fixtures/baseline_2x2_rgb.jpg");

test "decode 2x2 baseline RGB JPEG produces a 2x2 RGB Image" {
    const allocator = std.testing.allocator;

    var image = try jpegz.decode(allocator, fixture_baseline_2x2_rgb);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
    // Source was YCbCr (libjpeg's default for an encoded RGB JFIF).
    try std.testing.expectEqual(jpegz.ColorSpace.ycbcr, image.source_color_space);

    // Pixel buffer size = 2 * 2 * 3 = 12 bytes.
    try std.testing.expectEqual(@as(usize, 12), image.pixels.len);
    try std.testing.expectEqual(@as(usize, 6), image.rowStride());

    // Sanity check: at quality=90, pixel (1,1) was input 0xFFFFFF (white);
    // round-trip should keep it >= 240 in every channel.
    const px11 = image.pixels[1 * image.rowStride() + 1 * 3 ..][0..3];
    try std.testing.expect(px11[0] >= 240);
    try std.testing.expect(px11[1] >= 240);
    try std.testing.expect(px11[2] >= 240);
}

test "decode rejects empty input" {
    const empty: []const u8 = &[_]u8{};
    try std.testing.expectError(
        error.TruncatedStream,
        jpegz.decode(std.testing.allocator, empty),
    );
}

test "decode rejects non-JPEG input" {
    const garbage = "this is not a JPEG file at all";
    try std.testing.expectError(
        error.InvalidMarker,
        jpegz.decode(std.testing.allocator, garbage),
    );
}

/// 8×8 RGB progressive JPEG (SOF2). libjpeg-turbo decodes both
/// baseline and progressive through the same `decode` entry point —
/// this test confirms our wrapper doesn't accidentally restrict by SOF.
const fixture_progressive_8x8 = @embedFile("fixtures/progressive_8x8_rgb.jpg");

/// 4×4 8-bit grayscale lossless (SOF3) JPEG (predictor=1, all 0x80).
/// libjpeg-turbo 3.1+ supports lossless decoding via the same
/// `jpeg_read_scanlines` API used for SOF0/SOF1/SOF2 — for 8-bit
/// precision. 12/16-bit lossless requires `jpeg12_/jpeg16_` APIs and
/// is the M1.4b follow-up.
const fixture_lossless_4x4_gray8 = @embedFile("fixtures/lossless_4x4_gray8.jpg");

test "decode 4x4 8-bit grayscale lossless (SOF3) JPEG" {
    const allocator = std.testing.allocator;

    var image = try jpegz.decode(allocator, fixture_lossless_4x4_gray8);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.grayscale, image.layout);
    try std.testing.expectEqual(jpegz.ColorSpace.grayscale, image.source_color_space);
    try std.testing.expectEqual(@as(usize, 16), image.pixels.len);

    // Lossless round-trip: every byte should be exactly 0x80 (the input).
    for (image.pixels) |b| {
        try std.testing.expectEqual(@as(u8, 0x80), b);
    }
}

/// 4×4 12-bit grayscale lossless. precision 12, all 0x800.
const fixture_lossless_4x4_gray12 = @embedFile("fixtures/lossless_4x4_gray12.jpg");

test "decode 4x4 12-bit grayscale lossless (SOF3) JPEG" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_lossless_4x4_gray12);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 12), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.grayscale, image.layout);
    // []u16 view: 4*4 = 16 samples, 32 bytes total.
    try std.testing.expectEqual(@as(usize, 32), image.pixels.len);
    const px = image.pixelsU16();
    try std.testing.expectEqual(@as(usize, 16), px.len);
    for (px) |s| try std.testing.expectEqual(@as(u16, 0x800), s);
}

/// 4×4 12-bit grayscale baseline DCT (SOF1 extended sequential, NOT
/// SOF0 baseline — T.81 SOF0 is 8-bit-only). cjpeg `-baseline
/// -precision 12` emits this. Goes through libjpeg-turbo's
/// `jpeg12_read_scanlines` path via M1.4b's precision-range
/// dispatch in the wrapper. Cleanroom (SOF0-only) returns
/// NotImplemented and falls back.
const fixture_baseline_4x4_gray12_dct = @embedFile("fixtures/baseline_4x4_gray12_dct.jpg");

test "decode 4x4 12-bit grayscale baseline DCT (SOF1)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_baseline_4x4_gray12_dct);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 12), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.grayscale, image.layout);
    try std.testing.expectEqual(@as(usize, 32), image.pixels.len); // 4*4*2 (u16-aliased)
    // Source: uniform 0x0800 (mid-range 12-bit). Lossy DCT round-trip
    // at default quality keeps values close. Tight ±200 (out of 4095)
    // tolerance.
    const px = image.pixelsU16();
    try std.testing.expectEqual(@as(usize, 16), px.len);
    for (px) |s| {
        const delta = @as(i32, s) - 0x800;
        try std.testing.expect(@abs(delta) < 200);
    }
}

/// 4×4 14-bit grayscale lossless (precision 14, all 0x2000). DNG raw
/// commonly uses 14-bit precision (Sony/Nikon/Fuji sensors); jpegz's
/// libjpeg-turbo path routes precision 13..16 through jpeg16_*. M1.4b
/// originally checked precision == exactly 16; tiffz's DNG handoff
/// flagged 14-bit as in-scope, so the precision check now accepts
/// any 1..16 and routes by range.
const fixture_lossless_4x4_gray14 = @embedFile("fixtures/lossless_4x4_gray14.jpg");

test "decode 4x4 14-bit grayscale lossless (SOF3) JPEG (DNG path)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_lossless_4x4_gray14);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 14), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.grayscale, image.layout);
    try std.testing.expectEqual(@as(usize, 32), image.pixels.len);
    const px = image.pixelsU16();
    try std.testing.expectEqual(@as(usize, 16), px.len);
    for (px) |s| try std.testing.expectEqual(@as(u16, 0x2000), s);
}

// ─────────────────────────────────────────────────────────────────────
// Tier 1 — wrapper coverage verification (per Peter, 2026-05-06).
// Each of these fixtures is a real-world JPEG variant our wrapper
// claims to handle but never had explicit test coverage. They
// double as Phase 2 oracle test cases (cleanroom impl must produce
// byte-equal output to libjpeg-turbo for these inputs).
// ─────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────
// M2.1 cleanroom — 3-component RGB without subsampling (4:4:4).
// First fixture exercising the multi-component MCU loop in cleanroom.
// ─────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────
// M2.1c — real-world failure-mode reproducers. Each fixture below
// reproduces a class of CLEAN-ERR seen in the cleanroom-diff run
// against Peter's 4,125-JPEG corpus. Synthetic stand-ins generated
// via cjpeg with the matching encoder flags (per CLAUDE.md: do not
// commit Peter's actual corpus files; reproduce shape with cjpeg).
// ─────────────────────────────────────────────────────────────────────

/// 128×128 RGB baseline 4:4:4 with restart markers every 4 MCUs.
/// 256 MCUs total → 63 RSTm markers cycling 0..7. Reproduces the
/// `InvalidMarker` failure mode hit by petethumb128x128.jpg in the
/// real corpus. cjpeg `-sample 1x1 -restart 4B`.
const fixture_baseline_128x128_dri4 = @embedFile("fixtures/baseline_128x128_dri4.jpg");

test "decode 128x128 4:4:4 RGB baseline with DRI=4 (RST every 4 MCUs)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_baseline_128x128_dri4);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 128), image.width);
    try std.testing.expectEqual(@as(u32, 128), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
    try std.testing.expectEqual(@as(usize, 128 * 128 * 3), image.pixels.len);
    // Source: pixel(x, y) = ((2x)%256, (2y)%256, (x+y)%256). Lossy q=80
    // round-trip stays within ±25 per channel against that pattern.
    var y: u32 = 0;
    while (y < 128) : (y += 1) {
        var x: u32 = 0;
        while (x < 128) : (x += 1) {
            const i = (y * 128 + x) * 3;
            try std.testing.expect(@abs(@as(i16, image.pixels[i + 0]) - @as(i16, @intCast((x * 2) % 256))) < 25);
            try std.testing.expect(@abs(@as(i16, image.pixels[i + 1]) - @as(i16, @intCast((y * 2) % 256))) < 25);
            try std.testing.expect(@abs(@as(i16, image.pixels[i + 2]) - @as(i16, @intCast((x + y) % 256))) < 25);
        }
    }
}

/// 4×4 RGB baseline with all components at 1×1 sampling (no subsampling).
/// cjpeg's default produces 4:2:0; this fixture used `-sample 1x1`.
const fixture_baseline_4x4_rgb_444 = @embedFile("fixtures/baseline_4x4_rgb_444.jpg");

test "decode 4x4 RGB baseline 4:4:4 (no subsampling) — cleanroom path" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_baseline_4x4_rgb_444);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
    try std.testing.expectEqual(jpegz.ColorSpace.ycbcr, image.source_color_space);
    try std.testing.expectEqual(@as(usize, 4 * 4 * 3), image.pixels.len);
    // Source: uniform R=0x80, G=0x40, B=0xA0. Quality=80 lossy round-trip;
    // every output pixel should land within ±20 per channel.
    var i: usize = 0;
    while (i < image.pixels.len) : (i += 3) {
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 0]) - 0x80) < 20);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 1]) - 0x40) < 20);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 2]) - 0xA0) < 20);
    }
}

/// T1.1: arithmetic-coded baseline (SOF9). Patents expired in early
/// 2000s; libjpeg-turbo decodes it via the same scanline path.
const fixture_baseline_4x4_arithmetic = @embedFile("fixtures/baseline_4x4_arithmetic.jpg");

test "decode 4x4 arithmetic-coded baseline JPEG (SOF9)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_baseline_4x4_arithmetic);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
}

/// T1.2: baseline JPEG with restart markers (DRI=2 every 2 MCUs).
/// Tests entropy-stream RST handling.
const fixture_baseline_16x16_restart = @embedFile("fixtures/baseline_16x16_restart.jpg");

test "decode 16x16 baseline JPEG with restart markers (DRI=2)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_baseline_16x16_restart);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 16), image.width);
    try std.testing.expectEqual(@as(u32, 16), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(@as(usize, 16 * 16 * 3), image.pixels.len);
    // Source: uniform R=0x80 G=0x40 B=0xA0; quality=80 lossy. Every
    // pixel within ±25 per channel — proves restart-marker handling
    // is correct (a missed/mishandled RST realigns prev_dc and the
    // pixels go wildly off).
    var i: usize = 0;
    while (i < image.pixels.len) : (i += 3) {
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 0]) - 0x80) < 25);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 1]) - 0x40) < 25);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 2]) - 0xA0) < 25);
    }
}

/// T1.3: 4×4 CMYK JPEG (4 components, Adobe APP14 colorspace = CMYK).
const fixture_baseline_4x4_cmyk = @embedFile("fixtures/baseline_4x4_cmyk.jpg");

test "decode 4x4 CMYK JPEG (Adobe APP14)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_baseline_4x4_cmyk);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 4), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.cmyk, image.layout);
    // source_color_space should be either .cmyk or .ycck (libjpeg-turbo
    // sets one based on the Adobe APP14 transform byte).
    const cs = image.source_color_space;
    try std.testing.expect(cs == .cmyk or cs == .ycck);
    try std.testing.expectEqual(@as(usize, 4 * 4 * 4), image.pixels.len);
}

/// T1.4: 4×4 grayscale baseline JPEG (1 component).
const fixture_baseline_4x4_grayscale = @embedFile("fixtures/baseline_4x4_grayscale.jpg");

test "decode 4x4 grayscale baseline JPEG (1 component)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_baseline_4x4_grayscale);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.grayscale, image.layout);
    try std.testing.expectEqual(jpegz.ColorSpace.grayscale, image.source_color_space);
    try std.testing.expectEqual(@as(usize, 4 * 4), image.pixels.len);
    // Input was uniform 0x80; quality=80 round-trip should keep all
    // pixels close to 0x80 (within ±20).
    for (image.pixels) |b| {
        const delta = @as(i16, @intCast(b)) - 0x80;
        try std.testing.expect(@abs(delta) < 20);
    }
}

/// T1.5a: 8×8 RGB JPEG with 4:2:0 chroma subsampling. libjpeg-turbo
/// upsamples to full-res RGB on output, so the consumer sees
/// `width=8 height=8 channels=3` regardless of internal subsampling.
const fixture_baseline_8x8_yuv420 = @embedFile("fixtures/baseline_8x8_yuv420.jpg");

test "decode 8x8 baseline JPEG with 4:2:0 chroma subsampling" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_baseline_8x8_yuv420);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 8), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
    try std.testing.expectEqual(@as(usize, 8 * 8 * 3), image.pixels.len);
    // Source: uniform R=0x80 G=0x40 B=0xA0; lossy at quality=80 with
    // 4:2:0 chroma sub. Every pixel within ±25 per channel.
    var i: usize = 0;
    while (i < image.pixels.len) : (i += 3) {
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 0]) - 0x80) < 25);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 1]) - 0x40) < 25);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 2]) - 0xA0) < 25);
    }
}

/// T1.5b: 8×8 RGB JPEG with 4:2:2 chroma subsampling.
const fixture_baseline_8x8_yuv422 = @embedFile("fixtures/baseline_8x8_yuv422.jpg");

test "decode 8x8 baseline JPEG with 4:2:2 chroma subsampling" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_baseline_8x8_yuv422);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 8), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
    var i: usize = 0;
    while (i < image.pixels.len) : (i += 3) {
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 0]) - 0x80) < 25);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 1]) - 0x40) < 25);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 2]) - 0xA0) < 25);
    }
}

test "islow IDCT + fixed-point YCbCr matches libjpeg-turbo on 4:2:0 (max delta ≤ 2)" {
    // After replacing the float DCT-direct IDCT with libjpeg-turbo's
    // islow algorithm and the f32 YCbCr→RGB conversion with the fixed-point
    // version (jdcolor.c), max divergence vs. the wrapper drops to 2 LSB
    // sub-pixel rounding noise across the entire corpus. Asserting strict
    // byte-equality is too tight (1 LSB ties differ by integer-vs-float
    // rounding edge cases) — assert max-delta ≤ 2 instead.
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.cleanroomDecode(allocator, fixture_baseline_8x8_yuv420);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_baseline_8x8_yuv420);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqual(wrapper.width, cleanroom.width);
    try std.testing.expectEqual(wrapper.height, cleanroom.height);
    var max_delta: u8 = 0;
    for (cleanroom.pixels, wrapper.pixels) |a, b| {
        const d: u8 = @intCast(@abs(@as(i32, a) - @as(i32, b)));
        if (d > max_delta) max_delta = d;
    }
    try std.testing.expect(max_delta <= 2);
}

test "decodeWithOptions threading API: default options match decode()" {
    // M2.1d threading-control surface: jpegz.decode(..) and
    // jpegz.decodeWithOptions(.., .{}) must produce byte-identical
    // results. The options struct is additive; default `threads = 1`
    // is the same path the original `decode` always took.
    const allocator = std.testing.allocator;
    var a = try jpegz.decode(allocator, fixture_baseline_2x2_rgb);
    defer a.deinit(allocator);
    var b = try jpegz.decodeWithOptions(allocator, fixture_baseline_2x2_rgb, .{});
    defer b.deinit(allocator);
    try std.testing.expectEqual(a.width, b.width);
    try std.testing.expectEqual(a.height, b.height);
    try std.testing.expectEqual(a.channels, b.channels);
    try std.testing.expectEqualSlices(u8, a.pixels, b.pixels);
}

test "decodeWithOptions threading API: threads > 1 currently no-op (parallelism is M2.1d follow-up)" {
    // Surface contract: `threads = N` for any N is accepted today and
    // produces correct output. Parallel execution lands later; for
    // now the value is recorded but not acted on. This test guards
    // against regressions where someone wires `threads` through and
    // accidentally breaks the contract that "any value still decodes".
    const allocator = std.testing.allocator;
    var t1 = try jpegz.decodeWithOptions(allocator, fixture_baseline_2x2_rgb, .{ .threads = 1 });
    defer t1.deinit(allocator);
    var t4 = try jpegz.decodeWithOptions(allocator, fixture_baseline_2x2_rgb, .{ .threads = 4 });
    defer t4.deinit(allocator);
    var auto = try jpegz.decodeWithOptions(allocator, fixture_baseline_2x2_rgb, .{ .threads = 0 });
    defer auto.deinit(allocator);
    try std.testing.expectEqualSlices(u8, t1.pixels, t4.pixels);
    try std.testing.expectEqualSlices(u8, t1.pixels, auto.pixels);
}

test "fancy upsampling matches libjpeg-turbo on 4:2:0 (cleanroom == wrapper)" {
    // Tiny 2×2 4:2:0 fixture — chroma plane is 1×1 active in an 8×8
    // MCU-padded plane. Without active-frame boundary clamping, fancy
    // upsampling would pull garbage from padded chroma into visible
    // pixels (cleanroom showed (1,1) as 229,255,231 vs wrapper's
    // 247,246,251). After the fix every output pixel matches the
    // libjpeg-turbo wrapper byte-for-byte.
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.cleanroomDecode(allocator, fixture_baseline_2x2_rgb);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_baseline_2x2_rgb);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqual(wrapper.width, cleanroom.width);
    try std.testing.expectEqual(wrapper.height, cleanroom.height);
    try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
}

/// 4×4 16-bit grayscale lossless. precision 16, all 0x8000.
const fixture_lossless_4x4_gray16 = @embedFile("fixtures/lossless_4x4_gray16.jpg");

test "decode 4x4 16-bit grayscale lossless (SOF3) JPEG" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_lossless_4x4_gray16);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 16), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.grayscale, image.layout);
    try std.testing.expectEqual(@as(usize, 32), image.pixels.len);
    const px = image.pixelsU16();
    try std.testing.expectEqual(@as(usize, 16), px.len);
    for (px) |s| try std.testing.expectEqual(@as(u16, 0x8000), s);
}

test "decode 8x8 progressive RGB JPEG" {
    const allocator = std.testing.allocator;

    var image = try jpegz.decode(allocator, fixture_progressive_8x8);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 8), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
    try std.testing.expectEqual(@as(usize, 8 * 8 * 3), image.pixels.len);
    // Source: uniform R=0xFF G=0x80 B=0x40; quality=85 progressive. ±25.
    var i: usize = 0;
    while (i < image.pixels.len) : (i += 3) {
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 0]) - 0xFF) < 25);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 1]) - 0x80) < 25);
        try std.testing.expect(@abs(@as(i16, image.pixels[i + 2]) - 0x40) < 25);
    }
}

/// 8×8 grayscale progressive — simplest progressive case (1 component,
/// 6 scans: DC first + AC[1..5] + AC[6..63] + AC refine + DC refine + AC refine).
const fixture_progressive_8x8_gray = @embedFile("fixtures/progressive_8x8_gray.jpg");

test "decode 8x8 progressive grayscale (currently wrapper; cleanroom WIP)" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_progressive_8x8_gray);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 8), image.width);
    try std.testing.expectEqual(@as(u32, 8), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.grayscale, image.layout);
    try std.testing.expectEqual(@as(usize, 64), image.pixels.len);
    // Input was uniform 0x80; quality=85 progressive should round-trip
    // each pixel within ±15.
    for (image.pixels) |b| {
        try std.testing.expect(@abs(@as(i16, b) - 0x80) < 15);
    }
}

// ─────────────────────────────────────────────────────────────────────
// M2.2 — progressive cleanroom validation (gap-closer #1).
// These tests exercise `internal.progressiveDecode` directly, separate
// from the public dispatcher. They go green when the SOF2 code path in
// `src/decode/progressive.zig` matches libjpeg-turbo wrapper output
// closely enough to wire into dispatch.
// ─────────────────────────────────────────────────────────────────────

test "M2.2: progressive cleanroom decodes 8x8 grayscale fixture" {
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.progressiveDecode(allocator, fixture_progressive_8x8_gray);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_progressive_8x8_gray);
    defer wrapper.deinit(allocator);

    try std.testing.expectEqual(wrapper.width, cleanroom.width);
    try std.testing.expectEqual(wrapper.height, cleanroom.height);
    try std.testing.expectEqual(wrapper.channels, cleanroom.channels);
    try std.testing.expectEqual(wrapper.pixels.len, cleanroom.pixels.len);

    // ≤2 LSB tolerance, the same threshold baseline cleanroom uses
    // against wrapper output (sub-pixel rounding from float vs fixed-
    // point IDCT/color rounding).
    var max_delta: u8 = 0;
    for (cleanroom.pixels, wrapper.pixels) |a, b| {
        const d: u8 = @intCast(@abs(@as(i32, a) - @as(i32, b)));
        if (d > max_delta) max_delta = d;
    }
    try std.testing.expect(max_delta <= 2);
}

/// 2×2 RGB SOF1 (extended sequential, 8-bit precision) — generated by
/// patching `baseline_2x2_rgb.jpg`'s SOF0 (0xFF 0xC0) marker to SOF1
/// (0xFF 0xC1). For 8-bit precision the bitstream is identical to
/// SOF0; only the marker differs. T.81 §A.4.2 / F.1.1 requires the
/// decoder to accept SOF1 the same as SOF0 at 8-bit precision.
const fixture_extended_2x2_rgb_sof1 = @embedFile("fixtures/extended_2x2_rgb_sof1.jpg");

/// 4×4 gradient (0x00,0x10,…,0xF0) encoded with `cjpeg -lossless 1`
/// (predictor 1 = Pa, left neighbor). Exercises the actual predictor +
/// difference math, not just the all-zero-diff trivial case.
const fixture_lossless_gradient_pred1 = @embedFile("fixtures/lossless_4x4_gradient_pred1.jpg");

/// All 7 predictors (T.81 §H.1.2.1) on the same 4×4 gradient. Each
/// fixture: `cjpeg -lossless <psv> /tmp/gradient.pgm`. Tests that
/// every predictor selector produces byte-identical pixels to the
/// wrapper's libjpeg-turbo decode of the same input. Lossless is
/// exact reconstruction by definition — any rounding mismatch is
/// a real bug in our predictor formula.
const fixture_lossless_gradient_pred2 = @embedFile("fixtures/lossless_4x4_gradient_pred2.jpg");
const fixture_lossless_gradient_pred3 = @embedFile("fixtures/lossless_4x4_gradient_pred3.jpg");
const fixture_lossless_gradient_pred4 = @embedFile("fixtures/lossless_4x4_gradient_pred4.jpg");
const fixture_lossless_gradient_pred5 = @embedFile("fixtures/lossless_4x4_gradient_pred5.jpg");
const fixture_lossless_gradient_pred6 = @embedFile("fixtures/lossless_4x4_gradient_pred6.jpg");
const fixture_lossless_gradient_pred7 = @embedFile("fixtures/lossless_4x4_gradient_pred7.jpg");

/// 32×32 grayscale progressive JPEG with DRI=8 (restart every 8 MCUs).
/// Generated via `cjpeg -progressive -restart 2 grad32.pgm`. Exercises
/// progressive cleanroom's DRI handling, which previously returned
/// NotImplemented for any 0xFF DD marker.
const fixture_progressive_32x32_dri = @embedFile("fixtures/progressive_32x32_gray_dri.jpg");

test "M2.5: progressive cleanroom decodes a JPEG with DRI > 0" {
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.progressiveDecode(allocator, fixture_progressive_32x32_dri);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_progressive_32x32_dri);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqual(wrapper.width, cleanroom.width);
    try std.testing.expectEqual(wrapper.height, cleanroom.height);
    try std.testing.expectEqual(wrapper.channels, cleanroom.channels);
    var max_delta: u8 = 0;
    for (cleanroom.pixels, wrapper.pixels) |a, b| {
        const d: u8 = @intCast(@abs(@as(i32, a) - @as(i32, b)));
        if (d > max_delta) max_delta = d;
    }
    try std.testing.expect(max_delta <= 2);
}

/// SOF9 arithmetic-coded baseline fixtures across all 4 chroma
/// sampling factors + grayscale. Generated by
/// `scratch/gen_arith_fixtures.sh` (cjpeg -arithmetic). Held here
/// as B1 ground-truth inputs; the parametric "cleanroom == wrapper"
/// test is added in the follow-on commit that ships DC/AC
/// binarization + DAC parser + SOF9 dispatch.
const fixture_arith_baseline_16x16_rgb_444 = @embedFile("fixtures/arith_baseline_16x16_rgb_444.jpg");
const fixture_arith_baseline_16x16_rgb_420 = @embedFile("fixtures/arith_baseline_16x16_rgb_420.jpg");
const fixture_arith_baseline_16x16_rgb_422 = @embedFile("fixtures/arith_baseline_16x16_rgb_422.jpg");
const fixture_arith_baseline_16x16_rgb_440 = @embedFile("fixtures/arith_baseline_16x16_rgb_440.jpg");
const fixture_arith_baseline_8x8_gray = @embedFile("fixtures/arith_baseline_8x8_gray.jpg");

// ─────────────────────────────────────────────────────────────────────
// B2 — JPEG-LS (T.87) via charls wrapper. Cleanroom to follow.
// ─────────────────────────────────────────────────────────────────────

/// 4×4 8-bit grayscale JPEG-LS, gradient 0x00, 0x10, …, 0xF0. Encoded
/// by `scratch/gen_jpegls_fixtures.c` (one-shot, charls encoder).
const fixture_jpegls_4x4_gray8 = @embedFile("fixtures/jpegls_4x4_gray8.jls");

/// 4×4 16-bit grayscale JPEG-LS, gradient 0x0000, 0x1111, …, 0xFFFF.
const fixture_jpegls_4x4_gray16 = @embedFile("fixtures/jpegls_4x4_gray16.jls");

/// 4×4 RGB 8-bit JPEG-LS, sample-interleaved. R = x*0x40, G = y*0x40,
/// B = (x+y)*0x20.
const fixture_jpegls_4x4_rgb8 = @embedFile("fixtures/jpegls_4x4_rgb8.jls");

test "B2: JPEG-LS 4x4 8-bit grayscale lossless round-trip via charls wrapper" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_jpegls_4x4_gray8);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.grayscale, image.layout);
    try std.testing.expectEqual(@as(usize, 16), image.pixels.len);
    // Lossless: every pixel must match the gradient bit-exactly.
    for (image.pixels, 0..) |b, i| {
        try std.testing.expectEqual(@as(u8, @intCast(i << 4)), b);
    }
}

test "B2: JPEG-LS 4x4 16-bit grayscale lossless round-trip" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_jpegls_4x4_gray16);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 1), image.channels);
    try std.testing.expectEqual(@as(u8, 16), image.bits_per_sample);
    try std.testing.expectEqual(@as(usize, 32), image.pixels.len);
    const px = image.pixelsU16();
    try std.testing.expectEqual(@as(usize, 16), px.len);
    for (px, 0..) |s, i| {
        try std.testing.expectEqual(@as(u16, @intCast(i * 0x1111)), s);
    }
}

test "B2: JPEG-LS 4x4 RGB 8-bit lossless round-trip" {
    const allocator = std.testing.allocator;
    var image = try jpegz.decode(allocator, fixture_jpegls_4x4_rgb8);
    defer image.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 4), image.width);
    try std.testing.expectEqual(@as(u32, 4), image.height);
    try std.testing.expectEqual(@as(u8, 3), image.channels);
    try std.testing.expectEqual(@as(u8, 8), image.bits_per_sample);
    try std.testing.expectEqual(jpegz.PixelLayout.rgb, image.layout);
    try std.testing.expectEqual(@as(usize, 4 * 4 * 3), image.pixels.len);
    var y: u32 = 0;
    while (y < 4) : (y += 1) {
        var x: u32 = 0;
        while (x < 4) : (x += 1) {
            const off: usize = (@as(usize, y) * 4 + @as(usize, x)) * 3;
            try std.testing.expectEqual(@as(u8, @intCast(x * 0x40)), image.pixels[off]);
            try std.testing.expectEqual(@as(u8, @intCast(y * 0x40)), image.pixels[off + 1]);
            try std.testing.expectEqual(@as(u8, @intCast((x + y) * 0x20)), image.pixels[off + 2]);
        }
    }
}

/// SOF10 arithmetic progressive fixtures across all 4 chroma sampling
/// factors + grayscale. Generated by scratch/gen_arith_fixtures.sh
/// (cjpeg -arithmetic -progressive). Cleanroom must match libjpeg-turbo
/// within the same DCT-cleanroom tolerance as SOF9 / progressive Huffman.
const fixture_arith_progressive_16x16_rgb_444 = @embedFile("fixtures/arith_progressive_16x16_rgb_444.jpg");
const fixture_arith_progressive_16x16_rgb_420 = @embedFile("fixtures/arith_progressive_16x16_rgb_420.jpg");
const fixture_arith_progressive_16x16_rgb_422 = @embedFile("fixtures/arith_progressive_16x16_rgb_422.jpg");
const fixture_arith_progressive_16x16_rgb_440 = @embedFile("fixtures/arith_progressive_16x16_rgb_440.jpg");
const fixture_arith_progressive_8x8_gray = @embedFile("fixtures/arith_progressive_8x8_gray.jpg");

test "B1 SOF10: arithmetic progressive cleanroom (gray + RGB at all sampling factors)" {
    const allocator = std.testing.allocator;
    const RgbCase = struct { data: []const u8 };
    const rgb_cases = [_]RgbCase{
        .{ .data = fixture_arith_progressive_16x16_rgb_444 },
        .{ .data = fixture_arith_progressive_16x16_rgb_420 },
        .{ .data = fixture_arith_progressive_16x16_rgb_422 },
        .{ .data = fixture_arith_progressive_16x16_rgb_440 },
    };
    inline for (rgb_cases) |c| {
        var cleanroom = try jpegz.internal.arithDecode(allocator, c.data);
        defer cleanroom.deinit(allocator);
        var wrapper = try jpegz.internal.wrapperDecode(allocator, c.data);
        defer wrapper.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 8), cleanroom.bits_per_sample);
        try std.testing.expectEqual(@as(u8, 3), cleanroom.channels);
        try std.testing.expectEqual(@as(u32, 16), cleanroom.width);
        try std.testing.expectEqual(@as(u32, 16), cleanroom.height);
        try std.testing.expectEqual(jpegz.PixelLayout.rgb, cleanroom.layout);
        try std.testing.expectEqual(wrapper.pixels.len, cleanroom.pixels.len);
        var max_delta: u8 = 0;
        for (cleanroom.pixels, wrapper.pixels) |a, b| {
            const d: u8 = @intCast(@abs(@as(i32, a) - @as(i32, b)));
            if (d > max_delta) max_delta = d;
        }
        try std.testing.expect(max_delta <= 4);
    }
    // Grayscale: tighter ≤2 LSB tolerance (no chroma upsample / colorconv).
    {
        var cleanroom = try jpegz.internal.arithDecode(allocator, fixture_arith_progressive_8x8_gray);
        defer cleanroom.deinit(allocator);
        var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_arith_progressive_8x8_gray);
        defer wrapper.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 1), cleanroom.channels);
        try std.testing.expectEqual(jpegz.PixelLayout.grayscale, cleanroom.layout);
        var max_delta: u8 = 0;
        for (cleanroom.pixels, wrapper.pixels) |a, b| {
            const d: u8 = @intCast(@abs(@as(i32, a) - @as(i32, b)));
            if (d > max_delta) max_delta = d;
        }
        try std.testing.expect(max_delta <= 2);
    }
}

test "B1: SOF9 arithmetic baseline cleanroom (gray + RGB at all sampling factors)" {
    // Real cleanroom-vs-wrapper gate. Same tolerance shape as A3:
    // ≤4 LSB for RGB (chroma upsampling amplifies sub-pixel rounding),
    // ≤2 LSB for grayscale.
    const allocator = std.testing.allocator;
    const RgbCase = struct { data: []const u8 };
    const rgb_cases = [_]RgbCase{
        .{ .data = fixture_arith_baseline_16x16_rgb_444 },
        .{ .data = fixture_arith_baseline_16x16_rgb_420 },
        .{ .data = fixture_arith_baseline_16x16_rgb_422 },
        .{ .data = fixture_arith_baseline_16x16_rgb_440 },
    };
    inline for (rgb_cases) |c| {
        var cleanroom = try jpegz.internal.arithDecode(allocator, c.data);
        defer cleanroom.deinit(allocator);
        var wrapper = try jpegz.internal.wrapperDecode(allocator, c.data);
        defer wrapper.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 8), cleanroom.bits_per_sample);
        try std.testing.expectEqual(@as(u8, 3), cleanroom.channels);
        try std.testing.expectEqual(@as(u32, 16), cleanroom.width);
        try std.testing.expectEqual(@as(u32, 16), cleanroom.height);
        try std.testing.expectEqual(jpegz.PixelLayout.rgb, cleanroom.layout);
        try std.testing.expectEqual(wrapper.pixels.len, cleanroom.pixels.len);
        var max_delta: u8 = 0;
        for (cleanroom.pixels, wrapper.pixels) |a, b| {
            const d: u8 = @intCast(@abs(@as(i32, a) - @as(i32, b)));
            if (d > max_delta) max_delta = d;
        }
        try std.testing.expect(max_delta <= 4);
    }
    // Grayscale: no chroma upsample, no color conversion → tighter ≤2.
    {
        var cleanroom = try jpegz.internal.arithDecode(allocator, fixture_arith_baseline_8x8_gray);
        defer cleanroom.deinit(allocator);
        var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_arith_baseline_8x8_gray);
        defer wrapper.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 1), cleanroom.channels);
        try std.testing.expectEqual(jpegz.PixelLayout.grayscale, cleanroom.layout);
        var max_delta: u8 = 0;
        for (cleanroom.pixels, wrapper.pixels) |a, b| {
            const d: u8 = @intCast(@abs(@as(i32, a) - @as(i32, b)));
            if (d > max_delta) max_delta = d;
        }
        try std.testing.expect(max_delta <= 2);
    }
}

/// SOF2 12-bit progressive fixtures across all 4 chroma sampling
/// factors + grayscale. Generated by `scratch/gen_prog12_fixtures.sh`
/// (cjpeg -progressive -precision 12 -sample <factors> | -grayscale).
/// Exercises A3: cleanroom 12-bit DCT in the progressive scan context,
/// reusing A1's `idct.idct8x8Generic(12, ...)` and A1 Part B's
/// `color.ycbcrRowToRgb12` / `fancyUpsample12` via Phase 2 refactor.
const fixture_progressive_16x16_rgb12_444 = @embedFile("fixtures/progressive_16x16_rgb12_444.jpg");
const fixture_progressive_16x16_rgb12_420 = @embedFile("fixtures/progressive_16x16_rgb12_420.jpg");
const fixture_progressive_16x16_rgb12_422 = @embedFile("fixtures/progressive_16x16_rgb12_422.jpg");
const fixture_progressive_16x16_rgb12_440 = @embedFile("fixtures/progressive_16x16_rgb12_440.jpg");
const fixture_progressive_8x8_gray12 = @embedFile("fixtures/progressive_8x8_gray12.jpg");

test "A3: SOF2 12-bit progressive cleanroom (gray + RGB at all sampling factors)" {
    const allocator = std.testing.allocator;
    const RgbCase = struct { data: []const u8 };
    const rgb_cases = [_]RgbCase{
        .{ .data = fixture_progressive_16x16_rgb12_444 },
        .{ .data = fixture_progressive_16x16_rgb12_420 },
        .{ .data = fixture_progressive_16x16_rgb12_422 },
        .{ .data = fixture_progressive_16x16_rgb12_440 },
    };
    inline for (rgb_cases) |c| {
        var cleanroom = try jpegz.internal.progressiveDecode(allocator, c.data);
        defer cleanroom.deinit(allocator);
        var wrapper = try jpegz.internal.wrapperDecode(allocator, c.data);
        defer wrapper.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 12), cleanroom.bits_per_sample);
        try std.testing.expectEqual(@as(u8, 3), cleanroom.channels);
        try std.testing.expectEqual(@as(u32, 16), cleanroom.width);
        try std.testing.expectEqual(@as(u32, 16), cleanroom.height);
        try std.testing.expectEqual(jpegz.PixelLayout.rgb, cleanroom.layout);
        const c_u16 = cleanroom.pixelsU16();
        const w_u16 = wrapper.pixelsU16();
        try std.testing.expectEqual(w_u16.len, c_u16.len);
        // ≤4 LSB tolerance per spec; same gate as A1 Part B (12-bit
        // YCbCr→RGB with chroma upsample amplifies sub-pixel rounding).
        for (c_u16, w_u16) |a, b| {
            const ad: u32 = @abs(@as(i32, a) - @as(i32, b));
            try std.testing.expect(ad <= 4);
        }
    }
    // Grayscale case — no chroma upsample, no color conversion, so
    // tighter tolerance (≤2 LSB, same as 8-bit progressive).
    {
        var cleanroom = try jpegz.internal.progressiveDecode(allocator, fixture_progressive_8x8_gray12);
        defer cleanroom.deinit(allocator);
        var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_progressive_8x8_gray12);
        defer wrapper.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 12), cleanroom.bits_per_sample);
        try std.testing.expectEqual(@as(u8, 1), cleanroom.channels);
        try std.testing.expectEqual(jpegz.PixelLayout.grayscale, cleanroom.layout);
        const c_u16 = cleanroom.pixelsU16();
        const w_u16 = wrapper.pixelsU16();
        for (c_u16, w_u16) |a, b| {
            const ad: u32 = @abs(@as(i32, a) - @as(i32, b));
            try std.testing.expect(ad <= 2);
        }
    }
}

/// 4×4 RGB lossless (SOF3, 3 components, 1×1 sampling each, predictor 1).
/// Generated via `cjpeg -lossless 1 grad_rgb.ppm`. Component IDs are
/// the ASCII codes for R/G/B (82/71/66) rather than the more common
/// 1/2/3 — exercises ID-agnostic component lookup. v1 single-component
/// scope returned NotImplemented for 3-component SOF3.
const fixture_lossless_4x4_rgb = @embedFile("fixtures/lossless_4x4_rgb_pred1.jpg");

/// 16×16 grayscale lossless with restart-interval = 64 MCUs (4 rows of 16).
/// Generated via `cjpeg -lossless 1 -restart 4`. Three RSTm markers fall
/// within the entropy stream (at samples 64, 128, 192). Exercises lossless
/// cleanroom's RST handling, mirroring the M2.5 progressive+DRI fix.
const fixture_lossless_dri = @embedFile("fixtures/lossless_16x16_gray_dri.jpg");

/// 16×16 RGB SOF1 12-bit fixtures across all 4 common chroma sampling
/// factors. Generated by `scratch/gen_rgb12_fixtures.sh` (cjpeg
/// -baseline -precision 12 -sample <factors>) from a 16×16 RGB
/// gradient PPM. Exercises A1 Part B: cleanroom 12-bit DCT with 3
/// components and the new u16 YCbCr→RGB / fancy-upsample path.
const fixture_baseline_16x16_rgb12_444 = @embedFile("fixtures/baseline_16x16_rgb12_444.jpg");
const fixture_baseline_16x16_rgb12_420 = @embedFile("fixtures/baseline_16x16_rgb12_420.jpg");
const fixture_baseline_16x16_rgb12_422 = @embedFile("fixtures/baseline_16x16_rgb12_422.jpg");
const fixture_baseline_16x16_rgb12_440 = @embedFile("fixtures/baseline_16x16_rgb12_440.jpg");

test "A1 Part B: SOF1 12-bit RGB cleanroom decodes vs wrapper, all sampling factors" {
    const allocator = std.testing.allocator;
    const cases = [_][]const u8{
        fixture_baseline_16x16_rgb12_444,
        fixture_baseline_16x16_rgb12_420,
        fixture_baseline_16x16_rgb12_422,
        fixture_baseline_16x16_rgb12_440,
    };
    inline for (cases) |data| {
        var cleanroom = try jpegz.internal.cleanroomDecode(allocator, data);
        defer cleanroom.deinit(allocator);
        var wrapper = try jpegz.internal.wrapperDecode(allocator, data);
        defer wrapper.deinit(allocator);
        try std.testing.expectEqual(@as(u8, 12), cleanroom.bits_per_sample);
        try std.testing.expectEqual(@as(u8, 3), cleanroom.channels);
        try std.testing.expectEqual(@as(u32, 16), cleanroom.width);
        try std.testing.expectEqual(@as(u32, 16), cleanroom.height);
        try std.testing.expectEqual(jpegz.PixelLayout.rgb, cleanroom.layout);
        const c_u16 = cleanroom.pixelsU16();
        const w_u16 = wrapper.pixelsU16();
        try std.testing.expectEqual(w_u16.len, c_u16.len);
        // 12-bit YCbCr→RGB with chroma upsample amplifies sub-pixel
        // rounding: a 1-LSB chroma diff propagates to ≤2 LSB in B
        // (Cb·116130/2^16 ≈ 1.77). Empirical max across all 4 sampling
        // factors is ≤3 LSB (4:4:4 / 4:2:0 are ≤2; H2V1 / H1V2 fancy
        // upsample land at 3). Tolerance set to ≤4 with 1 LSB headroom.
        // Cleanroom matches libjpeg's IJG-fancy output exactly at 4:4:4.
        for (c_u16, w_u16) |a, b| {
            const delta = @as(i32, a) - @as(i32, b);
            const ad: u32 = @abs(delta);
            try std.testing.expect(ad <= 4);
        }
    }
}

test "A1: SOF1 12-bit grayscale cleanroom decodes byte-for-byte vs wrapper" {
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.cleanroomDecode(allocator, fixture_baseline_4x4_gray12_dct);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_baseline_4x4_gray12_dct);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqual(@as(u8, 12), cleanroom.bits_per_sample);
    try std.testing.expectEqual(wrapper.bits_per_sample, cleanroom.bits_per_sample);
    try std.testing.expectEqual(@as(u32, 4), cleanroom.width);
    try std.testing.expectEqual(@as(u32, 4), cleanroom.height);
    try std.testing.expectEqual(@as(u8, 1), cleanroom.channels);
    try std.testing.expectEqual(jpegz.PixelLayout.grayscale, cleanroom.layout);
    const cleanroom_u16 = cleanroom.pixelsU16();
    const wrapper_u16 = wrapper.pixelsU16();
    try std.testing.expectEqual(@as(usize, 16), cleanroom_u16.len);
    try std.testing.expectEqual(wrapper_u16.len, cleanroom_u16.len);
    // ≤2 LSB tolerance per spec (DCT rounding); uniform-input fixture
    // produces DC-only coefficients so in practice this should match
    // wrapper byte-exact, but the spec tolerance is the contractual gate.
    for (cleanroom_u16, wrapper_u16) |c, w| {
        const delta = @as(i32, c) - @as(i32, w);
        try std.testing.expect(@abs(delta) <= 2);
    }
}

test "M2.8: lossless SOF3 cleanroom decodes 12/14/16-bit grayscale precision byte-for-byte" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { data: []const u8, bps: u8, expected: u16 }{
        .{ .data = fixture_lossless_4x4_gray12, .bps = 12, .expected = 0x0800 },
        .{ .data = fixture_lossless_4x4_gray14, .bps = 14, .expected = 0x2000 },
        .{ .data = fixture_lossless_4x4_gray16, .bps = 16, .expected = 0x8000 },
    };
    inline for (cases) |c| {
        var cleanroom = try jpegz.internal.losslessDecode(allocator, c.data);
        defer cleanroom.deinit(allocator);
        var wrapper = try jpegz.internal.wrapperDecode(allocator, c.data);
        defer wrapper.deinit(allocator);
        try std.testing.expectEqual(c.bps, cleanroom.bits_per_sample);
        try std.testing.expectEqual(wrapper.bits_per_sample, cleanroom.bits_per_sample);
        try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
        const px = cleanroom.pixelsU16();
        for (px) |s| try std.testing.expectEqual(c.expected, s);
    }
}

test "M2.7: lossless SOF3 cleanroom decodes a JPEG with DRI > 0 byte-for-byte" {
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.losslessDecode(allocator, fixture_lossless_dri);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_lossless_dri);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
}

test "M2.6: lossless SOF3 cleanroom decodes 3-component RGB byte-for-byte" {
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.losslessDecode(allocator, fixture_lossless_4x4_rgb);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_lossless_4x4_rgb);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqual(wrapper.width, cleanroom.width);
    try std.testing.expectEqual(wrapper.height, cleanroom.height);
    try std.testing.expectEqual(wrapper.channels, cleanroom.channels);
    // Lossless = exact reconstruction; ANY pixel mismatch is a real bug.
    try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
}

test "M2.4: lossless SOF3 cleanroom decodes 4x4 gradient with predictors 2..7 byte-for-byte" {
    const allocator = std.testing.allocator;
    const expected = [_]u8{ 0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0 };
    const fixtures = [_][]const u8{
        fixture_lossless_gradient_pred2,
        fixture_lossless_gradient_pred3,
        fixture_lossless_gradient_pred4,
        fixture_lossless_gradient_pred5,
        fixture_lossless_gradient_pred6,
        fixture_lossless_gradient_pred7,
    };
    inline for (fixtures, 2..) |fix, psv| {
        var cleanroom = try jpegz.internal.losslessDecode(allocator, fix);
        defer cleanroom.deinit(allocator);
        var wrapper = try jpegz.internal.wrapperDecode(allocator, fix);
        defer wrapper.deinit(allocator);
        std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels) catch |e| {
            std.debug.print("predictor {d} mismatch vs wrapper\n", .{psv});
            return e;
        };
        std.testing.expectEqualSlices(u8, &expected, cleanroom.pixels) catch |e| {
            std.debug.print("predictor {d} mismatch vs original gradient\n", .{psv});
            return e;
        };
    }
}

test "M2.4: lossless SOF3 cleanroom decodes 4x4 gradient byte-for-byte (predictor 1)" {
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.losslessDecode(allocator, fixture_lossless_gradient_pred1);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_lossless_gradient_pred1);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
    // Sanity: original pattern preserved.
    const expected = [_]u8{ 0x00, 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0 };
    try std.testing.expectEqualSlices(u8, &expected, cleanroom.pixels);
}

test "M2.4: lossless 8-bit grayscale SOF3 cleanroom matches wrapper byte-for-byte" {
    // T.81 §H — Lossless predictive coding. Sample values reconstructed
    // exactly via predictor + Huffman-coded difference; no DCT, no
    // quantization, no IDCT rounding. Cleanroom output MUST be
    // byte-identical to wrapper for any SOF3 input we accept.
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.losslessDecode(allocator, fixture_lossless_4x4_gray8);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_lossless_4x4_gray8);
    defer wrapper.deinit(allocator);
    try std.testing.expectEqual(wrapper.width, cleanroom.width);
    try std.testing.expectEqual(wrapper.height, cleanroom.height);
    try std.testing.expectEqual(wrapper.channels, cleanroom.channels);
    try std.testing.expectEqual(wrapper.bits_per_sample, cleanroom.bits_per_sample);
    try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
}

test "M2.3: extended sequential 8-bit SOF1 cleanroom decode matches wrapper" {
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.cleanroomDecode(allocator, fixture_extended_2x2_rgb_sof1);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_extended_2x2_rgb_sof1);
    defer wrapper.deinit(allocator);

    try std.testing.expectEqual(wrapper.width, cleanroom.width);
    try std.testing.expectEqual(wrapper.height, cleanroom.height);
    try std.testing.expectEqual(wrapper.channels, cleanroom.channels);
    try std.testing.expectEqualSlices(u8, wrapper.pixels, cleanroom.pixels);
}

test "M2.2: progressive cleanroom decodes 8x8 RGB fixture" {
    const allocator = std.testing.allocator;
    var cleanroom = try jpegz.internal.progressiveDecode(allocator, fixture_progressive_8x8);
    defer cleanroom.deinit(allocator);
    var wrapper = try jpegz.internal.wrapperDecode(allocator, fixture_progressive_8x8);
    defer wrapper.deinit(allocator);

    try std.testing.expectEqual(wrapper.width, cleanroom.width);
    try std.testing.expectEqual(wrapper.height, cleanroom.height);
    try std.testing.expectEqual(wrapper.channels, cleanroom.channels);
    try std.testing.expectEqual(wrapper.pixels.len, cleanroom.pixels.len);

    var max_delta: u8 = 0;
    for (cleanroom.pixels, wrapper.pixels) |a, b| {
        const d: u8 = @intCast(@abs(@as(i32, a) - @as(i32, b)));
        if (d > max_delta) max_delta = d;
    }
    try std.testing.expect(max_delta <= 2);
}
