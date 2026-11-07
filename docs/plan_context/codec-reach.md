# Codec reach

On 2026-11-06 the owner, answering a report that undecodable files now read "unsupported", said: "We need to support those compression algorithms, simple as that. Our goal is 100% TIFF/RAW coverage (in conjunction with rawz), to the extent technically-possible."

INTENT.md had left "JPEG2000-in-TIFF, JBIG, and other undispatched codecs" unclaimed "until an explicit owner decision". This note takes the 2026-11-06 statement as that decision for every undispatched TIFF codec that is not blocked.

OJPEG (Compression 6) was blocked by name on 2026-08-27 ("Do not reopen"). The owner reopened it on 2026-11-07: "do Compression 6. Overriding that 'do not reopen'".

WebP and LZMA (owner, 2026-11-07): "wrap an existing project in Zig unless it is GPL, in which case, rewrite it from scratch in Zig". libwebp is BSD-3-Clause and liblzma is 0BSD, so neither needs a rewrite. LZMA wraps liblzma (xz 5.8.3), decoder subset, built from the pinned upstream release by deps/liblzma. Zig 0.16's std.compress.xz was tried first and ruled out: it rejects multi-filter blocks such as libtiff's Delta + LZMA2, does not verify block checks, and panics in `discard`.


Vendor RAW codecs (Sony ARW 32767 and the others in rawz's scope) stay with rawz.

## Supported before this program

1, 3, 4, 5, 7, 8, 32773, 32946, 34887 (LERC) and 50000 (zstd).

## What the local corpora use

This is a survey of 589 TIFF and DNG files: tiffz's committed fixtures, validate's ground-truth examples and the scratch GDAL and raw.pixls.us sets. Only IFD 0 and chained IFDs were counted, not SubIFDs. Undecoded codes, by number of files:

| Code | Scheme | Files | Notes |
|---|---|---|---|
| 6 | Old-style JPEG (TIFF 6.0 section 22) | 27 | reopened (owner, 2026-11-07) |
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
5. **50001 WebP, 34925 LZMA.** Decided 2026-11-07. LZMA landed 2026-11-07 through liblzma; WebP wraps libwebp 1.6.0.
6. **34712 JPEG 2000 and 50002 / 52546 JPEG XL.** These go through jpegz's jp2z and libjxlz legs (INTENT: one jpegz instance per compilation), once exemplars exist. JPEG XL done 2026-11-07 through jpegz.jpegxl (validate, then decode the first frame), with exemplars made by libjxl's cjxl and checked by djxl; JPEG 2000 still needs an exemplar and a specification of its strip framing.
7. **6 OJPEG.** Reopened by the owner 2026-11-07.

## FillOrder 2 under non-CCITT codecs (open, 2026-11-07)

Found while checking LZMA against libtiff. libtiff 4.7.2's `tiffcp -c lzma`
(likewise lzw, zip and zstd) of `tests/fixtures/ccitt_g3/fax2d.tif`, a 1-bit
FillOrder 2 file, keeps FillOrder 2 and stores the coded stream with every
byte's bits reversed. The LZMA strip begins `bf ec 5e 1a 5a 00`, which is the
xz magic `fd 37 7a 58 5a 00` bit-reversed. On reading, libtiff reverses the
raw bytes before any codec that does not handle FillOrder itself.

tiffz applies FillOrder only inside its CCITT decoders, so all four copies
fail Malformed. TIFF 6.0 p. 32: "FillOrder = 2 should be used only when
BitsPerSample = 1 and the data is either uncompressed or compressed using
CCITT 1D or 2D compression, to avoid potentially ambigous situations." That
is a should, not a shall.

Questions for validate:

- Should tiffz decode these as libtiff does?
- How should the should-row be classed?
