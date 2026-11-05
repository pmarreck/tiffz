# IFD-entry faults tiffz accepts silently

Twelve corruption cases from the gating campaign (master 42, 385 trials per
profile, corruption-reader 0.8.0, tiffz 4bba9948) that tiffz accepts with an
unchanged finding set, while libtiff 4.7.2 `tiffinfo -D` reports a
diagnostic the unmutated seed does not produce. Each is a single changed
byte in a tracked fixture, inside an IFD entry. None touches sample data.

Status: validate ruled on 2026-11-03 that all twelve are proven TIFF 6.0
violations, so the verdict is corrupt (validate FAIL), never valid and
never known_defect. Findings are named for what was found:
`ifd_entries_unsorted` and `tag_field_invalid`. The Namespace B numbers
(proposed 17 and 18) await Einstein's sign-off. Keep these cases as
regressions, with the clean seeds as controls, and raise the floors when the
findings ship.

validate's decoding of the bytes:

- Cases 3, 5, 8, 9, 10 and 12 are corrupted tag IDs, not reorderings:
  PlanarConfiguration 284 becomes 8476, 4380 or 65052 (3, 5, 12),
  Compression 259 becomes 8451 (8), SamplesPerPixel 277 becomes 65045 (9),
  and GeoAsciiParamsTag 34737 becomes 30897 (10). Each lost value equaled
  the TIFF default, which is why the pixels match the seed; case 10
  silently loses the GeoTIFF ASCII parameters. The ordering violation is
  the only evidence of that damage.
- Case 1: TransferFunction count 256 becomes 272. Case 2: SampleFormat
  count 1 becomes 33, which turns the value field into an offset (1) into
  the header. Case 4: SampleFormat 257. Case 6: Orientation 257. Case 7:
  FillOrder type SHORT becomes FLOAT (11). Case 11: FillOrder 254.

Normative basis (TIFF 6.0): entries sorted ascending by tag (p. 15); the
reader must check the type, and BYTE, SHORT or LONG is acceptable for any
unsigned-integer field, arrays included (p. 16; validate corrected its
scalar-only wording on 2026-11-04); FillOrder SHORT, N = 1, 1 or 2
(p. 32); Orientation SHORT, N = 1, 1 to 8 (pp. 36-37); SampleFormat SHORT,
N = SamplesPerPixel, 1 to 4 (p. 80); TransferFunction N = {1 or 3} *
(1 << BitsPerSample) (p. 84). Not violations, and so not to fail:
FillOrder 2 on 8-bit data, Orientation 2 to 8, SampleFormat 4.

| # | Seed | Offset | Old | New | libtiff diagnostic |
|---|---|---|---|---|---|
| 1 | tests/fixtures/zstd/rgb_zstd.tif | 134 | 0x00 | 0x10 | Incorrect count for "TransferFunction"; tag ignored |
| 2 | tests/fixtures/lerc/gray16_lerc.tif | 134 | 0x01 | 0x21 | SampleFormat count 33, SamplesPerPixel 1; bad value 10825 for SampleFormat |
| 3 | tests/fixtures/geotiff/gray16_geotiff.tif | 119 | 0x01 | 0x21 | tags are not sorted in ascending order |
| 4 | tests/fixtures/geotiff/gray16_geotiff.tif | 139 | 0x00 | 0x01 | bad value 257 for SampleFormat |
| 5 | tests/fixtures/photometric/ycbcr.tif | 911 | 0x01 | 0x11 | tags are not sorted in ascending order |
| 6 | tests/fixtures/photometric/ycbcr.tif | 871 | 0x00 | 0x01 | bad value 257 for Orientation |
| 7 | tests/fixtures/photometric/cmyk.tif | 1096 | 0x03 | 0x0b | incompatible type for FillOrder; tag ignored |
| 8 | tests/fixtures/photometric/rgb16.tif | 1583 | 0x01 | 0x21 | tags are not sorted in ascending order |
| 9 | tests/fixtures/geotiff/gray16_geotiff.tif | 83 | 0x01 | 0xfe | tags are not sorted in ascending order |
| 10 | tests/fixtures/geotiff/gray16_geotiff.tif | 191 | 0x87 | 0x78 | tags are not sorted in ascending order |
| 11 | tests/fixtures/photometric/cmyk.tif | 1102 | 0x01 | 0xfe | bad value 254 for FillOrder |
| 12 | tests/fixtures/predictor/predictor3_deflate_fp32.tif | 119 | 0x01 | 0xfe | tags are not sorted in ascending order |
| 13 | tests/fixtures/photometric/rgb16.tif | 1603 | 0x00 | 0x04 | (none: libtiff accepts PhotometricInterpretation 1026) |
| 14 | tests/fixtures/geotiff/gray16_geotiff.tif | 55 | 0x00 | 0x40 | Compression scheme 16385 strip decoding is not implemented |

Cases 1-8 are sniper (one bit) and 9-12 bolter (one byte). By seed class:
1 unchecked (Zstd), 2 and 12 checksummed (LERC, Deflate), the rest
uncompressed. Cases 13 and 14 (sniper round 336 case 6 and round 273
case 20) became detections with the Compression and
PhotometricInterpretation value sets (commit 222a6069). Their arrival
moved the deterministic draw, so the sniper checksummed case at
predictor3_deflate_fp32.tif offset 638 (0x31 to 0x21, round 378 case 11,
a Deflate data error) is no longer drawn. It is pinned as its own replay
in `tests/fixture_test.zig` (validate, 2026-11-04).

To rebuild case N into `out.tif` from its seed, offset and new byte:

```sh
{ head -c "$offset" "$seed"; printf "\\x$new"; tail -c "+$((offset + 2))" "$seed"; } >out.tif
```

where `$new` is the New column without `0x`.

## Real-file impact (2026-11-04)

Before landing, the increment (ordering plus the four tag rules) was run
against the previous commit over 63 real TIFF-family files: validate's
ground-truth set (TIFF, DNG and camera raw; its deliberately corrupted files
excluded), this repository's fixtures and rawz's test files. 62 verdicts are
unchanged, and no file produces finding 18.

One verdict changes. A Sony ILCE-7S ARW (firmware "ILCE-7S v3.20",
DateTimeOriginal equal to ModifyDate, so not re-saved by other software)
goes from ok to invalid with three `ifd_entries_unsorted` findings in its
raw-data SubIFD. XResolution follows PlanarConfiguration, SonyRawFileType
(0x7000) follows CFAPattern, and StripOffsets follows the Sony tag 0x7020.
exiftool's `-validate` reports the same three entries as out of order.

It is a producer pattern, not damage. A follow-up survey of 12 CC0 Sony
samples from raw.pixls.us (one a byte-identical copy of the corpus file, so
11 distinct exemplars in all) (checked against their published sha256, kept
out of every repository) found the same three SubIFD misplacements in every
ARW 2.1 to 4.0.1 file. That covers 10 bodies with firmware from 2008 to
2023. ARW 2.3.3 and later add two more around the DNG-range tags 0xC61D
to 0xC620. ARW 1.0 is sorted. exiftool flags exactly the same entries.
Stable-sorting the entries gives an ok verdict with identical LibRaw raw
data and embedded previews. Per validate's addendum, these files stay
corrupt unless validate's KNOWN_DEFECT registry admits the signature with
evidence. tiffz never admits a producer pattern itself. Both reports went to
validate on 2026-11-04.

### Sony ARW evidence of record

By hash and size only; the sample files are not committed. All are camera
firmware output (Software is the body's firmware string). "Unsorted" counts
`ifd_entries_unsorted` findings, all in the raw-data SubIFD. exiftool
13.59 reports the same entries, and LibRaw 0.22.1 reads every file.

| model | firmware | ARW | sha256 | bytes | unsorted |
|---|---|---|---|---|---|
| ILCE-7S | v3.20 | 2.3.1 | a35ebb2fbec929daa5beb20d1ce5c15a8aac7b1a7a231455387f3df8a7442e07 | 6160384 | 3 |
| ILCE-7S | v3.20 | 2.3.1 | 7cc338a0abc8fdad32d61006f1f8f412297b93e040c7efba572eb2bd8f8e8be2 | 13107200 | 3 |
| ILCE-7SM2 | v2.10 | 2.3.2 | 46044fb6a9c805f2b4915cd4970316b4d04b0566bcf5287afaad3ef648d7a3db | 13271040 | 3 |
| ILCE-7 | v2.00 | 2.3.1 | c242df04d4a0e246130600e102371d4aea2e7eeac35c1e65c4757191dcb7cd33 | 24969216 | 3 |
| ILCE-6000 | v3.20 | 2.3.1 | ce8b4957281a817d52a07a691e2468567b6c78223bd0b514ffc1c65b002b8d89 | 25624576 | 3 |
| DSC-RX100 | v1.00 | 2.3 | 579a485b5126a25cbd55cbd5dadfa7d09cf021c99cc7d4869f9e56e3f759390b | 21155328 | 3 |
| DSLR-A900 | v2.00 | 2.1 | ac7c1532df77c321e8010aa1be60c1b9f245b1ac0db6f38fe617a73aae81af50 | 37933568 | 3 |
| ILCE-7M3 | v1.00 | 2.3.3 | 250784580ea527442c09004417bb0eead484f2bf3ee8f9121a776ac65bb50d0f | 25639680 | 5 |
| ILCE-1 | v1.00 | 4.0 | ddb72880da333b46a4c13286f78473dacc11377ea874bc3656e64e30a8122a88 | 63216896 | 5 |
| ILCE-7SM3 | v2.01 | 4.0 | 17e35d98d448b44164ecf414f980e9248b5829233e83a1adbee396b6c1a1a0c6 | 15468544 | 5 |
| ILCE-7M4 | v2.00 | 4.0.1 | 639a6d4db881f1359e3ea7e1137b314e59417d24e6d4d862b7202111a2c823b2 | 19636224 | 5 |
| DSLR-A100 (control) | v1.04 | 1.0 | 4df7981ac4baec9648b4f106751ea4b09a6e27bc70a15f8ef09bec051fec362d | 10137572 | 0 |

The three layouts, as (tag, previous tag) pairs:

- ARW 2.1 to 2.3.2: (0x011A, 0x011C), (0x7000, 0x828E), (0x0111, 0x7020).
- ARW 2.3.3: those three, plus (0x7316, 0xC61D) and (0x74C7, 0xC620).
- ARW 4.0 and 4.0.1: those three, plus (0x74C7, 0xC620) and (0x0102, 0xC61D).

Repair-to-pass: stable-sorting the SubIFD's entries gives an ok verdict
with the same findings minus code 17. LibRaw's unprocessed raw data and the
extracted PreviewImage and ThumbnailImage are unchanged. validate recorded
the pattern as a KNOWN_DEFECT candidate on 2026-11-04. Admission is the
owner's decision, and validate will not adopt finding 17 until it is made.

## Wider corpus (2026-11-04)

165 real files: the 63 above, libtiff's pics-3.8.0 archive (61 TIFFs; tarball
sha256 e0e34732b61e1ce49eff2c7a079994c856d2a5f772f5228c84678272bc6829a9), the
11 Sony ARWs, and 30 CC0 raw.pixls.us files covering one per other maker and
format, plus 7 more Kodak TIFF-based raws. Beyond the Sony pattern, these files
have findings 17 or 18:

| file | firmware | sha256 | bytes | finding | verdict |
|---|---|---|---|---|---|
| Kodak DCS760C | 3.2.8 | d0e6bd0a3339daff884e73a08fed8e75b20fe05bba438fc185e3f0bd019d0da8 | 7547392 | 18 Orientation = 9 | ok -> invalid |
| Kodak DCS520C | 3.2.3 | d95e983bea9cf13f356e49b0f59629306bc7a51882ff20766c74ccff5f007d69 | 1970973 | 18 Orientation = 9 | invalid (other cause) |
| Kodak DCS Pro SLR/c | 5.4.9 | dca493a81bd4f87428d1584fa4ee6a4e98c97d6540b16a7a42d25916b0fd6107 | 14920832 | 18 ResolutionUnit = 0 (new row) | ok -> invalid |
| Samsung NX500 | (none) | 156e43118811bcecb6fcc600b5f41ee1773c4f00b6a5b2dd72e177e35f6596ab | 20750652 | 17 SubIFDs after ExifOffset in IFD0 | invalid (other cause) |

exiftool flags each one too. Kodak's 3.x firmware writing Orientation 9 is a
producer-pattern candidate with two exemplars. The other two are single files.
All were reported to validate, and none is admitted.

The corpus is pinned in `real_corpus_manifest.tsv` (sha256, size, source and
name per file), so later reports run against the same baseline and list any
added files explicitly. Rule rows are batched by specification section,
with one corpus report per batch (validate, 2026-11-04).

## TIFF 6.0 batch rulings (validate, 2026-11-04)

1. ASCII (p. 15): a byte of 0x80 or above, or a final byte other than NUL,
   is a value fault. A count of 0 is a count fault.
2. NUL runs (p. 16): only a run followed by more text ("A\0\0B") is a fault.
   Trailing padding ("Model\0\0\0") is recorded as data only.
3. YCbCr multiples (p. 92): ImageWidth, ImageLength, TileWidth and
   TileLength wait for the Technical Notes batch (pinned in
   `ifd_conformance.pending`). RowsPerStrip uses the effective rows per strip,
   min(RowsPerStrip, ImageLength), and a multi-strip value must already be a
   multiple of YCbCrSubsampleVert, which defaults to 2.
4. "Private" means defined by no claimed specification, whatever the number.
   Copyright (33432) is checked.

Also, BigTIFF allows LONG8 for StripOffsets, StripByteCounts, TileOffsets
and TileByteCounts only (BigTIFF design, libtiff documentation). LONG8 in
any other field, or in a classic TIFF, is a type fault.

## Canon CR2 evidence of record (2026-11-04)

Every Canon CR2 surveyed gives IFD0 a three-value BitsPerSample ([8, 8, 8], the
old-style JPEG preview) and omits SamplesPerPixel, whose default is 1. So
`tag_field_invalid` (count) is reported at IFD0 entry 2, and every file goes
from ok to invalid. Repair-to-pass rebuilds IFD0 with SamplesPerPixel 3 inserted
in tag order. Each repaired copy validates ok with the same partial coverage,
and LibRaw's raw data and the extracted previews are unchanged. The files are
CC0 samples from raw.pixls.us, kept out of every repository; the CR2 test fixture
is the 40D. By hash and size:

| model | firmware | year | sha256 | bytes | repair identical |
|---|---|---|---|---|---|
| Canon EOS 40D | 1.1.1 | 2017 | ba644e7dd2abe74eca260e67f0206ff113bf0f62e710f8130611e964d6be5bf1 | 5805950 | yes |
| Canon EOS-1D Mark III | 1.3.0 | 2017 | 860b5c9791548db8081823e3852c436a439e648ea863b0def05e99aac6e9e726 | 14312777 | yes |
| Canon EOS-1D X Mark II | (not recorded) | 2017 | 35b66b2fc26a015ee622af7269eaf3e694fa6f5b6126ade27d910957d417d81a | 12294856 | yes |
| Canon EOS 20D | (not recorded) | 2017 | db78660d48589130d99e0bc621424851eb0f84df052634fb5bc89c7a02fe7033 | 7489116 | yes |
| Canon EOS 30D | (not recorded) | 2017 | fb216f8df8d7abca4eb9d9f8dc594c1d2b69d0a6369fb8b4107743343c37144f | 9254110 | yes |
| Canon EOS 350D DIGITAL | (not recorded) | 2008 | 8cbb84e04d93b005fe082da9c954122a612b5281af00aa088d767850f343fd38 | 10586467 | yes |
| Canon EOS 50D | 1.0.9 | 2017 | 1f8521e21d53e8df6c5f6b390aa4e0e9928e87412e94d0d0a6f34f4848c18304 | 9705243 | yes |
| Canon EOS 5D Mark III | 1.2.3 | 2017 | a79065e78a6c5bdbc8726e786ade02d54a7d496cc3cb4504d804c924a3d999da | 12343414 | yes |
| Canon EOS 5D Mark IV | (not recorded) | 2017 | 25d928f9e9a65525ac796bdff13e93b7b36b627568d7a17338e12dc44424078a | 15217883 | yes |
| Canon EOS 60D | 1.1.1 | 2017 | 248945210b1edd43073499f8211707e06adf5a66e416ca9d1c86196e3f941d19 | 11955913 | yes |
| Canon EOS 6D Mark II | (not recorded) | 2017 | a4bf9842c2222b2eeb95ec71065f9d981c9b5be619b96db7f121e395968a119b | 20556842 | yes |
| Canon EOS 6D | 1.1.7 | 2017 | a4f71895b4c5087791ed2cb97b30790ae9d52a9e7b66f0c9ea91cf3e4a12335b | 11605858 | yes |
| Canon EOS 70D | 1.1.1 | 2017 | dd166060ef873a2356f9a41a991b875d09229692cf219073e65dc906e42e042f | 12068759 | yes |
| Canon EOS 7D | 2.0.3 | 2016 | 3789b1ba5d880613104637c40a06619cd9f3b54b0cf62d2d95b9f9e885edcf6e | 11062629 | yes |
| Canon EOS 80D | 1.0.1 | 2017 | f9c5404b57248c21e9b269721aa0d721c3b1281c94ebdee3c50bf32db42613a8 | 20220625 | yes |
| Canon PowerShot G9 | (not recorded) | 2009 | ad27a4d751984cd709380e3be274a4a5243d36ca89c5fc711736ba8a9f5c932f | 12586055 | yes |

A Canon PowerShot S2 IS sample named .CR2 is in fact a DNG written by CHDK
(third-party firmware). Its DateTime is binary garbage, a different producer
and fault (sha256 445764716df165a1facd37c01d67ede44ca49671ed1a6112dd8ff7426324c757,
6611520 bytes). No surveyed CR2 writes SamplesPerPixel in IFD0.

## Kodak MinSampleValue repair-to-pass (2026-11-04)

The six Kodak DCS files give MinSampleValue one value where SamplesPerPixel is
3 (YCbCr preview IFDs). libtiff reads the single value (0) without a warning,
so readers apply it to every sample. Repeating the value to count 3 (stored
out of line) removes every MinSampleValue finding. The three files with no other
fault (DCS Pro 14n, 14nx, SLR/n) then validate ok. LibRaw raw data and the
extracted previews are identical in all six.

## Technical Notes batch rulings (validate, 2026-11-04)

1. XClipPathUnits and YClipPathUnits are "Type = DWORD" in the PageMaker 6.0
   notes. Only what every reading agrees on is checked: a 32-bit integer type
   (BYTE, SHORT, LONG or SLONG) and N = 1, with no value or sign check.
   libtiff registers both as LONG, which is context, not authority.
2. TIFF Technical Note 2 rewrites TIFF 6.0 Section 21 for every YCbCr
   image, whatever the compression: "ImageWidth/ImageLength are not
   constrained" (validate corrected its earlier Compression-7-only reading
   the same day). Only tile sizes and a multi-strip RowsPerStrip must be
   multiples of the subsampling. Tile sizes need no separate check, since a
   multiple of 16 is a multiple of any subsampling factor.
3. TN2's DCT geometry (multi-strip RowsPerStrip and tile sizes as MCU
   multiples) and its rule that SOF sampling factors equal YCbCrSubSampling
   are checked where the SOF is parsed. The finding cites the entry and the
   SOF offset, and unexamined data counts as reach, never a pass. validate
   approved `jpeg_segment_geometry_invalid` with changes: exact SOF classes
   (DCT 0, 1, 2, 5, 6, 9, 10, 13, 14; lossless 3, 7, 11, 15) pinned by a
   test; every segment scanned, one record per IFD per rule with violating and
   examined segment counts; luma-to-chroma ratio agreement for
   PlanarConfiguration 1, with no subsampling for non-YCbCr; all factors 1
   for PlanarConfiguration 2; and tiffz's own bounded SOF scan for now, with
   a differential test against jpegz, until jpegz offers a frame-header API.
   The number needs Einstein, so the rule waits in `ifd_conformance.pending`.

## ExtraSamples count ruling (validate, 2026-11-04)

m is the count of ExtraSamples, or 0 when the field is absent. It must equal
SamplesPerPixel - C, where C is the number of color channels the photometric
implies. ExtraSamples (p. 32): "This field must be present if there are extra
samples", and readers "must not assume a particular SamplesPerPixel value based
on the value of the PhotometricInterpretation field". C is:

- 1 for 0 and 1, the one-component WhiteIsZero and BlackIsZero definitions
  (p. 37).
- 3 for RGB 2 (p. 24).
- 1 for palette 3 and transparency mask 4 ("SamplesPerPixel must be 1",
  p. 37).
- NumberOfInks for Separated 5, default 4 (p. 70), for any InkSet. With
  InkSet 1 (CMYK) and an explicit NumberOfInks other than 4, either value is
  accepted.
- 3 for YCbCr 6 (p. 94).
- 3 or 1 for CIELab 8 (p. 111), ICCLab 9 (Photoshop notes) and ITULab 10
  (RFC 3949), since L* may stand alone.

Private photometrics are skipped. A wrong count with ExtraSamples present is a
count fault on ExtraSamples. With it absent, the mismatch is reported once on
SamplesPerPixel, since the file cannot say which field is wrong.

Implementation choices beyond the table, for validate's review:

- Palette 3 and transparency mask 4 require SamplesPerPixel 1 outright
  ("SamplesPerPixel must be 1", p. 37), so ExtraSamples present with
  either is a count fault on ExtraSamples, whatever SamplesPerPixel says.
- With neither SamplesPerPixel nor ExtraSamples present, SamplesPerPixel
  takes its default of 1. A photometric that needs more channels is then
  reported on PhotometricInterpretation (value), the only entry involved.
- InkSet defaults to 1 (p. 70), so an absent InkSet takes the "either 4
  or NumberOfInks" branch. A malformed SamplesPerPixel, NumberOfInks or
  InkSet reports only its own fault.
- Undefined public photometrics (7, 11 and up) have their own value
  fault and no channel check.

Corpus report (140 distinct sha256, pinned manifest), 2026-11-04. No verdict
changes. Three files gain one finding 18 each; all were already invalid.
An independent tiffdump scan of every top-level IFD (`Photometric`,
`SamplesPerPixel`, `ExtraSamples` count, `InkSet`, `NumberOfInks`) found
the two KDC mismatches and no others; tiffdump does not follow SubIFDs,
which is where the third file's mismatch is.

| file | sha256 | bytes | IFD | finding | prior cause | cause |
|---|---|---|---|---|---|---|
| Kodak P880 KDC | 8138d068d14e9ce90c6877b175759fc92358024303b8cd5e9b9eb5ae11e8c4b1 | 13828802 | 0 | PhotometricInterpretation 6 (YCbCr) with SamplesPerPixel absent, entry offset 34 | findings 9 and 2 | producer pattern |
| Kodak P712 KDC | b1c3870c8c794f0271053a80a15296e3a9b575ab736796cdb53929d50c86a084 | 12245402 | 0 | same as P880 | findings 9 and 2 | producer pattern |
| Kodak EOS DCS 3 TIF | dd05419fedb091ca14c86485106e8c338509b09c8188dacf92eef6c78007deca | 1374208 | 1 (SubIFD at 1024) | SamplesPerPixel 3 with BlackIsZero and no ExtraSamples, entry offset 1098 | finding 18 on Make and Software (ASCII without NUL) | producer pattern |

Both KDC IFD0s describe a JPEG thumbnail through JPEGInterchangeFormat
without ImageWidth, ImageLength or SamplesPerPixel. The DCS 3 SubIFD is a
160x128 three-plane thumbnail (PlanarConfiguration 2) labeled BlackIsZero.
Per-row occurrences: ExtraSamples 0, SamplesPerPixel 1,
PhotometricInterpretation 2.

## ExtraSamples re-anchoring and the p. 37 rows (validate, 2026-11-04)

validate accepted choice 2 above, and changed the anchoring:

- Palette 3 or transparency mask 4 with SamplesPerPixel other than 1: one
  value fault on SamplesPerPixel (p. 37), whether or not ExtraSamples is
  present, and no second fault on ExtraSamples. With SamplesPerPixel 1 (or
  absent) and ExtraSamples present, the general rule gives a count fault
  on ExtraSamples (pp. 31-32).
- SamplesPerPixel that is not C, with ExtraSamples absent, is a mismatch
  between fields, not an invalid SamplesPerPixel value. It is reason 4
  `channel_mismatch`, anchored on SamplesPerPixel, or on
  PhotometricInterpretation when SamplesPerPixel is absent and its default
  of 1 (p. 39) is what fails.

Finding 18's payload for reason 4 is 48 bytes: the usual 38, then u16
PhotometricInterpretation, u16 SamplesPerPixel used, u16 1 if stored or 0
if absent, and u16, u16 for the channel counts C allowed (equal when one
is; Lab gives 3 and 1, Separated with InkSet 1 gives NumberOfInks and 4).
Reasons 1 to 3 keep their 38 bytes.

New rows, approved the same day: PhotometricInterpretation 3 without a
ColorMap is a value fault on PhotometricInterpretation ("ColorMap must be
present", p. 37), and a transparency mask's BitsPerSample other than 1 is a
value fault on BitsPerSample ("SamplesPerPixel and BitsPerSample must be
1", p. 37). An absent BitsPerSample takes its default of 1.

Corpus report (140 distinct sha256), against the build before ExtraSamples:
no verdict changes, and the same three Kodak files as above, now reason 4.
The KDC payload extension reads photometric 6, SamplesPerPixel 1 absent, C
3; the DCS 3 SubIFD's reads photometric 1, SamplesPerPixel 3 stored, C 1.
The p. 37 rows change nothing: an independent tiffdump scan finds seven
palette IFDs, all with a ColorMap, and no transparency masks. Controlled
reds: dropping the ColorMap rule, or the mask rule alone, failed the p. 37
test; reporting the mismatch as a value fault failed the channel table and
the payload test.

## GeoTIFF Tier 1 (validate, 2026-11-04)

validate approved six rows under finding 18, cited to OGC GeoTIFF 1.1
(19-008r4):

| Tag | Name | Type | Count | Requirements |
|---|---|---|---|---|
| 33550 | ModelPixelScale | DOUBLE | 3 | 10.2, 10.3 |
| 33922 | ModelTiepoint | DOUBLE | a positive multiple of 6 | 9.2, 9.3 |
| 34264 | ModelTransformation | DOUBLE | 16 | 11.2, 11.3 |
| 34735 | GeoKeyDirectory | SHORT | at least 4 | 2.2, 2.3 |
| 34736 | GeoDoubleParams | DOUBLE | any | 5.1, 5.2 |
| 34737 | GeoAsciiParams | ASCII | any | 6.5; TIFF 6.0 p. 15 |

DOUBLE is the only valid type for the four DOUBLE tags: the pending
widening ruling concerns only BYTE, SHORT and LONG, so FLOAT, RATIONAL or an
integer type there is a type fault under either reading. A ModelTiepoint
count of 0 or a count that is not a multiple of 6 is a count fault.
GeoKeyDirectory's count of at least 4 is the Tier 1 floor; the exact count
equation belongs to Tier 3. GeoKeyDirectory uses the unsigned-short kind,
so it currently accepts BYTE and LONG holding 16-bit values, as every
SHORT array does under the p. 16 widening; it follows the widening ruling
when that is made.

Tier 2 (cross-tag presence) and Tier 3 (GeoKeyDirectory structure) wait for
the owner's decision on the reporting form. Model tags without a
GeoKeyDirectory are not a violation (Q1b).

### Corpus extension

validate asked for real GeoTIFFs with sha256, size, source URL and license.
The pinned manifest gains `url` and `license` columns (`-` where a row was
pinned before they existed) and 104 files from GDAL's autotest data at
commit fa1fc3c77e75787c614e12a2ba5ac366db833e1f: every TIFF of 1 MiB or less
in `autotest/gcore/data` and `autotest/gdrivers/data/gtiff` that carries a
GeoKeyDirectory, deduplicated by sha256 (114 files, 10 byte-identical
duplicates). Their license is the MIT terms in GDAL's LICENSE.TXT ("GDAL/OGR
General"); neither directory has a file-specific notice. Many of these files
are deliberately malformed GDAL regression inputs; they are pinned as they
are, and their verdicts are baseline, not findings of this batch.

The corpus is now 244 distinct sha256, and every row's `seen` count is
recomputed over it. The GeoTIFF rows occur in 105 (ModelPixelScale), 108
(ModelTiepoint), 1 (ModelTransformation), 110 (GeoKeyDirectory), 25
(GeoDoubleParams) and 99 (GeoAsciiParams) IFDs.

### Corpus report (244 distinct sha256, pinned manifest), 2026-11-04

Old (yolo c821d4e9) against new, over all 244 files: no verdict changes and
no finding changes. An independent byte scan of every GeoTIFF entry agrees:
every one is DOUBLE, SHORT or ASCII as required, and every count fits
(ModelTiepoint 6, 12 or 24).

The 104 new files: 80 ok, 24 invalid. Seven of the invalid ones carry a
finding 18 from existing rows:

| File | sha256 | Bytes | Tag | Cause |
|---|---|---|---|---|
| gcore/cfloat32.tif | bfbada089a6911efca50bcd10fc6913959094fb07cdaedc08f9084d8f86ae1a1 | 3536 | SampleFormat 6 | producer pattern |
| gcore/cfloat64.tif | ea1c6461e7f6539ff927091015d176e2b2dbbed433c3bdd51860f0f76fe8e8eb | 6736 | SampleFormat 6 | producer pattern |
| gcore/cint16.tif | b4b60961818d2386f19d43c15dcc7fc0a46c6eac83a3c02478e120213fb2916b | 1936 | SampleFormat 5 | producer pattern |
| gcore/cint32.tif | c8305231fe87e428642da908660e54f59cefc036dd075339e4374236f036f0da | 3536 | SampleFormat 5 | producer pattern |
| gcore/cint_sar.tif | 186842cbaadac156f42c14a26ac5d978a9ac44a227b3458455631bc2cda045ec | 1587 | SampleFormat 5 | producer pattern |
| gcore/6band_wrong_number_extrasamples.tif | 7e95bce3beac79757ed03aed1b09f9635f034e8982fc4a3e8c987a298008c46a | 2804 | ExtraSamples count | deliberate damage |
| gcore/leak-ZIPSetupDecode.tif | 14f71ac235855c4ba614bb8543f7d72e02abddc6772a476ef9f94466a8eec203 | 379 | Predictor 255 | deliberate damage (fuzz input) |

SampleFormat 5 and 6 are libtiff's complex signed integer and complex IEEE
floating point, which GDAL writes for complex rasters. No claimed
specification defines them, so they stay value faults; this is a
producer-pattern candidate for validate's registry, not admitted. The
files carry no Software tag; cint_sar.tif's GDAL metadata names
CEOS_SOFTWARE_ID ERS2-SLC-6.1.

Controlled reds: letting RATIONAL pass as DOUBLE failed the GeoTIFF unit
test and both IFD-entry fixture tests; dropping the multiple-of-6 test
failed the unit test only, until the ModelTiepoint corrupt case used 7
values instead of 4; it now fails the unit test and both fixture tests.
