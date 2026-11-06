//! Compression scheme 7 (JPEG-in-TIFF, TIFF Technical Note 2).
//!
//! Strips/tiles hold a JPEG bitstream that decodes to the per-chunk
//! pixel block. Two on-disk variants per TN2:
//!
//!   Mode 1 (no JPEGTables tag): each strip is a complete, self-
//!     contained JPEG datastream — SOI … tables … SOF SOS scan … EOI.
//!     We pass strip bytes straight to jpegz.
//!
//!   Mode 2 (JPEGTables tag 347 present): the tag carries an
//!     "abbreviated table specification datastream" — SOI … tables …
//!     EOI — and each strip carries an abbreviated image datastream
//!     — SOI … SOF SOS scan … EOI — referencing those tables. To
//!     decode, we splice: JPEGTables minus its trailing EOI, followed
//!     by strip bytes minus their leading SOI. The resulting buffer
//!     is one complete JPEG stream.
//!
//! Mode 2 is the dominant real-world variant (ImageMagick + libtiff
//! both default to it). Mode 1 falls out naturally — when there's no
//! JPEGTables to splice, the strip bytes ARE the complete stream.
//!
//! Photometric scope: RGB (2), YCbCr (6), BlackIsZero (1) and CFA (32803).
//! RGB/YCbCr decode to pixels (YCbCr becomes RGB inside jpegz). BlackIsZero
//! (a gray page) and CFA accept only a jpegz-checked single-component decode
//! and return those samples unchanged. Other photometrics stay UnsupportedCompression before
//! jpegz runs. An unchecked single-component variant still runs jpegz.validate so
//! the reach finding is visible, then returns UnsupportedCompression.
//!
//! For YCbCr the underlying
//! libjpeg-turbo wrapper performs internal YCbCr→RGB conversion, so
//! the bytes returned in `dest` are RGB pixels regardless of the TIFF
//! photometric tag. The caller MUST treat the output as
//! photometric=RGB during photometric expansion (libtiff takes the
//! same approach in TIFFReadRGBAImage). Other photometric
//! values with Compression=7 surface as UnsupportedCompression at the
//! decoder layer.

const std = @import("std");
const Allocator = std.mem.Allocator;

const errors = @import("tiffz-parser").errors;
const Endian = @import("tiffz-parser").header.Endian;
const native_endian = @import("builtin").cpu.arch.endian();
pub const jpegz = @import("jpegz");

/// One complete JPEG stream prepared from TIFF Tech Note 2 Mode 1 or Mode 2.
/// Its offset mapper reports host-exact positions only for bytes originating
/// in the TIFF chunk; cached JPEGTables bytes deliberately remain unknown.
pub const PreparedStream = struct {
    bytes: []const u8,
    owned: ?[]u8,
    tables_prefix_len: usize,
    strip_prefix_removed: usize,

    pub fn deinit(self: *PreparedStream, allocator: Allocator) void {
        if (self.owned) |buf| allocator.free(buf);
        self.* = undefined;
    }

    pub fn hostOffset(self: PreparedStream, stream_offset: u64, chunk_offset: u64) ?u64 {
        if (self.owned == null) return std.math.add(u64, chunk_offset, stream_offset) catch null;
        if (stream_offset < self.tables_prefix_len) return null;
        const strip_relative = std.math.add(
            u64,
            stream_offset - self.tables_prefix_len,
            self.strip_prefix_removed,
        ) catch return null;
        return std.math.add(u64, chunk_offset, strip_relative) catch null;
    }
};

/// Materialize the single JPEG stream used by both strict validation and
/// pixel decode, preventing validator/decoder disagreement over Mode 2 splice.
pub fn prepareStream(
    allocator: Allocator,
    strip_bytes: []const u8,
    jpeg_tables: ?[]const u8,
) errors.Error!PreparedStream {
    if (jpeg_tables) |tables| {
        const tables_trimmed = stripEoi(tables);
        const strip_trimmed = stripSoi(strip_bytes);
        const total = std.math.add(usize, tables_trimmed.len, strip_trimmed.len) catch return error.Malformed;
        const buf = allocator.alloc(u8, total) catch return error.OutOfMemory;
        @memcpy(buf[0..tables_trimmed.len], tables_trimmed);
        @memcpy(buf[tables_trimmed.len..], strip_trimmed);
        return .{
            .bytes = buf,
            .owned = buf,
            .tables_prefix_len = tables_trimmed.len,
            .strip_prefix_removed = strip_bytes.len - strip_trimmed.len,
        };
    }
    return .{
        .bytes = strip_bytes,
        .owned = null,
        .tables_prefix_len = 0,
        .strip_prefix_removed = 0,
    };
}

/// Decode an already-prepared stream after the caller has run jpegz validation.
pub fn decodePrepared(
    allocator: Allocator,
    stream: []const u8,
    dest: []u8,
) errors.Error!usize {
    const img = jpegz.decode(allocator, stream) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        // No jpegz decoder for this variant: reach, not a defect in the stream.
        error.NotImplemented => return error.UnsupportedCompression,
        else => return error.JpegInTiffPayload,
    };
    defer allocator.free(img.pixels);

    if (img.pixels.len > dest.len) return error.DestTooSmall;
    @memcpy(dest[0..img.pixels.len], img.pixels);
    return img.pixels.len;
}

/// Write a stored-sample decode (CFA, LinearRaw or gray, whose JPEG samples
/// are the chunk's samples with no color transform) in the form an
/// uncompressed chunk takes (TIFF 6.0 p. 30): rows of `row_samples` samples
/// that begin on a byte boundary, 8-bit samples as bytes, 16-bit samples as
/// SHORTs in the file's byte order, other depths packed high bit first with
/// no unused bits except at the end of a row. The decode's samples are read
/// in raster order, components interleaved, so a DNG lossless stream whose
/// width, length or component count differs from the chunk's still fills it
/// row by row ("Only the total sample counts need to match", DNG 1.6.0.0
/// p. 20). Returns the bytes written. Malformed when the samples do not fill
/// whole rows or one does not fit in `bps` bits; the caller compares the
/// length with the chunk's declared extent.
pub fn storeSamples(
    img: jpegz.Image,
    bps: u16,
    row_samples: usize,
    endian: Endian,
    dest: []u8,
) errors.Error!usize {
    if (bps == 0 or bps > 16 or row_samples == 0) return error.Malformed;
    const total = std.math.mul(usize, @as(usize, img.width) * img.height, img.channels) catch return error.Malformed;
    const wide = img.bits_per_sample > 8;
    if (img.pixels.len != (if (wide) total * 2 else total)) return error.Malformed;
    if (total % row_samples != 0) return error.Malformed;
    const rows = total / row_samples;
    const row_bits = std.math.mul(usize, row_samples, bps) catch return error.Malformed;
    const row_bytes = row_bits / 8 + @intFromBool(row_bits % 8 != 0);
    const out_len = std.math.mul(usize, rows, row_bytes) catch return error.Malformed;
    if (out_len > dest.len) return error.DestTooSmall;

    if (bps == 8 and !wide) {
        @memcpy(dest[0..out_len], img.pixels);
        return out_len;
    }
    const max: u32 = (@as(u32, 1) << @intCast(bps)) - 1;
    const sampleAt = struct {
        fn read(image: jpegz.Image, is_wide: bool, i: usize) u32 {
            if (!is_wide) return image.pixels[i];
            return std.mem.readInt(u16, image.pixels[i * 2 ..][0..2], native_endian);
        }
    }.read;
    if (bps == 16) {
        const order: std.builtin.Endian = if (endian == .little) .little else .big;
        for (0..total) |i| {
            std.mem.writeInt(u16, dest[i * 2 ..][0..2], @intCast(sampleAt(img, wide, i)), order);
        }
        return out_len;
    }

    var out: usize = 0;
    var i: usize = 0;
    for (0..rows) |_| {
        var acc: u32 = 0;
        var bits: u5 = 0;
        for (0..row_samples) |_| {
            const v = sampleAt(img, wide, i);
            i += 1;
            if (v > max) return error.Malformed;
            acc = (acc << @intCast(bps)) | v;
            bits += @intCast(bps);
            while (bits >= 8) {
                bits -= 8;
                dest[out] = @truncate(acc >> bits);
                out += 1;
            }
            acc &= (@as(u32, 1) << bits) - 1;
        }
        if (bits > 0) {
            dest[out] = @truncate(acc << (8 - @as(u4, @intCast(bits))));
            out += 1;
        }
    }
    std.debug.assert(out == out_len);
    return out_len;
}

/// Decode one JPEG-in-TIFF chunk into `dest`. `strip_bytes` is the
/// raw on-disk strip/tile data; `jpeg_tables` is the IFD's JPEGTables
/// tag value (tag 347) or `null` for Mode 1. Returns the number of
/// bytes written to `dest` (= width × height × samples × bytes_per_sample,
/// which the caller validates).
pub fn decode(
    allocator: Allocator,
    strip_bytes: []const u8,
    jpeg_tables: ?[]const u8,
    dest: []u8,
) errors.Error!usize {
    // Splice JPEGTables (sans trailing EOI) + strip_bytes (sans leading SOI)
    // when Mode 2. Mode 1 hands strip_bytes straight through.
    var prepared = try prepareStream(allocator, strip_bytes, jpeg_tables);
    defer prepared.deinit(allocator);

    // jpegz returns a fully realized RGB (or grayscale) image. The
    // pixel buffer is owned by jpegz's allocator; copy into `dest` so
    // the caller's lifetime story stays simple.
    // Use jpegz.decode (the pure-Zig cleanroom). jpegz reached byte-exact
    // parity with libjpeg for the TIFF Compression=7 cases we need: RGB/YCbCr
    // baseline AND Mode-2 spliced abbreviated (JPEGTables) streams, including
    // RGB signaled purely via component IDs 'R','G','B' with no JFIF/APP14
    // (jpegz 7e93e957, verified by a differential test vs the libjpeg oracle).
    // The libjpeg oracle is no longer linked (built -Dwith-libjpeg-oracle=false),
    // which also unblocks Windows cross-compile (libjpeg-turbo has no mingw static).
    // A jpegz failure here is a defect in the embedded JPEG stream, not in the
    // TIFF structure. The Decoder's production path validates this prepared
    // stream first, forwards the precise nested finding, and surfaces decode
    // failure as JpegInTiffPayload. Unvalidated, "no decoder for this
    // variant" also covers bytes that are not JPEG at all, so it stays a
    // payload failure here.
    return decodePrepared(allocator, prepared.bytes, dest) catch |e| switch (e) {
        error.UnsupportedCompression => error.JpegInTiffPayload,
        else => e,
    };
}

/// Strip trailing EOI marker (FF D9) if present. JPEG streams always
/// end with one; defensively no-op if absent so we don't truncate
/// valid data.
fn stripEoi(stream: []const u8) []const u8 {
    if (stream.len >= 2 and stream[stream.len - 2] == 0xFF and stream[stream.len - 1] == 0xD9) {
        return stream[0 .. stream.len - 2];
    }
    return stream;
}

/// Strip leading SOI marker (FF D8) if present. JPEG streams always
/// begin with one; defensive no-op for malformed inputs.
fn stripSoi(stream: []const u8) []const u8 {
    if (stream.len >= 2 and stream[0] == 0xFF and stream[1] == 0xD8) {
        return stream[2..];
    }
    return stream;
}

// ---- tests ----

test "stripEoi: trims trailing FF D9" {
    const with_eoi = [_]u8{ 0x01, 0x02, 0xFF, 0xD9 };
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02 }, stripEoi(&with_eoi));
}

test "stripEoi: passes through when no EOI" {
    const no_eoi = [_]u8{ 0x01, 0x02, 0x03 };
    try std.testing.expectEqualSlices(u8, &no_eoi, stripEoi(&no_eoi));
}

test "stripSoi: trims leading FF D8" {
    const with_soi = [_]u8{ 0xFF, 0xD8, 0x01, 0x02 };
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02 }, stripSoi(&with_soi));
}

test "stripSoi: passes through when no SOI" {
    const no_soi = [_]u8{ 0x01, 0x02 };
    try std.testing.expectEqualSlices(u8, &no_soi, stripSoi(&no_soi));
}

fn testImage(pixels: []u8, width: u32, height: u32, channels: u8, precision: u8) jpegz.Image {
    return .{
        .pixels = pixels,
        .width = width,
        .height = height,
        .channels = channels,
        .bits_per_sample = precision,
        .source_color_space = if (channels == 1) .grayscale else .rgb,
        .layout = if (channels == 1) .grayscale else .rgb,
    };
}

fn wideSamples(comptime values: []const u16) [values.len * 2]u8 {
    var out: [values.len * 2]u8 = undefined;
    for (values, 0..) |v, i| std.mem.writeInt(u16, out[i * 2 ..][0..2], v, native_endian);
    return out;
}

test "storeSamples packs 12-bit samples high bit first and pads each row to a byte (TIFF 6.0 p. 30)" {
    // Three samples ABC 123 456 are 36 bits: AB C1 23 45 6 and four pad bits.
    var one_row = wideSamples(&.{ 0xABC, 0x123, 0x456 });
    var dest: [8]u8 = undefined;
    const n = try storeSamples(testImage(&one_row, 3, 1, 1, 12), 12, 3, .little, &dest);
    try std.testing.expectEqualSlices(u8, &.{ 0xAB, 0xC1, 0x23, 0x45, 0x60 }, dest[0..n]);

    // One sample per row: each row starts on its own byte.
    var two_rows = wideSamples(&.{ 0xABC, 0xDEF });
    const m = try storeSamples(testImage(&two_rows, 1, 2, 1, 12), 12, 1, .big, &dest);
    try std.testing.expectEqualSlices(u8, &.{ 0xAB, 0xC0, 0xDE, 0xF0 }, dest[0..m]);
}

test "storeSamples writes 16-bit samples in the file's byte order" {
    var px = wideSamples(&.{ 0x0102, 0xA0B0 });
    var dest: [4]u8 = undefined;
    _ = try storeSamples(testImage(&px, 2, 1, 1, 16), 16, 2, .little, &dest);
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x01, 0xB0, 0xA0 }, &dest);
    _ = try storeSamples(testImage(&px, 2, 1, 1, 16), 16, 2, .big, &dest);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0xA0, 0xB0 }, &dest);
}

test "storeSamples fills chunk rows from a frame of another shape, in raster order (DNG 1.6.0.0 p. 20)" {
    // A 2x1 two-component frame is four samples: one row of a 4-sample chunk.
    var px = [_]u8{ 1, 2, 3, 4 };
    var dest: [4]u8 = undefined;
    const n = try storeSamples(testImage(&px, 2, 1, 2, 8), 8, 4, .little, &dest);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, dest[0..n]);
}

test "storeSamples refuses a sample wider than BitsPerSample and a partial row" {
    var px = wideSamples(&.{ 0x1000, 0x0001 });
    var dest: [8]u8 = undefined;
    try std.testing.expectError(error.Malformed, storeSamples(testImage(&px, 2, 1, 1, 16), 12, 2, .little, &dest));
    var ok = wideSamples(&.{ 0x0FFF, 0x0001 });
    try std.testing.expectEqual(@as(usize, 3), try storeSamples(testImage(&ok, 2, 1, 1, 16), 12, 2, .little, &dest));
    try std.testing.expectError(error.Malformed, storeSamples(testImage(&ok, 2, 1, 1, 16), 12, 3, .little, &dest));
    try std.testing.expectError(error.DestTooSmall, storeSamples(testImage(&ok, 2, 1, 1, 16), 12, 2, .little, dest[0..2]));
}

test "decode: malformed JPEG payloads map to error.JpegInTiffPayload, not generic Malformed" {
    // A jpegz decode failure on a Compression=7 strip is a JPEG-payload defect,
    // not a TIFF-structure defect; it must surface as its own error so validate's
    // routeError can label it correctly. Classifier over deterministic jpegz
    // failures (Mode 1: strip bytes ARE the stream). The must-pass side (valid
    // stream -> success) is covered by the ycbcr_jpeg.tif / rgb-jpeg.tif oracle
    // tests in fixture_test.zig.
    const allocator = std.testing.allocator;
    var dest: [64]u8 = undefined;
    const bad_streams = [_][]const u8{
        &[_]u8{}, // empty — no SOI
        &[_]u8{ 0x00, 0x01, 0x02, 0x03 }, // no SOI marker
        &[_]u8{ 0xFF, 0xD8, 0xFF, 0xD9 }, // SOI + EOI, no frame
    };
    for (bad_streams) |s| {
        try std.testing.expectError(error.JpegInTiffPayload, decode(allocator, s, null, &dest));
    }
}
