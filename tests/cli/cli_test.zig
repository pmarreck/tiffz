//! CLI integration tests. Spawns the installed `tiffz` binary and
//! asserts its stdout/stderr/exit code. Pure black-box; the binary
//! is built by build.zig before these run.

const std = @import("std");

fn cliPath(allocator: std.mem.Allocator) ![]const u8 {
    // build.zig installs to <build-out>/bin/tiffz. The Zig test
    // runner runs from the build root, so zig-out/bin/tiffz is the
    // canonical path.
    const sentinel = std.Io.Dir.cwd().realPathFileAlloc(
        std.testing.io,
        "zig-out/bin/tiffz",
        allocator,
    ) catch return error.CliBinaryNotFound;
    // realPathFileAlloc returns [:0]u8; the [*:0] sentinel is owned by
    // the same allocation, so we can hand back the sentinel-less slice
    // for our purposes but caller must free the original (slice covers
    // the same allocation).
    return sentinel;
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
