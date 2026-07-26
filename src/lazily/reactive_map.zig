//! The unified keyed reactive map (`ReactiveMap`) and its `SourceMap` / `ComputedMap`
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
//! - **[`SourceMap`]** (`ReactiveMap(K, V, .source)`) — **input-cell** entries. Adds
//!   cell-only [`set`](ReactiveMap.set) and eager value-minting
//!   ([`entry`](ReactiveMap.entry) / [`entryWith`](ReactiveMap.entryWith)).
//! - **[`ComputedMap`]** (`ReactiveMap(K, V, .computed)`) — **derived-slot** entries.
//!   [`getOrInsertWith`](ReactiveMap.getOrInsertWith) mints a slot on first access
//!   (**lazy materialization**); a slot's value is derived, so `ComputedMap` has **no
//!   `set`**. Eager materialization is a pre-mint loop over the keyset
//!   ([`materializeAll`](ReactiveMap.materializeAll)); lazy is mint-on-access.
//!   There is **no eager/lazy mode flag** — eager = pre-mint, lazy = mint-on-access.
//!
//! The shared surface — `getOrInsertWith` / `remove` / `move*` / membership /
//! order / `keys` / `len` / `contains` — lives on the generic `ReactiveMap`.
//! `set` and eager value-minting are the `SourceMap`-only specialization; the
//! pre-mint eager helper is the `ComputedMap`-only specialization.
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
const keyed_order = @import("keyed_order.zig");
const KeyedOrder = keyed_order.KeyedOrder;
const Mutation = keyed_order.Mutation;
const Move = keyed_order.Move;

/// Which kind of reactive node a [`ReactiveMap`] entry is — the handle-kind axis
/// the map fixes at comptime.
///
/// Mirrors `EntryKind` in `lazily-formal`'s `Materialization` module and the Rust
/// `EntryKind`.
///
/// The tag identifiers follow the v2 cell kernel (`Source` / `Computed`); the
/// **wire** spelling does not. Conformance fixtures and the sibling binding
/// runners still speak `"cell"` / `"slot"`, so serialization goes through
/// [`wireName`](EntryKind.wireName) / [`fromWireName`](EntryKind.fromWireName)
/// and never `@tagName`.
pub const EntryKind = enum {
    /// An **input** source cell — always materialized on access; writable via `set`.
    source,
    /// A **derived** computed — materialized eagerly (pre-mint) or lazily on first read.
    computed,

    /// Deprecated: renamed to [`EntryKind.source`] when the v2 kernel renamed the
    /// node kinds to `Source` / `Computed`. Kept as a namespaced constant so
    /// `EntryKind.cell` still resolves; use `.source` in new code. (Zig has no
    /// enum-tag aliases, so the enum-literal form `.cell` does **not** resolve.)
    pub const cell: EntryKind = .source;

    /// Deprecated: renamed to [`EntryKind.computed`]. See [`EntryKind.cell`].
    pub const slot: EntryKind = .computed;

    /// The stable **wire** spelling — `"cell"` / `"slot"`. Frozen: nine binding
    /// runners and the spec fixtures read these strings, so this mapping is
    /// written out explicitly rather than derived from `@tagName`.
    pub fn wireName(self: EntryKind) []const u8 {
        return switch (self) {
            .source => "cell",
            .computed => "slot",
        };
    }

    /// Parse a fixture/wire `kind` field. Accepts the frozen wire spellings
    /// (`"cell"` / `"slot"`) **and** the v2 kernel spellings (`"source"` /
    /// `"computed"`) so a fixture flip is a no-op here. Anything else is an
    /// error — never a silent default.
    pub fn fromWireName(name: []const u8) error{UnknownEntryKind}!EntryKind {
        if (std.mem.eql(u8, name, "cell") or std.mem.eql(u8, name, "source")) return .source;
        if (std.mem.eql(u8, name, "slot") or std.mem.eql(u8, name, "computed")) return .computed;
        return error.UnknownEntryKind;
    }
};

/// Choose the right hash map implementation for key type K. Re-exported from
/// the shared bookkeeping core so all three flavors key alike.
const HashMapFor = keyed_order.HashMapFor;

/// Key-equality for string and value-type keys. See [`HashMapFor`].
const keysEqual = keyed_order.keysEqual;

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

/// What identifies an entry on the single-threaded map.
///
/// The Core surface requires `handle(key)` so the atomic-move law ("a reorder
/// keeps the entry's same handle") is assertable. This flavor is not
/// graph-backed — entries are cached values, not nodes — so there is no node id
/// to hand back; identity here is the entry's value version, which a write bumps
/// and a reorder must not. Strictly weaker than a node handle, and the reason
/// this binding scores partial rather than green on the Core row.
pub const EntryHandle = struct {
    /// Monotonic birth id, assigned once when the entry is minted. Stable across
    /// value writes and reorders; a removed-and-re-minted key gets a fresh one.
    /// This is the identity the atomic-move law is stated over.
    id: u64,
};

/// The unified keyed reactive map (`#reactivemap`): keys `K` map to per-entry
/// reactive nodes of the comptime-fixed [`EntryKind`], with reactive membership +
/// order. See the module docs and the [`SourceMap`] / [`ComputedMap`] specializations.
pub fn ReactiveMap(comptime K: type, comptime V: type, comptime entry_kind: EntryKind) type {
    return struct {
        /// One entry's payload. The cached value plus its **own** version, so a
        /// value write is observable independently of membership and order —
        /// the third reader class the fixtures assert. Without it, `set` on an
        /// existing key changed nothing any reader could see.
        pub const Entry = struct {
            value: V,
            /// Bumped only by a write to this entry — the value reader class.
            version: u64 = 0,
            /// Birth id. Never changes for the life of the entry, which is what
            /// makes it an identity rather than a change counter.
            id: u64,
        };

        ctx: *Context,
        /// Present set + authoritative order + the move algebra, shared verbatim
        /// with the thread-safe and async flavors. The payload is the cached
        /// value: this flavor is not graph-backed (see the module docs).
        core: KeyedOrder(K, Entry),
        /// Membership version — bumped on add/remove only. `len` / `contains`
        /// readers subscribe here.
        membership_version: u64 = 0,
        /// Monotonic source of entry birth ids. Never reused within a map, so a
        /// remove-then-re-mint is distinguishable from a reorder.
        next_entry_id: u64 = 0,
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
                .core = KeyedOrder(K, Entry).init(ctx.allocator),
                .allocator = ctx.allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.core.deinit();
        }

        /// Mint the entry for `key` with `value` (assumes `key` is absent),
        /// recording membership + order. Bumps both the membership and order
        /// versions: a new key changes the set identity and the ordered key list.
        fn mint(self: *Self, key: K, value: V) !void {
            const id = self.next_entry_id;
            self.next_entry_id += 1;
            const res = try self.core.insert(key, .{ .value = value, .id = id });
            if (res.mutation == .changed) {
                self.membership_version += 1;
                self.order_version += 1;
            }
        }

        /// Get the value at `key`, minting the entry via `factory(key)` first if
        /// the key is absent — the mint-on-access recipe. For a [`ComputedMap`] this
        /// is the **lazy materialization** pull; for a [`SourceMap`] it seeds an
        /// input cell. Re-reading an existing key returns its current value
        /// without re-running the factory (the present set only grows).
        pub fn getOrInsertWith(self: *Self, key: K, factory: Factory(K, V)) !V {
            if (self.core.get(key)) |e| return e.value; // warm: already present.
            const value = factory.call(key);
            try self.mint(key, value);
            return value;
        }

        /// Read the value at `key` if present, else `null`. Non-minting.
        pub fn get(self: *const Self, key: K) ?V {
            const e = self.core.get(key) orelse return null;
            return e.value;
        }

        /// The entry's identity for `key`, or `null` if absent.
        ///
        /// The Core-surface `handle`. This flavor is not graph-backed, so there
        /// is no node id to return; identity here is the entry's **birth id**,
        /// which survives value writes and reorders and changes only on a
        /// remove-then-re-mint. That is exactly what the atomic-move law is
        /// stated over, so `handle_stable` is assertable — but it carries no
        /// dependents and no lineage, which is why this binding is marked
        /// partial on the Core row rather than green.
        pub fn handle(self: *const Self, key: K) ?EntryHandle {
            const e = self.core.get(key) orelse return null;
            return .{ .id = e.id };
        }

        /// The value version for `key`, or `null` if absent. Bumped only by a
        /// write to that entry — never by membership or order changes.
        pub fn valueVersion(self: *const Self, key: K) ?u64 {
            const e = self.core.get(key) orelse return null;
            return e.version;
        }

        /// Remove `key`'s entry. Bumps membership + order. Returns whether the key
        /// was present.
        pub fn remove(self: *Self, key: K) bool {
            const res = self.core.remove(key);
            if (res.mutation == .unchanged) return false;
            self.membership_version += 1;
            self.order_version += 1;
            return true;
        }

        /// Reactive snapshot of the keys in their current order — order readers
        /// (add/remove **and** move/reorder), not per-entry value changes.
        pub fn keys(self: *const Self) []const K {
            return self.core.keys();
        }

        /// The currently-materialized (present) keys, in first-materialization
        /// order. Alias for [`keys`].
        pub fn presentKeys(self: *const Self) []const K {
            return self.core.keys();
        }

        /// Number of currently-materialized (present) entries.
        pub fn presentCount(self: *const Self) usize {
            return self.core.len();
        }

        /// Whether `key` is currently materialized (present). Non-reactive.
        pub fn isPresent(self: *const Self, key: K) bool {
            return self.core.contains(key);
        }

        /// Current 0-based position of `key` in the order, or `null` if absent.
        pub fn position(self: *const Self, key: K) ?usize {
            return self.core.position(key);
        }

        /// Reactive entry count. Membership readers subscribe here.
        pub fn len(self: *const Self) usize {
            return self.core.len();
        }

        /// Reactive emptiness check.
        pub fn isEmpty(self: *const Self) bool {
            return self.core.len() == 0;
        }

        /// Reactive membership test for `key`.
        pub fn contains(self: *const Self, key: K) bool {
            return self.core.contains(key);
        }

        /// Current membership version (bumped on add/remove).
        pub fn membershipVersion(self: *const Self) u64 {
            return self.membership_version;
        }

        /// Current order version (bumped on add/remove and reorder).
        pub fn orderVersion(self: *const Self) u64 {
            return self.order_version;
        }

        /// This map's entry kind ([`EntryKind.source`] for a [`SourceMap`],
        /// [`EntryKind.computed`] for a [`ComputedMap`]).
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
            return self.settleMove(self.core.moveTo(key, index));
        }

        /// Atomically move `key` to sit immediately **before** `before_key`.
        /// Order signal only.
        pub fn moveBefore(self: *Self, key: K, before_key: K) bool {
            return self.settleMove(self.core.moveBefore(key, before_key));
        }

        /// Atomically move `key` to sit immediately **after** `after_key`.
        /// Order signal only.
        pub fn moveAfter(self: *Self, key: K, after_key: K) bool {
            return self.settleMove(self.core.moveAfter(key, after_key));
        }

        /// Bump the order version iff the order actually changed, and report
        /// whether the move could be expressed. Shared by all three `move*`.
        fn settleMove(self: *Self, outcome: Move) bool {
            if (outcome.changed()) self.order_version += 1;
            return outcome.isPresent();
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

        // --- SourceMap-only surface: eager value-minting + `set` ---

        /// Return the value for `key`, minting it with `value` on first access
        /// (eager value-minting). Adding a new key bumps membership + order;
        /// re-fetching an existing key returns its current value without a bump.
        /// Cell-only: compile error on a slot map.
        pub fn entry(self: *Self, key: K, value: V) !V {
            if (entry_kind != .source) @compileError("ReactiveMap.entry is only valid on cell (input) maps");
            if (self.core.get(key)) |e| return e.value;
            try self.mint(key, value);
            return value;
        }

        /// Like [`entry`] but the default is produced by `default_fn` only when
        /// the key is absent. Cell-only.
        pub fn entryWith(self: *Self, key: K, default_fn: *const fn () V) !V {
            if (entry_kind != .source) @compileError("ReactiveMap.entryWith is only valid on cell (input) maps");
            if (self.core.get(key)) |e| return e.value;
            const value = default_fn();
            try self.mint(key, value);
            return value;
        }

        /// Set the value at `key`, inserting a new entry (and bumping membership +
        /// order) if absent. Updating an existing entry leaves membership and order
        /// untouched and invalidates only that entry's value axis. An equal-value
        /// set is a no-op (PartialEq guard). Cell-only: a derived [`ComputedMap`] slot
        /// is not writable.
        pub fn set(self: *Self, key: K, value: V) !void {
            if (entry_kind != .source) @compileError("ReactiveMap.set is only valid on cell (input) maps");
            if (self.core.getPtr(key)) |ep| {
                if (std.meta.eql(ep.value, value)) return; // PartialEq guard.
                // Value axis only — membership/order untouched. The per-entry
                // version bump is what makes that observable to a reader.
                ep.value = value;
                ep.version +%= 1;
                return;
            }
            try self.mint(key, value);
        }

        // --- ComputedMap-only surface: the eager pre-mint helper ---

        /// **Eager materialization**: pre-mint a derived slot for every key in
        /// `all_keys` via `factory`, up front. Observationally identical to minting
        /// each key lazily on first read ([`getOrInsertWith`]) — it only changes
        /// *when* the nodes are allocated. Slot-only.
        pub fn materializeAll(self: *Self, all_keys: []const K, factory: Factory(K, V)) !void {
            if (entry_kind != .computed) @compileError("ReactiveMap.materializeAll is only valid on slot (derived) maps");
            for (all_keys) |key| _ = try self.getOrInsertWith(key, factory);
        }
    };
}

/// A keyed **input-cell** map: every entry is a settable input cell. The
/// `SourceMap` specialization of [`ReactiveMap`] adds cell-only `set` and eager
/// value-minting (`entry` / `entryWith`) on top of the shared reactive surface.
pub fn SourceMap(comptime K: type, comptime V: type) type {
    return ReactiveMap(K, V, .source);
}

/// A keyed **derived-slot** map: every entry is a derived slot.
/// [`getOrInsertWith`](ReactiveMap.getOrInsertWith) mints a slot on first access
/// (lazy materialization); [`materializeAll`](ReactiveMap.materializeAll)
/// pre-mints the keyset (eager). A slot's value is derived, so `ComputedMap` has **no
/// `set`**.
pub fn ComputedMap(comptime K: type, comptime V: type) type {
    return ReactiveMap(K, V, .computed);
}

/// Deprecated: renamed to [`SourceMap`] when the v2 kernel renamed the node
/// kinds to `Source` / `Computed`. Kept as an alias so existing callers keep
/// compiling; use `SourceMap` in new code.
pub const CellMap = SourceMap;

/// Deprecated: renamed to [`ComputedMap`] when the v2 kernel renamed the node
/// kinds to `Source` / `Computed`. Kept as an alias so existing callers keep
/// compiling; use `ComputedMap` in new code.
pub const SlotMap = ComputedMap;

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

    var map = SourceMap([]const u8, i32).init(ctx);
    defer map.deinit();

    try testing.expectEqual(@as(i32, 1), try map.entry("a", 1));
    // Same key -> cached value; the second default is ignored.
    try testing.expectEqual(@as(i32, 1), try map.entry("a", 999));
    try testing.expectEqual(@as(usize, 1), map.len());
}

test "lazily/reactive_map: set inserts then updates in place" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var map = SourceMap([]const u8, i32).init(ctx);
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

    var map = SourceMap([]const u8, i32).init(ctx);
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

    var map = SourceMap([]const u8, i32).init(ctx);
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

    var map = ComputedMap(u32, u32).init(ctx);
    defer map.deinit();

    try testing.expectEqual(@as(u32, 14), try map.getOrInsertWith(7, Factory(u32, u32).pure(timesTwo)));
    try testing.expectEqual(@as(usize, 1), map.presentCount());
    try testing.expect(map.isPresent(7));
    // Same key -> same value; factory NOT re-run (timesThree would give 21).
    try testing.expectEqual(@as(u32, 14), try map.getOrInsertWith(7, Factory(u32, u32).pure(timesThree)));
    try testing.expectEqual(@as(?u32, 14), map.get(7));
}

test "lazily/reactive_map: ComputedMap materializeAll is eager" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var map = ComputedMap(u32, u32).init(ctx);
    defer map.deinit();
    try map.materializeAll(&.{ 0, 1, 2, 5, 9 }, Factory(u32, u32).pure(timesThree));
    try testing.expectEqual(@as(usize, 5), map.presentCount());
    for ([_]u32{ 0, 1, 2, 5, 9 }) |k| try testing.expect(map.isPresent(k));
    try testing.expectEqual(@as(?u32, 15), map.get(5));
    try testing.expectEqual(EntryKind.computed, map.entryKind());
}

test "lazily/reactive_map: ComputedMap lazy vs eager observe identically" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var eager_map = ComputedMap(u32, u32).init(ctx);
    defer eager_map.deinit();
    try eager_map.materializeAll(&.{ 0, 1, 2, 5, 9 }, Factory(u32, u32).pure(timesThree));

    var lazy_map = ComputedMap(u32, u32).init(ctx);
    defer lazy_map.deinit();
    for ([_]u32{ 0, 1, 2, 5, 9 }) |k| {
        try testing.expectEqual(eager_map.get(k).?, try lazy_map.getOrInsertWith(k, Factory(u32, u32).pure(timesThree)));
    }
}

test "lazily/reactive_map: present set is monotone across reads" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var map = ComputedMap(u32, u32).init(ctx);
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

    var map = SourceMap(u32, u32).init(ctx);
    defer map.deinit();

    try testing.expectEqual(@as(u32, 7), try map.entry(7, 7));
    try map.set(7, 100);
    try testing.expectEqual(@as(?u32, 100), map.get(7));
    try testing.expectEqual(EntryKind.source, map.entryKind());
    _ = identity; // referenced to keep helper parity with sibling flavors
}

test "lazily/reactive_map: cell map materialized on entry in any use" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    const cell_keys = [_][]const u8{ "a", "b", "c" };
    var map = SourceMap([]const u8, u32).init(ctx);
    defer map.deinit();
    for (cell_keys) |k| _ = try map.entry(k, 0);
    try testing.expectEqual(EntryKind.source, map.entryKind());
    try testing.expectEqual(@as(usize, 3), map.presentCount());
}

test "lazily/reactive_map: atomic move bumps order only, preserves membership + value" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var map = SourceMap([]const u8, i32).init(ctx);
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

    var map = SourceMap([]const u8, i32).init(ctx);
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

    var map = SourceMap(i32, i32).init(ctx);
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
        SourceMap(u32, u32).invalidates(.set_value),
    );
    try testing.expectEqual(
        InvalidateFlags{ .value = false, .membership = true, .order = true },
        SourceMap(u32, u32).invalidates(.insert),
    );
    try testing.expectEqual(
        InvalidateFlags{ .value = false, .membership = true, .order = true },
        SourceMap(u32, u32).invalidates(.remove),
    );
    try testing.expectEqual(
        InvalidateFlags{ .value = false, .membership = false, .order = true },
        SourceMap(u32, u32).invalidates(.move_to),
    );
}

// ---------------------------------------------------------------------------
// lazily-spec conformance fixture replay
// `../lazily-spec/conformance/materialization/*.json` (model: ComputedMap) — the
// executable form of the `lazily-formal` Materialization theorems (mirrors
// lazily-rs `tests/materialization_conformance.rs`). Eager = pre-mint loop
// (`materializeAll`); lazy = mint-on-access (`getOrInsertWith`).
// ---------------------------------------------------------------------------

const json = std.json;
const SPEC_DIR = "../lazily-spec/conformance/materialization";
const FV = i64;

/// Reads through the runtime conformance manifest recorder
/// (#lazilyupgradeconformance): naming a fixture is not replaying it, so the
/// coverage guard is fed by observed reads rather than a source grep.
const readFixtureFile = @import("conformance_manifest.zig").specReadFile;

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

const Slots = ComputedMap([]const u8, FV);
const Cells = SourceMap([]const u8, FV);

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
    // modelled by a SourceMap over the cell entries and a ComputedMap over the slot
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
        // Forward-compatible: the fixture may spell the kinds either the frozen
        // wire way (`"cell"` / `"slot"`) or the v2 kernel way (`"source"` /
        // `"computed"`). Anything else is a hard error.
        switch (try EntryKind.fromWireName(kind)) {
            .source => try cell_keys.append(testing.allocator, key),
            .computed => try slot_keys.append(testing.allocator, key),
        }
    }

    // Eager build: every entry present (cells via entry, slots via materializeAll).
    var eager_cells = Cells.init(ctx);
    defer eager_cells.deinit();
    for (cell_keys.items) |k| _ = try eager_cells.entry(k, lookup.map.get(k).?);
    var eager_slots = Slots.init(ctx);
    defer eager_slots.deinit();
    try eager_slots.materializeAll(slot_keys.items, lookup.factory());
    try testing.expectEqual(EntryKind.source, eager_cells.entryKind());
    try testing.expectEqual(EntryKind.computed, eager_slots.entryKind());
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

test "lazily/reactive_map: deprecated CellMap/SlotMap aliases still resolve" {
    try testing.expect(CellMap(u32, u32) == SourceMap(u32, u32));
    try testing.expect(SlotMap(u32, u32) == ComputedMap(u32, u32));
    try testing.expectEqual(EntryKind.source, CellMap(u32, u32).kind);
    try testing.expectEqual(EntryKind.computed, SlotMap(u32, u32).kind);
}

test "lazily/reactive_map: deprecated EntryKind.cell/.slot constants still resolve" {
    try testing.expectEqual(EntryKind.source, EntryKind.cell);
    try testing.expectEqual(EntryKind.computed, EntryKind.slot);
}

test "lazily/reactive_map: EntryKind wire spelling stays cell/slot after the tag rename" {
    // Frozen cross-binding wire contract: the v2 tag rename must NOT reach the
    // wire. `@tagName` now says source/computed, so wireName is an explicit map.
    try testing.expectEqualStrings("cell", EntryKind.source.wireName());
    try testing.expectEqualStrings("slot", EntryKind.computed.wireName());
    try testing.expectEqualStrings("source", @tagName(EntryKind.source));
    try testing.expectEqualStrings("computed", @tagName(EntryKind.computed));
}

test "lazily/reactive_map: EntryKind.fromWireName accepts both spellings, rejects others" {
    try testing.expectEqual(EntryKind.source, try EntryKind.fromWireName("cell"));
    try testing.expectEqual(EntryKind.source, try EntryKind.fromWireName("source"));
    try testing.expectEqual(EntryKind.computed, try EntryKind.fromWireName("slot"));
    try testing.expectEqual(EntryKind.computed, try EntryKind.fromWireName("computed"));
    // No silent default: anything else is a hard error.
    try testing.expectError(error.UnknownEntryKind, EntryKind.fromWireName("signal"));
    try testing.expectError(error.UnknownEntryKind, EntryKind.fromWireName(""));
    try testing.expectError(error.UnknownEntryKind, EntryKind.fromWireName("Cell"));
    // Round-trip: the wire name a kind emits parses back to that kind.
    try testing.expectEqual(EntryKind.source, try EntryKind.fromWireName(EntryKind.source.wireName()));
    try testing.expectEqual(EntryKind.computed, try EntryKind.fromWireName(EntryKind.computed.wireName()));
}

