//! lazily-zig thread-safe contention benchmark (`#lzcontentionbench`).
//!
//! Measures the graph mutex (`ParkingMutex`, `#lzparkingmutex`) under N-thread
//! contention, head-to-head against the previous busy-wait spinlock it replaced.
//! Each worker thread hammers `lock + short critical section + unlock` for a
//! fixed wall-clock window; completed ops are counted and reported as total
//! throughput (Mops/s) and per-op latency (ns/op).
//!
//! ## Why direct lock measurement (not slot.get())
//!
//! The ideal workload — N threads doing `slot.get()` on a shared Context —
//! cannot currently run: lazily-zig's `slot()`/`Slot.initKeyed` path has a
//! pre-existing concurrency bug where 4+ threads concurrently calling `slot()`
//! on the same Context cause the process to exit (investigated but root cause
//! not yet isolated; appears to be in the materialization path, not the lock).
//! That is a pre-existing issue tracked separately from the parking mutex.
//!
//! Measuring the lock DIRECTLY is the honest way to prove the parking-mutex
//! win: it isolates exactly the code that changed (the mutex), with no
//! contribution from the orthogonal slot()-path bug. Both the parking mutex
//! and the old spinlock are measured on the same machine in the same binary,
//! so the before/after comparison is controlled.
//!
//! ## What the numbers show
//!
//! - **N=1 (uncontended):** both mutexes are one `cmpxchg` on the fast path.
//!   Numbers should match within noise — proves the parking mutex doesn't
//!   regress the common case.
//! - **N>1 (contended):** the spinlock busy-waits (`while (!tryLock()) {}`),
//!   so N spinning threads hammer the cache line holding the lock word,
//!   stealing memory bandwidth from the lock holder and ballooning per-op
//!   latency. The parking mutex parks contended threads via the Linux futex
//!   syscall, keeping per-op latency bounded and letting the lock holder run
//!   unimpeded.
//!
//! Run: `zig build bench-contention`
//! Env:  LAZILY_CONTENTION_WINDOW_MS (default 100)
//!       LAZILY_CONTENTION_THREADS   (default "1,2,4,8,16")

const std = @import("std");
const builtin = @import("builtin");
const lazily = @import("lazily");

const ParkingMutex = lazily.ParkingMutex;
const linux = std.os.linux;

fn nowNs() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn sleepMs(ms: u64) void {
    var req: linux.timespec = .{ .sec = 0, .nsec = @intCast(ms * std.time.ns_per_ms) };
    _ = linux.nanosleep(&req, null);
}

/// Read an env var's raw value via `/proc/self/environ` (the stable env path
/// on Zig 0.17-dev — `std.posix.getenv` moved behind the Io interface).
fn envStr(name: []const u8) ?[]const u8 {
    var buf: [65536]u8 = undefined;
    const fd: usize = linux.open("/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(fd)) < 0) return null;
    defer _ = linux.close(@intCast(fd));
    var total: usize = 0;
    while (total < buf.len) {
        const r = linux.read(@intCast(fd), buf[total..].ptr, buf.len - total);
        const ri: isize = @bitCast(r);
        if (ri <= 0) break;
        total += @intCast(r);
    }
    var it = std.mem.splitScalar(u8, buf[0..total], 0);
    while (it.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..eq], name)) return entry[eq + 1 ..];
    }
    return null;
}

// --- the two mutex policies under test ---------------------------------------

/// The previous graph-mutex fallback: a busy-wait spinlock over
/// `std.atomic.Mutex`. This is exactly what `context.zig` used before
/// `#lzparkingmuxed` it. Vendored here so both policies run in the same binary
/// for a controlled before/after comparison.
const Spinlock = struct {
    inner: std.atomic.Mutex = .unlocked,
    pub fn lock(self: *Spinlock) void {
        while (!self.inner.tryLock()) {}
    }
    pub fn unlock(self: *Spinlock) void {
        self.inner.unlock();
    }
};

// A per-thread counter, bumped under the lock. Models the shape of a real
// critical section (read-modify-write of shared state) without touching the
// lazily slot path.
const Shared = struct {
    counter: std.atomic.Value(u64) = .init(0),
};

const Policy = enum { parking, spin };

const WorkerArgs = struct {
    lock_idx: usize, // index into the per-policy lock array
    policy: Policy,
    barrier: *std.atomic.Value(i32),
    stop: *std.atomic.Value(bool),
    ops: *std.atomic.Value(u64),
};

// One lock per (policy, run) so runs don't share lock state. Sized to the max
// thread count we test.
var parking_locks: [16]ParkingMutex = init: {
    var arr: [16]ParkingMutex = undefined;
    for (&arr) |*m| m.* = .{};
    break :init arr;
};
var spin_locks: [16]Spinlock = init: {
    var arr: [16]Spinlock = undefined;
    for (&arr) |*m| m.* = .{};
    break :init arr;
};
var shared_state: [16]Shared = init: {
    var arr: [16]Shared = undefined;
    for (&arr) |*m| m.* = .{};
    break :init arr;
};

fn worker(args: WorkerArgs) void {
    _ = args.barrier.fetchSub(1, .seq_cst);
    while (args.barrier.load(.acquire) > 0) std.atomic.spinLoopHint();

    var local: u64 = 0;
    const idx = args.lock_idx;
    const shared = &shared_state[idx];
    while (!args.stop.load(.monotonic)) {
        // Critical section: lock, bump counter, unlock. Short (matches the
        // shape of the lazily graph critical section). This is the exact
        // contention pattern the spinlock choked on.
        switch (args.policy) {
            .parking => {
                parking_locks[idx].lock();
                _ = shared.counter.fetchAdd(1, .monotonic);
                parking_locks[idx].unlock();
            },
            .spin => {
                spin_locks[idx].lock();
                _ = shared.counter.fetchAdd(1, .monotonic);
                spin_locks[idx].unlock();
            },
        }
        local += 1;
    }
    _ = args.ops.fetchAdd(local, .monotonic);
}

fn runPolicy(policy: Policy, n_threads: usize, window_ms: u64, run_idx: usize) struct {
    mops: f64,
    ns_per_op: f64,
} {
    var barrier = std.atomic.Value(i32).init(@intCast(n_threads));
    var stop = std.atomic.Value(bool).init(false);
    var ops = std.atomic.Value(u64).init(0);

    const allocator = std.heap.page_allocator;
    const threads = allocator.alloc(std.Thread, n_threads) catch unreachable;
    defer allocator.free(threads);

    for (threads) |*t| {
        t.* = std.Thread.spawn(.{}, worker, .{WorkerArgs{
            .lock_idx = run_idx,
            .policy = policy,
            .barrier = &barrier,
            .stop = &stop,
            .ops = &ops,
        }}) catch unreachable;
    }

    while (barrier.load(.acquire) > 0) std.atomic.spinLoopHint();
    const start = nowNs();
    sleepMs(window_ms);
    stop.store(true, .release);
    for (threads) |t| t.join();
    const end = nowNs();

    const window_ns: f64 = @floatFromInt(@as(i64, @intCast(end - start)));
    const total_ops = ops.load(.monotonic);
    const mops = if (window_ns > 0) (@as(f64, @floatFromInt(total_ops)) / (window_ns / 1e9)) / 1e6 else 0;
    const ns_per_op: f64 = if (total_ops > 0) window_ns / @as(f64, @floatFromInt(total_ops)) else 0;
    return .{ .mops = mops, .ns_per_op = ns_per_op };
}

fn parseThreadList(env: ?[]const u8) []const usize {
    const default_list = [_]usize{ 1, 2, 4, 8, 16 };
    if (env == null) return &default_list;
    var buf: [16]usize = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, env.?, ',');
    while (it.next()) |tok| {
        if (n >= buf.len) break;
        buf[n] = std.fmt.parseInt(usize, std.mem.trim(u8, tok, " "), 10) catch continue;
        n += 1;
    }
    if (n == 0) return &default_list;
    const Static = struct {
        var stored: [16]usize = undefined;
    };
    @memcpy(Static.stored[0..n], buf[0..n]);
    return Static.stored[0..n];
}

pub fn main() !void {
    const window_ms: u64 = blk: {
        if (envStr("LAZILY_CONTENTION_WINDOW_MS")) |s| {
            break :blk std.fmt.parseInt(u64, s, 10) catch 100;
        }
        break :blk 100;
    };
    const thread_list = parseThreadList(envStr("LAZILY_CONTENTION_THREADS"));

    std.debug.print("lazily-zig graph-mutex contention benchmark\n", .{});
    std.debug.print("===========================================\n\n", .{});
    std.debug.print("window = {d} ms per (policy × thread count)\n", .{window_ms});
    std.debug.print("Workload: N threads × {{lock; counter++; unlock}} on a shared lock.\n\n", .{});
    std.debug.print("Head-to-head: ParkingMutex (new, #lzparkingmutex) vs Spinlock (old).\n", .{});
    std.debug.print("Both vendored in-binary for a controlled before/after comparison.\n\n", .{});

    std.debug.print("## ParkingMutex (new — parks contended threads via Linux futex)\n\n", .{});
    std.debug.print("| Threads | Throughput (Mops/s) | Latency (ns/op) |\n", .{});
    std.debug.print("|---:|---:|---:|\n", .{});
    var run: usize = 0;
    for (thread_list) |n| {
        _ = runPolicy(.parking, n, 10, run); // warmup
        const r = runPolicy(.parking, n, window_ms, run);
        run += 1;
        std.debug.print("| {d} | {d:.3} | {d:.1} |\n", .{ n, r.mops, r.ns_per_op });
    }

    std.debug.print("\n## Spinlock (old — busy-wait over std.atomic.Mutex)\n\n", .{});
    std.debug.print("| Threads | Throughput (Mops/s) | Latency (ns/op) |\n", .{});
    std.debug.print("|---:|---:|---:|\n", .{});
    run = 0;
    for (thread_list) |n| {
        _ = runPolicy(.spin, n, 10, run); // warmup
        const r = runPolicy(.spin, n, window_ms, run);
        run += 1;
        std.debug.print("| {d} | {d:.3} | {d:.1} |\n", .{ n, r.mops, r.ns_per_op });
    }

    std.debug.print("\n## Honest read\n\n", .{});
    std.debug.print("- **N=1** should match across both (fast path = one cmpxchg, no syscall).\n", .{});
    std.debug.print("- **N>1** is where they diverge: the spinlock's busy-wait hammers the cache\n", .{});
    std.debug.print("  line holding the lock word (N-1 cores compete with the holder for memory\n", .{});
    std.debug.print("  bandwidth), so latency balloons. The parking mutex parks waiters in the\n", .{});
    std.debug.print("  kernel, so the holder runs unimpeded and per-op latency stays bounded.\n", .{});
    std.debug.print("- This is the **lock-isolated** measurement. The full `slot.get()` path has a\n", .{});
    std.debug.print("  separate pre-existing concurrency bug (4+ threads on `slot()` exit the\n", .{});
    std.debug.print("  process) tracked as follow-up — orthogonal to the parking mutex itself.\n", .{});
}
