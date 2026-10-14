# PLAN

Open work and the latest completions. Older narrative:
`docs/plan_context/legacy-plan-2026-09-29.md`. Purpose: `INTENT.md`.

## Now

- [ ] Keep SubIFD depth and bytes-visited caps high, and name that result only after Validate maps a limit onto reach (BDFN 2026-10-14). JPEG hold stays `33ea394`.
- [ ] Add an Adobe Deflate 32946 tag discriminator after the SubIFD walk. It shares the zlib arm with compression 8.
- [ ] Migrate local mutation vocabulary to sparse shotgun and dense nuke, and keep historical 4096-byte shotgun reports labeled as nuke (Einstein 2026-09-29).
- [ ] After jpegz publishes a green head, repin that jpegz only and keep lercz on published yolo `a88c39b` (default-branch `3125e79` has no Zig package).

## Done

- [x] Walk tag 330 after the next-IFD chain: an intact child decodes, a short child is Malformed, count 0 adds no page, a past-EOF offset is SourceTooShort, a shared child is one page, and an ancestor pointer is IfdChainCycle (done 2026-10-10 21:08 EDT).
- [x] Prefer tag 330 payload reach over a 32946 oracle. rawz locates sensors; it does not validate every nested image (done 2026-10-10 19:16 EDT).
- [x] Report the abc2beb2 payload-versus-tag inventory and the validate `179e4261` versus rawz `abc2beb2` pin split (done 2026-10-10 19:08 EDT).
- [x] Publish `abc2beb2`. Mechatron Prime CI succeeded 2026-10-10T06:35:29Z–06:44:14Z. Package hash `tiffz-0.1.0-qutJAY8I0QHEcRu8-jNoUM7yDnVBfAIpKHp3CA6tQYtT` (done 2026-10-10 02:44 EDT).
- [x] ReleaseFast `./build` of `d3295f9a` exited 0 at 2026-10-10 02:25 EDT. Binary sha256 `1b904345008517af23840f3c5ab1e3a093818b3010bcaa208a3b0b3027e84382` (done 2026-10-10 02:25 EDT).
- [x] Record the publication-freeze release at 2026-10-10 02:19 EDT. Published tip stays `618d38d4`; `4b5e9507` stays local until its CI lane (done 2026-10-10 02:19 EDT).
- [x] Correct the MKTP sample-cap sentence and lock inclusive max_dim on both axes for strips and tiles, plus CLI Malformed status 2 beside the dimension cap (done 2026-10-10 01:28 EDT).
- [x] Report configured resource limits as `limited` / exit 4 on the CLI, and lock FFI status 15 against `Malformed` (2026-10-10 00:30 EDT).
- [x] Record the TIFF MKTP inventory and reject declared rasters past `max_dim` / `max_total_samples` before the u32 row-span sum wraps (`docs/mktp-research/tiff.md`) (2026-10-10 00:05 EDT).
- [x] Refresh nixpkgs to `39ad350a` (2026-10-07) and zig-overlay to `940ecf1b` (2026-10-09), keeping Zig 0.16.0 (done 2026-10-09 12:50 EDT).
