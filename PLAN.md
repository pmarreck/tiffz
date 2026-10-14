# PLAN

Open work and the latest completions. Older narrative:
`docs/plan_context/legacy-plan-2026-09-29.md`. Purpose: `INTENT.md`.

## Now

- [ ] Integrate published jpegz `f1a255a` (origin `e9564e4f`) into the local SubIFD commits and rerun the gates before any push. lercz stays `a88c39b` (context: docs/plan_context/jpegz-pin-hold.md).
- [ ] Add high SubIFD depth and bytes-visited caps on the existing limit statuses. Statuses 11-19 and finding 16 are reach. Do not lower defaults (context: docs/plan_context/subifd-payload.md).
- [ ] Append a limit-progress channel (byte offset, IFD index, or bytes consumed). `tiffz_validate` returns only a status today (context: docs/plan_context/subifd-payload.md).
- [ ] Add an Adobe Deflate 32946 tag discriminator after the SubIFD walk. It shares the zlib arm with compression 8.
- [ ] Append a CCITT T.6 early-EOFB outcome, distinct from Malformed, with zero-fill after EOFB (context: docs/plan_context/ccitt-t6-eofb.md).
- [ ] Migrate local mutation vocabulary to sparse shotgun and dense nuke, and keep historical 4096-byte shotgun reports labeled as nuke (Einstein 2026-09-29).

## Done

- [x] Record that statuses 11-19 and finding 16 are reach, and that IfdChainCycle, Malformed, and a supported codec error stay file claims (done 2026-10-14 14:43 EDT).
- [x] Walk tag 330 after the next-IFD chain: an intact child decodes, a short child is Malformed, count 0 adds no page, a past-EOF offset is SourceTooShort, a shared child is one page, and an ancestor pointer is IfdChainCycle (done 2026-10-10 21:08 EDT).
- [x] Prefer tag 330 payload reach over a 32946 oracle. rawz locates sensors; it does not validate every nested image (done 2026-10-10 19:16 EDT).
- [x] Report the abc2beb2 payload-versus-tag inventory and the validate `179e4261` versus rawz `abc2beb2` pin split (done 2026-10-10 19:08 EDT).
- [x] Publish `abc2beb2`. Mechatron Prime CI succeeded 2026-10-10T06:35:29Z–06:44:14Z. Package hash `tiffz-0.1.0-qutJAY8I0QHEcRu8-jNoUM7yDnVBfAIpKHp3CA6tQYtT` (done 2026-10-10 02:44 EDT).
- [x] ReleaseFast `./build` of `d3295f9a` exited 0 at 2026-10-10 02:25 EDT. Binary sha256 `1b904345008517af23840f3c5ab1e3a093818b3010bcaa208a3b0b3027e84382` (done 2026-10-10 02:25 EDT).
- [x] Record the publication-freeze release at 2026-10-10 02:19 EDT. Published tip stays `618d38d4`; `4b5e9507` stays local until its CI lane (done 2026-10-10 02:19 EDT).
- [x] Correct the MKTP sample-cap sentence and lock inclusive max_dim on both axes for strips and tiles, plus CLI Malformed status 2 beside the dimension cap (done 2026-10-10 01:28 EDT).
- [x] Report configured resource limits as `limited` / exit 4 on the CLI, and lock FFI status 15 against `Malformed` (2026-10-10 00:30 EDT).
- [x] Record the TIFF MKTP inventory and reject declared rasters past `max_dim` / `max_total_samples` before the u32 row-span sum wraps (`docs/mktp-research/tiff.md`) (2026-10-10 00:05 EDT).
