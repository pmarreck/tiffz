# Codec reach

On 2026-11-06 the owner, answering a report that undecodable files now read "unsupported", said: "We need to support those compression algorithms, simple as that. Our goal is 100% TIFF/RAW coverage (in conjunction with rawz), to the extent technically-possible."

INTENT.md had left "JPEG2000-in-TIFF, JBIG, and other undispatched codecs" unclaimed "until an explicit owner decision". This note takes the 2026-11-06 statement as that decision for every undispatched TIFF codec that is not blocked.

OJPEG (Compression 6) is different: the owner blocked it by name on 2026-08-27 ("Do not reopen"). Whether the 2026-11-06 goal reopens it is an open question for the owner, and nothing changes for OJPEG until it is answered.

Vendor RAW codecs (Sony ARW 32767 and the others in rawz's scope) stay with rawz.

## Supported before this program

1, 3, 4, 5, 7, 8, 32773, 32946, 34887 (LERC) and 50000 (zstd).

## What the local corpora use

This is a survey of 589 TIFF and DNG files: tiffz's committed fixtures, validate's ground-truth examples and the scratch GDAL and raw.pixls.us sets. Only IFD 0 and chained IFDs were counted, not SubIFDs. Undecoded codes, by number of files:

| Code | Scheme | Files | Notes |
|---|---|---|---|
| 6 | Old-style JPEG (TIFF 6.0 section 22) | 27 | blocked (owner, 2026-08-27); question open |
| 34676 / 34677 | SGILog / SGILog24 (LogLuv) | 3 / 1 | Ward, "The LogLuv Encoding for Full Gamut, High Dynamic Range Images" |
| 32766 | NeXT 2-bit RLE | 3 | |
| 50001 | WebP | 2 | needs a WebP decoder (VP8L lossless, VP8 lossy) |
| 32809 | ThunderScan 4-bit | 2 | |
| 2 | CCITT modified Huffman (T.4 1D, no EOLs, byte-aligned rows) | 1 | TIFF 6.0 section 10 |
| 34892 | DNG lossy JPEG | (SubIFDs) | DNG 1.4.0.0; the iPhone 12 Pro semantic mask uses it |

There is no local file for JPEG 2000 (34712), JPEG XL (50002 in libtiff, 52546 in DNG 1.7), LZMA (34925), JBIG (34661) or Pixar log (32908/32909). Each needs a reproducible exemplar before it is built.

## Order

Within one cost tier, the order follows corpus prevalence. Each codec gets the following before it counts as covered:
- an independent oracle (libtiff, ImageMagick, or the scheme's reference decoder);
- clean and damaged fixtures;
- a controlled red;
- a corpus report.

1. **34892 DNG lossy JPEG** (done 2026-11-06). Baseline JPEG through jpegz. LinearRaw is color-converted like RGB and YCbCr, a PhotometricMask is a one-component gray decode, and any other photometric stays unsupported. The Adobe-converted Canon 5D Mark III raw IFD and the iPhone 12 Pro mask now decode.
2. **2 CCITT modified Huffman** (done 2026-11-06). The T.4 one-dimensional decoder without EOL codes, rows byte-aligned. The fixture comes from libtiff's own encoder.
3. **32766 NeXT and 32809 ThunderScan** (done 2026-11-06). No published specification; read as libtiff's tif_next.c and tif_thunder.c describe them, with libtiff's decodes as the fixture oracle. NeXT's 32766 is outside the Compression row's specified values and still a finding 18 value fault, a question with validate.
4. **34676 / 34677 SGILog.** 34676 (LogL, LogLuv32) done 2026-11-06: per-row run-length byte planes, decoded to the 16-bit signed samples the directory declares. 34677 (LogLuv24) done 2026-11-06: 3 bytes per pixel, a 10-bit log luminance Le over a 14-bit index into Larson's (u, v) table (data from libtiff's uvcode.h, with its notice), decoded to the same L, u and v samples. Two libtiff discrepancies, neither affecting a verdict: its decoder masks with 0xffd where the documented L = 4 Le + 13314 needs 0xffc, so its L carries bit 12 of the index; and its 16-bit encoder takes Le = (L - 3314) / 4, 10000 off its own decoder. tiffz follows the documented form. tiffcp has no working -c sgilog24 (it writes 34676), so the fixtures come from a small C program against libtiff's encoder.
5. **50001 WebP, 34925 LZMA.** These need a codec package. A new sibling package, or a vendored C library in the zstdz pattern, is a dependency decision to record first.
6. **34712 JPEG 2000 and 50002 / 52546 JPEG XL.** These go through jpegz's jp2z and libjxlz legs (INTENT: one jpegz instance per compilation), once exemplars exist. JPEG XL done 2026-11-07 through jpegz.jpegxl (validate, then decode the first frame), with exemplars made by libjxl's cjxl and checked by djxl; JPEG 2000 still needs an exemplar and a specification of its strip framing.
7. **6 OJPEG.** Only if the owner reopens it.
