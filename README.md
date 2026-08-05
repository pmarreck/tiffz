# tiffz

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Mechatron Prime CI](https://img.shields.io/endpoint?url=https%3A%2F%2Fthelio-nixos.tail66c90.ts.net%2Fbadges%2Ftiffz.json&style=for-the-badge)](https://thelio-nixos.tail66c90.ts.net/mechatron-prime/)

A cleanroom, spec-complete TIFF reader in pure Zig. Targets full
conformance with the TIFF 6.0 specification and the major modern
extensions (BigTIFF, DNG, ZSTD-in-TIFF) with both streaming and
whole-buffer decode modes.

Sibling project to [`validate`](../validate) (the primary downstream
consumer), [`jpegz`](../jpegz) (provides the JPEG-in-TIFF codec
under the hood), and [`zstdz`](../zstdz) (provides the ZSTD codec).
Built because the existing TIFF support in `zigimg` is incremental-
by-design — useful as a generalist library but not a path to
byte-complete spec coverage. Pro photographers, GIS / mapping
archives, and pathology slide stacks all need byte-complete TIFF
verification.

## Status

✅ **Shipped — usable today.** All SPEC §9 milestones M1–M10 are
complete, plus ZSTD-in-TIFF, the streaming
`Source.fromBufferedReader`, and eager IFD value caching. See
[`docs/possible_future_directions.md`](docs/possible_future_directions.md)
for the honest inventory of remaining gaps (mostly niche format
variants and adjacent improvements).

## What's supported

### Compression schemes

| Compression | Code | Status |
|---|---|---|
| None | 1 | ✅ |
| CCITT 1D / T.4 (Group 3) | 3 | ✅ |
| CCITT T.6 (Group 4) | 4 | ✅ marquee target validated against 11059×15671 fax scan |
| LZW (TIFF 6.0 + Sun/Adobe legacy LSB-first) | 5 | ✅ |
| JPEG-in-TIFF (TN2 Mode 1 + Mode 2) | 7 | ✅ via `jpegz.wrapperDecode`; RGB + YCbCr photometric |
| Deflate / AdobeDeflate | 8 / 32946 | ✅ wraps system zlib |
| PackBits | 32773 | ✅ |
| ZSTD-in-TIFF (GDAL/libtiff extension) | 50000 | ✅ via `zstdz` |

### Photometric interpretations

| Photometric | Code | Status |
|---|---|---|
| MinIsWhite (fax) | 0 | ✅ 1-bit, 8-bit, 16-bit |
| MinIsBlack (grayscale) | 1 | ✅ 1-bit, 8-bit, 16-bit |
| RGB | 2 | ✅ 8-bit, 16-bit |
| Palette | 3 | ✅ 8-bit (canonical `(u16*255+32767)/65535` ColorMap downscale matches ImageMagick's ScaleQuantumToChar) |
| Separated / CMYK | 5 | ✅ 8-bit, 16-bit (no ICC profile — device-dependent subtractive recipe) |
| YCbCr | 6 | ✅ BT.601 inverse with Q16 fixed-point coefficients; matches libtiff `tiff2rgba` byte-exact |
| CIE L\*a\*b\* | 8 | ✅ 8-bit; Lab→XYZ(D50) → Bradford D50→D65 → sRGB linear → sRGB gamma (all integer Q24 fixed-point at runtime, LUTs precomputed at comptime) |
| CFA (DNG raw mosaic) | 32803 | ✅ v1 emits each sample as gray RGBA; full Bayer/X-Trans demosaic deferred |

### Layout / structural

- **Strip layout** + **Tile layout** (M6 — shared codec dispatch
  via `ChunkExtent`)
- **Chunky** + **separate-planar** photometric expansion
  (separate-planar via the `interleavePlanesToChunky` helper)
- **BigTIFF** (M7 — runtime `OffsetWidth` enum threaded through
  the IFD parser; classic and big inline-fit caps abstracted)
- **Multi-IFD chains** (lazy materialization on `Decoder.ifd(N)`)
- **DNG metadata** (M8 — CFA pattern, opcode list — parsed not
  executed; see `src/dng.zig`)
- **Eager IFD value caching** — all out-of-line tag values are
  copied into the Ifd at parse time (sorted by value-offset for
  forward-only Source reads), so per-strip decodes don't
  round-trip the Source

### Predictors (tag 317)

- **None** (predictor=1)
- **Horizontal** (predictor=2) — 8-bit + 16-bit endian-aware
- **Floating-point** (predictor=3, TIFF Tech Note 3) — FP16, FP24,
  FP32, FP64 with endian-aware byte-plane de-interleave

### Sources

- `Source.fromBuffer(handle)` — wrap an immutable byte slice
  (no allocation)
- `Source.fromBufferedReader(handle)` — sequential reader +
  caller-supplied sliding cache, single-threaded only. See the
  factory's doc-comment for cache-sizing guidance (IFD-at-start
  files work with a tiny cache; IFD-at-end files need a cache
  spanning the strip region)

### Limits / defenses

Configurable via `Decoder.openWithLimits(allocator, source, limits)`:

- Per-IFD tag count cap
- Per-tag value byte cap
- Strip / tile count cap
- Decompressed strip byte cap
- Codec scratch cap
- DNG opcode count cap (default 1,000,000)

## Quick start (Zig)

```zig
const std = @import("std");
const tiffz = @import("tiffz");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Load a TIFF into a buffer.
    const bytes = try std.fs.cwd().readFileAlloc(allocator, "image.tif", 64 << 20);
    defer allocator.free(bytes);

    // Wrap as a Source.
    var handle = tiffz.source.BufferHandle.init(bytes);
    const src = tiffz.Source.fromBuffer(&handle);

    // Header + IFD0 parse + eager out-of-line value caching.
    var dec = try tiffz.Decoder.open(allocator, src);
    defer dec.deinit();

    const dir = try dec.ifd(0);
    // dir.get(tag_id) -> ?*const Entry,
    // dir.cachedValueBytes(tag_id) -> ?[]const u8,
    // dir.arrayElementU64(tag_id, index, endian, source) — cache-first
    // for strip/tile offset and byte-count arrays.

    // Decode each strip into a caller-owned buffer; expand to RGBA via
    // photometrics.expandRowsToRgba.
    var ws = tiffz.Workspace.init(allocator);
    defer ws.deinit();
}
```

The fixture-test helpers in `tests/fixture_test.zig` show end-to-end
strip / tile decode and RGBA expansion against ImageMagick / libtiff
oracles — that's the most accurate reference for the full call
sequence including planar=separate handling, multi-IFD walks, and
the JPEG-in-TIFF YCbCr photometric override.

### Parser-only consumers

RAW/container classifiers that need TIFF headers, tags, and IFD facts without
pixel decoding should import `dep.module("tiffz-parser")`. That module has the
same `Source`, `Limits`, `header`, `ifd`, `tags`, and IFD-chain `Decoder`
surface used by rawz, with no codec imports or library links. The full
`dep.module("tiffz")` API remains unchanged and re-exports the same shared
parser types, so both modules from one dependency instance can coexist in one
Zig compilation. See
[`docs/parser_only_module.md`](docs/parser_only_module.md) for the dependency
contract and its blocking closure checks.

## Validate integration

tiffz is designed to be `validate`'s TIFF deep-verification engine.
The mapping from tiffz errors and informational findings to
validate's `RoutedFinding` taxonomy lives in
[`docs/tiffz_findings_mapping.md`](docs/tiffz_findings_mapping.md) —
copy the snippet at the bottom into validate's
`src/core/tiffz_shim.zig` to wire it up.

`build.zig.zon` dep stanza:

```zig
.tiffz = .{
    .url = "git+https://github.com/pmarreck/tiffz#<commit>",
    .hash = "",  // run `zig build --fetch=all` to fill in
},
```

## Architecture

```
Any consumer (validate / image tools / GUI) ──► C FFI ──► tiffz Zig core (pure, no I/O)
```

- **Zig core** (`src/`) — pure decoder logic. Operates on byte
  slices and `Source` (the I/O-shape abstraction). No I/O performed
  by the core itself.
- **C FFI** (`src/ffi.zig` + `include/tiffz.h`) — the real public
  API for non-Zig consumers. Currently a scaffold
  (`tiffz_version` exported); the Zig-module path
  (`b.dependency("tiffz").module("tiffz")`) is what validate
  consumes today.
- **Parser-only Zig module** (`src/parser.zig`) — TIFF header and lazy IFD-chain
  parsing for rawz/container classifiers, exported as `tiffz-parser` without
  codec imports or library links.
- **C CLI** (`cli/main.c` → `tiffz` executable) — dogfoods the
  FFI. All I/O happens here.

### Dependencies

- [`pmarreck/jpegz`](https://github.com/pmarreck/jpegz) — JPEG
  codec (currently wraps libjpeg-turbo + openjpeg; cleanroom in
  progress)
- [`pmarreck/zstdz`](https://github.com/pmarreck/zstdz) — ZSTD
  codec (wraps vendored facebook/zstd C library)
- System zlib (via `flake.nix` `buildInputs`)

### Algorithmic discipline

All hot-path math is integer / fixed-point. The YCbCr inverse uses
Q16 coefficients matching libtiff's `TIFFYCbCrToRGBInit` byte-exact;
the CIELAB pipeline uses Q24 fixed-point matrix multiplications
with comptime-generated LUTs for the L_byte→Y_d50 and sRGB-gamma
nonlinearities. The only floating-point in the codebase is inside
`comptime` initializers (LUT generation) — runtime is 100% integer.

## Testing

```bash
./test    # runs the entire sandboxed Nix-derivation test suite
          # (unit tests + integration fixtures + CLI tests)
./build   # builds via `nix build`
```

Real-fixture oracle tests live in `tests/fixtures/` with byte-exact
RGBA oracles. Each oracle is generated by either ImageMagick or
libtiff `tiff2rgba` — whichever is the spec-canonical reference for
the codec / photometric in question, documented per-test. (For
YCbCr-derived photometrics tiffz matches `tiff2rgba` byte-exact;
ImageMagick's Q16-internal chroma upsampling drifts ±1 LSB and
isn't the canonical reference.)

## License

MIT. See [`LICENSE`](LICENSE).

### Cleanroom legal hygiene

Implementation derived strictly from published specs. libtiff and
other GPL / LGPL code may be used as a black-box oracle for
verification but may not be copied or transcribed. See
[`CLEANROOM_LEGAL_PACKET.md`](CLEANROOM_LEGAL_PACKET.md).
