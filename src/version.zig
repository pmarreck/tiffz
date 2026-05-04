//! Version string. Single source of truth for both the Zig public
//! API and the C FFI's tiffz_version() return value.

pub const string: [:0]const u8 = "0.1.0";

test "version is non-empty" {
    const std = @import("std");
    try std.testing.expect(string.len > 0);
}
