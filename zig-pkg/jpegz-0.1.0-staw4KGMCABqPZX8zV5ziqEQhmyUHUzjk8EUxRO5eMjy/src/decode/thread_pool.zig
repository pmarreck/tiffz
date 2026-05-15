//! Minimal internal thread pool used by the cleanroom decoders.
//!
//! Zig 0.16 removed `std.Thread.Pool`, `std.Thread.WaitGroup`,
//! `std.Thread.Mutex`, and `std.Thread.Condition` in favor of
//! `std.Io.Group` / `std.Io.async` / `std.Io.concurrent` + `std.Io.Mutex`.
//! That API requires threading an `io: std.Io` argument through every
//! site that wants to dispatch work — invasive for an I/O-free decode
//! library whose public surface is `decode(allocator, data)`.
//!
//! This shim reproduces the small slice of `std.Thread.Pool` that the
//! cleanroom decoder actually uses (`spawnWg` + `waitAndWork`) on top
//! of `std.Thread.spawn` and atomics. The internal contract is: jobs
//! are queued into a fixed worker set; `waitAndWork` blocks the
//! calling thread until every queued job has finished (with the
//! calling thread also draining work to avoid stalling on the last
//! few tasks). Jobs must not return errors — they wrap user closures
//! that handle their own errors (panicking, or writing to a pre-
//! allocated output buffer).
//!
//! Threading primitives — Zig 0.16 removed `std.Thread.Mutex` and
//! `std.Thread.Condition`. For short critical sections (queue push /
//! pop) an atomic-CAS spin lock is the right tool (per compact_pro's
//! firsthand note in ZIG_0.15_TO_0.16_MIGRATION.md §🔥 `SpinMutex`).
//! Workers idle by yielding the CPU instead of `condvar.wait` —
//! decode work units (≥ 8 µs) dominate the idle yield cost.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    OutOfMemory,
    ThreadSpawnFailed,
};

/// A tiny CAS-based spin lock. Replaces the removed `std.Thread.Mutex`
/// for short bounded critical sections (queue push / pop inside the
/// pool). For long-held locks, use `std.Io.Mutex` and plumb `io`.
const SpinMutex = struct {
    state: std.atomic.Value(u8) = .init(0),

    fn lock(self: *SpinMutex) void {
        while (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinMutex) void {
        self.state.store(0, .release);
    }
};

/// Tracks outstanding work items so `Pool.waitAndWork` knows when
/// every spawned job has finished. The internal counter is an
/// `std.atomic.Value(u32)` updated with monotonic-then-acquire-release
/// semantics — start() bumps, finish() decrements and the waiter
/// polls `isDone` until it hits zero.
pub const WaitGroup = struct {
    counter: std.atomic.Value(u32) = .init(0),

    pub fn start(self: *WaitGroup) void {
        _ = self.counter.fetchAdd(1, .monotonic);
    }

    fn finish(self: *WaitGroup) void {
        _ = self.counter.fetchSub(1, .release);
    }

    pub fn isDone(self: *const WaitGroup) bool {
        return self.counter.load(.acquire) == 0;
    }
};

/// A single queued work item: a type-erased closure plus its arena
/// allocation (so the pool can free it after the closure has run).
const Job = struct {
    runFn: *const fn (closure: *anyopaque) void,
    closure: *anyopaque,
    closure_size: usize,
    closure_align: u8,
    wg: ?*WaitGroup,
};

pub const Options = struct {
    allocator: Allocator,
    /// Number of worker threads to spawn. Must be ≥ 1.
    n_jobs: u32,
};

/// Internal thread pool. Mirrors the slice of the removed
/// `std.Thread.Pool` API the cleanroom decoder needs.
pub const Pool = struct {
    allocator: Allocator,
    workers: []std.Thread,
    mutex: SpinMutex = .{},
    queue: std.ArrayList(Job),
    shutdown: std.atomic.Value(bool),

    /// Spawns `options.n_jobs` worker threads. Returns `error` on
    /// allocation or thread-spawn failure; partial spawns are torn
    /// down before propagating.
    pub fn init(self: *Pool, options: Options) Error!void {
        const workers = try options.allocator.alloc(std.Thread, options.n_jobs);
        errdefer options.allocator.free(workers);

        self.* = .{
            .allocator = options.allocator,
            .workers = workers,
            .queue = .empty,
            .shutdown = .init(false),
        };

        var spawned: usize = 0;
        errdefer {
            self.shutdown.store(true, .release);
            var i: usize = 0;
            while (i < spawned) : (i += 1) workers[i].join();
            self.queue.deinit(self.allocator);
        }

        while (spawned < workers.len) : (spawned += 1) {
            workers[spawned] = std.Thread.spawn(.{}, workerLoop, .{self}) catch
                return Error.ThreadSpawnFailed;
        }
    }

    /// Drain all queued work, signal workers to exit, join every
    /// thread. Safe to call exactly once; calling twice is a bug.
    pub fn deinit(self: *Pool) void {
        self.shutdown.store(true, .release);
        for (self.workers) |w| w.join();
        self.queue.deinit(self.allocator);
        self.allocator.free(self.workers);
        self.* = undefined;
    }

    /// Spawn `function(args...)` on the pool and register it with the
    /// given `WaitGroup`. The closure is heap-allocated (sized to the
    /// args tuple) and freed by the worker after `function` returns.
    pub fn spawnWg(
        self: *Pool,
        wg: *WaitGroup,
        comptime function: anytype,
        args: anytype,
    ) void {
        const Args = @TypeOf(args);
        const Closure = struct {
            args: Args,
            fn run(opaque_ptr: *anyopaque) void {
                const closure: *@This() = @ptrCast(@alignCast(opaque_ptr));
                @call(.auto, function, closure.args);
            }
        };

        // Allocate the closure. If allocation fails, fall back to
        // running the work inline on the calling thread — the pool's
        // purpose is throughput, not correctness, so we still finish.
        const mem = self.allocator.create(Closure) catch {
            wg.start();
            @call(.auto, function, args);
            wg.finish();
            return;
        };
        mem.* = .{ .args = args };

        wg.start();

        self.mutex.lock();
        self.queue.append(self.allocator, .{
            .runFn = &Closure.run,
            .closure = mem,
            .closure_size = @sizeOf(Closure),
            .closure_align = @alignOf(Closure),
            .wg = wg,
        }) catch {
            // OOM enqueuing — fall back to inline execution.
            self.mutex.unlock();
            @call(.auto, function, args);
            wg.finish();
            self.allocator.destroy(mem);
            return;
        };
        self.mutex.unlock();
    }

    /// Block the calling thread until `wg` hits zero. While waiting,
    /// the calling thread cooperatively pulls jobs off the queue so
    /// it doesn't stall on the last few tasks (matches std's
    /// `waitAndWork` semantics).
    pub fn waitAndWork(self: *Pool, wg: *WaitGroup) void {
        while (!wg.isDone()) {
            if (self.tryDequeue()) |job| {
                runJob(self, job);
            } else {
                std.Thread.yield() catch {};
            }
        }
    }

    fn tryDequeue(self: *Pool) ?Job {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queue.items.len == 0) return null;
        return self.queue.orderedRemove(0);
    }

    fn runJob(self: *Pool, job: Job) void {
        job.runFn(job.closure);
        if (job.wg) |wg| wg.finish();
        // Free the closure heap allocation. We need the type-erased
        // size and alignment captured at spawn time.
        const raw: [*]u8 = @ptrCast(@alignCast(job.closure));
        const slice = raw[0..job.closure_size];
        self.allocator.rawFree(slice, std.mem.Alignment.fromByteUnits(job.closure_align), @returnAddress());
    }

    fn workerLoop(self: *Pool) void {
        while (true) {
            if (self.tryDequeue()) |job| {
                runJob(self, job);
                continue;
            }
            if (self.shutdown.load(.acquire)) return;
            std.Thread.yield() catch {};
        }
    }
};
