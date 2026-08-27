//! Informational findings emitted to a caller-supplied callback
//! during decode. Used by `validate` (the primary downstream
//! consumer) to populate per-file finding accumulators alongside the
//! `RoutedFinding` taxonomy in `docs/tiffz_findings_mapping.md`.
//!
//! The callback carries a typed producer, raw and optional mapped codes,
//! four-way verdict, and presence-flagged leaf/host offsets. This keeps nested
//! JPEG-family findings intact rather than flattening numeric namespaces.
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
///
/// **Cross-board ruling 2026-06-29 (Einstein):** These codes form
/// **Namespace B** in the shared cross-decoder registry. They are
/// DISJOINT from Namespace A (jpegz + jp2z share that one), and
/// validate disambiguates findings by the emitting decoder — so
/// e.g. tiffz `1 bigtiff_format` and jpegz `1 missing_soi` do NOT
/// collide. Never renumber 1–11 to avoid Namespace A; do NOT add
/// new codes without Einstein's sign-off (drop a note in
/// `~/Code/inbox/`). Future JP2-in-TIFF path (`Compression 33003 /
/// 33005`) must keep nested jpegz/jp2z findings tagged in
/// Namespace A — never flatten them into this enum — to preserve
/// the (decoder, code) pair through the seam.
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
    /// Compression=34887 present on any IFD (LERC-in-TIFF, Esri /
    /// GDAL / libtiff extension). Payload empty. Allocated by
    /// Einstein 2026-07-19 per Namespace B convention. The
    /// Deflate/Zstd post-filter distinction (LercParameters bit 1)
    /// is deliberately not surfaced as a separate finding.
    lerc_compression = 12,
    /// A final strip decoded beyond its logical row extent but no farther
    /// than one full RowsPerStrip chunk. Accept with a caller-routed warning.
    final_strip_padding_tolerated = 13,
    /// An LZW stream reached a clean physical EOF without EOD after producing
    /// exactly the bounded TIFF extent. Accept with a caller-routed warning.
    lzw_missing_eod_tolerated = 14,
    /// Tile geometry used strip offset/count tags only. Accepted under the
    /// bounded compatibility classifier and surfaced exactly once per file.
    tiled_geometry_via_strip_tags_tolerated = 15,
    /// An otherwise well-formed IFD uses a compression tiffz deliberately
    /// never supports (e.g. old-style JPEG, Compression=6); the walk skipped
    /// its chunks and continued — the file may still validate OK with this
    /// portion honestly uncovered (Peter's partial-coverage ruling,
    /// 2026-08-27). Emitted once PER SKIPPED IFD. Payload: 8 bytes,
    /// u32 LE IFD index then u32 LE compression code.
    unsupported_compression_skipped = 16,
    _,
};

/// C-callable callback. tiffz passes the InfoFinding code as an
/// `i32` so it round-trips cleanly through the C ABI's `int`.
/// `payload` is null and `payload_len` is 0 for presence-only
/// findings; for findings with a numeric payload the byte layout is
/// little-endian (documented above per finding).
/// Append-only producer registry. The non-exhaustive enum preserves unknown
/// future values rather than collapsing them into a known decoder.
pub const SourceDecoder = enum(i32) {
    unknown = 0,
    tiffz = 1,
    jpegz = 2,
    jp2z = 3,
    libjxlz = 4,
    _,
};

/// Four-way validation outcome. Native informational/tolerance findings use
/// `valid`; strict nested validators preserve all four values unchanged.
pub const Verdict = enum(i32) {
    valid = 0,
    corrupt = 1,
    unsupported = 2,
    indeterminate = 3,
    _,
};

/// Presence and exactness bits for the callback's scalar metadata fields.
pub const MetadataFlags = struct {
    pub const mapped_code_present: u32 = 1 << 0;
    pub const byte_offset_present: u32 = 1 << 1;
    pub const host_offset_present: u32 = 1 << 2;
    pub const offset_is_exact: u32 = 1 << 3;
};

/// Preserve a strict facade finding's own outcome instead of deriving one from
/// the aggregate result. Unknown mapped JP2 codes and future JXL leaf codes
/// fail closed as indeterminate.
pub fn strictFindingVerdict(finding: @import("jpegz").StrictFinding) Verdict {
    const jpegz = @import("jpegz");
    return switch (finding.source) {
        .jp2z => if (finding.code == null)
            .indeterminate
        else if (finding.code.? == jpegz.FindingCode.jp2_unsupported_marker_ignored)
            .unsupported
        else if (finding.severity == .fail)
            .corrupt
        else
            .valid,
        .libjxlz => switch (finding.leaf_code) {
            1, 2, 3 => .corrupt,
            4 => .unsupported,
            5, 6, 7, 8 => .indeterminate,
            else => .indeterminate,
        },
        // jpegz's own cleanroom T.81/T.87 leg (validateAny, added 2026-08-06),
        // plus its validateAny meta-findings. Mirror jpegz.strictFromReport: a
        // deviation the decoder recovers from (.warn/.info) is not corruption,
        // only .fail is; the two validator-meta codes are indeterminate.
        .jpegz => if (finding.severity == .fail)
            .corrupt
        else if (finding.code) |c| switch (c) {
            .unrecognized_container, .jxl_validator_unavailable => .indeterminate,
            else => .valid,
        } else .valid,
    };
}

/// C-callable finding callback. `(source_decoder, finding_code)` is the stable
/// identity; mapped codes and offsets are explicitly presence-flagged so zero
/// remains a legitimate value. Unknown source/verdict integers round-trip.
pub const Callback = ?*const fn (
    userdata: ?*anyopaque,
    source_decoder: i32,
    finding_code: i32,
    mapped_finding_code: i32,
    verdict: i32,
    byte_offset: u64,
    host_byte_offset: u64,
    metadata_flags: u32,
    payload: ?[*]const u8,
    payload_len: usize,
) callconv(.c) void;
