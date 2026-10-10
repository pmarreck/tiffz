# PLAN

Open work and the latest completions. Older narrative:
`docs/plan_context/legacy-plan-2026-09-29.md`. Purpose: `INTENT.md`.

## Now

- [ ] Hold yolo pushes until Turing's explicit release or 2026-10-10 03:15 EDT; published tip stays `618d38d403764fbe29692ec211d2d4b45e748e6d`.
- [ ] Migrate local mutation vocabulary to sparse shotgun and dense nuke, and keep historical 4096-byte shotgun reports labeled as nuke (Einstein 2026-09-29).
- [ ] Repin jpegz only after its published green receipt for the jp2z head; do not pin an unpublished tree (jpegz 2026-10-10).

## Done

- [x] Correct the MKTP sample-cap sentence and lock inclusive max_dim on both axes for strips and tiles, plus CLI Malformed status 2 beside the dimension cap (done 2026-10-10 01:28 EDT).
- [x] Report configured resource limits as `limited` / exit 4 on the CLI, and lock FFI status 15 against `Malformed` (2026-10-10 00:30 EDT).
- [x] Record the TIFF MKTP inventory and reject declared rasters past `max_dim` / `max_total_samples` before the u32 row-span sum wraps (`docs/mktp-research/tiff.md`) (2026-10-10 00:05 EDT).
- [x] Refresh nixpkgs to `39ad350a` (2026-10-07) and zig-overlay to `940ecf1b` (2026-10-09), keeping Zig 0.16.0 (done 2026-10-09 12:50 EDT).
- [x] Repin jpegz to upstream head `33ea394` (jp2z `54917d6` inside; libjxlz stays `93b29e86`; Zig stays 0.16.0) (done 2026-10-08 21:30 EDT).
- [x] Repin jpegz to upstream head `4d68daa` (OOM buffer cleanup; `5c5191a` and `6ef766c` remain ancestors; libjxlz stays `93b29e86`) (done 2026-10-08 20:55 EDT).
- [x] Repin jpegz to `5c5191a` (Canon SOF3 `6ef766c` plus the DHT range check); the 178-byte over-subscribed DHT is `huffman_table_corrupt` through the single jpegz instance (done 2026-09-29 20:05 EDT).
- [x] Tell validate, pdfz, and rawz to re-pin `d2ce15c7` (zstdz `484cc81`, lercz 4.2.0), and send Einstein the 2026-07-23 audit closeout (done 2026-09-29 15:36 EDT).
- [x] Nested findings use `(source_decoder, finding_code)` with tiffz=1, jpegz=2, jp2z=3, libjxlz=4, covered by the ABI identity test (done 2026-09-29 15:28 EDT, already on `d2ce15c7`).
- [x] JPEG-in-TIFF decode calls `jpegz.decode`, the cleanroom path (done 2026-09-29 15:28 EDT, already on `d2ce15c7`).
