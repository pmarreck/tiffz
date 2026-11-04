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

Cases 1-8 are sniper (one bit) and 9-12 bolter (one byte). By seed class:
1 unchecked (Zstd), 2 and 12 checksummed (LERC, Deflate), the rest
uncompressed.

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
