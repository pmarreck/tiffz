# DNG lossless JPEG reach

The owner set the goal on 2026-11-06: "Our goal is 100% TIFF/RAW coverage (in conjunction with rawz), to the extent technically-possible." This note records what tiffz decodes in DNG Compression 7 raw IFDs, what it still cannot decode, and who owns each gap.

## Rule

DNG 1.6.0.0 p. 20 (Compression):
- "If PhotometricInterpretation = 6 (YCbCr) and BitsPerSample = 8/8/8, or if PhotometricInterpretation = 1 (BlackIsZero) and BitsPerSample = 8, then the JPEG variant must be baseline DCT JPEG."
- "Otherwise, the JPEG variant must be lossless Huffman JPEG. For lossless JPEG, the internal width/length/components in the JPEG stream are not required to match the strip or tile's width/length/components. Only the total sample counts need to match. It is common for CFA images to be encoded with a different width, length or component count to allow the JPEG compression predictors to work across like colors."

LibRaw's `lossless_dng_load_raw` reads such a stream the same way: it takes the decoded samples in raster order and fills the tile row by row.

## What tiffz does

CFA (32803) and LinearRaw (34892) chunks take the stored-sample path; so does BlackIsZero (1).
- jpegz must validate the stream and report a checked decode.
- A gray page must be one component.
- A frame with several components must be lossless Huffman, because a lossy decode of several components may be color-converted, so it is not the file's samples.
- The decoded samples, in raster order with components interleaved, are written in the form an uncompressed chunk takes (TIFF 6.0 p. 30):
  - rows begin on a byte boundary;
  - 8-bit samples are bytes;
  - 16-bit samples are SHORTs in the file's byte order;
  - other depths (12, 14) are packed high bit first.
- The total must fill whole chunk rows, and every sample must fit in BitsPerSample (Malformed otherwise). The chunk's declared extent check then applies as for every codec.
- Mixed BitsPerSample is UnsupportedBitDepth, because a JPEG frame has one precision.

A jpegz decode that returns NotImplemented after validation passed is UnsupportedCompression (reach), not JpegInTiffPayload. Before this change, such a stream made a valid file report invalid.

Before this change, 16-bit JPEG samples were copied in host byte order, which would have byte-swapped 16-bit JPEG data in a big-endian file.

## Corpus effect (263 files, HEAD 8b0beb40 against this change)

| File | Before | After |
|---|---|---|
| Samsung Galaxy S21 Ultra, S22 Ultra, S23 (LinearRaw, 3 components, 16/12/12-bit) | unsupported (3) | ok |
| Google Pixel 8 Pro (CFA, 2 components, 16-bit) | invalid (JpegInTiffPayload) | unsupported |
| Apple iPhone 6s Plus (CFA, 2 components, 12-bit) | invalid (JpegInTiffPayload) | invalid (UnsupportedCompression) |
| Leica M11 (CFA, 2 components, 14-bit) | invalid (JpegInTiffPayload) | invalid (UnsupportedCompression) |
| Apple iPhone 12 Pro (LinearRaw, 3 components, 12-bit) | invalid (UnsupportedCompression) | invalid (Malformed) |
| iphone-mask-photometric1.dng (control) | invalid (UnsupportedCompression) | invalid (Malformed) |

No finding set changed. The iPhone 6s Plus, Leica M11 and iPhone 12 Pro stay invalid on their existing directory records (TileWidth and TileLength, finding 18). The iPhone 12 Pro's raw tiles now decode, so its walk ends on those records (Malformed) instead of stopping at the raw IFD. An independent decode of its first tile (libjpeg-turbo djpeg, component IDs renamed to R G B so that no color conversion applies) gives 504x378x3 samples with a maximum of 849, within 12 bits.

## Open gaps

- **jpegz: two-component lossless decode.** `decode/lossless.zig` takes one or three components. jpegz validates the Pixel 8 Pro, iPhone 6s Plus and Leica M11 tiles, but its decoder returns NotImplemented, so those files are unsupported. This is the common DNG CFA layout, so it is the largest remaining DNG gap. Owner: jpegz. When it lands, the tiffz test "a two-component lossless frame jpegz cannot decode yet is unsupported" fails and becomes a decode test.
- **jpegz and validate: all-ones Huffman codeword.** Pentax K-x, Pentax K-r, Ricoh GR and DJI FC4382 DNGs use a DHT whose code space is exactly full, so the last length-10 code is all ones. T.81 Annex C reserves that codeword. jpegz rejects the table as corrupt; libjpeg-turbo rejects it too; LibRaw decodes all four files. Whether this is KNOWN_DEFECT is validate's ruling. Owner: validate (category), jpegz (decode).
- **Lossy JPEG under a raw photometric.** A baseline frame under CFA or LinearRaw is outside DNG p. 20 unless it is the 8-bit BlackIsZero or YCbCr case. tiffz accepts a single-component baseline CFA frame as before and reports a multi-component one unsupported. Whether that should be a conformance fault is a question for validate.
- **12-bit lossy RGB/YCbCr JPEG-in-TIFF** still copies jpegz's u16 output unchanged. That path is outside this change.
