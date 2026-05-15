//! C ABI surface for jpegz. Defines the `export fn` entry points
//! consumed by `include/jpegz_core.h`. The Zig core (`src/jpegz.zig`)
//! is the single implementation; this module is pure marshalling.
//!
//! Layout choices documented in
//! `docs/superpowers/specs/2026-05-04-jpegz-public-api-design.md` § 5.

const std = @import("std");
const errors = @import("../core/errors.zig");
const jpegz = @import("../jpegz.zig");

// `c_int` is a Zig builtin for the C `int` type — no alias needed.

// ─────────────────────────────────────────────────────────────────────
// Allocator strategy: single global allocator backing all C-allocated
// memory (pixels, findings, detail strings). Using c_allocator keeps
// the picture simple — caller-owned C memory uses the C heap.
// Future: allow caller to supply a custom allocator via an opt struct.
// ─────────────────────────────────────────────────────────────────────
const c_allocator = std.heap.c_allocator;

// ─────────────────────────────────────────────────────────────────────
// Status / error mapping
// ─────────────────────────────────────────────────────────────────────

/// Exhaustive switch — adding a Zig variant to DecodeError without
/// updating this is a COMPILE-TIME ERROR. That's the design point:
/// the Zig declarations are the source of truth, the C ABI is the
/// formal mirror.
fn toCStatus(err: errors.DecodeError) c_int {
    return switch (err) {
        error.NotImplemented        => -1,
        error.InvalidMarker         => -2,
        error.UnsupportedPrecision  => -3,
        error.TruncatedStream       => -4,
        error.NotRowStreamable      => -5,
        error.BackendError          => -6,
        error.InvalidJp2Codestream  => -7,
        error.OutOfMemory           => -8,
        error.CallbackAborted       => -9,
    };
}

// ─────────────────────────────────────────────────────────────────────
// Thread-local last-error message
// ─────────────────────────────────────────────────────────────────────
//
// The backing buffer + setter live in `src/core/last_error.zig` so the
// public Zig API can read the same memory via `jpegz.lastErrorMessage()`
// without duplicating storage. The two locals below are thin aliases
// that keep existing call sites in this file unchanged.

const last_error = @import("../core/last_error.zig");
const clearLastError = last_error.clear;
const setLastError = last_error.set;

export fn jpegz_last_error_message() [*:0]const u8 {
    return last_error.cPtr();
}

// ─────────────────────────────────────────────────────────────────────
// Versioning
// ─────────────────────────────────────────────────────────────────────

export fn jpegz_version() [*:0]const u8 {
    return jpegz.version.ptr;
}

// ─────────────────────────────────────────────────────────────────────
// Image — C representation
// ─────────────────────────────────────────────────────────────────────

const CImage = extern struct {
    pixels: [*c]u8,
    pixels_len: usize,
    width: u32,
    height: u32,
    channels: u8,
    bits_per_sample: u8,
    source_color_space: c_int,
    layout: c_int,
};

fn writeImageToC(out: *CImage, img: jpegz.Image) void {
    out.* = .{
        .pixels = img.pixels.ptr,
        .pixels_len = img.pixels.len,
        .width = img.width,
        .height = img.height,
        .channels = img.channels,
        .bits_per_sample = img.bits_per_sample,
        .source_color_space = @intFromEnum(img.source_color_space),
        .layout = @intFromEnum(img.layout),
    };
}

export fn jpegz_image_free(image: ?*CImage) void {
    const im = image orelse return;
    if (im.pixels != null and im.pixels_len > 0) {
        const slice: []u8 = im.pixels[0..im.pixels_len];
        c_allocator.free(slice);
    }
    im.* = std.mem.zeroes(CImage);
}

// ─────────────────────────────────────────────────────────────────────
// jpegz_decode / jpegz_jp2_decode (+ _ex variants for caller-controlled
// options — cross-project threading-control convention, agreed
// 2026-05-07; see jpegz_core.h docstring on jpegz_decode_options_t).
// ─────────────────────────────────────────────────────────────────────

/// Mirrors `jpegz_decode_options_t` in include/jpegz_core.h.
/// Layout: `threads: u8` followed by 7 reserved zero bytes for forward
/// compatibility. Existing fields never shift; new fields append.
const CDecodeOptions = extern struct {
    threads: u8,
    reserved: [7]u8,
};

fn doDecodeWithOptions(
    decoder: *const fn (std.mem.Allocator, []const u8, jpegz.DecodeOptions) errors.DecodeError!jpegz.Image,
    data: [*c]const u8,
    len: usize,
    c_options: ?*const CDecodeOptions,
    out_image: ?*CImage,
) c_int {
    clearLastError();
    const out = out_image orelse {
        setLastError("out_image must not be NULL", .{});
        return -3;
    };
    const slice: []const u8 = if (data == null or len == 0) &[_]u8{} else data[0..len];
    const opts: jpegz.DecodeOptions = if (c_options) |co|
        .{ .threads = co.threads }
    else
        .{};
    const img = decoder(c_allocator, slice, opts) catch |err| {
        setLastError("decode failed: {s}", .{@errorName(err)});
        return toCStatus(err);
    };
    writeImageToC(out, img);
    return 0;
}

export fn jpegz_decode(data: [*c]const u8, len: usize, out_image: ?*CImage) c_int {
    return doDecodeWithOptions(jpegz.decodeWithOptions, data, len, null, out_image);
}

export fn jpegz_decode_ex(
    data: [*c]const u8,
    len: usize,
    options: ?*const CDecodeOptions,
    out_image: ?*CImage,
) c_int {
    return doDecodeWithOptions(jpegz.decodeWithOptions, data, len, options, out_image);
}

export fn jpegz_jp2_decode(data: [*c]const u8, len: usize, out_image: ?*CImage) c_int {
    return doDecodeWithOptions(jpegz.jpeg2000.decodeWithOptions, data, len, null, out_image);
}

export fn jpegz_jp2_decode_ex(
    data: [*c]const u8,
    len: usize,
    options: ?*const CDecodeOptions,
    out_image: ?*CImage,
) c_int {
    return doDecodeWithOptions(jpegz.jpeg2000.decodeWithOptions, data, len, options, out_image);
}

// ─────────────────────────────────────────────────────────────────────
// Row-streaming decode — C ABI surface parity with the Zig
// `decodeStreamingRows` / `decodeStreamingRowsWithOptions` entries.
// ─────────────────────────────────────────────────────────────────────

const CImageMetadata = extern struct {
    width: u32,
    height: u32,
    channels: u8,
    bits_per_sample: u8,
    source_color_space: c_int,
    layout: c_int,
};

const CRowCallbackFn = *const fn (
    ctx: ?*anyopaque,
    row: [*c]const u8,
    row_len: usize,
    y: u32,
) callconv(.c) c_int;

/// Bridge between the C-shaped row callback (returns int) and Zig's
/// `RowCallback` shape (returns `anyerror!void`). Lives on the
/// caller's stack during the streaming call.
const CRowBridge = struct {
    c_fn: CRowCallbackFn,
    c_ctx: ?*anyopaque,
    last_c_rc: c_int,
};

fn zigRowBridge(ctx_opaque: ?*anyopaque, row: []const u8, y: u32) anyerror!void {
    const bridge: *CRowBridge = @ptrCast(@alignCast(ctx_opaque.?));
    const rc = bridge.c_fn(bridge.c_ctx, row.ptr, row.len, y);
    if (rc != 0) {
        bridge.last_c_rc = rc;
        return error.CallbackAborted;
    }
}

fn doStreamingWithOptions(
    data: [*c]const u8,
    len: usize,
    c_options: ?*const CDecodeOptions,
    on_row: ?CRowCallbackFn,
    ctx: ?*anyopaque,
    out_meta: ?*CImageMetadata,
) c_int {
    clearLastError();
    const cb_fn = on_row orelse {
        setLastError("on_row must not be NULL", .{});
        return -3;
    };
    const slice: []const u8 = if (data == null or len == 0) &[_]u8{} else data[0..len];
    const opts: jpegz.DecodeOptions = if (c_options) |co|
        .{ .threads = co.threads }
    else
        .{};

    var bridge = CRowBridge{ .c_fn = cb_fn, .c_ctx = ctx, .last_c_rc = 0 };
    const meta = jpegz.decodeStreamingRowsWithOptions(c_allocator, slice, opts, .{
        .on_row = zigRowBridge,
        .ctx = &bridge,
    }) catch |err| {
        // The library's last_error path already records detail for
        // most errors; for callback aborts the message will say
        // "row N: callback returned error.CallbackAborted" which is
        // less helpful than the original C return value. Overwrite
        // with the C-friendly form.
        if (err == error.CallbackAborted) {
            setLastError("callback returned {d}", .{bridge.last_c_rc});
        }
        return toCStatus(err);
    };

    if (out_meta) |m| m.* = .{
        .width = meta.width,
        .height = meta.height,
        .channels = meta.channels,
        .bits_per_sample = meta.bits_per_sample,
        .source_color_space = @intFromEnum(meta.source_color_space),
        .layout = @intFromEnum(meta.layout),
    };
    return 0;
}

export fn jpegz_decode_streaming_rows(
    data: [*c]const u8,
    len: usize,
    on_row: ?CRowCallbackFn,
    ctx: ?*anyopaque,
    out_metadata: ?*CImageMetadata,
) c_int {
    return doStreamingWithOptions(data, len, null, on_row, ctx, out_metadata);
}

export fn jpegz_decode_streaming_rows_ex(
    data: [*c]const u8,
    len: usize,
    options: ?*const CDecodeOptions,
    on_row: ?CRowCallbackFn,
    ctx: ?*anyopaque,
    out_metadata: ?*CImageMetadata,
) c_int {
    return doStreamingWithOptions(data, len, options, on_row, ctx, out_metadata);
}

// ─────────────────────────────────────────────────────────────────────
// Validation — C representation
// ─────────────────────────────────────────────────────────────────────

const CFinding = extern struct {
    severity: c_int,
    code: u32,
    /// INT64_MIN for "no offset", any other for the byte offset.
    offset: i64,
    /// NUL-terminated, owned by the report. NULL = no detail.
    detail: ?[*:0]const u8,
};

const OFFSET_NONE: i64 = std.math.minInt(i64);

const CValidationReport = extern struct {
    overall: c_int,
    variant: c_int,
    /// 0 means "not parsed".
    width: u32,
    height: u32,
    findings: [*c]const CFinding,
    findings_len: usize,
};

fn buildCFindings(zig_findings: []const jpegz.Finding) ![*c]CFinding {
    if (zig_findings.len == 0) return null;
    const arr = try c_allocator.alloc(CFinding, zig_findings.len);
    errdefer c_allocator.free(arr);

    for (zig_findings, 0..) |f, i| {
        // For each detail string, allocate a NUL-terminated C copy.
        var detail_c: ?[*:0]const u8 = null;
        if (f.detail) |d| {
            const buf = try c_allocator.alloc(u8, d.len + 1);
            @memcpy(buf[0..d.len], d);
            buf[d.len] = 0;
            detail_c = @ptrCast(buf.ptr);
        }
        arr[i] = .{
            .severity = @intFromEnum(f.severity),
            .code = @intFromEnum(f.code),
            .offset = if (f.offset) |o| @intCast(o) else OFFSET_NONE,
            .detail = detail_c,
        };
    }
    return @ptrCast(arr.ptr);
}

fn freeCFindings(findings: [*c]const CFinding, len: usize) void {
    if (findings == null or len == 0) return;
    // Free detail strings.
    var i: usize = 0;
    while (i < len) : (i += 1) {
        if (findings[i].detail) |d| {
            const slice = std.mem.span(d);
            // Free the allocation including the NUL byte.
            const full = @as([*]u8, @ptrCast(@constCast(d)))[0 .. slice.len + 1];
            c_allocator.free(full);
        }
    }
    // Free the array itself.
    const arr_slice = @as([*]const CFinding, findings)[0..len];
    c_allocator.free(@as([*]CFinding, @constCast(@ptrCast(arr_slice.ptr)))[0..len]);
}

export fn jpegz_validation_report_free(report: ?*CValidationReport) void {
    const r = report orelse return;
    freeCFindings(r.findings, r.findings_len);
    r.* = std.mem.zeroes(CValidationReport);
}

fn doValidate(
    validator: *const fn (std.mem.Allocator, []const u8) error{OutOfMemory}!jpegz.ValidationReport,
    data: [*c]const u8,
    len: usize,
    out_report: ?*CValidationReport,
) c_int {
    clearLastError();
    const out = out_report orelse {
        setLastError("out_report must not be NULL", .{});
        return -8; // OUT_OF_MEMORY-adjacent; reuse for invalid-arg-NULL.
    };
    const slice: []const u8 = if (data == null or len == 0) &[_]u8{} else data[0..len];
    var report = validator(c_allocator, slice) catch |err| {
        setLastError("validate failed: {s}", .{@errorName(err)});
        return toCStatus(err);
    };
    defer report.deinit(c_allocator);

    const c_findings = buildCFindings(report.findings.items) catch {
        setLastError("OOM building C findings", .{});
        return -8;
    };

    out.* = .{
        .overall = @intFromEnum(report.overall),
        .variant = @intFromEnum(report.variant),
        .width = report.width orelse 0,
        .height = report.height orelse 0,
        .findings = c_findings,
        .findings_len = report.findings.items.len,
    };
    return 0;
}

export fn jpegz_validate(data: [*c]const u8, len: usize, out_report: ?*CValidationReport) c_int {
    return doValidate(jpegz.validate, data, len, out_report);
}

export fn jpegz_jp2_validate(data: [*c]const u8, len: usize, out_report: ?*CValidationReport) c_int {
    return doValidate(jpegz.jpeg2000.validate, data, len, out_report);
}
