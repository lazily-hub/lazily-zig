const std = @import("std");
const lt = @import("lossless_tree.zig");
const crdt = @import("crdt.zig");
const OpId = crdt.OpId;
const LosslessTreeCrdt = lt.LosslessTreeCrdt;
const NodeSeed = lt.NodeSeed;
const LeafKind = lt.LeafKind;

const allocator = std.testing.allocator;

fn render(t: *LosslessTreeCrdt) ![]u8 {
    return t.render(allocator);
}

// Append a leaf child to `parent` after the previous sibling `after` (null =
// first child). Mirrors the fixture interpreter's in-order sibling placement.
fn leaf(t: *LosslessTreeCrdt, parent: OpId, after: ?OpId, kind: LeafKind, text: []const u8) !OpId {
    return try t.createNode(parent, after, .{ .leaf = .{ .kind = kind, .text = text } });
}

fn element(t: *LosslessTreeCrdt, parent: OpId, after: ?OpId, kind: []const u8) !OpId {
    return try t.createNode(parent, after, .{ .element = kind });
}

// ---------------------------------------------------------------------------
// exact_roundtrip fixture (Token/Trivia/Raw/Error + multibyte)
// ---------------------------------------------------------------------------

test "lazily/lossless_tree: exact_roundtrip — render(tree) == source" {
    var t = try LosslessTreeCrdt.init(allocator, 1);
    defer t.deinit();

    const heading = try element(&t, lt.root_id, null, "heading");
    const tok = try leaf(&t, heading, null, .token, "# ");
    _ = try leaf(&t, heading, tok, .raw, "Título café");
    const gap = try leaf(&t, lt.root_id, heading, .trivia, "\n\n");
    const para = try element(&t, lt.root_id, gap, "para");
    const p1 = try leaf(&t, para, null, .raw, "prix: 12€ ");
    const p2 = try leaf(&t, para, p1, .err, "```rust");
    _ = try leaf(&t, para, p2, .trivia, "\n");

    const r = try render(&t);
    defer allocator.free(r);
    try std.testing.expectEqualStrings("# Título café\n\nprix: 12€ ```rust\n", r);
    try std.testing.expectEqual(@as(usize, 8), t.liveNodeCount());
}

// ---------------------------------------------------------------------------
// one_leaf_edit_delta fixture (per-leaf text delta over multi-byte text)
// ---------------------------------------------------------------------------

test "lazily/lossless_tree: one_leaf_edit_delta — insert after multibyte char" {
    var a = try LosslessTreeCrdt.init(allocator, 1);
    defer a.deinit();
    const para = try element(&a, lt.root_id, null, "para");
    const body = try leaf(&a, para, null, .raw, "héllo");

    var b = try a.fork(2);
    defer b.deinit();

    try a.editLeaf(body, 3, 0, "X");
    const upd = try a.diff(&b.getFrontier(), allocator);
    defer a.freeUpdate(upd);
    try b.applyUpdate(upd);

    const ra = try render(&a);
    defer allocator.free(ra);
    const rb = try render(&b);
    defer allocator.free(rb);
    try std.testing.expectEqualStrings("héXllo", ra);
    try std.testing.expectEqualStrings("héXllo", rb);
}

test "lazily/lossless_tree: one_leaf_edit_delta — delete multibyte char" {
    var a = try LosslessTreeCrdt.init(allocator, 1);
    defer a.deinit();
    const para = try element(&a, lt.root_id, null, "para");
    const body = try leaf(&a, para, null, .raw, "héllo");

    var b = try a.fork(2);
    defer b.deinit();

    try a.editLeaf(body, 1, 2, "e");
    const upd = try a.diff(&b.getFrontier(), allocator);
    defer a.freeUpdate(upd);
    try b.applyUpdate(upd);

    const ra = try render(&a);
    defer allocator.free(ra);
    const rb = try render(&b);
    defer allocator.free(rb);
    try std.testing.expectEqualStrings("hello", ra);
    try std.testing.expectEqualStrings("hello", rb);
}

// ---------------------------------------------------------------------------
// split_merge fixture
// ---------------------------------------------------------------------------

test "lazily/lossless_tree: split_grows_live_nodes" {
    var a = try LosslessTreeCrdt.init(allocator, 1);
    defer a.deinit();
    const para = try element(&a, lt.root_id, null, "para");
    const body = try leaf(&a, para, null, .raw, "héllo world");

    _ = try a.splitLeaf(body, 3);

    const r = try render(&a);
    defer allocator.free(r);
    try std.testing.expectEqualStrings("héllo world", r);
    try std.testing.expectEqual(@as(usize, 3), a.liveNodeCount());
}

test "lazily/lossless_tree: split_then_merge_restores" {
    var a = try LosslessTreeCrdt.init(allocator, 1);
    defer a.deinit();
    const para = try element(&a, lt.root_id, null, "para");
    const body = try leaf(&a, para, null, .raw, "héllo world");

    const tail = try a.splitLeaf(body, 6);
    try a.mergeAdjacentLeaves(body, tail);

    const r = try render(&a);
    defer allocator.free(r);
    try std.testing.expectEqualStrings("héllo world", r);
    try std.testing.expectEqual(@as(usize, 2), a.liveNodeCount());
}

// ---------------------------------------------------------------------------
// concurrent_insert_same_parent fixture
// ---------------------------------------------------------------------------

test "lazily/lossless_tree: concurrent_insert_same_parent — both survive, deterministic order" {
    var a = try LosslessTreeCrdt.init(allocator, 1);
    defer a.deinit();
    const para = try element(&a, lt.root_id, null, "para");
    const base = try leaf(&a, para, null, .trivia, "base");

    var b = try a.fork(2);
    defer b.deinit();

    _ = try a.createNode(para, base, .{ .leaf = .{ .kind = .raw, .text = "A" } });
    _ = try b.createNode(para, base, .{ .leaf = .{ .kind = .raw, .text = "B" } });

    const u_ab = try a.diff(&b.getFrontier(), allocator);
    defer a.freeUpdate(u_ab);
    try b.applyUpdate(u_ab);
    const u_ba = try b.diff(&a.getFrontier(), allocator);
    defer b.freeUpdate(u_ba);
    try a.applyUpdate(u_ba);

    const ra = try render(&a);
    defer allocator.free(ra);
    const rb = try render(&b);
    defer allocator.free(rb);
    try std.testing.expectEqualStrings("baseAB", ra);
    try std.testing.expectEqualStrings("baseAB", rb);
    try std.testing.expectEqual(@as(usize, 4), a.liveNodeCount());
}

// ---------------------------------------------------------------------------
// concurrent_reorder_and_leaf_edit fixture (independent registers)
// ---------------------------------------------------------------------------

test "lazily/lossless_tree: concurrent_reorder_and_leaf_edit — move + edit both apply" {
    var a = try LosslessTreeCrdt.init(allocator, 1);
    defer a.deinit();
    const para = try element(&a, lt.root_id, null, "para");
    const x = try leaf(&a, para, null, .raw, "x");
    const y = try leaf(&a, para, x, .raw, "y");

    var b = try a.fork(2);
    defer b.deinit();

    try a.reorderChild(x, y); // a: move x to just after y → "yx"
    try b.editLeaf(x, 1, 0, "!"); // b: append "!" to x → "x!"

    const u_ab = try a.diff(&b.getFrontier(), allocator);
    defer a.freeUpdate(u_ab);
    try b.applyUpdate(u_ab);
    const u_ba = try b.diff(&a.getFrontier(), allocator);
    defer b.freeUpdate(u_ba);
    try a.applyUpdate(u_ba);

    const ra = try render(&a);
    defer allocator.free(ra);
    const rb = try render(&b);
    defer allocator.free(rb);
    try std.testing.expectEqualStrings("yx!", ra);
    try std.testing.expectEqualStrings("yx!", rb);
}

// ---------------------------------------------------------------------------
// non_contiguous_anti_entropy fixture (dotted frontier keeps a hole)
// ---------------------------------------------------------------------------

test "lazily/lossless_tree: non_contiguous_anti_entropy — hole then repair" {
    var a = try LosslessTreeCrdt.init(allocator, 1);
    defer a.deinit();
    const para = try element(&a, lt.root_id, null, "para");
    const base = try leaf(&a, para, null, .trivia, "0");

    var b = try a.fork(2);
    defer b.deinit();

    const one = try a.createNode(para, base, .{ .leaf = .{ .kind = .trivia, .text = "1" } });
    const two = try a.createNode(para, one, .{ .leaf = .{ .kind = .trivia, .text = "2" } });
    _ = try a.createNode(para, two, .{ .leaf = .{ .kind = .trivia, .text = "3" } });

    // Partial delivery: diff against b's frontier, hand b sorted indices [0,2].
    const full = try a.diff(&b.getFrontier(), allocator);
    defer a.freeUpdate(full);
    try std.testing.expectEqual(@as(usize, 3), full.ops.len);
    const selected = try allocator.alloc(lt.TreeOp, 2);
    selected[0] = try lt.dupOp(allocator, full.ops[0]);
    selected[1] = try lt.dupOp(allocator, full.ops[2]);
    const partial = lt.TreeUpdate{ .ops = selected };
    defer {
        for (partial.ops) |op| lt.freeOp(allocator, op);
        allocator.free(partial.ops);
    }
    try b.applyUpdate(partial);

    const rb_hole = try render(&b);
    defer allocator.free(rb_hole);
    try std.testing.expectEqualStrings("013", rb_hole);

    const repair = try a.diff(&b.getFrontier(), allocator);
    defer a.freeUpdate(repair);
    try b.applyUpdate(repair);

    const ra = try render(&a);
    defer allocator.free(ra);
    const rb = try render(&b);
    defer allocator.free(rb);
    try std.testing.expectEqualStrings("0123", ra);
    try std.testing.expectEqualStrings("0123", rb);
}

// ---------------------------------------------------------------------------
// token_trivia_preservation fixture
// ---------------------------------------------------------------------------

test "lazily/lossless_tree: token_trivia_preservation — edit keeps marker + newline" {
    var a = try LosslessTreeCrdt.init(allocator, 1);
    defer a.deinit();
    const item = try element(&a, lt.root_id, null, "list_item");
    const marker = try leaf(&a, item, null, .token, "- ");
    const body = try leaf(&a, item, marker, .raw, "item one");
    _ = try leaf(&a, item, body, .trivia, "\n");

    try a.editLeaf(body, 8, 0, "!");

    const r = try render(&a);
    defer allocator.free(r);
    try std.testing.expectEqualStrings("- item one!\n", r);
    try std.testing.expectEqual(@as(usize, 4), a.liveNodeCount());
}

// ---------------------------------------------------------------------------
// invalid_source_roundtrip fixture (Error leaves round-trip verbatim)
// ---------------------------------------------------------------------------

test "lazily/lossless_tree: invalid_source_roundtrip — error spans survive" {
    var t = try LosslessTreeCrdt.init(allocator, 1);
    defer t.deinit();
    const p1 = try element(&t, lt.root_id, null, "para");
    const txt = try leaf(&t, p1, null, .raw, "before ");
    const bad = try leaf(&t, p1, txt, .err, "<!-- agent:oops");
    _ = try leaf(&t, p1, bad, .trivia, "\n");
    const fence = try element(&t, lt.root_id, p1, "para");
    const open = try leaf(&t, fence, null, .err, "```rust");
    const nl2 = try leaf(&t, fence, open, .trivia, "\n");
    _ = try leaf(&t, fence, nl2, .raw, "fn main() {}");

    const r = try render(&t);
    defer allocator.free(r);
    try std.testing.expectEqualStrings("before <!-- agent:oops\n```rust\nfn main() {}", r);
    try std.testing.expectEqual(@as(usize, 8), t.liveNodeCount());
}

test "lazily/lossless_tree: invalid_source_roundtrip — edit adjacent raw keeps error spans" {
    var t = try LosslessTreeCrdt.init(allocator, 1);
    defer t.deinit();
    const p1 = try element(&t, lt.root_id, null, "para");
    const txt = try leaf(&t, p1, null, .raw, "before ");
    const bad = try leaf(&t, p1, txt, .err, "<!-- agent:oops");
    _ = try leaf(&t, p1, bad, .trivia, "\n");

    try t.editLeaf(txt, 7, 0, "X");

    const r = try render(&t);
    defer allocator.free(r);
    try std.testing.expectEqualStrings("before X<!-- agent:oops\n", r);
    try std.testing.expectEqual(@as(usize, 4), t.liveNodeCount());
}

// ---------------------------------------------------------------------------
// concurrent_conflict_preserves_text fixture (element wrap vs bare leaf)
// ---------------------------------------------------------------------------

test "lazily/lossless_tree: concurrent_conflict_preserves_text — both shapes survive" {
    var a = try LosslessTreeCrdt.init(allocator, 1);
    defer a.deinit();
    const para = try element(&a, lt.root_id, null, "para");
    const base = try leaf(&a, para, null, .raw, "x");

    var b = try a.fork(2);
    defer b.deinit();

    // a: wrap in a new element + leaf "A"; b: bare raw leaf "B".
    const a_strong = try a.createNode(para, base, .{ .element = "strong" });
    _ = try a.createNode(a_strong, null, .{ .leaf = .{ .kind = .raw, .text = "A" } });
    _ = try b.createNode(para, base, .{ .leaf = .{ .kind = .raw, .text = "B" } });

    const u_ab = try a.diff(&b.getFrontier(), allocator);
    defer a.freeUpdate(u_ab);
    try b.applyUpdate(u_ab);
    const u_ba = try b.diff(&a.getFrontier(), allocator);
    defer b.freeUpdate(u_ba);
    try a.applyUpdate(u_ba);

    const ra = try render(&a);
    defer allocator.free(ra);
    const rb = try render(&b);
    defer allocator.free(rb);
    try std.testing.expectEqualStrings("xAB", ra);
    try std.testing.expectEqualStrings("xAB", rb);
    try std.testing.expectEqual(@as(usize, 5), a.liveNodeCount());
}

// ---------------------------------------------------------------------------
// tombstone + out-of-order buffering + idempotent apply
// ---------------------------------------------------------------------------

test "lazily/lossless_tree: tombstone renders subtree away" {
    var t = try LosslessTreeCrdt.init(allocator, 1);
    defer t.deinit();
    const first = try leaf(&t, lt.root_id, null, .raw, "keep");
    const second = try leaf(&t, lt.root_id, first, .raw, "drop");
    try t.tombstoneNode(second);
    const r = try render(&t);
    defer allocator.free(r);
    try std.testing.expectEqualStrings("keep", r);
}

test "lazily/lossless_tree: applyUpdate is idempotent and order-tolerant" {
    var a = try LosslessTreeCrdt.init(allocator, 1);
    defer a.deinit();
    const para = try element(&a, lt.root_id, null, "para");
    _ = try leaf(&a, para, null, .raw, "abc");

    var c = try LosslessTreeCrdt.init(allocator, 3);
    defer c.deinit();
    const upd = try a.diff(&c.getFrontier(), allocator);
    defer a.freeUpdate(upd);
    try c.applyUpdate(upd);
    try c.applyUpdate(upd); // idempotent re-apply

    const rc = try render(&c);
    defer allocator.free(rc);
    try std.testing.expectEqualStrings("abc", rc);
}

// ---------------------------------------------------------------------------
// Wire round-trip (lossless-tree.json + lossless-tree-delta.json conformance)
// ---------------------------------------------------------------------------

test "lazily/lossless_tree: TreeUpdate wire round-trip is byte-stable" {
    var a = try LosslessTreeCrdt.init(allocator, 1);
    defer a.deinit();
    const para = try element(&a, lt.root_id, null, "para");
    const body = try leaf(&a, para, null, .raw, "héllo");
    _ = try leaf(&a, lt.root_id, para, .trivia, "\n");
    try a.editLeaf(body, 5, 0, "!");
    const tail = try a.splitLeaf(body, 4);
    try a.mergeAdjacentLeaves(body, tail);

    var empty = lt.TreeVersionFrontier.init(allocator);
    defer empty.deinit();
    const upd = try a.diff(&empty, allocator);
    defer a.freeUpdate(upd);

    const encoded1 = try lt.treeUpdateToJson(allocator, upd);
    defer allocator.free(encoded1);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded1, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decoded = try lt.treeUpdateFromJson(arena.allocator(), parsed.value);

    const encoded2 = try lt.treeUpdateToJson(allocator, decoded);
    defer allocator.free(encoded2);

    try std.testing.expectEqualSlices(u8, encoded1, encoded2);

    var fresh = try LosslessTreeCrdt.init(allocator, 9);
    defer fresh.deinit();
    try fresh.applyUpdate(decoded);
    const ra = try render(&a);
    defer allocator.free(ra);
    const rf = try render(&fresh);
    defer allocator.free(rf);
    try std.testing.expectEqualStrings(ra, rf);
}

test "lazily/lossless_tree: LeafKind round-trips wire + seed names" {
    const all = [_]LeafKind{ .token, .trivia, .raw, .err };
    for (all) |k| {
        try std.testing.expectEqual(k, try LeafKind.fromWireName(k.wireName()));
    }
    try std.testing.expectEqual(LeafKind.token, try LeafKind.fromSeedKind("token"));
    try std.testing.expectEqual(LeafKind.err, try LeafKind.fromSeedKind("error"));
    try std.testing.expectError(error.UnknownLeafKind, LeafKind.fromWireName("nope"));
}
