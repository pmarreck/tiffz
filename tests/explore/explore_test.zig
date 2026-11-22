//! In-process corruption exploration (owner, 2026-11-05: corruption_reader is
//! a library, and a good corpus is an unlimited, reproducible bad corpus with
//! nothing written to disk). The driver is driver.zig.
//!
//! The parity test replays the pinned floors plan
//! (tests/corruption_coverage_floors) and must reproduce its detected case
//! set exactly: the floors were written by the subprocess harness, so they are
//! an oracle independent of this driver. Exploring any master and profile is
//! the `tiffz-explore` executable (main.zig; `nix run .#explore`).
//!
//! Run with `zig build explore -Dcorruption-reader-src=DIR` (the flake passes
//! its corruption-reader input). Not part of plain `zig build`: the reader is
//! not a public package (docs/plan_context/in-process-exploration.md).

const std = @import("std");
const driver = @import("driver.zig");

const Key = driver.Key;
const Outcome = driver.Outcome;
const Seed = driver.Seed;
const classify = driver.classify;
const parseMaster = driver.parseMaster;

test "master seeds parse as corruption-reader parses them: big-endian, decimal or 0x hex" {
    var want = [_]u8{0} ** 32;
    want[31] = 42;
    try std.testing.expectEqualSlices(u8, &want, &(try parseMaster("42")));
    try std.testing.expectEqualSlices(u8, &want, &(try parseMaster("0x2a")));
    want[30] = 0x01;
    want[31] = 0x00;
    try std.testing.expectEqualSlices(u8, &want, &(try parseMaster("256")));
    try std.testing.expectError(error.InvalidMasterSeed, parseMaster("0x"));
    try std.testing.expectError(error.InvalidMasterSeed, parseMaster("12a"));
}

test "classification follows corruption-coverage: exit 1 detects, exit 4 is reach, exit 0 compares with the seed" {
    var seed_codes = [_]i32{ 2, 9 };
    const seed: Key = .{ .codes = &seed_codes, .has16 = false };
    var same = [_]i32{ 2, 9 };
    var other = [_]i32{ 2, 9, 18 };
    try std.testing.expectEqual(Outcome.detect, classify(.{ .exit = 1, .key = seed }, seed));
    try std.testing.expectEqual(Outcome.reach, classify(.{ .exit = 4, .key = seed }, seed));
    try std.testing.expectEqual(Outcome.accept, classify(.{ .exit = 0, .key = .{ .codes = &same, .has16 = false } }, seed));
    try std.testing.expectEqual(Outcome.detect, classify(.{ .exit = 0, .key = .{ .codes = &other, .has16 = false } }, seed));
    try std.testing.expectEqual(Outcome.reach, classify(.{ .exit = 0, .key = .{ .codes = &same, .has16 = true } }, seed));
}

test "parity: the pinned floors plan replayed in-process detects exactly the pinned cases" {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const keep = arena_state.allocator();
    const floors = try driver.parseFloors(keep, try driver.loadFile(std.testing.io, keep, driver.floors_path));
    const master = try parseMaster(floors.master);

    var seeds = try keep.alloc(Seed, floors.seeds.items.len);
    for (floors.seeds.items, 0..) |path, i| seeds[i] = try driver.loadSeed(std.testing.io, keep, path);

    var lost: usize = 0;
    var new: usize = 0;
    var found: usize = 0;
    var case_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer case_arena.deinit();
    for (floors.plans.items) |plan| {
        var loader: driver.cr.profiles.Loader = .{ .arena = keep };
        const profile = try loader.load(driver.readerProfile(plan.profile));
        var k: u64 = 0;
        while (k < plan.batches) : (k += 1) {
            const seed = &seeds[@intCast(k % seeds.len)];
            var i: u64 = 0;
            while (i < plan.per) : (i += 1) {
                const round = k * plan.per + i;
                _ = case_arena.reset(.retain_capacity);
                const outcome = (try driver.runCase(case_arena.allocator(), std.testing.allocator, profile, seed, master, round)).outcome;
                const id = try driver.caseId(case_arena.allocator(), plan.profile, seed.path, round);
                const pinned = floors.detects.contains(id);
                if (outcome == .detect) found += 1;
                if (pinned and outcome != .detect) {
                    lost += 1;
                    std.debug.print("case lost {s} ({s})\n", .{ id, @tagName(outcome) });
                } else if (!pinned and outcome == .detect) {
                    new += 1;
                    std.debug.print("case new {s}\n", .{id});
                }
            }
        }
    }
    if (lost != 0 or new != 0 or found != floors.detects.count()) {
        std.debug.print("parity: {d} detected in-process, {d} pinned, {d} lost, {d} new\n", .{ found, floors.detects.count(), lost, new });
    }
    try std.testing.expectEqual(@as(usize, 0), lost);
    try std.testing.expectEqual(@as(usize, 0), new);
    try std.testing.expectEqual(floors.detects.count(), found);
}


test "tiffz-explore arguments: --master required, harness defaults, bad values are usage errors" {
    const a = try driver.parseArgs(&.{ "--master", "0x2a" });
    try std.testing.expectEqualStrings("0x2a", a.master);
    try std.testing.expectEqualStrings("shotgun", a.profile);
    try std.testing.expectEqual(@as(u64, 0), a.first_round);
    try std.testing.expectEqual(@as(u64, 385), a.rounds);
    try std.testing.expectEqualStrings(driver.floors_path, a.floors);
    const b = try driver.parseArgs(&.{ "--profile", "nuke", "--rounds", "7", "--first-round", "100", "--master", "9", "--floors", "f" });
    try std.testing.expectEqualStrings("nuke", b.profile);
    try std.testing.expectEqual(@as(u64, 7), b.rounds);
    try std.testing.expectEqual(@as(u64, 100), b.first_round);
    try std.testing.expectEqualStrings("f", b.floors);
    try std.testing.expectError(error.Help, driver.parseArgs(&.{"--help"}));
    try std.testing.expectError(error.Usage, driver.parseArgs(&.{}));
    try std.testing.expectError(error.Usage, driver.parseArgs(&.{"--master"}));
    try std.testing.expectError(error.Usage, driver.parseArgs(&.{ "--master", "12a" }));
    try std.testing.expectError(error.Usage, driver.parseArgs(&.{ "--master", "1", "--rounds", "x" }));
    try std.testing.expectError(error.Usage, driver.parseArgs(&.{ "--master", "1", "--bogus", "2" }));
    try std.testing.expectError(error.Usage, driver.parseArgs(&.{ "--master", "1", "--first-round", "18446744073709551615", "--rounds", "1" }));
}

test "seed layouts parse from corruption-coverage --layouts-out, and malformed lines are refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const map = try driver.parseLayouts(a, "seed\tx.tif\t100\tuncompressed\nfree\tx.tif\t8\t40\nfree\tx.tif\t60\t70\nseed\ty.tif\t50\tchecksummed\n");
    const x = map.get("x.tif").?;
    try std.testing.expectEqual(@as(u64, 100), x.bytes);
    try std.testing.expectEqualStrings("uncompressed", x.class);
    try std.testing.expectEqualSlices([2]u64, &.{ .{ 8, 40 }, .{ 60, 70 } }, x.free.items);
    try std.testing.expectEqual(@as(usize, 0), map.get("y.tif").?.free.items.len);
    try std.testing.expectError(error.BadLayouts, driver.parseLayouts(a, "free\tx.tif\t8\t40\n"));
    try std.testing.expectError(error.BadLayouts, driver.parseLayouts(a, "seed\tx.tif\t100\tuncompressed\nseed\tx.tif\t100\tuncompressed\n"));
    try std.testing.expectError(error.BadLayouts, driver.parseLayouts(a, "seed\tx.tif\t100\tuncompressed\nfree\tx.tif\t40\t8\n"));
    try std.testing.expectError(error.BadLayouts, driver.parseLayouts(a, "seed\tx.tif\tten\tuncompressed\n"));
    try std.testing.expectError(error.BadLayouts, driver.parseLayouts(a, "range\tx.tif\t1\t2\n"));
}

test "bound follows corruption-coverage: free only when every changed byte is an uncompressed sample" {
    var layout: driver.Layout = .{ .bytes = 8, .class = "uncompressed" };
    var ranges = [_][2]u64{ .{ 2, 4 }, .{ 6, 8 } };
    layout.free = .{ .items = &ranges, .capacity = ranges.len };
    const seed = "ABCDEFGH";
    try std.testing.expectEqual(driver.Bound.free, driver.bound(&layout, seed, "ABxDEFyH"));
    try std.testing.expectEqual(driver.Bound.free, driver.bound(&layout, seed, "ABCxEFGy"));
    // A changed byte just outside a range (offset 4, 5 or 1) is open.
    try std.testing.expectEqual(driver.Bound.open, driver.bound(&layout, seed, "ABCDxFGH"));
    try std.testing.expectEqual(driver.Bound.open, driver.bound(&layout, seed, "AxCDEFGH"));
    try std.testing.expectEqual(driver.Bound.open, driver.bound(&layout, seed, "ABxDExGH"));
    // A length change is open; no layout is unknown.
    try std.testing.expectEqual(driver.Bound.open, driver.bound(&layout, seed, "ABCDEFG"));
    try std.testing.expectEqual(driver.Bound.unknown, driver.bound(null, seed, "ABxDEFGH"));
    // No changed byte at all is free, as an empty `cmp -l` is in the harness.
    try std.testing.expectEqual(driver.Bound.free, driver.bound(&layout, seed, seed));
}

test "tiffz-explore arguments: --replay-floors takes no master, --layouts takes a path" {
    const r = try driver.parseArgs(&.{ "--replay-floors", "--layouts", "l" });
    try std.testing.expect(r.replay_floors);
    try std.testing.expectEqualStrings("l", r.layouts.?);
    try std.testing.expectError(error.Usage, driver.parseArgs(&.{ "--replay-floors", "--master", "1" }));
    try std.testing.expectError(error.Usage, driver.parseArgs(&.{ "--master", "1", "--layouts" }));
}
