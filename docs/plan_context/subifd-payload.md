# Tag 330 payload walk

The full decoder follows the next-IFD chain first, then tag 330 children. `validateAllStripsAndTiles` materializes both. The codec-free parser stays chain-only: sensor classification and vendor locate remain with the consumer that already walks tag 330 for that purpose.

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

Offsets stored in tag 330 and in strip/tile arrays are file offsets from byte 0. There is no region base. `tiffz_validate` returns a status code. The stored error is that status plus the error name. It does not carry a byte offset, an IFD index, or a bytes-consumed count. No new status variant was added for the walk.

## Limits

`max_ifds` bounds how many directories the walk parses. Crossing it is `LimitExceededIfdCount` (status 11). Statuses 11 through 19 are reach, and finding 16 (unsupported compression) is structural reach. Validate confirmed both on 2026-10-14. `IfdChainCycle`, `Malformed`, and a supported codec's own decode error stay claims about the file. A configured cap is not `Malformed`.

The walk has no separate depth cap and no total-bytes-visited cap yet. Both will be high safety stops, because capacity grows (BDFN, 2026-10-14). Existing defaults stay: `max_ifds` 1024, `max_tags_per_ifd` 4096, `max_tag_value_bytes` 64 MiB, `max_strips_or_tiles` 16<<20, `max_dim` 2^30, `max_total_samples` 2^40, `max_codec_scratch` 256 MiB, and both strip caps at 2^30. Do not lower them.

A depth or bytes-visited stop reuses an existing limit status when that status can say what stopped. `LimitExceededIfdCount` already covers directory count. Any new code is appended and announced before a consumer repins. Do not renumber.

Validate's shim still maps 11-19 to FAIL and finding 16 to WARN. That routing is theirs to fix. This library does not emit `KNOWN_DEFECT`, `mktp`, or `full`.

## Progress on a limit

A limit result does not say how far the walk got. A later appended channel may carry a byte offset, the IFD index, or bytes consumed. Until that channel exists, a consumer that needs `examined_bytes` has only the status. A caller that walks `ifd()` itself can see how many directories were materialized, and that count is not part of the status return.

## Later, not this walk

An Adobe Deflate 32946 tag check shares the zlib arm with compression 8. It does not show that a nested page was read. Photometric expansion stays in `photometrics.zig`; this walk does not invent a photometric finding.
