//! Codec-free TIFF container parser for downstream format classifiers.
//!
//! Import this through `dep.module("tiffz-parser")`. The full `tiffz` module
//! remains the image-decoding API and intentionally carries codec dependencies.

pub const errors = @import("errors.zig");
pub const limits = @import("limits.zig");
pub const source = @import("source.zig");
pub const header = @import("header.zig");
pub const ifd = @import("ifd.zig");
pub const tags = @import("tags.zig");
pub const decoder = @import("parser_decoder.zig");

pub const Error = errors.Error;
pub const Limits = limits.Limits;
pub const Source = source.Source;
pub const Decoder = decoder.Decoder;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
}
