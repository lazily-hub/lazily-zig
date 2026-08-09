//! Canonical replay for `collections/seqcrdt_convergence.json`.
//!
//! `seq_crdt.zig` implements the whole move-aware sequence CRDT and carries six
//! inline tests, one per fixture scenario — and the corpus was still in
//! `KNOWN_UNCOVERED` under "No runner at all in this binding", which is why Zig
//! scored `~` on the move-aware-sequence-crdt coverage row.
//!
//! Those six mirrors are the argument for this module rather than against it.
//! One of them read:
//!
//!     try std.testing.expect(!ab.contains("b") or ab.get("b") == null);
//!
//! which is the mirror hedging around a real defect it was transcribed from:
//! `contains` answered from the ENTRY TABLE, so it returned true for a
//! tombstoned element. lazily-rs answers `entries.get(id).is_some_and(|e|
//! !e.deleted.value())`, and the fixture's `not_contains_on` pins that reading
//! directly. A mirror agrees with whatever it was transcribed from; the corpus
//! does not.
//!
//! What the fixture pins, and what this module therefore drives:
//!
//! - **insert_back_and_front_orders** — the `(frac, peer)` total order over
//!   fractional-index positions, front and back.
//! - **move_is_single_reassignment** — a move is ONE LWW reassignment of
//!   `position`, not delete+reinsert, so `len` is unchanged and the value
//!   travels with the element.
//! - **concurrent_inserts_same_gap_converge** — two replicas insert into the
//!   same gap; both survive, ordered by the peer tiebreak, and the two merge
//!   orders agree.
//! - **concurrent_move_converges_to_later_stamp** — the later HLC stamp wins a
//!   position conflict, with no duplication.
//! - **concurrent_move_and_value_edit_commute** — `position` and `value` are
//!   INDEPENDENT registers, so a concurrent move and value edit both apply.
//! - **remove_tombstone_converges_commutatively** — removal is an LWW tombstone
//!   and `a⊕b == b⊕a`.
//!
//! Replica identity: the fixture names replicas (`a`, `b`, `a2`, `merged`, …),
//! so each scenario carries its own small name table. A step naming an unknown
//! replica is a hard error rather than a skip — a runner that silently ignored a
//! step would replay a shorter scenario and still report the fixture covered.

const std = @import("std");
const testing = std.testing;

const cj = @import("conformance_json.zig");
const Value = cj.Value;

const seq_crdt = @import("seq_crdt.zig");
const PeerId = @import("crdt.zig").PeerId;

/// The fixture's element values are integers in some scenarios and strings in
/// others, so the replayed model is generic over a small sum rather than over
/// `std.json.Value` — the CRDT compares values for equality when reporting
/// change, and a whole JSON tree is more machinery than the corpus needs.
const SeqValue = union(enum) {
    integer: i64,
    string: []const u8,

    fn from(v: Value) !SeqValue {
        return switch (v) {
            .integer => |n| .{ .integer = n },
            .string => |s| .{ .string = s },
            else => error.UnsupportedSeqValue,
        };
    }
};

const Seq = seq_crdt.SeqCrdt([]const u8, SeqValue);

fn skipAbsent(name: []const u8) void {
    std.debug.print(
        "skipping {s}: {s}/collections absent - run with the lazily-spec sibling\n",
        .{ name, cj.CONFORMANCE_ROOT },
    );
}

/// One named replica.
const Replica = struct {
    name: []const u8,
    crdt: Seq,
};

/// The replica set for one scenario. Small and linear on purpose: a scenario
/// never has more than a handful, and lookup by name has to fail loudly.
const World = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Replica) = .empty,

    fn deinit(self: *World) void {
        for (self.items.items) |*r| r.crdt.deinit();
        self.items.deinit(self.allocator);
    }

    fn get(self: *World, name: []const u8) !*Replica {
        for (self.items.items) |*r| {
            if (std.mem.eql(u8, r.name, name)) return r;
        }
        std.debug.print("seqcrdt: no replica named `{s}`\n", .{name});
        return error.UnknownReplica;
    }

    fn put(self: *World, name: []const u8, crdt: Seq) !void {
        for (self.items.items) |*r| {
            if (!std.mem.eql(u8, r.name, name)) continue;
            r.crdt.deinit();
            r.crdt = crdt;
            return;
        }
        var owned = crdt;
        errdefer owned.deinit();
        try self.items.append(self.allocator, .{ .name = name, .crdt = owned });
    }
};

/// Apply one `op` step to one replica.
///
/// Every op carries its own `now`: the HLC never reads a system clock, which is
/// what makes a concurrent-stamp scenario replayable at all.
fn applyOp(r: *Replica, step: Value) !void {
    const op = try cj.asStr(try cj.required(step, "op"));
    const now = try cj.asU64(try cj.required(step, "now"));
    const id = try cj.asStr(try cj.required(step, "id"));

    if (std.mem.eql(u8, op, "insert_back")) {
        return r.crdt.insertBack(id, try SeqValue.from(try cj.required(step, "value")), now);
    }
    if (std.mem.eql(u8, op, "insert_front")) {
        return r.crdt.insertFront(id, try SeqValue.from(try cj.required(step, "value")), now);
    }
    if (std.mem.eql(u8, op, "set_value")) {
        _ = try r.crdt.setValue(id, try SeqValue.from(try cj.required(step, "value")), now);
        return;
    }
    if (std.mem.eql(u8, op, "move_after")) {
        const anchor = try cj.asStr(try cj.required(step, "anchor"));
        if (!try r.crdt.moveAfter(id, anchor, now)) return error.MoveAfterFoundNoAnchor;
        return;
    }
    if (std.mem.eql(u8, op, "move_before")) {
        const anchor = try cj.asStr(try cj.required(step, "anchor"));
        if (!try r.crdt.moveBefore(id, anchor, now)) return error.MoveBeforeFoundNoAnchor;
        return;
    }
    if (std.mem.eql(u8, op, "remove")) {
        if (!r.crdt.remove(id, now)) return error.RemoveFoundNoElement;
        return;
    }

    std.debug.print("seqcrdt: unhandled op `{s}`\n", .{op});
    return error.UnhandledOp;
}

/// Seed the scenario's replica `a`.
///
/// Two shapes, both in the corpus: a `replica`-only scenario that starts empty
/// and does its inserts as steps, and a `{peer, inserts}` seed.
fn seedWorld(allocator: std.mem.Allocator, world: *World, scenario: Value) !void {
    if (cj.field(scenario, "seed")) |seed| {
        const peer: PeerId = try cj.asU64(try cj.required(seed, "peer"));
        var a = Seq.init(allocator, peer);
        {
            errdefer a.deinit();
            for (try cj.asArray(try cj.required(seed, "inserts"))) |ins| {
                try a.insertBack(
                    try cj.asStr(try cj.required(ins, "id")),
                    try SeqValue.from(try cj.required(ins, "value")),
                    try cj.asU64(try cj.required(ins, "now")),
                );
            }
        }
        return world.put("a", a);
    }
    if (cj.field(scenario, "replica")) |rep| {
        const peer: PeerId = try cj.asU64(try cj.required(rep, "peer"));
        return world.put("a", Seq.init(allocator, peer));
    }
    return error.MissingSeed;
}

/// Replay one scenario's steps.
fn runSteps(world: *World, scenario: Value) !void {
    for (try cj.asArray(try cj.required(scenario, "steps"))) |step| {
        if (cj.field(step, "fork")) |fork_name| {
            // A fork always branches from `a`: the corpus never forks a fork,
            // and guessing a source would hide it if that changed. The step's
            // `now` is advisory — a fork is a copy, not a stamped event, so
            // there is no HLC tick to attribute to it.
            const peer: PeerId = try cj.asU64(try cj.required(step, "peer"));
            const src = try world.get("a");
            try world.put(try cj.asStr(fork_name), try src.crdt.fork(peer));
            continue;
        }
        if (cj.field(step, "clone")) |clone_name| {
            // Clone = same peer, same stamps. Forking under the source's own
            // peer is exactly that; a fresh peer would change the `(frac, peer)`
            // tiebreak and make the two "identical" replicas order differently.
            const src = try world.get(try cj.asStr(try cj.required(step, "from")));
            try world.put(try cj.asStr(clone_name), try src.crdt.fork(src.crdt.peer));
            continue;
        }
        if (cj.field(step, "merge")) |merge| {
            // `now` sits on the STEP, not inside the merge block: it is the
            // receiving replica's observation time, which the HLC needs to
            // advance past the highest stamp it just saw.
            const now = try cj.asU64(try cj.required(step, "now"));
            const from = try world.get(try cj.asStr(try cj.required(merge, "from")));
            const into = try world.get(try cj.asStr(try cj.required(merge, "into")));
            _ = try into.crdt.merge(&from.crdt, now);
            continue;
        }
        const on = if (cj.field(step, "on")) |o| try cj.asStr(o) else "a";
        if (cj.field(step, "op") == null) {
            std.debug.print("seqcrdt: step carries no recognised form\n", .{});
            return error.UnrecognizedStep;
        }
        try applyOp(try world.get(on), step);
    }
}

/// The replica `len` and `contains_all` are asserted on: the first replica of
/// the first `orders_equal` group when there is one — that is the converged
/// replica the fixture is talking about — else `a`.
///
/// This SELECTS A TARGET rather than comparing a value, so it reads the raw
/// block instead of going through the tracker; `orders_equal` is asserted on its
/// own below.
fn targetName(expect_raw: Value) ![]const u8 {
    if (cj.field(expect_raw, "orders_equal")) |groups_raw| {
        const groups = try cj.asArray(groups_raw);
        if (groups.len > 0) {
            const pair = try cj.asArray(groups[0]);
            if (pair.len > 0) return cj.asStr(pair[0]);
        }
    }
    return "a";
}

fn expectOrder(allocator: std.mem.Allocator, r: *Replica, want: Value) !void {
    const names = try cj.asArray(want);
    const got = try r.crdt.order(allocator);
    defer allocator.free(got);
    testing.expectEqual(names.len, got.len) catch |err| {
        std.debug.print("seqcrdt: replica {s} order length\n", .{r.name});
        return err;
    };
    for (names, got) |w, g| {
        testing.expectEqualStrings(try cj.asStr(w), g) catch |err| {
            std.debug.print("seqcrdt: replica {s} order\n", .{r.name});
            return err;
        };
    }
}

/// Compare a live element's value against the fixture's own, by the value's own
/// Zig type so the tracker records a real comparison.
fn assertElementValue(keys: *cj.AssertionKeys, name: []const u8, got: SeqValue) !void {
    return switch (got) {
        .integer => |n| keys.assertKey(name, n),
        .string => |s| keys.assertKey(name, s),
    };
}

/// The expectation checks, bundled so `assertKeyWith*` has one context value.
const Checks = struct {
    allocator: std.mem.Allocator,
    world: *World,
    target: []const u8,

    fn order(self: Checks, want: Value) !void {
        try expectOrder(self.allocator, try self.world.get("a"), want);
    }

    fn len(self: Checks, want: Value) !void {
        const r = try self.world.get(self.target);
        const live = try r.crdt.values(self.allocator);
        defer self.allocator.free(live);
        testing.expectEqual(try cj.asUsize(want), live.len) catch |err| {
            std.debug.print("seqcrdt: len on replica {s}\n", .{self.target});
            return err;
        };
    }

    fn ordersEqual(self: Checks, want: Value) !void {
        // Convergence is the identical live ORDER across a named pair, compared
        // against each other. Comparing each against a fixture literal instead
        // would pass on two replicas that both match it while disagreeing about
        // anything the literal elides.
        const groups = try cj.asArray(want);
        if (groups.len == 0) return error.OrdersEqualNeedsAGroup;
        for (groups) |group_raw| {
            const group = try cj.asArray(group_raw);
            if (group.len < 2) return error.OrdersEqualNeedsTwoReplicas;
            const first = try (try self.world.get(try cj.asStr(group[0]))).crdt.order(self.allocator);
            defer self.allocator.free(first);
            for (group[1..]) |n| {
                const other = try (try self.world.get(try cj.asStr(n))).crdt.order(self.allocator);
                defer self.allocator.free(other);
                try testing.expectEqual(first.len, other.len);
                for (first, other) |x, y| try testing.expectEqualStrings(x, y);
            }
        }
    }

    fn containsAll(self: Checks, want: Value) !void {
        const r = try self.world.get(self.target);
        for (try cj.asArray(want)) |id_raw| {
            const id = try cj.asStr(id_raw);
            testing.expect(r.crdt.contains(id)) catch |err| {
                std.debug.print("seqcrdt: replica {s} should contain `{s}`\n", .{ self.target, id });
                return err;
            };
        }
    }
};

/// `order_on` / `not_contains_on` — one array per named replica.
fn assertPerReplicaArray(
    allocator: std.mem.Allocator,
    world: *World,
    expect: *cj.AssertionKeys,
    key: []const u8,
    raw: Value,
    comptime check: fn (std.mem.Allocator, *Replica, Value) anyerror!void,
) !void {
    // DESCEND rather than sweep. The keys are data (replica names), so the CHILD
    // tracker owns each one: a replica the corpus adds later reaches a
    // comparison instead of being walked past by a loop nothing audits
    // (`#lzsubblockkeyset`).
    var on = try expect.sub(key);
    errdefer on.finish() catch {};
    var it = raw.object.iterator();
    while (it.next()) |entry| {
        const one = PerReplica{
            .allocator = allocator,
            .replica = try world.get(entry.key_ptr.*),
            .check = check,
        };
        try on.assertKeyWith(entry.key_ptr.*, one, PerReplica.run);
    }
    try on.finish();
}

/// One `order_on` / `not_contains_on` entry, resolved before the check runs.
///
/// The replica is bound into the context rather than looked up inside the check,
/// because `assertKeyWith` hands the check only the fixture's VALUE — which is
/// the right shape: a check that could pick its own key could also check the
/// wrong one.
const PerReplica = struct {
    allocator: std.mem.Allocator,
    replica: *Replica,
    check: *const fn (std.mem.Allocator, *Replica, Value) anyerror!void,

    fn run(self: PerReplica, want: Value) !void {
        return self.check(self.allocator, self.replica, want);
    }
};

fn checkOrderOn(allocator: std.mem.Allocator, replica: *Replica, want: Value) anyerror!void {
    return expectOrder(allocator, replica, want);
}

fn checkNotContainsOn(_: std.mem.Allocator, replica: *Replica, want: Value) anyerror!void {
    for (try cj.asArray(want)) |id_raw| {
        const id = try cj.asStr(id_raw);
        testing.expect(!replica.crdt.contains(id)) catch |err| {
            std.debug.print(
                "seqcrdt: replica {s} should NOT contain `{s}` (a removed element is a " ++
                    "tombstone in the entry table, and `contains` answers about LIVE elements)\n",
                .{ replica.name, id },
            );
            return err;
        };
    }
}

/// `get` on replica `a`, and `get_on` per named replica: element id -> value.
fn assertGetBlock(world: *World, expect: *cj.AssertionKeys, key: []const u8, raw: Value, on_a: bool) !void {
    var block = try expect.sub(key);
    errdefer block.finish() catch {};
    var it = raw.object.iterator();
    while (it.next()) |entry| {
        if (on_a) {
            // `get`'s keys are element ids, read from `a`.
            const got = (try world.get("a")).crdt.get(entry.key_ptr.*) orelse {
                std.debug.print("seqcrdt: get(`{s}`) is not live on `a`\n", .{entry.key_ptr.*});
                return error.GetMissingElement;
            };
            try assertElementValue(&block, entry.key_ptr.*, got);
            continue;
        }
        // `get_on`'s keys are replica names; descend a second time so the
        // element ids are owned by their own tracker.
        const replica = try world.get(entry.key_ptr.*);
        var ids = try block.sub(entry.key_ptr.*);
        errdefer ids.finish() catch {};
        const declared = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => return error.GetOnEntryNotAnObject,
        };
        var iit = declared.iterator();
        while (iit.next()) |id_entry| {
            const got = replica.crdt.get(id_entry.key_ptr.*) orelse {
                std.debug.print(
                    "seqcrdt: get_on(`{s}`, `{s}`) is not live\n",
                    .{ replica.name, id_entry.key_ptr.* },
                );
                return error.GetMissingElement;
            };
            try assertElementValue(&ids, id_entry.key_ptr.*, got);
        }
        try ids.finish();
    }
    try block.finish();
}

/// Replay one scenario end to end.
fn replayScenario(allocator: std.mem.Allocator, scenario: Value) !void {
    var world = World{ .allocator = allocator };
    defer world.deinit();

    try seedWorld(allocator, &world, scenario);
    try runSteps(&world, scenario);

    const expect_raw = try cj.required(scenario, "expect");
    var expect = cj.AssertionKeys.init("seqcrdt expect", expect_raw);
    const ctx = Checks{
        .allocator = allocator,
        .world = &world,
        .target = try targetName(expect_raw),
    };
    _ = try expect.assertKeyWithOpt("order", ctx, Checks.order);
    _ = try expect.assertKeyWithOpt("orders_equal", ctx, Checks.ordersEqual);
    _ = try expect.assertKeyWithOpt("len", ctx, Checks.len);
    _ = try expect.assertKeyWithOpt("contains_all", ctx, Checks.containsAll);
    if (expect.has("get")) {
        try assertGetBlock(&world, &expect, "get", try cj.required(expect_raw, "get"), true);
    }
    if (expect.has("get_on")) {
        try assertGetBlock(&world, &expect, "get_on", try cj.required(expect_raw, "get_on"), false);
    }
    if (expect.has("order_on")) {
        try assertPerReplicaArray(
            allocator,
            &world,
            &expect,
            "order_on",
            try cj.required(expect_raw, "order_on"),
            checkOrderOn,
        );
    }
    if (expect.has("not_contains_on")) {
        try assertPerReplicaArray(
            allocator,
            &world,
            &expect,
            "not_contains_on",
            try cj.required(expect_raw, "not_contains_on"),
            checkNotContainsOn,
        );
    }
    // Any expect key this runner does not know fails HERE rather than being
    // walked past — a corpus that grows a claim must redden the binding that
    // has not implemented it.
    try expect.finish();
}

fn replayFixture(comptime name: []const u8) !void {
    const rel = "collections/" ++ name;
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

test "collections: seqcrdt_convergence" {
    try replayFixture("seqcrdt_convergence.json");
}
