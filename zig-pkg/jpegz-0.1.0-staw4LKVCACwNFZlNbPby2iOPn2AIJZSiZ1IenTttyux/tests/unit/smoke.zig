//! Phase-1 scaffold smoke tests. Proves wiring; the heavy decode
//! tests live in `tests/unit/decode.zig` (added at M1.3).

const std = @import("std");
const jpegz = @import("jpegz");

test "version is exposed" {
    try std.testing.expect(jpegz.version.len > 0);
    try std.testing.expectEqualStrings("0.1.0", jpegz.version);
}

test "decode rejects empty data" {
    const empty: []const u8 = &[_]u8{};
    try std.testing.expectError(
        error.TruncatedStream,
        jpegz.decode(std.testing.allocator, empty),
    );
}

test "jpeg2000.decode rejects empty data" {
    const empty: []const u8 = &[_]u8{};
    try std.testing.expectError(
        error.TruncatedStream,
        jpegz.jpeg2000.decode(std.testing.allocator, empty),
    );
}

test "validate empty input fails fast at missing_soi" {
    // Smoke: just confirms validate is wired and returns a freeable
    // report. Detailed scenarios live in tests/unit/validate.zig.
    const empty: []const u8 = &[_]u8{};
    var report = try jpegz.validate(std.testing.allocator, empty);
    defer report.deinit(std.testing.allocator);
    try std.testing.expectEqual(jpegz.Severity.fail, report.overall);
    try std.testing.expectEqual(jpegz.Variant.unknown, report.variant);
    try std.testing.expect(report.findings.items.len > 0);
}

// ── decodeStreamingRows tests ─────────────────────────────────────
//
// The streaming API materializes the full image internally (v1
// implementation strategy: re-use decode() then iterate). What
// callers depend on is the *shape*: callbacks fire in raster order,
// progressive scans get NotRowStreamable, and callback errors
// propagate as CallbackAborted. Each test asserts one of those
// invariants without depending on the internal materialization
// strategy — so a future per-decoder streaming implementation
// won't break the suite.

const fixture_baseline_2x2_rgb = @embedFile("fixtures/baseline_2x2_rgb.jpg");
const fixture_progressive_8x8_rgb = @embedFile("fixtures/progressive_8x8_rgb.jpg");
const fixture_lossless_4x4_gray8 = @embedFile("fixtures/lossless_4x4_gray8.jpg");
const fixture_jpegls_4x4_gray8 = @embedFile("fixtures/jpegls_4x4_gray8.jls");

/// Streaming callback that copies each row into a contiguous buffer
/// keyed by `y`. Lets the test assert raster order + content equals
/// `jpegz.decode()`'s output.
const RowCollector = struct {
    buf: []u8,
    row_stride: usize,
    rows_seen: u32,
    last_y: i32,
    in_order: bool,

    fn onRow(ctx_opaque: ?*anyopaque, row: []const u8, y: u32) anyerror!void {
        const self: *RowCollector = @ptrCast(@alignCast(ctx_opaque.?));
        @memcpy(self.buf[@as(usize, y) * self.row_stride ..][0..row.len], row);
        self.rows_seen += 1;
        if (@as(i32, @intCast(y)) <= self.last_y) self.in_order = false;
        self.last_y = @intCast(y);
    }
};

test "decodeStreamingRows: baseline JPEG streams rows matching decode()" {
    const allocator = std.testing.allocator;
    var ref = try jpegz.decode(allocator, fixture_baseline_2x2_rgb);
    defer ref.deinit(allocator);

    const buf = try allocator.alloc(u8, ref.pixels.len);
    defer allocator.free(buf);
    var collector = RowCollector{
        .buf = buf,
        .row_stride = ref.rowStride(),
        .rows_seen = 0,
        .last_y = -1,
        .in_order = true,
    };
    const meta = try jpegz.decodeStreamingRows(allocator, fixture_baseline_2x2_rgb, .{
        .on_row = RowCollector.onRow,
        .ctx = &collector,
    });

    try std.testing.expectEqual(ref.width, meta.width);
    try std.testing.expectEqual(ref.height, meta.height);
    try std.testing.expectEqual(ref.channels, meta.channels);
    try std.testing.expectEqual(ref.bits_per_sample, meta.bits_per_sample);
    try std.testing.expectEqual(ref.layout, meta.layout);
    try std.testing.expectEqual(@as(u32, ref.height), collector.rows_seen);
    try std.testing.expect(collector.in_order);
    try std.testing.expectEqualSlices(u8, ref.pixels, buf);
}

test "decodeStreamingRows: progressive JPEG returns NotRowStreamable" {
    const cb = jpegz.RowCallback{
        .on_row = struct {
            fn cb(_: ?*anyopaque, _: []const u8, _: u32) anyerror!void {}
        }.cb,
    };
    try std.testing.expectError(
        error.NotRowStreamable,
        jpegz.decodeStreamingRows(std.testing.allocator, fixture_progressive_8x8_rgb, cb),
    );
}

test "decodeStreamingRows: lossless SOF3 grayscale streams rows" {
    const allocator = std.testing.allocator;
    var ref = try jpegz.decode(allocator, fixture_lossless_4x4_gray8);
    defer ref.deinit(allocator);
    const buf = try allocator.alloc(u8, ref.pixels.len);
    defer allocator.free(buf);
    var collector = RowCollector{
        .buf = buf,
        .row_stride = ref.rowStride(),
        .rows_seen = 0,
        .last_y = -1,
        .in_order = true,
    };
    _ = try jpegz.decodeStreamingRows(allocator, fixture_lossless_4x4_gray8, .{
        .on_row = RowCollector.onRow,
        .ctx = &collector,
    });
    try std.testing.expectEqual(@as(u32, 4), collector.rows_seen);
    try std.testing.expectEqualSlices(u8, ref.pixels, buf);
}

test "decodeStreamingRows: JPEG-LS streams rows matching decode()" {
    const allocator = std.testing.allocator;
    var ref = try jpegz.decode(allocator, fixture_jpegls_4x4_gray8);
    defer ref.deinit(allocator);
    const buf = try allocator.alloc(u8, ref.pixels.len);
    defer allocator.free(buf);
    var collector = RowCollector{
        .buf = buf,
        .row_stride = ref.rowStride(),
        .rows_seen = 0,
        .last_y = -1,
        .in_order = true,
    };
    _ = try jpegz.decodeStreamingRows(allocator, fixture_jpegls_4x4_gray8, .{
        .on_row = RowCollector.onRow,
        .ctx = &collector,
    });
    try std.testing.expectEqual(@as(u32, 4), collector.rows_seen);
    try std.testing.expectEqualSlices(u8, ref.pixels, buf);
}

test "decodeStreamingRows: callback error propagates as CallbackAborted" {
    const cb = jpegz.RowCallback{
        .on_row = struct {
            fn cb(_: ?*anyopaque, _: []const u8, _: u32) anyerror!void {
                return error.UserAborted;
            }
        }.cb,
    };
    try std.testing.expectError(
        error.CallbackAborted,
        jpegz.decodeStreamingRows(std.testing.allocator, fixture_baseline_2x2_rgb, cb),
    );
}

test "decodeStreamingRows: callback error preserves original name via lastErrorMessage" {
    // CallbackAborted is the API-level error code (the contract); the
    // ORIGINAL error name should be recoverable through the thread-local
    // last-error buffer for both Zig and C callers.
    const cb = jpegz.RowCallback{
        .on_row = struct {
            fn cb(_: ?*anyopaque, _: []const u8, _: u32) anyerror!void {
                return error.UserAborted;
            }
        }.cb,
    };
    _ = jpegz.decodeStreamingRows(std.testing.allocator, fixture_baseline_2x2_rgb, cb) catch {};
    const msg = jpegz.lastErrorMessage();
    try std.testing.expect(msg.len > 0);
    // Detail string must mention the original error name.
    try std.testing.expect(std.mem.indexOf(u8, msg, "UserAborted") != null);
}

test "FindingCode numeric values are stable" {
    // Spot-check a few — these are wire-format values per the design
    // doc § 4.1; reordering is a wire-break.
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(jpegz.FindingCode.missing_soi));
    try std.testing.expectEqual(@as(u32, 50), @intFromEnum(jpegz.FindingCode.invalid_sof_precision));
    try std.testing.expectEqual(@as(u32, 100), @intFromEnum(jpegz.FindingCode.lossless_predictor_invalid));
    try std.testing.expectEqual(@as(u32, 200), @intFromEnum(jpegz.FindingCode.arithmetic_coding_used));
}
