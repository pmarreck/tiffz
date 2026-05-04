# tiffz — Code Minimap

A topographical overview of every important file in this repo and what
lives inside it. Updated as code lands. Scan this before grepping.

---

## Documentation (top-level)

| File | Purpose |
|---|---|
| `README.md` | One-screen project pitch, status, license. |
| `SPEC.md` | The complete starting specification: mission, brainstorm questions (now resolved — see API design doc), coverage gap matrix, spec sources, architecture sketch, milestones, fixture-generation recipes (Appendix B). |
| `LICENSING_NOTES.md` | License compatibility matrix. tiffz is MIT; libtiff/zigimg/Pillow/Go x/image are MIT/BSD-compatible reference reads. GPL'd TIFF code: AVOID. |
| `PLAN.md` | Living checklist of work items + milestones. The session-by-session source of truth. |
| `CODE_MINIMAP.md` | This file. |
| `LICENSE` | MIT. |
| `flake.nix` | Nix dev shell with Zig + libtiff + imagemagick + gdal + netpbm + vips + exiftool + hyperfine. `packages.default` and `checks.test` will be added in task #5 once `build.zig` exists. |
| `.envrc` | direnv: `use flake` + adds `zig-out/bin` to PATH. |
| `.gitignore` | Excludes the `inbox/` directory (incoming LLM messages, not project state) and Obsidian-vault doc symlinks (jj_cheatsheet, ZIG_RECENT_API_CHANGES, ZIG_0.15_TO_0.16_MIGRATION). |

## Symlinks (not committed)

| Path | Target |
|---|---|
| `AGENTS.md` | `~/Documents-CloudManaged/Obsidian Vaults/Peter Marreck/AGENTS_concise.md.md` |
| `CLAUDE.md` | same as above |
| `jj_cheatsheet.md` | `~/dotfiles/docs/jj_reference/jj_cheatsheet.md` |
| `ZIG_RECENT_API_CHANGES.md` | Obsidian vault |
| `ZIG_0.15_TO_0.16_MIGRATION.md` | Obsidian vault |

## docs/

| Path | Purpose |
|---|---|
| `docs/superpowers/specs/2026-05-04-tiffz-api-design.md` | **The frozen public API design.** Five resolved questions: access patterns (all four A/B/C/D first-class on a seekable `Source`), allocation strategy (α — threaded `Allocator` + `Workspace` + caller-supplied `dest`), error model (β — 1:1 stable C enum generated from Zig at build time), JPEG-in-TIFF (deferred to M9.5), forward-only adapter + `Limits` struct. |

## inbox/ (gitignored — incoming messages from sibling LLMs)

| File | From / Topic |
|---|---|
| `inbox/2026-05-04-from-validate-handoff.md` | Initial handoff from validate. Why tiffz exists, what's in flight on the zigimg fork (PRs #321/#322), the marquee reproducer file. |
| `inbox/2026-05-04-api-shape-response-from-validate.md` | validate's answer to the access-patterns question (Q1 in brainstorming): all four first-class, seekable `Source` foundation, layered API sketch, C FFI shape, Decoder pre-resolved decisions. |

---

## Source tree (current — M2 skeleton)

```
build.zig                    Zig build script: static lib + C CLI + unit + CLI tests
build.zig.zon                Project manifest (no deps yet)
build                        Driver script: nix build → zig-out/bin/
test                         Driver script: nix build .#checks.<sys>.test
include/
  tiffz.h                    Public C header (currently exports tiffz_version only;
                             stable tiffz_status_t enum will be build-generated in
                             a later milestone per design doc §7)
src/
  lib.zig                    Module root + re-exports + comptime{_=ffi} for symbol
                             emission + refAllDecls test runner
  errors.zig                 Canonical Error set (append-only, ordered by
                             introduction; will drive build-time C enum gen)
  limits.zig                 Limits struct + .default for resource-exhaustion /
                             decompression-bomb defense
  source.zig                 Source vtable type (read_at + size); concrete adapters
                             (fromBuffer / fromMmap / fromFile / fromBufferedReader)
                             land in M3+
  workspace.zig              Per-call codec scratch holder (skeleton; populates as
                             compression schemes land in M4+)
  decoder.zig                Public Decoder primitive (open / openWithLimits / deinit
                             / ifdCount); open is M2 stub — wires real header
                             parsing in M3
  version.zig                Single-source-of-truth version string
  ffi.zig                    C FFI exports — tiffz_version() proves the FFI roundtrip;
                             rest of the surface lands alongside its M3+ impl
cli/
  main.c                     C CLI (--version / --about / --help). Dogfoods the
                             C FFI per project convention.
tests/
  cli/cli_test.zig           Spawns zig-out/bin/tiffz, asserts stdout/stderr/exit code
                             for the four CLI surfaces (version/about/help/unknown)
audit/
  coverage_matrix.tsv        Empirical TIFF variant matrix from real-world corpus
  AUDIT_SUMMARY.md           Analysis + gap insights for fixture generation per milestone
tools/
  audit_corpus.sh            Generates coverage_matrix.tsv from a TIFF corpus

# Source tree (planned shape for later milestones)
src/
  ifd.zig                    IFD parsing (tag dict + lazy values)        [M3]
  bigtiff.zig                Comptime offset-width abstraction (u32/u64) [M7]
  compressions/
    uncompressed.zig                                                     [M3]
    packbits.zig / lzw.zig / deflate.zig                                 [M4]
    ccitt_t4.zig / ccitt_t6.zig                                          [M4]
    jpeg.zig                 (wraps sibling jpegz)                       [M9.5]
  predictors.zig             None / Horizontal / Floating-point          [M5]
  photometrics.zig           RGB / palette / CMYK / YCbCr / Lab          [M9]
  convenience.zig            validateAll / decodeStreaming / decodeAll
include/
  tiffz_errno.h              Generated by build.zig (stable C enum)      [later]
tests/
  fixtures/                  Generated + acquired TIFFs (SPEC §B)
  abi/error_codes.snapshot.txt  CI guard against accidental enum reordering
```
