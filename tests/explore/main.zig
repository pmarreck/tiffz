//! `tiffz-explore`: in-process corruption exploration under any master and
//! profile, over the seeds a floors file lists (driver.zig; `nix run
//! .#explore -- --master SEED` from the repository root). Built only with
//! `-Dcorruption-reader-src=DIR`, since the reader is not a public package.

const std = @import("std");
const driver = @import("driver.zig");

const Tally = struct { decisive: u64 = 0, detect: u64 = 0, free: u64 = 0, false_alarm: u64 = 0 };

/// Runs one case and prints its line. The line's prefix is flushed before
/// the case runs, so after a crash the last line names it.
fn runOne(out: *std.Io.Writer, arena: *std.heap.ArenaAllocator, gpa: std.mem.Allocator, profile_name: []const u8, profile: driver.cr.profiles.Profile, seed: *const driver.Seed, master: [32]u8, round: u64) !driver.Result {
    try out.print("case\t{s}\t{s}\t{d}\t", .{ profile_name, seed.path, round });
    try out.flush();
    _ = arena.reset(.retain_capacity);
    const r = try driver.runCase(arena.allocator(), gpa, profile, seed, master, round);
    try out.print("{s}\t{s}\n", .{ @tagName(r.outcome), @tagName(r.bound) });
    return r;
}

fn tally(t: *Tally, r: driver.Result) void {
    if (r.outcome != .detect and r.outcome != .accept) return;
    t.decisive += 1;
    if (r.outcome == .detect) t.detect += 1;
    if (r.bound == .free) t.free += 1;
    if (r.outcome == .detect and r.bound == .free) t.false_alarm += 1;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const keep = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(keep);
    var err_buf: [256]u8 = undefined;
    var err_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
    const stderr = &err_writer.interface;

    const args = driver.parseArgs(argv[1..]) catch |err| {
        const help = err == error.Help;
        if (!help) try stderr.writeAll("tiffz-explore: bad arguments\n");
        try stderr.writeAll(driver.usage);
        try stderr.flush();
        return if (help) 0 else 2;
    };

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &out_writer.interface;

    const floors = try driver.parseFloors(keep, try driver.loadFile(io, keep, args.floors));
    const seeds = try keep.alloc(driver.Seed, floors.seeds.items.len);
    for (floors.seeds.items, 0..) |path, i| seeds[i] = try driver.loadSeed(io, keep, path);
    if (args.layouts) |path| {
        const layouts = try driver.parseLayouts(keep, try driver.loadFile(io, keep, path));
        for (seeds) |*seed| seed.layout = layouts.getPtr(seed.path);
    }

    var loader: driver.cr.profiles.Loader = .{ .arena = keep };
    var case_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer case_arena.deinit();
    var false_alarms: u64 = 0;

    if (args.replay_floors) {
        // The floors plan, as the parity test replays it.
        const master = try driver.parseMaster(floors.master);
        const classes = [_][]const u8{ "uncompressed", "unchecked", "checksummed", "unknown" };
        const Row = struct { profile: []const u8, by_class: [classes.len]Tally };
        var rows: std.ArrayListUnmanaged(Row) = .empty;
        for (floors.plans.items) |plan| {
            const profile = try loader.load(driver.readerProfile(plan.profile));
            var row: Row = .{ .profile = plan.profile, .by_class = @splat(Tally{}) };
            var k: u64 = 0;
            while (k < plan.batches) : (k += 1) {
                const seed = &seeds[@intCast(k % seeds.len)];
                const class = if (seed.layout) |l| l.class else "unknown";
                const c = for (classes, 0..) |name, j| {
                    if (std.mem.eql(u8, name, class)) break j;
                } else classes.len - 1;
                var i: u64 = 0;
                while (i < plan.per) : (i += 1) {
                    const r = try runOne(out, &case_arena, init.gpa, plan.profile, profile, seed, master, k * plan.per + i);
                    tally(&row.by_class[c], r);
                }
            }
            try rows.append(keep, row);
        }
        for (rows.items) |row| {
            for (classes, row.by_class) |name, t| {
                if (t.decisive == 0) continue;
                try out.print("class {s} {s} decisive={d} detect={d} free={d} false_alarm={d}\n", .{ row.profile, name, t.decisive, t.detect, t.free, t.false_alarm });
                false_alarms += t.false_alarm;
            }
        }
    } else {
        const master = try driver.parseMaster(args.master);
        const profile = loader.load(driver.readerProfile(args.profile)) catch |err| {
            try stderr.print("tiffz-explore: profile {s}: {s}\n", .{ args.profile, @errorName(err) });
            try stderr.flush();
            return 2;
        };
        var counts = std.EnumArray(driver.Outcome, u64).initFill(0);
        var t: Tally = .{};
        var round = args.first_round;
        while (round < args.first_round + args.rounds) : (round += 1) {
            const seed = &seeds[@intCast(round % seeds.len)];
            const r = try runOne(out, &case_arena, init.gpa, args.profile, profile, seed, master, round);
            counts.getPtr(r.outcome).* += 1;
            tally(&t, r);
        }
        false_alarms = t.false_alarm;
        try out.print("explore {s} master {s} rounds {d}-{d}: detect {d} accept {d} reach {d} noop {d} free {d} false_alarm {d}\n", .{
            args.profile,
            args.master,
            args.first_round,
            args.first_round + args.rounds -| 1,
            counts.get(.detect),
            counts.get(.accept),
            counts.get(.reach),
            counts.get(.noop),
            t.free,
            t.false_alarm,
        });
    }
    try out.flush();
    if (false_alarms != 0) {
        try stderr.print("tiffz-explore: {d} false alarm(s): tiffz rejected a case whose every changed byte is an uncompressed sample\n", .{false_alarms});
        try stderr.flush();
        return 1;
    }
    return 0;
}
