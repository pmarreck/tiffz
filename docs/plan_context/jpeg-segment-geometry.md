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

## Delivery notes (2026-11-04)

- The frame header is read with `jpegz.frameHeader` (jpegz 38a348b) where the
  JPEG branch of the decoder already holds each segment's bytes, so no
  segment is read twice. A segment the decoder retries with a larger buffer
  is counted once.
- Rule 4 reports, in its required field, the first component that breaks it:
  index 2 when the chroma components disagree, index 0 (luma) when luma is
  not YCbCrSubSampling times chroma, and for other photometrics the first
  component that differs from component 0. The TIFF value is
  YCbCrSubSampling packed H << 16 | V for YCbCr, otherwise the photometric.
- The cited entry is RowsPerStrip, TileWidth, TileLength, PlanarConfiguration,
  or YCbCrSubSampling (PhotometricInterpretation when the default [2, 2]
  applies or the image is not YCbCr).
- A malformed YCbCrSubSampling (its own finding 18) disables rule 4 for that
  IFD rather than standing in for a value.

## Corpus report (140 distinct sha256, pinned manifest)

No verdict changes. tiffz emits no finding 19 on any corpus file. An
independent oracle (its own TIFF walk, JPEG marker walk to the first SOFn and
rules) finds 25 Compression 7 IFDs and predicts rule 4 on five DNG preview
IFDs whose JPEGs are 4:2:2 (luma 2x1) while YCbCrSubSampling is absent, so the
default [2, 2] applies (libtiff warns about the same mismatch):

| file | sha256 | IFDs | why tiffz does not reach them |
|---|---|---|---|
| Leica M11 DNG (validate ground truth), 78877156 bytes | bb85af7615824dd3afd44d9da0bfa6a9ec5e3d7bb5bcf48e11fbd10752a8cc45 | four preview SubIFDs | already invalid: the walk stops at IFD0 (JpegInTiffPayload) |
| Ricoh GR DNG (raw.pixls.us, CC0), 12129815 bytes | 7ceec1ea31c56b6e0414202504581b915f17818ffe018b4c8bba1393332c405e | one preview SubIFD | already invalid: a jpegz corrupt finding in another SubIFD stops the walk |

With copies whose header points straight at each preview SubIFD, tiffz and
the oracle agree on every record: rule 4, one violating of one examined
segment, TIFF value 0x00020002, component 0 with H 2, V 1. The pattern is a
producer pattern candidate that would surface if those files' other faults
were absent; validate was asked how to treat it.
