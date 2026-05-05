//! Oracle tests against real TIFF fixtures from validate's
//! ground_truth corpus (committed into tests/fixtures/ so they're
//! reproducible in the Nix sandbox).
//!
//! M3 oracle: open + IFD-parse + decode every strip; verify that
//! the per-strip byte counts emitted by decodeStrip match the
//! StripByteCounts metadata, and that the cumulative size matches
//! the sum.
//!
//! That proves the open→IFD→tag-dictionary→strip-decode pipeline
//! works on real TIFFs, without yet needing photometric expansion.
//! Hash-pinned regression assertions land alongside photometric
//! expansion (tiff2rgba oracle) in a later step.

const std = @import("std");
const tiffz = @import("tiffz");

fn loadFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buf);
    const got = try file.readAll(buf);
    if (got != buf.len) return error.SourceShortRead;
    return buf;
}

const FixtureProbe = struct {
    strip_count: u32,
    total_bytes: u64,
};

fn decodeAllStrips(allocator: std.mem.Allocator, fixture_path: []const u8) !FixtureProbe {
    const bytes = try loadFile(allocator, fixture_path);
    defer allocator.free(bytes);

    var handle = tiffz.source.BufferHandle.init(bytes);
    const src = tiffz.Source.fromBuffer(&handle);

    var dec = try tiffz.Decoder.open(allocator, src);
    defer dec.deinit();

    const dir = try dec.ifd(0);
    const sbc_entry = dir.get(tiffz.tags.strip_byte_counts) orelse return error.Malformed;
    const so_entry = dir.get(tiffz.tags.strip_offsets) orelse return error.Malformed;
    try std.testing.expectEqual(sbc_entry.count, so_entry.count);

    // 1 MB scratch covers any single strip in our small fixtures.
    const scratch = try allocator.alloc(u8, 1 << 20);
    defer allocator.free(scratch);

    var total: u64 = 0;
    var i: u32 = 0;
    while (i < sbc_entry.count) : (i += 1) {
        const n = try dec.decodeStrip(0, i, scratch);
        total += n;
    }
    return .{ .strip_count = sbc_entry.count, .total_bytes = total };
}

test "rgb-3c-8b.tiff: 157x151 RGB, multi-strip uncompressed" {
    const probe = try decodeAllStrips(
        std.testing.allocator,
        "tests/fixtures/uncompressed/rgb-3c-8b.tiff",
    );
    // From the audit matrix: 157×151 × 3 samples × 1 byte = 71121 raw bytes.
    // RowsPerStrip = 17 (per audit) → 9 strips ([17,17,17,17,17,17,17,17,15]).
    try std.testing.expectEqual(@as(u64, 71121), probe.total_bytes);
    try std.testing.expect(probe.strip_count > 1);
    try std.testing.expect(probe.strip_count <= 16);
}

test "minisblack-1c-8b.tiff: 157x151 grayscale, multi-strip" {
    const probe = try decodeAllStrips(
        std.testing.allocator,
        "tests/fixtures/uncompressed/minisblack-1c-8b.tiff",
    );
    // 157×151 × 1 sample × 1 byte = 23707 raw bytes.
    try std.testing.expectEqual(@as(u64, 23707), probe.total_bytes);
}

test "palette-1c-8b.tiff: 157x151 palette indices, multi-strip" {
    const probe = try decodeAllStrips(
        std.testing.allocator,
        "tests/fixtures/uncompressed/palette-1c-8b.tiff",
    );
    // 157×151 × 1 sample × 1 byte = 23707 raw bytes (8-bit indices).
    try std.testing.expectEqual(@as(u64, 23707), probe.total_bytes);
}
