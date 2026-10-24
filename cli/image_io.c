/* PNG and BMP codecs for the tiffz CLI. See image_io.h for the supported
 * subsets. Every length and offset read from a file is bounds-checked
 * before use. */

#include "image_io.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <zlib.h>

/* Largest image either decoder accepts, matching the writer's 32-bit
 * offset ceiling with headroom. */
#define MAX_PIXEL_BYTES ((size_t)1 << 31)

void image_free(image_t *img) {
	free(img->pixels);
	img->pixels = NULL;
	img->width = img->height = 0;
	img->channels = 0;
}

static int fail(char *err, size_t errlen, const char *fmt, ...) {
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(err, errlen, fmt, ap);
	va_end(ap);
	return -1;
}

static uint32_t be32(const uint8_t *p) {
	return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

static uint32_t le32(const uint8_t *p) {
	return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint16_t le16(const uint8_t *p) {
	return (uint16_t)(p[0] | (p[1] << 8));
}

static void put_be32(uint8_t *p, uint32_t v) {
	p[0] = (uint8_t)(v >> 24);
	p[1] = (uint8_t)(v >> 16);
	p[2] = (uint8_t)(v >> 8);
	p[3] = (uint8_t)v;
}

static void put_le32(uint8_t *p, uint32_t v) {
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
	p[2] = (uint8_t)(v >> 16);
	p[3] = (uint8_t)(v >> 24);
}

static void put_le16(uint8_t *p, uint16_t v) {
	p[0] = (uint8_t)v;
	p[1] = (uint8_t)(v >> 8);
}

/* width*height*channels, or 0 when it overflows or exceeds the cap. */
static size_t pixel_bytes(uint32_t width, uint32_t height, int channels) {
	size_t n = (size_t)width * (size_t)height;
	if (width != 0 && n / width != height)
		return 0;
	if (n > MAX_PIXEL_BYTES / (size_t)channels)
		return 0;
	return n * (size_t)channels;
}

/* ------------------------------------------------------------------ PNG */

static const uint8_t png_sig[8] = { 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

static uint8_t paeth(uint8_t a, uint8_t b, uint8_t c) {
	int p = (int)a + (int)b - (int)c;
	int pa = abs(p - (int)a), pb = abs(p - (int)b), pc = abs(p - (int)c);
	if (pa <= pb && pa <= pc)
		return a;
	return pb <= pc ? b : c;
}

/* Reverse PNG scanline filtering in place. `raw` holds height rows of
 * 1 filter byte + stride bytes; bpp is bytes per complete pixel (min 1). */
static int png_unfilter(uint8_t *raw, uint32_t height, size_t stride, size_t bpp, char *err, size_t errlen) {
	uint32_t y;
	size_t x;
	for (y = 0; y < height; y++) {
		uint8_t *row = raw + (size_t)y * (stride + 1);
		uint8_t filter = row[0];
		uint8_t *cur = row + 1;
		const uint8_t *prev = y > 0 ? raw + (size_t)(y - 1) * (stride + 1) + 1 : NULL;
		for (x = 0; x < stride; x++) {
			uint8_t a = x >= bpp ? cur[x - bpp] : 0;
			uint8_t b = prev ? prev[x] : 0;
			uint8_t c = (prev && x >= bpp) ? prev[x - bpp] : 0;
			switch (filter) {
			case 0: break;
			case 1: cur[x] = (uint8_t)(cur[x] + a); break;
			case 2: cur[x] = (uint8_t)(cur[x] + b); break;
			case 3: cur[x] = (uint8_t)(cur[x] + ((a + b) >> 1)); break;
			case 4: cur[x] = (uint8_t)(cur[x] + paeth(a, b, c)); break;
			default: return fail(err, errlen, "PNG: invalid filter type %u on row %u", filter, y);
			}
		}
	}
	return 0;
}

int png_decode(const uint8_t *buf, size_t len, image_t *out, char *err, size_t errlen) {
	size_t pos = 8;
	uint32_t width = 0, height = 0;
	int depth = 0, ctype = -1, have_ihdr = 0, have_iend = 0;
	uint8_t palette[256][3];
	uint8_t pal_alpha[256];
	int pal_count = 0, trns_count = 0, have_trns = 0;
	uint16_t trns_key[3] = { 0, 0, 0 };
	uint8_t *idat = NULL, *raw = NULL;
	size_t idat_len = 0, idat_cap = 0;
	int src_channels, out_channels, i;
	size_t stride, raw_len, npix, p;
	uLongf got;

	memset(out, 0, sizeof(*out));
	memset(pal_alpha, 255, sizeof(pal_alpha));
	if (len < 8 || memcmp(buf, png_sig, 8) != 0)
		return fail(err, errlen, "PNG: bad signature");

	while (!have_iend) {
		uint32_t clen;
		const uint8_t *type, *data;
		if (len - pos < 12) {
			free(idat);
			return fail(err, errlen, "PNG: truncated before IEND");
		}
		clen = be32(buf + pos);
		type = buf + pos + 4;
		data = buf + pos + 8;
		if (clen > len - pos - 12) {
			free(idat);
			return fail(err, errlen, "PNG: chunk %.4s runs past end of file", (const char *)type);
		}
		if ((uint32_t)crc32(crc32(0L, type, 4), data, clen) != be32(data + clen)) {
			free(idat);
			return fail(err, errlen, "PNG: CRC mismatch in %.4s chunk", (const char *)type);
		}
		if (!have_ihdr && memcmp(type, "IHDR", 4) != 0) {
			free(idat);
			return fail(err, errlen, "PNG: first chunk is not IHDR");
		}
		if (memcmp(type, "IHDR", 4) == 0) {
			if (clen != 13 || have_ihdr)
				return fail(err, errlen, "PNG: bad IHDR");
			width = be32(data);
			height = be32(data + 4);
			depth = data[8];
			ctype = data[9];
			if (width == 0 || height == 0)
				return fail(err, errlen, "PNG: zero width or height");
			if (data[10] != 0 || data[11] != 0)
				return fail(err, errlen, "PNG: unknown compression or filter method");
			if (data[12] != 0)
				return fail(err, errlen, "PNG: interlaced PNG is not supported");
			if (ctype == 3 || ctype == 0) {
				if (depth != 1 && depth != 2 && depth != 4 && depth != 8)
					return fail(err, errlen, "PNG: unsupported bit depth %d (1, 2, 4 or 8 for gray and palette)", depth);
			} else if (ctype == 2 || ctype == 4 || ctype == 6) {
				if (depth != 8)
					return fail(err, errlen, "PNG: unsupported bit depth %d (8 only)", depth);
			} else {
				return fail(err, errlen, "PNG: invalid color type %d", ctype);
			}
			have_ihdr = 1;
		} else if (memcmp(type, "PLTE", 4) == 0) {
			if (clen % 3 != 0 || clen / 3 > 256 || clen == 0) {
				free(idat);
				return fail(err, errlen, "PNG: bad PLTE length %u", clen);
			}
			pal_count = (int)(clen / 3);
			memcpy(palette, data, clen);
		} else if (memcmp(type, "tRNS", 4) == 0) {
			have_trns = 1;
			if (ctype == 3) {
				trns_count = clen > 256 ? 256 : (int)clen;
				memcpy(pal_alpha, data, (size_t)trns_count);
			} else if (ctype == 0 && clen == 2) {
				trns_key[0] = (uint16_t)((data[0] << 8) | data[1]);
			} else if (ctype == 2 && clen == 6) {
				for (i = 0; i < 3; i++)
					trns_key[i] = (uint16_t)((data[2 * i] << 8) | data[2 * i + 1]);
			} else {
				free(idat);
				return fail(err, errlen, "PNG: tRNS not allowed for color type %d", ctype);
			}
		} else if (memcmp(type, "IDAT", 4) == 0) {
			if (idat_len + clen > idat_cap) {
				size_t ncap = (idat_len + clen) * 2;
				uint8_t *grown = realloc(idat, ncap);
				if (grown == NULL) {
					free(idat);
					return fail(err, errlen, "out of memory");
				}
				idat = grown;
				idat_cap = ncap;
			}
			memcpy(idat + idat_len, data, clen);
			idat_len += clen;
		} else if (memcmp(type, "IEND", 4) == 0) {
			have_iend = 1;
		} else if (!(type[0] & 0x20)) {
			free(idat);
			return fail(err, errlen, "PNG: unknown critical chunk %.4s", (const char *)type);
		}
		pos += 12 + clen;
	}
	if (ctype == 3 && pal_count == 0) {
		free(idat);
		return fail(err, errlen, "PNG: palette image without PLTE");
	}
	if (idat_len == 0)
		return fail(err, errlen, "PNG: no IDAT data");

	src_channels = ctype == 2 ? 3 : ctype == 4 ? 2 : ctype == 6 ? 4 : 1;
	stride = ((size_t)width * (size_t)src_channels * (size_t)depth + 7) / 8;
	if (pixel_bytes(width, height, 4) == 0) {
		free(idat);
		return fail(err, errlen, "PNG: image too large");
	}
	raw_len = (stride + 1) * (size_t)height;
	raw = malloc(raw_len);
	if (raw == NULL) {
		free(idat);
		return fail(err, errlen, "out of memory");
	}
	got = (uLongf)raw_len;
	{
		int zrc = uncompress(raw, &got, idat, (uLong)idat_len);
		free(idat);
		if (zrc != Z_OK || got != raw_len) {
			free(raw);
			return fail(err, errlen, "PNG: image data does not inflate to %zu bytes (zlib %d)", raw_len, zrc);
		}
	}
	if (png_unfilter(raw, height, stride, (size_t)(src_channels * depth + 7) / 8, err, errlen) != 0) {
		free(raw);
		return -1;
	}

	if (ctype == 3)
		out_channels = have_trns ? 4 : 3;
	else if (ctype == 0)
		out_channels = have_trns ? 4 : 1;
	else if (ctype == 2)
		out_channels = have_trns ? 4 : 3;
	else
		out_channels = 4;
	npix = (size_t)width * height;
	out->pixels = malloc(npix * (size_t)out_channels);
	if (out->pixels == NULL) {
		free(raw);
		return fail(err, errlen, "out of memory");
	}
	for (p = 0; p < npix; p++) {
		size_t y = p / width, x = p % width;
		const uint8_t *row = raw + y * (stride + 1) + 1;
		uint8_t *o = out->pixels + p * (size_t)out_channels;
		if (ctype == 0 || ctype == 3) {
			size_t bit = x * (size_t)depth;
			unsigned v = (row[bit / 8] >> (8 - depth - (bit % 8))) & ((1u << depth) - 1);
			if (ctype == 3) {
				if ((int)v >= pal_count) {
					image_free(out);
					free(raw);
					return fail(err, errlen, "PNG: palette index %u out of range", v);
				}
				memcpy(o, palette[v], 3);
				if (out_channels == 4)
					o[3] = pal_alpha[v];
			} else {
				uint8_t g = (uint8_t)(v * 255u / ((1u << depth) - 1));
				if (out_channels == 1) {
					o[0] = g;
				} else {
					o[0] = o[1] = o[2] = g;
					o[3] = v == trns_key[0] ? 0 : 255;
				}
			}
		} else if (ctype == 4) {
			o[0] = o[1] = o[2] = row[x * 2];
			o[3] = row[x * 2 + 1];
		} else if (ctype == 2) {
			memcpy(o, row + x * 3, 3);
			if (out_channels == 4)
				o[3] = (o[0] == trns_key[0] && o[1] == trns_key[1] && o[2] == trns_key[2]) ? 0 : 255;
		} else {
			memcpy(o, row + x * 4, 4);
		}
	}
	free(raw);
	out->width = width;
	out->height = height;
	out->channels = out_channels;
	return 0;
}

static void png_chunk(uint8_t **p, const char *type, const uint8_t *data, uint32_t n) {
	uint32_t crc = (uint32_t)crc32(0L, (const Bytef *)type, 4);
	put_be32(*p, n);
	memcpy(*p + 4, type, 4);
	if (n > 0) {
		memcpy(*p + 8, data, n);
		crc = (uint32_t)crc32(crc, data, n);
	}
	put_be32(*p + 8 + n, crc);
	*p += 12 + n;
}

int png_encode(const image_t *img, uint8_t **out, size_t *out_len) {
	size_t row_bytes = (size_t)img->width * (size_t)img->channels;
	size_t raw_len = (size_t)img->height * (1 + row_bytes);
	uint8_t ihdr[13];
	uint8_t *raw, *comp, *buf, *p;
	uLongf comp_len;
	uint32_t y;

	raw = malloc(raw_len);
	if (raw == NULL)
		return -1;
	for (y = 0; y < img->height; y++) {
		raw[(size_t)y * (1 + row_bytes)] = 0; /* filter None */
		memcpy(raw + (size_t)y * (1 + row_bytes) + 1, img->pixels + (size_t)y * row_bytes, row_bytes);
	}
	comp_len = compressBound((uLong)raw_len);
	comp = malloc(comp_len);
	if (comp == NULL || compress(comp, &comp_len, raw, (uLong)raw_len) != Z_OK) {
		free(comp);
		free(raw);
		return -1;
	}
	free(raw);
	buf = malloc(8 + 25 + 12 + comp_len + 12);
	if (buf == NULL) {
		free(comp);
		return -1;
	}
	memcpy(buf, png_sig, 8);
	p = buf + 8;
	put_be32(ihdr, img->width);
	put_be32(ihdr + 4, img->height);
	ihdr[8] = 8;
	ihdr[9] = img->channels == 1 ? 0 : img->channels == 3 ? 2 : 6;
	ihdr[10] = ihdr[11] = ihdr[12] = 0;
	png_chunk(&p, "IHDR", ihdr, 13);
	png_chunk(&p, "IDAT", comp, (uint32_t)comp_len);
	png_chunk(&p, "IEND", NULL, 0);
	free(comp);
	*out = buf;
	*out_len = (size_t)(p - buf);
	return 0;
}

/* ------------------------------------------------------------------ BMP */

/* Shift and width of a contiguous bit mask; width 0 for an empty mask. */
static void mask_shape(uint32_t mask, int *shift, int *bits) {
	*shift = 0;
	*bits = 0;
	if (mask == 0)
		return;
	while (!(mask & 1)) {
		mask >>= 1;
		(*shift)++;
	}
	while (mask & 1) {
		mask >>= 1;
		(*bits)++;
	}
	if (mask != 0)
		*bits = -1; /* not contiguous */
}

int bmp_decode(const uint8_t *buf, size_t len, image_t *out, char *err, size_t errlen) {
	uint32_t data_off, dib, comp, masks[4] = { 0x00ff0000, 0x0000ff00, 0x000000ff, 0 };
	int32_t w, h;
	uint16_t bpp;
	int top_down, channels, shift[4], bits[4], i;
	uint32_t width, height, y, x;
	size_t stride;

	memset(out, 0, sizeof(*out));
	if (len < 26 || buf[0] != 'B' || buf[1] != 'M')
		return fail(err, errlen, "BMP: bad signature");
	data_off = le32(buf + 10);
	dib = le32(buf + 14);
	if (dib != 40 && dib != 52 && dib != 56 && dib != 108 && dib != 124)
		return fail(err, errlen, "BMP: unsupported header size %u", dib);
	if (len < 14 + (size_t)dib)
		return fail(err, errlen, "BMP: truncated header");
	w = (int32_t)le32(buf + 18);
	h = (int32_t)le32(buf + 22);
	bpp = le16(buf + 28);
	comp = le32(buf + 30);
	if (le16(buf + 26) != 1)
		return fail(err, errlen, "BMP: planes must be 1");
	if (w <= 0 || h == 0 || h == INT32_MIN)
		return fail(err, errlen, "BMP: bad dimensions");
	top_down = h < 0;
	width = (uint32_t)w;
	height = (uint32_t)(top_down ? -h : h);
	if (bpp != 24 && bpp != 32)
		return fail(err, errlen, "BMP: unsupported bit count %u (24 or 32)", bpp);
	if (comp == 3 && bpp == 32) {
		if (dib >= 52) {
			for (i = 0; i < (dib >= 56 ? 4 : 3); i++)
				masks[i] = le32(buf + 54 + 4 * i);
		} else {
			if (len < 66)
				return fail(err, errlen, "BMP: truncated bit masks");
			for (i = 0; i < 3; i++)
				masks[i] = le32(buf + 54 + 4 * i);
		}
	} else if (comp != 0) {
		return fail(err, errlen, "BMP: unsupported compression %u", comp);
	}
	for (i = 0; i < 4; i++) {
		mask_shape(masks[i], &shift[i], &bits[i]);
		if (bits[i] != 0 && bits[i] != 8)
			return fail(err, errlen, "BMP: only 8-bit channel masks are supported");
	}
	if (bits[0] == 0 || bits[1] == 0 || bits[2] == 0)
		return fail(err, errlen, "BMP: missing color mask");
	channels = (bpp == 32 && bits[3] == 8) ? 4 : 3;
	if (pixel_bytes(width, height, 4) == 0)
		return fail(err, errlen, "BMP: image too large");
	stride = (((size_t)width * bpp + 31) / 32) * 4;
	if (data_off > len || (len - data_off) / stride < height)
		return fail(err, errlen, "BMP: pixel data runs past end of file");

	out->pixels = malloc((size_t)width * height * (size_t)channels);
	if (out->pixels == NULL)
		return fail(err, errlen, "out of memory");
	for (y = 0; y < height; y++) {
		const uint8_t *row = buf + data_off + (size_t)(top_down ? y : height - 1 - y) * stride;
		uint8_t *o = out->pixels + (size_t)y * width * (size_t)channels;
		for (x = 0; x < width; x++, o += channels) {
			if (bpp == 24) {
				o[0] = row[x * 3 + 2];
				o[1] = row[x * 3 + 1];
				o[2] = row[x * 3];
			} else {
				uint32_t v = le32(row + x * 4);
				for (i = 0; i < channels; i++)
					o[i] = (uint8_t)(v >> shift[i]);
			}
		}
	}
	out->width = width;
	out->height = height;
	out->channels = channels;
	return 0;
}

int bmp_encode(const image_t *img, uint8_t **out, size_t *out_len) {
	int alpha = img->channels == 4;
	uint32_t dib = alpha ? 108 : 40;
	uint32_t bpp = alpha ? 32 : 24;
	size_t stride = (((size_t)img->width * bpp + 31) / 32) * 4;
	size_t data_off = 14 + dib;
	size_t total = data_off + stride * img->height;
	uint8_t *buf;
	uint32_t y, x;

	if (total > 0xffffffffu)
		return -1;
	buf = calloc(1, total);
	if (buf == NULL)
		return -1;
	buf[0] = 'B';
	buf[1] = 'M';
	put_le32(buf + 2, (uint32_t)total);
	put_le32(buf + 10, (uint32_t)data_off);
	put_le32(buf + 14, dib);
	put_le32(buf + 18, img->width);
	put_le32(buf + 22, img->height); /* bottom-up */
	put_le16(buf + 26, 1);
	put_le16(buf + 28, (uint16_t)bpp);
	put_le32(buf + 30, alpha ? 3 : 0);
	put_le32(buf + 34, (uint32_t)(stride * img->height));
	put_le32(buf + 38, 2835); /* 72 dpi */
	put_le32(buf + 42, 2835);
	if (alpha) {
		put_le32(buf + 54, 0x00ff0000);
		put_le32(buf + 58, 0x0000ff00);
		put_le32(buf + 62, 0x000000ff);
		put_le32(buf + 66, 0xff000000);
		put_le32(buf + 70, 0x73524742); /* 'sRGB' */
	}
	for (y = 0; y < img->height; y++) {
		uint8_t *row = buf + data_off + (size_t)(img->height - 1 - y) * stride;
		const uint8_t *s = img->pixels + (size_t)y * img->width * (size_t)img->channels;
		for (x = 0; x < img->width; x++, s += img->channels) {
			uint8_t r = s[0];
			uint8_t g = img->channels == 1 ? s[0] : s[1];
			uint8_t b = img->channels == 1 ? s[0] : s[2];
			if (alpha) {
				row[x * 4] = b;
				row[x * 4 + 1] = g;
				row[x * 4 + 2] = r;
				row[x * 4 + 3] = s[3];
			} else {
				row[x * 3] = b;
				row[x * 3 + 1] = g;
				row[x * 3 + 2] = r;
			}
		}
	}
	*out = buf;
	*out_len = total;
	return 0;
}

void image_reduce(image_t *img) {
	size_t n = (size_t)img->width * img->height, i;
	if (img->channels == 4) {
		for (i = 0; i < n; i++)
			if (img->pixels[i * 4 + 3] != 255)
				return;
		for (i = 0; i < n; i++)
			memmove(img->pixels + i * 3, img->pixels + i * 4, 3);
		img->channels = 3;
	}
	if (img->channels == 3) {
		for (i = 0; i < n; i++) {
			const uint8_t *s = img->pixels + i * 3;
			if (s[0] != s[1] || s[1] != s[2])
				return;
		}
		for (i = 0; i < n; i++)
			img->pixels[i] = img->pixels[i * 3];
		img->channels = 1;
	}
}
