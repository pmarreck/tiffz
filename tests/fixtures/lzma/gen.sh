#!/usr/bin/env bash
# gen.sh OUTDIR: LZMA (Compression 34925) fixtures encoded by libtiff 4.7.2's
# tiffcp -c lzma (Delta then LZMA2 in an .xz stream, no check), from this
# repo's 16x16 photometric fixtures. The *-none.tif oracles are libtiff's
# decodes of the coded files (tiffcp -c none), keeping their layout.
#   rgb16-lzma.tif        RGB 16-bit chunky, one strip (Delta distance 2)
#   rgb16-be-lzma.tif     the same, big-endian
#   rgb16-tiled-lzma.tif  the same, one 16x16 tile
#   rgb8-planar-lzma.tif  RGB 8-bit planar separate, three strips
# Run from the repository root. Needs libtiff's tiffcp on PATH.
set -eu
out="${1:?usage: gen.sh OUTDIR}"
p=tests/fixtures/photometric
tiffcp -c lzma "$p/rgb16.tif" "$out/rgb16-lzma.tif"
tiffcp -B -c lzma "$p/rgb16.tif" "$out/rgb16-be-lzma.tif"
tiffcp -t -w 16 -l 16 -c lzma "$p/rgb16.tif" "$out/rgb16-tiled-lzma.tif"
tiffcp -c lzma "$p/rgb_separate.tif" "$out/rgb8-planar-lzma.tif"
for f in rgb16-lzma rgb16-tiled-lzma rgb8-planar-lzma; do
	tiffcp -c none "$out/$f.tif" "$out/$f-none.tif"
done
# tiffcp writes host byte order unless told; keep the oracle big-endian.
tiffcp -B -c none "$out/rgb16-be-lzma.tif" "$out/rgb16-be-lzma-none.tif"
