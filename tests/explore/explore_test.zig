//! In-process corruption exploration (owner, 2026-11-05: corruption_reader is
//! a library, and a good corpus is an unlimited, reproducible bad corpus with
//! nothing written to disk). corruption_reader draws a case from a seed held
//! in memory; tiffz validates the case's positional view through a
//! PlanView-backed tiffz.Source; the outcome is classified exactly as
//! ./corruption-coverage classifies a subprocess run of `tiffz validate`.
//!
//! The parity test replays the pinned floors plan
//! (tests/corruption_coverage_floors) and must reproduce its detected case
//! set exactly: the floors were written by the subprocess harness, so they are
//! an oracle independent of this driver. The explore test runs any master and
//! profile over the floors' seeds when `-Dexplore-master` is given, and prints
//! each case's outcome. A crash ends the process; the case it was on is the
//! last "case" line printed.
//!
//! Run with `zig build explore -Dcorruption-reader-src=DIR` (the flake passes
//! its corruption-reader input). Not part of plain `zig build`: the reader is
//! not a public package (docs/plan_context/in-process-exploration.md).

const std = @import("std");
const tiffz = @import("tiffz");
const cr = @import("corruption_reader");
const options = @import("explore_options");

const floors_path = "tests/corruption_coverage_floors";

pub const Outcome = enum { detect, accept, reach, noop };

/// The findings of one validation, reduced to what the harness compares:
/// every finding code except 16, sorted, and whether 16 appeared.
const Key = struct {
    codes: []i32,
    has16: bool,

    fn eql(a: Key, b: Key) bool {
        return a.has16 == b.has16 and std.mem.eql(i32, a.codes, b.codes);
    }
};

const Recorder = struct {
    allocator: std.mem.Allocator,
    codes: std.ArrayListUnmanaged(i32) = .empty,
    has16: bool = false,
    corrupt: bool = false,
    failed: bool = false,

    fn callback(userdata: ?*anyopaque, source_decoder: i32, code: i32, mapped: i32, verdict: i32, offset: u64, host: u64, flags: u32, payload: ?[*]const u8, len: usize) callconv(.c) void {
        _ = .{ source_decoder, mapped, offset, host, flags, payload, len };
        const self: *Recorder = @ptrCast(@alignCast(userdata.?));
        if (verdict == @intFromEnum(tiffz.findings.Verdict.corrupt)) self.corrupt = true;
        if (code == 16) {
            self.has16 = true;
            return;
        }
        self.codes.append(self.allocator, code) catch {
            self.failed = true;
        };
    }
};

/// What `tiffz validate` would report: its exit status (0, 1 or 4) and key.
const Verdict = struct { exit: u8, key: Key };

/// The CLI's exit status for a failed validation (cli/main.c exit_for_status).
fn exitFor(err: tiffz.Error, corrupt: bool) u8 {
    if ((tiffz.errors.isLimit(err) or tiffz.errors.isUnsupported(err)) and !corrupt) return 4;
    return 1;
}

/// tiffz_open_from_buffer, the finding callback and tiffz_validate, as the
/// CLI calls them (src/ffi.zig), over any Source.
fn validate(allocator: std.mem.Allocator, src: tiffz.Source) !Verdict {
    var rec: Recorder = .{ .allocator = allocator };
    defer rec.codes.deinit(allocator);
    var exit: u8 = 0;
    run: {
        var dec = tiffz.Decoder.open(allocator, src) catch |err| {
            exit = exitFor(err, false);
            break :run;
        };
        defer dec.deinit();
        var ws = tiffz.Workspace.init(allocator);
        defer ws.deinit();
        dec.setFindingCallback(&Recorder.callback, @ptrCast(&rec));
        dec.scanFindings();
        dec.validateAllStripsAndTiles(&ws) catch |err| {
            exit = exitFor(err, rec.corrupt);
        };
    }
    if (rec.failed) return error.OutOfMemory;
    const codes = try allocator.dupe(i32, rec.codes.items);
    std.mem.sort(i32, codes, {}, std.sort.asc(i32));
    return .{ .exit = exit, .key = .{ .codes = codes, .has16 = rec.has16 } };
}

/// corruption-coverage's classify_tiffz, for a case and its unmutated seed.
fn classify(case: Verdict, seed: Key) Outcome {
    return switch (case.exit) {
        1 => .detect,
        4 => .reach,
        else => if (!std.mem.eql(i32, case.key.codes, seed.codes))
            .detect
        else if (case.key.has16 != seed.has16)
            .reach
        else
            .accept,
    };
}

/// A corruption_reader PlanView as a tiffz.Source.
const ViewSource = struct {
    view: cr.PlanView,

    fn readAt(ctx: *anyopaque, buf: []u8, offset: u64) anyerror!usize {
        const self: *ViewSource = @ptrCast(@alignCast(ctx));
        return self.view.readAt(offset, buf);
    }
    fn size(ctx: *anyopaque) anyerror!u64 {
        const self: *ViewSource = @ptrCast(@alignCast(ctx));
        return self.view.length();
    }
    const vtable: tiffz.Source.VTable = .{ .read_at = readAt, .size = size };

    fn source(self: *ViewSource) tiffz.Source {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }
};

const Seed = struct {
    path: []const u8,
    bytes: []const u8,
    key: Key,
};

fn loadSeed(allocator: std.mem.Allocator, path: []const u8) !Seed {
    const bytes = try loadFile(allocator, path);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const v = try validate(allocator, tiffz.Source.fromBuffer(&handle));
    if (v.exit != 0) {
        std.debug.print("seed {s} does not validate (exit {d})\n", .{ path, v.exit });
        return error.SeedRejected;
    }
    return .{ .path = path, .bytes = bytes, .key = v.key };
}

/// The harness's vocabulary name to a corruption_reader profile.
fn readerProfile(name: []const u8) []const u8 {
    return if (std.mem.eql(u8, name, "shotgun")) "shotgun_variable" else name;
}

/// Decimal or 0x hex, big-endian into 32 bytes, as corruption-reader's
/// --master parses it.
fn parseMaster(text: []const u8) ![32]u8 {
    var out = [_]u8{0} ** 32;
    const hex = std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X");
    const digits = if (hex) text[2..] else text;
    if (digits.len == 0) return error.InvalidMasterSeed;
    for (digits) |ch| {
        const d: u16 = if (hex) (std.fmt.charToDigit(ch, 16) catch return error.InvalidMasterSeed) else (std.fmt.charToDigit(ch, 10) catch return error.InvalidMasterSeed);
        var carry: u16 = d;
        var i: usize = 32;
        while (i > 0) {
            i -= 1;
            const v = @as(u16, out[i]) * (if (hex) @as(u16, 16) else 10) + carry;
            out[i] = @truncate(v);
            carry = v >> 8;
        }
        if (carry != 0) return error.InvalidMasterSeed;
    }
    return out;
}

/// Draws and validates one case. `arena` holds the profile's and the case's
/// memory; tiffz allocates from `allocator`.
fn runCase(arena: std.mem.Allocator, allocator: std.mem.Allocator, profile: cr.profiles.Profile, seed: *const Seed, master: [32]u8, round: u64) !Outcome {
    const bytes = try arena.create([]const u8);
    bytes.* = seed.bytes;
    const reader_src = cr.source.Source.fromSlice(bytes);
    const case = try cr.api.drawCase(arena, profile, reader_src, master, round);
    if (case.case.noop != null) return .noop;
    var view: ViewSource = .{ .view = try cr.api.view(arena, case, reader_src) };
    const v = try validate(allocator, view.source());
    defer allocator.free(v.key.codes);
    return classify(v, seed.key);
}

const Floors = struct {
    master: []const u8,
    seeds: std.ArrayListUnmanaged([]const u8) = .empty,
    plans: std.ArrayListUnmanaged(struct { profile: []const u8, per: u64, batches: u64 }) = .empty,
    detects: std.StringHashMapUnmanaged(void) = .empty,
};

/// "profile\tseed\tround", the identity of a pinned case.
fn caseId(allocator: std.mem.Allocator, profile: []const u8, seed: []const u8, round: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\t{s}\t{d}", .{ profile, seed, round });
}

fn parseFloors(allocator: std.mem.Allocator, text: []const u8) !Floors {
    var f: Floors = .{ .master = "" };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const kind = fields.next() orelse continue;
        if (std.mem.eql(u8, kind, "master")) {
            f.master = fields.next() orelse return error.BadFloors;
        } else if (std.mem.eql(u8, kind, "seed")) {
            try f.seeds.append(allocator, fields.next() orelse return error.BadFloors);
        } else if (std.mem.eql(u8, kind, "plan")) {
            const profile = fields.next() orelse return error.BadFloors;
            const per = fields.next() orelse return error.BadFloors;
            const batches = fields.next() orelse return error.BadFloors;
            if (!std.mem.startsWith(u8, per, "per=") or !std.mem.startsWith(u8, batches, "batches=")) return error.BadFloors;
            try f.plans.append(allocator, .{
                .profile = profile,
                .per = try std.fmt.parseInt(u64, per[4..], 10),
                .batches = try std.fmt.parseInt(u64, batches[8..], 10),
            });
        } else if (std.mem.eql(u8, kind, "detect")) {
            const profile = fields.next() orelse return error.BadFloors;
            const seed = fields.next() orelse return error.BadFloors;
            const round = try std.fmt.parseInt(u64, fields.next() orelse return error.BadFloors, 10);
            try f.detects.put(allocator, try caseId(allocator, profile, seed, round), {});
        }
    }
    if (f.master.len == 0 or f.seeds.items.len == 0 or f.plans.items.len == 0) return error.BadFloors;
    return f;
}

fn loadFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const io = std.testing.io;
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const buf = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(buf);
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buf);
    try file_reader.interface.readSliceAll(buf);
    return buf;
}

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
    const floors = try parseFloors(keep, try loadFile(keep, floors_path));
    const master = try parseMaster(floors.master);

    var seeds = try keep.alloc(Seed, floors.seeds.items.len);
    for (floors.seeds.items, 0..) |path, i| seeds[i] = try loadSeed(keep, path);

    var lost: usize = 0;
    var new: usize = 0;
    var found: usize = 0;
    var case_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer case_arena.deinit();
    for (floors.plans.items) |plan| {
        var loader: cr.profiles.Loader = .{ .arena = keep };
        const profile = try loader.load(readerProfile(plan.profile));
        var k: u64 = 0;
        while (k < plan.batches) : (k += 1) {
            const seed = &seeds[@intCast(k % seeds.len)];
            var i: u64 = 0;
            while (i < plan.per) : (i += 1) {
                const round = k * plan.per + i;
                _ = case_arena.reset(.retain_capacity);
                const outcome = try runCase(case_arena.allocator(), std.testing.allocator, profile, seed, master, round);
                const id = try caseId(case_arena.allocator(), plan.profile, seed.path, round);
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

test "explore: any master and profile over the floors' seeds (with -Dexplore-master)" {
    if (options.master.len == 0) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const keep = arena_state.allocator();
    const floors = try parseFloors(keep, try loadFile(keep, floors_path));
    const master = try parseMaster(options.master);
    var seeds = try keep.alloc(Seed, floors.seeds.items.len);
    for (floors.seeds.items, 0..) |path, i| seeds[i] = try loadSeed(keep, path);

    var loader: cr.profiles.Loader = .{ .arena = keep };
    const profile = try loader.load(readerProfile(options.profile));
    var counts = std.EnumArray(Outcome, u64).initFill(0);
    var case_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer case_arena.deinit();
    var round: u64 = options.first_round;
    while (round < options.first_round + options.rounds) : (round += 1) {
        const seed = &seeds[@intCast(round % seeds.len)];
        std.debug.print("case {s}\t{s}\t{d}\t", .{ options.profile, seed.path, round });
        _ = case_arena.reset(.retain_capacity);
        const outcome = try runCase(case_arena.allocator(), std.testing.allocator, profile, seed, master, round);
        std.debug.print("{s}\n", .{@tagName(outcome)});
        counts.getPtr(outcome).* += 1;
    }
    std.debug.print("explore {s} master {s}: detect {d} accept {d} reach {d} noop {d}\n", .{ options.profile, options.master, counts.get(.detect), counts.get(.accept), counts.get(.reach), counts.get(.noop) });
}
