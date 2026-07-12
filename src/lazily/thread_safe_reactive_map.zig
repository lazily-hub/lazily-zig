//! The thread-safe keyed reactive map (`ThreadSafeReactiveMap`) — the
//! `Send + Sync` flavor of `ReactiveMap` (`#reactivemap`, thread-safe).
//!
//! Where [`ReactiveMap`](reactive_map.zig) is a single-threaded keyed
//! reactive collection, this map guards its present-set state (the materialized
//! map + first-materialization order) behind a [`ParkingMutex`](parking_mutex.zig),
//! so a keyed map can live in an owner shared across threads and serve
//! `observe`/`getOrInsertWith` from any thread with no per-key locking of the
//! value axis.
//!
//! Two specializations mirror the single-threaded core:
//! - **[`ThreadSafeCellMap`]** — input cells; adds cell-only `set`.
//! - **[`ThreadSafeSlotMap`]** — derived slots; `getOrInsertWith` mints on first
//!   access (lazy), [`materializeAll`] pre-mints (eager). There is **no
//!   eager/lazy mode flag** — eager = pre-mint, lazy = mint-on-access.
//!
//! It obeys the same laws as the single-threaded map:
//! - **Observational transparency:** `observe(key)` returns an identical value
//!   whether the key was pre-minted (eager) or minted on access (lazy).
//! - **Present-set monotonicity:** the materialized set only grows.
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
const tsc = @import("thread_safe_context.zig");
const ThreadSafeContext = tsc.ThreadSafeContext;
const TsHandle = tsc.TsHandle;
const reactive_map = @import("reactive_map.zig");

pub const EntryKind = reactive_map.EntryKind;
pub const Factory = reactive_map.Factory;

/// Choose the right hash map implementation for key type K, mirroring
/// `reactive_map.zig`: `[]const u8` hashes content, everything else is auto.
fn HashMapFor(comptime K: type, comptime V: type) type {
    if (K == []const u8) return std.StringHashMap(V);
    return std.AutoHashMap(K, V);
}

/// The thread-safe unified keyed reactive map (`#reactivemap`): keys `K` map to
/// per-entry reactive cells of the comptime-fixed [`EntryKind`], with all
/// present-set mutation serialized by an internal [`ParkingMutex`].
///
/// The mutex lives inline; once a map is built its address is stable, so
/// concurrent readers may share a `*Self`. See the module docs for observational
/// transparency, present-set monotonicity, and materialization confluence.
pub fn ThreadSafeReactiveMap(comptime K: type, comptime V: type, comptime entry_kind: EntryKind) type {
    return struct {
        /// The shared reactive context every entry's cell lives in — the map
        /// rides on it (its thread-safety derives from the context + the
        /// present-set `mutex`, exactly like lazily-rs `ThreadSafeReactiveMap`
        /// over `ThreadSafeContext`).
        tsctx: *ThreadSafeContext,
        /// Present set: key → the handle of its reactive cell in `tsctx`.
        /// Guarded by `mutex`; grows on materialize, never shrinks.
        materialized: HashMapFor(K, TsHandle(V)),
        /// First-materialization order of the present set. Guarded by `mutex`.
        order: std.ArrayList(K),
        allocator: std.mem.Allocator,
        /// Serializes the present-set map (`tsctx` serializes the cells). The
        /// confluence proof is what lets one lock guard the whole value axis.
        mutex: ParkingMutex,

        const Self = @This();

        /// This map's entry kind (comptime).
        pub const kind: EntryKind = entry_kind;

        /// Create an empty map bound to `tsctx`.
        pub fn init(tsctx: *ThreadSafeContext) Self {
            return .{
                .tsctx = tsctx,
                .materialized = HashMapFor(K, TsHandle(V)).init(tsctx.allocator),
                .order = .empty,
                .allocator = tsctx.allocator,
                .mutex = ParkingMutex.init(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.order.deinit(self.allocator);
            self.materialized.deinit();
        }

        /// Materialize `key` if absent: allocate a real reactive cell in `tsctx`
        /// seeded with `value`, record it + first-materialization order, and
        /// return its handle. Caller MUST hold `mutex`. A warm key returns the
        /// cached handle — the present set only grows.
        fn mintLocked(self: *Self, key: K, value: V) !TsHandle(V) {
            if (self.materialized.get(key)) |h| return h; // warm.
            const handle = try self.tsctx.cell(V, value);
            try self.materialized.put(key, handle);
            try self.order.append(self.allocator, key);
            return handle;
        }

        /// Get `key`'s value, minting its cell via `factory(key)` on first access
        /// (the mint-on-access recipe / lazy pull) under the lock.
        pub fn getOrInsertWith(self: *Self, key: K, factory: Factory(K, V)) !V {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.materialized.get(key)) |h| return self.tsctx.getCell(V, h); // warm.
            const handle = try self.mintLocked(key, factory.call(key));
            return self.tsctx.getCell(V, handle);
        }

        /// Non-blocking read: `value` if present, else `null`. Does not mint.
        pub fn observe(self: *Self, key: K) ?V {
            self.mutex.lock();
            defer self.mutex.unlock();
            const handle = self.materialized.get(key) orelse return null;
            return self.tsctx.getCell(V, handle);
        }

        /// Overwrite an input **cell** entry's value (cells are writable inputs)
        /// through the reactive context, so dependents recompute. Inserts a new
        /// entry if absent. Compile error on a slot map.
        pub fn set(self: *Self, key: K, value: V) !void {
            if (entry_kind != .cell) @compileError("ThreadSafeReactiveMap.set is only valid on cell (input) maps");
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.materialized.get(key)) |h| {
                self.tsctx.setCell(V, h, value);
                return;
            }
            _ = try self.mintLocked(key, value);
        }

        /// **Eager materialization**: pre-mint a derived slot for every key in
        /// `all_keys` via `factory`, up front. Slot-only.
        pub fn materializeAll(self: *Self, all_keys: []const K, factory: Factory(K, V)) !void {
            if (entry_kind != .slot) @compileError("ThreadSafeReactiveMap.materializeAll is only valid on slot (derived) maps");
            self.mutex.lock();
            defer self.mutex.unlock();
            for (all_keys) |key| _ = try self.mintLocked(key, factory.call(key));
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

        /// This map's entry kind.
        pub fn entryKind(self: *Self) EntryKind {
            _ = self;
            return entry_kind;
        }
    };
}

/// A thread-safe **input-cell** map: every entry is a settable reactive cell.
pub fn ThreadSafeCellMap(comptime K: type, comptime V: type) type {
    return ThreadSafeReactiveMap(K, V, .cell);
}

/// A thread-safe **derived-slot** map: `getOrInsertWith` mints on first access
/// (lazy), [`materializeAll`](ThreadSafeReactiveMap.materializeAll) pre-mints
/// (eager).
pub fn ThreadSafeSlotMap(comptime K: type, comptime V: type) type {
    return ThreadSafeReactiveMap(K, V, .slot);
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

fn identity(k: u32) u32 {
    return k;
}

const SlotMapU32 = ThreadSafeSlotMap(u32, u32);
const CellMapBool = ThreadSafeCellMap(u32, bool);

test "lazily/thread_safe_reactive_map: eager cell map materializes all via set" {
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();
    var map = CellMapBool.init(&ctx);
    defer map.deinit();
    for ([_]u32{ 1, 2, 3 }) |k| try map.set(k, true);

    try testing.expectEqual(EntryKind.cell, map.entryKind());
    try testing.expectEqual(@as(usize, 3), map.presentCount());
    try testing.expect(map.isPresent(1) and map.isPresent(2) and map.isPresent(3));

    const keys = try map.presentKeys(testing.allocator);
    defer testing.allocator.free(keys);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, keys);
}

test "lazily/thread_safe_reactive_map: lazy slot map defers until read" {
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();
    var map = SlotMapU32.init(&ctx);
    defer map.deinit();

    try testing.expectEqual(@as(usize, 0), map.presentCount());
    try testing.expect(!map.isPresent(2));
    try testing.expectEqual(@as(?u32, null), map.observe(2));
    try testing.expectEqual(@as(u32, 20), try map.getOrInsertWith(2, Factory(u32, u32).pure(timesTen)));
    try testing.expect(map.isPresent(2));
    try testing.expectEqual(@as(usize, 1), map.presentCount());
}

test "lazily/thread_safe_reactive_map: eager materializeAll materializes all at build" {
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();
    var map = SlotMapU32.init(&ctx);
    defer map.deinit();
    try map.materializeAll(&.{ 7, 8 }, Factory(u32, u32).pure(timesTen));
    try testing.expectEqual(@as(usize, 2), map.presentCount());
}

test "lazily/thread_safe_reactive_map: observational transparency eager == lazy" {
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();
    var eager_map = SlotMapU32.init(&ctx);
    defer eager_map.deinit();
    try eager_map.materializeAll(&.{ 1, 2, 3 }, Factory(u32, u32).pure(timesTwo));
    var lazy_map = SlotMapU32.init(&ctx);
    defer lazy_map.deinit();
    for ([_]u32{ 1, 2, 3 }) |k| {
        try testing.expectEqual(eager_map.observe(k).?, try lazy_map.getOrInsertWith(k, Factory(u32, u32).pure(timesTwo)));
    }
}

test "lazily/thread_safe_reactive_map: present set grows monotonically" {
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();
    var map = SlotMapU32.init(&ctx);
    defer map.deinit();
    _ = try map.getOrInsertWith(5, Factory(u32, u32).pure(identity));
    _ = try map.getOrInsertWith(5, Factory(u32, u32).pure(identity)); // repeat: no growth
    _ = try map.getOrInsertWith(9, Factory(u32, u32).pure(identity));
    try testing.expectEqual(@as(usize, 2), map.presentCount());
    const keys = try map.presentKeys(testing.allocator);
    defer testing.allocator.free(keys);
    try testing.expectEqualSlices(u32, &.{ 5, 9 }, keys);
}

test "lazily/thread_safe_reactive_map: cell map set overwrites value in place" {
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();
    var map = CellMapBool.init(&ctx);
    defer map.deinit();
    try map.set(10, true);
    try map.set(20, true);
    try testing.expectEqual(@as(?bool, true), map.observe(20));
    try map.set(20, false);
    try testing.expectEqual(@as(?bool, false), map.observe(20));
    // present count unchanged (no re-order, no new key).
    try testing.expectEqual(@as(usize, 2), map.presentCount());
}

// Confluence soak: N threads materialize an overlapping key space concurrently.
// The present SET and every observed value must be independent of interleaving
// (materialize_present_comm / materialize_observe_comm). Only meaningful when
// the build links threading; guard on single-threaded targets.
const Soak = struct {
    map: *SlotMapU32,
    lo: u32,
    hi: u32,

    fn run(self: Soak) void {
        var k = self.lo;
        while (k < self.hi) : (k += 1) {
            // Observe twice + out of order to stress the "first writer wins /
            // warm read" path under contention.
            _ = self.map.getOrInsertWith(k, Factory(u32, u32).pure(timesTwo)) catch unreachable;
            _ = self.map.getOrInsertWith((self.hi - 1) - (k - self.lo), Factory(u32, u32).pure(timesTwo)) catch unreachable;
        }
    }
};

test "lazily/thread_safe_reactive_map: concurrent materialization is confluent" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();
    var map = SlotMapU32.init(&ctx);
    defer map.deinit();

    const N = 4;
    const span: u32 = 50; // total distinct keys 0..200, threads overlap at edges
    var threads: [N]std.Thread = undefined;
    for (0..N) |i| {
        const lo: u32 = @intCast(i * span);
        threads[i] = try std.Thread.spawn(.{}, Soak.run, .{Soak{ .map = &map, .lo = lo, .hi = lo + span }});
    }
    for (threads) |t| t.join();

    // Present set is exactly the union 0..N*span, order-independent.
    try testing.expectEqual(@as(usize, N * span), map.presentCount());
    var k: u32 = 0;
    while (k < N * span) : (k += 1) {
        try testing.expect(map.isPresent(k));
        // Observed value is the canonical factory value regardless of which
        // thread materialized it first.
        try testing.expectEqual(k * 2, map.observe(k).?);
    }
}
