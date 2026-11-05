# Strict type reading (owner decision 1, implemented)

BDFN decided on 2026-11-04 that a ruled field takes only the TIFF types its
specification defines, with the corpus impact reported before landing.
validate approved the impact report and the readings below on 2026-11-05.

## Before

Several rule kinds widened the defined type:
- an unsigned scalar or array accepted BYTE, SHORT or LONG whatever the
  definition said;
- SampleFormat and TransferFunction accepted BYTE and LONG tables;
- PageMaker's "DWORD" (X/YClipPathUnits) accepted BYTE, SHORT, LONG or
  SLONG.

## Readings (validate, 2026-11-05)

1. **DWORD is LONG only.** It is an unsigned 32-bit quantity and SLONG is
   signed, so SLONG is a type fault. This supersedes the earlier ruling.
2. **IFD offsets stay as defined:** SubIFDs ("LONG or IFD", IFD8 in
   BigTIFF) and GlobalParametersIFD ("IFD or LONG").
3. **LONG8 is allowed in BigTIFF only,** for StripOffsets, StripByteCounts,
   TileOffsets and TileByteCounts.
4. **"SHORT or LONG" fields take exactly those two; LONG-only fields take
   LONG only.**

## Implementation

`ifd_conformance` kinds now name the defined types:

| Kind | Types |
|---|---|
| `unsigned_short` | SHORT |
| `unsigned_long` | SHORT or LONG |
| `long_only` | LONG |
| `byte_or_short` | BYTE or SHORT (DotRange) |
| `unsigned_byte` | BYTE |
| `offsets_or_counts` | SHORT or LONG; LONG8 in BigTIFF |
| `long_offsets` | LONG; LONG8 in BigTIFF (TileOffsets) |
| `integer32` | LONG (DWORD) |
| `long_or_rational` | SHORT, LONG or RATIONAL |
| `short_or_rational` | SHORT or RATIONAL |

Twenty-four rows moved to `long_only`:
- TIFF 6.0: NewSubfileType, FreeOffsets, FreeByteCounts, T4Options,
  T6Options, the JPEG interchange format, length and table offsets;
- TIFF-FX: ProfileType, CodingMethods, T82Options, StripRowCounts and
  ImageLayer (RFC 3949 governs: LONG, where RFC 2301 said SHORT or LONG);
- DNG 1.6.0.0: BayerGreenSplit, ProfileHueSatMapDims, ProfileEmbedPolicy,
  PreviewColorSpace, ProfileLookTableDims, ProfileHueSatMapEncoding,
  ProfileLookTableEncoding, DefaultBlackRender and MaskSubArea.

A wrong type is finding 18 reason 1 (type), with the stored type in the
payload. The payload is unchanged.

## Tests

The tests that encoded the widening now assert the fault, and each kind
keeps a positive case for its defined type or types, so a swap in either
direction fails:
- the end-to-end SampleFormat and TransferFunction test: SHORT validates
  clean, BYTE and LONG are type faults;
- "strict types: an unsigned field takes only its defined types", one case
  per kind;
- "TransferFunction is SHORT: BYTE and LONG tables are type faults".

Every row's clean regression is now written in its defined type.

## Corpus comparison

**Pre-landing scan.** An independent byte scan checked 4,564 ruled BYTE,
SHORT and LONG entries in every IFD of the 249 pinned files and the 10
KNOWN_DEFECT fixtures. It found one hit: the Samsung NX500 SRW (sha256
156e43118811bcecb6fcc600b5f41ee1773c4f00b6a5b2dd72e177e35f6596ab), whose
SubIFD 1 stores Compression as LONG.

**Real-build comparison.** The 457e8988 build was run against this commit
over 263 files: the 249 pinned files, the 10 KNOWN_DEFECT fixtures and the
four patched DNG controls. One file changes, as predicted:
- **Samsung NX500 SRW:** it gains one finding 18 reason 1 at IFD 3, which
  is SubIFD 1 in walk order: Compression (259), stored type LONG.
- **Status:** unchanged, still invalid (error 2) for its existing causes.
- **Everything else:** no status, error or finding 17-19 payload changes
  in the other 262 files.

There is no KNOWN_DEFECT exemplar among the hits and no registry
candidate.

**Controlled red.** Re-widening `unsigned_short` to accept LONG failed five
tests, among them the three flipped widening tests and the one-case-per-kind
test. Restoring the strict check made them pass again.
