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

`shotgun_variable` is the draw whose width varies. The fixed `shotgun` profile is the 16-bit case. The in-tree `shotgun()` helper flips whole bytes at random offsets. It is not either profile.

tiffz `validate` exits 0 for ok, 1 for invalid, 3 for I/O, and 4 for limited. The JSON word is `ok`, `invalid`, or `limited`.

Score one case, the pair (profile, master, round, file), as follows:

- corruption-reader exit 2 is a harness failure.
- A report `noop`, or corruption-reader exit 3, is not a trial. `shotgun` on a file shorter than 32 bytes is `too_small` for every seed.
- tiffz exit 0 is an accept. A finding that does not fail validation is not a detection.
- tiffz exit 1 is a detection.
- tiffz exit 4 is reach. It is neither a detection nor a miss.
- A signal is a robustness failure, counted apart from the detection rate.

The unmutated seed, or the `identity` profile, must exit 0. A decoder that rejects every buffer fails that control and cannot post a detection rate.

An uncompressed sample byte is still legal TIFF. A sniper, bolter, shotgun, or nuke that lands there can leave a valid file. That accept is not a miss against the spec. The strict detection set is damage to a field the spec requires. The in-tree fuzz already checks three of those directly: the byte-order marker, the version magic, and a first-IFD offset past EOF.

One worked pipe, on the ReleaseFast binary of `d3295f9a` (sha256 `1b904345008517af23840f3c5ab1e3a093818b3010bcaa208a3b0b3027e84382`), not on current HEAD. Seed `tests/fixtures/uncompressed/minisblack-1c-8b.tiff`, 24001 bytes, master 42. The unmutated file was ok. Sniper round 0, bolter round 0, `shotgun_variable` round 0, and nuke rounds 0 through 2 were applied and stayed ok. The `header` profile was applied and came back invalid, error 2, with no IFD opened. `apply --case` reproduced nuke item 0 byte for byte.

A sandboxed `./test` cannot see the executable until this repo pins commit `21ee639` as a flake input. An unzoned detection rate is a report, not a failing gate, until someone chooses a threshold for a named zone.
