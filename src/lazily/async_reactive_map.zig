//! The async keyed reactive map (`AsyncReactiveMap`) — the async flavor of
//! `ReactiveMap` (`#reactivemap`, async), riding on [`AsyncContext(V)`](async_context.zig).
//!
//! Keys `K` map to per-entry async reactive nodes **allocated in a real
//! [`AsyncContext`]**:
//! - a **source** entry is an [`AsyncContext.source`] — always resolved;
//! - a **computed** entry is an [`AsyncContext.computedClosure`] — a genuine
//!   async computed that is **pending** until driven ([`drive`], the analog of
//!   `AsyncContext.get_async` / `settle`), then **resolved**. The per-key value
//!   is recovered by the computed's closure via a map-owned `id → value` map,
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
const AsyncComputed = async_context.AsyncComputed;
const AsyncSource = async_context.AsyncSource;
const reactive_map = @import("reactive_map.zig");
const keyed_order = @import("keyed_order.zig");
const KeyedOrder = keyed_order.KeyedOrder;
const Move = keyed_order.Move;

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
        /// Present set + authoritative order + the move algebra, shared verbatim
        /// with the single-threaded and thread-safe flavors.
        core: KeyedOrder(K, EntryHandle),
        /// For computed maps: node id → the canonical value its async compute
        /// resolves to (recovered by the closure via `cc.slot_id`).
        /// **Heap-allocated** so its address is stable across the by-value map
        /// move — the slot closure captures *this map*, never the reactive map,
        /// which relocates when `init` returns it. Empty for cell maps.
        slot_values: *SlotValues,
        allocator: std.mem.Allocator,
        /// Membership version — bumped on add/remove only.
        membership_version: u64 = 0,
        /// Order version — bumped on add/remove **and** move/reorder.
        order_version: u64 = 0,

        const Self = @This();
        const EntryHandle = if (entry_kind == .source) AsyncSource(V) else AsyncComputed(V);
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
                .core = KeyedOrder(K, EntryHandle).init(actx.allocator),
                .slot_values = values,
                .allocator = actx.allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.core.deinit();
            self.slot_values.deinit();
            self.allocator.destroy(self.slot_values);
        }

        /// Allocate `key` if absent (present-set grows) with canonical `value`,
        /// returning its canonical handle. A source is always resolved; a
        /// computed is pending until driven. Warm key → cached handle.
        fn mint(self: *Self, key: K, value: V) !EntryHandle {
            if (self.core.get(key)) |entry_handle| return entry_handle; // warm.
            const entry_handle: EntryHandle = if (entry_kind == .source)
                try self.actx.source(value)
            else computed: {
                const derived = try self.actx.computedClosure(self.slot_values, slotCompute);
                try self.slot_values.put(derived.id, value);
                break :computed derived;
            };
            const res = try self.core.insert(key, entry_handle);
            if (res.mutation == .changed) {
                self.membership_version += 1;
                self.order_version += 1;
            }
            return res.handle;
        }

        /// Allocate `key`'s node via `factory(key)` on first access (mint-on-access
        /// / lazy pull), returning its node id. A slot starts pending; drive it
        /// with [`drive`]. Warm key → cached id (factory not re-run).
        pub fn getOrInsertHandle(self: *Self, key: K, factory: Factory(K, V)) !EntryHandle {
            if (self.core.get(key)) |entry_handle| return entry_handle; // warm.
            return self.mint(key, factory.call(key));
        }

        /// Allocate `key`'s node via `factory(key)` on first access, returning its
        /// current non-blocking observation: `null` while a freshly-allocated slot
        /// is pending, else the resolved `value`. A cell resolves at allocation.
        pub fn getOrInsertWith(self: *Self, key: K, factory: Factory(K, V)) !?V {
            const entry_handle = try self.getOrInsertHandle(key, factory);
            if (entry_kind == .source) return try self.actx.getSource(entry_handle);
            return try self.actx.getComputed(entry_handle);
        }

        /// Drive `key` to resolution — the analog of `get_async`: settle its async
        /// slot (or read its cell) and return the resolved value. The
        /// eventual-transparency completion. `key` must already be present
        /// (allocate first via [`getOrInsertHandle`] / [`materializeAll`] / `set`).
        pub fn drive(self: *Self, key: K) !V {
            const entry_handle = self.core.get(key).?;
            if (entry_kind == .source) return self.actx.getSource(entry_handle);
            return self.actx.awaitComputed(entry_handle);
        }

        /// Non-blocking observe: `value` once resolved, `null` while pending or
        /// absent (`observe_pending_is_none`). Does not mint.
        pub fn observe(self: *Self, key: K) ?V {
            const entry_handle = self.core.get(key) orelse return null;
            if (entry_kind == .source) return self.actx.getSource(entry_handle) catch null;
            return self.actx.getComputed(entry_handle) catch null;
        }

        /// Overwrite an input **cell** entry (cells are writable, always
        /// resolved). Allocates the entry if absent. Compile error on a slot map.
        pub fn set(self: *Self, key: K, value: V) !void {
            if (entry_kind != .source) @compileError("AsyncReactiveMap.set is only valid on cell (input) maps");
            const entry_handle = try self.mint(key, value);
            try self.actx.setSource(entry_handle, value);
        }

        /// **Eager materialization**: pre-mint a derived slot for every key in
        /// `all_keys` via `factory`, up front (each starts pending). Slot-only.
        pub fn materializeAll(self: *Self, all_keys: []const K, factory: Factory(K, V)) !void {
            if (entry_kind != .computed) @compileError("AsyncReactiveMap.materializeAll is only valid on slot (derived) maps");
            for (all_keys) |key| _ = try self.mint(key, factory.call(key));
        }

        /// Whether `key` is currently allocated (present). Non-reactive.
        pub fn isPresent(self: *Self, key: K) bool {
            return self.core.contains(key);
        }

        /// Whether `key` is allocated **and resolved** (a non-blocking observe
        /// would return a value).
        pub fn isResolved(self: *Self, key: K) bool {
            const entry_handle = self.core.get(key) orelse return false;
            if (entry_kind == .source) return true;
            return (self.actx.getComputed(entry_handle) catch null) != null;
        }

        /// Number of currently-allocated entries.
        pub fn presentCount(self: *const Self) usize {
            return self.core.len();
        }

        /// The currently-allocated keys, in first-materialization order.
        pub fn presentKeys(self: *const Self) []const K {
            return self.core.keys();
        }

        /// Reactive snapshot of the keys in their current order.
        pub fn keys(self: *const Self) []const K {
            return self.core.keys();
        }

        /// Reactive entry count. Membership readers subscribe here.
        pub fn len(self: *const Self) usize {
            return self.core.len();
        }

        /// Reactive membership test for `key`.
        pub fn containsKey(self: *const Self, key: K) bool {
            return self.core.contains(key);
        }

        /// The entry's canonical handle for `key`, or `null`. Non-minting.
        ///
        /// Core surface: the atomic-move law is stated in terms of handle
        /// stability, so it is unassertable without this.
        pub fn handle(self: *const Self, key: K) ?EntryHandle {
            return self.core.get(key);
        }

        /// Current 0-based position of `key` in the order, or `null` if absent.
        pub fn position(self: *const Self, key: K) ?usize {
            return self.core.position(key);
        }

        /// Remove `key`'s entry, disposing its node. Bumps membership + order.
        pub fn remove(self: *Self, key: K) bool {
            const res = self.core.remove(key);
            const handle_value = res.handle orelse return false;
            if (entry_kind == .source) {
                self.actx.disposeSource(handle_value) catch return false;
            } else {
                self.actx.disposeComputed(handle_value) catch return false;
                _ = self.slot_values.remove(handle_value.id);
            }
            self.membership_version += 1;
            self.order_version += 1;
            return true;
        }

        /// Current membership version (bumped on add/remove).
        pub fn membershipVersion(self: *const Self) u64 {
            return self.membership_version;
        }

        /// Current order version (bumped on add/remove and reorder).
        pub fn orderVersion(self: *const Self) u64 {
            return self.order_version;
        }

        // --- atomic move (order signal only; not async-coloured) ---

        /// Atomically move `key` to absolute `index`. The entry keeps the same
        /// node, dependents, and lineage; only the order version is bumped.
        ///
        /// Ordering awaits nothing and touches no entry node, so it is the same
        /// synchronous algebra the other two flavors run.
        pub fn moveTo(self: *Self, key: K, index: usize) bool {
            return self.settleMove(self.core.moveTo(key, index));
        }

        /// Atomically move `key` to sit immediately **before** `before_key`.
        pub fn moveBefore(self: *Self, key: K, before_key: K) bool {
            return self.settleMove(self.core.moveBefore(key, before_key));
        }

        /// Atomically move `key` to sit immediately **after** `after_key`.
        pub fn moveAfter(self: *Self, key: K, after_key: K) bool {
            return self.settleMove(self.core.moveAfter(key, after_key));
        }

        fn settleMove(self: *Self, outcome: Move) bool {
            if (outcome.changed()) self.order_version += 1;
            return outcome.isPresent();
        }

        pub fn entryKind(self: *const Self) EntryKind {
            _ = self;
            return entry_kind;
        }
    };
}

/// An async **input-cell** map: every entry is an always-resolved async cell.
pub fn AsyncSourceMap(comptime K: type, comptime V: type) type {
    return AsyncReactiveMap(K, V, .source);
}

/// An async **derived-slot** map: `getOrInsertHandle` mints on first access
/// (lazy), [`materializeAll`](AsyncReactiveMap.materializeAll) pre-mints (eager);
/// resolved via [`drive`](AsyncReactiveMap.drive).
pub fn AsyncComputedMap(comptime K: type, comptime V: type) type {
    return AsyncReactiveMap(K, V, .computed);
}

/// Deprecated: renamed to [`AsyncSourceMap`] when the v2 kernel renamed the node
/// kinds to `Source` / `Computed`. Kept as an alias so existing callers keep
/// compiling; use `AsyncSourceMap` in new code.
pub const AsyncCellMap = AsyncSourceMap;

/// Deprecated: renamed to [`AsyncComputedMap`] when the v2 kernel renamed the
/// node kinds to `Source` / `Computed`. Kept as an alias so existing callers
/// keep compiling; use `AsyncComputedMap` in new code.
pub const AsyncSlotMap = AsyncComputedMap;

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

const ComputedMapU32 = AsyncComputedMap(u32, u32);
const SourceMapBool = AsyncSourceMap(u32, bool);

test "lazily/async_reactive_map: eager cell map resolves immediately" {
    var actx = AsyncContext(bool).init(testing.allocator);
    defer actx.deinit();
    var map = try SourceMapBool.init(&actx);
    defer map.deinit();
    for ([_]u32{ 1, 2, 3 }) |k| try map.set(k, true);

    try testing.expectEqual(EntryKind.source, map.entryKind());
    try testing.expectEqual(@as(usize, 3), map.presentCount());
    try testing.expectEqual(@as(?bool, true), map.observe(2)); // cell_resolved_at_build
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, map.presentKeys());
}

test "lazily/async_reactive_map: lazy slot map defers until read then resolves" {
    var actx = AsyncContext(u32).init(testing.allocator);
    defer actx.deinit();
    var map = try ComputedMapU32.init(&actx);
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
    var map = try ComputedMapU32.init(&actx);
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
    var eager_map = try ComputedMapU32.init(&actx_e);
    defer eager_map.deinit();
    try eager_map.materializeAll(&.{ 1, 2, 3 }, Factory(u32, u32).pure(timesTwo));
    var actx_l = AsyncContext(u32).init(testing.allocator);
    defer actx_l.deinit();
    var lazy_map = try ComputedMapU32.init(&actx_l);
    defer lazy_map.deinit();
    for ([_]u32{ 1, 2, 3 }) |k| {
        _ = try lazy_map.getOrInsertHandle(k, Factory(u32, u32).pure(timesTwo));
        try testing.expectEqual(try eager_map.drive(k), try lazy_map.drive(k));
    }
}

test "lazily/async_reactive_map: present set grows monotonically" {
    var actx = AsyncContext(u32).init(testing.allocator);
    defer actx.deinit();
    var map = try ComputedMapU32.init(&actx);
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
    var map = try SourceMapBool.init(&actx);
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
    var map = try ComputedMapU32.init(&actx);
    defer map.deinit();
    try map.materializeAll(&.{ 1, 2 }, Factory(u32, u32).pure(timesTwo));
    try testing.expectEqual(@as(u32, 2), try map.drive(1));
    try testing.expectEqual(@as(u32, 4), try map.drive(2)); // resolve_preserves_observe
    try testing.expectEqual(@as(?u32, 2), map.observe(1));
}

test "lazily/async_reactive_map: deprecated AsyncCellMap/AsyncSlotMap aliases still resolve" {
    try testing.expect(AsyncCellMap(u32, u32) == AsyncSourceMap(u32, u32));
    try testing.expect(AsyncSlotMap(u32, u32) == AsyncComputedMap(u32, u32));
}
