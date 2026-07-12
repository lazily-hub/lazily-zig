//! The unified keyed reactive map (`ReactiveMap`) and its `CellMap` / `SlotMap`
//! specializations (`#reactivemap`).
//!
//! `lazily-spec/cell-model.md` § "Keyed cell collections" fixes ONE keyed
//! reactive primitive that maps keys `K` to per-entry reactive nodes with
//! **reactive membership + order** and abstracts over the entry's **handle kind**
//! (`ReactiveMap<K, V, H>` in Rust). Zig has no runtime closures and keys its
//! reactive slots by comptime function pointer, so this port fixes the handle-kind
//! axis with a comptime [`EntryKind`] parameter and models each entry as a cached
//! value in a present-set map plus an authoritative order list.
//!
//! # One primitive, two specializations
//!
//! - **[`CellMap`]** (`ReactiveMap(K, V, .cell)`) — **input-cell** entries. Adds
//!   cell-only [`set`](ReactiveMap.set) and eager value-minting
//!   ([`entry`](ReactiveMap.entry) / [`entryWith`](ReactiveMap.entryWith)).
//! - **[`SlotMap`]** (`ReactiveMap(K, V, .slot)`) — **derived-slot** entries.
//!   [`getOrInsertWith`](ReactiveMap.getOrInsertWith) mints a slot on first access
//!   (**lazy materialization**); a slot's value is derived, so `SlotMap` has **no
//!   `set`**. Eager materialization is a pre-mint loop over the keyset
//!   ([`materializeAll`](ReactiveMap.materializeAll)); lazy is mint-on-access.
//!   There is **no eager/lazy mode flag** — eager = pre-mint, lazy = mint-on-access.
//!
//! The shared surface — `getOrInsertWith` / `remove` / `move*` / membership /
//! order / `keys` / `len` / `contains` — lives on the generic `ReactiveMap`.
//! `set` and eager value-minting are the `CellMap`-only specialization; the
//! pre-mint eager helper is the `SlotMap`-only specialization.
//!
//! # Three reader-class signals
//!
//! Like the Rust reference, a `ReactiveMap` exposes three independent version
//! counters (`conformance/collections/cellmap_independence.json`):
//! - **value**: per-entry — a value write invalidates only that entry's readers.
//! - **membership**: bumped on add/remove only (`len` / `contains` readers).
//! - **order**: bumped on add/remove **and** move/reorder (`keys` readers).
//!
//! A value write MUST NOT bump membership or order; a pure reorder bumps **only**
//! order (`moveTo` / `moveBefore` / `moveAfter` preserve the entry, never
//! remove-then-readd — `conformance/collections/cellmap_atomic_move.json`).

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("context.zig").Context;

/// Which kind of reactive node a [`ReactiveMap`] entry is — the handle-kind axis
/// the map fixes at comptime.
///
/// Mirrors `EntryKind` in `lazily-formal`'s `Materialization` module and the Rust
/// `EntryKind`.
pub const EntryKind = enum {
    /// An **input** cell — always materialized on access; writable via `set`.
    cell,
    /// A **derived** slot — materialized eagerly (pre-mint) or lazily on first read.
    slot,
};

/// Choose the right hash map implementation for key type K.
/// `[]const u8` uses `StringHashMap` (hashes content); everything else uses
/// `AutoHashMap`.
fn HashMapFor(comptime K: type, comptime V: type) type {
    if (K == []const u8) return std.StringHashMap(V);
    return std.AutoHashMap(K, V);
}

/// Key-equality check that works for both string keys (`[]const u8`) and
/// value-type keys (integers, etc.). Uses `std.mem.eql` for slices, `==` otherwise.
fn keysEqual(comptime K: type, a: K, b: K) bool {
    if (K == []const u8) return std.mem.eql(u8, a, b);
    return std.meta.eql(a, b);
}

/// The canonical per-key value producer — a derived slot's recompute, or an
/// input cell's initial value (`s.val` in the formal model). Zig has no
/// closures, so a captured factory is expressed as a userdata pointer plus a
/// call function (the standard Zig closure-emulation idiom). Use [`pure`] for a
/// factory with no captured state.
pub fn Factory(comptime K: type, comptime V: type) type {
    return struct {
        ptr: *anyopaque,
        call_fn: *const fn (ptr: *anyopaque, key: K) V,

        const Self = @This();

        /// Produce `key`'s canonical value.
        pub fn call(self: Self, key: K) V {
            return self.call_fn(self.ptr, key);
        }

        /// Build a factory from a pure `key -> value` function (no captured
        /// state). The userdata pointer is unused.
        pub fn pure(comptime f: fn (K) V) Self {
            const Wrap = struct {
                fn call(_: *anyopaque, key: K) V {
                    return f(key);
                }
            };
            return .{ .ptr = undefined, .call_fn = Wrap.call };
        }
    };
}

/// The unified keyed reactive map (`#reactivemap`): keys `K` map to per-entry
/// reactive nodes of the comptime-fixed [`EntryKind`], with reactive membership +
/// order. See the module docs and the [`CellMap`] / [`SlotMap`] specializations.
pub fn ReactiveMap(comptime K: type, comptime V: type, comptime entry_kind: EntryKind) type {
    return struct {
        ctx: *Context,
        /// Present set: key → cached value. Grows on mint, never shrinks silently
        /// (deferral, not de-allocation). The authoritative value axis.
        materialized: HashMapFor(K, V),
        /// Authoritative insertion/first-materialization order — the snapshot
        /// returned by `keys` / `presentKeys`.
        order: std.ArrayList(K),
        /// Membership version — bumped on add/remove only. `len` / `contains`
        /// readers subscribe here.
        membership_version: u64 = 0,
        /// Order version — bumped on add/remove **and** move/reorder. `keys`
        /// readers subscribe here so an atomic move invalidates order readers
        /// without disturbing set-identity readers.
        order_version: u64 = 0,
        allocator: std.mem.Allocator,

        const Self = @This();

        /// This map's entry kind (comptime).
        pub const kind: EntryKind = entry_kind;

        /// Create an empty map bound to `ctx`.
        pub fn init(ctx: *Context) Self {
            return .{
                .ctx = ctx,
                .materialized = HashMapFor(K, V).init(ctx.allocator),
                .order = .empty,
                .allocator = ctx.allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.order.deinit(self.allocator);
            self.materialized.deinit();
        }

        /// Mint the entry for `key` with `value` (assumes `key` is absent),
        /// recording membership + order. Bumps both the membership and order
        /// versions: a new key changes the set identity and the ordered key list.
        fn mint(self: *Self, key: K, value: V) !void {
            try self.materialized.put(key, value);
            try self.order.append(self.allocator, key);
            self.membership_version += 1;
            self.order_version += 1;
        }

        /// Get the value at `key`, minting the entry via `factory(key)` first if
        /// the key is absent — the mint-on-access recipe. For a [`SlotMap`] this
        /// is the **lazy materialization** pull; for a [`CellMap`] it seeds an
        /// input cell. Re-reading an existing key returns its current value
        /// without re-running the factory (the present set only grows).
        pub fn getOrInsertWith(self: *Self, key: K, factory: Factory(K, V)) !V {
            if (self.materialized.get(key)) |v| return v; // warm: already present.
            const value = factory.call(key);
            try self.mint(key, value);
            return value;
        }

        /// Read the value at `key` if present, else `null`. Non-minting.
        pub fn get(self: *const Self, key: K) ?V {
            return self.materialized.get(key);
        }

        /// Remove `key`'s entry. Bumps membership + order. Returns whether the key
        /// was present.
        pub fn remove(self: *Self, key: K) bool {
            if (!self.materialized.remove(key)) return false;
            for (self.order.items, 0..) |k, i| {
                if (keysEqual(K, k, key)) {
                    _ = self.order.orderedRemove(i);
                    break;
                }
            }
            self.membership_version += 1;
            self.order_version += 1;
            return true;
        }

        /// Reactive snapshot of the keys in their current order — order readers
        /// (add/remove **and** move/reorder), not per-entry value changes.
        pub fn keys(self: *const Self) []const K {
            return self.order.items;
        }

        /// The currently-materialized (present) keys, in first-materialization
        /// order. Alias for [`keys`].
        pub fn presentKeys(self: *const Self) []const K {
            return self.order.items;
        }

        /// Number of currently-materialized (present) entries.
        pub fn presentCount(self: *const Self) usize {
            return self.order.items.len;
        }

        /// Whether `key` is currently materialized (present). Non-reactive.
        pub fn isPresent(self: *const Self, key: K) bool {
            return self.materialized.contains(key);
        }

        /// Current 0-based position of `key` in the order, or `null` if absent.
        pub fn position(self: *const Self, key: K) ?usize {
            for (self.order.items, 0..) |k, i| {
                if (keysEqual(K, k, key)) return i;
            }
            return null;
        }

        /// Reactive entry count. Membership readers subscribe here.
        pub fn len(self: *const Self) usize {
            return self.order.items.len;
        }

        /// Reactive emptiness check.
        pub fn isEmpty(self: *const Self) bool {
            return self.order.items.len == 0;
        }

        /// Reactive membership test for `key`.
        pub fn contains(self: *const Self, key: K) bool {
            return self.materialized.contains(key);
        }

        /// Current membership version (bumped on add/remove).
        pub fn membershipVersion(self: *const Self) u64 {
            return self.membership_version;
        }

        /// Current order version (bumped on add/remove and reorder).
        pub fn orderVersion(self: *const Self) u64 {
            return self.order_version;
        }

        /// This map's entry kind ([`EntryKind.cell`] for a [`CellMap`],
        /// [`EntryKind.slot`] for a [`SlotMap`]).
        pub fn entryKind(self: *const Self) EntryKind {
            _ = self;
            return entry_kind;
        }

        // --- atomic move operations (preserve the entry, bump order only) ---

        /// Atomically move `key` to absolute `index` in the order. The entry keeps
        /// the **same** cached value and membership — only the order signal is
        /// bumped (once). `index` clamps to `[0, len)`. Returns whether `key` was
        /// present.
        pub fn moveTo(self: *Self, key: K, index: usize) bool {
            const from = self.position(key) orelse return false;
            const k = self.order.orderedRemove(from);
            // After removal the list is shorter, so an index pointing at the old
            // end becomes an append.
            const clamped = @min(index, self.order.items.len);
            if (from == clamped) {
                // No-op: re-insert at the same spot and do not invalidate readers.
                self.order.insert(self.allocator, from, k) catch return false;
                return true;
            }
            self.order.insert(self.allocator, clamped, k) catch return false;
            self.order_version += 1;
            return true;
        }

        /// Atomically move `key` to just before `before_key`. Order signal only.
        pub fn moveBefore(self: *Self, key: K, before_key: K) bool {
            const target = self.position(before_key) orelse return false;
            return self.moveTo(key, target);
        }

        /// Atomically move `key` to just after `after_key`. Order signal only.
        pub fn moveAfter(self: *Self, key: K, after_key: K) bool {
            const target = self.position(after_key) orelse return false;
            return self.moveTo(key, target + 1);
        }

        /// Which reader classes would be invalidated by applying `op` — the
        /// declarative contract behind the conformance fixtures.
        pub fn invalidates(op: CollectionOp) InvalidateFlags {
            return switch (op) {
                .set_value => .{ .value = true, .membership = false, .order = false },
                .insert, .remove => .{ .value = false, .membership = true, .order = true },
                .move_to, .move_before, .move_after => .{ .value = false, .membership = false, .order = true },
            };
        }

        // --- CellMap-only surface: eager value-minting + `set` ---

        /// Return the value for `key`, minting it with `value` on first access
        /// (eager value-minting). Adding a new key bumps membership + order;
        /// re-fetching an existing key returns its current value without a bump.
        /// Cell-only: compile error on a slot map.
        pub fn entry(self: *Self, key: K, value: V) !V {
            if (entry_kind != .cell) @compileError("ReactiveMap.entry is only valid on cell (input) maps");
            if (self.materialized.get(key)) |v| return v;
            try self.mint(key, value);
            return value;
        }

        /// Like [`entry`] but the default is produced by `default_fn` only when
        /// the key is absent. Cell-only.
        pub fn entryWith(self: *Self, key: K, default_fn: *const fn () V) !V {
            if (entry_kind != .cell) @compileError("ReactiveMap.entryWith is only valid on cell (input) maps");
            if (self.materialized.get(key)) |v| return v;
            const value = default_fn();
            try self.mint(key, value);
            return value;
        }

        /// Set the value at `key`, inserting a new entry (and bumping membership +
        /// order) if absent. Updating an existing entry leaves membership and order
        /// untouched and invalidates only that entry's value axis. An equal-value
        /// set is a no-op (PartialEq guard). Cell-only: a derived [`SlotMap`] slot
        /// is not writable.
        pub fn set(self: *Self, key: K, value: V) !void {
            if (entry_kind != .cell) @compileError("ReactiveMap.set is only valid on cell (input) maps");
            if (self.materialized.getPtr(key)) |vp| {
                if (std.meta.eql(vp.*, value)) return; // PartialEq guard.
                vp.* = value; // value axis only — membership/order untouched.
                return;
            }
            try self.mint(key, value);
        }

        // --- SlotMap-only surface: the eager pre-mint helper ---

        /// **Eager materialization**: pre-mint a derived slot for every key in
        /// `all_keys` via `factory`, up front. Observationally identical to minting
        /// each key lazily on first read ([`getOrInsertWith`]) — it only changes
        /// *when* the nodes are allocated. Slot-only.
        pub fn materializeAll(self: *Self, all_keys: []const K, factory: Factory(K, V)) !void {
            if (entry_kind != .slot) @compileError("ReactiveMap.materializeAll is only valid on slot (derived) maps");
            for (all_keys) |key| _ = try self.getOrInsertWith(key, factory);
        }
    };
}

/// A keyed **input-cell** map: every entry is a settable input cell. The
/// `CellMap` specialization of [`ReactiveMap`] adds cell-only `set` and eager
/// value-minting (`entry` / `entryWith`) on top of the shared reactive surface.
pub fn CellMap(comptime K: type, comptime V: type) type {
    return ReactiveMap(K, V, .cell);
}

/// A keyed **derived-slot** map: every entry is a derived slot.
/// [`getOrInsertWith`](ReactiveMap.getOrInsertWith) mints a slot on first access
/// (lazy materialization); [`materializeAll`](ReactiveMap.materializeAll)
/// pre-mints the keyset (eager). A slot's value is derived, so `SlotMap` has **no
/// `set`**.
pub fn SlotMap(comptime K: type, comptime V: type) type {
    return ReactiveMap(K, V, .slot);
}

/// Operations that can be applied to a [`ReactiveMap`] (mirrors conformance
/// fixture op types).
pub const CollectionOp = enum {
    set_value,
    insert,
    remove,
    move_to,
    move_before,
    move_after,
};

/// Which reader classes are invalidated by an operation.
pub const InvalidateFlags = struct {
    value: bool = false,
    membership: bool = false,
    order: bool = false,
};

// ---------------------------------------------------------------------------
// Tests — mirror lazily-rs `src/cell_family.rs` unit tests.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn timesThree(k: u32) u32 {
    return k * 3;
}

fn timesTwo(k: u32) u32 {
    return k * 2;
}

fn identity(k: u32) u32 {
    return k;
}

test "lazily/reactive_map: entry caches one value per key" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var map = CellMap([]const u8, i32).init(ctx);
    defer map.deinit();

    try testing.expectEqual(@as(i32, 1), try map.entry("a", 1));
    // Same key -> cached value; the second default is ignored.
    try testing.expectEqual(@as(i32, 1), try map.entry("a", 999));
    try testing.expectEqual(@as(usize, 1), map.len());
}

test "lazily/reactive_map: set inserts then updates in place" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var map = CellMap([]const u8, i32).init(ctx);
    defer map.deinit();

    try map.set("a", 1);
    const mv0 = map.membershipVersion();
    const ov0 = map.orderVersion();

    // Update existing: value axis only, no membership/order bump.
    try map.set("a", 42);
    try testing.expectEqual(@as(?i32, 42), map.get("a"));
    try testing.expectEqual(mv0, map.membershipVersion());
    try testing.expectEqual(ov0, map.orderVersion());

    // Insert new: membership + order bump.
    try map.set("b", 2);
    try testing.expect(map.membershipVersion() > mv0);
    try testing.expect(map.orderVersion() > ov0);
}

test "lazily/reactive_map: PartialEq guard on equal set is a no-op" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var map = CellMap([]const u8, i32).init(ctx);
    defer map.deinit();

    try map.set("a", 1);
    const mv0 = map.membershipVersion();
    const ov0 = map.orderVersion();
    try map.set("a", 1); // equal value: no signal changes.
    try testing.expectEqual(mv0, map.membershipVersion());
    try testing.expectEqual(ov0, map.orderVersion());
}

test "lazily/reactive_map: membership vs value independence" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var map = CellMap([]const u8, i32).init(ctx);
    defer map.deinit();
    _ = try map.entry("a", 1);
    _ = try map.entry("b", 2);
    try testing.expectEqual(@as(usize, 2), map.len());

    const mv = map.membershipVersion();
    // Mutating an existing entry must NOT change membership.
    try map.set("a", 100);
    try testing.expectEqual(mv, map.membershipVersion());
    try testing.expectEqual(@as(usize, 2), map.len());

    // Adding and removing keys DO change membership.
    _ = try map.entry("c", 3);
    try testing.expect(map.membershipVersion() > mv);
    try testing.expect(map.remove("b"));
    try testing.expect(!map.contains("b"));
    try testing.expectEqualSlices([]const u8, &.{ "a", "c" }, map.keys());
}

test "lazily/reactive_map: getOrInsertWith mints once then returns existing" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var map = SlotMap(u32, u32).init(ctx);
    defer map.deinit();

    try testing.expectEqual(@as(u32, 14), try map.getOrInsertWith(7, Factory(u32, u32).pure(timesTwo)));
    try testing.expectEqual(@as(usize, 1), map.presentCount());
    try testing.expect(map.isPresent(7));
    // Same key -> same value; factory NOT re-run (timesThree would give 21).
    try testing.expectEqual(@as(u32, 14), try map.getOrInsertWith(7, Factory(u32, u32).pure(timesThree)));
    try testing.expectEqual(@as(?u32, 14), map.get(7));
}

test "lazily/reactive_map: SlotMap materializeAll is eager" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var map = SlotMap(u32, u32).init(ctx);
    defer map.deinit();
    try map.materializeAll(&.{ 0, 1, 2, 5, 9 }, Factory(u32, u32).pure(timesThree));
    try testing.expectEqual(@as(usize, 5), map.presentCount());
    for ([_]u32{ 0, 1, 2, 5, 9 }) |k| try testing.expect(map.isPresent(k));
    try testing.expectEqual(@as(?u32, 15), map.get(5));
    try testing.expectEqual(EntryKind.slot, map.entryKind());
}

test "lazily/reactive_map: SlotMap lazy vs eager observe identically" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var eager_map = SlotMap(u32, u32).init(ctx);
    defer eager_map.deinit();
    try eager_map.materializeAll(&.{ 0, 1, 2, 5, 9 }, Factory(u32, u32).pure(timesThree));

    var lazy_map = SlotMap(u32, u32).init(ctx);
    defer lazy_map.deinit();
    for ([_]u32{ 0, 1, 2, 5, 9 }) |k| {
        try testing.expectEqual(eager_map.get(k).?, try lazy_map.getOrInsertWith(k, Factory(u32, u32).pure(timesThree)));
    }
}

test "lazily/reactive_map: present set is monotone across reads" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var map = SlotMap(u32, u32).init(ctx);
    defer map.deinit();

    var sizes: [4]usize = undefined;
    const reads = [_]u32{ 2, 4, 2, 5 };
    for (reads, 0..) |k, i| {
        _ = try map.getOrInsertWith(k, Factory(u32, u32).pure(timesTwo));
        sizes[i] = map.presentCount();
    }
    // Re-reading 2 does not re-materialize; sizes are non-decreasing.
    try testing.expectEqualSlices(usize, &.{ 1, 2, 2, 3 }, &sizes);
    try testing.expectEqualSlices(u32, &.{ 2, 4, 5 }, map.presentKeys());
}

test "lazily/reactive_map: cell entries are writable inputs" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var map = CellMap(u32, u32).init(ctx);
    defer map.deinit();

    try testing.expectEqual(@as(u32, 7), try map.entry(7, 7));
    try map.set(7, 100);
    try testing.expectEqual(@as(?u32, 100), map.get(7));
    try testing.expectEqual(EntryKind.cell, map.entryKind());
    _ = identity; // referenced to keep helper parity with sibling flavors
}

test "lazily/reactive_map: cell map materialized on entry in any use" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    const cell_keys = [_][]const u8{ "a", "b", "c" };
    var map = CellMap([]const u8, u32).init(ctx);
    defer map.deinit();
    for (cell_keys) |k| _ = try map.entry(k, 0);
    try testing.expectEqual(EntryKind.cell, map.entryKind());
    try testing.expectEqual(@as(usize, 3), map.presentCount());
}

test "lazily/reactive_map: atomic move bumps order only, preserves membership + value" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var map = CellMap([]const u8, i32).init(ctx);
    defer map.deinit();
    _ = try map.entry("a", 1);
    _ = try map.entry("b", 2);
    _ = try map.entry("c", 3);
    _ = try map.entry("d", 4);
    try testing.expectEqualSlices([]const u8, &.{ "a", "b", "c", "d" }, map.keys());

    const mv0 = map.membershipVersion();
    const ov0 = map.orderVersion();

    // moveTo: "c" -> front.
    try testing.expect(map.moveTo("c", 0));
    try testing.expectEqualSlices([]const u8, &.{ "c", "a", "b", "d" }, map.keys());
    // Order changed; membership did NOT.
    try testing.expectEqual(ov0 + 1, map.orderVersion());
    try testing.expectEqual(mv0, map.membershipVersion());
    // Value intact.
    try testing.expectEqual(@as(?i32, 3), map.get("c"));

    // Absent key -> false, no reorder.
    try testing.expect(!map.moveTo("z", 0));
    try testing.expectEqualSlices([]const u8, &.{ "c", "a", "b", "d" }, map.keys());
}

test "lazily/reactive_map: no-op move does not bump order" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var map = CellMap([]const u8, i32).init(ctx);
    defer map.deinit();
    _ = try map.entry("a", 1);
    _ = try map.entry("b", 2);
    const ov0 = map.orderVersion();

    // Moving to its current index is a no-op.
    try testing.expect(map.moveTo("a", 0));
    try testing.expectEqual(ov0, map.orderVersion());
    // Index past the end clamps to last position.
    try testing.expect(map.moveTo("a", 99));
    try testing.expectEqualSlices([]const u8, &.{ "b", "a" }, map.keys());
}

test "lazily/reactive_map: moveBefore / moveAfter place relative to anchor" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var map = CellMap(i32, i32).init(ctx);
    defer map.deinit();
    for ([_]i32{ 0, 1, 2, 3 }) |k| _ = try map.entry(k, k * 10);
    try testing.expectEqualSlices(i32, &.{ 0, 1, 2, 3 }, map.keys());

    // moveBefore: 3 before 1.
    try testing.expect(map.moveBefore(3, 1));
    try testing.expectEqualSlices(i32, &.{ 0, 3, 1, 2 }, map.keys());

    // moveAfter: 0 after 2.
    try testing.expect(map.moveAfter(0, 2));
    try testing.expectEqualSlices(i32, &.{ 3, 1, 2, 0 }, map.keys());

    // Unknown anchor / key -> false.
    try testing.expect(!map.moveBefore(3, 99));
    try testing.expect(!map.moveAfter(99, 2));
}

test "lazily/reactive_map: invalidate flags match conformance contract" {
    try testing.expectEqual(
        InvalidateFlags{ .value = true, .membership = false, .order = false },
        CellMap(u32, u32).invalidates(.set_value),
    );
    try testing.expectEqual(
        InvalidateFlags{ .value = false, .membership = true, .order = true },
        CellMap(u32, u32).invalidates(.insert),
    );
    try testing.expectEqual(
        InvalidateFlags{ .value = false, .membership = true, .order = true },
        CellMap(u32, u32).invalidates(.remove),
    );
    try testing.expectEqual(
        InvalidateFlags{ .value = false, .membership = false, .order = true },
        CellMap(u32, u32).invalidates(.move_to),
    );
}

// ---------------------------------------------------------------------------
// lazily-spec conformance fixture replay
// `../lazily-spec/conformance/materialization/*.json` (model: SlotMap) — the
// executable form of the `lazily-formal` Materialization theorems (mirrors
// lazily-rs `tests/materialization_conformance.rs`). Eager = pre-mint loop
// (`materializeAll`); lazy = mint-on-access (`getOrInsertWith`).
// ---------------------------------------------------------------------------

const json = std.json;
const SPEC_DIR = "../lazily-spec/conformance/materialization";
const FV = i64;

fn readFixtureFile(path: []const u8) ![]u8 {
    if (comptime builtin.zig_version.minor >= 16) {
        return std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            path,
            std.testing.allocator,
            .limited(1024 * 1024),
        );
    }
    return std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024 * 1024);
}

fn specFixturesPresent() bool {
    const raw = readFixtureFile(SPEC_DIR ++ "/observational_transparency.json") catch return false;
    std.testing.allocator.free(raw);
    return true;
}

fn jsonField(value: json.Value, name: []const u8) ?json.Value {
    return switch (value) {
        .object => |object| object.get(name),
        else => null,
    };
}

fn jsonFieldRequired(value: json.Value, name: []const u8) !json.Value {
    return jsonField(value, name) orelse error.MissingField;
}

fn jsonAsI64(value: json.Value) !FV {
    return switch (value) {
        .integer => |n| @intCast(n),
        .number_string => |s| try std.fmt.parseInt(FV, s, 10),
        else => error.ExpectedInteger,
    };
}

fn jsonAsString(value: json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}

/// A runtime `key -> value` lookup over a fixture's `spec.val` / `spec.entries`
/// map, exposed to a map as a captured [`Factory`] (userdata pointer).
const Lookup = struct {
    map: std.StringHashMap(FV),

    fn init() Lookup {
        return .{ .map = std.StringHashMap(FV).init(std.testing.allocator) };
    }

    fn deinit(self: *Lookup) void {
        self.map.deinit();
    }

    fn call(ptr: *anyopaque, key: []const u8) FV {
        const self: *Lookup = @ptrCast(@alignCast(ptr));
        return self.map.get(key) orelse std.debug.panic("no spec val for key {s}", .{key});
    }

    fn factory(self: *Lookup) Factory([]const u8, FV) {
        return .{ .ptr = self, .call_fn = Lookup.call };
    }
};

/// Assert `expected` and `got` are the same *set* of keys (order-independent).
fn expectSameKeySet(expected: []const json.Value, got: []const []const u8) !void {
    try testing.expectEqual(expected.len, got.len);
    for (expected) |want_v| {
        const want = try jsonAsString(want_v);
        var found = false;
        for (got) |g| {
            if (std.mem.eql(u8, g, want)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("missing expected present key: {s}\n", .{want});
            return error.KeySetMismatch;
        }
    }
}

fn arrayItems(value: json.Value) ![]const json.Value {
    return switch (value) {
        .array => |a| a.items,
        else => error.ExpectedArray,
    };
}

const Slots = SlotMap([]const u8, FV);
const Cells = CellMap([]const u8, FV);

/// Shared checks for the two `spec.val` fixtures (all-slot maps): default mode
/// eager, eager materializes all, observational transparency eager==lazy.
fn checkValFixture(ctx: *Context, name: []const u8) !void {
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ SPEC_DIR, name });
    defer testing.allocator.free(path);
    const raw = try readFixtureFile(path);
    defer testing.allocator.free(raw);
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const fixture = parsed.value;
    const expected = try jsonFieldRequired(fixture, "expected");

    // default_mode_eager
    try testing.expectEqualStrings("eager", try jsonAsString(try jsonFieldRequired(expected, "default_mode")));

    // Build the runtime lookup + declared key order from `spec.val`.
    const val_obj = switch (try jsonFieldRequired(try jsonFieldRequired(fixture, "spec"), "val")) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };
    var lookup = Lookup.init();
    defer lookup.deinit();
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(testing.allocator);
    var it = val_obj.iterator();
    while (it.next()) |entry| {
        try lookup.map.put(entry.key_ptr.*, try jsonAsI64(entry.value_ptr.*));
        try keys.append(testing.allocator, entry.key_ptr.*);
    }

    // Eager = pre-mint loop; lazy = empty, mint-on-access.
    var eager_map = Slots.init(ctx);
    defer eager_map.deinit();
    try eager_map.materializeAll(keys.items, lookup.factory());
    var lazy_map = Slots.init(ctx);
    defer lazy_map.deinit();

    // eager_materializes_all / lazy_defers_slots
    try testing.expectEqual(keys.items.len, eager_map.presentCount());
    try expectSameKeySet(try arrayItems(try jsonFieldRequired(expected, "eager_present")), eager_map.presentKeys());
    try testing.expectEqual(@as(usize, 0), lazy_map.presentCount());

    // observe_canonical / eager_lazy_observationally_equivalent
    const observe_obj = switch (try jsonFieldRequired(expected, "observe")) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };
    var oit = observe_obj.iterator();
    while (oit.next()) |entry| {
        const want = try jsonAsI64(entry.value_ptr.*);
        try testing.expectEqual(want, eager_map.get(entry.key_ptr.*).?);
        try testing.expectEqual(want, try lazy_map.getOrInsertWith(entry.key_ptr.*, lookup.factory()));
    }
}

test "lazily/reactive_map conformance: observational_transparency" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    try checkValFixture(ctx, "observational_transparency.json");

    // Replay the lazy read sequence on a fresh map; the lazy present set is
    // exactly the read keys (lazy_defers_slots).
    const raw = try readFixtureFile(SPEC_DIR ++ "/observational_transparency.json");
    defer testing.allocator.free(raw);
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const fixture = parsed.value;
    const expected = try jsonFieldRequired(fixture, "expected");

    const val_obj = switch (try jsonFieldRequired(try jsonFieldRequired(fixture, "spec"), "val")) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };
    var lookup = Lookup.init();
    defer lookup.deinit();
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(testing.allocator);
    var it = val_obj.iterator();
    while (it.next()) |entry| {
        try lookup.map.put(entry.key_ptr.*, try jsonAsI64(entry.value_ptr.*));
        try keys.append(testing.allocator, entry.key_ptr.*);
    }

    var lazy_map = Slots.init(ctx);
    defer lazy_map.deinit();
    for (try arrayItems(try jsonFieldRequired(fixture, "reads"))) |r| {
        _ = try lazy_map.getOrInsertWith(try jsonAsString(r), lookup.factory());
    }
    try expectSameKeySet(try arrayItems(try jsonFieldRequired(expected, "lazy_present_after_reads")), lazy_map.presentKeys());
}

test "lazily/reactive_map conformance: deferral_not_deallocation" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    try checkValFixture(ctx, "deferral_not_deallocation.json");

    const raw = try readFixtureFile(SPEC_DIR ++ "/deferral_not_deallocation.json");
    defer testing.allocator.free(raw);
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const fixture = parsed.value;
    const expected = try jsonFieldRequired(fixture, "expected");

    const val_obj = switch (try jsonFieldRequired(try jsonFieldRequired(fixture, "spec"), "val")) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };
    var lookup = Lookup.init();
    defer lookup.deinit();
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(testing.allocator);
    var it = val_obj.iterator();
    while (it.next()) |entry| {
        try lookup.map.put(entry.key_ptr.*, try jsonAsI64(entry.value_ptr.*));
        try keys.append(testing.allocator, entry.key_ptr.*);
    }

    var lazy_map = Slots.init(ctx);
    defer lazy_map.deinit();

    // present_after_each_read: cumulative present-set size, monotone and
    // unchanged by a re-read (materialize_present_monotone).
    const want_sizes = try arrayItems(try jsonFieldRequired(expected, "present_after_each_read"));
    const reads = try arrayItems(try jsonFieldRequired(fixture, "reads"));
    try testing.expectEqual(want_sizes.len, reads.len);
    for (reads, want_sizes) |r, want| {
        _ = try lazy_map.getOrInsertWith(try jsonAsString(r), lookup.factory());
        try testing.expectEqual(@as(usize, @intCast(try jsonAsI64(want))), lazy_map.presentCount());
    }

    // lazy_present_after_reads is a subset of eager_present.
    const lazy_present = try jsonFieldRequired(expected, "lazy_present_after_reads");
    try expectSameKeySet(try arrayItems(lazy_present), lazy_map.presentKeys());
    const eager_present = try arrayItems(try jsonFieldRequired(expected, "eager_present"));
    for (lazy_map.presentKeys()) |k| {
        var in_eager = false;
        for (eager_present) |e| {
            if (std.mem.eql(u8, try jsonAsString(e), k)) {
                in_eager = true;
                break;
            }
        }
        try testing.expect(in_eager);
    }
}

test "lazily/reactive_map conformance: entry_kind_orthogonal_to_mode" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    const raw = try readFixtureFile(SPEC_DIR ++ "/entry_kind_orthogonal_to_mode.json");
    defer testing.allocator.free(raw);
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const fixture = parsed.value;
    const expected = try jsonFieldRequired(fixture, "expected");
    try testing.expectEqualStrings("eager", try jsonAsString(try jsonFieldRequired(expected, "default_mode")));

    // Split the map's declared entries by kind: input cells vs derived slots.
    // A single ReactiveMap fixes one handle kind, so a mixed-kind fixture is
    // modelled by a CellMap over the cell entries and a SlotMap over the slot
    // entries — sharing one logical key space (mirrors lazily-rs).
    const entries_obj = switch (try jsonFieldRequired(try jsonFieldRequired(fixture, "spec"), "entries")) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };
    var lookup = Lookup.init();
    defer lookup.deinit();
    var cell_keys = std.ArrayList([]const u8).empty;
    defer cell_keys.deinit(testing.allocator);
    var slot_keys = std.ArrayList([]const u8).empty;
    defer slot_keys.deinit(testing.allocator);
    var it = entries_obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const kind = try jsonAsString(try jsonFieldRequired(entry.value_ptr.*, "kind"));
        try lookup.map.put(key, try jsonAsI64(try jsonFieldRequired(entry.value_ptr.*, "val")));
        if (std.mem.eql(u8, kind, "cell")) {
            try cell_keys.append(testing.allocator, key);
        } else if (std.mem.eql(u8, kind, "slot")) {
            try slot_keys.append(testing.allocator, key);
        } else return error.UnknownEntryKind;
    }

    // Eager build: every entry present (cells via entry, slots via materializeAll).
    var eager_cells = Cells.init(ctx);
    defer eager_cells.deinit();
    for (cell_keys.items) |k| _ = try eager_cells.entry(k, lookup.map.get(k).?);
    var eager_slots = Slots.init(ctx);
    defer eager_slots.deinit();
    try eager_slots.materializeAll(slot_keys.items, lookup.factory());
    try testing.expectEqual(EntryKind.cell, eager_cells.entryKind());
    try testing.expectEqual(EntryKind.slot, eager_slots.entryKind());
    try testing.expectEqual(
        eager_cells.presentCount() + eager_slots.presentCount(),
        (try arrayItems(try jsonFieldRequired(expected, "eager_present"))).len,
    );

    // Lazy build: cells present at build (input cells always materialized), slots deferred.
    var lazy_cells = Cells.init(ctx);
    defer lazy_cells.deinit();
    for (cell_keys.items) |k| _ = try lazy_cells.entry(k, lookup.map.get(k).?);
    var lazy_slots = Slots.init(ctx);
    defer lazy_slots.deinit();
    try testing.expectEqual(@as(usize, 0), lazy_slots.presentCount());
    try expectSameKeySet(try arrayItems(try jsonFieldRequired(expected, "lazy_present_at_build")), lazy_cells.presentKeys());

    // Reads (slot pulls) grow only the slot present set.
    for (try arrayItems(try jsonFieldRequired(fixture, "reads"))) |r| {
        const key = try jsonAsString(r);
        if (lazy_cells.isPresent(key)) {
            _ = lazy_cells.get(key);
        } else {
            _ = try lazy_slots.getOrInsertWith(key, lookup.factory());
        }
    }
    // Combined lazy present set after reads.
    const want_after = try arrayItems(try jsonFieldRequired(expected, "lazy_present_after_reads"));
    try testing.expectEqual(want_after.len, lazy_cells.presentCount() + lazy_slots.presentCount());

    // Observational transparency across kinds.
    const observe_obj = switch (try jsonFieldRequired(expected, "observe")) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };
    var oit = observe_obj.iterator();
    while (oit.next()) |entry| {
        const want = try jsonAsI64(entry.value_ptr.*);
        const key = entry.key_ptr.*;
        if (eager_cells.isPresent(key) or lazy_cells.isPresent(key)) {
            try testing.expectEqual(want, eager_cells.get(key).?);
            try testing.expectEqual(want, lazy_cells.get(key).?);
        } else {
            try testing.expectEqual(want, eager_slots.get(key).?);
            try testing.expectEqual(want, try lazy_slots.getOrInsertWith(key, lookup.factory()));
        }
    }
}
