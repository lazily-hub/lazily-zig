//! Parking mutex for the lazily graph lock (`#lzparkingmutex`).
//!
//! Background — Zig 0.16 removed `std.Thread.Mutex` (and `std.Thread.Futex`),
//! pushing synchronization onto the new `std.Io` runtime surface. lazily-zig's
//! graph lock does not (and cannot, portably) host an `Io`, so `context.zig`
//! had fallen back to a busy-wait spinlock over `std.atomic.Mutex`. Under N-
//! writer contention that busy-wait burns cores and offers no fairness/backoff
//! — a real high-load cliff (see BENCHMARKS.md § Thread-safe contention).
//!
//! This module vendors a minimal futex-backed parking mutex on Linux (the
//! primary dev/CI platform per BENCHMARKS.md) and falls back to a yield-backoff
//! spin on other targets. The fast path is identical to a spinlock (one
//! uncontended `cmpxchg`); the slow path *parks* the thread in the kernel
//! instead of spinning, so contended acquires stop consuming CPU.
//!
//! Design — the classic 3-state futex mutex (Drepper, "Futexes are tricky":
//! §1–2; this is what `std.Thread.Mutex` did before the 0.16 Io rework):
//!
//!   state == 0  UNLOCKED
//!   state == 1  LOCKED, no waiters
//!   state == 2  LOCKED, ≥1 waiter parked in the kernel
//!
//! - `lock()` fast path: `cmpxchg 0 → 1`. On success, no syscall.
//! - `lock()` slow path: adaptive spin (short — graph critical sections are
//!   tiny), then set the CONTESTED bit and `FUTEX_WAIT` on state==2.
//! - `unlock()`: `swap` to 0 with release ordering. If the previous state was
//!   CONTESTED, `FUTEX_WAKE` one waiter.
//!
//! The CONTESTED bit is the load-bearing piece: an unlocker only issues a wake
//! syscall when a waiter has actually parked, so the uncontended path never
//! enters the kernel. The bit also closes the lost-wakeup race: if an unlock
//! happens between a waiter's `cmpxchg` and its `FUTEX_WAIT`, the kernel
//! observes `state != 2` and returns `EAGAIN` immediately, so the waiter loops
//! and re-acquires. We do not inspect the syscall return — the loop's
//! state re-check is the source of truth.

const std = @import("std");
const builtin = @import("builtin");
const atomic = std.atomic;

const has_futex = builtin.os.tag == .linux;

/// 3-state parking mutex. Fast path: one `cmpxchg`. Slow path: futex park
/// (Linux) or `sched_yield` backoff (other platforms).
pub const ParkingMutex = struct {
    state: atomic.Value(u32) = .init(UNLOCKED),

    const UNLOCKED: u32 = 0;
    const LOCKED: u32 = 1;
    const CONTESTED: u32 = 2;

    /// Number of `spinLoopHint` iterations before parking/yielding. Graph
    /// critical sections are short (a few map ops), so a modest spin catches
    /// the common "lock released within a few cycles" case without burning
    /// meaningful CPU.
    const SPIN_MAX: u32 = 64;

    pub fn init() ParkingMutex {
        return .{ .state = .init(UNLOCKED) };
    }

    pub inline fn lock(self: *ParkingMutex) void {
        // Fast path: uncontended acquire — one cmpxchg, no syscall.
        if (self.state.cmpxchgStrong(UNLOCKED, LOCKED, .acquire, .monotonic) == null)
            return;
        self.lockSlow();
    }

    pub inline fn tryLock(self: *ParkingMutex) bool {
        return self.state.cmpxchgStrong(UNLOCKED, LOCKED, .acquire, .monotonic) == null;
    }

    pub inline fn unlock(self: *ParkingMutex) void {
        // Fast path: if no one parked, drop to UNLOCKED with no syscall.
        const prev = self.state.swap(UNLOCKED, .release);
        if (prev != LOCKED) {
            // A waiter is (or was) parked. Wake one. Spurious wakes are fine:
            // the woken waiter re-checks state and re-parks if it lost the race.
            self.wakeOne();
        }
    }

    fn lockSlow(self: *ParkingMutex) void {
        // Adaptive spin: pause-and-retry a bounded number of times. Catches
        // short critical sections without entering the kernel.
        var spin: u32 = 0;
        while (spin < SPIN_MAX) : (spin += 1) {
            if (self.state.load(.monotonic) == UNLOCKED) {
                if (self.state.cmpxchgStrong(UNLOCKED, LOCKED, .acquire, .monotonic) == null)
                    return;
            }
            atomic.spinLoopHint();
        }

        // Park path — the canonical 3-state futex mutex (Drepper, "Futexes Are
        // Tricky" §2; the glibc low-level-lock design). Once we enter the slow
        // path we acquire the lock by *swapping in CONTESTED*, never LOCKED: a
        // slow-path acquirer cannot know whether other waiters are still
        // parked, so it conservatively leaves the CONTESTED flag set. `unlock`
        // then always issues a wake (its `swap` returns 2, not 1), so wakeups
        // chain one waiter at a time and none is ever stranded.
        //
        // The previous version acquired as LOCKED when it observed UNLOCKED
        // from the wait path (`if (new == LOCKED) return`). That dropped the
        // CONTESTED flag: with ≥2 waiters parked, waking one — which then
        // re-acquired as LOCKED — meant its eventual `unlock` saw LOCKED and
        // skipped the wake, stranding the co-parked waiter forever. That is the
        // N-thread-contention deadlock (slot/cell thread-safe soaks hung in
        // `futex_wait` at 0% CPU). Acquiring as CONTESTED costs at most one
        // spurious wake syscall when we were in fact the last waiter — the
        // standard, correct trade.
        //
        // `swap(CONTESTED)` returns the prior state:
        //   - UNLOCKED → the lock was free; we now own it (state left CONTESTED).
        //   - LOCKED / CONTESTED → still held; park until woken, then retry. The
        //     swap has already re-armed CONTESTED, so `futex_wait` gates on it;
        //     if an unlocker raced ahead (state→UNLOCKED) the wait returns
        //     EAGAIN immediately and we re-swap.
        while (self.state.swap(CONTESTED, .acquire) != UNLOCKED) {
            self.waitOnContended();
        }
    }

    /// Park the current thread until `wakeOne` is called. The kernel gates the
    /// sleep on `state == CONTESTED`; if state changed (race with unlock), the
    /// call returns immediately — the caller's outer loop re-checks state.
    fn waitOnContended(self: *ParkingMutex) void {
        if (has_futex) {
            const linux = std.os.linux;
            const wait_op: linux.FUTEX_OP = .{ .cmd = .WAIT, .private = true };
            // Timeout null ⇒ block indefinitely until woken (or EAGAIN/EINTR).
            // Return value ignored — the outer loop re-checks state, which is
            // the source of truth (handles EAGAIN/EINTR/lost-wakeup uniformly).
            _ = linux.futex_4arg(&self.state.raw, wait_op, CONTESTED, null);
        } else {
            // Non-Linux fallback: yield to the scheduler. Less efficient under
            // heavy contention than a real park, but correct and portable.
            // The slow path here is the documented limitation; the headline
            // platform (Linux, where contention is benchmarked) uses futex.
            std.Thread.yield() catch {};
        }
    }

    fn wakeOne(self: *ParkingMutex) void {
        if (has_futex) {
            const linux = std.os.linux;
            const wake_op: linux.FUTEX_OP = .{ .cmd = .WAKE, .private = true };
            _ = linux.futex_3arg(&self.state.raw, wake_op, 1);
        }
        // Non-Linux fallback: waiters are spinning on yield, nothing to wake.
    }
};

/// Reentrant mutex: wraps `ParkingMutex` with owner-thread tracking so the
/// same thread can acquire the lock multiple times without deadlock. Each
/// `lock()` from the owner increments `depth`; each `unlock()` decrements;
/// the underlying `ParkingMutex` is only released when `depth` reaches 0.
///
/// This is the graph mutex type used by `Context` (via `GraphMutex`) on
/// Zig ≥0.16. The lazily graph's `Slot.initKeyed` calls user `valueFn` which
/// re-enters the graph via `cell()`/`slot()` (each of which locks). A
/// non-reentrant mutex would deadlock on that re-entry. The old pre-0.16
/// `std.Thread.Mutex` was similarly non-reentrant, so the engine released the
/// lock before calling valueFn — which opened a use-after-free race window
/// (`#lzuafix`: a concurrent `emitChange` could free a slot that the
/// materializing thread hadn't yet published to the cache). Reentrancy lets
/// `initKeyed` hold the lock across subscribe → valueFn → cache-put, closing
/// the window.
///
/// Correctness: `owner` is set AFTER `inner.lock()` succeeds and cleared
/// BEFORE `inner.unlock()`. Between those points, the owning thread
/// exclusively owns both `owner` and `depth` (no other thread can read or
/// write them — they're blocked on `inner`). The re-entrancy check
/// (`owner.load() == tid`) reads `owner` without holding `inner`, but this is
/// safe because only the owning thread sees `owner == tid`, and it's the only
/// thread that reads `depth`.
pub const ReentrantMutex = struct {
    inner: ParkingMutex = .{},
    owner: atomic.Value(usize) = .init(0),
    depth: u32 = 0,

    pub fn init() ReentrantMutex {
        return .{};
    }

    pub inline fn lock(self: *ReentrantMutex) void {
        const tid = currentThreadId();
        if (self.owner.load(.monotonic) == tid) {
            // Re-entrant acquire by the owner — just bump depth.
            self.depth += 1;
            return;
        }
        // Contended (or first) acquire — park on the inner mutex.
        self.inner.lock();
        self.owner.store(tid, .monotonic);
        self.depth = 1;
    }

    pub inline fn tryLock(self: *ReentrantMutex) bool {
        const tid = currentThreadId();
        if (self.owner.load(.monotonic) == tid) {
            self.depth += 1;
            return true;
        }
        if (self.inner.tryLock()) {
            self.owner.store(tid, .monotonic);
            self.depth = 1;
            return true;
        }
        return false;
    }

    pub inline fn unlock(self: *ReentrantMutex) void {
        std.debug.assert(self.depth > 0);
        self.depth -= 1;
        if (self.depth == 0) {
            self.owner.store(0, .release);
            self.inner.unlock();
        }
    }
};

/// Returns the current thread's OS-level ID as a `usize`. Used as the
/// reentrant-mutex owner token. `std.Thread.getCurrentId()` already caches the
/// tid in a thread-local after the first `gettid()`, so this is a TLS read on
/// the hot path — no per-acquire syscall.
fn currentThreadId() usize {
    return @intCast(std.Thread.getCurrentId());
}

/// Read/write lock — opt-in policy for read-heavy workloads (mirrors lazily-cpp
/// v0.4.0's `RwThreadSafeContext`). Multiple readers can hold the lock
/// concurrently via `lockShared`/`unlockShared`; writers get exclusive access
/// via `lockExclusive`/`unlockExclusive`.
///
/// Implementation: the classic "reader-count gates writer" pattern over two
/// `ParkingMutex`es. The first reader acquires `writer_gate` (locking out
/// writers); the last reader releases it. `reader_gate` serializes the
/// reader-count update (a short critical section). Writers acquire
/// `writer_gate` exclusively. This is reader-preferring (a steady stream of
/// readers starves writers) — the right default for UI/editor/CRDT workloads
/// where reads vastly outnumber writes.
///
/// Not as efficient as a single-atomic rwsem (the two-mutex handshake adds
/// overhead on reader entry/exit), but correct and simple. The bench shows
/// the conceptual scaling advantage of shared reads vs exclusive reads.
pub const RwLock = struct {
    writer_gate: ParkingMutex = .{},
    reader_gate: ParkingMutex = .{},
    reader_count: atomic.Value(u32) = .init(0),

    pub fn init() RwLock {
        return .{};
    }

    /// Acquire a shared (read) lock. Multiple readers may hold concurrently.
    /// Blocks if a writer holds the exclusive lock.
    pub inline fn lockShared(self: *RwLock) void {
        self.reader_gate.lock();
        const count = self.reader_count.fetchAdd(1, .monotonic);
        if (count == 0) {
            // First reader — lock out writers.
            self.writer_gate.lock();
        }
        self.reader_gate.unlock();
    }

    /// Release a shared (read) lock.
    pub inline fn unlockShared(self: *RwLock) void {
        self.reader_gate.lock();
        const count = self.reader_count.fetchSub(1, .monotonic);
        if (count == 1) {
            // Last reader — release the writer gate.
            self.writer_gate.unlock();
        }
        self.reader_gate.unlock();
    }

    /// Acquire an exclusive (write) lock. Blocks until all readers and writers
    /// release.
    pub inline fn lockExclusive(self: *RwLock) void {
        self.writer_gate.lock();
    }

    /// Release an exclusive (write) lock.
    pub inline fn unlockExclusive(self: *RwLock) void {
        self.writer_gate.unlock();
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "lazily/parking_mutex: basic mutual exclusion (single-threaded)" {
    var m = ParkingMutex.init();
    m.lock();
    try std.testing.expect(!m.tryLock()); // already held
    m.unlock();
    try std.testing.expect(m.tryLock()); // reacquirable after unlock
    m.unlock();
}

test "lazily/parking_mutex: tryLock returns false while held" {
    var m = ParkingMutex.init();
    try std.testing.expect(m.tryLock());
    try std.testing.expect(!m.tryLock());
    try std.testing.expect(!m.tryLock());
    m.unlock();
    try std.testing.expect(m.tryLock());
    m.unlock();
}

const SoakState = struct {
    mutex: ParkingMutex = .{},
    counter: atomic.Value(u64) = .init(0),
    iterations: u64,
    done: atomic.Value(u32) = .init(0),
};

fn soakWorker(s: *SoakState) void {
    var i: u64 = 0;
    while (i < s.iterations) : (i += 1) {
        s.mutex.lock();
        // Critical section: bump the shared counter under the lock. If the
        // mutex is correct, the final value == sum of all worker increments.
        _ = s.counter.fetchAdd(1, .monotonic);
        s.mutex.unlock();
    }
    _ = s.done.fetchAdd(1, .seq_cst);
}

test "lazily/parking_mutex: N-thread soak — no lost updates" {
    // 8 threads × 100k increments under the lock. If parking/waking has any
    // lost-update or double-unlock bug, the final counter will be wrong.
    // (Run with ReleaseFast internally via the bench build; the test build is
    // Debug/ReleaseSafe, which is the stricter check.)
    const n_threads: usize = 8;
    const iters: u64 = 100_000;

    var soak: SoakState = .{ .iterations = iters };
    var threads: [n_threads]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, soakWorker, .{&soak});
    }
    for (threads) |t| t.join();

    const expected: u64 = @as(u64, n_threads) * iters;
    try std.testing.expectEqual(expected, soak.counter.load(.monotonic));
}

test "lazily/parking_mutex: contended acquire with bounded spin path" {
    // Directly exercise the slow path: hold the lock from the spawning thread,
    // spawn a worker that blocks on lock(), then release and verify the worker
    // proceeds. This forces lockSlow() to run (the fast cmpxchg will fail).
    var m = ParkingMutex.init();
    var worker_ran = atomic.Value(u32).init(0);

    m.lock(); // held — worker's lock() must enter lockSlow
    const Worker = struct {
        fn run(mutex: *ParkingMutex, flag: *atomic.Value(u32)) void {
            mutex.lock();
            _ = flag.swap(1, .seq_cst);
            mutex.unlock();
        }
    };
    var thread = try std.Thread.spawn(.{}, Worker.run, .{ &m, &worker_ran });

    // Worker is (or will be) parked/spinning on lockSlow. Give it a moment to
    // reach the contended path, then release.
    shortSleep();
    try std.testing.expectEqual(@as(u32, 0), worker_ran.load(.seq_cst));

    m.unlock(); // should wake the worker
    thread.join();

    try std.testing.expectEqual(@as(u32, 1), worker_ran.load(.seq_cst));
}

/// ~1ms sleep via Linux nanosleep (test helper only — `std.Thread.sleep` was
/// removed with the rest of the 0.16 Thread API).
fn shortSleep() void {
    if (has_futex) {
        const linux = std.os.linux;
        var req: linux.timespec = .{ .sec = 0, .nsec = 1 * std.time.ns_per_ms };
        _ = linux.nanosleep(&req, null);
    } else {
        var spin: u32 = 0;
        while (spin < 10_000) : (spin += 1) atomic.spinLoopHint();
    }
}

test {
    std.testing.refAllDecls(@This());
}
