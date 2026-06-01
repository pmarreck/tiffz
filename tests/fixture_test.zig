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
        finding: tiffz.findings.InfoFinding,
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
        finding_id: i32,
        payload: ?[*]const u8,
        payload_len: usize,
    ) callconv(.c) void {
        const self: *FindingRecorder = @ptrCast(@alignCast(userdata.?));
        const finding: tiffz.findings.InfoFinding = @enumFromInt(@as(u32, @intCast(finding_id)));
        const payload_u32: ?u32 = if (payload_len >= 4 and payload != null) blk: {
            const slice = payload.?[0..4];
            break :blk std.mem.readInt(u32, slice, .little);
        } else null;
        self.findings.append(self.allocator, .{
            .finding = finding,
            .payload_u32 = payload_u32,
        }) catch unreachable;
    }

    fn has(self: *const FindingRecorder, finding: tiffz.findings.InfoFinding) bool {
        for (self.findings.items) |r| if (r.finding == finding) return true;
        return false;
    }

    fn payloadFor(self: *const FindingRecorder, finding: tiffz.findings.InfoFinding) ?u32 {
        for (self.findings.items) |r| if (r.finding == finding) return r.payload_u32;
        return null;
    }
};

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
