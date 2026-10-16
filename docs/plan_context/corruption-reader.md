# Corrupt-input checks through corruption-reader

The consumer contract is corruption_reader `docs/consumer_cli.md`, report version 1. The executable checked on 2026-10-15 was 0.7.0, commit `21ee639`, clean `origin/yolo`. A consumer runs that executable. It does not link the library.

```bash
set -o pipefail
corruption-reader corrupt PROFILE --master SEED --report report.jsonl SEED.tif \
  | tiffz validate --json - > verdict.json
```

`PIPESTATUS[0]` is corruption-reader. `PIPESTATUS[1]` is tiffz. Both programs use exit 3, for different facts, so a single `$?` after the pipe is the wrong number. `--master` is required in a test; without it the seed is random. `--count` above 1 needs `--emit tmp` or `--emit pb`. `corruption-reader apply --case RECORD INPUT` reproduces one reported case.

Profiles that match the shared names:

| Profile | What it changes |
|---|---|
| `sniper` | one bit |
| `bolter` | one byte, XOR `0xFF` |
| `shotgun` | 16 distinct bits inside a 32-byte window |
| `shotgun_variable` | 8 to 16 distinct bits in that window |
| `nuke` | a 4096-byte overwrite that must change bytes; a shorter file is replaced whole |
| `identity` | nothing; the specificity control |
| `header` | a clamped nuke inside the first 10 percent of the file |

`shotgun_variable` is the validate-mutation-v3 shotgun draw. The fixed profile named `shotgun` is the 16-bit case and is not what `./corruption-coverage` draws. The in-tree `denseByteFlip` helper flips whole bytes at random offsets. That helper is a dense overwrite, in the nuke class, and it is not either bit-window profile.

tiffz `validate` exits 0 for ok, 1 for invalid, 3 for I/O, and 4 for limited. The JSON word is `ok`, `invalid`, or `limited`.

Score one case, the pair (profile, master, round, file), as follows:

- corruption-reader exit 2 is a harness failure.
- A report `noop`, or corruption-reader exit 3, is not a trial. `shotgun` on a file shorter than 32 bytes is `too_small` for every seed.
- tiffz exit 1 is a detection.
- tiffz exit 0 is an accept when the non-reach finding set matches the unmutated seed. A finding other than code 16 that was not on that seed is a detection. Code 16 is unsupported compression, which is reach.
- tiffz exit 4, and a file whose only change is finding 16, are reach. Neither is a detection or a miss.
- A signal, or gtimeout status 124, is a crash. Crashes stay out of the rate.

The unmutated seed, or the `identity` profile, must exit 0. A decoder that rejects every buffer fails that control and cannot post a detection rate.

An uncompressed sample byte is still legal TIFF. A sniper, bolter, shotgun, or nuke that lands there can leave a valid file. That accept is not a miss against the spec. The strict detection set is damage to a field the spec requires. The in-tree fuzz already checks three of those directly: the byte-order marker, the version magic, and a first-IFD offset past EOF.

One worked pipe, on the ReleaseFast binary of `d3295f9a` (sha256 `1b904345008517af23840f3c5ab1e3a093818b3010bcaa208a3b0b3027e84382`), not on current HEAD. Seed `tests/fixtures/uncompressed/minisblack-1c-8b.tiff`, 24001 bytes, master 42. The unmutated file was ok. Sniper round 0, bolter round 0, `shotgun_variable` round 0, and nuke rounds 0 through 2 were applied and stayed ok. The `header` profile was applied and came back invalid, error 2, with no IFD opened. `apply --case` reproduced nuke item 0 byte for byte.

`./corruption-coverage` runs that score on the known-good corpus in `tests/fuzz/fuzz.zig`. The report line is `mutation_definition=validate-mutation-v3`. The four draws are sniper, bolter, shotgun, and nuke. Shotgun is corruption-reader profile `shotgun_variable` (8 to 16 distinct bits in one 32-byte window), not the fixed 16-bit profile named `shotgun`. The detection rate is detections divided by decisive trials, with a 95% Wilson interval. The default margin is 0.05. The run stops a profile once that interval's half-width is within the margin, or at the worst-case 385 decisive trials. `--trials N` collects N decisive trials instead. Exit 0 means every profile met the margin and no seed was rejected, no draw failed, and tiffz did not crash. The rate itself is not a pass/fail gate. Specificity prints each accepted seed's sha256 and byte count. `tests/cli/corruption_coverage_test` locks the arithmetic and the exit classes with fakes; it does not call the real tools.

A sandboxed `./test` does not run the campaign. The executable is resolved from `PATH`, then from a sibling `corruption_reader` binary. Commit `21ee639` is the 0.7.0 tree this contract was read against.

One earlier measurement, 2026-10-15, master 42, margin 0.05, is not validate-mutation-v3. It drew the fixed 16-bit `shotgun` profile and counted only exit 1 as a detection. corruption-reader 0.7.0. tiffz binary sha256 `e49f80bc933e516badcb84927345d69a2a4c9d0c360d24af69753d4904a7d4a4`, a ReleaseFast build with lercz still `a88c39b`. All 19 unmutated seeds were accepted. No crashes and no no-op draws.

| Profile | Decisive | Detected | Rate | 95% Wilson |
|---|---:|---:|---:|---|
| sniper | 340 | 112 | 0.329412 | 0.281603 to 0.381032 |
| bolter | 385 | 153 | 0.397403 | 0.349766 to 0.447066 |
| shotgun (fixed 16-bit, not MKTP) | 385 | 197 | 0.511688 | 0.461889 to 0.561257 |
| nuke | 335 | 251 | 0.749254 | 0.700190 to 0.792665 |

Reach cases were 2, 2, 14, and 7. They are not in the rates. These are unzoned rejection rates: a changed sample byte can still be a legal TIFF.

The validate-mutation-v3 measurement is 2026-10-15 23:59 EDT, master 42, margin 0.05, corruption-reader 0.7.0. ReleaseFast tiffz sha256 `f22fd10ca60ca99e9248d1a26b722605470596cebd37050fb2822aa027110a5b`. jpegz is `85455eb`. lercz stayed `a88c39b`. Specificity was 19 of 19. No crashes and no no-op draws. Shotgun draws were `shotgun_variable`. Exit 1 counts as a detection, and so does exit 0 when a finding other than code 16 differs from the unmutated seed. Finding 16 alone is reach.

| Profile | Decisive | Detected | Rate | 95% Wilson | Reach |
|---|---:|---:|---:|---|---:|
| sniper | 340 | 113 | 0.332353 | 0.284401 to 0.384051 | 2 |
| bolter | 385 | 153 | 0.397403 | 0.349766 to 0.447066 | 2 |
| shotgun (8 to 16 bits) | 385 | 183 | 0.475325 | 0.425931 to 0.525206 | 14 |
| nuke | 335 | 251 | 0.749254 | 0.700190 to 0.792665 | 7 |

Sniper detected 113, one more than the exit-1-only run. Bolter and nuke matched that run. The shotgun rate is the variable window. These remain unzoned rejection rates.
