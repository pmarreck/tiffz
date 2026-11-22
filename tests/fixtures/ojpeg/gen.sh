#!/usr/bin/env bash
# gen.sh OUTDIR: old-style JPEG (Compression 6) fixtures. A 32x32 RGB
# gradient is encoded by libjpeg-turbo's cjpeg (quality 90, 4:2:0, a restart
# marker every MCU row) as ojpeg-source.jpg; djpeg's decode of that JPEG is
# the oracle, ojpeg-oracle.rgb (32x32 RGB, no header). gen.pl then wraps the
# JPEG in the layouts libtiff's tif_ojpeg.c reads. Run from the repository
# root. Needs cjpeg, djpeg and perl on PATH.
set -eu
out="${1:?usage: gen.sh OUTDIR}"
here=tests/fixtures/ojpeg
tmp="$(mktemp -d)"
trap 'mv "$tmp" "${TMPDIR:-/tmp}/ojpeg-gen-done.$$"' EXIT
perl -e 'print "P6\n32 32\n255\n"; for my $y (0..31) { for my $x (0..31) { print pack("C3", $x * 8, $y * 8, (($x + $y) * 4) % 256) } }' > "$tmp/src.ppm"
cjpeg -quality 90 -sample 2x2 -restart 1 -outfile "$out/ojpeg-source.jpg" "$tmp/src.ppm"
djpeg -pnm -outfile "$tmp/oracle.ppm" "$out/ojpeg-source.jpg"
tail -c 3072 "$tmp/oracle.ppm" > "$out/ojpeg-oracle.rgb"
perl "$here/gen.pl" "$out/ojpeg-source.jpg" "$out"
