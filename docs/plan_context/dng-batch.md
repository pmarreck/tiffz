# DNG IFD-rule batch: row design (proposed, not implemented)

validate approved doing the DNG batch before TIFF/EP (2026-11-04), on five
conditions: name the edition and its sha256; gate on DNGVersion; cite the
DNG text alone; separate "should" from "must/shall"; and check overlap with
finding 19's DNG preview candidate. This note is the design sent for
review. Nothing here is implemented.

## Edition

Cited text: Digital Negative Specification 1.6.0.0 (December 2021), sha256
7f6e7867569c1daeae7f6835cd0a6a769e47e36b109594a8b3cc321d2327e569, the same
copy validate holds. 1.7.1.0 could not be fetched (Adobe's CDN refuses
scripted downloads), so no row notes a 1.6 to 1.7 difference. The
1.6.0.0 text groups tags by the edition that added them ("Additional Tags
for Version 1.x.0.0"); tags before the first such heading are 1.0 or 1.1,
and the text does not separate those two.

## Gating

- A row applies only when IFD0 carries DNGVersion, and then to every IFD
  in the walk (next chain and SubIFDs).
- Value lists use the union over 1.0 to 1.6, so a file is never faulted for
  a value a later edition permits (CFALayout 6 to 9, added in 1.3.0.0, are
  valid in a 1.2 file). A constraint that a later edition introduces
  applies only from that edition on.
- Proposed: a file declaring DNGVersion above 1.6.0.0 gets the type and
  count rows but no value-list rows, since a later edition may extend any
  list (question D1).
- Proposed: a DNGVersion entry that is itself malformed (not BYTE[4]) still
  marks the file as DNG, and only rows with no edition gate apply
  (question D2).

## Tier 1: one entry at a time (finding 18 reasons 1 to 3)

Type and count come from each tag's definition block. These blocks have no
modal verb, like TIFF 6.0's field definitions, which earlier batches
treated as normative (question D3).

Fixed counts:

| Count | Tags |
|---|---|
| 1 | CFALayout, BestQualityScale, CalibrationIlluminant1-3, BaselineExposure, BaselineNoise, BaselineSharpness, BayerGreenSplit, LinearResponseLimit, ChromaBlurRadius, AntiAliasStrength, ShadowScale, MakerNoteSafety, ColorimetricReference, NoiseReductionApplied, ProfileEmbedPolicy, PreviewColorSpace, RowInterleaveFactor, DefaultBlackRender, BaselineExposureOffset, ProfileLookTableEncoding, ProfileHueSatMapEncoding, RawToPreviewGain, DepthFormat, DepthNear, DepthFar, DepthUnits, DepthMeasureType |
| 2 | BlackLevelRepeatDim, DefaultScale, DefaultCropOrigin, DefaultCropSize, AsShotWhiteXY, SubTileBlockSize, OriginalDefaultFinalSize, OriginalBestQualityFinalSize, OriginalDefaultCropSize |
| 3 | ProfileHueSatMapDims, ProfileLookTableDims |
| 4 | DNGVersion, DNGBackwardVersion, LensInfo, ActiveArea, DefaultUserCrop, MaskSubArea |
| 16 | RawDataUniqueID, PreviewSettingsDigest, RawImageDigest, OriginalRawFileDigest, NewRawImageDigest |

Count shapes: MaskedAreas is a positive multiple of 4; NoiseProfile is
even and at least 2 (its exact count needs ColorPlanes, Tier 3);
ProfileToneCurve is even and at least 4, since its first and last samples
are required.

Types, as listed in the blocks. "SHORT or LONG" tags use tiffz's shared
unsigned kinds, so they follow the pending p. 16 widening ruling like every
other SHORT field. Opaque blocks (DNGPrivateData, OriginalRawFileData,
AsShot/CurrentICCProfile, OpcodeList1-3, ProfileGainTableMap, RGBTables,
IlluminantData1-3) get a type row only; their internal structure is a
later batch.

Strings:

- ASCII only (UniqueCameraModel, CameraSerialNumber, PreviewDateTime,
  EnhanceParams, SemanticName, SemanticInstanceID): the existing TIFF 6.0
  ASCII rules.
- "ASCII or BYTE", "Null-terminated UTF-8" (LocalizedCameraModel,
  OriginalRawFileName, and the profile and preview name and signature
  strings): NUL-terminated, and valid UTF-8 instead of 7-bit, for either
  type (question D4).
- EnhanceParams "is required to be non-null": at least one byte before
  the NUL.

Value rows:

| Tag | Valid | Wording |
|---|---|---|
| MakerNoteSafety | 0, 1 | Value field "0 (unsafe) or 1 (safe)" |
| ColorimetricReference | 0, 1 | Value field "0 or 1" |
| CFALayout | 1-9 | "currently defined values" |
| PreviewColorSpace | 0-4 | "valid values include" |
| ProfileEmbedPolicy | 0-3 | "valid values" |
| DefaultBlackRender | 0, 1 | "currently defined values" |
| ProfileLookTableEncoding, ProfileHueSatMapEncoding | 0, 1 | "currently defined values" |
| DepthFormat | 0-2 | "valid values" |
| DepthUnits | 0, 1 | "valid values" |
| DepthMeasureType | 0-2 | "valid values" |
| ProfileHueSatMapDims, ProfileLookTableDims | Hue >= 1, Sat >= 2, Value >= 1 | "allowed values include" |
| DefaultUserCrop | 0 <= Top < Bottom <= 1, 0 <= Left < Right <= 1 | "must satisfy" |
| NoiseProfile | each S > 0, each O >= 0 | "must" |
| ProfileToneCurve | first (0, 0), last (1, 1) | "is required to be" |

"Currently defined" and "valid values include" read as open lists (question
D5). CalibrationIlluminant's legal values are EXIF LightSource's; EXIF is
not a claimed specification, so there is no value row, only type and count.

## Tier 2: fields in the same IFD (finding 18 reason 2, anchored on the dependent entry)

These follow the existing precedent of SampleFormat counted per sample:

- BlackLevel count = BlackLevelRepeatRows * BlackLevelRepeatCols *
  SamplesPerPixel (repeat dimensions default to 1, 1).
- WhiteLevel count = SamplesPerPixel.
- BlackLevelDeltaH count = ActiveArea width, and BlackLevelDeltaV count =
  ActiveArea length (the whole image when ActiveArea is absent).
- ProfileHueSatMapData1-3 count = H * S * V * 3 from ProfileHueSatMapDims;
  ProfileLookTableData count likewise from ProfileLookTableDims.

Chapter 3 restrictions on existing TIFF tags:

| Rule | Wording | Proposed |
|---|---|---|
| BitsPerSample equal for every sample when SamplesPerPixel > 1 | "must" | value fault on BitsPerSample |
| FillOrder 1 when BitsPerSample is not 8, 16 or 32 | "must" | value fault on FillOrder |
| SampleFormat 1, or 3 from 1.4.0.0 | "always use", "allows" | value fault on SampleFormat (D6) |
| Floating point BitsPerSample 16, 24 or 32 | "allowed values" | value fault on BitsPerSample (D6) |
| Compression 1 or 7, plus 8 and 34892 from 1.4.0.0 | "supported", "adds support" | value fault on Compression (D6) |
| Deflate only for float, 32-bit integer, transparency or depth data | "is allowed for" | D6 |
| Lossy JPEG 34892 only for 8-bit LinearRaw or PhotometricMask | "is allowed for" | D6 |
| Predictor 1, 2, 3, 34892-34895 with Compression 8 | "allowed" | value fault on Predictor (D6) |
| PhotometricInterpretation 1, 2, 6 (previews), 32803, 34892 (raw), 51177, 52527 | "supported", "required" | D6 |

## Tier 3: across IFDs (ColorPlanes), proposed for a later batch

ColorPlanes is the raw IFD's color count: CFAPlaneColor's count for CFA
(default 3), SamplesPerPixel for LinearRaw. The raw IFD is the one with
NewSubFileType 0. It sizes ColorMatrix1-3 (ColorPlanes * 3), CameraCalibration1-3
(ColorPlanes squared), ReductionMatrix1-3 (3 * ColorPlanes, and only when
ColorPlanes > 3), AnalogBalance and AsShotNeutral (ColorPlanes),
ForwardMatrix1-3 (3 * ColorPlanes), the PreProfileMatrix tags (either
shape) and NoiseProfile (2 or 2 * ColorPlanes). These sit in IFD 0, or a
camera profile IFD, while ColorPlanes comes from a SubIFD; the
anchoring needs its own design.

## Waiting on the presence reporting form

"Required tag" and "must also include" rules wait for the owner's decision
on how to report a missing tag:

- DNGVersion, UniqueCameraModel and Orientation are required.
- ColorMatrix1 is required for non-monochrome files.
- CFAPlaneColor is required for non-RGB CFA images.
- CFA needs CFARepeatPatternDim and CFAPattern in the same IFD.
- CalibrationIlluminant 255 needs IlluminantData (1.6.0.0 on).
- A semantic mask IFD needs SemanticName.
- Every profile needs a ProfileName when there are several.

## "Should" rows (no fault; for validate's ruling)

- NewSubFileType: 0 for the main raw image, 1 for previews, 10001.H from 1.2,
  4 and 5 from 1.4, 8, 9 and 16 from 1.5, 10004.H from 1.6 (Chapter 3).
- DNGVersion "should contain" 1, 6, 0, 0 for 1.6 files.
- UniqueCameraModel "should include the manufacturer's name".
- Orientation: mirrored values "should not" be used for TIFF-EP
  compatibility.
- LensInfo unknown f-stops "should be encoded as 0/0".
- DefaultScale for CFALayout 2 to 5 "should usually differ by a factor of 2".
- MaskedAreas "should not be used" after black subtraction.
- ExtraCameraProfiles "should only be used" for more than one profile.
- PreviewDateTime is ISO 8601 ("is encoded using"; no modal verb), listed
  here because the format is open-ended.

## Placement ("Usage")

Each block names where a tag belongs (IFD 0, Raw IFD, Preview IFD, and so
on). A misplaced tag is not proposed as a fault in this batch (question
D7).

## Overlap with finding 19 and the DNG preview candidate

No proposed row reads YCbCrSubSampling or a JPEG frame header, so nothing
double-reports finding 19 rule 4 on the Leica M11 and Ricoh GR previews.
Chapter 3's JPEG-variant rule (baseline DCT for 8-bit YCbCr or BlackIsZero,
otherwise lossless Huffman) does read the SOF. It fits finding 19's form
better than finding 18's, so it is held out of this batch: adding it means
a new finding 19 rule, which needs sign-off. Those previews are baseline
and would not trigger it.

## Corpus check (244 distinct sha256, 12 DNGs, DNGVersion 1.0 to 1.4)

An independent byte scan applied two parts of this design, with edition
gates, to every IFD of the 12 DNGs:

- the Tier 1 types and fixed counts, read strictly (no widening);
- the Chapter 3 value rows for Compression, PhotometricInterpretation,
  SampleFormat, Predictor and NewSubFileType.

Neither found anything. The Tier 1 value rows, the string rules and Tier 2
are not scanned yet; that happens with the implementation. The DNGs carry
63 of the 109 DNG tags.

## Rulings (validate, 2026-11-04): Tiers 1 and 2 approved

- D1: above 1.6.0.0, apply type and count rows and the edition-gated
  constraints from 1.6 or earlier; skip closed value lists, with no record
  for a skipped list.
- D2: a malformed DNGVersion still makes the file DNG. The entry gets its
  own finding 18, and the version counts as unknown: type and count rows
  only, with no value lists and no edition-gated constraints.
- D3: the definition blocks are normative. Basis, DNGBackwardVersion (p.
  21): "readers should, for all tags, check the types, counts, and values,
  to verify it is able to correctly read the file."
- D4: for "ASCII or BYTE" UTF-8 strings, the last byte is NUL, the count
  includes it, and the bytes before it are valid UTF-8; the 7-bit rule does
  not apply. Inner NULs are not a fault in this batch (a should-row
  candidate).
- D5: "currently defined values" is a closed list over the 1.0 to 1.6 union
  (skipped above 1.6 per D1). "Valid values include" (PreviewColorSpace) is
  open, so no fault. "Valid values" (ProfileEmbedPolicy, the Depth enums)
  and the Value-field lists read as closed.
- D6: the Chapter 3 lists are restrictions and therefore faults, with
  edition gates as written. Lists that depend on an IFD's role take the
  role from NewSubFileType. Where the role cannot be determined, the union
  of that tag's role lists applies. Before landing, add a few 1.5 and 1.6
  DNGs (depth maps, semantic masks, an enhanced IFD) under the usual hash,
  size and license discipline.
- D7: a tag outside its Usage IFD is not a fault in this batch. It goes to
  the should-row list for a later ruling.
- Tier 3 is a later batch. Presence rules wait for the owner's
  reporting-form decision. The JPEG-variant "must" goes to the owner as a
  proposed finding 19 rule 6.

## Implementation (Tiers 1 and 2)

- Rows: 109 DNG rows in `ifd_conformance.rules`, one per Chapter 4 tag,
  each with the edition that added it (`since`). Of those, 51 have fixed
  counts and 10 have closed value lists; ten are Tier 2 derived counts
  (BlackLevel, WhiteLevel, BlackLevelDeltaH/V, ProfileHueSatMapData1-3 and
  ProfileLookTableData) and four carry value extras (DefaultUserCrop,
  NoiseProfile, ProfileToneCurve, EnhanceParams).
- Chapter 3: checked after an entry passes its TIFF row, for
  BitsPerSample, FillOrder, SampleFormat, Compression, Predictor and
  PhotometricInterpretation.
- Gate: the decoder reads DNGVersion from IFD 0 once (`Dng.fromIfd0`) and
  passes it to every IFD's check.
- Kinds:
  - BYTE fields that hold numbers (DNGVersion, DNGBackwardVersion,
    CFAPlaneColor) use the shared unsigned-byte kind, so they follow the
    p. 16 widening.
  - Opaque BYTE blocks (digests, RawDataUniqueID, DNGPrivateData) are
    BYTE only.
  - ExtraCameraProfiles uses the IFD-offset kind.
- Choices within the rulings, listed for validate:
  - NewSubFileType 1 marks previews and reduced-resolution raw images
    alike, so it takes both PhotometricInterpretation lists.
  - Enhanced IFDs (16) take LinearRaw alone, from Chapter 3's "can be used
    in ... enhanced IFDs".
  - Transparency masks (4, 5) get no list in the text, so they take the
    union, as an unknown role does.
  - ProfileHueSatMapDims' "allowed values include" is read like D5's
    "valid values include": open, so no fault.
  - BitsPerSample "from 8 to 32" is a closed list. The "same for each
    sample" must applies even with an unknown version.

## Corpus report (249 distinct sha256), 2026-11-04

Added under validate's D6 condition (raw.pixls.us, CC0 per its license
field):

| File | Size | DNGVersion | Note |
|---|---|---|---|
| Google Pixel 8 Pro | 45101750 | 1.6.0.0 | third calibration (CalibrationIlluminant3, ColorMatrix3, CameraCalibration3, ForwardMatrix3, IlluminantData3); ProfileGainTableMap |
| Samsung Galaxy S21 Ultra | 37770480 | 1.6.0.0 | ProfileGainTableMap |
| Samsung Galaxy S22 Ultra | 26798986 | 1.6.0.0 | |
| Samsung Galaxy S23 (16:9) | 25412616 | 1.6.0.0 | |
| Apple iPhone 12 Pro (ProRAW) | 29195592 | 1.4.0.0 | semantic mask IFD (NewSubFileType 10004.H, PhotometricMask 52527, lossy JPEG); also ProfileGainTableMap and SemanticName, both 1.6.0.0 tags, so under the edition gate their rows do not apply to this 1.4.0.0 file |

Sha256s are in the manifest. The 16 CC0 DNGs surveyed (raw.pixls.us,
makers Apple, DJI, Google, Hasselblad, Leica and Samsung) contain no depth
map (NewSubFileType 8 or 9) and no enhanced IFD (16). Those roles are
covered by unit tests only.

Old (yolo be9de912) against new, over all 249 files: no verdict changes
and no finding changes. An independent byte scan of every DNG tag entry in
the 17 corpus DNGs agrees on the Tier 1 types and fixed counts and on the
Chapter 3 lists.

Reach: tiffz stops at the first IFD it cannot decode.
- The four Samsung files stop at IFD 0 (lossless JPEG LinearRaw:
  UnsupportedCompression), so only their IFD 0 is checked.
- The iPhone stops at its raw SubIFD, so its semantic-mask IFD is not
  reached.
- A copy whose mask PhotometricInterpretation was patched to 1 confirms
  this: nothing is reported.

Positive controls on a real file (Sigma fp, DNG 1.4.0.0, valid): CFALayout
patched to 10, and MakerNoteSafety patched to 2. Each gives one finding 18
reason 3 on the patched tag in the new build; the old build passes both.

## Rulings on f8ca6ee1 (validate, 2026-11-04)

Choices 1, 3, 4 and 5 confirmed. Choice 2 overruled: enhanced IFDs take
the raw list (32803, 34892), because "The LinearRaw value can be used in
reduced resolution IFDs and enhanced IFDs" (p. 20) is permissive.
LinearRaw-only is should-row 10.

Three should-rows become faults (finding 18 reason 3), as definitional
statements in the D3 sense:

- MaskSubArea (from 1.6.0.0). The text says "the tag is invalid" when
  "T_crop + ImageWidth > H_full" or "L_crop + ImageLength > W_full".
  - Apparent erratum: those conditions pair the top offset with the width
    and the left offset with the length. The dimensionally consistent form
    is T_crop + ImageLength > H_full or L_crop + ImageWidth > W_full.
  - A fault is reported only when the entry is out of bounds under both
    readings. Without ImageWidth and ImageLength there is no check.
- PreviewDateTime (from 1.2.0.0) "is encoded using ISO 8601 format". The
  grammar is a complete date-time:
  - extended YYYY-MM-DDThh:mm:ss or basic YYYYMMDDThhmmss, one form
    throughout;
  - an optional fraction after "." or ",";
  - then no designator (local time), Z, or an offset ±hh:mm (basic
    ±hhmm);
  - calendar-checked fields, with 24:00:00 allowed only with a zero
    fraction and second 60 allowed for a leap second.
  - Reduced precision (no seconds) and a date alone are rejected.
  - Loosened by validate the same day ("encoded using ISO 8601 format",
    not "complete representation"): reduced precision down to the minute
    (hh:mm, basic hhmm) and an hour-only offset (±hh) are accepted, as is a
    fraction of the last component. Anything coarser than a minute, and a
    date alone, is still rejected.
  - Corpus check before landing: the only value in the 249 files,
    "2017-01-31T19:30:23Z" (Adobe DNG Converter, three IFDs), passes.
- Pixel types:
  - depth maps (NewSubFileType 8 or 9, from 1.5.0.0): single channel, 8
    or 16-bit unsigned integer;
  - semantic masks (10004.H, from 1.6.0.0): single channel, 8 or 16-bit
    unsigned integer or 32-bit floating point;
  - anchoring: closed lists, so D1 and D2 apply. A bad depth is reported on
    BitsPerSample, a format that does not match an allowed depth on
    SampleFormat, more than one sample on SamplesPerPixel, and an absent
    BitsPerSample (1 bit) on NewSubFileType.

D2 tightened with these: a DNG row in a file whose version is unknown gets
type and count only, with no value rule of any kind, not only no closed
list.

## Should-row queue

None of these is a fault. Whether a "should" deviation becomes an
informational record waits on the owner's INFO-severity decision (validate's
finding-retention design). Numbers follow the list sent to validate.

1. NewSubFileType values per role and edition (Chapter 3 "should use").
2. DNGVersion "should contain" 1, 6, 0, 0 for 1.6 files.
3. UniqueCameraModel "should include the manufacturer's name", "should not
   be localized".
4. Orientation: writers "should not use" mirrored values (TIFF-EP
   compatibility).
5. LensInfo: unknown f-stops "should be encoded as 0/0".
6. DefaultScale for CFALayout 2 to 5 "should usually differ by a factor of
   2.0".
7. MaskedAreas "should not be used" after black subtraction.
8. ExtraCameraProfiles "should only be used" with more than one profile.
10. Enhanced IFD: "should always use" LinearRaw; 16-bit unsigned or 16, 24
    or 32-bit float; a non-null EnhanceParams.
11. Depth and semantic-mask IFDs "should use" 51177 and 52527 (Chapter 3's
    "required" form is already a fault).
13. Inner NULs in the UTF-8 strings (D4).
14. A tag outside its Usage IFD (D7).
16. A file that uses constructs newer than its DNGVersion or
    DNGBackwardVersion.
    - Producer note: Apple iPhone 12 Pro ProRAW, sha256
      e91e77a4533ed7cce551d83330676ea5c47dd5e55fb38adda7819366afdbdfc2.
    - The file declares 1.4.0.0 but carries a semantic-mask IFD
      (NewSubFileType 10004.H, PhotometricInterpretation 52527),
      SemanticName and ProfileGainTableMap, all introduced in 1.6.0.0.

Rows 9, 12 and 15 became faults (above). The held-back musts are a later
batch with layout reading; ReductionMatrix goes in Tier 3.

## Should-rows as InfoFinding 22 (validate, 2026-11-07)

validate approved `should_deviation` (22): verdict valid, mapped to INFO by
validate, never changing the result. The payload is 20 bytes, little-endian:
- u32 IFD index;
- u32 entry index (0xFFFFFFFF when anchored on the IFD);
- u64 anchor offset;
- u16 tag (0 for the IFD as a whole);
- u16 rule.

The rule numbers follow the queue above: 1, 2, 4, 5, 6, 7, 8, 10, 11, 13,
14, 16, plus 17 for TN3's "Predictor 3 should be used only with SampleFormat
3". 3 is dropped and stays unused: whether the name is a manufacturer's
can't be checked mechanically, and non-ASCII bytes are already an
ASCII-content finding. 9, 12 and 15 stay unused because those rows became
faults. Rule 16 reports once per IFD, at the first newer construct; the
docs must say "first". They land as one batch with a corpus report per
rule and per producer, and a controlled red per rule family.

### Refinements (validate, 2026-11-07, later the same day)

- Rules 7, 8 and 11 stay unused. 7 isn't mechanical, since no field records
  black subtraction. 8 and 11 are always already finding 18: ExtraCameraProfiles
  needs at least one entry, and the depth and mask roles allow only 51177
  and 52527.
- Rules 1, 2, 4, 5, 6, 10, 13, 14 and 17 fire on the exact conditions sent
  that day. Rule 14 takes its table from each tag block's Usage line
  (src/dng_usage.zig, generated by tools/gen-dng-usage.pl) and fires only in
  clear cases.
- Rule 16 is split. 16 is the first construct newer than DNGBackwardVersion
  (default: DNGVersion with its last two bytes zero) but not newer than
  DNGVersion. 18 is the first construct newer than DNGVersion itself. Each
  fires once per IFD.
