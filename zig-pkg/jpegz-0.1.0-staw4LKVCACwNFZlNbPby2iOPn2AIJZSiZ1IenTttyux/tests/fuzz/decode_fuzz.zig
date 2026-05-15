//! Fuzz target: `jpegz.decode` must never panic, hang, or leak on
//! arbitrary byte input — it can only return a valid `Image` or a
//! `DecodeError`. Caught by mutation: the SOF9 Q-coder infinite-loop
//! bug that shipped past B1 checkpoint 1 would have been caught here.
//!
//! Two modes:
//!   - `zig build fuzz` (no `--fuzz` flag) — replays the seed corpus
//!     once each. Acts as a smoke test that the harness compiles.
//!   - `zig build fuzz --fuzz` — Zig 0.16's in-tree libfuzzer-style
//!     coverage-guided mutator. Run via `./fuzz`.
//!
//! The corpus is a representative subset of `tests/unit/fixtures/`
//! covering every SOF code path (SOF0/1/2/3/9). Each entry is wrapped
//! with a u32 little-endian length prefix because `std.testing.Smith`
//! consumes that as part of its slice protocol — see
//! `lib/std/testing/Smith.zig` `sliceWeightedWithHash`.

const std = @import("std");
const jpegz = @import("jpegz");
const seed = @import("seed");

/// Wrap a raw byte slice in the length-prefix shape `std.testing.Smith`
/// expects when consuming corpus entries via `smith.slice(buf)`. The
/// framework reads the first 4 bytes as a u32 LE length, then up to
/// that many bytes of payload — so a raw JPEG corpus entry would
/// silently drop its SOI marker. This wrapper fixes that.
fn withLenPrefix(comptime data: []const u8) [data.len + 4]u8 {
    var out: [data.len + 4]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], @intCast(data.len), .little);
    @memcpy(out[4..], data);
    return out;
}

// ── Seed corpus — one fixture per SOF code path ──────────────────
//
// Held as top-level `const` so the prefixed arrays have static
// lifetime (taking `&local_array` would dangle).
const seed_baseline_rgb = withLenPrefix(seed.baseline_rgb);
const seed_baseline_gray = withLenPrefix(seed.baseline_gray);
const seed_baseline_yuv420 = withLenPrefix(seed.baseline_yuv420);
const seed_baseline_dri = withLenPrefix(seed.baseline_dri);
const seed_baseline_cmyk = withLenPrefix(seed.baseline_cmyk);
const seed_ext_sof1 = withLenPrefix(seed.ext_sof1);
const seed_progressive = withLenPrefix(seed.progressive_rgb);
const seed_progressive_gray = withLenPrefix(seed.progressive_gray);
const seed_progressive_12 = withLenPrefix(seed.progressive_gray12);
const seed_lossless_gray = withLenPrefix(seed.lossless_gray);
const seed_lossless_gradient = withLenPrefix(seed.lossless_gradient);
const seed_lossless_rgb = withLenPrefix(seed.lossless_rgb);
const seed_lossless_12 = withLenPrefix(seed.lossless_gray12);
const seed_arith_baseline = withLenPrefix(seed.arith_baseline_gray);
const seed_arith_rgb = withLenPrefix(seed.arith_baseline_rgb);
const seed_arith_progressive = withLenPrefix(seed.arith_progressive_gray);

const corpus: []const []const u8 = &.{
    &seed_baseline_rgb,
    &seed_baseline_gray,
    &seed_baseline_yuv420,
    &seed_baseline_dri,
    &seed_baseline_cmyk,
    &seed_ext_sof1,
    &seed_progressive,
    &seed_progressive_gray,
    &seed_progressive_12,
    &seed_lossless_gray,
    &seed_lossless_gradient,
    &seed_lossless_rgb,
    &seed_lossless_12,
    &seed_arith_baseline,
    &seed_arith_rgb,
    &seed_arith_progressive,
};

/// Per-test scratch buffer cap. Real JPEGs in the wild can be huge,
/// but for fuzzing what matters is exercising the marker walker and
/// each entropy decoder over malformed inputs — a 256 KB ceiling
/// fits every fixture and forces the fuzzer to find truncation /
/// length-overflow bugs rather than chase pathological input sizes.
const MAX_INPUT_BYTES: usize = 256 * 1024;

const Ctx = struct {
    buf: *[MAX_INPUT_BYTES]u8,
};

fn fuzzDecode(ctx: Ctx, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    const len = smith.slice(ctx.buf);
    const input: []const u8 = ctx.buf[0..len];

    // The contract: decode must either succeed (return a valid Image
    // the caller must deinit) or return a DecodeError. Any panic or
    // leak is a fuzz failure surfaced by the test runner.
    var img = jpegz.decode(std.testing.allocator, input) catch return;
    defer img.deinit(std.testing.allocator);

    // If decode succeeded, basic invariants the public API promises:
    //   pixels.len == width * height * channels  (or *2 for ≥9-bit)
    //   bits_per_sample in [1, 16]
    try std.testing.expect(img.bits_per_sample >= 1 and img.bits_per_sample <= 16);
    const bytes_per_sample: usize = if (img.bits_per_sample <= 8) 1 else 2;
    const expected = @as(usize, img.width) * @as(usize, img.height) *
        @as(usize, img.channels) * bytes_per_sample;
    try std.testing.expectEqual(expected, img.pixels.len);
}

test "fuzz: jpegz.decode never panics or leaks" {
    const buf = try std.testing.allocator.create([MAX_INPUT_BYTES]u8);
    defer std.testing.allocator.destroy(buf);
    try std.testing.fuzz(Ctx{ .buf = buf }, fuzzDecode, .{ .corpus = corpus });
}
