/* tiffz — public C API.
 *
 * Project convention: this header is the real public API. The
 * in-tree CLI dogfoods through it; every external consumer uses it.
 * See README.md and docs/superpowers/specs/2026-05-04-tiffz-api-design.md.
 *
 * Status integers are 1:1 with src/errors.zig (append-only). 0 is OK.
 */

#ifndef TIFFZ_H
#define TIFFZ_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *tiffz_version(void);

typedef int32_t tiffz_status_t;
#define TIFFZ_OK 0
#define TIFFZ_INVALID_ARGUMENT 1
#define TIFFZ_MALFORMED 2
#define TIFFZ_UNSUPPORTED_COMPRESSION 3
#define TIFFZ_UNSUPPORTED_PHOTOMETRIC 4
#define TIFFZ_UNSUPPORTED_PREDICTOR 5
#define TIFFZ_UNSUPPORTED_BIT_DEPTH 6
#define TIFFZ_UNSUPPORTED_TAG_TYPE 7
#define TIFFZ_SOURCE_SEEK_TOO_FAR_BACK 8
#define TIFFZ_SOURCE_SHORT_READ 9
#define TIFFZ_SOURCE_TOO_SHORT 10
#define TIFFZ_LIMIT_EXCEEDED_IFD_COUNT 11
#define TIFFZ_LIMIT_EXCEEDED_TAG_COUNT 12
#define TIFFZ_LIMIT_EXCEEDED_TAG_VALUE_BYTES 13
#define TIFFZ_LIMIT_EXCEEDED_STRIP_COUNT 14
#define TIFFZ_LIMIT_EXCEEDED_DIMENSION 15
#define TIFFZ_LIMIT_EXCEEDED_TOTAL_SAMPLES 16
#define TIFFZ_LIMIT_EXCEEDED_CODEC_SCRATCH 17
#define TIFFZ_LIMIT_EXCEEDED_COMPRESSED_STRIP_BYTES 18
#define TIFFZ_LIMIT_EXCEEDED_DECOMPRESSED_STRIP_BYTES 19
#define TIFFZ_DEST_TOO_SMALL 20
#define TIFFZ_OUT_OF_MEMORY 21
#define TIFFZ_IO 22
#define TIFFZ_BUG 23
#define TIFFZ_IFD_CHAIN_CYCLE 24
#define TIFFZ_JPEG_IN_TIFF_PAYLOAD 25

const char *tiffz_status_name(tiffz_status_t status);

typedef struct tiffz_decoder tiffz_decoder_t;

/* Borrow `bytes` for the decoder lifetime. Caller keeps the buffer alive
 * until tiffz_close. On failure returns NULL and writes a non-zero status. */
tiffz_decoder_t *tiffz_open_from_buffer(
    const uint8_t *bytes,
    size_t len,
    tiffz_status_t *out_status);

void tiffz_close(tiffz_decoder_t *decoder);

tiffz_status_t tiffz_validate(tiffz_decoder_t *decoder);

size_t tiffz_ifd_count(const tiffz_decoder_t *decoder);

const char *tiffz_last_error_message(const tiffz_decoder_t *decoder);

typedef int32_t tiffz_source_decoder_t;
#define TIFFZ_SOURCE_UNKNOWN ((tiffz_source_decoder_t)0)
#define TIFFZ_SOURCE_TIFFZ ((tiffz_source_decoder_t)1)
#define TIFFZ_SOURCE_JPEGZ ((tiffz_source_decoder_t)2)
#define TIFFZ_SOURCE_JP2Z ((tiffz_source_decoder_t)3)
#define TIFFZ_SOURCE_LIBJXLZ ((tiffz_source_decoder_t)4)

typedef int32_t tiffz_finding_verdict_t;
#define TIFFZ_VERDICT_VALID ((tiffz_finding_verdict_t)0)
#define TIFFZ_VERDICT_CORRUPT ((tiffz_finding_verdict_t)1)
#define TIFFZ_VERDICT_UNSUPPORTED ((tiffz_finding_verdict_t)2)
#define TIFFZ_VERDICT_INDETERMINATE ((tiffz_finding_verdict_t)3)

#define TIFFZ_FINDING_MAPPED_CODE_PRESENT UINT32_C(1)
#define TIFFZ_FINDING_BYTE_OFFSET_PRESENT UINT32_C(2)
#define TIFFZ_FINDING_HOST_OFFSET_PRESENT UINT32_C(4)
#define TIFFZ_FINDING_OFFSET_IS_EXACT UINT32_C(8)

typedef void (*tiffz_finding_callback_t)(
    void *userdata,
    tiffz_source_decoder_t source_decoder,
    int32_t finding_code,
    int32_t mapped_finding_code,
    tiffz_finding_verdict_t verdict,
    uint64_t byte_offset,
    uint64_t host_byte_offset,
    uint32_t metadata_flags,
    const uint8_t *payload,
    size_t payload_len);

void tiffz_set_finding_callback(
    tiffz_decoder_t *decoder,
    tiffz_finding_callback_t callback,
    void *userdata);

/* Decode one IFD to packed 8-bit RGBA. On success `*out_pixels` is
 * width*height*4 bytes owned by the caller; free with tiffz_free. */
tiffz_status_t tiffz_decode_rgba(
    tiffz_decoder_t *decoder,
    size_t ifd_index,
    uint8_t **out_pixels,
    uint32_t *out_width,
    uint32_t *out_height);

void tiffz_free(void *ptr, size_t len);

#ifdef __cplusplus
}
#endif

#endif /* TIFFZ_H */
