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
        try dir.readEntryValueCached(tiffz.tags.bits_per_sample, dec.endian, src, buf[0..need]);
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
        try dir.readEntryValueCached(tiffz.tags.colormap, dec.endian, src, raw);
        const cmap16 = try allocator.alloc(u16, expected_count);
        for (cmap16, 0..) |*v, i| {
            v.* = tiffz.header.readU16(raw[i * 2 ..][0..2], dec.endian);
        }
        cmap_buf = cmap16;
    }

    // JPEG-in-TIFF with photometric=YCbCr quirk: libjpeg performs the
    // YCbCr→RGB conversion internally during decode, so the bytes
    // emitted by Decoder.decodeStrip are RGB regardless of the TIFF
    // photometric tag. Override here so expandRowsToRgba treats the
    // strip as RGB rather than re-applying a (now-incorrect) YCbCr→RGB
    // matrix. Mirrors libtiff TIFFReadRGBAImage behavior.
    const compression = ifdScalarU16(dir, tiffz.tags.compression, dec.endian) orelse tiffz.tags.compression_none;
    const effective_photometric: u16 = if (compression == tiffz.tags.compression_jpeg and photometric == tiffz.tags.photometric_ycbcr)
        tiffz.tags.photometric_rgb
    else
        photometric;

    const fmt: tiffz.photometrics.PixelFormat = .{
        .photometric = effective_photometric,
        .bits_per_sample = bits_per_sample,
        .samples_per_pixel = samples_per_pixel,
        .width = width,
        .colormap = cmap_buf,
        .endian = dec.endian,
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
    const dir = try dec.ifd(0);
    const planar = ifdScalarU16(dir, tiffz.tags.planar_configuration, dec.endian) orelse tiffz.tags.planar_chunky;
    if (planar == tiffz.tags.planar_separate) {
        return decodeStrippedSeparateIntoRgba(
            allocator,
            dec,
            fmt,
            rgba,
            ws,
            width,
            height,
            samples_per_pixel,
            bits_per_sample,
            rows_per_strip,
        );
    }

    const row_bits: usize = @as(usize, width) * @as(usize, samples_per_pixel) * @as(usize, bits_per_sample);
    const row_bytes: usize = (row_bits + 7) / 8;
    const strip_max: usize = row_bytes * rows_per_strip;
    const strip_buf = try allocator.alloc(u8, strip_max);
    defer allocator.free(strip_buf);

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

/// Separate-planar decode path. TIFF separate-planar layout:
///   strips_per_plane = ceil(height / rows_per_strip)
///   total strips = strips_per_plane * samples_per_pixel
///   strip k of plane p has index = p * strips_per_plane + k
/// For each row band we decode N plane buffers, interleave them via
/// `interleavePlanesToChunky`, then run expansion.
fn decodeStrippedSeparateIntoRgba(
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
    const sample_bytes: usize = bits_per_sample / 8;
    if (bits_per_sample != 8 and bits_per_sample != 16) return error.UnsupportedBitDepth;

    const strips_per_plane: u32 = (height + rows_per_strip - 1) / rows_per_strip;

    const plane_strip_bytes: usize = @as(usize, width) * @as(usize, rows_per_strip) * sample_bytes;
    const plane_bufs = try allocator.alloc([]u8, samples_per_pixel);
    defer allocator.free(plane_bufs);
    for (plane_bufs) |*pb| {
        pb.* = try allocator.alloc(u8, plane_strip_bytes);
    }
    defer for (plane_bufs) |pb| allocator.free(pb);

    const chunky_strip_bytes: usize = plane_strip_bytes * samples_per_pixel;
    const chunky_buf = try allocator.alloc(u8, chunky_strip_bytes);
    defer allocator.free(chunky_buf);

    var plane_views: []const []const u8 = undefined;
    const plane_views_storage = try allocator.alloc([]const u8, samples_per_pixel);
    defer allocator.free(plane_views_storage);

    var rgba_offset: usize = 0;
    var rows_done: u32 = 0;
    var band: u32 = 0;
    while (band < strips_per_plane) : (band += 1) {
        const this_band_rows: u32 = @min(rows_per_strip, height - rows_done);
        for (0..samples_per_pixel) |p| {
            const strip_index: u32 = @as(u32, @intCast(p)) * strips_per_plane + band;
            const n = try dec.decodeStrip(0, strip_index, plane_bufs[p], ws);
            plane_views_storage[p] = plane_bufs[p][0..n];
        }
        plane_views = plane_views_storage;
        try tiffz.photometrics.interleavePlanesToChunky(
            plane_views,
            this_band_rows,
            width,
            bits_per_sample,
            chunky_buf,
        );
        try tiffz.photometrics.expandRowsToRgba(
            chunky_buf[0 .. @as(usize, this_band_rows) * @as(usize, width) * @as(usize, samples_per_pixel) * sample_bytes],
            this_band_rows,
            fmt,
            rgba[rgba_offset..],
        );
        rgba_offset += @as(usize, this_band_rows) * width * 4;
        rows_done += this_band_rows;
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
    return .{ .strip_count = @intCast(sbc_entry.count), .total_bytes = total };
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

/// Decode every strip of `fixture_path` and concatenate the
/// post-codec, post-predictor bytes into a freshly-allocated slice.
/// Caller frees. Used for fixtures whose photometric expansion isn't
/// supported yet (e.g. FP32) but whose post-decode bytes are still
/// meaningfully verifiable.
fn decodeAllStripsBytes(allocator: std.mem.Allocator, fixture_path: []const u8) ![]u8 {
    const bytes = try loadFile(allocator, fixture_path);
    defer allocator.free(bytes);

    var handle = tiffz.source.BufferHandle.init(bytes);
    const src = tiffz.Source.fromBuffer(&handle);

    var dec = try tiffz.Decoder.open(allocator, src);
    defer dec.deinit();

    const dir = try dec.ifd(0);
    const sbc_entry = dir.get(tiffz.tags.strip_byte_counts) orelse return error.Malformed;

    // 64 KB scratch is plenty for any single strip in our small test fixtures.
    const scratch = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(scratch);

    var ws = tiffz.Workspace.init(allocator);
    defer ws.deinit();

    var collected: std.ArrayListUnmanaged(u8) = .empty;
    errdefer collected.deinit(allocator);

    var i: u32 = 0;
    while (i < sbc_entry.count) : (i += 1) {
        const n = try dec.decodeStrip(0, i, scratch, &ws);
        try collected.appendSlice(allocator, scratch[0..n]);
    }
    return try collected.toOwnedSlice(allocator);
}

test "rgb16.tif (uncompressed 16x16 RGB 16-bit-per-sample): RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/photometric/rgb16.tif",
        "tests/fixtures/photometric_oracle/rgb16.rgba",
    );
}

test "rgb_separate.tif (uncompressed 16x16 RGB 8-bit, planar=separate): RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/photometric/rgb_separate.tif",
        "tests/fixtures/photometric_oracle/rgb_separate.rgba",
    );
}

// ---- finding-callback tests ----

/// Per-test accumulator for INFO findings emitted via the callback API.
/// Lives in a thread-local-friendly shape (the callback gets a pointer
/// to one of these via userdata).
const FindingRecorder = struct {
    findings: std.ArrayListUnmanaged(Record),
    allocator: std.mem.Allocator,

    const Record = struct {
        source: tiffz.findings.SourceDecoder,
        finding_code: i32,
        mapped_finding_code: ?i32,
        verdict: tiffz.findings.Verdict,
        byte_offset: ?u64,
        host_byte_offset: ?u64,
        offset_is_exact: bool,
        payload_u32: ?u32, // decoded from a 4-byte little-endian payload, else null
    };

    fn init(allocator: std.mem.Allocator) FindingRecorder {
        return .{ .findings = .empty, .allocator = allocator };
    }

    fn deinit(self: *FindingRecorder) void {
        self.findings.deinit(self.allocator);
    }

    fn callback(
        userdata: ?*anyopaque,
        source_decoder: i32,
        finding_id: i32,
        mapped_finding_id: i32,
        verdict: i32,
        byte_offset: u64,
        host_byte_offset: u64,
        metadata_flags: u32,
        payload: ?[*]const u8,
        payload_len: usize,
    ) callconv(.c) void {
        const self: *FindingRecorder = @ptrCast(@alignCast(userdata.?));
        const payload_u32: ?u32 = if (payload_len >= 4 and payload != null) blk: {
            const slice = payload.?[0..4];
            break :blk std.mem.readInt(u32, slice, .little);
        } else null;
        self.findings.append(self.allocator, .{
            .source = @enumFromInt(source_decoder),
            .finding_code = finding_id,
            .mapped_finding_code = if ((metadata_flags & tiffz.findings.MetadataFlags.mapped_code_present) != 0)
                mapped_finding_id
            else
                null,
            .verdict = @enumFromInt(verdict),
            .byte_offset = if ((metadata_flags & tiffz.findings.MetadataFlags.byte_offset_present) != 0)
                byte_offset
            else
                null,
            .host_byte_offset = if ((metadata_flags & tiffz.findings.MetadataFlags.host_offset_present) != 0)
                host_byte_offset
            else
                null,
            .offset_is_exact = (metadata_flags & tiffz.findings.MetadataFlags.offset_is_exact) != 0,
            .payload_u32 = payload_u32,
        }) catch unreachable;
    }

    fn has(self: *const FindingRecorder, finding: tiffz.findings.InfoFinding) bool {
        for (self.findings.items) |r| {
            if (r.source == .tiffz and r.finding_code == @intFromEnum(finding)) return true;
        }
        return false;
    }

    fn count(self: *const FindingRecorder, finding: tiffz.findings.InfoFinding) usize {
        var total: usize = 0;
        for (self.findings.items) |r| {
            if (r.source == .tiffz and r.finding_code == @intFromEnum(finding)) total += 1;
        }
        return total;
    }

    fn payloadFor(self: *const FindingRecorder, finding: tiffz.findings.InfoFinding) ?u32 {
        for (self.findings.items) |r| {
            if (r.source == .tiffz and r.finding_code == @intFromEnum(finding)) return r.payload_u32;
        }
        return null;
    }
};

test "finding ABI identity is source plus code and preserves unknown sources" {
    var recorder = FindingRecorder.init(std.testing.allocator);
    defer recorder.deinit();
    FindingRecorder.callback(
        @ptrCast(&recorder),
        @intFromEnum(tiffz.findings.SourceDecoder.tiffz),
        1,
        0,
        @intFromEnum(tiffz.findings.Verdict.valid),
        0,
        0,
        0,
        null,
        0,
    );
    FindingRecorder.callback(
        @ptrCast(&recorder),
        @intFromEnum(tiffz.findings.SourceDecoder.jpegz),
        1,
        0,
        @intFromEnum(tiffz.findings.Verdict.corrupt),
        7,
        107,
        tiffz.findings.MetadataFlags.byte_offset_present |
            tiffz.findings.MetadataFlags.host_offset_present |
            tiffz.findings.MetadataFlags.offset_is_exact,
        null,
        0,
    );
    FindingRecorder.callback(
        @ptrCast(&recorder),
        99,
        1,
        0,
        @intFromEnum(tiffz.findings.Verdict.indeterminate),
        0,
        0,
        0,
        null,
        0,
    );

    try std.testing.expectEqual(@as(usize, 3), recorder.findings.items.len);
    try std.testing.expect(recorder.findings.items[0].source != recorder.findings.items[1].source);
    try std.testing.expectEqual(recorder.findings.items[0].finding_code, recorder.findings.items[1].finding_code);
    try std.testing.expectEqual(@as(i32, 99), @intFromEnum(recorder.findings.items[2].source));
    try std.testing.expectEqual(@as(?u64, 107), recorder.findings.items[1].host_byte_offset);
    try std.testing.expect(recorder.findings.items[1].offset_is_exact);
}

test "strict JPEG-family forwarding preserves mapped code offsets and four-way outcomes" {
    const allocator = std.testing.allocator;
    const bytes = try loadFile(allocator, "tests/fixtures/jpeg/ycbcr_jpeg.tif");
    defer allocator.free(bytes);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const source = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, source);
    defer dec.deinit();
    var recorder = FindingRecorder.init(allocator);
    defer recorder.deinit();
    dec.setFindingCallback(&FindingRecorder.callback, @ptrCast(&recorder));

    var strict = tiffz.jpegz.StrictValidationResult{
        .verdict = .unsupported,
        .format = .jpeg2000,
    };
    defer strict.deinit(allocator);
    try strict.findings.append(allocator, .{
        .source = .jp2z,
        .leaf_code = 177,
        .code = .jp2_unsupported_marker_ignored,
        .severity = .warn,
        .offset = 12,
        .host_offset = 212,
        .offset_is_exact = true,
    });
    try strict.findings.append(allocator, .{
        .source = .libjxlz,
        .leaf_code = 99,
        .code = null,
        .severity = .warn,
        .offset = 7,
        .host_offset = null,
        .offset_is_exact = false,
    });
    // jpegz's own T.81/T.87 leg (validateAny, added 2026-08-06). Classify the
    // whole jpegz verdict range: .fail → corrupt; a recovered deviation
    // (.warn/.info) → valid; the validator-meta code → indeterminate. Mirrors
    // jpegz.strictFromReport + validateAny's unknown/unavailable branches.
    try strict.findings.append(allocator, .{
        .source = .jpegz,
        .leaf_code = 3,
        .code = null,
        .severity = .fail,
        .offset = 5,
        .host_offset = 300,
        .offset_is_exact = true,
    });
    try strict.findings.append(allocator, .{
        .source = .jpegz,
        .leaf_code = 1,
        .code = null,
        .severity = .warn,
    });
    try strict.findings.append(allocator, .{
        .source = .jpegz,
        .leaf_code = @intFromEnum(tiffz.jpegz.FindingCode.unrecognized_container),
        .code = .unrecognized_container,
        .severity = .warn,
    });

    dec.emitStrictValidationFindings(&strict);
    try std.testing.expectEqual(@as(usize, 5), recorder.findings.items.len);
    try std.testing.expectEqual(tiffz.findings.SourceDecoder.jp2z, recorder.findings.items[0].source);
    try std.testing.expectEqual(tiffz.findings.Verdict.unsupported, recorder.findings.items[0].verdict);
    try std.testing.expect(recorder.findings.items[0].mapped_finding_code != null);
    try std.testing.expectEqual(@as(?u64, 212), recorder.findings.items[0].host_byte_offset);
    try std.testing.expect(recorder.findings.items[0].offset_is_exact);
    try std.testing.expectEqual(tiffz.findings.SourceDecoder.libjxlz, recorder.findings.items[1].source);
    try std.testing.expectEqual(tiffz.findings.Verdict.indeterminate, recorder.findings.items[1].verdict);
    try std.testing.expect(recorder.findings.items[1].mapped_finding_code == null);
    // jpegz source identity + verdict split.
    try std.testing.expectEqual(tiffz.findings.SourceDecoder.jpegz, recorder.findings.items[2].source);
    try std.testing.expectEqual(tiffz.findings.Verdict.corrupt, recorder.findings.items[2].verdict);
    try std.testing.expectEqual(tiffz.findings.SourceDecoder.jpegz, recorder.findings.items[3].source);
    try std.testing.expectEqual(tiffz.findings.Verdict.valid, recorder.findings.items[3].verdict);
    try std.testing.expectEqual(tiffz.findings.SourceDecoder.jpegz, recorder.findings.items[4].source);
    try std.testing.expectEqual(tiffz.findings.Verdict.indeterminate, recorder.findings.items[4].verdict);
}

test "findings: bali.btf fires bigtiff_format finding" {
    const allocator = std.testing.allocator;
    var recorder = FindingRecorder.init(allocator);
    defer recorder.deinit();

    const bytes = try loadFile(allocator, "tests/fixtures/bigtiff/bali.btf");
    defer allocator.free(bytes);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const src = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, src);
    defer dec.deinit();
    dec.setFindingCallback(&FindingRecorder.callback, @ptrCast(&recorder));
    dec.scanFindings();

    try std.testing.expect(recorder.has(.bigtiff_format));
}

test "findings: predictor2_lzw.tif fires predictor_applied=2" {
    const allocator = std.testing.allocator;
    var recorder = FindingRecorder.init(allocator);
    defer recorder.deinit();

    const bytes = try loadFile(allocator, "tests/fixtures/predictor/predictor2_lzw.tif");
    defer allocator.free(bytes);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const src = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, src);
    defer dec.deinit();
    dec.setFindingCallback(&FindingRecorder.callback, @ptrCast(&recorder));
    dec.scanFindings();

    try std.testing.expect(recorder.has(.predictor_applied));
    try std.testing.expectEqual(@as(?u32, 2), recorder.payloadFor(.predictor_applied));
}

test "findings: gray16_lerc.tif fires lerc_compression" {
    const allocator = std.testing.allocator;
    var recorder = FindingRecorder.init(allocator);
    defer recorder.deinit();

    const bytes = try loadFile(allocator, "tests/fixtures/lerc/gray16_lerc.tif");
    defer allocator.free(bytes);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const src = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, src);
    defer dec.deinit();
    dec.setFindingCallback(&FindingRecorder.callback, @ptrCast(&recorder));
    dec.scanFindings();

    try std.testing.expect(recorder.has(.lerc_compression));
}

test "findings: ycbcr_jpeg.tif fires jpeg_in_tiff" {
    const allocator = std.testing.allocator;
    var recorder = FindingRecorder.init(allocator);
    defer recorder.deinit();

    const bytes = try loadFile(allocator, "tests/fixtures/jpeg/ycbcr_jpeg.tif");
    defer allocator.free(bytes);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const src = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, src);
    defer dec.deinit();
    dec.setFindingCallback(&FindingRecorder.callback, @ptrCast(&recorder));
    dec.scanFindings();

    try std.testing.expect(recorder.has(.jpeg_in_tiff));
}

test "findings: cramps-tile.tif fires tiled_layout" {
    const allocator = std.testing.allocator;
    var recorder = FindingRecorder.init(allocator);
    defer recorder.deinit();

    const bytes = try loadFile(allocator, "tests/fixtures/tiled/cramps-tile.tif");
    defer allocator.free(bytes);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const src = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, src);
    defer dec.deinit();
    dec.setFindingCallback(&FindingRecorder.callback, @ptrCast(&recorder));
    dec.scanFindings();

    try std.testing.expect(recorder.has(.tiled_layout));
}

test "findings: rgb_separate.tif fires planar_separate" {
    const allocator = std.testing.allocator;
    var recorder = FindingRecorder.init(allocator);
    defer recorder.deinit();

    const bytes = try loadFile(allocator, "tests/fixtures/photometric/rgb_separate.tif");
    defer allocator.free(bytes);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const src = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, src);
    defer dec.deinit();
    dec.setFindingCallback(&FindingRecorder.callback, @ptrCast(&recorder));
    dec.scanFindings();

    try std.testing.expect(recorder.has(.planar_separate));
}

test "findings: predictor3_deflate_fp32.tif fires predictor_applied=3" {
    const allocator = std.testing.allocator;
    var recorder = FindingRecorder.init(allocator);
    defer recorder.deinit();

    const bytes = try loadFile(allocator, "tests/fixtures/predictor/predictor3_deflate_fp32.tif");
    defer allocator.free(bytes);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const src = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, src);
    defer dec.deinit();
    dec.setFindingCallback(&FindingRecorder.callback, @ptrCast(&recorder));
    dec.scanFindings();

    try std.testing.expect(recorder.has(.predictor_applied));
    try std.testing.expectEqual(@as(?u32, 3), recorder.payloadFor(.predictor_applied));
}

test "findings: rgb-3c-8b.tiff (uncompressed, no special tags) fires no findings" {
    const allocator = std.testing.allocator;
    var recorder = FindingRecorder.init(allocator);
    defer recorder.deinit();

    const bytes = try loadFile(allocator, "tests/fixtures/uncompressed/rgb-3c-8b.tiff");
    defer allocator.free(bytes);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const src = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, src);
    defer dec.deinit();
    dec.setFindingCallback(&FindingRecorder.callback, @ptrCast(&recorder));
    dec.scanFindings();

    try std.testing.expectEqual(@as(usize, 0), recorder.findings.items.len);
}

/// Sequential reader backed by a byte slice. Used as the underlying
/// reader for `Source.fromBufferedReader` end-to-end tests.
const SequentialReader = struct {
    bytes: []const u8,
    pos: usize,

    fn readFn(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *SequentialReader = @ptrCast(@alignCast(ctx));
        const remaining = self.bytes.len - self.pos;
        const n = @min(buf.len, remaining);
        @memcpy(buf[0..n], self.bytes[self.pos .. self.pos + n]);
        self.pos += n;
        return n;
    }
};

test "fromBufferedReader: rgb-3c-8b.tiff decodes via streaming source" {
    // rgb-3c-8b.tiff was written by GraphicsMagick with IFD-at-end
    // layout (header → 71KB of strip data → tag-value block → IFD).
    // For this shape the streaming source has to span the whole file
    // because parsing the IFD needs to seek back into the strip
    // region to read the out-of-line tag values. Cache = 128 KiB
    // > 71 KiB suffices. Files written with IFD-at-start (the more
    // common libtiff default) only need a small cache after the
    // eager-IFD-caching landed in this commit; see the sizing
    // guidance in `Source.fromBufferedReader`.
    const allocator = std.testing.allocator;
    const bytes = try loadFile(allocator, "tests/fixtures/uncompressed/rgb-3c-8b.tiff");
    defer allocator.free(bytes);

    var reader = SequentialReader{ .bytes = bytes, .pos = 0 };
    const cache = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(cache);
    var handle = tiffz.source.BufferedReaderHandle.init(
        @ptrCast(&reader),
        &SequentialReader.readFn,
        bytes.len,
        cache,
    );
    const src = tiffz.Source.fromBufferedReader(&handle);

    var dec = try tiffz.Decoder.open(allocator, src);
    defer dec.deinit();

    const dir = try dec.ifd(0);
    const width = ifdScalarU32(dir, tiffz.tags.image_width, dec.endian) orelse return error.Malformed;
    const height = ifdScalarU32(dir, tiffz.tags.image_length, dec.endian) orelse return error.Malformed;
    try std.testing.expectEqual(@as(u32, 157), width);
    try std.testing.expectEqual(@as(u32, 151), height);

    const sbc_entry = dir.get(tiffz.tags.strip_byte_counts) orelse return error.Malformed;
    var ws = tiffz.Workspace.init(allocator);
    defer ws.deinit();
    const scratch = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(scratch);
    // Decode all strips end-to-end to confirm the streaming source
    // serves both the tag-value re-reads and the strip-data reads
    // without back-seek errors.
    var total: u64 = 0;
    var i: u32 = 0;
    while (i < sbc_entry.count) : (i += 1) {
        const n = try dec.decodeStrip(0, i, scratch, &ws);
        total += n;
    }
    try std.testing.expectEqual(@as(u64, 71121), total);
}

test "ycbcr_jpeg.tif (Compression=7 JPEG-in-TIFF, photometric=YCbCr, 16x16): RGBA matches libtiff tiff2rgba oracle" {
    // libtiff's tiffcp writes YCbCr-photometric JPEG-in-TIFF with
    // chroma subsampling 2:2 (the format default for RGB→JPEG). tiffz's
    // decode path hands the JPEG bitstream to libjpeg via jpegz, which
    // performs the YCbCr→RGB conversion + chroma upsampling internally;
    // fixture_test bypasses tiffz's YCbCr photometric expansion via the
    // override in decodeFixtureToRgba. Oracle generated via tiff2rgba
    // because ImageMagick's Q16-internal chroma upsampling differs
    // from libjpeg/libtiff (visibly — not just ±1 LSB), and tiff2rgba
    // is the spec-canonical reference for this codec path.
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/jpeg/ycbcr_jpeg.tif",
        "tests/fixtures/jpeg_oracle/ycbcr_jpeg.rgba",
    );
}

test "rgb_zstd.tif (Compression=50000 ZSTD-in-TIFF, 16x16 RGB 8-bit): RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/zstd/rgb_zstd.tif",
        "tests/fixtures/zstd_oracle/rgb_zstd.rgba",
    );
}

test "gray16_lerc.tif (Compression=34887 LERC, 16x16 gray 8-bit, add_compression=0): RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/lerc/gray16_lerc.tif",
        "tests/fixtures/lerc_oracle/gray16_lerc.rgba",
    );
}

test "gray16_lerc_deflate.tif (Compression=34887 LERC + Deflate post-filter, 16x16 gray 8-bit): RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/lerc/gray16_lerc_deflate.tif",
        "tests/fixtures/lerc_oracle/gray16_lerc_deflate.rgba",
    );
}

test "gray16_lerc_zstd.tif (Compression=34887 LERC + Zstd post-filter, 16x16 gray 8-bit): RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/lerc/gray16_lerc_zstd.tif",
        "tests/fixtures/lerc_oracle/gray16_lerc_zstd.rgba",
    );
}

test "rgb16_lerc.tif (Compression=34887 LERC, 16x16 RGB 8-bit chunky): RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/lerc/rgb16_lerc.tif",
        "tests/fixtures/lerc_oracle/rgb16_lerc.rgba",
    );
}

test "gray16_geotiff.tif: parse metadata surface (pixel scale, tiepoint, keys, params)" {
    const allocator = std.testing.allocator;
    const bytes = try loadFile(allocator, "tests/fixtures/geotiff/gray16_geotiff.tif");
    defer allocator.free(bytes);

    var handle = tiffz.source.BufferHandle.init(bytes);
    const src = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, src);
    defer dec.deinit();

    const meta = (try tiffz.geotiff.parseFromIfd(dec.ifds.items[0], src, dec.endian, allocator)) orelse return error.TestExpectedEqual;
    defer meta.deinit(allocator);

    // ModelPixelScale (3 doubles)
    try std.testing.expect(meta.pixel_scale != null);
    const ps = meta.pixel_scale.?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.03125), ps[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.03125), ps[1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), ps[2], 1e-9);

    // ModelTiepoint (single 6-tuple: image origin at [0,0] → lon=-80.5, lat=40.5)
    try std.testing.expectEqual(@as(usize, 1), meta.tiepoints.len);
    const tp = meta.tiepoints[0];
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), tp[0], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), tp[1], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), tp[2], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, -80.5), tp[3], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 40.5), tp[4], 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), tp[5], 1e-9);

    // ModelTransformation absent for tiepoint+scale-shaped GeoTIFFs.
    try std.testing.expect(meta.transformation == null);

    // GeoKeyDirectory header + keys
    try std.testing.expectEqual(@as(u16, 1), meta.key_directory_version);
    try std.testing.expectEqual(@as(u16, 1), meta.key_revision);
    try std.testing.expectEqual(@as(u16, 0), meta.minor_revision);
    try std.testing.expectEqual(@as(usize, 7), meta.keys.len);

    // Spot-check a few keys by ID
    const key_by_id = struct {
        fn get(keys: []const tiffz.geotiff.GeoKey, id: u16) ?tiffz.geotiff.GeoKey {
            for (keys) |k| if (k.id == id) return k;
            return null;
        }
    };

    // GTModelType (1024) = 2 (Geographic)
    const gt_model = key_by_id.get(meta.keys, 1024) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u16, 0), gt_model.tag_location);
    try std.testing.expectEqual(@as(u16, 1), gt_model.count);
    try std.testing.expectEqual(@as(u16, 2), gt_model.value_offset);

    // GeodeticCRSGeoKey (2048) = 4326 (WGS84)
    const crs = key_by_id.get(meta.keys, 2048) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u16, 4326), crs.value_offset);

    // GeodeticCitationGeoKey (2049): references geo_ascii_params [offset 0, count 7]
    const citation = key_by_id.get(meta.keys, 2049) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u16, tiffz.tags.geo_ascii_params), citation.tag_location);
    try std.testing.expectEqual(@as(u16, 7), citation.count);
    try std.testing.expectEqual(@as(u16, 0), citation.value_offset);

    // GeoDoubleParams populated with the two ellipsoid constants
    try std.testing.expectEqual(@as(usize, 2), meta.double_params.len);
    try std.testing.expectApproxEqAbs(@as(f64, 298.257224), meta.double_params[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f64, 6378137.0), meta.double_params[1], 1e-3);

    // GeoAsciiParams contains "WGS 84|" (the '|' terminator is included)
    try std.testing.expect(std.mem.startsWith(u8, meta.ascii_params, "WGS 84"));
}

test "cmyk.tif (uncompressed 16x16 CMYK 8-bit): RGBA matches ImageMagick oracle" {
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/photometric/cmyk.tif",
        "tests/fixtures/photometric_oracle/cmyk.rgba",
    );
}

test "ycbcr.tif (uncompressed 16x16 YCbCr 8-bit, subsampling 1:1): RGBA matches libtiff tiff2rgba oracle" {
    // Oracle generated via `tiff2rgba` (libtiff's own conversion) rather
    // than `magick`. Reason: tiffz's BT.601 inverse matches libtiff's
    // byte-exact, but ImageMagick's YCbCr round-trip uses slightly
    // different intermediate precision and drifts ±1 LSB in some
    // pixels. Since tiff2rgba is the spec-canonical TIFF tool, that's
    // the more authoritative oracle.
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/photometric/ycbcr.tif",
        "tests/fixtures/photometric_oracle/ycbcr.rgba",
    );
}

test "predictor3_deflate_fp32.tif: FP32 byte-plane interleaved diff matches Predictor=1 oracle" {
    // Both fixtures were transcoded from the same 8x8 FP32 plasma seed
    // via gdal_translate. The Predictor=1 variant has no transform, so
    // its post-decode bytes ARE the raw FP32 pixels. The Predictor=3
    // variant uses TN3 byte-plane interleaved differencing — if tiffz's
    // applyInverse is correct, the post-decode + post-predictor bytes
    // must match the Predictor=1 oracle byte-exact.
    const allocator = std.testing.allocator;
    const oracle = try decodeAllStripsBytes(allocator, "tests/fixtures/predictor/predictor1_deflate_fp32.tif");
    defer allocator.free(oracle);
    const got = try decodeAllStripsBytes(allocator, "tests/fixtures/predictor/predictor3_deflate_fp32.tif");
    defer allocator.free(got);
    // 8 × 8 × 3 channels × 4 bytes = 768 bytes.
    try std.testing.expectEqual(@as(usize, 768), oracle.len);
    try std.testing.expectEqualSlices(u8, oracle, got);
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

test "bali.btf (BigTIFF + LZW, 725x489 palette, multi-strip with LONG8 offsets): RGBA matches ImageMagick oracle" {
    // Stresses the BigTIFF + compressed path with an out-of-line
    // LONG8 StripOffsets array (45 strips × 8 bytes = 360 bytes,
    // far beyond the 8-byte inline cap). LZW codec + palette
    // photometric + ColorMap out-of-line read all go through the
    // BigTIFF entry/value resolver.
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/bigtiff/bali.btf",
        "tests/fixtures/bigtiff_oracle/bali.rgba",
    );
}

test "rgb-jpeg.tif (Compression=7 JPEG-in-TIFF, 157x151 RGB, JPEGTables Mode 2): RGBA matches ImageMagick oracle" {
    // ImageMagick-generated JPEG-in-TIFF fixture. Photometric=RGB (2),
    // single strip, JPEGTables (tag 347) carries the shared DQT/DHT
    // headers (TIFF Tech Note 2 Mode 2 — the dominant real-world
    // variant). Decoder must splice JPEGTables + strip bytes before
    // handing to jpegz. JPEG is lossy, so the byte-exact assertion
    // works because both tiffz and the magick oracle route through
    // libjpeg-turbo internally — when jpegz Phase 2 (cleanroom) lands,
    // this oracle becomes the regression gate that the cleanroom must
    // also satisfy.
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/jpeg/rgb-jpeg.tif",
        "tests/fixtures/jpeg_oracle/rgb-jpeg.rgba",
    );
}

test "rgb-3c-8b.btf (BigTIFF, 157x151 RGB, LONG8 StripOffsets): RGBA matches ImageMagick oracle" {
    // Produced via `tiffcp -8 -c none rgb-3c-8b.tiff rgb-3c-8b.btf`.
    // Magic = 0x002B (BigTIFF), OffsetSize = 8, StripOffsets type 16 (LONG8),
    // StripByteCounts type 3 (SHORT). Validates the whole BigTIFF wire path:
    // 16-byte header, u64 entry_count, 20-byte entries with [8]u8 slot,
    // 8-byte inline-fit cap, LONG8 array-element reads.
    try assertOracleMatch(
        std.testing.allocator,
        "tests/fixtures/bigtiff/rgb-3c-8b.btf",
        "tests/fixtures/bigtiff_oracle/rgb-3c-8b.rgba",
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

// ── #H: IFD chain cycle detection ─────────────────────────────────
//
// Adversarial TIFF: IFD0's next_ifd_offset points back to itself.
// Currently the decoder walks the same IFD up to max_ifds (1024)
// times before failing with LimitExceededIfdCount. With cycle
// detection it should fail immediately with IfdChainCycle the
// moment a previously-seen offset reappears in the chain.

test "ifd chain cycle: self-loop fails with IfdChainCycle not LimitExceededIfdCount" {
    const allocator = std.testing.allocator;

    // Minimal classic TIFF, little-endian, IFD0 at offset 8,
    // entry_count = 0, next_ifd_offset = 8 (back to itself).
    const cyclic = [_]u8{
        'I', 'I',             // little-endian magic
        0x2A, 0x00,           // TIFF version 42
        0x08, 0x00, 0x00, 0x00, // IFD0 offset = 8
        0x00, 0x00,           // entry_count = 0
        0x08, 0x00, 0x00, 0x00, // next_ifd_offset = 8 (CYCLE)
    };

    var handle = tiffz.source.BufferHandle.init(&cyclic);
    const src = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, src);
    defer dec.deinit();

    // Reach for IFD index 1 — forces the walker to follow the
    // cycle. With cycle detection, this fires IfdChainCycle on
    // first reappearance. Without it, max_ifds is hit after 1024
    // redundant parses.
    const result = dec.ifd(1);
    try std.testing.expectError(error.IfdChainCycle, result);
}

// ── #C: photometricAfterDecode public-API getter ─────────────────
//
// JPEG-in-TIFF case: jpegz silently converts YCbCr→RGB internally
// (matching libjpeg-turbo default). The IFD photometric tag says
// YCbCr but the bytes returned from decodeStrip are RGB-ordered.
// Without an API to surface this, callers either get wrong colors
// or have to know about the quirk and hardcode the override. The
// new Decoder.photometricAfterDecode(ifd_index) returns the
// effective photometric the caller should pass to expansion.

test "photometricAfterDecode: Compression=7 + YCbCr returns RGB override" {
    const allocator = std.testing.allocator;
    const bytes = try loadFile(allocator, "tests/fixtures/jpeg/ycbcr_jpeg.tif");
    defer allocator.free(bytes);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const src = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, src);
    defer dec.deinit();

    const effective = try dec.photometricAfterDecode(0);
    try std.testing.expectEqual(tiffz.tags.photometric_rgb, effective);
}

test "photometricAfterDecode: non-JPEG passes IFD photometric through unchanged" {
    const allocator = std.testing.allocator;
    const bytes = try loadFile(allocator, "tests/fixtures/uncompressed/rgb-3c-8b.tiff");
    defer allocator.free(bytes);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const src = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, src);
    defer dec.deinit();

    const effective = try dec.photometricAfterDecode(0);
    try std.testing.expectEqual(tiffz.tags.photometric_rgb, effective);
}

test "photometricAfterDecode: PackBits MinIsWhite returns MinIsWhite" {
    const allocator = std.testing.allocator;
    const bytes = try loadFile(allocator, "tests/fixtures/packbits/cramps.tif");
    defer allocator.free(bytes);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const src = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, src);
    defer dec.deinit();

    const effective = try dec.photometricAfterDecode(0);
    try std.testing.expectEqual(tiffz.tags.photometric_white_is_zero, effective);
}

// ── #2: True u16 CMYK composition ─────────────────────────────────
//
// Current path downscales each u16 channel to u8 before subtractive
// composition: `(255-C)*(255-K)/255`. True u16 path keeps the full
// precision: `(65535-C)*(65535-K)/65535` and downscales the final
// RGB to u8 at the end. For values where the high byte of K is N
// but K (as u16) has lower-byte contribution, the two paths differ
// by 1 LSB.
//
// Test case: 1 pixel, C=K=0x8000, M=Y=0.
//   u8-first: sampleU8(0x8000)=128. R = (255-128)*(255-128)/255 = 63
//   true u16: (65535-32768)*(65535-32768)/65535 = 16383
//             downscale: (16383*255+32767)/65535 = 64
// → assert R=64 (the spec-precise answer). Test fails under the
// current u8-first path (which returns 63); passes after the fix.
// G and B are unaffected (M=Y=0 means the C channel quirk doesn'''t apply).

test "expandCmyk u16: high-precision composition diverges by 1 LSB from u8-first" {
    const allocator = std.testing.allocator;

    // One pixel of 16-bit CMYK, little-endian: C=0x8000, M=0, Y=0, K=0x8000.
    const src = [_]u8{
        0x00, 0x80, // C=0x8000
        0x00, 0x00, // M=0
        0x00, 0x00, // Y=0
        0x00, 0x80, // K=0x8000
    };

    var dest: [4]u8 = .{ 0xAA, 0xAA, 0xAA, 0xAA };

    const fmt: tiffz.photometrics.PixelFormat = .{
        .photometric = tiffz.tags.photometric_separated_cmyk,
        .bits_per_sample = 16,
        .samples_per_pixel = 4,
        .width = 1,
        .colormap = null,
        .endian = .little,
    };

    try tiffz.photometrics.expandRowsToRgba(&src, 1, fmt, &dest);
    _ = allocator;

    // u8-first path (current): R=63, G=127, B=127. Asserts true-u16: R=64.
    try std.testing.expectEqual(@as(u8, 64), dest[0]); // R (diverges)
    try std.testing.expectEqual(@as(u8, 127), dest[1]); // G (M=0 → no divergence)
    try std.testing.expectEqual(@as(u8, 127), dest[2]); // B (Y=0 → no divergence)
    try std.testing.expectEqual(@as(u8, 0xFF), dest[3]); // A (opaque, no extra sample)
}

test "expandCmyk u8: 8-bit input behavior unchanged after u16 fix" {
    const allocator = std.testing.allocator;
    _ = allocator;

    // One pixel: C=0, M=0, Y=0, K=128 (matches the u16 sample's
    // sampleU8(0x8000)=127 quantization, but the u8 input is exact).
    const src = [_]u8{ 0, 0, 0, 128 };
    var dest: [4]u8 = .{ 0xAA, 0xAA, 0xAA, 0xAA };

    const fmt: tiffz.photometrics.PixelFormat = .{
        .photometric = tiffz.tags.photometric_separated_cmyk,
        .bits_per_sample = 8,
        .samples_per_pixel = 4,
        .width = 1,
        .colormap = null,
        .endian = .little,
    };

    try tiffz.photometrics.expandRowsToRgba(&src, 1, fmt, &dest);

    // u8 path: (255-0)*(255-128)/255 = 255*127/255 = 127 (with +127 rounding)
    // → 32512/255 = 127. Path unchanged by u16 fix.
    try std.testing.expectEqual(@as(u8, 127), dest[0]);
    try std.testing.expectEqual(@as(u8, 127), dest[1]);
    try std.testing.expectEqual(@as(u8, 127), dest[2]);
}

// ── #4: photometric=9 (ICCLab) — TIFF Tech Note 3 variant ────────
//
// CIELAB (photometric=8): a/b stored as signed two's-complement bytes
//   (-128..127 maps to L*a*b* a/b in roughly -127..127 spec range).
// ICCLab  (photometric=9): a/b stored as UNSIGNED bytes with bias 128
//   (so a_star = a_byte - 128). Same L* encoding either way.
//
// For an achromatic mid-gray pixel:
//   CIELAB encoding: a_byte=0, b_byte=0 → a_star=0, b_star=0
//   ICCLab encoding: a_byte=128, b_byte=128 → a_star=0, b_star=0
// Both should produce the same RGB. The dispatch needs to switch on
// fmt.photometric or the result differs by ~100 LSBs in each channel.

test "expandIccLab photometric=9 mid-gray matches photometric=8 mid-gray" {
    const allocator = std.testing.allocator;
    _ = allocator;

    // Mid-gray pixel encoded both ways.
    const src_cielab = [_]u8{ 128, 0, 0 }; // L=50%, a=0, b=0 (signed)
    const src_icclab = [_]u8{ 128, 128, 128 }; // L=50%, a=0, b=0 (biased)

    var dest_cielab: [4]u8 = .{ 0, 0, 0, 0 };
    var dest_icclab: [4]u8 = .{ 0, 0, 0, 0 };

    const fmt_cielab: tiffz.photometrics.PixelFormat = .{
        .photometric = tiffz.tags.photometric_cielab,
        .bits_per_sample = 8,
        .samples_per_pixel = 3,
        .width = 1,
        .colormap = null,
    };
    const fmt_icclab: tiffz.photometrics.PixelFormat = .{
        .photometric = tiffz.tags.photometric_icclab,
        .bits_per_sample = 8,
        .samples_per_pixel = 3,
        .width = 1,
        .colormap = null,
    };

    try tiffz.photometrics.expandRowsToRgba(&src_cielab, 1, fmt_cielab, &dest_cielab);
    try tiffz.photometrics.expandRowsToRgba(&src_icclab, 1, fmt_icclab, &dest_icclab);

    try std.testing.expectEqual(dest_cielab[0], dest_icclab[0]); // R
    try std.testing.expectEqual(dest_cielab[1], dest_icclab[1]); // G
    try std.testing.expectEqual(dest_cielab[2], dest_icclab[2]); // B
}

test "expandIccLab photometric=9 max-positive-a encodes a*=127 (red shift)" {
    const allocator = std.testing.allocator;
    _ = allocator;

    // ICCLab a=255 → a_star = 255-128 = 127 (max positive a → red shift)
    const src = [_]u8{ 128, 255, 128 }; // L=50%, a=+127, b=0
    var dest: [4]u8 = .{ 0, 0, 0, 0 };

    const fmt: tiffz.photometrics.PixelFormat = .{
        .photometric = tiffz.tags.photometric_icclab,
        .bits_per_sample = 8,
        .samples_per_pixel = 3,
        .width = 1,
        .colormap = null,
    };

    try tiffz.photometrics.expandRowsToRgba(&src, 1, fmt, &dest);
    // Strong red shift: R should be substantially higher than G and B.
    try std.testing.expect(dest[0] > dest[1]);
    try std.testing.expect(dest[0] > dest[2]);
}

// The 1-bit LZW route must stay in the general TIFF decoder. Validate used
// to carry a duplicate TIFF parser/decoder solely for this case; this compact
// TIFF proves `Decoder.decodeStrip` handles a packed bilevel LZW strip before
// that fallback is removed.
test "Decoder decodes inline 1-bit LZW strip through the general path" {
    // Little-endian classic TIFF: 8×1, 1-bit MinisBlack, LZW, one strip.
    // Payload codes are CLEAR(256), literal 0xAA, EOD(257), MSB-packed.
    const bytes = [_]u8{
        'I', 'I', 42, 0, 8, 0, 0, 0,
        8, 0,
        // ImageWidth = 8
        0x00, 0x01, 0x04, 0x00, 1, 0, 0, 0, 8, 0, 0, 0,
        // ImageLength = 1
        0x01, 0x01, 0x04, 0x00, 1, 0, 0, 0, 1, 0, 0, 0,
        // BitsPerSample = 1
        0x02, 0x01, 0x03, 0x00, 1, 0, 0, 0, 1, 0, 0, 0,
        // Compression = LZW (5)
        0x03, 0x01, 0x03, 0x00, 1, 0, 0, 0, 5, 0, 0, 0,
        // PhotometricInterpretation = MinisBlack (1)
        0x06, 0x01, 0x03, 0x00, 1, 0, 0, 0, 1, 0, 0, 0,
        // StripOffsets = 110 (after this IFD)
        0x11, 0x01, 0x04, 0x00, 1, 0, 0, 0, 110, 0, 0, 0,
        // RowsPerStrip = 1
        0x16, 0x01, 0x04, 0x00, 1, 0, 0, 0, 1, 0, 0, 0,
        // StripByteCounts = 4
        0x17, 0x01, 0x04, 0x00, 1, 0, 0, 0, 4, 0, 0, 0,
        0, 0, 0, 0, // no next IFD
        0x80, 0x2A, 0xA0, 0x20,
    };

    var handle = tiffz.source.BufferHandle.init(&bytes);
    const source = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(std.testing.allocator, source);
    defer dec.deinit();
    var workspace = tiffz.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    var decoded: [1]u8 = undefined;

    const written = try dec.decodeStrip(0, 0, &decoded, &workspace);
    try std.testing.expectEqual(@as(usize, 1), written);
    try std.testing.expectEqual(@as(u8, 0xAA), decoded[0]);
}

test "Decoder maps an LZW strip without EOD to SourceTooShort" {
    // Same valid 8×1 bilevel directory as the positive integration fixture,
    // but CLEAR + literal 0xAA reaches physical EOF without TIFF's required
    // EOD code. This locks the tiffz adapter's mapping to its public error
    // vocabulary while the shared lzwz core owns the actual LZW state machine.
    const bytes = [_]u8{
        'I', 'I', 42, 0, 8, 0, 0, 0,
        8, 0,
        0x00, 0x01, 0x04, 0x00, 1, 0, 0, 0, 8, 0, 0, 0,
        0x01, 0x01, 0x04, 0x00, 1, 0, 0, 0, 1, 0, 0, 0,
        0x02, 0x01, 0x03, 0x00, 1, 0, 0, 0, 1, 0, 0, 0,
        0x03, 0x01, 0x03, 0x00, 1, 0, 0, 0, 5, 0, 0, 0,
        0x06, 0x01, 0x03, 0x00, 1, 0, 0, 0, 1, 0, 0, 0,
        0x11, 0x01, 0x04, 0x00, 1, 0, 0, 0, 110, 0, 0, 0,
        0x16, 0x01, 0x04, 0x00, 1, 0, 0, 0, 1, 0, 0, 0,
        0x17, 0x01, 0x04, 0x00, 1, 0, 0, 0, 3, 0, 0, 0,
        0, 0, 0, 0,
        // CLEAR(256), literal 0xAA, no EOD(257).
        0x80, 0x2A, 0x80,
    };

    var handle = tiffz.source.BufferHandle.init(&bytes);
    const source = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(std.testing.allocator, source);
    defer dec.deinit();
    var workspace = tiffz.Workspace.init(std.testing.allocator);
    defer workspace.deinit();
    var decoded: [1]u8 = undefined;

    try std.testing.expectError(error.SourceTooShort, dec.decodeStrip(0, 0, &decoded, &workspace));
}

// -------------------------------------------------------------------------
// Einstein 1.0 audit (2026-07-23): labeled-good false rejects.
//
// These fixtures are byte-verbatim copies of validate's labeled-good corpus
// at `~/Code/validate_gui/ground_truth_examples/tiff/`. Two of the five —
// cramps-tile.tif and quad-tile.tif — DIFFER byte-for-byte from the
// same-named files under `tests/fixtures/tiled/`, so the pre-existing
// oracle tests do not exercise the exact bytes validate measured.
//
// Each test opens the file, calls the product path
// `Decoder.validateAllStripsAndTiles` (the same call Einstein specified as
// the mandatory reproduction vector), and expects it to succeed. The
// canonical `./test` currently passes; these tests are the failing wedge
// the audit needs. When they eventually go green, per-fixture root causes
// go into CODE_REVIEW.md.
// -------------------------------------------------------------------------

/// Assert `validateAllStripsAndTiles` on a labeled-good fixture returns the
/// WRONG-BUT-CURRENT error. This is a negative characterization test — it
/// keeps `./test` green while documenting the exact regression. When the
/// underlying gate is corrected, this call fires (expected error not
/// produced), demanding the assertion be flipped to a bare positive call.
fn characterizeCurrentReject(
    fixture_path: []const u8,
    expected_err: tiffz.Error,
) !void {
    const allocator = std.testing.allocator;
    const bytes = try loadFile(allocator, fixture_path);
    defer allocator.free(bytes);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const source = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, source);
    defer dec.deinit();
    var workspace = tiffz.Workspace.init(allocator);
    defer workspace.deinit();
    try std.testing.expectError(expected_err, dec.validateAllStripsAndTiles(&workspace));
}

/// Assert `validateAllStripsAndTiles` ACCEPTS a labeled-good fixture through
/// the product path — the positive form of `characterizeCurrentReject`, used
/// once a gate is corrected and the characterization assertion is flipped.
fn expectFixtureValidates(fixture_path: []const u8) !void {
    const allocator = std.testing.allocator;
    const bytes = try loadFile(allocator, fixture_path);
    defer allocator.free(bytes);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const source = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, source);
    defer dec.deinit();
    var workspace = tiffz.Workspace.init(allocator);
    defer workspace.deinit();
    try dec.validateAllStripsAndTiles(&workspace);
}

/// Accept one compatibility fixture and prove its assigned finding fires once,
/// preventing a broad silent relaxation from satisfying the positive test.
fn expectFixtureValidatesWithFinding(
    fixture_path: []const u8,
    finding: tiffz.findings.InfoFinding,
) !void {
    const allocator = std.testing.allocator;
    const bytes = try loadFile(allocator, fixture_path);
    defer allocator.free(bytes);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const source = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, source);
    defer dec.deinit();
    var recorder = FindingRecorder.init(allocator);
    defer recorder.deinit();
    dec.setFindingCallback(&FindingRecorder.callback, @ptrCast(&recorder));
    var workspace = tiffz.Workspace.init(allocator);
    defer workspace.deinit();

    try dec.validateAllStripsAndTiles(&workspace);
    try std.testing.expectEqual(@as(usize, 1), recorder.count(finding));
}

/// Replace exactly one classic-TIFF IFD0 tag while preserving its value. Test
/// mutations use this to classify layout presence/absence without fabricating
/// unrelated decoder state.
fn replaceClassicIfd0Tag(bytes: []u8, old_tag: u16, new_tag: u16) !void {
    if (bytes.len < 8) return error.Malformed;
    const endian: std.builtin.Endian = if (std.mem.eql(u8, bytes[0..2], "II"))
        .little
    else if (std.mem.eql(u8, bytes[0..2], "MM"))
        .big
    else
        return error.Malformed;
    const ifd_offset: usize = switch (endian) {
        .little => std.mem.readInt(u32, bytes[4..8], .little),
        .big => std.mem.readInt(u32, bytes[4..8], .big),
    };
    if (ifd_offset > bytes.len - 2) return error.Malformed;
    const count: usize = switch (endian) {
        .little => std.mem.readInt(u16, bytes[ifd_offset..][0..2], .little),
        .big => std.mem.readInt(u16, bytes[ifd_offset..][0..2], .big),
    };
    var replacements: usize = 0;
    for (0..count) |index| {
        const tag_offset = ifd_offset + 2 + index * 12;
        if (tag_offset > bytes.len - 12) return error.Malformed;
        const tag = switch (endian) {
            .little => std.mem.readInt(u16, bytes[tag_offset..][0..2], .little),
            .big => std.mem.readInt(u16, bytes[tag_offset..][0..2], .big),
        };
        if (tag != old_tag) continue;
        switch (endian) {
            .little => std.mem.writeInt(u16, bytes[tag_offset..][0..2], new_tag, .little),
            .big => std.mem.writeInt(u16, bytes[tag_offset..][0..2], new_tag, .big),
        }
        replacements += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), replacements);
}

test "audit 1.0 [fixed]: cramps-tile.tif accepts tiled geometry via strip tags and emits finding 15 once" {
    try expectFixtureValidatesWithFinding(
        "tests/fixtures/labeled_good/cramps-tile.tif",
        .tiled_geometry_via_strip_tags_tolerated,
    );
}

test "audit 1.0 [fixed]: bounded final-strip padding is accepted and emits finding 13 exactly once" {
    const allocator = std.testing.allocator;
    const bytes = try loadFile(allocator, "tests/fixtures/labeled_good/deflate-last-strip.tiff");
    defer allocator.free(bytes);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const source = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, source);
    defer dec.deinit();
    var recorder = FindingRecorder.init(allocator);
    defer recorder.deinit();
    dec.setFindingCallback(&FindingRecorder.callback, @ptrCast(&recorder));
    var workspace = tiffz.Workspace.init(allocator);
    defer workspace.deinit();

    try dec.validateAllStripsAndTiles(&workspace);
    try std.testing.expectEqual(
        @as(usize, 1),
        recorder.count(.final_strip_padding_tolerated),
    );
    // validate renders "final strip padded by N bytes": N = written − logical.
    // deflate-last-strip.tiff: 500×500 8-bit 1-sample = 500 B/row; last strip
    // (idx 31) holds 4 real rows (logical 2000) padded to RowsPerStrip=16 (8000),
    // so the excess is 8000 − 2000 = 6000, carried as a 4-byte LE u32.
    try std.testing.expectEqual(
        @as(?u32, 6000),
        recorder.payloadFor(.final_strip_padding_tolerated),
    );
}

test "audit 1.0 [fixed]: exact-extent clean-EOF LZW is accepted and emits finding 14 exactly once" {
    const allocator = std.testing.allocator;
    const bytes = try loadFile(allocator, "tests/fixtures/labeled_good/lzw-single-strip.tiff");
    defer allocator.free(bytes);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const source = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, source);
    defer dec.deinit();
    var recorder = FindingRecorder.init(allocator);
    defer recorder.deinit();
    dec.setFindingCallback(&FindingRecorder.callback, @ptrCast(&recorder));
    var workspace = tiffz.Workspace.init(allocator);
    defer workspace.deinit();

    try dec.validateAllStripsAndTiles(&workspace);
    try std.testing.expectEqual(
        @as(usize, 1),
        recorder.count(.lzw_missing_eod_tolerated),
    );
}

test "audit 1.0 [fixed]: quad-tile.tif accepts tiled geometry via strip tags and emits finding 15 once" {
    try expectFixtureValidatesWithFinding(
        "tests/fixtures/labeled_good/quad-tile.tif",
        .tiled_geometry_via_strip_tags_tolerated,
    );
}

test "warning 15 classifier rejects incomplete fallback arrays and partial canonical precedence" {
    const allocator = std.testing.allocator;
    const pristine = try loadFile(allocator, "tests/fixtures/labeled_good/cramps-tile.tif");
    defer allocator.free(pristine);

    // Remove StripByteCounts while keeping TileWidth/TileLength + StripOffsets.
    // The compatibility shape is incomplete and must remain a hard failure.
    const incomplete = try allocator.dupe(u8, pristine);
    defer allocator.free(incomplete);
    try replaceClassicIfd0Tag(incomplete, tiffz.tags.strip_byte_counts, 65000);
    {
        var handle = tiffz.source.BufferHandle.init(incomplete);
        const source = tiffz.Source.fromBuffer(&handle);
        var dec = try tiffz.Decoder.open(allocator, source);
        defer dec.deinit();
        var workspace = tiffz.Workspace.init(allocator);
        defer workspace.deinit();
        try std.testing.expectError(error.Malformed, dec.validateAllStripsAndTiles(&workspace));
    }

    // Introduce only canonical TileOffsets. Canonical tile tags take
    // precedence, so tiffz rejects the missing TileByteCounts rather than
    // reconciling them with the complete strip arrays.
    const ambiguous = try allocator.dupe(u8, pristine);
    defer allocator.free(ambiguous);
    try replaceClassicIfd0Tag(ambiguous, 32996, tiffz.tags.tile_offsets);
    {
        var handle = tiffz.source.BufferHandle.init(ambiguous);
        const source = tiffz.Source.fromBuffer(&handle);
        var dec = try tiffz.Decoder.open(allocator, source);
        defer dec.deinit();
        var workspace = tiffz.Workspace.init(allocator);
        defer workspace.deinit();
        try std.testing.expectError(error.Malformed, dec.validateAllStripsAndTiles(&workspace));
    }
}

test "warning 15 classifier does not fire for canonical tile arrays" {
    const allocator = std.testing.allocator;
    const bytes = try loadFile(allocator, "tests/fixtures/photometric/ycbcr_tiled_uncompressed_sub2x2.tif");
    defer allocator.free(bytes);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const source = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, source);
    defer dec.deinit();
    var recorder = FindingRecorder.init(allocator);
    defer recorder.deinit();
    dec.setFindingCallback(&FindingRecorder.callback, @ptrCast(&recorder));
    var workspace = tiffz.Workspace.init(allocator);
    defer workspace.deinit();
    try dec.validateAllStripsAndTiles(&workspace);
    try std.testing.expectEqual(
        @as(usize, 0),
        recorder.count(.tiled_geometry_via_strip_tags_tolerated),
    );
}

test "audit 1.0 [fixed]: ycbcr-cat.tif ACCEPTED via subsampling-aware extent gate — 250x325 LZW YCbCr subsampling 2:2" {
    try expectFixtureValidates("tests/fixtures/labeled_good/ycbcr-cat.tif");
}

test "YCbCr tiled chunky subsampled 2:2 (uncompressed 16x16, one tile) validates via .tile extent branch" {
    // Real libtiff-authored fixture (LIBTIFF 4.7.1): PHOTOMETRIC_YCBCR,
    // YCBCRSUBSAMPLING 2,2, COMPRESSION_NONE, PLANARCONFIG_CONTIG, one 16x16 tile.
    // The tile stores ceil(16/2)*ceil(16/2)=64 data units * (2*2+2)=6 B = 384 B,
    // half the flat-model 16*16*3 = 768; acceptance proves the .tile branch of
    // expectedChunkBytes applies the TIFF 6.0 subsampling extent end-to-end (not
    // formula-only). Regenerate: TIFFWriteRawTile(t, 0, <384 pseudo-bytes>, 384)
    // with the tags above (see docs; niche uncompressed subsampled tiling — tiffcp
    // cannot copy subsampled images, so raw-tile authoring is required).
    try expectFixtureValidates("tests/fixtures/photometric/ycbcr_tiled_uncompressed_sub2x2.tif");
}

/// Metamorphic embedding proof for `Source.fromSubrange`: a labeled-good TIFF
/// must validate identically whether opened at base 0 or embedded at a nonzero
/// base inside junk padding (the real use case — a TIFF stream living inside a
/// DNG/RAW/container). The padding is 0xAB (a non-TIFF, nonzero pattern); the
/// sub-view being oblivious to it proves reads never leave [base, base+len).
fn expectEmbeddedFixtureValidates(fixture_path: []const u8, prefix_len: usize, suffix_len: usize) !void {
    const allocator = std.testing.allocator;
    const tiff = try loadFile(allocator, fixture_path);
    defer allocator.free(tiff);

    const host = try allocator.alloc(u8, prefix_len + tiff.len + suffix_len);
    defer allocator.free(host);
    @memset(host, 0xAB);
    @memcpy(host[prefix_len..][0..tiff.len], tiff);

    var inner_handle = tiffz.source.BufferHandle.init(host);
    const inner = tiffz.Source.fromBuffer(&inner_handle);
    var sub_handle = tiffz.source.SubSourceHandle.init(&inner, prefix_len, tiff.len);
    const source = tiffz.Source.fromSubrange(&sub_handle);

    var dec = try tiffz.Decoder.open(allocator, source);
    defer dec.deinit();
    var workspace = tiffz.Workspace.init(allocator);
    defer workspace.deinit();
    try dec.validateAllStripsAndTiles(&workspace);
}

test "fromSubrange: labeled-good TIFF validates embedded at a nonzero base in junk (metamorphic vs base 0)" {
    const fx = "tests/fixtures/photometric/ycbcr_tiled_uncompressed_sub2x2.tif";
    // base 0, no padding — parity with the fromBuffer path.
    try expectEmbeddedFixtureValidates(fx, 0, 0);
    // Embedded at a nonzero, unaligned base with leading + trailing junk — the
    // real container shape. Identical outcome (success) proves the validation
    // is invariant under the embedding offset AND that no strip/tile/tag/IFD
    // offset spills into the 0xAB padding on either side.
    try expectEmbeddedFixtureValidates(fx, 37, 19);
}

test "JPEG-in-TIFF: corrupt strip surfaces error.JpegInTiffPayload through the product path (was generic Malformed)" {
    const allocator = std.testing.allocator;
    const bytes = try loadFile(allocator, "tests/fixtures/jpeg/ycbcr_jpeg.tif");
    defer allocator.free(bytes);

    // Specificity / must-pass member: the pristine fixture validates clean.
    {
        var handle = tiffz.source.BufferHandle.init(bytes);
        const src = tiffz.Source.fromBuffer(&handle);
        var dec = try tiffz.Decoder.open(allocator, src);
        defer dec.deinit();
        var ws = tiffz.Workspace.init(allocator);
        defer ws.deinit();
        try dec.validateAllStripsAndTiles(&ws);
    }

    // Locate the JPEG strip (StripOffsets[0]) before corrupting.
    const strip_off: usize = blk: {
        var probe = tiffz.source.BufferHandle.init(bytes);
        const psrc = tiffz.Source.fromBuffer(&probe);
        var pdec = try tiffz.Decoder.open(allocator, psrc);
        defer pdec.deinit();
        const dir = try pdec.ifd(0);
        break :blk ifdScalarU32(dir, tiffz.tags.strip_offsets, pdec.endian) orelse return error.Malformed;
    };

    // The abbreviated image datastream begins SOI (FF D8) then SOF0 (FF C0).
    // Guard the assumed layout so a regenerated fixture fails loudly here rather
    // than silently weakening the test.
    try std.testing.expectEqual(@as(u8, 0xFF), bytes[strip_off]);
    try std.testing.expectEqual(@as(u8, 0xD8), bytes[strip_off + 1]);
    try std.testing.expectEqual(@as(u8, 0xFF), bytes[strip_off + 2]);
    try std.testing.expectEqual(@as(u8, 0xC0), bytes[strip_off + 3]);

    // Zero the SOF0 marker + its 17-byte segment: jpegz is left with no frame
    // header, a deterministic JPEG-payload decode failure (not a TIFF-structure
    // defect). Corrupting the frame header, not the entropy data, is what makes
    // the failure deterministic — entropy corruption can decode to garbage
    // without erroring.
    @memset(bytes[strip_off + 2 ..][0..19], 0x00);

    var handle = tiffz.source.BufferHandle.init(bytes);
    const src = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(allocator, src);
    defer dec.deinit();
    var recorder = FindingRecorder.init(allocator);
    defer recorder.deinit();
    dec.setFindingCallback(&FindingRecorder.callback, @ptrCast(&recorder));
    var ws = tiffz.Workspace.init(allocator);
    defer ws.deinit();
    try std.testing.expectError(error.JpegInTiffPayload, dec.validateAllStripsAndTiles(&ws));

    var saw_exact_nested_cause = false;
    for (recorder.findings.items) |finding| {
        if (finding.source != .jpegz or finding.verdict != .corrupt) continue;
        try std.testing.expect(finding.byte_offset != null);
        try std.testing.expect(finding.host_byte_offset != null);
        try std.testing.expect(finding.offset_is_exact);
        // This fixture is Tech Note 2 Mode 2: the leaf offset is in the
        // spliced JPEGTables+strip stream, while the host offset maps back to
        // the first corrupted strip byte after its SOI.
        try std.testing.expectEqual(
            strip_off + 2,
            @as(usize, @intCast(finding.host_byte_offset.?)),
        );
        try std.testing.expect(finding.byte_offset.? != finding.host_byte_offset.?);
        saw_exact_nested_cause = true;
    }
    try std.testing.expect(saw_exact_nested_cause);
}



test "validateAllStripsAndTiles rejects LZW EOD before declared pixel extent" {
    // Same 8×1 bilevel layout as the positive integration fixture, but its
    // LZW strip is CLEAR + EOD. The terminator is valid; its zero decoded
    // bytes are not enough for the one declared image byte. Deep validation
    // must reject that mismatch rather than treating any successful codec
    // return as complete coverage.
    const bytes = [_]u8{
        'I', 'I', 42, 0, 8, 0, 0, 0,
        8, 0,
        0x00, 0x01, 0x04, 0x00, 1, 0, 0, 0, 8, 0, 0, 0,
        0x01, 0x01, 0x04, 0x00, 1, 0, 0, 0, 1, 0, 0, 0,
        0x02, 0x01, 0x03, 0x00, 1, 0, 0, 0, 1, 0, 0, 0,
        0x03, 0x01, 0x03, 0x00, 1, 0, 0, 0, 5, 0, 0, 0,
        0x06, 0x01, 0x03, 0x00, 1, 0, 0, 0, 1, 0, 0, 0,
        0x11, 0x01, 0x04, 0x00, 1, 0, 0, 0, 110, 0, 0, 0,
        0x16, 0x01, 0x04, 0x00, 1, 0, 0, 0, 1, 0, 0, 0,
        0x17, 0x01, 0x04, 0x00, 1, 0, 0, 0, 3, 0, 0, 0,
        0, 0, 0, 0,
        // CLEAR(256) + EOD(257), MSB-packed; zero decoded pixels.
        0x80, 0x40, 0x40,
    };

    var handle = tiffz.source.BufferHandle.init(&bytes);
    const source = tiffz.Source.fromBuffer(&handle);
    var dec = try tiffz.Decoder.open(std.testing.allocator, source);
    defer dec.deinit();
    var workspace = tiffz.Workspace.init(std.testing.allocator);
    defer workspace.deinit();

    try std.testing.expectError(error.Malformed, dec.validateAllStripsAndTiles(&workspace));
}
