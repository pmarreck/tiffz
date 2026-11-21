#!/usr/bin/env bash
# gen.sh OUTDIR: WebP (Compression 50001) fixtures encoded by libtiff 4.7.2's
# tiffcp with libwebp 1.6.0. The *-none.tif oracles are libtiff's decodes of
# the coded files (tiffcp -c none), keeping their layout.
#   rgb8-lossless.tif  16x16 RGB, lossless (webp:p100), one strip
#   rgb8-lossy.tif     the same, lossy (webp:p75)
#   rgb8-strips.tif    lossless in 5-row strips (the last strip is 1 row)
#   rgb8-tiled.tif     lossless, one 16x16 tile
#   rgba8-lossless.tif 16x8 RGBA (unassociated alpha), lossless
# Sources: this repo's photometric/rgb_separate.tif, and a 16x8 RGBA image
# written below. Run from the repository root. Needs perl and tiffcp.
set -eu
out="${1:?usage: gen.sh OUTDIR}"
tmp=$(mktemp -d)
perl -e '
	my ($w, $h) = (16, 8); my $data = "";
	for my $y (0 .. $h - 1) { for my $x (0 .. $w - 1) {
		$data .= pack("C4", 15 * $x, 30 * $y, (7 * $x + 11 * $y) % 256, 255 - 13 * $x - 3 * $y) } }
	my @e = ([256, 3, $w], [257, 3, $h], [258, 3, 8], [259, 3, 1], [262, 3, 2], [273, 4, 0],
		[277, 3, 4], [278, 3, $h], [279, 4, length $data], [284, 3, 1], [338, 3, 2]);
	my $n = @e; my $ifd_end = 8 + 2 + 12 * $n + 4; my $bps = pack("v4", 8, 8, 8, 8);
	my $strip = $ifd_end + length $bps; my @packed;
	for my $x (@e) {
		my ($tag, $type, $v) = @$x;
		if ($tag == 258) { push @packed, pack("vvVV", 258, 3, 4, $ifd_end); next }
		$v = $strip if $tag == 273;
		push @packed, $type == 3 ? pack("vvVvv", $tag, 3, 1, $v, 0) : pack("vvVV", $tag, 4, 1, $v);
	}
	open my $f, ">:raw", $ARGV[0] or die "$ARGV[0]: $!";
	print $f "II", pack("vV", 42, 8), pack("v", $n), @packed, pack("V", 0), $bps, $data;
' "$tmp/rgba.tif"
p=tests/fixtures/photometric/rgb_separate.tif
tiffcp -p contig -c webp:p100 "$p" "$out/rgb8-lossless.tif"
tiffcp -p contig -c webp:p75 "$p" "$out/rgb8-lossy.tif"
tiffcp -p contig -r 5 -c webp:p100 "$p" "$out/rgb8-strips.tif"
tiffcp -p contig -t -w 16 -l 16 -c webp:p100 "$p" "$out/rgb8-tiled.tif"
tiffcp -c webp:p100 "$tmp/rgba.tif" "$out/rgba8-lossless.tif"
for f in rgb8-lossless rgb8-lossy rgb8-strips rgb8-tiled rgba8-lossless; do
	tiffcp -c none "$out/$f.tif" "$out/$f-none.tif"
done
mv "$tmp" "${TMPDIR:-/tmp}/webp-gen-scratch.$$"
