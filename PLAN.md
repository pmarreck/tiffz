# PLAN

Open work and the latest completions. Older narrative:
`docs/plan_context/legacy-plan-2026-09-29.md`. Purpose: `INTENT.md`.

## Now

## Done

- [x] Record the validate-mutation-v3 intervals on ReleaseFast sha256 `f22fd10c`. Specificity 19/19. Sniper 113/340, bolter 153/385, shotgun 183/385, nuke 251/335 (done 2026-10-15 23:59 EDT).
- [x] Publish jpegz `85455eb` after the ReleaseFast build. lercz stays `a88c39b` (done 2026-10-15 23:59 EDT).
- [x] Note rawz `4c0e82b`. No consumer acceptance is inferred, and no vendor RAW codec starts from that checkpoint (done 2026-10-15 23:59 EDT).

- [x] Report each validation discrepancy as a warning, an error, or a known failure, with a byte offset and a type. Decoded samples are not the result (done 2026-10-15 23:35 EDT).
- [x] Add high SubIFD depth and bytes-visited caps on the existing limit statuses. Statuses 11-19 and finding 16 are reach. Defaults stayed high (done 2026-10-15 23:35 EDT).
- [x] Append a limit-progress channel: byte offset, IFD index, and bytes consumed. `tiffz_validate` still returns only a status (done 2026-10-15 23:35 EDT).
- [x] Lock Adobe Deflate 32946 on the same zlib arm as compression 8 (done 2026-10-15 23:35 EDT).
- [x] Append CCITT T.6 early EOFB as its own outcome, with the completed row count and zero-fill after EOFB (done 2026-10-15 23:35 EDT).
- [x] Migrate local mutation vocabulary to sparse shotgun and dense nuke, and keep historical 4096-byte shotgun reports labeled as nuke (done 2026-10-15 23:35 EDT).
- [x] Run ./corruption-coverage on the known-good corpus. The 13:11 EDT run used the fixed 16-bit shotgun and is not validate-mutation-v3 (done 2026-10-15 13:11 EDT).
