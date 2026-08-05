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

tiffz surfaces failures via its single `errors.Error` set (see
`src/errors.zig`). For M10 integration, the C ABI exports
`tiffz_status_t` codes (1:1 with the Zig error set per the frozen
API design). Each `tiffz_status_t` value below is its
English-friendly finding name in this table.

INFO-tier findings (file is structurally valid but has a noteworthy
property) are emitted via a **callback** registered on the Decoder.
The callback fires synchronously from whatever thread is currently
running the decode method that detected the finding (tiffz itself is
single-threaded; the callback inherits the caller's thread context).

```zig
// In Zig:
const tiffz = @import("tiffz");

var dec = try tiffz.Decoder.open(allocator, source);
defer dec.deinit();

dec.setFindingCallback(my_callback, my_userdata);
// IFD-0 findings haven't fired yet — replay the IFDs we've already
// parsed:
dec.scanFindings();

// Walking the chain via dec.ifd(N) materializes IFD N and fires
// findings for that IFD as a side effect.
_ = try dec.ifd(1);
```

The callback record ABI is declared in `include/tiffz.h`; the public C Decoder
setter remains future API, while the current callable setter is Zig-only.
Finding identity is the
pair `(source_decoder, finding_code)`; equal integers from different sources
do not collide. Optional mapped codes and offsets are presence-flagged so zero
remains a valid value. JP2/JXL nested findings preserve `valid`, `corrupt`,
`unsupported`, and `indeterminate` rather than forcing a binary answer:

```c
typedef void (*tiffz_finding_callback_t)(
    void *userdata,
    int32_t source_decoder,
    int32_t finding_code,
    int32_t mapped_finding_code,
    int32_t verdict,
    uint64_t byte_offset,
    uint64_t host_byte_offset,
    uint32_t metadata_flags,
    const uint8_t *payload,
    size_t payload_len
);
```

### Per-finding firing policy

| Finding | Payload | Fires |
|---|---|---|
| `bigtiff_format` (1) | none | once per Decoder |
| `multi_ifd_chain` (2) | u32 LE: IFD count | per IFD beyond 0 (consumer dedupes) |
| `old_style_lzw_codes` (3) | none | once per Decoder (first strip that triggers the LZW new→old fallback) |
| `pre_multiplied_alpha` (4) | none | per IFD with ExtraSamples=1 |
| `predictor_applied` (5) | u32 LE: predictor value (2 or 3) | per IFD with Predictor != 1 |
| `geotiff_tags_present` (6) | none | per IFD with any known GeoTIFF tag |
| `cfa_pattern_present` (7) | none | per IFD with photometric=CFA or CFAPattern tag |
| `opcode_list_present` (8) | u32 LE: opcode count | once per opcode list (1/2/3) per IFD |
| `jpeg_in_tiff` (9) | none | per IFD with Compression=7 |
| `tiled_layout` (10) | none | per IFD with a TileOffsets tag |
| `planar_separate` (11) | none | per IFD with PlanarConfiguration=2 |
| `lerc_compression` (12) | none | per IFD with Compression=34887 |
| `final_strip_padding_tolerated` (13) | none | once when a final strip exceeds its logical extent but stays within one full RowsPerStrip chunk |
| `lzw_missing_eod_tolerated` (14) | none | once when valid LZW transitions reach physical EOF at an exact container bound without EOD |
| `tiled_geometry_via_strip_tags_tolerated` (15) | none | once when complete tile geometry uses complete strip arrays and both canonical tile arrays are absent |

Numeric finding codes are **stable** — they never change once
assigned. New findings append at the end. The Zig enum
(`tiffz.findings.InfoFinding`) is declared `enum(u32)` with an open
catch-all (`_`) so consumers can decode unknown codes as
forward-compat unknowns.

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
| `lerc_compression`                | info             | `info_message = "LERC-in-TIFF (Compression=34887)"`                    |
| `final_strip_padding_tolerated`   | warn             | `warning_message = "final TIFF strip padded to RowsPerStrip"`          |
| `lzw_missing_eod_tolerated`       | warn             | `warning_message = "TIFF LZW stream omitted EOD at exact extent"`      |
| `tiled_geometry_via_strip_tags_tolerated` | warn      | `warning_message = "TIFF tile geometry uses strip offset/count tags"`  |

Notes on taxonomy:

- **`info_message`** is for "this file is valid; here's a noteworthy
  property" (PASS-tier observation). Maps to `okWithDepthAndInfo` in
  validate.
- **`warning_message`** carries the three bounded, libtiff-compatible
  deviations above. Each has a negative classifier: beyond-full-strip bytes,
  short/overlong/invalid LZW, and incomplete or ambiguous tile arrays remain
  terminal failures.
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
const tiffz = @import("tiffz");
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
/// channel. INFO findings are emitted via the Decoder's callback —
/// see the integration recipe below `routeInfoFinding`.
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

/// INFO-tier finding codes — emitted via tiffz.Decoder's callback.
/// validate's per-file accumulator drains these into the file's
/// `info_message` list. Codes match `tiffz.findings.InfoFinding`
/// (stable u32; never renumbered).
pub const TiffzInfoFinding = enum(u32) {
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
    lerc_compression = 12,
    final_strip_padding_tolerated = 13,
    lzw_missing_eod_tolerated = 14,
    tiled_geometry_via_strip_tags_tolerated = 15,
    _, // forward-compat: new tiffz versions may introduce codes
};

pub fn routeInfoFinding(finding: TiffzInfoFinding, payload_u32: ?u32) RoutedFinding {
    return switch (finding) {
        .bigtiff_format        => .{ .info = "BigTIFF (64-bit offsets)" },
        .multi_ifd_chain       => .{ .info = "multi-IFD TIFF" },
        // Per validate's 2026-05-18 reply: promote to WARN at the shim
        // level (file is technically non-spec; tiff still decodes via
        // libtiff-style heuristic).
        .old_style_lzw_codes   => .{ .warning = "TIFF uses legacy LZW codes (off-by-one from spec); decoded via libtiff-style heuristic — file is technically non-spec" },
        .pre_multiplied_alpha  => .{ .info = "associated alpha (ExtraSamples=1)" },
        .predictor_applied     => blk: {
            // payload_u32 is the predictor value (2 or 3); could be
            // formatted into the message if validate's INFO sink
            // accepts dynamic strings.
            _ = payload_u32;
            break :blk .{ .info = "TIFF Predictor applied" };
        },
        .geotiff_tags_present  => .{ .info = "GeoTIFF tags present" },
        .cfa_pattern_present   => .{ .info = "CFA mosaic raw (DNG / TIFF-EP)" },
        .opcode_list_present   => .{ .info = "DNG opcode list" },
        .jpeg_in_tiff          => .{ .info = "JPEG-in-TIFF (Compression=7)" },
        .tiled_layout          => .{ .info = "tiled layout" },
        .planar_separate       => .{ .info = "separate planar configuration" },
        .lerc_compression      => .{ .info = "LERC-in-TIFF (Compression=34887)" },
        .final_strip_padding_tolerated => .{ .warning = "final TIFF strip padded to RowsPerStrip" },
        .lzw_missing_eod_tolerated => .{ .warning = "TIFF LZW stream omitted EOD at exact extent" },
        .tiled_geometry_via_strip_tags_tolerated => .{ .warning = "TIFF tile geometry uses strip offset/count tags" },
        _                      => .{ .other = "unknown tiffz finding code" },
    };
}

/// Per-file accumulator: a thread-local-friendly ArrayList that the
/// callback appends to. Drain after the decode completes and map
/// each entry through routeInfoFinding.
pub const FindingAccumulator = struct {
    findings: std.ArrayListUnmanaged(Entry),
    allocator: std.mem.Allocator,

    pub const Entry = struct {
        code: TiffzInfoFinding,
        payload_u32: ?u32,
    };

    pub fn init(allocator: std.mem.Allocator) FindingAccumulator {
        return .{ .findings = .empty, .allocator = allocator };
    }
    pub fn deinit(self: *FindingAccumulator) void {
        self.findings.deinit(self.allocator);
    }

    pub fn callback(
        userdata: ?*anyopaque,
        source_decoder: i32,
        finding_id: i32,
        mapped_finding_id: i32,
        verdict: i32,
        byte_offset: u64,
        host_byte_offset: u64,
        metadata_flags: u32,
        payload: ?[*]const u8,
        payload_len: usize,
    ) callconv(.c) void {
        const self: *FindingAccumulator = @ptrCast(@alignCast(userdata.?));
        // Compact native-only example. The production Validate shim must keep
        // nested source/code/verdict/offset metadata in its own accumulator.
        if (source_decoder != @intFromEnum(tiffz.findings.SourceDecoder.tiffz)) return;
        _ = mapped_finding_id;
        _ = verdict;
        _ = byte_offset;
        _ = host_byte_offset;
        _ = metadata_flags;
        const code: TiffzInfoFinding = @enumFromInt(@as(u32, @intCast(finding_id)));
        const payload_u32: ?u32 = if (payload_len >= 4 and payload != null) blk: {
            const slice = payload.?[0..4];
            break :blk std.mem.readInt(u32, slice, .little);
        } else null;
        self.findings.append(self.allocator, .{
            .code = code,
            .payload_u32 = payload_u32,
        }) catch {}; // OOM during accumulation — silently drop; the
                     // decode itself is unaffected.
    }
};
```

### Integration recipe

```zig
// Inside validate's validateTiffDeep:
var acc = FindingAccumulator.init(allocator);
defer acc.deinit();

var dec = try tiffz.Decoder.open(allocator, source);
defer dec.deinit();
dec.setFindingCallback(&FindingAccumulator.callback, @ptrCast(&acc));
dec.scanFindings(); // replay IFD-0 findings into the accumulator

// ... decode strips / walk additional IFDs as needed ...

// After decode: drain the accumulator into validate's result.
for (acc.findings.items) |entry| {
    const routed = routeInfoFinding(entry.code, entry.payload_u32);
    switch (routed) {
        .info => |msg| result.appendInfo(msg),
        .warning => |msg| result.appendWarning(msg),
        .error_code => |ec| return ec, // shouldn't happen for INFO codes
        .malformation => |m| result.malformations.insert(m),
        .other => |msg| result.appendInfo(msg),
    }
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
