# PLAN

Open work and the latest completions. Older narrative:
`docs/plan_context/legacy-plan-2026-09-29.md`. Purpose: `INTENT.md`.

## Now

- [ ] Refresh the nixpkgs and zig-overlay locks to within 7 days of channel head, and keep the Zig 0.16.0 selection (BDFN 2026-10-08; locks are 2026-05-03 and 2026-05-04).
- [ ] Migrate local mutation vocabulary to sparse shotgun and dense nuke, and keep historical 4096-byte shotgun reports labeled as nuke (Einstein 2026-09-29).

## Done

- [x] Repin jpegz to upstream head `4d68daa` (OOM buffer cleanup; `5c5191a` and `6ef766c` remain ancestors; libjxlz stays `93b29e86`) (done 2026-10-08 20:55 EDT).
- [x] Repin jpegz to `5c5191a` (Canon SOF3 `6ef766c` plus the DHT range check); the 178-byte over-subscribed DHT is `huffman_table_corrupt` through the single jpegz instance (done 2026-09-29 20:05 EDT).
- [x] Tell validate, pdfz, and rawz to re-pin `d2ce15c7` (zstdz `484cc81`, lercz 4.2.0), and send Einstein the 2026-07-23 audit closeout (done 2026-09-29 15:36 EDT).
- [x] Bump zstdz to `484cc81` and lercz to LERC 4.2.0 `a88c39b`; status 6 is `LimitExceededDimension` (done 2026-09-29 15:28 EDT, `d2ce15c7`).
- [x] Reject field types outside 1..18, and a tagless main-chain IFD without JPEGInterchangeFormat, as `error.Malformed` (done 2026-09-28 23:32 EDT, `c87b1604`).
- [x] Close the 2026-07-23 audit follow-ups against `CODE_REVIEW.md`: strictness, diagnostics, and the validate FFI were audited there; YCbCr extent, nested finding identity, labeled-corrupt adjudication, and `Source.fromSubrange` landed afterward. Per-compression sniper scores stay on validate's harness (`CODE_REVIEW.md` §10 item 5) (done 2026-09-29 15:28 EDT).
- [x] M10 validate TIFF integration: validate already consumes tiffz, and `docs/tiffz_findings_mapping.md` is the routing table (done 2026-09-29 15:28 EDT).
- [x] Validate's dual re-pin wait is over: validate moved to `c87b1604` while rawz remains on `0004f747`; both share libjxlz `93b29e86`, so there is no tiffz pin action left (done 2026-09-29 15:28 EDT).
- [x] Nested findings use `(source_decoder, finding_code)` with tiffz=1, jpegz=2, jp2z=3, libjxlz=4, covered by the ABI identity test (done 2026-09-29 15:28 EDT, already on `d2ce15c7`).
- [x] JPEG-in-TIFF decode calls `jpegz.decode`, the cleanroom path (done 2026-09-29 15:28 EDT, already on `d2ce15c7`).
