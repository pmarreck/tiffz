# GeoTIFF Tier 2 and Tier 3: geokey_invalid (21) and geokey_deviation (24)

validate numbered 21 on 2026-11-06 (class corrupt), and on 2026-11-07
approved the payload layout and rule numbers with a split by class. Rules
with no specified decode, or that suggest damage, report as 21
`geokey_invalid` (corrupt). Writer violations where every key still decodes
report as 24 `geokey_deviation` (WARN; verdict valid, a warning, never a
failure). Both use the same payload, and a rule keeps its number in both.
Source: OGC GeoTIFF 1.1, document 19-008r4. Code: `src/geokey_check.zig`.

## Scope

- Every walked IFD.
- Tier 1 (the six tags' types and counts) stays finding 18 in
  `ifd_conformance`. A GeoKeyDirectory that Tier 1 rejects for a non-integer
  type, or for fewer than four values, gets no Tier 3 walk.
- Model tags without a GeoKeyDirectory are not a violation (validate
  2026-11-04, Q1b). So rule 1 runs only where a GeoKeyDirectory is present,
  while rules 2 and 3, which concern the model tags themselves, run in any
  IFD (validate confirmed, 2026-11-07, question A).
- Key values come later in a separate key-value batch: GTModelTypeGeoKey
  presence, the CRS keys, Requirement 3.x codes and Requirement 6.2 (ASCII
  params present only when an ASCII key exists).

## Rules

| Rule | Code | Name | Requirement | Tag | Anchor and fields |
|---|---|---|---|---|---|
| 1 | 24 | georeference_absent | 1.2: one of ModelTiepoint or ModelTransformation SHALL be included | 34735 | GeoKeyDirectory entry |
| 2 | 24 | pixel_scale_with_transformation | 1.2: with ModelTransformation, ModelPixelScale SHALL NOT be included | 33550 | ModelPixelScale entry; related 34264 |
| 3 | 24 | pixel_scale_without_tiepoint | 1.2: with ModelPixelScale, ModelTiepoint SHALL also be included | 33550 | ModelPixelScale entry; related 33922 |
| 10 | 21 | key_directory_version | 2.5: KeyDirectoryVersion SHALL be 1 | 34735 | element 0; observed the value |
| 11 | 21 | key_revision | 2.7: KeyRevision SHALL be 1 | 34735 | element 1; observed |
| 12 | 21 | minor_revision | 2.9: MinorRevision SHALL be 0 or 1 | 34735 | element 2; observed |
| 13 | 21 | key_entries_truncated | 2.11: NumberOfKeys key entries after the header | 34735 | element 3; observed NumberOfKeys |
| 14 | 24 | key_unsorted | 1.6: KeyIDs in ascending order | 34735 | key; element its KeyID; observed the KeyID |
| 15 | 21 | key_duplicate | 1.6, a KeyID equal to the one before it | 34735 | as 14 |
| 16 | 21 | tag_location_invalid | 2.14: TIFFTagLocation is 0 or a GeoTIFF tag | 34735 | key; element its location; observed |
| 17 | 21 | location_tag_absent | 2.16: ValueOffset indexes the named tag, which is absent | 34735 | key; observed and related the location |
| 18 | 21 | value_out_of_bounds | 2.16: ValueOffset + Count past the named tag's values | 34735 | key; element its ValueOffset; observed ValueOffset + Count; related the location |
| 19 | 21 | short_params_inside_entries | 4.2: SHORT params SHALL appear after the last key entry | 34735 | key; element its ValueOffset; observed ValueOffset |
| 20 | 24 | ascii_terminator_missing | 6.3: the pipe terminates each ASCII string | 34737 | GeoAsciiParams entry; key; element the byte's index; observed the byte |
| 21 | 24 | ascii_nul_inside | 6.4: no NUL in the content (before the final byte) | 34737 | GeoAsciiParams entry; element the first NUL; no key |

The class of each rule (validate, 2026-11-07): 10-12 are editions with no
specified decode; 13 is a length mismatch; 15 leaves which value governs
unspecified; 16 is a location with no specified decode; 17 and 18 reference
an absent tag or run past the values; 19 overlaps the header or entries.
Rules 1-3, 14, 20 and 21 leave every key decodable. `Rule.class` is an
exhaustive switch, so a new rule cannot compile without a class.

Notes on the rules:

- **Rule 13.** A key count larger than 4 + 4N is not a fault: Requirement 4.2
  puts SHORT parameters after the last key entry, in the same array. Only
  missing entries are reported, and the walk covers the complete entries
  present.
- **Rule 18.** For 34735 the bound is the whole directory array. For 34736
  it is GeoDoubleParams' count. For 34737 it is GeoAsciiParams' count,
  final NUL included. A key out of bounds gets no rule 19 or 20 check.
- **Rule 20.** Count includes the pipe, as GeoTIFF's example shows: "NAD27 /
  UTM zone 11N|" is Count 21. The record is on 34737 because the byte lives
  there; the key fields name the GeoKeyDirectory key.
- **Not rules.** Count with TIFFTagLocation 0 is not checked: "Count=1 is
  implied" (7.1.2) is descriptive, not a SHALL. Requirement 2.14 says "a
  valid GeoTIFF tag identifier", read here as the three parameter tags. validate
  confirmed this on 2026-11-07 (question B): the model tags hold
  fixed-structure data, not key values.

## Payload

36 bytes, little-endian:

| Offset | Type | Field |
|---|---|---|
| 0 | u32 | IFD index |
| 4 | u32 | entry index (0xFFFFFFFF on the IFD; every current rule has an entry) |
| 8 | u64 | absolute anchor offset (the entry's) |
| 16 | u16 | tag |
| 18 | u16 | rule |
| 20 | u16 | key index, counted from 0 after the header (0xFFFF when none) |
| 22 | u16 | KeyID (0 when none) |
| 24 | u32 | element: index into the tag's values in their natural unit, a SHORT for 34735 and a byte for 34737 (0xFFFFFFFF when none) |
| 28 | u32 | observed value (0 when none) |
| 32 | u16 | related tag (0 when none) |
| 34 | u16 | reserved, 0 |

The byte offset of a finding is the anchor, exact. The element is an index,
not a byte offset, so the record survives a value array being moved. A
consumer gets the byte as the entry's value offset plus element times
element size.

## Controls

- Unit tests per rule in `src/geokey_check.zig`, each case firing and not
  firing. The no-record cases include MinorRevision 0, SHORT parameters
  after the entries, and model tags with no GeoKeyDirectory.
- End-to-end tests on tests/fixtures/geotiff/gray16_geotiff.tif:
  - the clean file;
  - rule 10, finding 21 corrupt and the file failing, with the anchor and
    payload checked;
  - rule 13 (NumberOfKeys one past the entries), finding 21 corrupt and the
    file failing;
  - rule 14 (two KeyIDs swapped), finding 24 and the file passing;
  - rule 20 (the citation key one byte short), finding 24 and the file
    passing;
  - rules 1 and 3 (ModelTiepoint renamed to a private tag), finding 24 and
    the file passing.
- A unit test pins each rule's class to validate's split.
- An independent oracle written from 19-008r4: a Perl reader of the raw
  bytes that walks the chain and SubIFDs, kept in scratch. It is compared
  with tiffz's records file by file.
