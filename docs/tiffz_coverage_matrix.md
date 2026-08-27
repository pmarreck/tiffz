# tiffz coverage matrix

Einstein dispatch outcome 2 (2026-08-04): inventory tiffz's format coverage as
**strict / partial / unsupported / blocked**.

- **strict** — recognized and fully validated/decoded per spec.
- **partial** — works with a documented gap, or accepted-with-WARN under a
  libtiff-tolerated deviation.
- **unsupported** — not dispatched; tiffz does not claim to handle it.
- **blocked** — deliberately excluded (will not be implemented).

This first pass is **code-derived** (read of `tags.zig`, `decoder.zig`,
`predictors.zig`, `photometrics.zig`, `dng.zig`, `geotiff.zig`, `findings.zig`,
`src/compressions/`). The **Verified** column says how the cell was confirmed:
`code` = source read; `fixture` = a committed fixture exercises it; `—` = not
yet confirmed by a fixture (classification inferred from code, treat as
provisional). Cells marked provisional are the honest edge of this inventory.

## Compression (Compression tag 259)

| Codec | Value | Status | Verified | Notes |
|---|---|---|---|---|
| None | 1 | strict | code | `compressions/none.zig` |
| CCITT Group 3 (T.4) | 3 | strict | code | `compressions/ccitt_t4.zig` |
| CCITT Group 4 (T.6) | 4 | strict | code | `compressions/ccitt_t6.zig` |
| LZW | 5 | strict | fixture | via `lzwz`; missing-EOD accepted with **WARN 14** (libtiff-tolerated) |
| OJPEG (old-style JPEG) | 6 | **blocked** | fixture | SPEC §3, re-affirmed by Peter 2026-08-27: never decoded. The walk SKIPS such IFDs with finding 16 (`unsupported_compression_skipped`, partial coverage) instead of failing the file — CR2 previews/vendor raw validate structurally with the uncovered portions named |
| JPEG-in-TIFF | 7 | strict | fixture | via `jpegz`; `error.JpegInTiffPayload` categorization; typed nested findings |
| Deflate / ZIP | 8 | strict | fixture | `compressions/deflate.zig`; final-strip padding accepted with **WARN 13** |
| Adobe Deflate | 32946 | strict | fixture | same path as Deflate |
| PackBits | 32773 | strict | code | `compressions/packbits.zig` |
| Zstd | 50000 | strict | code | `compressions/zstd.zig` (GDAL/libtiff extension) |
| LERC | 34887 | strict | code | `compressions/lerc.zig`; add-compression none/deflate/zstd |
| JBIG, JPEG2000-in-TIFF, Thunderscan, NeXT, others | — | unsupported | code | not dispatched |

## Container / structure

| Feature | Status | Verified | Notes |
|---|---|---|---|
| Classic TIFF (magic 0x2A) | strict | fixture | `header.zig` |
| BigTIFF (magic 0x2B, 64-bit offsets) | strict | fixture | `header.zig` parseBigTiffTail; IFD8 offset arrays decode |
| Striped | strict | fixture | `chunkLayout` strip branch |
| Tiled | strict | fixture | `chunkLayout` tile branch |
| Tiled geometry stored under strip tags | partial | fixture | libtiff-tolerated; accepted with **WARN 15**, else rejected |
| Multi-IFD / multi-page | strict | fixture | lazy IFD-chain traversal + cycle detection |
| SubIFD offset arrays (tag 330, incl. BigTIFF IFD8) | partial | fixture | offset arrays decode; automatic SubIFD-chain descent not claimed |
| PlanarConfiguration chunky (1) | strict | fixture | |
| PlanarConfiguration separate (2) | strict | fixture | per-plane strip-index math (u32-underflow-safe) |
| CR2 (Canon raw, TIFF-based) | partial | fixture | structural walk validates (`canon_eos_40d_sraw2.cr2` must-accept control); Compression=6 preview + vendor-raw IFDs skipped with **finding 16** (partial coverage); ARW/NEF pass the plain walk |

## Predictor (tag 317)

| Predictor | Value | Status | Verified | Notes |
|---|---|---|---|---|
| None | 1 | strict | code | |
| Horizontal, 8-bit | 2 | strict | fixture | |
| Horizontal, 16-bit | 2 | partial | code | deferred: needs endian-aware u16 reads (lands with DNG raw) |
| Floating-point (TN3) | 3 | strict | — | bps ∈ {16,24,32,64}, byte-plane de-interleave; provisional pending a float fixture |

## Photometric interpretation (tag 262)

| Photometric | Value | Status | Verified | Notes |
|---|---|---|---|---|
| WhiteIsZero | 0 | strict | fixture | |
| BlackIsZero | 1 | strict | fixture | |
| RGB | 2 | strict | fixture | |
| Palette | 3 | strict | code | `expandPalette` + ColorMap |
| Transparency mask | 4 | partial | — | tag recognized; dedicated decode path not confirmed |
| Separated / CMYK | 5 | strict | code | `expandCmyk` |
| YCbCr | 6 | strict | fixture | + chroma-subsampling extent (2×2 etc.) |
| CIELab / ICCLab | 8 / 9 | partial | code | `expandCieLab`; provisional pending a fixture |
| CFA (color filter array) | 32803 | partial | code | DNG parse only, see DNG |

## Bit depth / sample format

| Case | Status | Verified | Notes |
|---|---|---|---|
| 1-bit (bilevel, fax) | strict | fixture | CCITT codecs |
| 8-bit integer | strict | fixture | |
| 16-bit integer | partial | code | extent/decode yes; predictor-2 16-bit deferred |
| 32-bit / float | partial | — | predictor-3 float path exists; provisional pending a float fixture |

## Metadata

| Surface | Status | Verified | Notes |
|---|---|---|---|
| GeoTIFF (KeyDirectory, tiepoints, pixel scale, params) | strict (parse) | code | `geotiff.zig`; returns null for plain TIFF |
| DNG CFA pattern (33421/33422) | partial | code | parsed; not demosaiced |
| DNG OpcodeList 1/2/3 (51008/51009/51022) | partial | code | opcode structure parsed; parameters left unexecuted (big-endian per DNG §10) |
| EXIF IFD (34665) / GPS / Interop | unsupported | — | no dedicated ExifIFD descent found; provisional |
| XMP (700) | unsupported | — | not parsed |

## Embedded JPEG family

| Case | Status | Verified | Notes |
|---|---|---|---|
| JPEG (Compression 7) validate/decode | strict | fixture | `jpegz`; identity `(jpegz, code)`; TN2 Mode 1/2 host-offset mapping |
| Strict-facade forwarding (jp2z / libjxlz / jpegz) | strict | fixture | `emitStrictValidationFindings` preserves source identity + four-way verdict |
| TIFF actually embedding JP2/JXL streams | unsupported | — | forwarding path exists but TIFF containers rarely carry these |

## DNG (Adobe Digital Negative)

| Feature | Status | Verified | Notes |
|---|---|---|---|
| CFA pattern tags | partial | code | `dng.zig` parseCfaPattern |
| Opcode lists (structure) | partial | code | parsed; params unexecuted |
| Demosaic / raw development | **blocked** | code | out of scope — tiffz is a validation/parse library, not a raw developer |
| Predictor 3 (float) for DNG HDR | strict | — | provisional pending fixture |
| Predictor 2, 16-bit for DNG raw | partial | code | deferred |

## Vendor / GDAL / Esri extensions

| Extension | Status | Verified | Notes |
|---|---|---|---|
| Adobe Deflate (32946) | strict | fixture | |
| Zstd-in-TIFF (50000) | strict | code | |
| LERC (34887) + add-compression | strict | code | |
| Other private tags / codecs | unsupported | — | recognized as unknown; not dispatched |

## Summary and next verification steps

Strict, exercised-by-fixture core: classic + BigTIFF; striped + tiled; multi-IFD;
planar chunky + separate; None/LZW/JPEG/Deflate/PackBits/Zstd/LERC/CCITT codecs;
RGB/BlackIsZero/WhiteIsZero/YCbCr(+subsampling) photometrics; the three
libtiff-tolerated deviations (WARN 13/14/15) plus partial-coverage skips for
never-supported compressions (finding 16, CR2 must-accept control).

Provisional cells needing a committed fixture to promote from code-inferred:
predictor-3 float, CIELab/ICCLab, CMYK, transparency-mask, 32-bit float, and a
definitive answer on EXIF-IFD descent. These are the honest gaps in this
inventory, not claims of support.
