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

## Why 100% is not reachable

TIFF stores no checksum of its own. In an uncompressed strip or tile,
every byte value is a legal sample, so a flipped sample bit yields a
slightly different image that is still a valid TIFF. No validator can
detect it, because the damaged file is indistinguishable from a file
that was written that way.

To measure this independently of tiffz, the campaign maps each seed with
libtiff's `tiffdump` and records the byte ranges of uncompressed strip
and tile data (IFDs with Compression 1). A case whose changed bytes all
fall inside those ranges is **free**: undetectable in principle.

- `ceiling = (decisive - free) / decisive` is the known upper bound on
  the detection rate.
- `open_rate` is detections among the cases that are not free.
- `false_alarm` counts detections of free cases. tiffz rejected a valid
  file. The gate requires zero.

The ceiling is an upper bound, not the true maximum. Only one
undetectable class is mapped. Others exist and are not yet counted:

- unconstrained tag values, such as XResolution, DateTime or Software
  text;
- bytes no IFD references;
- for compressed data, damage that still decodes to a valid stream of
  the right length (below).

So a reported compressed ceiling of 1.0 means "no undetectable case was
identified", not "every case is detectable".

## Uncompressed and compressed seeds differ

Seeds are reported in two classes because their ceilings differ by an
order of magnitude. A seed is uncompressed when every IFD has
Compression 1, and compressed otherwise. Ten seeds are uncompressed
(including BigTIFF, tiled, GeoTIFF, YCbCr, CMYK and 16-bit RGB) and nine
are compressed.

In an uncompressed seed, most bytes are raw samples. The minisblack seed
is 23,707 sample bytes out of 24,001. Only structural bytes (header,
IFDs, tag values) can carry detectable damage.

In a compressed seed, a change to the compressed stream usually breaks
the code structure, the decoded length or an integrity check. How close
the true ceiling comes to 100% depends on the codec:

| codec | integrity check | effect on the ceiling |
|---|---|---|
| Deflate (8, 32946) | zlib Adler-32 trailer (RFC 1950), verified when tiffz inflates | almost every change to the stream is detectable |
| LERC (34887) | Fletcher-32 over the blob, verified by lercz (`Lerc2.cpp`) | almost every change to the blob is detectable |
| Zstd (50000) | optional frame content checksum; the seed's frame has none (descriptor 0x60) | detectable only when decoding fails or the length changes |
| LZW (5), PackBits (32773), CCITT G3/G4 (3, 4), JPEG (7) | none | a change that still decodes to the right amount of data is undetectable |

## Measured on 2026-10-23

corruption-reader 0.8.0 (a7ea995), master 42, 385 decisive trials per
profile, tiffz at the commit that added this gate. No false alarms.

| profile | class | decisive | detect | free | ceiling | rate | open_rate |
|---|---|---|---|---|---|---|---|
| sniper | uncompressed | 186 | 11 | 156 | 0.161 | 0.059 | 0.367 |
| sniper | compressed | 199 | 109 | 0 | ≤1.000 | 0.548 | 0.548 |
| bolter | uncompressed | 185 | 9 | 162 | 0.124 | 0.049 | 0.391 |
| bolter | compressed | 200 | 143 | 0 | ≤1.000 | 0.715 | 0.715 |
| shotgun | uncompressed | 183 | 14 | 160 | 0.126 | 0.077 | 0.609 |
| shotgun | compressed | 202 | 162 | 0 | ≤1.000 | 0.802 | 0.802 |
| nuke | uncompressed | 187 | 84 | 103 | 0.449 | 0.449 | 1.000 |
| nuke | compressed | 198 | 198 | 0 | ≤1.000 | 1.000 | 1.000 |

Across both classes, the overall rates are 0.312 (sniper), 0.395
(bolter), 0.457 (shotgun) and 0.732 (nuke). Those blend the two
populations and say little on their own.

The uncompressed `open_rate` for small damage (37% to 61%) is the
fraction of structural hits tiffz catches. Some of the misses land in
unconstrained tag values and are undetectable as well, so that rate
understates tiffz relative to the unmapped true ceiling.

## Changing the floors

Raise a floor when detection improves. Lower one only deliberately, and
say in the commit why tiffz now accepts those cases, for example a
deviation reclassified as tolerated. A floors file must name every
profile and class pair.
