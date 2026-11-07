//! liblzma's C API (xz 5.8.3, 0BSD), decoder subset. Built by this
//! package's build.zig from the pinned upstream release.
pub const c = @cImport({
    @cInclude("lzma.h");
});
