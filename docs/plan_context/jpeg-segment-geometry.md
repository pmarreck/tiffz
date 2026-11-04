# Finding 19 `jpeg_segment_geometry_invalid`

Approved by the owner via Einstein on 2026-11-04 (code 19, verdict corrupt),
with the design validate approved the same day. The rulings behind it are in
`ifd_fault_cases.md` ("Technical Notes batch rulings", item 3).

## What it finds

In Compression 7 (JPEG-in-TIFF) images, a JPEG segment whose frame header (SOF)
disagrees with the TIFF fields TIFF Technical Note 2 binds it to:

1. DCT SOF in a multi-strip image: RowsPerStrip not a multiple of 8 * Vmax.
2. and 3. DCT SOF in a tiled image: TileWidth or TileLength not a multiple of
   the MCU width or height.
4. PlanarConfiguration 1: SOF sampling factors whose luma-to-chroma ratio
   differs from YCbCrSubSampling, or chroma components that differ from each
   other; for non-YCbCr images, unequal factors.
5. PlanarConfiguration 2: any SOF sampling factor other than 1.

SOF classes are exact and pinned by a test: DCT 0, 1, 2, 5, 6, 9, 10, 13, 14;
lossless 3, 7, 11, 15. Lossless SOFs are exempt from rules 1 to 3. Every
segment is scanned. One record per IFD per rule, with counts, so a
5,000-strip file yields one record. Validation fails Malformed after the walk,
as for 17 and 18.

## Payload (little-endian, pinned by a test)

u32 IFD index, u32 first violating segment, u64 absolute TIFF entry offset,
u64 absolute SOF offset, u16 rule, u16 SOF type, u32 TIFF value, u32 required
value or SOF factors (rules 4 and 5: the disagreeing component index and its
H/V), u32 violating segments, u32 examined segments.

## Reach

An IFD with no examined segment never implies a pass. The existing reach and
coverage findings name what was not examined; no extra marker is needed.

## Implementation

Use `jpegz.frameHeader` (jpegz 6f2b881, CI-green at 38a348b) instead of an own
SOF scanner, with a differential check against jpegz decode over the corpus.
