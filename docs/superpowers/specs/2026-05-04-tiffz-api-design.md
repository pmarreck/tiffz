# tiffz Public API Design

**Date:** 2026-05-04
**Status:** Approved (brainstormed with Peter, validate handoff incorporated)
**Supersedes:** `SPEC.md` §1 / §8 sketches

This document is the frozen public API design for tiffz. It is the
input contract for the upcoming implementation plan. All subsequent
implementation work plans against this design; deviations require
re-brainstorming.

---

## 1. Mission recap

Pure-Zig, spec-complete TIFF reader (and eventually writer) targeting
byte-complete validation coverage of TIFF 6.0 + the major modern
extensions (BigTIFF, TIFF/EP, DNG, GeoTIFF). Hexagonal architecture:

```
Any consumer ──► C FFI (the real public API) ──► Zig core (pure, no I/O)
```

The Zig core does no I/O. The C FFI is what every external consumer
uses, including the in-tree C CLI (which dogfoods the FFI).

---

## 2. Access patterns (the four modes)

All four are first-class. They are not separate code paths — they are
thin convenience wrappers over a single random-access primitive.

| Mode | Use case                                              | Built on            |
|------|-------------------------------------------------------|---------------------|
| A    | Validate — decode every strip, never retain pixels    | Decoder (discard)   |
| B    | Pipeline decode — callback per strip, consumer holds  | Decoder (callback)  |
| C    | Random access — open, walk IFD tree, decode strip N   | Decoder (primitive) |
| D    | Eager all-at-once — return `Image{pixels}`            | Decoder (gather)    |

`Decoder` is the engine. A/B/D are 30-line convenience functions on
top of C.

---

## 3. Foundation: `Source` (seekable byte source)

The library never opens files. Consumers pass a `Source` — a vtable
abstraction over byte-range reads, pread-style.

```zig
pub const Source = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Read into buf starting at byte offset. Returns bytes read.
        /// Short reads at EOF are allowed; reads past end return 0.
        /// MUST be safe to call concurrently from multiple threads
        /// (see §8 thread safety contract).
        read_at: *const fn (ctx: *anyopaque, buf: []u8, offset: u64) anyerror!usize,
        /// Total size of the source, in bytes.
        size: *const fn (ctx: *anyopaque) anyerror!u64,
    };

    pub fn fromBuffer(buf: []const u8) Source;
    pub fn fromMmap(mmap: anytype) Source;
    pub fn fromFile(file: std.fs.File) Source;       // pread-based
    pub fn fromBufferedReader(
        reader: anytype,
        allocator: Allocator,
        options: BufferedReaderOptions,
    ) !Source;
};

pub const BufferedReaderOptions = struct {
    /// Sliding cache window in bytes. Default 8 MiB.
    cache_bytes: usize = 8 << 20,
    /// What to do when read_at requests an offset behind the window.
    /// Default `.err` returns error.SourceSeekTooFarBack.
    /// `.fully_buffer` materializes the entire stream up-front (RAM = source size).
    on_miss: enum { err, fully_buffer } = .err,
};
```

### Why seekable

Forward-only `std.io.Reader` cannot serve random IFD walks (DNG embedded
thumbnails, multi-page faxes, BigTIFF directory trees). Pread-based
`Source` is libtiff's structure too, well-trodden ground.

For consumers with only a forward-only stream (HTTP, stdin), the
`fromBufferedReader` adapter materializes ranges on demand. The cache
size and miss policy are caller-controlled — tiffz never silently
degrades to O(n²) on adversarial layouts.

---

## 4. The Decoder primitive

```zig
pub const Decoder = struct {
    pub fn open(allocator: Allocator, source: Source) !Decoder;
    pub fn openWithLimits(
        allocator: Allocator,
        source: Source,
        limits: Limits,
    ) !Decoder;
    pub fn deinit(self: *Decoder) void;

    pub fn ifdCount(self: *const Decoder) usize;
    pub fn ifd(self: *const Decoder, index: usize) !IfdView;

    /// Decode one strip into caller-supplied dest. Library never
    /// allocates pixel storage. dest.len bounds the maximum write.
    pub fn decodeStrip(
        self: *const Decoder,
        ifd_index: usize,
        strip_index: u32,
        dest: []u8,
        workspace: *Workspace,
    ) !DecodeResult;

    /// Tile decode is the equivalent path for tiled TIFFs.
    pub fn decodeTile(
        self: *const Decoder,
        ifd_index: usize,
        tile_index: u32,
        dest: []u8,
        workspace: *Workspace,
    ) !DecodeResult;
};

pub const DecodeResult = struct {
    bytes_written: usize,
    width_pixels: u32,
    height_pixels: u32,
    /// PixelLayout describes byte order, sample arrangement, channel count.
    layout: PixelLayout,
};
```

### Lifecycle: two-phase, multi-thread-ready

1. **Open phase (single-threaded by contract).** `Decoder.open` reads
   the header, walks the IFD chain, materializes all metadata. After
   `open` returns, all metadata is **frozen** — no further mutation.
2. **Decode phase (read-only on Decoder, parallel-ready).** All
   `decodeStrip` / `decodeTile` calls take `*const Decoder`. They
   read immutable IFD metadata and an immutable Source (`read_at` is
   thread-safe per §8). The only mutable state is the per-call
   `Workspace`.

This is the architecture for future multi-threading. v1 ships
single-threaded; the API does not change to enable threading later —
consumers just allocate one `Workspace` per worker.

### Workspace (per-call codec scratch)

```zig
pub const Workspace = struct {
    pub fn init(allocator: Allocator) Workspace;
    pub fn deinit(self: *Workspace) void;
    /// Reset (free internal scratch but keep the structure for reuse).
    pub fn reset(self: *Workspace) void;
};
```

A `Workspace` holds codec scratch (LZW dictionary, JPEG decoder state,
CCITT context, decompression buffers). It is single-threaded — never
share one across threads. Reuse one `Workspace` across many strips on
one thread to avoid per-strip allocations.

In v1, single-threaded callers can share one `Workspace` instance
across all decodes. In a future multi-threaded mode, callers allocate
one per worker. The signature does not change.

---

## 5. Allocation discipline (α + cached codec state in Workspace)

Three categories of memory:

| Category               | Lifetime           | Owner                         |
|------------------------|--------------------|-------------------------------|
| IFD metadata, color tables, decoder-wide state | Decoder lifetime | `allocator` passed to `open` |
| Per-call codec scratch | One decode call    | `Workspace.allocator`        |
| Output pixels          | Caller's choice    | Caller (`dest: []u8`)         |

Library never allocates output pixel storage. Library never holds
file handles, mmap regions, or any I/O resource — `Source` owns those.

Convention matches Peter's stack: thread `Allocator` explicitly, no
global state, no hidden frees.

---

## 6. Limits (resource exhaustion / decompression-bomb defense)

Adversarial TIFFs are a documented attack category. Every Decoder
enforces a `Limits` struct, with permissive-but-bounded defaults:

```zig
pub const Limits = struct {
    /// IFD chain bound (loop defense, well above DNG / multi-page real-world use).
    max_ifds: u32                     = 1024,
    /// EXIF/DNG use hundreds of tags; 4k is generous.
    max_tags_per_ifd: u32             = 4096,
    /// ICC profiles fit; pathological tag values don't.
    max_tag_value_bytes: u64          = 64 << 20,
    /// 16M strips; well above any sane image.
    max_strips_or_tiles: u32          = 16 << 20,
    /// ~1B pixels per axis. Gigapixel imagery fits comfortably.
    max_dim: u32                      = 1 << 30,
    /// ~1T total samples. Width × height × samples overflow guard.
    max_total_samples: u64            = 1 << 40,
    /// Per-decode-call codec scratch cap.
    max_codec_scratch: u64            = 256 << 20,
    /// Single compressed strip on-disk cap.
    max_compressed_strip_bytes: u64   = 1 << 30,
    /// Single decompressed strip cap (compression-bomb defense).
    max_decompressed_strip_bytes: u64 = 1 << 30,
};
```

Caller-supplied `dest.len` is the third bound — codec output never
exceeds `dest.len` regardless of limit values. Limits are
defense-in-depth, not the only line.

Validate's specific use case may tighten limits aggressively (treat
the input as untrusted). Library default is permissive enough to
process pro-photography multi-GB TIFFs without complaint.

Each limit triggers a distinct Zig error variant (see §7) — consumers
can branch by category. `tiffz_last_error_message` carries specifics
(which IFD, which tag, observed value vs limit).

---

## 7. Error model (β: 1:1 stable C enum mapping)

The Zig error set is the source of truth. The C header is generated
from it at build time. This forces structural alignment and makes the
C ABI a formal contract over the Zig errors.

```zig
// src/core/errors.zig — single declaration, ordered by introduction
pub const Error = error{
    InvalidArgument,        // = 1
    Malformed,              // = 2  (generic structural error)
    UnsupportedCompression, // = 3
    UnsupportedPhotometric, // = 4
    UnsupportedPredictor,   // = 5
    UnsupportedBitDepth,    // = 6
    UnsupportedTagType,     // = 7
    SourceSeekTooFarBack,   // = 8
    SourceShortRead,        // = 9
    SourceTooShort,         // = 10
    LimitExceededIfdCount,  // = 11
    LimitExceededTagCount,  // = 12
    LimitExceededTagValueBytes,        // = 13
    LimitExceededStripCount,           // = 14
    LimitExceededDimension,            // = 15
    LimitExceededTotalSamples,         // = 16
    LimitExceededCodecScratch,         // = 17
    LimitExceededCompressedStripBytes, // = 18
    LimitExceededDecompressedStripBytes, // = 19
    DestTooSmall,           // = 20
    OutOfMemory,            // = 21
    Io,                     // = 22  (Source.read_at error pass-through)
    Bug,                    // = 23  (internal invariant violated)
    // ... append-only as new variants are introduced
};
```

Discipline:

- **Append-only.** Values are assigned at first introduction, never
  reordered, never reused. Removing a Zig variant means the C value
  stays in the header (commented "deprecated") and the mapper returns
  `TIFFZ_BUG` if it ever fires.
- **CI guard.** `tests/abi/error_codes.snapshot.txt` is committed.
  Build fails if existing values change. New values append.
- **Generation.** `build.zig` reads `src/core/errors.zig` at codegen
  time (via `@import` + comptime reflection) and emits
  `include/tiffz_errno.h`. C header cannot drift from Zig.
- **Mapper exhaustiveness.** `ffi/c_api.zig` has one
  `fn toCStatus(err: Error) c_int` switch, exhaustive — drop a variant
  from the set and the FFI fails to compile until the mapper is
  updated.
- **Diagnostics.** `tiffz_last_error_message(decoder) -> const char*`
  returns a per-Decoder buffer holding the message set on the most
  recent failing call against that decoder. Stable enum is for
  branching; message is for logging. The buffer is owned by the
  Decoder; valid until the next call against the same decoder or
  until `tiffz_close`. Callers must not call this concurrently with
  other tiffz calls on the same decoder.

---

## 8. Thread safety contract

| Surface                  | Contract                                       |
|--------------------------|------------------------------------------------|
| `Source.read_at`         | Caller-implementer MUST provide a thread-safe impl. `fromFile` (pread) is. `fromMmap` is. `fromBuffer` is. `fromBufferedReader` is NOT — single-threaded only. |
| `Decoder.open`           | Single-threaded (one goroutine/thread/task). Caller sequences. |
| `Decoder.{decodeStrip, decodeTile, ifd, ifdCount}` | Read-only on `*const Decoder`. Safe to call concurrently from multiple threads, **provided** each thread uses a distinct `Workspace`. |
| `Workspace.{decode/reset/deinit}` | Single-threaded — never share across threads. |
| `Decoder.deinit`         | Caller ensures no concurrent `decodeStrip` calls remain. |
| `tiffz_last_error_message` | Per-Decoder buffer. Caller must not race with other calls on the same decoder. |

v1 ships single-threaded everywhere. The contract above defines the
shape multi-threading will take when enabled — no API changes
required.

---

## 9. Pre-resolved decisions (carried over from validate handoff)

The validate inbox handoff (`inbox/2026-05-04-api-shape-response-from-validate.md`)
pre-resolved several items that don't need re-brainstorming. Captured
here for completeness:

- **Lazy IFD parsing.** `Decoder.open` reads the IFD entry skeleton
  (tag dict per IFD); tag *values* (color tables, ICC profiles, large
  arrays) are fetched on demand via `IfdView` accessors. Multi-IFD
  TIFFs and DNGs benefit; classic-TIFF readers pay nothing for tags
  they don't query.
- **Strip and tile share the post-decode pipeline.** They differ only
  at the byte-source layer (one stride vs N×M tile-grid). Both feed
  the same predictor / photometric / colorspace pipeline.
- **BigTIFF offset width.** `comptime`-parameterized at the IFD parser
  level. Classic TIFF (`u32`) and BigTIFF (`u64`) share the parsing
  skeleton via a generic `OffsetWidth` parameter. Classic TIFF
  consumers pay zero overhead.

---

## 10. Convenience APIs (A / B / D as wrappers over Decoder)

```zig
/// A — validate-only. Walks every strip/tile of every IFD into the
/// caller-supplied scratch (overwritten each iteration). Returns a
/// structured report.
pub fn validateAll(
    allocator: Allocator,
    source: Source,
    scratch: []u8,
    workspace: *Workspace,
) !ValidationReport;

/// B — pipeline decode. Same walk, callback receives each strip/tile.
pub fn decodeStreaming(
    allocator: Allocator,
    source: Source,
    workspace: *Workspace,
    callback: *const fn (StripCallbackArg) anyerror!void,
) !void;

/// D — eager all-at-once. Decodes IFD 0 in matrix order, allocates
/// and returns Image. The one place the library allocates pixel
/// storage — and only because the convenience-mode contract is
/// "give me everything in one buffer."
pub fn decodeAll(
    allocator: Allocator,
    source: Source,
) !Image;
```

---

## 11. C FFI shape

Mirror of the Zig API. Caller-allocates everywhere except the opaque
`tiffz_decoder_t` (which is freed via `tiffz_close`).

```c
// tiffz_core.h (excerpt — full header is build-generated)

typedef struct tiffz_source {
    void *ctx;
    int  (*read_at)(void *ctx, uint8_t *buf, size_t buf_len,
                    uint64_t offset, size_t *out_read);
    int  (*size)(void *ctx, uint64_t *out_size);
} tiffz_source_t;

typedef struct tiffz_limits {
    uint32_t max_ifds;
    uint32_t max_tags_per_ifd;
    uint64_t max_tag_value_bytes;
    uint32_t max_strips_or_tiles;
    uint32_t max_dim;
    uint64_t max_total_samples;
    uint64_t max_codec_scratch;
    uint64_t max_compressed_strip_bytes;
    uint64_t max_decompressed_strip_bytes;
} tiffz_limits_t;

void tiffz_limits_default(tiffz_limits_t *out);

typedef struct tiffz_decoder tiffz_decoder_t;
typedef struct tiffz_workspace tiffz_workspace_t;

tiffz_workspace_t *tiffz_workspace_new(void);
void               tiffz_workspace_free(tiffz_workspace_t *ws);

tiffz_decoder_t *tiffz_open(const tiffz_source_t *source);
tiffz_decoder_t *tiffz_open_with_limits(const tiffz_source_t *source,
                                         const tiffz_limits_t *limits);
void             tiffz_close(tiffz_decoder_t *decoder);

size_t tiffz_ifd_count(const tiffz_decoder_t *decoder);
int    tiffz_ifd_get(const tiffz_decoder_t *decoder, size_t index,
                     tiffz_ifd_view_t *out);

int tiffz_decode_strip(const tiffz_decoder_t *decoder,
                       size_t ifd_index, uint32_t strip_index,
                       uint8_t *dest, size_t dest_len,
                       tiffz_workspace_t *ws,
                       tiffz_decode_result_t *out);

const char *tiffz_last_error_message(const tiffz_decoder_t *decoder);

// Convenience wrappers (same shape as Zig):
typedef struct tiffz_validation_report { /* counts per category */ } tiffz_validation_report_t;

int tiffz_validate_all(const tiffz_decoder_t *decoder,
                       uint8_t *scratch, size_t scratch_len,
                       tiffz_workspace_t *ws,
                       tiffz_validation_report_t *out);

typedef int (*tiffz_strip_callback_t)(void *user_ctx,
                                       size_t ifd, uint32_t strip,
                                       const uint8_t *bytes, size_t len);
int tiffz_decode_streaming(const tiffz_decoder_t *decoder,
                            tiffz_workspace_t *ws,
                            tiffz_strip_callback_t cb, void *user_ctx);
```

Conventions:
- Zero return = success; non-zero = error code from `tiffz_status_t`
  (the build-generated stable enum from §7).
- Byte slices as `(ptr, len)` pairs.
- Caller-allocates output buffers; library never mallocs anything the
  caller has to free, except the opaque `tiffz_decoder_t` and
  `tiffz_workspace_t`.

---

## 12. JPEG-in-TIFF: deferred to a follow-up milestone

JPEG-in-TIFF (compression=7) is excluded from milestones 1–9. It
slots in as **milestone 9.5** after pro photometrics (§9 in SPEC.md
mentions DNG + photometrics as 8/9) and before/around milestone 10
(validate integration).

The JPEG decoder will be a sibling pure-Zig project (`jpegz`) that
Peter is in-process building. tiffz consumes it via `build.zig.zon`
when ready. No vendoring inside tiffz; no FFI back into validate
(which would invert the dependency graph).

**Implication for milestones 1–9:** any TIFF in the audit corpus that
uses compression=7 is treated as "structurally validate, decode-skip"
during this period. Validate's TIFF integration at milestone 10 will
note JPEG-in-TIFF as "awaiting milestone 9.5" until then.

---

## 13. What this design DOES NOT include

- Write path. Reader-only for the foreseeable future. Write is a
  separate design conversation.
- Color management beyond pass-through. ICC profiles are surfaced as
  byte arrays; transform decisions are the consumer's.
- EXIF / TIFF/EP / GeoTIFF tag interpretation beyond raw value access.
  The IfdView gives consumers structured tag access; semantic
  interpretation lives in callers (or future sibling libs).
- DNG opcode list execution. DNG opcodes are surfaced as a
  structured list; tiffz doesn't run them. (Renderers do.)

---

## 14. Open implementation questions (to be settled in the plan, not the spec)

These are *implementation* choices, intentionally not pre-decided
here. They will surface in the writing-plans phase:

- File layout under `src/core/` — exact module split for compressions,
  predictors, photometrics. SPEC §6 has a sketch; treat it as a
  starting point, not a contract.
- IfdView concrete shape — accessor API for typed tag reads. Probably
  a small set of `getU16(tag)`, `getU32(tag)`, `getRationalAsF64(tag)`,
  `getBytes(tag, scratch)` etc., but exact ergonomics come during impl.
- Per-Decoder error message buffer size (probably 256–512 bytes).
  Truncation behavior on overflow.
- Test fixture corpus organization — SPEC.md Appendix B has the
  generation recipes; the on-disk layout under `tests/fixtures/` is an
  impl detail.

---

## 15. Acceptance

This design has been brainstormed end-to-end with Peter, with input
from validate (which is the primary downstream consumer). The five
questions resolved:

| Q | Topic                                | Resolution |
|---|--------------------------------------|------------|
| 1 | Access patterns                      | All four (A/B/C/D) first-class, built on seekable `Source`. |
| 2 | Allocation strategy                  | α — single threaded `Allocator`; codec scratch in `Workspace`; caller-supplied `dest` for output. Multi-thread-ready architecture. |
| 3 | Error model / FFI stability          | β — 1:1 stable C enum, generated from Zig at build time, append-only, CI-snapshot-guarded. |
| 4 | JPEG-in-TIFF                         | δ→β — defer to milestone 9.5; consume sibling `jpegz` project when ready. |
| 5 | Forward-only adapter cache + safety  | α/γ — caller-controlled cache size with `.err`-on-miss default; explicit `Limits` struct for resource exhaustion / decompression-bomb defense. |

Next step: invoke `superpowers:writing-plans` to produce the phased
implementation plan against this design.
