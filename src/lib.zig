//! tiffz — pure-Zig spec-complete TIFF reader (and eventually
//! writer).
//!
//! Architecture (per project convention): pure Zig core (no I/O) →
//! C FFI → C CLI dogfooding the FFI. See README.md and
//! `docs/superpowers/specs/2026-05-04-tiffz-api-design.md`.

pub const errors = @import("errors.zig");
// Re-export the one shared LZW module. Validate's PDF/GIF adapters consume
// this instance through tiffz so Zig 0.16 never sees two modules with the
// same lzwz source root.
pub const lzwz = @import("lzwz");
// Re-export jpegz so downstream consumers (e.g. validate) can reach the JPEG
// family decoder through tiffz instead of depending on jpegz a second time.
// Two independent `b.dependency("jpegz")` calls (one here, one in the consumer)
// create two module instances sharing one root file, which Zig 0.16 rejects
// ("file exists in modules 'jpegz' and 'jpegz0'") and the nix sandbox SEGVs on.
// Single source of truth = no dual-pin drift. See validate #32.
pub const jpegz = @import("jpegz");
pub const limits = @import("limits.zig");
pub const source = @import("source.zig");
pub const workspace = @import("workspace.zig");
pub const header = @import("header.zig");
pub const ifd = @import("ifd.zig");
pub const tags = @import("tags.zig");
pub const photometrics = @import("photometrics.zig");
pub const predictors = @import("predictors.zig");
pub const dng = @import("dng.zig");
pub const findings = @import("findings.zig");
pub const compressions = struct {
    pub const none = @import("compressions/none.zig");
    pub const packbits = @import("compressions/packbits.zig");
    pub const lzw = lzwz;
    pub const deflate = @import("compressions/deflate.zig");
    pub const ccitt_t4 = @import("compressions/ccitt_t4.zig");
    pub const ccitt_t6 = @import("compressions/ccitt_t6.zig");
    pub const jpeg = @import("compressions/jpeg.zig");
    pub const zstd = @import("compressions/zstd.zig");
    pub const lerc = @import("compressions/lerc.zig");
};
pub const geotiff = @import("geotiff.zig");
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
