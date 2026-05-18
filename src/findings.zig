//! Informational findings emitted to a caller-supplied callback
//! during decode. Used by `validate` (the primary downstream
//! consumer) to populate per-file finding accumulators alongside the
//! `RoutedFinding` taxonomy in `docs/tiffz_findings_mapping.md`.
//!
//! The shape mirrors jpegz's callback API so consumers can share a
//! single dispatch pattern across both decoders:
//!
//!   void cb(void *userdata, int finding_id, const void *payload, size_t payload_len)
//!
//! INFO findings are PASS-tier observations — files that decode
//! successfully but have a property worth annotating. Failures are
//! reported via the `errors.Error` return path, not the callback.
//!
//! Per-finding semantics:
//!
//!   bigtiff_format        — payload empty. Fires once per Decoder.
//!   multi_ifd_chain       — payload u32 LE (IFD count). Fires when
//!                           ifd(N) materializes a chain entry beyond
//!                           IFD 0; fires AGAIN per subsequent N.
//!                           Consumer dedupes if it only wants the
//!                           first signal.
//!   old_style_lzw_codes   — payload empty. Fires once per Decoder
//!                           (first strip where the LZW codec falls
//!                           back from new-style to old-style).
//!   pre_multiplied_alpha  — payload empty. Fires per IFD that has
//!                           ExtraSamples=1 (associated alpha).
//!   predictor_applied     — payload u32 LE (predictor value, 2 or 3).
//!                           Fires per IFD with Predictor != 1.
//!   geotiff_tags_present  — payload empty. Fires per IFD with any
//!                           known GeoTIFF tag.
//!   cfa_pattern_present   — payload empty. Fires per IFD with
//!                           photometric=CFA or a CFAPattern tag.
//!   opcode_list_present   — payload u32 LE (opcode count). Fires once
//!                           per opcode list (1/2/3) per IFD.
//!   jpeg_in_tiff          — payload empty. Fires per IFD with
//!                           Compression=7.
//!   tiled_layout          — payload empty. Fires per IFD with a
//!                           TileOffsets tag.
//!   planar_separate       — payload empty. Fires per IFD with
//!                           PlanarConfiguration=2.

/// Stable u32 codes for tiffz INFO findings. Codes never change once
/// assigned; new findings append at the end. Validate's
/// `tiffz_shim.zig` maps these to its own `TiffzInfoFinding` enum
/// per `docs/tiffz_findings_mapping.md`.
pub const InfoFinding = enum(u32) {
    bigtiff_format = 1,
    multi_ifd_chain = 2,
    old_style_lzw_codes = 3,
    pre_multiplied_alpha = 4,
    predictor_applied = 5,
    geotiff_tags_present = 6,
    cfa_pattern_present = 7,
    opcode_list_present = 8,
    jpeg_in_tiff = 9,
    tiled_layout = 10,
    planar_separate = 11,
    _,
};

/// C-callable callback. tiffz passes the InfoFinding code as an
/// `i32` so it round-trips cleanly through the C ABI's `int`.
/// `payload` is null and `payload_len` is 0 for presence-only
/// findings; for findings with a numeric payload the byte layout is
/// little-endian (documented above per finding).
pub const Callback = ?*const fn (
    userdata: ?*anyopaque,
    finding: i32,
    payload: ?[*]const u8,
    payload_len: usize,
) callconv(.c) void;
