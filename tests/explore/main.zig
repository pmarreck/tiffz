//! `tiffz-explore`: in-process corruption exploration under any master and
//! profile, over the seeds a floors file lists (driver.zig; `nix run
//! .#explore -- --master SEED` from the repository root). Built only with
//! `-Dcorruption-reader-src=DIR`, since the reader is not a public package.

const std = @import("std");
const driver = @import("driver.zig");

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
    const master = try driver.parseMaster(args.master);
    const seeds = try keep.alloc(driver.Seed, floors.seeds.items.len);
    for (floors.seeds.items, 0..) |path, i| seeds[i] = try driver.loadSeed(io, keep, path);

    var loader: driver.cr.profiles.Loader = .{ .arena = keep };
    const profile = loader.load(driver.readerProfile(args.profile)) catch |err| {
        try stderr.print("tiffz-explore: profile {s}: {s}\n", .{ args.profile, @errorName(err) });
        try stderr.flush();
        return 2;
    };

    var counts = std.EnumArray(driver.Outcome, u64).initFill(0);
    var case_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer case_arena.deinit();
    var round = args.first_round;
    while (round < args.first_round + args.rounds) : (round += 1) {
        const seed = &seeds[@intCast(round % seeds.len)];
        // Written before the case runs, so a crash leaves it as the last line.
        try out.print("case\t{s}\t{s}\t{d}\t", .{ args.profile, seed.path, round });
        try out.flush();
        _ = case_arena.reset(.retain_capacity);
        const outcome = try driver.runCase(case_arena.allocator(), init.gpa, profile, seed, master, round);
        try out.print("{s}\n", .{@tagName(outcome)});
        counts.getPtr(outcome).* += 1;
    }
    try out.print("explore {s} master {s} rounds {d}-{d}: detect {d} accept {d} reach {d} noop {d}\n", .{
        args.profile,
        args.master,
        args.first_round,
        args.first_round + args.rounds -| 1,
        counts.get(.detect),
        counts.get(.accept),
        counts.get(.reach),
        counts.get(.noop),
    });
    try out.flush();
    return 0;
}
