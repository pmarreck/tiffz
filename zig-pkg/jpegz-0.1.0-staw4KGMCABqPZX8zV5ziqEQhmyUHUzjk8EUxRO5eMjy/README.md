# jpegz

[![Garnix](https://img.shields.io/endpoint.svg?url=https%3A%2F%2Fgarnix.io%2Fapi%2Fbadges%2Fpmarreck%2Fjpegz%3Fbranch%3Dyolo)](https://garnix.io/repo/pmarreck/jpegz)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Spec-complete JPEG family decoder library in Zig. One project, one ABI surface,
covering:

- **Baseline JPEG** (ISO/IEC 10918-1, T.81) — DCT, sequential
- **Progressive JPEG** (ISO/IEC 10918-1)
- **Lossless JPEG** (ISO/IEC 10918-1, T.81 §13) — used by DICOM, some early DNG
- **Arithmetic coding** (ISO/IEC 10918-1, T.81 §F)
- **JPEG-LS** (ISO/IEC 14495-1, T.87) — eventually
- **JPEG 2000** (ISO/IEC 15444, T.800) — wavelet codec, separate ABI namespace
  in the same project (different math, but same problem domain)

This is a sibling project to [`validate`](../validate),
[`tiffz`](../tiffz), [`bzip2z`](../bzip2z), [`rarz`](../rarz),
[`par2z`](../par2z), [`uchardetz`](../uchardetz), and
[`zstdz`](../zstdz).

## Why jpegz exists

`validate` has been carrying three things:
- A C-FFI dep on `libjpeg-turbo` (BSD-3) for baseline + progressive
- A pure-Zig 698-line lossless JPEG decoder (`jpeg_lossless_decoder.zig`)
- A C-FFI dep on `openjpeg` (BSD-2) for JPEG 2000

`tiffz` (greenfield) needs JPEG-in-TIFF (compression=7). Both projects need
a unified, focused JPEG home.

## Architecture

```
Any consumer (validate / tiffz / image tools) ──► C FFI ──► jpegz Zig core
```

The Zig core is the single source of truth. The C FFI is the public API.
External consumers — including any C CLI on top — go through the C FFI.

## Phasing

**Phase 1 (MVP, libjpeg-turbo wrapper).** Wrap `libjpeg-turbo` for baseline +
progressive. Lift validate's `jpeg_lossless_decoder.zig` directly. Add an
`openjpeg` wrapper for JPEG 2000. One unified Zig API + C ABI; the
implementation is mostly FFI-into-C-libs in this phase. Both validate and
tiffz can depend on jpegz the day it's stood up.

**Phase 2 (cleanroom replacement).** Rewrite each codec in pure Zig,
keeping the C deps as test oracles only. Final state: zero C deps;
libjpeg-turbo and openjpeg ship only in `tests/` for sanity-check
assertions. See `SPEC.md` §6 for the order (baseline first, then
progressive, then lossless rewrite, then arithmetic, then JPEG-LS, then
JPEG 2000 wavelet pipeline).

## Goals

1. **Spec-complete.** Every variant the published JPEG specs define,
   including arithmetic coding (rare but spec-mandatory), 12-bit
   precision, multi-component subsampling, and the lossless mode.
2. **JPEG 2000 in the same project.** Shares packaging, build, ABI
   conventions; separate ABI namespace because the codec internals are
   completely different (wavelet, EBCOT, T2/T1 packets).
3. **No I/O in the core.** Pure Zig core operates on `[]const u8`
   buffers and `std.io.Reader`-shaped interfaces.
4. **Hexagonal architecture.** Zig core + C FFI + (optional) C CLI, per
   project convention.
5. **Cleanroom replacement targeted by Phase 2.** Until then, libjpeg-
   turbo / openjpeg do the heavy lifting and are honest about it (see
   `LICENSING_NOTES.md`).

## Status

🚧 **Greenfield.** No code yet beyond this scaffold. See `SPEC.md`.

## License

MIT (see `LICENSE`). Phase 1 transitively pulls in libjpeg-turbo (BSD-3)
and openjpeg (BSD-2) — both MIT-compatible. Phase 2 retires those deps.
