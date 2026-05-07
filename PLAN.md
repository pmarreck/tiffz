# tiffz — Plan

Living checklist of work items. Update as items complete; keep recent
completions for continuity. See `SPEC.md` for the milestone roadmap and
`docs/superpowers/specs/2026-05-04-tiffz-api-design.md` for the frozen
public API design.

## Next up

- [ ] **M3 follow-up: photometric expansion + tiff2rgba oracle.**
      Add an `expandToRgba` helper that consumes decoded strip bytes
      + IFD metadata (photometric, bits, samples, palette, planar
      config) and produces RGBA output. Generate `tiff2rgba` reference
      images for each uncompressed fixture, commit the .rgba files
      alongside the TIFFs, and assert byte-equivalence in the
      fixture tests.

- [ ] **M4: Compressions in order.** PackBits → LZW → Deflate →
      CCITT T.4 → CCITT T.6. Each lands as a separate
      `decompressors/<scheme>.zig` driven from `decodeStrip`'s switch
      on Compression tag. Marquee target at the end (T.6): the
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
      palette-1c-8b) passing the sandboxed gate. Photometric
      expansion + tiff2rgba oracle deferred to a follow-up.
- [ ] M4: Compressions, in order:
  - [ ] PackBits
  - [ ] LZW
  - [ ] ZLib Deflate
  - [ ] CCITT T.4 (Group 3)
  - [ ] CCITT T.6 (Group 4) — *target: pass on
        `/Volumes/Fileserver/Pictures/scan from pete's book.tif`
        (11059×15671) where zigimg PR #321 currently drifts after row 1030*
  - [ ] (JPEG-in-TIFF deferred to M9.5 — needs sibling `jpegz`)
- [ ] M5: Predictors (None / Horizontal / Floating-point).
- [ ] M6: Tile-based layout. Refactor strip path to share with tile path.
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
- [ ] M10: Validate integration — replace zigimg dep in validate's
      TIFF deep-validation. Drop a note in
      `~/Documents-CloudManaged/validate/inbox/` with the
      `build.zig.zon` dep URL.
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

## Brainstorm trigger at M3-end

- **Photometric helper split** (proposed by jpegz): jpegz emits
  RGB/gray/CMYK; tiffz owns photometric→RGBA mappings that know
  about TIFF semantics (CFA mosaic for raw sensors, palette
  lookups, YCbCr sub-sampling rules per TIFF revisions). Brainstorm
  whether the helper lives entirely inside tiffz or surfaces as a
  shared sibling utility. Trigger this brainstorm before starting
  M4.

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
