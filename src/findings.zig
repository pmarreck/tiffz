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
    /// Trailing stored bytes past the logical sample grid. A short final
    /// strip may reach one full RowsPerStrip chunk. A complete chunk may
    /// carry one further row. Accept with a caller-routed warning.
    final_strip_padding_tolerated = 13,
    /// An LZW stream reached a clean physical EOF without EOD after producing
    /// exactly the bounded TIFF extent. Accept with a caller-routed warning.
    lzw_missing_eod_tolerated = 14,
    /// Tile geometry used strip offset/count tags only. Accepted under the
    /// bounded compatibility classifier and surfaced exactly once per file.
    tiled_geometry_via_strip_tags = 15,
    /// An otherwise well-formed IFD uses a compression tiffz deliberately
    /// never supports (e.g. old-style JPEG, Compression=6); the walk skipped
    /// its chunks and continued — the file may still validate OK with this
    /// portion honestly uncovered (Peter's partial-coverage ruling,
    /// 2026-08-27). Emitted once PER SKIPPED IFD. Payload: 8 bytes,
    /// u32 LE IFD index then u32 LE compression code.
    unsupported_compression_skipped = 16,
    /// An IFD entry's tag is not larger than the tag before it (TIFF 6.0
    /// p. 15 requires strictly ascending order). Usually a corrupted tag
    /// ID, whose lost value the decoder then replaces with the default.
    /// Verdict corrupt: validation fails Malformed after the walk (validate
    /// ruling, 2026-11-03). Once per offending entry. Payload: 20 bytes,
    /// see `ifd_conformance.unsorted_payload_len`. The finding's byte offset
    /// is the entry's, exact.
    ifd_entries_unsorted = 17,
    /// An entry's type, count or value violates its tag's rule in
    /// `ifd_conformance.rules`. Verdict corrupt, as for 17. Once per
    /// offending entry. Payload: 38 bytes, or 48 for reason 4
    /// (`channel_mismatch`); see `ifd_conformance.field_invalid_payload_len`.
    tag_field_invalid = 18,
    /// A Compression 7 (JPEG-in-TIFF) segment whose frame header disagrees with
    /// the TIFF fields TIFF Technical Note 2 binds it to: RowsPerStrip or tile
    /// sizes not in whole MCUs for a DCT SOF, or SOF sampling factors that do
    /// not match YCbCrSubSampling or PlanarConfiguration. Verdict corrupt, as
    /// for 17. One record per IFD per rule, with counts. Payload: 44 bytes,
    /// see `jpeg_geometry.payload_len`. The finding's byte offset is the first
    /// violating segment's SOF marker, exact.
    jpeg_segment_geometry_invalid = 19,
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

/// Validation outcome. Native informational/tolerance findings use `valid`;
/// strict nested validators' outcomes pass through unchanged. `known_defect`
/// (appended to match jpegz's KNOWN_DEFECT wire value) is a recognized encoder
/// defect: the data decodes, and the consumer decides how to treat it.
pub const Verdict = enum(i32) {
    valid = 0,
    corrupt = 1,
    unsupported = 2,
    indeterminate = 3,
    known_defect = 4,
    _,
};

/// jpegz's own verdict for one finding from its T.81/T.87 validator
/// (`jpegz.classicFindingVerdict`, exported at jpegz 37231b9), so a TIFF
/// consumer sees the codec's judgment per finding. Recovered truncation and
/// restart faults are corruption whatever their severity, all-zero Huffman
/// padding and any finding at known_defect severity are a known defect (jpegz
/// c77f514), and an unknown marker leaves the outcome indeterminate. These are per-finding
/// labels: never fold them into a report verdict by taking the worst one.
pub fn classicFindingVerdict(code: @import("jpegz").FindingCode, severity: @import("jpegz").Severity) Verdict {
    return fromStrictVerdict(@import("jpegz").classicFindingVerdict(code, severity));
}

/// The same outcome as a tiffz Verdict. The switch is exhaustive, so a
/// verdict jpegz appends fails to compile here until tiffz maps it.
pub fn fromStrictVerdict(verdict: @import("jpegz").StrictVerdict) Verdict {
    return switch (verdict) {
        .valid => .valid,
        .corrupt => .corrupt,
        .unsupported => .unsupported,
        .indeterminate => .indeterminate,
        .known_defect => .known_defect,
    };
}

/// Presence and exactness bits for the callback's scalar metadata fields.
pub const MetadataFlags = struct {
    pub const mapped_code_present: u32 = 1 << 0;
    pub const byte_offset_present: u32 = 1 << 1;
    pub const host_offset_present: u32 = 1 << 2;
    pub const offset_is_exact: u32 = 1 << 3;
};

/// Preserve a strict facade finding's own outcome instead of deriving one from
/// the aggregate result. Unknown mapped JP2 codes and future JXL leaf codes
/// fail closed as indeterminate. JPEG XL padding (9) and truncated box-header
/// (13) stay corrupt even when jpegz reports them at warning severity.
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
            1, 2, 3, 9, 10, 11, 12, 13, 14, 15, 16 => .corrupt,
            4 => .unsupported,
            5, 6, 7, 8 => .indeterminate,
            else => .indeterminate,
        },
        // jpegz's own cleanroom T.81/T.87 leg (validateAny, added 2026-08-06),
        // plus its validateAny meta-findings.
        .jpegz => if (finding.code) |c|
            classicFindingVerdict(c, finding.severity)
        else if (finding.severity == .fail)
            .corrupt
        else
            .valid,
    };
}

test "classic JPEG finding verdict follows jpegz's classification over every code and severity" {
    // The rules tiffz relies on, as a literal table independent of jpegz's
    // implementation: any fail is corrupt; recovered truncation and restart
    // faults are corrupt at any severity (BDFN, 2026-11-03: a fault the
    // decoder works around is corrupt or a known defect, never a warning);
    // all-zero Huffman padding, and any finding at known_defect severity that
    // is not corrupt class, is a known defect (validate 2026-11-06: a known
    // defect is independent of WARN and FAIL); an unknown marker leaves the
    // result indeterminate, as do the two validateAny meta-findings. An
    // unchecked JFIF version is a WARN-class deviation, so valid (validate
    // 2026-11-05). Everything else a decoder recovers from is valid. A jpegz change to any of these fails here.
    @setEvalBranchQuota(100_000);
    const testing = @import("std").testing;
    const jpegz = @import("jpegz");
    const C = jpegz.FindingCode;
    const always_corrupt = [_]C{ .missing_eoi, .insufficient_data, .restart_marker_missing, .restart_marker_unexpected };
    const indeterminate = [_]C{ .unknown_marker, .unrecognized_container, .jxl_validator_unavailable };
    inline for (@typeInfo(C).@"enum".fields) |field| {
        const code: C = @field(C, field.name);
        inline for (@typeInfo(jpegz.Severity).@"enum".fields) |sev_field| {
            const severity: jpegz.Severity = @field(jpegz.Severity, sev_field.name);
            const expected: Verdict = if (severity == .fail or comptime contains(&always_corrupt, code))
                .corrupt
            else if (severity == .known_defect or code == .entropy_padding_zero_bits)
                .known_defect
            else if (comptime contains(&indeterminate, code))
                .indeterminate
            else
                .valid;
            testing.expectEqual(expected, classicFindingVerdict(code, severity)) catch |err| {
                @import("std").debug.print("code {s} severity {s}\n", .{ field.name, sev_field.name });
                return err;
            };
        }
    }
}

fn contains(comptime set: []const @import("jpegz").FindingCode, code: @import("jpegz").FindingCode) bool {
    for (set) |member| if (member == code) return true;
    return false;
}

test "strict JXL finding verdict classifies the complete known code set" {
    const testing = @import("std").testing;
    const Case = struct {
        leaf_code: u32,
        expected: Verdict,
    };
    const cases = [_]Case{
        .{ .leaf_code = 1, .expected = .corrupt },
        .{ .leaf_code = 2, .expected = .corrupt },
        .{ .leaf_code = 3, .expected = .corrupt },
        .{ .leaf_code = 4, .expected = .unsupported },
        .{ .leaf_code = 5, .expected = .indeterminate },
        .{ .leaf_code = 6, .expected = .indeterminate },
        .{ .leaf_code = 7, .expected = .indeterminate },
        .{ .leaf_code = 8, .expected = .indeterminate },
        .{ .leaf_code = 9, .expected = .corrupt },
        .{ .leaf_code = 10, .expected = .corrupt },
        .{ .leaf_code = 11, .expected = .corrupt },
        .{ .leaf_code = 12, .expected = .corrupt },
        .{ .leaf_code = 13, .expected = .corrupt },
        .{ .leaf_code = 14, .expected = .corrupt },
        .{ .leaf_code = 15, .expected = .corrupt },
        .{ .leaf_code = 16, .expected = .corrupt },
        .{ .leaf_code = 999, .expected = .indeterminate },
    };

    for (cases) |case| {
        const finding = @import("jpegz").StrictFinding{
            .source = .libjxlz,
            .leaf_code = case.leaf_code,
            .code = null,
            .severity = .warn,
        };
        try testing.expectEqual(case.expected, strictFindingVerdict(finding));
    }
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
