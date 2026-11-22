# In-process corruption exploration

The owner ruled on 2026-11-05: "corruption_reader is a library; a good corpus is an unlimited, reproducible bad corpus with nothing written to disk". `tests/explore/explore_test.zig` does this:
1. corruption_reader draws a case from a seed held in memory.
2. Its positional `PlanView` backs a `tiffz.Source`.
3. tiffz validates that source through the same calls the CLI makes (`Decoder.open`, the finding callback, `scanFindings`, `validateAllStripsAndTiles`).
4. The outcome is classified as `./corruption-coverage` classifies a subprocess run of `tiffz validate`:
   - exit 1 is a detection;
   - exit 4 is reach;
   - at exit 0, a finding set other than code 16 that differs from the seed's is a detection;
   - code 16 alone differing is reach;
   - otherwise the case is an accept.

## Wiring

corruption_reader is a private repository and tiffz is public, so the reader is not in `build.zig.zon`. A dependency there would break every outside consumer's `zig build --fetch=all`. Instead, `build.zig` takes `-Dcorruption-reader-src=DIR`, and only with it defines the `explore` step. The flake passes its pinned `corruption-reader` input, the same revision the floors file records. Plain `zig build` neither needs the reader nor fetches it. `checks.test` and `checks.explore-parity` share one derivation helper (`mkZigCheck`), so their ReleaseSafe floor and codec flags cannot drift.

## The parity gate

`checks.explore-parity`, run by `./test` and CI, replays the pinned floors plan in-process:
- the master and seeds come from `tests/corruption_coverage_floors`;
- batch k of each profile draws `per` cases from seed k mod N at round k * per.

The test must detect exactly the pinned case set. The floors were written by the subprocess harness (corruption-reader CLI, temp files, `tiffz validate --json`), so they are an oracle independent of this driver.

First run: 799 detected in-process, 799 pinned, 0 lost, 0 new.

Controls:
- treating an open failure as an accept loses 109 pinned cases;
- reading the unmutated source through the view loses all 799, which shows the view's corrupt bytes are what tiffz reads;
- the classification and master-seed parsing have unit tests.

## Exploring

`nix run .#explore -- --master M [--profile P] [--first-round R] [--rounds N] [--floors PATH]`, from the repository root, runs the `tiffz-explore` executable (`tests/explore/main.zig`, built ReleaseSafe like the tests). It runs profile P (harness names; `shotgun` maps to `shotgun_variable`; default shotgun) over the seeds the floors file lists, using seed round mod N. It prints one `case PROFILE SEED ROUND OUTCOME` line per case, tab-separated, then a summary. The driver it shares with the parity test is `tests/explore/driver.zig`. Before 2026-11-22 this mode was a test behind `-Dexplore-master` and needed the dev shell.

The explore-parity derivation also builds the executable, so `packages.explore` and `apps.explore` cost no second compile. It then runs two checks:
- a smoke run: 20 case lines, the summary, and exit 2 on a usage error;
- `tests/explore/exe-floors-check.sh`, an independent control. A floors file listing only seed k makes every round use seed k, so rounds k*per to k*per+per-1 are exactly floors batch k. The executable's detections there must equal the pinned cases the subprocess harness wrote. The check uses seeds 5 (PackBits) and 6 (Zstd), which have mixed outcomes in all four profiles. First run: all eight profile and seed pairs match.

A crash ends the process. The last `case` line names the case, which becomes a fixed replay in `tests/fixture_test.zig`.

False alarms still come from the subprocess harness: telling "free" cases (every changed byte an uncompressed sample) from the rest needs libtiff's layout of the seed, which the harness has and this driver does not.

## Out of scope

- Pattern-zone profiles with xor masks can simulate field-level writer bugs (type, count, value, a tag renamed to a private ID) for KNOWN_DEFECT exemplars and near-match controls. That is the next step, using the same driver with custom profile text through `Loader.loadText`.
- Structural rewrites (adding or dropping entries, reordering) stay out of scope. They need a plugin system or a tiffz-side rewrite pass, which is the owner's call.
