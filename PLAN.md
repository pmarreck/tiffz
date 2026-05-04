# tiffz — Plan

Living checklist of work items. Update as items complete; keep recent
completions for continuity. See `SPEC.md` for the milestone roadmap and
`docs/superpowers/specs/2026-05-04-tiffz-api-design.md` for the frozen
public API design.

## In flight

- [ ] **Task #3 — flake.nix + .envrc** (active). Devshell with Zig +
      libtiff + imagemagick + gdal + netpbm + vips + exiftool +
      hyperfine. `.envrc` runs `use flake` and adds `zig-out/bin` to
      PATH.

## Next up (this session)

- [ ] **Task #4 — Audit corpus + coverage matrix.** Per SPEC §2. Walk
      `~/Documents-CloudManaged/validate/ground_truth_examples/tiff`
      and `.../dng`, plus `/Volumes/Fileserver/Pictures/scan from
      pete's book.tif`. Emit `audit/coverage_matrix.tsv` with per-file
      variant axes (compression, photometric, predictor, planar
      config, strip-vs-tile, BigTIFF, etc.) and a "zigimg verdict"
      column.

- [ ] **Task #5 — Skeleton (milestone 2 from SPEC §9).**
      `build.zig`, `build.zig.zon`, `src/core/`, `ffi/c_api.zig`,
      `ffi/tiffz_core.h`, `cli/main.c`, hello-world FFI roundtrip,
      packages.default + checks.test wired into `flake.nix`. Garnix
      green on the empty scaffold.

## Milestones (from SPEC §9 — implement in order)

- [ ] M1: Audit + spec freeze (no code). Spec frozen 2026-05-04.
      Audit pending (task #4).
- [ ] M2: Skeleton — repo bootstrap, build.zig, flake, hello-world
      FFI, CI. (task #5)
- [ ] M3: Classic TIFF, uncompressed. Strip-based RGB/gray/palette.
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
- [ ] M9: Pro photometrics — CMYK, YCbCr, CIE Lab.
- [ ] M9.5: JPEG-in-TIFF (compression=7) once `jpegz` sibling is ready.
- [ ] M10: Validate integration — replace zigimg dep in validate's
      TIFF deep-validation. Drop a note in
      `~/Documents-CloudManaged/validate/inbox/` with the
      `build.zig.zon` dep URL.
- [ ] M11: GeoTIFF, TIFF/EP as needed.
- [ ] M12: Modern compressions (LERC, ZSTD-in-TIFF) as needed.

## Recently completed

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
