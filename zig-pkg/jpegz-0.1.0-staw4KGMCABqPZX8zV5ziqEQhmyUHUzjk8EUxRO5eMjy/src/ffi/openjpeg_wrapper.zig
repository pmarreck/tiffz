//! Phase 1 wrapper around openjpeg (BSD-2). Implements
//! `jpegz.jpeg2000.decode` for JP2 (file format) and J2K (raw
//! codestream) inputs. Phase 2 retires this with a cleanroom Zig
//! wavelet/EBCOT implementation.
//!
//! openjpeg's API is more involved than libjpeg's:
//!   1. Memory input requires a custom stream — no portable
//!      "from-buffer" helper in stock 2.5. We provide read/skip/seek
//!      callbacks over a `MemSource` struct.
//!   2. `opj_image_t.comps[i].data` is `OPJ_INT32*` (sign-extended
//!      32-bit per sample, even for 8-bit images). We pack it down to
//!      `[]u8` for the public Image type.
//!   3. Auto-detect JP2 box vs raw J2K codestream via magic bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../core/errors.zig");
const types = @import("../jpegz.zig");

const c = @cImport({
    @cInclude("openjpeg.h");
});

/// Magic-byte detect: JP2 box (".. .. .. 0C jP  ") vs raw J2K
/// codestream (FF 4F FF 51).
fn detectCodec(data: []const u8) ?c.OPJ_CODEC_FORMAT {
    if (data.len >= 12 and
        data[0] == 0x00 and data[1] == 0x00 and data[2] == 0x00 and data[3] == 0x0C and
        data[4] == 'j' and data[5] == 'P' and data[6] == ' ' and data[7] == ' ' and
        data[8] == 0x0D and data[9] == 0x0A and data[10] == 0x87 and data[11] == 0x0A)
    {
        return c.OPJ_CODEC_JP2;
    }
    if (data.len >= 4 and data[0] == 0xFF and data[1] == 0x4F and data[2] == 0xFF and data[3] == 0x51) {
        return c.OPJ_CODEC_J2K;
    }
    return null;
}

/// Memory-stream context passed to openjpeg via `user_data`. Contents
/// borrowed from caller; lifetime extends for the duration of the
/// decode call.
const MemSource = struct {
    data: []const u8,
    pos: usize,
};

fn memRead(buf: ?*anyopaque, num: c.OPJ_SIZE_T, user: ?*anyopaque) callconv(.c) c.OPJ_SIZE_T {
    const s: *MemSource = @ptrCast(@alignCast(user.?));
    if (s.pos >= s.data.len) return @bitCast(@as(c.OPJ_OFF_T, -1)); // EOF
    var bytes: usize = num;
    if (s.pos + bytes > s.data.len) bytes = s.data.len - s.pos;
    @memcpy(@as([*]u8, @ptrCast(buf.?))[0..bytes], s.data[s.pos .. s.pos + bytes]);
    s.pos += bytes;
    return bytes;
}

fn memSkip(n: c.OPJ_OFF_T, user: ?*anyopaque) callconv(.c) c.OPJ_OFF_T {
    const s: *MemSource = @ptrCast(@alignCast(user.?));
    if (n < 0) return -1;
    var to_skip: usize = @intCast(n);
    if (s.pos + to_skip > s.data.len) to_skip = s.data.len - s.pos;
    s.pos += to_skip;
    return @intCast(to_skip);
}

fn memSeek(n: c.OPJ_OFF_T, user: ?*anyopaque) callconv(.c) c.OPJ_BOOL {
    const s: *MemSource = @ptrCast(@alignCast(user.?));
    if (n < 0) return 0;
    const pos: usize = @intCast(n);
    if (pos > s.data.len) return 0;
    s.pos = pos;
    return 1;
}

fn errorCallback(_: [*c]const u8, _: ?*anyopaque) callconv(.c) void {}
fn warningCallback(_: [*c]const u8, _: ?*anyopaque) callconv(.c) void {}
fn infoCallback(_: [*c]const u8, _: ?*anyopaque) callconv(.c) void {}

pub fn decode(allocator: Allocator, data: []const u8) errors.DecodeError!types.Image {
    if (data.len < 4) return error.TruncatedStream;

    const codec_fmt = detectCodec(data) orelse return error.InvalidJp2Codestream;

    var mem = MemSource{ .data = data, .pos = 0 };

    // Build memory stream. Direction: input.
    const stream = c.opj_stream_create(@as(c.OPJ_SIZE_T, 4096), 1) orelse
        return error.OutOfMemory;
    defer c.opj_stream_destroy(stream);
    c.opj_stream_set_user_data(stream, &mem, null);
    c.opj_stream_set_user_data_length(stream, @intCast(data.len));
    c.opj_stream_set_read_function(stream, &memRead);
    c.opj_stream_set_skip_function(stream, &memSkip);
    c.opj_stream_set_seek_function(stream, &memSeek);

    const codec = c.opj_create_decompress(codec_fmt) orelse
        return error.BackendError;
    defer c.opj_destroy_codec(codec);

    // Suppress all output (test-clean stderr).
    _ = c.opj_set_error_handler(codec, &errorCallback, null);
    _ = c.opj_set_warning_handler(codec, &warningCallback, null);
    _ = c.opj_set_info_handler(codec, &infoCallback, null);

    var params: c.opj_dparameters_t = undefined;
    c.opj_set_default_decoder_parameters(&params);
    if (c.opj_setup_decoder(codec, &params) == 0) return error.BackendError;

    var image_ptr: ?*c.opj_image_t = null;
    if (c.opj_read_header(stream, codec, &image_ptr) == 0)
        return error.InvalidJp2Codestream;
    if (image_ptr == null) return error.InvalidJp2Codestream;
    defer c.opj_image_destroy(image_ptr);

    const image = image_ptr.?;

    if (c.opj_decode(codec, stream, image) == 0) return error.BackendError;
    if (c.opj_end_decompress(codec, stream) == 0) return error.BackendError;

    // Sanity-check the components.
    const num_comps: u8 = @intCast(image.numcomps);
    if (num_comps == 0 or num_comps > 4) return error.BackendError;

    // Image dimensions are emitted at the highest-resolution component's
    // natural resolution (matches what opj_decompress writes). Each JP2
    // component samples at its own dx/dy in the reference grid; we emit
    // at the resolution corresponding to the *finest* component (min dx
    // and min dy across all comps). Coarser components get nearest-
    // neighbor upsampled to that resolution.
    //
    // Worked examples:
    //   - All comps dx=dy=1 (no subsampling): width = canvas extent.
    //   - True 4:2:0 (Y=1×1, Cb/Cr=2×2): min_dx=min_dy=1, width = canvas.
    //   - Isotropic dx=dy=2 (IM convention): min_dx=2, width = canvas/2.
    //
    // Sample lookup: image pixel (x, y) maps to canvas position
    // (x * min_dx, y * min_dy); component i samples that canvas position
    // at (cx, cy) = (x * min_dx / comp.dx, y * min_dy / comp.dy).
    if (image.x1 <= image.x0 or image.y1 <= image.y0) return error.BackendError;
    var min_dx: u32 = std.math.maxInt(u32);
    var min_dy: u32 = std.math.maxInt(u32);
    {
        var ci: usize = 0;
        while (ci < num_comps) : (ci += 1) {
            const dx: u32 = @intCast(image.comps[ci].dx);
            const dy: u32 = @intCast(image.comps[ci].dy);
            if (dx == 0 or dy == 0) return error.BackendError;
            if (dx < min_dx) min_dx = dx;
            if (dy < min_dy) min_dy = dy;
        }
    }
    const canvas_w: u32 = @intCast(image.x1 - image.x0);
    const canvas_h: u32 = @intCast(image.y1 - image.y0);
    // Ceiling divide canvas extent by min_dx for the emit dimension.
    const width: u32 = (canvas_w + min_dx - 1) / min_dx;
    const height: u32 = (canvas_h + min_dy - 1) / min_dy;
    const prec: u8 = @intCast(image.comps[0].prec);

    // Precision must match across components (JPEG 2000 allows
    // per-component precision but we don't expose that in v1).
    var i: usize = 1;
    while (i < num_comps) : (i += 1) {
        if (image.comps[i].prec != prec) return error.BackendError;
    }

    // Map output layout. JP2's enumerated colorspace lives in `image.color_space`:
    //   OPJ_CLRSPC_GRAY (1), OPJ_CLRSPC_SRGB (2), OPJ_CLRSPC_SYCC (3),
    //   OPJ_CLRSPC_EYCC, OPJ_CLRSPC_CMYK
    const layout: types.PixelLayout = switch (num_comps) {
        1 => .grayscale,
        3 => .rgb,
        4 => .cmyk,
        else => unreachable,
    };
    const source_cs: types.ColorSpace = switch (image.color_space) {
        c.OPJ_CLRSPC_GRAY => .greyscale_jp2,
        c.OPJ_CLRSPC_SRGB => .srgb,
        else => if (num_comps == 1) .greyscale_jp2 else .srgb,
    };

    // Allocate destination buffer at canvas resolution.
    const bytes_per_sample: usize = if (prec > 8) 2 else 1;
    const pixel_count: usize = @as(usize, width) * @as(usize, height);
    const buf_len = pixel_count * @as(usize, num_comps) * bytes_per_sample;
    const pixels = allocator.alloc(u8, buf_len) catch return error.OutOfMemory;
    errdefer allocator.free(pixels);

    // Per-component sample lookup: nearest-neighbor map from canvas
    // (x, y) to component (cx, cy) using floor(x / dx), floor(y / dy).
    //
    // Common cases:
    //   - dx=dy=1 → identity (no subsampling); canvas pixel == component sample.
    //   - dx=dy=2 → 4:2:0; each component sample covers a 2×2 canvas block.
    //   - dx=2,dy=1 → 4:2:2; component sample covers a 2×1 canvas block.
    // The compute is cheap (integer division per pixel-component);
    // proper (cosited / midpoint) chroma upsampling is a future
    // refinement when image-quality consumers need it.
    if (prec <= 8) {
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const pixel_idx: usize = @as(usize, y) * @as(usize, width) + @as(usize, x);
                var ci: usize = 0;
                while (ci < num_comps) : (ci += 1) {
                    const comp = &image.comps[ci];
                    const cx: u32 = (x * min_dx) / @as(u32, @intCast(comp.dx));
                    const cy: u32 = (y * min_dy) / @as(u32, @intCast(comp.dy));
                    const clamped_cx: u32 = if (cx >= comp.w) comp.w - 1 else cx;
                    const clamped_cy: u32 = if (cy >= comp.h) comp.h - 1 else cy;
                    const sample_idx: usize = @as(usize, clamped_cy) *
                        @as(usize, @intCast(comp.w)) + @as(usize, clamped_cx);
                    const v = comp.data[sample_idx];
                    const clamped: u8 = if (v < 0) 0 else if (v > 255) 255 else @intCast(v);
                    pixels[pixel_idx * num_comps + ci] = clamped;
                }
            }
        }
    } else {
        // 9-16 bit: emit as host-endian u16 (matches design.md §3.1).
        const max_val: i32 = (@as(i32, 1) << @intCast(prec)) - 1;
        const out16 = std.mem.bytesAsSlice(u16, pixels);
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const pixel_idx: usize = @as(usize, y) * @as(usize, width) + @as(usize, x);
                var ci: usize = 0;
                while (ci < num_comps) : (ci += 1) {
                    const comp = &image.comps[ci];
                    const cx: u32 = (x * min_dx) / @as(u32, @intCast(comp.dx));
                    const cy: u32 = (y * min_dy) / @as(u32, @intCast(comp.dy));
                    const clamped_cx: u32 = if (cx >= comp.w) comp.w - 1 else cx;
                    const clamped_cy: u32 = if (cy >= comp.h) comp.h - 1 else cy;
                    const sample_idx: usize = @as(usize, clamped_cy) *
                        @as(usize, @intCast(comp.w)) + @as(usize, clamped_cx);
                    const v = comp.data[sample_idx];
                    const clamped: u16 = blk: {
                        if (v < 0) break :blk 0;
                        if (v > max_val) break :blk @intCast(max_val);
                        break :blk @intCast(v);
                    };
                    out16[pixel_idx * num_comps + ci] = clamped;
                }
            }
        }
    }

    return types.Image{
        .pixels = pixels,
        .width = width,
        .height = height,
        .channels = num_comps,
        .bits_per_sample = prec,
        .source_color_space = source_cs,
        .layout = layout,
    };
}
