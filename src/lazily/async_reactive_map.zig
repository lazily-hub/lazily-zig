//! The async keyed reactive map (`AsyncReactiveMap`) — the async flavor of
//! `ReactiveMap` (`#reactivemap`, async), riding on [`AsyncContext(V)`](async_context.zig).
//!
//! Keys `K` map to per-entry async reactive nodes **allocated in a real
//! [`AsyncContext`]**:
//! - a **cell** entry is an [`AsyncContext.cell`] — always resolved;
//! - a **slot** entry is an [`AsyncContext.computedAsyncClosure`] — a genuine
//!   async slot that is **pending** until driven ([`drive`], the analog of
//!   `AsyncContext.get_async` / `settle`), then **resolved**. The per-key value
//!   is recovered by the slot's closure via a map-owned `slot_id → value` map,
//!   the capability the generic `AsyncContext` closure-userdata unlocks.
//!
//! There is **no eager/lazy mode flag** — eager = pre-mint loop
//! ([`materializeAll`]); lazy = mint-on-access ([`getOrInsertHandle`] /
//! [`getOrInsertWith`]).
//!
//! A non-blocking read returns `?V`: `null` while pending, `value` once
//! resolved. The transparency law weakens to **eventual transparency**: once a
//! node resolves, its observed value is the canonical value. Proved in
//! `lazily-formal`'s `AsyncMaterialization` module (`eventual_transparency`,
//! `observe_pending_is_none`, `cell_resolved_at_build`, `resolve_monotone`,
//! `resolve_preserves_observe`); mirrors lazily-rs `src/async_reactive_family.rs`.

const std = @import("std");
const async_context = @import("async_context.zig");
const AsyncContext = async_context.AsyncContext;
const reactive_map = @import("reactive_map.zig");

pub const EntryKind = reactive_map.EntryKind;
pub const Factory = reactive_map.Factory;

fn HashMapFor(comptime K: type, comptime V: type) type {
    if (K == []const u8) return std.StringHashMap(V);
    return std.AutoHashMap(K, V);
}

/// The async unified keyed reactive map (`#reactivemap`): keys `K` map to
/// per-entry async reactive nodes of the comptime-fixed [`EntryKind`] in an
/// [`AsyncContext(V)`].
pub fn AsyncReactiveMap(comptime K: type, comptime V: type, comptime entry_kind: EntryKind) type {
    return struct {
        /// The shared async reactive context every entry lives in.
        actx: *AsyncContext(V),
        /// Present set: key → its node id in `actx`. Grows on materialize.
        materialized: HashMapFor(K, u64),
        /// First-materialization order of the present set.
        order: std.ArrayList(K),
        /// For slot maps: slot node id → the canonical value its async compute
        /// resolves to (recovered by the closure via `cc.slot_id`).
        /// **Heap-allocated** so its address is stable across the by-value map
        /// move — the slot closure captures *this map*, never the reactive map,
        /// which relocates when `init` returns it. Empty for cell maps.
        slot_values: *SlotValues,
        allocator: std.mem.Allocator,

        const Self = @This();
        const SlotValues = std.AutoHashMap(u64, V);

        pub const kind: EntryKind = entry_kind;

        /// The closure a slot entry's async compute runs: recover this slot's
        /// canonical value by id from the stable heap map. Reads no cells →
        /// resolves to the value.
        fn slotCompute(ptr: *anyopaque, cc: *AsyncContext(V).ComputeContext) anyerror!V {
            const values: *SlotValues = @ptrCast(@alignCast(ptr));
            return values.get(cc.slot_id).?;
        }

        /// Create an empty map bound to `actx`.
        pub fn init(actx: *AsyncContext(V)) !Self {
            const values = try actx.allocator.create(SlotValues);
            values.* = SlotValues.init(actx.allocator);
            return Self{
                .actx = actx,
                .materialized = HashMapFor(K, u64).init(actx.allocator),
                .order = .empty,
                .slot_values = values,
                .allocator = actx.allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.order.deinit(self.allocator);
            self.materialized.deinit();
            self.slot_values.deinit();
            self.allocator.destroy(self.slot_values);
        }

        /// Allocate `key` if absent (present-set grows) with canonical `value`,
        /// returning its node id. A cell entry is an always-resolved async cell;
        /// a slot entry is a genuine async slot (pending until driven). Warm key →
        /// cached id.
        fn mint(self: *Self, key: K, value: V) !u64 {
            if (self.materialized.get(key)) |id| return id; // warm.
            const id = if (entry_kind == .cell)
                try self.actx.cell(value)
            else id: {
                const sid = try self.actx.computedAsyncClosure(self.slot_values, slotCompute);
                try self.slot_values.put(sid, value);
                break :id sid;
            };
            try self.materialized.put(key, id);
            try self.order.append(self.allocator, key);
            return id;
        }

        /// Allocate `key`'s node via `factory(key)` on first access (mint-on-access
        /// / lazy pull), returning its node id. A slot starts pending; drive it
        /// with [`drive`]. Warm key → cached id (factory not re-run).
        pub fn getOrInsertHandle(self: *Self, key: K, factory: Factory(K, V)) !u64 {
            if (self.materialized.get(key)) |id| return id; // warm.
            return self.mint(key, factory.call(key));
        }

        /// Allocate `key`'s node via `factory(key)` on first access, returning its
        /// current non-blocking observation: `null` while a freshly-allocated slot
        /// is pending, else the resolved `value`. A cell resolves at allocation.
        pub fn getOrInsertWith(self: *Self, key: K, factory: Factory(K, V)) !?V {
            const id = try self.getOrInsertHandle(key, factory);
            if (entry_kind == .cell) return self.actx.getCell(id);
            return self.actx.get(id);
        }

        /// Drive `key` to resolution — the analog of `get_async`: settle its async
        /// slot (or read its cell) and return the resolved value. The
        /// eventual-transparency completion. `key` must already be present
        /// (allocate first via [`getOrInsertHandle`] / [`materializeAll`] / `set`).
        pub fn drive(self: *Self, key: K) !V {
            const id = self.materialized.get(key).?;
            if (entry_kind == .cell) return self.actx.getCell(id).?;
            return self.actx.awaitResolved(id);
        }

        /// Non-blocking observe: `value` once resolved, `null` while pending or
        /// absent (`observe_pending_is_none`). Does not mint.
        pub fn observe(self: *Self, key: K) ?V {
            const id = self.materialized.get(key) orelse return null;
            if (entry_kind == .cell) return self.actx.getCell(id);
            return self.actx.get(id);
        }

        /// Overwrite an input **cell** entry (cells are writable, always
        /// resolved). Allocates the entry if absent. Compile error on a slot map.
        pub fn set(self: *Self, key: K, value: V) !void {
            if (entry_kind != .cell) @compileError("AsyncReactiveMap.set is only valid on cell (input) maps");
            const id = try self.mint(key, value);
            try self.actx.setCell(id, value);
        }

        /// **Eager materialization**: pre-mint a derived slot for every key in
        /// `all_keys` via `factory`, up front (each starts pending). Slot-only.
        pub fn materializeAll(self: *Self, all_keys: []const K, factory: Factory(K, V)) !void {
            if (entry_kind != .slot) @compileError("AsyncReactiveMap.materializeAll is only valid on slot (derived) maps");
            for (all_keys) |key| _ = try self.mint(key, factory.call(key));
        }

        /// Whether `key` is currently allocated (present). Non-reactive.
        pub fn isPresent(self: *Self, key: K) bool {
            return self.materialized.contains(key);
        }

        /// Whether `key` is allocated **and resolved** (a non-blocking observe
        /// would return a value).
        pub fn isResolved(self: *Self, key: K) bool {
            const id = self.materialized.get(key) orelse return false;
            if (entry_kind == .cell) return true;
            return self.actx.get(id) != null;
        }

        /// Number of currently-allocated entries.
        pub fn presentCount(self: *const Self) usize {
            return self.order.items.len;
        }

        /// The currently-allocated keys, in first-materialization order.
        pub fn presentKeys(self: *const Self) []const K {
            return self.order.items;
        }

        pub fn entryKind(self: *const Self) EntryKind {
            _ = self;
            return entry_kind;
        }
    };
}

/// An async **input-cell** map: every entry is an always-resolved async cell.
pub fn AsyncCellMap(comptime K: type, comptime V: type) type {
    return AsyncReactiveMap(K, V, .cell);
}

/// An async **derived-slot** map: `getOrInsertHandle` mints on first access
/// (lazy), [`materializeAll`](AsyncReactiveMap.materializeAll) pre-mints (eager);
/// resolved via [`drive`](AsyncReactiveMap.drive).
pub fn AsyncSlotMap(comptime K: type, comptime V: type) type {
    return AsyncReactiveMap(K, V, .slot);
}

// ---------------------------------------------------------------------------
// Tests — mirror lazily-rs `src/async_reactive_family.rs`, naming the
// `lazily-formal` AsyncMaterialization theorems each assertion rests on.
// ---------------------------------------------------------------------------

const testing = std.testing;

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

const SlotMapU32 = AsyncSlotMap(u32, u32);
const CellMapBool = AsyncCellMap(u32, bool);

test "lazily/async_reactive_map: eager cell map resolves immediately" {
    var actx = AsyncContext(bool).init(testing.allocator);
    defer actx.deinit();
    var map = try CellMapBool.init(&actx);
    defer map.deinit();
    for ([_]u32{ 1, 2, 3 }) |k| try map.set(k, true);

    try testing.expectEqual(EntryKind.cell, map.entryKind());
    try testing.expectEqual(@as(usize, 3), map.presentCount());
    try testing.expectEqual(@as(?bool, true), map.observe(2)); // cell_resolved_at_build
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, map.presentKeys());
}

test "lazily/async_reactive_map: lazy slot map defers until read then resolves" {
    var actx = AsyncContext(u32).init(testing.allocator);
    defer actx.deinit();
    var map = try SlotMapU32.init(&actx);
    defer map.deinit();

    try testing.expectEqual(@as(usize, 0), map.presentCount());
    // getOrInsertWith allocates the async slot (present) but it is pending → null.
    try testing.expectEqual(@as(?u32, null), try map.getOrInsertWith(4, Factory(u32, u32).pure(timesTen)));
    try testing.expect(map.isPresent(4));
    try testing.expect(!map.isResolved(4));
    try testing.expectEqual(@as(usize, 1), map.presentCount());
    // drive settles it → canonical value.
    try testing.expectEqual(@as(u32, 40), try map.drive(4));
    try testing.expect(map.isResolved(4));
    try testing.expectEqual(@as(?u32, 40), map.observe(4));
}

test "lazily/async_reactive_map: pending read is null (observe_pending_is_none)" {
    var actx = AsyncContext(u32).init(testing.allocator);
    defer actx.deinit();
    var map = try SlotMapU32.init(&actx);
    defer map.deinit();
    try map.materializeAll(&.{ 5, 6 }, Factory(u32, u32).pure(timesTwo));
    try testing.expectEqual(@as(usize, 2), map.presentCount());
    try testing.expectEqual(@as(?u32, null), map.observe(5)); // allocated but pending
    try testing.expectEqual(@as(u32, 10), try map.drive(5)); // eventual transparency
    try testing.expectEqual(@as(?u32, 10), map.observe(5));
}

test "lazily/async_reactive_map: eventual transparency eager == lazy" {
    var actx_e = AsyncContext(u32).init(testing.allocator);
    defer actx_e.deinit();
    var eager_map = try SlotMapU32.init(&actx_e);
    defer eager_map.deinit();
    try eager_map.materializeAll(&.{ 1, 2, 3 }, Factory(u32, u32).pure(timesTwo));
    var actx_l = AsyncContext(u32).init(testing.allocator);
    defer actx_l.deinit();
    var lazy_map = try SlotMapU32.init(&actx_l);
    defer lazy_map.deinit();
    for ([_]u32{ 1, 2, 3 }) |k| {
        _ = try lazy_map.getOrInsertHandle(k, Factory(u32, u32).pure(timesTwo));
        try testing.expectEqual(try eager_map.drive(k), try lazy_map.drive(k));
    }
}

test "lazily/async_reactive_map: present set grows monotonically" {
    var actx = AsyncContext(u32).init(testing.allocator);
    defer actx.deinit();
    var map = try SlotMapU32.init(&actx);
    defer map.deinit();
    _ = try map.getOrInsertHandle(5, Factory(u32, u32).pure(identity));
    _ = try map.getOrInsertHandle(5, Factory(u32, u32).pure(identity)); // repeat: no growth
    _ = try map.getOrInsertHandle(9, Factory(u32, u32).pure(identity));
    try testing.expectEqual(@as(usize, 2), map.presentCount());
    try testing.expectEqualSlices(u32, &.{ 5, 9 }, map.presentKeys());
}

test "lazily/async_reactive_map: cell map reacts to set" {
    var actx = AsyncContext(bool).init(testing.allocator);
    defer actx.deinit();
    var map = try CellMapBool.init(&actx);
    defer map.deinit();
    try map.set(10, true);
    try map.set(20, true);
    try testing.expectEqual(@as(?bool, true), map.observe(20));
    try map.set(20, false);
    try testing.expectEqual(@as(?bool, false), map.observe(20));
    _ = alwaysTrue; // referenced to keep helper parity with sibling flavors
}

test "lazily/async_reactive_map: resolving one node never disturbs another (no churn)" {
    var actx = AsyncContext(u32).init(testing.allocator);
    defer actx.deinit();
    var map = try SlotMapU32.init(&actx);
    defer map.deinit();
    try map.materializeAll(&.{ 1, 2 }, Factory(u32, u32).pure(timesTwo));
    try testing.expectEqual(@as(u32, 2), try map.drive(1));
    try testing.expectEqual(@as(u32, 4), try map.drive(2)); // resolve_preserves_observe
    try testing.expectEqual(@as(?u32, 2), map.observe(1));
}
