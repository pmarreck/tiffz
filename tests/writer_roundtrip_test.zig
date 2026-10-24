//! Writer round trips through code the writer does not share: tiffz's
//! decoder (open, validate, RGBA expansion) and lzwz's TIFF LZW decoder.
//! The independent libtiff oracle runs from the CLI suite.

const std = @import("std");
const tiffz = @import("tiffz");
const writer = tiffz.writer;

const testing = std.testing;

fn noise(allocator: std.mem.Allocator, len: usize, seed: u64, levels: u8) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    const p = try allocator.alloc(u8, len);
    // `levels` limits the alphabet so LZW finds repeats; 0 means all bytes.
    for (p) |*x| x.* = if (levels == 0) r.int(u8) else r.uintLessThan(u8, levels) *% 37;
    return p;
}

/// Expected 8-bit RGBA for writer input: gray replicates, alpha defaults to 255.
fn expectedRgba(allocator: std.mem.Allocator, px: []const u8, channels: writer.Channels) ![]u8 {
    const spp: usize = @intFromEnum(channels);
    const n = px.len / spp;
    const out = try allocator.alloc(u8, n * 4);
    for (0..n) |i| {
        const s = px[i * spp ..][0..spp];
        out[i * 4 ..][0..4].* = switch (channels) {
            .gray => .{ s[0], s[0], s[0], 255 },
            .rgb => .{ s[0], s[1], s[2], 255 },
            .rgba => .{ s[0], s[1], s[2], s[3] },
        };
    }
    return out;
}

fn roundTrip(width: u32, height: u32, channels: writer.Channels, compression: writer.Compression, seed: u64, levels: u8) !void {
    const allocator = testing.allocator;
    const len = @as(usize, width) * height * @intFromEnum(channels);
    const px = try noise(allocator, len, seed, levels);
    defer allocator.free(px);
    const tif = try writer.encode(allocator, px, width, height, channels, compression);
    defer allocator.free(tif);

    var handle = tiffz.source.BufferHandle.init(tif);
    var dec = try tiffz.Decoder.open(allocator, tiffz.Source.fromBuffer(&handle));
    defer dec.deinit();
    var ws = tiffz.Workspace.init(allocator);
    defer ws.deinit();
    try dec.validateAllStripsAndTiles(&ws);

    const img = try tiffz.rgba.decodeIfdToRgba(allocator, &dec, &ws, 0);
    defer allocator.free(img.pixels);
    try testing.expectEqual(width, img.width);
    try testing.expectEqual(height, img.height);
    const want = try expectedRgba(allocator, px, channels);
    defer allocator.free(want);
    try testing.expectEqualSlices(u8, want, img.pixels);
}

test "every channel layout and compression round-trips through tiffz's decoder" {
    inline for (.{ writer.Channels.gray, writer.Channels.rgb, writer.Channels.rgba }) |ch| {
        inline for (.{ writer.Compression.none, writer.Compression.deflate, writer.Compression.lzw }) |comp| {
            try roundTrip(1, 1, ch, comp, 1, 0);
            try roundTrip(37, 11, ch, comp, 2, 0);
            try roundTrip(301, 97, ch, comp, 3, 6); // repetitive: long LZW strings
            try roundTrip(257, 129, ch, comp, 4, 0); // noise: Clear resets
        }
    }
}

/// Every strip of `tif` must decode with lzwz to exactly the matching rows.
fn checkLzwStrips(tif: []const u8, px: []const u8, row_bytes: usize) !void {
    const le32 = struct {
        fn f(b: []const u8, at: usize) u32 {
            return std.mem.readInt(u32, b[at..][0..4], .little);
        }
    }.f;
    const ifd = le32(tif, 4);
    const n = std.mem.readInt(u16, tif[ifd..][0..2], .little);
    var offs: [2]u32 = .{ 0, 0 }; // value, count for 273
    var counts: [2]u32 = .{ 0, 0 };
    var rps: u32 = 0;
    for (0..n) |i| {
        const at = ifd + 2 + i * 12;
        const tag = std.mem.readInt(u16, tif[at..][0..2], .little);
        const count = le32(tif, at + 4);
        const value = le32(tif, at + 8);
        switch (tag) {
            273 => offs = .{ value, count },
            279 => counts = .{ value, count },
            278 => rps = value,
            else => {},
        }
    }
    const rows_total = px.len / row_bytes;
    var row: usize = 0;
    for (0..offs[1]) |i| {
        const o = if (offs[1] == 1) offs[0] else le32(tif, offs[0] + i * 4);
        const c = if (counts[1] == 1) counts[0] else le32(tif, counts[0] + i * 4);
        const rows = @min(rps, rows_total - row);
        const want = px[row * row_bytes .. (row + rows) * row_bytes];
        const got = try testing.allocator.alloc(u8, want.len);
        defer testing.allocator.free(got);
        const report = try tiffz.lzwz.decode(tiffz.lzwz.Profile.tiff6(), tif[o .. o + c], got);
        try testing.expectEqual(want.len, report.decoded_len);
        try testing.expectEqual(@as(usize, c), report.bytesConsumed()); // EOI ends the strip
        try testing.expectEqualSlices(u8, want, got);
        row += rows;
    }
    try testing.expectEqual(rows_total, row);
}

test "LZW strips decode with lzwz's independent TIFF 6 decoder" {
    for ([_]u8{ 0, 2, 17 }, 0..) |levels, seed| {
        const px = try noise(testing.allocator, 1024 * 64, seed + 10, levels);
        defer testing.allocator.free(px);
        const tif = try writer.encode(testing.allocator, px, 1024, 64, .gray, .lzw);
        defer testing.allocator.free(tif);
        try checkLzwStrips(tif, px, 1024);
    }
}
