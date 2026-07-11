//! The async keyed reactive family (`AsyncReactiveFamily`) — the async flavor of
//! `ReactiveFamily` (`#lzmatmode`, async).
//!
//! Keys `K` map to per-entry async reactive nodes allocated per the family's
//! [`MaterializationMode`]. Like the thread-safe flavor it guards its state
//! behind a [`ParkingMutex`](parking_mutex.zig), so it can live in a cross-task
//! owner.
//!
//! Async adds a **resolution axis** orthogonal to the present-set (allocation)
//! axis of the single-threaded family: a derived (slot) entry is **pending**
//! until it is *driven* to resolution ([`drive`], the analog of Rust's
//! `AsyncContext.get_async`), then **resolved**. Input (cell) entries are
//! resolved at build. A non-blocking read therefore returns `?V`: `null` while
//! pending, `value` once resolved — exactly the Rust `AsyncReactiveFamily.observe`
//! signature.
//!
//! The single-threaded transparency law weakens to **eventual transparency**:
//! once a node resolves, its observed value is the canonical value — identical to
//! what the synchronous family observes. Proved in `lazily-formal`'s
//! `AsyncMaterialization` module (`eventual_transparency`,
//! `async_resolved_matches_sync`, `observe_pending_is_none`,
//! `cell_resolved_at_build`, `resolve_monotone`, `resolve_preserves_observe`);
//! mirrors lazily-rs `src/async_reactive_family.rs`.

const std = @import("std");
const ParkingMutex = @import("parking_mutex.zig").ParkingMutex;
const Context = @import("context.zig").Context;
const reactive_family = @import("reactive_family.zig");

pub const MaterializationMode = reactive_family.MaterializationMode;
pub const EntryKind = reactive_family.EntryKind;
pub const Factory = reactive_family.Factory;

fn HashMapFor(comptime K: type, comptime V: type) type {
    if (K == []const u8) return std.StringHashMap(V);
    return std.AutoHashMap(K, V);
}

/// The async unified keyed reactive family (`#lzmatmode`): keys `K` map to
/// per-entry async reactive nodes of the comptime-fixed [`EntryKind`], allocated
/// per its [`MaterializationMode`], each carrying a **resolution** flag.
///
/// See the module docs for the eager/lazy contract, present-set monotonicity,
/// and the eventual-transparency law.
pub fn AsyncReactiveFamily(comptime K: type, comptime V: type, comptime entry_kind: EntryKind) type {
    return struct {
        /// One family entry: allocated (present) once in the map; `resolved`
        /// tracks the async resolution axis, `value` caches its canonical value
        /// once resolved. A pending entry's `value` is unspecified.
        const Entry = struct {
            resolved: bool,
            value: V,
        };

        ctx: *Context,
        /// This family's materialization mode (immutable after build).
        mode: MaterializationMode,
        /// Canonical per-key value producer (a pure factory).
        factory: Factory(K, V),
        /// Currently-allocated entries (the "present" set). Guarded by `mutex`;
        /// grows on materialize, never shrinks (deferral-not-dealloc). Resolution
        /// only ever flips false→true (`resolve_monotone`).
        materialized: HashMapFor(K, Entry),
        /// First-materialization order of the present set. Guarded by `mutex`.
        order: std.ArrayList(K),
        allocator: std.mem.Allocator,
        mutex: ParkingMutex,

        const Self = @This();

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
                .materialized = HashMapFor(K, Entry).init(ctx.allocator),
                .order = .empty,
                .allocator = ctx.allocator,
                .mutex = ParkingMutex.init(),
            };
            for (keys) |key| {
                // A cell entry is always allocated + resolved at build. A slot
                // entry is allocated under eager (but starts pending — the async
                // value is only produced when driven); deferred under lazy.
                if (entry_kind == .cell or mode == .eager) {
                    try self.materializeKeyLocked(key);
                }
            }
            return self;
        }

        /// Build an **eager** family (the default mode): every declared key is
        /// allocated now. Cell entries resolve at build; slot entries are
        /// allocated but start pending.
        pub fn eager(ctx: *Context, keys: []const K, factory: Factory(K, V)) !Self {
            return build(ctx, .eager, keys, factory);
        }

        /// Build a **lazy** family: derived (slot) entries are deferred to first
        /// touch; input (cell) entries in `keys` are still materialized at build.
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

        /// Allocate `key` if absent (present-set grows), recording order. A cell
        /// entry is resolved immediately with its value; a slot entry starts
        /// **pending** (`resolved = false`). Caller MUST hold `mutex` (or build).
        /// A warm key is a no-op — the present set only grows.
        fn materializeKeyLocked(self: *Self, key: K) !void {
            if (self.materialized.contains(key)) return; // warm.
            const entry: Entry = if (entry_kind == .cell)
                .{ .resolved = true, .value = self.factory.call(key) }
            else
                .{ .resolved = false, .value = undefined };
            try self.materialized.put(key, entry);
            try self.order.append(self.allocator, key);
        }

        /// Drive `key` to resolution — the analog of `AsyncContext.get_async`:
        /// allocate if absent, resolve if pending (produce + cache the canonical
        /// value), and return the resolved value. A warm-resolved key returns its
        /// cached value unchanged. The eventual-transparency completion.
        pub fn drive(self: *Self, key: K) !V {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.materializeKeyLocked(key);
            const gop = try self.materialized.getOrPut(key);
            if (!gop.value_ptr.resolved) {
                gop.value_ptr.* = .{ .resolved = true, .value = self.factory.call(key) };
            }
            return gop.value_ptr.value;
        }

        /// Non-blocking observe: `value` once resolved, `null` while pending
        /// (`observe_pending_is_none`). Allocates the entry if absent — a freshly
        /// allocated slot is pending, so a first `observe` of a slot returns
        /// `null` until it is [`drive`]n; a cell is resolved at allocation, so it
        /// returns `value` immediately.
        pub fn observe(self: *Self, key: K) !?V {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.materializeKeyLocked(key);
            const entry = self.materialized.get(key).?;
            return if (entry.resolved) entry.value else null;
        }

        /// Overwrite an input **cell** entry's value (cells are writable, always
        /// resolved). Allocates the entry if absent. Compile error on a slot
        /// family.
        pub fn set(self: *Self, key: K, value: V) !void {
            if (entry_kind != .cell) @compileError("AsyncReactiveFamily.set is only valid on cell (input) families");
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.materializeKeyLocked(key);
            try self.materialized.put(key, .{ .resolved = true, .value = value });
        }

        /// Whether `key` is currently allocated (present). Non-reactive.
        pub fn isPresent(self: *Self, key: K) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.materialized.contains(key);
        }

        /// Whether `key` is allocated **and resolved** (a non-blocking observe
        /// would return a value).
        pub fn isResolved(self: *Self, key: K) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            const entry = self.materialized.get(key) orelse return false;
            return entry.resolved;
        }

        /// Number of currently-allocated entries.
        pub fn presentCount(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.order.items.len;
        }

        /// A stable snapshot of the currently-allocated keys, in
        /// first-materialization order. Owned slice — caller frees.
        pub fn presentKeys(self: *Self, allocator: std.mem.Allocator) ![]K {
            self.mutex.lock();
            defer self.mutex.unlock();
            return allocator.dupe(K, self.order.items);
        }

        pub fn entryKind(self: *Self) EntryKind {
            _ = self;
            return entry_kind;
        }
    };
}

/// An async **input-cell** family: every entry is an always-resolved cell value.
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
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var fam = try CellFamBool.eager(ctx, &.{ 1, 2, 3 }, Factory(u32, bool).pure(alwaysTrue));
    defer fam.deinit();

    try testing.expectEqual(EntryKind.cell, fam.entryKind());
    try testing.expectEqual(@as(usize, 3), fam.presentCount());
    // cell_resolved_at_build: observe returns a value immediately.
    try testing.expectEqual(@as(?bool, true), try fam.observe(2));
    const keys = try fam.presentKeys(testing.allocator);
    defer testing.allocator.free(keys);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, keys);
}

test "lazily/async_reactive_family: lazy slot family defers until read then resolves" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var fam = try SlotFam.lazy(ctx, &.{}, Factory(u32, u32).pure(timesTen));
    defer fam.deinit();

    try testing.expectEqual(MaterializationMode.lazy, fam.mode);
    try testing.expectEqual(@as(usize, 0), fam.presentCount());
    // observe allocates the entry (present) but it is pending → null.
    try testing.expectEqual(@as(?u32, null), try fam.observe(4));
    try testing.expect(fam.isPresent(4));
    try testing.expect(!fam.isResolved(4));
    try testing.expectEqual(@as(usize, 1), fam.presentCount());
    // drive resolves it → canonical value.
    try testing.expectEqual(@as(u32, 40), try fam.drive(4));
    try testing.expect(fam.isResolved(4));
    // now observe (non-blocking) returns the resolved value.
    try testing.expectEqual(@as(?u32, 40), try fam.observe(4));
}

test "lazily/async_reactive_family: pending read is null (observe_pending_is_none)" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var fam = try SlotFam.eager(ctx, &.{ 5, 6 }, Factory(u32, u32).pure(timesTwo));
    defer fam.deinit();
    // Eager allocates the slots (present) but they start pending.
    try testing.expectEqual(@as(usize, 2), fam.presentCount());
    try testing.expectEqual(@as(?u32, null), try fam.observe(5));
    // Driving resolves; eventual transparency.
    try testing.expectEqual(@as(u32, 10), try fam.drive(5));
    try testing.expectEqual(@as(?u32, 10), try fam.observe(5));
}

test "lazily/async_reactive_family: eventual transparency eager == lazy" {
    const ctx_e = try Context.init(testing.allocator);
    defer ctx_e.deinit();
    var eager_fam = try SlotFam.eager(ctx_e, &.{ 1, 2, 3 }, Factory(u32, u32).pure(timesTwo));
    defer eager_fam.deinit();
    const ctx_l = try Context.init(testing.allocator);
    defer ctx_l.deinit();
    var lazy_fam = try SlotFam.lazy(ctx_l, &.{ 1, 2, 3 }, Factory(u32, u32).pure(timesTwo));
    defer lazy_fam.deinit();
    for ([_]u32{ 1, 2, 3 }) |k| {
        try testing.expectEqual(try eager_fam.drive(k), try lazy_fam.drive(k));
    }
}

test "lazily/async_reactive_family: present set grows monotonically" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var fam = try SlotFam.lazy(ctx, &.{}, Factory(u32, u32).pure(identity));
    defer fam.deinit();
    _ = try fam.drive(5);
    _ = try fam.drive(5); // repeat: no growth
    _ = try fam.drive(9);
    try testing.expectEqual(@as(usize, 2), fam.presentCount());
    const keys = try fam.presentKeys(testing.allocator);
    defer testing.allocator.free(keys);
    try testing.expectEqualSlices(u32, &.{ 5, 9 }, keys);
}

test "lazily/async_reactive_family: cell family reacts to set" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var fam = try CellFamBool.eager(ctx, &.{ 10, 20 }, Factory(u32, bool).pure(alwaysTrue));
    defer fam.deinit();
    try testing.expectEqual(@as(?bool, true), try fam.observe(20));
    try fam.set(20, false);
    try testing.expectEqual(@as(?bool, false), try fam.observe(20));
}

test "lazily/async_reactive_family: resolving one node never disturbs another (no churn)" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var fam = try SlotFam.eager(ctx, &.{ 1, 2 }, Factory(u32, u32).pure(timesTwo));
    defer fam.deinit();
    try testing.expectEqual(@as(u32, 2), try fam.drive(1));
    // Driving 2 leaves 1's resolved value intact (resolve_preserves_observe).
    try testing.expectEqual(@as(u32, 4), try fam.drive(2));
    try testing.expectEqual(@as(?u32, 2), try fam.observe(1));
}
