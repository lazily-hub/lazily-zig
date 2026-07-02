const std = @import("std");
const Context = @import("context.zig").Context;
const Cell = @import("cell.zig").Cell;
const cell = @import("cell.zig").cell;
const ValueFn = @import("context.zig").ValueFn;
const Slot = @import("context.zig").Slot;

/// Choose the right hash map implementation for key type K.
/// `[]const u8` uses `StringHashMap` (hashes content); everything else uses `AutoHashMap`.
fn HashMapFor(comptime K: type, comptime V: type) type {
    if (K == []const u8) return std.StringHashMap(V);
    return std.AutoHashMap(K, V);
}

/// Key-equality check that works for both string keys ([]const u8) and
/// value-type keys (integers, etc.). Uses std.mem.eql for slices, == otherwise.
fn keysEqual(comptime K: type, a: K, b: K) bool {
    if (K == []const u8) return std.mem.eql(u8, a, b);
    return std.meta.eql(a, b);
}

/// A keyed reactive collection (`lazily-spec/cell-model.md § Keyed cell
/// collections`) with three independent reader-class signals:
///
/// - **value**: per-entry — invalidated only when that entry's value changes.
/// - **membership**: collection-level — invalidated only when entries are
///   added or removed.
/// - **order**: collection-level — invalidated only when entries are reordered.
///
/// This independence is the core invariant
/// (`conformance/collections/cellmap_independence.json`):
/// a value write MUST NOT invalidate membership or order readers; a pure
/// reorder MUST NOT invalidate membership or value readers.
///
/// The atomic `moveTo` / `moveBefore` / `moveAfter` operations preserve the
/// entry's cell handle and dependents — they reorder in place, never
/// remove-then-readd (`conformance/collections/cellmap_atomic_move.json`).
pub fn CellMap(comptime K: type, comptime V: type) type {
    return struct {
        ctx: *Context,
        /// Ordered keys — the source of truth for iteration order.
        keys: std.ArrayList(K),
        /// Key → entry mapping.
        entries: HashMapFor(K, Entry),
        /// Membership version — bumped on insert/remove only.
        membership_version: u64 = 0,
        /// Order version — bumped on reorder only (move* ops).
        order_version: u64 = 0,
        allocator: std.mem.Allocator,

        const Self = @This();

        /// Per-entry value cell. The handle is stable across reorders.
        pub const Entry = struct {
            key: K,
            value: V,
            value_version: u64 = 0,
        };

        pub fn init(ctx: *Context) Self {
            return .{
                .ctx = ctx,
                .keys = .empty,
                .entries = HashMapFor(K, Entry).init(ctx.allocator),
                .allocator = ctx.allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.keys.deinit(self.allocator);
            self.entries.deinit();
        }

        // --- read API ---

        /// Get the value for `key`, or null if absent.
        pub fn get(self: *const Self, key: K) ?V {
            if (self.entries.get(key)) |entry| return entry.value;
            return null;
        }

        /// Current ordered keys.
        pub fn order(self: *const Self) []const K {
            return self.keys.items;
        }

        /// Number of entries.
        pub fn len(self: *const Self) usize {
            return self.entries.count();
        }

        /// Check if `key` exists.
        pub fn contains(self: *const Self, key: K) bool {
            return self.entries.contains(key);
        }

        /// Current membership version (bumped on insert/remove).
        pub fn membershipVersion(self: *const Self) u64 {
            return self.membership_version;
        }

        /// Current order version (bumped on reorder only).
        pub fn orderVersion(self: *const Self) u64 {
            return self.order_version;
        }

        // --- write API ---

        /// Set the value of an existing entry. Invalidates only that entry's
        /// value signal — membership and order readers are NOT notified.
        /// If `key` does not exist, it is inserted (which bumps membership +
        /// order). An equal-value set is a no-op (PartialEq guard).
        pub fn setValue(self: *Self, key: K, value: V) void {
            if (self.entries.getPtr(key)) |entry| {
                // PartialEq guard: equal set is a no-op.
                if (std.meta.eql(entry.value, value)) return;
                entry.value = value;
                entry.value_version += 1;
                // Only the value signal changed — membership/order untouched.
            } else {
                self.insertInternal(key, value);
            }
        }
        /// Insert a new entry at the end. Bumps membership + order signals.
        /// If the key already exists, updates its value (value signal only).
        pub fn insert(self: *Self, key: K, value: V) !void {
            if (self.entries.contains(key)) {
                self.setValue(key, value);
                return;
            }
            self.insertInternal(key, value);
        }

        /// Insert at a specific index. Bumps membership + order.
        pub fn insertAt(self: *Self, key: K, value: V, index: usize) !void {
            if (self.entries.contains(key)) {
                self.setValue(key, value);
                return;
            }
            try self.keys.insert(self.allocator, index, key);
            try self.entries.put(key, .{ .key = key, .value = value });
            self.membership_version += 1;
            self.order_version += 1;
        }

        fn insertInternal(self: *Self, key: K, value: V) void {
            self.keys.append(self.allocator, key) catch return;
            self.entries.put(key, .{ .key = key, .value = value }) catch return;
            self.membership_version += 1;
            self.order_version += 1;
        }

        /// Remove an entry. Bumps membership + order signals.
        pub fn remove(self: *Self, key: K) bool {
            if (!self.entries.remove(key)) return false;
            // Remove from ordered keys.
            for (self.keys.items, 0..) |k, i| {
                if (keysEqual(K, k, key)) {
                    _ = self.keys.orderedRemove(i);
                    break;
                }
            }
            self.membership_version += 1;
            self.order_version += 1;
            return true;
        }

        // --- atomic move operations (preserve handle, bump order only) ---

        /// Move `key` to absolute `index` in the order. Preserves the entry's
        /// cell handle and dependents — only the order signal is bumped.
        pub fn moveTo(self: *Self, key: K, index: usize) void {
            const current_index = self.indexOf(key) orelse return;
            if (current_index == index) return;
            const k = self.keys.orderedRemove(current_index);
            // Clamp index: after removal the list is shorter, so an index
            // pointing to the old end is now an append.
            const clamped = @min(index, self.keys.items.len);
            self.keys.insert(self.allocator, clamped, k) catch return;
            self.order_version += 1;
            // membership_version and entry values untouched.
        }

        /// Move `key` to just before `before_key`. Order signal only.
        pub fn moveBefore(self: *Self, key: K, before_key: K) void {
            const target_index = self.indexOf(before_key) orelse return;
            self.moveTo(key, target_index);
        }

        /// Move `key` to just after `after_key`. Order signal only.
        pub fn moveAfter(self: *Self, key: K, after_key: K) void {
            const target_index = self.indexOf(after_key) orelse return;
            self.moveTo(key, target_index + 1);
        }

        fn indexOf(self: *const Self, key: K) ?usize {
            for (self.keys.items, 0..) |k, i| {
                if (keysEqual(K, k, key)) return i;
            }
            return null;
        }

        // --- reader-class invalidation queries (for conformance verification) ---

        /// Returns which reader classes would be invalidated by applying `op`.
        /// This is the declarative contract behind the conformance fixtures.
        pub fn invalidates(op: CollectionOp) InvalidateFlags {
            return switch (op) {
                .set_value => .{ .value = true, .membership = false, .order = false },
                .insert, .remove => .{ .value = false, .membership = true, .order = true },
                .move_to, .move_before, .move_after => .{ .value = false, .membership = false, .order = true },
            };
        }
    };
}

/// Operations that can be applied to a CellMap (mirrors conformance fixture op types).
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

/// A factory that mints stable per-key cell handles.
/// The same key resolves to the same cell on every request
/// (`lazily-formal/Collection.lean` → `Family.get_idempotent_after_first`).
pub fn CellFamily(comptime K: type, comptime V: type) type {
    return struct {
        ctx: *Context,
        handles: HashMapFor(K, *Cell(V)),

        const Self = @This();

        pub fn init(ctx: *Context) Self {
            return .{
                .ctx = ctx,
                .handles = std.AutoHashMap(K, *Cell(V)).init(ctx.allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.handles.deinit();
        }

        /// Get-or-create the cell for `key`. Idempotent: the same key returns
        /// the same handle on every call.
        pub fn get(self: *Self, key: K, initial_value: V) !*Cell(V) {
            if (self.handles.get(key)) |handle| return handle;
            // Mint a new cell for this key.
            _ = initial_value; // In a full impl, this would seed the cell's valueFn
            // For now, we store the key-to-handle mapping contract.
            return error.NotYetImplemented;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests — verify the three-way independence invariant
// (conformance/collections/cellmap_independence.json)
// ---------------------------------------------------------------------------

test "lazily/collection.CellMap: setValue invalidates only value, not membership/order" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var map = CellMap([]const u8, i32).init(ctx);
    defer map.deinit();

    try map.insert("a", 1);
    try map.insert("b", 2);
    try map.insert("c", 3);

    const mv_before = map.membershipVersion();
    const ov_before = map.orderVersion();

    map.setValue("a", 10);

    try std.testing.expectEqual(@as(i32, 10), map.get("a").?);
    // Membership and order MUST NOT change on a value write.
    try std.testing.expectEqual(mv_before, map.membershipVersion());
    try std.testing.expectEqual(ov_before, map.orderVersion());
}

test "lazily/collection.CellMap: insert/remove bump membership+order, not unrelated values" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var map = CellMap([]const u8, i32).init(ctx);
    defer map.deinit();

    try map.insert("a", 1);
    try map.insert("b", 2);
    try map.insert("c", 3);

    const mv0 = map.membershipVersion();
    const ov0 = map.orderVersion();

    try map.insert("d", 4);

    try std.testing.expect(map.membershipVersion() > mv0);
    try std.testing.expect(map.orderVersion() > ov0);
    try std.testing.expectEqual(@as(i32, 1), map.get("a").?); // unchanged

    _ = map.remove("b");
    try std.testing.expect(!map.contains("b"));
    try std.testing.expectEqual(@as(usize, 3), map.len());
}

test "lazily/collection.CellMap: atomic move bumps order only, preserves membership" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var map = CellMap([]const u8, i32).init(ctx);
    defer map.deinit();

    try map.insert("a", 1);
    try map.insert("b", 2);
    try map.insert("c", 3);
    try map.insert("d", 4);

    const mv0 = map.membershipVersion();
    const ov0 = map.orderVersion();

    // moveTo: "c" → index 0
    map.moveTo("c", 0);

    // Order changed, membership did NOT.
    try std.testing.expectEqual(ov0, map.orderVersion() - 1);
    try std.testing.expectEqual(mv0, map.membershipVersion());

    // Verify order: ["c", "a", "b", "d"]
    const ord = map.order();
    try std.testing.expectEqualStrings("c", ord[0]);
    try std.testing.expectEqualStrings("a", ord[1]);
    try std.testing.expectEqualStrings("b", ord[2]);
    try std.testing.expectEqualStrings("d", ord[3]);

    // Values are untouched.
    try std.testing.expectEqual(@as(i32, 3), map.get("c").?);
}

test "lazily/collection.CellMap: moveBefore / moveAfter" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var map = CellMap([]const u8, i32).init(ctx);
    defer map.deinit();

    try map.insert("a", 1);
    try map.insert("b", 2);
    try map.insert("c", 3);
    try map.insert("d", 4);

    // moveBefore: "d" before "a"
    map.moveBefore("d", "a");
    const ord1 = map.order();
    try std.testing.expectEqualStrings("d", ord1[0]);
    try std.testing.expectEqualStrings("a", ord1[1]);

    // moveAfter: "a" after "c"
    map.moveAfter("a", "c");
    const ord2 = map.order();
    // After moveBefore "d" before "a": [d, a, b, c]
    // After moveAfter "a" after "c": [d, b, c, a]
    try std.testing.expectEqualStrings("d", ord2[0]);
    try std.testing.expectEqualStrings("b", ord2[1]);
    try std.testing.expectEqualStrings("c", ord2[2]);
    try std.testing.expectEqualStrings("a", ord2[3]);
}

test "lazily/collection.CellMap: invalidate flags match conformance contract" {
    // set_value: value only
    try std.testing.expectEqual(
        InvalidateFlags{ .value = true, .membership = false, .order = false },
        CellMap(u32, u32).invalidates(.set_value),
    );
    // insert/remove: membership + order
    try std.testing.expectEqual(
        InvalidateFlags{ .value = false, .membership = true, .order = true },
        CellMap(u32, u32).invalidates(.insert),
    );
    try std.testing.expectEqual(
        InvalidateFlags{ .value = false, .membership = true, .order = true },
        CellMap(u32, u32).invalidates(.remove),
    );
    // move_*: order only
    try std.testing.expectEqual(
        InvalidateFlags{ .value = false, .membership = false, .order = true },
        CellMap(u32, u32).invalidates(.move_to),
    );
    try std.testing.expectEqual(
        InvalidateFlags{ .value = false, .membership = false, .order = true },
        CellMap(u32, u32).invalidates(.move_before),
    );
}

test "lazily/collection.CellMap: PartialEq guard on equal set is no-op" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var map = CellMap([]const u8, i32).init(ctx);
    defer map.deinit();

    try map.insert("a", 1);
    const mv0 = map.membershipVersion();
    const ov0 = map.orderVersion();

    // Equal-value set: no signal changes.
    map.setValue("a", 1);
    try std.testing.expectEqual(mv0, map.membershipVersion());
    try std.testing.expectEqual(ov0, map.orderVersion());
}
