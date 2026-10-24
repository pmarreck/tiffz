/* PNG and BMP codecs for the tiffz CLI's convert and dump verbs. These are
 * CLI-side adapters: tiffz itself only reads and writes TIFF, through the
 * C FFI. All buffers are in memory; the caller does file I/O. */

#ifndef TIFFZ_CLI_IMAGE_IO_H
#define TIFFZ_CLI_IMAGE_IO_H

#include <stddef.h>
#include <stdint.h>

/* Packed 8-bit samples, row-major, `channels` interleaved per pixel:
 * 1 gray, 3 RGB, 4 RGBA (unassociated alpha). `pixels` is malloc'd. */
typedef struct {
	uint8_t *pixels;
	uint32_t width;
	uint32_t height;
	int channels;
} image_t;

void image_free(image_t *img);

/* Decoders return 0 and fill `out`, or -1 with a message in `err`.
 * PNG: non-interlaced; 8-bit gray, gray+alpha, RGB, RGBA; palette and gray
 * at 1, 2, 4 or 8 bits; tRNS becomes alpha. CRCs are checked.
 * BMP: 24-bit, and 32-bit BI_RGB or BI_BITFIELDS with 8-bit masks;
 * bottom-up or top-down. */
int png_decode(const uint8_t *buf, size_t len, image_t *out, char *err, size_t errlen);
int bmp_decode(const uint8_t *buf, size_t len, image_t *out, char *err, size_t errlen);

/* Encoders return 0 with a malloc'd `*out` of `*out_len` bytes, or -1.
 * PNG keeps the channel count (gray, RGB or RGBA). BMP writes 24-bit for
 * gray or RGB, and 32-bit BI_BITFIELDS with an alpha mask for RGBA. */
int png_encode(const image_t *img, uint8_t **out, size_t *out_len);
int bmp_encode(const image_t *img, uint8_t **out, size_t *out_len);

/* Drop channels that carry no information: alpha when every pixel is
 * opaque, then color when every pixel is gray. Lossless. */
void image_reduce(image_t *img);

#endif
