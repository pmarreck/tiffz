//! Public error vocabulary for jpegz. Single source of truth.
//!
//! Numeric values (in the comments / `enum(u32)` declarations) are
//! STABLE FOREVER — new entries APPEND, never reorder, never reuse a
//! freed value. The C header generator (`tools/gen_c_header.zig`)
//! reads this file at comptime; un-mapped Zig errors break the FFI
//! mapper at compile time. See
//! `docs/superpowers/specs/2026-05-04-jpegz-public-api-design.md` §4.

/// API-level error set returned by `decode`, `decodeStreamingRows`,
/// `jpeg2000.decode`, and the C ABI mapper. The C side gets the
/// negative-coded mirror in `jpegz_status_t`.
pub const DecodeError = error{
    NotImplemented,          // C: -1
    InvalidMarker,           // C: -2
    UnsupportedPrecision,    // C: -3
    TruncatedStream,         // C: -4
    NotRowStreamable,        // C: -5
    BackendError,            // C: -6
    InvalidJp2Codestream,    // C: -7
    OutOfMemory,             // C: -8
    CallbackAborted,         // C: -9
};

/// Severity tier for `Finding`s in a `ValidationReport`. Mirrors the
/// validate project's PASS/INFO/WARN/FAIL vocabulary.
pub const Severity = enum(u8) {
    pass = 0,
    /// Notable observation; image is valid (e.g., "12-bit precision
    /// detected", "arithmetic coding used"). Surfaces info validate
    /// may want to annotate.
    info = 1,
    /// Tolerated deviation; image decodes but violates a non-critical
    /// spec requirement (e.g., missing optional APPn marker).
    warn = 2,
    /// Cannot decode or structurally broken.
    fail = 3,
};

/// JPEG storage variant detected during validation. Useful even when
/// `overall == .fail` — caller knows what was being attempted.
pub const Variant = enum(u8) {
    unknown                = 0,
    baseline_huffman       = 1,  // SOF0
    extended_huffman       = 2,  // SOF1
    progressive_huffman    = 3,  // SOF2
    lossless_huffman       = 4,  // SOF3
    baseline_arithmetic    = 5,  // SOF9
    progressive_arithmetic = 6,  // SOF10
    lossless_arithmetic    = 7,  // SOF11
    jpegls                 = 8,  // SOF55 (T.87)
    jpeg2000               = 9,  // JP2 / J2K
};

/// Symbolic codes for a `Finding` in a `ValidationReport`. The numeric
/// `enum(u32)` value is the wire format used by the C ABI; see the
/// `JPEGZ_FINDING_*` enum in the auto-generated `jpegz_errno.h`.
pub const FindingCode = enum(u32) {
    // ── Structural (1..49) ───────────────────────────────────────
    missing_soi                  = 1,
    missing_eoi                  = 2,
    truncated_stream             = 3,
    bad_marker_length            = 4,
    unknown_marker               = 5,
    duplicate_sof                = 6,
    // libjpeg-style entropy-data exhaustion the decoder zero-pads
    // through (JWRN_HIT_MARKER / JWRN_JPEG_EOF). File is structurally
    // complete but a block could not be filled — usually emitted at
    // severity=warn by validate(...). See NEXT_STEPS.md §"Validation-
    // strictness: warns over silent tolerance".
    insufficient_data            = 7,
    // libjpeg JWRN_EXTRANEOUS_DATA: "Corrupt JPEG data: N extraneous
    // bytes before marker 0xXX". The decoder skips them and resumes,
    // but the bytes are spec violations worth flagging.
    extraneous_bytes_before_marker = 8,

    // ── T.81 codec-specific (50..99) ─────────────────────────────
    invalid_sof_precision       = 50,
    huffman_table_corrupt       = 51,
    quantization_table_corrupt  = 52,
    arithmetic_table_corrupt    = 53,
    sof_component_count_invalid = 54,
    sos_component_mismatch      = 55,
    restart_marker_missing      = 56,
    restart_marker_unexpected   = 57,
    dct_coefficient_overflow    = 58,
    progressive_scan_invalid    = 59,

    // ── Lossless (T.81 §13) (100..119) ───────────────────────────
    lossless_predictor_invalid       = 100,
    lossless_pointtransform_invalid  = 101,

    // ── JPEG-LS (T.87) (120..139) ────────────────────────────────
    jpegls_invalid_run_mode      = 120,
    jpegls_context_table_invalid = 121,

    // ── JPEG 2000 (140..179) ─────────────────────────────────────
    jp2_invalid_signature        = 140,
    jp2_invalid_codestream       = 141,
    jp2_bad_progression_order    = 142,
    jp2_tile_decode_failed       = 143,
    jp2_codeblock_decode_failed  = 144,

    // ── Informational (severity = .info) (200..249) ──────────────
    arithmetic_coding_used     = 200,
    twelve_bit_precision       = 201,
    sixteen_bit_lossless       = 202,
    progressive_scan_count     = 203,
    embedded_thumbnail_present = 204,
    exif_metadata_present      = 205,
    icc_profile_present        = 206,
    jp2_uses_9x7_wavelet       = 207,
    jp2_uses_5x3_wavelet       = 208,
    // Added per validate handoff (2026-05-06): APPn presence flags
    // and trailing-data signal. validate's PDF / metadata pipeline
    // consumes these. See validator.zig's APPn signature scan.
    jfif_metadata_present      = 209,
    xmp_metadata_present       = 210,
    photoshop_irb_present      = 211,
    trailing_data_after_eoi    = 212,
};
