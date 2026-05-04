//! CLI integration tests. Spawns the installed `tiffz` binary and
//! asserts its stdout/stderr/exit code. Pure black-box; the binary
//! is built by build.zig before these run.

const std = @import("std");

fn cliPath(allocator: std.mem.Allocator) ![]const u8 {
    // build.zig installs to <build-out>/bin/tiffz. The Zig test
    // runner runs from the build root, so zig-out/bin/tiffz is the
    // canonical path.
    return std.fs.cwd().realpathAlloc(allocator, "zig-out/bin/tiffz") catch
        error.CliBinaryNotFound;
}

fn runCli(args: []const []const u8) !std.process.Child.RunResult {
    const allocator = std.testing.allocator;
    const cli = try cliPath(allocator);
    defer allocator.free(cli);

    var argv = std.ArrayListUnmanaged([]const u8){};
    defer argv.deinit(allocator);
    try argv.append(allocator, cli);
    for (args) |a| try argv.append(allocator, a);

    return std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
    });
}

test "tiffz --version prints non-empty version" {
    const r = try runCli(&.{"--version"});
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    try std.testing.expectEqual(@as(u8, 0), r.term.Exited);
    try std.testing.expect(r.stdout.len > 1); // version + newline
}

test "tiffz --about contains tiffz and version" {
    const r = try runCli(&.{"--about"});
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    try std.testing.expectEqual(@as(u8, 0), r.term.Exited);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "tiffz") != null);
}

test "tiffz --help mentions usage" {
    const r = try runCli(&.{"--help"});
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    try std.testing.expectEqual(@as(u8, 0), r.term.Exited);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "USAGE") != null);
}

test "tiffz with unknown arg exits non-zero" {
    const r = try runCli(&.{"--definitely-not-a-flag"});
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    try std.testing.expect(r.term.Exited != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "unknown argument") != null);
}
