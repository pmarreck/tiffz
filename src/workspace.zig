//! Per-call codec scratch holder. Single-threaded — never share a
//! Workspace across threads. Reuse one Workspace across many strips
//! on a single thread to avoid per-strip allocations.
//!
//! Holds a growable byte buffer (`scratch`) used by compressed
//! decoders to stage compressed strip bytes before expansion.
//! Capacity grows monotonically — repeated strips on one thread reuse
//! the same allocation.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Workspace = struct {
    allocator: Allocator,
    scratch: []u8,
    /// Secondary scratch, used by codecs that need two live buffers at
    /// once — e.g. LERC-with-Deflate/Zstd post-filter, where scratch
    /// holds the compressed strip bytes read from Source and scratch2
    /// holds the inner LERC blob after post-filter removal.
    scratch2: []u8,

    pub fn init(allocator: Allocator) Workspace {
        return .{
            .allocator = allocator,
            .scratch = &.{},
            .scratch2 = &.{},
        };
    }

    pub fn deinit(self: *Workspace) void {
        if (self.scratch.len > 0) self.allocator.free(self.scratch);
        if (self.scratch2.len > 0) self.allocator.free(self.scratch2);
        self.scratch = &.{};
        self.scratch2 = &.{};
    }

    /// Ensure scratch is at least `min_bytes` long. Returns a slice
    /// of exactly `min_bytes` (the prefix of self.scratch). Grows the
    /// underlying buffer as needed; never shrinks.
    pub fn ensureScratch(self: *Workspace, min_bytes: usize) error{OutOfMemory}![]u8 {
        if (self.scratch.len < min_bytes) {
            const new = try self.allocator.alloc(u8, min_bytes);
            if (self.scratch.len > 0) self.allocator.free(self.scratch);
            self.scratch = new;
        }
        return self.scratch[0..min_bytes];
    }

    /// Ensure scratch2 is at least `min_bytes` long. Same semantics as
    /// `ensureScratch` on the secondary buffer.
    pub fn ensureScratch2(self: *Workspace, min_bytes: usize) error{OutOfMemory}![]u8 {
        if (self.scratch2.len < min_bytes) {
            const new = try self.allocator.alloc(u8, min_bytes);
            if (self.scratch2.len > 0) self.allocator.free(self.scratch2);
            self.scratch2 = new;
        }
        return self.scratch2[0..min_bytes];
    }

    /// Reset (logically empty) the scratch — capacity stays for the
    /// next decode. M4-A no-op since `ensureScratch` is the only API.
    pub fn reset(self: *Workspace) void {
        _ = self;
    }
};

test "Workspace.ensureScratch grows monotonically" {
    var ws = Workspace.init(std.testing.allocator);
    defer ws.deinit();

    const a = try ws.ensureScratch(16);
    try std.testing.expectEqual(@as(usize, 16), a.len);

    const b = try ws.ensureScratch(8); // smaller — buffer doesn't shrink
    try std.testing.expectEqual(@as(usize, 8), b.len);
    try std.testing.expect(ws.scratch.len >= 16); // underlying capacity preserved

    const c = try ws.ensureScratch(64); // grow
    try std.testing.expectEqual(@as(usize, 64), c.len);
    try std.testing.expect(ws.scratch.len >= 64);
}
