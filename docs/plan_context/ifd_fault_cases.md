# IFD-entry faults tiffz accepts silently

Twelve corruption cases from the gating campaign (master 42, 385 trials per
profile, corruption-reader 0.8.0, tiffz 4bba9948) that tiffz accepts with an
unchanged finding set, while libtiff 4.7.2 `tiffinfo -D` reports a
diagnostic the unmutated seed does not produce. Each is a single changed
byte in a tracked fixture, inside an IFD entry. None touches sample data.

Status: kept for the pending rulings. validate decides error or warning
(asked 2026-11-03) and Einstein signs off on the Namespace B codes
(proposed 17 `ifd_entries_unsorted_tolerated`, 18 `tag_value_ignored`).
Keep these cases and the current floors until both answer.

| # | Seed | Offset | Old | New | libtiff diagnostic |
|---|---|---|---|---|---|
| 1 | tests/fixtures/zstd/rgb_zstd.tif | 134 | 0x00 | 0x10 | Incorrect count for "TransferFunction"; tag ignored |
| 2 | tests/fixtures/lerc/gray16_lerc.tif | 134 | 0x01 | 0x21 | SampleFormat count 33, SamplesPerPixel 1; bad value 10825 for SampleFormat |
| 3 | tests/fixtures/geotiff/gray16_geotiff.tif | 119 | 0x01 | 0x21 | tags are not sorted in ascending order |
| 4 | tests/fixtures/geotiff/gray16_geotiff.tif | 139 | 0x00 | 0x01 | bad value 257 for SampleFormat |
| 5 | tests/fixtures/photometric/ycbcr.tif | 911 | 0x01 | 0x11 | tags are not sorted in ascending order |
| 6 | tests/fixtures/photometric/ycbcr.tif | 871 | 0x00 | 0x01 | bad value 257 for Orientation |
| 7 | tests/fixtures/photometric/cmyk.tif | 1096 | 0x03 | 0x0b | incompatible type for FillOrder; tag ignored |
| 8 | tests/fixtures/photometric/rgb16.tif | 1583 | 0x01 | 0x21 | tags are not sorted in ascending order |
| 9 | tests/fixtures/geotiff/gray16_geotiff.tif | 83 | 0x01 | 0xfe | tags are not sorted in ascending order |
| 10 | tests/fixtures/geotiff/gray16_geotiff.tif | 191 | 0x87 | 0x78 | tags are not sorted in ascending order |
| 11 | tests/fixtures/photometric/cmyk.tif | 1102 | 0x01 | 0xfe | bad value 254 for FillOrder |
| 12 | tests/fixtures/predictor/predictor3_deflate_fp32.tif | 119 | 0x01 | 0xfe | tags are not sorted in ascending order |

Cases 1-8 are sniper (one bit) and 9-12 bolter (one byte). By seed class:
1 unchecked (Zstd), 2 and 12 checksummed (LERC, Deflate), the rest
uncompressed.

To rebuild case N into `out.tif` from its seed, offset and new byte:

```sh
{ head -c "$offset" "$seed"; printf "\\x$new"; tail -c "+$((offset + 2))" "$seed"; } >out.tif
```

where `$new` is the New column without `0x`.
