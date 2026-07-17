# tiffz — Plan

Living checklist of work items. Update as items complete; keep recent
completions for continuity. See `SPEC.md` for the milestone roadmap and
`docs/superpowers/specs/2026-05-04-tiffz-api-design.md` for the frozen
public API design.

## Next up

- [x] **Require LZW EOD and prove general 1-bit LZW decoding**
      (2026-07-17). The TIFF LZW loop now returns `SourceTooShort` rather
      than accepting physical EOF before its required EOD code. A compact
      inline 8×1 bilevel LZW TIFF proves the ordinary `Decoder.decodeStrip`
      path handles packed 1-bit LZW data, so Validate can remove its duplicate
      TIFF fallback after the shared `lzwz` migration.
- [x] **Require exact decoded extent per strip and tile** (2026-07-17).
      `validateAllStripsAndTiles` now derives each chunk's byte extent from
      image geometry, sample depths, planar layout, and edge-strip/tile shape;
      a valid LZW EOD with zero output for a declared 8×1 bilevel strip is
      rejected. This closes the complementary PASS path where a terminator
      existed but the declared pixels were absent. Full sandboxed suite green
      18:33 EDT.
- [x] **Migrate TIFF LZW to shared `lzwz`** (2026-07-17). `tiffz` now
      imports and re-exports the single profile-configured core used by PDF,
      GIF, and TIFF; its 346-line private decoder and duplicate dictionary
      tests are deleted. The thin adapter maps `IncompleteSource` to
      `SourceTooShort`, keeps the existing malformed-only old-style fallback
      and INFO finding, and avoids a second Zig module instance downstream.
      Fresh fixed-output dependency hash, release build, and full sandboxed
      test suite green 18:42 EDT. Updated to `lzwz` v0.2.0's shared
      count-only exact-extent API surface (including exhaustive error mapping)
      with fresh Nix hash, release build, and sandboxed test suite green
      19:05 EDT.
- [x] **16-bit-per-sample photometric expansion (RGB / Gray / CMYK)**
      (2026-05-17). `PixelFormat` gained `endian: Endian = .little`;
      new `sampleU8` helper does endian-aware u16 reads + canonical
      `(x*255+32767)/65535` downscale. Per-channel u8 reuse keeps the
      8-bit composition math intact. Palette + CFA + YCbCr + Lab stay
      8-bit (16-bit variants are niche).
- [x] **planar=separate photometric expansion** (2026-05-17). New
      `interleavePlanesToChunky` helper assembles N per-plane buffers
      into chunky form for `expandRowsToRgba` to consume. Fixture
      test integration through `decodeStrippedSeparateIntoRgba` which
      reads N strips per row band and routes through the helper.
      rgb_separate.tif (16x16 RGB 8-bit, planar=separate) matches the
      magick RGBA oracle byte-exact.
- [x] **ZSTD-in-TIFF** (2026-05-17). Compression code 50000.
      `src/compressions/zstd.zig` wraps pmarreck/zstdz (vendored
      facebook/zstd C library via Zig build). rgb_zstd.tif fixture
      generated via `gdal_translate -co COMPRESS=ZSTD` decodes byte-
      exact against the magick RGBA oracle.
- [x] **JPEG-in-TIFF YCbCr photometric override** (2026-05-17).
      Caller-side override in `decodeFixtureToRgba`: when
      compression=7 + photometric=YCbCr, force photometric=RGB before
      expansion (libjpeg already converts internally). ycbcr_jpeg.tif
      fixture (tiffcp -c jpeg:90, subsampling 2:2) matches libtiff
      tiff2rgba byte-exact.
- [x] **Eager IFD value caching** (2026-05-17). `Ifd.parse` now
      eagerly loads every out-of-line tag value at parse time (sorted
      by value-offset for forward-only Source traversal). Subsequent
      `Ifd.arrayElementU64` and `Ifd.readEntryValueCached` lookups
      serve from the cache without touching the Source. Lifts the
      cache-sizing constraint for streaming sources reading
      IFD-at-start TIFFs to "just enough for one strip". IFD-at-end
      layouts still need a cache that spans the strip region —
      documented in `Source.fromBufferedReader` doc-comment and in
      `docs/possible_future_directions.md` §G.
- [x] **`docs/possible_future_directions.md`** (2026-05-17).
      Inventory of remaining coverage gaps and adjacent improvements,
      each annotated with realistic cost (XS/S/M/L) and rationale
      for deferral.
- [x] **INFO finding callback API** (2026-05-18). New
      `src/findings.zig` with `InfoFinding` enum (stable u32 codes,
      1..11) + Callback type using C calling convention. Decoder
      grows `setFindingCallback(cb, userdata)`, `scanFindings()`,
      and per-IFD scanner that fires for BigTIFF, multi-IFD,
      predictor != 1, ExtraSamples=1 (pre-multiplied alpha),
      Compression=7 (JPEG-in-TIFF), TileOffsets present (tiled
      layout), PlanarConfiguration=2 (separate), photometric=CFA
      or CFAPattern present, opcode list 1/2/3 present (with count
      payload), and any GeoTIFF tag present. LZW codec dispatch
      fires `old_style_lzw_codes` (once per Decoder via a flag) when
      the codec falls back from new-style to old-style on a
      malformed stream. 7 fixture-based unit tests verify emission
      on real TIFFs. Mapping doc updated with the new API + a
      ready-to-paste `FindingAccumulator` shim for validate.
      Validate's M10 integration unblocked.
      (2026-05-17). New `BufferedReaderHandle` wraps a sequential
      reader (function-pointer ctx + read_fn) and a caller-supplied
      cache window. Reads inside the window are served from cache
      without touching the reader; forward reads beyond `cache_end`
      pull from the reader (sliding the window by half its size
      when full to amortize the memmove cost across multiple pulls);
      reads before `cache_start` surface as
      `error.SourceSeekTooFarBack`. Cache-sizing guidance documented
      in `Source.fromBufferedReader`: since the decoder re-reads
      out-of-line tag values (StripOffsets / StripByteCounts / etc.)
      on each `decodeStrip` call rather than caching the arrays
      eagerly, the cache must remain large enough to keep those
      low-offset values resident; for typical libtiff-default
      layouts a 1 MiB cache covers all common cases.

## Milestones (from SPEC §9 — implement in order)

- [ ] M1: Audit + spec freeze (no code). Spec frozen 2026-05-04.
      Audit pending (task #4).
- [x] **M2: Skeleton** (2026-05-04). build.zig + build.zig.zon, Zig
      core (errors, limits, source, workspace, decoder, version, ffi,
      lib), C FFI (`tiffz_version` exported), C CLI (--version /
      --about / --help) dogfooding the FFI, packages.default +
      checks.test in flake.nix, ./build + ./test driver scripts,
      Zig+CLI integration tests passing under sandboxed nix. Zig
      pinned to 0.15.2 via mitchellh/zig-overlay (per portfolio
      "wait for 0.16.1" convention).
- [x] **M3: Classic TIFF, uncompressed (core)** (2026-05-05).
      Source.fromBuffer + BufferHandle, header parser (classic +
      BigTIFF magic detect + reject), IFD parser with lazy values
      and limit enforcement, Decoder.open/decodeStrip wired
      end-to-end, real-fixture tests (rgb-3c-8b, minisblack-1c-8b,
      palette-1c-8b) passing the sandboxed gate.
- [x] **M3 follow-up: photometric expansion + RGBA oracle**
      (2026-05-06). expandRowsToRgba in src/photometrics.zig handles
      photometric ∈ {0 MinIsWhite, 1 MinIsBlack, 2 RGB, 3 Palette}
      for 8-bit chunky planar input. Canonical u16→u8 downscale
      `(x*255 + 32767)/65535` matches ImageMagick's
      ScaleQuantumToChar (catch: plain `>> 8` truncation off-by-ones
      whenever ColorMap low byte ≥ 0x80, e.g. 0x49E8 trunc 0x49 vs
      correct 0x4A). Three real-fixture tests assert byte-exact
      match against committed .rgba oracles generated via `magick
      ... RGBA:...`. Decoder/IFD pipeline now produces full RGBA
      images for the uncompressed cases.
- [ ] M4: Compressions, in order:
  - [x] PackBits (2026-05-07): src/compressions/packbits.zig + dispatch in
        Decoder.decodeStrip on Compression=32773. Two real-fixture oracle
        tests pass byte-exact: cramps.tif (800×607 MinIsWhite, big-endian)
        and at3_1m4_01_rgb.tif (640×480 MinIsBlack, little-endian). Workspace
        gained ensureScratch(min_bytes) for compressed-input staging.
  - [x] LZW (2026-05-07, partial): src/compressions/lzw.zig (algorithm
        adapted from validate's tiff_lzw_decoder.zig with attribution
        + tiffz API shape — caller-supplied dest, no allocation, tiffz
        error set). Variant enum supports new_style (TIFF 6.0 spec:
        MSB-first + early code-width change) and old_style (Sun/Adobe
        legacy: LSB-first + late change); strip dispatcher tries
        new_style first, falls back to old_style on Malformed.
        bali.tif (725×489 LZW palette, big-endian) oracle passes.
        Two follow-ups deferred:
          • quad-lzw.tif → Malformed under both variants. Likely needs
            a libtiff-style header sniff (LZWFixupTags) or a third
            variant combo. Test commented out with TODO.
          • strike.tif → decode succeeds but bytes differ from the
            ImageMagick oracle. Confirmed 2026-05-07 by validate:
            *tiffz's output is the spec-correct one* (ExtraSamples=1
            stores associated/pre-multiplied alpha; ImageMagick's
            RGBA: output un-pre-multiplies as a presentation choice).
            tiffz should NOT un-pre-multiply during decode. The fix
            is (a) regenerate the strike oracle preserving assoc-alpha
            (or use a tiffz-native byte-correct oracle), and
            (b) emit an INFO finding (`pre_multiplied_alpha = true`)
            at validate-integration time. INFO finding work lands at
            M10 alongside the validate finding mapping table.
          • quad-lzw.tif → validate flagged 2026-05-07 that this is
            libtiff's *third* LZW variant: pre-emptive code-width
            bump (separate from new/old style timing). Libtiff sniffs
            it from the first few bytes of the codestream. Adding a
            third Variant member + heuristic detection is a future
            follow-up.
  - [x] CCITT G3 1D / T.4 (2026-05-07 algorithm; 2026-05-13 Linux-
        portable): src/compressions/ccitt_t4.zig. Modified-Huffman
        tables (white runs, black runs, color-independent extended
        make-up codes) transcribed from ITU-T T.4 §4.1.4 Tables 1-3.
        BitReader supports both FillOrder values (1=MSB-first,
        2=LSB-first per TIFF tag 266). Per-color comptime-built
        [14][8192] O(1) lookup tables keyed on (length, bits).
        Decode loop: syncToEol at row start (no post-EOL alignment —
        T4Options bit 2 means EOL is pre-padded so it itself starts
        at a byte boundary; reading the 12-bit EOL leaves us 4 bits
        in and data continues from there). 2D mode rejected, that's
        M4-E.
        fax2d.tif (1728×1082, FillOrder=2, EOL byte-aligned, single
        strip via RowsPerStrip=4294967295) oracle passes byte-exact
        on both Mac aarch64-darwin and Linux x86_64-musl. Decoder
        regression guard pinned via SHA-256 in a @embedFile-backed
        unit test (independent of the fixture-pipeline). Photometrics
        also gained 1-bit-per-sample expansion (MinIsWhite invert +
        MinIsBlack direct, 1-bit packed MSB-first → RGBA).
        Bug stack from the Linux-portability dig:
          1. Initial decoder had a spurious post-EOL alignToByte —
             I misread T4Options bit 2 as "align after EOL" when the
             spec says "EOL is at byte boundary (encoder pads
             before)." Removing the alignToByte fixed correctness.
          2. Linear table scan was slow enough that Linux musl
             exceeded the 10-min watchdog. Replaced with
             comptime-built [14][8192] lookup tables; ~12× speedup.
          3. fixture_test didn't clamp RowsPerStrip = 0xFFFFFFFF
             ("infinite"), so strip_max = 216 × 4294967295 ≈ 927 GB.
             Mac's lazy allocator tolerated the virtual reservation;
             Linux musl rejected. Same clamp as Decoder.decodeStrip
             already had internally now propagated into fixture_test.
  - [x] Deflate (2026-05-07): src/compressions/deflate.zig.
        compression=8 (Deflate) and compression=32946 (AdobeDeflate)
        — same on-disk zlib-framed format, separate registrations
        per TIFF Technical Note 2. Wraps allyourcodebase/zlib
        (community Zig wrapper around upstream C zlib, zlib license,
        same dep validate uses). flake.nix gained the fixed-output
        zigDeps pattern for sandboxed Nix builds. deflate-last-strip.tiff
        (500×500 MinIsBlack, little-endian) oracle passes byte-exact.
  - [ ] LZW
  - [ ] ZLib Deflate
  - [ ] CCITT T.4 (Group 3)
  - [x] CCITT T.6 (Group 4) (2026-05-13). src/compressions/ccitt_t6.zig.
        2D modified-modified-Huffman: pass / vertical (V0, VR1-3,
        VL1-3) / horizontal mode codes; reference-line management
        via changing-element lists; pair-step cursor (a0/b1/b2);
        EOFB detection. Reuses T.4's modified-Huffman tables + bit
        reader (made pub: Color, CodeKind, Match, BitReader,
        matchCode).
        **Marquee target passes byte-exact**: scan_petes_book.tif
        (11059×15671, the file that drifts after row 1030 in zigimg
        PR #321). Photometric-expanded RGBA hash-pinned to
        SHA-256 4514c30c... (oracle is 693 MB so committed via hash
        rather than raw bytes). Test runs in seconds thanks to the
        O(1) lookup-table refactor shared with T.4.
  - [ ] (JPEG-in-TIFF deferred to M9.5 — needs sibling `jpegz`)
- [x] M5: Predictors (None / Horizontal) (2026-05-13).
      src/predictors.zig: applyInverse handles Predictor tag 317 values
      1 (none, no-op) and 2 (horizontal differencing). 8-bit-per-sample
      fully supported in both chunky and separate planar configs;
      stride = samples_per_pixel (chunky) or 1 (separate per-plane strip).
      Wraps mod 256 via Zig's `+%` operator. Decoder.decodeStrip applies
      the inverse via a new applyPredictor pass that runs after the
      codec dispatch and before the strip is returned (predictor=1 is
      a fast-path no-op). 3 real-fixture oracle tests pass byte-exact:
      LZW+pred1, LZW+pred2, Deflate+pred2 (all 32×32 RGB from a
      deterministic plasma seed). 6 unit tests cover the spec's
      worked example plus wrap-around, multi-row boundary, separate
      planar, 16-bit rejection, and floating-point rejection.
      *Deferred:* 16-bit horizontal predictor (needs file-endian-aware
      u16 reads — lands when 16-bit fixtures appear at M8 DNG).
      Predictor=3 floating-point (TIFF Tech Note 3, byte-plane
      interleaved differencing) returns UnsupportedPredictor; lands
      with M8 DNG raw work.
- [x] **M6: Tile-based layout** (2026-05-13). Decoder grew a
      `decodeTile(ifd_index, tile_index, dest, workspace)` primitive
      that mirrors `decodeStrip` for tiled images. Strip and tile
      paths share a single codec dispatch via the new private
      `decodeBytes(dir, ChunkExtent, dest, workspace)` helper; the
      per-chunk extent carries `offset/byte_count/width/rows` so
      CCITT (which needs scan-line geometry) works the same whether
      the chunk is a strip or a tile. `readPredictorMeta` factors the
      shared per-IFD predictor metadata; `applyPredictorStrip` /
      `applyPredictorTile` differ only in width/rows source
      (ImageWidth × clamped RowsPerStrip vs TileWidth × TileLength).
      decodeStrip rejects tile-tag dirs and decodeTile rejects
      strip-tag dirs (caller routes by `is_tiled`). Two real-fixture
      oracle tests pass byte-exact: cramps-tile.tif (800×607
      MinIsWhite, 256×256 tiles, uncompressed) and quad-tile.tif
      (512×384 RGB, 128×128 tiles, LZW). Tile edge cropping uses
      `@min(tile_w, width - origin_x)` and `@min(tile_h,
      height - origin_y)` — encoder pads the full tile, decoder
      copies just the in-image portion to the output RGBA.
      *Bug caught during impl:* the first cramps-tile fixture was a
      malformed tiled-TIFF where TileWidth/TileLength were set but
      data offsets lived in StripOffsets/StripByteCounts (libtiff
      tolerates this aliasing; tiffz won't). Regenerated both
      fixtures via `tiffcp -t -w … -l …` so they use the proper
      TileOffsets/TileByteCounts tags.
      *Threading-convention design captured 2026-05-07* (validate +
      jpegz aligning on the same shape; see "Decided design choices"
      below): when parallel strip / tile decode lands as a follow-up
      to this milestone, surface a `DecodeOptions { threads: u8 = 1 }`
      parameter on the convenience APIs (`validateAll`,
      `decodeStreaming`, `decodeAll`). Default `1` = sequential.
      `0` = explicit caller-opted-in auto-detect. `Decoder.decodeStrip`
      / `Decoder.decodeTile` themselves stay single-threaded
      primitives — caller distributes chunks across threads. No
      globals, no env vars, no auto-detection on the default path.
      C ABI mirrors with `tiffz_decode_all_ex(opts*)` plus an inline
      default-options wrapper.
- [x] **M7: BigTIFF — runtime offset-width abstraction** (2026-05-15).
      The IFD parser branches on a new `OffsetWidth { classic, big }`
      enum threaded through from the header. `Entry` is now uniform
      across both variants — `count: u64`, `raw_value_or_offset: [8]u8`
      (classic zero-pads the upper 4 bytes), eliminating any sum-type
      ripple through consumers. Wire-format differences (u16 vs u64
      entry_count, 12 vs 20 byte entries, u32 vs u64 next-IFD pointer)
      stay confined to `ifd.parse`. `readEntryValue` and
      `readArrayElementU64` (renamed/widened from U32) take an
      `OffsetWidth` parameter; inline-fit cap = 4 (classic) or 8 (big).
      Three new FieldType variants land: long8 (16), slong8 (17),
      ifd8 (18) — each 8 bytes/elem. `Decoder.open` drops the M7
      reject and passes `h.bigtiff ? .big : .classic` to the parser.
      Two real-fixture oracle tests pass byte-exact:
        • rgb-3c-8b.btf — uncompressed RGB, LONG8 StripOffsets
          (inline-fit because 9 strips × 8 bytes = 72 → out-of-line
          via u64 pointer); StripByteCounts SHORT inline.
        • bali.btf — LZW palette, LONG8 StripOffsets out-of-line
          (45 × 8 = 360 bytes); LONG StripByteCounts out-of-line.
      The codec dispatch (LZW + photometric + ColorMap pickup) all
      runs unchanged on BigTIFF metadata — the abstraction held.
      *Why runtime over comptime monomorphization* (SPEC.md hinted at
      comptime): the IFD parser isn't a hot path — codec dispatch is.
      A comptime split would double the parser binary footprint to
      save one branch per tag lookup. Runtime branch keeps a single
      code path and a single test matrix.
- [x] **M8: DNG — predictor 3, CFA tags, opcode list parser** (2026-05-16).
      Predictor=3 (TIFF Tech Note 3, FP byte-plane interleaved
      differencing) lands in `src/predictors.zig` for bps ∈ {16, 24,
      32, 64}, chunky + separate planar. Per-row two-step inverse:
      (1) horizontal byte-diff with stride = samples_per_pixel, then
      (2) endian-aware byte-plane de-interleave (TN3 stores planes
      MSB-first regardless of file endian, so LE-file decoders must
      invert the plane→byte mapping). The deferred-from-M5 Predictor=2
      16-bit horizontal path also lands here (endian-aware u16 reads
      via std.mem.readInt + wrap mod 2^16). applyInverse signature
      grew an `endian: Endian` and an `allocator: std.mem.Allocator`
      parameter — only the FP path consumes the allocator (one per-row
      scratch buffer), only horizontal-16 consumes the endian; decoder
      threads `self.endian` and `self.allocator` through both
      applyPredictorStrip and applyPredictorTile.
      New module `src/dng.zig` parses (no execution) the DNG-specific
      auxiliary tags:
        • CfaPattern (33421 dim + 33422 pattern) — zero-copy borrow
          of the pattern bytes; rejects dim=0 and short buffers.
        • OpcodeList (51008/51009/51022) — big-endian datastream per
          DNG §10.1; each opcode { opcode_id, dng_version, flags,
          parameters } with parameters as a zero-copy borrow.
          Hard cap of 1,000,000 opcodes to bound allocation on
          adversarial inputs.
      Photometric=32803 (CFA) routes through `photometrics.expandGray
      .direct` for v1 — each CFA sample emitted as gray RGBA so
      consumers can see the mosaic and demosaic later using the
      CfaPattern.
      End-to-end FP32 oracle test: gdal_translate generates a
      Predictor=1 (no transform) and a Predictor=3 fixture from the
      same 8×8 FP32 plasma seed; the test decodes both via
      Decoder.decodeStrip and asserts byte-exact match. This caught
      and pinned the LE plane-mapping bug.
      *Deferred (out of M8 scope):* full Bayer/X-Trans demosaic
      (M11/M12 territory); opcode list semantic execution (consumer
      concern); real-camera DNG fixtures (gdal-synth covers the
      Predictor=3 algorithmic case).
- [x] **M9: Pro photometrics — CMYK, YCbCr, CIE Lab** (2026-05-17,
      integer-only runtime same day per the new global "avoid
      floating-point in algorithm rewrites" design goal).
      Three new arms in `photometrics.expandRowsToRgba`:
      - **CMYK** (photometric=5): subtractive `(255-C)*(255-K)/255`
        with round-to-nearest. No ICC profile (device-dependent;
        deferred). 4-sample chunky 8-bit; extra samples beyond CMYK
        used as alpha when SamplesPerPixel ≥ 5.
      - **YCbCr** (photometric=6): BT.601 inverse with full-range
        (0..255), matching the TIFF defaults for YCbCrCoefficients
        (529) = (0.299, 0.587, 0.114) and ReferenceBlackWhite (532)
        full-range. Q16 fixed-point coefficients
        (`Cr_r=91881, Cb_g=-22554, Cr_g=-46802, Cb_b=116130`) matching
        libtiff's `TIFFYCbCrToRGBInit` byte-exact. Clamp to [0,255]
        at output. YCbCrSubSampling beyond 1:1 deferred.
      - **CIE Lab** (photometric=8): TIFF 8-bit Lab decode →
        Lab→XYZ (D50 reference white per spec) → D50→D65 Bradford
        adaptation → XYZ→sRGB linear → sRGB gamma → u8 clamp. Pure
        integer runtime: Q24 fixed-point for the matrix chain;
        comptime-generated LUTs for the L_byte→Y_d50 mapping, the
        a/b offsets, and the sRGB gamma encode (4097-entry Q12
        linear → u8 gamma). The Lab f^-1 piecewise function runs at
        runtime in Q24 (with comptime constants for 6/29, 4/29,
        and 3·(6/29)²). a*/b* read as signed bytes via
        two's-complement bitcast. 16-bit Lab and photometric=9
        (ICCLab) deferred.
      M9.5 follow-up: decoder.zig now accepts Compression=7 with
      photometric=YCbCr in addition to RGB. CAVEAT: libjpeg (via
      jpegz.wrapperDecode) performs YCbCr→RGB conversion internally,
      so the decoded bytes are RGB regardless of the TIFF photometric
      tag. The caller MUST NOT re-apply photometric=YCbCr expansion
      after JPEG decode (libtiff TIFFReadRGBAImage takes the same
      approach). Documented in src/compressions/jpeg.zig and
      decoder.zig.
      *Tests*: unit-scope CMYK endpoints + arbitrary pixel; YCbCr
      gray endpoints + near-pure-red round-trip; Lab black/white
      endpoints. End-to-end oracle fixtures: cmyk.tif (16×16, magick
      RGBA oracle) and ycbcr.tif (16×16, libtiff tiff2rgba oracle —
      tiffz's BT.601 inverse matches libtiff byte-exact; ImageMagick's
      Q16-internal YCbCr round-trip drifts ±1 LSB and isn't the
      canonical reference).
      *Deferred*: 16-bit Lab, ICCLab (photometric=9), CIE Lab fixture
      with magick/tiff2rgba oracle (the sRGB gamma curve + Bradford
      adaptation makes byte-exact oracle generation finicky; endpoint
      tests cover correctness for v1), JPEG-in-TIFF end-to-end with
      YCbCr photometric (requires caller-side photometric override
      since post-JPEG bytes are RGB).
- [x] **M9.5: JPEG-in-TIFF (compression=7)** (2026-05-16).
      `src/compressions/jpeg.zig` calls into jpegz via
      `jpegz.internal.wrapperDecode` (the libjpeg-turbo path).
      Photometric=RGB (2) only — YCbCr (6) defers to M9 where the
      photometric expansion grows YCbCr→RGB. Both TIFF Tech Note 2
      modes handled: Mode 1 (no JPEGTables) passes the strip stream
      straight through; Mode 2 (JPEGTables present) splices
      tables-sans-EOI ++ strip-sans-SOI into one self-contained
      JPEG. Real-fixture oracle: rgb-jpeg.tif (157×151 RGB, single
      strip, JPEGTables Mode 2) decodes byte-exact against the
      magick RGBA oracle.
      *Why wrapperDecode and not plain jpegz.decode:* jpegz's
      baseline cleanroom (~199/276 byte-perfect on libjpeg corpus;
      the rest within ≤2 LSB) is not byte-exact on our RGB-marked
      baseline + abbreviated/spliced bitstream. Pinning the libjpeg
      wrapper guarantees agreement with the magick oracle today;
      when jpegz Phase 2 cleanroom reaches byte-parity on these
      inputs, this swaps back to plain `jpegz.decode` with no
      behavioral change. Sent jpegz an inbox note with the spliced-
      stream fixture so they can repro.
      *Dependency wiring:* jpegz pulled in via `build.zig.zon` as
      `git+https://github.com/pmarreck/jpegz#<commit>` (pinned),
      added a 5-line `build.zig.zon` upstream so it could be
      referenced as a Zig package. tiffz passes `-Dwith-charls=false`
      to skip the JPEG-LS C++ compile (also added that gate
      upstream). flake.nix gains libjpeg-turbo + openjpeg buildInputs;
      `OPENJPEG_INC` env var threads the versioned include path
      (`include/openjpeg-2.5/`) through to jpegz's `@cImport`.
      *Follow-ups:*
        - YCbCr photometric (6) support — needs YCbCr→RGB at M9.
        - Tile-based JPEG-in-TIFF (current fixture is strip-based;
          the codec dispatch already routes through `decodeBytes`
          for both, but no tiled fixture is tested yet).
        - Swap to plain `jpegz.decode` when jpegz Phase 2 cleanroom
          handles RGB-marked baseline + spliced abbreviated streams.
      *Hash-pin floor captured 2026-05-07:* jpegz's corpus soak hit
      99.5% pixel-perfect against libjpeg-turbo (3828/3848) on
      baseline JPEGs after five cleanroom-internal fixes shipped that
      day. No ABI changes — Phase 1 wrapper / dispatcher / C FFI
      surface unchanged. Pin `build.zig.zon` `.jpegz.url` at any
      commit hash ≥ `17e70d3` to get the full pixel-parity plus the
      NotImplemented → wrapper fallback for progressive (SOF2) JPEGs.
- [ ] M10: Validate integration — replace zigimg dep in validate's
      TIFF deep-validation. Validate is *actively waiting on this*
      (per Peter 2026-05-07). When tiffz is M9-complete:
      (a) Use the LLMsend skill to drop a status note in validate's
          inbox + tmux ping with the `build.zig.zon` dep URL +
          commit hash to pin.
      (b) Ship a `tiffz_findings_mapping.md` modeled on jpegz's
          `2026-05-06-jpegz-mapping-table.md` (in validate's inbox
          archive). Format: routing taxonomy table (FindingCode,
          severity, routes-to: error_code/info/warning/malformation),
          short prose on info/warning/malformation distinction, and
          a ready-to-paste `mapping.zig` snippet with a
          `RoutedFinding` union(enum). Validate drops it verbatim
          into `src/core/tiffz_shim.zig` at integration time.
      (c) Initial INFO finding set to seed the mapping:
            • bigtiff_format (M7-gated)
            • multi_ifd_chain (DNG, multi-page faxes)
            • old_style_lzw_codes (LZW Malformed-fallback fired)
            • pre_multiplied_alpha (ExtraSamples=1 — covers strike.tif
              et al.; resolves the "skipped fixture" follow-up from M4-B)
            • predictor_applied = N (M5-gated)
            • geotiff_tags_present (M11-gated)
- [ ] M11: GeoTIFF, TIFF/EP as needed.
- [ ] M12: Modern compressions (LERC, ZSTD-in-TIFF) as needed.

## Recently completed

- [x] **M2 skeleton** (2026-05-04). See M2 above.
- [x] **Audit corpus + coverage matrix** (2026-05-04). 18 TIFFs from
      validate's ground_truth + the marquee CCITT G4 reproducer
      scan. `audit/coverage_matrix.tsv` and `audit/AUDIT_SUMMARY.md`
      capture variant axes + gaps for synthetic fixture generation
      in later milestones.
- [x] **Bootstrap flake.nix + .envrc** (2026-05-04). Zig + libtiff +
      imagemagick + gdal (with check phase neutralized) + netpbm +
      vips + exiftool + hyperfine. `.envrc` activates the flake.
- [x] **Brainstorm + freeze public API design** (2026-05-04). Five
      open questions resolved (access patterns / allocation / errors
      / JPEG-in-TIFF / forward-only adapter + safety limits). Design
      committed to
      `docs/superpowers/specs/2026-05-04-tiffz-api-design.md`.
- [x] **Initial scaffold commit** (2026-05-04, upstream). README,
      SPEC, LICENSING_NOTES, LICENSE, validate handoff in `inbox/`.
- [x] **Untrack Obsidian-vault symlinks under jj** (2026-05-04). jj
      autocommit was staging gitignored Obsidian-vault doc symlinks
      (jj_cheatsheet, ZIG_RECENT_API_CHANGES, ZIG_0.15_TO_0.16). Now
      gitignored AND `jj file untrack`'d.

## Real-world reproducer pointers (from validate 2026-05-07)

- **`/Volumes/Fileserver/Pictures/scan from pete's book.tif`** —
  CCITT G4, 11059×15671, 1-bit MinIsWhite. **M4-E marquee target**
  (zigimg PR #321 drifts after row 1030). Already captured.
- **`/Volumes/Fileserver/Pictures/scan20050424_162904.tiff`** —
  uncompressed RGB, 21 MB, 2364×2951. Was a zigimg false-positive;
  M3 should validate it cleanly. Pull into fixtures when convenient
  to extend the M3 oracle suite to a larger image.
- **`/Volumes/Fileserver/Pictures/scan20041120_160518.tiff`** —
  uncompressed RGB, 9.7 MB, 2129×1486. Same class as above.
- Old-scanner TIFFs with non-standard RowsPerStrip → flag at M5
  (predictor edge cases).
- Photoshop CMYK proof TIFFs in `/Volumes/Fileserver/Documents/`
  and `/Volumes/Fileserver/Textfiles & PDF & eBook/` → M9 targets
  (CMYK photometric + Adobe ICC profile + DotRange tags).

## External signals received

- **2026-05-06 — jpegz Phase 1 ready** (see
  `inbox/2026-05-05-jpegz-phase1-ready.md`). Acknowledged via reply
  in `~/Documents-CloudManaged/jpegz/inbox/2026-05-06-from-tiffz-ack.md`.
- **2026-05-06 — jpegz M1.4b shipped + 14-bit precision fix** (see
  `inbox/2026-05-06-jpegz-reply-m14b-shipped.md`). M8 DNG schedule
  risk resolved. M1.5b (codec-level integrity in `jpegz_validate`)
  and M1.5c (APPn / trailing-EOI findings) also shipped — useful
  for pre-validating JPEGTables before splicing at M9.5. jpegz also
  proposed a clean photometric-helper split for an M3-end brainstorm:
  jpegz emits RGB/gray/CMYK; tiffz handles photometric→RGBA
  (CFA mosaic, palette, YCbCr sub-sampling). Captured below.

## Decided design choices

- **Photometric helper split** (decided 2026-05-06, both sides
  aligned): tiffz owns the photometric→RGBA layer because it knows
  TIFF semantics (CFA mosaic for raw sensors, palette lookups,
  per-revision YCbCr sub-sampling). jpegz stays decode-only and
  emits raw RGB / gray / CMYK that tiffz then transforms. Clean
  separation; can revisit if a sibling JPEG-only consumer ever wants
  the same RGBA helper. No further brainstorm needed; lock this in
  as the M3 follow-up shape.
- **Threading control convention** (aligned with validate + jpegz
  2026-05-07): convenience APIs gain a
  `DecodeOptions { threads: u8 = 1 }` parameter. Default `1` =
  sequential in calling thread. Explicit `0` = caller-opted-in
  auto-detect (uncommon — usually only standalone CLI tools).
  No globals, no env vars, no library-level auto-detection on the
  default path. The library passes `options.threads` through to any
  underlying multi-threaded deps (jpegz at M9.5, openjpeg if it
  ever lands). C ABI mirrors with an `_ex(opts*)` form plus an
  inline default-options wrapper. Validate's call sites read
  `tiffz.decode(source, .{ .threads = 1 })` — symmetric with
  `jpegz.decode(data, .{ .threads = 1 })`. Wired in at M6 alongside
  parallel strip/tile decode.

## Curiosity pokes / open questions for later

- Streaming-mode `Source.fromBufferedReader` cache size — default 8 MiB
  is a guess; bench against real TIFF layouts in the audit corpus to
  confirm it's not a foot-gun.
- `Limits.max_decompressed_strip_bytes = 1 GiB` is generous; tighten
  defaults if validate's audit shows real-world TIFFs comfortably fit
  under e.g. 256 MiB.
- IfdView accessor ergonomics — typed-getter shape (`getU16(tag)` vs
  `as(comptime T, tag)`) deferred to skeleton + first-use phase.
- DNG opcode list — surfaces as a structured list in tiffz; semantic
  execution (the actual image transforms) is a *consumer* concern.
  Confirm validate doesn't need execution at M10.
