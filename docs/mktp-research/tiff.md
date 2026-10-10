# TIFF chain: objective checks and one raster-limit gap

Record date: 2026-10-09. Starting tree: `179e4261` (nixpkgs `39ad350a`, zig-overlay `940ecf1b`, Zig 0.16.0). Codec pins were not moved: jpegz `33ea394`, libjxlz `93b29e86`, lzwz `511bc8f`, zstdz `484cc81`, lercz `a88c39b`.

The suite gate compiles tests with `-Doptimize=ReleaseSafe` (see the flake's `checks.test`). The red and green unit runs below used that profile on x86_64-linux, Zig 0.16.0. No external oracle binary was invoked in this pass. SHA-256 values are of the committed fixture bytes, measured with `sha256sum` on 2026-10-09.

`docs/tiffz_coverage_matrix.md` (2026-08-04) still marks several cells as code-only. The fixture section below is the later measurement. Where they disagree, this file is the one that names a hash.

## Supported compression codes

`Decoder.supported_compressions` in `src/decoder.zig` is the dispatch list. A code absent from it is not decoded. Old JPEG (Compression=6) is absent on purpose (SPEC §3).

| Code | Name | Objective payload check already in tree | This pass |
|---|---|---|---|
| 1 | None | `rgb-3c-8b.tiff` vs ImageMagick RGBA oracle | re-hashed, not re-decoded |
| 3 | CCITT T.4 | `fax2d.tif` vs RGBA oracle. T4Options bit 0 (2D) and bit 1 (uncompressed) return `UnsupportedCompression`. Bit 2 (EOL byte align) is decoded. | re-hashed |
| 4 | CCITT T.6 | `scan_petes_book.tif`. The expanded RGBA oracle is not stored; the test pins SHA-256 `4514c30c83b632e17fffff95ba72d41e0197dd2df99ca70d5ea4b36847e1137c`, captured 2026-05-13. T6Options bit 1 (uncompressed mode) returns `UnsupportedCompression`. | file re-hashed; pinned digest not recomputed |
| 5 | LZW | `bali.tif` vs RGBA oracle. Missing EOD on a short strip is `Malformed` (`validateAllStripsAndTiles rejects LZW EOD before declared pixel extent`). | re-hashed |
| 7 | JPEG | `rgb-jpeg.tif` and `ycbcr_jpeg.tif` vs RGBA oracles. Photometric other than RGB (2), YCbCr (6), or CFA (32803) is `UnsupportedCompression` before jpegz. YCbCr output is already RGB. CFA accepts only `codec_check == .decoded` and a 1-channel grayscale jpegz image. | re-hashed the two oracle pairs |
| 8 | Deflate | `deflate-last-strip.tiff` vs RGBA oracle | re-hashed |
| 32946 | Adobe Deflate | same zlib arm as code 8. The classifier test lists 32946. This pass did not hash a separate 32946 file. | no new fixture |
| 32773 | PackBits | `cramps.tif` vs RGBA oracle | re-hashed |
| 50000 | Zstd | `rgb_zstd.tif` vs RGBA oracle | re-hashed |
| 34887 | LERC | `gray16_lerc.tif` vs RGBA oracle. Add-compression 1 and 2 have sibling files (hashes below). Tag 50674 must be two u32s; the added codec must be 0, 1, or 2. | re-hashed |

Compression 6, T.4 2D, T.6 uncompressed mode, and JPEG photometrics outside RGB/YCbCr/CFA are reach. A file that hits them is not a defect in the file.

## Embedded image and RAW paths

- JPEG-in-TIFF (compression 7) is the embedded-image path. JPEGTables (tag 347) is spliced by `prepareStream`. Tables that already fit inline are `Malformed`.
- Canon CR2 `canon_eos_40d_sraw2.cr2` validates with two finding-16 skips (compression not in the supported list on those IFDs, including IFD1's JPEGInterchangeFormat). SHA-256 `ba644e7dd2abe74eca260e67f0206ff113bf0f62e710f8130611e964d6be5bf1`. SubIFDs are not walked.
- DNG CFA compression 7 has a synthetic 4×4 lossless-JPEG length check (`decoded n == 16`). That test does not assert pixel values. A 12-bit camera DNG is not in this tree's fixtures.
- Predictor 3, FP32: `predictor3_deflate_fp32.tif` must match the decoded bytes of `predictor1_deflate_fp32.tif`. The test comment says both came from one 8×8 FP32 plasma seed via `gdal_translate`. This pass did not re-run GDAL. FP16 and FP32 have direct `applyInverse` vectors. FP24 and FP64 use the same byte-plane loop and have no dedicated vector in `src/predictors.zig`.
- CIE Lab has endpoint unit tests. A 2026-06-01 note in `docs/possible_future_directions.md` records 1–7 LSB disagreement with `tiff2rgba` on black and an out-of-gamut red. Those are two legal conversions, not a missing checksum.

## Fixture hashes (SHA-256)

| Path | SHA-256 |
|---|---|
| `tests/fixtures/uncompressed/rgb-3c-8b.tiff` | `21a751d4d6cad3903e4833db726c1b645fc88a1161efffcabaf9ce9c8c8f7084` |
| `tests/fixtures/uncompressed_oracle/rgb-3c-8b.rgba` | `e862a633fc5a7ab51d6aa345102954ffb0d14218d5a770b368a077bf5edf073d` |
| `tests/fixtures/packbits/cramps.tif` | `d9fb9600d745cb33a82a5448ef6cf9d6933c9462b90d3887475039ae2485af40` |
| `tests/fixtures/packbits_oracle/cramps.rgba` | `3768570932f0bdc0d0809e62c58163a669e6bc6f9cd9c9743c266b8213d1bb4b` |
| `tests/fixtures/lzw/bali.tif` | `d1be89c492f698d814deb61eaa58fc9f2866f72a33187255b086421b71fa9352` |
| `tests/fixtures/lzw_oracle/bali.rgba` | `e2edc6163ad943de2245ec22957ac92d792def6093fb0972eb671cbd75a966e4` |
| `tests/fixtures/deflate/deflate-last-strip.tiff` | `031aa7e15c2dfb21fe2fdd89eff88c4505c306f641be8b98f3666707d698b5ae` |
| `tests/fixtures/deflate_oracle/deflate-last-strip.rgba` | `0436d5c4165084507221c3db3e05a9b2b667b5ce011d320e9a53b5b4ff2dfdca` |
| `tests/fixtures/jpeg/rgb-jpeg.tif` | `fb638a47f2ef11a839fdf2603981ed74727d9eb13ab78e74a2489fff5971871f` |
| `tests/fixtures/jpeg_oracle/rgb-jpeg.rgba` | `6c0c3e0676d478e7b3f9073340ea8c673c29037e927e0f014ba858dc0da3507b` |
| `tests/fixtures/jpeg/ycbcr_jpeg.tif` | `91286d951ce3e6450fd9f3da849e7d69864b9a4a341170bca237dde45f1a969d` |
| `tests/fixtures/jpeg_oracle/ycbcr_jpeg.rgba` | `de80178a577bdc66eb3da19ac02f09992e2d904eb39bcced2fb0351368331c63` |
| `tests/fixtures/ccitt_g3/fax2d.tif` | `4e497620740a6c192ac9523817c9e51ba3596d5ab8b4ac1a15e8cc58e9a49b3f` |
| `tests/fixtures/ccitt_g3_oracle/fax2d.rgba` | `52b4c7dba3ce779c2dd031c01d52c98770254b4aac232e47012ed919f3b7a632` |
| `tests/fixtures/ccitt_g4/scan_petes_book.tif` | `02235d7f350caea91bc8e9654acfe4853e9e79624a9bf4e6dcdf2c596de024c4` |
| `tests/fixtures/zstd/rgb_zstd.tif` | `3e592edc801ea7fec682e44a937410efb155b1473b0ae48b34c44fe97cd106ed` |
| `tests/fixtures/zstd_oracle/rgb_zstd.rgba` | `f44e0c67e473eff4cf58369eea4b3a562d507756c5911ca296b08c60df4d1349` |
| `tests/fixtures/lerc/gray16_lerc.tif` | `5a4f2e7825bd59be8144893fba77d78b498c8c70bd43cf547c87dbb514799d5a` |
| `tests/fixtures/lerc_oracle/gray16_lerc.rgba` | `78e5d58df7a534ee685872400496271345aac3200b36b90dd720c327284fd4d5` |
| `tests/fixtures/lerc/gray16_lerc_deflate.tif` | `e3eee5e7d42a90f7c57b547b022ccd0b1176551b53978b808d30f043a0f5fdea` |
| `tests/fixtures/lerc/gray16_lerc_zstd.tif` | `518cd5addd6b34206ec37e52678718b26af5027d1d11c16c00e974bb8685650c` |
| `tests/fixtures/predictor/predictor1_deflate_fp32.tif` | `8bb9de0d8e5e091c1f388e938402395f8ecbc484655213223adfb3ab1d809593` |
| `tests/fixtures/predictor/predictor3_deflate_fp32.tif` | `89a9436665023e35498f0bf0571af9cb0f4ebfa7ab2498a11fafb13a9d2f0c30` |
| `tests/fixtures/cr2/canon_eos_40d_sraw2.cr2` | `ba644e7dd2abe74eca260e67f0206ff113bf0f62e710f8130611e964d6be5bf1` |

## Gap chosen

`Limits.max_dim` (default `1<<30`) and `Limits.max_total_samples` (default `1<<40`) were documented as the dimension budget and were not read on the decode or validate paths. `LimitExceededDimension` was only returned from the LERC status map. `LimitExceededTotalSamples` was never returned.

`stripRowSpan` computed `ceil(length / rows_per_strip)` as `(length + rps - 1) / rps`. When both operands are `0xFFFFFFFF`, that sum wraps. In ReleaseSafe the add panics. The wrapped quotient can also be 0, and the next `%` panics.

That is an unsafe malformed-input case on a declared raster, not a missing checksum. The synthetic pages below are the experiment. They are built in the test, not stored as files.

### Red, before the change

ReleaseSafe unit tests, filter on the new names. Parent tree `179e4261`.

1. ImageLength `0xFFFFFFFF`, width 1, one uncompressed byte, RowsPerStrip absent. `decodeStrip` aborted with signal ABRT, panic `integer overflow`. The trace named the `byte_count` cast. A print placed immediately before that cast did not run. The direct `stripRowSpan(0xFFFFFFFF, 0xFFFFFFFF, 0)` test panicked on `length + rps - 1`. The validate assertion in the same test was not reached.
2. ImageWidth `(1<<30)+1`, height 1, one byte. `decodeStrip` returned `1`. The test wanted `LimitExceededDimension`.
3. Custom limits `max_dim = 8`, `max_total_samples = 4`, image 3×2 (6 samples) with a 6-byte strip. `decodeStrip` returned `6`. The test wanted `LimitExceededTotalSamples`.
4. `stripRowSpan` at the u32 corner aborted as in (1).

### Green, after the change

`enforceRasterLimits` rejects width or height above `max_dim` with `LimitExceededDimension`, and `width * height * samples` above `max_total_samples` with `LimitExceededTotalSamples`. Both caps are inclusive. Decode and validate call it before the row-span math. Tile width and tile length are checked against `max_dim` as well.

`stripRowSpan` now uses `length / rps + (length % rps != 0)`. The u32-max corner is one full band. `ceil(0xFFFFFFFF / 0xFFFFFFFE)` is two bands: a full rows-per-strip, then a 1-row remainder. Those two expected values are the definition of ceil, not a copy of the old sum.

The same filtered ReleaseSafe run then reported 5 passed in 9 ms. The four tests in this section were in that set. The clean control inside the sample-count test is a 2×2 page, 4 samples, four bytes `0x5A`: `decodeStrip` returns 4 and `validateAllStripsAndTiles` succeeds under the same custom limits.

Full `./test` exited 0 on 2026-10-10 (about 293 seconds). That run includes sandboxed `checks.test` (ReleaseSafe), the parser closure, the JPEG validation closure, the native codec artifact export, the sibling freshness gate, and the libjxlz seed control. This pass does not change pins, does not add a finding code, and does not retune mutation vocabulary.

## Resource limits are not corruption findings

A configured cap is not evidence the file is malformed. The cheap distinction is the 3×2 uncompressed page under `max_total_samples = 4`: `decodeStrip` returns `LimitExceededTotalSamples`, and the same page at a cap of 4 decodes. A short strip that cannot cover its declared pixels stays `Malformed`. That extent check was not changed.

The C FFI already returns distinct codes. `LimitExceededDimension` is 15 and `LimitExceededTotalSamples` is 16. `Malformed` is 2. `tiffz_validate` on a page wider than the default `max_dim` returns 15.

The CLI used to print `invalid` and exit 1 for that same page, which is the corruption exit. It now prints `limited`, exits 4, and JSON uses `"status":"limited"` with the numeric FFI code. Exit 1 remains corrupt or malformed.

`101d007d` Mechatron Prime CI succeeded 2026-10-10T04:04:39Z–04:13:33Z (534 seconds, no failure stage). Its package hash is `tiffz-0.1.0-qutJAXTd0AEhSWmh2avZ3-YKS2JDQo20AiTmo3d0MDnJ`. The CLI wording above is a later commit. Do not reuse that package hash for the later commit.

## Still open, not treated as file defects

- FP24 and FP64 predictor vectors.
- A pixel oracle for the synthetic CFA lossless strip (the length check is not a known sample value).
- A dedicated Adobe Deflate (32946) file, separate from the shared zlib arm.
- Lab versus `tiff2rgba` LSB differences, already recorded as two legal conversions.
- OJPEG, T.4 2D, T.6 uncompressed mode, and other JPEG photometrics: reach.
