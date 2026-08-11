//! Canonical replays for the nine `lossless-tree/*.json` fixtures.
//!
//! `lossless_tree.zig` implements the whole `LosslessTreeCrdt` op vocabulary and
//! carries its own tests, but nothing in this binding ever opened the canonical
//! corpus for it: all nine fixtures sat in `KNOWN_UNCOVERED` under "No runner at
//! all in this binding", which is why Zig scored `~` on the three lossless-tree
//! rows in `coverage.json`.
//!
//! A binding's own tests and the corpus are not the same claim. The tests pin
//! what this implementation does; the corpus pins what every binding must agree
//! on, byte for byte. Retiring this binding's eight INLINE MIRRORS turned up
//! three real wire defects that the mirrors could not see, because a mirror
//! agrees with whatever it was transcribed from. A missing runner is the same
//! failure one step earlier: there is nothing to disagree with.
//!
//! What the fixtures pin, and what this module therefore drives:
//!
//! - **exact_roundtrip** — `render(tree) == source_text` over Token/Trivia/Raw/
//!   Error leaves including multi-byte text and an unclosed-fence Error span.
//! - **token_trivia_preservation** / **one_leaf_edit_delta** — an edit at a
//!   UTF-8 BYTE offset inside multi-byte text touches one leaf's text CRDT and
//!   ships as a bounded per-leaf delta.
//! - **split_merge** — `splitLeaf` / `mergeAdjacentLeaves` preserve the rendered
//!   text exactly.
//! - **concurrent_\*** — two replicas edit, exchange, and converge; the
//!   conflicting edits BOTH survive rather than one winning.
//! - **non_contiguous_anti_entropy** — a partner that received ops 0 and 2 but
//!   not 1 still converges once the gap is filled, which is what the dotted
//!   frontier exists for. `deliver.only` hands over exactly those indices.
//! - **invalid_source_roundtrip** — an Error leaf round-trips unchanged; the
//!   tree is lossless about text it cannot parse.
//! - **apply_update_advances_counter** — the Lamport counter advances past every
//!   observed op, unconditionally and BEFORE the idempotence skip, so a write
//!   minted AFTER a sync outranks the stamps that sync delivered. The first
//!   scenario in this corpus that mutates a replica AFTER a sync INTO it.
//! - **out_of_order_delivery_buffers** — an op whose parent/target or `prev` has
//!   not arrived is BUFFERED and retried as the rest of the same batch lands,
//!   rather than dropped while its dot is recorded. `deliver.order` ships the
//!   batch REVERSED, in one `applyUpdate` call (`#lzspecoutoforderfixtures`).
//!
//! Node identity: the fixtures name nodes by `label`, this binding by `OpId`.
//! Each replica therefore carries its own label table, populated as the seed
//! tree and every `create`/`split` op mint nodes. A step naming an unknown label
//! is a hard error rather than a skip — a runner that silently ignored a step
//! would replay a shorter scenario and still report the fixture covered.

const std = @import("std");
const testing = std.testing;

const cj = @import("conformance_json.zig");
const Value = cj.Value;

const lt = @import("lossless_tree.zig");
const LosslessTreeCrdt = lt.LosslessTreeCrdt;
const OpId = @import("crdt.zig").OpId;

fn skipAbsent(name: []const u8) void {
    std.debug.print(
        "skipping {s}: {s}/lossless-tree absent - run with the lazily-spec sibling\n",
        .{ name, cj.CONFORMANCE_ROOT },
    );
}

/// One named replica plus its label -> OpId table.
const Replica = struct {
    name: []const u8,
    crdt: LosslessTreeCrdt,
    labels: std.StringHashMapUnmanaged(OpId) = .empty,

    fn deinit(self: *Replica, allocator: std.mem.Allocator) void {
        self.crdt.deinit();
        self.labels.deinit(allocator);
    }

    fn node(self: *Replica, label: []const u8) !OpId {
        return self.labels.get(label) orelse {
            std.debug.print("lossless-tree: replica {s} has no node labelled `{s}`\n", .{ self.name, label });
            return error.UnknownNodeLabel;
        };
    }
};

/// The replica set for one scenario. Small and linear on purpose: a scenario
/// never has more than a handful, and lookup by name has to fail loudly.
const World = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Replica) = .empty,

    fn deinit(self: *World) void {
        for (self.items.items) |*r| r.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }

    fn get(self: *World, name: []const u8) !*Replica {
        for (self.items.items) |*r| {
            if (std.mem.eql(u8, r.name, name)) return r;
        }
        std.debug.print("lossless-tree: no replica named `{s}`\n", .{name});
        return error.UnknownReplica;
    }
};

/// Build the seed tree under `parent`, recording every `label`.
///
/// The fixture's node shape is either an element with `children` or a leaf with
/// `{kind, text}`. A node carrying neither is a corpus shape this runner does
/// not know, and is refused rather than skipped.
fn buildSeed(allocator: std.mem.Allocator, r: *Replica, parent: OpId, children: []const Value) !void {
    var after: ?OpId = null;
    for (children) |child| {
        const label = try cj.asStr(try cj.required(child, "label"));
        var id: OpId = undefined;
        if (cj.field(child, "leaf")) |leaf| {
            const kind = try lt.LeafKind.fromSeedKind(try cj.asStr(try cj.required(leaf, "kind")));
            const text = try cj.asStr(try cj.required(leaf, "text"));
            id = try r.crdt.createNode(parent, after, .{ .leaf = .{ .kind = kind, .text = text } });
        } else if (cj.field(child, "element")) |element| {
            id = try r.crdt.createNode(parent, after, .{ .element = try cj.asStr(element) });
            if (cj.field(child, "children")) |grand| {
                try buildSeed(allocator, r, id, try cj.asArray(grand));
            }
        } else {
            std.debug.print("lossless-tree: seed node `{s}` is neither a leaf nor an element\n", .{label});
            return error.UnknownSeedNode;
        }
        try r.labels.put(allocator, label, id);
        after = id;
    }
}

/// Resolve an optional `after` anchor: absent or null means "at the front".
fn afterAnchor(r: *Replica, step: Value) !?OpId {
    const raw = cj.field(step, "after") orelse return null;
    return switch (raw) {
        .null => null,
        else => try r.node(try cj.asStr(raw)),
    };
}

/// Apply one `op` step to one replica.
fn applyOp(allocator: std.mem.Allocator, r: *Replica, step: Value) !void {
    const op = try cj.asStr(try cj.required(step, "op"));

    if (std.mem.eql(u8, op, "create")) {
        const parent = if (cj.field(step, "parent")) |p| try r.node(try cj.asStr(p)) else lt.root_id;
        const after = try afterAnchor(r, step);
        const label = try cj.asStr(try cj.required(step, "label"));
        var id: OpId = undefined;
        if (cj.field(step, "leaf")) |leaf| {
            const kind = try lt.LeafKind.fromSeedKind(try cj.asStr(try cj.required(leaf, "kind")));
            const text = try cj.asStr(try cj.required(leaf, "text"));
            id = try r.crdt.createNode(parent, after, .{ .leaf = .{ .kind = kind, .text = text } });
        } else if (cj.field(step, "element")) |element| {
            id = try r.crdt.createNode(parent, after, .{ .element = try cj.asStr(element) });
        } else {
            return error.UnknownCreateShape;
        }
        try r.labels.put(allocator, label, id);
        return;
    }

    if (std.mem.eql(u8, op, "reorder")) {
        const node = try r.node(try cj.asStr(try cj.required(step, "node")));
        return r.crdt.reorderChild(node, try afterAnchor(r, step));
    }

    if (std.mem.eql(u8, op, "edit_leaf")) {
        const node = try r.node(try cj.asStr(try cj.required(step, "node")));
        // Byte offsets, not char offsets. The distinction is the point of the
        // multi-byte fixtures: at_byte 3 in "héllo" is after the two-byte é.
        const at_byte = try cj.asUsize(try cj.required(step, "at_byte"));
        const delete_bytes = if (cj.field(step, "delete_bytes")) |d| try cj.asUsize(d) else 0;
        const insert = if (cj.field(step, "insert")) |i| try cj.asStr(i) else "";
        return r.crdt.editLeaf(node, at_byte, delete_bytes, insert);
    }

    if (std.mem.eql(u8, op, "split")) {
        const node = try r.node(try cj.asStr(try cj.required(step, "node")));
        const at_byte = try cj.asUsize(try cj.required(step, "at_byte"));
        const new_id = try r.crdt.splitLeaf(node, at_byte);
        try r.labels.put(allocator, try cj.asStr(try cj.required(step, "new_label")), new_id);
        return;
    }

    if (std.mem.eql(u8, op, "merge_leaves")) {
        const left = try r.node(try cj.asStr(try cj.required(step, "left")));
        const right = try r.node(try cj.asStr(try cj.required(step, "right")));
        return r.crdt.mergeAdjacentLeaves(left, right);
    }

    std.debug.print("lossless-tree: unhandled op `{s}`\n", .{op});
    return error.UnhandledOp;
}

/// Which ops of the computed diff one delivery step ships, and in what sequence.
///
/// The diff itself is the same list `sync` computes — `diff(&their, allocator)`,
/// sorted by dotted `(counter, peer)`. That sort is pinned by
/// `lossless_tree_test.zig`'s "diff returns ops in canonical (counter, peer)
/// order", which is what makes an INDEX in the corpus mean the same op here as
/// in every other binding.
const Selection = union(enum) {
    /// A full `sync`: the whole diff, in canonical order.
    all,
    /// `deliver.only` — restrict delivery to those indices of the diff. The
    /// non-contiguous case, where the partner receives ops 0 and 2 and must
    /// still converge when 1 arrives later; applying the full diff there would
    /// test nothing.
    only: []const Value,
    /// `deliver.order` — deliver exactly those entries, IN THE LISTED SEQUENCE,
    /// as ONE `applyUpdate` call (`#lzspecoutoforderfixtures`).
    ///
    /// Not re-sorted, not split across calls, not clamped. A binding that
    /// re-sorts this list was measured GREEN against a library with no
    /// dependency buffer at all: canonical order delivers every parent before
    /// its child, so the buffer is never exercised and
    /// `out_of_order_delivery_buffers` stops discriminating anything. `order`
    /// need not be a permutation of the diff.
    order: []const Value,
};

/// Read the delivery selector off a `deliver` step. EXACTLY ONE of
/// `only` / `order` — both is ambiguous, neither is a corpus shape this runner
/// does not know. Fail closed on either, rather than picking a default and
/// replaying a step the fixture did not write (`#lzspecoutoforderfixtures`).
fn deliverSelection(d: Value) !Selection {
    const only = cj.field(d, "only");
    const order = cj.field(d, "order");
    if (only != null and order != null) {
        std.debug.print(
            "lossless-tree: `deliver` carries BOTH `only` and `order`; they select the " ++
                "same diff two ways and this runner will not guess which one the fixture meant\n",
            .{},
        );
        return error.DeliverSelectorConflict;
    }
    if (only) |o| return .{ .only = try cj.asArray(o) };
    if (order) |o| return .{ .order = try cj.asArray(o) };
    std.debug.print(
        "lossless-tree: `deliver` carries neither `only` nor `order`; a delivery with no " ++
            "selector is a `sync` the corpus spelled as a `deliver`\n",
        .{},
    );
    return error.DeliverSelectorMissing;
}

/// Test-only observation point (`#lzspecoutoforderfixtures`).
///
/// A fixture cannot assert on how its own step was INTERPRETED: a runner that
/// re-sorts `order` replays a different scenario and still renders whatever a
/// buffer-less library renders under canonical order. So the sequence handed to
/// `applyUpdate`, and the number of calls it took, are pinned by a direct test
/// through this probe rather than by the corpus.
const DeliveryProbe = struct {
    allocator: std.mem.Allocator,
    /// One increment per `applyUpdate` call `deliver` makes.
    calls: usize = 0,
    /// Every op id handed over, concatenated in the order it was passed.
    ids: std.ArrayListUnmanaged(OpId) = .empty,

    fn deinit(self: *DeliveryProbe) void {
        self.ids.deinit(self.allocator);
    }
};

var delivery_probe: ?*DeliveryProbe = null;

fn recordDelivery(ops: []const lt.TreeOp) void {
    const probe = delivery_probe orelse return;
    probe.calls += 1;
    for (ops) |op| probe.ids.append(probe.allocator, op.id) catch @panic("delivery probe out of memory");
}

/// Ship `from`'s unseen ops to `to`, as selected.
fn deliver(allocator: std.mem.Allocator, from: *Replica, to: *Replica, sel: Selection) !void {
    var their = to.crdt.getFrontier();
    const update = try from.crdt.diff(&their, allocator);
    defer from.crdt.freeUpdate(update);

    const idxs = switch (sel) {
        .all => {
            recordDelivery(update.ops);
            return to.crdt.applyUpdate(update);
        },
        .only => |o| o,
        .order => |o| o,
    };

    var picked = std.ArrayList(lt.TreeOp).empty;
    defer picked.deinit(allocator);
    for (idxs) |iv| {
        const i = try cj.asUsize(iv);
        // Refuse rather than clamp. A clamped index silently delivers a
        // DIFFERENT op than the fixture names, which is the one failure the
        // corpus cannot see from the outside.
        if (i >= update.ops.len) {
            std.debug.print(
                "lossless-tree: delivery index {d} is past the {d}-op diff from {s} to {s}\n",
                .{ i, update.ops.len, from.name, to.name },
            );
            return error.DeliverIndexOutOfRange;
        }
        try picked.append(allocator, update.ops[i]);
    }
    // ONE call, in the sequence the fixture listed.
    recordDelivery(picked.items);
    return to.crdt.applyUpdate(.{ .ops = picked.items });
}

/// A label table is per-replica, but a node created on one replica and shipped
/// to another has the SAME OpId, so the receiver can adopt the sender's labels
/// verbatim. Without this a post-sync step naming a remotely-created node would
/// fail on the receiver.
fn adoptLabels(allocator: std.mem.Allocator, from: *Replica, to: *Replica) !void {
    var it = from.labels.iterator();
    while (it.next()) |entry| {
        try to.labels.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
    }
}

fn expectRender(r: *Replica, allocator: std.mem.Allocator, want: []const u8) !void {
    const got = try r.crdt.render(allocator);
    defer allocator.free(got);
    testing.expectEqualStrings(want, got) catch |err| {
        std.debug.print("lossless-tree: replica {s} rendered wrong\n", .{r.name});
        return err;
    };
}

/// Replay one scenario end to end.
fn replayScenario(allocator: std.mem.Allocator, scenario: Value) !void {
    var world = World{ .allocator = allocator };
    defer world.deinit();

    const seed = try cj.required(scenario, "seed");
    var a = Replica{
        .name = "a",
        .crdt = try LosslessTreeCrdt.init(allocator, try cj.asU64(try cj.required(seed, "peer"))),
    };
    {
        errdefer a.deinit(allocator);
        const tree = try cj.required(seed, "tree");
        try buildSeed(allocator, &a, lt.root_id, try cj.asArray(try cj.required(tree, "children")));
    }
    try world.items.append(allocator, a);

    if (cj.field(scenario, "steps")) |steps_raw| {
        // Steps are replayed in corpus order with NO phase model: nothing here
        // assumes fork -> concurrent edits -> sync, and no replica's diff,
        // frontier or clock is cached across steps (`deliver` recomputes both
        // sides every time). `apply_update_advances_counter` is the first
        // scenario to mutate a replica AFTER a sync INTO it, and that works
        // because a mutation step is just "resolve the named replica, apply the
        // op" wherever it lands (`#lzspecoutoforderfixtures`).
        for (try cj.asArray(steps_raw)) |step| {
            if (cj.field(step, "fork")) |fork_name| {
                const name = try cj.asStr(fork_name);
                const peer = try cj.asU64(try cj.required(step, "peer"));
                // A fork always branches from `a`: the corpus never forks a
                // fork, and guessing a source would hide it if that changed.
                const src = try world.get("a");
                var forked = Replica{ .name = name, .crdt = try src.crdt.fork(peer) };
                errdefer forked.deinit(allocator);
                try adoptLabels(allocator, src, &forked);
                try world.items.append(allocator, forked);
                continue;
            }
            if (cj.field(step, "sync")) |sync| {
                const from = try world.get(try cj.asStr(try cj.required(sync, "from")));
                const to_name = try cj.asStr(try cj.required(sync, "to"));
                const to = try world.get(to_name);
                try deliver(allocator, from, to, .all);
                try adoptLabels(allocator, from, to);
                continue;
            }
            if (cj.field(step, "deliver")) |d| {
                const from = try world.get(try cj.asStr(try cj.required(d, "from")));
                const to = try world.get(try cj.asStr(try cj.required(d, "to")));
                try deliver(allocator, from, to, try deliverSelection(d));
                try adoptLabels(allocator, from, to);
                continue;
            }
            const on = if (cj.field(step, "on")) |o| try cj.asStr(o) else "a";
            try applyOp(allocator, try world.get(on), step);
        }
    }

    var expect = cj.AssertionKeys.init("lossless-tree expect", try cj.required(scenario, "expect"));
    const ctx = Checks{ .allocator = allocator, .world = &world };
    _ = try expect.assertKeyWithOpt("render", ctx, Checks.render);
    if (expect.has("render_on")) {
        // DESCEND rather than sweep. `render_on`'s keys are data (replica
        // names), so the CHILD tracker owns each one: a replica the corpus adds
        // later reaches a comparison instead of being walked past by a loop
        // nothing audits (`#lzsubblockkeyset`). The key list comes from the raw
        // object; every name then goes through the child's own assert, which is
        // what marks it consumed.
        const raw = try cj.required(try cj.required(scenario, "expect"), "render_on");
        var on = try expect.sub("render_on");
        var it = raw.object.iterator();
        while (it.next()) |entry| {
            const one = RenderOne{ .allocator = allocator, .replica = try world.get(entry.key_ptr.*) };
            try on.assertKeyWith(entry.key_ptr.*, one, RenderOne.check);
        }
        try on.finish();
    }
    _ = try expect.assertKeyWithOpt("converged", ctx, Checks.converged);
    _ = try expect.assertKeyWithOpt("live_nodes", ctx, Checks.liveNodes);
    // Any expect key this runner does not know fails HERE rather than being
    // walked past — a corpus that grows a claim must redden the binding that
    // has not implemented it.
    try expect.finish();
}

/// One `render_on` entry, resolved before the check runs.
///
/// The replica is bound into the context rather than looked up inside the
/// check, because `assertKeyWith` hands the check only the fixture's VALUE —
/// which is the right shape: a check that could pick its own key could also
/// check the wrong one.
const RenderOne = struct {
    allocator: std.mem.Allocator,
    replica: *Replica,

    fn check(self: RenderOne, want: Value) !void {
        try expectRender(self.replica, self.allocator, try cj.asStr(want));
    }
};

/// The expectation checks, bundled so `assertKeyWith*` has one context value.
const Checks = struct {
    allocator: std.mem.Allocator,
    world: *World,

    fn render(self: Checks, want: Value) !void {
        try expectRender(try self.world.get("a"), self.allocator, try cj.asStr(want));
    }

    fn converged(self: Checks, want: Value) !void {
        // Convergence is identical RENDERED text across every named replica,
        // compared pairwise against the first. Comparing each against the
        // fixture's own expected string instead would pass on two replicas that
        // both match it while disagreeing about anything render elides.
        const names = try cj.asArray(want);
        if (names.len < 2) return error.ConvergedNeedsTwoReplicas;
        const first = try (try self.world.get(try cj.asStr(names[0]))).crdt.render(self.allocator);
        defer self.allocator.free(first);
        for (names[1..]) |n| {
            const other = try (try self.world.get(try cj.asStr(n))).crdt.render(self.allocator);
            defer self.allocator.free(other);
            try testing.expectEqualStrings(first, other);
        }
    }

    fn liveNodes(self: Checks, want: Value) !void {
        // Asserted on EVERY replica, not just `a`. After a converging exchange
        // the counts must agree, so checking one would leave a replica that
        // resurrected or dropped a node undetected.
        const n = try cj.asUsize(want);
        for (self.world.items.items) |*r| {
            testing.expectEqual(n, r.crdt.liveNodeCount()) catch |err| {
                std.debug.print("lossless-tree: replica {s} live node count\n", .{r.name});
                return err;
            };
        }
    }
};

fn replayFixture(comptime name: []const u8) !void {
    const rel = "lossless-tree/" ++ name;
    var fx = (try cj.load(rel)) orelse {
        skipAbsent(rel);
        return;
    };
    defer fx.deinit();

    var it = try cj.scenarios(rel, fx.value);
    var replayed: usize = 0;
    while (it.next()) |scenario| {
        try replayScenario(testing.allocator, try scenario.replay());
        replayed += 1;
    }
    // A fixture whose scenarios all vanished upstream would otherwise pass by
    // replaying nothing at all.
    try testing.expect(replayed == it.len() and replayed > 0);
}

test "lossless-tree: exact_roundtrip" {
    try replayFixture("exact_roundtrip.json");
}

test "lossless-tree: invalid_source_roundtrip" {
    try replayFixture("invalid_source_roundtrip.json");
}

test "lossless-tree: token_trivia_preservation" {
    try replayFixture("token_trivia_preservation.json");
}

test "lossless-tree: one_leaf_edit_delta" {
    try replayFixture("one_leaf_edit_delta.json");
}

test "lossless-tree: split_merge" {
    try replayFixture("split_merge.json");
}

test "lossless-tree: concurrent_insert_same_parent" {
    try replayFixture("concurrent_insert_same_parent.json");
}

test "lossless-tree: concurrent_conflict_preserves_text" {
    try replayFixture("concurrent_conflict_preserves_text.json");
}

test "lossless-tree: concurrent_reorder_and_leaf_edit" {
    try replayFixture("concurrent_reorder_and_leaf_edit.json");
}

test "lossless-tree: non_contiguous_anti_entropy" {
    try replayFixture("non_contiguous_anti_entropy.json");
}

test "lossless-tree: apply_update_advances_counter" {
    try replayFixture("apply_update_advances_counter.json");
}

test "lossless-tree: out_of_order_delivery_buffers" {
    try replayFixture("out_of_order_delivery_buffers.json");
}

// ---------------------------------------------------------------------------
// The runner's own contract (`#lzspecoutoforderfixtures`)
// ---------------------------------------------------------------------------
//
// These replay INLINE scenarios, not corpus fixtures, and that is the point: a
// fixture can assert on what the library did, never on how the runner read the
// step that drove it. `deliver.order`'s whole value is the SEQUENCE, and a
// runner that re-sorted it — or clamped an index, or split the batch — would
// keep every corpus replay green while `out_of_order_delivery_buffers` stopped
// discriminating a dependency buffer from no buffer at all.
//
// Every scenario below is the same three-op shape the corpus uses: `b` forks
// off holding only the empty `para`, then `a` creates `outer`, creates `inner`
// under it, and edits `inner` — so the diff from `a` to `b` is exactly the
// three ops (2,1), (3,1), (4,1) in canonical order.
fn replayInline(src: []const u8) !void {
    var parsed = try cj.json.parseFromSlice(Value, testing.allocator, src, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try replayScenario(testing.allocator, parsed.value);
}

const three_op_steps =
    \\    { "fork": "b", "peer": 2 },
    \\    { "on": "a", "op": "create", "parent": "para", "after": null, "label": "outer", "element": "wrap" },
    \\    { "on": "a", "op": "create", "parent": "outer", "after": null, "label": "inner", "leaf": { "kind": "raw", "text": "deep" } },
    \\    { "on": "a", "op": "edit_leaf", "node": "inner", "at_byte": 4, "delete_bytes": 0, "insert": "X" },
;

fn threeOpScenario(comptime delivery: []const u8, comptime expect: []const u8) []const u8 {
    return
    \\{
    \\  "id": "runner_contract",
    \\  "seed": { "peer": 1, "tree": { "children": [
    \\    { "label": "para", "element": "para", "children": [] }
    \\  ] } },
    \\  "steps": [
    ++ three_op_steps ++ delivery ++
        \\
        \\  ],
        \\  "expect":
    ++ expect ++
        \\
        \\}
    ;
}

test "lossless-tree runner: deliver.order reaches applyUpdate unsorted, in ONE call" {
    var probe = DeliveryProbe{ .allocator = testing.allocator };
    defer probe.deinit();
    delivery_probe = &probe;
    defer delivery_probe = null;

    try replayInline(threeOpScenario(
        \\    { "deliver": { "from": "a", "to": "b", "order": [2, 1, 0] } }
    ,
        \\ { "render_on": { "a": "deepX", "b": "deepX" } }
    ));

    // ONE call. Splitting the batch would let each op find its dependency
    // already applied, so the buffer would never be exercised.
    try testing.expectEqual(@as(usize, 1), probe.calls);
    // The LISTED sequence, reversed relative to the canonical diff.
    try testing.expectEqualSlices(OpId, &.{
        .{ .counter = 4, .peer = 1 },
        .{ .counter = 3, .peer = 1 },
        .{ .counter = 2, .peer = 1 },
    }, probe.ids.items);
    // Non-vacuity: the canonical order really is the OTHER one, so a re-sorting
    // runner could not satisfy the assertion above by accident.
    for (probe.ids.items[1..], probe.ids.items[0 .. probe.ids.items.len - 1]) |curr, prev| {
        try testing.expectEqual(std.math.Order.gt, prev.compare(curr));
    }
}

test "lossless-tree runner: an out-of-range delivery index fails rather than clamping" {
    // Non-vacuity first: the last valid index really is 2, so the refusal below
    // is about the bound and not about the shape. `b` renders empty because the
    // one op it received is a `LeafEdit` whose target has not arrived — it sits
    // in the buffer, which is the behaviour the corpus fixture goes on to pin.
    try replayInline(threeOpScenario(
        \\    { "deliver": { "from": "a", "to": "b", "order": [2] } }
    ,
        \\ { "render_on": { "a": "deepX", "b": "" } }
    ));
    try testing.expectError(error.DeliverIndexOutOfRange, replayInline(threeOpScenario(
        \\    { "deliver": { "from": "a", "to": "b", "order": [3] } }
    ,
        \\ { "render_on": { "a": "deepX", "b": "deepX" } }
    )));
    try testing.expectError(error.DeliverIndexOutOfRange, replayInline(threeOpScenario(
        \\    { "deliver": { "from": "a", "to": "b", "only": [0, 9] } }
    ,
        \\ { "render_on": { "a": "deepX", "b": "deepX" } }
    )));
}

test "lossless-tree runner: a deliver step carries exactly one of only/order" {
    try testing.expectError(error.DeliverSelectorConflict, replayInline(threeOpScenario(
        \\    { "deliver": { "from": "a", "to": "b", "only": [0], "order": [0] } }
    ,
        \\ { "render_on": { "a": "deepX", "b": "deepX" } }
    )));
    try testing.expectError(error.DeliverSelectorMissing, replayInline(threeOpScenario(
        \\    { "deliver": { "from": "a", "to": "b" } }
    ,
        \\ { "render_on": { "a": "deepX", "b": "deepX" } }
    )));
}
