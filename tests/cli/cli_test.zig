//! CLI integration tests. Spawns the installed `tiffz` binary and
//! asserts its stdout/stderr/exit code. Pure black-box; the binary
//! is built by build.zig before these run.

const std = @import("std");

fn cliPath(allocator: std.mem.Allocator) ![]const u8 {
    // build.zig passes the exact path it installs the CLI to, so a
    // stale binary elsewhere can never satisfy these tests. Use dupe to
    // return a regular []u8 — earlier
    // attempts used `realPathFileAlloc` which returns `[:0]u8`,
    // then implicitly casts to []const u8 — but the debug allocator
    // rejects the free as "Invalid free" because the slice length
    // is short by 1 byte vs the original allocation (the sentinel
    // byte). Sticking to allocator.dupe avoids the mismatch entirely.
    return allocator.dupe(u8, @import("cli_test_options").cli_path);
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

/// The Mecha platform the test binary itself was compiled for. The CLI is
/// built for the same target, so its --about must name this PF.
fn expectedPf() []const u8 {
    const t = @import("builtin").target;
    const os = switch (t.os.tag) {
        .linux => "linux",
        .macos => "macos",
        .windows => "mswin",
        else => @compileError("unsupported test target OS"),
    };
    const arch = switch (t.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        else => @compileError("unsupported test target architecture"),
    };
    return os ++ "-" ++ arch;
}

test "tiffz --about is one line naming PF and, on Linux, the libc VARIANT" {
    const r = try runCli(&.{"--about"});
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 0), exitedCode(r.term));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, r.stdout, "\n"));
    try std.testing.expect(std.mem.endsWith(u8, r.stdout, "\n"));
    const line = r.stdout[0 .. r.stdout.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, line, "PF=" ++ comptime expectedPf()) != null);

    const t = @import("builtin").target;
    if (t.os.tag == .linux) {
        const variant = if (t.abi.isMusl()) "VARIANT=musl" else "VARIANT=gnu";
        try std.testing.expect(std.mem.indexOf(u8, line, variant) != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, line, "VARIANT=") == null);
    }
    // The retired OS/ARCH spelling must not linger beside PF.
    try std.testing.expect(std.mem.indexOf(u8, line, "x86_64") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "aarch64") == null);
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
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "resource limit") != null);
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

fn writeOverWidePage(path: []const u8) !void {
    const io = std.testing.io;
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [87]u8 = @splat(0);
    buf[0] = 'I';
    buf[1] = 'I';
    std.mem.writeInt(u16, buf[2..4], 42, .little);
    std.mem.writeInt(u32, buf[4..8], 8, .little);
    std.mem.writeInt(u16, buf[8..10], 6, .little);
    const entries = [_]struct { tag: u16, typ: u16, val: u32 }{
        .{ .tag = 256, .typ = 4, .val = (1 << 30) + 1 },
        .{ .tag = 257, .typ = 3, .val = 1 },
        .{ .tag = 258, .typ = 3, .val = 8 },
        .{ .tag = 259, .typ = 3, .val = 1 },
        .{ .tag = 273, .typ = 4, .val = 86 },
        .{ .tag = 279, .typ = 4, .val = 1 },
    };
    for (entries, 0..) |entry, i| {
        const at = 10 + i * 12;
        std.mem.writeInt(u16, buf[at..][0..2], entry.tag, .little);
        std.mem.writeInt(u16, buf[at + 2 ..][0..2], entry.typ, .little);
        std.mem.writeInt(u32, buf[at + 4 ..][0..4], 1, .little);
        std.mem.writeInt(u32, buf[at + 8 ..][0..4], entry.val, .little);
    }
    buf[86] = 0x5A;
    try file.writeStreamingAll(io, &buf);
}

test "tiffz validate: a dimension cap is limited, not a corruption finding" {
    const allocator = std.testing.allocator;
    const path = "zig-out/cli-test-overwide.tif";
    try writeOverWidePage(path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const r = try runCli(&.{ "validate", path });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 4), exitedCode(r.term));
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "limited") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "LimitExceededDimension") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "invalid") == null);

    const j = try runCli(&.{ "validate", "--json", path });
    defer allocator.free(j.stdout);
    defer allocator.free(j.stderr);
    try std.testing.expectEqual(@as(?u8, 4), exitedCode(j.term));
    try std.testing.expect(std.mem.indexOf(u8, j.stdout, "\"status\":\"limited\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j.stdout, "\"error\":15") != null);
    try std.testing.expect(std.mem.indexOf(u8, j.stdout, "\"limit_offset\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, j.stdout, "\"limit_ifd\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, j.stdout, "\"limit_bytes\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, j.stdout, "invalid") == null);
    try std.testing.expect(std.mem.indexOf(u8, j.stdout, "discrepancy") == null);
}

fn writeShortGrayPage(path: []const u8) !void {
    // 2×2 gray page, one stored byte. Four declared pixels, so validate is
    // Malformed (status 2), not a dimension cap.
    const io = std.testing.io;
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [87]u8 = @splat(0);
    buf[0] = 'I';
    buf[1] = 'I';
    std.mem.writeInt(u16, buf[2..4], 42, .little);
    std.mem.writeInt(u32, buf[4..8], 8, .little);
    std.mem.writeInt(u16, buf[8..10], 6, .little);
    const entries = [_]struct { tag: u16, typ: u16, val: u32 }{
        .{ .tag = 256, .typ = 3, .val = 2 },
        .{ .tag = 257, .typ = 3, .val = 2 },
        .{ .tag = 258, .typ = 3, .val = 8 },
        .{ .tag = 259, .typ = 3, .val = 1 },
        .{ .tag = 273, .typ = 4, .val = 86 },
        .{ .tag = 279, .typ = 4, .val = 1 },
    };
    for (entries, 0..) |entry, i| {
        const at = 10 + i * 12;
        std.mem.writeInt(u16, buf[at..][0..2], entry.tag, .little);
        std.mem.writeInt(u16, buf[at + 2 ..][0..2], entry.typ, .little);
        std.mem.writeInt(u32, buf[at + 4 ..][0..4], 1, .little);
        std.mem.writeInt(u32, buf[at + 8 ..][0..4], entry.val, .little);
    }
    buf[86] = 0x5A;
    try file.writeStreamingAll(io, &buf);
}

test "tiffz validate: a short strip is invalid status 2, not a resource limit" {
    const allocator = std.testing.allocator;
    const path = "zig-out/cli-test-short.tif";
    try writeShortGrayPage(path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};

    const r = try runCli(&.{ "validate", path });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 1), exitedCode(r.term));
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "invalid") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "Malformed") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "limited") == null);

    const j = try runCli(&.{ "validate", "--json", path });
    defer allocator.free(j.stdout);
    defer allocator.free(j.stderr);
    try std.testing.expectEqual(@as(?u8, 1), exitedCode(j.term));
    try std.testing.expect(std.mem.indexOf(u8, j.stdout, "\"status\":\"invalid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j.stdout, "\"error\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, j.stdout, "limited") == null);
    try std.testing.expect(std.mem.indexOf(u8, j.stdout, "limit_offset") == null);
    try std.testing.expect(std.mem.indexOf(u8, j.stdout, "\"discrepancy\":{\"class\":\"error\",\"type\":\"Malformed\",\"offset\":86}") != null);
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

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, at, needle)) |i| : (at = i + needle.len) n += 1;
    return n;
}

test "tiffz validate rejects the Canon 40D CR2 for its IFD0 BitsPerSample count" {
    // IFD0 gives BitsPerSample three values but omits SamplesPerPixel
    // (default 1): N = SamplesPerPixel, TIFF 6.0 p. 29. Corrupt per validate
    // (2026-11-04), pending its known-defect review of the Canon pattern.
    const r = try runCli(&.{ "validate", "--json", good_cr2 });
    defer std.testing.allocator.free(r.stdout);
    defer std.testing.allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 1), exitedCode(r.term));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(r.stdout, "\"code\":18,"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(r.stdout, "\"code\":17,"));
    // IFD 0, entry 2, entry offset 42, tag 258, reason 2 (count), type 3, count 3.
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "\"payload_hex\":\"00000000" ++ "02000000" ++ "2a00000000000000" ++ "0201" ++ "0200" ++ "0300" ++ "0300000000000000") != null);
    // Partial coverage is still named: two code-16 skips.
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(r.stdout, "\"code\":16,"));
}

/// `withSamplesPerPixelInIfd0` in tests/fixture_test.zig, duplicated because
/// this test module cannot import outside tests/cli: IFD0 rebuilt at the end
/// of a copy with SamplesPerPixel `spp` inserted in tag order.
fn withSamplesPerPixelInIfd0(allocator: std.mem.Allocator, bytes: []const u8, spp: u16) ![]u8 {
    std.debug.assert(bytes[0] == 'I' and bytes[1] == 'I');
    const ifd: usize = std.mem.readInt(u32, bytes[4..8], .little);
    const n: usize = std.mem.readInt(u16, bytes[ifd..][0..2], .little);
    const pad = bytes.len % 2;
    const at = bytes.len + pad;
    const out = try allocator.alloc(u8, at + 2 + (n + 1) * 12 + 4);
    @memcpy(out[0..bytes.len], bytes);
    if (pad == 1) out[bytes.len] = 0;
    std.mem.writeInt(u16, out[at..][0..2], @intCast(n + 1), .little);
    var placed = false;
    var w: usize = at + 2;
    for (0..n) |i| {
        const entry = bytes[ifd + 2 + 12 * i ..][0..12];
        const tag = std.mem.readInt(u16, entry[0..2], .little);
        std.debug.assert(tag != 277);
        if (!placed and tag > 277) {
            std.mem.writeInt(u16, out[w..][0..2], 277, .little);
            std.mem.writeInt(u16, out[w + 2 ..][0..2], 3, .little);
            std.mem.writeInt(u32, out[w + 4 ..][0..4], 1, .little);
            std.mem.writeInt(u32, out[w + 8 ..][0..4], spp, .little);
            w += 12;
            placed = true;
        }
        @memcpy(out[w..][0..12], entry);
        w += 12;
    }
    std.debug.assert(placed);
    @memcpy(out[w..][0..4], bytes[ifd + 2 + 12 * n ..][0..4]);
    std.mem.writeInt(u32, out[4..8], @intCast(at), .little);
    return out;
}

test "tiffz validate accepts CR2 partial coverage with exit 0 once IFD0 is consistent" {
    // The control for the test above: the same 40D with SamplesPerPixel 3
    // added to IFD0 at test time (no fixture bytes committed). It must pass
    // for the right reason: partial coverage, no directory-rule finding.
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const original = blk: {
        const file = try std.Io.Dir.cwd().openFile(io, good_cr2, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        const buf = try allocator.alloc(u8, @intCast(stat.size));
        errdefer allocator.free(buf);
        var read_buf: [4096]u8 = undefined;
        var reader = file.reader(io, &read_buf);
        try reader.interface.readSliceAll(buf);
        break :blk buf;
    };
    defer allocator.free(original);
    const repaired = try withSamplesPerPixelInIfd0(allocator, original, 3);
    defer allocator.free(repaired);

    const path = "zig-out/cli-test-cr2-spp3.cr2";
    {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, repaired);
    }
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const r = try runCli(&.{ "validate", "--json", path });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);

    try std.testing.expectEqual(@as(?u8, 0), exitedCode(r.term));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(r.stdout, "\"code\":18,"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(r.stdout, "\"code\":17,"));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(r.stdout, "\"code\":16,"));
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

// What tiffz does not implement is reach, never corruption (validate
// TERMINOLOGY.md, 2026-11-05): exit 4 and "unsupported". A corrupt record
// outranks the refusal. The fixtures are from tests/fixtures/predictor/gen.pl.
test "tiffz validate: an unimplemented feature is unsupported (reach), not invalid" {
    const allocator = std.testing.allocator;
    // Gray 32-bit with Predictor 2: TIFF 6.0 defines it and libtiff decodes
    // it; tiffz's horizontal predictor handles 8 and 16 bits only.
    const path = "tests/fixtures/predictor/predictor2_deflate_bps32.tif";
    const r = try runCli(&.{ "validate", path });
    defer allocator.free(r.stdout);
    defer allocator.free(r.stderr);
    try std.testing.expectEqual(@as(?u8, 4), exitedCode(r.term));
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "unsupported") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "UnsupportedBitDepth") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "invalid") == null);

    const j = try runCli(&.{ "validate", "--json", path });
    defer allocator.free(j.stdout);
    defer allocator.free(j.stderr);
    try std.testing.expectEqual(@as(?u8, 4), exitedCode(j.term));
    try std.testing.expect(std.mem.indexOf(u8, j.stdout, "\"status\":\"unsupported\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j.stdout, "\"error\":6") != null);
    try std.testing.expect(std.mem.indexOf(u8, j.stdout, "\"verdict\":1") == null);
}

test "tiffz validate: a corrupt record outranks an unsupported refusal" {
    const allocator = std.testing.allocator;
    // 12-bit Predictor 3: the decoder refuses the width (UnsupportedBitDepth),
    // and finding 18 on Predictor says the file is at fault.
    const path = "tests/fixtures/predictor/predictor3_deflate_bps12.tif";
    const j = try runCli(&.{ "validate", "--json", path });
    defer allocator.free(j.stdout);
    defer allocator.free(j.stderr);
    try std.testing.expectEqual(@as(?u8, 1), exitedCode(j.term));
    try std.testing.expect(std.mem.indexOf(u8, j.stdout, "\"status\":\"invalid\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j.stdout, "\"code\":18,\"verdict\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, j.stdout, "unsupported") == null);
}
