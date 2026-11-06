#!/usr/bin/env perl
# gen.pl OUTDIR: write next-8x3.tif (Compression 32766, NeXT 2-bit) and
# thunder-8x2.tif (Compression 32809, ThunderScan 4-bit), little-endian
# classic TIFF, BlackIsZero, one strip, from the hand-encoded streams below.
# The oracles next-8x3-none.tif and thunder-8x2-none.tif are libtiff 4.7.2's
# decodes of them, `tiffcp -c none IN OUT`; tests/fixture_test.zig compares
# tiffz's decode of each coded file with the oracle's samples.
use strict; use warnings;
my $out = shift or die "usage: gen.pl OUTDIR\n";

# NeXT, width 8 (2 bytes a row): a literal row (samples 0 1 2 3 3 2 1 0);
# a literal span (byte 1 = 0x00, byte 0 left white); run mode (4 of gray 1,
# 3 of gray 2, 1 of gray 0).
my $next = pack("C*", 0x00, 0x1B, 0xE4, 0x40, 0x00, 0x01, 0x00, 0x01, 0x00, 0x44, 0x83, 0x01);

# ThunderScan, width 8: row 0 is raw 5, a run of 2, 2-bit deltas +1 -1 skip,
# 3-bit deltas +3 -2, raw 15 (5 5 5 6 5 8 6 15); row 1 is raw 0, 3-bit
# deltas +3 +3, 2-bit deltas +1 +1 -1, a run of 2 (0 3 6 7 8 7 7 7).
my $thunder = pack("C*", 0xC5, 0x02, 0x40 | (1 << 4) | (3 << 2) | 2, 0x80 | (3 << 3) | 6, 0xCF,
	0xC0, 0x80 | (3 << 3) | 3, 0x40 | (1 << 4) | (1 << 2) | 3, 0x02);

sub tiff {
	my ($path, $w, $h, $bps, $comp, $strip) = @_;
	my @e = ([256, 4, $w], [257, 4, $h], [258, 3, $bps], [259, 3, $comp], [262, 3, 1],
		[273, 4, 0], [277, 3, 1], [278, 4, $h], [279, 4, length $strip]);
	my $n = @e;
	$e[5][2] = 8 + 2 + 12 * $n + 4;
	my $t = "II" . pack("vV", 42, 8) . pack("v", $n);
	for my $x (@e) {
		my ($tag, $type, $v) = @$x;
		$t .= pack("vvV", $tag, $type, 1) . ($type == 3 ? pack("vv", $v, 0) : pack("V", $v));
	}
	$t .= pack("V", 0) . $strip;
	open my $f, '>:raw', $path or die "$path: $!";
	print $f $t;
	close $f;
}
tiff("$out/next-8x3.tif", 8, 3, 2, 32766, $next);
tiff("$out/thunder-8x2.tif", 8, 2, 4, 32809, $thunder);
