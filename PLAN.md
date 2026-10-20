# PLAN

Open work and the latest completions. Older narrative:
`docs/plan_context/legacy-plan-2026-09-29.md`. Purpose: `INTENT.md`.

## Now

- [ ] Diagnose CI FAIL on 18f27c19: Zig compiler_rt sub-compile hit LLVM "failed to parse x86_64-unknown-linux5.10.0-musl" in checks.test. The same drv (lww6ppxq) passed 5 of 5 local builds including 4 --rebuild runs; disk was not full. Re-run CI on the next commit; if it repeats, send the log to Mechatron Prime. Hold the rawz/validate notice until CI is green.


## Done

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
