/* tiffz CLI — dogfoods the C FFI. All I/O lives here. */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <zlib.h>

#include "tiffz.h"
#include "image_io.h"

/* build.zig defines these from the resolved compile target. */
#ifndef TIFFZ_PF
#error "TIFFZ_PF must be defined by the build (e.g. -DTIFFZ_PF=\"linux-amd64\")"
#endif
#ifndef TIFFZ_VARIANT
#define TIFFZ_VARIANT ""
#endif

#define EXIT_OK 0
#define EXIT_INVALID 1
#define EXIT_USAGE 2
#define EXIT_IO 3
#define EXIT_LIMITED 4

typedef struct Finding {
	int32_t source;
	int32_t code;
	int32_t mapped;
	int32_t verdict;
	uint64_t byte_offset;
	uint64_t host_offset;
	uint32_t flags;
	uint8_t *payload;
	size_t payload_len;
} Finding;

typedef struct FindingList {
	Finding *items;
	size_t len;
	size_t cap;
} FindingList;

static void announce_debug(void) {
	const char *mute = getenv("MUTE_DEBUG_STATUS");
	if (mute != NULL && mute[0] != '\0')
		return;
#if defined(TIFFZ_DEBUG)
	fputs("\x1b[33mDEBUG BUILD\x1b[0m\n", stderr);
#endif
}

static int print_about(void) {
	if (TIFFZ_VARIANT[0] != '\0')
		printf("tiffz %s — pure-Zig spec-complete TIFF reader PF=%s VARIANT=%s\n",
		       tiffz_version(), TIFFZ_PF, TIFFZ_VARIANT);
	else
		printf("tiffz %s — pure-Zig spec-complete TIFF reader PF=%s\n",
		       tiffz_version(), TIFFZ_PF);
	return EXIT_OK;
}

static int print_version(void) {
	printf("%s\n", tiffz_version());
	return EXIT_OK;
}

static int print_help(void) {
	printf(
		"tiffz %s — pure-Zig TIFF reader and validator\n"
		"\n"
		"USAGE:\n"
		"    tiffz [OPTIONS] [validate] FILE...\n"
		"    tiffz convert INPUT -o OUTPUT [--to FORMAT] [--compression C]\n"
		"    tiffz --about | --version | --help\n"
		"\n"
		"FILE may be a path, - , or @stdin.\n"
		"\n"
		"VERBS:\n"
		"    validate         Decode every strip/tile; report findings (default)\n"
		"    dump             Decode one IFD to 8-bit RGBA PNG\n"
		"    convert          Convert between TIFF, PNG and BMP (8-bit samples)\n"
		"\n"
		"OPTIONS:\n"
		"    --json           Write a JSON report to stdout (validate)\n"
		"    -o, --output PATH  Destination for dump or convert (- or @stdout)\n"
		"    --ifd N          TIFF IFD index to dump or convert (default 0)\n"
		"    --to FORMAT      convert output: tiff, png or bmp (default: from -o's\n"
		"                     extension; required for stdout)\n"
		"    --compression C  TIFF output: none, lzw or deflate (default deflate,\n"
		"                     whose Adler-32 lets readers detect corruption)\n"
		"    --simple, --ascii, --no-ansi, --no-color\n"
		"                     Suppress ANSI color (reserved; English CLI)\n"
		"    --version, -v    Print version and exit\n"
		"    --about          One-line description, version, and platform\n"
		"    --help, -h       Print this help and exit\n"
		"\n"
		"EXIT CODES:\n"
		"    0  valid (named WARN/INFO findings, including partial coverage)\n"
		"    1  corrupt or malformed\n"
		"    2  usage error\n"
		"    3  I/O error (missing file, read failure)\n"
		"    4  configured resource limit (not a corruption finding)\n",
		tiffz_version());
	return EXIT_OK;
}

static int is_exact(const char *arg, const char *a, const char *b) {
	if (strcmp(arg, a) == 0)
		return 1;
	if (b != NULL && strcmp(arg, b) == 0)
		return 1;
	return 0;
}

static int is_stdin_name(const char *path) {
	return strcmp(path, "-") == 0 || strcmp(path, "@stdin") == 0;
}

static void findings_free(FindingList *list) {
	size_t i;
	for (i = 0; i < list->len; i++)
		free(list->items[i].payload);
	free(list->items);
	list->items = NULL;
	list->len = 0;
	list->cap = 0;
}

static void on_finding(
	void *userdata,
	tiffz_source_decoder_t source_decoder,
	int32_t finding_code,
	int32_t mapped_finding_code,
	tiffz_finding_verdict_t verdict,
	uint64_t byte_offset,
	uint64_t host_byte_offset,
	uint32_t metadata_flags,
	const uint8_t *payload,
	size_t payload_len) {
	FindingList *list = userdata;
	Finding *slot;
	if (list->len == list->cap) {
		size_t ncap = list->cap == 0 ? 16 : list->cap * 2;
		Finding *grown = realloc(list->items, ncap * sizeof(*grown));
		if (grown == NULL)
			return;
		list->items = grown;
		list->cap = ncap;
	}
	slot = &list->items[list->len];
	slot->source = source_decoder;
	slot->code = finding_code;
	slot->mapped = mapped_finding_code;
	slot->verdict = verdict;
	slot->byte_offset = byte_offset;
	slot->host_offset = host_byte_offset;
	slot->flags = metadata_flags;
	slot->payload = NULL;
	slot->payload_len = 0;
	if (payload != NULL && payload_len > 0) {
		slot->payload = malloc(payload_len);
		if (slot->payload != NULL) {
			memcpy(slot->payload, payload, payload_len);
			slot->payload_len = payload_len;
		}
	}
	list->len++;
}

static void json_escape(FILE *out, const char *s) {
	fputc('"', out);
	for (; *s != '\0'; s++) {
		unsigned char c = (unsigned char)*s;
		if (c == '"' || c == '\\') {
			fputc('\\', out);
			fputc((char)c, out);
		} else if (c < 0x20) {
			fprintf(out, "\\u%04x", c);
		} else {
			fputc((char)c, out);
		}
	}
	fputc('"', out);
}

static void write_payload_hex(FILE *out, const uint8_t *p, size_t n) {
	static const char hex[] = "0123456789abcdef";
	size_t i;
	fputc('"', out);
	for (i = 0; i < n; i++) {
		fputc(hex[p[i] >> 4], out);
		fputc(hex[p[i] & 0x0f], out);
	}
	fputc('"', out);
}

static int is_resource_limit(tiffz_status_t status) {
	return tiffz_status_is_limit(status) != 0;
}

static const char *report_word(int ok, tiffz_status_t status) {
	if (ok)
		return "ok";
	if (is_resource_limit(status))
		return "limited";
	return "invalid";
}

static int exit_for_status(tiffz_status_t status) {
	if (is_resource_limit(status))
		return EXIT_LIMITED;
	return EXIT_INVALID;
}

static void write_json(
	const char *path,
	int ok,
	tiffz_status_t status,
	size_t ifds,
	const FindingList *list,
	tiffz_decoder_t *dec) {
	size_t i;
	fputs("{\"status\":", stdout);
	json_escape(stdout, report_word(ok, status));
	fputs(",\"path\":", stdout);
	json_escape(stdout, path);
	fprintf(stdout, ",\"error\":%d,\"ifds\":%zu,\"findings\":[", (int)status, ifds);
	for (i = 0; i < list->len; i++) {
		const Finding *f = &list->items[i];
		if (i > 0)
			fputc(',', stdout);
		fprintf(stdout,
			"{\"source\":%d,\"code\":%d,\"verdict\":%d",
			f->source, f->code, f->verdict);
		if (f->flags & TIFFZ_FINDING_MAPPED_CODE_PRESENT)
			fprintf(stdout, ",\"mapped\":%d", f->mapped);
		if (f->flags & TIFFZ_FINDING_BYTE_OFFSET_PRESENT)
			fprintf(stdout, ",\"offset\":%llu", (unsigned long long)f->byte_offset);
		if (f->flags & TIFFZ_FINDING_HOST_OFFSET_PRESENT)
			fprintf(stdout, ",\"host_offset\":%llu", (unsigned long long)f->host_offset);
		if (f->payload_len > 0) {
			fputs(",\"payload_hex\":", stdout);
			write_payload_hex(stdout, f->payload, f->payload_len);
		}
		fputc('}', stdout);
	}
	fputc(']', stdout);
	if (dec != NULL) {
		uint64_t limit_offset = 0;
		uint64_t limit_ifd = 0;
		uint64_t limit_bytes = 0;
		uint32_t rows_decoded = 0;
		if (tiffz_limit_progress(dec, &limit_offset, &limit_ifd, &limit_bytes) == 0) {
			fprintf(stdout,
				",\"limit_offset\":%llu,\"limit_ifd\":%llu,\"limit_bytes\":%llu",
				(unsigned long long)limit_offset,
				(unsigned long long)limit_ifd,
				(unsigned long long)limit_bytes);
		}
		if (tiffz_facsimile_rows(dec, &rows_decoded) == 0) {
			fprintf(stdout, ",\"rows_decoded\":%u", rows_decoded);
		}
		{
			int32_t class_id = 0;
			uint64_t disc_offset = 0;
			int offset_known = 0;
			const char *disc_type = NULL;
			if (tiffz_discrepancy(dec, &class_id, &disc_offset, &offset_known, &disc_type) == 0
				&& disc_type != NULL) {
				const char *class_name = "error";
				if (class_id == 1)
					class_name = "warning";
				else if (class_id == 3)
					class_name = "known_failure";
				fputs(",\"discrepancy\":{\"class\":", stdout);
				json_escape(stdout, class_name);
				fputs(",\"type\":", stdout);
				json_escape(stdout, disc_type);
				if (offset_known)
					fprintf(stdout, ",\"offset\":%llu", (unsigned long long)disc_offset);
				fputc('}', stdout);
			}
		}
	}
	fputs("}\n", stdout);
}

static int read_all_fp(FILE *fp, uint8_t **out_buf, size_t *out_len) {
	size_t cap = 4096;
	size_t len = 0;
	uint8_t *buf = malloc(cap);
	if (buf == NULL)
		return -1;
	for (;;) {
		size_t n;
		if (len == cap) {
			size_t ncap = cap * 2;
			uint8_t *grown = realloc(buf, ncap);
			if (grown == NULL) {
				free(buf);
				return -1;
			}
			buf = grown;
			cap = ncap;
		}
		n = fread(buf + len, 1, cap - len, fp);
		len += n;
		if (n == 0) {
			if (ferror(fp)) {
				free(buf);
				return -1;
			}
			break;
		}
	}
	*out_buf = buf;
	*out_len = len;
	return 0;
}

static int read_path(const char *path, uint8_t **out_buf, size_t *out_len) {
	FILE *fp;
	int rc;
	if (is_stdin_name(path))
		return read_all_fp(stdin, out_buf, out_len);
	fp = fopen(path, "rb");
	if (fp == NULL)
		return (errno == ENOENT) ? -2 : -1;
	rc = read_all_fp(fp, out_buf, out_len);
	fclose(fp);
	return rc;
}

static int is_stdout_name(const char *path) {
	return path == NULL || strcmp(path, "-") == 0 || strcmp(path, "@stdout") == 0;
}

static int dump_one(const char *path, const char *out_path, size_t ifd_index) {
	uint8_t *buf = NULL;
	size_t len = 0;
	int read_rc;
	tiffz_status_t status = TIFFZ_OK;
	tiffz_decoder_t *dec;
	uint8_t *pixels = NULL;
	uint32_t width = 0;
	uint32_t height = 0;
	size_t pix_len;
	FILE *out;
	int close_out = 0;
	int rc = EXIT_INVALID;

	read_rc = read_path(path, &buf, &len);
	if (read_rc == -2) {
		fprintf(stderr, "tiffz: cannot open '%s': No such file or directory\n", path);
		return EXIT_IO;
	}
	if (read_rc != 0) {
		fprintf(stderr, "tiffz: failed to read '%s'\n", path);
		return EXIT_IO;
	}

	dec = tiffz_open_from_buffer(buf, len, &status);
	if (dec == NULL) {
		fprintf(stderr, "%s  %s  (%s)\n", report_word(0, status), path, tiffz_status_name(status));
		free(buf);
		return exit_for_status(status);
	}
	status = tiffz_decode_rgba(dec, ifd_index, &pixels, &width, &height);
	if (status != TIFFZ_OK) {
		const char *msg = tiffz_last_error_message(dec);
		fprintf(stderr, "%s  %s  (%s)\n", report_word(0, status), path,
			(msg != NULL && msg[0] != '\0') ? msg : tiffz_status_name(status));
		tiffz_close(dec);
		free(buf);
		return exit_for_status(status);
	}
	pix_len = (size_t)width * (size_t)height * 4;

	if (is_stdout_name(out_path)) {
		out = stdout;
	} else {
		out = fopen(out_path, "wb");
		if (out == NULL) {
			fprintf(stderr, "tiffz: cannot write '%s'\n", out_path);
			tiffz_free(pixels, pix_len);
			tiffz_close(dec);
			free(buf);
			return EXIT_IO;
		}
		close_out = 1;
	}
	{
		image_t img = { pixels, width, height, 4 };
		uint8_t *png = NULL;
		size_t png_len = 0;
		if (png_encode(&img, &png, &png_len) != 0 || fwrite(png, 1, png_len, out) != png_len) {
			fprintf(stderr, "tiffz: failed to write PNG\n");
			rc = EXIT_IO;
			free(png);
			goto done;
		}
		free(png);
	}
	{
		if (!is_stdout_name(out_path))
			fprintf(stderr, "wrote  %s  (%ux%u)\n", out_path, width, height);
		rc = EXIT_OK;
	}
done:
	if (close_out)
		fclose(out);
	tiffz_free(pixels, pix_len);
	tiffz_close(dec);
	free(buf);
	return rc;
}

typedef enum { FMT_NONE, FMT_TIFF, FMT_PNG, FMT_BMP } format_t;

static const char *format_name(format_t f) {
	return f == FMT_TIFF ? "TIFF" : f == FMT_PNG ? "PNG" : f == FMT_BMP ? "BMP" : "?";
}

static format_t parse_format(const char *s) {
	if (strcmp(s, "tiff") == 0 || strcmp(s, "tif") == 0)
		return FMT_TIFF;
	if (strcmp(s, "png") == 0)
		return FMT_PNG;
	if (strcmp(s, "bmp") == 0)
		return FMT_BMP;
	return FMT_NONE;
}

/* Output format from the path's extension, ignoring case. */
static format_t format_from_extension(const char *path) {
	const char *dot = strrchr(path, '.');
	char ext[8];
	size_t i;
	if (dot == NULL || strchr(dot, '/') != NULL || strlen(dot + 1) >= sizeof(ext))
		return FMT_NONE;
	for (i = 0; dot[1 + i] != '\0'; i++)
		ext[i] = (char)((dot[1 + i] >= 'A' && dot[1 + i] <= 'Z') ? dot[1 + i] + 32 : dot[1 + i]);
	ext[i] = '\0';
	return parse_format(ext);
}

/* Input format from magic bytes; the extension is never trusted. */
static format_t sniff_format(const uint8_t *b, size_t n) {
	if (n >= 8 && memcmp(b, "\x89PNG\r\n\x1a\n", 8) == 0)
		return FMT_PNG;
	if (n >= 2 && b[0] == 'B' && b[1] == 'M')
		return FMT_BMP;
	if (n >= 4 && (memcmp(b, "II*\0", 4) == 0 || memcmp(b, "MM\0*", 4) == 0 ||
	               memcmp(b, "II+\0", 4) == 0 || memcmp(b, "MM\0+", 4) == 0))
		return FMT_TIFF;
	return FMT_NONE;
}

/* Decode a TIFF IFD through the FFI into an image with spare channels
 * dropped. Returns an exit code. */
static int decode_tiff(const char *path, const uint8_t *buf, size_t len, size_t ifd_index, image_t *img) {
	tiffz_status_t status = TIFFZ_OK;
	tiffz_decoder_t *dec = tiffz_open_from_buffer(buf, len, &status);
	uint8_t *pixels = NULL;
	uint32_t width = 0, height = 0;
	size_t n;
	if (dec == NULL) {
		fprintf(stderr, "%s  %s  (%s)\n", report_word(0, status), path, tiffz_status_name(status));
		return exit_for_status(status);
	}
	status = tiffz_decode_rgba_straight(dec, ifd_index, &pixels, &width, &height);
	if (status != TIFFZ_OK) {
		const char *msg = tiffz_last_error_message(dec);
		fprintf(stderr, "%s  %s  (%s)\n", report_word(0, status), path,
			(msg != NULL && msg[0] != '\0') ? msg : tiffz_status_name(status));
		tiffz_close(dec);
		return exit_for_status(status);
	}
	n = (size_t)width * height * 4;
	img->pixels = malloc(n);
	if (img->pixels == NULL) {
		tiffz_free(pixels, n);
		tiffz_close(dec);
		fputs("tiffz: out of memory\n", stderr);
		return EXIT_IO;
	}
	memcpy(img->pixels, pixels, n);
	img->width = width;
	img->height = height;
	img->channels = 4;
	tiffz_free(pixels, n);
	tiffz_close(dec);
	image_reduce(img);
	return EXIT_OK;
}

/* Read any supported input, convert it in memory, and write the output
 * only after encoding succeeds, so a refused conversion leaves no file. */
static int convert_one(const char *path, const char *out_path, format_t to, uint32_t compression, size_t ifd_index) {
	uint8_t *buf = NULL, *encoded = NULL;
	size_t len = 0, encoded_len = 0;
	image_t img = { NULL, 0, 0, 0 };
	char err[256];
	format_t from;
	int read_rc, rc = EXIT_OK;
	int to_stdout = is_stdout_name(out_path);

	if (to == FMT_NONE && !to_stdout)
		to = format_from_extension(out_path);
	if (to == FMT_NONE) {
		fprintf(stderr, "tiffz: cannot tell the output format of '%s'; pass --to tiff, png or bmp\n",
			to_stdout ? "stdout" : out_path);
		return EXIT_USAGE;
	}

	read_rc = read_path(path, &buf, &len);
	if (read_rc == -2) {
		fprintf(stderr, "tiffz: cannot open '%s': No such file or directory\n", path);
		return EXIT_IO;
	}
	if (read_rc != 0) {
		fprintf(stderr, "tiffz: failed to read '%s'\n", path);
		return EXIT_IO;
	}
	from = sniff_format(buf, len);
	if (from == FMT_TIFF) {
		rc = decode_tiff(path, buf, len, ifd_index, &img);
	} else if (from == FMT_PNG || from == FMT_BMP) {
		int drc = from == FMT_PNG ? png_decode(buf, len, &img, err, sizeof(err))
		                          : bmp_decode(buf, len, &img, err, sizeof(err));
		if (drc != 0) {
			fprintf(stderr, "invalid  %s  (%s)\n", path, err);
			rc = EXIT_INVALID;
		} else {
			image_reduce(&img);
		}
	} else {
		fprintf(stderr, "invalid  %s  (unrecognized input format; expected TIFF, PNG or BMP)\n", path);
		rc = EXIT_INVALID;
	}
	free(buf);
	if (rc != EXIT_OK) {
		image_free(&img);
		return rc;
	}

	if (to == FMT_TIFF) {
		size_t n = (size_t)img.width * img.height * (size_t)img.channels;
		tiffz_status_t status = tiffz_encode(img.pixels, n, img.width, img.height,
			(uint32_t)img.channels, compression, &encoded, &encoded_len);
		if (status != TIFFZ_OK) {
			fprintf(stderr, "tiffz: cannot encode TIFF (%s)\n", tiffz_status_name(status));
			image_free(&img);
			return exit_for_status(status);
		}
	} else if ((to == FMT_PNG ? png_encode(&img, &encoded, &encoded_len)
	                          : bmp_encode(&img, &encoded, &encoded_len)) != 0) {
		fprintf(stderr, "tiffz: cannot encode %s\n", format_name(to));
		image_free(&img);
		return EXIT_IO;
	}

	if (to_stdout) {
		if (fwrite(encoded, 1, encoded_len, stdout) != encoded_len || fflush(stdout) != 0) {
			fputs("tiffz: failed to write stdout\n", stderr);
			rc = EXIT_IO;
		}
	} else {
		FILE *out = fopen(out_path, "wb");
		if (out == NULL) {
			fprintf(stderr, "tiffz: cannot write '%s'\n", out_path);
			rc = EXIT_IO;
		} else {
			if (fwrite(encoded, 1, encoded_len, out) != encoded_len)
				rc = EXIT_IO;
			if (fclose(out) != 0)
				rc = EXIT_IO;
			if (rc != EXIT_OK) {
				fprintf(stderr, "tiffz: failed to write '%s'\n", out_path);
				remove(out_path);
			} else {
				fprintf(stderr, "wrote  %s  (%ux%u %s)\n", out_path, img.width, img.height, format_name(to));
			}
		}
	}
	if (to == FMT_TIFF)
		tiffz_free(encoded, encoded_len);
	else
		free(encoded);
	image_free(&img);
	return rc;
}

static int validate_one(const char *path, int json) {
	uint8_t *buf = NULL;
	size_t len = 0;
	int read_rc;
	tiffz_status_t status = TIFFZ_OK;
	tiffz_decoder_t *dec;
	FindingList findings = {0};
	size_t ifds = 0;
	int ok;

	read_rc = read_path(path, &buf, &len);
	if (read_rc == -2) {
		if (json) {
			FindingList empty = {0};
			write_json(path, 0, TIFFZ_IO, 0, &empty, NULL);
		} else {
			fprintf(stderr, "tiffz: cannot open '%s': No such file or directory\n", path);
		}
		return EXIT_IO;
	}
	if (read_rc != 0) {
		if (json) {
			FindingList empty = {0};
			write_json(path, 0, TIFFZ_IO, 0, &empty, NULL);
		} else {
			fprintf(stderr, "tiffz: failed to read '%s'\n", path);
		}
		return EXIT_IO;
	}

	dec = tiffz_open_from_buffer(buf, len, &status);
	if (dec == NULL) {
		if (json) {
			FindingList empty = {0};
			write_json(path, 0, status, 0, &empty, NULL);
		} else {
			fprintf(stderr, "%s  %s  (%s)\n", report_word(0, status), path, tiffz_status_name(status));
		}
		free(buf);
		return exit_for_status(status);
	}

	tiffz_set_finding_callback(dec, on_finding, &findings);
	status = tiffz_validate(dec);
	ifds = tiffz_ifd_count(dec);
	ok = (status == TIFFZ_OK);

	if (json) {
		write_json(path, ok, status, ifds, &findings, dec);
	} else if (ok) {
		fprintf(stderr, "ok  %s\n", path);
	} else {
		const char *msg = tiffz_last_error_message(dec);
		const char *detail = (msg != NULL && msg[0] != '\0') ? msg : tiffz_status_name(status);
		fprintf(stderr, "%s  %s  (%s)\n", report_word(0, status), path, detail);
	}

	tiffz_close(dec);
	findings_free(&findings);
	free(buf);
	return ok ? EXIT_OK : exit_for_status(status);
}

static int is_win_alias(const char *arg, const char *name) {
	/* Exact "/json" etc. Paths like /home/... are not aliases. */
	if (arg[0] != '/')
		return 0;
	return strcmp(arg + 1, name) == 0;
}

int main(int argc, char **argv) {
	int json = 0;
	int i;
	int end_opts = 0;
	const char *verb = NULL;
	const char *out_path = NULL;
	size_t ifd_index = 0;
	format_t to = FMT_NONE;
	uint32_t compression = TIFFZ_COMPRESSION_DEFLATE;
	char **files = NULL;
	int nfiles = 0;
	int worst = EXIT_OK;

	announce_debug();

	if (argc < 2)
		return print_help();

	files = calloc((size_t)argc, sizeof(*files));
	if (files == NULL) {
		fputs("tiffz: out of memory\n", stderr);
		return EXIT_IO;
	}

	for (i = 1; i < argc; i++) {
		const char *arg = argv[i];
		if (!end_opts) {
			if (strcmp(arg, "--") == 0) {
				end_opts = 1;
				continue;
			}
			if (is_exact(arg, "--help", "-h") || is_win_alias(arg, "help") ||
			    is_win_alias(arg, "h") || strcmp(arg, "/?") == 0) {
				free(files);
				return print_help();
			}
			if (is_exact(arg, "--about", NULL) || is_win_alias(arg, "about")) {
				free(files);
				return print_about();
			}
			if (is_exact(arg, "--version", "-v") || is_win_alias(arg, "version") ||
			    is_win_alias(arg, "v")) {
				free(files);
				return print_version();
			}
			if (is_exact(arg, "--json", NULL) || is_win_alias(arg, "json")) {
				json = 1;
				continue;
			}
			if (is_exact(arg, "--simple", NULL) || is_exact(arg, "--ascii", NULL) ||
			    is_exact(arg, "--no-ansi", NULL) || is_exact(arg, "--no-color", NULL)) {
				continue;
			}
			if (is_exact(arg, "-o", "--output") || is_win_alias(arg, "o")) {
				if (i + 1 >= argc) {
					fputs("tiffz: -o requires a PATH\n", stderr);
					free(files);
					return EXIT_USAGE;
				}
				out_path = argv[++i];
				continue;
			}
			if (is_exact(arg, "--ifd", NULL)) {
				if (i + 1 >= argc) {
					fputs("tiffz: --ifd requires an index\n", stderr);
					free(files);
					return EXIT_USAGE;
				}
				ifd_index = (size_t)strtoul(argv[++i], NULL, 10);
				continue;
			}
			if (is_exact(arg, "--to", NULL)) {
				if (i + 1 >= argc || (to = parse_format(argv[i + 1])) == FMT_NONE) {
					fputs("tiffz: --to takes tiff, png or bmp\n", stderr);
					free(files);
					return EXIT_USAGE;
				}
				i++;
				continue;
			}
			if (is_exact(arg, "--compression", NULL)) {
				const char *c = i + 1 < argc ? argv[++i] : "";
				if (strcmp(c, "none") == 0)
					compression = TIFFZ_COMPRESSION_NONE;
				else if (strcmp(c, "lzw") == 0)
					compression = TIFFZ_COMPRESSION_LZW;
				else if (strcmp(c, "deflate") == 0)
					compression = TIFFZ_COMPRESSION_DEFLATE;
				else {
					fputs("tiffz: --compression takes none, lzw or deflate\n", stderr);
					free(files);
					return EXIT_USAGE;
				}
				continue;
			}
			if (arg[0] == '-' && arg[1] != '\0' && !is_stdin_name(arg)) {
				fprintf(stderr, "tiffz: unknown argument '%s' (try --help)\n", arg);
				free(files);
				return EXIT_USAGE;
			}
		}
		if (verb == NULL && strcmp(arg, "validate") == 0) {
			verb = "validate";
			continue;
		}
		if (verb == NULL && strcmp(arg, "dump") == 0) {
			verb = "dump";
			continue;
		}
		if (verb == NULL && strcmp(arg, "convert") == 0) {
			verb = "convert";
			continue;
		}
		files[nfiles++] = argv[i];
	}

	if (nfiles == 0) {
		if (verb != NULL) {
			fprintf(stderr, "tiffz: %s requires a FILE (- or @stdin for stdin)\n", verb);
			free(files);
			return EXIT_USAGE;
		}
		free(files);
		return print_help();
	}

	if (verb != NULL && strcmp(verb, "convert") == 0) {
		int rc;
		if (nfiles != 1) {
			fputs("tiffz: convert takes exactly one INPUT\n", stderr);
			rc = EXIT_USAGE;
		} else if (out_path == NULL) {
			fputs("tiffz: convert requires -o OUTPUT (- or @stdout with --to)\n", stderr);
			rc = EXIT_USAGE;
		} else {
			rc = convert_one(files[0], out_path, to, compression, ifd_index);
		}
		free(files);
		return rc;
	}

	for (i = 0; i < nfiles; i++) {
		int rc;
		if (verb != NULL && strcmp(verb, "dump") == 0)
			rc = dump_one(files[i], out_path, ifd_index);
		else
			rc = validate_one(files[i], json);
		if (rc > worst)
			worst = rc;
	}
	free(files);
	return worst;
}
