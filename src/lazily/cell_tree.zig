const std = @import("std");
const Context = @import("context.zig").Context;

/// Key-equality that works for both string keys and value-type keys.
fn keysEqual(comptime K: type, a: K, b: K) bool {
    if (K == []const u8) return std.mem.eql(u8, a, b);
    return std.meta.eql(a, b);
}

/// HashMap context for Id keys that may be `[]const u8` (hashed by content)
/// or value types (hashed by bytes).
pub fn TreeIdContext(comptime K: type) type {
    return struct {
        pub fn hash(_: @This(), key: K) u64 {
            if (K == []const u8) return std.hash_map.hashString(key);
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&key));
            return h.final();
        }
        pub fn eql(_: @This(), a: K, b: K) bool {
            return keysEqual(K, a, b);
        }
    };
}

/// A CellTreeNode is one node of an ordered keyed tree. It carries a value
/// cell and the per-level reactive membership/order versions (mirroring
/// `CellMap`'s three-signal model). Child handles live in a non-reactive map
/// kept in lockstep with `order`.
///
/// Mirrors lazily-rs `CellTreeNode` (`cell_tree.rs:62-76`). Each node owns its
/// children (allocated in the caller's allocator); structural sharing is by
/// pointer aliasing (the Zig analog of `Rc`).
pub fn CellTreeNode(comptime Id: type, comptime V: type) type {
    return struct {
        id: Id,
        value: V,
        /// Ordered child ids — source of truth for iteration order.
        child_order: std.ArrayList(Id),
        /// Child id -> child node.
        children: std.HashMap(Id, *@This(), TreeIdContext(Id), std.hash_map.default_max_load_percentage),
        allocator: std.mem.Allocator,
        /// Bumped on insert/remove only.
        membership_version: u64 = 0,
        /// Bumped on reorder only (move* ops).
        order_version: u64 = 0,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, id: Id, value: V) !*Self {
            const node = try allocator.create(Self);
            node.* = .{
                .id = id,
                .value = value,
                .child_order = .empty,
                .children = std.HashMap(Id, *Self, TreeIdContext(Id), std.hash_map.default_max_load_percentage).init(allocator),
                .allocator = allocator,
            };
            return node;
        }

        pub fn deinit(self: *Self) void {
            var iter = self.children.valueIterator();
            while (iter.next()) |child_ptr| {
                child_ptr.*.deinit();
            }
            self.children.deinit();
            self.child_order.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        pub fn getValue(self: *const Self) V {
            return self.value;
        }

        pub fn setValue(self: *Self, v: V) void {
            // PartialEq guard.
            if (crdtEqVal(V, self.value, v)) return;
            self.value = v;
            // value_version is implicit: readers of this node's value see the
            // new value; derived readers are invalidated by SemTree's edge
            // subscription (not a version counter here).
        }

        pub fn childCount(self: *const Self) usize {
            return self.children.count();
        }

        pub fn containsChild(self: *const Self, id: Id) bool {
            return self.children.contains(id);
        }

        pub fn child(self: *const Self, id: Id) ?*Self {
            return self.children.get(id);
        }

        pub fn childIds(self: *const Self) []const Id {
            return self.child_order.items;
        }

        /// Insert a leaf child at the end. Idempotent if id exists.
        pub fn insertChild(self: *Self, id: Id, v: V) !*Self {
            if (self.children.get(id)) |existing| {
                existing.setValue(v);
                return existing;
            }
            const new_node = try CellTreeNode(Id, V).init(self.allocator, id, v);
            try self.child_order.append(self.allocator, id);
            try self.children.put(id, new_node);
            self.membership_version += 1;
            self.order_version += 1;
            return new_node;
        }

        /// Attach a pre-built subtree. The receiver takes ownership.
        pub fn attachChild(self: *Self, child_node: *Self) !*Self {
            if (self.children.get(child_node.id)) |existing| {
                existing.deinit();
            } else {
                try self.child_order.append(self.allocator, child_node.id);
                self.membership_version += 1;
                self.order_version += 1;
            }
            try self.children.put(child_node.id, child_node);
            return child_node;
        }

        pub fn removeChild(self: *Self, id: Id) bool {
            const removed = self.children.fetchRemove(id);
            if (removed == null) return false;
            removed.?.value.deinit();
            // Remove from ordered list.
            for (self.child_order.items, 0..) |k, i| {
                if (keysEqual(Id, k, id)) {
                    _ = self.child_order.orderedRemove(i);
                    break;
                }
            }
            self.membership_version += 1;
            self.order_version += 1;
            return true;
        }

        /// Move `id` to absolute `index` in the child order. Order only.
        pub fn moveChildTo(self: *Self, id: Id, index: usize) bool {
            const current = self.indexOf(id) orelse return false;
            if (current == index) return false;
            const k = self.child_order.orderedRemove(current);
            const clamped = @min(index, self.child_order.items.len);
            self.child_order.insert(self.allocator, clamped, k) catch return false;
            self.order_version += 1;
            return true;
        }

        pub fn moveChildBefore(self: *Self, id: Id, anchor: Id) bool {
            const target = self.indexOf(anchor) orelse return false;
            return self.moveChildTo(id, target);
        }

        pub fn moveChildAfter(self: *Self, id: Id, anchor: Id) bool {
            const target = self.indexOf(anchor) orelse return false;
            return self.moveChildTo(id, target + 1);
        }

        /// Resolve a path of ids from this node downward.
        pub fn resolvePath(self: *const Self, path: []const Id) ?*Self {
            var current: *const Self = self;
            for (path) |seg| {
                current = current.children.get(seg) orelse return null;
            }
            return @constCast(current);
        }

        fn indexOf(self: *const Self, id: Id) ?usize {
            for (self.child_order.items, 0..) |k, i| {
                if (keysEqual(Id, k, id)) return i;
            }
            return null;
        }
    };
}

fn crdtEqVal(comptime V: type, a: V, b: V) bool {
    return switch (@typeInfo(V)) {
        .pointer => |p| if (p.size == .slice) std.mem.eql(p.child, a, b) else a == b,
        else => std.meta.eql(a, b),
    };
}

/// An ordered keyed tree — composition of per-node value cells with per-level
/// membership/order reactivity. Mirrors lazily-rs `CellTree` (`cell_tree.rs`).
/// One root node; structural sharing by pointer aliasing (attach pre-built
/// subtrees). See `lazily-spec/cell-model.md § Ordered keyed tree`.
pub fn CellTree(comptime Id: type, comptime V: type) type {
    return struct {
        root: *CellTreeNode(Id, V),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, root_id: Id, root_value: V) !Self {
            return .{ .root = try CellTreeNode(Id, V).init(allocator, root_id, root_value) };
        }

        pub fn deinit(self: *Self) void {
            self.root.deinit();
        }

        pub fn rootNode(self: *Self) *CellTreeNode(Id, V) {
            return self.root;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests — per-node / per-level invariants (mirrors lazily-rs cell_tree.rs)
// ---------------------------------------------------------------------------

test "lazily/cell_tree: per-node value isolation" {
    const allocator = std.testing.allocator;
    var tree = try CellTree([]const u8, i64).init(allocator, "root", 0);
    defer tree.deinit();

    const a = try tree.root.insertChild("a", 1);
    const b = try tree.root.insertChild("b", 2);
    _ = a;
    _ = b;
    try std.testing.expectEqual(@as(usize, 2), tree.root.childCount());

    // Edit one node — only that node's value changes; sibling untouched.
    tree.root.child("a").?.setValue(100);
    try std.testing.expectEqual(@as(i64, 100), tree.root.child("a").?.getValue());
    try std.testing.expectEqual(@as(i64, 2), tree.root.child("b").?.getValue());
}

test "lazily/cell_tree: atomic move bumps order only, preserves membership" {
    const allocator = std.testing.allocator;
    var tree = try CellTree([]const u8, i64).init(allocator, "root", 0);
    defer tree.deinit();

    _ = try tree.root.insertChild("a", 1);
    _ = try tree.root.insertChild("b", 2);
    _ = try tree.root.insertChild("c", 3);

    const mv0 = tree.root.membership_version;
    const ov0 = tree.root.order_version;

    try std.testing.expect(tree.root.moveChildTo("c", 0));
    try std.testing.expectEqual(mv0, tree.root.membership_version); // membership unchanged
    try std.testing.expectEqual(ov0 + 1, tree.root.order_version); // order bumped

    const ids = tree.root.childIds();
    try std.testing.expectEqualStrings("c", ids[0]);
    try std.testing.expectEqualStrings("a", ids[1]);
    try std.testing.expectEqualStrings("b", ids[2]);
}

test "lazily/cell_tree: remove + resolvePath" {
    const allocator = std.testing.allocator;
    var tree = try CellTree([]const u8, i64).init(allocator, "root", 0);
    defer tree.deinit();

    const a = try tree.root.insertChild("a", 1);
    _ = try a.insertChild("a1", 10);

    const path = [_][]const u8{ "a", "a1" };
    try std.testing.expectEqual(@as(i64, 10), tree.root.resolvePath(&path).?.getValue());

    try std.testing.expect(tree.root.removeChild("a"));
    try std.testing.expect(tree.root.resolvePath(&path) == null);
}
