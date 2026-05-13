# tiffz — Plan

Living checklist of work items. Update as items complete; keep recent
completions for continuity. See `SPEC.md` for the milestone roadmap and
`docs/superpowers/specs/2026-05-04-tiffz-api-design.md` for the frozen
public API design.

## Next up

- [ ] **M4: Compressions in order.** PackBits → LZW → Deflate →
      CCITT T.4 → CCITT T.6. Each lands as a separate
      `compressions/<scheme>.zig` driven from `decodeStrip`'s switch
      on the Compression tag. Marquee target at the end (T.6): the
      11059×15671 scan that drifts after row 1030 in zigimg's PR #321.

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
- [ ] M5: Predictors (None / Horizontal / Floating-point).
- [ ] M6: Tile-based layout. Refactor strip path to share with tile path.
      *Threading-convention design captured 2026-05-07* (validate +
      jpegz aligning on the same shape; see "Decided design choices"
      below): when parallel strip / tile decode lands at this
      milestone, surface a `DecodeOptions { threads: u8 = 1 }`
      parameter on the convenience APIs (`validateAll`,
      `decodeStreaming`, `decodeAll`). Default `1` = sequential.
      `0` = explicit caller-opted-in auto-detect. `Decoder.decodeStrip`
      itself stays a single-threaded primitive — caller distributes
      strips across threads. No globals, no env vars, no
      auto-detection on the default path. C ABI mirrors with
      `tiffz_decode_all_ex(opts*)` plus an inline default-options
      wrapper.
- [ ] M7: BigTIFF — comptime offset-width abstraction.
- [ ] M8: DNG — predictor 3, CFA tags, opcode list parser.
      *Schedule risk resolved 2026-05-06:* jpegz M1.4b shipped with a
      1..16 precision range fix that covers DNG's 14-bit case (per
      `inbox/2026-05-06-jpegz-reply-m14b-shipped.md`). Lossless raw
      decode path is ready when we reach M8.
- [ ] M9: Pro photometrics — CMYK, YCbCr, CIE Lab.
- [ ] M9.5: JPEG-in-TIFF (compression=7) once `jpegz` sibling is ready.
      *Status (2026-05-06):* jpegz Phase 1 + M1.4b + M1.5b/c shipped;
      baseline / extended / progressive / lossless 1..16-bit /
      arithmetic SOF9-11 all available via
      `jpegz_decode(uint8_t*, size_t)`. JPEGTables (tag 347) splice
      recipe lives in jpegz at
      `2026-05-06-jpegz-integration-recipe.md` (`spliceJpegTables`:
      tables-EOI ++ strip-SOI = self-contained JPEG; ~50-byte memcpy
      per strip, negligible vs entropy decode). M1.5b/c provides
      codec-level integrity findings (Huffman corruption, malformed
      APPn / trailing-after-EOI in JPEGTables) we can surface before
      a strip even reaches the decoder. No further blockers from
      jpegz's side.
      *Implementation detail captured 2026-05-06:* `jpegz_validate`'s
      `findings[i].offset` is relative to the buffer handed in. When
      we hand it a spliced (tables ++ strip) buffer, subtract
      `spliced_table_prefix_len` from each finding's offset to recover
      the strip-relative offset, then add the strip's TIFF offset to
      get the absolute file position. Build that into the integration
      shim's finding-translation step.
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
