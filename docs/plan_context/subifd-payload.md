# Tag 330 payload walk

The full decoder follows `next_ifd_offset` only. `validateAllStripsAndTiles` checks that chain. A tag 330 child is never decoded, so a short nested strip still validates. The codec-free parser stays chain-only: sensor classification and vendor locate remain with the consumer that already walks tag 330 for that purpose.

Children append after the main chain. Existing chain indices stay put. A child is then an ordinary IFD index for `decodeStrip` / `decodeTile`.

## Controls

- Intact uncompressed child, one stored byte `0x5A`: validation succeeds and decoding that child returns that byte.
- The same file with the child strip short of its declared pixel: `Malformed`. The parent page still decodes.
- A child offset that is the directory itself or an ancestor is `IfdChainCycle`. TIFF 6.0 ends an IFD chain with a zero next pointer; a pointer back into the ancestors does not name a new image and does not terminate. That is the same class as the existing next-IFD cycle, not a resource limit.
- Two parents naming one child offset materialize that directory once. Tag 330 is an offset to a child IFD (DNG / TIFF Tech Note 1), and an IFD is identified by its file offset. The second reference is an alias, not a second page and not a cycle.
- Tag 330 count 0 is an empty value array. The parent page still validates. No child index appears.
- A child offset past the file fails the walk with the parse error. It is not skipped.
- Unsupported compression on a child stays finding 16 (`unsupported_compression_skipped`) and does not fail the walk. A supported codec's decode failure stays that codec's error.
- JPEG-compressed children stay on the single pinned jpegz instance. This slice uses uncompressed pages only.

Offsets stored in tag 330 and in strip/tile arrays are file offsets from byte 0. There is no region base. `tiffz_validate` still returns a status code, not an offset channel. No new status variant is part of this slice.

## Limits

`max_ifds` bounds how many directories the walk parses. Crossing it is `LimitExceededIfdCount` (reach), not `Malformed`.

The walk itself is in the full decoder. A separate depth cap and a total-bytes-visited cap are still open. Both will be high safety stops, because capacity grows (BDFN, 2026-10-14). The existing defaults stay as they are: `max_ifds` 1024, `max_dim` 2^30, `max_total_samples` 2^40, and the strip caps at 2^30. Crossing a cap is not `Malformed`. Whether the library status stays `limited` (CLI exit 4, statuses 11 through 19) or Validate records it only as reach is the question sent to Validate. If a new status code is required, append it and announce it before a consumer repins. Do not renumber the existing set.

## Later, not this walk

An Adobe Deflate 32946 tag check shares the zlib arm with compression 8. It does not show that a nested page was read. Photometric expansion stays in `photometrics.zig`; this walk does not invent a photometric finding.
