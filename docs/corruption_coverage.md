# Corruption detection coverage

`./corruption-coverage` measures how often `tiffz validate` notices damage
to a known-good TIFF. `./test` runs it as a gate through the Nix check
`checks.<system>.corruption-coverage`, against the floors in
`tests/corruption_coverage_floors`.

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
build give the same counts, so the gate compares exact detection counts
against floors.

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

## Measured on 2026-10-28

corruption-reader 0.8.0 (a7ea995), master 42, 385 decisive trials per
profile, tiffz 627f74ff, libtiff 4.7.2. No false alarms.

| profile | class | decisive | detect | free | clean | ceiling | ceiling_est | rate | stricter |
|---|---|---|---|---|---|---|---|---|---|
| sniper | uncompressed | 186 | 11 | 156 | 14 | 0.161 | 0.086 | 0.059 | 1 |
| sniper | unchecked | 146 | 63 | 0 | 93 | ≤1.000 | 0.363 | 0.432 | 11 |
| sniper | checksummed | 53 | 46 | 0 | 6 | ≤1.000 | 0.887 | 0.868 | 0 |
| bolter | uncompressed | 185 | 9 | 162 | 11 | 0.124 | 0.065 | 0.049 | 0 |
| bolter | unchecked | 147 | 91 | 0 | 71 | ≤1.000 | 0.517 | 0.619 | 15 |
| bolter | checksummed | 53 | 52 | 0 | 0 | ≤1.000 | 1.000 | 0.981 | 0 |
| shotgun | uncompressed | 183 | 14 | 160 | 9 | 0.126 | 0.077 | 0.077 | 0 |
| shotgun | unchecked | 143 | 104 | 0 | 58 | ≤1.000 | 0.594 | 0.727 | 19 |
| shotgun | checksummed | 59 | 58 | 0 | 1 | ≤1.000 | 0.983 | 0.983 | 0 |
| nuke | uncompressed | 187 | 84 | 103 | 0 | 0.449 | 0.449 | 0.449 | 0 |
| nuke | unchecked | 147 | 147 | 0 | 0 | ≤1.000 | 1.000 | 1.000 | 0 |
| nuke | checksummed | 51 | 51 | 0 | 0 | ≤1.000 | 1.000 | 1.000 | 0 |

The two ceilings, as estimated:

| profile | worst case (uncompressed) | best case (checksummed) |
|---|---|---|
| sniper (1 bit) | 0.086 (bound 0.161) | 0.887 |
| bolter (1 byte) | 0.065 (bound 0.124) | 1.000 |
| shotgun (8 to 16 bits) | 0.077 (bound 0.126) | 0.983 |
| nuke (4096 bytes) | 0.449 | 1.000 |

The unchecked class lands in between, and how far depends on the codec.
For a single bit, libtiff decoded 93 of 146 unchecked cases without
complaint, so damage to LZW, PackBits, CCITT or JPEG data is far from
reliably detectable. tiffz detects more of those cases than libtiff
does (rate 0.432 against an estimate of 0.363), which shows how low
that estimate runs.

For small damage, tiffz misses some open cases: 6 of 16 single-bit
uncompressed cases, 3 of 12 single-byte ones and 1 of 47 single-bit
checksummed ones. These are candidates for better detection.

Across all classes, the overall rates are 0.312 (sniper), 0.395
(bolter), 0.457 (shotgun) and 0.732 (nuke). They mix populations whose
ceilings differ by an order of magnitude, so they say little on their own.

## Changing the floors

Raise a floor when detection improves. Lower one only deliberately, and
say in the commit why tiffz now accepts those cases, for example a
deviation reclassified as tolerated. A floors file must name every
profile and class pair (uncompressed, unchecked, checksummed).
