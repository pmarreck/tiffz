/* tiffz CLI — dogfoods the C FFI. All I/O lives here. */

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <zlib.h>

#include "tiffz.h"

#if defined(__aarch64__) || defined(_M_ARM64)
#define TIFFZ_ARCH "aarch64"
#elif defined(__x86_64__) || defined(_M_X64)
#define TIFFZ_ARCH "x86_64"
#else
#define TIFFZ_ARCH "unknown"
#endif

#if defined(__APPLE__)
#define TIFFZ_OS "macos"
#elif defined(__linux__)
#define TIFFZ_OS "linux"
#elif defined(_WIN32)
#define TIFFZ_OS "windows"
#else
#define TIFFZ_OS "unknown"
#endif

#define EXIT_OK 0
#define EXIT_INVALID 1
#define EXIT_USAGE 2
#define EXIT_IO 3

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
	printf("tiffz %s — pure-Zig spec-complete TIFF reader (%s/%s)\n",
	       tiffz_version(), TIFFZ_OS, TIFFZ_ARCH);
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
		"    tiffz --about | --version | --help\n"
		"\n"
		"FILE may be a path, - , or @stdin.\n"
		"\n"
		"VERBS:\n"
		"    validate         Decode every strip/tile; report findings (default)\n"
		"    dump             Decode one IFD to 8-bit RGBA PNG\n"
		"\n"
		"OPTIONS:\n"
		"    --json           Write a JSON report to stdout (validate)\n"
		"    -o, --output PATH  PNG destination for dump (- or @stdout for stdout)\n"
		"    --ifd N          IFD index to dump (default 0)\n"
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
		"    3  I/O error (missing file, read failure)\n",
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

static void write_json(
	const char *path,
	int ok,
	tiffz_status_t status,
	size_t ifds,
	const FindingList *list) {
	size_t i;
	fputs("{\"status\":", stdout);
	json_escape(stdout, ok ? "ok" : "invalid");
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
	fputs("]}\n", stdout);
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

static void wr_be32(FILE *fp, uint32_t v) {
	uint8_t b[4] = {
		(uint8_t)(v >> 24), (uint8_t)(v >> 16),
		(uint8_t)(v >> 8), (uint8_t)v,
	};
	fwrite(b, 1, 4, fp);
}

static int write_png_chunk(FILE *fp, const char *type, const uint8_t *data, uLong n) {
	uint32_t crc;
	wr_be32(fp, (uint32_t)n);
	if (fwrite(type, 1, 4, fp) != 4)
		return -1;
	if (n > 0 && fwrite(data, 1, n, fp) != n)
		return -1;
	crc = (uint32_t)crc32(0L, (const Bytef *)type, 4);
	if (n > 0)
		crc = (uint32_t)crc32(crc, data, n);
	wr_be32(fp, crc);
	return 0;
}

static int write_rgba_png(FILE *fp, const uint8_t *rgba, uint32_t width, uint32_t height) {
	static const uint8_t sig[8] = { 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };
	uint8_t ihdr[13];
	size_t row_bytes = (size_t)width * 4;
	size_t raw_len = (size_t)height * (1 + row_bytes);
	uint8_t *raw = NULL;
	uLongf comp_len;
	uint8_t *comp = NULL;
	uint32_t y;
	int rc = -1;

	if (fwrite(sig, 1, 8, fp) != 8)
		return -1;

	ihdr[0] = (uint8_t)(width >> 24);
	ihdr[1] = (uint8_t)(width >> 16);
	ihdr[2] = (uint8_t)(width >> 8);
	ihdr[3] = (uint8_t)width;
	ihdr[4] = (uint8_t)(height >> 24);
	ihdr[5] = (uint8_t)(height >> 16);
	ihdr[6] = (uint8_t)(height >> 8);
	ihdr[7] = (uint8_t)height;
	ihdr[8] = 8;  /* bit depth */
	ihdr[9] = 6;  /* RGBA */
	ihdr[10] = 0;
	ihdr[11] = 0;
	ihdr[12] = 0;
	if (write_png_chunk(fp, "IHDR", ihdr, 13) != 0)
		return -1;

	raw = malloc(raw_len);
	if (raw == NULL)
		return -1;
	for (y = 0; y < height; y++) {
		raw[(size_t)y * (1 + row_bytes)] = 0; /* filter None */
		memcpy(raw + (size_t)y * (1 + row_bytes) + 1, rgba + (size_t)y * row_bytes, row_bytes);
	}
	comp_len = compressBound((uLong)raw_len);
	comp = malloc(comp_len);
	if (comp == NULL) {
		free(raw);
		return -1;
	}
	if (compress(comp, &comp_len, raw, (uLong)raw_len) != Z_OK) {
		free(comp);
		free(raw);
		return -1;
	}
	if (write_png_chunk(fp, "IDAT", comp, comp_len) == 0 &&
	    write_png_chunk(fp, "IEND", NULL, 0) == 0)
		rc = 0;
	free(comp);
	free(raw);
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
		fprintf(stderr, "invalid  %s  (%s)\n", path, tiffz_status_name(status));
		free(buf);
		return EXIT_INVALID;
	}
	status = tiffz_decode_rgba(dec, ifd_index, &pixels, &width, &height);
	if (status != TIFFZ_OK) {
		const char *msg = tiffz_last_error_message(dec);
		fprintf(stderr, "invalid  %s  (%s)\n", path,
			(msg != NULL && msg[0] != '\0') ? msg : tiffz_status_name(status));
		tiffz_close(dec);
		free(buf);
		return EXIT_INVALID;
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
	if (write_rgba_png(out, pixels, width, height) != 0) {
		fprintf(stderr, "tiffz: failed to write PNG\n");
		rc = EXIT_IO;
	} else {
		if (!is_stdout_name(out_path))
			fprintf(stderr, "wrote  %s  (%ux%u)\n", out_path, width, height);
		rc = EXIT_OK;
	}
	if (close_out)
		fclose(out);
	tiffz_free(pixels, pix_len);
	tiffz_close(dec);
	free(buf);
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
			write_json(path, 0, TIFFZ_IO, 0, &empty);
		} else {
			fprintf(stderr, "tiffz: cannot open '%s': No such file or directory\n", path);
		}
		return EXIT_IO;
	}
	if (read_rc != 0) {
		if (json) {
			FindingList empty = {0};
			write_json(path, 0, TIFFZ_IO, 0, &empty);
		} else {
			fprintf(stderr, "tiffz: failed to read '%s'\n", path);
		}
		return EXIT_IO;
	}

	dec = tiffz_open_from_buffer(buf, len, &status);
	if (dec == NULL) {
		if (json) {
			FindingList empty = {0};
			write_json(path, 0, status, 0, &empty);
		} else {
			fprintf(stderr, "invalid  %s  (%s)\n", path, tiffz_status_name(status));
		}
		free(buf);
		return EXIT_INVALID;
	}

	tiffz_set_finding_callback(dec, on_finding, &findings);
	status = tiffz_validate(dec);
	ifds = tiffz_ifd_count(dec);
	ok = (status == TIFFZ_OK);

	if (json) {
		write_json(path, ok, status, ifds, &findings);
	} else if (ok) {
		fprintf(stderr, "ok  %s\n", path);
	} else {
		const char *msg = tiffz_last_error_message(dec);
		if (msg != NULL && msg[0] != '\0')
			fprintf(stderr, "invalid  %s  (%s)\n", path, msg);
		else
			fprintf(stderr, "invalid  %s  (%s)\n", path, tiffz_status_name(status));
	}

	tiffz_close(dec);
	findings_free(&findings);
	free(buf);
	return ok ? EXIT_OK : EXIT_INVALID;
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
