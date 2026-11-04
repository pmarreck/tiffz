#!/usr/bin/env perl
# gen.pl DIR: JPEG-in-TIFF (Compression 7, TIFF Technical Note 2 mode 1)
# fixtures for finding 19, assembled from the JPEG strips in DIR. Each strip
# is a complete JPEG stream. The strips were encoded once with ImageMagick
# 7.1.2-31 (`magick -size WxH gradient:A-B -strip -sampling-factor F
# -quality 90`) and are committed, so this script is deterministic.
#   s16x8_22.jpg   16x8,  Y 2x2, Cb Cr 1x1 (MCU 16x16)
#   s16x16_22.jpg  16x16, Y 2x2, Cb Cr 1x1 (MCU 16x16)
#   s16x16_41.jpg  16x16, Y 4x1, Cb Cr 1x1 (MCU 32x8)
use strict; use warnings;
my $dir = shift or die "usage: gen.pl DIR\n";
sub slurp { local $/; open my $h, '<:raw', "$dir/$_[0]" or die "$_[0]: $!"; my $b = <$h>; $b }

# Classic little-endian TIFF: header, segments, then the IFD and its values.
sub tiff {
    my ($fields, $segments, $tiled) = @_;
    my $buf = "II" . pack("v", 42) . pack("V", 0);
    my (@offs, @counts);
    for my $s (@$segments) {
        $buf .= "\0" if length($buf) % 2;
        push @offs, length $buf; push @counts, length $s; $buf .= $s;
    }
    $buf .= "\0" if length($buf) % 2;
    my %f = %$fields;
    $f{$tiled ? 324 : 273} = [4, \@offs];
    $f{$tiled ? 325 : 279} = [4, \@counts];
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
sub ycbcr {
    my (%o) = @_;
    my %f = (
        256 => [3, [$o{width}]], 257 => [3, [$o{length}]], 258 => [3, [8, 8, 8]],
        259 => [3, [7]], 262 => [3, [6]], 277 => [3, [3]], 284 => [3, [1]],
        530 => [3, $o{sub}],
    );
    if ($o{tile}) { $f{322} = [3, [$o{tile}[0]]]; $f{323} = [3, [$o{tile}[1]]] }
    else { $f{278} = [3, [$o{rows}]] }
    return \%f;
}
sub put { open my $h, '>:raw', "$dir/$_[0]" or die; print $h $_[1]; close $h }

# Control: two 16-row strips with 2x2 sampling, RowsPerStrip 16 = 8 * Vmax.
put('rows-ok.tif', tiff(ycbcr(width => 16, length => 32, rows => 16, sub => [2, 2]),
    [slurp('s16x16_22.jpg'), slurp('s16x16_22.jpg')], 0));
# Rule 1: two 8-row strips with 2x2 sampling, RowsPerStrip 8 < 8 * Vmax = 16.
put('rows-bad.tif', tiff(ycbcr(width => 16, length => 16, rows => 8, sub => [2, 2]),
    [slurp('s16x8_22.jpg'), slurp('s16x8_22.jpg')], 0));
# Rule 2: one 16x16 tile with 4x1 sampling, TileWidth 16 < 8 * Hmax = 32.
put('tile-width-bad.tif', tiff(ycbcr(width => 16, length => 16, tile => [16, 16], sub => [4, 1]),
    [slurp('s16x16_41.jpg')], 1));
