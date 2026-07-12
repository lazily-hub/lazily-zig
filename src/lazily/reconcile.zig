const std = @import("std");
const cell_tree = @import("cell_tree.zig");

/// Keyed reconciliation diff op. Mirrors lazily-rs `DiffOp` (`reconcile.rs`).
/// When applied in emitted order — removes first, then inserts/moves
/// left-to-right by index, then updates — they transform the old sequence
/// into the new one. Reordering is move-minimized: keys already in relative
/// order (the LIS over prior indices) do NOT move; only the remainder emit a
/// move. See `lazily-spec/cell-model.md § Keyed reconciliation`.
pub fn DiffOp(comptime K: type, comptime V: type) type {
    return union(enum) {
        insert: struct { key: K, value: V, index: usize },
        remove: struct { key: K },
        move: struct { key: K, to: usize },
        update: struct { key: K, value: V },

        pub const Insert = struct { key: K, value: V, index: usize };
        pub const Remove = struct { key: K };
        pub const Move = struct { key: K, to: usize };
        pub const Update = struct { key: K, value: V };
    };
}

/// Longest strictly-increasing subsequence indices (patience sort, O(n log n)).
/// Returns the indices into `seq` (not the values). Mirrors lazily-rs
/// `longest_increasing_subsequence` (`reconcile.rs:211-252`).
pub fn longestIncreasingSubsequence(
    allocator: std.mem.Allocator,
    seq: []const usize,
) ![]usize {
    if (seq.len == 0) return &.{};
    var tails = std.ArrayList(usize).empty;
    defer tails.deinit(allocator);
    var prev = try allocator.alloc(usize, seq.len);
    defer allocator.free(prev);
    @memset(prev, std.math.maxInt(usize));

    for (seq, 0..) |val, i| {
        // Binary search for the first tail whose seq value is >= val (strict LIS).
        var lo: usize = 0;
        var hi: usize = tails.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (seq[tails.items[mid]] < val) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo > 0) prev[i] = tails.items[lo - 1];
        if (lo == tails.items.len) {
            try tails.append(allocator, i);
        } else {
            tails.items[lo] = i;
        }
    }

    var out = std.ArrayList(usize).empty;
    errdefer out.deinit(allocator);
    var k: usize = tails.items[tails.items.len - 1];
    while (true) {
        try out.append(allocator, k);
        if (prev[k] == std.math.maxInt(usize)) break;
        k = prev[k];
    }
    std.mem.reverse(usize, out.items);
    return out.toOwnedSlice(allocator);
}

/// A key/value pair in sequence order (used by `reconcile`).
pub fn KV(comptime K: type, comptime V: type) type {
    return struct { key: K, value: V };
}

/// Diff two keyed sequences by stable key, emitting the move-minimized
/// `{insert, remove, move, update}` op set. Mirrors lazily-rs `reconcile`
/// (`reconcile.rs:64-128`).
pub fn reconcile(
    comptime K: type,
    comptime V: type,
    allocator: std.mem.Allocator,
    old: []const KV(K, V),
    new: []const KV(K, V),
) ![]DiffOp(K, V) {
    var ops = std.ArrayList(DiffOp(K, V)).empty;
    errdefer ops.deinit(allocator);

    const MapT = if (K == []const u8) std.StringHashMap(usize) else std.AutoHashMap(K, usize);
    var old_pos = MapT.init(allocator);
    defer old_pos.deinit();
    for (old, 0..) |o, oi| {
        try old_pos.put(o.key, oi);
    }

    var new_keys_set = try allocator.alloc(bool, old.len);
    defer allocator.free(new_keys_set);
    @memset(new_keys_set, false);
    // Build which old keys appear in new.
    for (new) |n| {
        if (old_pos.get(n.key)) |oi| {
            if (oi < new_keys_set.len) new_keys_set[oi] = true;
        }
    }

    // 1. Removes — old keys absent from new, in old order.
    for (old, 0..) |o, oi| {
        if (!new_keys_set[oi]) {
            try ops.append(allocator, .{ .remove = .{ .key = o.key } });
        }
    }

    // 2. Common keys in new order → their old indices form the LIS input.
    var common_new_idx = std.ArrayList(usize).empty;
    defer common_new_idx.deinit(allocator);
    var seq = std.ArrayList(usize).empty;
    defer seq.deinit(allocator);
    for (new, 0..) |n, ni| {
        if (old_pos.get(n.key)) |oi| {
            try common_new_idx.append(allocator, ni);
            try seq.append(allocator, oi);
        }
    }
    const lis = try longestIncreasingSubsequence(allocator, seq.items);
    defer allocator.free(lis);

    var stable = try allocator.alloc(bool, new.len);
    defer allocator.free(stable);
    @memset(stable, false);
    for (lis) |j| stable[common_new_idx.items[j]] = true;

    // 3. Inserts + Moves, left-to-right in new order.
    for (new, 0..) |n, i| {
        if (old_pos.get(n.key)) |_| {
            if (!stable[i]) {
                try ops.append(allocator, .{ .move = .{ .key = n.key, .to = i } });
            }
        } else {
            try ops.append(allocator, .{ .insert = .{ .key = n.key, .value = n.value, .index = i } });
        }
    }

    // 4. Updates — common keys whose value changed.
    for (new) |n| {
        if (old_pos.get(n.key)) |oi| {
            const changed = if (V == []const u8)
                !std.mem.eql(u8, old[oi].value, n.value)
            else
                !std.meta.eql(old[oi].value, n.value);
            if (changed) {
                try ops.append(allocator, .{ .update = .{ .key = n.key, .value = n.value } });
            }
        }
    }

    return ops.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests (mirror keyed_reconciliation_lis.json)
// ---------------------------------------------------------------------------

test "lazily/reconcile: longestIncreasingSubsequence basic" {
    const allocator = std.testing.allocator;
    const seq = [_]usize{ 1, 2, 0, 3 };
    const lis = try longestIncreasingSubsequence(allocator, &seq);
    defer allocator.free(lis);
    // LIS is [1,2,3] → indices [0,1,3].
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 3 }, lis);
}

test "lazily/reconcile: prior [a,b,c,d] -> target [b,c,a] emits {remove d, move a}" {
    const allocator = std.testing.allocator;
    const old = [_]KV([]const u8, i32){
        .{ .key = "a", .value = 1 },
        .{ .key = "b", .value = 2 },
        .{ .key = "c", .value = 3 },
        .{ .key = "d", .value = 4 },
    };
    const new = [_]KV([]const u8, i32){
        .{ .key = "b", .value = 2 },
        .{ .key = "c", .value = 3 },
        .{ .key = "a", .value = 1 },
    };
    const ops = try reconcile([]const u8, i32, allocator, &old, &new);
    defer allocator.free(ops);

    // Exactly 2 ops: remove d, move a (b and c are stable — in LIS).
    try std.testing.expectEqual(@as(usize, 2), ops.len);
    try std.testing.expect(ops[0] == .remove);
    try std.testing.expectEqualStrings("d", ops[0].remove.key);
    try std.testing.expect(ops[1] == .move);
    try std.testing.expectEqualStrings("a", ops[1].move.key);
}

test "lazily/reconcile: pure reversal is minimal (n-1 moves for n keys)" {
    const allocator = std.testing.allocator;
    const old = [_]KV(u32, u32){
        .{ .key = 1, .value = 10 },
        .{ .key = 2, .value = 20 },
        .{ .key = 3, .value = 30 },
        .{ .key = 4, .value = 40 },
    };
    const new = [_]KV(u32, u32){
        .{ .key = 4, .value = 40 },
        .{ .key = 3, .value = 30 },
        .{ .key = 2, .value = 20 },
        .{ .key = 1, .value = 10 },
    };
    const ops = try reconcile(u32, u32, allocator, &old, &new);
    defer allocator.free(ops);
    var moves: usize = 0;
    for (ops) |op| if (op == .move) {
        moves += 1;
    };
    // Reversal of 4 elements: LIS = 1, so 3 must move.
    try std.testing.expectEqual(@as(usize, 3), moves);
}
