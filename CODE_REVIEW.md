---
purpose: Release-critical parser-correctness audit surface for tiffz 1.0. Findings, evidence pointers, remediation shape — NOT fixes.
audience: agent
maintained_by: agent
---

# tiffz 1.0 audit — parser correctness

**Audit slice:** first pass per Einstein 2026-07-23 dispatch
(`inbox/2026-07-23-from-Einstein-validate-image-parser-1.0-audit.md`,
already trashed; content mirrored into `PLAN.md` "Next up").
**Scope:** verified reproducers + attribution; no fix work per Einstein's
"stop at the audit/report milestone."
**Baseline commit:** `bcbe83b4616a67fa099c98463dafaad907491589` (yolo tip).
**Dirty-state ownership:** working tree is clean modulo the two
never-commit CLAUDE/AGENTS symlink retargets that are the project's
persistent state.
**Author:** tiffz session, 2026-07-24 EDT.

---

## 1. Measured state (from Einstein Note 1 — reproduced locally today)

Validate's product measurement at tiffz `bcbe83b4`:

| Corpus              | Accepted | Rejected | Total | Notes                                        |
| ------------------- | -------: | -------: | ----: | -------------------------------------------- |
| Labeled-good TIFF   |       10 |        5 |    15 | **5 false rejects** — the primary regression |
| Labeled-corrupt TIFF|        5 |        0 |     5 | 0/5 rejected — shim gap, see §6              |

Mutation coverage on `pc260001.tif` (largest fixture only): sniper **0/100**,
bolter **0/100**, shotgun **0/100**. Prior compressed `bali.tif` was
7/100, 45/100, 100/100. Per-compression stratification has never been
produced; §5 tracks that gap.

## 2. Reproducers (product path, negative characterization)

Fixtures under `tests/fixtures/labeled_good/` are byte-verbatim copies
of `~/Code/validate_gui/ground_truth_examples/tiff/`. Two of the five —
`cramps-tile.tif` and `quad-tile.tif` — DIFFER byte-for-byte from the
same-named files already under `tests/fixtures/tiled/`, so the
pre-existing positive oracle tests did NOT exercise the exact bytes
validate measures. That drift is itself audit-worthy (§8).

Five negative-characterization tests in `tests/fixture_test.zig` under
the `audit 1.0 [reg]:` prefix assert the WRONG-BUT-CURRENT verdict
through `Decoder.validateAllStripsAndTiles` (the exact product entry
Einstein mandated). They keep `./test` green today and will fire
loudly the moment the underlying gate is corrected.

Confirmed error attribution (2026-07-24, sandboxed test build):

| Fixture                     | Shape                                            | Product error          | Failing check                             |
| --------------------------- | ------------------------------------------------ | ---------------------- | ----------------------------------------- |
| `cramps-tile.tif`           | 800×607 tiled 256×256, uncompressed, 1ch 8bpp    | `Malformed`            | exact-extent gate (post-codec)            |
| `deflate-last-strip.tiff`   | 500×500 Deflate, RowsPerStrip=16                 | `Malformed`            | exact-extent gate (post-codec)            |
| `lzw-single-strip.tiff`     | 7795×3122 bilevel LZW, single strip              | `SourceTooShort`       | required-EOD gate (codec)                 |
| `quad-tile.tif`             | 512×384 tiled 128×128, LZW RGB 3ch chunky        | `Malformed`            | exact-extent gate (post-codec)            |
| `ycbcr-cat.tif`             | 250×325 LZW YCbCr subsampling 2:2                | `Malformed`            | exact-extent gate (post-codec)            |

An in-test probe (`probeFirstFailure`, later refactored out of the
negative-characterization form but archived in the transcript) walked
per-chunk `decodeStrip`/`decodeTile` for each fixture and observed
that four of the five fixtures decode ALL chunks successfully at the
codec layer — the rejection fires only when
`validateAllStripsAndTiles` compares `written` to
`expectedChunkBytes(...)`.

## 3. Root cause: single-commit-range strictness regression (2026-07-17)

Both gates that trigger 5/5 of the false rejects landed on the same
day — the LZW-lzwz migration and the exact-extent introduction. Per
`PLAN.md` "Next up" entries dated 2026-07-17:

1. **Required LZW EOD** — `lzwz` v0.2.0 no longer accepts physical EOF
   before the required EOD code; returns `SourceTooShort`. Explains
   `lzw-single-strip.tiff`. Historical TIFF writers (per the fixture's
   filename convention and its 7795×3122 bilevel scan shape) commonly
   omitted EOD. libtiff tolerates that.
2. **Exact-extent gate** — `validateAllStripsAndTiles` derives each
   chunk's expected byte extent from `image_width × image_length ×
   samples × bits`, planar layout, edge geometry, and rejects any
   `written != expected` with `error.Malformed`. Located
   `src/decoder.zig:357-401`, extent math at `expectedChunkBytes`
   (`src/decoder.zig:443-506`). Explains the other four.

The extent-gate math (`src/decoder.zig:490-506`) assumes chunky-photometric
`bytes_per_pixel = ceil(sum(bits_per_sample)/8)` and does not model:

- **YCbCr subsampling** (`ycbcr-cat.tif`, subsampling 2:2): actual
  packed layout for a 2×2 block is `4·Y + Cb + Cr = 6 bytes` per 4
  pixels, i.e. 1.5 bytes/pixel — half our computed 3 bytes/pixel.
  Extent-gate expects ~2× the bytes the codec produces → mismatch.
- **Tile edge padding vs image bounds — but ONLY when the codec chooses
  to short-return**: for the two tiled uncompressed / LZW fixtures
  (`cramps-tile.tif`, `quad-tile.tif`), the codec returns fewer bytes
  than `tile_width × tile_length × bytes_per_pixel` for one or more
  edge tiles. Needs isolation per fixture (see §7 to-dos).
- **Deflate final-strip short return** (`deflate-last-strip.tiff`,
  RowsPerStrip=16 over 500 rows → last strip is 4 rows). Extent gate
  computes `500×4 = 2000` bytes for the last strip; the Deflate codec
  may be returning either 500×4 (correct) that we then miscompute, or
  8000 (padded to a full RowsPerStrip strip) that we correctly reject
  but shouldn't. Needs a small instrumented rerun to disambiguate.

## 4. Strictness audit vs libtiff / ImageMagick

Only surface-scan complete for this slice. The 5-fixture regression
above is where our strictness diverges from libtiff/ImageMagick's
acceptance envelope. Additional gaps observed during this session but
NOT reproduced yet:

- **Truncation** — no dedicated test-corpus of TIFFs truncated at
  known-byte boundaries. `SourceTooShort` is well-mapped by the
  codec, but per-tag / mid-IFD truncation acceptance is unaudited.
- **Malformed IFD/tag structures** — spot-checks in `decoder.zig`
  show a mix of `Malformed` returns and `error.UnsupportedTagType`.
  Not yet cataloged whether every branch carries diagnostic context.
- **Illegal offsets/counts** — `limits.max_strips_or_tiles`,
  `max_decompressed_strip_bytes` are enforced; `image_width×length ==
  0` is rejected. No corpus for offset-past-EOF or offset-into-header.
- **Overlapping/cyclic structures** — `IfdChainCycle` error exists
  and is emitted by `parseIfdChain`; validate treats it as
  structural FAIL. No test yet demonstrates coverage against an
  actual cyclic sample.
- **Trailing data** — silently ignored; no policy check today.
- **Resource limits** — `limits.zig` covers strip count, decompressed
  bytes, IFD chain depth. No fuzz over adversarial limit values.
- **Unsupported-vs-invalid classification** — `error.UnsupportedCompression`
  vs `error.Malformed` at `src/decoder.zig:892` is the primary
  discriminator; validate's routeError maps each. No cross-repo test
  proves the mapping holds for future codec code additions.

## 5. Sniper / bolter / shotgun coverage

- **Current state**: mutation runs live in validate, not here. Prior
  measured cell was `bali.tif` at 7/45/100 (sniper/bolter/shotgun);
  latest cell `pc260001.tif` is 0/0/0.
- **Missing**: per-fixture, per-compression stratified matrix. Every
  compression (`none`, `packbits`, `lzw`, `ccitt_t4`, `ccitt_t6`,
  `deflate`, `deflate_adobe`, `jpeg`, `zstd`, `lerc`) needs its own
  row. Absent that stratification, a low overall score can be
  masked by a single high-coverage codec (Deflate ≈100 shotgun via
  CRC32) or falsely blamed on the codec (uncompressed → no codec
  invariant → 0 by construction, not by bug).
- **Not in this slice**: mutation harness lives in validate; a tiffz-
  side stratified sweep would duplicate that harness. See §7 next
  slice — cross-repo coordination note to validate.

## 6. Diagnostics audit

Current shape of error surface:

- `errors.Error` is a flat enum (`Malformed`, `SourceTooShort`,
  `UnsupportedCompression`, `UnsupportedTagType`, `LimitExceeded*`,
  `Io`, `OutOfMemory`, `Bug`, etc.). Sufficient for validate's
  route decision, INSUFFICIENT for the per-finding constraint
  detail Einstein Note 2 §5 requires (byte offset, IFD/tag/chunk
  context, expected constraint, actual value, severity).
- INFO findings via `Decoder.setFindingCallback` + `emit` do carry
  a code + payload (see `src/findings.zig`), but only for the
  presence-of-feature class of observation — not for structural
  rejections. Structural rejections are opaque enums.
- **Gap:** `validateAllStripsAndTiles` cannot today report
  "IFD 0 tile 7: expected 32768 bytes, got 24576, extent gate at
  decoder.zig:387." That is the exact diagnostic depth Einstein
  requires. Fix shape (deferred): add a `Diagnostic` struct
  variant with (offset, ifd_index, chunk_index, expected, actual,
  reason_code) and route through the finding callback OR return
  via `error{...} + out-parameter` pattern.

## 7. Embedded-stream / bounded-Source support

- **API today**: `Source.fromBuffer` (caller-owned slice) and
  `Source.fromBufferedReader` (sequential reader with cache
  window). All reads route through `Source.readAt(offset)` where
  `offset` is source-relative.
- **What validate needs (per Einstein Note 2 §6)**: reads MUST NOT
  escape a bounded window of a parent file. Today the caller can
  hand `Source.fromBuffer(parent_bytes[range])` — that gives a
  slice-of-slice with the parent's addressing zeroed at
  `range.start`. `Source.readAt(offset)` then operates in the
  child window's frame — but any offset written into the file's
  own tag values (which are absolute within the sub-window) is
  fine PROVIDED the caller has fully copied the sub-slice.
- **What's NOT yet in place**: a `Source.subSource(offset, length)`
  that WRAPS the parent without copying AND enforces that all
  reads land inside `[offset, offset+length)`. Also missing: a
  diagnostic distinction between "payload-relative offset" and
  "host-file offset" so an error message can carry both.
- **Fix shape (deferred)**: add a `BoundedSource` variant to the
  `Source` union with `(parent_source, base_offset, length)` and
  extend the finding/diagnostic payload with `host_offset` and
  `payload_offset` fields.

## 8. Fixture drift (`tests/fixtures/tiled/` vs labeled corpus)

- `tests/fixtures/tiled/cramps-tile.tif`: SHA256 prefix `c4795de1...`.
- `~/Code/validate_gui/ground_truth_examples/tiff/cramps-tile.tif`:
  SHA256 prefix `cd14f8e2...`.
- `tests/fixtures/tiled/quad-tile.tif` prefix `6483855c...` vs
  labeled `ab5e5c87...`.
- `deflate-last-strip.tiff` is byte-identical between the two.
- **Consequence**: the pre-existing positive `cramps-tile.tif` and
  `quad-tile.tif` oracle tests pass on OUR fixtures because they
  are different files. Not a bug per se — the pre-existing tests
  do exercise real TIFFs — but the naming collision is a maintenance
  trap. The audit fixtures under `tests/fixtures/labeled_good/`
  address this by using a distinct directory and asserting the
  cross-repo byte-identity in the test's failure diagnostic.

## 9. Validate integration API/FFI

- LERC + GeoTIFF surfaces landed in the 2026-07-19 handoff
  (`ae2af963` + `277a16b0`) and were acknowledged by validate on
  2026-07-23 (`bcbe83b4` is validate's integration pin, matching
  our HEAD).
- No further API/FFI work is BLOCKED on tiffz today.
- Blocker on the shim side: labeled-corrupt 0/5 rejected. Two
  possibilities:
  1. All five corrupt fixtures are pixel-only byte flips that
     no TIFF structural rule can catch (valid-but-different
     pixels). Einstein Note 1 acknowledges this class.
  2. tiffz IS returning `Malformed` on one or more but the shim
     is swallowing it. Requires validate-side inspection.
- **Action (this slice)**: LLMsend validate for adjudication of
  the 5 corrupt fixtures (see next slice §10).

## 10. Smallest next release slice

Once orchestrator merges the four parser audits into one master
priority list:

1. **Fix `expectedChunkBytes` for YCbCr subsampling.** Concrete
   ask: consult `YCbCrSubSampling` tag; expected bytes per pixel
   is `(2 × subH × subV + 2) / (subH × subV)` for chunky YCbCr.
   Reproducer: the `ycbcr-cat.tif` characterization test.
2. **Fix `expectedChunkBytes` for tiled edge tiles / deflate
   last-strip return convention.** Instrument the four
   extent-gate rejections one more time to capture the exact
   `(expected, actual)` pair for the failing chunk of each
   fixture — then decide whether to accept short returns
   (codec did the right thing, extent-math was too strict) or
   force codecs to pad (codec should return the full extent).
   Trade-off deserves an Einstein or Peter decision.
3. **Optional-mode required-EOD.** Downgrade
   `SourceTooShort` on LZW streams that reach the declared
   pixel extent without an EOD from FAIL to WARN. Payload:
   INFO finding code (`missing_lzw_eod`?) so validate can
   route as such. Reproducer: `lzw-single-strip.tiff`.
4. **Bounded-Source API + host/payload offset distinction.**
   Required by Einstein Note 2 §6 for embedded-stream support.
5. **Sniper/bolter/shotgun stratification on validate's side.**
   Not a tiffz task; coordination note only.

Do NOT bundle 1-5 into one commit. Each is its own TDD slice:
red test in `audit 1.0 [reg]:` → fix → flip the assertion
from `expectError(...)` to bare positive.

---

## Appendix A — verification commands run this session

```
./test                              # canonical suite — GREEN
./build (implicit via ./test)       # nix build — GREEN
```

Corpus sizes:

```
labeled_good/cramps-tile.tif         786_758 B
labeled_good/deflate-last-strip.tiff  12_789 B
labeled_good/lzw-single-strip.tiff    76_264 B
labeled_good/quad-tile.tif           209_220 B
labeled_good/ycbcr-cat.tif            72_766 B
```
