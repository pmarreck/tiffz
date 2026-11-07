#!/usr/bin/env bash
# gen.sh OUTDIR: SGILog (Compression 34676) fixtures encoded by libtiff 4.7.2.
#   logl-37x5.tif   Photometric LogL (32844), one 16-bit signed sample
#   logluv-37x5.tif Photometric LogLuv (32845), three 16-bit signed samples
# Each comes from an uncompressed source written below, then
# `tiffcp -c sgilog`; the oracles *-none.tif are libtiff's decodes of the
# coded files (`tiffcp -c none`). LogLuv quantizes u and v to 8 bits when
# it encodes, so its oracle is libtiff's decode, not the source.
# Needs perl and libtiff's tiffcp on PATH.
set -eu
out="${1:?usage: gen.sh OUTDIR}"
src() { # src PATH PHOTOMETRIC SAMPLES: 37x5 uncompressed int16 source
	perl -e '
		my ($path, $photo, $spp) = @ARGV; my ($w, $h) = (37, 5);
		my $data = "";
		for my $y (0 .. $h - 1) { for my $x (0 .. $w - 1) {
			# L: a sign bit of 0 and a 15-bit log value; u, v near the white point.
			$data .= pack("s<", 13000 + 97 * $x + 211 * $y);
			if ($spp == 3) { $data .= pack("s<", 6000 + 40 * $x) . pack("s<", 15000 - 30 * $y) }
		} }
		my @e = ([256, 3, 1, $w], [257, 3, 1, $h], [258, 3, $spp, 16], [259, 3, 1, 1], [262, 3, 1, $photo],
			[273, 4, 1, 0], [277, 3, 1, $spp], [278, 3, 1, $h], [279, 4, 1, length $data], [339, 3, $spp, 2]);
		my $n = @e; my $ifd_end = 8 + 2 + 12 * $n + 4; my $extra = "";
		my @packed;
		for my $x (@e) {
			my ($tag, $type, $count, $v) = @$x;
			if ($count == 1) { push @packed, pack("vvV", $tag, $type, 1) . pack("vv", $v, 0) . ""; next }
			# a SHORT array of 3 goes out of line
			push @packed, pack("vvV", $tag, $type, $count) . pack("V", $ifd_end + length $extra);
			$extra .= pack("v*", ($v) x $count);
		}
		my $strip = $ifd_end + length $extra;
		for my $i (0 .. $#e) { if ($e[$i][0] == 273) { $packed[$i] = pack("vvV", 273, 4, 1) . pack("V", $strip) }
			elsif ($e[$i][1] == 4 && $e[$i][2] == 1) { $packed[$i] = pack("vvV", $e[$i][0], 4, 1) . pack("V", $e[$i][3]) } }
		open my $f, ">:raw", $path or die "$path: $!";
		print $f "II", pack("vV", 42, 8), pack("v", $n), @packed, pack("V", 0), $extra, $data;
	' "$@"
}
tmp=$(mktemp -d)
src "$tmp/logl-src.tif" 32844 1
src "$tmp/logluv-src.tif" 32845 3
tiffcp -c sgilog "$tmp/logl-src.tif" "$out/logl-37x5.tif"
tiffcp -c sgilog "$tmp/logluv-src.tif" "$out/logluv-37x5.tif"
tiffcp -c none "$out/logl-37x5.tif" "$out/logl-37x5-none.tif"
tiffcp -c none "$out/logluv-37x5.tif" "$out/logluv-37x5-none.tif"
mv "$tmp" "${TMPDIR:-/tmp}/sgilog-gen-scratch.$$"
