//! C FFI surface. Per project convention (CLAUDE.md) the C ABI is
//! the real public API — every consumer, including the in-tree CLI,
//! reaches the Zig core through here.
//!
//! M2: tiffz_version only. The Decoder/Source/Workspace exports
//! land alongside the M3 implementation. We export *types* via
//! tiffz_core.h hand-curated for now; build-time errno generation
//! lands in a later milestone.

const version = @import("version.zig");

/// Returns a NUL-terminated, statically-allocated version string.
/// The pointer is valid for the lifetime of the loaded library.
export fn tiffz_version() callconv(.c) [*:0]const u8 {
    return version.string.ptr;
}

test "tiffz_version returns the version string" {
    const std = @import("std");
    const ptr = tiffz_version();
    const slice: [*:0]const u8 = ptr;
    const s = std.mem.span(slice);
    try std.testing.expectEqualStrings(version.string, s);
}
