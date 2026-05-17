//! Photometric expansion: decoded strip bytes → RGBA pixels.
//!
//! tiff2rgba's expansion rules (matching libtiff convention):
//!
//!   PhotometricInterpretation = 0 (MinIsWhite, grayscale inverted):
//!     R = G = B = ~sample;  A = 255
//!   PhotometricInterpretation = 1 (MinIsBlack, grayscale):
//!     R = G = B = sample;   A = 255
//!   PhotometricInterpretation = 2 (RGB):
//!     R, G, B = sample0, sample1, sample2;  A = 255 (or sample3 if extras)
//!   PhotometricInterpretation = 3 (Palette):
//!     R, G, B = colormap[idx], colormap[idx+N], colormap[idx+2N];
//!     A = 255. ColorMap entries are u16 0..65535; we down-shift to
//!     u8 by taking the high byte (>> 8) which is what tiff2rgba does.
//!
//! M3 follow-up scope: 8-bit per sample, chunky planar config,
//! photometric ∈ {0, 1, 2, 3}. Other photometrics (CMYK, YCbCr, Lab)
//! land at M9; non-8-bit at M5; planar=separate at later milestones.

const std = @import("std");

const errors = @import("errors.zig");
const tags = @import("tags.zig");

pub const PixelFormat = struct {
    photometric: u16,
    bits_per_sample: u16,           // assumed uniform across samples for M3
    samples_per_pixel: u16,
    width: u32,
    /// For palette photometric only. Length = 3 × (2^bits_per_sample).
    /// Layout per TIFF 6.0: all R values, then all G, then all B.
    colormap: ?[]const u16,
};

/// Expand `src_rows` rows of decoded chunky pixel data into RGBA.
/// `src_bytes` is the on-disk row data for those rows (row-stride =
/// width × samples_per_pixel × bits_per_sample/8). `dest` must be at
/// least `src_rows × width × 4` bytes; only that prefix is written.
pub fn expandRowsToRgba(
    src_bytes: []const u8,
    src_rows: u32,
    fmt: PixelFormat,
    dest: []u8,
) errors.Error!void {
    if (fmt.bits_per_sample != 1 and fmt.bits_per_sample != 8) return error.UnsupportedBitDepth;

    const out_bytes_per_row: usize = @as(usize, fmt.width) * 4;
    const need_dest = out_bytes_per_row * src_rows;
    if (dest.len < need_dest) return error.DestTooSmall;

    if (fmt.bits_per_sample == 1) {
        // 1-bit per sample is grayscale-only by spec (samples_per_pixel = 1).
        return switch (fmt.photometric) {
            tags.photometric_white_is_zero => expandGray1bit(src_bytes, src_rows, fmt, dest, .invert),
            tags.photometric_black_is_zero => expandGray1bit(src_bytes, src_rows, fmt, dest, .direct),
            else => error.UnsupportedPhotometric,
        };
    }

    return switch (fmt.photometric) {
        tags.photometric_white_is_zero => expandGray(src_bytes, src_rows, fmt, dest, .invert),
        tags.photometric_black_is_zero => expandGray(src_bytes, src_rows, fmt, dest, .direct),
        tags.photometric_rgb => expandRgb(src_bytes, src_rows, fmt, dest),
        tags.photometric_palette => expandPalette(src_bytes, src_rows, fmt, dest),
        // CFA mosaic raw — v1 emits each sample as gray RGBA. The
        // consumer (validate, raw-pipeline tools) does demosaic later
        // using the CFAPattern tag (parsed in src/dng.zig). Full
        // Bayer/X-Trans demosaic lands at M11/M12.
        tags.photometric_color_filter_array => expandGray(src_bytes, src_rows, fmt, dest, .direct),
        else => error.UnsupportedPhotometric,
    };
}

/// 1-bit-per-pixel grayscale expansion. Source bytes are packed
/// MSB-first within each byte (bit 7 = leftmost pixel of those 8) —
/// the conventional in-memory layout after CCITT decode normalizes
/// FillOrder. `direct` mode: bit=0 → black (0x00), bit=1 → white (0xFF)
/// (PhotometricInterpretation = 1 / MinIsBlack). `invert` flips both
/// sides (PhotometricInterpretation = 0 / MinIsWhite, the fax default).
fn expandGray1bit(
    src_bytes: []const u8,
    src_rows: u32,
    fmt: PixelFormat,
    dest: []u8,
    mode: GrayMode,
) errors.Error!void {
    if (fmt.samples_per_pixel != 1) return error.UnsupportedPhotometric;

    const bytes_per_row: usize = (@as(usize, fmt.width) + 7) / 8;
    if (src_bytes.len < bytes_per_row * src_rows) return error.SourceShortRead;

    var di: usize = 0;
    var rows_done: u32 = 0;
    while (rows_done < src_rows) : (rows_done += 1) {
        const row = src_bytes[rows_done * bytes_per_row ..][0..bytes_per_row];
        var x: u32 = 0;
        while (x < fmt.width) : (x += 1) {
            const byte_idx: usize = x / 8;
            const bit_idx: u3 = @intCast(7 - (x % 8));
            const bit: u1 = @intCast((row[byte_idx] >> bit_idx) & 1);
            // bit=1 means "set" (black under MinIsBlack, white under MinIsWhite);
            // bit=0 means "unset". `mode` flips the intensity polarity.
            const v: u8 = switch (mode) {
                .direct => if (bit == 1) 0xFF else 0x00,
                .invert => if (bit == 1) 0x00 else 0xFF,
            };
            dest[di + 0] = v;
            dest[di + 1] = v;
            dest[di + 2] = v;
            dest[di + 3] = 0xFF;
            di += 4;
        }
    }
}

const GrayMode = enum { direct, invert };

fn expandGray(
    src_bytes: []const u8,
    src_rows: u32,
    fmt: PixelFormat,
    dest: []u8,
    mode: GrayMode,
) errors.Error!void {
    if (fmt.samples_per_pixel != 1) return error.UnsupportedPhotometric;

    const stride: usize = @as(usize, fmt.width);
    if (src_bytes.len < stride * src_rows) return error.SourceShortRead;

    var di: usize = 0;
    var si: usize = 0;
    var rows_done: u32 = 0;
    while (rows_done < src_rows) : (rows_done += 1) {
        var x: u32 = 0;
        while (x < fmt.width) : (x += 1) {
            const v: u8 = switch (mode) {
                .direct => src_bytes[si],
                .invert => 0xFF -% src_bytes[si],
            };
            dest[di + 0] = v;
            dest[di + 1] = v;
            dest[di + 2] = v;
            dest[di + 3] = 0xFF;
            si += 1;
            di += 4;
        }
    }
}

fn expandRgb(
    src_bytes: []const u8,
    src_rows: u32,
    fmt: PixelFormat,
    dest: []u8,
) errors.Error!void {
    if (fmt.samples_per_pixel < 3) return error.UnsupportedPhotometric;
    const stride: usize = @as(usize, fmt.width) * fmt.samples_per_pixel;
    if (src_bytes.len < stride * src_rows) return error.SourceShortRead;

    var di: usize = 0;
    var si: usize = 0;
    var rows_done: u32 = 0;
    while (rows_done < src_rows) : (rows_done += 1) {
        var x: u32 = 0;
        while (x < fmt.width) : (x += 1) {
            dest[di + 0] = src_bytes[si + 0];
            dest[di + 1] = src_bytes[si + 1];
            dest[di + 2] = src_bytes[si + 2];
            // Alpha: extra sample if present, else opaque.
            dest[di + 3] = if (fmt.samples_per_pixel >= 4) src_bytes[si + 3] else 0xFF;
            si += fmt.samples_per_pixel;
            di += 4;
        }
    }
}

fn expandPalette(
    src_bytes: []const u8,
    src_rows: u32,
    fmt: PixelFormat,
    dest: []u8,
) errors.Error!void {
    if (fmt.samples_per_pixel != 1) return error.UnsupportedPhotometric;
    const cmap = fmt.colormap orelse return error.Malformed;

    const palette_size: usize = @as(usize, 1) << @intCast(fmt.bits_per_sample);
    if (cmap.len < 3 * palette_size) return error.Malformed;

    const r_base: usize = 0;
    const g_base: usize = palette_size;
    const b_base: usize = 2 * palette_size;

    const stride: usize = fmt.width;
    if (src_bytes.len < stride * src_rows) return error.SourceShortRead;

    var di: usize = 0;
    var si: usize = 0;
    var rows_done: u32 = 0;
    while (rows_done < src_rows) : (rows_done += 1) {
        var x: u32 = 0;
        while (x < fmt.width) : (x += 1) {
            const idx: usize = src_bytes[si];
            dest[di + 0] = u16ToU8(cmap[r_base + idx]);
            dest[di + 1] = u16ToU8(cmap[g_base + idx]);
            dest[di + 2] = u16ToU8(cmap[b_base + idx]);
            dest[di + 3] = 0xFF;
            si += 1;
            di += 4;
        }
    }
}

/// Canonical u16-to-u8 downscale: `round(x * 255 / 65535)`. TIFF
/// ColorMap entries are u16 (full-range 0..65535) per TIFF 6.0 spec.
/// Matches ImageMagick's ScaleQuantumToChar in 16-bit Q. Truncation
/// (`x >> 8`) introduces an off-by-one against the spec for any value
/// whose low byte is ≥ 0x80 (e.g. 0x49E8 truncates to 0x49 but the
/// correct answer is 0x4A).
fn u16ToU8(x: u16) u8 {
    return @intCast((@as(u32, x) * 255 + 32767) / 65535);
}

// ---- tests ----

test "expandRgb: 2x2 RGB → RGBA with alpha=255" {
    const src = [_]u8{
        0xFF, 0x00, 0x00, // pixel 0,0 red
        0x00, 0xFF, 0x00, // pixel 0,1 green
        0x00, 0x00, 0xFF, // pixel 1,0 blue
        0xFF, 0xFF, 0x00, // pixel 1,1 yellow
    };
    var dest: [16]u8 = undefined;
    try expandRowsToRgba(&src, 2, .{
        .photometric = tags.photometric_rgb,
        .bits_per_sample = 8,
        .samples_per_pixel = 3,
        .width = 2,
        .colormap = null,
    }, &dest);
    try std.testing.expectEqualSlices(u8, &.{
        0xFF, 0x00, 0x00, 0xFF,
        0x00, 0xFF, 0x00, 0xFF,
        0x00, 0x00, 0xFF, 0xFF,
        0xFF, 0xFF, 0x00, 0xFF,
    }, &dest);
}

test "expandGray direct (MinIsBlack): 1 row of 4 → RGBA with R=G=B=value" {
    const src = [_]u8{ 0x00, 0x55, 0xAA, 0xFF };
    var dest: [16]u8 = undefined;
    try expandRowsToRgba(&src, 1, .{
        .photometric = tags.photometric_black_is_zero,
        .bits_per_sample = 8,
        .samples_per_pixel = 1,
        .width = 4,
        .colormap = null,
    }, &dest);
    try std.testing.expectEqualSlices(u8, &.{
        0x00, 0x00, 0x00, 0xFF,
        0x55, 0x55, 0x55, 0xFF,
        0xAA, 0xAA, 0xAA, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
    }, &dest);
}

test "expandGray invert (MinIsWhite): 0x00 → white, 0xFF → black" {
    const src = [_]u8{ 0x00, 0xFF };
    var dest: [8]u8 = undefined;
    try expandRowsToRgba(&src, 1, .{
        .photometric = tags.photometric_white_is_zero,
        .bits_per_sample = 8,
        .samples_per_pixel = 1,
        .width = 2,
        .colormap = null,
    }, &dest);
    try std.testing.expectEqualSlices(u8, &.{
        0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x00, 0x00, 0xFF,
    }, &dest);
}

test "expandPalette: 8-bit indices into a 256-entry colormap" {
    // 256-entry colormap (3 × 256 u16 values per TIFF 6.0 layout).
    // We populate just slots 0 and 1: rest is implicitly zero.
    var cmap: [768]u16 = .{0} ** 768;
    // R[0]=0x0000, R[1]=0xFFFF
    cmap[0] = 0x0000;
    cmap[1] = 0xFFFF;
    // G[0]=0x0000, G[1]=0xFFFF — at offset 256
    cmap[256] = 0x0000;
    cmap[257] = 0xFFFF;
    // B[0]=0xFFFF, B[1]=0x0000 — at offset 512
    cmap[512] = 0xFFFF;
    cmap[513] = 0x0000;

    const src = [_]u8{ 0, 1, 1, 0 };
    var dest: [16]u8 = undefined;
    try expandRowsToRgba(&src, 1, .{
        .photometric = tags.photometric_palette,
        .bits_per_sample = 8,
        .samples_per_pixel = 1,
        .width = 4,
        .colormap = &cmap,
    }, &dest);
    try std.testing.expectEqualSlices(u8, &.{
        0x00, 0x00, 0xFF, 0xFF, // idx 0 = blue
        0xFF, 0xFF, 0x00, 0xFF, // idx 1 = yellow
        0xFF, 0xFF, 0x00, 0xFF,
        0x00, 0x00, 0xFF, 0xFF,
    }, &dest);
}

test "expandRowsToRgba rejects unsupported bit depth" {
    var dest: [4]u8 = undefined;
    try std.testing.expectError(error.UnsupportedBitDepth, expandRowsToRgba(&.{}, 0, .{
        .photometric = tags.photometric_rgb,
        .bits_per_sample = 16,
        .samples_per_pixel = 3,
        .width = 1,
        .colormap = null,
    }, &dest));
}

test "expandGray1bit MinIsWhite (fax default): 0-bits → white, 1-bits → black" {
    // 8-pixel row, MSB-first packed: 0b10110000 = 0xB0.
    // Pixels: 1 0 1 1 0 0 0 0 → black white black black white white white white.
    // Under MinIsWhite (invert): 1=black=0, 0=white=255.
    const src = [_]u8{0xB0};
    var dest: [32]u8 = undefined;
    try expandRowsToRgba(&src, 1, .{
        .photometric = tags.photometric_white_is_zero,
        .bits_per_sample = 1,
        .samples_per_pixel = 1,
        .width = 8,
        .colormap = null,
    }, &dest);
    // pixel 0 (bit=1) → black; pixel 1 (bit=0) → white; …
    try std.testing.expectEqualSlices(u8, &.{
        0x00, 0x00, 0x00, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x00, 0x00, 0xFF,
        0x00, 0x00, 0x00, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
    }, &dest);
}

test "expandGray1bit MinIsBlack (direct): 0=black, 1=white" {
    // 4 pixels worth in the high nibble: 0b1010_0000.
    const src = [_]u8{0xA0};
    var dest: [16]u8 = undefined;
    try expandRowsToRgba(&src, 1, .{
        .photometric = tags.photometric_black_is_zero,
        .bits_per_sample = 1,
        .samples_per_pixel = 1,
        .width = 4,
        .colormap = null,
    }, &dest);
    try std.testing.expectEqualSlices(u8, &.{
        0xFF, 0xFF, 0xFF, 0xFF, // bit 1 = white
        0x00, 0x00, 0x00, 0xFF, // bit 0 = black
        0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x00, 0x00, 0xFF,
    }, &dest);
}

test "expandGray1bit handles non-byte-aligned width" {
    // 12 pixels, 2 bytes-per-row. Bits: 1100_1010_1111_xxxx (last 4 ignored).
    const src = [_]u8{ 0xCA, 0xF0 };
    var dest: [48]u8 = undefined;
    try expandRowsToRgba(&src, 1, .{
        .photometric = tags.photometric_black_is_zero,
        .bits_per_sample = 1,
        .samples_per_pixel = 1,
        .width = 12,
        .colormap = null,
    }, &dest);
    const expected = [_]u8{
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x00, 0x00, 0xFF,
        0x00, 0x00, 0x00, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x00, 0x00, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x00, 0x00, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
    };
    try std.testing.expectEqualSlices(u8, &expected, &dest);
}

test "expandRowsToRgba rejects unsupported photometric" {
    var dest: [4]u8 = undefined;
    try std.testing.expectError(error.UnsupportedPhotometric, expandRowsToRgba(&.{}, 0, .{
        .photometric = tags.photometric_separated_cmyk,
        .bits_per_sample = 8,
        .samples_per_pixel = 4,
        .width = 1,
        .colormap = null,
    }, &dest));
}

test "expandRowsToRgba photometric=CFA (32803) maps each sample as gray RGBA" {
    // CFA mosaic raw — one sample per sensor site. tiffz emits each
    // sample as gray (R=G=B=value, A=255) so consumers can see the
    // mosaic; full demosaic lands at M11/M12. spp=1 for CFA.
    const src = [_]u8{ 0x10, 0x80, 0xC0, 0xFF };
    var dest: [16]u8 = undefined;
    try expandRowsToRgba(&src, 1, .{
        .photometric = tags.photometric_color_filter_array,
        .bits_per_sample = 8,
        .samples_per_pixel = 1,
        .width = 4,
        .colormap = null,
    }, &dest);
    try std.testing.expectEqualSlices(u8, &.{
        0x10, 0x10, 0x10, 0xFF,
        0x80, 0x80, 0x80, 0xFF,
        0xC0, 0xC0, 0xC0, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
    }, &dest);
}

test "expandRowsToRgba rejects too-small dest" {
    const src = [_]u8{ 0xFF, 0x00, 0x00 };
    var dest: [3]u8 = undefined;
    try std.testing.expectError(error.DestTooSmall, expandRowsToRgba(&src, 1, .{
        .photometric = tags.photometric_rgb,
        .bits_per_sample = 8,
        .samples_per_pixel = 3,
        .width = 1,
        .colormap = null,
    }, &dest));
}
