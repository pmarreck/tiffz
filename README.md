# tiffz

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A cleanroom, spec-complete TIFF reader (and eventually writer) in pure Zig.
Targets full conformance with the TIFF 6.0 specification and the major
modern extensions (BigTIFF, TIFF/EP, DNG, GeoTIFF), with both streaming
and whole-buffer decode modes.

This is a sibling project to [`validate`](../validate),
[`bzip2z`](../bzip2z), [`rarz`](../rarz), [`par2z`](../par2z),
[`uchardetz`](../uchardetz), and [`zstdz`](../zstdz). It exists because
the existing TIFF support in `zigimg` (and its `pmarreck/zigimg` fork)
is incremental-by-design — useful as a generalist library but not a
plausible path to byte-complete spec coverage. Pro photographers are a
primary downstream customer of `validate`; TIFF must be byte-complete.

## Goals

1. **Full TIFF 6.0 conformance** — every required tag, all defined
   compression schemes (uncompressed, PackBits, CCITT 1D / Group 3 /
   Group 4, LZW, JPEG-in-TIFF, ZLib Deflate), all photometric
   interpretations (white-is-zero, black-is-zero, RGB, palette, mask,
   separated/CMYK, YCbCr, CIE L\*a\*b\*), all predictor modes (None,
   Horizontal, Floating-point), strip- and tile-based layouts.
2. **BigTIFF (TIFF 6.0 + 64-bit offsets)** — for files larger than 4 GB
   (large-format prints, gigapixel composites).
3. **TIFF/EP and DNG** — pro-photography raw workflows. DNG predictor
   mode 3 (floating-point) for HDR; non-trivial subsampling rules; CFA
   pattern tags.
4. **Both streaming and all-at-once modes.** Some validate use cases
   need fixed-RAM streaming over multi-GB TIFFs; some image processing
   pipelines want random-access into a fully-loaded IFD tree.
5. **No I/O in the core.** Pure Zig core that operates on `[]const u8`
   buffers and `std.io.Reader`-shaped interfaces. C FFI on top. CLI on
   top of the FFI. Hexagonal architecture (matches the project
   convention).
6. **Zero unsafe deps.** Pure Zig. No libtiff link, no libjpeg link
   (JPEG-in-TIFF will reuse our existing pure-Zig JPEG decoder via FFI
   if needed), no system-library dependencies.
7. **Cleanroom legal hygiene.** Implementation derived strictly from
   published specs. libtiff and other GPL/LGPL code MAY be used as a
   black-box oracle for verification but MAY NOT be copied or
   transcribed. See `CLEANROOM_LEGAL_PACKET.md`.

## Status

🚧 **Greenfield.** No code yet. See `SPEC.md` for the starting
specification including the coverage matrix, prior art notes, and
discovery steps.

## Architecture

```
Any consumer (validate / image tools / GUI) ──► C FFI ──► tiffz Zig core (pure, no I/O)
```

- **Zig core** — pure decoder logic, operates on byte slices and
  reader interfaces. No I/O.
- **C FFI** — the real public API. What every external consumer uses.
- **C CLI** (`tiffz` executable) — dogfoods the FFI. All I/O happens
  here.

## License

MIT. See `LICENSE`.
