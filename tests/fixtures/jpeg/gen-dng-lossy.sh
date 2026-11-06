#!/usr/bin/env bash
# Regenerate dng-lossy-linear-16x16.jpg and dng-lossy-mask-16x16.jpg, the
# baseline JPEG streams tests/fixture_test.zig wraps as DNG Lossy JPEG
# (Compression 34892) under LinearRaw and PhotometricMask. Each sample
# (x, y, c) of the 16x16 source is 4x + 2y + 30c + 20. Encoded with
# libjpeg-turbo 3.1.4 cjpeg -quality 95 (YCbCr 4:2:0 for three components);
# djpeg returns the source within 2 (three components) and 1 (one).
# Usage: gen-dng-lossy.sh OUTDIR (needs cjpeg and perl on PATH).
set -eu
out="${1:?usage: gen-dng-lossy.sh OUTDIR}"
ramp() { # ramp W H C: binary PPM (C=3) or PGM (C=1)
	perl -e 'my ($w, $h, $c) = @ARGV; binmode STDOUT;
		print(($c == 3 ? "P6" : "P5"), "\n$w $h\n255\n");
		for my $y (0 .. $h - 1) { for my $x (0 .. $w - 1) { for my $k (0 .. $c - 1) {
			print pack("C", 4 * $x + 2 * $y + 30 * $k + 20) } } }' "$@"
}
ramp 16 16 3 | cjpeg -quality 95 -outfile "$out/dng-lossy-linear-16x16.jpg"
ramp 16 16 1 | cjpeg -quality 95 -outfile "$out/dng-lossy-mask-16x16.jpg"
