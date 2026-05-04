# Licensing notes (tiffz)

**Date:** 2026-05-04
**Project license:** MIT (see `LICENSE`)

## Short answer

TIFF is a freely implementable file format. There is no patent, no
restrictive license, no legal barrier to writing a TIFF reader/writer
in Zig. Adobe published TIFF 6.0 in 1992; ITU publishes T.4/T.6
freely; LZW patent expired in 2003; DNG ships with explicit Adobe
patent grants. Dozens of independent TIFF implementations coexist
legally (libtiff, Pillow, Go x/image, ImageMagick, GIMP, ...).

## License compatibility

- **libtiff** — BSD-3-Clause. Fully MIT-compatible. Reference reading
  is fine. If any algorithm shape is adapted directly from libtiff
  (rather than from the spec), include the BSD-3 attribution in a
  source comment + a note in the project's `THIRD_PARTY_NOTICES.md`
  (create as needed).
- **zigimg** (and the `pmarreck/zigimg` fork) — MIT. Compatible.
  Reference reading is fine; explicit code reuse should be attributed
  if used wholesale.
- **Pillow's TiffImagePlugin** — MIT-style. Compatible. Same rule.
- **Go x/image/tiff** — BSD-3. Compatible. Same rule.
- **ImageMagick TIFF coder** — Apache-2-style. Compatible but
  carries patent-grant clauses; if anything is adapted, the Apache
  attribution requires NOTICE-style mention.

## Avoid (GPL contamination)

- **GPL'd TIFF code** — some pre-libtiff and some niche tools are
  GPL. GPL contamination is unrecoverable for an MIT project. **Do
  not read** known-GPL TIFF code with intent to implement similarly.
- If you accidentally encounter GPL'd code while researching, log it
  briefly and continue from spec only.

## Patent landscape (snapshot, 2026)

- **TIFF 6.0** — no patents.
- **LZW** — patent expired 2003. Free.
- **CCITT T.4 / T.6** — algorithms are decades old; patents long
  expired. Free.
- **JPEG (DCT-based, the kind in JPEG-in-TIFF compression=7)** — core
  algorithm patent-free; Forgent's claim was ruled out years ago. Free.
- **JPEG 2000** — more complex landscape. Most relevant patents
  expired or covered by ISO RAND grants, but verify before
  implementing JPEG2000-in-TIFF specifically.
- **DNG** — Adobe issues an explicit, irrevocable patent grant for
  any patents Adobe holds that read on DNG implementation. See the
  DNG spec preamble.
- **LERC** — Apache 2.0 licensed; ESRI patents granted under
  Apache's patent clause.
- **ZSTD** — BSD-3 with patent grant from Facebook/Meta. Free.

## Implementation approach (style discipline, not legal posture)

The recommended approach — **read TIFF 6.0 spec first, libtiff as
reference for ambiguities, oracles for verification** — is a quality
discipline, not a cleanroom requirement. Reading the spec carefully
produces a spec-conformant decoder; copying libtiff's shape produces a
"compatible with libtiff" decoder, which is sometimes different
(libtiff has documented bugs and historical workarounds we don't want
to inherit).

- Primary source: TIFF 6.0 spec, ITU T.4/T.6, DNG spec, BigTIFF spec,
  GeoTIFF spec.
- Secondary: libtiff source as ambiguity-resolution reference. Cite
  in comment when used.
- Verification: libtiff binaries (`tiffinfo`, `tiff2rgba`, `tiffcp`)
  as oracle.

If something in the spec is ambiguous and libtiff resolves it
differently than zigimg, libtiff wins (it's the longer-standing
reference). Document the choice in a source comment.

## Distribution

`tiffz` ships under MIT. If/when third-party code IS adopted in
recognizable form, create `THIRD_PARTY_NOTICES.md` listing each upstream + its license.

## Questions

Escalate to Peter. Don't guess at licensing edge cases.
