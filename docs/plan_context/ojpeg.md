# Old-style JPEG (Compression 6)

## Rulings

Owner, 2026-11-07 17:24 EST: "do Compression 6. Overriding that 'do not reopen'".

Owner, 2026-11-07 18:53 EST: "Trying to detect damage in a broken spec sounds like a nightmare. We should make a best-effort parse but WARN on it regardless of result."

Validate, 2026-11-07, approved this as InfoFinding 25 `ojpeg_best_effort`:

- WARN, verdict valid.
- One record per Compression 6 IFD, whatever the result.
- The payload carries the layout recognized and the counts of chunks decoded and not.
- The byte layout goes to validate for approval with the implementation.
- Findings 23, 17 and 18 keep their class.

## Reading

tiffz reads Compression 6 the way libtiff 4.7.2's `tif_ojpeg.c` does: TIFF 6.0 section 22 itself is self-contradictory (TIFF Technical Note 2). The code is in `src/compressions/ojpeg.zig`.

1. **Input.** The JPEGInterchangeFormat bytes, if any, followed by every strip or tile in order. Reads are clamped as libtiff clamps them:
   - an offset of 0, or one at or past the end of the file, gives nothing;
   - a count of 0, or one running past the end, runs to the end.
2. **Header.** The input's leading markers, up to SOS or to the first byte that is not a marker:
   - APPn and COM are dropped;
   - DQT and DHT are kept;
   - DRI sets the restart interval;
   - the SOF must be 8-bit, carry SamplesPerPixel components, and be at least as large as the image or the stacked strips or tiles;
   - any other marker fails.
3. **No SOF.** The header is rebuilt from JPEGQTables, JPEGDCTables and JPEGACTables:
   - an 8-bit baseline frame of `strile_width` by `strile_length_total`;
   - components 0, 1 and 2, the first carrying the YCbCr subsampling (default 2, 2; 1x1 for anything but 3-sample YCbCr);
   - a component whose table offset repeats the previous one reuses its table.
4. **Subsampling correction.** A YCbCr frame takes its subsampling from the first SOF in the leading markers, as libtiff corrects YCbCrSubsampling.
5. **Restart interval.** Several strips or tiles imply one restart interval per strip or tile: MCUs across times MCU rows per strip. This applies when the subsampling is 1, 2 or 4 and the strip length is a multiple of the MCU height.
6. **Assembled stream.**
   - SOI, the tables, DRI when a restart interval applies, SOF, SOS;
   - the rest of the input with an RST marker between consecutive strips or tiles;
   - EOI.

   The data ends at the first EOI in the input, where libjpeg stops. So a JPEGInterchangeFormat stream that already holds the whole image is not followed by the strips that repeat it.
7. **Decode.** jpegz decodes the stream once per IFD, and the decode is cached. Strip or tile k is the band of rows starting at k times the strip or tile length. libtiff stacks tiles in one column, `strile_width` wide.
   - YCbCr decodes to RGB, as for Compression 7, so `photometricAfterDecode` reports RGB.
   - Not read: planar-separate 3-sample data, which libtiff composes from one SOS per plane.

## Finding 25 payload (proposed)

28 bytes, little-endian:

| Offset | Type | Field |
|---|---|---|
| 0 | u32 | IFD |
| 4 | u32 | Compression entry index |
| 8 | u64 | anchor: that entry's file offset (also the finding's exact byte offset) |
| 16 | u16 | header source: 0 none, 1 JPEGInterchangeFormat stream, 2 first strip or tile, 3 table tags |
| 18 | u16 | stage: 0 no header assembled, 1 assembled but not decoded, 2 decoded |
| 20 | u32 | strips or tiles |
| 24 | u32 | strips or tiles decoded (each within the extent its geometry gives) |

## Validation

The Compression 6 branch of `validateAllStripsAndTiles` works as follows:

- **Each strip or tile decodes best-effort.** A failed decode is counted, never fatal.
- **Still fatal:**
  - a geometry the directory cannot give;
  - a strip or tile past the end of the file (finding 23);
  - a limit;
  - running out of memory.
- **An IFD with no strip or tile arrays** (the EXIF-style thumbnail and preview IFDs) is read from its JPEGInterchangeFormat stream alone.
- **One finding 25** is emitted per Compression 6 IFD, anchored on the Compression entry.

## Evidence

- **Fixtures** (`tests/fixtures/ojpeg/gen.sh`): one cjpeg JPEG (32x32 RGB, 4:2:0, a restart marker every MCU row) wrapped three ways:
  - JPEGInterchangeFormat plus a strip into its scan data;
  - table tags plus two strips split at the restart marker;
  - the whole JPEG in one strip.

  libtiff's `tiff2rgba` reads all of them, and its three decodes are identical to each other. tiffz's decodes equal djpeg's decode of the source JPEG byte for byte.
- **A cut second strip** still validates. Its finding 25 counts it undecoded.
- **Corpus** (263-file pinned list, before and after): 22 files change and each only gains finding 25 records (39 in all). No verdict changes and no earlier finding disappears. libtiff pics `smallliz.tif` (JPEGInterchangeFormat plus a strip) and `zackthecat.tif` (table tags plus a tile) decode their one chunk. The Sony ARW, Nikon NRW and Pentax PEF thumbnail and preview IFDs are JPEGInterchangeFormat-only and get stage 0 when the directory lacks the geometry to check the frame against; libtiff refuses the same Sony IFD0 for its missing ImageLength.
- **Controlled reds:** six mutations (no restart markers between strips, swapped header source, every chunk starting at row 0, a decode failure made fatal, no restart interval, and the table path forcing 1x1 sampling) each fail their targeted tests.
