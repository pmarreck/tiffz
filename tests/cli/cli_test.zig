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

test "tiffz --help mentions validate" {
    const r = try runCli(&.{"--help"});
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 0), exitedCode(r.term));
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "validate") != null);
}

const good_rgb = "tests/fixtures/uncompressed/rgb-3c-8b.tiff";
const good_cr2 = "tests/fixtures/cr2/canon_eos_40d_sraw2.cr2";

test "tiffz validate accepts a clean RGB TIFF with exit 0" {
    const r = try runCli(&.{ "validate", good_rgb });
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 0), exitedCode(r.term));
}

test "tiffz FILE without a verb validates" {
    const r = try runCli(&.{good_rgb});
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 0), exitedCode(r.term));
}

test "tiffz validate rejects a truncated header with exit 1" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir = std.Io.Dir.cwd();
    const path = "zig-out/cli-test-truncated.tif";
    {
        const file = try dir.createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "II*\x00\x08\x00\x00\x00");
    }
    defer dir.deleteFile(io, path) catch {};

    const r = try runCli(&.{ "validate", path });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 1), exitedCode(r.term));
}

test "tiffz validate missing file exits 3" {
    const r = try runCli(&.{ "validate", "tests/fixtures/does-not-exist.tif" });
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 3), exitedCode(r.term));
}

test "tiffz validate without a file exits 2" {
    const r = try runCli(&.{"validate"});
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 2), exitedCode(r.term));
}

test "tiffz validate --json writes a JSON object to stdout" {
    const r = try runCli(&.{ "validate", "--json", good_rgb });
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 0), exitedCode(r.term));
    try std.testing.expect(r.stdout.len > 0);
    try std.testing.expect(r.stdout[0] == '{');
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "\"status\"") != null);
}

test "tiffz validate accepts CR2 partial coverage with exit 0" {
    const r = try runCli(&.{ "validate", good_cr2 });
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 0), exitedCode(r.term));
}

test "tiffz --help mentions dump" {
    const r = try runCli(&.{"--help"});
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 0), exitedCode(r.term));
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "dump") != null);
}

test "tiffz dump writes a PNG with the PNG signature" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir = std.Io.Dir.cwd();
    const out_path = "zig-out/cli-test-dump.png";
    defer dir.deleteFile(io, out_path) catch {};

    const r = try runCli(&.{ "dump", good_rgb, "-o", out_path });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 0), exitedCode(r.term));

    const file = try dir.openFile(io, out_path, .{});
    defer file.close(io);
    var buf: [8]u8 = undefined;
    var read_buf: [8]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    try reader.interface.readSliceAll(&buf);
    const png_sig = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };
    try std.testing.expectEqualSlices(u8, &png_sig, &buf);
}

test "tiffz dump without -o writes PNG to stdout" {
    const r = try runCli(&.{ "dump", good_rgb });
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 0), exitedCode(r.term));
    try std.testing.expect(r.stdout.len >= 8);
    const png_sig = [_]u8{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a };
    try std.testing.expectEqualSlices(u8, &png_sig, r.stdout[0..8]);
}

test "tiffz validate accepts a path with spaces" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const dir = std.Io.Dir.cwd();
    const dest = "zig-out/cli test dir/spaced.tiff";
    defer dir.deleteTree(io, "zig-out/cli test dir") catch {};
    try dir.copyFile(good_rgb, dir, dest, io, .{ .make_path = true });

    const r = try runCli(&.{ "validate", dest });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 0), exitedCode(r.term));
}

test "tiffz with unknown arg exits non-zero" {
    const r = try runCli(&.{"--definitely-not-a-flag"});
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    const code = exitedCode(r.term);
    try std.testing.expect(code == null or code.? != 0);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "unknown argument") != null);
}
