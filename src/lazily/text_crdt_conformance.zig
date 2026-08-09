//! Canonical replays for `collections/textcrdt_convergence.json` and
//! `collections/textcrdt_delta_sync.json`.
//!
//! `text_crdt.zig` implements the whole Fugue/RGA character CRDT and carries its
//! own tests, but nothing in this binding ever opened the canonical corpus for
//! it: both fixtures sat in `KNOWN_UNCOVERED` under "No runner at all in this
//! binding", which is why Zig scored `~` on the free-text-character-crdt and
//! textcrdt-delta-sync coverage rows.
//!
//! A binding's own tests and the corpus are not the same claim, and the six
//! inline mirrors in `text_crdt.zig` are the reason to say so out loud: a mirror
//! agrees with whatever it was transcribed from. `lossless_tree_conformance.zig`
//! found three real wire defects the moment its mirrors were retired; this
//! module found one more of the same family in `seq_crdt.zig` (see
//! `seq_crdt_conformance.zig`).
//!
//! What the fixtures pin, and what this module therefore drives:
//!
//! - **local_insert_and_delete** — index-addressed `insert` / `delete` over the
//!   visible text, with the tombstone left in place.
//! - **concurrent_\*** — two replicas edit the same spot, merge in both
//!   directions, and converge with BOTH edits preserved (peer tiebreak), never
//!   one winning.
//! - **merge_is_idempotent_and_commutative** — `a⊕b⊕b == a⊕b` and
//!   `a⊕b == b⊕a`, replayed as two clones merged in opposite orders.
//! - **gc_collects_stable_leaf_keeps_referenced_tombstone** — GC is conditional
//!   on stability AND on nothing referencing the element as a left origin, so
//!   the same op run twice with different stability collects 0 then 1.
//! - **version_vector_covers_inserts_and_tombstones** — the version vector is
//!   the greatest counter per peer over insert ids AND tombstone delete ids;
//!   omitting the delete stamps is the classic under-count.
//! - **bidirectional_delta_exchange_converges** / **snapshot_fork_preserves_identity_and_merges**
//!   — `delta_since` / `apply_delta` preserve every element's `OpId`, so a
//!   replica rebuilt from a whole-state snapshot (`delta_since({})`) still
//!   merges conflict-free with its source. Re-parsing would mint fresh ids and
//!   duplicate on merge, which is exactly what scenarios 2-3 fail on.
//! - **delta_apply_is_idempotent** — re-applying the same delta reports no
//!   change rather than re-inserting.
//!
//! Replica identity: the fixtures name replicas (`a`, `b`, `ab`, `member`), so
//! each scenario carries its own small name table. A step naming an unknown
//! replica is a hard error rather than a skip — a runner that silently ignored a
//! step would replay a shorter scenario and still report the fixture covered.

const std = @import("std");
const testing = std.testing;

const cj = @import("conformance_json.zig");
const Value = cj.Value;

const TextCrdt = @import("text_crdt.zig").TextCrdt;
const OpId = @import("crdt.zig").OpId;

fn skipAbsent(name: []const u8) void {
    std.debug.print(
        "skipping {s}: {s}/collections absent - run with the lazily-spec sibling\n",
        .{ name, cj.CONFORMANCE_ROOT },
    );
}

/// One named replica.
const Replica = struct {
    name: []const u8,
    crdt: TextCrdt,
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
        std.debug.print("textcrdt: no replica named `{s}`\n", .{name});
        return error.UnknownReplica;
    }

    /// Bind `name` to `crdt`, replacing any replica already under that name.
    /// The corpus does not currently rebind, but a `new`/`snapshot` step that
    /// did would otherwise leak the old replica and keep asserting the stale one.
    fn put(self: *World, name: []const u8, crdt: TextCrdt) !void {
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

fn alwaysStable(_: OpId) bool {
    return true;
}

fn neverStable(_: OpId) bool {
    return false;
}

/// The single code point behind an `insert` step's `ch`.
///
/// Refused rather than truncated when the fixture carries zero or several: `ch`
/// is a CHARACTER in this model, and quietly taking the first of a grapheme
/// cluster would replay a different edit than the corpus describes.
fn singleCodepoint(s: []const u8) !u21 {
    var view = try std.unicode.Utf8View.init(s);
    var it = view.iterator();
    const cp = it.nextCodepoint() orelse return error.EmptyChar;
    if (it.nextCodepoint() != null) return error.MultiCodepointChar;
    return cp;
}

/// Apply one `op` step to one replica.
fn applyOp(r: *Replica, step: Value) !void {
    const op = try cj.asStr(try cj.required(step, "op"));

    if (std.mem.eql(u8, op, "insert")) {
        const index = try cj.asUsize(try cj.required(step, "index"));
        return r.crdt.insert(index, try singleCodepoint(try cj.asStr(try cj.required(step, "ch"))));
    }

    if (std.mem.eql(u8, op, "insert_str")) {
        const index = try cj.asUsize(try cj.required(step, "index"));
        return r.crdt.insertStr(index, try cj.asStr(try cj.required(step, "str")));
    }

    if (std.mem.eql(u8, op, "delete")) {
        return r.crdt.delete(try cj.asUsize(try cj.required(step, "index")));
    }

    if (std.mem.eql(u8, op, "gc")) {
        // `stable` selects the stability oracle, which is the whole subject of
        // the fixture: the same tombstone is uncollectable then collectable.
        const stable = try cj.asBool(try cj.required(step, "stable"));
        const is_stable: *const fn (OpId) bool = if (stable) &alwaysStable else &neverStable;
        const collected = try r.crdt.gcWith(is_stable);
        if (cj.field(step, "expect_collected")) |want| {
            testing.expectEqual(try cj.asUsize(want), collected) catch |err| {
                std.debug.print("textcrdt: gc(stable={}) collected {d}\n", .{ stable, collected });
                return err;
            };
        }
        return;
    }

    std.debug.print("textcrdt: unhandled op `{s}`\n", .{op});
    return error.UnhandledOp;
}

/// Ship `from`'s unseen ops to `to` and report whether `to`'s text changed.
fn shipDelta(allocator: std.mem.Allocator, from: *const Replica, to: *Replica) !bool {
    var their = try to.crdt.versionVector(allocator);
    defer their.deinit();
    const ops = try from.crdt.deltaSince(&their, allocator);
    defer allocator.free(ops);
    return to.crdt.applyDelta(ops);
}

/// Bidirectional delta sync.
///
/// BOTH version vectors are read before EITHER delta is applied. Computing the
/// second delta after the first has landed would ask a replica that already
/// holds the partner's ops what the partner is missing, which is a different
/// (and weaker) question than the one the fixture poses.
fn exchange(allocator: std.mem.Allocator, x: *Replica, y: *Replica) !void {
    var xv = try x.crdt.versionVector(allocator);
    defer xv.deinit();
    var yv = try y.crdt.versionVector(allocator);
    defer yv.deinit();

    const to_x = try y.crdt.deltaSince(&xv, allocator);
    defer allocator.free(to_x);
    const to_y = try x.crdt.deltaSince(&yv, allocator);
    defer allocator.free(to_y);

    _ = try x.crdt.applyDelta(to_x);
    _ = try y.crdt.applyDelta(to_y);
}

/// Assert a step-level `expect_changed`, when the fixture carries one.
fn expectChanged(step: Value, changed: bool, what: []const u8) !void {
    const want = cj.field(step, "expect_changed") orelse return;
    testing.expectEqual(try cj.asBool(want), changed) catch |err| {
        std.debug.print("textcrdt: {s} reported changed={}\n", .{ what, changed });
        return err;
    };
}

/// Seed the scenario's replica `a`.
///
/// Three shapes, all of them in the corpus: a bare `seed` string with the peer
/// on `replica`, a `{peer, text}` seed object, and a `replica`-only scenario
/// that starts empty.
fn seedWorld(allocator: std.mem.Allocator, world: *World, scenario: Value) !void {
    if (cj.field(scenario, "seed")) |seed| {
        switch (seed) {
            .string => |text| {
                const peer = if (cj.field(scenario, "replica")) |rep|
                    try cj.asU64(try cj.required(rep, "peer"))
                else
                    return error.SeedStringWithoutReplicaPeer;
                return world.put("a", try TextCrdt.fromStr(allocator, peer, text));
            },
            .object => {
                const peer = try cj.asU64(try cj.required(seed, "peer"));
                const text = try cj.asStr(try cj.required(seed, "text"));
                return world.put("a", try TextCrdt.fromStr(allocator, peer, text));
            },
            else => return error.UnknownSeedShape,
        }
    }
    if (cj.field(scenario, "replica")) |rep| {
        const peer = try cj.asU64(try cj.required(rep, "peer"));
        return world.put("a", TextCrdt.init(allocator, peer));
    }
    return error.MissingSeed;
}

/// Replay one scenario's steps.
fn runSteps(allocator: std.mem.Allocator, world: *World, scenario: Value) !void {
    const steps_raw = cj.field(scenario, "steps") orelse return;
    for (try cj.asArray(steps_raw)) |step| {
        if (cj.field(step, "fork")) |fork_name| {
            // A fork always branches from `a`: the corpus never forks a fork,
            // and guessing a source would hide it if that changed.
            const peer = try cj.asU64(try cj.required(step, "peer"));
            const src = try world.get("a");
            try world.put(try cj.asStr(fork_name), try src.crdt.fork(peer));
            continue;
        }
        if (cj.field(step, "clone")) |clone_name| {
            // Clone = same peer, same ids. Forking under the source's own peer
            // is exactly that; passing a fresh peer here would make the two
            // "identical" replicas mint different ids on the next edit and turn
            // the idempotence scenario into a convergence scenario.
            const src = try world.get(try cj.asStr(try cj.required(step, "from")));
            try world.put(try cj.asStr(clone_name), try src.crdt.fork(src.crdt.peer));
            continue;
        }
        if (cj.field(step, "new")) |new_name| {
            const peer = try cj.asU64(try cj.required(step, "peer"));
            try world.put(try cj.asStr(new_name), TextCrdt.init(allocator, peer));
            continue;
        }
        if (cj.field(step, "merge")) |merge| {
            const from = try world.get(try cj.asStr(try cj.required(merge, "from")));
            const into = try world.get(try cj.asStr(try cj.required(merge, "into")));
            _ = try into.crdt.merge(&from.crdt);
            continue;
        }
        if (cj.field(step, "delta")) |d| {
            const from = try world.get(try cj.asStr(try cj.required(d, "from")));
            const into = try world.get(try cj.asStr(try cj.required(d, "into")));
            const changed = try shipDelta(allocator, from, into);
            try expectChanged(step, changed, "delta");
            continue;
        }
        if (cj.field(step, "snapshot")) |s| {
            // A whole-state snapshot is `delta_since({})` — the empty version
            // vector, not a re-parse of the rendered text.
            const from_name = try cj.asStr(try cj.required(s, "from"));
            const into_name = try cj.asStr(try cj.required(s, "into"));
            const peer = try cj.asU64(try cj.required(s, "peer"));

            var replica = TextCrdt.init(allocator, peer);
            const changed = blk: {
                errdefer replica.deinit();
                var empty = std.AutoHashMap(u64, u64).init(allocator);
                defer empty.deinit();
                const from = try world.get(from_name);
                const ops = try from.crdt.deltaSince(&empty, allocator);
                defer allocator.free(ops);
                break :blk try replica.applyDelta(ops);
            };
            try world.put(into_name, replica);
            try expectChanged(step, changed, "snapshot");
            continue;
        }
        if (cj.field(step, "exchange")) |pair_raw| {
            const pair = try cj.asArray(pair_raw);
            if (pair.len != 2) return error.ExchangeNeedsTwoReplicas;
            const x = try world.get(try cj.asStr(pair[0]));
            const y = try world.get(try cj.asStr(pair[1]));
            try exchange(allocator, x, y);
            continue;
        }
        const on = if (cj.field(step, "on")) |o| try cj.asStr(o) else "a";
        if (cj.field(step, "op") == null) {
            std.debug.print("textcrdt: step carries no recognised form\n", .{});
            return error.UnrecognizedStep;
        }
        try applyOp(try world.get(on), step);
    }
}

/// The replica `len` and `tombstone_count` are asserted on.
///
/// `text` names `a`; otherwise the first replica of the first `texts_equal`
/// group, which is the converged one the fixture is talking about. This SELECTS
/// A TARGET rather than comparing a value, so it reads the raw block instead of
/// going through the tracker — `text` and `texts_equal` are each asserted on
/// their own below.
fn targetName(expect_raw: Value) ![]const u8 {
    if (cj.field(expect_raw, "text") != null) return "a";
    if (cj.field(expect_raw, "texts_equal")) |groups_raw| {
        const groups = try cj.asArray(groups_raw);
        if (groups.len > 0) {
            const pair = try cj.asArray(groups[0]);
            if (pair.len > 0) return cj.asStr(pair[0]);
        }
    }
    return "a";
}

fn renderText(allocator: std.mem.Allocator, r: *Replica) ![]u8 {
    return r.crdt.text(allocator);
}

/// The expectation checks, bundled so `assertKeyWith*` has one context value.
const Checks = struct {
    allocator: std.mem.Allocator,
    world: *World,
    target: []const u8,

    fn text(self: Checks, want: Value) !void {
        const got = try renderText(self.allocator, try self.world.get("a"));
        defer self.allocator.free(got);
        try testing.expectEqualStrings(try cj.asStr(want), got);
    }

    fn len(self: Checks, want: Value) !void {
        const r = try self.world.get(self.target);
        testing.expectEqual(try cj.asUsize(want), try r.crdt.len()) catch |err| {
            std.debug.print("textcrdt: len on replica {s}\n", .{self.target});
            return err;
        };
    }

    fn textsEqual(self: Checks, want: Value) !void {
        // Convergence is identical text across a NAMED pair, compared against
        // each other. Comparing each against the fixture's own expected string
        // instead would pass on two replicas that both match it while
        // disagreeing about anything `text` elides.
        const groups = try cj.asArray(want);
        if (groups.len == 0) return error.TextsEqualNeedsAGroup;
        for (groups) |group_raw| {
            const group = try cj.asArray(group_raw);
            if (group.len < 2) return error.TextsEqualNeedsTwoReplicas;
            const first = try renderText(self.allocator, try self.world.get(try cj.asStr(group[0])));
            defer self.allocator.free(first);
            for (group[1..]) |n| {
                const other = try renderText(self.allocator, try self.world.get(try cj.asStr(n)));
                defer self.allocator.free(other);
                try testing.expectEqualStrings(first, other);
            }
        }
    }

    fn startsWith(self: Checks, want: Value) !void {
        const got = try renderText(self.allocator, try self.world.get("a"));
        defer self.allocator.free(got);
        const prefix = try cj.asStr(want);
        testing.expect(std.mem.startsWith(u8, got, prefix)) catch |err| {
            std.debug.print("textcrdt: `{s}` should start with `{s}`\n", .{ got, prefix });
            return err;
        };
    }

    fn endsWith(self: Checks, want: Value) !void {
        const got = try renderText(self.allocator, try self.world.get("a"));
        defer self.allocator.free(got);
        const suffix = try cj.asStr(want);
        testing.expect(std.mem.endsWith(u8, got, suffix)) catch |err| {
            std.debug.print("textcrdt: `{s}` should end with `{s}`\n", .{ got, suffix });
            return err;
        };
    }

    fn tombstoneCount(self: Checks, want: Value) !void {
        const r = try self.world.get(self.target);
        try testing.expectEqual(try cj.asUsize(want), r.crdt.tombstoneCount());
    }
};

/// `text_on` — one rendered text per named replica.
fn assertTextOn(allocator: std.mem.Allocator, world: *World, expect: *cj.AssertionKeys, raw: Value) !void {
    // DESCEND rather than sweep. `text_on`'s keys are data (replica names), so
    // the CHILD tracker owns each one: a replica the corpus adds later reaches a
    // comparison instead of being walked past by a loop nothing audits
    // (`#lzsubblockkeyset`).
    var on = try expect.sub("text_on");
    errdefer on.finish() catch {};
    var it = raw.object.iterator();
    while (it.next()) |entry| {
        const got = try renderText(allocator, try world.get(entry.key_ptr.*));
        defer allocator.free(got);
        try on.assertKey(entry.key_ptr.*, got);
    }
    try on.finish();
}

/// `version_vector_on` — `{replica: {peer: counter}}`.
fn assertVersionVectorOn(
    allocator: std.mem.Allocator,
    world: *World,
    expect: *cj.AssertionKeys,
    raw: Value,
) !void {
    var on = try expect.sub("version_vector_on");
    errdefer on.finish() catch {};
    var it = raw.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        var vv = try (try world.get(name)).crdt.versionVector(allocator);
        defer vv.deinit();

        // Descend a second time: the peer ids are the grandchild's keys, so a
        // peer the corpus adds is an unconsumed key rather than a comparison
        // nothing makes.
        var peers = try on.sub(name);
        errdefer peers.finish() catch {};
        const declared = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => return error.VersionVectorNotAnObject,
        };
        var pit = declared.iterator();
        while (pit.next()) |peer_entry| {
            const peer = try std.fmt.parseInt(u64, peer_entry.key_ptr.*, 10);
            const counter = vv.get(peer) orelse {
                std.debug.print(
                    "textcrdt: replica {s} version vector has no entry for peer {d}\n",
                    .{ name, peer },
                );
                return error.VersionVectorMissingPeer;
            };
            try peers.assertKey(peer_entry.key_ptr.*, counter);
        }
        // The other direction. Descent proves every DECLARED peer reached a
        // comparison; only this proves the run did not also carry a peer the
        // fixture omits, which is what an over-counted vector looks like.
        testing.expectEqual(declared.count(), vv.count()) catch |err| {
            std.debug.print("textcrdt: replica {s} version vector peer count\n", .{name});
            return err;
        };
        try peers.finish();
    }
    try on.finish();
}

/// Replay one scenario end to end.
fn replayScenario(allocator: std.mem.Allocator, scenario: Value) !void {
    var world = World{ .allocator = allocator };
    defer world.deinit();

    try seedWorld(allocator, &world, scenario);
    try runSteps(allocator, &world, scenario);

    const expect_raw = try cj.required(scenario, "expect");
    var expect = cj.AssertionKeys.init("textcrdt expect", expect_raw);
    const ctx = Checks{
        .allocator = allocator,
        .world = &world,
        .target = try targetName(expect_raw),
    };
    _ = try expect.assertKeyWithOpt("text", ctx, Checks.text);
    _ = try expect.assertKeyWithOpt("texts_equal", ctx, Checks.textsEqual);
    _ = try expect.assertKeyWithOpt("len", ctx, Checks.len);
    _ = try expect.assertKeyWithOpt("a_starts_with", ctx, Checks.startsWith);
    _ = try expect.assertKeyWithOpt("a_ends_with", ctx, Checks.endsWith);
    _ = try expect.assertKeyWithOpt("tombstone_count", ctx, Checks.tombstoneCount);
    if (expect.has("text_on")) {
        try assertTextOn(allocator, &world, &expect, try cj.required(expect_raw, "text_on"));
    }
    if (expect.has("version_vector_on")) {
        try assertVersionVectorOn(
            allocator,
            &world,
            &expect,
            try cj.required(expect_raw, "version_vector_on"),
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

test "collections: textcrdt_convergence" {
    try replayFixture("textcrdt_convergence.json");
}

test "collections: textcrdt_delta_sync" {
    try replayFixture("textcrdt_delta_sync.json");
}
