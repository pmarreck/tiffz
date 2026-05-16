# Handoff: M8 (DNG) and M10 (validate integration)

**Written:** 2026-05-16 by the just-shipped-M7+M9.5 instance
**For:** the next fresh-context instance starting M8

You're picking up tiffz right after M7 (BigTIFF) and M9.5 (JPEG-in-TIFF)
just shipped. Garnix is all-green at `b48ec295`. M9 (Pro photometrics:
CMYK / YCbCr / Lab) is still pending but **Peter wants M8 done first,
then M10** — M9 can land before, after, or interleaved at your
discretion, but the explicit ask is M8 → M10.

This doc is here so you don't have to spelunk through a 100k-token
debug transcript to find what matters. Read it once, then start fresh.

---

## State of the world

### What's shipped

| Milestone | Status | Notes |
|---|---|---|
| M1-M6 | ✅ done | scaffold, classic-TIFF uncompressed, photometric expansion, packbits, LZW, deflate, CCITT G3/G4, predictors, tiles |
| **M7 (BigTIFF)** | ✅ shipped 2026-05-15 | runtime offset-width abstraction; `OffsetWidth { classic, big }` enum threaded through ifd.parse + readEntryValue. Entry unified (`count: u64`, `raw_value_or_offset: [8]u8`). |
| **M9.5 (JPEG-in-TIFF)** | ✅ shipped 2026-05-16 | `src/compressions/jpeg.zig` shim over `jpegz.internal.wrapperDecode`. RGB photometric only. Both TN2 Mode 1 and Mode 2 (JPEGTables splice) handled. |
| **M9 (Pro photometrics)** | ⏸ pending | YCbCr (6) + CMYK (5) + CIE Lab (8). Unblocks YCbCr-photometric Compression=7 fixtures too. |

### Read these files first (in order, ~10 minutes)

1. `PLAN.md` — M8 entry (line ~218), M10 entry (line ~266). Skim the rest.
2. `SPEC.md` §9 step 8 — "DNG — predictor 3 + CFA tags + opcode list parser". §A appendix has fixture recipes.
3. `CODE_MINIMAP.md` — high-level map of the codebase. Section on `predictors.zig` is the M5 anchor you'll extend in M8.
4. `src/predictors.zig` — applyInverse currently handles Predictor=1 (none) and Predictor=2 (horizontal, 8-bit). M8 adds Predictor=3 (FP byte-plane interleaved) per TIFF Tech Note 3, and 16-bit support for Predictor=2.
5. `docs/superpowers/specs/2026-05-04-tiffz-api-design.md` — the frozen API design. Stable.

---

## M8 (DNG raw) — concrete scope

### What ships at M8

DNG is a TIFF/EP-flavored container for camera raw. Three deliverables:

1. **Predictor=3 (Floating-point) inverse** — TIFF Tech Note 3, byte-plane
   interleaved differencing. Used by DNG HDR variants and high-end scanners.
   Adds 16-bit + 32-bit precision paths to `applyInverse` in
   `src/predictors.zig`. (Currently 8-bit only.)

2. **Predictor=2 16-bit path** — Predictor=2 (horizontal) already works for
   8-bit; 16-bit is deferred from M5 ("16-bit needed for DNG raw and
   high-end scanner content"). Needs file-endian-aware u16 reads with the
   horizontal-differencing math wrapping mod 2^16.

3. **CFA tags + opcode list parser** — DNG specific:
   - `CFAPattern` (33422) — Bayer / X-Trans / etc. mosaic pattern.
     Stored as 1-byte values: 0=red, 1=green, 2=blue. tiffz returns the
     pattern; downstream consumers (validate, demosaic pipelines) act on it.
   - `CFARepeatPatternDim` (33421) — pattern dimensions (usually 2×2 for
     Bayer, 6×6 for X-Trans).
   - `OpcodeList1/2/3` (51008/51009/51022) — Adobe's opcode bytecode for
     post-decode correction (lens distortion, vignette, dead pixel fixup,
     gain map). DNG spec §10 has the full opcode list (~30 ops). v1
     scope: PARSE the opcode list (don't apply the ops). Surface them as
     a structured `OpcodeList` for downstream validators. The "parse"
     part is straightforward — big-endian u32 fields. Application is
     out of scope for M8.

### What's already in place

- **Lossless JPEG decode** is already wired via jpegz Phase 1 (M1.4 +
  M1.4b shipped in jpegz). For DNG raws stored as Compression=7 with
  SOF3 (lossless JPEG), our M9.5 code path
  (`src/compressions/jpeg.zig`) already routes them through
  `jpegz.internal.wrapperDecode`, which handles SOF3 + 1..16-bit
  precision. So **you do NOT need new JPEG codec work for DNG raw**.
  Just make sure the raw bits flow through: a DNG fixture with
  Compression=7 + photometric=CFA (32803 — see below).

- **CFA photometric (32803)** is a new photometric value — add to
  `src/tags.zig` as `photometric_cfa = 32803`. Decoder doesn't need to
  "expand" CFA to RGB (that's a demosaic step, separately layered);
  tiffz just returns the raw CFA bytes and the consumer demosaics.
  But you DO need to make `photometrics.expandRowsToRgba` produce
  *something* for the fixture tests — easiest is "pass-through gray"
  for CFA: emit each CFA byte as gray RGBA. That's not pretty but
  it's defensible for v1; document as "demosaic in M11/M12" if
  pretty-output is needed later.

### Test fixtures

DNG fixtures are tricky because Adobe DNG Converter isn't Nix-packageable
(per SPEC.md §A "Real-world / acquired fixtures"). Options:

1. **Synthetic DNG** via libtiff's `raw2tiff` + manual IFD edits via
   `exiftool` (in the dev shell already). For predictor=3 specifically,
   generate a 16x16 FP TIFF directly via Python + tifffile (Python is
   discouraged per CLAUDE.md but it's the most surgical here) OR via
   `gdal_translate` with `-of GTiff -co PREDICTOR=3 -ot Float32`. Both
   should be available in the dev shell.
2. **Real DNG samples** from a public corpus. Adobe's own DNG
   reference samples (CC0): `https://helpx.adobe.com/photoshop/digital-negative.html`.
   Pick a small one (under 1 MB if possible to keep the repo
   reasonable), commit it, hash-pin the .rgba oracle.
3. **GDAL-synthesized DNG** — `gdal_translate -of DNG -co PREDICTOR=3 ...`.
   Easiest if it works.

Try (3) first. Fall back to (1) if needed.

### TDD order

1. Write a failing fixture test that decodes a 16x16 Predictor=3 FP
   TIFF and asserts against a hand-derived expected output (small
   enough to compute by hand: 4x4 image, FP32 values picked so
   byte-plane diffs are obvious). Fixture not yet committed; commit
   once test exists.
2. Make `predictors.applyInverse` handle `.float_point` predictor with
   FP32 byte-plane interleaved differencing (TN3 algorithm: bytes are
   interleaved by component byte position, then horizontal differencing
   applies per-byte-plane, then byte-planes are de-interleaved at the
   end).
3. Add Predictor=2 16-bit path (same horizontal differencing math but
   with u16 reads — needs the endian context from `dec.endian`).
4. Add CFA / opcode list tag parsers + a tiny opcode list fixture test
   (synthetic DNG with one known opcode entry).
5. Document the demosaic deferral.

Per portfolio convention: failing test FIRST, watch it fail, then
implement, then watch pass. Don't skip the failure verification — see
CLAUDE.md "TDD Discipline (Critical for AI Agents)".

---

## M10 (validate integration) — concrete scope

### What ships at M10

Validate currently uses zigimg for TIFF parsing. Replace that with
tiffz, and surface tiffz-specific findings into validate's report
schema.

Three deliverables:

1. **Coordinate with validate** via the LLMsend skill (in
   `~/.claude/skills/LLMsend/SKILL.md`; auto-loaded). Validate has been
   *actively waiting* on this per Peter's 2026-05-07 note. Drop a
   markdown note in `../validate/inbox/` with:
   - The current tiffz commit hash for `build.zig.zon` dep pinning
     (`git+https://github.com/pmarreck/tiffz#<hash>`).
   - The hash to use (you'll need to do the `--fetch=all` dance: set
     `.hash = ""` in their build.zig.zon, run `zig build`, get the
     printed correct hash, install).
   - Pointer to the public API surface in `src/lib.zig`.
   - The findings mapping doc (see #3 below).

2. **C ABI export** — tiffz already has a C FFI scaffolded
   (`src/ffi.zig` + `include/tiffz.h`) but only `tiffz_version` is
   exported. Validate might use the Zig module directly via
   `b.dependency("tiffz", .{}).module("tiffz")` — confirm during
   coordination. If C FFI is needed too, expand it; if Zig-module is
   sufficient (Validate is a Zig project), don't bother yet.

3. **Findings mapping table** — Validate has a routing taxonomy:
   each finding gets classified as one of `info | warning | malformation`
   plus a routing target (some are `error_code`s, some are
   informational signals). Ship `docs/tiffz_findings_mapping.md`
   modeled exactly on jpegz's
   `2026-05-06-jpegz-mapping-table.md` (find it in validate's inbox
   archive). The format Peter wants:
   - Routing taxonomy table at the top: `FindingCode | Severity | Routes-To`.
   - Short prose section on info vs warning vs malformation distinction.
   - Ready-to-paste `mapping.zig` snippet with a `RoutedFinding`
     `union(enum)`. Validate drops it verbatim into
     `src/core/tiffz_shim.zig`.

   Initial INFO finding set to seed the mapping (already approved by
   Peter; see PLAN.md M10 entry):
   - `bigtiff_format` (M7-gated — already implemented)
   - `multi_ifd_chain` (DNG, multi-page faxes)
   - `old_style_lzw_codes` (LZW Malformed-fallback fired)
   - `pre_multiplied_alpha` (ExtraSamples=1; covers `strike.tif`,
     resolves the M4-B "skipped fixture" follow-up)
   - `predictor_applied = N` (M5-gated)
   - `geotiff_tags_present` (M11-gated, can be placeholder)

The mapping table is the substantive deliverable; the LLMsend ping
is the trigger.

### Coordination order

1. Read jpegz's mapping table (validate's inbox archive) for format.
   It's in `../validate/inbox/processed/` or thereabouts — grep for
   "mapping" or "jpegz".
2. Draft `docs/tiffz_findings_mapping.md`.
3. Ship the mapping + commit + push to make tiffz consumable.
4. LLMsend ping validate's session with the dep URL + commit hash +
   mapping doc path. Validate's session is in a tmux session named
   `validate` per portfolio convention.

---

## Important technical context (so you don't relearn the hard way)

### jpegz integration is via `wrapperDecode`, not regular `decode`

`src/compressions/jpeg.zig` calls `jpegz.internal.wrapperDecode`
explicitly. **Don't switch back to plain `jpegz.decode`** — its
cleanroom dispatch (B0 baseline + progressive + lossless cleanroom)
has small byte-divergences from libjpeg-turbo on the RGB-marked
baseline + spliced abbreviated streams we get from TIFF
compression=7. When jpegz Phase 2 reaches byte-parity, you can flip
to plain `jpegz.decode` — that's a one-line swap. There's a
coordination note already sitting in jpegz's inbox dated 2026-05-16
flagging this.

For DNG raw (SOF3 lossless), `wrapperDecode` also handles 1..16-bit
precision (per jpegz M1.4b). No new JPEG work needed for M8.

### BigTIFF is runtime-branched, not comptime

The `OffsetWidth` enum is a runtime field on `Ifd`; we evaluated
comptime monomorphization and rejected it (IFD parser isn't a hot
path; comptime split would double the binary footprint). If you're
tempted to revisit, the rationale is in M7's commit message and
PLAN.md.

DNG often uses BigTIFF for large raws — your test fixtures should
include at least one BigTIFF-DNG combo to confirm the M7+M8 stacking
works.

### Flake.nix uses pkgsStatic on Linux, regular pkgs on Darwin

Today (2026-05-16) we got bitten hard by Zig 0.16's host-ABI
detection failing in Garnix's Linux sandbox. The fix that landed:

- Linux Garnix cross-compiles to `x86_64-linux-musl` (static).
- `pkgsStatic.{libjpeg, openjpeg, zlib}` provide musl-compatible C
  libs.
- The flake's `jpegPkgs` attrset selects pkgsStatic on Linux, regular
  pkgs on macOS — see `flake.nix` lines ~45-55.

If you add a new C dep (e.g. for M11 LERC/ZSTD), follow the same
pattern: add a `pkgsStatic.X` for the Linux branch.

### zigDepsHash bumping

When you change `build.zig.zon` (add/remove deps, bump versions),
update the hash:

1. Set `zigDepsHash = pkgs.lib.fakeHash` in flake.nix.
2. Run `nix build .#packages.aarch64-darwin.default 2>&1 | grep "got:"`.
3. Paste the printed hash back.

### jj/git workflow gotcha

Today we ended up force-pushing the same logical jj revision multiple
times because `jj describe -m "..."` keeps editing the @ revision in
place instead of creating new commits. **Use `jj new` BEFORE editing
files** when you want a fresh commit; otherwise you'll keep amending
the previous one and the bookmark sideways-pushes will look like
force-pushes to anyone watching origin.

Pattern:
```bash
# Finish current commit
jj describe -m "..."
jj bookmark move yolo --to @
jj git push --bookmark yolo

# NEW work — start a fresh revision
jj new
# edit files...
jj describe -m "new commit msg"
jj bookmark move yolo --to @
jj git push --bookmark yolo
```

### cli_test allocator-free bug

`tests/cli/cli_test.zig:cliPath` had a latent bug where it returned a
`[:0]u8` cast to `[]const u8`, and the caller's `allocator.free(cli)`
failed with "Invalid free" because the slice length was short by 1
byte vs the original allocation (the sentinel). Fixed to use
`allocator.dupe(u8, "zig-out/bin/tiffz")`. If you write more CLI tests,
follow the same pattern.

### LLMsend skill is auto-loaded

`~/.claude/skills/LLMsend/SKILL.md` is the inter-LLM messaging skill.
For M10 coordination with validate, that's how you reach the validate
session. Read the skill once; the protocol is:
1. Write a markdown note to `../validate/inbox/<date>-<topic>.md`.
2. tmux send-keys to ping validate's session — uses kitty CSI u (`\e[13u`)
   to submit the message to validate's prompt.

Validate's tmux session is named `validate`. Confirm it's running
with `tmux list-sessions | grep validate` before pinging.

---

## How to start

1. `cd /Users/pmarreck/Documents-CloudManaged/tiffz`
2. `./test` to confirm 117/117 tests still green from a fresh shell.
3. Read PLAN.md M8 + M10 entries.
4. Skim `src/predictors.zig` — M5 anchor that grows for M8.
5. Read `SPEC.md` §9 step 8 + §A DNG fixture recipes.
6. Run `dirtree` for repo overview.
7. Run `codescan status` — if it's indexed and watching, prefer
   codescan over Grep/Glob for navigation (per CLAUDE.md).
8. Start TDD: failing test for Predictor=3 → implement → green.

When stuck on DNG fixture generation, ask Peter — he may have real
DNG samples on `/Volumes/Fileserver/Pictures/` or similar (per
validate's prior reproducer pointers in PLAN.md "Real-world
reproducer pointers" section).

---

## Quick reference: tip of yolo

```
b48ec295 fix(flake): restore Linux musl target with pkgsStatic C deps
f4c15e93 M7 + M9.5: BigTIFF + JPEG-in-TIFF (Compression=7), with CI fixes
e3764b6a zig 0.16 upgrade
c00df2ba M6: Tile-based layout
```

Garnix all-green at `b48ec295`.

Good luck. Remember the back of the cabinet.
