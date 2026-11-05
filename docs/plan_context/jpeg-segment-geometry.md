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
. In a DNG: a JPEG variant other than the one DNG 1.6.0.0 Chapter 3
   requires (baseline DCT or lossless Huffman; see "Rule 6" below).

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

## Rule 6: the DNG JPEG variant (owner, 2026-11-04)

The owner approved this rule on 2026-11-04; validate relayed it as decision 7.
It enforces DNG 1.6.0.0 Chapter 3, Compression: "If PhotometricInterpretation
= 6 (YCbCr) and BitsPerSample = 8/8/8, or if PhotometricInterpretation = 1
(BlackIsZero) and BitsPerSample = 8, then the JPEG variant must be baseline
DCT JPEG. Otherwise, the JPEG variant must be lossless Huffman JPEG."

- **Readings:**
  - Baseline DCT is SOF0 only.
  - Lossless Huffman JPEG is SOF3 only. SOF7 is hierarchical, and SOF11
    and SOF15 are arithmetic-coded.
  - These are reversible choices, reported to validate with the landing.
- **Scope:** Compression 7 IFDs in a DNG of known version. The text has
  stood since DNG 1.0.0.0, so it applies to every known version. An
  unknown version gets no rule (D2).
- **Inputs:** PhotometricInterpretation, SamplesPerPixel (default 1) and
  BitsPerSample.
  - BitsPerSample is absent: the default of 1 is not 8, so lossless is
    required.
  - Photometric is absent, or BitsPerSample is malformed (not SHORT, or
    its count is not SamplesPerPixel): no rule. That is its own fault.
- **Payload:** finding 19's payload is unchanged.
  - The record cites the Compression entry.
  - The TIFF value is the PhotometricInterpretation.
  - The required value is the SOF type the rule requires (0 or 3).
  - The SOF type field holds the type found.
  - As for rules 1 to 5, there is one record per IFD, with the first
    violating segment and the counts.

Fixtures (tests/fixtures/jpeg_geometry, from gen.pl) are one-IFD DNG 1.6.0.0
previews:
- dng-ycbcr-ok.tif: YCbCr 8/8/8 with SOF0, a control with no record.
- dng-ycbcr-sof1.tif: the same stream marked SOF1, so baseline is required
  and the file gets a record.
- dng-rgb-sof0.tif: RGB 8/8/8 with SOF0, so lossless is required and the
  file gets a record.

The non-DNG RGB SOF0 fixture (tests/fixtures/jpeg/rgb-jpeg.tif) is the
control for the DNGVersion gate.

### Corpus report (263 files: the pinned manifest, KNOWN_DEFECT fixtures and patched controls)

No verdict changes, and tiffz emits no finding 19 on any file. The
finding 19 oracle, extended with rule 6, examines the 52 Compression 7
IFDs, 32 of them in DNGs. It predicts one record:

| file | sha256 | IFD | prediction | why tiffz does not reach it |
|---|---|---|---|---|
| Blackmagic Micro Cinema DNG (validate ground truth, DNG 1.2.0.0), 1228096 bytes | 4c65b8cda205087cfb94d8931811e53e15eb4df538ad67c1b4a3e76c1185b277 | 0 (raw, CFA, 12-bit) | rule 6, required SOF3, 2 of 2 tiles violate: they are SOF1, 12-bit extended DCT, 1952x552 frames in 976x1104 tiles | already invalid (Malformed, with tiled_layout and jpegz findings); finding 19 records are emitted only once every segment of the IFD decodes |

The Blackmagic file is lossy DCT under Compression 7 in a CFA raw IFD. DNG
1.4.0.0 added code 34892 for lossy JPEG, so in a 1.2.0.0 file this is a
producer pattern candidate, not a reader matter. validate has been told.

**Real-file control.** The Adobe DNG Converter 9.8 Canon EOS 5D Mark III DNG
(sha256 b22f1e36331f679abb8b13e433b9bbde3988723adf10fee7aa0dda6381016a98)
validates ok. A copy with IFD 0's preview SOF0 changed to SOF1, at offset
199126, gives one rule 6 record from tiffz:
- IFD 0, first segment 0;
- Compression entry at 58;
- SOF type 1, TIFF value 6, required 0;
- 1 of 1 segments.

The oracle predicts the same record. The previous build validates the copy
ok.

**Controlled red.** Applying the rule outside DNG files failed the finding
19 fixture test (on the non-DNG RGB control) and the rule 6 unit test.
Restoring the gate made both pass again.

## Reach from the marker walk (validate, 2026-11-05; landed)

Rules 1 to 6 read marker-segment fields only. They are structural checks, so
reach ruling A applies: records do not wait for the entropy data to decode.

**The pass.** Finding 19 is now `checkJpegGeometry`, a per-IFD pass that
reads each Compression 7 segment only up to its frame header.
- **When it runs:** in the walk, right after the directory rules and before
  decoding; and in the post-stop pass, for IFDs a stopping error left
  unreached.
- **Reads:** they start at 4 KiB and double only while the header is cut off
  by the read, bounded by the segment's byte count and
  `max_compressed_strip_bytes`.
- **Segments that contribute nothing:**
  - a segment whose markers do not parse, which is not examined;
  - a segment that cannot be read.
- **The byte budget:** exhausting it during this pass is that limit.
- **No pass after a limit, OutOfMemory or Bug:** unchanged.
- **Removed:** the old feed from inside the JPEG decode.

**Readings for rule 6 (validate):**
- Baseline DCT is SOF0 only (T.81 Table B.1).
- Lossless Huffman is SOF3, the lossless mode of Annex H.
- SOF7, a differential frame of the hierarchical mode (Annex J), and the
  arithmetic SOF11 and SOF15 are faults.
- A hierarchical stream (DHP, then frames) is a fault even with a SOF3
  first frame. jpegz has been asked to report a DHP before the first frame.
  Until it does, that case is not detected.

**Fixtures (gen.pl):**
- rows-bad-cut.tif: rule 1, second strip cut after SOS.
- stop-then-rows-bad.tif: IFD 0 cut, so the walk stops; IFD 1 is rule 1.
- dng-cfa-sof0-cut.tif: a DNG 1.2.0.0 CFA raw with cut DCT data, so rule 6
  applies with lossless required.

**Impact (263 files, ecad5628 against the change).** There are no status
changes. Three already-invalid files gain exactly the records the oracle
predicts:
- Blackmagic Micro Cinema: IFD 0, rule 6, SOF1, 2 of 2.
- Leica M11: IFDs 1 to 4, rule 4.
- Ricoh GR: IFD 2, rule 4.

**Controlled red.** Reinstating the decode gate silenced all three fixtures.
