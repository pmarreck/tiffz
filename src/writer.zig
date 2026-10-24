//! Minimal baseline TIFF writer (in scope since 2026-10-23, see INTENT.md):
//! little-endian classic TIFF, one IFD, chunky strips of about 8 KiB,
//! 8-bit gray (MinIsBlack), RGB or RGBA (unassociated alpha), stored
//! uncompressed, Deflate (zlib) or LZW. Pure in-memory; the C FFI and
//! CLI do all I/O. Tiles, 16-bit samples, BigTIFF and multi-page stay
//! out of scope.

const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("zlib.h");
});

/// Subset of the tiffz error set; coerces into `errors.Error`.
pub const Error = error{ InvalidArgument, OutOfMemory };

pub const Channels = enum(u8) { gray = 1, rgb = 3, rgba = 4 };

/// Values are the TIFF Compression tag codes.
pub const Compression = enum(u16) { none = 1, lzw = 5, deflate = 8 };

/// libtiff's default strip size target.
const strip_target_bytes = 8192;

const tag_type_short = 3;
const tag_type_long = 4;
const tag_type_rational = 5;

const IfdEntry = struct { tag: u16, field_type: u16, count: u32, value: u32 };

/// Encode `pixels` (row-major, `channels` interleaved bytes per pixel) as a
/// complete TIFF file. Caller frees the result with `allocator`.
/// Layout: header, IFD, out-of-line tag values, then strip data, every
/// offset word aligned. Classic TIFF, so the file must fit 32-bit offsets.
pub fn encode(
    allocator: Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
    channels: Channels,
    compression: Compression,
) Error![]u8 {
    if (width == 0 or height == 0) return error.InvalidArgument;
    const spp: u32 = @intFromEnum(channels);
    const row_bytes = std.math.mul(usize, width, spp) catch return error.InvalidArgument;
    const total = std.math.mul(usize, row_bytes, height) catch return error.InvalidArgument;
    if (pixels.len != total) return error.InvalidArgument;
    if (total > std.math.maxInt(u32) / 2) return error.InvalidArgument;

    const rows_per_strip: u32 = @intCast(@min(height, @max(1, strip_target_bytes / row_bytes)));
    const strip_count: u32 = (height + rows_per_strip - 1) / rows_per_strip;

    // Compress every strip into one data blob, recording each strip's
    // start within it and its length. Strips start word aligned.
    var data: std.ArrayListUnmanaged(u8) = .empty;
    defer data.deinit(allocator);
    const starts = try allocator.alloc(u32, strip_count);
    defer allocator.free(starts);
    const lengths = try allocator.alloc(u32, strip_count);
    defer allocator.free(lengths);
    for (0..strip_count) |i| {
        if (data.items.len % 2 == 1) try data.append(allocator, 0);
        const first = i * rows_per_strip;
        const rows = @min(rows_per_strip, height - first);
        const raw = pixels[first * row_bytes .. (first + rows) * row_bytes];
        const before = data.items.len;
        switch (compression) {
            .none => try data.appendSlice(allocator, raw),
            .deflate => try deflateAppend(allocator, &data, raw),
            .lzw => try lzwAppend(allocator, &data, raw),
        }
        starts[i] = @intCast(before);
        lengths[i] = @intCast(data.items.len - before);
    }

    const extra_samples = channels == .rgba;
    const entry_count: u16 = if (extra_samples) 14 else 13;
    const ifd_offset: u32 = 8;
    const ifd_bytes: u32 = 2 + @as(u32, entry_count) * 12 + 4;

    // Out-of-line values, appended after the IFD.
    var extra: std.ArrayListUnmanaged(u8) = .empty;
    defer extra.deinit(allocator);
    const extra_base = ifd_offset + ifd_bytes;

    var bps_value: u32 = 8;
    if (spp > 2) {
        bps_value = extra_base + @as(u32, @intCast(extra.items.len));
        for (0..spp) |_| try appendInt(allocator, &extra, u16, 8);
    }
    const xres_offset = extra_base + @as(u32, @intCast(extra.items.len));
    try appendInt(allocator, &extra, u32, 72);
    try appendInt(allocator, &extra, u32, 1);
    const yres_offset = extra_base + @as(u32, @intCast(extra.items.len));
    try appendInt(allocator, &extra, u32, 72);
    try appendInt(allocator, &extra, u32, 1);

    var offsets_value: u32 = 0;
    var counts_value: u32 = lengths[0];
    if (strip_count > 1) {
        counts_value = extra_base + @as(u32, @intCast(extra.items.len));
        for (lengths) |n| try appendInt(allocator, &extra, u32, n);
        offsets_value = extra_base + @as(u32, @intCast(extra.items.len));
        try extra.appendNTimes(allocator, 0, strip_count * 4); // patched below
    }
    if (extra.items.len % 2 == 1) try extra.append(allocator, 0);

    const data_base = extra_base + @as(u32, @intCast(extra.items.len));
    if (@as(u64, data_base) + data.items.len > std.math.maxInt(u32)) return error.InvalidArgument;
    if (strip_count > 1) {
        const at = offsets_value - extra_base;
        for (starts, 0..) |s, i| {
            std.mem.writeInt(u32, extra.items[at + i * 4 ..][0..4], data_base + s, .little);
        }
    } else {
        offsets_value = data_base + starts[0];
    }

    const strip_type: u16 = tag_type_long;
    var ifd_entries = [_]IfdEntry{
        .{ .tag = 256, .field_type = tag_type_long, .count = 1, .value = width },
        .{ .tag = 257, .field_type = tag_type_long, .count = 1, .value = height },
        .{ .tag = 258, .field_type = tag_type_short, .count = spp, .value = bps_value },
        .{ .tag = 259, .field_type = tag_type_short, .count = 1, .value = @intFromEnum(compression) },
        .{ .tag = 262, .field_type = tag_type_short, .count = 1, .value = if (channels == .gray) 1 else 2 },
        .{ .tag = 273, .field_type = strip_type, .count = strip_count, .value = offsets_value },
        .{ .tag = 277, .field_type = tag_type_short, .count = 1, .value = spp },
        .{ .tag = 278, .field_type = tag_type_long, .count = 1, .value = rows_per_strip },
        .{ .tag = 279, .field_type = strip_type, .count = strip_count, .value = counts_value },
        .{ .tag = 282, .field_type = tag_type_rational, .count = 1, .value = xres_offset },
        .{ .tag = 283, .field_type = tag_type_rational, .count = 1, .value = yres_offset },
        .{ .tag = 284, .field_type = tag_type_short, .count = 1, .value = 1 },
        .{ .tag = 296, .field_type = tag_type_short, .count = 1, .value = 2 },
        .{ .tag = 338, .field_type = tag_type_short, .count = 1, .value = 2 },
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, data_base + data.items.len);
    try out.appendSlice(allocator, "II*\x00");
    try appendInt(allocator, &out, u32, ifd_offset);
    try appendInt(allocator, &out, u16, entry_count);
    for (ifd_entries[0..entry_count]) |e| {
        try appendInt(allocator, &out, u16, e.tag);
        try appendInt(allocator, &out, u16, e.field_type);
        try appendInt(allocator, &out, u32, e.count);
        // An inline SHORT sits in the first two bytes of the value field.
        if (e.field_type == tag_type_short and e.count == 1) {
            try appendInt(allocator, &out, u16, @intCast(e.value));
            try appendInt(allocator, &out, u16, 0);
        } else {
            try appendInt(allocator, &out, u32, e.value);
        }
    }
    try appendInt(allocator, &out, u32, 0); // no next IFD
    try out.appendSlice(allocator, extra.items);
    try out.appendSlice(allocator, data.items);
    return out.toOwnedSlice(allocator);
}

fn appendInt(allocator: Allocator, list: *std.ArrayListUnmanaged(u8), comptime T: type, v: T) Error!void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, v, .little);
    try list.appendSlice(allocator, &buf);
}

/// zlib-framed deflate (TIFF compression 8) via the C zlib already linked
/// for decoding.
fn deflateAppend(allocator: Allocator, list: *std.ArrayListUnmanaged(u8), raw: []const u8) Error!void {
    const bound: usize = c.compressBound(@intCast(raw.len));
    try list.ensureUnusedCapacity(allocator, bound);
    const dest = list.unusedCapacitySlice();
    var dest_len: c.uLongf = @intCast(dest.len);
    const rc = c.compress2(dest.ptr, &dest_len, raw.ptr, @intCast(raw.len), c.Z_DEFAULT_COMPRESSION);
    switch (rc) {
        c.Z_OK => list.items.len += @intCast(dest_len),
        c.Z_MEM_ERROR => return error.OutOfMemory,
        else => return error.InvalidArgument,
    }
}

const lzw_clear: u16 = 256;
const lzw_eoi: u16 = 257;
const lzw_first: u16 = 258;
const lzw_min_bits: u5 = 9;
const lzw_max_code: u16 = 4095;

/// MSB-first bit packer for LZW codes.
const BitSink = struct {
    list: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,
    acc: u32 = 0,
    nacc: u5 = 0,

    fn put(self: *BitSink, code: u16, bits: u5) Error!void {
        self.acc = (self.acc << bits) | code;
        self.nacc += bits;
        while (self.nacc >= 8) {
            self.nacc -= 8;
            try self.list.append(self.allocator, @truncate(self.acc >> self.nacc));
        }
        self.acc &= (@as(u32, 1) << self.nacc) - 1;
    }

    fn flush(self: *BitSink) Error!void {
        if (self.nacc > 0) {
            const shift: u5 = 8 - @as(u5, @intCast(self.nacc));
            try self.list.append(self.allocator, @truncate(self.acc << shift));
            self.nacc = 0;
            self.acc = 0;
        }
    }
};

/// TIFF LZW (compression 5): MSB-first codes, a leading Clear, 9 to 12
/// bit widths with the encoder-side switch libtiff uses (width grows once
/// the next free code exceeds the current maximum, which decoders see as
/// "early change"), a Clear when code 4094 would be assigned, then EOI.
/// The string table is a hash map keyed by (prefix code, next byte).
fn lzwAppend(allocator: Allocator, list: *std.ArrayListUnmanaged(u8), raw: []const u8) Error!void {
    var table: std.AutoHashMapUnmanaged(u32, u16) = .empty;
    defer table.deinit(allocator);
    try table.ensureTotalCapacity(allocator, lzw_max_code);

    var sink: BitSink = .{ .list = list, .allocator = allocator };
    var bits: u5 = lzw_min_bits;
    var max_code: u16 = (1 << lzw_min_bits) - 1;
    var free_ent: u16 = lzw_first;

    try sink.put(lzw_clear, bits);
    var ent: u16 = raw[0];
    for (raw[1..]) |byte| {
        const key = (@as(u32, ent) << 8) | byte;
        if (table.get(key)) |code| {
            ent = code;
            continue;
        }
        try sink.put(ent, bits);
        ent = byte;
        table.putAssumeCapacity(key, free_ent);
        free_ent += 1;
        if (free_ent == lzw_max_code - 1) {
            try sink.put(lzw_clear, bits);
            table.clearRetainingCapacity();
            bits = lzw_min_bits;
            max_code = (1 << lzw_min_bits) - 1;
            free_ent = lzw_first;
        } else if (free_ent > max_code) {
            bits += 1;
            max_code = @intCast((@as(u32, 1) << bits) - 1);
        }
    }
    try sink.put(ent, bits);
    free_ent += 1;
    if (free_ent == lzw_max_code - 1) {
        try sink.put(lzw_clear, bits);
        bits = lzw_min_bits;
    } else if (free_ent > max_code) {
        bits += 1;
    }
    try sink.put(lzw_eoi, bits);
    try sink.flush();
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn le16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}
fn le32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

/// A parsed IFD entry, read straight from the bytes so the tests do not
/// share code with the writer.
const Entry = struct { tag: u16, field_type: u16, count: u32, value: u32 };

fn entries(b: []const u8) ![]const Entry {
    const S = struct {
        var buf: [32]Entry = undefined;
    };
    try testing.expectEqualSlices(u8, "II*\x00", b[0..4]);
    const ifd = le32(b, 4);
    const n = le16(b, ifd);
    try testing.expect(n <= S.buf.len);
    for (0..n) |i| {
        const at = ifd + 2 + i * 12;
        S.buf[i] = .{ .tag = le16(b, at), .field_type = le16(b, at + 2), .count = le32(b, at + 4), .value = le32(b, at + 8) };
    }
    try testing.expectEqual(@as(u32, 0), le32(b, ifd + 2 + @as(usize, n) * 12));
    return S.buf[0..n];
}

fn find(es: []const Entry, tag: u16) !Entry {
    for (es) |e| if (e.tag == tag) return e;
    return error.TestUnexpectedResult;
}

fn has(es: []const Entry, tag: u16) bool {
    for (es) |e| if (e.tag == tag) return true;
    return false;
}

/// The value of a SHORT/LONG count-1 entry.
fn scalar(es: []const Entry, tag: u16) !u32 {
    const e = try find(es, tag);
    try testing.expectEqual(@as(u32, 1), e.count);
    return if (e.field_type == 3) e.value & 0xffff else e.value;
}

/// The i-th element of a LONG array entry, inline or out of line.
fn longAt(b: []const u8, e: Entry, i: usize) u32 {
    if (e.count == 1) return e.value;
    return le32(b, e.value + i * 4);
}

/// Concatenate every strip's stored bytes.
fn stripBytes(allocator: Allocator, b: []const u8, es: []const Entry) ![]u8 {
    const offs = try find(es, 273);
    const counts = try find(es, 279);
    try testing.expectEqual(offs.count, counts.count);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (0..offs.count) |i| {
        const o = longAt(b, offs, i);
        const n = longAt(b, counts, i);
        try testing.expect(o + n <= b.len);
        try out.appendSlice(allocator, b[o .. o + n]);
    }
    return out.toOwnedSlice(allocator);
}

fn pattern(allocator: Allocator, len: usize) ![]u8 {
    const p = try allocator.alloc(u8, len);
    for (p, 0..) |*x, i| x.* = @truncate(i *% 37 +% (i >> 7));
    return p;
}

test "gray8 uncompressed: baseline tags and strip bytes equal the pixels" {
    const px = [_]u8{ 0, 64, 128, 192, 255, 7 };
    const tif = try encode(testing.allocator, &px, 3, 2, .gray, .none);
    defer testing.allocator.free(tif);
    const es = try entries(tif);

    var prev: u16 = 0;
    for (es) |e| {
        try testing.expect(e.tag > prev); // ascending, no duplicates
        prev = e.tag;
    }
    try testing.expectEqual(@as(u32, 3), try scalar(es, 256));
    try testing.expectEqual(@as(u32, 2), try scalar(es, 257));
    try testing.expectEqual(@as(u32, 8), try scalar(es, 258));
    try testing.expectEqual(@as(u32, 1), try scalar(es, 259));
    try testing.expectEqual(@as(u32, 1), try scalar(es, 262)); // MinIsBlack
    try testing.expectEqual(@as(u32, 1), try scalar(es, 277));
    try testing.expectEqual(@as(u32, 1), try scalar(es, 284)); // chunky
    try testing.expectEqual(@as(u32, 2), try scalar(es, 296)); // inch
    for ([_]u16{ 282, 283 }) |t| {
        const r = try find(es, t);
        try testing.expectEqual(@as(u16, 5), r.field_type);
        try testing.expectEqual(@as(u32, 72), le32(tif, r.value));
        try testing.expectEqual(@as(u32, 1), le32(tif, r.value + 4));
    }
    try testing.expect(!has(es, 338));

    const got = try stripBytes(testing.allocator, tif, es);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &px, got);
}

test "rgba declares unassociated alpha and 8,8,8,8 out of line" {
    const px = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    const tif = try encode(testing.allocator, &px, 2, 1, .rgba, .none);
    defer testing.allocator.free(tif);
    const es = try entries(tif);
    try testing.expectEqual(@as(u32, 2), try scalar(es, 262)); // RGB
    try testing.expectEqual(@as(u32, 4), try scalar(es, 277));
    try testing.expectEqual(@as(u32, 2), try scalar(es, 338)); // unassociated
    const bps = try find(es, 258);
    try testing.expectEqual(@as(u32, 4), bps.count);
    for (0..4) |i| try testing.expectEqual(@as(u16, 8), le16(tif, bps.value + i * 2));

    const rgb = try encode(testing.allocator, px[0..6], 2, 1, .rgb, .none);
    defer testing.allocator.free(rgb);
    const res = try entries(rgb);
    try testing.expectEqual(@as(u32, 3), try scalar(res, 277));
    try testing.expect(!has(res, 338));
}

test "rows are split into strips of about 8 KiB at word-aligned offsets" {
    // 3000-byte rows: two rows per strip, five strips.
    const px = try pattern(testing.allocator, 1000 * 3 * 10);
    defer testing.allocator.free(px);
    const tif = try encode(testing.allocator, px, 1000, 10, .rgb, .none);
    defer testing.allocator.free(tif);
    const es = try entries(tif);
    try testing.expectEqual(@as(u32, 2), try scalar(es, 278));
    const offs = try find(es, 273);
    const counts = try find(es, 279);
    try testing.expectEqual(@as(u32, 5), offs.count);
    for (0..5) |i| {
        try testing.expectEqual(@as(u32, 6000), longAt(tif, counts, i));
        try testing.expectEqual(@as(u32, 0), longAt(tif, offs, i) % 2);
    }
    for (es) |e| {
        const elem: u32 = switch (e.field_type) {
            3 => 2,
            4 => 4,
            5 => 8,
            else => 1,
        };
        if (elem * e.count > 4) try testing.expectEqual(@as(u32, 0), e.value % 2);
    }
    const got = try stripBytes(testing.allocator, tif, es);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, px, got);

    // A 1-pixel-high image is one strip whose RowsPerStrip is the height.
    const one = try encode(testing.allocator, px[0..9000], 3000, 1, .rgb, .none);
    defer testing.allocator.free(one);
    const oes = try entries(one);
    try testing.expectEqual(@as(u32, 1), try scalar(oes, 278));
    try testing.expectEqual(@as(u32, 1), (try find(oes, 273)).count);
}

test "deflate strips are zlib streams that inflate to the rows" {
    const px = try pattern(testing.allocator, 640 * 40);
    defer testing.allocator.free(px);
    const tif = try encode(testing.allocator, px, 640, 40, .gray, .deflate);
    defer testing.allocator.free(tif);
    const es = try entries(tif);
    try testing.expectEqual(@as(u32, 8), try scalar(es, 259));
    const rps = try scalar(es, 278);
    const offs = try find(es, 273);
    const counts = try find(es, 279);
    var row: usize = 0;
    for (0..offs.count) |i| {
        const o = longAt(tif, offs, i);
        const n = longAt(tif, counts, i);
        const rows = @min(rps, 40 - row);
        const want = px[row * 640 .. (row + rows) * 640];
        const got = try testing.allocator.alloc(u8, want.len);
        defer testing.allocator.free(got);
        var got_len: c.uLongf = got.len;
        try testing.expectEqual(@as(c_int, c.Z_OK), c.uncompress(got.ptr, &got_len, tif[o..].ptr, n));
        try testing.expectEqual(@as(c.uLongf, want.len), got_len);
        try testing.expectEqualSlices(u8, want, got);
        row += rows;
    }
    try testing.expectEqual(@as(usize, 40), row);
}

test "lzw strip matches a hand-encoded vector" {
    // Clear(256) 'A'(65) 'B'(66) EOI(257), all 9-bit, MSB first:
    // 100000000 001000001 001000010 100000001 + 4 zero pad bits.
    const tif = try encode(testing.allocator, "AB", 2, 1, .gray, .lzw);
    defer testing.allocator.free(tif);
    const es = try entries(tif);
    try testing.expectEqual(@as(u32, 5), try scalar(es, 259));
    const got = try stripBytes(testing.allocator, tif, es);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u8, &.{ 0x80, 0x10, 0x48, 0x50, 0x10 }, got);
}

test "invalid geometry and short or long pixel buffers are refused" {
    const px = [_]u8{0} ** 12;
    try testing.expectError(error.InvalidArgument, encode(testing.allocator, &px, 0, 1, .gray, .none));
    try testing.expectError(error.InvalidArgument, encode(testing.allocator, &px, 1, 0, .gray, .none));
    try testing.expectError(error.InvalidArgument, encode(testing.allocator, px[0..11], 2, 2, .rgb, .none));
    try testing.expectError(error.InvalidArgument, encode(testing.allocator, &px, 2, 1, .rgb, .none));
    try testing.expectError(error.InvalidArgument, encode(testing.allocator, &px, 0xffff_ffff, 0xffff_ffff, .rgba, .none));
}
