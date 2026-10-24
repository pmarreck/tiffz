# PLAN

Open work and the latest completions. Older narrative:
`docs/plan_context/legacy-plan-2026-09-29.md`. Purpose: `INTENT.md`.

## Now

Order (BDFN, 2026-10-23): coverage gate, then build-layout conformance, then writer and conversion CLI.

- [ ] Shared PATH cutover to `bin/<PF>` (dotfiles owner), then drop the legacy `result` and `zig-out/bin/tiffz` links from `./build`'s publish().
- [ ] C CLI conversion both ways through the C FFI, for PNG and BMP (BDFN, 2026-10-23). Today `dump` writes TIFF to PNG. Add TIFF to BMP, plus PNG and BMP to TIFF, through a minimal Zig-core writer: strip-based, 8-bit gray/RGB/RGBA, uncompressed or Deflate/LZW, with new FFI entry points (scope recorded in INTENT.md). Round-trip tests both ways. Writer output must pass `tiffz validate` and libtiff.
  - [ ] `src/writer.zig` encode(): little-endian baseline TIFF, one IFD, strips of about 8 KiB, gray8 (MinIsBlack), RGB8, RGBA8 (ExtraSamples = unassociated alpha), compression none. Round-trips through tiffz's own decoder.
  - [ ] Deflate (zlib, compression 8) and TIFF LZW (compression 5, MSB-first, early change, Clear at 4094). lzwz only decodes, so the encoder lives in the writer; lzwz's decoder is a second-implementation check.
  - [ ] FFI `tiffz_encode(pixels, len, width, height, channels, compression, &out, &out_len)`, freed with `tiffz_free`, plus header docs.
  - [ ] CLI `convert IN -o OUT [--to tiff|png|bmp] [--compression none|lzw|deflate] [--ifd N]`. Input format sniffed from magic bytes, output from `--to` or the extension; `-`/@stdin/@stdout. C-side BMP writer, and PNG and BMP readers (8-bit gray, gray+alpha, RGB, RGBA, palette; non-interlaced PNG; 24/32-bit uncompressed BMP). Anything else is a clear error.
  - [ ] Independent oracles: libtiff `tiffinfo` accepts every written TIFF and `tiff2rgba` pixels match the source; ImageMagick decodes our PNG and BMP output and produces the PNG/BMP inputs. Run as a Nix check from `./test`.


## Done

- [x] Repin lercz to 9c9a84f: forward-only Lerc2 validation parser, C CLI, and a Lerc2 version-byte mutation (outside the Fletcher checksum) now fails instead of decoding wrong pixels. Coverage counts unchanged on the 385-trial campaign, so floors stay (done 2026-10-23 21:10 EDT).
- [x] Conform to the cross-platform-project-build-arch convention (skill and its verification-and-migration reference). Gaps seen 2026-10-23: no `bin/<PF>/` entrypoint, products land in unnamespaced `zig-out/` and `result`, not `zig-out/<PF>/[<VARIANT>/]<profile>/` and `.nix-out/<PF>/<profile>`, no `./run`, `./build` has no `--backend=direct`, its header still cites Zig 0.15.2, and `corruption-coverage` looks for the retired `bin/linux/$arch` layout. Prove it with the reference's PATH selection, publication-failure and header-inspection scenarios, not directory names.
  Rollout (skill order): stage the new layout first and keep the legacy `zig-out/bin` and `result` publication, since the shared shell PATH still admits them. The PATH cutover is the dotfiles owner's step; drop the legacy mirror after it.
  - [x] `tools/pf`: uname to PF classifier, rejecting unsupported pairs (classifier test over a set).
  - [x] `--about` reports `PF=` and `VARIANT=` from the compile target, via build.zig macros.
  - [x] `tools/inspect-binary`: ELF/Mach-O/PE header to PF, an oracle independent of build flags.
  - [x] `./build`: Nix default to `.nix-out/<PF>/[<VARIANT>/]<profile>`, `--backend=direct` to `zig-out/<PF>/[<VARIANT>/]<profile>`, header-checked atomic publish of `bin/<PF>/tiffz`. A failed build or a wrong header keeps the previous link. Tested in a disposable project with a stub nix, as the read-only `checks.<system>.build-layout` Nix check.
  - [x] `./run`, `.envrc` PATH via `bin/<PF>`, corruption-coverage lookup, CLI test binary path from a build option, and an updated build header. (done 2026-10-23 21:00 EDT, 07b2ac24)
  - Verified 2026-10-23 20:25 EDT: real `./build` (ALLOW_STALE for the lercz item) published `bin/linux-amd64/tiffz` -> `.nix-out/linux-amd64/musl/ReleaseFast`, header linux-amd64 static, `--about` PF=linux-amd64 VARIANT=musl; the direct backend built and passed `zig build test` natively (VARIANT=gnu). Not exercised: macOS and Windows hosts, and cross targets. Remaining: the shared PATH cutover to `bin/<PF>` (dotfiles owner), then drop the legacy `result` and `zig-out/bin` links.

- [x] Repin jpegz to 8fd246d: code 63 `entropy_padding_zero_bits` WARN, plus ca500f9 (lenient decoding past end-of-scan padding faults) and 698c2c3. jpegz's own pins unchanged. No tiffz mapping change, since jpegz WARN maps to valid and 62 stays FAIL (done 2026-10-23 19:10 EDT).
- [x] Corruption detection coverage as a gate in `./test` (`checks.<system>.corruption-coverage`, Mechatron Prime target): corruption-reader pinned as a flake input (a7ea995, its own nixpkgs so the binary matches the measured one), master 42, 385 decisive trials per profile, ~100 s. libtiff `tiffdump` maps each seed independently of tiffz, so every case is classed uncompressed or compressed and free or open, with a per-class ceiling and false-alarm count. Floors are per profile and class, and a false alarm fails the gate. Determinism confirmed by an identical rerun, and a raised floor fails on real data. Documented in docs/corruption_coverage.md, with uncompressed and compressed ceilings and per-codec integrity checks. Full `./test` green in 311 s; Nix check reproduced every floor exactly (done 2026-10-23 18:50 EDT).

- [x] CI on 18f27c19 failed once in Zig compiler_rt ("LLVM failed to parse x86_64-unknown-linux5.10.0-musl"). The same drv passed 5/5 locally and CI passed d3b993c7. Treated as a nondeterministic toolchain or runner fault; watch for a repeat. rawz and validate told d3b993c7 (done 2026-10-20 14:00 EDT).

- [x] Repin jpegz to 860654d: multi-scan sequential false FAIL fixed, typed entropy findings incl. code 62. No tiffz mapping change (done 2026-10-20 13:40 EDT).

- [x] Repin jpegz to tip 1998721 (flake-only follow-up of bc01093, jp2z a7cc185) and lercz to 39703ee. tiffz published a7204fdb, then 1c86eb33 for the jpegz tip (done 2026-10-19 00:20 EDT).
- [x] Repin jpegz to bc01093 (jp2z a7cc185) and lercz to 39703ee in one commit. Freshness gate green without ALLOW_STALE (done 2026-10-18 23:25 EDT).

- [x] validate confirmed finding 13 on the real P7100 NRW under be1e8cbc: ok, warning at 163840, excess 448. Grid is 15,081,024 bytes, so the earlier 64 was a misquoted grid (done 2026-10-18 22:35 EDT).

- [x] Confirm Mechatron Prime CI on be1e8cbc: PASS, 10m 29s, 2026-10-18 14:32Z. 35536193 never built alone, and be1e8cbc contains it (done 2026-10-18 22:25 EDT).
- [x] Treat up to one trailing row past a complete strip as finding 13, not Malformed. The Nikon NRW SubIFD is that shape (done 2026-10-18 10:21 EDT).
- [x] Answer validate: the NRW excess is finding 13. jp2z a7cc185 is not in jpegz 85455eb. lercz 39703ee is documentation and stays unpinned (done 2026-10-18 10:21 EDT).

- [x] Record the validate-mutation-v3 intervals on ReleaseFast sha256 `f22fd10c`. Specificity 19/19. Sniper 113/340, bolter 153/385, shotgun 183/385, nuke 251/335 (done 2026-10-15 23:59 EDT).
- [x] Publish jpegz `85455eb` after the ReleaseFast build. lercz stays `a88c39b` (done 2026-10-15 23:59 EDT).
- [x] Note rawz `4c0e82b`. No consumer acceptance is inferred, and no vendor RAW codec starts from that checkpoint (done 2026-10-15 23:59 EDT).

- [x] Add high SubIFD depth and bytes-visited caps on the existing limit statuses. Statuses 11-19 and finding 16 are reach. Defaults stayed high (done 2026-10-15 23:35 EDT).
- [x] Append a limit-progress channel: byte offset, IFD index, and bytes consumed. `tiffz_validate` still returns only a status (done 2026-10-15 23:35 EDT).
- [x] Lock Adobe Deflate 32946 on the same zlib arm as compression 8 (done 2026-10-15 23:35 EDT).
- [x] Append CCITT T.6 early EOFB as its own outcome, with the completed row count and zero-fill after EOFB (done 2026-10-15 23:35 EDT).
- [x] Migrate local mutation vocabulary to sparse shotgun and dense nuke, and keep historical 4096-byte shotgun reports labeled as nuke (done 2026-10-15 23:35 EDT).
