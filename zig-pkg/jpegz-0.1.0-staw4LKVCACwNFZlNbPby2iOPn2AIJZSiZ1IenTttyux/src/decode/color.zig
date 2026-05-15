//! Shared YCbCr→RGB color conversion + chroma upsampling helpers.
//!
//! Both baseline (SOF0) and progressive (SOF2) cleanroom decoders end
//! up with the same shape of output: per-component pixel planes (Y, Cb,
//! Cr at their respective sampling factors) that need to be assembled
//! into interleaved RGB output.
//!
//! Functions here are intentionally **integer-only** (no IEEE754):
//!   - `fancyUpsample` mirrors libjpeg-turbo's IJG fancy upsampling
//!     (jdsample.c h2v2_fancy_upsample, h2v1_fancy_upsample, etc.) —
//!     bilinear-with-rounding for typical 4:2:0/4:2:2 layouts, with
//!     active-frame boundary clamping so MCU-padded chroma never bleeds
//!     into visible pixels.
//!   - `ycbcrRowToRgb` mirrors libjpeg-turbo's jdcolor.c
//!     ycc_rgb_convert: 16-bit SCALEBITS fixed-point with
//!     Cred=91881, Cgreen_cb=-22554, Cgreen_cr=-46802, Cblue=116130,
//!     ONE_HALF=32768. Output is bit-identical to the wrapper.
//!
//! Float arithmetic is avoided per project preference (see
//! `~/.claude/projects/.../memory/feedback_prefer_integer_fixed_point.md`).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{OutOfMemory};

pub inline fn clampSampleI32(v: i32) u8 {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return @intCast(v);
}

/// 12-bit sibling of `clampSampleI32`. Range [0, 4095].
pub inline fn clampSample12I32(v: i32) u16 {
    if (v < 0) return 0;
    if (v > 4095) return 4095;
    return @intCast(v);
}

/// IJG "fancy" chroma upsampling. `src` is `src_w` × `src_h`; output is
/// `out_w` × `out_h`. `active_w` / `active_h` are the in-frame chroma
/// extents (`<= src_w/src_h`); boundary clamping uses these so MCU-pad
/// chroma never bleeds into visible pixels.
pub fn fancyUpsample(
    allocator: Allocator,
    src: []const u8,
    src_w: u32,
    src_h: u32,
    out_w: u32,
    out_h: u32,
    active_w: u32,
    active_h: u32,
    h_ratio: u32,
    v_ratio: u32,
) Error![]u8 {
    const dst = try allocator.alloc(u8, @as(usize, out_w) * @as(usize, out_h));
    errdefer allocator.free(dst);

    const cw: u32 = @max(active_w, 1);
    const ch: u32 = @max(active_h, 1);
    if (h_ratio == 2 and v_ratio == 2) {
        var cy: u32 = 0;
        while (cy < ch) : (cy += 1) {
            const cy_up: u32 = if (cy == 0) 0 else cy - 1;
            const cy_dn: u32 = if (cy + 1 < ch) cy + 1 else cy;
            var cx: u32 = 0;
            while (cx < cw) : (cx += 1) {
                const cx_lf: u32 = if (cx == 0) 0 else cx - 1;
                const cx_rt: u32 = if (cx + 1 < cw) cx + 1 else cx;
                const c: i32 = src[cy * src_w + cx];
                const c_l: i32 = src[cy * src_w + cx_lf];
                const c_r: i32 = src[cy * src_w + cx_rt];
                const c_u: i32 = src[cy_up * src_w + cx];
                const c_ul: i32 = src[cy_up * src_w + cx_lf];
                const c_ur: i32 = src[cy_up * src_w + cx_rt];
                const c_d: i32 = src[cy_dn * src_w + cx];
                const c_dl: i32 = src[cy_dn * src_w + cx_lf];
                const c_dr: i32 = src[cy_dn * src_w + cx_rt];
                const tl: i32 = (9 * c + 3 * c_l + 3 * c_u + c_ul + 8) >> 4;
                const tr: i32 = (9 * c + 3 * c_r + 3 * c_u + c_ur + 8) >> 4;
                const bl: i32 = (9 * c + 3 * c_l + 3 * c_d + c_dl + 8) >> 4;
                const br: i32 = (9 * c + 3 * c_r + 3 * c_d + c_dr + 8) >> 4;
                const ox: u32 = cx * 2;
                const oy: u32 = cy * 2;
                if (oy < out_h and ox < out_w) dst[oy * out_w + ox] = clampSampleI32(tl);
                if (oy < out_h and ox + 1 < out_w) dst[oy * out_w + ox + 1] = clampSampleI32(tr);
                if (oy + 1 < out_h and ox < out_w) dst[(oy + 1) * out_w + ox] = clampSampleI32(bl);
                if (oy + 1 < out_h and ox + 1 < out_w) dst[(oy + 1) * out_w + ox + 1] = clampSampleI32(br);
            }
        }
        return dst;
    }
    if (h_ratio == 2 and v_ratio == 1) {
        var cy: u32 = 0;
        while (cy < ch and cy < out_h) : (cy += 1) {
            var cx: u32 = 0;
            while (cx < cw) : (cx += 1) {
                const cx_lf: u32 = if (cx == 0) 0 else cx - 1;
                const cx_rt: u32 = if (cx + 1 < cw) cx + 1 else cx;
                const c: i32 = src[cy * src_w + cx];
                const c_l: i32 = src[cy * src_w + cx_lf];
                const c_r: i32 = src[cy * src_w + cx_rt];
                const lf: i32 = (3 * c + c_l + 2) >> 2;
                const rt: i32 = (3 * c + c_r + 2) >> 2;
                const ox: u32 = cx * 2;
                if (ox < out_w) dst[cy * out_w + ox] = clampSampleI32(lf);
                if (ox + 1 < out_w) dst[cy * out_w + ox + 1] = clampSampleI32(rt);
            }
        }
        return dst;
    }
    if (h_ratio == 1 and v_ratio == 2) {
        var cy: u32 = 0;
        while (cy < ch) : (cy += 1) {
            const cy_up: u32 = if (cy == 0) 0 else cy - 1;
            const cy_dn: u32 = if (cy + 1 < ch) cy + 1 else cy;
            var cx: u32 = 0;
            while (cx < cw and cx < out_w) : (cx += 1) {
                const c: i32 = src[cy * src_w + cx];
                const c_u: i32 = src[cy_up * src_w + cx];
                const c_d: i32 = src[cy_dn * src_w + cx];
                const up: i32 = (3 * c + c_u + 2) >> 2;
                const dn: i32 = (3 * c + c_d + 2) >> 2;
                const oy: u32 = cy * 2;
                if (oy < out_h) dst[oy * out_w + cx] = clampSampleI32(up);
                if (oy + 1 < out_h) dst[(oy + 1) * out_w + cx] = clampSampleI32(dn);
            }
        }
        return dst;
    }
    // Fallback: nearest-neighbor for 1×1 or unusual ratios.
    var y: u32 = 0;
    while (y < out_h) : (y += 1) {
        const sy: u32 = @min((y * src_h) / out_h, src_h - 1);
        var x: u32 = 0;
        while (x < out_w) : (x += 1) {
            const sx: u32 = @min((x * src_w) / out_w, src_w - 1);
            dst[y * out_w + x] = src[sy * src_w + sx];
        }
    }
    return dst;
}

/// Per-row YCbCr→RGB. `plane_y/cb/cr` are full-resolution (post-upsample)
/// canvas planes of dimension `canvas_w × canvas_h`. Writes `width*3`
/// bytes of interleaved RGB into `pixels` at row `y`.
pub fn ycbcrRowToRgb(
    plane_y: []const u8,
    plane_cb: []const u8,
    plane_cr: []const u8,
    canvas_w: u32,
    width: u32,
    pixels: []u8,
    y: u32,
) void {
    var x: u32 = 0;
    while (x < width) : (x += 1) {
        const off_in: usize = @as(usize, y) * @as(usize, canvas_w) + @as(usize, x);
        const Y: i32 = @intCast(plane_y[off_in]);
        const Cb: i32 = @as(i32, plane_cb[off_in]) - 128;
        const Cr: i32 = @as(i32, plane_cr[off_in]) - 128;
        const r: i32 = Y + ((Cr * 91881 + 32768) >> 16);
        const g: i32 = Y + ((Cb * -22554 + Cr * -46802 + 32768) >> 16);
        const b: i32 = Y + ((Cb * 116130 + 32768) >> 16);
        const out_off: usize = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 3;
        pixels[out_off + 0] = clampSampleI32(r);
        pixels[out_off + 1] = clampSampleI32(g);
        pixels[out_off + 2] = clampSampleI32(b);
    }
}

// ─────── 12-bit RGB siblings (A1 Part B) ─────────────────────────
//
// Same algorithm topology as the 8-bit functions above; only:
//   - input/output element type is u16,
//   - chroma bias is 2048 (instead of 128) — the 12-bit signed center,
//   - clamp is [0, 4095].
// FIX_* constants and SCALEBITS (16) are unchanged because they encode
// ratios (Cred / 2^16 = 1.40200). i32 accumulators still suffice:
// worst-case |Cb'| × 116130 ≈ 2^28, well below 2^31. The 1/2-LSB
// rounding offset shifts from 32768 unchanged.

/// 12-bit IJG fancy chroma upsampler. Mirrors `fancyUpsample` exactly
/// — same weights, same boundary clamps — but operates on `u16` planes
/// in [0, 4095]. Used when 4:2:0 / 4:2:2 / 4:4:0 chroma needs to be
/// brought up to canvas resolution before color conversion.
pub fn fancyUpsample12(
    allocator: Allocator,
    src: []const u16,
    src_w: u32,
    src_h: u32,
    out_w: u32,
    out_h: u32,
    active_w: u32,
    active_h: u32,
    h_ratio: u32,
    v_ratio: u32,
) Error![]u16 {
    const dst = try allocator.alloc(u16, @as(usize, out_w) * @as(usize, out_h));
    errdefer allocator.free(dst);

    const cw: u32 = @max(active_w, 1);
    const ch: u32 = @max(active_h, 1);
    // libjpeg-turbo `h2v2_fancy_upsample` (jdsample.c): the 2×2 outputs
    // per chroma cell use asymmetric rounding +8 (left) / +7 (right) to
    // break ties in opposite directions across the pair. Boundary
    // columns: at cx==0 and cx==cw-1, the missing-neighbor side
    // replicates the cell value (lastcolsum == thiscolsum), which our
    // cx_lf == cx / cx_rt == cx clamp already produces.
    if (h_ratio == 2 and v_ratio == 2) {
        var cy: u32 = 0;
        while (cy < ch) : (cy += 1) {
            const cy_up: u32 = if (cy == 0) 0 else cy - 1;
            const cy_dn: u32 = if (cy + 1 < ch) cy + 1 else cy;
            var cx: u32 = 0;
            while (cx < cw) : (cx += 1) {
                const cx_lf: u32 = if (cx == 0) 0 else cx - 1;
                const cx_rt: u32 = if (cx + 1 < cw) cx + 1 else cx;
                const c: i32 = src[cy * src_w + cx];
                const c_l: i32 = src[cy * src_w + cx_lf];
                const c_r: i32 = src[cy * src_w + cx_rt];
                const c_u: i32 = src[cy_up * src_w + cx];
                const c_ul: i32 = src[cy_up * src_w + cx_lf];
                const c_ur: i32 = src[cy_up * src_w + cx_rt];
                const c_d: i32 = src[cy_dn * src_w + cx];
                const c_dl: i32 = src[cy_dn * src_w + cx_lf];
                const c_dr: i32 = src[cy_dn * src_w + cx_rt];
                const tl: i32 = (9 * c + 3 * c_l + 3 * c_u + c_ul + 8) >> 4;
                const tr: i32 = (9 * c + 3 * c_r + 3 * c_u + c_ur + 7) >> 4;
                const bl: i32 = (9 * c + 3 * c_l + 3 * c_d + c_dl + 8) >> 4;
                const br: i32 = (9 * c + 3 * c_r + 3 * c_d + c_dr + 7) >> 4;
                const ox: u32 = cx * 2;
                const oy: u32 = cy * 2;
                if (oy < out_h and ox < out_w) dst[oy * out_w + ox] = clampSample12I32(tl);
                if (oy < out_h and ox + 1 < out_w) dst[oy * out_w + ox + 1] = clampSample12I32(tr);
                if (oy + 1 < out_h and ox < out_w) dst[(oy + 1) * out_w + ox] = clampSample12I32(bl);
                if (oy + 1 < out_h and ox + 1 < out_w) dst[(oy + 1) * out_w + ox + 1] = clampSample12I32(br);
            }
        }
        return dst;
    }
    // libjpeg `h2v1_fancy_upsample`: leftmost column outputs the source
    // value verbatim; rightmost column likewise. Middle uses
    // (3*c + lastcol + 1) >> 2 / (3*c + nextcol + 2) >> 2.
    if (h_ratio == 2 and v_ratio == 1) {
        var cy: u32 = 0;
        while (cy < ch and cy < out_h) : (cy += 1) {
            var cx: u32 = 0;
            while (cx < cw) : (cx += 1) {
                const c: i32 = src[cy * src_w + cx];
                const ox: u32 = cx * 2;
                if (cx == 0) {
                    // First column — left output is the chroma value itself;
                    // right output uses the column-1 case formula with +2.
                    const c_r: i32 = if (cx + 1 < cw) @as(i32, src[cy * src_w + cx + 1]) else c;
                    const rt: i32 = (3 * c + c_r + 2) >> 2;
                    if (ox < out_w) dst[cy * out_w + ox] = clampSample12I32(c);
                    if (ox + 1 < out_w) dst[cy * out_w + ox + 1] = clampSample12I32(rt);
                } else if (cx == cw - 1) {
                    // Last column — left output uses (3*c + prev + 1) >> 2;
                    // right output is the chroma value itself.
                    const c_l: i32 = src[cy * src_w + cx - 1];
                    const lf: i32 = (3 * c + c_l + 1) >> 2;
                    if (ox < out_w) dst[cy * out_w + ox] = clampSample12I32(lf);
                    if (ox + 1 < out_w) dst[cy * out_w + ox + 1] = clampSample12I32(c);
                } else {
                    const c_l: i32 = src[cy * src_w + cx - 1];
                    const c_r: i32 = src[cy * src_w + cx + 1];
                    const lf: i32 = (3 * c + c_l + 1) >> 2;
                    const rt: i32 = (3 * c + c_r + 2) >> 2;
                    if (ox < out_w) dst[cy * out_w + ox] = clampSample12I32(lf);
                    if (ox + 1 < out_w) dst[cy * out_w + ox + 1] = clampSample12I32(rt);
                }
            }
        }
        return dst;
    }
    // libjpeg `h1v2_fancy_upsample`: per 2×1 output cell, top output
    // uses bias=1, bottom output uses bias=2 — the V-axis analogue of
    // H2V1's asymmetric rounding.
    if (h_ratio == 1 and v_ratio == 2) {
        var cy: u32 = 0;
        while (cy < ch) : (cy += 1) {
            const cy_up: u32 = if (cy == 0) 0 else cy - 1;
            const cy_dn: u32 = if (cy + 1 < ch) cy + 1 else cy;
            var cx: u32 = 0;
            while (cx < cw and cx < out_w) : (cx += 1) {
                const c: i32 = src[cy * src_w + cx];
                const c_u: i32 = src[cy_up * src_w + cx];
                const c_d: i32 = src[cy_dn * src_w + cx];
                const up: i32 = (3 * c + c_u + 1) >> 2;
                const dn: i32 = (3 * c + c_d + 2) >> 2;
                const oy: u32 = cy * 2;
                if (oy < out_h) dst[oy * out_w + cx] = clampSample12I32(up);
                if (oy + 1 < out_h) dst[(oy + 1) * out_w + cx] = clampSample12I32(dn);
            }
        }
        return dst;
    }
    // Nearest-neighbor fallback for 1×1 and unusual ratios.
    var y: u32 = 0;
    while (y < out_h) : (y += 1) {
        const sy: u32 = @min((y * src_h) / out_h, src_h - 1);
        var x: u32 = 0;
        while (x < out_w) : (x += 1) {
            const sx: u32 = @min((x * src_w) / out_w, src_w - 1);
            dst[y * out_w + x] = src[sy * src_w + sx];
        }
    }
    return dst;
}

/// 12-bit sibling of `ycbcrRowToRgb`. Inputs are `u16` Y/Cb/Cr planes
/// in [0, 4095] with chroma centered at 2048. Writes 3 × `width` u16
/// samples of interleaved RGB at row `y` into `pixels` (which is the
/// `u16` host-endian view of the final byte buffer).
pub fn ycbcrRowToRgb12(
    plane_y: []const u16,
    plane_cb: []const u16,
    plane_cr: []const u16,
    canvas_w: u32,
    width: u32,
    pixels: []align(1) u16,
    y: u32,
) void {
    var x: u32 = 0;
    while (x < width) : (x += 1) {
        const off_in: usize = @as(usize, y) * @as(usize, canvas_w) + @as(usize, x);
        const Y: i32 = @intCast(plane_y[off_in]);
        const Cb: i32 = @as(i32, plane_cb[off_in]) - 2048;
        const Cr: i32 = @as(i32, plane_cr[off_in]) - 2048;
        const r: i32 = Y + ((Cr * 91881 + 32768) >> 16);
        const g: i32 = Y + ((Cb * -22554 + Cr * -46802 + 32768) >> 16);
        const b: i32 = Y + ((Cb * 116130 + 32768) >> 16);
        const out_off: usize = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 3;
        pixels[out_off + 0] = clampSample12I32(r);
        pixels[out_off + 1] = clampSample12I32(g);
        pixels[out_off + 2] = clampSample12I32(b);
    }
}

// ── Inline unit tests ───────────────────────────────────────────

test "clampSample12I32 boundaries" {
    try std.testing.expectEqual(@as(u16, 0), clampSample12I32(-1));
    try std.testing.expectEqual(@as(u16, 0), clampSample12I32(0));
    try std.testing.expectEqual(@as(u16, 1234), clampSample12I32(1234));
    try std.testing.expectEqual(@as(u16, 4095), clampSample12I32(4095));
    try std.testing.expectEqual(@as(u16, 4095), clampSample12I32(99999));
}

test "ycbcrRowToRgb12 neutral chroma → R=G=B=Y at every Y" {
    // With Cb=Cr=2048 (chroma "zero"), the conversion collapses to
    // R=G=B=Y. Test at Y=0, mid, max.
    const allocator = std.testing.allocator;
    const w: u32 = 4;
    const plane_y = try allocator.alloc(u16, w);
    defer allocator.free(plane_y);
    const plane_cb = try allocator.alloc(u16, w);
    defer allocator.free(plane_cb);
    const plane_cr = try allocator.alloc(u16, w);
    defer allocator.free(plane_cr);
    for (plane_cb) |*v| v.* = 2048;
    for (plane_cr) |*v| v.* = 2048;
    plane_y[0] = 0;
    plane_y[1] = 1000;
    plane_y[2] = 2048;
    plane_y[3] = 4095;

    const pixels = try allocator.alloc(u8, w * 3 * 2);
    defer allocator.free(pixels);
    const pixels_u16: []align(1) u16 = std.mem.bytesAsSlice(u16, pixels);
    ycbcrRowToRgb12(plane_y, plane_cb, plane_cr, w, w, pixels_u16, 0);
    for (0..w) |i| {
        try std.testing.expectEqual(plane_y[i], pixels_u16[i * 3 + 0]);
        try std.testing.expectEqual(plane_y[i], pixels_u16[i * 3 + 1]);
        try std.testing.expectEqual(plane_y[i], pixels_u16[i * 3 + 2]);
    }
}

test "fancyUpsample12 1×1 passthrough preserves u16 values" {
    const allocator = std.testing.allocator;
    const w: u32 = 4;
    const h: u32 = 4;
    var src: [16]u16 = .{ 0, 100, 1000, 4095, 50, 200, 2000, 4000, 75, 300, 3000, 3500, 25, 500, 2500, 1500 };
    const dst = try fancyUpsample12(allocator, &src, w, h, w, h, w, h, 1, 1);
    defer allocator.free(dst);
    for (src, dst) |s, d| try std.testing.expectEqual(s, d);
}
