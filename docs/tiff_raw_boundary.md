# The TIFF ↔ RAW boundary: what belongs in tiffz vs rawz

**Decided:** 2026-07-31 (Peter + Einstein).
**Status:** boundary agreed; `rawz` not yet built. Written *before* more RAW
code accretes, because it is already accreting in the wrong places.

## Why this document exists

Camera RAW parsing in Zig **already exists in this fleet**, cleanroom, spread
across two repositories with no boundary ever having been drawn:

| Location | Contents |
|---|---|
| `tiffz/src/dng.zig` (259 lines) | CFA pattern parsing (tags 33421 `CFARepeatPatternDim` / 33422 `CFAPattern`), `photometric_color_filter_array = 32803`, DNG **opcode lists**, Bayer/X-Trans mosaic handling |
| `validate/src/core/pef_decoder.zig` | A **Pentax PEF** decoder — a proprietary vendor RAW format, living inside the *consumer* application |
| `validate/src/core/{tiffz_shim,format_validation,image_validators}.zig` | Further RAW concepts |

That split is arbitrary: **DNG in the TIFF library, PEF in the app.** Nothing
principled put them there. This document supplies the missing principle.

## The core fact: most RAW *is* TIFF

This is why the boundary is confusing in the first place.

| Format | Container |
|---|---|
| **DNG** | TIFF/EP — an Adobe specification layered directly on TIFF 6.0 |
| **CR2** (Canon), **NEF** (Nikon), **ARW** (Sony), **ORF** (Olympus), **PEF** (Pentax) | TIFF-based, with vendor tags + MakerNote blobs |
| **3FR/FFF** (Hasselblad) | TIFF-based |
| **RW2** (Panasonic) | TIFF-like, with deviations |
| **RAF** (Fujifilm) | proprietary container, TIFF-like IFDs inside |
| **CR3** (Canon, current) | **not TIFF** — ISO BMFF (MP4-style boxes) |

**Consequence, already observed:** validate's sweep selected `pc260001.tif` for
its `tiff` fixture slot, and validate correctly detected it as **ORF** — so the
published `tiff` row measured the wrong format (0/0/0). That was not a detection
bug. ORF genuinely *is* a TIFF file. **TIFF and RAW cannot be separated
structurally**, only semantically.

## THE BOUNDARY

> **Standardized, publicly specified TIFF profiles → `tiffz`.**
> **Proprietary, reverse-engineered vendor formats → `rawz`.**
> **`rawz` depends on `tiffz` for container parsing.**

### Therefore

**tiffz keeps:**
- Baseline TIFF and BigTIFF: IFDs, tags, offsets, strips/tiles, predictors,
  compressions.
- **DNG** — it is a public Adobe/TIFF-EP standard, stable, and definitionally a
  TIFF profile. `src/dng.zig` is **correctly placed; do not move it.**
- The CFA *tag* primitives (33421/33422, photometric 32803) — these are
  TIFF/EP-standard tags, not vendor secrets.
- Reporting facts without classifying: tiffz surfaces the IFDs and tags; it does
  **not** decide "this is an ORF."

**rawz takes:**
- Vendor formats: PEF, CR2, NEF, ARW, ORF, RW2, RAF, 3FR — including
  `pef_decoder.zig`, which is in validate today purely by accident of history.
- MakerNote interpretation (vendor-private, per-model, reverse-engineered).
- RAW *semantics*: bit depth vs storage width, black/white levels, per-vendor
  compression schemes, sensor geometry.
- CR3, which needs an ISO BMFF parser rather than a TIFF one.
- Format **classification** — "is this file a photographic TIFF or camera RAW?"
  answered from tiffz-reported tags.

**validate keeps:** none of the above. It is the *consumer*. Its job is to call
tiffz/rawz and render findings.

### Why not merge them into one "tiffrawz"

1. **Change-rate asymmetry.** TIFF has been effectively frozen since 1992;
   vendor RAW changes with every camera generation. Merging makes every
   TIFF-only consumer absorb camera churn.
2. **A compound name names the confusion rather than resolving it.** The
   boundary exists (standard vs proprietary); the name should reflect that.
3. **Precedent in this fleet:** tiffz already depends on jpegz for JPEG-in-TIFF.
   `rawz → tiffz` is the identical, already-proven layering.

### Classification protocol (resolves the ORF/TIFF ambiguity)

tiffz reports; the caller decides. Signals, in rough order of strength:

- `PhotometricInterpretation == 32803` (CFA) ⇒ raw sensor mosaic, not a
  photographic TIFF.
- `DNGVersion` present ⇒ DNG.
- `Make` / `Model` + a vendor MakerNote ⇒ that vendor's RAW dialect.
- `NewSubfileType` / SubIFD layout distinguishing thumbnail vs full sensor
  image.

A validator keying on structure alone will misclassify **forever**; this is the
fix for the class of bug the `pc260001.tif` fixture exposed.

## Licensing note (relevant to a commercial product)

`validate` links **LibRaw**, with **CDDL-1.0 elected** from its CDDL-1.0 /
LGPL-2.1+ dual license (`validate/build.zig:385`). LibRaw is used as an
independent *validator/oracle* (`libraw_validator.zig`, 137 lines) — **not** as
the parsing implementation, so the cleanroom lineage of the Zig code is intact.

CDDL is file-level copyleft and workable for a proprietary product, but carries
obligations (ship the license text; offer source for the CDDL portions). See
`LICENSING_NOTES.md` and validate's `license-inventory-follow-up` note.

**A mature `rawz` could eventually drop the LibRaw dependency entirely** — the
same motivation that produced cleanroom `z7z` and `jpegz`. That is a long-term
benefit of the split, not a near-term one; LibRaw remains a valuable
differential oracle regardless.

## Sequencing (deliberate)

1. **Now:** scaffold `rawz`; write all **new** RAW work there, not in
   validate/tiffz. Stops the accretion immediately at zero risk.
2. **After validate's current release ships:** migrate `pef_decoder.zig` and the
   RAW validators out of validate. Changing validate's dependency graph
   mid-release is not worth it.
3. **Never:** move `dng.zig` out of tiffz. It is where it belongs.

Initial `rawz` scope is **parsing and error reporting only**. Explicitly *not*
demosaicing or color science — that is darktable/RawTherapee territory, years of
work, and the obvious way a focused parser becomes a bottomless project.

## Corpus: where valid RAW and TIFF test data comes from

Both libraries need a far larger corpus of **known-good** files than currently
exists — the existing sweep had one TIFF fixture, and it turned out to be an ORF.

### RAW — use a purpose-built sample archive, not darktable

darktable **cannot generate camera RAW**; it only reads it. For real RAW breadth
the canonical sources are:

- **`raw.pixls.us`** — the PIXLS.US RAW sample repository. Purpose-built for
  exactly this: **CC0-licensed** samples across hundreds of camera models,
  maintained *specifically* so RAW software (rawspeed, LibRaw, RawTherapee) can
  test against real files. This is the right primary source; CC0 means no
  licensing entanglement for a commercial product. **Verify the license terms at
  fetch time rather than trusting this note.**
- **`rawsamples.ch`** — older archive, broader vintage coverage, but check
  per-file licensing.
- Prefer samples that span the axes that actually matter: **compressed vs
  uncompressed variants of the same format** (see below), bit depth (12/14/16),
  and CFA vs Foveon/X-Trans mosaics.

**Critical corpus axis — compression variant.** Nikon NEF ships uncompressed,
lossless-compressed and lossy-compressed; Sony ARW and Canon CR2 similarly vary.
Corruption detectability differs *fundamentally* between them (entropy-coded data
desynchronizes and is detectable; uncompressed sensor data is not). Any coverage
number reported per *extension* rather than per *compression variant* is
misleading — this is suspected to be the cause of validate's uniform "RAW ≈ 0%"
result.

### TIFF — darktable IS the right generator

`darktable-cli` exports TIFF with controllable bit depth (8/16/32-float) and
compression (none/deflate/LZW), so it can produce a **controlled matrix of valid
TIFFs** from real photographic data — far better coverage than hand-made
fixtures, and every file is known-good by construction. Scriptable via its Lua
API for batch generation.

### darktable's real role for RAW: differential oracle, not generator

rawspeed (bundled with darktable 5.6.0 on the Thelio: 79 makers / 1,389 models)
is an **independent decoder** neither tiffz nor rawz wrote. Mutate a known-good
RAW, then compare our verdict against rawspeed's decode result:

- both reject ⇒ agreement;
- **rawspeed rejects, we pass ⇒ a gap we can close** (the valuable case);
- both pass ⇒ genuinely undetectable, and the honest answer is parity data
  (Mecha RotShield), not better parsing.

Caveat: two decoders agree trivially on well-formed files. **The entire value is
in the divergences on corrupted input** — do not treat "rawspeed decoded it" as
ground truth for validity beyond a true-negative control.
