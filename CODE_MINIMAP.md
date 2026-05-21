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
                             magic 43 (BigTIFF, structurally parsed; M7 unlocks the
                             rest of the path), endian-aware u16/u32/u64 readers
                             reused by ifd.zig + decoder.zig
  ifd.zig                    Unified IFD parser for classic TIFF + BigTIFF (M7).
                             OffsetWidth enum (classic = 32-bit offsets / 4-byte
                             inline slot; big = 64-bit offsets / 8-byte slot)
                             threads from the header through parse() into the Ifd
                             struct + readEntryValue. Wire-format differences (u16
                             vs u64 entry_count, 12 vs 20 byte entries, u32 vs u64
                             next-IFD pointer) live inside parse(); Entry is
                             uniform (count: u64, raw_value_or_offset: [8]u8 —
                             classic zero-pads the upper 4 bytes). FieldType enum
                             covers BYTE..DOUBLE plus BigTIFF additions LONG8 (16),
                             SLONG8 (17), IFD8 (18). Ifd.get(tag) is a linear scan
                             (small IFDs). readEntryValue handles inline-vs-offset
                             with inline cap = offset_width.inlineCap() and pointer
                             width = offset_width.pointerBytes(). Limits enforced
                             on max_tags_per_ifd + max_tag_value_bytes.
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
    jpeg.zig                 Compression=7 (JPEG-in-TIFF, TIFF Tech Note 2).
                             Thin shim over jpegz.internal.wrapperDecode
                             (the libjpeg-turbo path within jpegz's Phase 1
                             wrapper — bypasses the cleanroom dispatch because
                             jpegz's baseline cleanroom isn't yet byte-exact
                             on RGB-marked baseline + abbreviated/spliced
                             streams). Handles TN2 Mode 1 (no JPEGTables tag)
                             via direct decode, and Mode 2 (JPEGTables tag 347
                             present) by splicing tables-sans-EOI ++ strip-
                             sans-SOI into one self-contained JPEG stream.
                             Photometric=RGB (2) only in M9.5; YCbCr (6)
                             defers to M9 (Pro photometrics).
  source.zig                 Seekable byte-source vtable
                             (`read_at(buf, offset) + size()`). Two
                             implementations: fromBuffer wraps an
                             immutable byte slice (no allocation);
                             fromBufferedReader wraps a sequential
                             reader + caller-supplied cache window
                             (`BufferedReaderHandle`). The latter
                             slides forward through the reader as
                             needed and surfaces back-seeks past
                             `cache_start` as
                             error.SourceSeekTooFarBack. Cache-sizing
                             guidance is in fromBufferedReader's
                             doc-comment.
  predictors.zig             applyInverse reverses the TIFF Predictor tag
                             (317) transform on post-codec strip bytes.
                             Predictor=1 (none) is no-op; predictor=2
                             (horizontal differencing) adds each sample to
                             the previous same-channel sample in the row,
                             wrapping mod 2^bits. 8-bit + 16-bit paths
                             supported (16-bit uses endian-aware
                             std.mem.readInt/writeInt). Predictor=3
                             (floating-point, M8 / DNG) implements TIFF
                             Tech Note 3 for bps ∈ {16, 24, 32, 64}:
                             two-step per-row inverse — (1) horizontal
                             byte-diff with stride = samples_per_pixel
                             across the whole reshuffled row; (2)
                             endian-aware de-interleave of byte planes
                             back into per-sample bytes. Per TN3, plane 0
                             always holds the MSB of every sample
                             regardless of file endian; LE files invert
                             the plane→byte mapping at de-interleave time
                             so byte offset 0 of a sample (LSB on LE)
                             draws from plane (bps-1). Allocator
                             parameter feeds the FP path's per-row scratch
                             buffer; endian parameter feeds the
                             horizontal-16 and FP paths. None and
                             horizontal-8 paths ignore both. Stride is
                             samples_per_pixel for chunky planar, 1 for
                             separate (per-plane strip).
  findings.zig               INFO finding emission to a caller-supplied
                             callback. InfoFinding enum (stable u32
                             codes, 1..11) + Callback type with C
                             calling convention. Decoder fires findings
                             at IFD-parse time (per-IFD scan) plus
                             one-shots for file-level facts (BigTIFF,
                             LZW old-style fallback). Mirrors jpegz's
                             callback shape. Per-finding payload
                             semantics documented in the module
                             docstring and `docs/tiffz_findings_mapping.md`.
  dng.zig                    DNG auxiliary metadata parsers (M8). tiffz
                             parses only — it does not act on these
                             structures; consumers (validate, raw-pipeline
                             tools) demosaic and execute opcodes
                             themselves. parseCfaPattern decodes
                             CFARepeatPatternDim (33421) + CFAPattern
                             (33422) into a CfaPattern struct
                             { repeat_dim_x, repeat_dim_y, pattern }
                             with the pattern slice as a zero-copy
                             borrow. Pattern values: 0=R 1=G 2=B 3=C 4=M
                             5=Y 6=W per TIFF/EP. parseOpcodeList decodes
                             OpcodeList1/2/3 (51008/51009/51022) — per
                             DNG §10.1 the datastream is always big-endian
                             regardless of file endian. Each opcode is
                             { opcode_id, dng_version, flags, parameters
                             } with parameters as a zero-copy borrow.
                             Hard cap of 1,000,000 opcodes bounds
                             allocation on adversarial inputs.
  photometrics.zig           expandRowsToRgba: decoded chunky pixels →
                             RGBA. Supports bits_per_sample ∈ {1, 8, 16}
                             (16-bit only for RGB/Gray/CMYK; palette,
                             CFA, YCbCr, Lab stay 8-bit at v1). 16-bit
                             reads go through `sampleU8` which uses the
                             file endian + canonical
                             `(x*255 + 32767) / 65535` downscale.
                             interleavePlanesToChunky helper handles
                             planar=separate at the caller side by
                             interleaving N per-plane buffers into
                             chunky form for expandRowsToRgba to
                             consume. Photometric ∈ {0 MinIsWhite, 1
                             MinIsBlack, 2 RGB, 3 Palette, 5 CMYK, 6 YCbCr,
                             8 CIELAB, 32803 CFA}. Palette uses the
                             canonical `(u16 * 255 + 32767) / 65535`
                             downscale on ColorMap entries (matches
                             ImageMagick's ScaleQuantumToChar; plain
                             `>> 8` truncation off-by-ones whenever the
                             low byte ≥ 0x80). CMYK (5) is the standard
                             subtractive composition `(255-C)*(255-K)/255`
                             with round-to-nearest (no ICC profile —
                             device-dependent; deferred). YCbCr (6) uses
                             Q16 fixed-point BT.601 inverse coefficients
                             matching libtiff's TIFFYCbCrToRGBInit
                             byte-exact (Cr_r=91881, Cb_g=-22554,
                             Cr_g=-46802, Cb_b=116130; bias=32768 for
                             round-to-nearest after >> 16). Matches
                             libtiff tiff2rgba byte-exact (magick's Q16
                             round-trip drifts ±1 LSB and isn't the
                             canonical reference). CIE Lab (8) uses
                             integer Q24 fixed-point with comptime-
                             generated LUTs: L_byte → Y_d50 LUT
                             (256), L_byte → fy LUT (256), a_byte →
                             a/500 LUT (256), b_byte → -b/200 LUT
                             (256), linear-Q12 → 8-bit sRGB-gamma LUT
                             (4097). Lab f^-1 piecewise runs at
                             runtime in Q24. Matrix chain: Lab→XYZ(D50)
                             → Bradford D50→D65 → XYZ→sRGB linear →
                             gamma LUT lookup. Runtime path is 100%
                             integer per the avoid-floating-point
                             design goal; LUT generation uses f64 at
                             comptime only. CFA (32803) v1 is gray
                             pass-through — each CFA sample emitted as
                             gray RGBA so consumers can see the mosaic
                             and demosaic later using the CfaPattern
                             returned from src/dng.zig (full Bayer/X-Trans
                             demosaic lands at M11/M12). 16-bit Lab,
                             photometric=9 (ICCLab), planar=separate, and
                             YCbCrSubSampling beyond 1:1 deferred.
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
    jpeg/                    M9.5 JPEG-in-TIFF fixtures: rgb-jpeg.tif
                             (157×151 RGB, single strip, JPEGTables Mode 2,
                             ImageMagick-generated). Tests the strip+
                             JPEGTables splice + libjpeg decode round-trip.
    jpeg_oracle/             Matching .rgba ground truth.
    bigtiff/                 M7 BigTIFF fixtures generated via `tiffcp -8`:
                             rgb-3c-8b.btf (157×151 RGB uncompressed, LONG8
                             StripOffsets) and bali.btf (725×489 LZW palette,
                             LONG8 StripOffsets out-of-line — 45 strips × 8 bytes
                             = 360 bytes via u64 pointer; LONG StripByteCounts
                             out-of-line). Both exercise the 16-byte BigTIFF
                             header, u64 entry_count, 20-byte entries, and
                             8-byte inline-fit cap.
    bigtiff_oracle/          Matching .rgba ground truth.
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
  ifd.zig                    IFD parsing with eager out-of-line value
                             caching. parse() reads the IFD entry block,
                             then sorts out-of-line entries by
                             value_offset and walks them in
                             forward-only order so a streaming Source
                             never back-seeks during parse. The cached
                             bytes are owned by the Ifd and freed in
                             deinit. arrayElementU64(tag, index, …)
                             and readEntryValueCached(tag, …) serve
                             reads from the cache; both fall back to a
                             Source pread if the value somehow wasn't
                             cached (defensive only — shouldn't
                             happen post-parse).                       [M3]
  bigtiff.zig                Comptime offset-width abstraction (u32/u64) [M7]
  compressions/
    uncompressed.zig                                                     [M3]
    packbits.zig / lzw.zig / deflate.zig                                 [M4]
    ccitt_t4.zig / ccitt_t6.zig                                          [M4]
    jpeg.zig                 (wraps sibling jpegz)                       [M9.5]
    zstd.zig                 (wraps sibling zstdz)                       [M12]
  predictors.zig             None / Horizontal / Floating-point          [M5]
  photometrics.zig           RGB / palette / CMYK / YCbCr / Lab          [M9]
  convenience.zig            validateAll / decodeStreaming / decodeAll
include/
  tiffz_errno.h              Generated by build.zig (stable C enum)      [later]
tests/
  fixtures/                  Generated + acquired TIFFs (SPEC §B)
  abi/error_codes.snapshot.txt  CI guard against accidental enum reordering
```
