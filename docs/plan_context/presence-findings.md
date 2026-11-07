# Presence findings and the required-field scope (proposed, not implemented)

This is the design for the owner's decisions 2 and 3 of 2026-11-04, relayed by
validate, which decides TIFF rule questions under the owner's delegation. It
is for validate's review before any implementation, as asked. Nothing here is
implemented. The finding number and payload need Einstein's allocation,
requested 2026-11-04.

## Decision 2: one presence finding

Working name `tag_presence_invalid`, Namespace B, verdict corrupt. It has
three reasons:

| Reason | Meaning | Anchor |
|---|---|---|
| 1 `required_absent` | a field the claimed spec requires is not in the IFD | the IFD (no entry exists) |
| 2 `excluded_present` | a field that must not be present is present | that entry |
| 3 `dependency_absent` | an entry requires a field that is absent | the entry that requires it |

It is meant to cover:
- the TIFF 6.0 baseline required fields (decision 3);
- GeoTIFF Requirement 1.2;
- DNG "required tag";
- DNG "may only be used if" (ReductionMatrix with ColorPlanes of 3 or fewer);
- CFAPlaneColor for non-RGB CFA.

This design implements only the baseline required fields. The others become
later batches, each with its own corpus report.

### Proposed payload (needs Einstein)

All fields are little-endian:

| Field | Size | Contents |
|---|---|---|
| IFD index | u32 | |
| entry index | u32 | `0xFFFFFFFF` when anchored on the IFD |
| anchor offset | u64 | absolute: the IFD's offset, or the entry's |
| tag | u16 | the tag concerned (the absent one for reasons 1 and 3) |
| reason | u16 | |
| requirement | u16 | the requirement reference: 1 is the TIFF 6.0 baseline required fields (p. 17 ff.); later batches add GeoTIFF 1.2, DNG required, DNG only-if and so on |
| reserved | u16 | zero |

That is 24 bytes. There is one record per absent field per IFD, so each record
names exactly one tag and a reader never has to decode a mask. Records count
toward the existing finding-retention limits.

The verdict is invalid (Malformed) after the walk, as for findings 17 to 19.
Presence is a structural, directory-only check, so it runs in the walk and in
the post-stop pass (reach ruling A).

## Decision 3: required fields without a default

Every IFD that carries image data must have:
- ImageWidth (256);
- ImageLength (257);
- PhotometricInterpretation (262);
- StripOffsets (273) and StripByteCounts (279), or TileOffsets (324) and
  TileByteCounts (325);
- XResolution (282) and YResolution (283).

Fields with a default are satisfied by it: Compression, BitsPerSample,
RowsPerStrip, ResolutionUnit, SamplesPerPixel and the rest.

**DNG.** DNG 1.6.0.0 names no exception to these fields. Its Chapter 3
"Restrictions and Extensions to Existing TIFF Tags" constrains values, never
presence, and no tag text waives a baseline field. So DNG files get the same
checks, and no DNG exception is relied on.

## Measured impact (pre-landing)

An independent byte scan (its own TIFF walker, never tiffz) covered the same
263 files as the other batches: the 249 pinned files, the 10 KNOWN_DEFECT
fixtures and the 4 patched DNG controls. It walked 374 IFDs, the next chain
plus SubIFDs. The full per-file list is in `presence-impact.tsv`: sha256,
source, name, IFD, compression, photometric, the data fields present and the
missing fields. IFD numbers are the scan's own walk order (chain, with SubIFDs
after their parent), which can differ from tiffz's.

**Totals:**
- 238 of 374 IFDs, in 176 of 263 files, lack at least one field.
- 116 of the 181 files that validate ok today would turn invalid.
- The question of which IFDs carry image data (Q1 below) changes neither
  total, because XResolution and YResolution dominate.

**By field (IFDs):**

| Field | IFDs |
|---|---|
| XResolution, YResolution | 198 |
| PhotometricInterpretation | 48 |
| ImageWidth, ImageLength | 40 |
| no strip or tile arrays | 45 |
| TileOffsets, TileByteCounts (tiles stored in strip tags) | 2 |

**Resolution alone versus everything else:**
- **XResolution/YResolution only:** 149 files, 110 of them ok today.
- **Something else missing:** 27 files, 6 of them ok today:
  - Nikon P1000 and P7100 NRW;
  - Pentax K10D PEF;
  - libtiff quad-tile and cramps-tile;
  - the Canon CR2 IFD0 control fixture.

**By source (files with any record, of files in the source):**

| Source | Files | With a record | Resolution only | Anything else |
|---|---|---|---|---|
| GDAL autotest | 104 | 101 | 101 | 0 |
| libtiff pics 3.8.0 | 61 | 9 | 7 | 2 |
| raw.pixls.us | 42 | 27 | 10 | 17 |
| tiffz fixtures (manifest) | 28 | 23 | 23 | 0 |
| validate ground truth | 8 | 5 | 2 | 3 |
| KNOWN_DEFECT fixtures and controls | 14 | 11 | 6 | 5 |

### Patterns behind the non-resolution records

1. **Old-style JPEG IFDs** (Compression 6, data located by
   JPEGInterchangeFormat/Length): 41 IFDs. These are the Sony ARW previews in every ARW (IFD 0 and IFD 2, or IFD 1
   in the DSLR-A100), the Nikon NRW, the Pentax PEF and the NX500
   SubIFDs. Most lack ImageWidth, ImageLength and PhotometricInterpretation as
   well as strips. This is the Sony IFD0 the owner anticipated.
2. **The Canon CR2 IFD0** has no PhotometricInterpretation. This is the
   other anticipated pattern. It hits the corpus CR2 and all five Canon
   KNOWN_DEFECT fixtures.
3. **IFDs with no data fields at all:** 4 IFDs, the Samsung NX500 IFD 0 and
   IFD 3 and the SubIFD of each Kodak KDC. They are only containers for
   SubIFDs or metadata.
4. **Tiles stored in StripOffsets/StripByteCounts**, with TileWidth and
   TileLength present: libtiff's quad-tile and cramps-tile. tiffz already
   tolerates this layout with its `tiled_geometry_via_strip_tags`
   warning.
5. **Sony ARW IFD 3**, a Compression 7 YCbCr preview located by
   JPEGInterchangeFormat, has no strips and no X/YResolution.

### KNOWN_DEFECT impact

Every Canon CR2 fixture gains PhotometricInterpretation, XResolution and
YResolution records. Every Kodak MinSampleValue fixture gains XResolution and
YResolution records.

The Kodak fixtures are tiffz's own synthetic files, and they lack resolution
only because they were built minimal. The real Kodak exemplars' IFDs need
checking separately. I propose adding XResolution and YResolution to those
fixtures, so that they stay focused on the MinSampleValue pattern, unless you
want them to carry the records.

The Canon fixtures follow the real CR2 IFD0, so their signatures need your
rewrite, as the owner said. The Sony ARW pattern's records come from IFD 0
and IFD 2 (pattern 1) and IFD 3 (pattern 5).

## Questions for validate

1. **Which IFDs carry image data?**
   - Option A: every walked IFD, since TIFF 6.0 makes each IFD an image and
     SubIFDs are images too.
   - Option B: only IFDs with a data field (strips, tiles or
     JPEGInterchangeFormat).
   - The difference is the four container IFDs of pattern 3. Under A they
     get ImageWidth, ImageLength, PhotometricInterpretation and strip
     records; under B nothing.
   - I propose B: an IFD with no image data does not "carry image data", in
     the owner's words.
2. **Old-style JPEG (Compression 6).** Does JPEGInterchangeFormat satisfy
   the strip/tile requirement?
   - TIFF 6.0 Section 22 defines it, and TIFF Technical Note 2 obsoletes
     Compression 6.
   - Strictly, the baseline fields are still required, which gives the
     records above.
   - Alternatively, Compression 6 IFDs could be left to a later old-JPEG
     rule.
3. **Tiles in strip tags** (pattern 4): `required_absent` records for
   TileOffsets and TileByteCounts, or leave the layout to the existing
   tolerance warning?
4. **TileWidth and TileLength** have no default either. The owner's list
   does not name them. Should a tiled IFD require them? No corpus IFD lacks
   them.
5. **XResolution and YResolution everywhere**, including SubIFDs and reduced
   images? This is the bulk of the impact: 101 of the 104 GDAL files, 23
   tiffz fixtures and 110 files that are ok today. I read the owner's list
   as yes. Please confirm, since this is the largest verdict change any
   batch has made.
6. **Payload:** is the shape above acceptable to send to Einstein: 24 bytes,
   one record per absent field, a requirement reference field and the
   entry index `0xFFFFFFFF` for IFD anchors?
