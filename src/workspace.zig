//! Per-call codec scratch holder. Single-threaded — never share a
//! Workspace across threads. Reuse one Workspace across many strips
//! on a single thread to avoid per-strip allocations.
//!
//! M2: skeleton. Real allocations (LZW dictionary, JPEG state,
//! decompression intermediates) populate as compression schemes land
//! in M4+.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Workspace = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) Workspace {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Workspace) void {
        _ = self;
    }

    /// Free transient scratch but keep the structure for reuse on
    /// the next decode call. M2 stub.
    pub fn reset(self: *Workspace) void {
        _ = self;
    }
};

test "Workspace init/deinit roundtrip" {
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();
    ws.reset();
}
