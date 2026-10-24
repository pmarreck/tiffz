//! C FFI surface. Per project convention the C ABI is the real public
//! API — every consumer, including the in-tree CLI, reaches the Zig
//! core through here. The core still performs no I/O: callers pass a
//! borrowed byte buffer.

const std = @import("std");
const parser = @import("tiffz-parser");
const version = @import("version.zig");
const errors = parser.errors;
const source_mod = parser.source;
const decoder_mod = @import("decoder.zig");
const workspace_mod = @import("workspace.zig");
const findings_mod = @import("findings.zig");
const rgba_mod = @import("rgba.zig");
const writer = @import("writer.zig");

const Allocator = std.mem.Allocator;
const Decoder = decoder_mod.Decoder;
const Workspace = workspace_mod.Workspace;
const Source = source_mod.Source;

/// Returns a NUL-terminated, statically-allocated version string.
/// The pointer is valid for the lifetime of the loaded library.
export fn tiffz_version() callconv(.c) [*:0]const u8 {
    return version.string.ptr;
}

const Handle = struct {
    buffer_handle: source_mod.BufferHandle,
    decoder: Decoder,
    workspace: Workspace,
    last_status: i32,
    last_message: [256]u8,
    last_message_len: usize,
};

fn setOutStatus(out: ?*i32, status: i32) void {
    if (out) |p| p.* = status;
}

fn storeError(h: *Handle, err: errors.Error) i32 {
    const status = statusFromError(err);
    h.last_status = status;
    const name = @errorName(err);
    const n = @min(name.len, h.last_message.len - 1);
    @memcpy(h.last_message[0..n], name[0..n]);
    h.last_message[n] = 0;
    h.last_message_len = n;
    return status;
}

fn statusFromError(err: errors.Error) i32 {
    return switch (err) {
        error.InvalidArgument => 1,
        error.Malformed => 2,
        error.UnsupportedCompression => 3,
        error.UnsupportedPhotometric => 4,
        error.UnsupportedPredictor => 5,
        error.UnsupportedBitDepth => 6,
        error.UnsupportedTagType => 7,
        error.SourceSeekTooFarBack => 8,
        error.SourceShortRead => 9,
        error.SourceTooShort => 10,
        error.LimitExceededIfdCount => 11,
        error.LimitExceededTagCount => 12,
        error.LimitExceededTagValueBytes => 13,
        error.LimitExceededStripCount => 14,
        error.LimitExceededDimension => 15,
        error.LimitExceededTotalSamples => 16,
        error.LimitExceededCodecScratch => 17,
        error.LimitExceededCompressedStripBytes => 18,
        error.LimitExceededDecompressedStripBytes => 19,
        error.DestTooSmall => 20,
        error.OutOfMemory => 21,
        error.Io => 22,
        error.Bug => 23,
        error.IfdChainCycle => 24,
        error.JpegInTiffPayload => 25,
        error.EndOfFacsimileBlock => 26,
        error.LimitExceededIfdDepth => 27,
        error.LimitExceededBytesVisited => 28,
    };
}

const status_names = [_][:0]const u8{
    "OK",
    "InvalidArgument",
    "Malformed",
    "UnsupportedCompression",
    "UnsupportedPhotometric",
    "UnsupportedPredictor",
    "UnsupportedBitDepth",
    "UnsupportedTagType",
    "SourceSeekTooFarBack",
    "SourceShortRead",
    "SourceTooShort",
    "LimitExceededIfdCount",
    "LimitExceededTagCount",
    "LimitExceededTagValueBytes",
    "LimitExceededStripCount",
    "LimitExceededDimension",
    "LimitExceededTotalSamples",
    "LimitExceededCodecScratch",
    "LimitExceededCompressedStripBytes",
    "LimitExceededDecompressedStripBytes",
    "DestTooSmall",
    "OutOfMemory",
    "Io",
    "Bug",
    "IfdChainCycle",
    "JpegInTiffPayload",
    "EndOfFacsimileBlock",
    "LimitExceededIfdDepth",
    "LimitExceededBytesVisited",
};

export fn tiffz_status_name(status: i32) callconv(.c) [*:0]const u8 {
    if (status < 0) return "UnknownStatus";
    const idx: usize = @intCast(status);
    if (idx >= status_names.len) return "UnknownStatus";
    return status_names[idx].ptr;
}

export fn tiffz_open_from_buffer(
    bytes: ?[*]const u8,
    len: usize,
    out_status: ?*i32,
) callconv(.c) ?*Handle {
    if (bytes == null and len != 0) {
        setOutStatus(out_status, 1);
        return null;
    }
    const slice: []const u8 = if (len == 0 or bytes == null) &[_]u8{} else bytes.?[0..len];
    const allocator = std.heap.c_allocator;
    const h = allocator.create(Handle) catch {
        setOutStatus(out_status, 21);
        return null;
    };
    h.buffer_handle = source_mod.BufferHandle.init(slice);
    h.workspace = Workspace.init(allocator);
    h.last_status = 0;
    h.last_message_len = 0;
    h.last_message[0] = 0;
    h.decoder = Decoder.open(allocator, Source.fromBuffer(&h.buffer_handle)) catch |err| {
        h.workspace.deinit();
        allocator.destroy(h);
        setOutStatus(out_status, statusFromError(err));
        return null;
    };
    setOutStatus(out_status, 0);
    return h;
}

export fn tiffz_close(decoder: ?*Handle) callconv(.c) void {
    const h = decoder orelse return;
    h.decoder.deinit();
    h.workspace.deinit();
    std.heap.c_allocator.destroy(h);
}

export fn tiffz_validate(decoder: ?*Handle) callconv(.c) i32 {
    const h = decoder orelse return 1;
    h.decoder.scanFindings();
    h.decoder.validateAllStripsAndTiles(&h.workspace) catch |err| {
        return storeError(h, err);
    };
    h.last_status = 0;
    h.last_message[0] = 0;
    h.last_message_len = 0;
    return 0;
}

export fn tiffz_ifd_count(decoder: ?*const Handle) callconv(.c) usize {
    const h = decoder orelse return 0;
    return h.decoder.ifdCount();
}

export fn tiffz_status_is_limit(status: i32) callconv(.c) i32 {
    return switch (status) {
        11...19, 27, 28 => 1,
        else => 0,
    };
}

export fn tiffz_limit_progress(
    decoder: ?*const Handle,
    out_offset: ?*u64,
    out_ifd_index: ?*u64,
    out_bytes: ?*u64,
) callconv(.c) i32 {
    const h = decoder orelse return 1;
    const progress = h.decoder.limit_progress orelse return 1;
    if (out_offset) |p| p.* = progress.offset;
    if (out_ifd_index) |p| p.* = progress.ifd_index;
    if (out_bytes) |p| p.* = progress.bytes;
    return 0;
}

export fn tiffz_facsimile_rows(decoder: ?*const Handle, out_rows: ?*u32) callconv(.c) i32 {
    const h = decoder orelse return 1;
    const rows = h.decoder.facsimile_rows orelse return 1;
    if (out_rows) |p| p.* = rows;
    return 0;
}

export fn tiffz_discrepancy(
    decoder: ?*const Handle,
    out_class: ?*i32,
    out_offset: ?*u64,
    out_offset_known: ?*i32,
    out_type: ?*[*:0]const u8,
) callconv(.c) i32 {
    const h = decoder orelse return 1;
    const found = h.decoder.discrepancy orelse return 1;
    if (out_class) |p| p.* = @intFromEnum(found.class);
    if (out_offset_known) |p| p.* = if (found.offset != null) 1 else 0;
    if (out_offset) |p| p.* = found.offset orelse 0;
    if (out_type) |p| p.* = found.type_name.ptr;
    return 0;
}

export fn tiffz_last_error_message(decoder: ?*const Handle) callconv(.c) [*:0]const u8 {
    const h = decoder orelse return "";
    if (h.last_message_len == 0) return "";
    return @ptrCast(&h.last_message);
}

export fn tiffz_set_finding_callback(
    decoder: ?*Handle,
    callback: findings_mod.Callback,
    userdata: ?*anyopaque,
) callconv(.c) void {
    const h = decoder orelse return;
    h.decoder.setFindingCallback(callback, userdata);
}

export fn tiffz_decode_rgba(
    decoder: ?*Handle,
    ifd_index: usize,
    out_pixels: ?*?[*]u8,
    out_width: ?*u32,
    out_height: ?*u32,
) callconv(.c) i32 {
    const h = decoder orelse return 1;
    const pixels_slot = out_pixels orelse return 1;
    const w_slot = out_width orelse return 1;
    const h_slot = out_height orelse return 1;
    const img = rgba_mod.decodeIfdToRgba(std.heap.c_allocator, &h.decoder, &h.workspace, ifd_index) catch |err| {
        return storeError(h, err);
    };
    pixels_slot.* = img.pixels.ptr;
    w_slot.* = img.width;
    h_slot.* = img.height;
    return 0;
}

/// tiffz_decode_rgba with straight alpha: associated (premultiplied) alpha
/// is divided out. Same ownership and status contract.
export fn tiffz_decode_rgba_straight(
    decoder: ?*Handle,
    ifd_index: usize,
    out_pixels: ?*?[*]u8,
    out_width: ?*u32,
    out_height: ?*u32,
) callconv(.c) i32 {
    const h = decoder orelse return 1;
    const pixels_slot = out_pixels orelse return 1;
    const w_slot = out_width orelse return 1;
    const h_slot = out_height orelse return 1;
    const img = rgba_mod.decodeIfdToStraightRgba(std.heap.c_allocator, &h.decoder, &h.workspace, ifd_index) catch |err| {
        return storeError(h, err);
    };
    pixels_slot.* = img.pixels.ptr;
    w_slot.* = img.width;
    h_slot.* = img.height;
    return 0;
}

/// Encode packed 8-bit pixels as a baseline TIFF (see writer.zig). On
/// success `*out` holds `*out_len` bytes the caller frees with tiffz_free;
/// on any failure they are NULL and 0.
export fn tiffz_encode(
    pixels: ?[*]const u8,
    pixels_len: usize,
    width: u32,
    height: u32,
    channels: u32,
    compression: u32,
    out: ?*?[*]u8,
    out_len: ?*usize,
) callconv(.c) i32 {
    const out_slot = out orelse return 1;
    const len_slot = out_len orelse return 1;
    out_slot.* = null;
    len_slot.* = 0;
    const src = pixels orelse return 1;
    const ch: writer.Channels = switch (channels) {
        1 => .gray,
        3 => .rgb,
        4 => .rgba,
        else => return 1,
    };
    const comp: writer.Compression = switch (compression) {
        1 => .none,
        5 => .lzw,
        8 => .deflate,
        else => return statusFromError(error.UnsupportedCompression),
    };
    const bytes = writer.encode(std.heap.c_allocator, src[0..pixels_len], width, height, ch, comp) catch |err| {
        return statusFromError(err);
    };
    out_slot.* = bytes.ptr;
    len_slot.* = bytes.len;
    return 0;
}

export fn tiffz_free(ptr: ?*anyopaque, len: usize) callconv(.c) void {
    if (ptr == null or len == 0) return;
    const p: [*]u8 = @ptrCast(ptr);
    std.heap.c_allocator.free(p[0..len]);
}

test "tiffz_version returns the version string" {
    const ptr = tiffz_version();
    const s = std.mem.span(ptr);
    try std.testing.expectEqualStrings(version.string, s);
}

test "statusFromError covers every Error variant in declaration order" {
    const values = [_]errors.Error{
        error.InvalidArgument,
        error.Malformed,
        error.UnsupportedCompression,
        error.UnsupportedPhotometric,
        error.UnsupportedPredictor,
        error.UnsupportedBitDepth,
        error.UnsupportedTagType,
        error.SourceSeekTooFarBack,
        error.SourceShortRead,
        error.SourceTooShort,
        error.LimitExceededIfdCount,
        error.LimitExceededTagCount,
        error.LimitExceededTagValueBytes,
        error.LimitExceededStripCount,
        error.LimitExceededDimension,
        error.LimitExceededTotalSamples,
        error.LimitExceededCodecScratch,
        error.LimitExceededCompressedStripBytes,
        error.LimitExceededDecompressedStripBytes,
        error.DestTooSmall,
        error.OutOfMemory,
        error.Io,
        error.Bug,
        error.IfdChainCycle,
        error.JpegInTiffPayload,
        error.EndOfFacsimileBlock,
        error.LimitExceededIfdDepth,
        error.LimitExceededBytesVisited,
    };
    for (values, 1..) |err, i| {
        try std.testing.expectEqual(@as(i32, @intCast(i)), statusFromError(err));
    }
    try std.testing.expectEqualStrings("Malformed", std.mem.span(tiffz_status_name(2)));
}

test "tiffz_open_from_buffer rejects an empty buffer" {
    var status: i32 = -1;
    const d = tiffz_open_from_buffer(null, 0, &status);
    try std.testing.expect(d == null);
    try std.testing.expect(status != 0);
}

test "tiffz_validate: a dimension cap is status 15, not Malformed" {
    var buf: [87]u8 = @splat(0);
    buf[0] = 'I';
    buf[1] = 'I';
    std.mem.writeInt(u16, buf[2..4], 42, .little);
    std.mem.writeInt(u32, buf[4..8], 8, .little);
    std.mem.writeInt(u16, buf[8..10], 6, .little);
    const entries = [_]struct { tag: u16, typ: u16, val: u32 }{
        .{ .tag = 256, .typ = 4, .val = (1 << 30) + 1 },
        .{ .tag = 257, .typ = 3, .val = 1 },
        .{ .tag = 258, .typ = 3, .val = 8 },
        .{ .tag = 259, .typ = 3, .val = 1 },
        .{ .tag = 273, .typ = 4, .val = 86 },
        .{ .tag = 279, .typ = 4, .val = 1 },
    };
    for (entries, 0..) |entry, i| {
        const at = 10 + i * 12;
        std.mem.writeInt(u16, buf[at..][0..2], entry.tag, .little);
        std.mem.writeInt(u16, buf[at + 2 ..][0..2], entry.typ, .little);
        std.mem.writeInt(u32, buf[at + 4 ..][0..4], 1, .little);
        std.mem.writeInt(u32, buf[at + 8 ..][0..4], entry.val, .little);
    }
    buf[86] = 0x5A;
    var status: i32 = -1;
    const bytes: []const u8 = &buf;
    const dec = tiffz_open_from_buffer(bytes.ptr, bytes.len, &status);
    try std.testing.expectEqual(@as(i32, 0), status);
    try std.testing.expect(dec != null);
    defer tiffz_close(dec);
    const verdict = tiffz_validate(dec.?);
    try std.testing.expectEqual(@as(i32, 15), verdict);
    try std.testing.expect(verdict != 2);
    var offset: u64 = 0;
    var ifd_index: u64 = 99;
    var visited: u64 = 0;
    try std.testing.expectEqual(@as(i32, 0), tiffz_limit_progress(dec.?, &offset, &ifd_index, &visited));
    try std.testing.expectEqual(@as(i32, 1), tiffz_discrepancy(dec.?, null, null, null, null));
    try std.testing.expect(visited > 0);
    try std.testing.expectEqual(@as(u64, 0), ifd_index);
}

test "limit statuses are exactly the LimitExceeded errors, and EOFB is not one" {
    const values = [_]errors.Error{
        error.InvalidArgument,
        error.Malformed,
        error.UnsupportedCompression,
        error.UnsupportedPhotometric,
        error.UnsupportedPredictor,
        error.UnsupportedBitDepth,
        error.UnsupportedTagType,
        error.SourceSeekTooFarBack,
        error.SourceShortRead,
        error.SourceTooShort,
        error.LimitExceededIfdCount,
        error.LimitExceededTagCount,
        error.LimitExceededTagValueBytes,
        error.LimitExceededStripCount,
        error.LimitExceededDimension,
        error.LimitExceededTotalSamples,
        error.LimitExceededCodecScratch,
        error.LimitExceededCompressedStripBytes,
        error.LimitExceededDecompressedStripBytes,
        error.DestTooSmall,
        error.OutOfMemory,
        error.Io,
        error.Bug,
        error.IfdChainCycle,
        error.JpegInTiffPayload,
        error.EndOfFacsimileBlock,
        error.LimitExceededIfdDepth,
        error.LimitExceededBytesVisited,
    };
    for (values) |err| {
        const status = statusFromError(err);
        const limit = std.mem.startsWith(u8, @errorName(err), "LimitExceeded");
        try std.testing.expectEqual(limit, tiffz_status_is_limit(status) == 1);
    }
    try std.testing.expectEqual(@as(i32, 26), statusFromError(error.EndOfFacsimileBlock));
    try std.testing.expectEqual(@as(i32, 27), statusFromError(error.LimitExceededIfdDepth));
    try std.testing.expectEqual(@as(i32, 28), statusFromError(error.LimitExceededBytesVisited));
}

test "tiffz_open_from_buffer + validate accepts a clean RGB TIFF" {
    const io = std.testing.io;
    const file = try std.Io.Dir.cwd().openFile(io, "tests/fixtures/uncompressed/rgb-3c-8b.tiff", .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try std.testing.allocator.alloc(u8, @intCast(stat.size));
    defer std.testing.allocator.free(buf);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    try reader.interface.readSliceAll(buf);

    var status: i32 = -1;
    const d = tiffz_open_from_buffer(buf.ptr, buf.len, &status);
    try std.testing.expectEqual(@as(i32, 0), status);
    try std.testing.expect(d != null);
    defer tiffz_close(d);
    try std.testing.expectEqual(@as(i32, 0), tiffz_validate(d.?));
    try std.testing.expect(tiffz_ifd_count(d.?) >= 1);
}

test "tiffz_encode output reopens and decodes to the same RGBA" {
    const px = [_]u8{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120 };
    inline for (.{ 1, 5, 8 }) |compression| {
        var out: ?[*]u8 = null;
        var out_len: usize = 0;
        try std.testing.expectEqual(@as(i32, 0), tiffz_encode(&px, px.len, 3, 1, 4, compression, &out, &out_len));
        try std.testing.expect(out != null and out_len > 8);
        defer tiffz_free(out, out_len);

        var status: i32 = -1;
        const d = tiffz_open_from_buffer(out, out_len, &status);
        try std.testing.expectEqual(@as(i32, 0), status);
        defer tiffz_close(d);
        try std.testing.expectEqual(@as(i32, 0), tiffz_validate(d.?));
        var pixels: ?[*]u8 = null;
        var w: u32 = 0;
        var h: u32 = 0;
        try std.testing.expectEqual(@as(i32, 0), tiffz_decode_rgba(d, 0, &pixels, &w, &h));
        defer tiffz_free(pixels, @as(usize, w) * h * 4);
        try std.testing.expectEqual(@as(u32, 3), w);
        try std.testing.expectEqual(@as(u32, 1), h);
        try std.testing.expectEqualSlices(u8, &px, pixels.?[0..12]);
    }
}

test "tiffz_encode refuses bad arguments and leaves no output" {
    const px = [_]u8{0} ** 12;
    var out: ?[*]u8 = @constCast(&px);
    var out_len: usize = 99;
    // channels 2 is not gray, RGB or RGBA
    try std.testing.expectEqual(@as(i32, 1), tiffz_encode(&px, px.len, 2, 1, 2, 1, &out, &out_len));
    try std.testing.expect(out == null and out_len == 0);
    // compression 7 (JPEG) is not writable
    try std.testing.expectEqual(@as(i32, 3), tiffz_encode(&px, px.len, 4, 1, 3, 7, &out, &out_len));
    // pixel byte count must equal width * height * channels
    try std.testing.expectEqual(@as(i32, 1), tiffz_encode(&px, 11, 4, 1, 3, 1, &out, &out_len));
    try std.testing.expectEqual(@as(i32, 1), tiffz_encode(null, 12, 4, 1, 3, 1, &out, &out_len));
    try std.testing.expectEqual(@as(i32, 1), tiffz_encode(&px, px.len, 4, 1, 3, 1, null, &out_len));
    try std.testing.expectEqual(@as(i32, 1), tiffz_encode(&px, px.len, 4, 1, 3, 1, &out, null));
    try std.testing.expectEqual(@as(i32, 1), tiffz_encode(&px, px.len, 0, 1, 3, 1, &out, &out_len));
    try std.testing.expect(out == null and out_len == 0);
}

fn readFixture(path: []const u8) ![]u8 {
    const io = std.testing.io;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try std.testing.allocator.alloc(u8, @intCast(stat.size));
    errdefer std.testing.allocator.free(buf);
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    try reader.interface.readSliceAll(buf);
    return buf;
}

test "tiffz_decode_rgba_straight un-premultiplies associated alpha only" {
    // strike.tif declares ExtraSamples = 1 (associated alpha).
    const buf = try readFixture("tests/fixtures/lzw/strike.tif");
    defer std.testing.allocator.free(buf);
    var status: i32 = -1;
    const d = tiffz_open_from_buffer(buf.ptr, buf.len, &status);
    defer tiffz_close(d);
    var pre: ?[*]u8 = null;
    var straight: ?[*]u8 = null;
    var w: u32 = 0;
    var h: u32 = 0;
    try std.testing.expectEqual(@as(i32, 0), tiffz_decode_rgba(d, 0, &pre, &w, &h));
    const n = @as(usize, w) * h * 4;
    defer tiffz_free(pre, n);
    try std.testing.expectEqual(@as(i32, 0), tiffz_decode_rgba_straight(d, 0, &straight, &w, &h));
    defer tiffz_free(straight, n);
    var changed: usize = 0;
    var i: usize = 0;
    while (i < n) : (i += 4) {
        const a = pre.?[i + 3];
        try std.testing.expectEqual(a, straight.?[i + 3]);
        for (0..3) |k| {
            const p = pre.?[i + k];
            const s = straight.?[i + k];
            if (a == 0) {
                try std.testing.expectEqual(@as(u8, 0), s);
            } else if (p > a) {
                // Not valid premultiplied data; the straight value saturates.
                try std.testing.expectEqual(@as(u8, 255), s);
            } else {
                // Re-premultiplying the straight value recovers the stored one.
                const back = (@as(u32, s) * a + 127) / 255;
                try std.testing.expect(@abs(@as(i32, @intCast(back)) - @as(i32, p)) <= 1);
                if (s != p) changed += 1;
            }
        }
    }
    try std.testing.expect(changed > 0);

    // Without associated alpha the two calls agree byte for byte.
    const rgb = try readFixture("tests/fixtures/uncompressed/rgb-3c-8b.tiff");
    defer std.testing.allocator.free(rgb);
    const d2 = tiffz_open_from_buffer(rgb.ptr, rgb.len, &status);
    defer tiffz_close(d2);
    var pre2: ?[*]u8 = null;
    var straight2: ?[*]u8 = null;
    try std.testing.expectEqual(@as(i32, 0), tiffz_decode_rgba(d2, 0, &pre2, &w, &h));
    const n2 = @as(usize, w) * h * 4;
    defer tiffz_free(pre2, n2);
    try std.testing.expectEqual(@as(i32, 0), tiffz_decode_rgba_straight(d2, 0, &straight2, &w, &h));
    defer tiffz_free(straight2, n2);
    try std.testing.expectEqualSlices(u8, pre2.?[0..n2], straight2.?[0..n2]);
}
