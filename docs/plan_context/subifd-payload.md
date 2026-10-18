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

Offsets stored in tag 330 and in strip/tile arrays are file offsets from byte 0. There is no region base. `tiffz_validate` still returns only a status code. When the status is a limit, `tiffz_limit_progress` reports the file offset, the IFD index being entered, and how many source bytes had been read. The CLI JSON names those `limit_offset`, `limit_ifd`, and `limit_bytes`. No new status was added for the walk itself.

## Limits

`max_ifds` bounds how many directories the walk parses. Crossing it is `LimitExceededIfdCount` (status 11). Statuses 11 through 19 are reach, and finding 16 (unsupported compression) is structural reach. Validate confirmed both on 2026-10-14. `IfdChainCycle`, `Malformed`, and a supported codec's own decode error stay claims about the file. A configured cap is not `Malformed`.

Depth and bytes visited are separate from directory count. `max_ifd_depth` defaults to 1024. IFD0 is depth 1, and a tag 330 child of IFD0 is depth 2. Crossing it is `LimitExceededIfdDepth` (status 27). `max_bytes_visited` defaults to 2^40. A read that would pass that count is refused whole and is `LimitExceededBytesVisited` (status 28). Both are reach: `tiffz_status_is_limit` is 1, and the CLI word is `limited`, exit 4. Existing defaults stay: `max_ifds` 1024, `max_tags_per_ifd` 4096, `max_tag_value_bytes` 64 MiB, `max_strips_or_tiles` 16<<20, `max_dim` 2^30, `max_total_samples` 2^40, `max_codec_scratch` 256 MiB, and both strip caps at 2^30. Do not lower them.

`LimitExceededIfdCount` still means directory count, not depth. Status 26 is `EndOfFacsimileBlock`, a file claim, and `tiffz_status_is_limit` is 0 for it. Do not renumber.

Validate's candidate chain routes statuses 11-19 and finding 16 as reach. An older checkout mapped 11-19 to FAIL and finding 16 to WARN. This library does not emit `KNOWN_DEFECT`, `mktp`, or `full`.

A complete strip, including a tag 330 child whose rows equal RowsPerStrip, may store up to one extra row past the sample grid. That excess is finding 13 (`final_strip_padding_tolerated`), a warning at the strip offset. The sample grid stays the minimum. One byte past that row stays `Malformed`. Short final strips still stop at one full RowsPerStrip chunk, as before.

## Progress on a limit

`tiffz_limit_progress` returns 0 when a limit recorded those three numbers, and 1 when it did not. The first site wins. A caller that walks `ifd()` itself can still see how many directories were materialized, and that count is not part of the status return.

## Compression 32946

Adobe Deflate (tag value 32946) uses the same zlib arm as compression 8. A predictor-2 deflate fixture with that tag rewritten to 32946 decodes to the same bytes. It does not show that a nested page was read. Photometric expansion stays in `photometrics.zig`.
