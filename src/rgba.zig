//! Decode one IFD into packed 8-bit RGBA. CLI dump and other I/O
//! adapters use this so photometric expansion stays in the Zig core.

const std = @import("std");
const Allocator = std.mem.Allocator;

const parser = @import("tiffz-parser");
const errors = parser.errors;
const tags = parser.tags;
const Ifd = parser.ifd.Ifd;
const decoder_mod = @import("decoder.zig");
const Decoder = decoder_mod.Decoder;
const Workspace = @import("workspace.zig").Workspace;
const photometrics = @import("photometrics.zig");

pub const RgbaImage = struct {
    pixels: []u8,
    width: u32,
    height: u32,
};

fn scalarU16(dir: *const Ifd, tag: u16, endian: parser.header.Endian) ?u16 {
    const e = dir.get(tag) orelse return null;
    if (e.count != 1) return null;
    return switch (e.field_type) {
        .short => parser.header.readU16(e.raw_value_or_offset[0..2], endian),
        .long => @intCast(parser.header.readU32(&e.raw_value_or_offset, endian)),
        else => null,
    };
}

fn scalarU32(dir: *const Ifd, tag: u16, endian: parser.header.Endian) ?u32 {
    const e = dir.get(tag) orelse return null;
    if (e.count != 1) return null;
    return switch (e.field_type) {
        .short => @intCast(parser.header.readU16(e.raw_value_or_offset[0..2], endian)),
        .long => parser.header.readU32(&e.raw_value_or_offset, endian),
        else => null,
    };
}

/// Decode IFD `ifd_index` to 8-bit RGBA (width × height × 4). Caller frees
/// `pixels` with the same allocator.
pub fn decodeIfdToRgba(
    allocator: Allocator,
    dec: *Decoder,
    workspace: *Workspace,
    ifd_index: usize,
) errors.Error!RgbaImage {
    const dir = try dec.ifd(ifd_index);
    const width = scalarU32(dir, tags.image_width, dec.endian) orelse return error.Malformed;
    const height = scalarU32(dir, tags.image_length, dec.endian) orelse return error.Malformed;
    const photometric = scalarU16(dir, tags.photometric, dec.endian) orelse return error.Malformed;
    const samples_per_pixel = scalarU16(dir, tags.samples_per_pixel, dec.endian) orelse 1;
    const rps_raw = scalarU32(dir, tags.rows_per_strip, dec.endian) orelse height;
    const rows_per_strip: u32 = if (rps_raw > height) height else rps_raw;

    var bits_per_sample: u16 = 8;
    if (dir.get(tags.bits_per_sample)) |bps_entry| {
        var buf: [16]u8 = undefined;
        const need: usize = @as(usize, bps_entry.field_type.elementBytes()) * @as(usize, bps_entry.count);
        if (need > buf.len) return error.Malformed;
        try dir.readEntryValueCached(tags.bits_per_sample, dec.endian, dec.source, buf[0..need]);
        bits_per_sample = parser.header.readU16(buf[0..2], dec.endian);
    }

    var cmap_buf: ?[]u16 = null;
    defer if (cmap_buf) |c| allocator.free(c);
    if (photometric == tags.photometric_palette) {
        const cmap_entry = dir.get(tags.colormap) orelse return error.Malformed;
        const palette_size: usize = @as(usize, 1) << @intCast(bits_per_sample);
        const expected_count: u32 = @intCast(3 * palette_size);
        if (cmap_entry.count != expected_count) return error.Malformed;
        const need_bytes: usize = @as(usize, expected_count) * 2;
        const raw = allocator.alloc(u8, need_bytes) catch return error.OutOfMemory;
        defer allocator.free(raw);
        try dir.readEntryValueCached(tags.colormap, dec.endian, dec.source, raw);
        const cmap16 = allocator.alloc(u16, expected_count) catch return error.OutOfMemory;
        for (cmap16, 0..) |*v, i| {
            v.* = parser.header.readU16(raw[i * 2 ..][0..2], dec.endian);
        }
        cmap_buf = cmap16;
    }

    const compression = scalarU16(dir, tags.compression, dec.endian) orelse tags.compression_none;
    const effective_photometric: u16 = if (compression == tags.compression_jpeg and photometric == tags.photometric_ycbcr)
        tags.photometric_rgb
    else
        photometric;

    const fmt: photometrics.PixelFormat = .{
        .photometric = effective_photometric,
        .bits_per_sample = bits_per_sample,
        .samples_per_pixel = samples_per_pixel,
        .width = width,
        .colormap = cmap_buf,
        .endian = dec.endian,
    };

    const rgba_total: usize = @as(usize, width) * @as(usize, height) * 4;
    const rgba = allocator.alloc(u8, rgba_total) catch return error.OutOfMemory;
    errdefer allocator.free(rgba);

    const is_tiled = dir.get(tags.tile_offsets) != null;
    if (is_tiled) {
        try decodeTiled(allocator, dec, ifd_index, fmt, rgba, workspace, width, height, samples_per_pixel, bits_per_sample);
    } else {
        try decodeStripped(allocator, dec, ifd_index, fmt, rgba, workspace, width, height, samples_per_pixel, bits_per_sample, rows_per_strip);
    }

    return .{ .pixels = rgba, .width = width, .height = height };
}

fn decodeStripped(
    allocator: Allocator,
    dec: *Decoder,
    ifd_index: usize,
    fmt: photometrics.PixelFormat,
    rgba: []u8,
    ws: *Workspace,
    width: u32,
    height: u32,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    rows_per_strip: u32,
) errors.Error!void {
    const dir = try dec.ifd(ifd_index);
    const planar = scalarU16(dir, tags.planar_configuration, dec.endian) orelse tags.planar_chunky;
    if (planar == tags.planar_separate) {
        return decodeStrippedSeparate(allocator, dec, ifd_index, fmt, rgba, ws, width, height, samples_per_pixel, bits_per_sample, rows_per_strip);
    }

    const row_bits: usize = @as(usize, width) * @as(usize, samples_per_pixel) * @as(usize, bits_per_sample);
    const row_bytes: usize = (row_bits + 7) / 8;
    const strip_max: usize = row_bytes * rows_per_strip;
    const strip_buf = allocator.alloc(u8, strip_max) catch return error.OutOfMemory;
    defer allocator.free(strip_buf);

    const sbc_entry = dir.get(tags.strip_byte_counts) orelse return error.Malformed;
    var rgba_offset: usize = 0;
    var strip_index: u32 = 0;
    var rows_done: u32 = 0;
    while (strip_index < sbc_entry.count) : (strip_index += 1) {
        const n = try dec.decodeStrip(ifd_index, strip_index, strip_buf, ws);
        const remaining = height - rows_done;
        const this_strip_rows: u32 = @min(rows_per_strip, remaining);
        try photometrics.expandRowsToRgba(strip_buf[0..n], this_strip_rows, fmt, rgba[rgba_offset..]);
        rgba_offset += @as(usize, this_strip_rows) * width * 4;
        rows_done += this_strip_rows;
    }
}

fn decodeStrippedSeparate(
    allocator: Allocator,
    dec: *Decoder,
    ifd_index: usize,
    fmt: photometrics.PixelFormat,
    rgba: []u8,
    ws: *Workspace,
    width: u32,
    height: u32,
    samples_per_pixel: u16,
    bits_per_sample: u16,
    rows_per_strip: u32,
) errors.Error!void {
    const sample_bytes: usize = bits_per_sample / 8;
    if (bits_per_sample != 8 and bits_per_sample != 16) return error.UnsupportedBitDepth;

    const strips_per_plane: u32 = (height + rows_per_strip - 1) / rows_per_strip;
    const plane_strip_bytes: usize = @as(usize, width) * @as(usize, rows_per_strip) * sample_bytes;
    const plane_bufs = allocator.alloc([]u8, samples_per_pixel) catch return error.OutOfMemory;
    defer allocator.free(plane_bufs);
    for (plane_bufs) |*pb| {
        pb.* = allocator.alloc(u8, plane_strip_bytes) catch return error.OutOfMemory;
    }
    defer for (plane_bufs) |pb| allocator.free(pb);

    const chunky_strip_bytes: usize = plane_strip_bytes * samples_per_pixel;
    const chunky_buf = allocator.alloc(u8, chunky_strip_bytes) catch return error.OutOfMemory;
    defer allocator.free(chunky_buf);

    const plane_views_storage = allocator.alloc([]const u8, samples_per_pixel) catch return error.OutOfMemory;
    defer allocator.free(plane_views_storage);

    var rgba_offset: usize = 0;
    var rows_done: u32 = 0;
    var band: u32 = 0;
    while (band < strips_per_plane) : (band += 1) {
        const this_band_rows: u32 = @min(rows_per_strip, height - rows_done);
        for (0..samples_per_pixel) |p| {
            const strip_index: u32 = @as(u32, @intCast(p)) * strips_per_plane + band;
            const n = try dec.decodeStrip(ifd_index, strip_index, plane_bufs[p], ws);
            plane_views_storage[p] = plane_bufs[p][0..n];
        }
        try photometrics.interleavePlanesToChunky(
            plane_views_storage,
            this_band_rows,
            width,
            bits_per_sample,
            chunky_buf,
        );
        try photometrics.expandRowsToRgba(
            chunky_buf[0 .. @as(usize, this_band_rows) * @as(usize, width) * @as(usize, samples_per_pixel) * sample_bytes],
            this_band_rows,
            fmt,
            rgba[rgba_offset..],
        );
        rgba_offset += @as(usize, this_band_rows) * width * 4;
        rows_done += this_band_rows;
    }
}

fn decodeTiled(
    allocator: Allocator,
    dec: *Decoder,
    ifd_index: usize,
    fmt: photometrics.PixelFormat,
    rgba: []u8,
    ws: *Workspace,
    width: u32,
    height: u32,
    samples_per_pixel: u16,
    bits_per_sample: u16,
) errors.Error!void {
    const dir = try dec.ifd(ifd_index);
    const tile_w = scalarU32(dir, tags.tile_width, dec.endian) orelse return error.Malformed;
    const tile_h = scalarU32(dir, tags.tile_length, dec.endian) orelse return error.Malformed;

    const tile_row_bits: usize = @as(usize, tile_w) * @as(usize, samples_per_pixel) * @as(usize, bits_per_sample);
    const tile_row_bytes: usize = (tile_row_bits + 7) / 8;
    const tile_decoded_bytes: usize = tile_row_bytes * tile_h;
    const tile_buf = allocator.alloc(u8, tile_decoded_bytes) catch return error.OutOfMemory;
    defer allocator.free(tile_buf);

    const tile_rgba_bytes: usize = @as(usize, tile_w) * tile_h * 4;
    const tile_rgba = allocator.alloc(u8, tile_rgba_bytes) catch return error.OutOfMemory;
    defer allocator.free(tile_rgba);

    var tile_fmt = fmt;
    tile_fmt.width = tile_w;

    const tiles_across: u32 = (width + tile_w - 1) / tile_w;
    const tiles_down: u32 = (height + tile_h - 1) / tile_h;

    var ty: u32 = 0;
    while (ty < tiles_down) : (ty += 1) {
        var tx: u32 = 0;
        while (tx < tiles_across) : (tx += 1) {
            const tile_index = ty * tiles_across + tx;
            const n = try dec.decodeTile(ifd_index, tile_index, tile_buf, ws);
            try photometrics.expandRowsToRgba(tile_buf[0..n], tile_h, tile_fmt, tile_rgba);
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
