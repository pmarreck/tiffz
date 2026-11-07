#!/usr/bin/env perl
# gen.pl OUTDIR: spec-built classic little-endian TIFFs for validate's
# KNOWN_DEFECT registry controls (Kodak MinSampleValue, Canon CR2 IFD0
# BitsPerSample). Each IFD is a list of [tag, type, [values]] or
# [tag, 'ascii', "string"]; RATIONAL (type 5) values are numerator,
# denominator pairs. Entries are written in ascending tag order and values
# that do not fit in 4 bytes go out of line, word-aligned.
use strict; use warnings;
my $out = shift or die "usage: gen.pl OUTDIR\n";
my %size = (1 => 1, 2 => 1, 3 => 2, 4 => 4);

# Lay out IFDs (IFD0 chain plus at most one SubIFD hanging off IFD0) and a
# strip per IFD. Returns the file bytes.
sub build {
    my (%a) = @_;
    my @ifds = @{ $a{ifds} };          # each: { entries => [...], strip => bytes }
    my $sub = $a{subifd};              # optional: { entries, strip }, child of IFD0
    my @all = (@ifds, ($sub ? ($sub) : ()));
    my $buf = "II" . pack("v", 42) . pack("V", 0);
    # Strips first, right after the header.
    for my $d (@all) {
        $buf .= "\0" if length($buf) % 2;
        $d->{strip_off} = length $buf;
        $buf .= $d->{strip};
    }
    # Offsets of each IFD: compute sizes, values follow each IFD.
    my $pos = length $buf; $pos++ if $pos % 2;
    for my $d (@all) {
        my @e = sort { $a->[0] <=> $b->[0] } @{ $d->{entries} };
        $d->{sorted} = \@e;
        $d->{off} = $pos;
        my $len = 2 + 12 * @e + 4;
        for my $x (@e) { my $n = vlen($x); $len += $n + ($n % 2) if $n > 4 }
        $pos += $len; $pos++ if $pos % 2;
    }
    $buf .= "\0" x ($pos - length $buf);
    for my $i (0 .. $#all) {
        my $d = $all[$i];
        my $next = ($i < $#ifds) ? $ifds[$i + 1]{off} : 0;
        $next = 0 if $sub && $d == $sub;
        my $ifd = pack("v", scalar @{ $d->{sorted} });
        my $vals = '';
        my $vstart = $d->{off} + 2 + 12 * @{ $d->{sorted} } + 4;
        for my $x (@{ $d->{sorted} }) {
            my ($tag, $type, $v) = @$x;
            $v = [ $d->{strip_off} ] if $tag == 273 && !@$v;
            $v = [ $sub->{off} ] if $tag == 330 && $sub && !@$v;
            my ($t, $bytes, $count) = encode($type, $v);
            if (length $bytes <= 4) {
                $ifd .= pack("v v V", $tag, $t, $count) . $bytes . ("\0" x (4 - length $bytes));
            } else {
                $ifd .= pack("v v V V", $tag, $t, $count, $vstart + length $vals);
                $vals .= $bytes; $vals .= "\0" if length($vals) % 2;
            }
        }
        $ifd .= pack("V", $next);
        substr($buf, $d->{off}, length($ifd) + length($vals)) = $ifd . $vals;
    }
    substr($buf, 4, 4) = pack("V", $ifds[0]{off});
    return $buf;
}
sub encode {
    my ($type, $v) = @_;
    return (2, $v . "\0", length($v) + 1) if $type eq 'ascii';
    return (5, pack("V*", @$v), @$v / 2) if $type eq '5';
    my $f = { 1 => 'C', 3 => 'v', 4 => 'V' }->{$type};
    return ($type, pack("$f*", @$v), scalar @$v);
}
sub vlen { my ($t, $type, $v) = @{ $_[0] }; return $type eq 'ascii' ? length($v) + 1 : $type eq '5' ? 4 * @$v : $size{$type} * @$v }

sub write_file { my ($name, $bytes) = @_; open my $fh, '>:raw', "$out/$name" or die; print $fh $bytes; close $fh }

# Kodak: 2x2 uncompressed YCbCr, no chroma subsampling, 8-bit, with the
# baseline XResolution and YResolution (72/1 inch), so the fixtures carry only
# the MinSampleValue pattern (validate, 2026-11-05).
sub kodak_entries {
    my (%o) = @_;
    my $spp = $o{spp} // 3;
    my @e = (
        [256, 3, [2]], [257, 3, [2]], [258, 3, [(8) x $spp]], [259, 3, [1]],
        [262, 3, [6]], [271, 'ascii', 'Kodak'], [273, 4, []], [277, 3, [$spp]],
        [278, 3, [2]], [279, 4, [4 * $spp]],
        [280, 3, [(0) x ($o{min_count} // 1)]],
        [281, 3, [(255) x ($o{max_count} // $spp)]],
        [282, 5, [72, 1]], [283, 5, [72, 1]],
        [284, 3, [1]], [296, 3, [2]], [530, 3, [1, 1]],
    );
    push @e, [338, 3, [(0) x ($spp - 3)]] if $spp > 3;
    return \@e;
}
sub kodak {
    my (%o) = @_;
    my $spp = $o{spp} // 3;
    return build(ifds => [{ entries => kodak_entries(%o), strip => chr(128) x (4 * $spp) }]);
}

# Canon: IFD0 shaped like a CR2 IFD0 (old-style JPEG preview, BitsPerSample
# for three samples, no SamplesPerPixel or PhotometricInterpretation).
sub canon_ifd0 {
    my (%o) = @_;
    my @e = (
        [256, 3, [8]], [257, 3, [8]], [258, 3, $o{bps} // [8, 8, 8]], [259, 3, [6]],
        [271, 'ascii', 'Canon'], [272, 'ascii', 'Synthetic CR2 IFD0'],
        [273, 4, []], [274, 3, [1]], [279, 4, [4]],
        [282, 5, undef], [283, 5, undef], [296, 3, [2]],
    );
    @e = grep { $_->[1] ne '5' } @e;    # no RATIONAL support needed
    push @e, @{ $o{extra} // [] };
    return \@e;
}
my $jpeg_stub = "\xFF\xD8\xFF\xD9";   # SOI EOI: old-style JPEG strip, not decoded

mkdir $out;
write_file('kodak-minsamplevalue-exemplar.tif', kodak());
write_file('kodak-minsamplevalue-near-count2.tif', kodak(min_count => 2));
write_file('kodak-minsamplevalue-near-spp4.tif', kodak(spp => 4));
write_file('kodak-minsamplevalue-near-max-short.tif', kodak(max_count => 1));
write_file('canon-cr2-ifd0-bps-exemplar.tif',
    build(ifds => [{ entries => canon_ifd0(), strip => $jpeg_stub }]));
write_file('canon-cr2-ifd0-bps-near-8-8-16.tif',
    build(ifds => [{ entries => canon_ifd0(bps => [8, 8, 16]), strip => $jpeg_stub }]));
write_file('canon-cr2-ifd0-bps-near-count2.tif',
    build(ifds => [{ entries => canon_ifd0(bps => [8, 8]), strip => $jpeg_stub }]));
# The same entry in a SubIFD: IFD0 is sound (SamplesPerPixel 3, YCbCr).
write_file('canon-cr2-ifd0-bps-near-subifd.tif',
    build(
        ifds => [{ entries => canon_ifd0(extra => [[262, 3, [6]], [277, 3, [3]], [330, 4, []]]), strip => $jpeg_stub }],
        subifd => { entries => canon_ifd0(), strip => $jpeg_stub },
    ));

# Near-match: three YCbCr IFDs; MinSampleValue is sound (count 3) in IFD0 and
# count 1 in IFD1 and IFD2, so the signature must be evaluated per IFD.
{
    my @ifds;
    for my $min_count (3, 1, 1) {
        push @ifds, { entries => kodak_entries(min_count => $min_count), strip => chr(128) x 12 };
    }
    write_file('kodak-minsamplevalue-near-one-ifd-sound.tif', build(ifds => \@ifds));
}
# Passing control: the Canon IFD0 shape with SamplesPerPixel 3 written.
write_file('canon-cr2-ifd0-bps-control-spp-present.tif',
    build(ifds => [{ entries => canon_ifd0(extra => [[277, 3, [3]]]), strip => $jpeg_stub }]));
