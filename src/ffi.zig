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
