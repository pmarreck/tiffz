# Corruption detection coverage

`./corruption-coverage` measures how often `tiffz validate` notices damage
to a known-good TIFF. `./test` runs it as a gate through the Nix check
`checks.<system>.corruption-coverage`, against the exact set of detected
cases pinned in `tests/corruption_coverage_floors` (see "The case set").

## The campaign

corruption-reader (a sibling project, pinned as a flake input) draws
deterministic mutations of the 19 known-good seeds listed in
`tests/fuzz/fuzz.zig`:

| profile | damage |
|---|---|
| sniper | 1 flipped bit |
| bolter | 1 byte XORed with 0xFF |
| shotgun | 8 to 16 distinct bits in one 32-byte window |
| nuke | a 4096-byte overwrite |

tiffz exit 1 is a detection. Exit 0 counts as a detection only when a
finding other than code 16 differs from the unmutated seed. Each profile
collects 385 decisive trials, enough for a 95% Wilson interval no wider
than ±5 points. Every seed must validate first (specificity), and a
crash or timeout is counted apart and fails the run.

The same master seed, trial count, corruption-reader version and tiffz
build give the same cases and the same outcomes, so the gate compares
the exact set of detected cases.

## Two ceilings: worst case and best case

A TIFF can store the same image with no integrity protection at all or
with a checksum over every strip, so no single "maximum detectable
corruption" figure describes the format. The campaign reports two
ceilings per profile:

- **Worst case**: uncompressed data. TIFF stores no checksum of its
  own, and in an uncompressed strip every byte value is a legal sample.
  A flipped sample bit yields a slightly different image that is still a
  valid TIFF, indistinguishable from a file written that way.
- **Best case**: checksummed codecs. Deflate carries zlib's Adler-32
  trailer (RFC 1950) and LERC a Fletcher-32 over the blob (verified by
  lercz, after `Lerc2.cpp`). Almost any change to the stream breaks the
  check. What remains undetectable lies outside the stream: tag values
  nothing constrains, and bytes no IFD references.

Between them sits a third class, **unchecked**: LZW, PackBits, CCITT
G3/G4, JPEG and Zstd without a content checksum (the Zstd seed's frame
descriptor is 0x00, flag clear). Damage there often breaks the code
structure or the decoded length, but a change that still decodes to the
right amount of data is undetectable.

Each seed takes the class of the codec holding most of its strip and
tile bytes, and a tie takes the weaker class. Nine seeds are uncompressed
(including BigTIFF, tiled, GeoTIFF, YCbCr, CMYK and 16-bit RGB), seven are
unchecked and three are checksummed. The checksummed class rests on
three seeds (two Deflate, one LERC), so it is the least sampled.

## Bounding each case independently of tiffz

Every case is classed by oracles that do not involve tiffz:

| bound | rule | meaning |
|---|---|---|
| free | every changed byte lies in uncompressed strip or tile data (libtiff `tiffdump` maps it) | provably undetectable: the file is a valid TIFF |
| clean | libtiff `tiffinfo -D` reads every directory and strip with exactly the seed's diagnostics, and every Deflate stream the change touches still inflates with a matching Adler-32 (`pigz -dc`) | probably undetectable |
| open | anything else, including a change of length | detectable as far as these oracles know |

pigz is there because libtiff does not verify Adler-32. It stops
inflating once it has the bytes it asked for and never reads the
trailer. In a probe on 2026-10-28, 5 of 40 single-bit flips in a Deflate
strip read cleanly through libtiff, and pigz rejected a flipped trailer
byte with "adler32 mismatch". LERC needs no second tool, since libtiff's
LERC codec verifies the Fletcher-32 itself. No seed uses a checksummed
Zstd frame. The campaign refuses one until a Zstd oracle exists, rather
than class it without one.

Per profile and class:

- `ceiling = (decisive - free) / decisive` is an upper bound on the
  detection rate. For compressed classes no case is provably free, so
  this bound is 1.0 and says nothing; read `ceiling_est` instead.
- `ceiling_est = (decisive - free - clean) / decisive` estimates the
  true ceiling. libtiff is lenient, so some clean cases are detectable
  (`stricter` counts those tiffz catches), and the estimate errs low by
  at least `stricter / decisive`. libtiff can also complain about a
  file that is legal, which would push the estimate high. The baseline
  comparison removes complaints the seed already raises.
- `open_rate` is detections among open cases.
- `false_alarm` counts detections of free cases, which means tiffz
  rejected a valid file. The gate requires zero.
- `stricter` counts detections of clean cases. These are not failures:
  tiffz caught something libtiff accepts.

## Measured on 2026-11-05

corruption-reader 0.8.0 (a7ea995), master 42, at least 385 decisive
trials per profile over the fixed draw plan (19 batches of 21 cases per
profile, one per seed), tiffz with findings 17 and 18 (IFD-entry rules)
and the Compression and PhotometricInterpretation value sets, libtiff
4.7.2. No false alarms. Only the checksummed rows differ from
2026-11-04. The old plan cut its last batch short, and the last seed is
the checksummed `predictor3_deflate_fp32.tif`. The fixed plan draws all
21 of its cases, and tiffz detects every one ("Re-set on 2026-11-05").

| profile | class | decisive | detect | free | clean | ceiling | ceiling_est | rate | stricter |
|---|---|---|---|---|---|---|---|---|---|
| sniper | uncompressed | 187 | 19 | 156 | 14 | 0.166 | 0.091 | 0.102 | 2 |
| sniper | unchecked | 146 | 64 | 0 | 93 | ≤1.000 | 0.363 | 0.438 | 11 |
| sniper | checksummed | 63 | 57 | 0 | 6 | ≤1.000 | 0.905 | 0.905 | 0 |
| bolter | uncompressed | 185 | 12 | 162 | 11 | 0.124 | 0.065 | 0.065 | 0 |
| bolter | unchecked | 147 | 91 | 0 | 71 | ≤1.000 | 0.517 | 0.619 | 15 |
| bolter | checksummed | 62 | 62 | 0 | 0 | ≤1.000 | 1.000 | 1.000 | 0 |
| shotgun | uncompressed | 183 | 14 | 160 | 9 | 0.126 | 0.077 | 0.077 | 0 |
| shotgun | unchecked | 143 | 104 | 0 | 58 | ≤1.000 | 0.594 | 0.727 | 19 |
| shotgun | checksummed | 61 | 60 | 0 | 1 | ≤1.000 | 0.984 | 0.984 | 0 |
| nuke | uncompressed | 187 | 84 | 103 | 0 | 0.449 | 0.449 | 0.449 | 0 |
| nuke | unchecked | 147 | 147 | 0 | 0 | ≤1.000 | 1.000 | 1.000 | 0 |
| nuke | checksummed | 63 | 63 | 0 | 0 | ≤1.000 | 1.000 | 1.000 | 0 |

The two ceilings, as estimated:

| profile | worst case (uncompressed) | best case (checksummed) |
|---|---|---|
| sniper (1 bit) | 0.091 (bound 0.166) | 0.905 |
| bolter (1 byte) | 0.065 (bound 0.124) | 1.000 |
| shotgun (8 to 16 bits) | 0.077 (bound 0.126) | 0.984 |
| nuke (4096 bytes) | 0.449 | 1.000 |

The unchecked class lands in between, and how far depends on the codec.
For a single bit, libtiff decoded 93 of 146 unchecked cases without
complaint, so damage to LZW, PackBits, CCITT or JPEG data is far from
reliably detectable. tiffz detects more of those cases than libtiff
does (rate 0.438 against an estimate of 0.363), which shows how low
that estimate runs.

tiffz now detects every open case (`open_rate` 1.000 in every class).
Before findings 17 and 18 it missed twelve: single-byte faults in IFD
entries, such as a corrupted tag ID or an out-of-range Orientation, that
libtiff warns about and tiffz decoded around without saying so. validate
ruled them corrupt (2026-11-03). They are kept as regressions in
`tests/fixture_test.zig` and listed in
`docs/plan_context/ifd_fault_cases.md`. tiffz's sniper uncompressed rate
(0.102) now exceeds that class's ceiling estimate (0.091) because it
also catches two cases libtiff accepts (`stricter` 2). One is a
PhotometricInterpretation of 1026, which no claimed specification
defines.

Across all classes, the overall rates are 0.354 (sniper), 0.419
(bolter), 0.460 (shotgun) and 0.741 (nuke). They mix populations whose
ceilings differ by an order of magnitude, so they say little on their own.

## The case set

`tests/corruption_coverage_floors` pins every detected case as profile,
seed and round. A count floor cannot tell a lost case from a lost case
offset by a gain. The exact set can, and it names the case to replay
(validate, 2026-11-05).

**The draw plan never depends on an outcome.** Batch k of a profile
draws 21 cases (the trial count over the corpus size, rounded up) from
seed k mod 19 at round 21k. The file pins the number of batches per
profile. The old plan drew `min(21, cases still needed)` per batch, so a
case that changed between reach, accept and detect moved every later
round. On 2026-11-04 that lowered the sniper checksummed floor from 47
to 46 with no detection lost.

**The file's identity.** It records the master seed, the trial count,
the corruption-reader version (without its platform suffix) and source
revision, its RNG and case derivation, a sha256 of each resolved
profile definition, and each seed's path and sha256. A seed and round
identify a case only under all of these. If any differs, the gate fails
with `case set stale: regenerate with --write-floors` and names the
changed lines. It draws nothing, so a changed generator never shows up
as hundreds of spurious losses.

**The gate.** It fails on:
- a pinned case that is no longer detected (`case lost`);
- a detected case that is not pinned (`case new`);
- a detected case whose changed bytes are all free (false alarm);
- a crash, or a profile short of 385 decisive trials.

Each profile and class also gets a `floor` line comparing detections
with the pinned count. When a loss is offset by a gain, the counts still
match and only the case lines show it.

**Changing the set.** Only the tool writes the file:

```
nix run .#corruption-floors
```

This runs `./corruption-coverage --write-floors` with the tools the check
uses. It draws batches until each profile has 385 decisive trials. It
prints every case added and removed, and the old and new count per
profile and class, then rewrites the file sorted. It refuses to write on
a crash, a false alarm or a short profile. Commit the result with that
output. A removed case is a lost detection: say in the commit why tiffz
now accepts it, for example a deviation reclassified as tolerated. A
generator or corpus change regenerates the whole set; give the old and
new per-cell counts in the commit.

## Re-set on 2026-11-05

The switch to the fixed draw plan re-set every cell once. The cases
drawn differ from the old plan's, so a changed cell is a different
sample, not a change in detection.

| profile | class | old floor | new pinned count | cause |
|---|---|---|---|---|
| sniper | uncompressed | 19 | 19 | |
| sniper | unchecked | 64 | 64 | |
| sniper | checksummed | 46 | 57 | +11: the last batch is full (10 of 21 cases drawn before) |
| bolter | uncompressed | 12 | 12 | |
| bolter | unchecked | 91 | 91 | |
| bolter | checksummed | 53 | 62 | +9: the last batch is full (12 of 21 before) |
| shotgun | uncompressed | 14 | 14 | |
| shotgun | unchecked | 104 | 104 | |
| shotgun | checksummed | 58 | 60 | +2: the last batch is full (19 of 21 before) |
| nuke | uncompressed | 84 | 84 | |
| nuke | unchecked | 147 | 147 | |
| nuke | checksummed | 51 | 63 | +12: the last batch is full (9 of 21 before) |

Every profile drew 19 batches, the same first 378 cases as before plus
the rest of the last seed's batch. tiffz detects all 21 cases of that
batch in every profile. No cell is lower. The file pins 777 cases.

Earlier count floors, kept from the old floors file:
- **2026-10-28:** set with corruption-reader 0.8.0 (a7ea995), at 385
  decisive trials per profile.
- **2026-11-03:** raised for findings 17 and 18 (IFD-entry rules):
  sniper +6/+1/+1, bolter +3/+0/+1.
- **2026-11-04:** changed for the Compression and
  PhotometricInterpretation value sets. Sniper uncompressed went from
  17 to 19: the new rules caught PhotometricInterpretation 1026 in
  `rgb16.tif` and Compression 16385 in `gray16_geotiff.tif`. Sniper
  checksummed went from 47 to 46, because sniper reached its trials one
  draw sooner and the last checksummed case
  (`predictor3_deflate_fp32.tif`, round 389, item 11 of the batch at
  round 378) was not drawn. That case is also replayed in
  `tests/fixture_test.zig`, and is in the set again.
