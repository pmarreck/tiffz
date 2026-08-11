//! Deterministic mutation fuzzer for the tiffz validator (Einstein dispatch
//! outcome 5). Hermetic by design: it mutates committed fixtures with a
//! fixed-seed PRNG, so it runs inside the Nix sandbox and reproduces
//! byte-for-byte on every machine — no wall-clock, no external corpus, no
//! network. The libtiff/ImageMagick oracle diff lives in `./fuzz` (native),
//! NOT here: external tools are dev/test oracles only and stay out of the
//! hermetic check.
//!
//! MFIC properties enforced here:
//!   1. Robustness (non-crash) — every mutation of every seed must be handled
//!      without a crash or UB. Built ReleaseSafe, a panic IS a real bug: an
//!      integer overflow, OOB, or bad cast on adversarial input.
//!   2. Specificity — every UNMUTATED seed must validate (return without
//!      error). This is the paired guard from the MFIC discipline: without it
//!      a reject-everything validator would score 100% on detection. A number
//!      that only measures sensitivity is gameable.
//!   3. Non-vacuous mutators — the mutation primitives are themselves tested,
//!      because a mutator that silently no-ops makes the whole fuzz vacuous.

const std = @import("std");
const tiffz = @import("tiffz");

// ─────────────────────────────────────────────────────────────────────
// Mutation primitives — pure, deterministic, individually tested.
// ─────────────────────────────────────────────────────────────────────

/// Flip exactly one byte. XOR with `(mask | 1)` — always nonzero, so the byte
/// is GUARANTEED to change (a mutator that might no-op undercounts detection).
fn snipe(bytes: []u8, offset: usize, mask: u8) void {
    bytes[offset] ^= (mask | 1);
}

/// Overwrite a contiguous field with PRNG bytes — structured corruption of a
/// whole IFD entry / offset / count. Clamps at end-of-buffer.
fn boltgun(bytes: []u8, offset: usize, len: usize, rng: std.Random) void {
    var i: usize = 0;
    while (i < len and offset + i < bytes.len) : (i += 1) {
        bytes[offset + i] = rng.int(u8);
    }
}

/// Flip `n` bytes at random offsets (broad shotgun). Each hit XORs with a
/// nonzero value so every targeted offset changes; distinct offsets are not
/// guaranteed (two hits may coincide), which is fine for a breadth sweep.
fn shotgun(bytes: []u8, rng: std.Random, n: usize) void {
    if (bytes.len == 0) return;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const off = rng.uintLessThan(usize, bytes.len);
        bytes[off] ^= (rng.int(u8) | 1);
    }
}

// ─────────────────────────────────────────────────────────────────────
// Seed corpus — one or two representative KNOWN-GOOD fixtures per codec /
// structure / photometric / predictor / bit-depth cell. Committed, so the
// sandbox sees them. Every entry must validate unmutated (specificity).
// ─────────────────────────────────────────────────────────────────────

const seed_corpus = [_][]const u8{
    "tests/fixtures/uncompressed/minisblack-1c-8b.tiff",
    "tests/fixtures/uncompressed/rgb-3c-8b.tiff",
    "tests/fixtures/uncompressed/palette-1c-8b.tiff",
    "tests/fixtures/lzw/strike.tif",
    "tests/fixtures/deflate/deflate-last-strip.tiff",
    "tests/fixtures/packbits/cramps.tif",
    "tests/fixtures/zstd/rgb_zstd.tif",
    "tests/fixtures/lerc/gray16_lerc.tif",
    "tests/fixtures/ccitt_g3/fax2d.tif",
    "tests/fixtures/ccitt_g4/scan_petes_book.tif",
    "tests/fixtures/jpeg/rgb-jpeg.tif",
    "tests/fixtures/bigtiff/rgb-3c-8b.btf",
    "tests/fixtures/tiled/cramps-tile.tif",
    "tests/fixtures/geotiff/gray16_geotiff.tif",
    "tests/fixtures/photometric/ycbcr.tif",
    "tests/fixtures/photometric/cmyk.tif",
    "tests/fixtures/photometric/rgb16.tif",
    "tests/fixtures/predictor/predictor2_lzw.tif",
    "tests/fixtures/predictor/predictor3_deflate_fp32.tif",
};

/// Fixtures kept OUT of the robustness mutation sweep (they REMAIN in the
/// specificity corpus). Each entry is a live, tracked TODO: remove it once the
/// underlying dependency crash is fixed. The `./fuzz` script echoes this set so
/// the dropped coverage is visible, never silent.
const robustness_excluded = [_][]const u8{
    // jpegz `decodeBlockCoefficients` (baseline.zig:850) index-OOB on corrupt
    // JPEG entropy data, reached via tiffz Compression=7 → jpegz.validate.
    // Reported to jpegz 2026-08-11.
    "tests/fixtures/jpeg/rgb-jpeg.tif",
};

fn excludedFromRobustness(path: []const u8) bool {
    for (robustness_excluded) |ex| {
        if (std.mem.eql(u8, ex, path)) return true;
    }
    return false;
}

fn loadFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.testing.io;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buf);
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    try file_reader.interface.readSliceAll(buf);
    return buf;
}

/// Run tiffz's full validation over `bytes`. Returns true iff it VALIDATED
/// (open + validateAllStripsAndTiles both returned without error), false on any
/// rejection. It must never crash: a rejection is a clean `false`, whereas a
/// panic / UB (only reachable via a real tiffz bug) aborts the test — the point
/// of the robustness sweep. Uses default Limits so corrupted counts can't drive
/// an unbounded allocation.
fn tiffzValidates(allocator: std.mem.Allocator, bytes: []const u8, limits: tiffz.Limits) bool {
    var handle = tiffz.source.BufferHandle.init(bytes);
    const source = tiffz.Source.fromBuffer(&handle);
    var dec = tiffz.Decoder.openWithLimits(allocator, source, limits) catch return false;
    defer dec.deinit();
    var workspace = tiffz.Workspace.init(allocator);
    defer workspace.deinit();
    dec.validateAllStripsAndTiles(&workspace) catch return false;
    return true;
}

/// Bounded limits for the robustness sweep only. The defaults allow ~1 GB per
/// strip, so a mutation claiming a huge decoded size spikes RSS; capping at
/// 256 MB bounds memory in CI. The no-crash property is limit-independent (a
/// bad index / overflow doesn't depend on the cap), so this doesn't weaken it.
/// Specificity below uses the REAL defaults, holding genuine fixtures to
/// production behavior (16 MB was too tight — `scan_petes_book.tif` legitimately
/// decodes past it).
const fuzz_robustness_limits: tiffz.Limits = .{
    .max_decompressed_strip_bytes = 256 << 20,
    .max_compressed_strip_bytes = 256 << 20,
    .max_codec_scratch = 64 << 20,
};

// ─────────────────────────────────────────────────────────────────────
// Property 3: the mutators are non-vacuous (tested before we trust them).
// ─────────────────────────────────────────────────────────────────────

test "mutation: snipe changes exactly one byte and always changes it" {
    var buf = [_]u8{ 0x00, 0x11, 0x22, 0x33, 0x44 };
    const before = buf;
    snipe(&buf, 2, 0x00); // mask 0 → XOR 1, still guaranteed to change
    try std.testing.expect(buf[2] != before[2]);
    try std.testing.expectEqual(before[0], buf[0]);
    try std.testing.expectEqual(before[1], buf[1]);
    try std.testing.expectEqual(before[3], buf[3]);
    try std.testing.expectEqual(before[4], buf[4]);
}

test "mutation: boltgun overwrites the field, clamps at end, no OOB" {
    var buf = [_]u8{0xAA} ** 8;
    var prng = std.Random.DefaultPrng.init(1);
    boltgun(&buf, 6, 5, prng.random()); // 6+5 would run past len 8 → clamp
    // bytes before the field are untouched; the last two are within range and
    // were written from the PRNG (may equal 0xAA by chance, but the call must
    // not write past index 7 — proven by this test not tripping ReleaseSafe).
    try std.testing.expectEqual(@as(u8, 0xAA), buf[0]);
    try std.testing.expectEqual(@as(u8, 0xAA), buf[5]);
}

test "mutation: shotgun with a fixed seed changes the buffer" {
    var buf = [_]u8{0x00} ** 64;
    const before = buf;
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    shotgun(&buf, prng.random(), 5);
    try std.testing.expect(!std.mem.eql(u8, &before, &buf)); // not a no-op
}

// ─────────────────────────────────────────────────────────────────────
// Property 2: specificity — every known-good seed validates unmutated.
// ─────────────────────────────────────────────────────────────────────

test "fuzz specificity: every seed fixture validates unmutated" {
    const allocator = std.testing.allocator;
    for (seed_corpus) |path| {
        const bytes = try loadFile(allocator, path);
        defer allocator.free(bytes);
        if (!tiffzValidates(allocator, bytes, tiffz.Limits.default)) {
            std.debug.print("specificity FAIL: known-good seed rejected: {s}\n", .{path});
            return error.SpecificityCorpusRejected;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Property 1: robustness — seeded mutations never crash tiffz.
// ─────────────────────────────────────────────────────────────────────

test "fuzz robustness: seeded mutations never crash the validator" {
    const allocator = std.testing.allocator;
    // Fixed seed → identical mutation stream on every run and machine.
    var prng = std.Random.DefaultPrng.init(0x7217_F221_2026_0805);
    const rng = prng.random();

    const iterations_per_seed = 200;
    for (seed_corpus) |path| {
        // Robustness exclusion (tracked TODO, not a silent skip): mutating a
        // real embedded-JPEG strip drives tiffz's Compression=7 path into
        // `jpegz.validate`, which currently PANICS (index-OOB in jpegz
        // decodeBlockCoefficients, baseline.zig:850) on corrupt entropy data
        // instead of returning an error. That is a jpegz robustness bug, not
        // tiffz's — and a panic can't be caught, so the sweep can't test past
        // it. Reported to jpegz 2026-08-11 (inbox note). Re-include this fixture
        // once the jpegz pin carries the fix. It STAYS in the specificity corpus
        // above: the pristine JPEG validates fine.
        if (excludedFromRobustness(path)) continue;

        const original = try loadFile(allocator, path);
        defer allocator.free(original);
        if (original.len == 0) continue;

        var it: usize = 0;
        while (it < iterations_per_seed) : (it += 1) {
            const buf = try allocator.dupe(u8, original);
            defer allocator.free(buf);

            // Bias half the mutations toward the structural region (header +
            // IFD live in the first bytes) so the parser's error paths get hit,
            // not only pixel-data bytes it never inspects.
            const structural = it % 2 == 0;
            const span: usize = if (structural) @min(@as(usize, 256), buf.len) else buf.len;

            switch (it % 3) {
                0 => snipe(buf, rng.uintLessThan(usize, span), rng.int(u8)),
                1 => shotgun(buf, rng, 1 + rng.uintLessThan(usize, 8)),
                2 => boltgun(buf, rng.uintLessThan(usize, span), 8, rng),
                else => unreachable,
            }
            // Verdict is irrelevant here; the assertion is "did not crash".
            _ = tiffzValidates(allocator, buf, fuzz_robustness_limits);
        }
    }
}
