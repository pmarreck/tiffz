# tiffz — intent

Purpose, users, outcomes, scope, and the constraints later work must
satisfy. Implementation status lives in `README.md` and
`docs/tiffz_coverage_matrix.md`. Execution lives in `PLAN.md`. Terms
live in `TERMINOLOGY.md`.

## Purpose and users

tiffz is validate's TIFF deep-verification library: a spec-driven
reader (and eventually writer) that reports whether a TIFF, BigTIFF, or
public DNG/TIFF-EP file is structurally sound, which portions were
actually decoded, and which deviations were tolerated.

It exists because incremental TIFF work in zigimg could not close the
variant matrix. "We can't validate this variant" is not an acceptable
steady state: either cover the variant, or name the uncovered portion
as partial coverage. Silent skip is the failure mode this project was
created to end. (SPEC.md §0, 2026-05-04; Peter's partial-coverage
ruling, 2026-08-27.)

Primary consumer: [`validate`](../validate) (Mecha Validate). Direct
Zig-module and C-FFI consumers are in scope. End users of the
verification, per README, are professional photographers, GIS/mapping
archives, and pathology slide stacks.

Proprietary camera RAW is not tiffz's product. See Scope.

## Desired outcomes

- Byte-complete validation of TIFF 6.0 and the major modern extensions
  that remain in scope (BigTIFF, JPEG-in-TIFF TN2, DNG container and
  CFA/opcode *parse*, ZSTD-in-TIFF, LERC, GeoTIFF tags).
- Consumers can distinguish corrupt data, tolerated encoder deviations,
  and incomplete coverage. Nested JPEG-family findings keep their own
  source identity and four-way verdict.
- Bounded-memory validation of large TIFFs (multi-GB scans) via
  `Source`. The whole file need not sit decoded in RAM.
- A writer path eventually. No current work or date. Not a reason to
  delay the reader/validator.

## Scope

**tiffz keeps** (Peter + Einstein, 2026-07-31,
`docs/tiff_raw_boundary.md`):

- Baseline TIFF and BigTIFF: IFDs, tags, offsets, strips/tiles,
  predictors, dispatched compressions.
- DNG as a public Adobe/TIFF-EP profile, including CFA tags and opcode
  *structure*. `src/dng.zig` stays here.
- Reporting facts without classifying vendor RAW. tiffz surfaces IFDs
  and tags; it does not decide "this is an ORF."
- Codec-free `tiffz-parser` for rawz and other classifiers.

**rawz takes:** vendor RAW (CR2, NEF, ARW, ORF, PEF, RW2, RAF, 3FR,
CR3), MakerNote interpretation, RAW semantics, format classification.

**validate keeps:** none of the parse. It calls tiffz/rawz and renders
findings.

## Non-goals

- **OJPEG (Compression=6).** Blocked. Peter, 2026-08-27: no decode of
  the TIFF 6.0 §22 scheme *or* Canon's relabeled CR2 flavor. The walk
  skips those IFDs with finding 16 and continues. Direct `decodeStrip`
  returns `UnsupportedCompression`. Do not reopen because SPEC §3 once
  said "probably skip."
- **Demosaic / raw development / DNG opcode execution.** Parse only.
- **ICC-profile-aware color.** Device-dependent CMYK/Lab fallback is
  documented; an ICC engine is a different tool class.
- **EXIF/XMP semantic parse.** Pass-through; consumers parse.
- **Repair.** tiffz does not rewrite files. Tolerated deviations are
  reported, not fixed.
- A second jpegz (or libjxlz/jp2z) module instance in any one Zig
  compilation. Validate consumes JPEG-family codecs only through
  `tiffz.jpegz`.

Unsupported means unclaimed. Blocked means will not be implemented.
JPEG2000-in-TIFF, JBIG, and other undispatched codecs stay unclaimed
until an explicit owner decision.

## Constraints

**Strictness** (Peter, 2026-09-09, standing rule for all Validate
libraries including this one): err on the side of strictness and
reporting detail. Fail closed on real corruption. When a known encoder
quirk is tolerated, emit a WARN (or INFO) with offset and payload;
never silent accept. Current named tolerances: findings 13, 14, 15, and
the finding-16 skip. New TIFF deviations follow the same rule.

**Spec over libtiff shape.** TIFF 6.0, TN1/TN2, BigTIFF, DNG, GeoTIFF,
ITU T.4/T.6 are primary. libtiff is the ambiguity-resolution reference
and, where the spec is unclear, wins over zigimg. Binary oracles
(`tiff2rgba`, `tiffinfo`, ImageMagick where it is the canonical
reference) verify output. Do not copy GPL TIFF code.
(`LICENSING_NOTES.md`, SPEC §4.)

**Findings ABI.** Namespace B codes are append-only; never renumber.
New codes need Einstein sign-off. Identity is
`(source_decoder, finding_code)`. Nested jpegz/jp2z/libjxlz findings
stay in their own source; do not flatten them into tiffz InfoFinding.
(`docs/tiffz_findings_mapping.md`, `src/findings.zig`.)

**Architecture.** Pure Zig core, no I/O. C FFI is the public non-Zig
API; the C CLI dogfoods it. Validate currently imports the Zig module.
Parser-only consumers import `tiffz-parser` from the same dependency
instance as `tiffz`.

## How success is verified

- `./test` (unit, fixtures, CLI, parser-closure, jpeg-validation-closure,
  lerc-artifact-export) and `./build`. Mechatron Prime exact-commit
  targets in `.mechatron-prime/targets`.
- Fixture oracles: decoded RGBA vs libtiff `tiff2rgba` or ImageMagick,
  documented per test. YCbCr matches `tiff2rgba` byte-exact.
- Coverage claims: `docs/tiffz_coverage_matrix.md`.
- Mutation/fuzz: `./fuzz` specificity corpus plus must-detect
  structural corruptions. A reject-everything validator must fail
  specificity.
- Downstream: validate's mapping in `docs/tiffz_findings_mapping.md`.
  A tiffz SHA is not delivered until that consumer can pin it.

Measured capability is not intent. If the matrix is partial, the
intent is still coverage or an honest named gap, not a quieter
parser.

## Open questions

- TIFF writer: accepted as eventual (SPEC §0). No date, no
  `intents/` file, no current PLAN item.
- JPEG2000-in-TIFF and other undispatched codecs: unsupported, not
  blocked. No owner decision yet.
- SPEC.md still reads as a 2026-05 starting brief in places
  (greenfield header, zigimg-gap table, Garnix). Those sections are
  historical; they are not a second purpose statement.

## Links

- Terms: `TERMINOLOGY.md`
- Plan: `PLAN.md`
- Starting spec and milestone history: `SPEC.md`
- TIFF ↔ RAW boundary rationale: `docs/tiff_raw_boundary.md`
- Coverage (measured): `docs/tiffz_coverage_matrix.md`
- Finding routing: `docs/tiffz_findings_mapping.md`
- Parser-only contract: `docs/parser_only_module.md`
- Remaining gaps (not commitments): `docs/possible_future_directions.md`
