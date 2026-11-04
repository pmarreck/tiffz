# PLAN log

The checklist through 2026-09-29 15:28 EDT was archived verbatim at
`docs/plan_context/legacy-plan-2026-09-29.md` when `PLAN.md` was
shortened to one-line items. Completions after that stay in `PLAN.md`
until the next retire.

## Retired 2026-09-29

- [x] [Done] JPEG XL leaf classification shipped with the `3f6066c` pin; codes 9 and 13 are corrupt to match the jpegz facade, which supersedes the earlier valid-finding wording (done 2026-09-20 15:00 EDT, `0004f747`).
- [x] [Done] The 2026-09-09 jpegz promotion HOLD is superseded by the `3f6066c` pin, whose jp2z `77dbeaa` carries `9369627` (done 2026-09-20 15:00 EDT, `0004f747`).

## Retired 2026-10-08

- [x] [Done] DNG CFA compression 7 validates through the single jpegz instance as single-component samples (done 2026-09-24 21:48 EDT, `b38c2f47`).
- [x] [Done] Reject field types outside 1..18, and a tagless main-chain IFD without JPEGInterchangeFormat, as `error.Malformed` (done 2026-09-28 23:32 EDT, `c87b1604`).

## Retired 2026-10-09

- [x] [Done] Bump zstdz to `484cc81` and lercz to LERC 4.2.0 `a88c39b`; status 6 is `LimitExceededDimension` (done 2026-09-29 15:28 EDT, `d2ce15c7`).

## Retired 2026-10-10

- [x] [Done] Close the 2026-07-23 audit follow-ups against `CODE_REVIEW.md`: strictness, diagnostics, and the validate FFI were audited there; YCbCr extent, nested finding identity, labeled-corrupt adjudication, and `Source.fromSubrange` landed afterward. Per-compression sniper scores stay on validate's harness (`CODE_REVIEW.md` §10 item 5) (done 2026-09-29 15:28 EDT).
- [x] [Done] M10 validate TIFF integration: validate already consumes tiffz, and `docs/tiffz_findings_mapping.md` is the routing table (done 2026-09-29 15:28 EDT).
- [x] [Done] Validate's dual re-pin wait is over: validate moved to `c87b1604` while rawz remains on `0004f747`; both share libjxlz `93b29e86`, so there is no tiffz pin action left (done 2026-09-29 15:28 EDT).
- [x] [Done] Nested findings use `(source_decoder, finding_code)` with tiffz=1, jpegz=2, jp2z=3, libjxlz=4, covered by the ABI identity test (done 2026-09-29 15:28 EDT, already on `d2ce15c7`).
- [x] [Done] JPEG-in-TIFF decode calls `jpegz.decode`, the cleanroom path (done 2026-09-29 15:28 EDT, already on `d2ce15c7`).
- [x] [Done] Tell validate, pdfz, and rawz to re-pin `d2ce15c7` (zstdz `484cc81`, lercz 4.2.0), and send Einstein the 2026-07-23 audit closeout (done 2026-09-29 15:36 EDT).
- [x] [Done] Repin jpegz to `5c5191a` (Canon SOF3 `6ef766c` plus the DHT range check); the 178-byte over-subscribed DHT is `huffman_table_corrupt` through the single jpegz instance (done 2026-09-29 20:05 EDT).
- [x] [Done] Repin jpegz to upstream head `4d68daa` (OOM buffer cleanup; `5c5191a` and `6ef766c` remain ancestors; libjxlz stays `93b29e86`) (done 2026-10-08 20:55 EDT).
- [x] [Done] Repin jpegz to upstream head `33ea394` (jp2z `54917d6` inside; libjxlz stays `93b29e86`; Zig stays 0.16.0) (done 2026-10-08 21:30 EDT).

## Retired 2026-10-14

- [x] [Done] Refresh nixpkgs to `39ad350a` (2026-10-07) and zig-overlay to `940ecf1b` (2026-10-09), keeping Zig 0.16.0 (done 2026-10-09 12:50 EDT).
- [x] [Done] Record the TIFF MKTP inventory and reject declared rasters past `max_dim` / `max_total_samples` before the u32 row-span sum wraps (`docs/mktp-research/tiff.md`) (2026-10-10 00:05 EDT).

## Retired 2026-10-15

- [x] [Done] Report configured resource limits as `limited` / exit 4 on the CLI, and lock FFI status 15 against `Malformed` (2026-10-10 00:30 EDT).
- [x] [Done] Prefer tag 330 payload reach over a 32946 oracle. rawz locates sensors; it does not validate every nested image (done 2026-10-10 19:16 EDT).
- [x] [Done] Report the abc2beb2 payload-versus-tag inventory and the validate `179e4261` versus rawz `abc2beb2` pin split (done 2026-10-10 19:08 EDT).
- [x] [Done] Publish `abc2beb2`. Mechatron Prime CI succeeded 2026-10-10T06:35:29Z–06:44:14Z. Package hash `tiffz-0.1.0-qutJAY8I0QHEcRu8-jNoUM7yDnVBfAIpKHp3CA6tQYtT` (done 2026-10-10 02:44 EDT).
- [x] [Done] ReleaseFast `./build` of `d3295f9a` exited 0 at 2026-10-10 02:25 EDT. Binary sha256 `1b904345008517af23840f3c5ab1e3a093818b3010bcaa208a3b0b3027e84382` (done 2026-10-10 02:25 EDT).
- [x] [Done] Record the publication-freeze release at 2026-10-10 02:19 EDT. Published tip stays `618d38d4`; `4b5e9507` stays local until its CI lane (done 2026-10-10 02:19 EDT).
- [x] [Done] Correct the MKTP sample-cap sentence and lock inclusive max_dim on both axes for strips and tiles, plus CLI Malformed status 2 beside the dimension cap (done 2026-10-10 01:28 EDT).
- [x] [Done] Integrate published jpegz `f1a255a` (origin `e9564e4f`) into the local SubIFD commits. `./test` passed on that tree. lercz stays `a88c39b` (done 2026-10-14 15:14 EDT).
- [x] [Done] Record that statuses 11-19 and finding 16 are reach, and that IfdChainCycle, Malformed, and a supported codec error stay file claims (done 2026-10-14 14:43 EDT).
- [x] [Done] Walk tag 330 after the next-IFD chain: an intact child decodes, a short child is Malformed, count 0 adds no page, a past-EOF offset is SourceTooShort, a shared child is one page, and an ancestor pointer is IfdChainCycle (done 2026-10-10 21:08 EDT).

## Retired 2026-10-18

- [x] [Done] Report each validation discrepancy as a warning, an error, or a known failure, with a byte offset and a type. Decoded samples are not the result (done 2026-10-15 23:35 EDT).
- [x] [Done] Run ./corruption-coverage on the known-good corpus. The 13:11 EDT run used the fixed 16-bit shotgun and is not validate-mutation-v3 (done 2026-10-15 13:11 EDT).

## Retired 2026-11-04

- [x] [Done] C CLI conversion both ways through the C FFI, for PNG and BMP (BDFN, 2026-10-23). Today `dump` writes TIFF to PNG. Add TIFF to BMP, plus PNG and BMP to TIFF, through a minimal Zig-core writer: strip-based, 8-bit gray/RGB/RGBA, uncompressed or Deflate/LZW, with new FFI entry points (scope recorded in INTENT.md). Round-trip tests both ways. Writer output must pass `tiffz validate` and libtiff.
  - [x] `src/writer.zig` encode(): little-endian baseline TIFF, one IFD, strips of about 8 KiB, gray8 (MinIsBlack), RGB8, RGBA8 (ExtraSamples = unassociated alpha), compression none. Round-trips through tiffz's own decoder.
  - [x] Deflate (zlib, compression 8) and TIFF LZW (compression 5, MSB-first, early change, Clear at 4094). lzwz only decodes, so the encoder lives in the writer; lzwz's decoder is a second-implementation check.
  - [x] FFI `tiffz_encode(pixels, len, width, height, channels, compression, &out, &out_len)`, freed with `tiffz_free`, plus header docs.
  - [x] CLI `convert IN -o OUT [--to tiff|png|bmp] [--compression none|lzw|deflate] [--ifd N]`. Input format sniffed from magic bytes, output from `--to` or the extension; `-`/@stdin/@stdout. C-side BMP writer, and PNG and BMP readers (8-bit gray, gray+alpha, RGB, RGBA, palette; non-interlaced PNG; 24/32-bit uncompressed BMP). Anything else is a clear error.
  - [x] Independent oracles: libtiff `tiffinfo -D` reads every written TIFF without complaint and tiffz `validate` accepts it; ImageMagick builds the PNG/BMP inputs from deterministic bytes, and its RGBA renderings of input and output must match byte for byte. `checks.<system>.convert`, run from `./test`.
  - [x] Associated (premultiplied) alpha, as in libtiff's strike.tif: `tiffz_decode_rgba` keeps the stored values (matching TIFFReadRGBAImage and the existing oracles), and the new `tiffz_decode_rgba_straight` divides alpha out for convert. Fully transparent pixels become 0, and invalid premultiplied colors saturate. (done 2026-10-24 00:30 EDT)
- [x] [Done] CI on 18f27c19 failed once in Zig compiler_rt ("LLVM failed to parse x86_64-unknown-linux5.10.0-musl"). The same drv passed 5/5 locally and CI passed d3b993c7. Treated as a nondeterministic toolchain or runner fault; watch for a repeat. rawz and validate told d3b993c7 (done 2026-10-20 14:00 EDT).
- [x] [Done] Repin jpegz to 860654d: multi-scan sequential false FAIL fixed, typed entropy findings incl. code 62. No tiffz mapping change (done 2026-10-20 13:40 EDT).
- [x] [Done] Repin jpegz to tip 1998721 (flake-only follow-up of bc01093, jp2z a7cc185) and lercz to 39703ee. tiffz published a7204fdb, then 1c86eb33 for the jpegz tip (done 2026-10-19 00:20 EDT).
- [x] [Done] Repin jpegz to bc01093 (jp2z a7cc185) and lercz to 39703ee in one commit. Freshness gate green without ALLOW_STALE (done 2026-10-18 23:25 EDT).
- [x] [Done] validate confirmed finding 13 on the real P7100 NRW under be1e8cbc: ok, warning at 163840, excess 448. Grid is 15,081,024 bytes, so the earlier 64 was a misquoted grid (done 2026-10-18 22:35 EDT).
- [x] [Done] Confirm Mechatron Prime CI on be1e8cbc: PASS, 10m 29s, 2026-10-18 14:32Z. 35536193 never built alone, and be1e8cbc contains it (done 2026-10-18 22:25 EDT).
- [x] [Done] Treat up to one trailing row past a complete strip as finding 13, not Malformed. The Nikon NRW SubIFD is that shape (done 2026-10-18 10:21 EDT).
- [x] [Done] Answer validate: the NRW excess is finding 13. jp2z a7cc185 is not in jpegz 85455eb. lercz 39703ee is documentation and stays unpinned (done 2026-10-18 10:21 EDT).
- [x] [Done] Record the validate-mutation-v3 intervals on ReleaseFast sha256 `f22fd10c`. Specificity 19/19. Sniper 113/340, bolter 153/385, shotgun 183/385, nuke 251/335 (done 2026-10-15 23:59 EDT).
- [x] [Done] Publish jpegz `85455eb` after the ReleaseFast build. lercz stays `a88c39b` (done 2026-10-15 23:59 EDT).
- [x] [Done] Note rawz `4c0e82b`. No consumer acceptance is inferred, and no vendor RAW codec starts from that checkpoint (done 2026-10-15 23:59 EDT).
- [x] [Done] Add high SubIFD depth and bytes-visited caps on the existing limit statuses. Statuses 11-19 and finding 16 are reach. Defaults stayed high (done 2026-10-15 23:35 EDT).
- [x] [Done] Append a limit-progress channel: byte offset, IFD index, and bytes consumed. `tiffz_validate` still returns only a status (done 2026-10-15 23:35 EDT).
- [x] [Done] Lock Adobe Deflate 32946 on the same zlib arm as compression 8 (done 2026-10-15 23:35 EDT).
- [x] [Done] Append CCITT T.6 early EOFB as its own outcome, with the completed row count and zero-fill after EOFB (done 2026-10-15 23:35 EDT).
- [x] [Done] Migrate local mutation vocabulary to sparse shotgun and dense nuke, and keep historical 4096-byte shotgun reports labeled as nuke (done 2026-10-15 23:35 EDT).
- [x] [Done] Conform to the cross-platform-project-build-arch convention (skill and its verification-and-migration reference). Gaps seen 2026-10-23: no `bin/<PF>/` entrypoint, products land in unnamespaced `zig-out/` and `result`, not `zig-out/<PF>/[<VARIANT>/]<profile>/` and `.nix-out/<PF>/<profile>`, no `./run`, `./build` has no `--backend=direct`, its header still cites Zig 0.15.2, and `corruption-coverage` looks for the retired `bin/linux/$arch` layout. Prove it with the reference's PATH selection, publication-failure and header-inspection scenarios, not directory names. (context: docs/plan_context/build-layout.md)
  - [x] `tools/pf`: uname to PF classifier, rejecting unsupported pairs (classifier test over a set).
  - [x] `--about` reports `PF=` and `VARIANT=` from the compile target, via build.zig macros.
  - [x] `tools/inspect-binary`: ELF/Mach-O/PE header to PF, an oracle independent of build flags.
  - [x] `./build`: Nix default to `.nix-out/<PF>/[<VARIANT>/]<profile>`, `--backend=direct` to `zig-out/<PF>/[<VARIANT>/]<profile>`, header-checked atomic publish of `bin/<PF>/tiffz`. A failed build or a wrong header keeps the previous link. Tested in a disposable project with a stub nix, as the read-only `checks.<system>.build-layout` Nix check.
  - [x] `./run`, `.envrc` PATH via `bin/<PF>`, corruption-coverage lookup, CLI test binary path from a build option, and an updated build header. (done 2026-10-23 21:00 EDT, 07b2ac24)
