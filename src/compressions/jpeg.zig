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
//! Photometric scope (M9.5): RGB (2) only. YCbCr (6) lands at M9
//! where YCbCr-derived photometric expansion arrives properly.

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
    // Use jpegz.internal.wrapperDecode (the libjpeg path) directly
    // instead of the regular jpegz.decode dispatch. Reason: jpegz's
    // baseline cleanroom (B0 milestone) is currently byte-perfect on
    // ~72% of libjpeg's corpus and within ≤2 LSB on the rest. For
    // TIFF Compression=7 we need exact agreement with the magick
    // oracle (which also goes through libjpeg), so we pin the libjpeg
    // wrapper. When jpegz Phase 2 cleanroom becomes byte-exact on
    // RGB-marked baseline + spliced abbreviated streams, this swaps
    // back to plain jpegz.decode and the cleanroom takes over with
    // no behavioral change.
    const img = jpegz.internal.wrapperDecode(allocator, stream) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Malformed,
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
