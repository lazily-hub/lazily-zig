//! The async keyed reactive family (`AsyncReactiveFamily`) — the async flavor of
//! `ReactiveFamily` (`#lzmatmode`, async), riding on [`AsyncContext(V)`](async_context.zig).
//!
//! Keys `K` map to per-entry async reactive nodes **allocated in a real
//! [`AsyncContext`]**, per the family's [`MaterializationMode`]:
//! - a **cell** entry is an [`AsyncContext.cell`] — always resolved;
//! - a **slot** entry is an [`AsyncContext.computedAsyncClosure`] — a genuine
//!   async slot that is **pending** until driven ([`drive`], the analog of
//!   `AsyncContext.get_async` / `settle`), then **resolved**. The per-key value
//!   is recovered by the slot's closure via a family-owned `slot_id → value`
//!   map, the capability the generic `AsyncContext` closure-userdata unlocks.
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
const reactive_family = @import("reactive_family.zig");

pub const MaterializationMode = reactive_family.MaterializationMode;
pub const EntryKind = reactive_family.EntryKind;
pub const Factory = reactive_family.Factory;

fn HashMapFor(comptime K: type, comptime V: type) type {
    if (K == []const u8) return std.StringHashMap(V);
    return std.AutoHashMap(K, V);
}

/// The async unified keyed reactive family (`#lzmatmode`): keys `K` map to
/// per-entry async reactive nodes of the comptime-fixed [`EntryKind`] in an
/// [`AsyncContext(V)`], allocated per its [`MaterializationMode`].
pub fn AsyncReactiveFamily(comptime K: type, comptime V: type, comptime entry_kind: EntryKind) type {
    return struct {
        /// The shared async reactive context every entry lives in.
        actx: *AsyncContext(V),
        mode: MaterializationMode,
        factory: Factory(K, V),
        /// Present set: key → its node id in `actx`. Grows on materialize.
        materialized: HashMapFor(K, u64),
        /// First-materialization order of the present set.
        order: std.ArrayList(K),
        /// For slot families: slot node id → the canonical value its async
        /// compute resolves to (recovered by the closure via `cc.slot_id`).
        /// **Heap-allocated** so its address is stable across the by-value family
        /// move — the slot closure captures *this map*, never the family, which
        /// relocates when `eager`/`lazy` returns it. Empty for cell families.
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

        fn build(
            actx: *AsyncContext(V),
            mode: MaterializationMode,
            factory: Factory(K, V),
        ) !Self {
            const values = try actx.allocator.create(SlotValues);
            values.* = SlotValues.init(actx.allocator);
            return Self{
                .actx = actx,
                .mode = mode,
                .factory = factory,
                .materialized = HashMapFor(K, u64).init(actx.allocator),
                .order = .empty,
                .slot_values = values,
                .allocator = actx.allocator,
            };
        }

        /// Build an **eager** family (the default): every declared key allocated
        /// now. Cell entries resolve at build; slot entries are allocated but
        /// start pending (their async value is produced when driven).
        pub fn eager(actx: *AsyncContext(V), keys: []const K, factory: Factory(K, V)) !Self {
            var self = try build(actx, .eager, factory);
            for (keys) |key| _ = try self.materializeKey(key);
            return self;
        }

        /// Build a **lazy** family: derived (slot) entries deferred to first
        /// touch; input (cell) entries in `keys` are still materialized at build.
        pub fn lazy(actx: *AsyncContext(V), keys: []const K, factory: Factory(K, V)) !Self {
            var self = try build(actx, .lazy, factory);
            if (entry_kind == .cell) {
                for (keys) |key| _ = try self.materializeKey(key);
            }
            return self;
        }

        /// Build a family in the **default** mode (eager). Alias for [`eager`].
        pub fn new(actx: *AsyncContext(V), keys: []const K, factory: Factory(K, V)) !Self {
            return eager(actx, keys, factory);
        }

        pub fn deinit(self: *Self) void {
            self.order.deinit(self.allocator);
            self.materialized.deinit();
            self.slot_values.deinit();
            self.allocator.destroy(self.slot_values);
        }

        /// Allocate `key` if absent (present-set grows), returning its node id. A
        /// cell entry is an always-resolved async cell; a slot entry is a genuine
        /// async slot (pending until driven). Warm key → cached id.
        fn materializeKey(self: *Self, key: K) !u64 {
            if (self.materialized.get(key)) |id| return id; // warm.
            const value = self.factory.call(key);
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

        /// Drive `key` to resolution — the analog of `get_async`: allocate if
        /// absent, then settle its async slot (or read its cell) and return the
        /// resolved value. The eventual-transparency completion.
        pub fn drive(self: *Self, key: K) !V {
            const id = try self.materializeKey(key);
            if (entry_kind == .cell) return self.actx.getCell(id).?;
            return self.actx.awaitResolved(id);
        }

        /// Non-blocking observe: `value` once resolved, `null` while pending
        /// (`observe_pending_is_none`). Allocates the entry if absent — a freshly
        /// allocated slot is pending, so a first `observe` of a slot returns
        /// `null` until it is [`drive`]n; a cell is resolved at allocation.
        pub fn observe(self: *Self, key: K) !?V {
            const id = try self.materializeKey(key);
            if (entry_kind == .cell) return self.actx.getCell(id);
            return self.actx.get(id);
        }

        /// Overwrite an input **cell** entry (cells are writable, always
        /// resolved). Allocates the entry if absent. Compile error on a slot.
        pub fn set(self: *Self, key: K, value: V) !void {
            if (entry_kind != .cell) @compileError("AsyncReactiveFamily.set is only valid on cell (input) families");
            const id = try self.materializeKey(key);
            try self.actx.setCell(id, value);
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

/// An async **input-cell** family: every entry is an always-resolved async cell.
pub fn AsyncCellFamily(comptime K: type, comptime V: type) type {
    return AsyncReactiveFamily(K, V, .cell);
}

/// An async **derived-slot** family: entries are governed by the family's
/// [`MaterializationMode`], resolved via [`drive`].
pub fn AsyncSlotFamily(comptime K: type, comptime V: type) type {
    return AsyncReactiveFamily(K, V, .slot);
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

const SlotFam = AsyncSlotFamily(u32, u32);
const CellFamBool = AsyncCellFamily(u32, bool);

test "lazily/async_reactive_family: eager cell family resolves immediately" {
    var actx = AsyncContext(bool).init(testing.allocator);
    defer actx.deinit();
    var fam = try CellFamBool.eager(&actx, &.{ 1, 2, 3 }, Factory(u32, bool).pure(alwaysTrue));
    defer fam.deinit();

    try testing.expectEqual(EntryKind.cell, fam.entryKind());
    try testing.expectEqual(@as(usize, 3), fam.presentCount());
    try testing.expectEqual(@as(?bool, true), try fam.observe(2)); // cell_resolved_at_build
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, fam.presentKeys());
}

test "lazily/async_reactive_family: lazy slot family defers until read then resolves" {
    var actx = AsyncContext(u32).init(testing.allocator);
    defer actx.deinit();
    var fam = try SlotFam.lazy(&actx, &.{}, Factory(u32, u32).pure(timesTen));
    defer fam.deinit();

    try testing.expectEqual(MaterializationMode.lazy, fam.mode);
    try testing.expectEqual(@as(usize, 0), fam.presentCount());
    // observe allocates the async slot (present) but it is pending → null.
    try testing.expectEqual(@as(?u32, null), try fam.observe(4));
    try testing.expect(fam.isPresent(4));
    try testing.expect(!fam.isResolved(4));
    try testing.expectEqual(@as(usize, 1), fam.presentCount());
    // drive settles it → canonical value.
    try testing.expectEqual(@as(u32, 40), try fam.drive(4));
    try testing.expect(fam.isResolved(4));
    try testing.expectEqual(@as(?u32, 40), try fam.observe(4));
}

test "lazily/async_reactive_family: pending read is null (observe_pending_is_none)" {
    var actx = AsyncContext(u32).init(testing.allocator);
    defer actx.deinit();
    var fam = try SlotFam.eager(&actx, &.{ 5, 6 }, Factory(u32, u32).pure(timesTwo));
    defer fam.deinit();
    try testing.expectEqual(@as(usize, 2), fam.presentCount());
    try testing.expectEqual(@as(?u32, null), try fam.observe(5)); // allocated but pending
    try testing.expectEqual(@as(u32, 10), try fam.drive(5)); // eventual transparency
    try testing.expectEqual(@as(?u32, 10), try fam.observe(5));
}

test "lazily/async_reactive_family: eventual transparency eager == lazy" {
    var actx_e = AsyncContext(u32).init(testing.allocator);
    defer actx_e.deinit();
    var eager_fam = try SlotFam.eager(&actx_e, &.{ 1, 2, 3 }, Factory(u32, u32).pure(timesTwo));
    defer eager_fam.deinit();
    var actx_l = AsyncContext(u32).init(testing.allocator);
    defer actx_l.deinit();
    var lazy_fam = try SlotFam.lazy(&actx_l, &.{ 1, 2, 3 }, Factory(u32, u32).pure(timesTwo));
    defer lazy_fam.deinit();
    for ([_]u32{ 1, 2, 3 }) |k| {
        try testing.expectEqual(try eager_fam.drive(k), try lazy_fam.drive(k));
    }
}

test "lazily/async_reactive_family: present set grows monotonically" {
    var actx = AsyncContext(u32).init(testing.allocator);
    defer actx.deinit();
    var fam = try SlotFam.lazy(&actx, &.{}, Factory(u32, u32).pure(identity));
    defer fam.deinit();
    _ = try fam.drive(5);
    _ = try fam.drive(5); // repeat: no growth
    _ = try fam.drive(9);
    try testing.expectEqual(@as(usize, 2), fam.presentCount());
    try testing.expectEqualSlices(u32, &.{ 5, 9 }, fam.presentKeys());
}

test "lazily/async_reactive_family: cell family reacts to set" {
    var actx = AsyncContext(bool).init(testing.allocator);
    defer actx.deinit();
    var fam = try CellFamBool.eager(&actx, &.{ 10, 20 }, Factory(u32, bool).pure(alwaysTrue));
    defer fam.deinit();
    try testing.expectEqual(@as(?bool, true), try fam.observe(20));
    try fam.set(20, false);
    try testing.expectEqual(@as(?bool, false), try fam.observe(20));
}

test "lazily/async_reactive_family: resolving one node never disturbs another (no churn)" {
    var actx = AsyncContext(u32).init(testing.allocator);
    defer actx.deinit();
    var fam = try SlotFam.eager(&actx, &.{ 1, 2 }, Factory(u32, u32).pure(timesTwo));
    defer fam.deinit();
    try testing.expectEqual(@as(u32, 2), try fam.drive(1));
    try testing.expectEqual(@as(u32, 4), try fam.drive(2)); // resolve_preserves_observe
    try testing.expectEqual(@as(?u32, 2), try fam.observe(1));
}
