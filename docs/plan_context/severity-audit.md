# Severity audit draft (tiffz, 2026-11-05; re-graded 2026-11-06)

Status: **draft for validate and the owner. Nothing here is implemented,** and no verdict changes until the owner approves.

## Basis

**The owner's definition** (2026-11-05, 11:07 and 11:10, relayed by validate): a failure is data statistically likely to come from damage. That means a media, transmission, disk or driver error, or a cosmic ray. Detection stays as strict as it is now; only the severity attached to a record changes.

**The owner's correction** (2026-11-06, relayed by validate): "we are no longer in the business of judging what's acceptable, just what's out of spec ... we don't judge based on what other readers do anymore." So:
- WARN is a spec violation most likely made by the writer.
- FAIL is likely damage, a checksum or length mismatch, or data the specification gives no decode for. "No specified decode" means the specification defines none.
- What other readers do is not evidence for a grade. Producer evidence is: the same signature from repeated files, bodies or makers, against the corruption campaign's damage counts.

**validate TERMINOLOGY.md A2** (rewritten 2026-11-05, uncommitted at the time of writing):
- KNOWN_DEFECT is its own category, and is either warning-treated or failure-treated.
- A checksum or declared-length mismatch, or one that is absent where the file claims it, fails by default.
- Data with no specified decode fails.
- Damage that mimics a writer violation shows as a warning, and coverage reports count it apart.

## Evidence

Two independent measurements.

**Damage (the corruption campaign).** The campaign ran master 42 in adaptive mode on ddfcbb5f: sniper, bolter, shotgun and nuke, 1,540 decisive trials, 743 detections. Each case's tiffz records were logged with a scratch copy of `./corruption-coverage`; the gate script is unchanged.
- **719 of the 743 detections are decode errors with no conformance record.** Examples are Malformed, SourceTooShort, JpegInTiffPayload, DestTooSmall and the final-strip padding finding. They are unaffected by this audit and stay FAIL.
- **24 carry a finding 17 or 18 record:**
  - 11 are finding 17: a tag-ID bit or byte that breaks the sort order.
  - 13 are finding 18: 3 type, 3 count and 7 value faults.
  - No finding 19 record and no channel mismatch came from damage.
  - Presence records were not measured: the finding is on a held branch. A tag-ID flip on a required tag would produce one.

**Writers (the pinned corpus, real_world class, 74 distinct files).** Every record in a real-world file traces to a consistent producer pattern:

| Record | Files | Producers |
|---|---|---|
| 17 (unsorted entries; tags 273, 282, 28672, 29895, 258, 29462) | 13 | Sony ARW, 13 bodies with the same set; Samsung NX500 (tag 330) |
| 18 reason 1 (type) | 3 | HP and NeXT old-style JPEG (ReferenceBlackWhite 532); Samsung NX500 (Compression) |
| 18 reason 2 (count) | 8 | Kodak DCS bodies (MinSampleValue 280, count 1 for 3 samples); Canon EOS 40D (BitsPerSample, the IFD0 candidate); Samsung NX500 |
| 18 reason 3 (value) | 20 | Sony ARW (Compression 32767, 12 bodies); Kodak (Orientation 9; DCS 3 Make and Software ASCII); Leica M11 and Nikon Coolscan (ASCII fields); Apple iPhone (TileWidth and TileLength not multiples of 16); Kodak DCS760C and DCS520C (Orientation) |
| 18 reason 4 (channel mismatch) | 3 | Kodak P880 and P712 KDC; Kodak EOS DCS 3 |
| 19 rule 4 (YCbCr subsampling against SOF) | 2 | Leica M11, Ricoh GR (4:2:2 preview) |
| 19 rule 6 (DNG variant SOF) | 1 | Blackmagic Micro Cinema |

The test_suite class (90 files) carries none of these records. In the damaged class, the only one is the GDAL ExtraSamples writer bug.

## Proposed classes (re-graded 2026-11-06)

Columns:
- **Damage:** campaign cases out of 743 detections, plus an example mutation.
- **Writer:** real-world files and their producers.
- **Specified decode:** whether the specification defines a decode for the data as written. A deviation in a descriptive field leaves the image payload's decode defined.
- **Proposed:** FAIL, WARN or open, by the 2026-11-06 rule:
  - FAIL when the specification gives no decode, for a checksum or length mismatch, or when damage is the only observed source.
  - WARN when the specification gives a decode and producer repetition shows a writer made it.
  - Open when there is no evidence either way.
- **KNOWN_DEFECT:** the candidate signature. There is no treatment column (owner, 2026-11-05 15:25).
- **Changed:** whether the 2026-11-06 re-grade changed the row. The 2026-11-05 draft had a "Decodes" column (whether other readers cope); it is gone.

| Rule or reason | Now | Damage | Writer | Specified decode | Proposed | KNOWN_DEFECT | Changed |
|---|---|---|---|---|---|---|---|
| 17 entries out of order | FAIL | 11: a bit in a tag ID (sniper rgb_zstd.tif round 130) | 13 (Sony ARW, 13 bodies; Samsung NX500) | yes: every entry is still defined | WARN | Sony ARW candidate | basis only |
| 18 r1, a type a reader could widen (SHORT for LONG, RATIONAL forms) | FAIL | 3: a bit in the type field (RowsPerStrip, FillOrder, PhotometricInterpretation) | 3 (HP, NeXT, Samsung NX500) | yes: the value is representable | WARN | | basis only |
| 18 r1, an unknown or unreadable type (raw type 0 or above 18) | FAIL | yes, a type-field flip | none | no | FAIL | | no |
| 18 r2, count on a field that drives decoding (StripOffsets, StripByteCounts, TileOffsets, TileByteCounts, BitsPerSample, SampleFormat) | FAIL | 1 (SampleFormat count, sniper gray16_lerc.tif round 156) | Canon 40D IFD0 BitsPerSample | no: per-sample or per-chunk layout undefined | FAIL | Canon CR2 IFD0, admitted | no |
| 18 r2, count on a descriptive field (MinSampleValue, ExtraSamples, ...) | FAIL | 2 (TransferFunction count, rgb_zstd.tif sniper round 132, bolter round 136) | Kodak DCS bodies (MinSampleValue); GDAL ExtraSamples bug | yes for the payload | WARN | Kodak MinSampleValue candidate | basis only |
| 18 r3, value of a field that drives decoding (Compression, PhotometricInterpretation, Predictor, PlanarConfiguration, BitsPerSample, SampleFormat, SamplesPerPixel) | FAIL | 3 (SampleFormat, Compression 16385, Photometric 1026; gray16_geotiff.tif rounds 280 and 292, rgb16.tif round 341) | Sony Compression 32767 | no | FAIL | Sony ARW candidate | no |
| 18 r3, Predictor 3 with samples that are not whole bytes | FAIL | not observed | none | no (TN3) | FAIL | | no |
| 18 r3, value of a descriptive field (Orientation, ResolutionUnit, Threshholding, FillOrder, ...) | FAIL | 2 (Orientation, FillOrder) | Kodak Orientation 9 (several bodies) | yes for the payload | WARN | Kodak Orientation 9 candidate | basis only |
| 18 r3, ASCII content (high byte, embedded NUL run, missing terminator) | FAIL | 2 (nuke deflate-last-strip.tif rounds 85, 90: GeoAsciiParams) | Leica, Nikon Coolscan, Kodak DCS 3 | yes for the payload | WARN | | basis only |
| 18 r3, TileWidth or TileLength not a multiple of 16 | FAIL | not observed | Apple iPhone DNG (2 files) | yes: the tile grid is fully stated | WARN | Apple candidate | basis only |
| 18 r3, an offset or pointer outside the file (SubIFDs, ExtraCameraProfiles, ...) | FAIL | yes: an offset flip | none | no | FAIL | | no |
| 18 r4 channel mismatch (SamplesPerPixel against Photometric, no ExtraSamples) | FAIL | not observed | Kodak P880, P712 KDC; Kodak EOS DCS 3 | yes for the color channels; the extra sample has no defined meaning | WARN | Kodak KDC candidate | basis only |
| 18 cross-field: palette without ColorMap; transparency mask not 1 bit; palette or mask with JPEG | FAIL | yes, a Photometric flip | none | no | FAIL | | no |
| 18 cross-field: YCbCr RowsPerStrip not a multiple of vertical subsampling; StripRowCounts with RowsPerStrip | FAIL | not observed | none | no: chunk layout ambiguous | FAIL | | no |
| 18 cross-field: ImageLayer; DNG DefaultUserCrop, NoiseProfile signs, ProfileToneCurve endpoints | FAIL | not observed | none | yes for the payload | open (was WARN because rendering metadata is readable) | | yes |
| 18, DNG Chapter 3 restrictions (Compression and bit-depth lists, Photometric by role) | FAIL | not observed | none | decode-driving rows: no; others: yes | FAIL for decode-driving rows; open for the others (was WARN) | | yes |
| 18, GeoTIFF Tier 1 (types and counts of the six georeferencing tags) | FAIL | 2 (GeoAsciiParams, above) | none | yes when enough values are present | FAIL: damage is the only observed source (was WARN when readable) | | yes |
| 19 rules 1, 2, 3, 5 (JPEG strip and tile geometry against SOF and MCU) | FAIL | not observed | none | no: pixel placement undefined | FAIL | | no |
| 19 rule 4 (YCbCrSubSampling against SOF factors) | FAIL | not observed | Leica M11, Ricoh GR | yes: the JPEG stream defines its own sampling | WARN | DNG 4:2:2 candidate | basis only |
| 19 rule 6 (DNG SOF variant) | FAIL | not observed | Blackmagic Micro Cinema | yes: the SOF names its process | WARN | | basis only |
| 19 rule 7 (hierarchical JPEG in a DNG) | FAIL | not observed | none | no: DNG defines baseline and lossless only | FAIL | | no |
| presence 1: ImageWidth, ImageLength, strip or tile offsets and counts | (held) | yes: a tag-ID flip | none | no | FAIL | | no |
| presence 1: PhotometricInterpretation | (held) | yes | the Canon SPP layout | no: TIFF 6.0 gives it no default | FAIL (was WARN because readers infer it) | Canon SPP candidate | yes |
| presence 1: XResolution, YResolution | (held) | yes | many | yes for the payload | WARN (owner, 11:07) | | no |
| presence 2: tiles stored in strip tags | (held) | unlikely | libtiff pics quad-tile, cramps-tile | no: TIFF 6.0 describes tiles only through the tile tags | FAIL by the rule (was WARN because libtiff reads them); tiffz tolerates it today with a warning record, so this needs validate's ruling | | yes |
| presence 3: a tile field without its partner | (held) | yes | none | no | FAIL | | no |
| checksum or declared-length mismatch (Adler-32, LERC, Zstd checksum, truncated strip) | FAIL | the bulk of the 719 | none | no | FAIL (owner, 11:13) | | no |
| TileByteCounts or StripByteCounts zero for a chunk with a nonzero offset | FAIL (SourceTooShort) | yes: a zeroed count | 1 test_suite file: GDAL COG, sizes in a 4-byte leader | only through GDAL's declared leader convention | FAIL, unless the ghost header declares the leader (amendment 3) | | basis only |

**What changed on 2026-11-06.** Rows marked "basis only" keep their grade on producer evidence, without reader evidence. Five rows changed:
- **Rendering metadata cross-field rows:** they had no evidence either way, so they are open.
- **Non-decode-driving DNG Chapter 3 rows:** likewise open.
- **GeoTIFF Tier 1:** damage is its only observed source, so it is FAIL.
- **Missing PhotometricInterpretation:** TIFF 6.0 gives it no default, so it is FAIL.
- **Tiles in strip tags:** the rule makes it FAIL, but tiffz tolerates it today, so it waits for a ruling.

The rows behind the 16 real-world flips below are all writer-evidenced and unchanged. The presence rows are on a held branch, so the effect counts do not move.

## Effect

**Pinned corpus, files invalid today that would become ok with warnings:**

| class | invalid today | would flip |
|---|---|---|
| real_world | 42 | 16 |
| test_suite | 1 | 0 |
| damaged | 3 | 1 |

The counts are on acb0c0aa. Since 12ae528f, a feature tiffz does not implement is reported as unsupported (reach, exit 4) rather than invalid. That moved 10 pinned files out of "invalid": 3 Samsung DNGs (real_world), 6 GDAL JPEG-tables files (test_suite) and 1 damaged GDAL file.

- **real_world:** Kodak DCS 14n, 14nx, SLR/n, SLR/c, DCS760C, DCS520C and EOS DCS 3; Kodak P880 and P712 KDC; Apple iPhone 6s Plus and iPhone 12 Pro; Leica M11; Blackmagic Micro Cinema; Nikon Coolscan IV; HP smallliz and NeXT zackthecat.
- **test_suite:** the one invalid file is `cog_strile_arrays_zeroified_when_possible.tif`; see the GDAL row and question 4.
- **damaged:** the GDAL ExtraSamples writer bug.

**The Sony ARW files stay invalid,** because Compression 32767 has no specified decode. So do the files whose discrepancy is a decode error.

**Corruption coverage:** 20 of the 743 campaign detections (2.7%) would become warnings. They are 9 sniper, 9 bolter and 2 nuke cases, all lone finding 17 records, readable-type faults or descriptive finding 18 records. The other 4 record-carrying cases stay FAIL: SampleFormat count and value, Compression 16385 and Photometric 1026. Under A2 they are "damage that mimics a writer violation". Coverage would report them in a warning column, apart from FAIL, and the pinned case-set gate would need that column too.

## Open questions

1. **Is "drives decoding" the right line for finding 18 value and count faults?** The field list above is tiffz's proposal.
2. **Warning and INFO:** one severity or two? Einstein was asked on 2026-11-05.
3. **The 20 campaign cases:** should a warning that came from damage count as detected (it is still reported) or as missed (it no longer fails)?

4. **GDAL's zeroed byte counts.** `cog_strile_arrays_zeroified_when_possible.tif` (GDAL autotest) has TileByteCounts 0,0,0,0 with offsets 842, 953, 1070 and 1174. Its ghost header says `BLOCK_LEADER=SIZE_AS_UINT4`, and the 4 bytes before offset 842 hold 78, the tile's real size. GDAL reads the sizes from the leaders; libtiff refuses ("Invalid tile byte count") and so does tiffz (SourceTooShort). TIFF 6.0 has no zero-count chunk with data. Is this a GDAL extension tiffz should read (reach, like a codec), a WARN when the ghost header declares it, or FAIL as written? The second IFD's offset-0, count-0 tiles are GDAL's separate sparse convention (SPARSE_OK), with the same question.

5. **GDAL's two "JPEG codestream taller than the last strip" files disagree, but not over the quirk.** Both files are reference-only: excluded, license unknown. Both are 20x19 Compression 7 pages with RowsPerStrip 16 and JPEGTables. In each, the last strip holds 3 rows but its SOF0 declares 4 (strip 1 at 653 in the gray file, at 1115 in the YCbCr file). libtiff accepts both.
   - `tif_jpeg_ycbcr_too_big_last_stripe.tif` (YCbCr, 3 components) decodes and is `ok`. The extra row is tolerated as finding 13 (`final_strip_padding_tolerated`, a warning) at offset 1115.
   - `tif_jpeg_too_big_last_stripe.tif` (BlackIsZero, 1 component) is `unsupported`: UnsupportedCompression at offset 460, which is strip 0. The walk stops before reaching the last strip, so the quirk is never judged. This is the abbreviated-stream reach gap listed for GDAL's JPEG-tables files. Strip 0's own SOF0 matches its strip: 16 rows by 20.

   So the quirk has one verdict, a warning. Once the gray JPEG-tables gap is closed, the gray file should land on the same finding 13. Question for the audit: is a JPEG frame one row taller than its last strip (libtiff accepts it, and GDAL's writer produced it) the warning this file shows, or KNOWN_DEFECT once validate's registry admits the GDAL signature?
   **Ruling (validate, 2026-11-05):** WARN (finding 13) by default. KNOWN_DEFECT only through the admission rule: the same signature in 3 or more independent real-world files or in verified checksummed bytes, or a documented upstream producer bug describing it exactly (a libtiff or GDAL writer note or fix commit). These two GDAL test files count as neither. Close the JPEG-tables reach gap first, so the gray file reaches the same finding.


## validate review, 2026-11-05 14:51 (owner approval pending)

## Amendments

**1. "No specified decode" means no decode exists anywhere, not "the TIFF spec defines none".**
- **Withdrawn 2026-11-06** by validate after the owner's correction. "No specified decode" now means the specification defines none.
- Sony Compression 32767 is a vendor codec. rawz decodes the Sony raw payload, and LibRaw reads all 11 exemplars.
- So the generic row stays FAIL: an unassigned Compression value outside a recognized signature is damage-likely.
- But the Sony signature becomes KNOWN_DEFECT, **warning-treated**, because the data does decode through the vendor format.
- The Sony admission is still the owner's call.

**2. Canon CR2 IFD0 BitsPerSample count: KNOWN_DEFECT, warning-treated, not failure-treated.**
- The generic decode-driving count row stays FAIL, as proposed.
- But inside the Canon signature, the layout is resolved: three 8-bit components in a Compression 6 JPEG. LibRaw and rawspeed decode all 15. libtiff warns, applies SPP 3 and reads it.
- Same principle as 1: the signature carries the reader evidence, so the treatment follows decodability.

**3. GDAL zeroed byte counts (question 4).** Use FAIL as written, unless the file itself declares the extension.
- With `BLOCK_LEADER=SIZE_AS_UINT4` in GDAL's ghost header and leader sizes that agree, it is WARN: a declared producer extension that its producer's reader decodes. Reading the leaders is a reach item for tiffz (decode support), like a codec.
- Offset-0, count-0 tiles: WARN only when the ghost header declares `SPARSE_OK=TRUE`; otherwise FAIL.
- Record the ghost header and the leader check in the record's detail, so the WARN is explained.

**4. Your questions 2 and 3.**
- **(2) WARN and INFO stay two severities.** WARN (A2, exit 3) is a spec violation. INFO (A3, exit 0) means the file conforms and has a property worth knowing. That covers the should-rows: not following a "should" breaks no requirement. Einstein numbers the carriers.
- **(3) Warned campaign cases are their own outcome,** neither detected nor missed: validate's corruption-experiment already counts exit 3 as "warned". The pinned case-set file needs a `warn` line type beside `detect`, so a case can't silently drift between the two. Add a controlled red: a pinned warn case that turns into a detect, or the reverse, must fail.

## Accepted as proposed

- the "drives decoding" line for finding 18 count and value faults (question 1);
- every other row;
- the effect tables: 16 of 42 invalid real-world files would become ok with warnings, and 20 of 743 campaign detections (2.7%) would become warned.

Later refinement, not for this batch: inside the WARN rows, an out-of-domain value one bit flip from a legal value in a sparse domain could be raised to FAIL. That is the "bit distance" adjustment in validate's notes. Only with campaign evidence that it improves the damage-reported-as-WARN rate without adding false FAILs.


## validate update, 2026-11-05 (owner rulings 15:25)

## KNOWN_DEFECT always exits 4, whatever its treatment

The owner, at 15:25:

> It's not our call to decide what spec deviations are accepted by the community. But we can be honest about those spec deviations, and KNOWN_DEFECT covers that. This also gets us out of the business of judging warning level based on who (if any) can read/parse it.

**What this means for the table:**
- **The KNOWN_DEFECT column takes no treatment.** Drop "warning-treated" and "failure-treated" from it.
- **Reader results become a recorded fact.** That includes LibRaw and rawspeed decoding the Canon files, and rawz decoding Sony.
- **Amendment 1 (Sony 32767)** becomes: the generic row stays FAIL; the Sony signature is a KNOWN_DEFECT candidate.
- **Amendment 2 (Canon IFD0 count)** becomes: the generic row stays FAIL; the Canon signature is a KNOWN_DEFECT, already admitted.

## Admission now needs writer evidence

A tolerating reader is no longer required. Admission rests on the same signature in at least 3 independent real-world files, or inside verified checksummed bytes. A documented upstream producer bug, reproduced synthetically, is also accepted.

Amendments 3 and 4 are unchanged. The table itself still waits for the owner's approval.


## validate update, 2026-11-06 (owner corrections)

- **The owner, November 6:** "we are no longer in the business of judging what's acceptable, just what's out of spec ... we don't judge based on what other readers do anymore." The table above drops the readers column and re-grades every row from producer and damage evidence. See "What changed on 2026-11-06".
- **Amendment 1's reading of "no specified decode" is withdrawn.** It now means the specification defines none.
- **Admitted:** the DNG exactly-full Huffman table (Pentax K-x, K-r, Ricoh GR, DJI FC4382) is a KNOWN_DEFECT. jpegz emits 71 `huffman_table_full_all_ones` at KNOWN_DEFECT severity, and tiffz needs a repin.
- **The owner, on unchecked payloads:** "we need to parse everything parseable." Every "unsupported" reach on a payload the specification defines is a work item, not an end state (`codec-reach.md`).

## validate review of the re-grade, 2026-11-06

- **Accepted,** including GeoTIFF Tier 1 and a missing PhotometricInterpretation becoming FAIL. The admitted Canon CR2 entry absorbs its exact presence sets, as recorded on November 5.
- **Tiles in strip tags: FAIL by default.** TIFF 6.0 section 15 says the tile fields replace StripOffsets, StripByteCounts and RowsPerStrip, so the specification gives no decode for tile geometry addressed through the strip tags. libtiff's pics samples (quad-tile, cramps-tile) are test-suite files and are not producer evidence. Three independent files from a real producer, for example a pre-6.0 libtiff written to the Aldus tiling draft, would make it a KNOWN_DEFECT candidate.
- **Rename** `tiled_geometry_via_strip_tags_tolerated`: "tolerated" encodes acceptability. Approved by validate 2026-11-06 as `tiled_geometry_via_strip_tags`, same number and payload, and renamed.
- **The two open rows** (rendering-metadata cross-field rows; DNG Chapter 3 rows that don't drive decoding) keep their shipped routing until evidence decides them. The evidence needed is a corruption campaign over fixtures carrying those tags, plus a producer survey of the corpus.
