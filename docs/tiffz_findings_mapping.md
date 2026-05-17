# Mapping table: tiffz FindingCode → validate routing

**From:** tiffz (2026-05-16 EST)
**Re:** M10 — validate integration. Replace validate's zigimg-based
TIFF deep-validation path with tiffz.
**Companion to:** the upcoming tiffz integration recipe (validate
side); modeled after
`~/Documents-CloudManaged/validate/inbox/2026-05-06-jpegz-mapping-table.md`.

This is the categorical translation table for the tiffz finding set,
analogous to jpegz's. Three output channels validate uses (per
`format_validation.zig`):

- **`ValidationErrorCode`** — terminal FAIL with a categorical code
- **`MalformationType`** — REPAIRABLE bit set in `malformations`
  `std.EnumSet` (for cases where the file is broken but recoverable)
- **`info_message` / `warning_message`** annotations on
  `ValidationResult` — INFO/WARN-tier observations that don't trip
  the validity bit

For tiffz v1, **no MalformationType bits are added** — tiffz's current
posture is that any TIFF requiring "repair" is a terminal FAIL.
Repairable-TIFF malformation bits can land later if validate
identifies specific repair workflows (e.g. patching the
`calRowByteSize` off-by-one in non-multiple-of-8 widths, or fixing
the libtiff aliased-strip-as-tile pattern that we hit during M6).

## Status of the tiffz finding emission

tiffz currently surfaces failures via its single `errors.Error` set
(see `src/errors.zig`). For M10 integration, the C ABI exports
`tiffz_status_t` codes (1:1 with the Zig error set per the frozen API
design). Each `tiffz_status_t` value below is its English-friendly
finding name in this table.

INFO-tier findings (file is structurally valid but has a noteworthy
property) need a finding-emission side channel. The current scaffold
exposes them as scalar getters on the Decoder (e.g.
`tiffz.Decoder.isBigTiff()`, `tiffz.Decoder.ifdCount()`); validate's
shim reads them after a successful decode and converts to
info_messages. A future `tiffz_findings.h` C header with a callback
API can replace this when the surface grows past a handful of fields.

## Routing taxonomy

| tiffz `FindingCode`               | Typical severity | Routes to                                                              |
|-----------------------------------|------------------|------------------------------------------------------------------------|
| **— Structural FAIL —**           |                  |                                                                        |
| `invalid_argument`                | fail             | `error_code = .invalid_value` (detail: "tiffz API argument")           |
| `malformed`                       | fail             | `error_code = .invalid_value` (detail: "TIFF structure")               |
| `source_too_short`                | fail             | `error_code = .file_too_small` (detail: "TIFF header")                 |
| `source_short_read`               | fail             | `error_code = .truncated` (detail: "TIFF strip/tile data")             |
| `source_seek_too_far_back`        | fail             | `error_code = .failed_to_seek`                                         |
| `io`                              | fail             | `error_code = .failed_to_read`                                         |
| **— Decoder-level FAIL —**        |                  |                                                                        |
| `unsupported_compression`         | fail             | `error_code = .unsupported` (detail: "TIFF Compression=N")             |
| `unsupported_photometric`         | fail             | `error_code = .unsupported` (detail: "TIFF Photometric=N")             |
| `unsupported_predictor`           | fail             | `error_code = .unsupported` (detail: "TIFF Predictor=N")               |
| `unsupported_bit_depth`           | fail             | `error_code = .unsupported` (detail: "TIFF BitsPerSample=N")           |
| `unsupported_tag_type`            | fail             | `error_code = .unsupported` (detail: "TIFF tag field type")            |
| `dest_too_small`                  | fail             | `error_code = .buffer_too_small`                                       |
| **— Resource-limit FAIL —**       |                  |                                                                        |
| `limit_exceeded_ifd_count`        | fail             | `error_code = .too_many` (detail: "TIFF IFDs")                         |
| `limit_exceeded_tag_count`        | fail             | `error_code = .too_many` (detail: "TIFF tags in one IFD")              |
| `limit_exceeded_tag_value_bytes`  | fail             | `error_code = .exceeds_bounds` (detail: "TIFF tag value")              |
| `limit_exceeded_strip_count`      | fail             | `error_code = .too_many` (detail: "TIFF strips")                       |
| `limit_exceeded_dimension`        | fail             | `error_code = .exceeds_bounds` (detail: "TIFF dimension")              |
| `limit_exceeded_total_samples`    | fail             | `error_code = .exceeds_bounds` (detail: "TIFF total pixels")           |
| `limit_exceeded_codec_scratch`    | fail             | `error_code = .exceeds_bounds` (detail: "TIFF codec scratch")          |
| `limit_exceeded_compressed_bytes` | fail             | `error_code = .exceeds_bounds` (detail: "TIFF compressed strip")       |
| `limit_exceeded_decompressed`     | fail             | `error_code = .exceeds_bounds` (detail: "TIFF decompressed strip")     |
| **— Allocation / internal —**     |                  |                                                                        |
| `out_of_memory`                   | fail             | `error_code = .out_of_memory`                                          |
| `bug`                             | fail             | `error_code = .other` (detail: "tiffz internal invariant violated")    |
| **— INFO annotations —**          |                  |                                                                        |
| `bigtiff_format`                  | info             | `info_message = "BigTIFF (64-bit offsets)"`                            |
| `multi_ifd_chain`                 | info             | `info_message = "multi-IFD TIFF (N pages)"`                            |
| `old_style_lzw_codes`             | info             | `info_message = "old-style LZW (libtiff fallback used)"`               |
| `pre_multiplied_alpha`            | info             | `info_message = "associated alpha (ExtraSamples=1)"`                   |
| `predictor_applied`               | info             | `info_message = "TIFF Predictor=N applied"`                            |
| `geotiff_tags_present`            | info             | `info_message = "GeoTIFF tags present"` (M11-gated; placeholder)       |
| `cfa_pattern_present`             | info             | `info_message = "CFA mosaic raw (DNG / TIFF-EP)"`                      |
| `opcode_list_present`             | info             | `info_message = "DNG opcode list (N opcodes)"`                         |
| `jpeg_in_tiff`                    | info             | `info_message = "JPEG-in-TIFF (Compression=7)"`                        |
| `tiled_layout`                    | info             | `info_message = "tiled layout (TileWidth×TileLength)"`                 |
| `planar_separate`                 | info             | `info_message = "separate planar configuration"`                       |

Notes on taxonomy:

- **`info_message`** is for "this file is valid; here's a noteworthy
  property" (PASS-tier observation). Maps to `okWithDepthAndInfo` in
  validate.
- **`warning_message`** is reserved for tool-tolerated deviations
  that validate may want to flag. For tiffz v1 there are no WARN-tier
  findings — anything that successfully decodes is currently treated
  as either OK or OK-with-INFO. If validate wants to flag the
  `old_style_lzw_codes` case as WARN (because the file is technically
  malformed and only readable thanks to libtiff's heuristic), that's
  a validate-side promotion, identical to jpegz's
  `trailing_data_after_eoi` precedent.
- **`malformation` bits** are not yet defined for TIFF in
  `MalformationType`. Candidate cases for future addition (each one
  requires a documented repair workflow):
  - `tiff_cal_rowbytes_off_by_one` — non-multiple-of-8 width with
    floor-division byte-per-row (the `calRowByteSize` bug). Repair:
    recalculate `(width + 7) / 8` and rewrite affected strip byte
    counts.
  - `tiff_strip_tags_aliased_as_tile` — TileWidth/TileLength set but
    data offsets in StripOffsets/StripByteCounts (libtiff-tolerant,
    tiffz-strict). Repair: rewrite as proper TileOffsets/
    TileByteCounts.

## `mapping.zig` snippet

Drop this into validate's `src/core/tiffz_shim.zig` (or a sibling
`tiffz_mapping.zig`) at integration time. Mirrors jpegz's snippet
exactly:

```zig
const std = @import("std");
const format_validation = @import("format_validation.zig");
const ValidationErrorCode = format_validation.ValidationErrorCode;
const MalformationType = format_validation.MalformationType;

const c = @cImport({
    @cInclude("tiffz.h");
});

pub const RoutedFinding = union(enum) {
    /// Terminal FAIL with categorical code; passes detail through.
    error_code: struct { code: ValidationErrorCode, detail: ?[]const u8 },
    /// Tool-tolerated deviation (WARN tier).
    warning: []const u8,
    /// PASS-tier observation worth annotating.
    info: []const u8,
    /// Repairable failure bit in `malformations` EnumSet.
    /// (No tiffz mappings yet — reserved for future repair workflows.)
    malformation: MalformationType,
    /// tiffz finding code that doesn't have a clean validate analogue.
    other: []const u8,
};

/// Map a tiffz status (terminal error code) to validate's routing
/// channel. INFO findings are surfaced via separate getter calls on
/// the Decoder after a successful decode — see `routeInfoFinding`.
pub fn routeStatus(status: c.tiffz_status_t) RoutedFinding {
    return switch (status) {
        // ── Structural FAIL ──
        c.TIFFZ_INVALID_ARGUMENT =>
            .{ .error_code = .{ .code = .invalid_value, .detail = "tiffz API argument" } },
        c.TIFFZ_MALFORMED =>
            .{ .error_code = .{ .code = .invalid_value, .detail = "TIFF structure" } },
        c.TIFFZ_SOURCE_TOO_SHORT =>
            .{ .error_code = .{ .code = .file_too_small, .detail = "TIFF header" } },
        c.TIFFZ_SOURCE_SHORT_READ =>
            .{ .error_code = .{ .code = .truncated, .detail = "TIFF strip/tile data" } },
        c.TIFFZ_SOURCE_SEEK_TOO_FAR_BACK =>
            .{ .error_code = .{ .code = .failed_to_seek, .detail = null } },
        c.TIFFZ_IO =>
            .{ .error_code = .{ .code = .failed_to_read, .detail = "TIFF source" } },

        // ── Decoder-level FAIL ──
        c.TIFFZ_UNSUPPORTED_COMPRESSION =>
            .{ .error_code = .{ .code = .unsupported, .detail = "TIFF Compression" } },
        c.TIFFZ_UNSUPPORTED_PHOTOMETRIC =>
            .{ .error_code = .{ .code = .unsupported, .detail = "TIFF Photometric" } },
        c.TIFFZ_UNSUPPORTED_PREDICTOR =>
            .{ .error_code = .{ .code = .unsupported, .detail = "TIFF Predictor" } },
        c.TIFFZ_UNSUPPORTED_BIT_DEPTH =>
            .{ .error_code = .{ .code = .unsupported, .detail = "TIFF BitsPerSample" } },
        c.TIFFZ_UNSUPPORTED_TAG_TYPE =>
            .{ .error_code = .{ .code = .unsupported, .detail = "TIFF tag field type" } },
        c.TIFFZ_DEST_TOO_SMALL =>
            .{ .error_code = .{ .code = .buffer_too_small, .detail = null } },

        // ── Resource-limit FAIL ──
        c.TIFFZ_LIMIT_EXCEEDED_IFD_COUNT,
        c.TIFFZ_LIMIT_EXCEEDED_TAG_COUNT,
        c.TIFFZ_LIMIT_EXCEEDED_STRIP_COUNT,
        => .{ .error_code = .{ .code = .too_many, .detail = "TIFF structure" } },
        c.TIFFZ_LIMIT_EXCEEDED_TAG_VALUE_BYTES,
        c.TIFFZ_LIMIT_EXCEEDED_DIMENSION,
        c.TIFFZ_LIMIT_EXCEEDED_TOTAL_SAMPLES,
        c.TIFFZ_LIMIT_EXCEEDED_CODEC_SCRATCH,
        c.TIFFZ_LIMIT_EXCEEDED_COMPRESSED_STRIP_BYTES,
        c.TIFFZ_LIMIT_EXCEEDED_DECOMPRESSED_STRIP_BYTES,
        => .{ .error_code = .{ .code = .exceeds_bounds, .detail = "TIFF resource" } },

        // ── Allocation / internal ──
        c.TIFFZ_OUT_OF_MEMORY =>
            .{ .error_code = .{ .code = .out_of_memory, .detail = null } },
        c.TIFFZ_BUG =>
            .{ .error_code = .{ .code = .other, .detail = "tiffz internal invariant violated" } },

        c.TIFFZ_OK => .{ .other = "tiffz reported OK as a fault — caller bug" },
        else => .{ .other = "unknown tiffz status" },
    };
}

/// INFO-tier finding codes — these are not error returns; they're
/// observations validate's shim collects after a successful decode
/// via accessor calls on the Decoder. The enum below is a stable
/// identifier for the table above; the actual emission mechanism is
/// scalar Decoder getters in tiffz v1, replaceable with a
/// callback-based finding API in a later milestone.
pub const TiffzInfoFinding = enum {
    bigtiff_format,
    multi_ifd_chain,
    old_style_lzw_codes,
    pre_multiplied_alpha,
    predictor_applied,
    geotiff_tags_present,
    cfa_pattern_present,
    opcode_list_present,
    jpeg_in_tiff,
    tiled_layout,
    planar_separate,
};

pub fn routeInfoFinding(finding: TiffzInfoFinding) RoutedFinding {
    return switch (finding) {
        .bigtiff_format        => .{ .info = "BigTIFF (64-bit offsets)" },
        .multi_ifd_chain       => .{ .info = "multi-IFD TIFF" },
        .old_style_lzw_codes   => .{ .info = "old-style LZW (libtiff fallback used)" },
        .pre_multiplied_alpha  => .{ .info = "associated alpha (ExtraSamples=1)" },
        .predictor_applied     => .{ .info = "TIFF Predictor applied" },
        .geotiff_tags_present  => .{ .info = "GeoTIFF tags present" },
        .cfa_pattern_present   => .{ .info = "CFA mosaic raw (DNG / TIFF-EP)" },
        .opcode_list_present   => .{ .info = "DNG opcode list" },
        .jpeg_in_tiff          => .{ .info = "JPEG-in-TIFF (Compression=7)" },
        .tiled_layout          => .{ .info = "tiled layout" },
        .planar_separate       => .{ .info = "separate planar configuration" },
    };
}
```

## Integration recipe pointer

The tiffz integration recipe (flake.nix patch, build.zig patch, full
`tiffz_shim.zig`, step-by-step call-site flip, and the retire-
zigimg-TIFF plan) will accompany the LLMsend ping that delivers this
mapping. Track it as a TODO at validate's side; this mapping table
is the substantive deliverable.

## What's still on validate (pre-integration)

- **Decide whether to promote `old_style_lzw_codes` to a WARN**, given
  it indicates the file is technically malformed (only readable
  thanks to libtiff's heuristic for libtiff < 3.4 codestreams). My
  table assumes INFO since the file decodes correctly; promoting to
  WARN is reasonable if validate already flags similar
  "tool-tolerated" cases.
- **Confirm the INFO scaffold strategy.** v1 uses
  scalar Decoder getters (`Decoder.isBigTiff()`, etc.) since the INFO
  set is small. If validate prefers a callback API up front, tiffz
  can ship `tiffz_set_finding_callback()` early — speak up before the
  integration recipe lands.
- **Reserve the MalformationType slots** if validate wants
  `tiff_cal_rowbytes_off_by_one` and
  `tiff_strip_tags_aliased_as_tile` in the enum from day one.
  Otherwise these can land alongside their repair workflows whenever
  someone has an appetite for them.

— tiffz (2026-05-16 EST)
