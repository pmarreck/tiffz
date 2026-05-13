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
  source.zig                 Source vtable + fromBuffer/BufferHandle (zero-alloc
                             in-memory adapter; tests cover full/partial/EOF/empty).
                             fromMmap / fromFile / fromBufferedReader stay as M5+
                             work since fromBuffer covers all M3-M4 needs.
  header.zig                 Header parser: II/MM byte order, magic 42 (classic) +
                             magic 43 (BigTIFF, structurally parsed but rejected at
                             Decoder level until M7), endian-aware u16/u32/u64 readers
                             reused by ifd.zig + decoder.zig
  ifd.zig                    Classic-TIFF IFD parser: u16 entry_count + 12-byte
                             Entries + u32 next_offset. FieldType enum (BYTE..DOUBLE
                             + unknown). Ifd.get(tag) lookup. readEntryValue handles
                             inline-vs-offset (≤4-byte values inline; larger via
                             u32 offset → Source.read_at). Limits enforced on
                             max_tags_per_ifd + max_tag_value_bytes.
  tags.zig                   Named TIFF 6.0 tag constants (the M3 set: ImageWidth,
                             ImageLength, BitsPerSample, Compression, Photometric,
                             StripOffsets/ByteCounts, SamplesPerPixel, RowsPerStrip,
                             PlanarConfiguration, Predictor, ColorMap, Tile* tags)
                             plus compression / photometric / planar enum values.
                             Accretes as later milestones land.
  workspace.zig              Per-call codec scratch holder. ensureScratch(min_bytes)
                             returns a slice of the requested size; underlying
                             buffer grows monotonically (never shrinks). Used by
                             compressed decoders to stage compressed strip bytes
                             before expansion. Single-threaded — never share
                             across threads.
  compressions/
    none.zig                 Compression=1: source.read_at into dest, no expansion.
    packbits.zig             Compression=32773: TIFF 6.0 §9 RLE. Header byte n is
                             signed int8: n in [0,127] → copy n+1 literal bytes;
                             n in [-127,-1] → repeat next byte 1-n times; n=-128
                             → no-op. Pure function over (compressed src,
                             dest); caller stages bytes via Workspace.
    lzw.zig                  Compression=5: LZW per TIFF 6.0 §13. Variant enum
                             lets callers choose new_style (MSB-first packing,
                             early code-width change at (1<<bits)-1, TIFF 6.0
                             default) or old_style (LSB-first, late change at
                             (1<<bits), Sun/Adobe legacy "compat" path).
                             Prefix-chain dictionary (each entry stores
                             prefix-id + suffix-byte + total length); emit
                             walks the chain backwards filling dest from the
                             end. Algorithm adapted from validate's
                             tiff_lzw_decoder.zig (Peter's MIT project) with
                             attribution; API rewritten to caller-supplied
                             dest (no allocation) and tiffz's shared error set.
    ccitt_t4.zig             Compression=3: CCITT Group 3 (T.4) 1D modified-
                             Huffman fax codec. Per-color tables (white runs,
                             black runs) plus color-independent extended
                             make-up codes (1792..2560). BitReader supports
                             both FillOrder values (MSB-first per TIFF default,
                             LSB-first common in fax-origin data). Comptime-
                             built [14][8192] O(1) lookup tables keyed on
                             (length, bits). T4Options bit 2 (EOL byte
                             alignment) is informational at decode time —
                             syncToEol absorbs arbitrary pre-EOL padding
                             zeros directly. 2D mode rejected; that's M4-E
                             territory shared with G4/T.6. Embedded-fixture
                             unit test pins the decoder's SHA-256 against
                             fax2d.tif as a regression guard independent
                             of the file-I/O / photometric pipeline.
    .fax2d.tif               Embedded copy of the fax2d.tif fixture, used by
                             the @embedFile-backed regression-guard unit
                             test in ccitt_t4.zig. Dotfile so it's
                             unobtrusive in directory listings; same bytes
                             as tests/fixtures/ccitt_g3/fax2d.tif.
    ccitt_t6.zig             Compression=4: CCITT Group 4 (T.6) 2D modified-
                             modified-Huffman fax codec. Per-row decode via
                             three mode codes (Pass `0001`, Vertical V0/VR1-3/
                             VL1-3, Horizontal `001` followed by two T.4-style
                             runs); reference-line management via
                             changing-element lists; pair-step cursor
                             (a0/b1/b2); EOFB (two consecutive 12-bit EOLs)
                             detection. Reuses T.4's exposed BitReader,
                             matchCode, Color, CodeKind, and modified-Huffman
                             tables.
    deflate.zig              Compression=8 (Deflate) / 32946 (AdobeDeflate):
                             zlib-framed deflate per TIFF/EP + TIFF Technical
                             Note 2. Both compression codes mean the same
                             on-disk format. Thin wrapper over the C zlib
                             API (inflateInit2 with windowBits=15 → zlib-
                             framed). Uses the allyourcodebase/zlib dep
                             (community Zig wrapper around upstream C zlib,
                             zlib license; same dep validate ships).
  predictors.zig             applyInverse reverses the TIFF Predictor tag
                             (317) transform on post-codec strip bytes.
                             Predictor=1 (none) is no-op; predictor=2
                             (horizontal differencing) adds each sample to the
                             previous same-channel sample in the row, wrapping
                             mod 2^bits. 8-bit only in M5; 16-bit + floating-
                             point predictor=3 deferred to M8 (DNG). Stride
                             is samples_per_pixel for chunky planar, 1 for
                             separate (per-plane strip).
  photometrics.zig           expandRowsToRgba: decoded chunky 8-bit per-sample
                             pixels → RGBA. Photometric ∈ {0 MinIsWhite, 1
                             MinIsBlack, 2 RGB, 3 Palette}. Palette uses the
                             canonical `(u16 * 255 + 32767) / 65535` downscale
                             on ColorMap entries (matches ImageMagick's
                             ScaleQuantumToChar; plain `>> 8` truncation
                             off-by-ones whenever the low byte ≥ 0x80).
                             Other photometrics + non-8-bit + planar=separate
                             land in later milestones.
  decoder.zig                Decoder.open parses header + IFD0 eagerly (lazy IFD
                             chain — sibling IFDs materialize on first ifd(N) call).
                             decodeStrip / decodeTile are sibling primitives (M6):
                             both dispatch through the shared decodeBytes(dir,
                             ChunkExtent, dest, ws) helper which switches on the
                             Compression tag. ChunkExtent carries
                             offset/byte_count/width/rows so CCITT codecs can use
                             scan-line geometry regardless of layout. decodeStrip
                             rejects tile-tag dirs; decodeTile rejects strip-tag
                             dirs (caller routes by `is_tiled`). Predictor pass
                             runs after the codec via applyPredictorStrip /
                             applyPredictorTile (extents differ: ImageWidth ×
                             clamped RowsPerStrip × strip_index vs TileWidth ×
                             TileLength); readPredictorMeta factors the shared
                             per-IFD metadata read. readScalarU16 /
                             readArrayElementU32 helpers handle inline-vs-offset
                             SHORT/LONG arrays. All Limits checked before any
                             Source read.
  version.zig                Single-source-of-truth version string
  ffi.zig                    C FFI exports — tiffz_version() proves the FFI roundtrip;
                             rest of the surface lands alongside its M3+ impl
cli/
  main.c                     C CLI (--version / --about / --help). Dogfoods the
                             C FFI per project convention.
tests/
  cli/cli_test.zig           Spawns zig-out/bin/tiffz, asserts stdout/stderr/exit code
                             for the four CLI surfaces (version/about/help/unknown)
  fixture_test.zig           Decodes real TIFFs from tests/fixtures/, asserts (a)
                             cumulative decoded byte count matches expected raw
                             pixel size, AND (b) full image after photometric
                             expansion matches the .rgba oracle byte-for-byte.
                             ifdScalarU16/ifdScalarU32 helpers extract typed
                             values from IFD entries; decodeFixtureToRgba
                             stitches Decoder + photometrics into a complete
                             "open file → RGBA buffer" pipeline.
  fixtures/
    uncompressed/            Real ground-truth fixtures from validate's corpus
                             (rgb-3c-8b, minisblack-1c-8b, palette-1c-8b).
    uncompressed_oracle/     Raw RGBA byte streams produced by ImageMagick:
                             `magick <fixture>.tiff -depth 8 RGBA:<oracle>.rgba`.
                             Each is exactly width*height*4 bytes (94828 for the
                             three 157×151 fixtures). Regenerable; committed so
                             the test suite is hermetic in the Nix sandbox.
    packbits/                Real TIFF fixtures with compression=32773:
                             cramps.tif (800×607 MinIsWhite, big-endian) and
                             at3_1m4_01_rgb.tif (640×480 MinIsBlack, little-endian).
    packbits_oracle/         Matching .rgba ground truth from ImageMagick.
    lzw/                     Real TIFF fixtures with compression=5: bali.tif
                             (725×489 palette, big-endian — passes oracle),
                             quad-lzw.tif (deferred: needs LZWFixupTags-style
                             variant detection), strike.tif (deferred:
                             needs assoc-alpha un-pre-multiply, M9).
    lzw_oracle/              Matching .rgba ground truth from ImageMagick.
    deflate/                 deflate-last-strip.tiff (500×500 MinIsBlack,
                             little-endian, compression=8/Deflate). Oracle
                             passes byte-exact.
    deflate_oracle/          Matching .rgba ground truth.
    ccitt_g3/                fax2d.tif (1728×1082 MinIsWhite, FillOrder=2
                             LSB-first, T4Options=4 = EOL byte-aligned, single
                             strip via RowsPerStrip=infinite). G3 1D modified
                             Huffman; oracle passes byte-exact.
    ccitt_g3_oracle/         Matching .rgba ground truth (~7.1 MB).
    predictor/               Synthetic TIFFs generated via libtiff's tiffcp
                             from a 32×32 plasma seed: predictor1_lzw.tif
                             (LZW + no predictor), predictor2_lzw.tif
                             (LZW + horizontal differencing), predictor2_deflate.tif
                             (Deflate + horizontal differencing).
    predictor_oracle/        Matching .rgba ground truth.
    tiled/                   M6 tile-layout fixtures: cramps-tile.tif (800×607
                             MinIsWhite, 256×256 tiles, uncompressed) and
                             quad-tile.tif (512×384 RGB, 128×128 tiles, LZW).
                             Both generated via `tiffcp -t -w <w> -l <h>` so
                             they use TileOffsets/TileByteCounts (the proper
                             tiled-TIFF tags) rather than aliased StripOffsets.
    tiled_oracle/            Matching .rgba ground truth.
    ccitt_g4/                scan_petes_book.tif (11059×15671 MinIsWhite,
                             FillOrder=1 MSB-first, single strip via
                             RowsPerStrip=15671). The marquee target — fax-
                             style scan that drifts after row 1030 in zigimg
                             PR #321. ~1.3 MB compressed → ~693 MB RGBA
                             expanded. Oracle pinned via SHA-256 in
                             fixture_test.zig instead of committing the 693
                             MB raw .rgba.
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
