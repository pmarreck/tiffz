/* jpegz_core.h — public C ABI for jpegz.
 *
 * Project convention: this header is the real public API. The in-tree
 * C CLI dogfoods through it; every external consumer (validate, tiffz,
 * etc.) uses it. See README.md and
 * docs/superpowers/specs/2026-05-04-jpegz-public-api-design.md.
 *
 * Buffer-lifetime contract: every function that accepts a (data, len)
 * pair borrows the buffer for the call's duration only. Caller may
 * free / reuse the buffer the moment the function returns.
 *
 * Thread safety: every function is reentrant; no shared state except
 * the thread-local last-error string. Two threads calling jpegz
 * concurrently cannot corrupt each other.
 *
 * Memory: structs containing pointers (jpegz_image_t,
 * jpegz_validation_report_t) own those pointers. Free them via the
 * matching jpegz_*_free() function. Do NOT free pointers individually.
 *
 * License: MIT. See LICENSE.
 */

#ifndef JPEGZ_CORE_H
#define JPEGZ_CORE_H

#include <stdint.h>
#include <stddef.h>

/* Auto-generated from src/core/errors.zig; emits jpegz_status_t and
 * jpegz_finding_code_t. Built at flake-time by tools/gen_c_header.zig. */
#include "jpegz_errno.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ── Versioning ────────────────────────────────────────────────── */

#define JPEGZ_VERSION_MAJOR 0
#define JPEGZ_VERSION_MINOR 1
#define JPEGZ_VERSION_PATCH 0

/* Returns a NUL-terminated, statically-allocated version string.
 * Pointer is valid for the lifetime of the loaded library. */
const char *jpegz_version(void);

/* ── Diagnostics ───────────────────────────────────────────────── */

/* Thread-local human-readable detail for the most recent error.
 * Returns a NUL-terminated UTF-8 string with thread-local lifetime —
 * valid until the next jpegz call on this thread. Returns "" (not
 * NULL) when the last call succeeded. */
const char *jpegz_last_error_message(void);

/* ── Pixel data ────────────────────────────────────────────────── */

typedef enum {
    JPEGZ_LAYOUT_GRAYSCALE = 0,
    JPEGZ_LAYOUT_RGB       = 1,
    JPEGZ_LAYOUT_CMYK      = 2,
} jpegz_pixel_layout_t;

typedef enum {
    JPEGZ_CS_UNKNOWN        = 0,
    JPEGZ_CS_GRAYSCALE      = 1,
    JPEGZ_CS_RGB            = 2,
    JPEGZ_CS_YCBCR          = 3,
    JPEGZ_CS_CMYK           = 4,
    JPEGZ_CS_YCCK           = 5,
    JPEGZ_CS_SRGB           = 6,    /* JP2 enumerated colorspace 16 */
    JPEGZ_CS_GREYSCALE_JP2  = 7,    /* JP2 enumerated colorspace 17 */
} jpegz_color_space_t;

typedef struct {
    /* For 8-bit images: pixels is a uint8_t array of size
     *   width * height * channels.
     * For 12/16-bit images: pixels is a uint8_t-aliased uint16_t array
     *   of size 2 * width * height * channels (host endianness; library
     *   guarantees the high bits are zero on <16-bit precision).
     * Free via jpegz_image_free(). */
    uint8_t              *pixels;
    size_t                pixels_len;       /* size of the buffer in bytes */
    uint32_t              width;
    uint32_t              height;
    uint8_t               channels;         /* 1 (gray) | 3 (RGB) | 4 (CMYK) */
    uint8_t               bits_per_sample;  /* 8 | 12 | 16 */
    jpegz_color_space_t   source_color_space;
    jpegz_pixel_layout_t  layout;
} jpegz_image_t;

/* Free pixels and reset the struct to zero. Safe to call on a
 * zero-initialized struct (no-op). */
void jpegz_image_free(jpegz_image_t *image);

/* Decode any T.81 / T.87 JPEG (sequential / progressive / lossless /
 * arithmetic / JPEG-LS) into a fully-realized image.
 *
 * Convenience wrapper around jpegz_decode_ex with default options
 * (single-threaded). For caller-controlled threading, use
 * jpegz_decode_ex. */
jpegz_status_t jpegz_decode(
    const uint8_t  *data,
    size_t          len,
    jpegz_image_t  *out_image
);

/* Caller-controlled decode parameters. Cross-project convention
 * (validate / jpegz / tiffz, agreed 2026-05-07).
 *
 * threads:
 *   1 (default) — sequential decode in the calling thread. No threads
 *     spawned, no oversubscription with caller-side worker pools.
 *   0           — explicit caller opt-in to library-side auto-detection
 *     (CPU count, capped at independent decode units). Library may use
 *     fewer threads than the cap if work doesn't amortize setup.
 *   >1          — explicit budget; same caveat as 0.
 *
 * No globals, no env vars, no implicit auto-detection. Today's
 * implementation accepts the value but the cleanroom decoder runs
 * sequentially regardless; pipeline parallelism lands in M2.1d
 * follow-up. Wrapper paths pass `threads` through where the
 * underlying C lib supports it (openjpeg → opj_codec_set_threads;
 * libjpeg-turbo's traditional API has no thread param). */
typedef struct {
    uint8_t threads;
    /* Reserved for forward compatibility — must be zero. Future fields
     * will be added here only by appending; existing layout never
     * shifts. */
    uint8_t reserved[7];
} jpegz_decode_options_t;

/* Decode with caller-controlled options. Pass NULL for `options` to
 * use defaults (equivalent to jpegz_decode). */
jpegz_status_t jpegz_decode_ex(
    const uint8_t                       *data,
    size_t                               len,
    const jpegz_decode_options_t        *options,
    jpegz_image_t                       *out_image
);

/* Decode JPEG 2000 (J2K codestream or JP2 file) into a fully-realized
 * image. Whole-image only in v1; tile/resolution streaming = v2.
 *
 * Convenience wrapper around jpegz_jp2_decode_ex. */
jpegz_status_t jpegz_jp2_decode(
    const uint8_t  *data,
    size_t          len,
    jpegz_image_t  *out_image
);

/* Decode JP2 with caller-controlled options. Same convention as
 * jpegz_decode_ex. JP2 path passes `options.threads` through to
 * `opj_codec_set_threads`. */
jpegz_status_t jpegz_jp2_decode_ex(
    const uint8_t                       *data,
    size_t                               len,
    const jpegz_decode_options_t        *options,
    jpegz_image_t                       *out_image
);

/* ── Row-streaming decode ──────────────────────────────────────── */

/* Returned by jpegz_decode_streaming_rows. Same fields as
 * jpegz_image_t minus the pixel buffer (rows are delivered to the
 * callback, not collected here). */
typedef struct {
    uint32_t              width;
    uint32_t              height;
    uint8_t               channels;
    uint8_t               bits_per_sample;
    jpegz_color_space_t   source_color_space;
    jpegz_pixel_layout_t  layout;
} jpegz_image_metadata_t;

/* Row callback. Invoked once per emitted row in raster order (y =
 * 0, 1, ..., height-1).
 *
 * Parameters:
 *   ctx     — opaque pointer the caller passed in. Library never
 *             dereferences it.
 *   row     — borrowed slice of pixels for this row. Length is
 *             width * channels * (bits_per_sample > 8 ? 2 : 1)
 *             bytes. Lifetime: only valid for this call.
 *   row_len — `row`'s length in bytes. Equal to the formula above;
 *             provided for convenience so callbacks don't recompute.
 *   y       — 0-based row index.
 *
 * Return value:
 *   0       — continue.
 *   non-0   — abort. Library returns JPEGZ_ERR_CALLBACK_ABORTED;
 *             the return value is preserved as the "original error"
 *             in jpegz_last_error_message ("callback returned N").
 *             Convention: positive non-zero codes are caller-defined
 *             (e.g. a TIFF strip writer might use 1 for "out of
 *             disk space"). */
typedef int (*jpegz_row_callback_fn)(
    void           *ctx,
    const uint8_t  *row,
    size_t          row_len,
    uint32_t        y
);

/* Stream decode by calling `on_row` for each output row in raster
 * order. Materializes no pixel buffer at the API surface; pixels
 * live transiently in `row` slices passed to the callback.
 *
 * Returns:
 *   JPEGZ_OK                      — all rows delivered; *out_metadata populated.
 *   JPEGZ_ERR_NOT_ROW_STREAMABLE  — progressive scan (caller should
 *                                   fall back to jpegz_decode).
 *   JPEGZ_ERR_CALLBACK_ABORTED    — callback returned non-zero.
 *                                   Detail in jpegz_last_error_message.
 *   Other JPEGZ_ERR_* on decode failure.
 *
 * Same dispatch chain as jpegz_decode (cleanroom paths first,
 * wrappers as fallback).
 *
 * `out_metadata` may be NULL if the caller doesn't need the
 * geometry summary; the callback still fires for every row. */
jpegz_status_t jpegz_decode_streaming_rows(
    const uint8_t            *data,
    size_t                    len,
    jpegz_row_callback_fn     on_row,
    void                     *ctx,
    jpegz_image_metadata_t   *out_metadata
);

/* Same with caller-controlled options. */
jpegz_status_t jpegz_decode_streaming_rows_ex(
    const uint8_t                       *data,
    size_t                               len,
    const jpegz_decode_options_t        *options,
    jpegz_row_callback_fn                on_row,
    void                                *ctx,
    jpegz_image_metadata_t              *out_metadata
);

/* ── Validation ────────────────────────────────────────────────── */

typedef enum {
    JPEGZ_SEVERITY_PASS = 0,
    JPEGZ_SEVERITY_INFO = 1,
    JPEGZ_SEVERITY_WARN = 2,
    JPEGZ_SEVERITY_FAIL = 3,
} jpegz_severity_t;

typedef enum {
    JPEGZ_VARIANT_UNKNOWN                 = 0,
    JPEGZ_VARIANT_BASELINE_HUFFMAN        = 1,
    JPEGZ_VARIANT_EXTENDED_HUFFMAN        = 2,
    JPEGZ_VARIANT_PROGRESSIVE_HUFFMAN     = 3,
    JPEGZ_VARIANT_LOSSLESS_HUFFMAN        = 4,
    JPEGZ_VARIANT_BASELINE_ARITHMETIC     = 5,
    JPEGZ_VARIANT_PROGRESSIVE_ARITHMETIC  = 6,
    JPEGZ_VARIANT_LOSSLESS_ARITHMETIC     = 7,
    JPEGZ_VARIANT_JPEGLS                  = 8,
    JPEGZ_VARIANT_JPEG2000                = 9,
} jpegz_variant_t;

typedef struct {
    jpegz_severity_t      severity;
    jpegz_finding_code_t  code;
    /* INT64_MIN means "not applicable / unknown"; any other value is a
     * legitimate byte offset into `data`. (Distinguishes from offset 0.) */
    int64_t               offset;
    /* NUL-terminated, owned by the report; freed by
     * jpegz_validation_report_free. NULL means "no detail string". */
    const char           *detail;
} jpegz_finding_t;

typedef struct {
    jpegz_severity_t       overall;
    jpegz_variant_t        variant;
    /* width/height: 0 means "not parsed". (No real JPEG is 0×0.) */
    uint32_t               width;
    uint32_t               height;
    /* Caller-readable; do not modify. Free via
     * jpegz_validation_report_free. */
    const jpegz_finding_t *findings;
    size_t                 findings_len;
} jpegz_validation_report_t;

/* Free findings array and reset the struct to zero. Safe to call on
 * a zero-initialized struct (no-op). */
void jpegz_validation_report_free(jpegz_validation_report_t *report);

/* Returns JPEGZ_OK with a populated report (even if overall == FAIL).
 * Returns JPEGZ_ERR_OUT_OF_MEMORY only on allocation failure. */
jpegz_status_t jpegz_validate(
    const uint8_t              *data,
    size_t                      len,
    jpegz_validation_report_t  *out_report
);

jpegz_status_t jpegz_jp2_validate(
    const uint8_t              *data,
    size_t                      len,
    jpegz_validation_report_t  *out_report
);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* JPEGZ_CORE_H */
