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

    /// Wrap a sequential-reader + sliding-cache as a Source. The
    /// `BufferedReaderHandle` owns the cache buffer (caller-supplied,
    /// typically 1–8 MiB). Reads forward through the underlying reader
    /// as needed; reads inside the cache window are served without
    /// touching the reader. Reads to offsets before the cache window
    /// fail with `error.SourceSeekTooFarBack` — single-threaded only.
    ///
    /// **Cache-sizing guidance.** Out-of-line IFD tag values are
    /// eagerly cached on the `Ifd` at parse time (see
    /// `Ifd.parse`), so subsequent per-strip lookups don't round-trip
    /// the Source. That leaves two file-layout concerns:
    ///
    /// 1. **IFD-at-start (libtiff default for most writers):** the
    ///    IFD entries + all out-of-line tag values live near the
    ///    beginning of the file, strip data follows. After parse,
    ///    streaming forward through strip data is monotone — even a
    ///    1 MiB cache works for arbitrarily large files.
    ///
    /// 2. **IFD-at-end (GraphicsMagick / some other writers):** the
    ///    IFD lives at the end of the file with tag values just
    ///    before, and strip data fills the bulk of the bytes in
    ///    between. Streaming through such a file means reading all
    ///    the strip data first (to advance the source position to
    ///    the IFD), then parsing the IFD reads tag values
    ///    *backward* into the strip region — a sliding window
    ///    smaller than the strip-data span will fail with
    ///    `error.SourceSeekTooFarBack`. For these files the cache
    ///    must span at least `[start of strip data, end of IFD]`
    ///    — typically the whole file. Use `Source.fromBuffer` (or
    ///    a memory-mapped source) when the reader is genuinely
    ///    streaming and the file is large + IFD-at-end.
    pub fn fromBufferedReader(handle: *BufferedReaderHandle) Source {
        return .{
            .ctx = @ptrCast(handle),
            .vtable = &buffered_reader_vtable,
        };
    }

    /// Wrap an existing Source as a bounded, base-offset sub-view over
    /// `[base, base+len)`, presented to tiffz as a self-contained 0-based
    /// source of `len` bytes. Intended for validating a TIFF stream embedded
    /// inside a larger host file (a DNG/RAW preview, a container payload)
    /// **without copying** the embedded bytes: the caller keeps one Source over
    /// the whole host file and hands tiffz a sub-range. TIFF's own offsets are
    /// stream-relative (byte 0 = the II/MM header), so a 0-based view is exactly
    /// what the decoder expects. Reads are clamped to the sub-range — a read
    /// that would spill past `base+len` is truncated, so host bytes outside the
    /// declared window can never be surfaced through this view. The inner Source
    /// and the handle must outlive the returned Source; no allocation. Thread
    /// safety follows the inner Source.
    pub fn fromSubrange(handle: *const SubSourceHandle) Source {
        return .{
            .ctx = @constCast(@ptrCast(handle)),
            .vtable = &subsource_vtable,
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

/// Caller-managed handle for `Source.fromSubrange`: a bounded, base-offset
/// window `[base, base+len)` over an inner Source. Neither the inner Source
/// nor its backing bytes are owned — the caller keeps both alive for the
/// sub-view's lifetime.
pub const SubSourceHandle = struct {
    inner: *const Source,
    base: u64,
    len: u64,

    pub fn init(inner: *const Source, base: u64, len: u64) SubSourceHandle {
        return .{ .inner = inner, .base = base, .len = len };
    }
};

const subsource_vtable: Source.VTable = .{
    .read_at = subSourceReadAt,
    .size = subSourceSize,
};

/// Translate a 0-based sub-view read to the inner Source at `base + offset`,
/// clamping the length so the request can never read past `base + len`. Offsets
/// at or beyond `len` return 0 (short read), matching the whole-source EOF
/// convention — the sub-range boundary is enforced here, not delegated to the
/// inner Source (whose size may be far larger).
fn subSourceReadAt(ctx: *anyopaque, dst: []u8, offset: u64) anyerror!usize {
    const handle: *const SubSourceHandle = @ptrCast(@alignCast(ctx));
    if (offset >= handle.len) return 0;
    const remaining: u64 = handle.len - offset;
    const want: usize = @intCast(@min(@as(u64, dst.len), remaining));
    return handle.inner.readAt(dst[0..want], handle.base + offset);
}

fn subSourceSize(ctx: *anyopaque) anyerror!u64 {
    const handle: *const SubSourceHandle = @ptrCast(@alignCast(ctx));
    return handle.len;
}

/// Sentinel error for back-seek beyond the cache window. Re-export of
/// errors.SourceSeekTooFarBack via Source.read_at's `anyerror` channel.
const SourceSeekTooFarBack = error.SourceSeekTooFarBack;

/// Caller-managed handle wrapping a sequential reader + sliding cache
/// for `fromBufferedReader`. The cache buffer slice is owned by the
/// caller and must outlive the Source.
pub const BufferedReaderHandle = struct {
    /// Underlying reader. `read_fn(ctx, buf)` fills `buf` with the
    /// next sequential bytes and returns how many were read. Short
    /// reads allowed; 0 means EOF.
    reader_ctx: *anyopaque,
    read_fn: *const fn (ctx: *anyopaque, buf: []u8) anyerror!usize,

    /// Pre-declared total source size in bytes — caller knows this
    /// from out-of-band metadata (Content-Length, file stat, etc.).
    total_size: u64,

    /// Caller-allocated cache buffer. Length defines the cache window.
    /// The design doc recommends 8 MiB for typical TIFF layouts; 1 MiB
    /// also works for tiles that comfortably fit.
    cache_buf: []u8,
    /// File offset of `cache_buf[0]`. Reads at offsets < cache_start
    /// fail with SourceSeekTooFarBack.
    cache_start: u64,
    /// How much of `cache_buf` is currently filled. The cache window
    /// covers `[cache_start, cache_start + cache_len)`.
    cache_len: usize,
    /// True after the underlying reader returned 0 (EOF).
    eof: bool,

    pub fn init(
        reader_ctx: *anyopaque,
        read_fn: *const fn (ctx: *anyopaque, buf: []u8) anyerror!usize,
        total_size: u64,
        cache_buf: []u8,
    ) BufferedReaderHandle {
        return .{
            .reader_ctx = reader_ctx,
            .read_fn = read_fn,
            .total_size = total_size,
            .cache_buf = cache_buf,
            .cache_start = 0,
            .cache_len = 0,
            .eof = false,
        };
    }

    /// Pull more bytes from the reader, sliding the cache window
    /// forward if the cache is full. Returns the number of bytes
    /// freshly buffered (0 if EOF reached).
    fn refill(self: *BufferedReaderHandle) anyerror!usize {
        if (self.eof) return 0;
        if (self.cache_len == self.cache_buf.len) {
            // Cache full — slide forward by half the cache so we
            // amortize the memmove cost across multiple subsequent
            // refills rather than memmove-ing one byte per pull.
            const slide: usize = self.cache_buf.len / 2;
            std.mem.copyForwards(
                u8,
                self.cache_buf[0 .. self.cache_buf.len - slide],
                self.cache_buf[slide..],
            );
            self.cache_start += slide;
            self.cache_len -= slide;
        }
        const free_space = self.cache_buf.len - self.cache_len;
        const n = try self.read_fn(self.reader_ctx, self.cache_buf[self.cache_len .. self.cache_len + free_space]);
        if (n == 0) {
            self.eof = true;
            return 0;
        }
        self.cache_len += n;
        return n;
    }
};

const buffered_reader_vtable: Source.VTable = .{
    .read_at = bufferedReaderReadAt,
    .size = bufferedReaderSize,
};

fn bufferedReaderSize(ctx: *anyopaque) anyerror!u64 {
    const handle: *const BufferedReaderHandle = @ptrCast(@alignCast(ctx));
    return handle.total_size;
}

fn bufferedReaderReadAt(ctx: *anyopaque, dst: []u8, offset: u64) anyerror!usize {
    const handle: *BufferedReaderHandle = @ptrCast(@alignCast(ctx));

    // Past end of source — return 0 (short read).
    if (offset >= handle.total_size) return 0;
    // Before cache window — caller asked us to seek backwards beyond
    // what we've kept. Surface as an error so the caller can decide
    // (re-open the source, bump the cache size, etc.). This is the
    // single foot-gun the design doc warned about; the cache size
    // should be picked to make this case rare for the workload.
    if (offset < handle.cache_start) return SourceSeekTooFarBack;

    // Clamp the request to the known end of the source.
    const remaining_in_source: u64 = handle.total_size - offset;
    const want: usize = @intCast(@min(@as(u64, dst.len), remaining_in_source));

    var copied: usize = 0;
    while (copied < want) {
        const cur_offset: u64 = offset + copied;
        const cache_end: u64 = handle.cache_start + handle.cache_len;
        if (cur_offset >= cache_end) {
            // Need to pull from the reader.
            const got = try handle.refill();
            if (got == 0) break; // EOF before request fulfilled
            continue;
        }
        const in_cache_off: usize = @intCast(cur_offset - handle.cache_start);
        const avail_in_cache: usize = handle.cache_len - in_cache_off;
        const to_copy: usize = @min(want - copied, avail_in_cache);
        @memcpy(dst[copied .. copied + to_copy], handle.cache_buf[in_cache_off .. in_cache_off + to_copy]);
        copied += to_copy;
    }
    return copied;
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

// ---- fromSubrange (bounded sub-source / base-offset view) tests ----

test "fromSubrange: classifier over base translation, length clamp, and escape" {
    // Inner is 0..15. The sub-range view [base=4, len=8] must present as a
    // self-contained 0-based source of exactly 8 bytes covering inner[4..12].
    var inner_data: [16]u8 = undefined;
    for (&inner_data, 0..) |*b, i| b.* = @intCast(i);
    var inner_handle = BufferHandle.init(&inner_data);
    const inner = Source.fromBuffer(&inner_handle);

    var sub_handle = SubSourceHandle.init(&inner, 4, 8);
    const sub = Source.fromSubrange(&sub_handle);

    // sizeOf reports the sub-range length, not the inner size.
    try std.testing.expectEqual(@as(u64, 8), try sub.sizeOf());

    // Full read maps 0-based offset onto base: sub[0..8] == inner[4..12].
    var d8: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), try sub.readAt(&d8, 0));
    try std.testing.expectEqualSlices(u8, inner_data[4..12], &d8);

    // Partial read at sub-offset 0.
    var d4: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try sub.readAt(&d4, 0));
    try std.testing.expectEqualSlices(u8, inner_data[4..8], &d4);

    // Read near the end clamps to the sub-range: sub-offset 6, want 8 -> 2.
    var dtail: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try sub.readAt(&dtail, 6));
    try std.testing.expectEqualSlices(u8, inner_data[10..12], dtail[0..2]);

    // ESCAPE CHECK (the point of the type): inner HAS bytes at [12..16], but a
    // read that would spill past base+len must never surface them. A big read
    // straddling the boundary from sub-offset 4 returns only inner[8..12].
    var dbig: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try sub.readAt(&dbig, 4));
    try std.testing.expectEqualSlices(u8, inner_data[8..12], dbig[0..4]);

    // At/after the sub-range end -> 0 (short read, not an inner read).
    try std.testing.expectEqual(@as(usize, 0), try sub.readAt(&d8, 8));
    try std.testing.expectEqual(@as(usize, 0), try sub.readAt(&d8, 100));
}

test "fromSubrange: base 0 full-length view is transparent over the inner source" {
    const inner_data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x42 };
    var inner_handle = BufferHandle.init(&inner_data);
    const inner = Source.fromBuffer(&inner_handle);

    var sub_handle = SubSourceHandle.init(&inner, 0, inner_data.len);
    const sub = Source.fromSubrange(&sub_handle);

    try std.testing.expectEqual(@as(u64, 5), try sub.sizeOf());
    var d: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), try sub.readAt(&d, 0));
    try std.testing.expectEqualSlices(u8, &inner_data, &d);
}

test "fromSubrange: declared len past the inner end short-reads, never over-reads" {
    // len=20 declared, but inner only has bytes [8..16] = 8 available.
    var inner_data: [16]u8 = undefined;
    for (&inner_data, 0..) |*b, i| b.* = @intCast(i);
    var inner_handle = BufferHandle.init(&inner_data);
    const inner = Source.fromBuffer(&inner_handle);

    var sub_handle = SubSourceHandle.init(&inner, 8, 20);
    const sub = Source.fromSubrange(&sub_handle);

    // sizeOf trusts the caller's declared length...
    try std.testing.expectEqual(@as(u64, 20), try sub.sizeOf());
    // ...but a read can only ever yield what the inner actually holds.
    var d: [20]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), try sub.readAt(&d, 0));
    try std.testing.expectEqualSlices(u8, inner_data[8..16], d[0..8]);
}

// ---- fromBufferedReader tests ----

/// Helper: a sequential reader backed by a fixed byte slice. Mimics
/// a streaming source whose total length is known up front (the
/// typical TIFF-over-network or TIFF-from-file shape).
const SliceReader = struct {
    bytes: []const u8,
    pos: usize,

    fn readFn(ctx: *anyopaque, buf: []u8) anyerror!usize {
        const self: *SliceReader = @ptrCast(@alignCast(ctx));
        const remaining = self.bytes.len - self.pos;
        const n = @min(buf.len, remaining);
        @memcpy(buf[0..n], self.bytes[self.pos .. self.pos + n]);
        self.pos += n;
        return n;
    }
};

test "fromBufferedReader: size matches declared total" {
    const data = [_]u8{ 1, 2, 3, 4, 5 };
    var reader = SliceReader{ .bytes = &data, .pos = 0 };
    var cache: [16]u8 = undefined;
    var handle = BufferedReaderHandle.init(@ptrCast(&reader), &SliceReader.readFn, data.len, &cache);
    const src = Source.fromBufferedReader(&handle);
    try std.testing.expectEqual(@as(u64, 5), try src.sizeOf());
}

test "fromBufferedReader: sequential forward read fills via reader" {
    var data: [128]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i);
    var reader = SliceReader{ .bytes = &data, .pos = 0 };
    var cache: [32]u8 = undefined;
    var handle = BufferedReaderHandle.init(@ptrCast(&reader), &SliceReader.readFn, data.len, &cache);
    const src = Source.fromBufferedReader(&handle);

    var dst: [16]u8 = undefined;
    const n = try src.readAt(&dst, 0);
    try std.testing.expectEqual(@as(usize, 16), n);
    try std.testing.expectEqualSlices(u8, data[0..16], &dst);
}

test "fromBufferedReader: forward seek beyond cache window slides forward" {
    var data: [1024]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    var reader = SliceReader{ .bytes = &data, .pos = 0 };
    var cache: [64]u8 = undefined; // small cache to force sliding
    var handle = BufferedReaderHandle.init(@ptrCast(&reader), &SliceReader.readFn, data.len, &cache);
    const src = Source.fromBufferedReader(&handle);

    // Jump to offset 500 — well past the 64-byte cache window.
    var dst: [8]u8 = undefined;
    const n = try src.readAt(&dst, 500);
    try std.testing.expectEqual(@as(usize, 8), n);
    try std.testing.expectEqualSlices(u8, data[500..508], &dst);
}

test "fromBufferedReader: read inside cache window doesn't advance the reader" {
    var data: [64]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i);
    var reader = SliceReader{ .bytes = &data, .pos = 0 };
    var cache: [32]u8 = undefined;
    var handle = BufferedReaderHandle.init(@ptrCast(&reader), &SliceReader.readFn, data.len, &cache);
    const src = Source.fromBufferedReader(&handle);

    // First read at offset 0 — pulls 32 bytes into cache.
    var dst1: [16]u8 = undefined;
    _ = try src.readAt(&dst1, 0);
    const reader_pos_after_first = reader.pos;

    // Second read at offset 5 — stays inside cache window.
    var dst2: [8]u8 = undefined;
    const n2 = try src.readAt(&dst2, 5);
    try std.testing.expectEqual(@as(usize, 8), n2);
    try std.testing.expectEqualSlices(u8, data[5..13], &dst2);
    // Reader position should be unchanged: no new pull required.
    try std.testing.expectEqual(reader_pos_after_first, reader.pos);
}

test "fromBufferedReader: back-seek inside cache window works" {
    var data: [256]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    var reader = SliceReader{ .bytes = &data, .pos = 0 };
    var cache: [128]u8 = undefined;
    var handle = BufferedReaderHandle.init(@ptrCast(&reader), &SliceReader.readFn, data.len, &cache);
    const src = Source.fromBufferedReader(&handle);

    var dst: [16]u8 = undefined;
    _ = try src.readAt(&dst, 80); // pulls bytes through 80+16=96
    // Back-seek to 50 — still inside [cache_start, cache_end).
    const n = try src.readAt(&dst, 50);
    try std.testing.expectEqual(@as(usize, 16), n);
    try std.testing.expectEqualSlices(u8, data[50..66], &dst);
}

test "fromBufferedReader: back-seek past cache start errors" {
    var data: [2048]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    var reader = SliceReader{ .bytes = &data, .pos = 0 };
    var cache: [64]u8 = undefined;
    var handle = BufferedReaderHandle.init(@ptrCast(&reader), &SliceReader.readFn, data.len, &cache);
    const src = Source.fromBufferedReader(&handle);

    var dst: [8]u8 = undefined;
    // Pull far forward — the cache has slid past offset 0.
    _ = try src.readAt(&dst, 1500);
    try std.testing.expect(handle.cache_start > 0);

    // Try to read at offset 0 → too far back.
    try std.testing.expectError(error.SourceSeekTooFarBack, src.readAt(&dst, 0));
}

test "fromBufferedReader: read past total_size returns short" {
    var data: [10]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i);
    var reader = SliceReader{ .bytes = &data, .pos = 0 };
    var cache: [32]u8 = undefined;
    var handle = BufferedReaderHandle.init(@ptrCast(&reader), &SliceReader.readFn, data.len, &cache);
    const src = Source.fromBufferedReader(&handle);

    var dst: [20]u8 = undefined;
    const n = try src.readAt(&dst, 5);
    try std.testing.expectEqual(@as(usize, 5), n); // only 5 bytes remain from offset 5
    try std.testing.expectEqualSlices(u8, data[5..10], dst[0..5]);

    // Read at exactly total_size → 0.
    const m = try src.readAt(&dst, 10);
    try std.testing.expectEqual(@as(usize, 0), m);
}

test "fromBufferedReader: request larger than cache iteratively slides" {
    var data: [256]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i & 0xFF);
    var reader = SliceReader{ .bytes = &data, .pos = 0 };
    var cache: [16]u8 = undefined; // tiny cache, request is bigger
    var handle = BufferedReaderHandle.init(@ptrCast(&reader), &SliceReader.readFn, data.len, &cache);
    const src = Source.fromBufferedReader(&handle);

    var dst: [200]u8 = undefined;
    const n = try src.readAt(&dst, 0);
    try std.testing.expectEqual(@as(usize, 200), n);
    try std.testing.expectEqualSlices(u8, data[0..200], &dst);
}
