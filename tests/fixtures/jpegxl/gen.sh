#!/usr/bin/env bash
# gen.sh OUTDIR: JPEG XL (Compression 50002) strip fixtures from libjxl's own
# encoder. Each source is a raster from a formula (repeated in
# tests/fixture_test.zig as the oracle), encoded losslessly with
# `cjxl -d 0`; `djxl` must return the source exactly, or this fails.
#   gray8-16x8.tif    one 8-bit sample: (x * 13 + y * 31) mod 256
#   rgb8-12x6.tif     three 8-bit samples: R (x*20+y) mod 256, G (y*40+x) mod 256, B (x*y*7) mod 256
#   gray12-10x4.tif   one 12-bit sample: (x * 397 + y * 1021) mod 4096, BitsPerSample 12
# Needs perl, cjxl and djxl (nixpkgs libjxl) on PATH.
set -eu
out="${1:?usage: gen.sh OUTDIR}"
tmp=$(mktemp -d)
raster() { # raster KIND PATH: write the source as PGM/PPM
	perl -e '
		my ($kind, $path) = @ARGV; open my $f, ">:raw", $path or die;
		if ($kind eq "gray8") { print $f "P5\n16 8\n255\n"; for my $y (0..7) { for my $x (0..15) { print $f chr(($x*13+$y*31)%256) } } }
		elsif ($kind eq "rgb8") { print $f "P6\n12 6\n255\n"; for my $y (0..5) { for my $x (0..11) { print $f chr(($x*20+$y)%256), chr(($y*40+$x)%256), chr(($x*$y*7)%256) } } }
		elsif ($kind eq "gray12") { print $f "P5\n10 4\n4095\n"; for my $y (0..3) { for my $x (0..9) { print $f pack("n", ($x*397+$y*1021)%4096) } } }
	' "$@"
}
wrap() { # wrap JXL TIFF WIDTH HEIGHT SPP PHOTOMETRIC BPS: one strip, Compression 50002
	perl -e '
		my ($jxl, $tif, $w, $h, $spp, $photo, $bps) = @ARGV;
		open my $j, "<:raw", $jxl or die; local $/; my $data = <$j>;
		my @e = ([256,4,1,$w], [257,4,1,$h], [258,3,$spp,$bps], [259,3,1,50002], [262,3,1,$photo],
			[273,4,1,0], [277,3,1,$spp], [278,4,1,$h], [279,4,1,length $data]);
		my $n = @e; my $ifd_end = 8 + 2 + 12*$n + 4; my $extra = "";
		my $bps_off = $ifd_end; $extra = pack("v*", ($bps) x $spp) if $spp > 2;
		my $strip = $ifd_end + length $extra;
		my $body = "";
		for my $x (@e) { my ($tag,$type,$count,$v) = @$x;
			if ($tag == 273) { $body .= pack("vvVV", 273, 4, 1, $strip); next }
			if ($tag == 258 && $count > 2) { $body .= pack("vvVV", 258, 3, $count, $bps_off); next }
			if ($type == 4) { $body .= pack("vvVV", $tag, 4, $count, $v) } else { $body .= pack("vvVvv", $tag, 3, $count, $v, 0) } }
		open my $t, ">:raw", $tif or die;
		print $t "II", pack("vV", 42, 8), pack("v", $n), $body, pack("V", 0), $extra, $data;
	' "$@"
}
for spec in "gray8 16 8 1 1 8 gray8-16x8 pgm" "rgb8 12 6 3 2 8 rgb8-12x6 ppm" "gray12 10 4 1 1 12 gray12-10x4 pgm"; do
	set -- $spec
	raster "$1" "$tmp/$7.$8"
	cjxl -d 0 -e 7 --quiet "$tmp/$7.$8" "$tmp/$7.jxl" >/dev/null 2>&1
	djxl --quiet "$tmp/$7.jxl" "$tmp/$7.back.$8" >/dev/null 2>&1
	cmp "$tmp/$7.$8" "$tmp/$7.back.$8"
	wrap "$tmp/$7.jxl" "$out/$7.tif" "$2" "$3" "$4" "$5" "$6"
done
mv "$tmp" "${TMPDIR:-/tmp}/jxl-gen-scratch.$$"
