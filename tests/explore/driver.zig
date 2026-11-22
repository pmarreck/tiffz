//! The in-process corruption exploration driver, shared by the parity test
//! (explore_test.zig) and the `tiffz-explore` executable (main.zig).
//! corruption_reader draws a case from a seed held in memory; tiffz validates
//! the case's positional view through a PlanView-backed tiffz.Source; the
//! outcome is classified exactly as ./corruption-coverage classifies a
//! subprocess run of `tiffz validate` (docs/plan_context/in-process-exploration.md).

const std = @import("std");
const tiffz = @import("tiffz");
pub const cr = @import("corruption_reader");

pub const floors_path = "tests/corruption_coverage_floors";

pub const Outcome = enum { detect, accept, reach, noop };

/// The findings of one validation, reduced to what the harness compares:
/// every finding code except 16, sorted, and whether 16 appeared.
pub const Key = struct {
    codes: []i32,
    has16: bool,

    pub fn eql(a: Key, b: Key) bool {
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
pub const Verdict = struct { exit: u8, key: Key };

/// The CLI's exit status for a failed validation (cli/main.c exit_for_status).
fn exitFor(err: tiffz.Error, corrupt: bool) u8 {
    if ((tiffz.errors.isLimit(err) or tiffz.errors.isUnsupported(err)) and !corrupt) return 4;
    return 1;
}

/// tiffz_open_from_buffer, the finding callback and tiffz_validate, as the
/// CLI calls them (src/ffi.zig), over any Source.
pub fn validate(allocator: std.mem.Allocator, src: tiffz.Source) !Verdict {
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
pub fn classify(case: Verdict, seed: Key) Outcome {
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

pub const Seed = struct {
    path: []const u8,
    bytes: []const u8,
    key: Key,
    /// libtiff's layout of the seed, when a layouts file lists it.
    layout: ?*const Layout = null,
};

/// One seed's layout as ./corruption-coverage maps it with libtiff's
/// tiffdump (`--layouts-out`): its class and the half-open byte ranges of
/// its uncompressed strip and tile data.
pub const Layout = struct {
    bytes: u64,
    class: []const u8,
    free: std.ArrayListUnmanaged([2]u64) = .empty,
};

/// Seed path to layout, from "seed\tPATH\tBYTES\tCLASS" and
/// "free\tPATH\tSTART\tEND" lines.
pub fn parseLayouts(allocator: std.mem.Allocator, text: []const u8) !std.StringHashMapUnmanaged(Layout) {
    var map: std.StringHashMapUnmanaged(Layout) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const kind = fields.next() orelse return error.BadLayouts;
        const path = fields.next() orelse return error.BadLayouts;
        const a = std.fmt.parseInt(u64, fields.next() orelse return error.BadLayouts, 10) catch return error.BadLayouts;
        const b = fields.next() orelse return error.BadLayouts;
        if (fields.next() != null) return error.BadLayouts;
        if (std.mem.eql(u8, kind, "seed")) {
            const gop = try map.getOrPut(allocator, path);
            if (gop.found_existing) return error.BadLayouts;
            gop.value_ptr.* = .{ .bytes = a, .class = b };
        } else if (std.mem.eql(u8, kind, "free")) {
            const layout = map.getPtr(path) orelse return error.BadLayouts;
            const end = std.fmt.parseInt(u64, b, 10) catch return error.BadLayouts;
            if (end < a) return error.BadLayouts;
            try layout.free.append(allocator, .{ a, end });
        } else return error.BadLayouts;
    }
    return map;
}

/// The harness's bound on a case (corruption-coverage case_bound, first
/// step): free when the length is unchanged and every changed byte lies in
/// an uncompressed sample range, so the file is still a valid TIFF and no
/// validator can detect it. `open` covers the harness's clean and open,
/// since telling them apart needs libtiff's tiffinfo. `unknown` without a
/// layout.
pub const Bound = enum { free, open, unknown };

pub fn bound(layout: ?*const Layout, seed: []const u8, case: []const u8) Bound {
    const l = layout orelse return .unknown;
    if (case.len != seed.len) return .open;
    for (seed, case, 0..) |s, c, i| {
        if (s == c) continue;
        const at: u64 = i;
        for (l.free.items) |r| {
            if (at >= r[0] and at < r[1]) break;
        } else return .open;
    }
    return .free;
}

pub const Result = struct { outcome: Outcome, bound: Bound };

pub fn loadSeed(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !Seed {
    const bytes = try loadFile(io, allocator, path);
    var handle = tiffz.source.BufferHandle.init(bytes);
    const v = try validate(allocator, tiffz.Source.fromBuffer(&handle));
    if (v.exit != 0) {
        std.debug.print("seed {s} does not validate (exit {d})\n", .{ path, v.exit });
        return error.SeedRejected;
    }
    return .{ .path = path, .bytes = bytes, .key = v.key };
}

/// The harness's vocabulary name to a corruption_reader profile.
pub fn readerProfile(name: []const u8) []const u8 {
    return if (std.mem.eql(u8, name, "shotgun")) "shotgun_variable" else name;
}

/// Decimal or 0x hex, big-endian into 32 bytes, as corruption-reader's
/// --master parses it.
pub fn parseMaster(text: []const u8) ![32]u8 {
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
pub fn runCase(arena: std.mem.Allocator, allocator: std.mem.Allocator, profile: cr.profiles.Profile, seed: *const Seed, master: [32]u8, round: u64) !Result {
    const bytes = try arena.create([]const u8);
    bytes.* = seed.bytes;
    const reader_src = cr.source.Source.fromSlice(bytes);
    const case = try cr.api.drawCase(arena, profile, reader_src, master, round);
    if (case.case.noop != null) return .{ .outcome = .noop, .bound = .unknown };
    var view: ViewSource = .{ .view = try cr.api.view(arena, case, reader_src) };
    const v = try validate(allocator, view.source());
    defer allocator.free(v.key.codes);
    const outcome = classify(v, seed.key);
    if (seed.layout == null) return .{ .outcome = outcome, .bound = .unknown };
    // The case's bytes, read through the same view tiffz read.
    const case_bytes = try arena.alloc(u8, @intCast(view.view.length()));
    var got: usize = 0;
    while (got < case_bytes.len) {
        const n = try view.view.readAt(got, case_bytes[got..]);
        if (n == 0) return error.ShortView;
        got += n;
    }
    return .{ .outcome = outcome, .bound = bound(seed.layout, seed.bytes, case_bytes) };
}

pub const Floors = struct {
    master: []const u8,
    seeds: std.ArrayListUnmanaged([]const u8) = .empty,
    plans: std.ArrayListUnmanaged(struct { profile: []const u8, per: u64, batches: u64 }) = .empty,
    detects: std.StringHashMapUnmanaged(void) = .empty,
};

/// "profile\tseed\tround", the identity of a pinned case.
pub fn caseId(allocator: std.mem.Allocator, profile: []const u8, seed: []const u8, round: u64) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}\t{s}\t{d}", .{ profile, seed, round });
}

pub fn parseFloors(allocator: std.mem.Allocator, text: []const u8) !Floors {
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

pub fn loadFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
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

/// `tiffz-explore` options. Defaults match ./corruption-coverage: shotgun,
/// rounds from 0, 385 rounds, and the pinned floors' seeds.
pub const Args = struct {
    master: []const u8,
    profile: []const u8 = "shotgun",
    first_round: u64 = 0,
    rounds: u64 = 385,
    floors: []const u8 = floors_path,
    /// ./corruption-coverage --layouts-out, for the free-case bound.
    layouts: ?[]const u8 = null,
    /// Replay the floors plan (every profile, the floors' master) instead
    /// of a master and profile.
    replay_floors: bool = false,
};

pub const usage =
    \\usage: tiffz-explore --master SEED [--profile NAME] [--first-round R]
    \\                     [--rounds N] [--floors PATH] [--layouts PATH]
    \\       tiffz-explore --replay-floors [--floors PATH] [--layouts PATH]
    \\
    \\Draws N corruption_reader cases in-process, round R onward, from the
    \\seeds a floors file lists (default tests/corruption_coverage_floors,
    \\relative to the current directory), and validates each through tiffz.
    \\Case k uses seed k mod SEEDS. SEED is decimal or 0x hex, as
    \\corruption-reader's --master; NAME is a harness profile (sniper,
    \\bolter, shotgun, nuke, ...; default shotgun). Prints one line per case,
    \\"case PROFILE SEED ROUND OUTCOME", then a summary. The case line is
    \\written before the case runs, so after a crash the last line names it.
    \\
    \\With --layouts (./corruption-coverage --layouts-out), each line ends
    \\with the case's bound: free when every changed byte is an uncompressed
    \\sample (the file is still valid, so a detection is a false alarm), open
    \\otherwise, unknown without a layout. --replay-floors replays the floors
    \\plan (batch k draws per cases from seed k mod SEEDS at round k*per)
    \\under the floors' master and prints "class PROFILE CLASS decisive=N
    \\detect=K free=F false_alarm=A" per profile and seed class.
    \\Exit 0 when every case ran without a false alarm, 1 on an error or a
    \\false alarm, 2 on a usage error.
    \\
;

/// Parses argv without the program name. error.Help for -h or --help.
pub fn parseArgs(argv: []const []const u8) !Args {
    var master: ?[]const u8 = null;
    var out: Args = .{ .master = "" };
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const flag = argv[i];
        if (std.mem.eql(u8, flag, "-h") or std.mem.eql(u8, flag, "--help")) return error.Help;
        if (std.mem.eql(u8, flag, "--replay-floors")) {
            out.replay_floors = true;
            continue;
        }
        i += 1;
        if (i == argv.len) return error.Usage;
        const value = argv[i];
        if (std.mem.eql(u8, flag, "--master")) {
            _ = parseMaster(value) catch return error.Usage;
            master = value;
        } else if (std.mem.eql(u8, flag, "--profile")) {
            out.profile = value;
        } else if (std.mem.eql(u8, flag, "--first-round")) {
            out.first_round = std.fmt.parseInt(u64, value, 10) catch return error.Usage;
        } else if (std.mem.eql(u8, flag, "--rounds")) {
            out.rounds = std.fmt.parseInt(u64, value, 10) catch return error.Usage;
        } else if (std.mem.eql(u8, flag, "--floors")) {
            out.floors = value;
        } else if (std.mem.eql(u8, flag, "--layouts")) {
            out.layouts = value;
        } else return error.Usage;
    }
    if (out.replay_floors) {
        if (master != null) return error.Usage;
    } else out.master = master orelse return error.Usage;
    _ = std.math.add(u64, out.first_round, out.rounds) catch return error.Usage;
    return out;
}
