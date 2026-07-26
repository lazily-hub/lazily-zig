//! Graph-agnostic keyed bookkeeping core for the reactive map family.
//!
//! The three map flavors ([`ReactiveMap`](reactive_map.zig),
//! [`ThreadSafeReactiveMap`](thread_safe_reactive_map.zig),
//! [`AsyncReactiveMap`](async_reactive_map.zig)) differ in what a per-entry
//! payload *is* — a cached value, a `TsHandle`, an async node id — and in what
//! guards their state. Everything between those is the same code three times:
//! the present set, the authoritative key order, `position`, and the atomic-move
//! algebra.
//!
//! [`KeyedOrder`] is that middle, mirroring lazily-rs `src/keyed_order.rs`:
//!
//! - **no context** — it never touches a reactive node;
//! - **no payload semantics** — generic over `H`, so it neither mints nor reads;
//! - **no lock** — each flavor supplies its own (`ParkingMutex`, or none).
//!
//! Reactivity stays deliberately *out*. Mutators report what changed
//! ([`Mutation`], [`Move`]) and the owning map decides which reader-class
//! signal to bump, because that decision is context-typed.
//!
//! # The move is allocation-free, and that is load-bearing
//!
//! An earlier `moveTo` did `orderedRemove` then `insert(...) catch return
//! false`, which on allocator failure left the key **absent from `order` but
//! still present in `materialized`** — the two planes desynced, permanently, on
//! an error path that returned a plain `false`. Reordering cannot need memory:
//! the list neither grows nor shrinks. So the move is a `std.mem.rotate` over
//! the affected window, which is infallible by construction. There is no error
//! path left to desync on.

const std = @import("std");

/// Choose the right hash map implementation for key type `K`. `[]const u8` uses
/// `StringHashMap` (hashes content); everything else uses `AutoHashMap`.
pub fn HashMapFor(comptime K: type, comptime V: type) type {
    if (K == []const u8) return std.StringHashMap(V);
    return std.AutoHashMap(K, V);
}

/// Key equality for both string keys (`[]const u8`) and value-type keys.
pub fn keysEqual(comptime K: type, a: K, b: K) bool {
    if (K == []const u8) return std.mem.eql(u8, a, b);
    return std.meta.eql(a, b);
}

/// What an insert/remove did to the key set, so the owner knows whether to bump
/// its membership + order signals.
pub const Mutation = enum {
    /// The key set changed. Bump membership *and* order — an add/remove changes
    /// the ordered key list too.
    changed,
    /// Nothing changed (insert of a present key, remove of an absent one). Bump
    /// nothing: invalidating readers here would be a spurious wakeup.
    unchanged,
};

/// The outcome of an atomic ordered move.
///
/// Three-way rather than two, because "the key was present" and "the order
/// actually changed" are different questions: the public `move*` methods return
/// the former, while only the latter may bump the order signal.
pub const Move = enum {
    /// The key (or the anchor) is not in the order — nothing to move.
    absent,
    /// The key is already at the requested position. A no-op: do **not**
    /// invalidate order readers.
    unchanged,
    /// The key changed position. Bump the order signal — once. Membership is
    /// untouched: a reorder does not change set identity.
    reordered,

    /// Whether the move could be expressed at all — the `bool` the public
    /// `moveTo` / `moveBefore` / `moveAfter` return.
    pub fn isPresent(self: Move) bool {
        return self != .absent;
    }

    /// Whether the order actually changed, i.e. whether to bump the order signal.
    pub fn changed(self: Move) bool {
        return self == .reordered;
    }
};

/// The result of an insert: the payload now bound to the key (which is the
/// *existing* one if the key was already present), and whether the set grew.
pub fn Inserted(comptime H: type) type {
    return struct { handle: H, mutation: Mutation };
}

/// The result of a remove: the evicted payload if any, and whether the set shrank.
pub fn Removed(comptime H: type) type {
    return struct { handle: ?H, mutation: Mutation };
}

/// The present set plus its authoritative key order, with the move algebra.
///
/// `present` and `order` are kept in lockstep: every key in one appears exactly
/// once in the other. Every mutator preserves that on **all** paths, including
/// failure paths.
pub fn KeyedOrder(comptime K: type, comptime H: type) type {
    return struct {
        /// Present set: key → per-entry payload. What a payload *means* is the
        /// owning map's business; this core only stores and returns it.
        present: HashMapFor(K, H),
        /// Authoritative key list. Insertion-ordered until an atomic move
        /// reorders it; the snapshot returned by `keys`.
        order: std.ArrayList(K),
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .present = HashMapFor(K, H).init(allocator),
                .order = .empty,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.order.deinit(self.allocator);
            self.present.deinit();
        }

        /// The payload for `key`, if present.
        pub fn get(self: *const Self, key: K) ?H {
            return self.present.get(key);
        }

        /// A mutable pointer to `key`'s payload, for in-place value updates that
        /// do not touch either plane.
        pub fn getPtr(self: *Self, key: K) ?*H {
            return self.present.getPtr(key);
        }

        /// Whether `key` is in the present set.
        pub fn contains(self: *const Self, key: K) bool {
            return self.present.contains(key);
        }

        /// Insert `handle` at `key`, appending to the order. If `key` is already
        /// present the **existing** payload is kept (first writer wins, so a key
        /// keeps a stable entry identity) and `handle` is discarded.
        pub fn insert(self: *Self, key: K, handle: H) !Inserted(H) {
            if (self.present.get(key)) |existing| {
                return .{ .handle = existing, .mutation = .unchanged };
            }
            // Reserve the order slot BEFORE publishing to the present set, so an
            // allocator failure cannot leave a key in one plane and not the other.
            try self.order.append(self.allocator, key);
            errdefer _ = self.order.pop();
            try self.present.put(key, handle);
            return .{ .handle = handle, .mutation = .changed };
        }

        /// Remove `key` from both planes, returning its payload if present. The
        /// caller is responsible for tearing down whatever the payload denotes.
        pub fn remove(self: *Self, key: K) Removed(H) {
            const handle = self.present.get(key) orelse {
                return .{ .handle = null, .mutation = .unchanged };
            };
            _ = self.present.remove(key);
            if (self.position(key)) |idx| _ = self.order.orderedRemove(idx);
            return .{ .handle = handle, .mutation = .changed };
        }

        /// Snapshot of the keys in their current order. Borrowed, not owned.
        pub fn keys(self: *const Self) []const K {
            return self.order.items;
        }

        /// Number of present entries.
        pub fn len(self: *const Self) usize {
            return self.order.items.len;
        }

        /// Current 0-based position of `key` in the order, or `null` if absent.
        pub fn position(self: *const Self, key: K) ?usize {
            for (self.order.items, 0..) |k, i| {
                if (keysEqual(K, k, key)) return i;
            }
            return null;
        }

        /// Atomically move `key` to `index`.
        ///
        /// The entry keeps the **same** payload and its identity — unlike a
        /// remove + re-mint, which reallocates and bumps membership twice.
        /// `index` is clamped to `[0, len)`. Infallible: see the module docs.
        pub fn moveTo(self: *Self, key: K, index: usize) Move {
            const from = self.position(key) orelse return .absent;
            if (self.order.items.len == 0) return .absent;
            const to = @min(index, self.order.items.len - 1);
            if (from == to) return .unchanged;
            const items = self.order.items;
            if (from < to) {
                // Rotating the window [from, to] left by one carries items[from]
                // to `to` and shifts the rest down by one.
                std.mem.rotate(K, items[from .. to + 1], 1);
            } else {
                // Rotating the window [to, from] left by (from - to) — i.e. right
                // by one — carries items[from] to `to`.
                std.mem.rotate(K, items[to .. from + 1], from - to);
            }
            return .reordered;
        }

        /// Atomically move `key` to sit immediately **before** `anchor`.
        ///
        /// The target index is not simply `position(anchor)`: removing `key`
        /// first shifts the anchor left by one whenever `key` precedes it. Without
        /// that adjustment, moving a key rightwards past its anchor lands it
        /// *after* the anchor — which is what this binding used to do.
        pub fn moveBefore(self: *Self, key: K, anchor: K) Move {
            const anchor_idx = self.position(anchor) orelse return .absent;
            const from = self.position(key) orelse return .absent;
            const target = if (from < anchor_idx) anchor_idx - 1 else anchor_idx;
            return self.moveTo(key, target);
        }

        /// Atomically move `key` to sit immediately **after** `anchor`. Same
        /// shift adjustment as [`moveBefore`].
        pub fn moveAfter(self: *Self, key: K, anchor: K) Move {
            const anchor_idx = self.position(anchor) orelse return .absent;
            const from = self.position(key) orelse return .absent;
            const target = if (from <= anchor_idx) anchor_idx else anchor_idx + 1;
            return self.moveTo(key, target);
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn seeded(keys: []const []const u8) !KeyedOrder([]const u8, u32) {
    var core = KeyedOrder([]const u8, u32).init(testing.allocator);
    for (keys, 0..) |k, i| _ = try core.insert(k, @intCast(i));
    return core;
}

fn expectOrder(core: *const KeyedOrder([]const u8, u32), want: []const []const u8) !void {
    const got = core.keys();
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
}

test "lazily/keyed_order: insert appends and reports growth" {
    var core = try seeded(&.{});
    defer core.deinit();
    try testing.expectEqual(Mutation.changed, (try core.insert("a", 1)).mutation);
    try testing.expectEqual(Mutation.changed, (try core.insert("b", 2)).mutation);
    try expectOrder(&core, &.{ "a", "b" });
    try testing.expectEqual(@as(usize, 2), core.len());
}

test "lazily/keyed_order: reinsert keeps the original payload and reports no change" {
    var core = try seeded(&.{"a"});
    defer core.deinit();
    const res = try core.insert("a", 99);
    // First writer wins: the key keeps a stable entry identity, and the caller
    // learns not to bump membership.
    try testing.expectEqual(Mutation.unchanged, res.mutation);
    try testing.expectEqual(@as(u32, 0), res.handle);
    try testing.expectEqual(@as(?u32, 0), core.get("a"));
    try expectOrder(&core, &.{"a"});
}

test "lazily/keyed_order: remove clears both planes" {
    var core = try seeded(&.{ "a", "b", "c" });
    defer core.deinit();
    const res = core.remove("b");
    try testing.expectEqual(Mutation.changed, res.mutation);
    try testing.expectEqual(@as(?u32, 1), res.handle);
    try expectOrder(&core, &.{ "a", "c" });
    try testing.expect(!core.contains("b"));
    try testing.expectEqual(@as(?usize, null), core.position("b"));
    // Absent remove is inert.
    try testing.expectEqual(Mutation.unchanged, core.remove("b").mutation);
}

test "lazily/keyed_order: moveTo reorders and clamps" {
    var core = try seeded(&.{ "a", "b", "c", "d" });
    defer core.deinit();
    try testing.expectEqual(Move.reordered, core.moveTo("b", 3));
    try expectOrder(&core, &.{ "a", "c", "d", "b" });
    // Out-of-range index clamps to the last slot rather than panicking.
    try testing.expectEqual(Move.reordered, core.moveTo("a", 99));
    try expectOrder(&core, &.{ "c", "d", "b", "a" });
    // ...and back down to the front.
    try testing.expectEqual(Move.reordered, core.moveTo("a", 0));
    try expectOrder(&core, &.{ "a", "c", "d", "b" });
}

test "lazily/keyed_order: moveTo to the same position is unchanged, not reordered" {
    var core = try seeded(&.{ "a", "b", "c" });
    defer core.deinit();
    // The distinction the order signal depends on: a no-op move must not
    // invalidate order readers.
    try testing.expectEqual(Move.unchanged, core.moveTo("b", 1));
    try testing.expect(core.moveTo("b", 1).isPresent());
    try testing.expect(!core.moveTo("b", 1).changed());
    try expectOrder(&core, &.{ "a", "b", "c" });
}

test "lazily/keyed_order: moving an absent key or anchor is absent" {
    var core = try seeded(&.{"a"});
    defer core.deinit();
    try testing.expectEqual(Move.absent, core.moveTo("zz", 0));
    try testing.expect(!core.moveTo("zz", 0).isPresent());
    try testing.expectEqual(Move.absent, core.moveBefore("zz", "a"));
    try testing.expectEqual(Move.absent, core.moveBefore("a", "zz"));
    try testing.expectEqual(Move.absent, core.moveAfter("a", "zz"));
}

test "lazily/keyed_order: moveBefore lands ahead of the anchor from either side" {
    // Rightwards past the anchor — the case this binding used to get wrong,
    // landing the key AFTER the anchor.
    var right = try seeded(&.{ "a", "b", "c", "d" });
    defer right.deinit();
    try testing.expectEqual(Move.reordered, right.moveBefore("a", "d"));
    try expectOrder(&right, &.{ "b", "c", "a", "d" });

    // Leftwards ahead of the anchor.
    var left = try seeded(&.{ "a", "b", "c", "d" });
    defer left.deinit();
    try testing.expectEqual(Move.reordered, left.moveBefore("d", "a"));
    try expectOrder(&left, &.{ "d", "a", "b", "c" });
}

test "lazily/keyed_order: moveAfter lands behind the anchor from either side" {
    var right = try seeded(&.{ "a", "b", "c", "d" });
    defer right.deinit();
    try testing.expectEqual(Move.reordered, right.moveAfter("a", "c"));
    try expectOrder(&right, &.{ "b", "c", "a", "d" });

    var left = try seeded(&.{ "a", "b", "c", "d" });
    defer left.deinit();
    try testing.expectEqual(Move.reordered, left.moveAfter("d", "a"));
    try expectOrder(&left, &.{ "a", "d", "b", "c" });
}

test "lazily/keyed_order: moving relative to an adjacent anchor is a no-op" {
    var core = try seeded(&.{ "a", "b", "c" });
    defer core.deinit();
    try testing.expectEqual(Move.unchanged, core.moveBefore("a", "b"));
    try testing.expectEqual(Move.unchanged, core.moveAfter("c", "b"));
    try expectOrder(&core, &.{ "a", "b", "c" });
}

test "lazily/keyed_order: the two planes never desync" {
    var core = try seeded(&.{ "a", "b", "c", "d", "e" });
    defer core.deinit();
    _ = core.moveTo("e", 0);
    _ = core.remove("c");
    _ = core.moveBefore("a", "e");
    _ = try core.insert("f", 5);
    _ = core.moveAfter("b", "f");

    try testing.expectEqual(core.len(), core.keys().len);
    for (core.keys()) |k| {
        try testing.expect(core.contains(k));
        try testing.expect(core.position(k) != null);
    }
    for ([_][]const u8{ "a", "b", "d", "e", "f" }) |k| {
        try testing.expect(core.position(k) != null);
    }
    try testing.expect(!core.contains("c"));
}

test "lazily/keyed_order: a move under a failing allocator cannot desync the planes" {
    // The regression guard for the original defect. `moveTo` used to
    // `orderedRemove` then `insert(...) catch return false`, so an allocator
    // failure dropped the key from `order` while leaving it in `present`.
    // The rotate-based move never allocates, so a zero-capacity failing
    // allocator cannot perturb it at all.
    var core = KeyedOrder([]const u8, u32).init(testing.allocator);
    defer core.deinit();
    for ([_][]const u8{ "a", "b", "c", "d" }, 0..) |k, i| _ = try core.insert(k, @intCast(i));

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    core.allocator = failing.allocator();

    try testing.expectEqual(Move.reordered, core.moveTo("a", 3));
    try expectOrder(&core, &.{ "b", "c", "d", "a" });
    try testing.expectEqual(core.len(), core.keys().len);
    for (core.keys()) |k| try testing.expect(core.contains(k));

    core.allocator = testing.allocator;
}
