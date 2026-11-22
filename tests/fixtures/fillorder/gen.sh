#!/usr/bin/env bash
# gen.sh OUTDIR: FillOrder 2 fixtures written by libtiff 4.7.2, which stores
# every coded byte bit-reversed under FillOrder 2 and reverses it again on
# reading for every codec except CCITT, JPEG and JBIG.
#   fax2d-{lzw,zip,zstd,lzma}.tif  tiffcp -c CODEC of ccitt_g3/fax2d.tif
#                                  (1-bit, FillOrder 2 kept)
#   fax2d-msb-lzw.tif              oracle: the same image, FillOrder 1, LZW
#   crop-fo2.tif                   a 64x16 crop of fax2d.tif with ink, uncompressed,
#                                  FillOrder 2 (1-bit: TIFF 6.0's own case)
#   crop-msb.tif                   oracle: the crop, FillOrder 1
#   cmyk-fo2.tif                   photometric/cmyk.tif (8-bit), uncompressed,
#                                  FillOrder 2; oracle: photometric/cmyk.tif
# Run from the repository root. Needs libtiff's tiffcp and tiffcrop on PATH.
set -eu
out="${1:?usage: gen.sh OUTDIR}"
fax=tests/fixtures/ccitt_g3/fax2d.tif
for c in lzw zip zstd lzma; do
	tiffcp -c "$c" "$fax" "$out/fax2d-$c.tif"
done
tiffcp -f msb2lsb -c lzw "$fax" "$out/fax2d-msb-lzw.tif"
tiffcrop -U px -z 400,300,463,315 -c none "$fax" "$out/crop-fo2.tif"
tiffcp -f msb2lsb -c none "$out/crop-fo2.tif" "$out/crop-msb.tif"
tiffcp -f lsb2msb -c none tests/fixtures/photometric/cmyk.tif "$out/cmyk-fo2.tif"
