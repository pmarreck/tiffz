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

#ifdef __cplusplus
extern "C" {
#endif

/* Return a NUL-terminated, statically-allocated version string.
 * The pointer is valid for the lifetime of the loaded library. */
const char *tiffz_version(void);

#ifdef __cplusplus
}
#endif

#endif /* TIFFZ_H */
