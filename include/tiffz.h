/* tiffz — public C API.
 *
 * Project convention: this header is the real public API. The
 * in-tree CLI dogfoods through it; every external consumer uses it.
 * See README.md and docs/superpowers/specs/2026-05-04-tiffz-api-design.md.
 *
 * M2: only tiffz_version() is exported. The Decoder / Source /
 * Workspace surfaces, plus the build-generated tiffz_status_t enum,
 * land alongside their M3+ implementations.
 */

#ifndef TIFFZ_H
#define TIFFZ_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Return a NUL-terminated, statically-allocated version string.
 * The pointer is valid for the lifetime of the loaded library. */
const char *tiffz_version(void);

/* Finding producer and verdict are explicitly int32_t at the ABI. Keep these
 * registries append-only; unknown future integer values remain valid inputs. */
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

#ifdef __cplusplus
}
#endif

#endif /* TIFFZ_H */
