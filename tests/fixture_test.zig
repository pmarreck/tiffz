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

/// Read scalar u16 tag (count==1, SHORT or LONG-tolerant).
fn ifdScalarU16(dir: *const tiffz.ifd.Ifd, tag: u16, endian: tiffz.header.Endian) ?u16 {
    const e = dir.get(tag) orelse return null;
    if (e.count != 1) return null;
    return switch (e.field_type) {
        .short => tiffz.header.readU16(e.raw_value_or_offset[0..2], endian),
        .long => @intCast(tiffz.header.readU32(&e.raw_value_or_offset, endian)),
        else => null,
    };
}

fn ifdScalarU32(dir: *const tiffz.ifd.Ifd, tag: u16, endian: tiffz.header.Endian) ?u32 {
    const e = dir.get(tag) orelse return null;
    if (e.count != 1) return null;
    return switch (e.field_type) {
        .short => @intCast(tiffz.header.readU16(e.raw_value_or_offset[0..2], endian)),
        .long => tiffz.header.readU32(&e.raw_value_or_offset, endian),
        else => null,
    };
}

/// Decode all strips of IFD0, photometric-expand to RGBA, return the
/// fresh allocation. Caller frees.
fn decodeFixtureToRgba(allocator: std.mem.Allocator, fixture_path: []const u8) ![]u8 {
    const bytes = try loadFile(allocator, fixture_path);
    defer allocator.free(bytes);

    var handle = tiffz.source.BufferHandle.init(bytes);
    const src = tiffz.Source.fromBuffer(&handle);

    var dec = try tiffz.Decoder.open(allocator, src);
    defer dec.deinit();

    const dir = try dec.ifd(0);

    // Required scalars for M3 photometric expansion.
    const width = ifdScalarU32(dir, tiffz.tags.image_width, dec.endian) orelse return error.Malformed;
    const height = ifdScalarU32(dir, tiffz.tags.image_length, dec.endian) orelse return error.Malformed;
    const photometric = ifdScalarU16(dir, tiffz.tags.photometric, dec.endian) orelse return error.Malformed;
    const samples_per_pixel = ifdScalarU16(dir, tiffz.tags.samples_per_pixel, dec.endian) orelse 1;
    // RowsPerStrip = (uint32)-1 means "all rows in one strip" (the
    // fax convention via the "(infinite)" tiffinfo display).
    // Clamp to the image height so downstream allocations don't
    // try to reserve 4 GB × bytes-per-row.
    const rps_raw = ifdScalarU32(dir, tiffz.tags.rows_per_strip, dec.endian) orelse height;
    const rows_per_strip: u32 = if (rps_raw > height) height else rps_raw;

    // BitsPerSample: per-sample SHORT array. Take the first; assume
    // uniform across samples for M3 (SamplesPerPixel ≤ 4).
    var bits_per_sample: u16 = 8;
    if (dir.get(tiffz.tags.bits_per_sample)) |bps_entry| {
        var buf: [16]u8 = undefined;
        const need: usize = @as(usize, bps_entry.field_type.elementBytes()) * @as(usize, bps_entry.count);
        if (need > buf.len) return error.Malformed;
        try tiffz.ifd.Ifd.readEntryValue(bps_entry.*, dec.endian, src, buf[0..need]);
        bits_per_sample = tiffz.header.readU16(buf[0..2], dec.endian);
    }

    // ColorMap (palette only) — 3 × 2^bits_per_sample u16 values.
    var cmap_buf: ?[]u16 = null;
    defer if (cmap_buf) |c| allocator.free(c);
    if (photometric == tiffz.tags.photometric_palette) {
        const cmap_entry = dir.get(tiffz.tags.colormap) orelse return error.Malformed;
        const palette_size: usize = @as(usize, 1) << @intCast(bits_per_sample);
        const expected_count: u32 = @intCast(3 * palette_size);
        if (cmap_entry.count != expected_count) return error.Malformed;
        const need_bytes: usize = @as(usize, expected_count) * 2;
        const raw = try allocator.alloc(u8, need_bytes);
        defer allocator.free(raw);
        try tiffz.ifd.Ifd.readEntryValue(cmap_entry.*, dec.endian, src, raw);
        const cmap16 = try allocator.alloc(u16, expected_count);
        for (cmap16, 0..) |*v, i| {
            v.* = tiffz.header.readU16(raw[i * 2 ..][0..2], dec.endian);
        }
        cmap_buf = cmap16;
    }

    const fmt: tiffz.photometrics.PixelFormat = .{
        .photometric = photometric,
        .bits_per_sample = bits_per_sample,
        .samples_per_pixel = samples_per_pixel,
        .width = width,
        .colormap = cmap_buf,
    };

    // Output buffer: width × height × 4 (RGBA).
    const rgba_total: usize = @as(usize, width) * @as(usize, height) * 4;
    const rgba = try allocator.alloc(u8, rgba_total);
    errdefer allocator.free(rgba);

    // Strip scratch — sized to the maximum decompressed strip.
    // bytes-per-row = ceil(width * samples * bits / 8); strip-bytes
    // = rows_per_strip × that. Sub-byte bits_per_sample (1 for fax)
    // would round to zero with naive `(bits/8)` integer arithmetic.
    const row_bits: usize = @as(usize, width) * @as(usize, samples_per_pixel) * @as(usize, bits_per_sample);
    const row_bytes: usize = (row_bits + 7) / 8;
    const strip_max: usize = row_bytes * rows_per_strip;
    const strip_buf = try allocator.alloc(u8, strip_max);
    defer allocator.free(strip_buf);

    var ws = tiffz.Workspace.init(allocator);
    defer ws.deinit();

    const sbc_entry = dir.get(tiffz.tags.strip_byte_counts) orelse return error.Malformed;
    var rgba_offset: usize = 0;
    var strip_index: u32 = 0;
    var rows_done: u32 = 0;
    while (strip_index < sbc_entry.count) : (strip_index += 1) {
        const n = try dec.decodeStrip(0, strip_index, strip_buf, &ws);
        const this_strip_rows: u32 = blk: {
            const remaining = height - rows_done;
            break :blk @min(rows_per_strip, remaining);
        };
        try tiffz.photometrics.expandRowsToRgba(
            strip_buf[0..n],
            this_strip_rows,
            fmt,
            rgba[rgba_offset..],
        );
        rgba_offset += @as(usize, this_strip_rows) * width * 4;
        rows_done += this_strip_rows;
    }

    return rgba;
}

fn assertOracleMatch(allocator: std.mem.Allocator, fixture_path: []const u8, oracle_path: []const u8) !void {
    const got = try decodeFixtureToRgba(allocator, fixture_path);
    defer allocator.free(got);
    const expected = try loadFile(allocator, oracle_path);
    defer allocator.free(expected);

    if (got.len != expected.len or !std.mem.eql(u8, got, expected)) {
        var first_diff: usize = 0;
        const min_len = @min(got.len, expected.len);
        while (first_diff < min_len and got[first_diff] == expected[first_diff]) first_diff += 1;
        std.debug.print("\nZZ {s}: got_len={d} exp_len={d} first_diff={d}\n", .{ fixture_path, got.len, expected.len, first_diff });
        const cs = first_diff -| 4;
        const ce = @min(first_diff + 24, min_len);
        std.debug.print("ZZ G", .{});
        for (got[cs..ce]) |b| std.debug.print(" {x:0>2}", .{b});
        std.debug.print("\nZZ E", .{});
        for (expected[cs..ce]) |b| std.debug.print(" {x:0>2}", .{b});
        std.debug.print("\n", .{});
    }
    try std.testing.expectEqualSlices(u8, expected, got);
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

    var ws = tiffz.Workspace.init(allocator);
    defer ws.deinit();

    var total: u64 = 0;
    var i: u32 = 0;
    while (i < sbc_entry.count) : (i += 1) {
        const n = try dec.decodeStrip(0, i, scratch, &ws);
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
    try std.testing.expectEqual(@as(u64, 71121), probe.total_bytes);
    try std.testing.expect(probe.strip_count > 1);
    try std.testing.expect(probe.strip_count <= 16);
}

test "minisblack-1c-8b.tiff: 157x151 grayscale, multi-strip" {
    const probe = try decodeAllStrips(
        std.testing.allocator,
        "tests/fixtures/uncompressed/minisblack-1c-8b.tiff",
    );
    try std.testing.expectEqual(@as(u64, 23707), probe.total_bytes);
}

test "palette-1c-8b.tiff: 157x151 palette indices, multi-strip" {
    const probe = try decodeAllStrips(
        std.testing.allocator,
        "tests/fixtures/uncompressed/palette-1c-8b.tiff",
    );
    try std.testing.expectEqual(@as(u64, 23707), probe.total_bytes);
}

test "rgb-3c-8b.tiff: photometric-expanded RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/uncompressed/rgb-3c-8b.tiff",
        "tests/fixtures/uncompressed_oracle/rgb-3c-8b.rgba",
    );
}

test "minisblack-1c-8b.tiff: photometric-expanded RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/uncompressed/minisblack-1c-8b.tiff",
        "tests/fixtures/uncompressed_oracle/minisblack-1c-8b.rgba",
    );
}

test "palette-1c-8b.tiff: photometric-expanded RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/uncompressed/palette-1c-8b.tiff",
        "tests/fixtures/uncompressed_oracle/palette-1c-8b.rgba",
    );
}

test "cramps.tif (PackBits, 800x607 MinIsWhite): RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/packbits/cramps.tif",
        "tests/fixtures/packbits_oracle/cramps.rgba",
    );
}

test "at3_1m4_01_rgb.tif (PackBits, 640x480 MinIsBlack): RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/packbits/at3_1m4_01_rgb.tif",
        "tests/fixtures/packbits_oracle/at3_1m4_01_rgb.rgba",
    );
}

test "fax2d.tif (CCITT G3 1D, 1728x1082 MinIsWhite LSB-first): RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/ccitt_g3/fax2d.tif",
        "tests/fixtures/ccitt_g3_oracle/fax2d.rgba",
    );
}

test "deflate-last-strip.tiff (Deflate, 500x500 MinIsBlack, little-endian): RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/deflate/deflate-last-strip.tiff",
        "tests/fixtures/deflate_oracle/deflate-last-strip.rgba",
    );
}

test "bali.tif (LZW, 725x489 palette, big-endian): RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/lzw/bali.tif",
        "tests/fixtures/lzw_oracle/bali.rgba",
    );
}

// quad-lzw.tif: deferred. Triggers ImageMagick's "Old-style LZW codes,
// convert file" warning. Both my new-style (MSB-first + early-change)
// and old-style (LSB-first + late-change) decode paths return Malformed
// on this file. Likely needs an additional variant combination or a
// libtiff-style pre-decode header sniff (the LZWFixupTags path in
// tif_lzw.c) to pick the right combo. Deferred to a follow-up; bali
// + strike's other-issue prove the basic LZW path works.
//
// strike.tif: deferred. Has ExtraSamples=1 (assoc-alpha = pre-multiplied
// alpha per TIFF 6.0 §18). My LZW decode produces the literal stored
// bytes (e.g. R = 0x80 × A = 0x02 / 255 ≈ 0x01); ImageMagick's RGBA:
// output un-pre-multiplies (so R = 0x80 stays 0x80). Need un-pre-multiply
// step keyed on ExtraSamples tag. Deferred to M9 (Pro photometrics)
// where assoc/unassoc alpha lands properly.
