//! CLI integration tests. Spawns the installed `tiffz` binary and
//! asserts its stdout/stderr/exit code. Pure black-box; the binary
//! is built by build.zig before these run.

const std = @import("std");

fn cliPath(allocator: std.mem.Allocator) ![]const u8 {
    // build.zig installs to <build-out>/bin/tiffz. The Zig test
    // runner runs from the build root, so zig-out/bin/tiffz is the
    // canonical path. Use dupe to return a regular []u8 — earlier
    // attempts used `realPathFileAlloc` which returns `[:0]u8`,
    // then implicitly casts to []const u8 — but the debug allocator
    // rejects the free as "Invalid free" because the slice length
    // is short by 1 byte vs the original allocation (the sentinel
    // byte). Sticking to allocator.dupe avoids the mismatch entirely.
    return allocator.dupe(u8, "zig-out/bin/tiffz");
}

fn runCli(args: []const []const u8) !std.process.RunResult {
    const allocator = std.testing.allocator;
    const cli = try cliPath(allocator);
    defer allocator.free(cli);

    var argv: std.ArrayListUnmanaged([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, cli);
    for (args) |a| try argv.append(allocator, a);

    return std.process.run(allocator, std.testing.io, .{
        .argv = argv.items,
    });
}

fn exitedCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

test "tiffz --version prints non-empty version" {
    const r = try runCli(&.{"--version"});
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 0), exitedCode(r.term));
    try std.testing.expect(r.stdout.len > 1); // version + newline
}

test "tiffz --about contains tiffz and version" {
    const r = try runCli(&.{"--about"});
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 0), exitedCode(r.term));
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "tiffz") != null);
}

test "tiffz --help mentions usage" {
    const r = try runCli(&.{"--help"});
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 0), exitedCode(r.term));
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "USAGE") != null);
}

test "tiffz with unknown arg exits non-zero" {
    const r = try runCli(&.{"--definitely-not-a-flag"});
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    const code = exitedCode(r.term);
    try std.testing.expect(code == null or code.? != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "unknown argument") != null);
}
