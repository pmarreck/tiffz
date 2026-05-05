//! Seekable byte-source abstraction. tiffz never opens files —
//! consumers pass a Source. Pread-style `read_at(buf, offset)` +
//! `size()` is the foundation; all four access patterns (validate /
//! pipeline / random / eager) build on this.
//!
//! Thread safety: read_at MUST be safe to call concurrently from
//! multiple threads. fromFile (pread) is. fromMmap is. fromBuffer
//! is (read-only against immutable bytes). fromBufferedReader is NOT
//! — single-threaded only by contract.

const std = @import("std");

pub const Source = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Read into buf starting at byte `offset`. Returns bytes
        /// read. Short reads at EOF allowed; reads past end return 0.
        read_at: *const fn (ctx: *anyopaque, buf: []u8, offset: u64) anyerror!usize,
        /// Total size of the source, in bytes.
        size: *const fn (ctx: *anyopaque) anyerror!u64,
    };

    pub fn readAt(self: Source, buf: []u8, offset: u64) anyerror!usize {
        return self.vtable.read_at(self.ctx, buf, offset);
    }

    pub fn sizeOf(self: Source) anyerror!u64 {
        return self.vtable.size(self.ctx);
    }

    /// Wrap an immutable byte slice as a Source. The handle and the
    /// slice it points at must outlive the Source. No allocation.
    pub fn fromBuffer(handle: *const BufferHandle) Source {
        return .{
            .ctx = @constCast(@ptrCast(handle)),
            .vtable = &buffer_vtable,
        };
    }
};

/// Caller-managed handle wrapping a byte slice for fromBuffer.
/// The bytes themselves are not owned — caller keeps the underlying
/// memory alive for the Source's lifetime.
pub const BufferHandle = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) BufferHandle {
        return .{ .bytes = bytes };
    }
};

const buffer_vtable: Source.VTable = .{
    .read_at = bufferReadAt,
    .size = bufferSize,
};

fn bufferReadAt(ctx: *anyopaque, dst: []u8, offset: u64) anyerror!usize {
    const handle: *const BufferHandle = @ptrCast(@alignCast(ctx));
    const bytes = handle.bytes;
    if (offset >= bytes.len) return 0;
    const start: usize = @intCast(offset);
    const remaining = bytes.len - start;
    const n = @min(dst.len, remaining);
    @memcpy(dst[0..n], bytes[start..][0..n]);
    return n;
}

fn bufferSize(ctx: *anyopaque) anyerror!u64 {
    const handle: *const BufferHandle = @ptrCast(@alignCast(ctx));
    return @intCast(handle.bytes.len);
}

test "Source type compiles" {
    _ = Source;
    _ = Source.VTable;
}

test "fromBuffer: size matches the underlying slice length" {
    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x42 };
    var handle = BufferHandle.init(&data);
    const src = Source.fromBuffer(&handle);
    try std.testing.expectEqual(@as(u64, 5), try src.sizeOf());
}

test "fromBuffer: full read at offset 0" {
    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x42 };
    var handle = BufferHandle.init(&data);
    const src = Source.fromBuffer(&handle);

    var dst: [5]u8 = undefined;
    const n = try src.readAt(&dst, 0);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualSlices(u8, &data, &dst);
}

test "fromBuffer: partial read in the middle" {
    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x42 };
    var handle = BufferHandle.init(&data);
    const src = Source.fromBuffer(&handle);

    var dst: [2]u8 = undefined;
    const n = try src.readAt(&dst, 1);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u8, 0xAD), dst[0]);
    try std.testing.expectEqual(@as(u8, 0xBE), dst[1]);
}

test "fromBuffer: short read at EOF returns truncated count" {
    const data = [_]u8{ 0x01, 0x02, 0x03 };
    var handle = BufferHandle.init(&data);
    const src = Source.fromBuffer(&handle);

    var dst: [10]u8 = undefined;
    const n = try src.readAt(&dst, 1);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u8, 0x02), dst[0]);
    try std.testing.expectEqual(@as(u8, 0x03), dst[1]);
}

test "fromBuffer: read past end returns 0" {
    const data = [_]u8{ 0x01, 0x02, 0x03 };
    var handle = BufferHandle.init(&data);
    const src = Source.fromBuffer(&handle);

    var dst: [4]u8 = undefined;
    const n = try src.readAt(&dst, 100);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "fromBuffer: empty slice has zero size and reads return zero" {
    const data = [_]u8{};
    var handle = BufferHandle.init(&data);
    const src = Source.fromBuffer(&handle);

    try std.testing.expectEqual(@as(u64, 0), try src.sizeOf());

    var dst: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try src.readAt(&dst, 0));
}
