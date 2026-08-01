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
//! Photometric scope: RGB (2) and YCbCr (6). For YCbCr the underlying
//! libjpeg-turbo wrapper performs internal YCbCr→RGB conversion, so
//! the bytes returned in `dest` are RGB pixels regardless of the TIFF
//! photometric tag. The caller MUST treat the output as
//! photometric=RGB during photometric expansion (libtiff takes the
//! same approach in TIFFReadRGBAImage). Non-RGB/non-YCbCr photometric
//! values with Compression=7 surface as UnsupportedCompression at the
//! decoder layer.

const std = @import("std");
const Allocator = std.mem.Allocator;

const errors = @import("../errors.zig");
const jpegz = @import("jpegz");

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
    var spliced_owned: ?[]u8 = null;
    defer if (spliced_owned) |b| allocator.free(b);

    const stream: []const u8 = if (jpeg_tables) |tables| blk: {
        // JPEGTables shape: SOI (FF D8) … markers … EOI (FF D9). Strip
        // bytes shape: SOI (FF D8) … markers + scan … EOI (FF D9). After
        // splicing, the result is SOI … tables-markers … SOF SOS scan … EOI.
        const tables_trimmed = stripEoi(tables);
        const strip_trimmed = stripSoi(strip_bytes);
        const total = tables_trimmed.len + strip_trimmed.len;
        const buf = allocator.alloc(u8, total) catch return error.OutOfMemory;
        @memcpy(buf[0..tables_trimmed.len], tables_trimmed);
        @memcpy(buf[tables_trimmed.len..], strip_trimmed);
        spliced_owned = buf;
        break :blk buf;
    } else strip_bytes;

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
    // TIFF structure. Surface it as JpegInTiffPayload so the caller (validate)
    // can route it to a JPEG-payload message instead of "Invalid TIFF
    // structure". The specific jpegz cause (missing SOI / bad SOF / huffman /
    // truncated scan) is a separate nested-finding change gated on Einstein's
    // Namespace-A sign-off (see findings.zig) — this is the categorization tier.
    const img = jpegz.decode(allocator, stream) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.JpegInTiffPayload,
    };
    defer allocator.free(img.pixels);

    if (img.pixels.len > dest.len) return error.DestTooSmall;
    @memcpy(dest[0..img.pixels.len], img.pixels);
    return img.pixels.len;
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
