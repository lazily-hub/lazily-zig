//! Lossless mergeable document-tree contract (`#lzcrdttree`).

const std = @import("std");
const text_crdt = @import("text_crdt.zig");
/// Per-scenario replay accounting (#lzscenariocoverage). The three scenarios
/// below are hand-written rather than looped, so each names itself into the
/// runtime ledger through `replayingScenario` — which errors when the corpus no
/// longer carries that id, so a rename upstream breaks the runner instead of
/// quietly dropping the scenario out of the ledger.
const cj = @import("conformance_json.zig");
const ALGEBRA_FIXTURE = "crdt-tree/algebra.json";

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

/// PREDICATES, not assertions: the fixture's own booleans are what decides the
/// verdict now (`#lzzigblockwalk`), so these report the observation and the
/// tracker compares it. An `expect*` helper that failed on the spot could never
/// answer for a corpus that declared `texts_equal: false`.
fn frontiersEqual(
    expected: *const std.AutoHashMap(u64, u64),
    actual: *const std.AutoHashMap(u64, u64),
) bool {
    if (expected.count() != actual.count()) return false;
    var iter = expected.iterator();
    while (iter.next()) |entry| {
        const got = actual.get(entry.key_ptr.*) orelse return false;
        if (got != entry.value_ptr.*) return false;
    }
    return true;
}

fn sameOpIds(expected: []const text_crdt.TextOp, actual: []const text_crdt.TextOp) bool {
    if (expected.len != actual.len) return false;
    for (expected) |expected_op| {
        var found = false;
        for (actual) |actual_op| {
            if (expected_op.id.eql(actual_op.id)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Op ids carried more than once — `len - distinct`, the same count every other
/// binding reports for `later_merge_duplicates`.
fn duplicateOpIds(ops: []const text_crdt.TextOp) usize {
    var duplicates: usize = 0;
    for (ops, 0..) |op, i| {
        for (ops[0..i]) |earlier| {
            if (earlier.id.eql(op.id)) {
                duplicates += 1;
                break;
            }
        }
    }
    return duplicates;
}

test "CrdtTree replays canonical merge, snapshot, and frontier algebra" {
    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, fixture_algebra, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("CrdtTree", parsed.value.object.get("kind").?.string);
    try std.testing.expectEqualStrings("TextCrdt", parsed.value.object.get("model").?.string);
    try std.testing.expectEqual(@as(usize, 3), parsed.value.object.get("scenarios").?.array.items.len);

    const scenarios = parsed.value.object.get("scenarios").?.array.items;

    _ = try cj.replayingScenario(
        ALGEBRA_FIXTURE,
        parsed.value,
        "merge_is_order_and_duplication_independent",
    );
    var merge_expect = cj.AssertionKeys.init(
        ALGEBRA_FIXTURE ++ " merge_is_order_and_duplication_independent.expect",
        scenarios[0].object.get("expect").?,
    );
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
    var texts_equal = true;
    var vectors_equal = true;
    for (folds[1..]) |*fold| {
        const actual_text = try fold.value(allocator);
        defer allocator.free(actual_text);
        if (!std.mem.eql(u8, expected_text, actual_text)) texts_equal = false;
        var actual_frontier = try fold.versionVector(allocator);
        defer actual_frontier.deinit();
        if (!frontiersEqual(&expected_frontier, &actual_frontier)) vectors_equal = false;
    }
    // The two claims the fixture actually makes, compared THROUGH the tracker
    // (`#lzzigblockwalk`). Until now this runner asserted the same facts with
    // hardcoded `expectEqualStrings` calls and never read the block, so editing
    // either key in the corpus changed nothing here and rung 0 could not see
    // that nothing bound it.
    try merge_expect.assertKey("texts_equal", texts_equal);
    try merge_expect.assertKey("version_vectors_equal", vectors_equal);
    try merge_expect.finish();
    // Still a hard failure, not only a recorded verdict: the tracker compares
    // the fixture's booleans, and these name WHICH fold diverged.
    try std.testing.expect(texts_equal);
    try std.testing.expect(vectors_equal);

    _ = try cj.replayingScenario(
        ALGEBRA_FIXTURE,
        parsed.value,
        "empty_frontier_snapshot_preserves_lineage",
    );
    var lineage_expect = cj.AssertionKeys.init(
        ALGEBRA_FIXTURE ++ " empty_frontier_snapshot_preserves_lineage.expect",
        scenarios[1].object.get("expect").?,
    );
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
    try lineage_expect.assertKey(
        "restored_text_equal",
        std.mem.eql(u8, source_text, restored_text),
    );
    const restored_snapshot = try restored.deltaSince(&empty_frontier, allocator);
    defer allocator.free(restored_snapshot);
    // Lineage, not just text: a snapshot that re-minted op ids would round-trip
    // the same characters and still break every later merge.
    try lineage_expect.assertKey("op_ids_equal", sameOpIds(snapshot, restored_snapshot));

    try source.insertBackCp('A');
    try restored.insertBackCp('B');
    _ = try source.mergeFrom(&restored);
    _ = try restored.mergeFrom(&source);
    const converged_source = try source.value(allocator);
    defer allocator.free(converged_source);
    const converged_restored = try restored.value(allocator);
    defer allocator.free(converged_restored);
    try std.testing.expectEqualStrings(converged_source, converged_restored);
    // A merge that re-applied an op it already carried would show up here and
    // nowhere else: the texts converge either way.
    const converged_ops = try source.deltaSince(&empty_frontier, allocator);
    defer allocator.free(converged_ops);
    try lineage_expect.assertKey("later_merge_duplicates", duplicateOpIds(converged_ops));
    try lineage_expect.finish();
    try std.testing.expectEqualStrings(source_text, restored_text);
    try std.testing.expect(sameOpIds(snapshot, restored_snapshot));

    _ = try cj.replayingScenario(
        ALGEBRA_FIXTURE,
        parsed.value,
        "own_frontier_emits_empty_delta",
    );
    var steady_expect = cj.AssertionKeys.init(
        ALGEBRA_FIXTURE ++ " own_frontier_emits_empty_delta.expect",
        scenarios[2].object.get("expect").?,
    );
    var steady = try text_crdt.TextCrdt.fromStr(allocator, 9, "steady\n");
    defer steady.deinit();
    var steady_frontier = try steady.versionVector(allocator);
    defer steady_frontier.deinit();
    const empty_delta = try steady.deltaSince(&steady_frontier, allocator);
    defer allocator.free(empty_delta);
    // `delta` is array-valued and the corpus declares it empty, so its LENGTH
    // is the whole claim; comparing the fixture's own array against what the
    // run produced is what makes editing it change this outcome.
    try steady_expect.assertKeyWith("delta", empty_delta, struct {
        fn check(produced: []const text_crdt.TextOp, want: cj.Value) anyerror!void {
            try std.testing.expectEqual((try cj.asArray(want)).len, produced.len);
        }
    }.check);
    try steady_expect.assertKey("apply_changed", try steady.applyDelta(empty_delta));
    try steady_expect.finish();
    try std.testing.expectEqual(@as(usize, 0), empty_delta.len);
}
