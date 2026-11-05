#!/usr/bin/env perl
# gen.pl DIR: Predictor 3 (Adobe Photoshop TIFF Technical Note 3, 2005)
# fixtures beside the GDAL-written ones. TN3 p. 2: "This predictor should
# only be applied to floating point data that has BitsPerSample equal to a
# multiple of 8." Deterministic: no external encoder. Compress::Zlib (core
# Perl) writes the Deflate streams.
#   predictor3_deflate_fp16.tif     8x8, one IEEE half-float sample per
#                                   pixel (SampleFormat 3), value k/64 at
#                                   pixel k. Clean: 16 is a multiple of 8.
#   predictor3_deflate_bps12.tif    8x8, one 12-bit sample per pixel with
#                                   Predictor 3 and SampleFormat 3, so only
#                                   the byte-width rule applies. Corrupt:
#                                   12 is not a multiple of 8, so the
#                                   transform, a split into bytes, is
#                                   undefined.
#   predictor3_deflate_mixed.tif    8x8 RGB float at 32,32,16 with Predictor 3.
#                                   Corrupt: TN3 defines one width per row.
#   predictor2_deflate_mixed.tif    8x8 RGB at 8,8,16 with Predictor 2.
#                                   Clean; tiffz refuses the mixed widths as
#                                   reach (unsupported, exit 4).
#   predictor3_deflate_8bit_float.tif  8x8, 8-bit, SampleFormat 3, Predictor 3.
#                                   Clean (TN3: any multiple of 8).
#   predictor3_deflate_8bit_uint.tif   The same bytes with SampleFormat 1:
#                                   the TN3 should-row, no fault.
use strict; use warnings;
use Compress::Zlib qw(compress);
my $dir = shift or die "usage: gen.pl DIR\n";

# Classic little-endian TIFF: header, one strip, then the IFD and values.
sub tiff {
    my ($fields, $strip) = @_;
    my $buf = "II" . pack("v", 42) . pack("V", 0) . $strip;
    $buf .= "\0" if length($buf) % 2;
    my %f = %$fields;
    $f{273} = [4, [8]];
    $f{279} = [4, [length $strip]];
    my @tags = sort { $a <=> $b } keys %f;
    my $ifd_off = length $buf;
    my $vals_off = $ifd_off + 2 + 12 * @tags + 4;
    my ($ifd, $vals) = (pack("v", scalar @tags), '');
    for my $t (@tags) {
        my ($type, $v) = @{ $f{$t} };
        my $bytes = pack($type == 3 ? 'v*' : 'V*', @$v);
        if (length $bytes <= 4) {
            $ifd .= pack("v v V", $t, $type, scalar @$v) . $bytes . ("\0" x (4 - length $bytes));
        } else {
            $ifd .= pack("v v V V", $t, $type, scalar @$v, $vals_off + length $vals);
            $vals .= $bytes;
        }
    }
    $buf .= $ifd . pack("V", 0) . $vals;
    substr($buf, 4, 4) = pack("V", $ifd_off);
    return $buf;
}
sub put { open my $h, '>:raw', "$dir/$_[0]" or die "$_[0]: $!"; print $h $_[1]; close $h }

# IEEE 754 binary16 bits of k/64 for 0 <= k < 64, exactly: k = 2^m + r
# gives exponent m - 6 and mantissa r / 2^m, a multiple of 1/32.
sub half_bits {
    my ($k) = @_;
    return 0 if $k == 0;
    my $m = 0;
    $m++ while (1 << ($m + 1)) <= $k;
    my $r = $k - (1 << $m);
    return (($m - 6 + 15) << 10) | ($r * 1024 / (1 << $m));
}

# TN3's encoder, per row: put byte b (most significant first) of every
# sample in plane b, planes in order, then difference each byte from the
# one before it, modulo 256.
sub fp_predict_row {
    my ($bytes_per_sample, @samples_be) = @_;
    my $n = @samples_be;
    my @out;
    for my $b (0 .. $bytes_per_sample - 1) {
        push @out, map { ord substr($_, $b, 1) } @samples_be;
    }
    for (my $i = $#out; $i > 0; $i--) { $out[$i] = ($out[$i] - $out[$i - 1]) & 0xFF }
    return pack('C*', @out);
}

my $width = 8;
my $length = 8;
my $raw = '';
for my $row (0 .. $length - 1) {
    $raw .= fp_predict_row(2, map { pack('n', half_bits($row * $width + $_)) } 0 .. $width - 1);
}
put('predictor3_deflate_fp16.tif', tiff({
    256 => [3, [$width]], 257 => [3, [$length]], 258 => [3, [16]], 259 => [3, [8]],
    262 => [3, [1]], 277 => [3, [1]], 278 => [3, [$length]], 284 => [3, [1]],
    317 => [3, [3]], 339 => [3, [3]],
}, compress($raw, 9)));

# 12 bits per sample: 8 * 12 / 8 = 12 bytes per row. The bytes are a plain
# gradient; no reading of them is defined under Predictor 3.
put('predictor3_deflate_bps12.tif', tiff({
    256 => [3, [$width]], 257 => [3, [$length]], 258 => [3, [12]], 259 => [3, [8]],
    262 => [3, [1]], 277 => [3, [1]], 278 => [3, [$length]], 284 => [3, [1]],
    317 => [3, [3]], 339 => [3, [3]],
}, compress(pack('C*', map { $_ & 0xFF } 0 .. 12 * $length - 1), 9)));

# Mixed sample widths (validate, 2026-11-05). TN3's DecodeFPDelta takes a
# single bytesPerSample for every sample of a row, so a Predictor 3 image
# with mixed widths has no specified decode: a fault on Predictor. TIFF 6.0
# defines Predictor 2 per sample; tiffz refuses mixed widths there as reach
# until it implements them. The strip bytes are a plain gradient.
put('predictor3_deflate_mixed.tif', tiff({
    256 => [3, [$width]], 257 => [3, [$length]], 258 => [3, [32, 32, 16]], 259 => [3, [8]],
    262 => [3, [2]], 277 => [3, [3]], 278 => [3, [$length]], 284 => [3, [1]],
    317 => [3, [3]], 339 => [3, [3, 3, 3]],
}, compress(pack('C*', map { $_ & 0xFF } 0 .. 10 * $width * $length - 1), 9)));
put('predictor2_deflate_mixed.tif', tiff({
    256 => [3, [$width]], 257 => [3, [$length]], 258 => [3, [8, 8, 16]], 259 => [3, [8]],
    262 => [3, [2]], 277 => [3, [3]], 278 => [3, [$length]], 284 => [3, [1]],
    317 => [3, [2]],
}, compress(pack('C*', map { $_ & 0xFF } 0 .. 4 * $width * $length - 1), 9)));

# 8-bit Predictor 3 (validate, 2026-11-05): TN3 allows any multiple of 8,
# and with one-byte samples the byte shuffle is the identity. Pixel k holds
# the byte 3k mod 256. The float file is clean; the integer one is the
# SampleFormat should-row (an INFO record once that row lands). libtiff
# refuses both, so the decoded bytes are checked against k directly.
my $raw8 = '';
for my $row (0 .. $length - 1) {
    $raw8 .= fp_predict_row(1, map { pack('C', (3 * ($row * $width + $_)) & 0xFF) } 0 .. $width - 1);
}
for my $variant (['predictor3_deflate_8bit_float.tif', 3], ['predictor3_deflate_8bit_uint.tif', undef]) {
    my ($file, $format) = @$variant;
    my %f = (
        256 => [3, [$width]], 257 => [3, [$length]], 258 => [3, [8]], 259 => [3, [8]],
        262 => [3, [1]], 277 => [3, [1]], 278 => [3, [$length]], 284 => [3, [1]],
        317 => [3, [3]],
    );
    $f{339} = [3, [$format]] if defined $format;
    put($file, tiff(\%f, compress($raw8, 9)));
}
