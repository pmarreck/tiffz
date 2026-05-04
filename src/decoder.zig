//! The Decoder primitive: random-access TIFF decode engine. All four
//! access patterns (validate / pipeline / random / eager) build on
//! this. See `docs/superpowers/specs/2026-05-04-tiffz-api-design.md`.
//!
//! M2: skeleton — open returns InvalidArgument until M3 wires up the
//! IFD parser. The point at this milestone is to lock in the type
//! shape so the FFI surface and CI can compile.

const std = @import("std");
const Allocator = std.mem.Allocator;

const errors = @import("errors.zig");
const Limits = @import("limits.zig").Limits;
const Source = @import("source.zig").Source;
const Workspace = @import("workspace.zig").Workspace;

pub const Decoder = struct {
    allocator: Allocator,
    source: Source,
    limits: Limits,

    pub fn open(allocator: Allocator, source: Source) errors.Error!Decoder {
        return openWithLimits(allocator, source, .{});
    }

    pub fn openWithLimits(
        allocator: Allocator,
        source: Source,
        limits: Limits,
    ) errors.Error!Decoder {
        // M2 stub: header parsing lands in M3.
        _ = source.sizeOf() catch return error.Io;
        return .{
            .allocator = allocator,
            .source = source,
            .limits = limits,
        };
    }

    pub fn deinit(self: *Decoder) void {
        _ = self;
    }

    pub fn ifdCount(self: *const Decoder) usize {
        _ = self;
        return 0; // M2 stub
    }
};

test "Decoder type compiles" {
    _ = Decoder;
}
