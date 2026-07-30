//! Canonical replays for the four `collections/*.json` fixtures this binding
//! used to assert with INLINE MIRRORS (`#lazilyzigconformance`).
//!
//! Each of `keyed_reconciliation_lis`, `mergecell_algebra`, `semtree_incremental`
//! and `stableid_alignment` was previously "covered" by a test that named the
//! fixture in a comment and hand-transcribed its numbers into the `.zig` source.
//! Upstream could change any of them and every mirror stayed green — the same
//! defect class as lazily-cpp's hand-transcribed queue tests. The runtime
//! manifest (`#lazilyupgradeconformance`) demoted them from "named" to
//! "not opened"; this module opens them.
//!
//! What replaces each mirror is the fixture's own op stream, not a
//! prettier spelling of the same constants:
//!
//! - **keyed_reconciliation_lis** — the emitted op set is compared op-for-op
//!   against `expected.ops` (resolving a relative `after`/`before` anchor to the
//!   absolute index `DiffOp.move` carries), then applied to a live `SourceMap`
//!   which must converge to `expected.result_order`, and the stable keys'
//!   value versions must survive the sibling reorder untouched.
//! - **mergecell_algebra** — every policy's `flags` are checked against the
//!   policy struct, and each step asserts both the converged value AND
//!   `invalidates`. The mirror asserted neither the flags nor the cascade; it
//!   compared final values only. `invalidates` is observed through an `Effect`
//!   reading the cell, so a policy that stopped suppressing an equal write
//!   fails here rather than passing on an unchanged number.
//! - **semtree_incremental** — the tree is built from the fixture's own JSON
//!   (the mirror reused one hand-built tree for all three scenarios, including
//!   the removal scenario whose canonical tree has a different shape and only
//!   coincidentally the same totals), and `sibling_a_cached` /
//!   `downstream_consumer_reran` are asserted through the per-node recompute
//!   counters.
//! - **stableid_alignment** — all six scenarios drive `alignBlocks` /
//!   `assignStableKeys` / `contentHash` from the fixture's blocks and match
//!   strings.

const std = @import("std");
const testing = std.testing;

const cj = @import("conformance_json.zig");
const Value = cj.Value;

const Context = @import("context.zig").Context;
const Compute = @import("context.zig").Compute;
const CellMod = @import("cell.zig");
const effect_mod = @import("effect.zig");
const merge_mod = @import("merge.zig");
const reactive_map = @import("reactive_map.zig");
const reconcile_mod = @import("reconcile.zig");
const sem_tree_mod = @import("sem_tree.zig");
const source_tree = @import("source_tree.zig");
const stable_id = @import("stable_id.zig");

/// Entry value type used across the collections fixtures (JSON integers).
const V = i64;

fn skipAbsent(name: []const u8) void {
    std.debug.print(
        "skipping {s}: {s}/collections absent - run with the lazily-spec sibling\n",
        .{ name, cj.CONFORMANCE_ROOT },
    );
}

// ---------------------------------------------------------------------------
// keyed_reconciliation_lis.json
// ---------------------------------------------------------------------------

const KV = reconcile_mod.KV([]const u8, V);
const DiffOp = reconcile_mod.DiffOp([]const u8, V);

/// `{order, values}` → the keyed sequence `reconcile` diffs. Caller frees.
fn keyedPairs(block: Value) ![]KV {
    const order = try cj.asArray(try cj.required(block, "order"));
    const values = try cj.required(block, "values");
    const out = try testing.allocator.alloc(KV, order.len);
    errdefer testing.allocator.free(out);
    for (order, out) |k, *slot| {
        const key = try cj.asStr(k);
        slot.* = .{
            .key = key,
            .value = try cj.asI64(cj.field(values, key) orelse return error.MissingValue),
        };
    }
    return out;
}

fn positionOf(order: []const Value, key: []const u8) !usize {
    for (order, 0..) |k, i| {
        if (std.mem.eql(u8, try cj.asStr(k), key)) return i;
    }
    return error.KeyNotInResultOrder;
}

/// The fixture may anchor a move relatively (`after`/`before`) or absolutely
/// (`to`); `DiffOp.move` carries the absolute final index either way.
fn expectedMoveIndex(op: Value, result_order: []const Value) !usize {
    if (try cj.optStr(op, "after")) |after| return try positionOf(result_order, after) + 1;
    if (try cj.optStr(op, "before")) |before| return try positionOf(result_order, before);
    return cj.asUsize(try cj.required(op, "to"));
}

fn applyOps(map: *reactive_map.SourceMap([]const u8, V), ops: []const DiffOp) !void {
    // Emitted order IS application order: removes, then inserts/moves
    // left-to-right by index, then updates.
    for (ops) |op| switch (op) {
        .remove => |r| _ = map.remove(r.key),
        .insert => |i| {
            try map.set(i.key, i.value);
            _ = map.moveTo(i.key, i.index);
        },
        .move => |m| _ = map.moveTo(m.key, m.to),
        .update => |u| try map.set(u.key, u.value),
    };
}

test "collections conformance: keyed_reconciliation_lis.json" {
    const allocator = testing.allocator;
    var parsed = (try cj.load("collections/keyed_reconciliation_lis.json")) orelse {
        skipAbsent("keyed_reconciliation_lis.json");
        return;
    };
    defer parsed.deinit();
    const fixture = parsed.value;

    const block = try cj.required(fixture, "reconcile");
    const prior = try keyedPairs(try cj.required(block, "prior"));
    defer allocator.free(prior);
    const target = try keyedPairs(try cj.required(block, "target"));
    defer allocator.free(target);

    const expected = try cj.required(fixture, "expected");
    const result_order = try cj.asArray(try cj.required(expected, "result_order"));
    const expected_ops = try cj.asArray(try cj.required(expected, "ops"));
    // A vacuous replay must not report green.
    try testing.expect(prior.len > 0 and expected_ops.len > 0);

    // 1. The emitted op set is minimal (LIS) and matches the fixture op-for-op.
    const ops = try reconcile_mod.reconcile([]const u8, V, allocator, prior, target);
    defer allocator.free(ops);
    try testing.expectEqual(expected_ops.len, ops.len);

    for (expected_ops) |want| {
        const ty = try cj.asStr(try cj.required(want, "type"));
        const key = try cj.asStr(try cj.required(want, "key"));
        var found = false;
        for (ops) |got| {
            found = switch (got) {
                .remove => |r| std.mem.eql(u8, ty, "remove") and std.mem.eql(u8, r.key, key),
                .insert => |i| std.mem.eql(u8, ty, "insert") and std.mem.eql(u8, i.key, key),
                .update => |u| std.mem.eql(u8, ty, "update") and std.mem.eql(u8, u.key, key),
                .move => |m| std.mem.eql(u8, ty, "move") and std.mem.eql(u8, m.key, key) and
                    m.to == try expectedMoveIndex(want, result_order),
            };
            if (found) break;
        }
        if (!found) {
            std.debug.print("expected op {s}({s}) not in the emitted set\n", .{ ty, key });
            return error.MissingExpectedOp;
        }
    }

    // 2. Applying the op set to a live map converges to `result_order`.
    {
        const ctx = try Context.init(allocator);
        defer ctx.deinit();
        var map = try reactive_map.SourceMap([]const u8, V).init(ctx);
        defer map.deinit();
        for (prior) |kv| try map.set(kv.key, kv.value);
        try applyOps(&map, ops);

        const keys = map.keys().get();
        try testing.expectEqual(result_order.len, keys.len);
        for (result_order, keys) |want, got| {
            try testing.expectEqualStrings(try cj.asStr(want), got);
        }
    }

    // 3. Stable entries' value cells are NOT invalidated by the sibling reorder.
    {
        const stable = try cj.arrayOr(expected, "stable_keys_not_invalidated");
        const ctx = try Context.init(allocator);
        defer ctx.deinit();
        var map = try reactive_map.SourceMap([]const u8, V).init(ctx);
        defer map.deinit();
        for (prior) |kv| try map.set(kv.key, kv.value);

        var before = std.StringHashMap(u64).init(allocator);
        defer before.deinit();
        for (stable) |k| {
            const key = try cj.asStr(k);
            try before.put(key, map.valueVersion(key) orelse return error.StableKeyAbsent);
        }

        try applyOps(&map, ops);

        for (stable) |k| {
            const key = try cj.asStr(k);
            const now = map.valueVersion(key) orelse return error.StableKeyDropped;
            if (now != before.get(key).?) {
                std.debug.print(
                    "stable entry `{s}` value cell was invalidated by a sibling reorder\n",
                    .{key},
                );
                return error.StableEntryInvalidated;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// mergecell_algebra.json
// ---------------------------------------------------------------------------

/// `Source.init` takes a comptime value fn, so a fixture-supplied `initial` has
/// to arrive through a global the fn reads. Each scenario gets a fresh
/// `Context`, so the shared cache key never collides across scenarios.
var merge_initial: V = 0;

fn mergeInitialFn(_: *Context) !V {
    return merge_initial;
}

/// Cascade probe for `invalidates`. The Effect reads the cell under replay, so
/// its run count is the observable behind the fixture's flag: a merge that
/// converges to the same value must not re-run it (the ==-guard suppresses the
/// cascade), and one that changes the value must.
var probe_cell: ?*CellMod.Source(V) = null;
var probe_runs: u64 = 0;

fn probeBody(c: *Compute) anyerror!void {
    if (probe_cell) |cell| _ = c.get(cell);
    probe_runs += 1;
}

fn policyByName(name: []const u8) !merge_mod.MergePolicy(V) {
    if (std.mem.eql(u8, name, "KeepLatest")) return merge_mod.keepLatest(V);
    if (std.mem.eql(u8, name, "Sum")) return merge_mod.sum(V);
    if (std.mem.eql(u8, name, "Max")) return merge_mod.max(V);
    std.debug.print("unknown merge policy `{s}`\n", .{name});
    return error.UnknownMergePolicy;
}

test "collections conformance: mergecell_algebra.json" {
    const allocator = testing.allocator;
    var parsed = (try cj.load("collections/mergecell_algebra.json")) orelse {
        skipAbsent("mergecell_algebra.json");
        return;
    };
    defer parsed.deinit();

    const scenarios = try cj.asArray(try cj.required(parsed.value, "scenarios"));
    try testing.expect(scenarios.len > 0);

    var steps_replayed: usize = 0;
    for (scenarios, 0..) |scenario, si| {
        const policy = try policyByName(try cj.asStr(try cj.required(scenario, "policy")));

        // The transport-selected property flags are part of the contract: they
        // decide which overflow behaviour is sound, so a policy whose flags
        // drift from the corpus is a wire-level bug, not a comment.
        const flags = try cj.required(scenario, "flags");
        try testing.expectEqual(try cj.asBool(try cj.required(flags, "commutative")), policy.commutative);
        try testing.expectEqual(try cj.asBool(try cj.required(flags, "idempotent")), policy.idempotent);

        const ctx = try Context.init(allocator);
        defer ctx.deinit();

        merge_initial = try cj.asI64(try cj.required(scenario, "initial"));
        var mc = try merge_mod.MergeCell(V).init(ctx, mergeInitialFn, policy);
        try testing.expectEqual(merge_initial, mc.get());

        probe_cell = mc.underlying();
        probe_runs = 0;
        const probe = try effect_mod.effectNoCleanup(ctx, probeBody);
        defer {
            probe.dispose();
            ctx.allocator.destroy(probe);
            probe_cell = null;
        }
        // The effect body runs once on creation.
        try testing.expectEqual(@as(u64, 1), probe_runs);

        const steps = try cj.asArray(try cj.required(scenario, "steps"));
        try testing.expect(steps.len > 0);
        for (steps, 0..) |step, i| {
            const expected = try cj.required(step, "expected");
            const runs_before = probe_runs;

            mc.merge(try cj.asI64(try cj.required(step, "merge")));

            const want_value = try cj.asI64(try cj.required(expected, "value"));
            if (mc.get() != want_value) {
                std.debug.print(
                    "scenario {d} ({s}) step {d}: converged value {d}, want {d}\n",
                    .{ si, policy.name, i, mc.get(), want_value },
                );
                return error.ConvergedValueMismatch;
            }

            const want_invalidates = try cj.asBool(try cj.required(expected, "invalidates"));
            const did_invalidate = probe_runs != runs_before;
            if (did_invalidate != want_invalidates) {
                std.debug.print(
                    "scenario {d} ({s}) step {d}: invalidates={} want {}\n",
                    .{ si, policy.name, i, did_invalidate, want_invalidates },
                );
                return error.InvalidationMismatch;
            }
            steps_replayed += 1;
        }
    }
    try testing.expect(steps_replayed > 0);
}

// ---------------------------------------------------------------------------
// semtree_incremental.json
// ---------------------------------------------------------------------------

const Tree = source_tree.SourceTree([]const u8, V);
const Node = source_tree.SourceTreeNode([]const u8, V);
const Sem = sem_tree_mod.SemTree([]const u8, V, V);

fn sumFold(node_value: V, child_deriveds: []const V) V {
    var total = node_value;
    for (child_deriveds) |d| total += d;
    return total;
}

fn countPositiveFold(node_value: V, child_deriveds: []const V) V {
    var total: V = if (node_value > 0) 1 else 0;
    for (child_deriveds) |d| total += d;
    return total;
}

fn foldByName(name: []const u8) !*const fn (V, []const V) V {
    if (std.mem.eql(u8, name, "sum")) return sumFold;
    if (std.mem.eql(u8, name, "count_positive")) return countPositiveFold;
    std.debug.print("unknown semtree fold `{s}`\n", .{name});
    return error.UnknownFold;
}

/// Attach the fixture's `children` block (an ordered key list plus a values
/// object) under `parent`, recursively.
fn attachChildren(parent: *Node, node_json: Value) !void {
    const children = cj.field(node_json, "children") orelse return;
    const order = try cj.asArray(try cj.required(children, "order"));
    const values = try cj.required(children, "values");
    for (order) |k| {
        const id = try cj.asStr(k);
        const child_json = cj.field(values, id) orelse return error.MissingChildNode;
        const child = try parent.insertChild(
            try cj.asStr(try cj.required(child_json, "id")),
            try cj.asI64(try cj.required(child_json, "value")),
        );
        try attachChildren(child, child_json);
    }
}

fn buildTree(allocator: std.mem.Allocator, root_json: Value) !Tree {
    var tree = try Tree.init(
        allocator,
        try cj.asStr(try cj.required(root_json, "id")),
        try cj.asI64(try cj.required(root_json, "value")),
    );
    errdefer tree.deinit();
    try attachChildren(tree.root, root_json);
    return tree;
}

/// Every `{id: derived}` entry in an `expect_*` block that names a tree node.
/// The two boolean claims (`sibling_a_cached`, `downstream_consumer_reran`) are
/// asserted separately against the recompute counters.
fn expectDerived(sem: *const Sem, expect: Value, scenario: usize, phase: []const u8) !void {
    var it = switch (expect) {
        .object => |o| o.iterator(),
        else => return error.ExpectedObject,
    };
    while (it.next()) |entry| {
        const id = entry.key_ptr.*;
        if (entry.value_ptr.* != .integer) continue; // boolean claims handled below
        const want = try cj.asI64(entry.value_ptr.*);
        const got = sem.nodeValue(id) orelse {
            std.debug.print("scenario {d} {s}: node `{s}` has no derived value\n", .{ scenario, phase, id });
            return error.MissingDerivedNode;
        };
        if (got != want) {
            std.debug.print(
                "scenario {d} {s}: node `{s}` derived {d}, want {d}\n",
                .{ scenario, phase, id, got, want },
            );
            return error.DerivedValueMismatch;
        }
    }
}

test "collections conformance: semtree_incremental.json" {
    const allocator = testing.allocator;
    var parsed = (try cj.load("collections/semtree_incremental.json")) orelse {
        skipAbsent("semtree_incremental.json");
        return;
    };
    defer parsed.deinit();

    const scenarios = try cj.asArray(try cj.required(parsed.value, "scenarios"));
    try testing.expect(scenarios.len > 0);

    for (scenarios, 0..) |scenario, si| {
        const fold = try foldByName(try cj.asStr(try cj.required(scenario, "fold")));
        var tree = try buildTree(allocator, try cj.required(scenario, "tree"));
        defer tree.deinit();

        var sem = try Sem.build(allocator, tree.root, fold);
        defer sem.deinit();

        const expect_initial = try cj.required(scenario, "expect_initial");
        // The fixture names the root's derived value as `root`, which is also
        // the root node's id — so the generic pass covers it.
        try expectDerived(&sem, expect_initial, si, "initial");

        // Counters sampled before the mutation back the two boolean claims.
        const sibling_before = sem.recomputeCount("a");
        const root_before = sem.recomputeCount("root");

        if (cj.field(scenario, "edit")) |edit| {
            try sem.applyEdit(
                tree.root,
                try cj.asStr(try cj.required(edit, "id")),
                try cj.asI64(try cj.required(edit, "value")),
            );
        } else if (cj.field(scenario, "remove_child")) |rm| {
            try sem.applyRemoveChild(
                tree.root,
                try cj.asStr(try cj.required(rm, "parent")),
                try cj.asStr(try cj.required(rm, "child")),
            );
        } else {
            return error.ScenarioHasNoMutation;
        }

        const expect_after = try cj.required(scenario, "expect_after");
        try expectDerived(&sem, expect_after, si, "after");

        // Both booleans are asserted in BOTH directions. `sibling_a_cached`
        // used to be a GATE — `if (want) { check }` — so flipping it to false
        // in the corpus deleted the check instead of demanding the opposite
        // fact (#lzconsumednotasserted).
        if (cj.field(expect_after, "sibling_a_cached")) |flag| {
            const cached = sem.recomputeCount("a") == sibling_before;
            if (cached != try cj.asBool(flag)) {
                std.debug.print(
                    "scenario {d}: sibling subtree `a` cached={} want {} " ++
                        "(an edit in a different subtree must not recompute it)\n",
                    .{ si, cached, try cj.asBool(flag) },
                );
                return error.SiblingSubtreeRecomputed;
            }
        }
        if (cj.field(expect_after, "downstream_consumer_reran")) |flag| {
            const reran = sem.recomputeCount("root") != root_before;
            if (reran != try cj.asBool(flag)) {
                std.debug.print(
                    "scenario {d}: downstream_consumer_reran={} want {}\n",
                    .{ si, reran, try cj.asBool(flag) },
                );
                return error.MemoGuardMismatch;
            }
        }
    }
}

// ---------------------------------------------------------------------------
// stableid_alignment.json
// ---------------------------------------------------------------------------

fn blocksFrom(list: []const Value) ![]stable_id.Block {
    const out = try testing.allocator.alloc(stable_id.Block, list.len);
    errdefer testing.allocator.free(out);
    for (list, out) |item, *slot| {
        slot.* = .{
            .anchor = try cj.optStr(item, "anchor"),
            .text = try cj.asStr(try cj.required(item, "text")),
        };
    }
    return out;
}

/// `"Same:2"` / `"Edited:0"` / `"Inserted"` — the cross-language spelling of
/// `stable_id.Match`.
fn expectMatch(spec: []const u8, got: stable_id.Match, scenario: usize, i: usize) !void {
    const colon = std.mem.indexOfScalar(u8, spec, ':');
    const kind = if (colon) |c| spec[0..c] else spec;
    const old_index: ?usize = if (colon) |c| try std.fmt.parseInt(usize, spec[c + 1 ..], 10) else null;

    const ok = if (std.mem.eql(u8, kind, "Same"))
        got == .same and got.same == old_index.?
    else if (std.mem.eql(u8, kind, "Edited"))
        got == .edited and got.edited.old == old_index.?
    else if (std.mem.eql(u8, kind, "Inserted"))
        got == .inserted
    else
        return error.UnknownMatchKind;

    if (!ok) {
        std.debug.print("scenario {d} match {d}: got {any}, want `{s}`\n", .{ scenario, i, got, spec });
        return error.MatchMismatch;
    }
}

test "collections conformance: stableid_alignment.json" {
    const allocator = testing.allocator;
    var parsed = (try cj.load("collections/stableid_alignment.json")) orelse {
        skipAbsent("stableid_alignment.json");
        return;
    };
    defer parsed.deinit();

    const scenarios = try cj.asArray(try cj.required(parsed.value, "scenarios"));
    try testing.expect(scenarios.len > 0);

    var claims: usize = 0;
    for (scenarios, 0..) |scenario, si| {
        const expect = try cj.required(scenario, "expect");

        // Shape 1: one `blocks` list, with key-identity claims over its indices.
        if (cj.field(scenario, "blocks")) |blocks_json| {
            const blocks = try blocksFrom(try cj.asArray(blocks_json));
            defer allocator.free(blocks);

            for (try cj.arrayOr(expect, "key_equal")) |pair| {
                const p = try cj.asArray(pair);
                const a = stable_id.BlockKey.fromBlock(blocks[try cj.asUsize(p[0])]);
                const b = stable_id.BlockKey.fromBlock(blocks[try cj.asUsize(p[1])]);
                if (!a.eqlString(b)) {
                    std.debug.print("scenario {d}: blocks {d}/{d} must share a key\n", .{ si, try cj.asUsize(p[0]), try cj.asUsize(p[1]) });
                    return error.KeyShouldMatch;
                }
                claims += 1;
            }
            for (try cj.arrayOr(expect, "key_not_equal")) |pair| {
                const p = try cj.asArray(pair);
                const a = stable_id.BlockKey.fromBlock(blocks[try cj.asUsize(p[0])]);
                const b = stable_id.BlockKey.fromBlock(blocks[try cj.asUsize(p[1])]);
                if (a.eqlString(b)) {
                    std.debug.print("scenario {d}: blocks {d}/{d} must NOT share a key\n", .{ si, try cj.asUsize(p[0]), try cj.asUsize(p[1]) });
                    return error.KeyShouldDiffer;
                }
                claims += 1;
            }
            continue;
        }

        // Shape 2: an `old`/`new` pair aligned against each other.
        const old = try blocksFrom(try cj.asArray(try cj.required(scenario, "old")));
        defer allocator.free(old);
        const new = try blocksFrom(try cj.asArray(try cj.required(scenario, "new")));
        defer allocator.free(new);

        var alignment = try stable_id.alignBlocks(allocator, old, new);
        defer alignment.deinit();

        if (cj.field(expect, "matches")) |matches| {
            const want = try cj.asArray(matches);
            try testing.expectEqual(want.len, alignment.new_matches.len);
            for (want, alignment.new_matches, 0..) |spec, got, i| {
                try expectMatch(try cj.asStr(spec), got, si, i);
                claims += 1;
            }
        }
        if (cj.field(expect, "removed")) |removed| {
            const want = try cj.asArray(removed);
            try testing.expectEqual(want.len, alignment.removed.len);
            for (want, alignment.removed) |w, got| {
                try testing.expectEqual(try cj.asUsize(w), got);
            }
            claims += 1;
        }
        if (cj.field(expect, "similarity_min")) |min| {
            const floor: f32 = @floatCast(try cj.asF64(min));
            for (alignment.new_matches) |m| {
                if (m == .edited) try testing.expect(m.edited.similarity >= floor);
            }
            claims += 1;
        }
        if (cj.field(expect, "new_key_equals_old_key")) |pairs| {
            const keys = try stable_id.assignStableKeys(allocator, old, new);
            defer {
                for (keys) |k| allocator.free(k);
                allocator.free(keys);
            }
            for (try cj.asArray(pairs)) |pair| {
                const p = try cj.asArray(pair);
                const new_i = try cj.asUsize(p[0]);
                const old_i = try cj.asUsize(p[1]);
                var buf: [256]u8 = undefined;
                const old_key = stable_id.BlockKey.fromBlock(old[old_i]).writeString(&buf);
                try testing.expectEqualStrings(old_key, keys[new_i]);
                claims += 1;
            }
        }
    }
    // A replay that asserted nothing is the vacuous green this file exists to
    // remove.
    try testing.expect(claims > 0);
}
