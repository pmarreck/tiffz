/* gen24.c: write SGILog24 (Compression 34677, LogLuv24) fixtures with
 * libtiff's own encoder; tiffcp has no -c option for it. Build and run:
 *   cc gen24.c -ltiff -o gen24 && ./gen24 logluv24-37x5.tif logluv24-37x5-be.tif
 * Photometric LogLuv (32845), three 16-bit signed samples (L, u, v) given
 * to the encoder as SGILOGDATAFMT_16BIT, 37x5, one strip; the first file is
 * little-endian, the second big-endian, both undithered. The oracles are
 * libtiff's decodes of these files (tiffcp -c none), since the encoder
 * quantizes.
 * libtiff's 16-bit encoder takes Le = (L - 3314) / 4, where its decoder and
 * the 10- and 16-bit log definitions give L = 4 * Le + 13314, so L here
 * stays in 3314..7410 to land inside Le's range rather than saturate. The
 * u and v ramps span enough of the gamut that the uv index crosses bit 12,
 * which libtiff's decoded L carries (see src/compressions/sgilog.zig). */
#include <stdio.h>
#include <tiffio.h>

static int write_one(const char *path, const char *mode) {
	enum { W = 37, H = 5 };
	int16_t row[W * 3];
	TIFF *t = TIFFOpen(path, mode);
	if (!t) return 1;
	TIFFSetField(t, TIFFTAG_IMAGEWIDTH, W);
	TIFFSetField(t, TIFFTAG_IMAGELENGTH, H);
	TIFFSetField(t, TIFFTAG_BITSPERSAMPLE, 16);
	TIFFSetField(t, TIFFTAG_SAMPLESPERPIXEL, 3);
	TIFFSetField(t, TIFFTAG_SAMPLEFORMAT, SAMPLEFORMAT_INT);
	TIFFSetField(t, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_LOGLUV);
	TIFFSetField(t, TIFFTAG_COMPRESSION, COMPRESSION_SGILOG24);
	TIFFSetField(t, TIFFTAG_SGILOGDATAFMT, SGILOGDATAFMT_16BIT);
	TIFFSetField(t, TIFFTAG_SGILOGENCODE, SGILOGENCODE_NODITHER);
	TIFFSetField(t, TIFFTAG_ROWSPERSTRIP, H);
	TIFFSetField(t, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
	for (int y = 0; y < H; y++) {
		for (int x = 0; x < W; x++) {
			row[x * 3] = (int16_t)(3400 + 80 * x + 50 * y);
			row[x * 3 + 1] = (int16_t)(3300 + 270 * x);
			row[x * 3 + 2] = (int16_t)(6600 + 2500 * y);
		}
		if (TIFFWriteScanline(t, row, (unsigned)y, 0) < 0) return 1;
	}
	TIFFClose(t);
	return 0;
}

int main(int argc, char **argv) {
	if (argc != 3) { fprintf(stderr, "usage: gen24 LITTLE.tif BIG.tif\n"); return 2; }
	return write_one(argv[1], "wl") || write_one(argv[2], "wb");
}
