//! libwebp's decoding API (libwebp 1.6.0, BSD-3-Clause). Built by this
//! package's build.zig from the pinned upstream release.
pub const c = @cImport({
    @cInclude("webp/decode.h");
});
