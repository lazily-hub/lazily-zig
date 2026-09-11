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

/// What each of the three `expected` sub-assertions of
/// `keyed_reconciliation_lis.json` needs, so each can run INSIDE the tracker
/// callback that books its key (`#lzzigblockwalk`). The comparisons are
/// unchanged; what is new is that the fixture's value reaches them through an
/// `AssertionKeys` tracker, so the block is bound and rung 0 can see it.
const LisCtx = struct {
    allocator: std.mem.Allocator,
    prior: []const KV,
    ops: []const DiffOp,
    result_order: []const Value,
};

/// 1. The emitted op set is minimal (LIS) and matches the fixture op-for-op.
fn lisOps(ctx: LisCtx, want: Value) anyerror!void {
    const expected_ops = try cj.asArray(want);
    try testing.expectEqual(expected_ops.len, ctx.ops.len);
    for (expected_ops) |op| {
        const ty = try cj.asStr(try cj.required(op, "type"));
        const key = try cj.asStr(try cj.required(op, "key"));
        var found = false;
        for (ctx.ops) |got| {
            found = switch (got) {
                .remove => |r| std.mem.eql(u8, ty, "remove") and std.mem.eql(u8, r.key, key),
                .insert => |i| std.mem.eql(u8, ty, "insert") and std.mem.eql(u8, i.key, key),
                .update => |u| std.mem.eql(u8, ty, "update") and std.mem.eql(u8, u.key, key),
                .move => |m| std.mem.eql(u8, ty, "move") and std.mem.eql(u8, m.key, key) and
                    m.to == try expectedMoveIndex(op, ctx.result_order),
            };
            if (found) break;
        }
        if (!found) {
            std.debug.print("expected op {s}({s}) not in the emitted set\n", .{ ty, key });
            return error.MissingExpectedOp;
        }
    }
}

/// 2. Applying the op set to a live map converges to `result_order`.
fn lisResultOrder(ctx: LisCtx, want: Value) anyerror!void {
    const result_order = try cj.asArray(want);
    const c = try Context.init(ctx.allocator);
    defer c.deinit();
    var map = try reactive_map.SourceMap([]const u8, V).init(c);
    defer map.deinit();
    for (ctx.prior) |kv| try map.set(kv.key, kv.value);
    try applyOps(&map, ctx.ops);

    const keys = map.keys().get();
    try testing.expectEqual(result_order.len, keys.len);
    for (result_order, keys) |w, got| {
        try testing.expectEqualStrings(try cj.asStr(w), got);
    }
}

/// 3. Stable entries' value cells are NOT invalidated by the sibling reorder.
fn lisStableKeys(ctx: LisCtx, want: Value) anyerror!void {
    const stable = try cj.asArray(want);
    const c = try Context.init(ctx.allocator);
    defer c.deinit();
    var map = try reactive_map.SourceMap([]const u8, V).init(c);
    defer map.deinit();
    for (ctx.prior) |kv| try map.set(kv.key, kv.value);

    var before = std.StringHashMap(u64).init(ctx.allocator);
    defer before.deinit();
    for (stable) |k| {
        const key = try cj.asStr(k);
        try before.put(key, map.valueVersion(key) orelse return error.StableKeyAbsent);
    }

    try applyOps(&map, ctx.ops);

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

    const reconcile_block = try cj.required(fixture, "reconcile");
    const prior = try keyedPairs(try cj.required(reconcile_block, "prior"));
    defer allocator.free(prior);
    const target = try keyedPairs(try cj.required(reconcile_block, "target"));
    defer allocator.free(target);

    const expected = try cj.required(fixture, "expected");
    var block = cj.AssertionKeys.init(
        "collections/keyed_reconciliation_lis.json expected",
        expected,
    );
    const result_order = try cj.asArray(try block.required("result_order"));
    const expected_ops = try cj.asArray(try block.required("ops"));
    // A vacuous replay must not report green.
    try testing.expect(prior.len > 0 and expected_ops.len > 0);

    const ops = try reconcile_mod.reconcile([]const u8, V, allocator, prior, target);
    defer allocator.free(ops);

    const ctx = LisCtx{
        .allocator = allocator,
        .prior = prior,
        .ops = ops,
        .result_order = result_order,
    };
    try block.assertKeyWith("ops", ctx, lisOps);
    try block.assertKeyWith("result_order", ctx, lisResultOrder);
    _ = try block.assertKeyWithOpt("stable_keys_not_invalidated", ctx, lisStableKeys);
    try block.finish();
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

    // Per-scenario replay accounting (#lzscenariocoverage). This fixture is the
    // one in the corpus carrying NO identifier — its scenarios are told apart
    // only by `policy` — so the ledger records them positionally and the
    // coverage guard reports the fallback rather than accepting it silently.
    var ledger = try cj.scenarios("collections/mergecell_algebra.json", parsed.value);
    try testing.expect(ledger.len() > 0);

    var steps_replayed: usize = 0;
    while (ledger.next()) |sc| {
        // Rung 4 books on the PAYLOAD handoff (#lzscenariobodyskip), so a
        // body that stops short of replaying stops being booked.
        const si = ledger.at();
        const scenario = try sc.replay();
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
            var where_buf: [192]u8 = undefined;
            const where = std.fmt.bufPrint(
                &where_buf,
                "collections/mergecell_algebra.json scenarios[{d}] ({s}) #{d}.expected",
                .{ si, policy.name, i },
            ) catch "collections/mergecell_algebra.json expected";
            // Rung 0 (`#lzzigblockwalk`): the per-step `expected` block was
            // compared key by key and bound to nothing, so all 15 of them were
            // invisible to every rung above the bind ledger.
            var block = cj.AssertionKeys.init(where, expected);
            const runs_before = probe_runs;

            mc.merge(try cj.asI64(try cj.required(step, "merge")));

            const ctx_step = MergeStepCtx{
                .got_value = mc.get(),
                .did_invalidate = probe_runs != runs_before,
                .scenario = si,
                .policy = policy.name,
                .step = i,
            };
            try block.assertKeyWith("value", ctx_step, mergeStepValue);
            try block.assertKeyWith("invalidates", ctx_step, mergeStepInvalidates);
            try block.finish();
            steps_replayed += 1;
        }
    }
    try testing.expect(steps_replayed > 0);
}

/// One `mergecell_algebra.json` step's observed outcome, so both of its
/// `expected` keys can be compared inside the tracker callback that books them
/// (`#lzzigblockwalk`).
const MergeStepCtx = struct {
    got_value: V,
    did_invalidate: bool,
    scenario: usize,
    policy: []const u8,
    step: usize,
};

fn mergeStepValue(ctx: MergeStepCtx, want_json: Value) anyerror!void {
    const want = try cj.asI64(want_json);
    if (ctx.got_value == want) return;
    std.debug.print(
        "scenario {d} ({s}) step {d}: converged value {d}, want {d}\n",
        .{ ctx.scenario, ctx.policy, ctx.step, ctx.got_value, want },
    );
    return error.ConvergedValueMismatch;
}

fn mergeStepInvalidates(ctx: MergeStepCtx, want_json: Value) anyerror!void {
    const want = try cj.asBool(want_json);
    if (ctx.did_invalidate == want) return;
    std.debug.print(
        "scenario {d} ({s}) step {d}: invalidates={} want {}\n",
        .{ ctx.scenario, ctx.policy, ctx.step, ctx.did_invalidate, want },
    );
    return error.InvalidationMismatch;
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

/// One `{id: derived}` entry of an `expect_*` block.
const DerivedCtx = struct {
    sem: *const Sem,
    id: []const u8,
    scenario: usize,
    phase: []const u8,
};

fn derivedMember(ctx: DerivedCtx, want_json: Value) anyerror!void {
    const want = try cj.asI64(want_json);
    const got = ctx.sem.nodeValue(ctx.id) orelse {
        std.debug.print(
            "scenario {d} {s}: node `{s}` has no derived value\n",
            .{ ctx.scenario, ctx.phase, ctx.id },
        );
        return error.MissingDerivedNode;
    };
    if (got == want) return;
    std.debug.print(
        "scenario {d} {s}: node `{s}` derived {d}, want {d}\n",
        .{ ctx.scenario, ctx.phase, ctx.id, got, want },
    );
    return error.DerivedValueMismatch;
}

/// Every `{id: derived}` entry in an `expect_*` block that names a tree node,
/// asserted THROUGH the block's tracker (`#lzzigblockwalk`). The two boolean
/// claims (`sibling_a_cached`, `downstream_consumer_reran`) are asserted by the
/// caller against the recompute counters, so this pass skips them and
/// `finish()` is what refuses one nobody discharged.
fn expectDerived(sem: *const Sem, block: *cj.AssertionKeys, scenario: usize, phase: []const u8) !void {
    var it = switch (block.object) {
        .object => |o| o.iterator(),
        else => return error.ExpectedObject,
    };
    while (it.next()) |entry| {
        const id = entry.key_ptr.*;
        if (entry.value_ptr.* != .integer) continue; // boolean claims handled by the caller
        try block.assertKeyWith(
            id,
            DerivedCtx{ .sem = sem, .id = id, .scenario = scenario, .phase = phase },
            derivedMember,
        );
    }
}

test "collections conformance: semtree_incremental.json" {
    const allocator = testing.allocator;
    var parsed = (try cj.load("collections/semtree_incremental.json")) orelse {
        skipAbsent("semtree_incremental.json");
        return;
    };
    defer parsed.deinit();

    // Per-scenario replay accounting (#lzscenariocoverage).
    var ledger = try cj.scenarios("collections/semtree_incremental.json", parsed.value);
    try testing.expect(ledger.len() > 0);

    while (ledger.next()) |sc| {
        // Rung 4 books on the PAYLOAD handoff (#lzscenariobodyskip), so a
        // body that stops short of replaying stops being booked.
        const si = ledger.at();
        const scenario = try sc.replay();
        const fold = try foldByName(try cj.asStr(try cj.required(scenario, "fold")));
        var tree = try buildTree(allocator, try cj.required(scenario, "tree"));
        defer tree.deinit();

        var sem = try Sem.build(allocator, tree.root, fold);
        defer sem.deinit();

        const expect_initial = try cj.required(scenario, "expect_initial");
        var initial_block = cj.AssertionKeys.init(
            "collections/semtree_incremental.json expect_initial",
            expect_initial,
        );
        // The fixture names the root's derived value as `root`, which is also
        // the root node's id — so the generic pass covers it.
        try expectDerived(&sem, &initial_block, si, "initial");
        try initial_block.finish();

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
        var after_block = cj.AssertionKeys.init(
            "collections/semtree_incremental.json expect_after",
            expect_after,
        );
        try expectDerived(&sem, &after_block, si, "after");

        // Both booleans are asserted in BOTH directions. `sibling_a_cached`
        // used to be a GATE — `if (want) { check }` — so flipping it to false
        // in the corpus deleted the check instead of demanding the opposite
        // fact (#lzconsumednotasserted).
        const memo = MemoCtx{
            .cached = sem.recomputeCount("a") == sibling_before,
            .reran = sem.recomputeCount("root") != root_before,
            .scenario = si,
        };
        _ = try after_block.assertKeyWithOpt("sibling_a_cached", memo, memoSiblingCached);
        _ = try after_block.assertKeyWithOpt("downstream_consumer_reran", memo, memoDownstreamReran);
        try after_block.finish();
    }
}

/// The two boolean memo claims of `semtree_incremental.json`'s `expect_after`,
/// sampled from the recompute counters before and after the mutation.
const MemoCtx = struct {
    cached: bool,
    reran: bool,
    scenario: usize,
};

fn memoSiblingCached(ctx: MemoCtx, want_json: Value) anyerror!void {
    const want = try cj.asBool(want_json);
    if (ctx.cached == want) return;
    std.debug.print(
        "scenario {d}: sibling subtree `a` cached={} want {} " ++
            "(an edit in a different subtree must not recompute it)\n",
        .{ ctx.scenario, ctx.cached, want },
    );
    return error.SiblingSubtreeRecomputed;
}

fn memoDownstreamReran(ctx: MemoCtx, want_json: Value) anyerror!void {
    const want = try cj.asBool(want_json);
    if (ctx.reran == want) return;
    std.debug.print(
        "scenario {d}: downstream_consumer_reran={} want {}\n",
        .{ ctx.scenario, ctx.reran, want },
    );
    return error.MemoGuardMismatch;
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

/// Shape 1 of `stableid_alignment.json`: key-identity claims over one `blocks`
/// list's indices.
const KeyClaimCtx = struct {
    blocks: []const stable_id.Block,
    scenario: usize,
    claims: *usize,
};

fn keysMustMatch(ctx: KeyClaimCtx, want: Value) anyerror!void {
    for (try cj.asArray(want)) |pair| {
        const p = try cj.asArray(pair);
        const i = try cj.asUsize(p[0]);
        const j = try cj.asUsize(p[1]);
        const a = stable_id.BlockKey.fromBlock(ctx.blocks[i]);
        const b = stable_id.BlockKey.fromBlock(ctx.blocks[j]);
        if (!a.eqlString(b)) {
            std.debug.print(
                "scenario {d}: blocks {d}/{d} must share a key\n",
                .{ ctx.scenario, i, j },
            );
            return error.KeyShouldMatch;
        }
        ctx.claims.* += 1;
    }
}

fn keysMustDiffer(ctx: KeyClaimCtx, want: Value) anyerror!void {
    for (try cj.asArray(want)) |pair| {
        const p = try cj.asArray(pair);
        const i = try cj.asUsize(p[0]);
        const j = try cj.asUsize(p[1]);
        const a = stable_id.BlockKey.fromBlock(ctx.blocks[i]);
        const b = stable_id.BlockKey.fromBlock(ctx.blocks[j]);
        if (a.eqlString(b)) {
            std.debug.print(
                "scenario {d}: blocks {d}/{d} must NOT share a key\n",
                .{ ctx.scenario, i, j },
            );
            return error.KeyShouldDiffer;
        }
        ctx.claims.* += 1;
    }
}

/// Shape 2: an `old`/`new` pair aligned against each other.
const AlignCtx = struct {
    allocator: std.mem.Allocator,
    old: []const stable_id.Block,
    new: []const stable_id.Block,
    alignment: *const stable_id.Alignment,
    scenario: usize,
    claims: *usize,
};

fn alignMatches(ctx: AlignCtx, want_json: Value) anyerror!void {
    const want = try cj.asArray(want_json);
    try testing.expectEqual(want.len, ctx.alignment.new_matches.len);
    for (want, ctx.alignment.new_matches, 0..) |spec, got, i| {
        try expectMatch(try cj.asStr(spec), got, ctx.scenario, i);
        ctx.claims.* += 1;
    }
}

fn alignRemoved(ctx: AlignCtx, want_json: Value) anyerror!void {
    const want = try cj.asArray(want_json);
    try testing.expectEqual(want.len, ctx.alignment.removed.len);
    for (want, ctx.alignment.removed) |w, got| {
        try testing.expectEqual(try cj.asUsize(w), got);
    }
    ctx.claims.* += 1;
}

fn alignSimilarityMin(ctx: AlignCtx, want_json: Value) anyerror!void {
    const floor: f32 = @floatCast(try cj.asF64(want_json));
    for (ctx.alignment.new_matches) |m| {
        if (m == .edited) try testing.expect(m.edited.similarity >= floor);
    }
    ctx.claims.* += 1;
}

fn alignStableKeys(ctx: AlignCtx, want_json: Value) anyerror!void {
    const keys = try stable_id.assignStableKeys(ctx.allocator, ctx.old, ctx.new);
    defer {
        for (keys) |k| ctx.allocator.free(k);
        ctx.allocator.free(keys);
    }
    for (try cj.asArray(want_json)) |pair| {
        const p = try cj.asArray(pair);
        const new_i = try cj.asUsize(p[0]);
        const old_i = try cj.asUsize(p[1]);
        var buf: [256]u8 = undefined;
        const old_key = stable_id.BlockKey.fromBlock(ctx.old[old_i]).writeString(&buf);
        try testing.expectEqualStrings(old_key, keys[new_i]);
        ctx.claims.* += 1;
    }
}

test "collections conformance: stableid_alignment.json" {
    const allocator = testing.allocator;
    var parsed = (try cj.load("collections/stableid_alignment.json")) orelse {
        skipAbsent("stableid_alignment.json");
        return;
    };
    defer parsed.deinit();

    // Per-scenario replay accounting (#lzscenariocoverage). Both shapes below
    // are recorded — the `blocks` shape `continue`s out of the body, so the
    // ledger entry has to be written before that branch is taken.
    var ledger = try cj.scenarios("collections/stableid_alignment.json", parsed.value);
    try testing.expect(ledger.len() > 0);

    var claims: usize = 0;
    while (ledger.next()) |sc| {
        // Rung 4 books on the PAYLOAD handoff (#lzscenariobodyskip), so a
        // body that stops short of replaying stops being booked.
        const si = ledger.at();
        const scenario = try sc.replay();
        const expect = try cj.required(scenario, "expect");
        // Rung 0 (`#lzzigblockwalk`): each scenario's `expect` block is bound,
        // and `finish()` is what refuses a claim key this runner does not
        // discharge — the `cj.field` gates it replaces read the key and could
        // not report one they had never heard of.
        var block = cj.AssertionKeys.init("collections/stableid_alignment.json expect", expect);

        // Shape 1: one `blocks` list, with key-identity claims over its indices.
        if (cj.field(scenario, "blocks")) |blocks_json| {
            const blocks = try blocksFrom(try cj.asArray(blocks_json));
            defer allocator.free(blocks);

            const ctx_keys = KeyClaimCtx{ .blocks = blocks, .scenario = si, .claims = &claims };
            _ = try block.assertKeyWithOpt("key_equal", ctx_keys, keysMustMatch);
            _ = try block.assertKeyWithOpt("key_not_equal", ctx_keys, keysMustDiffer);
            try block.finish();
            continue;
        }

        // Shape 2: an `old`/`new` pair aligned against each other.
        const old = try blocksFrom(try cj.asArray(try cj.required(scenario, "old")));
        defer allocator.free(old);
        const new = try blocksFrom(try cj.asArray(try cj.required(scenario, "new")));
        defer allocator.free(new);

        var alignment = try stable_id.alignBlocks(allocator, old, new);
        defer alignment.deinit();

        const ctx_align = AlignCtx{
            .allocator = allocator,
            .old = old,
            .new = new,
            .alignment = &alignment,
            .scenario = si,
            .claims = &claims,
        };
        _ = try block.assertKeyWithOpt("matches", ctx_align, alignMatches);
        _ = try block.assertKeyWithOpt("removed", ctx_align, alignRemoved);
        _ = try block.assertKeyWithOpt("similarity_min", ctx_align, alignSimilarityMin);
        _ = try block.assertKeyWithOpt("new_key_equals_old_key", ctx_align, alignStableKeys);
        try block.finish();
    }
    // A replay that asserted nothing is the vacuous green this file exists to
    // remove.
    try testing.expect(claims > 0);
}
