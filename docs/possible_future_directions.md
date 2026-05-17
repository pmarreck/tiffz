# tiffz — possible future directions

Snapshot taken **2026-05-17** after M10 mapping doc + eager IFD
caching landed. tiffz now covers the SPEC §9 milestones M1–M10 plus
ZSTD-in-TIFF and streaming `Source.fromBufferedReader`. What follows
is an honest inventory of remaining coverage gaps and adjacent
improvements, ordered by likely impact on real-world workflows.

This isn't a commitment to ship any of these. It's a written-down
list so the next session (human or AI) doesn't have to rediscover
what's missing.

---

## Coverage gaps — known formats / variants

### 1. 16-bit-per-sample Palette / CFA / YCbCr / Lab

**What:** `expandRowsToRgba` currently accepts `bits_per_sample`
∈ {1, 8, 16} but the 16-bit path is wired only for **RGB / Gray /
CMYK**. Palette and CFA stay 8-bit because 16-bit palette is rare
(needs a 65536-entry ColorMap). YCbCr-16 and Lab-16 are niche
(scientific microscopy, some medical imaging).

**Cost:** Small. Each photometric arm needs the same
`sampleU8`-style indirection the 8/16 RGB/Gray/CMYK arms got. YCbCr-16
needs the BT.601 coefficients reapplied at u16; Lab-16 needs the TIFF
16-bit Lab encoding (L scaled to 0..65535 mapping to L*0..100,
a*/b* as signed 16-bit values) decoded before the existing Q24
matrix chain.

**Why it's deferred:** No current customer ask for these specific
combinations.

### 2. True u16 CMYK composition

**What:** 16-bit CMYK currently downscales each channel to u8 first,
then runs the 8-bit subtractive composition `(255-C)*(255-K)/255`.
A "true" u16 implementation would do `(65535-C)*(65535-K)/65535`,
then downscale once at the end.

**Cost:** Trivial — extend the existing CMYK arm with a
`bps==16` branch.

**Why it's deferred:** The precision difference is <1 LSB in the
8-bit RGB output. Real CMYK workflows want ICC-profile-aware
conversion anyway (see #3).

### 3. ICC-profile-aware CMYK / Lab

**What:** CMYK is device-dependent — the spec-correct conversion to
sRGB requires the file's embedded ICC profile (tag 34675). tiffz v1
emits the no-profile subtractive identity, which is the documented
fallback. ICC-aware decoding needs an embedded ICC engine
(little-cms / lcms2 is the obvious dep). Same story for Lab when a
profile is embedded.

**Cost:** Medium — adds a C-library dep (lcms2 or a Zig
reimplementation), wires ICC profile loading through the photometric
expansion path.

**Why it's deferred:** Casual CMYK consumers (e.g. previews) get
acceptable results from the no-profile path. Print-production
workflows that need byte-perfect ICC handling are a different tool
class.

### 4. photometric=9 (ICCLab)

**What:** A second CIELAB encoding from the TIFF Tech Note 3
extension: L* in 0..255 maps to L*0..100, **a/b also in 0..255**
(unsigned, biased by 128) rather than two's-complement signed.

**Cost:** Tiny — one more photometric arm that reuses the existing
Lab Q24 matrix chain with a different byte-decode step.

**Why it's deferred:** photometric=8 (the signed-byte form) is what
ImageMagick / libtiff write by default; ICCLab is rare outside ICC
v4 raw containers.

### 5. YCbCrSubSampling beyond 1:1

**What:** TIFF tag 530 lets the Cb/Cr planes be at half or quarter
resolution. Common in JPEG-in-TIFF (2:2 is libtiff's default for RGB
→ JPEG); not common in non-JPEG YCbCr-photometric files (most write
subsampling=1:1 since they'd lose quality otherwise). tiffz v1
hard-codes 1:1 for the non-JPEG case.

**Cost:** Medium — needs chroma upsampling at expansion time
(nearest-neighbour or bilinear). The JPEG-in-TIFF case already
works because libjpeg does the upsampling internally.

**Why it's deferred:** No customer fixture has surfaced.

### 6. planar=separate for tiled layout

**What:** `decodeStrippedSeparateIntoRgba` in fixture_test
demonstrates separate-planar strip decode. The tiled-layout
analogue (decode N tile-strips per band, interleave, expand)
isn't yet wired.

**Cost:** Small — mirror the strip path with `decodeTile` calls
and per-band tile counts.

**Why it's deferred:** No customer fixture (most separate-planar
TIFFs in the wild are strip-based).

### 7. Old-style LZW (libtiff pre-3.4) third variant

**What:** Some legacy files use a pre-emptive code-width-bump
heuristic that libtiff sniffs from the first few codestream bytes.
tiffz's LZW supports `new_style` (TIFF 6.0 spec) and `old_style`
(Sun/Adobe legacy LSB-first); the third variant is rare.

**Cost:** Small — add a variant detection pass + third
`Variant` enum member to `src/compressions/lzw.zig`.

**Why it's deferred:** Surfaced once (quad-lzw.tif from validate's
audit corpus); not blocking any current workflow.

### 8. LERC, LZMA-in-TIFF, WebP-in-TIFF, JPEG2000-in-TIFF

**What:** Modern compression schemes registered with the TIFF spec
but not widely shipped:

- **LERC** (Compression=34887 / 34925): Esri's Limited Error Raster
  Compression. Common in GIS workflows. No pure-Zig
  decoder exists; would need to wrap a C library.
- **LZMA** (Compression=34925): same code as LERC2 in some
  registrations; ambiguous. Realistically need to support both.
- **WebP** (Compression=50001 / 50002): rare. Needs libwebp.
- **JPEG2000** (Compression=33003 / 33005): handled via jpegz's
  openjpeg wrapper today for raw JP2 streams but tiffz doesn't
  dispatch to it from TIFF.

**Cost:** Medium per codec. Each needs an upstream C wrapper +
flake.nix entry + dispatch arm.

**Why it's deferred:** No customer ask for any of these. ZSTD
already covers the modern-compression use case that mattered.

### 9. GeoTIFF tags (M11)

**What:** TIFF/GeoTIFF tags (33550 ModelPixelScale, 33922
ModelTiepoint, 34264 ModelTransformation, 34735
GeoKeyDirectory, …) carry geospatial metadata. tiffz currently
decodes the pixel data of GeoTIFF files correctly (they're just
TIFFs with extra tags) but doesn't surface the geo-metadata in
typed form.

**Cost:** Medium — adds a `src/geotiff.zig` parser that walks the
GeoKeyDirectory and surfaces an `EpsgCode` / `AffineTransform` /
`ProjectionParameters` struct. Routes a `geotiff_tags_present`
INFO finding (already reserved in the M10 mapping doc).

**Why it's deferred:** Consumers who care about GeoTIFF (gdal et
al.) already use gdal directly. Validate could use it once it
ships.

### 10. TIFF/EP extension tags

**What:** TIFF/EP is the camera-raw foundation that DNG builds on;
it defines additional metadata tags (CFA layout details, sensor
calibration, lens metadata) that DNG inherits. tiffz parses the DNG
subset (CFA pattern, opcode list) but not the broader TIFF/EP
metadata.

**Cost:** Medium — most of the work is enumerating tags and writing
typed accessors; no algorithmic complexity. The opcode list
parser already lives in `src/dng.zig` and would extend naturally.

**Why it's deferred:** Validate is the primary consumer that would
benefit. Not blocking yet.

### 11. DNG opcode list semantic execution

**What:** tiffz parses the opcode list datastream into a structured
`OpcodeList` but doesn't execute the opcodes (gain map application,
dead-pixel fixup, lens correction, etc.). DNG spec §10 defines ~30
opcodes; semantic execution is involved.

**Cost:** Large — each opcode is a separate image-processing
operation, often with non-trivial state.

**Why it's deferred:** This is **explicitly out of scope by
design** — tiffz parses; downstream pipelines (raw developers, DNG
viewers, validators) execute. Documented in `src/dng.zig`.

---

## Adjacent improvements (not coverage gaps, but quality-of-life)

### A. `decodeStreaming` callback API

**What:** The API design doc (2026-05-04) sketches three convenience
APIs on top of the Decoder primitive: `validateStreaming`,
`decodeStreaming`, and `decodeAll`. None are implemented yet. The
streaming variant would call a user callback per decoded strip/tile
so the caller can write to disk / push to a pipeline without
allocating the entire image in memory.

**Cost:** Small. The Decoder.decodeStrip / decodeTile primitives
already exist; this is a thin wrapper that walks the IFD's
strip/tile arrays and invokes the callback.

**Why it's deferred:** Power users use the primitive directly;
the convenience wrapper would just dedupe the strip-walk loop in a
handful of places.

### B. `threads: u8` in `DecodeOptions`

**What:** The threading-control convention agreed in May 2026 with
validate + jpegz puts a `threads: u8 = 1` parameter on the
convenience APIs. Default 1 = sequential. 0 = caller-opted-in
auto-detect. Convenience APIs distribute strips/tiles across
threads. The primitive (Decoder.decodeStrip / decodeTile) stays
single-threaded by contract.

**Cost:** Medium — needs a `std.Thread.Pool`-backed dispatcher in
the convenience layer. The codecs themselves are already
single-strip-at-a-time so no per-codec changes are needed.

**Why it's deferred:** Single-threaded decode is fast enough for
the file sizes seen so far (largest fixture: 11059×15671 G4 scan,
decodes in seconds). Becomes relevant for batch-processing
workflows.

### C. JPEG-in-TIFF YCbCr fixture-test path through the public API

**What:** The current YCbCr JPEG-in-TIFF override lives in
`tests/fixture_test.zig`'s `decodeFixtureToRgba` helper. The
public API surface (`Decoder.decodeStrip` + `expandRowsToRgba`)
doesn't expose any equivalent — the caller has to know about the
quirk and override the photometric themselves. A cleaner shape
would expose an "effective photometric after codec decode" on the
Decoder so callers can route accordingly.

**Cost:** Small — extend the Decoder's per-strip metadata accessors
with a "photometric after decode" getter that returns RGB for
JPEG-YCbCr and the IFD value otherwise.

**Why it's deferred:** No external consumer is using the API
surface yet; the quirk has been documented in
`src/compressions/jpeg.zig` and the integration test demonstrates
the override pattern.

### D. Cleanroom-JPEG byte parity for Compression=7

**What:** `src/compressions/jpeg.zig` calls jpegz's
`wrapperDecode` (libjpeg-turbo path) rather than `jpegz.decode`
(cleanroom) because the cleanroom isn't byte-exact on RGB-marked
baseline + spliced abbreviated streams. When jpegz Phase 2 closes
that gap, tiffz can flip to plain `jpegz.decode` — a one-line swap
in `decode()`.

**Cost:** Trivial change in tiffz; substantial upstream work in
jpegz.

**Why it's deferred:** Tracked on jpegz's roadmap. No tiffz-side
blocking work.

### E. Memory-mapped Source

**What:** `Source.fromMmap` is referenced in the docstring's
thread-safety note but isn't yet implemented. Would be a thin
wrapper around `std.posix.mmap` / `MapViewOfFile`.

**Cost:** Small — modest amount of cross-platform handling for
the mmap call + a vtable entry. Source already has a
`read_at(buf, offset)` shape that maps trivially to a memcpy from
the mapped region.

**Why it's deferred:** `fromBuffer` covers the common case (load
file into RAM, then mmap is functionally equivalent for random
access). Would shave one alloc in workflows that read files anyway.

---

## Internals — would benefit from a refactor

### F. Eager IFD value caching could become an opt-in / size cap

**What:** `Ifd.parse` currently loads every out-of-line value at
parse time. For typical TIFFs that's fine — they have a dozen
small tag values. For pathological files (huge ICC profiles, JPEG
tables, XMP blocks), the parse-time allocation can be large. The
per-entry cap (`limits.max_tag_value_bytes`) bounds the worst
case, but a streaming consumer that doesn't care about the IFD's
out-of-line values still pays the cost.

**Cost:** Small — add a flag on `Limits` for "lazy values" mode
and skip the prefetch when set. The `arrayElementU64` /
`readEntryValueCached` paths already fall back to a Source read.

**Why it's deferred:** Eager is the right default for almost
every consumer; the lazy mode would only help very narrow
streaming-validate workflows.

### G. IFD-at-end + streaming source

**What:** Many TIFF writers (GraphicsMagick, ImageMagick, …) put
the IFD at the *end* of the file. For a streaming source this
means parsing the IFD requires either (a) buffering the whole
file (defeats streaming) or (b) doing a two-pass read with a
seekable underlying transport (e.g. HTTP range requests). Today
tiffz's `Source.fromBufferedReader` documents the limitation.

**Cost:** Medium — would need a two-phase Source-like protocol
that lets the consumer say "first give me the last N bytes" then
"now stream from offset 0". HTTP range requests fit naturally;
plain pipes don't.

**Why it's deferred:** Users with IFD-at-end files generally
have the whole file in memory anyway. The two-phase protocol
would need careful spec work first.

### H. IFD chain depth + per-IFD limits

**What:** `Limits` caps total IFD count but doesn't separately
limit IFD chain depth (`SubIFDs` tag) or recursion. DNG files
with embedded thumbnails + preview chains can be many IFDs deep;
malformed files could plausibly create cycles.

**Cost:** Small — add `max_subifd_depth` to Limits and propagate
through any future SubIFDs accessor.

**Why it's deferred:** The flat next-IFD chain limit covers most
real files; SubIFDs handling isn't yet implemented (tiffz only
walks the IFD0 chain at v1).

---

## Tooling / process improvements

### I. End-to-end fixture for Lab photometric

**What:** Lab unit tests only cover black/white endpoints. A
fixture-based test against a magick-generated Lab TIFF would pin
correctness across the gamut.

**Cost:** Small — generate fixture via magick, generate oracle
via `tiff2rgba`. The current Lab impl matches libtiff's behavior
(both use D50 → D65 Bradford → sRGB) so the oracle would line up.

**Why it's deferred:** Endpoint tests + the algorithmic
correctness inherited from the textbook Lab→XYZ→sRGB chain are
enough confidence for v1.

### J. Fuzzing harness

**What:** No `./fuzz` script yet. Codec inputs (LZW, Deflate, T.4,
T.6, ZSTD) are obvious fuzz targets — libtiff has a history of
codec-side CVEs and tiffz reimplemented several of those codecs
cleanroom.

**Cost:** Small per codec — write a Zig fuzz harness that feeds
random bytes to each `decode(src, dest)` entry point and asserts
no panics / no buffer overruns.

**Why it's deferred:** Sandboxed Nix tests + the existing oracle
fixtures cover the happy path. Fuzzing is the obvious next step
for security hardening.

---

## Status quick-reference

| Item | Realistic cost | Real-world demand | Notes |
|------|---------------|-------------------|-------|
| 16-bit Palette/CFA/YCbCr/Lab | S | Low | One arm each |
| True u16 CMYK | S | Low | Precision <1 LSB |
| ICC-aware CMYK/Lab | M | Medium | Needs lcms2 |
| photometric=9 | XS | Low | One arm |
| YCbCrSubSampling > 1:1 | M | Low | JPEG path already covers |
| planar=separate tiled | S | Low | Mirror strip helper |
| Old-style LZW v3 | S | Low | One file in corpus |
| LERC | M | Medium (GIS) | Needs lerc lib |
| LZMA-in-TIFF | M | Low | Niche |
| WebP-in-TIFF | M | Low | Needs libwebp |
| GeoTIFF tags | M | Medium (GIS) | M11 milestone |
| TIFF/EP tags | M | Low | Camera-raw |
| DNG opcode execution | L | Out of scope | Consumer concern |
| `decodeStreaming` | S | Low | Convenience |
| `threads: u8` | M | Low | Files fit in seconds |
| JPEG-YCbCr API surface | S | Low | Quirk documented |
| Cleanroom JPEG byte parity | XS in tiffz | Tracked upstream | jpegz Phase 2 |
| `Source.fromMmap` | S | Low | Cosmetic |
| Lazy IFD values | S | Low | Eager is default |
| IFD-at-end streaming | M | Low | Workflow needs two-phase |
| Per-IFD limits | XS | Low | Defense-in-depth |
| Lab fixture | XS | Low | Confidence-boost |
| Fuzzing | S+ | Medium (security) | Obvious next step |

Costs: XS = under an hour. S = under a day. M = a few days. L = a
week+.
