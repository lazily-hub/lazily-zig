const std = @import("std");
const cell_tree = @import("cell_tree.zig");
const CellTree = cell_tree.CellTree;
const CellTreeNode = cell_tree.CellTreeNode;

/// A memoized semantic tree — one memo slot per node folding
/// `(node value, child derived values)`. Editing one node recomputes only its
/// ANCESTOR CHAIN (a sibling subtree's derived slot stays cached); a node edit
/// that does not change the folded result does NOT re-run a downstream consumer
/// (memo equality guard). Mirrors lazily-rs `SemTree` (`sem_tree.rs`) and the
/// `lazily-spec/cell-model.md § Memoized semantic tree` contract.
///
/// Implementation: the tree is walked once to derive per-node slots; each slot
/// records the set of ancestor slots that depend on it. A node edit marks only
/// its ancestor chain dirty (sibling subtrees are untouched by construction),
/// and re-runs the chain bottom-up. The memo guard short-circuits cascade when
/// a recomputed derived value equals the old.
pub fn SemTree(comptime Id: type, comptime V: type, comptime D: type) type {
    return struct {
        allocator: std.mem.Allocator,
        /// Derived value per node (memoized).
        derived: std.HashMap(Id, D, cell_tree.TreeIdContext(Id), std.hash_map.default_max_load_percentage),
        /// Per-node recomputation counter (for the `sibling_a_cached` /
        /// `downstream_consumer_reran` conformance assertions).
        recompute_counts: std.HashMap(Id, u64, cell_tree.TreeIdContext(Id), std.hash_map.default_max_load_percentage),
        /// Parent map: child id -> parent id (for ancestor-chain walks).
        parent_of: std.HashMap(Id, Id, cell_tree.TreeIdContext(Id), std.hash_map.default_max_load_percentage),
        root_id: Id,
        fold: *const fn (node_value: V, child_deriveds: []const D) D,

        const Self = @This();

        pub fn build(
            allocator: std.mem.Allocator,
            root: *CellTreeNode(Id, V),
            fold: *const fn (node_value: V, child_deriveds: []const D) D,
        ) !Self {
            var self = Self{
                .allocator = allocator,
                .derived = std.HashMap(Id, D, cell_tree.TreeIdContext(Id), std.hash_map.default_max_load_percentage).init(allocator),
                .recompute_counts = std.HashMap(Id, u64, cell_tree.TreeIdContext(Id), std.hash_map.default_max_load_percentage).init(allocator),
                .parent_of = std.HashMap(Id, Id, cell_tree.TreeIdContext(Id), std.hash_map.default_max_load_percentage).init(allocator),
                .root_id = root.id,
                .fold = fold,
            };
            try self.deriveNode(root);
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.derived.deinit();
            self.recompute_counts.deinit();
            self.parent_of.deinit();
        }

        /// The derived value at `id`.
        pub fn nodeValue(self: *const Self, id: Id) ?D {
            return self.derived.get(id);
        }

        pub fn rootValue(self: *const Self) ?D {
            return self.derived.get(self.root_id);
        }

        /// Number of times the derived slot at `id` has been recomputed.
        pub fn recomputeCount(self: *const Self, id: Id) u64 {
            return self.recompute_counts.get(id) orelse 0;
        }

        /// Recompute `id`'s derived value (folding its value + present child
        /// deriveds) and return whether the derived value changed.
        fn recomputeOne(self: *Self, node: *CellTreeNode(Id, V)) !bool {
            const old = self.derived.get(node.id);
            // Gather present child derived values in current child order.
            var child_ds = std.ArrayList(D).empty;
            defer child_ds.deinit(self.allocator);
            for (node.childIds()) |cid| {
                if (self.derived.get(cid)) |d| {
                    try child_ds.append(self.allocator, d);
                }
            }
            const new = self.fold(node.getValue(), child_ds.items);
            const changed = if (old) |o| !derivedEq(D, o, new) else true;
            try self.derived.put(node.id, new);
            const cur = self.recompute_counts.get(node.id) orelse 0;
            try self.recompute_counts.put(node.id, cur + 1);
            return changed;
        }

        /// Bottom-up derivation: children first, then this node folds their
        /// derived values with its own value.
        fn deriveNode(self: *Self, node: *CellTreeNode(Id, V)) !void {
            for (node.childIds()) |cid| {
                if (node.child(cid)) |child_node| {
                    try self.parent_of.put(cid, node.id);
                    try self.deriveNode(child_node);
                }
            }
            _ = try self.recomputeOne(node);
        }

        /// Apply a node-value edit. Recomputes the ancestor chain bottom-up;
        /// sibling subtrees stay cached. The memo guard stops propagation when
        /// a recomputed derived value is unchanged.
        pub fn applyEdit(self: *Self, tree_root: *CellTreeNode(Id, V), id: Id, new_value: V) !void {
            const node = findNode(Id, V, tree_root, id) orelse return error.NodeNotFound;
            node.setValue(new_value);
            // Walk id and its ancestor chain, recomputing each. Stop cascading
            // upward as soon as a recomputed derived is unchanged (memo guard).
            var current: ?Id = id;
            while (current) |cur_id| {
                const cur_node = findNode(Id, V, tree_root, cur_id) orelse break;
                const changed = try self.recomputeOne(cur_node);
                if (!changed) break; // memo guard: derived unchanged, stop cascade
                current = self.parent_of.get(cur_id);
            }
        }

        /// Apply a remove-child op: re-derive the parent's subtree.
        pub fn applyRemoveChild(
            self: *Self,
            tree_root: *CellTreeNode(Id, V),
            parent_id: Id,
            child_id: Id,
        ) !void {
            const parent = findNode(Id, V, tree_root, parent_id) orelse return error.NodeNotFound;
            if (!parent.removeChild(child_id)) return error.NodeNotFound;
            _ = self.derived.remove(child_id);
            _ = self.recompute_counts.remove(child_id);
            _ = self.parent_of.remove(child_id);
            // Recompute parent and its ancestor chain (memo guard applies).
            var current: ?Id = parent_id;
            while (current) |cur_id| {
                const cur_node = findNode(Id, V, tree_root, cur_id) orelse break;
                const changed = try self.recomputeOne(cur_node);
                if (!changed) break;
                current = self.parent_of.get(cur_id);
            }
        }
    };
}

fn derivedEq(comptime D: type, a: D, b: D) bool {
    return switch (@typeInfo(D)) {
        .pointer => |p| if (p.size == .slice) std.mem.eql(p.child, a, b) else a == b,
        else => std.meta.eql(a, b),
    };
}

fn findNode(comptime Id: type, comptime V: type, root: *CellTreeNode(Id, V), id: Id) ?*CellTreeNode(Id, V) {
    if (cell_tree.TreeIdContext(Id).eql(undefined, root.id, id)) return root;
    return findInChildren(Id, V, root, id);
}

fn findInChildren(comptime Id: type, comptime V: type, node: *CellTreeNode(Id, V), id: Id) ?*CellTreeNode(Id, V) {
    for (node.childIds()) |cid| {
        if (node.child(cid)) |child| {
            if (cell_tree.TreeIdContext(Id).eql(undefined, child.id, id)) return child;
            if (findInChildren(Id, V, child, id)) |found| return found;
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Folds used by the tests / conformance fixture replay.
// ---------------------------------------------------------------------------

fn sumFoldI64(node_value: i64, child_deriveds: []const i64) i64 {
    var total = node_value;
    for (child_deriveds) |d| total += d;
    return total;
}

fn countPositiveFoldI64(node_value: i64, child_deriveds: []const i64) i64 {
    var total: i64 = if (node_value > 0) 1 else 0;
    for (child_deriveds) |d| total += d;
    return total;
}

// ---------------------------------------------------------------------------
// Tests (mirror semtree_incremental.json scenarios)
// ---------------------------------------------------------------------------

const Tree = CellTree([]const u8, i64);
const Node = CellTreeNode([]const u8, i64);

fn buildSampleTree(allocator: std.mem.Allocator) !Tree {
    var t = try Tree.init(allocator, "root", 0);
    errdefer t.deinit();
    const a = try t.root.insertChild("a", 1);
    _ = try a.insertChild("a1", 10);
    _ = try a.insertChild("a2", 20);
    const b = try t.root.insertChild("b", 2);
    _ = try b.insertChild("b1", 100);
    return t;
}

test "lazily/sem_tree: folds whole subtree; edit recomputes only ancestor chain" {
    const allocator = std.testing.allocator;
    var tree = try buildSampleTree(allocator);
    defer tree.deinit();

    var sem = try SemTree([]const u8, i64, i64).build(allocator, tree.root, sumFoldI64);
    defer sem.deinit();

    try std.testing.expectEqual(@as(i64, 133), sem.nodeValue("root").?);
    try std.testing.expectEqual(@as(i64, 31), sem.nodeValue("a").?);
    try std.testing.expectEqual(@as(i64, 102), sem.nodeValue("b").?);

    const a_count_before = sem.recomputeCount("a");
    try sem.applyEdit(tree.root, "b1", 200);

    try std.testing.expectEqual(@as(i64, 233), sem.nodeValue("root").?);
    try std.testing.expectEqual(@as(i64, 202), sem.nodeValue("b").?);
    try std.testing.expectEqual(@as(i64, 31), sem.nodeValue("a").?);
    // Sibling isolation: a was NOT recomputed.
    try std.testing.expectEqual(a_count_before, sem.recomputeCount("a"));
}

test "lazily/sem_tree: memo guard stops propagation when result unchanged" {
    const allocator = std.testing.allocator;
    var tree = try Tree.init(allocator, "root", 0);
    defer tree.deinit();
    _ = try tree.root.insertChild("a", -1);
    _ = try tree.root.insertChild("b", 7);

    var sem = try SemTree([]const u8, i64, i64).build(allocator, tree.root, countPositiveFoldI64);
    defer sem.deinit();

    try std.testing.expectEqual(@as(i64, 1), sem.nodeValue("root").?);

    const root_before = sem.recomputeCount("root");
    // Edit b from 7 to 9 — count_positive(root) stays at 1 (memo guard).
    try sem.applyEdit(tree.root, "b", 9);
    try std.testing.expectEqual(@as(i64, 1), sem.nodeValue("root").?);
    try std.testing.expectEqual(root_before, sem.recomputeCount("root"));
}

test "lazily/sem_tree: removal updates derivation (dropped subtree)" {
    const allocator = std.testing.allocator;
    var tree = try buildSampleTree(allocator);
    defer tree.deinit();

    var sem = try SemTree([]const u8, i64, i64).build(allocator, tree.root, sumFoldI64);
    defer sem.deinit();

    try std.testing.expectEqual(@as(i64, 133), sem.nodeValue("root").?);

    try sem.applyRemoveChild(tree.root, "root", "b");
    try std.testing.expectEqual(@as(i64, 31), sem.nodeValue("root").?);
}
