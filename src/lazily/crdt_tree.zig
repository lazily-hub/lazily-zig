//! Lossless mergeable document-tree contract (`#lzcrdttree`).

const std = @import("std");
const text_crdt = @import("text_crdt.zig");

/// Zig expresses the CrdtTree interface as a compile-time structural contract.
/// The returned type is unchanged; missing methods fail at comptime.
pub fn CrdtTree(comptime Tree: type) type {
    inline for (.{
        "versionVector",
        "deltaSince",
        "applyDelta",
        "text",
        "value",
        "mergeFrom",
    }) |name| {
        if (!@hasDecl(Tree, name)) {
            @compileError(@typeName(Tree) ++ " is missing CrdtTree." ++ name);
        }
    }
    return Tree;
}

comptime {
    _ = CrdtTree(text_crdt.TextCrdt);
}

test "CrdtTree structural contract accepts TextCrdt" {
    const Tree = CrdtTree(text_crdt.TextCrdt);
    try std.testing.expect(Tree == text_crdt.TextCrdt);
}

const fixture_algebra = @embedFile("test/crdt-tree/algebra.json");

fn expectFrontiersEqual(
    expected: *const std.AutoHashMap(u64, u64),
    actual: *const std.AutoHashMap(u64, u64),
) !void {
    try std.testing.expectEqual(expected.count(), actual.count());
    var iter = expected.iterator();
    while (iter.next()) |entry| {
        try std.testing.expectEqual(entry.value_ptr.*, actual.get(entry.key_ptr.*).?);
    }
}

fn expectSameOpIds(expected: []const text_crdt.TextOp, actual: []const text_crdt.TextOp) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected) |expected_op| {
        var found = false;
        for (actual) |actual_op| {
            if (expected_op.id.eql(actual_op.id)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}

test "CrdtTree replays canonical merge, snapshot, and frontier algebra" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, fixture_algebra, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("CrdtTree", parsed.value.object.get("kind").?.string);
    try std.testing.expectEqualStrings("TextCrdt", parsed.value.object.get("model").?.string);
    try std.testing.expectEqual(@as(usize, 3), parsed.value.object.get("scenarios").?.array.items.len);

    var base = try text_crdt.TextCrdt.fromStr(allocator, 1, "root\n");
    defer base.deinit();
    var a = try base.fork(2);
    defer a.deinit();
    var b = try base.fork(3);
    defer b.deinit();
    var c = try base.fork(4);
    defer c.deinit();
    try a.insertBackCp('a');
    try b.insertBackCp('b');
    try c.insertBackCp('c');

    var folds: [3]text_crdt.TextCrdt = .{
        try base.fork(100),
        try base.fork(101),
        try base.fork(102),
    };
    defer for (&folds) |*fold| fold.deinit();
    _ = try folds[0].mergeFrom(&a);
    _ = try folds[0].mergeFrom(&b);
    _ = try folds[0].mergeFrom(&c);
    _ = try folds[1].mergeFrom(&c);
    _ = try folds[1].mergeFrom(&a);
    _ = try folds[1].mergeFrom(&b);
    _ = try folds[2].mergeFrom(&b);
    try std.testing.expect(!try folds[2].mergeFrom(&b));
    _ = try folds[2].mergeFrom(&c);
    _ = try folds[2].mergeFrom(&a);

    const expected_text = try folds[0].value(allocator);
    defer allocator.free(expected_text);
    var expected_frontier = try folds[0].versionVector(allocator);
    defer expected_frontier.deinit();
    for (folds[1..]) |*fold| {
        const actual_text = try fold.value(allocator);
        defer allocator.free(actual_text);
        try std.testing.expectEqualStrings(expected_text, actual_text);
        var actual_frontier = try fold.versionVector(allocator);
        defer actual_frontier.deinit();
        try expectFrontiersEqual(&expected_frontier, &actual_frontier);
    }

    var source = try text_crdt.TextCrdt.fromStr(allocator, 7, "snapshot\n");
    defer source.deinit();
    var empty_frontier = std.AutoHashMap(u64, u64).init(allocator);
    defer empty_frontier.deinit();
    const snapshot = try source.deltaSince(&empty_frontier, allocator);
    defer allocator.free(snapshot);
    var restored = text_crdt.TextCrdt.init(allocator, 8);
    defer restored.deinit();
    try std.testing.expect(try restored.applyDelta(snapshot));
    const source_text = try source.value(allocator);
    defer allocator.free(source_text);
    const restored_text = try restored.value(allocator);
    defer allocator.free(restored_text);
    try std.testing.expectEqualStrings(source_text, restored_text);
    const restored_snapshot = try restored.deltaSince(&empty_frontier, allocator);
    defer allocator.free(restored_snapshot);
    try expectSameOpIds(snapshot, restored_snapshot);

    try source.insertBackCp('A');
    try restored.insertBackCp('B');
    _ = try source.mergeFrom(&restored);
    _ = try restored.mergeFrom(&source);
    const converged_source = try source.value(allocator);
    defer allocator.free(converged_source);
    const converged_restored = try restored.value(allocator);
    defer allocator.free(converged_restored);
    try std.testing.expectEqualStrings(converged_source, converged_restored);

    var steady = try text_crdt.TextCrdt.fromStr(allocator, 9, "steady\n");
    defer steady.deinit();
    var steady_frontier = try steady.versionVector(allocator);
    defer steady_frontier.deinit();
    const empty_delta = try steady.deltaSince(&steady_frontier, allocator);
    defer allocator.free(empty_delta);
    try std.testing.expectEqual(@as(usize, 0), empty_delta.len);
    try std.testing.expect(!try steady.applyDelta(empty_delta));
}
