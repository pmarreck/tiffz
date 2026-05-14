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

    const width = ifdScalarU32(dir, tiffz.tags.image_width, dec.endian) orelse return error.Malformed;
    const height = ifdScalarU32(dir, tiffz.tags.image_length, dec.endian) orelse return error.Malformed;
    const photometric = ifdScalarU16(dir, tiffz.tags.photometric, dec.endian) orelse return error.Malformed;
    const samples_per_pixel = ifdScalarU16(dir, tiffz.tags.samples_per_pixel, dec.endian) orelse 1;
    // RowsPerStrip = (uint32)-1 means "all rows in one strip" (the
    // fax convention via the "(infinite)" tiffinfo display). Clamp to
    // the image height so downstream allocations don't try to reserve
    // 4 GB × bytes-per-row.
    const rps_raw = ifdScalarU32(dir, tiffz.tags.rows_per_strip, dec.endian) orelse height;
    const rows_per_strip: u32 = if (rps_raw > height) height else rps_raw;

    // BitsPerSample: per-sample SHORT array. Take the first; assume
    // uniform across samples (SamplesPerPixel ≤ 4).
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

    var ws = tiffz.Workspace.init(allocator);
    defer ws.deinit();

    // Detect tile vs strip layout. TIFF doesn't allow both.
    const is_tiled = dir.get(tiffz.tags.tile_offsets) != null;
    if (is_tiled) {
        try decodeTiledIntoRgba(allocator, &dec, fmt, rgba, &ws, width, height, samples_per_pixel, bits_per_sample);
    } else {
        try decodeStrippedIntoRgba(allocator, &dec, fmt, rgba, &ws, width, height, samples_per_pixel, bits_per_sample, rows_per_strip);
    }

    return rgba;
}

fn decodeStrippedIntoRgba(
    allocator: std.mem.Allocator,
    dec: *tiffz.Decoder,
    fmt: tiffz.photometrics.PixelFormat,
    rgba: []u8,
    ws: *tiffz.Workspace,
    width: u32,
    height: u32,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    rows_per_strip: u32,
) !void {
    const row_bits: usize = @as(usize, width) * @as(usize, samples_per_pixel) * @as(usize, bits_per_sample);
    const row_bytes: usize = (row_bits + 7) / 8;
    const strip_max: usize = row_bytes * rows_per_strip;
    const strip_buf = try allocator.alloc(u8, strip_max);
    defer allocator.free(strip_buf);

    const dir = try dec.ifd(0);
    const sbc_entry = dir.get(tiffz.tags.strip_byte_counts) orelse return error.Malformed;
    var rgba_offset: usize = 0;
    var strip_index: u32 = 0;
    var rows_done: u32 = 0;
    while (strip_index < sbc_entry.count) : (strip_index += 1) {
        const n = try dec.decodeStrip(0, strip_index, strip_buf, ws);
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
}

fn decodeTiledIntoRgba(
    allocator: std.mem.Allocator,
    dec: *tiffz.Decoder,
    fmt: tiffz.photometrics.PixelFormat,
    rgba: []u8,
    ws: *tiffz.Workspace,
    width: u32,
    height: u32,
    samples_per_pixel: u16,
    bits_per_sample: u16,
) !void {
    const dir = try dec.ifd(0);
    const tile_w = ifdScalarU32(dir, tiffz.tags.tile_width, dec.endian) orelse return error.Malformed;
    const tile_h = ifdScalarU32(dir, tiffz.tags.tile_length, dec.endian) orelse return error.Malformed;

    // Per-tile scratch buffers: decoded bytes + RGBA expansion.
    const tile_row_bits: usize = @as(usize, tile_w) * @as(usize, samples_per_pixel) * @as(usize, bits_per_sample);
    const tile_row_bytes: usize = (tile_row_bits + 7) / 8;
    const tile_decoded_bytes: usize = tile_row_bytes * tile_h;
    const tile_buf = try allocator.alloc(u8, tile_decoded_bytes);
    defer allocator.free(tile_buf);

    const tile_rgba_bytes: usize = @as(usize, tile_w) * tile_h * 4;
    const tile_rgba = try allocator.alloc(u8, tile_rgba_bytes);
    defer allocator.free(tile_rgba);

    // PixelFormat for tile expansion — same as image fmt but width
    // is tile_w (so expandRowsToRgba knows the per-row pixel count).
    var tile_fmt = fmt;
    tile_fmt.width = tile_w;

    const tiles_across: u32 = (width + tile_w - 1) / tile_w;
    const tiles_down: u32 = (height + tile_h - 1) / tile_h;

    var ty: u32 = 0;
    while (ty < tiles_down) : (ty += 1) {
        var tx: u32 = 0;
        while (tx < tiles_across) : (tx += 1) {
            const tile_index = ty * tiles_across + tx;
            const n = try dec.decodeTile(0, tile_index, tile_buf, ws);
            try tiffz.photometrics.expandRowsToRgba(
                tile_buf[0..n],
                tile_h,
                tile_fmt,
                tile_rgba,
            );
            // Copy in-image portion of the tile RGBA into the full
            // image RGBA. Edge tiles may have less than tile_w/tile_h
            // pixels visible.
            const origin_x = tx * tile_w;
            const origin_y = ty * tile_h;
            const visible_w: u32 = @min(tile_w, width - origin_x);
            const visible_h: u32 = @min(tile_h, height - origin_y);
            var row: u32 = 0;
            while (row < visible_h) : (row += 1) {
                const src_off = @as(usize, row) * tile_w * 4;
                const dst_off = (@as(usize, origin_y + row) * width + origin_x) * 4;
                @memcpy(rgba[dst_off..][0 .. @as(usize, visible_w) * 4], tile_rgba[src_off..][0 .. @as(usize, visible_w) * 4]);
            }
        }
    }
}

fn assertOracleMatch(allocator: std.mem.Allocator, fixture_path: []const u8, oracle_path: []const u8) !void {
    const got = try decodeFixtureToRgba(allocator, fixture_path);
    defer allocator.free(got);
    const expected = try loadFile(allocator, oracle_path);
    defer allocator.free(expected);

    if (got.len != expected.len) {
        std.debug.print("\n[mismatch-len] {s}: got_len={d} exp_len={d}\n", .{ fixture_path, got.len, expected.len });
        return error.TestExpectedEqual;
    }
    if (!std.mem.eql(u8, got, expected)) {
        var first_diff: usize = 0;
        while (first_diff < got.len and got[first_diff] == expected[first_diff]) first_diff += 1;
        std.debug.print("\n[mismatch] {s}: len={d} first_diff={d} (0x{x})\n", .{ fixture_path, got.len, first_diff, first_diff });
        const cs = first_diff -| 4;
        const ce = @min(first_diff + 24, got.len);
        std.debug.print("  got     [{d}..{d}]: ", .{ cs, ce });
        for (got[cs..ce]) |b| std.debug.print("{x:0>2} ", .{b});
        std.debug.print("\n  expected[{d}..{d}]: ", .{ cs, ce });
        for (expected[cs..ce]) |b| std.debug.print("{x:0>2} ", .{b});
        std.debug.print("\n", .{});
        return error.TestExpectedEqual;
    }
}

/// Hash-pinned oracle for fixtures whose .rgba is too large to
/// commit. Decodes + photometric-expands the fixture and compares
/// the SHA-256 of the result to the pinned digest. Mismatch =
/// decoder regression; regenerate by hashing the ImageMagick oracle
/// output and updating the pinned digest.
fn assertOracleHashMatch(
    allocator: std.mem.Allocator,
    fixture_path: []const u8,
    expected_digest: [32]u8,
) !void {
    const got = try decodeFixtureToRgba(allocator, fixture_path);
    defer allocator.free(got);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(got);
    var actual: [32]u8 = undefined;
    hasher.final(&actual);
    try std.testing.expectEqualSlices(u8, &expected_digest, &actual);
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

test "predictor1_lzw.tif (LZW + Predictor=1 no-op, 32x32 RGB): RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/predictor/predictor1_lzw.tif",
        "tests/fixtures/predictor_oracle/predictor1_lzw.rgba",
    );
}

test "predictor2_lzw.tif (LZW + Predictor=2 horizontal, 32x32 RGB): RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/predictor/predictor2_lzw.tif",
        "tests/fixtures/predictor_oracle/predictor2_lzw.rgba",
    );
}

test "predictor2_deflate.tif (Deflate + Predictor=2 horizontal, 32x32 RGB): RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/predictor/predictor2_deflate.tif",
        "tests/fixtures/predictor_oracle/predictor2_deflate.rgba",
    );
}

test "cramps-tile.tif (uncompressed tiled, 800x607 MinIsWhite, 256x256 tiles): RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/tiled/cramps-tile.tif",
        "tests/fixtures/tiled_oracle/cramps-tile.rgba",
    );
}

test "quad-tile.tif (LZW tiled, 512x384 RGB, 128x128 tiles): RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/tiled/quad-tile.tif",
        "tests/fixtures/tiled_oracle/quad-tile.rgba",
    );
}

test "scan_petes_book.tif (CCITT G4 marquee, 11059x15671): RGBA matches pinned ImageMagick oracle SHA-256" {
    // Marquee target for M4-E: 1-bit fax-style scan that drifts after
    // row 1030 in zigimg PR #321. ~1.3 MB compressed → ~693 MB RGBA
    // when expanded; oracle isn't committed (way too big) — pinned
    // SHA-256 4514c30c… captured from a known-good `magick … RGBA:`
    // run on 2026-05-13.
    const expected_digest: [32]u8 = .{
        0x45, 0x14, 0xc3, 0x0c, 0x83, 0xb6, 0x32, 0xe1,
        0x7f, 0xff, 0xff, 0x95, 0xba, 0x72, 0xd4, 0x1e,
        0x01, 0x97, 0xdd, 0x2d, 0xf9, 0x9c, 0xa7, 0x0d,
        0x5e, 0xa4, 0xb3, 0x68, 0x47, 0xe1, 0x13, 0x7c,
    };
    try assertOracleHashMatch(
        std.testing.allocator,
        "tests/fixtures/ccitt_g4/scan_petes_book.tif",
        expected_digest,
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
