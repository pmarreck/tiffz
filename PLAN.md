# tiffz — Plan

Living checklist of work items. Update as items complete; keep recent
completions for continuity. See `SPEC.md` for the milestone roadmap and
`docs/superpowers/specs/2026-05-04-tiffz-api-design.md` for the frozen
public API design.

## Next up

### >>> MORNING RUNBOOK (2026-08-27; freeze 17:00 EDT) — two launch-critical items <<<

**Freeze context (validate note 2026-08-21, urgent):** Peter committed to a 15-person
Mecha Validate Founding Beta 2026-09-01; freeze recommendation 2026-08-27 17:00 EDT.
Only two tiffz items are on the critical path. Both notes' full text preserved below
in their PLAN items; inbox notes trashed per ephemeral rule after acks were sent
2026-08-26 late night (validate got a CR2 status + lercz ETA; Einstein got an ack).

- [x] **1. lercz artifact export** (2026-08-27 11:40 EDT). RED: a genuinely external
      consumer package `tests/lerc_consumer_pkg/` (tiffz as a path dep) panicked
      "unable to find artifact 'lerc'" — exactly validate's failure shape. GREEN: one
      `b.installArtifact(lercz_dep.artifact("lerc"))` re-export in build.zig (same
      target/optimize instance the module links; no new pins/instances). The consumer
      declares the two C externs (`lerc_getBlobInfo`/`lerc_decode`) with no header,
      links ONLY the exported artifact, and both calls must reject garbage at runtime
      (link-level + call-level proof, silent on success). Wired
      `checks.lerc-artifact-export` (Nix), a `./test` subtest, and the Mechatron
      target. All four `./test` subtests + `./build` green. Original ask follows: validate_gui pin `c104bc0` fails
      `nix build .#validate-server` linking `libvalidate_core.a`: undefined
      `lerc_getBlobInfo`/`lerc_decode` reached through `src/compressions/lerc.zig` —
      external static-archive consumers can't name tiffz's private
      `lercz_dep.artifact("lerc")` for flattening. TDD: consumer-shaped contract test
      FIRST that fails on the present build and proves a downstream
      `b.dependency("tiffz", ...).artifact("lerc")` (or a better stable public name)
      resolves + links code calling the LERC C ABI through the exported artifact (not
      just tiffz's own exe). Then expose/install the EXISTING artifact — same
      target/optimize instance the named module imports; NO nixpkgs LERC, no second
      pin, no second module instance. Acceptance: `./test` + Nix checks clean; docs/
      PLAN/dirtree current; commit+push; reply to Einstein + validate with exact SHA,
      Zig package hash, artifact name, and the focused consumer command.
- [x] **2. CR2 sRAW2 false-Malformed FIXED via partial-coverage skip** (2026-08-27
      ~11:45 EDT). Peter ruled live: OJPEG decode coverage abandoned entirely (legacy
      TIFF-6.0 §22 scheme AND Canon's relabeled flavor); "propagate the named
      unsupported portion of the file as partial coverage." Einstein approved
      Namespace-B `unsupported_compression_skipped = 16` (8-byte payload: u32 LE IFD
      index + u32 LE compression; once per skipped IFD). Implementation: comptime
      `supported_compressions` list is the single source of truth driving BOTH the
      `decodeBytes` dispatch guard and the walk's skip, so they cannot drift; the walk
      skips never-supported-compression IFDs with the finding and continues; direct
      `decodeStrip` callers still get the hard `UnsupportedCompression`. The SPP/BPS
      strictness (original Malformed site) is now unreachable for this file and stays
      UNIMPLEMENTED (no failing fixture; latent-strictness watch: a SUPPORTED-
      compression file with BitsPerSample.count>1 and SamplesPerPixel absent would
      still false-reject — fix on first real sighting). MFIC per Einstein's list:
      predicate classifier over supported/never-supported/unknown code sets; CR2
      must-accept asserts payload length 8, both LE halves (IFD 0+3, comp 6), exactly
      2 emissions, walk continuation (IFD2 decodes); corrupt-comp-7 test asserts zero
      code-16 (supported failures keep native errors). RED (Malformed) → GREEN
      188/188. Fixture vendored byte-identical (5.8MB must-accept control). Original
      context follows: Root cause of the sRAW2 false-Malformed is
      PINNED (2026-08-19 instrumentation, still in the dirty tree):
      `expectedChunkBytes` on **IFD0 chunk 0** — the CR2's embedded JPEG preview IFD,
      NOT Canon's vendor IFD3. IFD0 (per tiffdump) has `BitsPerSample` count=3
      (8,8,8) but NO SamplesPerPixel tag (TIFF default 1) and NO Photometric;
      `bitsPerPixel`'s guard `bps_entry.count != 1 and != samples` (decoder.zig:772)
      → Malformed. exiftool/libtiff/libraw all tolerate (infer 3 samples).
      **Fix part A** (mechanical): when SPP is absent, infer samples from
      BitsPerSample count — libtiff-tolerated deviation → accept (+ likely WARN code
      16, needs Einstein sign-off per the registry rule).
      **Fix part B (the policy fork, Peter's call):** after A, the walk still hits
      Compression=6 (OJPEG, deliberately blocked per SPEC §3) on IFD0 AND IFD3 — a
      named unsupported error would propagate and fail the whole walk. For the
      must-accept contract the walk needs a semantics decision: skip
      undecodable-but-well-formed IFDs with a coverage-gap finding (validate routes
      to WARN), vs propagate named-unsupported (validate treats as coverage WARN but
      the walk "fails"), vs full acceptance only for known-preview IFD shapes.
      **Freeze reality told to validate:** plan for CR2 = honest `partial` at the
      freeze; if Peter + Einstein rule fast in the morning the fix may still land by
      17:00 and I notify immediately. Dirty-tree state: vendored fixture
      `tests/fixtures/cr2/` (untracked), must-accept test + CR2DBG split
      instrumentation in fixture_test.zig, walk instrumentation in decoder.zig,
      `.filters = &.{"CR2"}` in build.zig (REVERT filter + instrumentation before
      any commit). Suite is deliberately red on the CR2 must-accept test (the
      failing wedge).

### >>> TOMORROW'S SCOPE (scoped 2026-08-05 23:00 EDT, for Peter's oversight) <<<

State: the whole seam A+B was executed overnight (Einstein-authorized, superseding
the pause) in `8fe6524e` on top of parser-module refactors, tip `5f97831d`; Mechatron
PASS on all four manifest targets. VERIFIED tonight (read-only): codes 13/14/15 exist
in findings.zig (75-84); stale `lerc_post_compression=13` comment gone; jpegz pinned to
the requested `fb72045459be`; all four labeled_good fixtures FLIPPED from reject to
accept+WARN (deflate→13, lzw→14, cramps/quad→15 once each, fixture_test.zig ~1653-1710)
plus a code-15 negative classifier. So the seam BEHAVIOR is done. What remains:

- [x] **P0 — code-13 u32 payload** (2026-08-11). `acceptDecodedExtent` (decoder.zig:552)
      now emits `emitU32(.final_strip_padding_tolerated, written − ext.min)` — the LE u32
      excess bytes validate wanted for "final strip padded by N bytes" — replacing the
      empty `emit(...&.{})`, still firing once. Excess saturates into u32 defensively.
      TDD: extended the finding-13 test to assert `payloadFor(...) == 6000` for
      deflate-last-strip (derived from geometry: 500 B/row × (16−4) padding rows = 6000,
      not from the impl). RED (found null) → GREEN. `./test` (all three sandbox checks) +
      `./build` green; native 186/186. Durable-reply to validate pending after commit.
- [x] **P0 — jpegz pin bump `fb72045` → `98824e7b`** (2026-08-11). build.zig.zon pinned;
      flake.nix `zigDepsHash` regenerated → `sha256-FOaYVuJfJSySdKIYnhUiso7c+WHxC4gEJQ5QaXZM9Jg=`.
      The bump surfaced a real integration fix: jpegz's new `validateAny` appended a
      `.jpegz` leaf to `facade_validation.ValidatorSource`, and tiffz's two forwarding
      switches (decoder.zig:131 `emitStrictValidationFindings`, findings.zig:127
      `strictFindingVerdict`) were non-exhaustive → compile error. Mapped `.jpegz →
      SourceDecoder.jpegz` and mirrored jpegz's own verdict semantics from
      `jpegz.strictFromReport`: `.fail`→corrupt, recovered deviation (`.warn`/`.info`)→
      valid, meta-codes (`unrecognized_container`, `jxl_validator_unavailable`)→
      indeterminate. Extended the strict-facade forwarding test into a jp2z/libjxlz/jpegz
      classifier covering the full verdict range. We import the Zig MODULE (build.zig:155),
      not the static `.a`, so jpegz's ET_REL link-bug does not affect us. `./test` (incl.
      JPEG-validation-closure) + `./build` green; native 186/186. Ack owed to jpegz +
      validate (validate can now reach validateAny through `tiffz.jpegz`).
- [x] **P1 — coverage inventory matrix (Einstein dispatch outcome 2)** (2026-08-11).
      `docs/tiffz_coverage_matrix.md`: strict/partial/unsupported/blocked across
      compression, container/structure, predictor, photometric, bit-depth, metadata,
      embedded-JPEG, DNG, vendor-extension. Code-derived first pass with a **Verified**
      column (code / fixture / provisional) — honest about which cells are fixture-backed
      vs inferred. Provisional cells flagged for fixture promotion: predictor-3 float,
      CIELab/ICCLab, CMYK, transparency-mask, 32-bit float, EXIF-IFD descent.
- [x] **P1 — corpus + mutation classification + fuzz (Einstein outcome 5)** — DONE
      (Peter's call 2026-08-12: outcome 5 delivered by increments 1+2 + the existing
      `assertOracleMatch` oracle differential; the runtime mutation-verdict diff is skipped
      as noisy/low-ROI). Mechatron `c695f8ba` = success (548s, incl. the fuzz target).
      Increment 1 SHIPPED (2026-08-11): `tests/fuzz/fuzz.zig` — deterministic (fixed-seed,
      hermetic) mutation fuzzer with three MFIC properties: (1) robustness/non-crash sweep
      over 18 committed seed fixtures × 200 seeded mutations (sniper/shotgun/boltgun,
      biased toward the structural region), built ReleaseSafe so any UB on mutated input
      is a real bug; (2) specificity corpus — every known-good seed must validate unmutated
      under REAL default limits (the paired guard so a reject-everything validator can't
      score 100%); (3) the mutators are themselves tested for non-vacuity. Wired `./fuzz`
      (native), `zig build fuzz`, `checks.fuzz` (Nix, ReleaseSafe), and the Mechatron
      target `checks.x86_64-linux.fuzz`. Robustness uses bounded 256 MB limits to cap CI
      RSS (was ~1 GB). `./fuzz` + `./test` green.
      **The fuzzer immediately found a real bug**: a mutated embedded-JPEG strip makes
      `jpegz.validate` PANIC (index-OOB in jpegz `decodeBlockCoefficients`, baseline.zig:850)
      instead of erroring — a jpegz robustness bug tiffz inherits (a panic can't be caught).
      Reported to jpegz (inbox note). The JPEG fixture is a TRACKED exclusion from the
      robustness sweep (kept in specificity); re-include on the fixed jpegz pin.
      Increment 2 SHIPPED (2026-08-11): a must-detect SENSITIVITY classifier — three
      structurally-fatal corruptions (byte-order marker, version magic, first-IFD offset
      past EOF; endianness- and BigTIFF-aware) applied across the whole corpus (incl. JPEG,
      which rejects at open before any strip decode), asserting 100% detection. Paired with
      the specificity corpus this is a real detection number (a reject-everything validator
      fails specificity). `./fuzz` (Nix, ReleaseSafe) green, 6/6 harness tests.
      Increment 3 (oracle) — REFRAMED: the "oracle vs libtiff/ImageMagick" requirement is
      already met by `assertOracleMatch` (fixture_test.zig:334), which differentials tiffz's
      decoded RGBA against ImageMagick/tiff2rgba reference over 28 `_oracle` fixtures. The
      fuzz adds the mutation dimension that was missing. The only unbuilt piece is a RUNTIME
      mutation-verdict diff (tiffz vs libtiff accept/reject on mutated files), which needs a
      new validate executable (CLI is an M2 scaffold) and is inherently noisy on corrupt
      inputs — deferred pending Peter's call on whether it's worth it.
- [x] **P2 — independent verification (MFIC segregation of duties)** (2026-08-11). Fresh
      baseline `./test` of HEAD `f7d03e4e` → exit 0 (overnight seam independently confirmed
      green on my machine). Spot-checked code-15 bounds in `chunkLayout` (decoder.zig:498):
      canonical tile arrays handled FIRST (precedence, `tolerated=false`); the compat route
      fires only with both TileWidth+TileLength, canonical tile arrays absent, and both
      strip arrays complete + count-matched; every incomplete/ambiguous shape hits
      `orelse return error.Malformed`. Matches Einstein's ruling; negative classifier
      present. Sound.
- [x] **P2 — acyclic rawz/tiffz/jpegz boundary (Einstein outcome 4)** (2026-08-11).
      Confirmed acyclic: the only `rawz` token in tiffz's build files is a comment; tiffz
      EXPORTS `tiffz-parser` (build.zig:17, consumed by rawz) and imports NO rawz. A
      `tiffz-parser-consumer` artifact (build.zig:26) exercises the codec-free boundary.
      Dependency flows one way (`rawz → tiffz-parser`); no coordinator needed.

Cross-repo context (NOT tiffz work): validate is integrating `8fe6524` in their v1
cutover now (their blockers: JXL non-claimable, production closure still has OpenJPEG/
libjpeg-turbo/LibRaw — all validate-side). rawz repin done (`c57166db` parser module).

### WATCH FOR — ALL THREE RESOLVED 2026-08-14 (`f0cbb2d9` + `388dee45`)

- [x] **jpegz re-pin (JP2 fix)** — bumped jpegz `98824e7b` → `919571d` (`f0cbb2d9`),
      which re-pins jp2z `1b29e0c` (the `entropy_under_read` false-positive fix behind
      the `jp2_uses_9x7_wavelet`-on-clean-lossy-JP2 reject). Also bumped lzwz 0.2.0 →
      0.3.0 `c8f1c9a` (`388dee45`, provenance/release bump, src unchanged, warning-14
      contract re-verified). validate notified with the pin to consume.
- [x] **`-Dwith-jp2-decode` forwarding** — jpegz shipped it in `a8b79da` (⊂ `919571d`);
      tiffz now declares the option and forwards it verbatim in all three jpegz
      dependency branches (default true = jpegz's own; false drops opj_ symbols for
      validation-only consumers). validate sets it through their tiffz dependency.
- [x] **JPEG fuzz re-enable** — jpegz `d1eedca` (⊂ `919571d`) fixed the
      `decodeBlockCoefficients` OOB this repo's fuzzer reported (root cause per jpegz:
      SOS Td/Ta table selectors, 4 bits → 0..15, indexing `[4]` arrays — scan header,
      not the entropy stream; plus two sibling crashes we never hit).
      `robustness_excluded` is EMPTY again; the same fixed-seed mutation stream that
      panicked the old pin passes 6/6 whole-corpus.

### Mecha Validate v1 strict JPEG-family finding seam (2026-08-05 overnight)

- [x] TDD approved warning codes 13/14/15 with their exact bounded acceptance rules and independently classified fixture evidence. RED and GREEN observed for each; completed 2026-08-05 01:59 EDT.
- [x] Extend the pre-1.0 callback ABI to typed `(source_decoder, finding_code)` identity with append-only sources tiffz=1, jpegz=2, jp2z=3, libjxlz=4 and an unknown-value path. Equal-code/different-source and unknown-source classifier green; completed 2026-08-05 02:07 EDT.
- [x] Pin exact `jpegz@fb72045459be7dc2c73337e321096ed3e1eedb0f` and bridge only its strict validation findings into tiffz without a rawz dependency or a second jpegz module instance. The shared LZW compatibility core is pinned at `5dba5c449219f00f665efe31e69934364e048de5`; completed 2026-08-05 02:12 EDT.
- [x] Preserve nested raw code, source, TIFF-host offset, offset exactness, and valid/corrupt/unsupported/indeterminate semantics; unsupported and indeterminate do not become valid or corrupt. Mode-2 offset mapping and synthetic JP2/JXL forwarding classifier green; completed 2026-08-05 02:12 EDT.
- [x] Prove the selected production validation closure excludes external JPEG-family decoders/oracles while preserving the completed codec-free `tiffz-parser` boundary. Static musl proof checks runtime result, symbols, dynamic section, and embedded store references; Nix `allowedReferences=[]` passed 2026-08-05 02:16 EDT.
- [x] Run canonical `./test`, `./build`, exact Nix manifest gates, commit/push green, obtain terminal exact-SHA Mechatron evidence, and publish immutable Validate/rawz/global notes. Mechatron passed `8fe6524e40dc3c5472c19e5a8044c07aa3a880b3` in 3m27s; durable notes delivered; completed 2026-08-05 02:35 EDT.

Curiosity pokes: callback source/code equality must distinguish numeric collisions; the strip tolerances must not widen unrelated corrupt inputs; canonical tile tags must retain precedence; and tiffz must not import rawz or duplicate the jpegz module instance downstream.

### Parser-only production boundary (rawz/Validate unblock)

- [x] Expose `dep.module("tiffz-parser")` with the Source, Limits, header,
      IFD, tags, and IFD-chain parser surface needed by rawz, while preserving
      the existing full `tiffz` module/API. Curiosity poke: rawz currently
      reads `Decoder.ifd_offsets`; the compatibility surface must cover that
      field without importing the codec-bearing decoder. Completed 2026-08-05
      00:57 EDT.
- [x] Add a mechanical consumer/closure gate that compiles and runs without
      codec imports or system-library links, and rejects zlib, OpenJPEG,
      libjpeg/libjxl, zstd, LERC, jpegz, or other codec leakage. Curiosity
      poke: a green executable alone can miss unused build-graph edges, so the
      gate must inspect both the parser source import closure and the produced
      artifact. The gate independently rejected a package import, a `-lz`
      compiler edge, a dynamic ELF, and an injected Nix store reference;
      canonical `./test` and `./build` passed. Completed 2026-08-05 00:57 EDT.
- [x] Make the full `tiffz` module consume the parser module as the sole owner
      of shared parser files, and permanently test full+parser coexistence in
      one Zig compilation. RED at 2026-08-05 01:02 EDT: Zig rejected
      `src/errors.zig` as owned by both modules. Curiosity poke: every full-side
      relative import of a parser-owned file must move to the named module, or
      the first fixed collision will only reveal the next one. GREEN with
      shared type-identity assertions, canonical `./test`/`./build`, and a
      zero-reference parser Nix output. Completed 2026-08-05 01:08 EDT.
- [x] Publish the exact tiffz repin and module-name instructions to rawz and
      Validate after canonical tests, build, Nix targets, and terminal
      Mechatron evidence pass. Curiosity poke: the full tiffz consumer remains
      intentionally codec-bearing; only parser consumers should switch.
      Durable notes include the shared-instance injection rule, exact commit,
      Zig package hash, and terminal 151-second Mechatron result. Completed
      2026-08-05 01:18 EDT.

### POLICY (Peter, 2026-08-01): readable-but-nonconformant → accept + WARN

Standing rule. If data is technically wrong per the TIFF spec but still readable,
and libtiff overlooks/allows it, tiffz accepts it too rather than FAILing — but
emits a WARNING to callers. `docs/tiffz_findings_mapping.md:151-155` already
reserved `warning_message` for exactly this; severity lives on validate's side,
tiffz emits a finding code that validate routes to WARN.

Investigation of the 4 held false-rejects (2026-08-01, instrumented the extent
gate then reverted):

- **deflate-last-strip.tiff** — last strip (idx 31) decodes to 8000 bytes but the
  gate expects 2000 (4 logical rows × 500, RowsPerStrip=16 so the strip is padded
  to a full 16 rows). Padded final strip = technically wrong, libtiff-tolerated →
  **accept + WARN**.
- **lzw-single-strip.tiff** — LZW stream ends at physical EOF with no required EOD
  code (`SourceTooShort` from the codec, never reaches the extent gate). libtiff
  tolerates → **accept + WARN**.
- **cramps-tile.tif**, **quad-tile.tif** — CHARACTERIZED 2026-08-04 (instrumented
  the strip branch + expectedChunkBytes, then reverted; cross-checked with
  `tiffdump`/`tiffinfo`). NOT padding cases — a DISTINCT third deviation. Both are
  TILED images (cramps 800×607 / 256×256 tiles = 4×3 = 12 tiles; quad 512×384 /
  128×128 = 12 tiles) whose tile offsets + byte counts are stored under the STRIP
  tags `StripOffsets(273)`/`StripByteCounts(279)` with a `RowsPerStrip` tag, and
  which have NO `TileOffsets(324)`/`TileByteCounts(325)`. This violates TIFF 6.0
  (tiled images must use tile tags, must not use RowsPerStrip), but libtiff
  tolerates it: it aliases StripOffsets≡TileOffsets / StripByteCounts≡TileByteCounts
  internally and keys "is tiled" on `TileWidth`. tiffz keys "is tiled" strictly on
  `TileOffsets(324)`, so it misclassifies these as strip-based, then
  `expectedChunkBytes(.strip, 0)` throws `Malformed` at the chunk-count check
  (12 offset entries = 12 tiles, but RowsPerStrip=256/128 over the image height
  implies only 3 strips → `chunk_count(12) != expected_cc(3)`). Correct handling
  per Peter's policy: detect tiling via `TileWidth`/`TileLength` presence and read
  tile offsets/counts from the strip tags when the tile tags are absent (a decode-
  path change, NOT just a gate relaxation) + a THIRD WARN code (e.g.
  `tiled_geometry_via_strip_tags_tolerated`). So the WARN set grows to 3, and this
  one carries real decode work beyond the padding/EOD relaxations.

**UNBLOCKED — Einstein ruled 2026-08-02** (`inbox/2026-08-02-from-Einstein-finding-seam-and-warning-codes.md`).
Namespace-B codes assigned append-only: `13 final_strip_padding_tolerated`,
`14 lzw_missing_eod_tolerated`. The speculative `lerc_post_compression = 13`
comment in findings.zig:73-78 must be removed (never assigned; 13 is now taken).
Safety boundaries are part of the ruling and must gate the accept:
- **LZW missing EOD** → accept+WARN ONLY if decode reached physical EOF cleanly
  AND produced the exact bounded extent the container expects. Short, overlong,
  invalid code transition, or any other entropy failure stays a hard failure.
- **Final-strip padding** → accept+WARN ONLY inside a derived bounded
  `[logical_min, permitted_full_chunk_max]`. Bytes past the max stay a failure.
- **cramps-tile.tif / quad-tile.tif** NOT proved to hit the padding path.
  Characterize before applying the policy (may be a distinct bug, not a WARN).
- TDD the WARN emission and the callback ABI as a classifier; coordinate the
  validate-side pin so neither repo's canonical gates go red between commits.

### SEAM PLAN — Peter chose "do the whole seam (A+B)" 2026-08-04; NOT started (late)

Peter's steer: implement the full finding-seam + accept+WARN, Phase A then Phase B.
Deferred starting because it's a multi-hour ABI-breaking cross-repo push and it was
after 10pm — better begun fresh. Everything needed to launch is captured here.

Code 15 APPROVED by Einstein 2026-08-04 (`inbox/processed/2026-08-04-from-Einstein-warning-code-15-approved.md`).
Final Namespace-B WARN codes (append-only after `12 lerc_compression`):
- `13 final_strip_padding_tolerated` — bounded `[logical_min, full_chunk_max]`; bytes past max still FAIL.
- `14 lzw_missing_eod_tolerated` — accept ONLY if decode hit physical EOF cleanly AND produced the exact bounded extent; short/overlong/invalid still FAIL.
- `15 tiled_geometry_via_strip_tags_tolerated` — Einstein's bounds: activate the
  fallback ONLY when tiled geometry is present (TileWidth/TileLength), canonical
  `TileOffsets(324)`/`TileByteCounts(325)` are ABSENT, and BOTH strip-tag arrays
  (273/279) are present. Canonical tile tags keep precedence — do NOT reconcile
  ambiguous simultaneous tile+strip arrays. Emit 15 exactly once per accepted
  deviation. Reject malformed/incomplete arrays. Needs a real decode-path change
  (detect tiling via TileWidth; read tile offsets/counts from the strip tags),
  not just a gate relaxation.

Ordered steps for next session:
1. Fix the stale `lerc_post_compression = 13` comment in findings.zig:73-78 (13 is now taken).
2. Phase A, TDD each: code 13 (deflate-last-strip accept+WARN), code 14 (lzw-single-strip
   accept+WARN), code 15 (cramps/quad tiled-via-strip-tags decode fix + WARN). Flip the
   four labeled_good characterization tests from `characterizeCurrentReject` to
   `expectFixtureValidates` as each lands. Keep 13/14/15 independently classifiable over
   the fixture set (deflate, lzw, cramps, quad + must-pass conformant members).
3. Phase B: Option-B typed-source callback ABI change (source registry `tiffz=1,jpegz=2,
   jp2z=3,libjxlz=4`, `i32`/`int32_t` named constants, unknown-value path) for nested
   jpegz findings (P1 Tier 2). Coordinate the validate-side pin so neither repo goes red.
4. Report to Einstein when the seam lands: tiffz SHA, exact test counts, Mechatron result,
   validate-side pin/API change.

Session 2026-08-04 shipped (all pushed, Mechatron `b3b8871a` = success): rawz M2
double-free (`2a431856`), rawz M2 BigTIFF IFD8 (`b3b8871a`), cramps/quad characterization
(`bfb2ca53`). Einstein reported (`inbox/.../2026-08-04-from-tiffz-rawz-m2-fixed...`).


- [x] **Fix planar=separate u32 underflow in strip row math** (2026-07-31,
      Einstein note 2026-07-29). ReleaseSafe test builds (`flake.nix` now passes
      `-Doptimize=ReleaseSafe` to `zig build test` — fleet UB floor) exposed a
      real crasher: `length - strip_index*rps` in the strip paths underflows on
      the 2nd+ sample plane when `PlanarConfiguration=2` makes StripOffsets span
      all planes. Under ReleaseFast it wrapped huge and the next `@min` clamp
      masked it into the right answer *by accident*. Fixed by extracting a pure
      `stripRowSpan(length, rps, strip_index)` that reduces the index into its
      plane band (`% strips_per_plane`, a no-op for chunky) and guards rps/length
      == 0. **Two** call sites had the bug: `decodeStripRaw` (codec dispatch,
      the one Einstein flagged) AND `applyPredictorStrip` (inverse predictor).
      Tile paths confirmed unaffected (always full TileLength, no index math).
      MFIC: classifier unit test over chunky/separate × single/multi-strip ×
      short-last-band with hand-derived oracles — the separate odd-band cases
      (idx 3,5 @ len=20,rps=16 → 4) give a WRONG 16 pre-fix even under
      ReleaseFast, so the test bites in both build modes, not just via the
      ReleaseSafe panic. `./test` + `./build` green; committed with the flake
      change (`d03c9d24`).
- [x] **Bounded sub-source / base-offset API — `Source.fromSubrange`**
      (2026-07-31, Peter elevated it; Einstein Note 2 §6 fork). Read-only audit
      first: the current `Source` is strictly 0-based pread (`readAt`+`sizeOf`),
      NO base offset; embedding today = caller slices `[start,end)` into a
      `fromBuffer`/`fromBufferedReader` 0-based view, and offsets provably cannot
      escape (past-range read → 0 → `error.SourceShortRead`). So "prove the
      contract" already held for *correctness*; the real gaps were (1) no
      zero-copy view into a larger host Source, (2) host-absolute diagnostics.
      Fork resolved: **built gap 1**, a `Source.fromSubrange(&SubSourceHandle{
      inner, base, len })` bounded base-offset view — reads translate to
      `base+off` and clamp to `len` (host bytes outside the window are
      unreachable), `sizeOf`==len, no allocation, thread-safety follows inner.
      Exactly what validate needs to hand tiffz an embedded TIFF (DNG/RAW preview,
      container payload) without copying — the frozen API design already names
      "DNG embedded thumbnails" as the motivating case. **Deferred gap 2**
      (host-absolute diagnostics): findings.zig carries only enum codes + LE
      numeric payloads, NO byte offsets, so there is no surface to map back to
      the host yet — pairs with a future offsets-in-findings change nobody has
      requested. MFIC: unit classifier over base translation / length clamp /
      escape + declared-len-past-inner short-read, plus a metamorphic integration
      proof (a real fixture validates identically at base 0 vs embedded at a
      nonzero base in 0xAB junk). 207/207 tests; `./test` + `./build` green.

**QUEUED (not dropped):**
- [x] **P1 Tier 1 — JPEG-in-TIFF error categorization** (2026-08-01, validate
      2026-07-30 media-release blocker). `compressions/jpeg.zig` collapsed every
      `jpegz.decode` failure to `error.Malformed`, so validate's routeError could
      only say "Invalid TIFF structure" for a bad embedded JPEG. Added
      `error.JpegInTiffPayload` (errors.zig #25, append-only; C ABI status enum
      is build-generated so no header edit) and remapped the non-OOM catch to it.
      This is validate's option 2 (categorization), which they called a big
      improvement over generic Malformed. TDD: added the two tests first, watched
      them fail with `found error.Malformed` (proves jpegz errors on the inputs
      and the tests bite), then remapped. Unit classifier over deterministic bad
      streams (empty / no-SOI / SOI+EOI) plus an integration test that corrupts a
      real fixture's SOF0 and asserts the error propagates through
      `validateAllStripsAndTiles`, with the pristine fixture as the must-pass
      member. 209/209; `./test` + `./build` green.
- [ ] **P1 Tier 2 — specific jpegz cause via nested finding. UNBLOCKED — Einstein
      chose Option B 2026-08-02** (callback ABI extension, not a wrapper code).
      The callback gains a typed source so every finding is the pair
      `(source_decoder, finding_code)`, never a bare integer. Append-only source
      registry shared at the ABI: `tiffz=1, jpegz=2, jp2z=3, libjxlz=4`, sized
      `i32`/`int32_t` with named constants (C enum-width rules must not alter the
      ABI), plus an unknown-value path for newer producers. Native tiffz findings
      emit `(tiffz, Namespace-B)`; embedded JPEG findings emit `(jpegz,
      Namespace-A)` with jpegz's own code, never flattened. TDD the ABI as a
      classifier over native + nested findings INCLUDING equal numeric codes from
      different sources, to prove the pair prevents collision. Coordinate the
      validate-side pin so neither repo's gates go red. NB Peter 2026-07-31:
      jpegz is absorbing JPEG-XL + JP2 (WIP); the source registry already
      reserves jp2z/libjxlz so the seam stays valid as jpegz owns more formats.

### rawz M2 defects (Einstein, 2026-08-03) — additive, behind the finding-seam work

- [x] **FailingAllocator index 3 segfault in `Decoder.openWithLimits` cleanup**
      (2026-08-04 17:45 EDT). Root cause was in `ifd.zig` `parse` (reached via
      openWithLimits at decoder.zig:80): once `ifd` was built, `entries` had TWO
      owners — the early `errdefer allocator.free(entries)` AND `errdefer
      ifd.deinit()` (deinit also frees entries). Allocation failure index 3 (the
      `scratch` alloc, first alloc after the ifd.deinit errdefer) fired both →
      double-free of `entries` → SEGV. Fixed by giving each resource exactly one
      owner: kept `free(entries)`, added `free(cached_values)` for the pointer
      array, and replaced `errdefer ifd.deinit()` with one freeing only the
      accumulated out-of-line bufs. No deinit() on a partially-built object.
      MFIC: `std.testing.checkAllAllocationFailures` sweep as a 2-member
      classifier — inline-only fixture (pins the reported index 3) + two
      out-of-line values (covers the `buf` alloc/accumulation path, indices 4-5),
      so fixing index 3 can't hide a sibling invalid-free (Einstein's follow-up).
      RED first: SEGV at index 3; GREEN after: 211/211. `./test` (ReleaseSafe) +
      `./build` (ReleaseFast) both green.
- [x] **`Ifd.arrayElementU64` returns `UnsupportedTagType` for BigTIFF `IFD8`
      arrays** (2026-08-04 17:55 EDT). IFD8 (type 18) is a u64 offset with the same
      on-disk shape as LONG8, but all three u64 read paths — `arrayElementU64`'s
      raw out-of-line switch, `readArrayElementFromBytes` (cached), and
      `readArrayInline` — listed `.long8` and fell `.ifd8` through to
      `else => UnsupportedTagType`. Fixed by aliasing `.ifd8` onto the `.long8`
      arm in all three. MFIC: mechanically-built BigTIFF SubIFD (tag 330) fixture,
      classifier over {inline count=1 → readArrayInline, out-of-line count=2 →
      cached readArrayElementFromBytes}, asserting the decoded u64 offsets. RED
      first (UnsupportedTagType); GREEN after: 212/212. `./test` + `./build` green.
- [x] **P2 — joint labeled-good + labeled-corrupt adjudication reply**
      (2026-08-01, validate 2026-07-25). Independently re-derived both answers on
      the current tree (`8e02bc71`), not trusting validate's manifest: Q3 via my
      own `cmp -l` vs the clean control (all 5 = exactly one byte → 0x00 at the
      listed offsets, SHAs match), Q1 via a throwaway native harness running
      `validateAllStripsAndTiles` over control + 5 corrupt (all six return OK;
      harness read the external private corpus so it was run natively and removed,
      not committed). Verdict `valid_modified_payload`, not a tiffz gap; concur
      with validate's reclassification `74a1f17e0f14`. Joint Part A (labeled-good
      false-reject root cause: exact-extent + required-EOD gates, 1/5 fixed via
      the YCbCr work, 4/5 held pending a cross-parser padding/EOD policy ruling)
      + Part B sent to `~/Code/inbox/`. Flagged the padding + EOD standards
      decisions to Einstein.

### 1.0 finish-line audit (Einstein, 2026-07-23) — audit-only, no broad fixes

Sequencing per Einstein Note 2: stop at the verified audit/report milestone
so the orchestrator can merge all four parser audits into one master list.
Response is expected durably in `~/Code/inbox/`.

- [x] **Reproduce every false-reject as a failing library test**
      (2026-07-24). Byte-verbatim fixtures under
      `tests/fixtures/labeled_good/`; 5 negative-characterization
      tests in `tests/fixture_test.zig` under the `audit 1.0 [reg]:`
      prefix assert the wrong-but-current error through
      `validateAllStripsAndTiles`. Attribution: 4/5 =
      exact-extent gate (post-codec), 1/5 = required-EOD gate
      (codec). Both gates shipped 2026-07-17 — single-commit-range
      strictness regression. See `CODE_REVIEW.md` §3.
- [x] **Independently adjudicate the 5 labeled-corrupt fixtures**
      (2026-07-24). Ran `Decoder.open` + `validateAllStripsAndTiles` over the
      clean control + all five `rgb-3c-8b_corrupt_{1..5}.tiff` at `83064193`
      and again on the post-YCbCr tree: **all six return OK (exit-0
      equivalent)**. Each mutation is one byte → `0x00` in an uncompressed RGB
      strip payload (no header/IFD/offset/count/codec touch): category =
      uncompressed pixel/sample data with no integrity oracle (5/5 pixel-only,
      0 structural, 0 codec-payload, 0 unadjudicated). Reconciles byte-for-byte
      with validate's table; confirmed compatible with validate's
      `valid_modified_payload` reclassification. Corpus labels need correcting,
      not a tiffz decoder/shim change.
- [x] **YCbCr subsampling extent correction** (2026-07-24). CODE_REVIEW §10
      slice #1. `ycbcr-cat.tif` (250×325 LZW YCbCr 2:2) now validates.
      `expectedChunkBytes` returns `ExpectedExtent {min,max}`: chunky subsampled
      YCbCr sizes data units of (H·V·Y + Cb + Cr) per TIFF 6.0 §21, the final
      strip permitted to pad from required (libtiff `TIFFVStripSize`) up to
      full-RowsPerStrip (`TIFFStripSize`) — libtiff probe captured last strip
      required 2250 / stored 3750. Non-subsampled chunks keep min==max
      (exact-equality gate unchanged). Tag 530 added; 6 pure-formula unit tests
      (odd dims, 2:1/1:2/2:2/4:4, limit) + flipped product-path fixture test.
      JPEG-in-TIFF excluded (jpegz returns upsampled RGB).
- [x] **YCbCr residual slices** (Einstein continue-note 2026-07-24 13:08). Done:
      - [x] tag-absent `YCbCrSubSampling` default `{2,2}` — product-path test
            (`2ec617b4`).
      - [x] tiled chunky subsampled YCbCr — real libtiff 4.7.1 fixture
            (`ycbcr_tiled_uncompressed_sub2x2.tif`, 16×16 one tile, 384 B vs flat
            768) + product-path test; upgrades the `.tile` branch off formula-only.
      - [x] planar-separate subsampled YCbCr — RESOLVED as correct-by-design, NOT
            a gap: libtiff 4.7.1 itself cannot read it (`TIFFStripSize`=256 for
            every plane; subsampling math is contig-only, so the 64-B chroma
            planes error with "expected 256"). tiffz's `planar==chunky` guard
            already matches libtiff — separate-plane YCbCr is treated full-res.
            No code change; documented with the libtiff probe evidence.
      Exact-equality preserved for non-subsampled; characterized-red short-return
      fixtures kept separate from padded-final-strip acceptance.

- [ ] **Flip JPEG decode to jpegz cleanroom** (jpegz note 2026-07-24: gap D
      landed at `a59df43`). One-liner `src/compressions/jpeg.zig:decode`
      `jpegz.internal.wrapperDecode` → `jpegz.decode`; must hold byte-exact vs
      ImageMagick oracle across ALL jpeg-in-TIFF fixtures (not just rgb-jpeg.tif).
      Unblocks jpegz's libjpeg graduation (two-step handshake). No timeline
      pressure; ship only if the full jpeg oracle suite stays green, else report
      the failing fixture(s) back to jpegz as a blocker.
- [x] **validate byte-value correction acknowledged** (2026-07-24, FYI). Old-byte
      transcription fixed (corrupt_1 83→00, _2 A4→00, _3 8D→00, _4 02→00,
      _5 C7→00); offsets/coords/`valid_modified_payload` conclusion unchanged, so
      all five tiffz direct verdicts stand. Authoritative TSV: validate_gui
      `8fb1699`, verified by validate `74a1f17e0`.


- [ ] **Produce per-fixture, per-compression sniper/bolter/shotgun scores.**
      Never let one uncompressed largest fixture stand in for TIFF. Report
      exact commands, corpus provenance/counts, and a confusion matrix.
- [ ] **Bounded sub-source / base-offset API — add it or prove the current
      caller-owned slice contract.** Include tests that no strip/tag offset
      escapes the embedded TIFF range and diagnostics distinguish
      payload-relative from host-file offsets.
- [ ] **Strictness audit vs libtiff / ImageMagick.** Truncation, malformed
      IFD/tag structures, illegal offsets/counts, decompressor
      terminators/extents, overlapping/cyclic structures, trailing data,
      resource limits, unsupported-vs-invalid classification.
- [ ] **Diagnostics audit.** Every finding must carry byte offset,
      IFD/tag/chunk context, expected constraint, actual value, severity;
      accumulate multiple safe-to-report findings rather than opaque
      fail-fast.
- [x] **Update `CODE_REVIEW.md`** (2026-07-24). First-slice
      audit surface written directly (skill invocation deferred —
      the findings are domain-specific and the audit is scoped to
      the labeled-good regression + adjacent gaps). Doc covers
      measured state, reproducers, root cause, strictness /
      diagnostics / embedded-stream gap sketches, and the ordered
      smallest-next-release-slice list.
- [ ] **Refresh `PLAN.md` with every concrete pre-1.0 gap** the audit
      surfaces (this section itself may split further as evidence lands).
- [ ] **Identify API/FFI work validate still needs** and any integration
      blocker in either repository.
- [ ] **Reply to `~/Code/inbox/`** with: current commit, dirty-state
      ownership, exact scores, critical findings, and the smallest next
      release slice — NOT a broad fix batch.

### Previously completed (2026-07-19)

- [x] **Require LZW EOD and prove general 1-bit LZW decoding**
      (2026-07-17). The TIFF LZW loop now returns `SourceTooShort` rather
      than accepting physical EOF before its required EOD code. A compact
      inline 8×1 bilevel LZW TIFF proves the ordinary `Decoder.decodeStrip`
      path handles packed 1-bit LZW data, so Validate can remove its duplicate
      TIFF fallback after the shared `lzwz` migration.
- [x] **Require exact decoded extent per strip and tile** (2026-07-17).
      `validateAllStripsAndTiles` now derives each chunk's byte extent from
      image geometry, sample depths, planar layout, and edge-strip/tile shape;
      a valid LZW EOD with zero output for a declared 8×1 bilevel strip is
      rejected. This closes the complementary PASS path where a terminator
      existed but the declared pixels were absent. Full sandboxed suite green
      18:33 EDT.
- [x] **Migrate TIFF LZW to shared `lzwz`** (2026-07-17). `tiffz` now
      imports and re-exports the single profile-configured core used by PDF,
      GIF, and TIFF; its 346-line private decoder and duplicate dictionary
      tests are deleted. The thin adapter maps `IncompleteSource` to
      `SourceTooShort`, keeps the existing malformed-only old-style fallback
      and INFO finding, and avoids a second Zig module instance downstream.
      Fresh fixed-output dependency hash, release build, and full sandboxed
      test suite green 18:42 EDT. Updated to `lzwz` v0.2.0's shared
      count-only exact-extent API surface (including exhaustive error mapping)
      with fresh Nix hash, release build, and sandboxed test suite green
      19:05 EDT.
- [x] **16-bit-per-sample photometric expansion (RGB / Gray / CMYK)**
      (2026-05-17). `PixelFormat` gained `endian: Endian = .little`;
      new `sampleU8` helper does endian-aware u16 reads + canonical
      `(x*255+32767)/65535` downscale. Per-channel u8 reuse keeps the
      8-bit composition math intact. Palette + CFA + YCbCr + Lab stay
      8-bit (16-bit variants are niche).
- [x] **planar=separate photometric expansion** (2026-05-17). New
      `interleavePlanesToChunky` helper assembles N per-plane buffers
      into chunky form for `expandRowsToRgba` to consume. Fixture
      test integration through `decodeStrippedSeparateIntoRgba` which
      reads N strips per row band and routes through the helper.
      rgb_separate.tif (16x16 RGB 8-bit, planar=separate) matches the
      magick RGBA oracle byte-exact.
- [x] **ZSTD-in-TIFF** (2026-05-17). Compression code 50000.
      `src/compressions/zstd.zig` wraps pmarreck/zstdz (vendored
      facebook/zstd C library via Zig build). rgb_zstd.tif fixture
      generated via `gdal_translate -co COMPRESS=ZSTD` decodes byte-
      exact against the magick RGBA oracle.
- [x] **JPEG-in-TIFF YCbCr photometric override** (2026-05-17).
      Caller-side override in `decodeFixtureToRgba`: when
      compression=7 + photometric=YCbCr, force photometric=RGB before
      expansion (libjpeg already converts internally). ycbcr_jpeg.tif
      fixture (tiffcp -c jpeg:90, subsampling 2:2) matches libtiff
      tiff2rgba byte-exact.
- [x] **Eager IFD value caching** (2026-05-17). `Ifd.parse` now
      eagerly loads every out-of-line tag value at parse time (sorted
      by value-offset for forward-only Source traversal). Subsequent
      `Ifd.arrayElementU64` and `Ifd.readEntryValueCached` lookups
      serve from the cache without touching the Source. Lifts the
      cache-sizing constraint for streaming sources reading
      IFD-at-start TIFFs to "just enough for one strip". IFD-at-end
      layouts still need a cache that spans the strip region —
      documented in `Source.fromBufferedReader` doc-comment and in
      `docs/possible_future_directions.md` §G.
- [x] **`docs/possible_future_directions.md`** (2026-05-17).
      Inventory of remaining coverage gaps and adjacent improvements,
      each annotated with realistic cost (XS/S/M/L) and rationale
      for deferral.
- [x] **INFO finding callback API** (2026-05-18). New
      `src/findings.zig` with `InfoFinding` enum (stable u32 codes,
      1..11) + Callback type using C calling convention. Decoder
      grows `setFindingCallback(cb, userdata)`, `scanFindings()`,
      and per-IFD scanner that fires for BigTIFF, multi-IFD,
      predictor != 1, ExtraSamples=1 (pre-multiplied alpha),
      Compression=7 (JPEG-in-TIFF), TileOffsets present (tiled
      layout), PlanarConfiguration=2 (separate), photometric=CFA
      or CFAPattern present, opcode list 1/2/3 present (with count
      payload), and any GeoTIFF tag present. LZW codec dispatch
      fires `old_style_lzw_codes` (once per Decoder via a flag) when
      the codec falls back from new-style to old-style on a
      malformed stream. 7 fixture-based unit tests verify emission
      on real TIFFs. Mapping doc updated with the new API + a
      ready-to-paste `FindingAccumulator` shim for validate.
      Validate's M10 integration unblocked.
      (2026-05-17). New `BufferedReaderHandle` wraps a sequential
      reader (function-pointer ctx + read_fn) and a caller-supplied
      cache window. Reads inside the window are served from cache
      without touching the reader; forward reads beyond `cache_end`
      pull from the reader (sliding the window by half its size
      when full to amortize the memmove cost across multiple pulls);
      reads before `cache_start` surface as
      `error.SourceSeekTooFarBack`. Cache-sizing guidance documented
      in `Source.fromBufferedReader`: since the decoder re-reads
      out-of-line tag values (StripOffsets / StripByteCounts / etc.)
      on each `decodeStrip` call rather than caching the arrays
      eagerly, the cache must remain large enough to keep those
      low-offset values resident; for typical libtiff-default
      layouts a 1 MiB cache covers all common cases.

## Milestones (from SPEC §9 — implement in order)

- [x] M1: Audit + spec freeze (2026-05-04). Spec frozen; audit
      corpus + coverage matrix committed (see Recently completed).
- [x] **M2: Skeleton** (2026-05-04). build.zig + build.zig.zon, Zig
      core (errors, limits, source, workspace, decoder, version, ffi,
      lib), C FFI (`tiffz_version` exported), C CLI (--version /
      --about / --help) dogfooding the FFI, packages.default +
      checks.test in flake.nix, ./build + ./test driver scripts,
      Zig+CLI integration tests passing under sandboxed nix. Zig
      pinned to 0.15.2 via mitchellh/zig-overlay (per portfolio
      "wait for 0.16.1" convention).
- [x] **M3: Classic TIFF, uncompressed (core)** (2026-05-05).
      Source.fromBuffer + BufferHandle, header parser (classic +
      BigTIFF magic detect + reject), IFD parser with lazy values
      and limit enforcement, Decoder.open/decodeStrip wired
      end-to-end, real-fixture tests (rgb-3c-8b, minisblack-1c-8b,
      palette-1c-8b) passing the sandboxed gate.
- [x] **M3 follow-up: photometric expansion + RGBA oracle**
      (2026-05-06). expandRowsToRgba in src/photometrics.zig handles
      photometric ∈ {0 MinIsWhite, 1 MinIsBlack, 2 RGB, 3 Palette}
      for 8-bit chunky planar input. Canonical u16→u8 downscale
      `(x*255 + 32767)/65535` matches ImageMagick's
      ScaleQuantumToChar (catch: plain `>> 8` truncation off-by-ones
      whenever ColorMap low byte ≥ 0x80, e.g. 0x49E8 trunc 0x49 vs
      correct 0x4A). Three real-fixture tests assert byte-exact
      match against committed .rgba oracles generated via `magick
      ... RGBA:...`. Decoder/IFD pipeline now produces full RGBA
      images for the uncompressed cases.
- [x] M4: Compressions (all sub-items complete; see below).
  - [x] PackBits (2026-05-07): src/compressions/packbits.zig + dispatch in
        Decoder.decodeStrip on Compression=32773. Two real-fixture oracle
        tests pass byte-exact: cramps.tif (800×607 MinIsWhite, big-endian)
        and at3_1m4_01_rgb.tif (640×480 MinIsBlack, little-endian). Workspace
        gained ensureScratch(min_bytes) for compressed-input staging.
  - [x] LZW (2026-05-07, partial): src/compressions/lzw.zig (algorithm
        adapted from validate's tiff_lzw_decoder.zig with attribution
        + tiffz API shape — caller-supplied dest, no allocation, tiffz
        error set). Variant enum supports new_style (TIFF 6.0 spec:
        MSB-first + early code-width change) and old_style (Sun/Adobe
        legacy: LSB-first + late change); strip dispatcher tries
        new_style first, falls back to old_style on Malformed.
        bali.tif (725×489 LZW palette, big-endian) oracle passes.
        Two follow-ups deferred:
          • quad-lzw.tif → Malformed under both variants. Likely needs
            a libtiff-style header sniff (LZWFixupTags) or a third
            variant combo. Test commented out with TODO.
          • strike.tif → decode succeeds but bytes differ from the
            ImageMagick oracle. Confirmed 2026-05-07 by validate:
            *tiffz's output is the spec-correct one* (ExtraSamples=1
            stores associated/pre-multiplied alpha; ImageMagick's
            RGBA: output un-pre-multiplies as a presentation choice).
            tiffz should NOT un-pre-multiply during decode. The fix
            is (a) regenerate the strike oracle preserving assoc-alpha
            (or use a tiffz-native byte-correct oracle), and
            (b) emit an INFO finding (`pre_multiplied_alpha = true`)
            at validate-integration time. INFO finding work lands at
            M10 alongside the validate finding mapping table.
          • quad-lzw.tif → validate flagged 2026-05-07 that this is
            libtiff's *third* LZW variant: pre-emptive code-width
            bump (separate from new/old style timing). Libtiff sniffs
            it from the first few bytes of the codestream. Adding a
            third Variant member + heuristic detection is a future
            follow-up.
  - [x] CCITT G3 1D / T.4 (2026-05-07 algorithm; 2026-05-13 Linux-
        portable): src/compressions/ccitt_t4.zig. Modified-Huffman
        tables (white runs, black runs, color-independent extended
        make-up codes) transcribed from ITU-T T.4 §4.1.4 Tables 1-3.
        BitReader supports both FillOrder values (1=MSB-first,
        2=LSB-first per TIFF tag 266). Per-color comptime-built
        [14][8192] O(1) lookup tables keyed on (length, bits).
        Decode loop: syncToEol at row start (no post-EOL alignment —
        T4Options bit 2 means EOL is pre-padded so it itself starts
        at a byte boundary; reading the 12-bit EOL leaves us 4 bits
        in and data continues from there). 2D mode rejected, that's
        M4-E.
        fax2d.tif (1728×1082, FillOrder=2, EOL byte-aligned, single
        strip via RowsPerStrip=4294967295) oracle passes byte-exact
        on both Mac aarch64-darwin and Linux x86_64-musl. Decoder
        regression guard pinned via SHA-256 in a @embedFile-backed
        unit test (independent of the fixture-pipeline). Photometrics
        also gained 1-bit-per-sample expansion (MinIsWhite invert +
        MinIsBlack direct, 1-bit packed MSB-first → RGBA).
        Bug stack from the Linux-portability dig:
          1. Initial decoder had a spurious post-EOL alignToByte —
             I misread T4Options bit 2 as "align after EOL" when the
             spec says "EOL is at byte boundary (encoder pads
             before)." Removing the alignToByte fixed correctness.
          2. Linear table scan was slow enough that Linux musl
             exceeded the 10-min watchdog. Replaced with
             comptime-built [14][8192] lookup tables; ~12× speedup.
          3. fixture_test didn't clamp RowsPerStrip = 0xFFFFFFFF
             ("infinite"), so strip_max = 216 × 4294967295 ≈ 927 GB.
             Mac's lazy allocator tolerated the virtual reservation;
             Linux musl rejected. Same clamp as Decoder.decodeStrip
             already had internally now propagated into fixture_test.
  - [x] Deflate (2026-05-07): src/compressions/deflate.zig.
        compression=8 (Deflate) and compression=32946 (AdobeDeflate)
        — same on-disk zlib-framed format, separate registrations
        per TIFF Technical Note 2. Wraps allyourcodebase/zlib
        (community Zig wrapper around upstream C zlib, zlib license,
        same dep validate uses). flake.nix gained the fixed-output
        zigDeps pattern for sandboxed Nix builds. deflate-last-strip.tiff
        (500×500 MinIsBlack, little-endian) oracle passes byte-exact.
  - [x] CCITT T.6 (Group 4) (2026-05-13). src/compressions/ccitt_t6.zig.
        2D modified-modified-Huffman: pass / vertical (V0, VR1-3,
        VL1-3) / horizontal mode codes; reference-line management
        via changing-element lists; pair-step cursor (a0/b1/b2);
        EOFB detection. Reuses T.4's modified-Huffman tables + bit
        reader (made pub: Color, CodeKind, Match, BitReader,
        matchCode).
        **Marquee target passes byte-exact**: scan_petes_book.tif
        (11059×15671, the file that drifts after row 1030 in zigimg
        PR #321). Photometric-expanded RGBA hash-pinned to
        SHA-256 4514c30c... (oracle is 693 MB so committed via hash
        rather than raw bytes). Test runs in seconds thanks to the
        O(1) lookup-table refactor shared with T.4.
  - [x] JPEG-in-TIFF (2026-05-17). `src/compressions/jpeg.zig`
        dispatches Compression=7 through the sibling `jpegz`
        module (imported via `build.zig.zon`, re-exported as
        `tiffz.jpegz` in `lib.zig` so downstream consumers share
        a single jpegz module instance). Caller-side YCbCr
        photometric override in `decodeFixtureToRgba`: when
        compression=7 + photometric=YCbCr, force photometric=RGB
        before expansion (libjpeg already converts internally).
        `ycbcr_jpeg.tif` fixture (tiffcp -c jpeg:90, subsampling
        2:2) matches libtiff `tiff2rgba` byte-exact.
- [x] M5: Predictors (None / Horizontal) (2026-05-13).
      src/predictors.zig: applyInverse handles Predictor tag 317 values
      1 (none, no-op) and 2 (horizontal differencing). 8-bit-per-sample
      fully supported in both chunky and separate planar configs;
      stride = samples_per_pixel (chunky) or 1 (separate per-plane strip).
      Wraps mod 256 via Zig's `+%` operator. Decoder.decodeStrip applies
      the inverse via a new applyPredictor pass that runs after the
      codec dispatch and before the strip is returned (predictor=1 is
      a fast-path no-op). 3 real-fixture oracle tests pass byte-exact:
      LZW+pred1, LZW+pred2, Deflate+pred2 (all 32×32 RGB from a
      deterministic plasma seed). 6 unit tests cover the spec's
      worked example plus wrap-around, multi-row boundary, separate
      planar, 16-bit rejection, and floating-point rejection.
      *Deferred:* 16-bit horizontal predictor (needs file-endian-aware
      u16 reads — lands when 16-bit fixtures appear at M8 DNG).
      Predictor=3 floating-point (TIFF Tech Note 3, byte-plane
      interleaved differencing) returns UnsupportedPredictor; lands
      with M8 DNG raw work.
- [x] **M6: Tile-based layout** (2026-05-13). Decoder grew a
      `decodeTile(ifd_index, tile_index, dest, workspace)` primitive
      that mirrors `decodeStrip` for tiled images. Strip and tile
      paths share a single codec dispatch via the new private
      `decodeBytes(dir, ChunkExtent, dest, workspace)` helper; the
      per-chunk extent carries `offset/byte_count/width/rows` so
      CCITT (which needs scan-line geometry) works the same whether
      the chunk is a strip or a tile. `readPredictorMeta` factors the
      shared per-IFD predictor metadata; `applyPredictorStrip` /
      `applyPredictorTile` differ only in width/rows source
      (ImageWidth × clamped RowsPerStrip vs TileWidth × TileLength).
      decodeStrip rejects tile-tag dirs and decodeTile rejects
      strip-tag dirs (caller routes by `is_tiled`). Two real-fixture
      oracle tests pass byte-exact: cramps-tile.tif (800×607
      MinIsWhite, 256×256 tiles, uncompressed) and quad-tile.tif
      (512×384 RGB, 128×128 tiles, LZW). Tile edge cropping uses
      `@min(tile_w, width - origin_x)` and `@min(tile_h,
      height - origin_y)` — encoder pads the full tile, decoder
      copies just the in-image portion to the output RGBA.
      *Bug caught during impl:* the first cramps-tile fixture was a
      malformed tiled-TIFF where TileWidth/TileLength were set but
      data offsets lived in StripOffsets/StripByteCounts (libtiff
      tolerates this aliasing; tiffz won't). Regenerated both
      fixtures via `tiffcp -t -w … -l …` so they use the proper
      TileOffsets/TileByteCounts tags.
      *Threading-convention design captured 2026-05-07* (validate +
      jpegz aligning on the same shape; see "Decided design choices"
      below): when parallel strip / tile decode lands as a follow-up
      to this milestone, surface a `DecodeOptions { threads: u8 = 1 }`
      parameter on the convenience APIs (`validateAll`,
      `decodeStreaming`, `decodeAll`). Default `1` = sequential.
      `0` = explicit caller-opted-in auto-detect. `Decoder.decodeStrip`
      / `Decoder.decodeTile` themselves stay single-threaded
      primitives — caller distributes chunks across threads. No
      globals, no env vars, no auto-detection on the default path.
      C ABI mirrors with `tiffz_decode_all_ex(opts*)` plus an inline
      default-options wrapper.
- [x] **M7: BigTIFF — runtime offset-width abstraction** (2026-05-15).
      The IFD parser branches on a new `OffsetWidth { classic, big }`
      enum threaded through from the header. `Entry` is now uniform
      across both variants — `count: u64`, `raw_value_or_offset: [8]u8`
      (classic zero-pads the upper 4 bytes), eliminating any sum-type
      ripple through consumers. Wire-format differences (u16 vs u64
      entry_count, 12 vs 20 byte entries, u32 vs u64 next-IFD pointer)
      stay confined to `ifd.parse`. `readEntryValue` and
      `readArrayElementU64` (renamed/widened from U32) take an
      `OffsetWidth` parameter; inline-fit cap = 4 (classic) or 8 (big).
      Three new FieldType variants land: long8 (16), slong8 (17),
      ifd8 (18) — each 8 bytes/elem. `Decoder.open` drops the M7
      reject and passes `h.bigtiff ? .big : .classic` to the parser.
      Two real-fixture oracle tests pass byte-exact:
        • rgb-3c-8b.btf — uncompressed RGB, LONG8 StripOffsets
          (inline-fit because 9 strips × 8 bytes = 72 → out-of-line
          via u64 pointer); StripByteCounts SHORT inline.
        • bali.btf — LZW palette, LONG8 StripOffsets out-of-line
          (45 × 8 = 360 bytes); LONG StripByteCounts out-of-line.
      The codec dispatch (LZW + photometric + ColorMap pickup) all
      runs unchanged on BigTIFF metadata — the abstraction held.
      *Why runtime over comptime monomorphization* (SPEC.md hinted at
      comptime): the IFD parser isn't a hot path — codec dispatch is.
      A comptime split would double the parser binary footprint to
      save one branch per tag lookup. Runtime branch keeps a single
      code path and a single test matrix.
- [x] **M8: DNG — predictor 3, CFA tags, opcode list parser** (2026-05-16).
      Predictor=3 (TIFF Tech Note 3, FP byte-plane interleaved
      differencing) lands in `src/predictors.zig` for bps ∈ {16, 24,
      32, 64}, chunky + separate planar. Per-row two-step inverse:
      (1) horizontal byte-diff with stride = samples_per_pixel, then
      (2) endian-aware byte-plane de-interleave (TN3 stores planes
      MSB-first regardless of file endian, so LE-file decoders must
      invert the plane→byte mapping). The deferred-from-M5 Predictor=2
      16-bit horizontal path also lands here (endian-aware u16 reads
      via std.mem.readInt + wrap mod 2^16). applyInverse signature
      grew an `endian: Endian` and an `allocator: std.mem.Allocator`
      parameter — only the FP path consumes the allocator (one per-row
      scratch buffer), only horizontal-16 consumes the endian; decoder
      threads `self.endian` and `self.allocator` through both
      applyPredictorStrip and applyPredictorTile.
      New module `src/dng.zig` parses (no execution) the DNG-specific
      auxiliary tags:
        • CfaPattern (33421 dim + 33422 pattern) — zero-copy borrow
          of the pattern bytes; rejects dim=0 and short buffers.
        • OpcodeList (51008/51009/51022) — big-endian datastream per
          DNG §10.1; each opcode { opcode_id, dng_version, flags,
          parameters } with parameters as a zero-copy borrow.
          Hard cap of 1,000,000 opcodes to bound allocation on
          adversarial inputs.
      Photometric=32803 (CFA) routes through `photometrics.expandGray
      .direct` for v1 — each CFA sample emitted as gray RGBA so
      consumers can see the mosaic and demosaic later using the
      CfaPattern.
      End-to-end FP32 oracle test: gdal_translate generates a
      Predictor=1 (no transform) and a Predictor=3 fixture from the
      same 8×8 FP32 plasma seed; the test decodes both via
      Decoder.decodeStrip and asserts byte-exact match. This caught
      and pinned the LE plane-mapping bug.
      *Deferred (out of M8 scope):* full Bayer/X-Trans demosaic
      (M11/M12 territory); opcode list semantic execution (consumer
      concern); real-camera DNG fixtures (gdal-synth covers the
      Predictor=3 algorithmic case).
- [x] **M9: Pro photometrics — CMYK, YCbCr, CIE Lab** (2026-05-17,
      integer-only runtime same day per the new global "avoid
      floating-point in algorithm rewrites" design goal).
      Three new arms in `photometrics.expandRowsToRgba`:
      - **CMYK** (photometric=5): subtractive `(255-C)*(255-K)/255`
        with round-to-nearest. No ICC profile (device-dependent;
        deferred). 4-sample chunky 8-bit; extra samples beyond CMYK
        used as alpha when SamplesPerPixel ≥ 5.
      - **YCbCr** (photometric=6): BT.601 inverse with full-range
        (0..255), matching the TIFF defaults for YCbCrCoefficients
        (529) = (0.299, 0.587, 0.114) and ReferenceBlackWhite (532)
        full-range. Q16 fixed-point coefficients
        (`Cr_r=91881, Cb_g=-22554, Cr_g=-46802, Cb_b=116130`) matching
        libtiff's `TIFFYCbCrToRGBInit` byte-exact. Clamp to [0,255]
        at output. YCbCrSubSampling beyond 1:1 deferred.
      - **CIE Lab** (photometric=8): TIFF 8-bit Lab decode →
        Lab→XYZ (D50 reference white per spec) → D50→D65 Bradford
        adaptation → XYZ→sRGB linear → sRGB gamma → u8 clamp. Pure
        integer runtime: Q24 fixed-point for the matrix chain;
        comptime-generated LUTs for the L_byte→Y_d50 mapping, the
        a/b offsets, and the sRGB gamma encode (4097-entry Q12
        linear → u8 gamma). The Lab f^-1 piecewise function runs at
        runtime in Q24 (with comptime constants for 6/29, 4/29,
        and 3·(6/29)²). a*/b* read as signed bytes via
        two's-complement bitcast. 16-bit Lab and photometric=9
        (ICCLab) deferred.
      M9.5 follow-up: decoder.zig now accepts Compression=7 with
      photometric=YCbCr in addition to RGB. CAVEAT: libjpeg (via
      jpegz.wrapperDecode) performs YCbCr→RGB conversion internally,
      so the decoded bytes are RGB regardless of the TIFF photometric
      tag. The caller MUST NOT re-apply photometric=YCbCr expansion
      after JPEG decode (libtiff TIFFReadRGBAImage takes the same
      approach). Documented in src/compressions/jpeg.zig and
      decoder.zig.
      *Tests*: unit-scope CMYK endpoints + arbitrary pixel; YCbCr
      gray endpoints + near-pure-red round-trip; Lab black/white
      endpoints. End-to-end oracle fixtures: cmyk.tif (16×16, magick
      RGBA oracle) and ycbcr.tif (16×16, libtiff tiff2rgba oracle —
      tiffz's BT.601 inverse matches libtiff byte-exact; ImageMagick's
      Q16-internal YCbCr round-trip drifts ±1 LSB and isn't the
      canonical reference).
      *Deferred*: 16-bit Lab, ICCLab (photometric=9), CIE Lab fixture
      with magick/tiff2rgba oracle (the sRGB gamma curve + Bradford
      adaptation makes byte-exact oracle generation finicky; endpoint
      tests cover correctness for v1), JPEG-in-TIFF end-to-end with
      YCbCr photometric (requires caller-side photometric override
      since post-JPEG bytes are RGB).
- [x] **M9.5: JPEG-in-TIFF (compression=7)** (2026-05-16).
      `src/compressions/jpeg.zig` calls into jpegz via
      `jpegz.internal.wrapperDecode` (the libjpeg-turbo path).
      Photometric=RGB (2) only — YCbCr (6) defers to M9 where the
      photometric expansion grows YCbCr→RGB. Both TIFF Tech Note 2
      modes handled: Mode 1 (no JPEGTables) passes the strip stream
      straight through; Mode 2 (JPEGTables present) splices
      tables-sans-EOI ++ strip-sans-SOI into one self-contained
      JPEG. Real-fixture oracle: rgb-jpeg.tif (157×151 RGB, single
      strip, JPEGTables Mode 2) decodes byte-exact against the
      magick RGBA oracle.
      *Why wrapperDecode and not plain jpegz.decode:* jpegz's
      baseline cleanroom (~199/276 byte-perfect on libjpeg corpus;
      the rest within ≤2 LSB) is not byte-exact on our RGB-marked
      baseline + abbreviated/spliced bitstream. Pinning the libjpeg
      wrapper guarantees agreement with the magick oracle today;
      when jpegz Phase 2 cleanroom reaches byte-parity on these
      inputs, this swaps back to plain `jpegz.decode` with no
      behavioral change. Sent jpegz an inbox note with the spliced-
      stream fixture so they can repro.
      *Dependency wiring:* jpegz pulled in via `build.zig.zon` as
      `git+https://github.com/pmarreck/jpegz#<commit>` (pinned),
      added a 5-line `build.zig.zon` upstream so it could be
      referenced as a Zig package. tiffz passes `-Dwith-charls=false`
      to skip the JPEG-LS C++ compile (also added that gate
      upstream). flake.nix gains libjpeg-turbo + openjpeg buildInputs;
      `OPENJPEG_INC` env var threads the versioned include path
      (`include/openjpeg-2.5/`) through to jpegz's `@cImport`.
      *Follow-ups:*
        - YCbCr photometric (6) support — needs YCbCr→RGB at M9.
        - Tile-based JPEG-in-TIFF (current fixture is strip-based;
          the codec dispatch already routes through `decodeBytes`
          for both, but no tiled fixture is tested yet).
        - Swap to plain `jpegz.decode` when jpegz Phase 2 cleanroom
          handles RGB-marked baseline + spliced abbreviated streams.
      *Hash-pin floor captured 2026-05-07:* jpegz's corpus soak hit
      99.5% pixel-perfect against libjpeg-turbo (3828/3848) on
      baseline JPEGs after five cleanroom-internal fixes shipped that
      day. No ABI changes — Phase 1 wrapper / dispatcher / C FFI
      surface unchanged. Pin `build.zig.zon` `.jpegz.url` at any
      commit hash ≥ `17e70d3` to get the full pixel-parity plus the
      NotImplemented → wrapper fallback for progressive (SOF2) JPEGs.
- [ ] M10: Validate integration — replace zigimg dep in validate's
      TIFF deep-validation. Validate is *actively waiting on this*
      (per Peter 2026-05-07). When tiffz is M9-complete:
      (a) Use the LLMsend skill to drop a status note in validate's
          inbox + tmux ping with the `build.zig.zon` dep URL +
          commit hash to pin.
      (b) Ship a `tiffz_findings_mapping.md` modeled on jpegz's
          `2026-05-06-jpegz-mapping-table.md` (in validate's inbox
          archive). Format: routing taxonomy table (FindingCode,
          severity, routes-to: error_code/info/warning/malformation),
          short prose on info/warning/malformation distinction, and
          a ready-to-paste `mapping.zig` snippet with a
          `RoutedFinding` union(enum). Validate drops it verbatim
          into `src/core/tiffz_shim.zig` at integration time.
      (c) Initial INFO finding set to seed the mapping:
            • bigtiff_format (M7-gated)
            • multi_ifd_chain (DNG, multi-page faxes)
            • old_style_lzw_codes (LZW Malformed-fallback fired)
            • pre_multiplied_alpha (ExtraSamples=1 — covers strike.tif
              et al.; resolves the "skipped fixture" follow-up from M4-B)
            • predictor_applied = N (M5-gated)
            • geotiff_tags_present (M11-gated)
- [x] M11: GeoTIFF metadata surface (2026-07-19).
      New `src/geotiff.zig` exposes `parseFromIfd(dir, source,
      endian, allocator) -> ?Metadata`, returning the fully
      parsed OGC GeoTIFF 1.1 metadata:
      `ModelPixelScale` (3 doubles), `ModelTiepoint`
      (N × 6 doubles), `ModelTransformation` (16 doubles),
      `GeoKeyDirectory` (header + N `GeoKey` entries with
      `id / tag_location / count / value_offset`),
      `GeoDoubleParams`, `GeoAsciiParams`. Metadata-only —
      no CRS resolution or coordinate transforms; callers walk
      keys and dereference into the params arrays. Strict
      parse: GeoKeyDirectory whose `count != 4 + 4×N_keys`
      rejects `error.Malformed`. Real 16×16 EPSG:4326 fixture
      passes byte-exact against a hand-derived expected surface
      (7 keys, WGS 84 ellipsoid constants). Sandboxed suite
      green 10:54 EDT. TIFF/EP tag surface deferred as a
      follow-up — not blocking validate M10 integration.
- [x] M11: Wire GeoTIFF surface into the public tiffz namespace
      (2026-07-19). `tiffz.geotiff.parseFromIfd` reachable via
      `pub const geotiff = @import("geotiff.zig")` in
      `src/lib.zig` and re-exported through the
      `tiffz_named_module` — validate can consume without
      any additional shim.
- [x] M12: Modern compressions (LERC, ZSTD-in-TIFF).
      ZSTD landed 2026-05-17 (see Next up).
      LERC-in-TIFF landed 2026-07-19: sibling
      `pmarreck/lercz` (Zig-wrap fork of Esri/lerc under
      Apache-2.0), consumed via `build.zig.zon`. New
      `src/compressions/lerc.zig` mediates Compression=34887
      with a strict two-u32 `LercParameters` (50674) parse
      (codec_version ∈ 2..6, add_compression ∈ {0,1,2}) and
      chains the Deflate/Zstd post-filter when present. Four
      real-fixture oracle tests pass byte-exact vs
      ImageMagick RGBA: 16×16 gray bare-LERC,
      LERC+Deflate, LERC+Zstd, and 16×16 chunky RGB LERC.
      Sandboxed suite green 10:41 EDT.
      LERC finding-code emission deferred pending Einstein
      Namespace B sign-off (see ~/Code/inbox/ ping-out).

## Recently completed

- [x] **M2 skeleton** (2026-05-04). See M2 above.
- [x] **Audit corpus + coverage matrix** (2026-05-04). 18 TIFFs from
      validate's ground_truth + the marquee CCITT G4 reproducer
      scan. `audit/coverage_matrix.tsv` and `audit/AUDIT_SUMMARY.md`
      capture variant axes + gaps for synthetic fixture generation
      in later milestones.
- [x] **Bootstrap flake.nix + .envrc** (2026-05-04). Zig + libtiff +
      imagemagick + gdal (with check phase neutralized) + netpbm +
      vips + exiftool + hyperfine. `.envrc` activates the flake.
- [x] **Brainstorm + freeze public API design** (2026-05-04). Five
      open questions resolved (access patterns / allocation / errors
      / JPEG-in-TIFF / forward-only adapter + safety limits). Design
      committed to
      `docs/superpowers/specs/2026-05-04-tiffz-api-design.md`.
- [x] **Initial scaffold commit** (2026-05-04, upstream). README,
      SPEC, LICENSING_NOTES, LICENSE, validate handoff in `inbox/`.
- [x] **Untrack Obsidian-vault symlinks under jj** (2026-05-04). jj
      autocommit was staging gitignored Obsidian-vault doc symlinks
      (jj_cheatsheet, ZIG_RECENT_API_CHANGES, ZIG_0.15_TO_0.16). Now
      gitignored AND `jj file untrack`'d.

## Real-world reproducer pointers (from validate 2026-05-07)

- **`/Volumes/Fileserver/Pictures/scan from pete's book.tif`** —
  CCITT G4, 11059×15671, 1-bit MinIsWhite. **M4-E marquee target**
  (zigimg PR #321 drifts after row 1030). Already captured.
- **`/Volumes/Fileserver/Pictures/scan20050424_162904.tiff`** —
  uncompressed RGB, 21 MB, 2364×2951. Was a zigimg false-positive;
  M3 should validate it cleanly. Pull into fixtures when convenient
  to extend the M3 oracle suite to a larger image.
- **`/Volumes/Fileserver/Pictures/scan20041120_160518.tiff`** —
  uncompressed RGB, 9.7 MB, 2129×1486. Same class as above.
- Old-scanner TIFFs with non-standard RowsPerStrip → flag at M5
  (predictor edge cases).
- Photoshop CMYK proof TIFFs in `/Volumes/Fileserver/Documents/`
  and `/Volumes/Fileserver/Textfiles & PDF & eBook/` → M9 targets
  (CMYK photometric + Adobe ICC profile + DotRange tags).

## External signals received

- **2026-05-06 — jpegz Phase 1 ready** (see
  `inbox/2026-05-05-jpegz-phase1-ready.md`). Acknowledged via reply
  in `~/Documents-CloudManaged/jpegz/inbox/2026-05-06-from-tiffz-ack.md`.
- **2026-05-06 — jpegz M1.4b shipped + 14-bit precision fix** (see
  `inbox/2026-05-06-jpegz-reply-m14b-shipped.md`). M8 DNG schedule
  risk resolved. M1.5b (codec-level integrity in `jpegz_validate`)
  and M1.5c (APPn / trailing-EOI findings) also shipped — useful
  for pre-validating JPEGTables before splicing at M9.5. jpegz also
  proposed a clean photometric-helper split for an M3-end brainstorm:
  jpegz emits RGB/gray/CMYK; tiffz handles photometric→RGBA
  (CFA mosaic, palette, YCbCr sub-sampling). Captured below.

## Decided design choices

- **Photometric helper split** (decided 2026-05-06, both sides
  aligned): tiffz owns the photometric→RGBA layer because it knows
  TIFF semantics (CFA mosaic for raw sensors, palette lookups,
  per-revision YCbCr sub-sampling). jpegz stays decode-only and
  emits raw RGB / gray / CMYK that tiffz then transforms. Clean
  separation; can revisit if a sibling JPEG-only consumer ever wants
  the same RGBA helper. No further brainstorm needed; lock this in
  as the M3 follow-up shape.
- **Threading control convention** (aligned with validate + jpegz
  2026-05-07): convenience APIs gain a
  `DecodeOptions { threads: u8 = 1 }` parameter. Default `1` =
  sequential in calling thread. Explicit `0` = caller-opted-in
  auto-detect (uncommon — usually only standalone CLI tools).
  No globals, no env vars, no library-level auto-detection on the
  default path. The library passes `options.threads` through to any
  underlying multi-threaded deps (jpegz at M9.5, openjpeg if it
  ever lands). C ABI mirrors with an `_ex(opts*)` form plus an
  inline default-options wrapper. Validate's call sites read
  `tiffz.decode(source, .{ .threads = 1 })` — symmetric with
  `jpegz.decode(data, .{ .threads = 1 })`. Wired in at M6 alongside
  parallel strip/tile decode.

## Curiosity pokes / open questions for later

- Streaming-mode `Source.fromBufferedReader` cache size — default 8 MiB
  is a guess; bench against real TIFF layouts in the audit corpus to
  confirm it's not a foot-gun.
- `Limits.max_decompressed_strip_bytes = 1 GiB` is generous; tighten
  defaults if validate's audit shows real-world TIFFs comfortably fit
  under e.g. 256 MiB.
- IfdView accessor ergonomics — typed-getter shape (`getU16(tag)` vs
  `as(comptime T, tag)`) deferred to skeleton + first-use phase.
- DNG opcode list — surfaces as a structured list in tiffz; semantic
  execution (the actual image transforms) is a *consumer* concern.
  Confirm validate doesn't need execution at M10.
