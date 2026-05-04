# tiffz — starting specification

**Status:** greenfield. No code yet. This document is the briefing
package for the next agent to start implementation.

**Read first:** `AGENTS.md` / `CLAUDE.md` (symlink to Peter's vault) for
project-wide conventions. Then `LICENSING_NOTES.md` for the
licensing notes (TIFF is freely implementable; libtiff and zigimg
are MIT/BSD-compatible reference reads).

---

## 0. Mission

Pure-Zig, spec-driven, complete TIFF reader (and eventually writer)
that reaches **byte-complete** validation coverage of the TIFF 6.0
specification and the major modern extensions. Pro photographers are a
primary downstream customer; "we can't validate this variant" is not
an acceptable steady state.

This project exists because the per-bug incremental approach in
`zigimg` (and the `pmarreck/zigimg` fork) cannot close the matrix in
reasonable time. Tiffz is the focused, completeness-as-success-criterion
alternative.

---

## 1. Use the brainstorming skill BEFORE writing code

The first thing to do is **NOT to start implementing.** It is to invoke
the `superpowers:brainstorming` skill and explore:

- Should the public Zig API present an `Image` (decoded into memory) or
  a `Reader` (lazy/streaming)? The README says we want both. How do
  they share code without one being a wrapper-with-overhead of the
  other?
- Where does the IFD tree live in memory? Lazy-loaded (parse only the
  tag dict; values fetched on demand) vs eager (parse everything up
  front)?
- How do tile- and strip-based layouts share the decode path? They
  share most of the post-decode pipeline but differ at the byte-source
  layer.
- BigTIFF vs classic TIFF — how do we abstract the offset width
  (32-bit vs 64-bit) without paying for it on every classic-TIFF read?
- JPEG-in-TIFF — do we vendor a Zig JPEG decoder, depend on a sibling
  one, or call out via FFI to one of validate's existing decoders?
- Streaming-mode constraints. Pro photographers' multi-GB TIFFs must
  validate with bounded RAM. What does the streaming reader look like?
  Does the API force the caller to opt into streaming, or do we always
  stream and the "all at once" mode is just a thin convenience wrapper?

Brainstorm those before any code. The answers shape the type system,
not just the impl. Then `superpowers:writing-plans`, then code.

---

## 2. Coverage matrix — the audit step

Before any code is written, build a **coverage matrix** of what zigimg
does today. This is the diagnostic baseline that tells us what tiffz
needs to handle differently.

**Corpus to gather:**
- A handful of DNGs from different camera makes (Canon, Nikon, Sony,
  Fuji, Panasonic — Adobe DNG Converter's reference outputs are the
  cleanest).
- Pro scanner outputs (Phase One IIQ-as-TIFF, Hasselblad 3FR if
  reachable).
- BigTIFF samples — search GitHub for `*.btf` / `*.tf8` test files;
  libtiff's test corpus has some.
- GIS tiled TIFFs — USGS or NASA Earth data. Public domain.
- Adobe Photoshop CMYK proof TIFFs.
- The known reproducer `/Volumes/Fileserver/Pictures/scan from pete's book.tif`
  (CCITT G4, 11059×15671, currently drifts in zigimg fork after row 1030).
- Validate's existing `ground_truth_examples/tiff/` and
  `ground_truth_examples/dng/` directories.
- Any TIFFs from Peter's own photography workflow (tell him the path
  and he'll cherry-pick a representative sample).

**Per-file emit:** dimensions, compression, photometric interpretation,
BitsPerSample, SamplesPerPixel, predictor, planar config,
strip-vs-tile, RowsPerStrip / TileWidth / TileLength, ICC profile
present, ExifIFD present, GeoTIFF tags present, BigTIFF or classic.
Plus zigimg's outcome on each (OK / structural-only / error variant).

**Output:** `audit/coverage_matrix.tsv` showing rows = files, columns =
the variant axes + zigimg's verdict. This is the spec for what tiffz
must support to subsume zigimg's TIFF surface and beyond.

---

## 3. The TIFF coverage gap (current zigimg + fork)

**What zigimg supports today:**
- Uncompressed (RGB / gray / etc.) — works after the recent agent
  patches.
- PackBits compression.
- CCITT RLE (T.4 1D mode 0).
- LZW.
- ZLib Deflate.

**What's missing or partial:**

| Variant | Status | Notes |
|---|---|---|
| CCITT Group 4 (T.6) | Partial — drifts after row 1030 on real fax scans | `pmarreck/zigimg` PR #321 (DRAFT) has pair-step refactor; residual edge case open |
| JPEG-in-TIFF (compression=7) | Missing | Need a JPEG decoder; possibly reuse validate's |
| BigTIFF (64-bit offsets) | Missing | TIFF magic `0x002B` (vs `0x002A`) — different IFD pointer width throughout |
| Predictor mode 2 (Horizontal) | Unclear / probably partial | Important for DNG |
| Predictor mode 3 (Floating-point) | Missing | DNG HDR uses this |
| 16-bit-per-sample | Unclear | High-end scanners (Phase One, Hasselblad) emit this |
| 32-bit float per sample | Missing | Scientific imaging, HDR |
| CMYK photometric (separated) | Unclear | Photoshop proof workflow |
| YCbCr photometric | Unclear | Some JPEG-in-TIFF flavors |
| CIE L\*a\*b\* photometric | Missing | Color-managed pro workflows |
| Tiled TIFF (vs strip-based) | Missing / partial | GIS / large-image overwhelmingly tiled |
| Multi-image (multi-IFD) | Unclear | Multi-page TIFF (faxes), DNG embedded thumbnails |
| LERC compression | Missing | Modern; ESRI |
| ZSTD-in-TIFF | Missing | Modern |
| JPEG2000-in-TIFF (compression=34712) | Missing | Rare |
| OJPEG (old-style JPEG, compression=6) | Probably skip | Deprecated and ambiguous; libtiff treats as best-effort |
| TIFF/EP | Missing | Pro photography metadata extension |
| DNG | Missing | Adobe Digital Negative — CFA pattern tags, opcode lists |
| GeoTIFF | Missing | GIS coordinate-system tags (separate IFD) |
| ICC profile parsing | Validate not parse | Just pass-through; consumers parse |
| EXIF sub-IFD | Validate not parse | Same |

The matrix audit (§2) refines this list with empirical data. The list
above is the starting hypothesis.

---

## 4. Specification sources (use these as primary authority)

**Implementation discipline:** these documents are the primary
authority for the implementation. libtiff source is permitted as a
reference for ambiguity resolution (BSD-3, MIT-compatible) but is
NOT the primary source — reading the spec carefully is the path to
spec-conformance, not bug-for-bug compatibility with libtiff. See
`LICENSING_NOTES.md` for the full attribution rules.

- **TIFF 6.0** (Adobe, 1992) — `https://download.osgeo.org/libtiff/doc/TIFF6.pdf`
  is a public mirror of the Adobe spec PDF. The original Adobe page is
  a frequent 404 candidate; mirror via osgeo.org or the Internet
  Archive Wayback Machine if needed.
- **TIFF Technical Notes** (TTN1, TTN2) — Adobe addenda for
  JPEG-in-TIFF and PackBits clarifications.
- **BigTIFF** — `https://www.awaresystems.be/imaging/tiff/bigtiff.html`
  is the canonical spec mirror. Original was at `bigtiff.org` (now
  defunct).
- **TIFF/EP (ISO 12234-2)** — paywalled by ISO. Free pre-publication
  drafts exist; cite them with care.
- **DNG specification 1.7** — Adobe, freely available at
  `https://helpx.adobe.com/camera-raw/digital-negative.html`. Cleanroom-safe.
- **GeoTIFF 1.1 (OGC standard)** — `https://docs.ogc.org/is/19-008r4/19-008r4.html`. OGC, freely available.
- **CCITT recommendations:** T.4 (Group 3) and T.6 (Group 4) from the
  ITU-T site — `https://www.itu.int/rec/T-REC-T.4` and `T-REC-T.6`.
  Both freely downloadable. This is THE spec source for the fax codecs.
- **LZW algorithm** — patent expired in 2003; original Welch 1984 paper
  ("A Technique for High-Performance Data Compression," IEEE Computer)
  is the canonical reference. PDF's LZWDecode quirks (EarlyChange
  semantics) are documented in the PDF 1.7 spec.

**Reference reads (permitted, MIT/BSD-compatible):**
- **libtiff source** (BSD-3) for ambiguity resolution. If a spec passage
  is unclear, libtiff is the de-facto canonical reference. Cite in a
  source-comment when an algorithm shape was clarified by libtiff.
- **zigimg's `src/formats/tiff.zig`** (MIT, including the
  `pmarreck/zigimg` fork) — the prior art whose limits motivated this
  project. Useful as a "what was attempted, where it drifted" pointer.

**Verification oracles (binary-only):** libtiff binaries (`tiffinfo`,
`tiff2rgba`, `tiffcp`, `tiffdump`) and ImageMagick (`identify`,
`convert`). Run on inputs, compare decoded bytes. The standard way to
say "we agree with the reference."

**Avoid (GPL contamination risk):** GPL'd TIFF code (some pre-libtiff
and niche tools). GPL contamination is unrecoverable for an MIT project.

---

## 5. Licensing notes (short summary)

TIFF is a freely implementable file format. There is no patent, no
restrictive license, no legal barrier. Adobe published TIFF 6.0
freely in 1992; ITU publishes T.4/T.6 freely; LZW patent expired in
2003; DNG ships with explicit Adobe patent grants.

- **libtiff** — BSD-3, MIT-compatible. OK to read; cite if any
  algorithm shape is adapted.
- **zigimg** — MIT, compatible. Same rule.
- **Spec text** — copyrighted, freely distributable. Implement from,
  don't transcribe verbatim beyond fair-use snippets.
- **GPL'd TIFF code** — avoid entirely.

See `LICENSING_NOTES.md` for the longer write-up including patent
landscape and a dependency-license matrix.

---

## 6. Architecture (Peter's stack convention)

Pure Zig core + C FFI + C CLI:

```
src/core/                  Pure Zig, no I/O
  decoder.zig              Public Zig API (Image, Reader)
  ifd.zig                  IFD parsing (tag dictionary, lazy values)
  compressions/            One file per scheme
    uncompressed.zig
    packbits.zig
    ccitt_t4.zig
    ccitt_t6.zig
    lzw.zig
    deflate.zig            (calls into existing zlib pure-Zig dep)
    jpeg.zig               (calls into a sibling JPEG decoder)
  predictors.zig
  photometrics.zig         (RGB / palette / CMYK / YCbCr / Lab conversions)
  bigtiff.zig              (offset-width abstraction)
ffi/
  c_api.zig                Exported C ABI
  tiffz_core.h             Hand-curated header
cli/
  main.c                   Dogfoods the C FFI
build.zig
build.zig.zon
flake.nix
```

Streaming mode = the core operates on `std.io.Reader` from the start;
the all-at-once mode is `Reader = std.io.fixedBufferStream(buf).reader()`
under the hood. Same code path, no duplication.

---

## 7. TDD discipline (mandatory)

Per project convention: every feature gets a failing test FIRST, then
the implementation. For tiffz specifically:

- **Per-variant test fixtures** — small, generated via libtiff's
  `tiffcp` from a tiny seed image (`magick -size 16x16 plasma: seed.tif`),
  one fixture per (compression, photometric, predictor, etc.) cell of
  the matrix. Each ≤ a few KB ideally.
- **Oracle assertions:** decoded output must match libtiff's
  `tiff2rgba` output byte-for-byte for the same fixture.
- **Real-world fixtures:** alongside the small synthetic ones, embed a
  handful of real-world TIFFs from the audit corpus (where licensing
  allows) for "this surfaces that edge case" regression coverage.
- **No `swallow the symptom` catches.** A decoder that catches its own
  overflow and silently produces wrong bytes is worse than a decoder
  that hard-errors. If you find yourself writing `... catch ...` to
  paper over a misalignment, stop and find the real bug. (See the
  prior G4 work in `pmarreck/zigimg` for the cautionary tale.)

---

## 8. Streaming vs all-at-once API sketch

(Brainstorm before fixing this; sketch only.)

```zig
// All-at-once — convenience, internally a fixedBufferStream wrapper.
pub fn decodeFromBuffer(allocator: Allocator, data: []const u8) !Image;

// Streaming — bounded RAM, suitable for multi-GB TIFFs.
pub fn decodeStreaming(
    allocator: Allocator,
    reader: anytype,         // std.io.Reader-shaped
    on_strip: *const fn (strip_idx: u32, decoded: []const u8) anyerror!void,
) !ImageMetadata;

// Validation-only path — used by `validate`. No pixel materialization.
pub fn validateStreaming(
    allocator: Allocator,
    reader: anytype,
) !ValidationReport;
```

The `validate` consumer almost certainly wants `validateStreaming` —
no pixel buffer, just a report ("file is structurally valid; all
strips decoded; CRC where applicable matched"). The image-tool
consumer wants `decodeStreaming` with the callback. The convenience
function wraps either.

---

## 9. Initial milestones (rough)

1. **Audit + spec freeze** (no code). Produce `audit/coverage_matrix.tsv`,
   freeze the SPEC.md and the API sketch via brainstorming.
2. **Skeleton** — repo bootstrap, `build.zig`, `flake.nix`, hello-world
   FFI, CI. Match `z7z` / `bzip2z` patterns.
3. **Classic TIFF, uncompressed.** Parse magic, IFD, strip-based
   uncompressed read. RGB + gray + palette photometrics.
4. **Compressions, in order:** PackBits → LZW → ZLib Deflate → CCITT
   T.4 → CCITT T.6 → JPEG-in-TIFF.
5. **Predictors** (None / Horizontal / Floating-point).
6. **Tile-based layout.** Refactor strip path to share with tile path.
7. **BigTIFF** — offset-width abstraction.
8. **DNG** — predictor 3 + CFA tags + opcode list parser.
9. **Pro photometrics** — CMYK, YCbCr, CIE Lab.
10. **Validate integration.** Replace zigimg dep in validate's TIFF
    deep-validation path with tiffz. Run validate against the audit
    corpus; confirm all formerly-WARN files now OK.
11. **GeoTIFF, TIFF/EP** as needed.
12. **Modern compressions** (LERC, ZSTD-in-TIFF) as needed.

Ship at each milestone. CI from milestone 2.

---

## 10. Known issues to inherit / avoid

- **`writeBits catch` swallow** in zigimg fork's T.6 decoder — masks an
  overflow that should surface as a hard error. Tiffz must not have
  defensive catches that mask incorrect output.
- **`calRowByteSize` off-by-one** for non-multiple-of-8 widths in
  zigimg — fixed via PR #322 (ceiling division). Tiffz must use
  ceiling division everywhere widths-to-bytes are computed.
- **CCITT G4 b1 reference cursor** — pair-step model (as in libtiff's
  `tif_fax3.c`) is the correct shape, BUT the prior fork agent's
  pair-step impl still drifts after row 1030 on complex real-world
  scans. Investigate `pass-mode cursor advancement` and `end-of-row
  reference-line termination` carefully. Section 4 of CCITT T.6 has
  the canonical algorithm.

---

## 11. Where things live

- This repo: `~/Documents-CloudManaged/tiffz/`
- Audit corpus working dir: `~/Documents-CloudManaged/tiffz/audit/`
- Sibling reference implementations (read-only — DO NOT copy code):
  - `~/Documents-CloudManaged/zigimg/` — Peter's zigimg fork (if
    cloned locally).
  - libtiff binaries via `nix shell nixpkgs#libtiff`.
  - ImageMagick via `nix shell nixpkgs#imagemagick`.
- Reference TIFFs:
  - `/Volumes/Fileserver/Pictures/` — Peter's personal scan archive.
  - `~/Documents-CloudManaged/validate/ground_truth_examples/tiff/`
    and `.../dng/`.

---

## 12. Reporting back

When the next agent makes meaningful progress, drop a status note in:
- `~/Documents-CloudManaged/validate/inbox/` so the validate LLM sees
  it (validate is the primary downstream consumer waiting on tiffz).

When tiffz hits milestone 10 (validate integration), validate's TIFF
WARN tier should empty out, and `pmarreck/zigimg` PR #321 (the partial
G4) can be closed (or repurposed as a different fix). The
`calRowByteSize` PR #322 stays — that's a separate latent bug
unrelated to tiffz.

---

## Appendix A — Toolchain (flake.nix + Garnix)

This project follows the project-stack convention: **all build-time and
fixture-generation tooling is controlled by `flake.nix` and verified
via Garnix CI** (the org-wide GitHub App is already installed, so
`packages.*` and `checks.*` from `flake.nix` will auto-evaluate on
every push). No system-installed tool dependencies; if it's needed, it
goes in `flake.nix`.

Tools to include in the dev shell:

```nix
# flake.nix devShell sketch (illustrative)
nativeBuildInputs = [
  zig                       # core build
  libtiff                   # tiffcp, tiffinfo, tiff2rgba, tiffmedian, raw2tiff, tiffdump
  imagemagick               # most flexible variant generator
  gdal                      # LERC, ZSTD-in-TIFF, JPEG2000, GeoTIFF, tiled
  netpbm                    # pnmtotiff / pamtotiff (lighter path for 1-bit)
  vips                      # alternative TIFF writer for cross-checking
  exiftool                  # TIFF/EP and DNG metadata inspection / injection
  hyperfine                 # benchmarking (per project convention)
];
```

Adobe DNG Converter is the one tool that can't be Nix-packaged (Adobe
binary, no source). For DNG fixtures the next agent should either:
(a) use real-camera DNG samples from public corpora (Adobe's own
sample set, RawTherapee's test images), or
(b) write a small "DNG synthesis" helper in tiffz itself once the
write path matures, validating output against Adobe DNG Converter as
oracle.

## Appendix B — Fixture generation recipes

Add `tools/gen_fixtures.sh` early in milestone 1. The script generates
one fixture per cell of the variant matrix. All fixtures must be:

- **Small** (≤ 16 KB each ideally; a 32×32 or 64×64 seed is enough)
- **Deterministic** (same seed → same output bytes; commit to repo
  rather than regenerate per build)
- **Regenerable** (the script is the source of truth; the committed
  files are cached outputs)

### Seed generation

```bash
# Pseudo-random 32x32 RGB seed (deterministic via -seed)
magick -seed 0 -size 32x32 plasma: tests/fixtures/_seed_rgb.tif

# 1-bit text seed for fax codecs
magick -size 64x64 -gravity center -font Courier label:"FAX" \
  -monochrome tests/fixtures/_seed_mono.tif

# Floating-point seed for predictor 3
magick -size 32x32 plasma: -depth 32 -define quantum:format=floating-point \
  tests/fixtures/_seed_float.tif
```

### Compression cells (libtiff `tiffcp`)

```bash
SEED=tests/fixtures/_seed_rgb.tif
SEED_MONO=tests/fixtures/_seed_mono.tif
OUT=tests/fixtures/compression

tiffcp -c none      "$SEED"      "$OUT/uncompressed.tif"
tiffcp -c packbits  "$SEED"      "$OUT/packbits.tif"
tiffcp -c lzw       "$SEED"      "$OUT/lzw.tif"
tiffcp -c jpeg      "$SEED"      "$OUT/jpeg.tif"
tiffcp -c zip       "$SEED"      "$OUT/deflate.tif"
tiffcp -c g3:1d     "$SEED_MONO" "$OUT/ccitt_g3_1d.tif"
tiffcp -c g3:2d     "$SEED_MONO" "$OUT/ccitt_g3_2d.tif"
tiffcp -c g4        "$SEED_MONO" "$OUT/ccitt_g4.tif"
```

### Predictor cells

```bash
# Predictor 1 = none (baseline; just tiffcp without -p)
tiffcp -c lzw          "$SEED" tests/fixtures/predictor/none_lzw.tif
tiffcp -c lzw -p 2     "$SEED" tests/fixtures/predictor/horizontal_lzw.tif
tiffcp -c zip -p 2     "$SEED" tests/fixtures/predictor/horizontal_zip.tif

# Predictor 3 (floating-point) — needs GDAL
gdal_translate -of GTiff -co COMPRESS=DEFLATE -co PREDICTOR=3 \
  tests/fixtures/_seed_float.tif tests/fixtures/predictor/floating_point.tif
```

### Bit depth + photometric cells (ImageMagick)

```bash
# 16-bit per sample (high-end scanners)
magick "$SEED" -depth 16 tests/fixtures/depth/rgb_16bit.tif

# 32-bit float per sample (HDR / scientific)
magick "$SEED" -depth 32 -define quantum:format=floating-point \
  tests/fixtures/depth/rgb_32bit_float.tif

# Photometrics
magick "$SEED" -colorspace Gray   tests/fixtures/photometric/gray.tif
magick "$SEED" -colorspace CMYK   tests/fixtures/photometric/cmyk.tif
magick "$SEED" -colorspace Lab    tests/fixtures/photometric/lab.tif
magick "$SEED" -colorspace YCbCr  tests/fixtures/photometric/ycbcr.tif
magick "$SEED" -type Palette      tests/fixtures/photometric/palette.tif
```

### Layout cells

```bash
# Tiled (the GIS norm)
gdal_translate -of GTiff -co TILED=YES -co BLOCKXSIZE=16 -co BLOCKYSIZE=16 \
  "$SEED" tests/fixtures/layout/tiled_16x16.tif

# Multi-IFD (multi-page)
tiffcp "$SEED" "$SEED_MONO" tests/fixtures/layout/multipage.tif
```

### BigTIFF cells

```bash
# Force BigTIFF (64-bit offsets) on a tiny image
tiffcp -8 "$SEED" tests/fixtures/bigtiff/classic_to_big.tif

# Or via GDAL
gdal_translate -of GTiff -co BIGTIFF=YES "$SEED" \
  tests/fixtures/bigtiff/gdal_big.tif
```

### Modern compression cells (GDAL only)

```bash
gdal_translate -of GTiff -co COMPRESS=ZSTD "$SEED" \
  tests/fixtures/modern/zstd.tif
gdal_translate -of GTiff -co COMPRESS=LERC "$SEED" \
  tests/fixtures/modern/lerc.tif
gdal_translate -of GTiff -co COMPRESS=LERC_DEFLATE "$SEED" \
  tests/fixtures/modern/lerc_deflate.tif
gdal_translate -of GTiff -co COMPRESS=LERC_ZSTD "$SEED" \
  tests/fixtures/modern/lerc_zstd.tif
# JPEG2000-in-TIFF is rare; skip unless GDAL build has openjpeg
```

### GeoTIFF cells

```bash
# A small GeoTIFF with EPSG:4326 (WGS 84)
gdal_translate -of GTiff -a_srs EPSG:4326 -a_ullr -180 90 180 -90 \
  "$SEED" tests/fixtures/geo/wgs84.tif

# UTM zone 33N
gdal_translate -of GTiff -a_srs EPSG:32633 \
  "$SEED" tests/fixtures/geo/utm_33n.tif
```

### Real-world / acquired fixtures (NOT generated)

- `tests/fixtures/real/scan_pete_book.tif` — symlink or copy from
  `/Volumes/Fileserver/Pictures/scan from pete's book.tif` (CCITT G4
  reproducer). Check Peter's permission to ship.
- `tests/fixtures/real/dng/*` — Adobe DNG Converter samples + a few
  cherry-picks from RawTherapee's public test images.
- `tests/fixtures/real/bigtiff/*` — sample BigTIFF files from
  libtiff's own test corpus (BSD-licensed; attribute).
- `tests/fixtures/real/scientific/*` — public-domain TIFF imagery
  from USGS / NASA / similar.

### Oracle assertions

For each generated fixture, the test asserts:
1. tiffz reads it without error.
2. Decoded pixel buffer matches `tiff2rgba`'s reference output
   byte-for-byte.

```bash
# Reference pixel decode
tiff2rgba tests/fixtures/compression/lzw.tif /tmp/lzw_ref.rgba

# Test asserts decodeFromBuffer(tiff_bytes).pixels == /tmp/lzw_ref.rgba bytes
```

### Garnix CI integration

```nix
# flake.nix
checks.<system>.fixture_generation = pkgs.stdenv.mkDerivation {
  name = "tiffz-fixture-generation-test";
  src = ./.;
  nativeBuildInputs = [ libtiff imagemagick gdal netpbm ];
  buildPhase = "bash tools/gen_fixtures.sh";
  installPhase = "mkdir -p $out && cp -r tests/fixtures/* $out/";
};
```

This makes Garnix verify that fixture generation is reproducible
across hosts. If the next agent commits regenerated fixtures and
Garnix produces different bytes, that's a Nix nondeterminism flag
worth chasing.

---

Good luck. The right answer is "no, we still don't have a complete
TIFF decoder" right up until tiffz reaches milestone 10. Don't
shortcut.
