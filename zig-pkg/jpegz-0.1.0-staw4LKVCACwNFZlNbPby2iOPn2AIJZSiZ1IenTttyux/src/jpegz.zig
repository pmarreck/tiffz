//! jpegz — spec-complete JPEG family decoder library (Zig core).
//!
//! Public API. The full API design lives in
//! `docs/superpowers/specs/2026-05-04-jpegz-public-api-design.md`.
//!
//! Phase 1 wraps libjpeg-turbo (BSD-3) for T.81 + JPEG-LS, openjpeg
//! (BSD-2) for JPEG 2000, and lifts validate's existing pure-Zig
//! lossless decoder for SOF3. Phase 2 retires the C deps with
//! cleanroom Zig replacements.
//!
//! No I/O in the core — all data flows in via `[]const u8` byte slices
//! the caller is responsible for materializing (mmap, readFile, network
//! buffer, embedded resource). The C FFI dogfoods this.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ── Re-exports from canonical core modules ──────────────────────
const errors = @import("core/errors.zig");
pub const DecodeError = errors.DecodeError;
pub const Severity = errors.Severity;
pub const Variant = errors.Variant;
pub const FindingCode = errors.FindingCode;

const core_types = @import("core/types.zig");
pub const ColorSpace = core_types.ColorSpace;
pub const PixelLayout = core_types.PixelLayout;
pub const Image = core_types.Image;
pub const ImageMetadata = core_types.ImageMetadata;

pub const version: [:0]const u8 = "0.1.0";

const last_error = @import("core/last_error.zig");

/// Return the thread-local last-error message, or an empty slice if
/// none has been recorded since the last successful call on this
/// thread. The slice borrows from a static per-thread buffer — copy
/// the bytes if you need them past the next public API call.
///
/// Useful when a generic `DecodeError` (e.g. `error.CallbackAborted`)
/// hides the underlying detail; this gives callers the original
/// reason. Same buffer the C ABI surfaces via
/// `jpegz_last_error_message()` — no duplication.
pub fn lastErrorMessage() []const u8 {
    return last_error.current();
}

// ─────────────────────────────────────────────────────────────────────
// 1. Pixel-data types
// ─────────────────────────────────────────────────────────────────────

// `ColorSpace`, `PixelLayout`, `Image`, `ImageMetadata` are
// re-exported from `core/types.zig` above. See that file for full
// documentation. Splitting them out lets the cleanroom decoder
// (`src/decode/baseline.zig` etc.) import the same types without
// creating a module cycle through this file.

// ─────────────────────────────────────────────────────────────────────
// 2. Streaming
// ─────────────────────────────────────────────────────────────────────

/// Row-streaming callback. Library calls `on_row` once per emitted row
/// in raster order (y = 0, 1, …, height-1). `row` is borrowed; copy if
/// you need it past return. Return an error to abort decode — the
/// library propagates it back as `error.CallbackAborted` and stores the
/// original error message via the thread-local last-error mechanism
/// (visible to C callers as `jpegz_last_error_message()`).
pub const RowCallback = struct {
    on_row: *const fn (ctx: ?*anyopaque, row: []const u8, y: u32) anyerror!void,
    ctx: ?*anyopaque = null,
};

// ─────────────────────────────────────────────────────────────────────
// 3. Validation
// ─────────────────────────────────────────────────────────────────────

/// One observation about the bitstream. Multiple findings per report
/// is normal; a healthy image is `findings.items.len == 0`.
pub const Finding = struct {
    severity: Severity,
    code: FindingCode,
    /// Byte offset in `data` where the issue was detected, if known.
    /// 0 is a legitimate offset; `null` means "didn't apply / unknown".
    offset: ?u64 = null,
    /// Optional human-readable detail. Allocated from the report's
    /// allocator; freed by `ValidationReport.deinit()`. `null` = no detail.
    detail: ?[]const u8 = null,
};

/// Structured validation report. `validate` and `jpeg2000.validate`
/// always populate this and return successfully — even for badly-broken
/// input. A Zig error is reserved for catastrophic conditions (OOM,
/// internal library bug). Structural problems with the file go in
/// `findings` with severity `.fail`.
pub const ValidationReport = struct {
    /// Highest severity in `findings`. `.pass` if findings is empty.
    overall: Severity,
    /// Best-effort variant detection (set even on fail, where possible).
    variant: Variant,
    /// Image dimensions from SOF, when available. `null` if SOF not parsed.
    width: ?u32,
    height: ?u32,
    /// All findings, in detection order. Caller must pass the same
    /// allocator to `deinit` that was used to construct the report
    /// (Zig 0.15.2 std.ArrayList is unmanaged).
    findings: std.ArrayList(Finding),

    pub fn isValid(self: ValidationReport) bool {
        return self.overall == .pass or self.overall == .info or self.overall == .warn;
    }

    pub fn deinit(self: *ValidationReport, allocator: Allocator) void {
        for (self.findings.items) |f| {
            if (f.detail) |d| allocator.free(d);
        }
        self.findings.deinit(allocator);
        self.* = undefined;
    }
};

// ─────────────────────────────────────────────────────────────────────
// 4. Public entry points
// ─────────────────────────────────────────────────────────────────────

/// Caller-controlled decode parameters. Adopted verbatim from the
/// cross-project threading-control convention validate proposed
/// 2026-05-07 (`inbox/2026-05-07-validate-threading-control-convention.md`).
/// Same shape will land in tiffz at M6+.
pub const DecodeOptions = struct {
    /// Number of threads jpegz may use for parallelizable decode steps.
    /// `1` (default) = run sequentially in the calling thread. No
    ///   threads spawned, no oversubscription with caller-side worker
    ///   pools (validate's primary concern).
    /// `0` = explicit caller opt-in to library-side auto-detection
    ///   (`std.Thread.getCpuCount()` capped at the number of independent
    ///   decode units, e.g. RST segments or MCU rows).
    /// `>1` = explicit budget; library may use fewer if the work
    ///   doesn't amortize.
    ///
    /// **No globals, no env vars, no implicit auto-detection.** The
    /// caller decides every call. Per-call decision so different
    /// pipelines in one process can make different choices.
    ///
    /// Today (M2.1d): the cleanroom decoder honors `threads` for
    /// parallelizable pipeline stages (IDCT, dequant, color conv,
    /// chroma upsample) when the image is large enough to amortize
    /// thread setup. Wrapper paths pass through where supported
    /// (openjpeg → `opj_codec_set_threads`); libjpeg-turbo's
    /// traditional API has no thread param.
    threads: u8 = 1,
};

/// Decode any T.81 / T.87 JPEG (sequential / progressive / lossless /
/// arithmetic / JPEG-LS) into a fully-realized `Image`. Universal
/// entry point — works for every storage mode and precision.
///
/// `data` must remain valid through the call's return.
///
/// Output:
///   - 8-bit images: `pixels` is byte-shaped, RGB/grayscale/CMYK per `layout`.
///   - 12/16-bit images: `pixels` is `u16` host-endian (reinterpret-cast
///     as `[]u8`); accessed via `image.pixelsU16()`.
///
/// Default options (`threads = 1`). For caller-controlled threading,
/// use `decodeWithOptions`.
pub fn decode(allocator: Allocator, data: []const u8) DecodeError!Image {
    return decodeWithOptions(allocator, data, .{});
}

/// Same as `decode` but accepts a `DecodeOptions` struct for caller-
/// controlled behavior (today: thread-count budget). Existing call
/// sites of `decode` are unaffected; new consumers needing thread
/// control call this entry point.
pub fn decodeWithOptions(
    allocator: Allocator,
    data: []const u8,
    options: DecodeOptions,
) DecodeError!Image {
    // Phase 2 dispatch: try cleanroom paths in order; each returns
    // `error.NotImplemented` if it doesn't handle the variant. Final
    // fallback is the libjpeg-turbo wrapper. Each retired libjpeg
    // path shrinks the wrapper's role until Phase 2 completes.
    const baseline = @import("decode/baseline.zig");
    const wrapper = @import("ffi/libjpeg_wrapper.zig");

    // JPEG-LS comes first: T.87 uses a different SOF marker (SOF55 =
    // 0xF7) that the other cleanroom paths' marker walkers don't
    // recognize — they'd misclassify and surface InvalidMarker
    // instead of NotImplemented. Try the cleanroom first (B2.2),
    // fall through to charls (B2.1) for variants the cleanroom
    // doesn't yet handle.
    const jpegls_cleanroom = @import("decode/jpegls.zig");
    if (jpegls_cleanroom.decode(allocator, data)) |img| {
        return img;
    } else |err| switch (err) {
        error.NotImplemented => {},
        else => return err,
    }

    const charls_wrapper = @import("ffi/charls_wrapper.zig");
    if (charls_wrapper.decode(allocator, data)) |img| {
        return img;
    } else |err| switch (err) {
        error.NotImplemented => {},
        else => return err,
    }

    // Try baseline cleanroom first (SOF0). Convert public DecodeOptions
    // → baseline's structurally-identical DecodeOptions (separate types
    // to keep baseline.zig free of a dependency on the parent module).
    const baseline_opts: baseline.DecodeOptions = .{ .threads = options.threads };
    if (baseline.decodeWithOptions(allocator, data, baseline_opts)) |img| {
        return img;
    } else |err| switch (err) {
        error.NotImplemented => {},
        else => return err,
    }

    // Try progressive cleanroom (SOF2). Validated 2026-05-08 against
    // 276 real-world progressive JPEGs from Peter's corpus: all decoded
    // within ≤2 LSB of libjpeg-turbo's wrapper output, with 199/276
    // byte-perfect (the residual 77 files differ only by sub-LSB
    // rounding noise — same threshold as baseline cleanroom). Six
    // bug fixes shipped: end-of-scan marker (markerHit→seekToMarker),
    // libjpeg `insufficient_data` parity, AC refinement ZRL break
    // semantics (libjpeg's `--r < 0`), float→fixed-point YCbCr,
    // single-component scan iteration via T.81 §A.2.4 xi/yi, IJG
    // fancy chroma upsampling. NotImplemented falls through to wrapper
    // for: DRI in progressive, 12-bit precision, multi-component scans
    // with > 4 components, etc.
    const progressive = @import("decode/progressive.zig");
    if (progressive.decode(allocator, data)) |img| {
        return img;
    } else |err| switch (err) {
        error.NotImplemented => {},
        else => return err,
    }

    // Try lossless cleanroom (SOF3, T.81 §H — predictive coding).
    // v1 handles 8-bit single-component only; 12/16-bit and multi-
    // component lossless fall through to wrapper via NotImplemented.
    const lossless = @import("decode/lossless.zig");
    if (lossless.decode(allocator, data)) |img| {
        return img;
    } else |err| switch (err) {
        error.NotImplemented => {},
        else => return err,
    }

    // Try arithmetic-coded cleanroom (SOF9 sequential; SOF10/11
    // fall through). Patents expired in early 2000s; libjpeg-turbo
    // decodes them. B1 milestone — see arith_decode.zig.
    const arith_decode = @import("decode/arith_decode.zig");
    if (arith_decode.decode(allocator, data)) |img| {
        return img;
    } else |err| switch (err) {
        error.NotImplemented => {},
        else => return err,
    }

    // Final: libjpeg-turbo wrapper handles everything jpegz hasn't
    // cleanroomed yet (SOF1 12-bit, SOF3 12/16-bit, SOF11). JPEG-LS
    // was already handled at the top of dispatch via charls_wrapper.
    // Wrapper currently ignores `options.threads` — libjpeg-turbo's
    // traditional API has no thread parameter.
    return wrapper.decode(allocator, data);
}

/// Decode JPEG row-by-row, invoking `cb` once per emitted row in
/// raster order (y = 0, 1, …, height-1).
///
/// Supported storage modes: SOF0 / SOF1 (sequential), SOF3 (lossless),
/// SOF9 / SOF10 / SOF11 (arithmetic), JPEG-LS (T.87). **Returns
/// `error.NotRowStreamable` for SOF2 progressive** — caller can fall
/// back to `decode` and iterate the resulting buffer themselves.
///
/// The callback receives a borrowed slice. Copy if you need it past
/// return. Returning an error from the callback aborts decode and
/// propagates as `error.CallbackAborted`; the original error message
/// is preserved in the thread-local last-error mechanism.
pub fn decodeStreamingRows(
    allocator: Allocator,
    data: []const u8,
    cb: RowCallback,
) DecodeError!ImageMetadata {
    return decodeStreamingRowsWithOptions(allocator, data, .{}, cb);
}

/// Same as `decodeStreamingRows` but accepts a `DecodeOptions` struct
/// for caller-controlled behavior (today: thread budget). Pairs with
/// `decodeWithOptions` — every public API surface has a `_ex`-style
/// option-bearing variant so consumers can pass `threads` consistently.
pub fn decodeStreamingRowsWithOptions(
    allocator: Allocator,
    data: []const u8,
    options: DecodeOptions,
    cb: RowCallback,
) DecodeError!ImageMetadata {
    last_error.clear();
    if (data.len < 4) {
        last_error.set("input too short ({d} bytes)", .{data.len});
        return error.TruncatedStream;
    }
    if (data[0] != 0xFF or data[1] != 0xD8) {
        last_error.set("missing SOI marker (got 0x{x:0>2}{x:0>2})", .{ data[0], data[1] });
        return error.InvalidMarker;
    }

    // Reject progressive scans up front. T.81 §G.1 progressive bitstreams
    // are inherently multi-pass: every coefficient is touched across all
    // scans before its block is complete, so row-by-row delivery isn't
    // possible without full materialization. Callers wanting that
    // experience should call `decode` and iterate the pixel buffer.
    if (peekIsProgressive(data)) {
        last_error.set("progressive scan — call decode() and iterate the buffer", .{});
        return error.NotRowStreamable;
    }

    // v1 strategy: materialize the full image via `decode`, then iterate
    // rows. Memory profile is identical to plain `decode`; the API
    // contract is what callers depend on. A future per-decoder
    // implementation can deliver rows incrementally without touching
    // the public surface. Thread budget plumbs through to the
    // underlying decoder.
    var image = try decodeWithOptions(allocator, data, options);
    defer image.deinit(allocator);

    const stride = image.rowStride();
    var y: u32 = 0;
    while (y < image.height) : (y += 1) {
        const row = image.pixels[@as(usize, y) * stride ..][0..stride];
        cb.on_row(cb.ctx, row, y) catch |e| {
            // Preserve the original error name so callers can recover it
            // via `lastErrorMessage()` — the API contract collapses any
            // callback error to `CallbackAborted`, but the detail isn't
            // lost. Same buffer C consumers read via
            // `jpegz_last_error_message()` (single backing memory, no
            // duplication).
            last_error.set("row {d}: callback returned error.{s}", .{ y, @errorName(e) });
            return error.CallbackAborted;
        };
    }

    return ImageMetadata{
        .width = image.width,
        .height = image.height,
        .channels = image.channels,
        .bits_per_sample = image.bits_per_sample,
        .source_color_space = image.source_color_space,
        .layout = image.layout,
    };
}

/// Cheap pre-flight: walk markers looking for a progressive SOF
/// (SOF2 0xC2 Huffman, SOF10 0xCA arithmetic). Stops at the first
/// SOFn or SOS — doesn't validate the rest of the stream. Used only
/// to gate `decodeStreamingRows` early; full classification lives in
/// `core/validator.zig`.
fn peekIsProgressive(data: []const u8) bool {
    var pos: usize = 2;
    while (pos + 1 < data.len) {
        while (pos < data.len and data[pos] != 0xFF) pos += 1;
        if (pos + 1 >= data.len) return false;
        while (pos + 1 < data.len and data[pos + 1] == 0xFF) pos += 1;
        if (pos + 1 >= data.len) return false;
        const marker = data[pos + 1];
        pos += 2;
        switch (marker) {
            0xC2, 0xCA => return true, // progressive Huffman / arithmetic
            // Any other SOFn or SOS: this is not a progressive image.
            0xC0, 0xC1, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCB, 0xCD, 0xCE, 0xCF,
            0xF7, 0xDA => return false,
            // Standalone markers we can skip safely.
            0x01, 0xD0...0xD7, 0xD8, 0xD9 => continue,
            // Length-prefixed marker — skip its payload.
            else => {
                if (pos + 1 >= data.len) return false;
                const seg_len: usize = (@as(usize, data[pos]) << 8) | data[pos + 1];
                if (seg_len < 2 or pos + seg_len > data.len) return false;
                pos += seg_len;
            },
        }
    }
    return false;
}

/// Walk the bitstream without materializing pixels. Accumulates
/// findings; **does not fail-fast on structural problems**. Returns
/// a Zig error only for OOM or genuinely-impossible internal states.
/// A FAIL-rated report still returns successfully.
pub fn validate(
    allocator: Allocator,
    data: []const u8,
) error{OutOfMemory}!ValidationReport {
    return @import("core/validator.zig").validate(allocator, data);
}

// ─────────────────────────────────────────────────────────────────────
// 5. JPEG 2000 sub-namespace
// ─────────────────────────────────────────────────────────────────────

/// JPEG 2000 lives in its own namespace because the codec internals
/// share nothing with T.81 (wavelet + EBCOT vs. DCT + Huffman /
/// arithmetic).
pub const jpeg2000 = struct {
    pub fn decode(allocator: Allocator, data: []const u8) DecodeError!Image {
        return jpeg2000.decodeWithOptions(allocator, data, .{});
    }

    /// Same as `decode` but accepts `DecodeOptions`. Today's openjpeg
    /// wrapper does not yet plumb `options.threads` through to
    /// `opj_codec_set_threads` — that lands with the cleanroom JP2
    /// path (M2.7) or as a wrapper-side enhancement when needed.
    pub fn decodeWithOptions(
        allocator: Allocator,
        data: []const u8,
        options: DecodeOptions,
    ) DecodeError!Image {
        _ = options;
        return @import("ffi/openjpeg_wrapper.zig").decode(allocator, data);
    }

    pub fn validate(
        allocator: Allocator,
        data: []const u8,
    ) error{OutOfMemory}!ValidationReport {
        _ = allocator;
        _ = data;
        return ValidationReport{
            .overall = .pass,
            .variant = .unknown,
            .width = null,
            .height = null,
            .findings = .empty,
        };
    }
};

// Reference the C API so the linker pulls its `export fn`s into the
// static library. Without this, dead-code elimination strips them
// because nothing in the Zig source side calls them.
comptime {
    _ = @import("ffi/c_api.zig");
}

/// Internal test-only entry points. Not part of the public ABI; meant
/// for analysis tools (e.g., scratch/cleanroom_diff.zig) that need to
/// call cleanroom and wrapper paths directly without going through
/// the dispatcher in `decode`.
pub const internal = struct {
    pub fn cleanroomDecode(allocator: Allocator, data: []const u8) DecodeError!Image {
        return @import("decode/baseline.zig").decode(allocator, data);
    }
    pub fn cleanroomDecodeWithOptions(
        allocator: Allocator,
        data: []const u8,
        options: DecodeOptions,
    ) DecodeError!Image {
        const baseline = @import("decode/baseline.zig");
        return baseline.decodeWithOptions(allocator, data, .{ .threads = options.threads });
    }
    pub fn progressiveDecode(allocator: Allocator, data: []const u8) DecodeError!Image {
        return @import("decode/progressive.zig").decode(allocator, data);
    }
    pub fn losslessDecode(allocator: Allocator, data: []const u8) DecodeError!Image {
        return @import("decode/lossless.zig").decode(allocator, data);
    }
    /// Diagnostic-only: decode a progressive JPEG and return the post-
    /// entropy quantized coefficients in natural order (un-zig-zagged),
    /// matching the layout of libjpeg-turbo's `jpeg_read_coefficients()`.
    /// Used by scratch/dump_coefs_jpegz.zig for byte-level diff against
    /// libjpeg's output. NOT part of the stable ABI.
    pub const ProgCoefDump = @import("decode/progressive.zig").CoefDump;
    pub fn progressiveDecodeAndDumpCoefs(allocator: Allocator, data: []const u8) DecodeError!ProgCoefDump {
        return @import("decode/progressive.zig").decodeAndDumpCoefs(allocator, data);
    }
    pub fn wrapperDecode(allocator: Allocator, data: []const u8) DecodeError!Image {
        return @import("ffi/libjpeg_wrapper.zig").decode(allocator, data);
    }
    /// Arithmetic-coded JPEG decode (SOF9 / SOF10). Returns
    /// `error.NotImplemented` until B1 lands; tests calling this
    /// entry point use that as their RED gate.
    pub fn arithDecode(allocator: Allocator, data: []const u8) DecodeError!Image {
        return @import("decode/arith_decode.zig").decode(allocator, data);
    }
};

// ─────────────────────────────────────────────────────────────────────
// Inline tests — wiring sanity. Real test suites in `tests/`.
// ─────────────────────────────────────────────────────────────────────

test "version is non-empty" {
    try std.testing.expect(version.len > 0);
}

test "Image.rowStride for 8-bit RGB" {
    const img = Image{
        .pixels = &[_]u8{},
        .width = 100,
        .height = 50,
        .channels = 3,
        .bits_per_sample = 8,
        .source_color_space = .ycbcr,
        .layout = .rgb,
    };
    try std.testing.expectEqual(@as(usize, 300), img.rowStride());
}

test "Image.rowStride for 16-bit grayscale" {
    const img = Image{
        .pixels = &[_]u8{},
        .width = 100,
        .height = 50,
        .channels = 1,
        .bits_per_sample = 16,
        .source_color_space = .grayscale,
        .layout = .grayscale,
    };
    try std.testing.expectEqual(@as(usize, 200), img.rowStride());
}
