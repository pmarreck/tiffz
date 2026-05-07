//! tiffz — pure-Zig spec-complete TIFF reader (and eventually
//! writer).
//!
//! Architecture (per project convention): pure Zig core (no I/O) →
//! C FFI → C CLI dogfooding the FFI. See README.md and
//! `docs/superpowers/specs/2026-05-04-tiffz-api-design.md`.

pub const errors = @import("errors.zig");
pub const limits = @import("limits.zig");
pub const source = @import("source.zig");
pub const workspace = @import("workspace.zig");
pub const header = @import("header.zig");
pub const ifd = @import("ifd.zig");
pub const tags = @import("tags.zig");
pub const photometrics = @import("photometrics.zig");
pub const compressions = struct {
    pub const none = @import("compressions/none.zig");
    pub const packbits = @import("compressions/packbits.zig");
    pub const lzw = @import("compressions/lzw.zig");
    pub const deflate = @import("compressions/deflate.zig");
};
pub const decoder = @import("decoder.zig");
pub const version = @import("version.zig");
pub const ffi = @import("ffi.zig");

// Re-export the core public types at the top level for ergonomic
// Zig consumers: `tiffz.Decoder`, `tiffz.Source`, etc.
pub const Error = errors.Error;
pub const Limits = limits.Limits;
pub const Source = source.Source;
pub const Workspace = workspace.Workspace;
pub const Decoder = decoder.Decoder;

// Force comptime analysis of the C FFI module so its `export`
// symbols are emitted into the static library. Without this, the
// FFI module is dead code from the Zig compiler's perspective.
comptime {
    _ = ffi;
}

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
