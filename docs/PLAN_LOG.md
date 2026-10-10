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
