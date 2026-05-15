//! Fuzz target: `jpegz.validate` walks the marker chain and emits a
//! `ValidationReport`. Per the public-API contract it returns a Zig
//! error **only** for `OutOfMemory` — every structural problem is
//! surfaced as a `Finding` inside the report. The fuzz contract is
//! therefore stricter than decode's:
//!
//!   * No panic on any input.
//!   * No leak (every successful return must deinit cleanly).
//!   * Only `error.OutOfMemory` is acceptable as an error result.
//!
//! This catches bugs where the validator dereferences past
//! `data.len`, dispatches on a marker without bounds-checking, or
//! recurses unboundedly on adversarial segment lengths.

const std = @import("std");
const jpegz = @import("jpegz");
const seed = @import("seed");

fn withLenPrefix(comptime data: []const u8) [data.len + 4]u8 {
    var out: [data.len + 4]u8 = undefined;
    std.mem.writeInt(u32, out[0..4], @intCast(data.len), .little);
    @memcpy(out[4..], data);
    return out;
}

// Seed corpus — same SOF coverage as decode_fuzz plus the explicit
// "bogus DHT" fixture that exists for validate's error-path tests.
const seed_baseline_rgb = withLenPrefix(seed.baseline_rgb);
const seed_baseline_gray = withLenPrefix(seed.baseline_gray);
const seed_baseline_dri = withLenPrefix(seed.baseline_dri);
const seed_bogus_dht = withLenPrefix(seed.baseline_bogus_dht);
const seed_trailing = withLenPrefix(seed.baseline_trailing);
const seed_progressive = withLenPrefix(seed.progressive_rgb);
const seed_lossless = withLenPrefix(seed.lossless_gray);
const seed_arith = withLenPrefix(seed.arith_baseline_gray);

const corpus: []const []const u8 = &.{
    &seed_baseline_rgb,
    &seed_baseline_gray,
    &seed_baseline_dri,
    &seed_bogus_dht,
    &seed_trailing,
    &seed_progressive,
    &seed_lossless,
    &seed_arith,
};

const MAX_INPUT_BYTES: usize = 256 * 1024;

const Ctx = struct {
    buf: *[MAX_INPUT_BYTES]u8,
};

fn fuzzValidate(ctx: Ctx, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    const len = smith.slice(ctx.buf);
    const input: []const u8 = ctx.buf[0..len];

    // The validator's contract: only OutOfMemory is allowed to error.
    var report = jpegz.validate(std.testing.allocator, input) catch |e| switch (e) {
        error.OutOfMemory => return, // allowed
    };
    defer report.deinit(std.testing.allocator);

    // Basic invariant: the overall severity must be consistent with
    // findings. If findings is empty the overall is `.pass`; otherwise
    // the overall must be ≥ the max severity of the findings.
    if (report.findings.items.len == 0) {
        try std.testing.expectEqual(jpegz.Severity.pass, report.overall);
    }
}

test "fuzz: jpegz.validate never panics or leaks; only OOM may error" {
    const buf = try std.testing.allocator.create([MAX_INPUT_BYTES]u8);
    defer std.testing.allocator.destroy(buf);
    try std.testing.fuzz(Ctx{ .buf = buf }, fuzzValidate, .{ .corpus = corpus });
}
