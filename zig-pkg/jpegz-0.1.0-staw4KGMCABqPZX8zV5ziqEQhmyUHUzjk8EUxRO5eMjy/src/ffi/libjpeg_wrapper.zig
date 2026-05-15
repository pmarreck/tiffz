//! Phase 1 wrapper around libjpeg-turbo (BSD-3). The Zig public API
//! `jpegz.decode` calls into this module for SOF0/1 (baseline / extended
//! sequential) and SOF2 (progressive). Lossless (SOF3) goes through the
//! lifted pure-Zig decoder (M1.4); arithmetic-coded variants come back
//! through here in M2.5.
//!
//! Architecture: setjmp/longjmp error bridge — libjpeg's default error
//! handler calls `exit()`, which we override with a custom `error_mgr`
//! whose `error_exit` longjmps back to a pre-set Zig context. The Zig
//! code wraps every libjpeg call in that setjmp block and translates
//! the libjpeg error message into a `DecodeError`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const errors = @import("../core/errors.zig");
const types = @import("../jpegz.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("setjmp.h");
    @cInclude("jpeglib.h");
    @cInclude("jerror.h");
});

/// Cap on captured warning records — libjpeg emits one WARNMS per
/// distinct event, but a single decode can produce dozens for a
/// pathological input. Past this cap we just bump `warning_count`
/// so the caller still sees that warnings happened.
pub const MAX_CAPTURED_WARNINGS: usize = 16;

/// One libjpeg WARNMS record. `msg_code` is the J_MESSAGE_CODE
/// (typically a JWRN_* constant from jerror.h); `message` is the
/// formatted human-readable string (NUL-padded to JMSG_LENGTH_MAX).
pub const CapturedWarning = extern struct {
    msg_code: c_int,
    message: [c.JMSG_LENGTH_MAX]u8,
};

/// Custom error_mgr: extends jpeg_error_mgr with a setjmp buffer plus
/// a buffer for non-fatal warnings (WARNMS) so the validator can
/// surface them as Finding(.warn) entries — see NEXT_STEPS.md
/// §"Validation-strictness: warns over silent tolerance".
const ErrorBridge = extern struct {
    pub_mgr: c.struct_jpeg_error_mgr,
    setjmp_buffer: c.jmp_buf,
    last_message: [c.JMSG_LENGTH_MAX]u8,
    /// Captured WARNMS records. Indices 0..min(warning_count, MAX).
    warnings: [MAX_CAPTURED_WARNINGS]CapturedWarning,
    /// Total WARNMS calls observed (may exceed MAX_CAPTURED_WARNINGS).
    warning_count: u32,
};

/// Replacement for the default `error_exit`. libjpeg invokes this when a
/// fatal error occurs. We capture the message and longjmp back to the
/// Zig caller's setjmp point.
fn errorExit(cinfo: c.j_common_ptr) callconv(.c) void {
    const bridge: *ErrorBridge = @fieldParentPtr("pub_mgr", @as(*c.struct_jpeg_error_mgr, @ptrCast(cinfo.*.err)));
    // Format the message into our buffer.
    bridge.pub_mgr.format_message.?(cinfo, &bridge.last_message);
    // Jump back to the caller's setjmp point.
    c.longjmp(&bridge.setjmp_buffer, 1);
}

/// Suppress libjpeg's warning/trace output (would otherwise hit stderr
/// during decode). Tests should be silent.
fn outputNoop(_: c.j_common_ptr) callconv(.c) void {}

/// emit_message override — buffer WARNMS (msg_level == -1) into the
/// bridge's `warnings` array rather than printing them to stderr.
/// Trace messages (msg_level >= 0) are dropped. Mirrors the
/// `num_warnings`-counting in libjpeg's default `emit_message` so the
/// fallback paths that check `err->num_warnings` still see the count.
fn emitMessageCapture(cinfo: c.j_common_ptr, msg_level: c_int) callconv(.c) void {
    if (msg_level >= 0) return; // trace, not a warning
    const bridge: *ErrorBridge = @fieldParentPtr("pub_mgr", @as(*c.struct_jpeg_error_mgr, @ptrCast(cinfo.*.err)));
    bridge.pub_mgr.num_warnings +%= 1;
    if (bridge.warning_count < MAX_CAPTURED_WARNINGS) {
        const slot = &bridge.warnings[bridge.warning_count];
        slot.msg_code = bridge.pub_mgr.msg_code;
        @memset(&slot.message, 0);
        bridge.pub_mgr.format_message.?(cinfo, &slot.message);
    }
    bridge.warning_count +%= 1;
}

/// Install our custom hooks on the bridge: setjmp longjmp for fatal
/// errors, silent output, and WARNMS capture. Zeroes the warning
/// state so each call starts fresh. Callers still need to wire
/// `cinfo.err = jpeg_std_error(&bridge.pub_mgr)` themselves.
fn initBridgeHandlers(bridge: *ErrorBridge) void {
    bridge.pub_mgr.error_exit = &errorExit;
    bridge.pub_mgr.output_message = &outputNoop;
    bridge.pub_mgr.emit_message = &emitMessageCapture;
    bridge.last_message[0] = 0;
    bridge.warning_count = 0;
}

/// Map a libjpeg `J_COLOR_SPACE` (out_color_space after start_decompress)
/// to the public-API source/layout pair.
fn mapColorSpace(jcs: c.J_COLOR_SPACE) struct { source: types.ColorSpace, layout: types.PixelLayout } {
    return switch (jcs) {
        c.JCS_GRAYSCALE => .{ .source = .grayscale, .layout = .grayscale },
        c.JCS_RGB       => .{ .source = .rgb,       .layout = .rgb },
        c.JCS_YCbCr     => .{ .source = .ycbcr,     .layout = .rgb }, // converted by libjpeg
        c.JCS_CMYK      => .{ .source = .cmyk,      .layout = .cmyk },
        c.JCS_YCCK      => .{ .source = .ycck,      .layout = .cmyk }, // converted by libjpeg
        else            => .{ .source = .unknown,   .layout = .rgb },
    };
}

/// Translate libjpeg's `jpeg_color_space` (the *source* color space, set
/// by `read_header` before any conversion) for the `Image.source_color_space`
/// field.
fn mapSourceColorSpace(jcs: c.J_COLOR_SPACE) types.ColorSpace {
    return switch (jcs) {
        c.JCS_GRAYSCALE => .grayscale,
        c.JCS_RGB       => .rgb,
        c.JCS_YCbCr     => .ycbcr,
        c.JCS_CMYK      => .cmyk,
        c.JCS_YCCK      => .ycck,
        else            => .unknown,
    };
}

/// Pre-flight check: does this look like a JPEG at all? Cheaper than
/// firing up the full decoder for obvious garbage. SOI marker is 0xFF 0xD8.
fn looksLikeJpeg(data: []const u8) bool {
    return data.len >= 2 and data[0] == 0xFF and data[1] == 0xD8;
}

/// Main entry — wraps libjpeg-turbo to decode a baseline / extended /
/// progressive JPEG into a fully-realized `Image` with `[]u8` pixels
/// in raster order, RGB or grayscale or CMYK per the source.
pub fn decode(allocator: Allocator, data: []const u8) errors.DecodeError!types.Image {
    if (data.len < 4) return error.TruncatedStream;
    if (!looksLikeJpeg(data)) return error.InvalidMarker;

    var bridge: ErrorBridge = undefined;
    var cinfo: c.struct_jpeg_decompress_struct = undefined;

    // Wire the custom error manager.
    cinfo.err = c.jpeg_std_error(&bridge.pub_mgr);
    initBridgeHandlers(&bridge);

    // setjmp returns 0 on first entry, non-zero if longjmp'd to.
    if (c.setjmp(&bridge.setjmp_buffer) != 0) {
        // libjpeg signaled an error. Clean up and translate.
        c.jpeg_destroy_decompress(&cinfo);
        return classifyLibjpegError(&bridge);
    }

    // jpeg_create_decompress is a macro; use the underlying function.
    c.jpeg_CreateDecompress(&cinfo, c.JPEG_LIB_VERSION, @sizeOf(c.struct_jpeg_decompress_struct));
    defer c.jpeg_destroy_decompress(&cinfo);

    // jpeg_mem_src reads bytes lazily — `data` must outlive this call.
    // Cast away const because libjpeg's API is non-const-correct; it
    // does not actually mutate the buffer.
    c.jpeg_mem_src(&cinfo, @constCast(data.ptr), @intCast(data.len));

    // TRUE = require image (not table-only). Returns JPEG_HEADER_OK on success.
    const header_status = c.jpeg_read_header(&cinfo, c.TRUE);
    if (header_status != c.JPEG_HEADER_OK) return error.InvalidMarker;

    // Grab source color space before start_decompress (which may convert).
    const source_cs = mapSourceColorSpace(cinfo.jpeg_color_space);

    // Capture data_precision BEFORE start_decompress.
    //
    // T.81 §13 SOF3 lossless allows precision 2..16. libjpeg-turbo
    // 3.x exposes three scanline APIs by sample width:
    //   precision  1..8   → JSAMPLE = unsigned char
    //   precision  9..12  → J12SAMPLE = signed short
    //   precision 13..16  → J16SAMPLE = unsigned short
    // DNG raw is the real-world driver: most cameras emit 12-bit or
    // 14-bit raw inside SOF3-lossless. Sticking to strict 8/12/16 only
    // would reject 14-bit DNG; route by range instead.
    const precision: u8 = @intCast(cinfo.data_precision);
    if (precision == 0 or precision > 16) return error.UnsupportedPrecision;

    if (c.jpeg_start_decompress(&cinfo) == 0) return error.BackendError;

    const cs_pair = mapColorSpace(cinfo.out_color_space);
    const channels: u8 = @intCast(cinfo.output_components);
    const width: u32 = @intCast(cinfo.output_width);
    const height: u32 = @intCast(cinfo.output_height);

    if (precision <= 8) {
        const row_stride: usize = @as(usize, width) * @as(usize, channels);
        const pixels = allocator.alloc(u8, row_stride * @as(usize, height)) catch
            return error.OutOfMemory;
        errdefer allocator.free(pixels);

        var row_buffer: [1][*c]u8 = .{undefined};
        var y: u32 = 0;
        while (y < height) {
            row_buffer[0] = pixels.ptr + y * row_stride;
            const got = c.jpeg_read_scanlines(&cinfo, &row_buffer[0], 1);
            if (got != 1) return error.TruncatedStream;
            y += 1;
        }
        if (c.jpeg_finish_decompress(&cinfo) == 0) return error.BackendError;

        return types.Image{
            .pixels = pixels,
            .width = width,
            .height = height,
            .channels = channels,
            .bits_per_sample = 8,
            .source_color_space = source_cs,
            .layout = cs_pair.layout,
        };
    }

    // 12-bit or 16-bit lossless path. libjpeg-turbo 3.x exposes
    // jpeg12_read_scanlines (J12SAMPLE = signed short) and
    // jpeg16_read_scanlines (J16SAMPLE = unsigned short). The bit
    // pattern lands in `[]u16` either way; the design type carries
    // bits_per_sample so callers can disambiguate the value range.
    const samples_per_row: usize = @as(usize, width) * @as(usize, channels);
    const row_bytes: usize = samples_per_row * 2;
    const total_bytes: usize = row_bytes * @as(usize, height);
    const pixels = allocator.alloc(u8, total_bytes) catch return error.OutOfMemory;
    errdefer allocator.free(pixels);

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row_ptr_u16: [*c]u16 = @ptrCast(@alignCast(pixels.ptr + y * row_bytes));
        var row_buffer: [1][*c]u16 = .{row_ptr_u16};
        const got = if (precision <= 12)
            c.jpeg12_read_scanlines(&cinfo, @ptrCast(&row_buffer[0]), 1)
        else
            c.jpeg16_read_scanlines(&cinfo, @ptrCast(&row_buffer[0]), 1);
        if (got != 1) return error.TruncatedStream;
    }

    if (c.jpeg_finish_decompress(&cinfo) == 0) return error.BackendError;

    return types.Image{
        .pixels = pixels,
        .width = width,
        .height = height,
        .channels = channels,
        .bits_per_sample = precision,
        .source_color_space = source_cs,
        .layout = cs_pair.layout,
    };
}

/// Result of a codec-level integrity check: null on success, or a
/// (code, message) pair describing the libjpeg failure for the
/// validator to translate into a Finding.
pub const CodecCheckFailure = struct {
    code: errors.FindingCode,
    /// Borrows from bridge's NUL-terminated buffer; copy if you need
    /// it past validateCodecIntegrity's return.
    message: []const u8,
};

/// Outcome of a codec-level integrity check. `failure` may be null
/// (libjpeg recovered) while `warnings` is non-empty — that's exactly
/// the libjpeg-style "silent tolerance" case the validate-warns
/// surface is meant to flag.
pub const CodecCheckResult = struct {
    failure: ?CodecCheckFailure,
    /// Captured libjpeg WARNMS records. Each `msg_code` is the
    /// J_MESSAGE_CODE (a JWRN_* constant). Borrows from bridge memory;
    /// caller must copy bytes if they need to outlive the call.
    warnings: []const CapturedWarning,
    /// Total WARNMS calls observed. May exceed `warnings.len` if the
    /// bridge's buffer overflowed.
    warning_count: u32,
};

/// Map a libjpeg msg_code (J_MESSAGE_CODE) to one of our FindingCode
/// values. Used by validateCodecIntegrity. Returns the best
/// categorical match; falls back to `huffman_table_corrupt` because
/// most libjpeg errors that survive the marker walker are entropy /
/// table issues, and validate-the-project just needs a categorical
/// FAIL signal — the human message is in `Finding.detail`.
fn libjpegMsgToFindingCode(code: c_int) errors.FindingCode {
    return switch (code) {
        c.JERR_BAD_HUFF_TABLE,
        c.JERR_HUFF_CLEN_OVERFLOW,
        c.JERR_HUFF_MISSING_CODE,
        c.JERR_NO_HUFF_TABLE,
        => .huffman_table_corrupt,

        c.JERR_NO_QUANT_TABLE,
        c.JERR_MISMATCHED_QUANT_TABLE,
        => .quantization_table_corrupt,

        c.JERR_NO_ARITH_TABLE,
        c.JERR_ARITH_NOTIMPL,
        => .arithmetic_table_corrupt,

        c.JERR_BAD_DCT_COEF,
        c.JERR_BAD_DCTSIZE,
        => .dct_coefficient_overflow,

        c.JERR_BAD_PRECISION => .invalid_sof_precision,
        c.JERR_INPUT_EMPTY,
        c.JERR_INPUT_EOF,
        c.JERR_FILE_READ,
        => .truncated_stream,
        c.JERR_NO_SOI => .missing_soi,

        else => .huffman_table_corrupt,
    };
}

/// Decode-through with no pixel materialization. Reports whether the
/// codec fully decoded the image (`result.failure == null`) plus any
/// non-fatal WARNMS records libjpeg emitted along the way (zero-pad
/// of premature EOI, extraneous bytes before a marker, etc.) — those
/// power the `validate(...)` warn-level surface.
///
/// The bridge is caller-owned (`bridge_out`) so message slices
/// returned in the result stay valid until the caller is done with
/// them. Callers typically stack-allocate one `ErrorBridge` and pass
/// `&bridge` here, then pump the result into their `Finding`
/// allocations before the bridge goes out of scope.
pub fn validateCodecIntegrity(data: []const u8, bridge_out: *ErrorBridge) CodecCheckResult {
    if (data.len < 4) return .{
        .failure = .{ .code = .truncated_stream, .message = "data too short for JPEG header" },
        .warnings = &.{},
        .warning_count = 0,
    };
    if (!looksLikeJpeg(data)) return .{
        .failure = .{ .code = .missing_soi, .message = "missing SOI marker (0xFF 0xD8)" },
        .warnings = &.{},
        .warning_count = 0,
    };

    var cinfo: c.struct_jpeg_decompress_struct = undefined;
    cinfo.err = c.jpeg_std_error(&bridge_out.pub_mgr);
    initBridgeHandlers(bridge_out);

    if (c.setjmp(&bridge_out.setjmp_buffer) != 0) {
        const code = libjpegMsgToFindingCode(bridge_out.pub_mgr.msg_code);
        const len = std.mem.indexOfScalar(u8, &bridge_out.last_message, 0) orelse bridge_out.last_message.len;
        c.jpeg_destroy_decompress(&cinfo);
        return .{
            .failure = .{ .code = code, .message = bridge_out.last_message[0..len] },
            .warnings = bridge_out.warnings[0..@min(bridge_out.warning_count, MAX_CAPTURED_WARNINGS)],
            .warning_count = bridge_out.warning_count,
        };
    }

    c.jpeg_CreateDecompress(&cinfo, c.JPEG_LIB_VERSION, @sizeOf(c.struct_jpeg_decompress_struct));
    defer c.jpeg_destroy_decompress(&cinfo);

    c.jpeg_mem_src(&cinfo, @constCast(data.ptr), @intCast(data.len));

    if (c.jpeg_read_header(&cinfo, c.TRUE) != c.JPEG_HEADER_OK) return .{
        .failure = .{ .code = .truncated_stream, .message = "jpeg_read_header rejected the file" },
        .warnings = bridge_out.warnings[0..@min(bridge_out.warning_count, MAX_CAPTURED_WARNINGS)],
        .warning_count = bridge_out.warning_count,
    };

    const precision: u8 = @intCast(cinfo.data_precision);
    if (precision == 0 or precision > 16) return .{
        .failure = .{ .code = .invalid_sof_precision, .message = "SOF precision out of T.81 §13 range (1..16)" },
        .warnings = bridge_out.warnings[0..@min(bridge_out.warning_count, MAX_CAPTURED_WARNINGS)],
        .warning_count = bridge_out.warning_count,
    };

    if (c.jpeg_start_decompress(&cinfo) == 0) return .{
        .failure = .{ .code = .truncated_stream, .message = "jpeg_start_decompress failed" },
        .warnings = bridge_out.warnings[0..@min(bridge_out.warning_count, MAX_CAPTURED_WARNINGS)],
        .warning_count = bridge_out.warning_count,
    };

    if (precision <= 8) {
        var row: [16384]u8 = undefined;
        var rb: [1][*c]u8 = .{&row[0]};
        var y: u32 = 0;
        const h: u32 = @intCast(cinfo.output_height);
        while (y < h) : (y += 1) {
            const got = c.jpeg_read_scanlines(&cinfo, &rb[0], 1);
            if (got != 1) return .{
                .failure = .{ .code = .truncated_stream, .message = "jpeg_read_scanlines short read" },
                .warnings = bridge_out.warnings[0..@min(bridge_out.warning_count, MAX_CAPTURED_WARNINGS)],
                .warning_count = bridge_out.warning_count,
            };
        }
    } else {
        var row: [16384]u16 = undefined;
        var rb: [1][*c]u16 = .{&row[0]};
        var y: u32 = 0;
        const h: u32 = @intCast(cinfo.output_height);
        while (y < h) : (y += 1) {
            const got = if (precision <= 12)
                c.jpeg12_read_scanlines(&cinfo, @ptrCast(&rb[0]), 1)
            else
                c.jpeg16_read_scanlines(&cinfo, @ptrCast(&rb[0]), 1);
            if (got != 1) return .{
                .failure = .{ .code = .truncated_stream, .message = "jpeg{12,16}_read_scanlines short read" },
                .warnings = bridge_out.warnings[0..@min(bridge_out.warning_count, MAX_CAPTURED_WARNINGS)],
                .warning_count = bridge_out.warning_count,
            };
        }
    }

    if (c.jpeg_finish_decompress(&cinfo) == 0) return .{
        .failure = .{ .code = .truncated_stream, .message = "jpeg_finish_decompress failed" },
        .warnings = bridge_out.warnings[0..@min(bridge_out.warning_count, MAX_CAPTURED_WARNINGS)],
        .warning_count = bridge_out.warning_count,
    };

    return .{
        .failure = null,
        .warnings = bridge_out.warnings[0..@min(bridge_out.warning_count, MAX_CAPTURED_WARNINGS)],
        .warning_count = bridge_out.warning_count,
    };
}

/// Re-export so validator.zig can stack-allocate an `ErrorBridge`
/// without depending on the internal struct shape.
pub const ValidationBridge = ErrorBridge;

/// Map a libjpeg JWRN_* msg_code to our FindingCode + Severity. Used by
/// validate() to surface each captured WARNMS as a `Finding(.warn)`.
/// Anything we don't recognize falls back to `huffman_table_corrupt`
/// at .warn — the human-readable libjpeg message rides in detail.
pub fn libjpegWarnToFindingCode(code: c_int) errors.FindingCode {
    return switch (code) {
        c.JWRN_JPEG_EOF,
        c.JWRN_HIT_MARKER,
        => .insufficient_data,
        c.JWRN_EXTRANEOUS_DATA => .extraneous_bytes_before_marker,
        c.JWRN_HUFF_BAD_CODE => .huffman_table_corrupt,
        c.JWRN_ARITH_BAD_CODE => .arithmetic_table_corrupt,
        c.JWRN_MUST_RESYNC => .restart_marker_missing,
        c.JWRN_BOGUS_PROGRESSION => .progressive_scan_invalid,
        c.JWRN_NOT_SEQUENTIAL => .progressive_scan_invalid,
        else => .huffman_table_corrupt,
    };
}

/// Map a libjpeg error code into our DecodeError set. libjpeg's
/// jpeg_error_mgr.msg_code is the canonical classification; the message
/// string in `bridge.last_message` is the human-readable detail.
fn classifyLibjpegError(bridge: *ErrorBridge) errors.DecodeError {
    // jpeg_error_mgr stores the error code in msg_code (a J_MESSAGE_CODE).
    // Common ones:
    //   JERR_NO_SOI            → InvalidMarker (no SOI marker)
    //   JERR_BAD_PRECISION     → UnsupportedPrecision
    //   JERR_NO_IMAGE          → TruncatedStream (no image data)
    //   JERR_INPUT_EMPTY       → TruncatedStream
    //   JERR_INPUT_EOF         → TruncatedStream
    // Anything else falls back to BackendError; the detailed message is
    // available via the C ABI's jpegz_last_error_message().
    const code = bridge.pub_mgr.msg_code;

    return switch (code) {
        c.JERR_NO_SOI,
        c.JERR_BAD_VIRTUAL_ACCESS, // bad/missing markers in many cases
        => error.InvalidMarker,

        c.JERR_BAD_PRECISION,
        => error.UnsupportedPrecision,

        c.JERR_NO_IMAGE,
        c.JERR_INPUT_EMPTY,
        c.JERR_INPUT_EOF,
        c.JERR_FILE_READ,
        => error.TruncatedStream,

        else => error.BackendError,
    };
}
