# tiffz — terminology

Project-specific terms. Ordinary TIFF vocabulary (IFD, strip, tile,
BigTIFF) is not repeated here.

## Coverage status

Used by `docs/tiffz_coverage_matrix.md`:

- **strict:** recognized and fully validated or decoded per spec.
- **partial:** works with a documented gap, or accepted with a WARN
  under a named libtiff-tolerated deviation.
- **unsupported:** not dispatched; tiffz does not claim it. May be
  added later.
- **blocked:** deliberately excluded and will not be implemented
  (OJPEG decode; demosaic / opcode execution).

## Modules

- **`tiffz`:** the full decoder, parser plus codecs (JPEG, LZW, ZSTD,
  LERC, and the rest of the dispatched set).
- **`tiffz-parser`:** header and lazy IFD-chain only. No codec
  imports or library links. The module rawz and other classifiers
  should import. Both modules come from one `b.dependency("tiffz")`
  instance.

## JPEG family in TIFF

- **OJPEG:** Compression=6, TIFF 6.0 §22 old-style JPEG. Blocked.
  See `INTENT.md`.
- **JPEG-in-TIFF:** Compression=7, Tech Note 2 Mode 1 and Mode 2.
  Implemented via jpegz.
- **one-instance rule:** a Zig compilation has one jpegz module,
  reached as `tiffz.jpegz`. Validate does not add a second pin over
  jpegz sources.

## Findings

- **Namespace A:** jpegz + jp2z finding codes. Nested JPEG-family
  findings stay tagged with their source decoder.
- **Namespace B:** tiffz `InfoFinding` codes (1–16 today). Disjoint
  from A. Validate disambiguates by emitting decoder, so tiffz `1`
  (`bigtiff_format`) does not collide with jpegz `1`.
- **Finding identity:** the pair `(source_decoder, finding_code)`.
  Equal integers from different sources do not collide.
- **Four-way verdict:** `valid`, `corrupt`, `unsupported`,
  `indeterminate`. Nested strict-facade findings keep all four;
  native tiffz INFO/WARN findings use `valid`.
- **Finding 16** (`unsupported_compression_skipped`): the walk
  skipped a never-supported compression IFD (payload: u32 LE IFD
  index, then u32 LE compression). Partial coverage, not a file-level
  fail.
- **Findings 13 / 14 / 15:** named tolerances: final-strip padding,
  LZW missing EOD at a clean bound, tile geometry stored in strip
  tags.

New Namespace B codes are append-only and need Einstein sign-off.
