//! The thread-safe keyed reactive family (`ThreadSafeReactiveFamily`) — the
//! `Send + Sync` flavor of `ReactiveFamily` (`#lzmatmode`, thread-safe).
//!
//! Where [`ReactiveFamily`](reactive_family.zig) is a single-threaded keyed
//! value-cache over a comptime factory, this family guards its present-set state
//! (the materialized map + first-materialization order) behind a
//! [`ParkingMutex`](parking_mutex.zig), so a keyed family can live in an owner
//! shared across threads and serve `observe`/`get` from any thread with no
//! per-key locking of the value axis.
//!
//! It obeys the same three laws as the single-threaded family
//! (see `reactive_family.zig`):
//! - **Eager/lazy contract:** eager materializes every declared node at build;
//!   lazy defers derived (slot) nodes to first read. Cell entries are always
//!   materialized regardless of mode.
//! - **Observational transparency:** `observe(key)` returns an identical value
//!   under either mode.
//! - **Present-set monotonicity:** the materialized set only grows (deferral,
//!   never de-allocation).
//!
//! plus **materialization confluence**: the present set and every observed value
//! are independent of the order in which keys are materialized. A mutex admits a
//! concurrent workload as *some* sequential order of the per-key materializations;
//! confluence is what makes any such order observationally identical. Proved in
//! `lazily-formal`'s `Materialization` module (`materialize_present_comm` /
//! `materialize_observe_comm`); mirrors lazily-rs
//! `src/thread_safe_reactive_family.rs`.

const std = @import("std");
const ParkingMutex = @import("parking_mutex.zig").ParkingMutex;
const Context = @import("context.zig").Context;
const reactive_family = @import("reactive_family.zig");

pub const MaterializationMode = reactive_family.MaterializationMode;
pub const EntryKind = reactive_family.EntryKind;
pub const Factory = reactive_family.Factory;

/// Choose the right hash map implementation for key type K, mirroring
/// `reactive_family.zig`: `[]const u8` hashes content, everything else is auto.
fn HashMapFor(comptime K: type, comptime V: type) type {
    if (K == []const u8) return std.StringHashMap(V);
    return std.AutoHashMap(K, V);
}

/// The thread-safe unified keyed reactive family (`#lzmatmode`): keys `K` map to
/// per-entry reactive values of the comptime-fixed [`EntryKind`], allocated per
/// its [`MaterializationMode`], with all present-set mutation serialized by an
/// internal [`ParkingMutex`].
///
/// The mutex lives inline; once a family is built its address is stable, so
/// concurrent readers may share a `*Self`. See the module docs for the
/// eager/lazy contract, observational transparency, present-set monotonicity,
/// and materialization confluence.
pub fn ThreadSafeReactiveFamily(comptime K: type, comptime V: type, comptime entry_kind: EntryKind) type {
    return struct {
        /// Owning context (its allocator backs the present-set storage).
        ctx: *Context,
        /// This family's materialization mode (immutable after build).
        mode: MaterializationMode,
        /// Canonical per-key value producer (a pure factory — no captured
        /// context reads, so it needs no lock of its own).
        factory: Factory(K, V),
        /// Currently-allocated entries (the "present" set) and their cached
        /// value. Guarded by `mutex`; grows on materialize, never shrinks.
        materialized: HashMapFor(K, V),
        /// First-materialization order of the present set. Guarded by `mutex`.
        order: std.ArrayList(K),
        allocator: std.mem.Allocator,
        /// Serializes every present-set access. The confluence proof is what
        /// lets one lock guard the whole value axis.
        mutex: ParkingMutex,

        const Self = @This();

        /// This family's entry kind (comptime).
        pub const kind: EntryKind = entry_kind;

        fn build(
            ctx: *Context,
            mode: MaterializationMode,
            keys: []const K,
            factory: Factory(K, V),
        ) !Self {
            var self = Self{
                .ctx = ctx,
                .mode = mode,
                .factory = factory,
                .materialized = HashMapFor(K, V).init(ctx.allocator),
                .order = .empty,
                .allocator = ctx.allocator,
                .mutex = ParkingMutex.init(),
            };
            for (keys) |key| {
                // A cell entry is always materialized regardless of mode; a slot
                // entry only under eager. (No lock needed at build: no other
                // thread can observe the family before it is returned.)
                if (entry_kind == .cell or mode == .eager) {
                    try self.materializeKeyLocked(key);
                }
            }
            return self;
        }

        /// Build an **eager** family: every declared key's node is allocated now
        /// ([`MaterializationMode.eager`], the default).
        pub fn eager(ctx: *Context, keys: []const K, factory: Factory(K, V)) !Self {
            return build(ctx, .eager, keys, factory);
        }

        /// Build a **lazy** family: derived (slot) entries are deferred to first
        /// read; input (cell) entries in `keys` are still materialized at build.
        pub fn lazy(ctx: *Context, keys: []const K, factory: Factory(K, V)) !Self {
            return build(ctx, .lazy, keys, factory);
        }

        /// Build a family in the **default** mode (eager). Alias for [`eager`].
        pub fn new(ctx: *Context, keys: []const K, factory: Factory(K, V)) !Self {
            return eager(ctx, keys, factory);
        }

        pub fn deinit(self: *Self) void {
            self.order.deinit(self.allocator);
            self.materialized.deinit();
        }

        /// Materialize `key` if absent, caching its canonical value and recording
        /// first-materialization order. Caller MUST hold `mutex` (or be building).
        /// A warm key is a no-op — the present set only grows.
        fn materializeKeyLocked(self: *Self, key: K) !void {
            if (self.materialized.contains(key)) return; // warm: already allocated.
            const value = self.factory.call(key);
            try self.materialized.put(key, value);
            try self.order.append(self.allocator, key);
        }

        /// Get `key`'s value, materializing it on first access (the lazy pull)
        /// under the lock. Under eager an entry is already present.
        pub fn get(self: *Self, key: K) !V {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.materializeKeyLocked(key);
            return self.materialized.get(key).?;
        }

        /// Observe `key`'s value — the transparency law: identical under either
        /// mode. Materializes the entry if absent.
        pub fn observe(self: *Self, key: K) !V {
            return self.get(key);
        }

        /// Overwrite an input **cell** entry's value (cells are writable inputs).
        /// Materializes the entry if absent, then caches the new value without
        /// re-ordering. Compile error on a slot family.
        pub fn set(self: *Self, key: K, value: V) !void {
            if (entry_kind != .cell) @compileError("ThreadSafeReactiveFamily.set is only valid on cell (input) families");
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.materializeKeyLocked(key);
            try self.materialized.put(key, value);
        }

        /// Whether `key` is currently materialized (present). Non-reactive.
        pub fn isPresent(self: *Self, key: K) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.materialized.contains(key);
        }

        /// Number of currently-materialized entries.
        pub fn presentCount(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.order.items.len;
        }

        /// A stable snapshot of the currently-materialized keys, in
        /// first-materialization order. Returns an owned slice the caller frees
        /// with `allocator` — the internal `order` must not escape the lock (a
        /// concurrent materialize could reallocate it). The present set only
        /// grows (deferral, not de-allocation).
        pub fn presentKeys(self: *Self, allocator: std.mem.Allocator) ![]K {
            self.mutex.lock();
            defer self.mutex.unlock();
            return allocator.dupe(K, self.order.items);
        }

        /// This family's entry kind.
        pub fn entryKind(self: *Self) EntryKind {
            _ = self;
            return entry_kind;
        }
    };
}

/// A thread-safe **input-cell** family: every entry is an always-materialized
/// cell value. The `Send + Sync` analog of `CellFamily`.
pub fn ThreadSafeCellFamily(comptime K: type, comptime V: type) type {
    return ThreadSafeReactiveFamily(K, V, .cell);
}

/// A thread-safe **derived-slot** family: entries are governed by the family's
/// [`MaterializationMode`].
pub fn ThreadSafeSlotFamily(comptime K: type, comptime V: type) type {
    return ThreadSafeReactiveFamily(K, V, .slot);
}

// ---------------------------------------------------------------------------
// Tests — mirror lazily-rs `src/thread_safe_reactive_family.rs`, which names the
// `lazily-formal` Materialization theorems (incl. the confluence pair) each
// assertion rests on.
// ---------------------------------------------------------------------------

const testing = std.testing;
const builtin = @import("builtin");

fn timesTwo(k: u32) u32 {
    return k * 2;
}

fn timesTen(k: u32) u32 {
    return k * 10;
}

fn alwaysTrue(_: u32) bool {
    return true;
}

fn identity(k: u32) u32 {
    return k;
}

const SlotFam = ThreadSafeSlotFamily(u32, u32);
const CellFamBool = ThreadSafeCellFamily(u32, bool);

test "lazily/thread_safe_reactive_family: default mode is eager" {
    try testing.expectEqual(MaterializationMode.eager, MaterializationMode.default());
}

test "lazily/thread_safe_reactive_family: eager cell family materializes all at build" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var fam = try CellFamBool.eager(ctx, &.{ 1, 2, 3 }, Factory(u32, bool).pure(alwaysTrue));
    defer fam.deinit();

    try testing.expectEqual(EntryKind.cell, fam.entryKind());
    try testing.expectEqual(MaterializationMode.eager, fam.mode);
    try testing.expectEqual(@as(usize, 3), fam.presentCount());
    try testing.expect(fam.isPresent(1) and fam.isPresent(2) and fam.isPresent(3));

    const keys = try fam.presentKeys(testing.allocator);
    defer testing.allocator.free(keys);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, keys);
}

test "lazily/thread_safe_reactive_family: lazy slot family defers until read" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var fam = try SlotFam.lazy(ctx, &.{}, Factory(u32, u32).pure(timesTen));
    defer fam.deinit();

    try testing.expectEqual(MaterializationMode.lazy, fam.mode);
    try testing.expectEqual(@as(usize, 0), fam.presentCount());
    try testing.expect(!fam.isPresent(2));
    try testing.expectEqual(@as(u32, 20), try fam.observe(2));
    try testing.expect(fam.isPresent(2));
    try testing.expectEqual(@as(usize, 1), fam.presentCount());
}

test "lazily/thread_safe_reactive_family: lazy cell entries still materialize at build" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var fam = try CellFamBool.lazy(ctx, &.{ 7, 8 }, Factory(u32, bool).pure(alwaysTrue));
    defer fam.deinit();
    try testing.expectEqual(@as(usize, 2), fam.presentCount());
}

test "lazily/thread_safe_reactive_family: observational transparency eager == lazy" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var eager_fam = try SlotFam.eager(ctx, &.{ 1, 2, 3 }, Factory(u32, u32).pure(timesTwo));
    defer eager_fam.deinit();
    var lazy_fam = try SlotFam.lazy(ctx, &.{ 1, 2, 3 }, Factory(u32, u32).pure(timesTwo));
    defer lazy_fam.deinit();
    for ([_]u32{ 1, 2, 3 }) |k| {
        try testing.expectEqual(try eager_fam.observe(k), try lazy_fam.observe(k));
    }
}

test "lazily/thread_safe_reactive_family: present set grows monotonically" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var fam = try SlotFam.lazy(ctx, &.{}, Factory(u32, u32).pure(identity));
    defer fam.deinit();
    _ = try fam.observe(5);
    _ = try fam.observe(5); // repeat: no growth
    _ = try fam.observe(9);
    try testing.expectEqual(@as(usize, 2), fam.presentCount());
    const keys = try fam.presentKeys(testing.allocator);
    defer testing.allocator.free(keys);
    try testing.expectEqualSlices(u32, &.{ 5, 9 }, keys);
}

test "lazily/thread_safe_reactive_family: cell family set overwrites value in place" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var fam = try CellFamBool.eager(ctx, &.{ 10, 20 }, Factory(u32, bool).pure(alwaysTrue));
    defer fam.deinit();
    try testing.expectEqual(true, try fam.observe(20));
    try fam.set(20, false);
    try testing.expectEqual(false, try fam.observe(20));
    // present count unchanged (no re-order, no new key).
    try testing.expectEqual(@as(usize, 2), fam.presentCount());
}

// Confluence soak: N threads materialize an overlapping key space concurrently.
// The present SET and every observed value must be independent of interleaving
// (materialize_present_comm / materialize_observe_comm). Only meaningful when
// the build links threading; guard on single-threaded targets.
const Soak = struct {
    fam: *SlotFam,
    lo: u32,
    hi: u32,

    fn run(self: Soak) void {
        var k = self.lo;
        while (k < self.hi) : (k += 1) {
            // Observe twice + out of order to stress the "first writer wins /
            // warm read" path under contention.
            _ = self.fam.observe(k) catch unreachable;
            _ = self.fam.observe((self.hi - 1) - (k - self.lo)) catch unreachable;
        }
    }
};

test "lazily/thread_safe_reactive_family: concurrent materialization is confluent" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var fam = try SlotFam.lazy(ctx, &.{}, Factory(u32, u32).pure(timesTwo));
    defer fam.deinit();

    const N = 4;
    const span: u32 = 50; // total distinct keys 0..200, threads overlap at edges
    var threads: [N]std.Thread = undefined;
    for (0..N) |i| {
        const lo: u32 = @intCast(i * span);
        threads[i] = try std.Thread.spawn(.{}, Soak.run, .{Soak{ .fam = &fam, .lo = lo, .hi = lo + span }});
    }
    for (threads) |t| t.join();

    // Present set is exactly the union 0..N*span, order-independent.
    try testing.expectEqual(@as(usize, N * span), fam.presentCount());
    var k: u32 = 0;
    while (k < N * span) : (k += 1) {
        try testing.expect(fam.isPresent(k));
        // Observed value is the canonical factory value regardless of which
        // thread materialized it first.
        try testing.expectEqual(k * 2, try fam.observe(k));
    }
}
