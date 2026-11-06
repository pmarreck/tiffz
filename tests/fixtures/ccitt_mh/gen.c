/* gen.c: write mh-300x4.tif, a TIFF 6.0 Compression 2 (CCITT modified
 * Huffman) bilevel image, with libtiff's own encoder. Build and run:
 *   cc gen.c -ltiff -o gen && ./gen mh-300x4.tif
 * WhiteIsZero, 1 bit per sample, 300x4, one strip. Pixel (x, y) is black
 * (bit 1) when black(x, y) below holds; tests/fixture_test.zig repeats
 * the rule as its oracle.
 *   row 0: all white
 *   row 1: all black (the row's white run is zero)
 *   row 2: alternating, starting white
 *   row 3: black where x % 97 < 70 (70-pixel black runs need make-up codes) */
#include <stdio.h>
#include <string.h>
#include <tiffio.h>

static int black(int x, int y) {
	switch (y) {
	case 0: return 0;
	case 1: return 1;
	case 2: return x % 2;
	default: return x % 97 < 70;
	}
}

int main(int argc, char **argv) {
	enum { W = 300, H = 4 };
	unsigned char row[(W + 7) / 8];
	if (argc != 2) { fprintf(stderr, "usage: gen OUT.tif\n"); return 2; }
	TIFF *t = TIFFOpen(argv[1], "w");
	if (!t) return 1;
	TIFFSetField(t, TIFFTAG_IMAGEWIDTH, W);
	TIFFSetField(t, TIFFTAG_IMAGELENGTH, H);
	TIFFSetField(t, TIFFTAG_BITSPERSAMPLE, 1);
	TIFFSetField(t, TIFFTAG_SAMPLESPERPIXEL, 1);
	TIFFSetField(t, TIFFTAG_PHOTOMETRIC, PHOTOMETRIC_MINISWHITE);
	TIFFSetField(t, TIFFTAG_COMPRESSION, COMPRESSION_CCITTRLE);
	TIFFSetField(t, TIFFTAG_ROWSPERSTRIP, H);
	TIFFSetField(t, TIFFTAG_PLANARCONFIG, PLANARCONFIG_CONTIG);
	for (int y = 0; y < H; y++) {
		memset(row, 0, sizeof row);
		for (int x = 0; x < W; x++)
			if (black(x, y)) row[x / 8] |= (unsigned char)(0x80 >> (x % 8));
		if (TIFFWriteScanline(t, row, (unsigned)y, 0) < 0) return 1;
	}
	TIFFClose(t);
	return 0;
}
