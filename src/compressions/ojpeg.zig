//! Old-style JPEG (Compression 6, TIFF 6.0 section 22), read the way libtiff
//! 4.7.2's tif_ojpeg.c reads it. TIFF 6.0's scheme contradicts itself (TIFF
//! Technical Note 2), so this is a best-effort reading, and the decoder
//! reports every Compression 6 IFD as finding 25 whatever the result (owner
//! 2026-11-07: "make a best-effort parse but WARN on it regardless of
//! result").
//!
//! The input is the JPEGInterchangeFormat bytes, if any, followed by every
//! strip or tile in order. Its leading markers, up to SOS or to the first
//! byte that is not a marker, give the header. When they hold no SOF, the
//! header is rebuilt from JPEGQTables, JPEGDCTables and JPEGACTables, as an
//! 8-bit baseline frame whose first component carries the YCbCr
//! subsampling. A complete stream is then assembled: SOI, the tables, DRI
//! when a restart interval applies, SOF, SOS, the rest of the input with an
//! RST marker between consecutive strips or tiles, and EOI. The data ends at
//! the first EOI in the input, where libjpeg stops, so a
//! JPEGInterchangeFormat stream that already holds the whole image is not
//! followed by the strips that repeat it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const errors = @import("tiffz-parser").errors;

/// Where the header came from (finding 25's payload).
pub const HeaderSource = enum(u16) {
    /// No SOF in the leading markers and no complete set of table tags.
    none = 0,
    /// Markers in the JPEGInterchangeFormat stream.
    interchange = 1,
    /// Markers at the start of the first strip or tile.
    first_chunk = 2,
    /// Rebuilt from JPEGQTables, JPEGDCTables and JPEGACTables.
    tables = 3,
};

/// The directory fields the reading depends on.
pub const Frame = struct {
    /// SamplesPerPixel: 1 or 3, the only counts libtiff accepts.
    samples: u8,
    /// PhotometricInterpretation is YCbCr (or ITULab) with 3 samples: the
    /// first component then carries the subsampling. Otherwise it is 1x1.
    ycbcr: bool,
    /// YCbCrSubsampling, or libtiff's default 2, 2.
    sub_h: u8 = 2,
    sub_v: u8 = 2,
    image_width: u32,
    image_length: u32,
    /// ImageWidth for strips, TileWidth for tiles.
    strile_width: u32,
    /// The clamped RowsPerStrip, or TileLength.
    strile_length: u32,
    /// ImageLength for strips; tiles down times TileLength for tiles.
    strile_length_total: u32,
    /// JPEGRestartInterval, 0 when absent.
    restart_interval: u16 = 0,
};

/// A table tag's value for one component: its file offset (libtiff reuses
/// the previous component's table when two offsets match) and its bytes.
pub const Table = struct { offset: u64, bytes: []const u8 };

/// JPEGQTables (64 bytes each, in zigzag order as DQT holds them), and
/// JPEGDCTables and JPEGACTables (16 code counts, then the values).
pub const Tables = struct {
    q: [3]?Table = .{ null, null, null },
    dc: [3]?Table = .{ null, null, null },
    ac: [3]?Table = .{ null, null, null },
};

pub const Input = struct {
    /// The JPEGInterchangeFormat bytes, then each strip or tile.
    bytes: []const u8,
    jif_len: usize,
    /// The end of each strip or tile within `bytes`, ascending.
    chunk_ends: []const usize,
};

pub const Composed = struct {
    stream: []u8,
    header: HeaderSource,
    /// The frame's width and height (its SOF).
    width: u32,
    height: u32,

    pub fn deinit(self: *Composed, allocator: Allocator) void {
        allocator.free(self.stream);
    }
};

const sof_markers = [_]u8{ 0xC0, 0xC1, 0xC3 };

/// Where the header would come from, without composing.
pub fn headerSource(input: Input, tables: Tables) HeaderSource {
    var pos: usize = 0;
    while (pos + 1 < input.bytes.len and input.bytes[pos] == 0xFF) {
        while (pos < input.bytes.len and input.bytes[pos] == 0xFF) pos += 1;
        if (pos >= input.bytes.len) break;
        const m = input.bytes[pos];
        const at = pos - 1;
        pos += 1;
        if (m == 0xD8) continue;
        if (std.mem.indexOfScalar(u8, &sof_markers, m) != null) {
            return if (at < input.jif_len) .interchange else .first_chunk;
        }
        if (m == 0xDA or pos + 2 > input.bytes.len) break;
        const len = std.mem.readInt(u16, input.bytes[pos..][0..2], .big);
        if (len < 2) break;
        pos += len;
    }
    return if (tables.q[0] != null and tables.dc[0] != null and tables.ac[0] != null) .tables else .none;
}

const Sof = struct {
    marker: u8,
    y: u16,
    x: u16,
    c: [3]u8 = .{ 0, 0, 0 },
    hv: [3]u8 = .{ 0x11, 0x11, 0x11 },
    tq: [3]u8 = .{ 0, 0, 0 },
};

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn byte(self: *Reader) errors.Error!u8 {
        if (self.pos >= self.bytes.len) return error.Malformed;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }

    fn word(self: *Reader) errors.Error!u16 {
        if (self.pos + 2 > self.bytes.len) return error.Malformed;
        defer self.pos += 2;
        return std.mem.readInt(u16, self.bytes[self.pos..][0..2], .big);
    }

    fn take(self: *Reader, n: usize) errors.Error![]const u8 {
        if (n > self.bytes.len - self.pos) return error.Malformed;
        defer self.pos += n;
        return self.bytes[self.pos..][0..n];
    }
};

/// libtiff's subsampling correction: a YCbCr frame takes its subsampling
/// from the first SOF in the leading markers, or 1x1 when that SOF's values
/// are not 1, 2 or 4 (or a later component is not 1x1).
fn correctedSubsampling(input: Input, frame: Frame) [2]u8 {
    if (frame.samples != 3 or !frame.ycbcr) return .{ 1, 1 };
    var r = Reader{ .bytes = input.bytes };
    while (r.pos < r.bytes.len and r.bytes[r.pos] == 0xFF) {
        while (r.pos < r.bytes.len and r.bytes[r.pos] == 0xFF) r.pos += 1;
        const m = r.byte() catch break;
        if (m == 0xD8) continue;
        if (m == 0xDA) break;
        const len = r.word() catch break;
        if (len < 2) break;
        const body = r.take(len - 2) catch break;
        if (std.mem.indexOfScalar(u8, &sof_markers, m) == null) continue;
        if (body.len < 6) break;
        const n = body[5];
        if (n == 0 or body.len < 6 + @as(usize, n) * 3) break;
        const hv = body[7];
        const h = hv >> 4;
        const v = hv & 15;
        var ok = (h == 1 or h == 2 or h == 4) and (v == 1 or v == 2 or v == 4);
        for (1..n) |k| {
            if (body[6 + k * 3 + 1] != 0x11) ok = false;
        }
        return if (ok) .{ h, v } else .{ 1, 1 };
    }
    return .{ frame.sub_h, frame.sub_v };
}

/// Assemble the complete JPEG stream libtiff hands libjpeg. Malformed when
/// the leading markers or the table tags cannot give a header libtiff would
/// accept.
pub fn compose(allocator: Allocator, input: Input, tables: Tables, frame: Frame) errors.Error!Composed {
    if (frame.samples != 1 and frame.samples != 3) return error.Malformed;
    const n: usize = frame.samples;
    const sub = correctedSubsampling(input, frame);

    var restart: u16 = frame.restart_interval;
    if (frame.strile_length < frame.image_length) {
        // Several strips or tiles: one restart interval per strip or tile.
        for (sub) |s| if (s != 1 and s != 2 and s != 4) return error.Malformed;
        const mcu_h: u32 = @as(u32, sub[0]) * 8;
        const mcu_v: u32 = @as(u32, sub[1]) * 8;
        if (frame.strile_length % mcu_v != 0) return error.Malformed;
        const across = (frame.strile_width + mcu_h - 1) / mcu_h;
        restart = std.math.cast(u16, across * (frame.strile_length / mcu_v)) orelse return error.Malformed;
    }

    var segments: std.ArrayListUnmanaged(u8) = .empty;
    defer segments.deinit(allocator);
    var sof: ?Sof = null;
    var sof_at: usize = 0;
    var cs: [3]u8 = .{ 0, 1, 2 };
    var tda: [3]u8 = .{ 0, 0, 0 };
    var r = Reader{ .bytes = input.bytes };
    while (true) {
        const peek = r.byte() catch return error.Malformed;
        if (peek != 0xFF) {
            r.pos -= 1;
            break;
        }
        var m = try r.byte();
        while (m == 0xFF) m = try r.byte();
        switch (m) {
            0xD8 => {},
            0xE0...0xEF, 0xFE => {
                const len = try r.word();
                if (len < 2) return error.Malformed;
                _ = try r.take(len - 2);
            },
            0xDD => {
                if (try r.word() != 4) return error.Malformed;
                restart = try r.word();
            },
            0xDB, 0xC4 => {
                const len = try r.word();
                if (len <= 2) return error.Malformed;
                const body = try r.take(len - 2);
                const len_be = be16(len);
                try segments.appendSlice(allocator, &.{ 0xFF, m, len_be[0], len_be[1] });
                try segments.appendSlice(allocator, body);
            },
            0xC0, 0xC1, 0xC3 => {
                if (sof != null) return error.Malformed;
                sof_at = r.pos - 2;
                const len = try r.word();
                if (len < 11 or (len - 8) % 3 != 0 or (len - 8) / 3 != n) return error.Malformed;
                if (try r.byte() != 8) return error.Malformed;
                var s = Sof{ .marker = m, .y = try r.word(), .x = try r.word() };
                if (s.y < frame.image_length and s.y < frame.strile_length_total) return error.Malformed;
                if (s.x < frame.image_width and s.x < frame.strile_width) return error.Malformed;
                if (s.x > frame.strile_width) return error.Malformed;
                if (try r.byte() != n) return error.Malformed;
                for (0..n) |k| {
                    s.c[k] = try r.byte();
                    s.hv[k] = try r.byte();
                    s.tq[k] = try r.byte();
                }
                sof = s;
            },
            0xDA => {
                if (sof == null) return error.Malformed;
                if (try r.word() != 6 + 2 * n) return error.Malformed;
                if (try r.byte() != n) return error.Malformed;
                for (0..n) |k| {
                    cs[k] = try r.byte();
                    tda[k] = try r.byte();
                }
                _ = try r.take(3);
                break;
            },
            else => return error.Malformed,
        }
    }

    var header: HeaderSource = undefined;
    if (sof) |_| {
        header = if (sof_at < input.jif_len) .interchange else .first_chunk;
    } else {
        // No SOF: rebuild the header from the table tags (libtiff
        // OJPEGReadHeaderInfoSecTables*).
        if (tables.q[0] == null or tables.dc[0] == null or tables.ac[0] == null) return error.Malformed;
        header = .tables;
        var s = Sof{
            .marker = 0xC0,
            .y = std.math.cast(u16, frame.strile_length_total) orelse return error.Malformed,
            .x = std.math.cast(u16, frame.strile_width) orelse return error.Malformed,
        };
        s.hv[0] = (sub[0] << 4) | sub[1];
        for (0..n) |k| {
            const kb: u8 = @intCast(k);
            s.c[k] = kb;
            cs[k] = kb;
            if (newTable(tables.q, k)) |t| {
                if (t.bytes.len != 64) return error.Malformed;
                try segments.appendSlice(allocator, &.{ 0xFF, 0xDB, 0, 67, kb });
                try segments.appendSlice(allocator, t.bytes);
                s.tq[k] = kb;
            } else if (k == 0) return error.Malformed else {
                s.tq[k] = s.tq[k - 1];
            }
            if (newTable(tables.dc, k)) |t| {
                try appendHuffman(allocator, &segments, t.bytes, kb);
                tda[k] = kb << 4;
            } else if (k == 0) return error.Malformed else {
                tda[k] = tda[k - 1] & 0xF0;
            }
            if (newTable(tables.ac, k)) |t| {
                try appendHuffman(allocator, &segments, t.bytes, 0x10 | kb);
                tda[k] |= kb;
            } else if (k == 0) return error.Malformed else {
                tda[k] |= tda[k - 1] & 0x0F;
            }
        }
        sof = s;
    }
    const f = sof.?;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &.{ 0xFF, 0xD8 });
    try out.appendSlice(allocator, segments.items);
    if (restart != 0) {
        const ri = be16(restart);
        try out.appendSlice(allocator, &.{ 0xFF, 0xDD, 0, 4, ri[0], ri[1] });
    }
    const nb: u8 = @intCast(n);
    const y = be16(f.y);
    const x = be16(f.x);
    try out.appendSlice(allocator, &.{ 0xFF, f.marker, 0, 8 + 3 * nb, 8, y[0], y[1], x[0], x[1], nb });
    for (0..n) |k| try out.appendSlice(allocator, &.{ f.c[k], f.hv[k], f.tq[k] });
    try out.appendSlice(allocator, &.{ 0xFF, 0xDA, 0, 6 + 2 * nb, nb });
    for (0..n) |k| try out.appendSlice(allocator, &.{ cs[k], tda[k] });
    try out.appendSlice(allocator, &.{ 0, 63, 0 });

    // The data: the rest of the JPEGInterchangeFormat bytes, then each strip
    // or tile, an RST marker between consecutive strips or tiles, to the
    // first EOI.
    var start = r.pos;
    var rst: u8 = 0;
    var ended = false;
    if (start < input.jif_len) {
        ended = try appendData(allocator, &out, input.bytes[start..input.jif_len]);
        start = input.jif_len;
    }
    var chunk_start = input.jif_len;
    for (input.chunk_ends, 0..) |end, i| {
        if (ended) break;
        if (end > input.bytes.len or end < chunk_start) return error.Malformed;
        if (end > start) {
            ended = try appendData(allocator, &out, input.bytes[@max(start, chunk_start)..end]);
            if (!ended and i + 1 < input.chunk_ends.len) {
                try out.appendSlice(allocator, &.{ 0xFF, 0xD0 + rst });
                rst = (rst + 1) % 8;
            }
        }
        chunk_start = end;
    }
    try out.appendSlice(allocator, &.{ 0xFF, 0xD9 });
    return .{ .stream = try out.toOwnedSlice(allocator), .header = header, .width = f.x, .height = f.y };
}

/// The table component `k` defines, or null when it reuses the previous
/// component's (libtiff: an absent offset, or the same offset as before).
fn be16(v: u16) [2]u8 {
    return .{ @intCast(v >> 8), @truncate(v) };
}

fn newTable(tables: [3]?Table, k: usize) ?Table {
    const t = tables[k] orelse return null;
    if (t.offset == 0) return null;
    if (k > 0) if (tables[k - 1]) |prev| if (prev.offset == t.offset) return null;
    return t;
}

fn appendHuffman(allocator: Allocator, out: *std.ArrayListUnmanaged(u8), table: []const u8, class_id: u8) errors.Error!void {
    if (table.len < 16) return error.Malformed;
    var count: usize = 0;
    for (table[0..16]) |c| count += c;
    if (table.len < 16 + count) return error.Malformed;
    const len = be16(std.math.cast(u16, 19 + count) orelse return error.Malformed);
    try out.appendSlice(allocator, &.{ 0xFF, 0xC4, len[0], len[1], class_id });
    try out.appendSlice(allocator, table[0 .. 16 + count]);
}

/// Append entropy-coded bytes up to an EOI marker. True when one was found.
fn appendData(allocator: Allocator, out: *std.ArrayListUnmanaged(u8), data: []const u8) errors.Error!bool {
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 1) {
        if (data[i] == 0xFF and data[i + 1] == 0xD9) {
            try out.appendSlice(allocator, data[0..i]);
            return true;
        }
    }
    try out.appendSlice(allocator, data);
    return false;
}

// ---- tests ----

const testing = std.testing;

const one_strip: Frame = .{ .samples = 1, .ycbcr = false, .image_width = 8, .image_length = 8, .strile_width = 8, .strile_length = 8, .strile_length_total = 8 };

test "ojpeg.compose: a complete stream in the JPEGInterchangeFormat bytes is rebuilt, its data ending at its EOI" {
    // SOI, APP0 (dropped), DQT, DHT, SOF0 8x8 gray, SOS, 3 data bytes, EOI;
    // a strip repeating the data follows and is not used.
    const jif = [_]u8{ 0xFF, 0xD8, 0xFF, 0xE0, 0, 4, 1, 2, 0xFF, 0xDB, 0, 3, 9, 0xFF, 0xC4, 0, 3, 7, 0xFF, 0xC0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 63, 0, 0xAA, 0xFF, 0x00, 0xFF, 0xD9 };
    const strip = [_]u8{ 0xAA, 0xFF, 0x00 };
    const bytes = jif ++ strip;
    var c = try compose(testing.allocator, .{ .bytes = &bytes, .jif_len = jif.len, .chunk_ends = &.{bytes.len} }, .{}, one_strip);
    defer c.deinit(testing.allocator);
    try testing.expectEqual(HeaderSource.interchange, c.header);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0xD8, 0xFF, 0xDB, 0, 3, 9, 0xFF, 0xC4, 0, 3, 7, 0xFF, 0xC0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 63, 0, 0xAA, 0xFF, 0x00, 0xFF, 0xD9 }, c.stream);
    try testing.expectEqual(HeaderSource.interchange, headerSource(.{ .bytes = &bytes, .jif_len = jif.len, .chunk_ends = &.{bytes.len} }, .{}));
}

test "ojpeg.compose: tables in tags rebuild the header; strips get RST markers between them and a computed restart interval" {
    // Two 8-row strips of 16x16 gray: one MCU row each, two MCUs across.
    const q = [_]u8{1} ** 64;
    const huff = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5 };
    const strips = [_]u8{ 0x11, 0x22, 0x33, 0x44 };
    const frame: Frame = .{ .samples = 1, .ycbcr = false, .image_width = 16, .image_length = 16, .strile_width = 16, .strile_length = 8, .strile_length_total = 16 };
    const tables: Tables = .{ .q = .{ .{ .offset = 100, .bytes = &q }, null, null }, .dc = .{ .{ .offset = 200, .bytes = &huff }, null, null }, .ac = .{ .{ .offset = 300, .bytes = &huff }, null, null } };
    const input: Input = .{ .bytes = &strips, .jif_len = 0, .chunk_ends = &.{ 2, 4 } };
    var c = try compose(testing.allocator, input, tables, frame);
    defer c.deinit(testing.allocator);
    try testing.expectEqual(HeaderSource.tables, c.header);
    try testing.expectEqual(HeaderSource.tables, headerSource(input, tables));
    var want: std.ArrayListUnmanaged(u8) = .empty;
    defer want.deinit(testing.allocator);
    try want.appendSlice(testing.allocator, &.{ 0xFF, 0xD8, 0xFF, 0xDB, 0, 67, 0 });
    try want.appendSlice(testing.allocator, &q);
    try want.appendSlice(testing.allocator, &.{ 0xFF, 0xC4, 0, 20, 0x00 });
    try want.appendSlice(testing.allocator, &huff);
    try want.appendSlice(testing.allocator, &.{ 0xFF, 0xC4, 0, 20, 0x10 });
    try want.appendSlice(testing.allocator, &huff);
    try want.appendSlice(testing.allocator, &.{ 0xFF, 0xDD, 0, 4, 0, 2 });
    try want.appendSlice(testing.allocator, &.{ 0xFF, 0xC0, 0, 11, 8, 0, 16, 0, 16, 1, 0, 0x11, 0 });
    try want.appendSlice(testing.allocator, &.{ 0xFF, 0xDA, 0, 8, 1, 0, 0x00, 0, 63, 0 });
    try want.appendSlice(testing.allocator, &.{ 0x11, 0x22, 0xFF, 0xD0, 0x33, 0x44, 0xFF, 0xD9 });
    try testing.expectEqualSlices(u8, want.items, c.stream);
}

test "ojpeg.compose: a header in the first strip; a missing table set or an SOS before SOF is Malformed" {
    const strip = [_]u8{ 0xFF, 0xD8, 0xFF, 0xC0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 63, 0, 0x55, 0xFF, 0xD9 };
    var c = try compose(testing.allocator, .{ .bytes = &strip, .jif_len = 0, .chunk_ends = &.{strip.len} }, .{}, one_strip);
    defer c.deinit(testing.allocator);
    try testing.expectEqual(HeaderSource.first_chunk, c.header);
    try testing.expectEqual(@as(u8, 0x55), c.stream[c.stream.len - 3]);

    const data = [_]u8{ 0x12, 0x34 };
    try testing.expectError(error.Malformed, compose(testing.allocator, .{ .bytes = &data, .jif_len = 0, .chunk_ends = &.{2} }, .{}, one_strip));
    try testing.expectEqual(HeaderSource.none, headerSource(.{ .bytes = &data, .jif_len = 0, .chunk_ends = &.{2} }, .{}));
    const sos_first = [_]u8{ 0xFF, 0xD8, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 63, 0, 0x55 };
    try testing.expectError(error.Malformed, compose(testing.allocator, .{ .bytes = &sos_first, .jif_len = 0, .chunk_ends = &.{sos_first.len} }, .{}, one_strip));
}

test "ojpeg.compose: a 12-bit SOF, a frame narrower than the image, or a wrong component count is Malformed" {
    const base = [_]u8{ 0xFF, 0xD8, 0xFF, 0xC0, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0, 0xFF, 0xDA, 0, 8, 1, 1, 0, 0, 63, 0, 0x55, 0xFF, 0xD9 };
    inline for (.{ .{ 6, 12 }, .{ 10, 4 }, .{ 11, 2 } }) |patch| {
        var bytes = base;
        bytes[patch[0]] = patch[1];
        try testing.expectError(error.Malformed, compose(testing.allocator, .{ .bytes = &bytes, .jif_len = 0, .chunk_ends = &.{bytes.len} }, .{}, one_strip));
    }
}
