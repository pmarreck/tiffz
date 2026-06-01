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
const header_mod = @import("header.zig");
const Endian = header_mod.Endian;

pub const PixelFormat = struct {
    photometric: u16,
    bits_per_sample: u16,           // assumed uniform across samples; supported widths: 1, 8, 16 (16 for RGB/Gray/CMYK only)
    samples_per_pixel: u16,
    width: u32,
    /// For palette photometric only. Length = 3 × (2^bits_per_sample).
    /// Layout per TIFF 6.0: all R values, then all G, then all B.
    colormap: ?[]const u16,
    /// File byte order. Only consulted for 16-bit-per-sample reads
    /// (the canonical u16 -> u8 downscale `(x * 255 + 32767) / 65535`
    /// is endian-independent once the u16 is recovered). Defaults to
    /// `.little` since 8-bit paths ignore it.
    endian: Endian = .little,
};

/// For separate planar (TIFF tag 284 = 2): interleave N per-plane row
/// buffers into a single chunky buffer that `expandRowsToRgba` can
/// consume. `plane_buffers[k]` holds the samples for channel `k`,
/// laid out as `rows × width` samples in file byte order.
///
/// Output layout (chunky): pixel-0 ch-0, pixel-0 ch-1, …, pixel-0 ch-N-1,
/// pixel-1 ch-0, … Row-major over rows.
///
/// Required because TIFF separate-planar storage delivers one plane
/// at a time (each strip is a single channel). Callers that already
/// have chunky data skip this helper.
pub fn interleavePlanesToChunky(
    plane_buffers: []const []const u8,
    rows: u32,
    width: u32,
    bits_per_sample: u16,
    dest: []u8,
) errors.Error!void {
    if (bits_per_sample != 8 and bits_per_sample != 16) return error.UnsupportedBitDepth;
    if (plane_buffers.len == 0) return error.InvalidArgument;
    const sample_bytes: usize = bits_per_sample / 8;
    const spp: usize = plane_buffers.len;
    const bytes_per_plane_row: usize = @as(usize, width) * sample_bytes;
    const bytes_per_chunky_row: usize = bytes_per_plane_row * spp;
    const total_rows: usize = @as(usize, rows);
    if (dest.len < bytes_per_chunky_row * total_rows) return error.DestTooSmall;
    for (plane_buffers) |plane| {
        if (plane.len < bytes_per_plane_row * total_rows) return error.SourceShortRead;
    }

    var row_idx: u32 = 0;
    while (row_idx < rows) : (row_idx += 1) {
        const plane_row_off: usize = @as(usize, row_idx) * bytes_per_plane_row;
        const chunky_row_off: usize = @as(usize, row_idx) * bytes_per_chunky_row;
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const plane_sample_off: usize = plane_row_off + @as(usize, x) * sample_bytes;
            const chunky_pixel_off: usize = chunky_row_off + @as(usize, x) * spp * sample_bytes;
            var k: usize = 0;
            while (k < spp) : (k += 1) {
                const dst_off: usize = chunky_pixel_off + k * sample_bytes;
                var b: usize = 0;
                while (b < sample_bytes) : (b += 1) {
                    dest[dst_off + b] = plane_buffers[k][plane_sample_off + b];
                }
            }
        }
    }
}

/// Read one sample at `byte_offset` in `bytes` and return it as a u8.
/// For bps=8 this is just `bytes[byte_offset]`; for bps=16 it reads the
/// endian-aware u16 then downscales via the canonical
/// `(x*255 + 32767) / 65535` round-to-nearest formula that matches
/// ImageMagick's ScaleQuantumToChar.
fn sampleU8(bytes: []const u8, byte_offset: usize, bps: u16, endian: Endian) u8 {
    if (bps == 8) return bytes[byte_offset];
    // bps == 16. Caller is responsible for guaranteeing other widths
    // never reach the per-pixel loop.
    const std_endian: std.builtin.Endian = if (endian == .little) .little else .big;
    const v16 = std.mem.readInt(u16, bytes[byte_offset..][0..2], std_endian);
    return @intCast((@as(u32, v16) * 255 + 32767) / 65535);
}

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
    if (fmt.bits_per_sample != 1 and fmt.bits_per_sample != 8 and fmt.bits_per_sample != 16) {
        return error.UnsupportedBitDepth;
    }

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

    // bps ∈ {8, 16}. The 16-bit code path is supported only for the
    // photometrics where it makes engineering sense and has real-world
    // demand: RGB / Gray / CMYK. Palette + CFA stay 8-bit (16-bit
    // palette is exceedingly rare — would need a 65536-entry ColorMap).
    // YCbCr and CIELAB at 16-bit are niche and deferred until a
    // concrete need surfaces.
    if (fmt.bits_per_sample == 16) {
        switch (fmt.photometric) {
            tags.photometric_white_is_zero,
            tags.photometric_black_is_zero,
            tags.photometric_rgb,
            tags.photometric_separated_cmyk,
            => {},
            tags.photometric_palette,
            tags.photometric_color_filter_array,
            tags.photometric_ycbcr,
            tags.photometric_cielab,
            tags.photometric_icclab,
            => return error.UnsupportedBitDepth,
            else => return error.UnsupportedPhotometric,
        }
    }

    return switch (fmt.photometric) {
        tags.photometric_white_is_zero => expandGray(src_bytes, src_rows, fmt, dest, .invert),
        tags.photometric_black_is_zero => expandGray(src_bytes, src_rows, fmt, dest, .direct),
        tags.photometric_rgb => expandRgb(src_bytes, src_rows, fmt, dest),
        tags.photometric_palette => expandPalette(src_bytes, src_rows, fmt, dest),
        tags.photometric_separated_cmyk => expandCmyk(src_bytes, src_rows, fmt, dest),
        tags.photometric_ycbcr => expandYCbCr(src_bytes, src_rows, fmt, dest),
        tags.photometric_cielab => expandCieLab(src_bytes, src_rows, fmt, dest),
        // ICCLab: same chain, different a/b byte encoding (TIFF
        // Tech Note 3). expandCieLab selects the LUT based on
        // fmt.photometric.
        tags.photometric_icclab => expandCieLab(src_bytes, src_rows, fmt, dest),
        // CFA mosaic raw — v1 emits each sample as gray RGBA. The
        // consumer (validate, raw-pipeline tools) does demosaic later
        // using the CFAPattern tag (parsed in src/dng.zig). Full
        // Bayer/X-Trans demosaic lands at M11/M12.
        tags.photometric_color_filter_array => expandGray(src_bytes, src_rows, fmt, dest, .direct),
        else => error.UnsupportedPhotometric,
    };
}

/// CMYK → RGBA without an ICC profile. Standard subtractive recipe:
///   R = (255 - C) * (255 - K) / 255
///   G = (255 - M) * (255 - K) / 255
///   B = (255 - Y) * (255 - K) / 255
/// The /255 uses round-to-nearest (`(x + 127) / 255`) so the result
/// hits exact 0 / 255 endpoints without truncation drift.
/// Real-world print workflows want an ICC profile (CMYK is
/// device-dependent), but the spec-correct no-profile fallback is the
/// subtractive identity above and that's what tiffz emits at v1.
fn expandCmyk(
    src_bytes: []const u8,
    src_rows: u32,
    fmt: PixelFormat,
    dest: []u8,
) errors.Error!void {
    if (fmt.samples_per_pixel < 4) return error.UnsupportedPhotometric;
    const sample_bytes: usize = fmt.bits_per_sample / 8;
    const stride_bytes: usize = @as(usize, fmt.width) * fmt.samples_per_pixel * sample_bytes;
    if (src_bytes.len < stride_bytes * src_rows) return error.SourceShortRead;

    var di: usize = 0;
    var si: usize = 0;
    var rows_done: u32 = 0;
    while (rows_done < src_rows) : (rows_done += 1) {
        var x: u32 = 0;
        while (x < fmt.width) : (x += 1) {
            if (fmt.bits_per_sample == 16) {
                // Full u16-precision subtractive composition: keeps
                // all 16 bits of each channel through the multiply,
                // downscale to u8 only at the end. Diverges from
                // u8-first by up to 1 LSB on synthetic mid-range
                // inputs (e.g. C=K=0x8000 → R=64 here, R=63 under
                // u8-first). Real ICC-aware workflows want #3
                // anyway, but the lossless-by-default math is the
                // honest v1 shape now that we've measured the gap.
                const std_endian: std.builtin.Endian = if (fmt.endian == .little) .little else .big;
                const c16: u32 = std.mem.readInt(u16, src_bytes[si + 0 * sample_bytes ..][0..2], std_endian);
                const m16: u32 = std.mem.readInt(u16, src_bytes[si + 1 * sample_bytes ..][0..2], std_endian);
                const y16: u32 = std.mem.readInt(u16, src_bytes[si + 2 * sample_bytes ..][0..2], std_endian);
                const k16: u32 = std.mem.readInt(u16, src_bytes[si + 3 * sample_bytes ..][0..2], std_endian);
                const k_inv16: u32 = 65535 - k16;
                // Composition stays in u32 (max product = 65535*65535 = 0xfffe_0001 < 2^32).
                // Add 65535/2 = 32767 for round-to-nearest, then floor-divide.
                const r16: u32 = ((65535 - c16) * k_inv16 + 32767) / 65535;
                const g16: u32 = ((65535 - m16) * k_inv16 + 32767) / 65535;
                const b16: u32 = ((65535 - y16) * k_inv16 + 32767) / 65535;
                // Downscale each u16-ish u32 to u8 with the canonical
                // (v*255+32767)/65535 mapping; same shape sampleU8 uses.
                dest[di + 0] = @intCast((r16 * 255 + 32767) / 65535);
                dest[di + 1] = @intCast((g16 * 255 + 32767) / 65535);
                dest[di + 2] = @intCast((b16 * 255 + 32767) / 65535);
                dest[di + 3] = if (fmt.samples_per_pixel >= 5)
                    sampleU8(src_bytes, si + 4 * sample_bytes, fmt.bits_per_sample, fmt.endian)
                else
                    0xFF;
            } else {
                // u8 path: per-channel downscale to u8 (no-op when
                // bits_per_sample==8), then composition in u32.
                const c: u32 = sampleU8(src_bytes, si + 0 * sample_bytes, fmt.bits_per_sample, fmt.endian);
                const m: u32 = sampleU8(src_bytes, si + 1 * sample_bytes, fmt.bits_per_sample, fmt.endian);
                const y: u32 = sampleU8(src_bytes, si + 2 * sample_bytes, fmt.bits_per_sample, fmt.endian);
                const k: u32 = sampleU8(src_bytes, si + 3 * sample_bytes, fmt.bits_per_sample, fmt.endian);
                const k_inv: u32 = 255 - k;
                dest[di + 0] = @intCast(((255 - c) * k_inv + 127) / 255);
                dest[di + 1] = @intCast(((255 - m) * k_inv + 127) / 255);
                dest[di + 2] = @intCast(((255 - y) * k_inv + 127) / 255);
                dest[di + 3] = if (fmt.samples_per_pixel >= 5)
                    sampleU8(src_bytes, si + 4 * sample_bytes, fmt.bits_per_sample, fmt.endian)
                else
                    0xFF;
            }
            si += @as(usize, fmt.samples_per_pixel) * sample_bytes;
            di += 4;
        }
    }
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

    const sample_bytes: usize = fmt.bits_per_sample / 8;
    const stride_bytes: usize = @as(usize, fmt.width) * sample_bytes;
    if (src_bytes.len < stride_bytes * src_rows) return error.SourceShortRead;

    var di: usize = 0;
    var si: usize = 0;
    var rows_done: u32 = 0;
    while (rows_done < src_rows) : (rows_done += 1) {
        var x: u32 = 0;
        while (x < fmt.width) : (x += 1) {
            const raw: u8 = sampleU8(src_bytes, si, fmt.bits_per_sample, fmt.endian);
            const v: u8 = switch (mode) {
                .direct => raw,
                .invert => 0xFF -% raw,
            };
            dest[di + 0] = v;
            dest[di + 1] = v;
            dest[di + 2] = v;
            dest[di + 3] = 0xFF;
            si += sample_bytes;
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
    const sample_bytes: usize = fmt.bits_per_sample / 8;
    const stride_bytes: usize = @as(usize, fmt.width) * fmt.samples_per_pixel * sample_bytes;
    if (src_bytes.len < stride_bytes * src_rows) return error.SourceShortRead;

    var di: usize = 0;
    var si: usize = 0;
    var rows_done: u32 = 0;
    while (rows_done < src_rows) : (rows_done += 1) {
        var x: u32 = 0;
        while (x < fmt.width) : (x += 1) {
            dest[di + 0] = sampleU8(src_bytes, si + 0 * sample_bytes, fmt.bits_per_sample, fmt.endian);
            dest[di + 1] = sampleU8(src_bytes, si + 1 * sample_bytes, fmt.bits_per_sample, fmt.endian);
            dest[di + 2] = sampleU8(src_bytes, si + 2 * sample_bytes, fmt.bits_per_sample, fmt.endian);
            // Alpha: extra sample if present, else opaque.
            dest[di + 3] = if (fmt.samples_per_pixel >= 4)
                sampleU8(src_bytes, si + 3 * sample_bytes, fmt.bits_per_sample, fmt.endian)
            else
                0xFF;
            si += @as(usize, fmt.samples_per_pixel) * sample_bytes;
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

/// YCbCr → RGBA per BT.601 with full-range (0..255) Y, Cb, Cr —
/// matches the TIFF defaults for YCbCrCoefficients tag (529)
/// = (0.299, 0.587, 0.114) and ReferenceBlackWhite tag (532)
/// = full-range. Subsampling beyond 1:1 (YCbCrSubSampling tag 530)
/// is out of scope for v1; chunky planar with samples_per_pixel = 3
/// only.
///
/// Integer Q16 fixed-point inverse, matching libtiff's
/// TIFFYCbCrToRGBInit byte-exact. Coefficients are
/// `round(c * 65536)`:
///   Cr_r =  round(2 * (1 - LumaRed)            * 65536) =  91881
///   Cb_g = -round(2 * LumaBlue * (1-LumaBlue)/LumaGreen * 65536) = -22554
///   Cr_g = -round(2 * LumaRed  * (1-LumaRed) /LumaGreen * 65536) = -46802
///   Cb_b =  round(2 * (1 - LumaBlue)           * 65536) = 116130
///   bias =  1 << 15 (32768) → round-half-up after >> 16
///   R = Y + (Cr_r*(Cr-128) + bias) >> 16
///   G = Y + (Cb_g*(Cb-128) + Cr_g*(Cr-128) + bias) >> 16
///   B = Y + (Cb_b*(Cb-128) + bias) >> 16
/// then clamp to [0, 255]. The saturated-color round-trip overshoots
/// slightly (e.g. pure red yields R=254, not 255) and the spec
/// expects the decoder to clamp rather than wrap.
fn expandYCbCr(
    src_bytes: []const u8,
    src_rows: u32,
    fmt: PixelFormat,
    dest: []u8,
) errors.Error!void {
    if (fmt.samples_per_pixel < 3) return error.UnsupportedPhotometric;
    const stride: usize = @as(usize, fmt.width) * fmt.samples_per_pixel;
    if (src_bytes.len < stride * src_rows) return error.SourceShortRead;

    const cr_r: i32 = 91881;
    const cb_g: i32 = -22554;
    const cr_g: i32 = -46802;
    const cb_b: i32 = 116130;
    const q16_round: i32 = 1 << 15;

    var di: usize = 0;
    var si: usize = 0;
    var rows_done: u32 = 0;
    while (rows_done < src_rows) : (rows_done += 1) {
        var x: u32 = 0;
        while (x < fmt.width) : (x += 1) {
            const y_i: i32 = src_bytes[si + 0];
            const cb_off: i32 = @as(i32, src_bytes[si + 1]) - 128;
            const cr_off: i32 = @as(i32, src_bytes[si + 2]) - 128;
            const r_delta: i32 = (cr_r * cr_off + q16_round) >> 16;
            const g_delta: i32 = (cb_g * cb_off + cr_g * cr_off + q16_round) >> 16;
            const b_delta: i32 = (cb_b * cb_off + q16_round) >> 16;
            dest[di + 0] = clampToU8I32(y_i + r_delta);
            dest[di + 1] = clampToU8I32(y_i + g_delta);
            dest[di + 2] = clampToU8I32(y_i + b_delta);
            dest[di + 3] = if (fmt.samples_per_pixel >= 4) src_bytes[si + 3] else 0xFF;
            si += fmt.samples_per_pixel;
            di += 4;
        }
    }
}

/// Saturating cast of an i32 result to u8. Used by inverse colour
/// matrices that overshoot at saturated values.
fn clampToU8I32(v: i32) u8 {
    if (v <= 0) return 0;
    if (v >= 255) return 255;
    return @intCast(v);
}

// ---- CIE Lab (integer-only runtime; LUTs precomputed at comptime) ----
//
// The Lab→sRGB pipeline has three nonlinearities that resist a clean
// closed-form fixed-point treatment:
//
//   1. The Lab f^-1 piecewise function (t > 6/29 → t^3; else linear).
//   2. The sRGB gamma encode `pow(linear, 1/2.4)` for linear > 0.0031308.
//   3. The L*-byte → L*-value `*100/255` scaling.
//
// We collapse all three into comptime-generated lookup tables so the
// per-pixel runtime path is pure integer arithmetic. Matrix mults stay
// in Q16 with rounded coefficient constants.
//
// Q24 fixed-point chosen for the intermediate XYZ values: the linear
// sRGB output stays comfortably in i64 range during the matrix mul
// even at saturated colours, and Q24 gives ~7 effective decimal
// digits which exceeds the 8-bit output precision by ~6 orders.

/// Q24 fixed-point unit (1.0 == 16777216).
const lab_q: u32 = 1 << 24;
/// Q24-encoded D50 reference white from TIFF spec for CIELAB:
/// (Xn, Yn, Zn) = (0.96422, 1.00000, 0.82521).
const lab_xn_q24: u32 = @intFromFloat(@round(0.96422 * @as(f64, @floatFromInt(lab_q))));
const lab_yn_q24: u32 = @intFromFloat(@round(1.00000 * @as(f64, @floatFromInt(lab_q))));
const lab_zn_q24: u32 = @intFromFloat(@round(0.82521 * @as(f64, @floatFromInt(lab_q))));

/// LUT: L_byte (0..255) → Y_d50 in Q24, where
/// Y_d50 = Yn * f_inv((L_star + 16) / 116) and
/// L_star = L_byte * 100 / 255.
const lab_y_d50_q24: [256]u32 = blk: {
    var t: [256]u32 = undefined;
    for (0..256) |i| {
        const l_star: f64 = @as(f64, @floatFromInt(i)) * 100.0 / 255.0;
        const fy: f64 = (l_star + 16.0) / 116.0;
        const y: f64 = 1.0 * labFInvF64(fy);
        t[i] = @intFromFloat(@round(y * @as(f64, @floatFromInt(lab_q))));
    }
    break :blk t;
};

/// LUT: L_byte → (L_star + 16) / 116 in Q24, used as the fy seed for
/// the per-pixel a*/b* deltas. Tracked separately from lab_y_d50_q24
/// because fy itself (not f_inv(fy)) is what mixes with a/500 and
/// b/200 before the next f_inv.
const lab_fy_q24: [256]u32 = blk: {
    var t: [256]u32 = undefined;
    for (0..256) |i| {
        const l_star: f64 = @as(f64, @floatFromInt(i)) * 100.0 / 255.0;
        const fy: f64 = (l_star + 16.0) / 116.0;
        t[i] = @intFromFloat(@round(fy * @as(f64, @floatFromInt(lab_q))));
    }
    break :blk t;
};

/// LUT: signed a_byte (i8 reinterpretation; range -128..127) → a/500
/// in Q24. Indexed by `@as(u8, @bitCast(a_i8))` so direct byte indexing
/// works (entries [0..127] cover non-negative; [128..255] cover
/// negative via two's complement).
const lab_a_offset_q24: [256]i32 = blk: {
    var t: [256]i32 = undefined;
    for (0..256) |i| {
        const a_i8: i32 = @as(i8, @bitCast(@as(u8, @intCast(i))));
        const a_star: f64 = @floatFromInt(a_i8);
        const off: f64 = a_star / 500.0;
        t[i] = @intFromFloat(@round(off * @as(f64, @floatFromInt(lab_q))));
    }
    break :blk t;
};

/// LUT: ICCLab (photometric=9) a_byte (unsigned, biased by 128) → a/500
/// in Q24. Matches lab_a_offset_q24 but with a_star = (a_byte - 128)
/// instead of the two's-complement reinterpretation.
const lab_a_offset_icclab_q24: [256]i32 = blk: {
    var t: [256]i32 = undefined;
    for (0..256) |i| {
        const a_star: f64 = @as(f64, @floatFromInt(@as(i32, @intCast(i)))) - 128.0;
        const off: f64 = a_star / 500.0;
        t[i] = @intFromFloat(@round(off * @as(f64, @floatFromInt(lab_q))));
    }
    break :blk t;
};

/// LUT: ICCLab b_byte (unsigned, biased by 128) → -b/200 in Q24.
const lab_b_offset_icclab_q24: [256]i32 = blk: {
    var t: [256]i32 = undefined;
    for (0..256) |i| {
        const b_star: f64 = @as(f64, @floatFromInt(@as(i32, @intCast(i)))) - 128.0;
        const off: f64 = -b_star / 200.0;
        t[i] = @intFromFloat(@round(off * @as(f64, @floatFromInt(lab_q))));
    }
    break :blk t;
};

/// LUT: signed b_byte → b/200 in Q24 (note sign convention: fz = fy - b/200,
/// so we store the NEGATIVE here for an additive update).
const lab_b_offset_q24: [256]i32 = blk: {
    var t: [256]i32 = undefined;
    for (0..256) |i| {
        const b_i8: i32 = @as(i8, @bitCast(@as(u8, @intCast(i))));
        const b_star: f64 = @floatFromInt(b_i8);
        const off: f64 = -b_star / 200.0;
        t[i] = @intFromFloat(@round(off * @as(f64, @floatFromInt(lab_q))));
    }
    break :blk t;
};

/// sRGB gamma encoder LUT: linear-Q12 (0..4096) → gamma-encoded 8-bit.
/// 4096 entries covers linear in [0, 1] in Q12 with rounding precision
/// of 1/4096 ≈ 0.00024 — at least an order of magnitude finer than
/// the 8-bit output bin.
const srgb_gamma_lut: [4097]u8 = blk: {
    @setEvalBranchQuota(10_000_000);
    var t: [4097]u8 = undefined;
    for (0..4097) |i| {
        const linear: f64 = @as(f64, @floatFromInt(i)) / 4096.0;
        const gamma: f64 = if (linear <= 0.0031308)
            12.92 * linear
        else
            1.055 * pow_f64(linear, 1.0 / 2.4) - 0.055;
        const scaled: f64 = gamma * 255.0;
        const clamped: f64 = if (scaled <= 0.0) 0.0 else if (scaled >= 255.0) 255.0 else @round(scaled);
        t[i] = @intFromFloat(clamped);
    }
    break :blk t;
};

/// Comptime-only `pow` shim. Zig's `std.math.pow` at comptime can't
/// always resolve runtime f64 calls in a const-eval block, so we
/// implement a series expansion equivalent of `exp(b * ln(x))`. Only
/// used at comptime for LUT generation; not in the runtime path.
fn pow_f64(base: f64, exp: f64) f64 {
    return std.math.pow(f64, base, exp);
}

/// Comptime-only Lab f^-1 (FP). Used for LUT generation; not in the
/// runtime path.
fn labFInvF64(t: f64) f64 {
    const delta: f64 = 6.0 / 29.0;
    if (t > delta) return t * t * t;
    return (t - 4.0 / 29.0) * 3.0 * delta * delta;
}

/// Q24 → Q16 helper used by the per-pixel f_inv path: rounded shift by 8.
fn q24ToQ16(x: i64) i64 {
    return (x + (1 << 7)) >> 8;
}

/// Runtime integer Lab f^-1: input fy/fx/fz in Q24, output in Q24.
/// Piecewise per TIFF spec: if t > 6/29 → t^3; else 3*(6/29)^2 * (t - 4/29).
/// Computed in Q24 throughout. (6/29 in Q24 = 3471883; (6/29)^2 in Q24 =
/// 718045; (6/29)^3 in Q24 = 148550; 4/29 in Q24 = 2314588;
/// 3*(6/29)^2 in Q24 = 2154136.)
fn labFInvQ24(t: i64) i64 {
    // 6/29 in Q24 (rounded).
    const delta_q24: i64 = comptime @intFromFloat(@round((6.0 / 29.0) * @as(f64, @floatFromInt(lab_q))));
    // 4/29 in Q24 (rounded).
    const t_offset_q24: i64 = comptime @intFromFloat(@round((4.0 / 29.0) * @as(f64, @floatFromInt(lab_q))));
    // 3 * (6/29)^2 in Q24 (rounded).
    const linear_slope_q24: i64 = comptime @intFromFloat(@round(3.0 * (6.0 / 29.0) * (6.0 / 29.0) * @as(f64, @floatFromInt(lab_q))));

    if (t > delta_q24) {
        // t^3 in Q24: (t/Q24)^3 * Q24 = t * t * t / Q24^2, rounded.
        const tsq: i64 = @divTrunc(t * t + (1 << 23), 1 << 24);
        return @divTrunc(tsq * t + (1 << 23), 1 << 24);
    } else {
        const delta_t: i64 = t - t_offset_q24;
        // linear_slope_q24 * delta_t / Q24 with rounding.
        return @divTrunc(linear_slope_q24 * delta_t + (1 << 23), 1 << 24);
    }
}

/// CIELAB → RGBA via integer Q24 fixed-point: Lab→XYZ(D50) →
/// Bradford D50→D65 → XYZ→sRGB linear → sRGB gamma (LUT). 8-bit
/// encoding only at v1 (photometric=8). Future work: photometric=9
/// (ICCLab, full-range u8) and 16-bit Lab.
///
/// TIFF 8-bit CIELAB encoding (per TIFF 6.0 §22):
///   L*: u8 in [0, 255] mapped linearly to L* in [0, 100]
///   a*: u8 reinterpreted as i8 (two's complement) — range [-128, 127]
///   b*: same as a*
///
/// All comptime LUT generation uses f64 (compile-time only — no FP at
/// runtime). The per-pixel runtime path is pure integer arithmetic.
fn expandCieLab(
    src_bytes: []const u8,
    src_rows: u32,
    fmt: PixelFormat,
    dest: []u8,
) errors.Error!void {
    if (fmt.samples_per_pixel < 3) return error.UnsupportedPhotometric;
    if (fmt.bits_per_sample != 8) return error.UnsupportedBitDepth;
    const stride: usize = @as(usize, fmt.width) * fmt.samples_per_pixel;
    if (src_bytes.len < stride * src_rows) return error.SourceShortRead;

    // Bradford D50 → D65 in Q24 (rounded at comptime).
    const bradford_d50_to_d65_q24 = comptime computeBradfordD50ToD65Q24();
    // XYZ D65 → linear sRGB in Q24 (rounded at comptime).
    const xyz_to_srgb_linear_q24 = comptime computeXyzToSrgbLinearQ24();

    var di: usize = 0;
    var si: usize = 0;
    var rows_done: u32 = 0;
    while (rows_done < src_rows) : (rows_done += 1) {
        var x: u32 = 0;
        while (x < fmt.width) : (x += 1) {
            const l_byte: u8 = src_bytes[si + 0];
            const a_byte: u8 = src_bytes[si + 1];
            const b_byte: u8 = src_bytes[si + 2];

            // Lab → XYZ(D50). Y_d50 comes straight from a LUT keyed
            // on L_byte. X and Z need a/b deltas added to fy before
            // the next f_inv.
            const y_d50_q24: i64 = @intCast(lab_y_d50_q24[l_byte]);
            const fy_q24: i64 = @intCast(lab_fy_q24[l_byte]);
            const a_lut = if (fmt.photometric == tags.photometric_icclab)
                &lab_a_offset_icclab_q24
            else
                &lab_a_offset_q24;
            const b_lut = if (fmt.photometric == tags.photometric_icclab)
                &lab_b_offset_icclab_q24
            else
                &lab_b_offset_q24;
            const fx_q24: i64 = fy_q24 + a_lut[a_byte];
            const fz_q24: i64 = fy_q24 + b_lut[b_byte];
            const x_d50_q24: i64 = @divTrunc(@as(i64, lab_xn_q24) * labFInvQ24(fx_q24) + (1 << 23), 1 << 24);
            const z_d50_q24: i64 = @divTrunc(@as(i64, lab_zn_q24) * labFInvQ24(fz_q24) + (1 << 23), 1 << 24);

            // Bradford D50 → D65. Coefficient * Q24 / Q24 with rounding.
            const x_d65_q24: i64 = matrixRowQ24(bradford_d50_to_d65_q24[0], x_d50_q24, y_d50_q24, z_d50_q24);
            const y_d65_q24: i64 = matrixRowQ24(bradford_d50_to_d65_q24[1], x_d50_q24, y_d50_q24, z_d50_q24);
            const z_d65_q24: i64 = matrixRowQ24(bradford_d50_to_d65_q24[2], x_d50_q24, y_d50_q24, z_d50_q24);

            // XYZ → linear sRGB.
            const r_lin_q24: i64 = matrixRowQ24(xyz_to_srgb_linear_q24[0], x_d65_q24, y_d65_q24, z_d65_q24);
            const g_lin_q24: i64 = matrixRowQ24(xyz_to_srgb_linear_q24[1], x_d65_q24, y_d65_q24, z_d65_q24);
            const b_lin_q24: i64 = matrixRowQ24(xyz_to_srgb_linear_q24[2], x_d65_q24, y_d65_q24, z_d65_q24);

            // Gamma LUT — index by Q12 (0..4096), clamping out-of-gamut
            // values. Q24 → Q12 is a rounded shift right by 12.
            dest[di + 0] = srgbGammaLookup(r_lin_q24);
            dest[di + 1] = srgbGammaLookup(g_lin_q24);
            dest[di + 2] = srgbGammaLookup(b_lin_q24);
            dest[di + 3] = if (fmt.samples_per_pixel >= 4) src_bytes[si + 3] else 0xFF;
            si += fmt.samples_per_pixel;
            di += 4;
        }
    }
}

/// row[0]*x + row[1]*y + row[2]*z, all Q24, result Q24 with rounding.
fn matrixRowQ24(row: [3]i64, x_q24: i64, y_q24: i64, z_q24: i64) i64 {
    const sum: i64 = row[0] * x_q24 + row[1] * y_q24 + row[2] * z_q24;
    return @divTrunc(sum + (1 << 23), 1 << 24);
}

fn srgbGammaLookup(linear_q24: i64) u8 {
    // Q24 → Q12: shift right by 12 with round-to-nearest, clamp 0..4096.
    const linear_q12_signed: i64 = @divTrunc(linear_q24 + (1 << 11), 1 << 12);
    if (linear_q12_signed <= 0) return srgb_gamma_lut[0];
    if (linear_q12_signed >= 4096) return srgb_gamma_lut[4096];
    return srgb_gamma_lut[@intCast(linear_q12_signed)];
}

fn computeBradfordD50ToD65Q24() [3][3]i64 {
    const m = [3][3]f64{
        .{ 0.9555766, -0.0230393, 0.0631636 },
        .{ -0.0282895, 1.0099416, 0.0210077 },
        .{ 0.0122982, -0.0204830, 1.3299098 },
    };
    var out: [3][3]i64 = undefined;
    for (0..3) |i| {
        for (0..3) |j| {
            out[i][j] = @intFromFloat(@round(m[i][j] * @as(f64, @floatFromInt(lab_q))));
        }
    }
    return out;
}

fn computeXyzToSrgbLinearQ24() [3][3]i64 {
    const m = [3][3]f64{
        .{ 3.2404542, -1.5371385, -0.4985314 },
        .{ -0.9692660, 1.8760108, 0.0415560 },
        .{ 0.0556434, -0.2040259, 1.0572252 },
    };
    var out: [3][3]i64 = undefined;
    for (0..3) |i| {
        for (0..3) |j| {
            out[i][j] = @intFromFloat(@round(m[i][j] * @as(f64, @floatFromInt(lab_q))));
        }
    }
    return out;
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
    // 32-bit-per-sample is not a supported width for photometric
    // expansion. Float-32 TIFFs decode at the strip level but
    // their photometric expansion is the consumer's concern (e.g.
    // scientific pipelines do their own tone-mapping).
    var dest: [4]u8 = undefined;
    try std.testing.expectError(error.UnsupportedBitDepth, expandRowsToRgba(&.{}, 0, .{
        .photometric = tags.photometric_rgb,
        .bits_per_sample = 32,
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
    // 999 is an unassigned photometric value — tiffz rejects anything
    // not in its known set.
    try std.testing.expectError(error.UnsupportedPhotometric, expandRowsToRgba(&.{}, 0, .{
        .photometric = 999,
        .bits_per_sample = 8,
        .samples_per_pixel = 1,
        .width = 1,
        .colormap = null,
    }, &dest));
}

test "expandRowsToRgba 16-bit RGB big-endian downscales via round-to-nearest" {
    // Per-channel canonical u16 → u8 downscale `(x*255 + 32767)/65535`:
    //   0xFFFF → 255 ; 0x8000 → 128 ; 0x0000 → 0 ;
    //   0x49E8 → 0x4A (not 0x49 — high byte ≥ 0x80 needs the round up)
    //   0xC0C0 → 0xC0
    const src = [_]u8{
        // pixel 0: R=0xFFFF, G=0x8000, B=0x0000 (big-endian bytes)
        0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00,
        // pixel 1: R=0x49E8, G=0xC0C0, B=0xFFFF
        0x49, 0xE8, 0xC0, 0xC0, 0xFF, 0xFF,
    };
    var dest: [8]u8 = undefined;
    try expandRowsToRgba(&src, 1, .{
        .photometric = tags.photometric_rgb,
        .bits_per_sample = 16,
        .samples_per_pixel = 3,
        .width = 2,
        .colormap = null,
        .endian = .big,
    }, &dest);
    try std.testing.expectEqualSlices(u8, &.{
        0xFF, 0x80, 0x00, 0xFF,
        0x4A, 0xC0, 0xFF, 0xFF,
    }, &dest);
}

test "expandRowsToRgba 16-bit RGB little-endian" {
    const src = [_]u8{
        // pixel 0: R=0xFFFF, G=0x8000, B=0x0000 (little-endian bytes)
        0xFF, 0xFF, 0x00, 0x80, 0x00, 0x00,
        // pixel 1: R=0x49E8, G=0xC0C0, B=0xFFFF
        0xE8, 0x49, 0xC0, 0xC0, 0xFF, 0xFF,
    };
    var dest: [8]u8 = undefined;
    try expandRowsToRgba(&src, 1, .{
        .photometric = tags.photometric_rgb,
        .bits_per_sample = 16,
        .samples_per_pixel = 3,
        .width = 2,
        .colormap = null,
        .endian = .little,
    }, &dest);
    try std.testing.expectEqualSlices(u8, &.{
        0xFF, 0x80, 0x00, 0xFF,
        0x4A, 0xC0, 0xFF, 0xFF,
    }, &dest);
}

test "expandRowsToRgba 16-bit MinIsBlack grayscale, two rows" {
    // 2 rows × 2 pixels × u16 big-endian.
    // Row 0: 0x4000, 0x8000 → 64, 128
    // Row 1: 0xC000, 0xFFFF → 192, 255
    // Canonical downscale: 0x4000 → (16384*255+32767)/65535 = 4210687/65535 = 64.25 → 64.
    //                       0x8000 → (32768*255+32767)/65535 = 8388607/65535 = 128.0 → 128.
    //                       0xC000 → (49152*255+32767)/65535 = 12566527/65535 = 191.7 → 191. Hmm.
    // Wait: 49152 * 255 = 12533760. + 32767 = 12566527. /65535 = 191.749 → floor 191.
    // 0xFFFF * 255 + 32767 = 16711425 + 32767 = 16744192. /65535 = 255.5 → floor 255. OK.
    var bytes = [_]u8{ 0x40, 0x00, 0x80, 0x00, 0xC0, 0x00, 0xFF, 0xFF };
    var dest: [16]u8 = undefined;
    try expandRowsToRgba(&bytes, 2, .{
        .photometric = tags.photometric_black_is_zero,
        .bits_per_sample = 16,
        .samples_per_pixel = 1,
        .width = 2,
        .colormap = null,
        .endian = .big,
    }, &dest);
    try std.testing.expectEqualSlices(u8, &.{
        64,  64,  64,  0xFF,
        128, 128, 128, 0xFF,
        191, 191, 191, 0xFF,
        255, 255, 255, 0xFF,
    }, &dest);
}

test "expandRowsToRgba 16-bit CMYK downscales per channel then composites" {
    // CMYK 16-bit, single pixel: C=0xFFFF M=0x0000 Y=0x0000 K=0x0000
    //   downscales to (255, 0, 0, 0) → standard CMYK math →
    //   R = (255-255)*(255-0)/255 = 0, G = 255, B = 255 → cyan.
    const src = [_]u8{
        0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    var dest: [4]u8 = undefined;
    try expandRowsToRgba(&src, 1, .{
        .photometric = tags.photometric_separated_cmyk,
        .bits_per_sample = 16,
        .samples_per_pixel = 4,
        .width = 1,
        .colormap = null,
        .endian = .big,
    }, &dest);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0xFF, 0xFF, 0xFF }, &dest);
}

test "interleavePlanesToChunky 8-bit 2-plane single row" {
    // R-plane: [0xAA, 0xBB]; G-plane: [0xCC, 0xDD].
    // Chunky output (pixel-major, channel-minor): [0xAA, 0xCC, 0xBB, 0xDD].
    const plane_r = [_]u8{ 0xAA, 0xBB };
    const plane_g = [_]u8{ 0xCC, 0xDD };
    const planes = [_][]const u8{ &plane_r, &plane_g };
    var dest: [4]u8 = undefined;
    try interleavePlanesToChunky(&planes, 1, 2, 8, &dest);
    try std.testing.expectEqualSlices(u8, &.{ 0xAA, 0xCC, 0xBB, 0xDD }, &dest);
}

test "interleavePlanesToChunky 16-bit 3-plane single row preserves byte order" {
    // Big-endian-like u16s: 0x1122, 0x3344 on plane 0; 0x5566, 0x7788
    // on plane 1; 0x99AA, 0xBBCC on plane 2.
    // Chunky: pix0(0x1122, 0x5566, 0x99AA), pix1(0x3344, 0x7788, 0xBBCC).
    const plane0 = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    const plane1 = [_]u8{ 0x55, 0x66, 0x77, 0x88 };
    const plane2 = [_]u8{ 0x99, 0xAA, 0xBB, 0xCC };
    const planes = [_][]const u8{ &plane0, &plane1, &plane2 };
    var dest: [12]u8 = undefined;
    try interleavePlanesToChunky(&planes, 1, 2, 16, &dest);
    try std.testing.expectEqualSlices(u8, &.{
        0x11, 0x22, 0x55, 0x66, 0x99, 0xAA,
        0x33, 0x44, 0x77, 0x88, 0xBB, 0xCC,
    }, &dest);
}

test "interleavePlanesToChunky multi-row, 3-channel, 8-bit" {
    // 2 rows × 3 pixels × 3 channels (RGB).
    // Row 0 plane R: [10, 11, 12]; row 0 plane G: [20, 21, 22]; row 0 plane B: [30, 31, 32]
    // Row 1 plane R: [40, 41, 42]; etc.
    const plane_r = [_]u8{ 10, 11, 12, 40, 41, 42 };
    const plane_g = [_]u8{ 20, 21, 22, 50, 51, 52 };
    const plane_b = [_]u8{ 30, 31, 32, 60, 61, 62 };
    const planes = [_][]const u8{ &plane_r, &plane_g, &plane_b };
    var dest: [18]u8 = undefined;
    try interleavePlanesToChunky(&planes, 2, 3, 8, &dest);
    try std.testing.expectEqualSlices(u8, &.{
        10, 20, 30, 11, 21, 31, 12, 22, 32,
        40, 50, 60, 41, 51, 61, 42, 52, 62,
    }, &dest);
}

test "interleavePlanesToChunky rejects unsupported bit depth" {
    const plane = [_]u8{ 0 };
    const planes = [_][]const u8{&plane};
    var dest: [4]u8 = undefined;
    try std.testing.expectError(error.UnsupportedBitDepth, interleavePlanesToChunky(&planes, 1, 1, 32, &dest));
}

test "interleavePlanesToChunky rejects too-small dest" {
    const plane = [_]u8{ 1, 2 };
    const planes = [_][]const u8{&plane};
    var dest: [1]u8 = undefined;
    try std.testing.expectError(error.DestTooSmall, interleavePlanesToChunky(&planes, 1, 2, 8, &dest));
}

test "interleavePlanesToChunky rejects short plane buffer" {
    const plane = [_]u8{1}; // need 2 for width=2 × bps=8
    const planes = [_][]const u8{&plane};
    var dest: [2]u8 = undefined;
    try std.testing.expectError(error.SourceShortRead, interleavePlanesToChunky(&planes, 1, 2, 8, &dest));
}

test "expandRowsToRgba rejects 16-bit palette" {
    var dest: [4]u8 = undefined;
    try std.testing.expectError(error.UnsupportedBitDepth, expandRowsToRgba(&.{}, 0, .{
        .photometric = tags.photometric_palette,
        .bits_per_sample = 16,
        .samples_per_pixel = 1,
        .width = 1,
        .colormap = null,
        .endian = .little,
    }, &dest));
}

test "expandRowsToRgba rejects 16-bit Lab (deferred)" {
    var dest: [4]u8 = undefined;
    try std.testing.expectError(error.UnsupportedBitDepth, expandRowsToRgba(&.{}, 0, .{
        .photometric = tags.photometric_cielab,
        .bits_per_sample = 16,
        .samples_per_pixel = 3,
        .width = 1,
        .colormap = null,
        .endian = .little,
    }, &dest));
}

test "expandRowsToRgba photometric=CMYK (5) maps to RGBA via subtractive composition" {
    // CMYK-to-RGB (no ICC profile):
    //   R = (255 - C) * (255 - K) / 255
    //   G = (255 - M) * (255 - K) / 255
    //   B = (255 - Y) * (255 - K) / 255
    //
    // Test pixels (C, M, Y, K):
    //   (0,0,0,0)         → white  (255,255,255)
    //   (255,0,0,0)       → cyan   (0,255,255)
    //   (0,255,0,0)       → magenta (255,0,255)
    //   (0,0,255,0)       → yellow (255,255,0)
    //   (0,0,0,255)       → black  (0,0,0)
    //   (128,64,32,16)    → ((127*239)/255, (191*239)/255, (223*239)/255)
    //                     ≈ (119, 179, 209)
    const src = [_]u8{
        0,   0,   0,   0,   // white
        255, 0,   0,   0,   // cyan
        0,   255, 0,   0,   // magenta
        0,   0,   255, 0,   // yellow
        0,   0,   0,   255, // black
        128, 64,  32,  16,  // arbitrary
    };
    var dest: [24]u8 = undefined;
    try expandRowsToRgba(&src, 1, .{
        .photometric = tags.photometric_separated_cmyk,
        .bits_per_sample = 8,
        .samples_per_pixel = 4,
        .width = 6,
        .colormap = null,
    }, &dest);
    try std.testing.expectEqualSlices(u8, &.{
        0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0xFF, 0xFF, 0xFF,
        0xFF, 0x00, 0xFF, 0xFF,
        0xFF, 0xFF, 0x00, 0xFF,
        0x00, 0x00, 0x00, 0xFF,
        // (127 * 239 + 127) / 255 = 119; (191 * 239 + 127) / 255 = 179;
        // (223 * 239 + 127) / 255 = 209 — using round-to-nearest division
        119, 179, 209, 0xFF,
    }, &dest);
}

test "expandRowsToRgba photometric=YCbCr (6) BT.601 full-range to RGBA" {
    // BT.601 inverse, full-range (0..255) — the TIFF default per
    // YCbCrCoefficients tag (529) defaults of (0.299, 0.587, 0.114)
    // and ReferenceBlackWhite (532) defaults of (0,255, 0,255, 0,255).
    //
    //   R = Y + 1.402 * (Cr - 128)
    //   G = Y - 0.344136 * (Cb - 128) - 0.714136 * (Cr - 128)
    //   B = Y + 1.772 * (Cb - 128)
    //   then clamp 0..255 (the matrix overshoots at saturated colors).
    //
    // Test pixels (Y, Cb, Cr):
    //   (0, 128, 128)   → (0, 0, 0)        — black
    //   (128, 128, 128) → (128, 128, 128)  — mid-gray
    //   (255, 128, 128) → (255, 255, 255)  — white
    //   (76, 85, 255)   → (254, 0, 0)      — near-pure red
    //                     R = 76 + 1.402 * 127 = 254.054 → 254
    //                     G = 76 + 14.798 - 90.695 = 0.103 → 0
    //                     B = 76 - 76.196 = -0.196 → clamp to 0
    const src = [_]u8{
        0,   128, 128,
        128, 128, 128,
        255, 128, 128,
        76,  85,  255,
    };
    var dest: [16]u8 = undefined;
    try expandRowsToRgba(&src, 1, .{
        .photometric = tags.photometric_ycbcr,
        .bits_per_sample = 8,
        .samples_per_pixel = 3,
        .width = 4,
        .colormap = null,
    }, &dest);
    try std.testing.expectEqualSlices(u8, &.{
        0x00, 0x00, 0x00, 0xFF,
        0x80, 0x80, 0x80, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
        254,  0,    0,    0xFF,
    }, &dest);
}

test "expandRowsToRgba photometric=CIELAB (8) endpoints map to black/white" {
    // TIFF 8-bit CIELAB encoding (photometric = 8):
    //   L*: u8 0..255 maps linearly to L* 0..100
    //   a*, b*: signed bytes via two's complement reinterpretation
    //           (0x00 = 0, 0x7F = +127, 0x80 = -128, 0xFF = -1)
    // Reference white per spec: D50. tiffz Bradford-adapts to D65 then
    // converts XYZ → sRGB linear → sRGB gamma → u8 with clamping.
    //
    // Endpoints round-trip exactly:
    //   (0,   0, 0)  → Lab(0,   0, 0) → black (0, 0, 0)
    //   (255, 0, 0)  → Lab(100, 0, 0) → D50 white = D65 white after
    //                  Bradford = sRGB (255, 255, 255) exactly
    //
    // Intermediate values aren't tested at unit scope because the
    // sRGB gamma curve + matrix multiplication makes hand-derived
    // expected values fragile; a fixture-based oracle test against
    // ImageMagick will pin those when M9 fixtures land.
    const src = [_]u8{
        0,   0, 0,   // L*=0, a*=0, b*=0 → black
        255, 0, 0,   // L*=100, a*=0, b*=0 → white
    };
    var dest: [8]u8 = undefined;
    try expandRowsToRgba(&src, 1, .{
        .photometric = tags.photometric_cielab,
        .bits_per_sample = 8,
        .samples_per_pixel = 3,
        .width = 2,
        .colormap = null,
    }, &dest);
    try std.testing.expectEqualSlices(u8, &.{
        0x00, 0x00, 0x00, 0xFF,
        0xFF, 0xFF, 0xFF, 0xFF,
    }, &dest);
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
