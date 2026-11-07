# Finding 23: extent_past_eof

A structure that declares more bytes than the file holds. It used to be
status-only SourceShortRead (9). Numbered by validate on 2026-11-06:
corrupt, FAIL by the declared-length default (TERMINOLOGY A2). One record
per offending structure, at the first one the parse or walk reaches. The
walk then stops, as SourceShortRead does.

## Payload: 40 bytes, little-endian

| Bytes | Field |
|---|---|
| 0..4 | u32 IFD index, in walk order |
| 4..6 | u16 kind: 1 entry table, 2 value array, 3 chunk |
| 6..8 | u16 declaring tag: 0 for an entry table, the entry's tag for a value array, 273 or 324 for a chunk |
| 8..16 | u64 declared start |
| 16..24 | u64 declared length, saturated at 2^64 - 1 |
| 24..32 | u64 file size |
| 32..40 | u64 entry offset: 2^64 - 1 when no entry declares the structure |

The record's byte offset is the entry offset when an entry declares the
structure, and the declared start otherwise. It is exact.

## Rulings (validate, 2026-11-07)

- **Kind 1** covers the whole IFD as TIFF 6.0 p. 14 declares it: the count,
  the entries and the next-IFD pointer (2 + 12n + 4 classic, 8 + 20n + 8
  BigTIFF). A file that ends inside the pointer used to read it as 0, the end
  of the chain, which hid the truncation. Survey before flipping: none of
  671 local files with TIFF magic does this, against a positive control, so
  it lands as FAIL.
- **Kind 3** anchors on the StripOffsets or TileOffsets entry, which gives
  the declared start; the payload carries the length.
- **IFD 0** fails inside open, before a callback exists. Approved option:
  `Decoder.openWithCallback(allocator, source, limits, cb, userdata)` and
  `tiffz_open_from_buffer_with_callback(bytes, len, cb, userdata, &status)`
  emit the record through the callback, then fail with status 9 as before.
  The old open calls stay.
