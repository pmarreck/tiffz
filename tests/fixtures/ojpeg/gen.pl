#!/usr/bin/env perl
# gen.pl JPEG OUTDIR: wrap one baseline JPEG (cjpeg, 32x32 RGB, 4:2:0, a
# restart marker every MCU row) as old-style JPEG (Compression 6) TIFFs in the
# three layouts libtiff's tif_ojpeg.c reads:
#   ojpeg-jif.tif     JPEGInterchangeFormat holds the whole JPEG; one strip
#                     points at its scan data (the libtiff pics smallliz.tif
#                     shape)
#   ojpeg-tables.tif  JPEGQTables, JPEGDCTables and JPEGACTables hold the
#                     tables; two 16-row strips hold the entropy-coded data,
#                     split at the restart marker (which libtiff reinserts)
#   ojpeg-strip.tif   one strip holds the whole JPEG, no table tags (the
#                     Canon CR2 IFD0 preview shape)
#   ojpeg-cut.tif     ojpeg-tables.tif with its second strip cut to 4 bytes
# Every file is little-endian classic TIFF, 32x32, YCbCr 2x2, 8-bit.
use strict;
use warnings;

my ($jpeg_path, $out) = @ARGV;
die "usage: gen.pl JPEG OUTDIR\n" unless defined $out;
open my $fh, '<:raw', $jpeg_path or die "$jpeg_path: $!";
my $jpeg = do { local $/; <$fh> };
close $fh;

# Walk the markers: DQT and DHT tables, the SOS, then the scan data to EOI.
my (%q, %dc, %ac, $scan_start);
my $p = 2;
die "not a JPEG\n" unless substr($jpeg, 0, 2) eq "\xFF\xD8";
while ($p < length $jpeg) {
	my ($ff, $m) = unpack 'CC', substr($jpeg, $p, 2);
	die "marker expected at $p\n" unless $ff == 0xFF;
	my $len = unpack 'n', substr($jpeg, $p + 2, 2);
	my $body = substr($jpeg, $p + 4, $len - 2);
	if ($m == 0xDB) {
		my $o = 0;
		while ($o < length $body) {
			my $pq_tq = ord substr($body, $o, 1);
			die "16-bit DQT\n" if $pq_tq >> 4;
			$q{$pq_tq & 15} = substr($body, $o + 1, 64);
			$o += 65;
		}
	} elsif ($m == 0xC4) {
		my $o = 0;
		while ($o < length $body) {
			my $tc_th = ord substr($body, $o, 1);
			my @counts = unpack 'C16', substr($body, $o + 1, 16);
			my $n = 0;
			$n += $_ for @counts;
			my $table = substr($body, $o + 1, 16 + $n);
			if ($tc_th >> 4) { $ac{$tc_th & 15} = $table } else { $dc{$tc_th & 15} = $table }
			$o += 17 + $n;
		}
	} elsif ($m == 0xDA) {
		$scan_start = $p + 2 + $len;
		last;
	}
	$p += 2 + $len;
}
die "no SOS\n" unless defined $scan_start;
my $eoi = rindex $jpeg, "\xFF\xD9";
my $scan = substr($jpeg, $scan_start, $eoi - $scan_start);
my @rst = ();
while ($scan =~ /\xFF([\xD0-\xD7])/g) { push @rst, pos($scan) - 2 }
die "expected one restart marker, found " . scalar(@rst) . "\n" unless @rst == 1;
my @strips = (substr($scan, 0, $rst[0]), substr($scan, $rst[0] + 2));

# A classic little-endian TIFF: header, then the blobs, then IFD 0. Each
# entry is [tag, type, count, value-or-blob-key]; blob offsets are patched.
sub tiff {
	my ($path, $blobs, $entries) = @_;
	my $data = '';
	my %at;
	for my $b (@$blobs) {
		$data .= "\0" if length($data) % 2;
		$at{$b->[0]} = 8 + length $data;
		$data .= $b->[1];
	}
	$data .= "\0" if length($data) % 2;
	my $ifd = 8 + length $data;
	my @e = sort { $a->[0] <=> $b->[0] } @$entries;
	my $extra = '';
	my $extra_at = $ifd + 2 + 12 * @e + 4;
	my $dir = pack 'v', scalar @e;
	for my $e (@e) {
		my ($tag, $type, $count, $v) = @$e;
		my @vals = map { exists $at{$_} ? $at{$_} : $_ } (ref $v ? @$v : ($v));
		my $size = { 3 => 2, 4 => 4 }->{$type};
		my $packed = join '', map { pack($type == 3 ? 'v' : 'V', $_) } @vals;
		if ($size * $count <= 4) {
			$dir .= pack('vvV', $tag, $type, $count) . $packed . ("\0" x (4 - length $packed));
		} else {
			$dir .= pack('vvVV', $tag, $type, $count, $extra_at + length $extra);
			$extra .= $packed;
		}
	}
	$dir .= pack 'V', 0;
	open my $o, '>:raw', $path or die "$path: $!";
	print $o "II*\0", pack('V', $ifd), $data, $dir, $extra;
	close $o;
}

my @common = (
	[256, 3, 1, 32], [257, 3, 1, 32], [258, 3, 3, [8, 8, 8]], [259, 3, 1, 6],
	[262, 3, 1, 6], [277, 3, 1, 3], [284, 3, 1, 1], [530, 3, 2, [2, 2]],
);

tiff("$out/ojpeg-jif.tif", [['jif', $jpeg]], [
	@common, [273, 4, 1, 0], [278, 3, 1, 32], [279, 4, 1, length $scan],
	[513, 4, 1, 'jif'], [514, 4, 1, length $jpeg],
]);
# The strip offset points inside the JPEGInterchangeFormat bytes.
{
	open my $i, '<:raw', "$out/ojpeg-jif.tif" or die;
	my $t = do { local $/; <$i> };
	close $i;
	my $jif_at = index $t, $jpeg;
	my $want = $jif_at + $scan_start;
	my $ifd = unpack 'V', substr($t, 4, 4);
	my $n = unpack 'v', substr($t, $ifd, 2);
	for my $k (0 .. $n - 1) {
		my $e = $ifd + 2 + 12 * $k;
		substr($t, $e + 8, 4) = pack 'V', $want if unpack('v', substr($t, $e, 2)) == 273;
	}
	open my $o, '>:raw', "$out/ojpeg-jif.tif" or die;
	print $o $t;
	close $o;
}

sub tables_tiff {
	my ($path, @s) = @_;
	tiff($path, [['q0', $q{0}], ['q1', $q{1}], ['dc0', $dc{0}], ['dc1', $dc{1}], ['ac0', $ac{0}], ['ac1', $ac{1}], ['s0', $s[0]], ['s1', $s[1]]], [
		@common, [273, 4, 2, ['s0', 's1']], [278, 3, 1, 16], [279, 4, 2, [length $s[0], length $s[1]]],
		[512, 3, 1, 1], [519, 4, 3, ['q0', 'q1', 'q1']], [520, 4, 3, ['dc0', 'dc1', 'dc1']], [521, 4, 3, ['ac0', 'ac1', 'ac1']],
	]);
}
tables_tiff("$out/ojpeg-tables.tif", @strips);
tables_tiff("$out/ojpeg-cut.tif", $strips[0], substr($strips[1], 0, 4));

tiff("$out/ojpeg-strip.tif", [['s', $jpeg]], [
	@common, [273, 4, 1, 's'], [278, 3, 1, 32], [279, 4, 1, length $jpeg],
]);
