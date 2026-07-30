//! Canonical replays for the two `distributed/*.json` fixtures this binding
//! used to assert with INLINE MIRRORS (`#lazilyzigconformance`).
//!
//! `anti_entropy_converge.json` and `crdt_sync_frames.json` were both named in
//! a comment above hand-written tests in `crdt_plane.zig` / `ipc.zig`, and the
//! transcription had already drifted: the mirror for the idempotence scenario
//! used stamps `(10,0,1)`/`(11,0,1)` where the fixture uses `(10,0,1)`/`(12,0,2)`,
//! and the reverse-order mirror dropped the third op — the very op that makes
//! "converges to the SAME winner regardless of order" a non-trivial claim.
//! Neither mirror asserted `applied_count`, and neither replayed the keyed
//! `doc/count` peer-tie-break node at all.
//!
//! - **anti_entropy_converge** — every scenario's ops are decoded straight from
//!   the fixture with `CrdtOp.fromJson`, ingested into a `CrdtPlaneRuntime`, and
//!   checked against `expect.applied_count` and `expect.converged`. Scenarios
//!   flagged `redeliver` re-ingest the identical frame and must apply
//!   `redeliver_applied_count` ops; scenarios flagged `reverse_order_equivalent`
//!   are replayed a second time in reverse into a fresh runtime and must
//!   converge to the same registers.
//! - **crdt_sync_frames** — each frame's `wire` is decoded through
//!   `IpcMessage.decodeJson` (the real wire path, externally-tagged envelope
//!   included), its `assertions` are checked against the decoded value, and the
//!   re-encoded frame is compared structurally to the canonical bytes. The
//!   `frontier_omitted` frame is the frontier-suppression case documented on
//!   `CrdtSync.fromJson`: an omitted frontier decodes as empty and re-encodes
//!   explicitly, so only its `ops` are compared shape-for-shape.

const std = @import("std");
const testing = std.testing;

const cj = @import("conformance_json.zig");
const Value = cj.Value;

const ipc = @import("ipc.zig");
const crdt_plane = @import("crdt_plane.zig");

fn skipAbsent(name: []const u8) void {
    std.debug.print(
        "skipping {s}: {s}/distributed absent - run with the lazily-spec sibling\n",
        .{ name, cj.CONFORMANCE_ROOT },
    );
}

// ---------------------------------------------------------------------------
// anti_entropy_converge.json
// ---------------------------------------------------------------------------

/// Decode a scenario's `ops` array. `CrdtOp.state` borrows its payload bytes,
/// so they are allocated in `arena` and outlive every ingest in the scenario.
fn decodeOps(arena: std.mem.Allocator, ops_json: []const Value) ![]ipc.CrdtOp {
    const out = try arena.alloc(ipc.CrdtOp, ops_json.len);
    for (ops_json, out) |raw, *slot| slot.* = try ipc.CrdtOp.fromJson(arena, raw);
    return out;
}

/// The converged register for `node`, resolved the way the fixture addresses it.
fn convergedState(rt: *const crdt_plane.CrdtPlaneRuntime, node: u64) ?ipc.IpcValue {
    const cell = rt.cells.get(node) orelse return null;
    return cell.state;
}

fn expectConverged(rt: *const crdt_plane.CrdtPlaneRuntime, expected: []const Value, label: []const u8) !void {
    for (expected) |want| {
        const node = try cj.asU64(try cj.required(want, "node"));
        const got = convergedState(rt, node) orelse {
            std.debug.print("{s}: node {d} has no converged state\n", .{ label, node });
            return error.MissingConvergedNode;
        };
        var got_parsed = try cj.encodeToValue(got);
        defer got_parsed.deinit();
        try cj.expectJsonEql(try cj.required(want, "state"), got_parsed.value);

        // The fixture's `key` is the wire-stable node key; a runtime that
        // dropped it would still converge on values while losing addressing.
        if (try cj.optStr(want, "key")) |key| {
            const cell = rt.cells.get(node).?;
            const cell_key = cell.key orelse {
                std.debug.print("{s}: node {d} lost its key `{s}`\n", .{ label, node, key });
                return error.MissingNodeKey;
            };
            try testing.expectEqualStrings(key, cell_key);
        }
    }
}

/// The single conflict resolution this binding's CRDT plane implements. The
/// fixture's `resolution` is asserted against it: a corpus that grew a second
/// model would fail here rather than be replayed against the wrong engine.
const RESOLUTION_IMPLEMENTED = "max_stamp";

/// `assertKeyWith` context for `converged` — the failure message names the
/// scenario, so the check needs both the runtime and the name.
const ConvergeCheck = struct {
    rt: *crdt_plane.CrdtPlaneRuntime,
    name: []const u8,

    fn check(self: ConvergeCheck, want: Value) !void {
        try expectConverged(self.rt, try cj.asArray(want), self.name);
    }
};

test "distributed conformance: anti_entropy_converge.json" {
    const allocator = testing.allocator;
    var parsed = (try cj.load("distributed/anti_entropy_converge.json")) orelse {
        skipAbsent("anti_entropy_converge.json");
        return;
    };
    defer parsed.deinit();

    const scenarios = try cj.asArray(try cj.required(parsed.value, "scenarios"));
    try testing.expect(scenarios.len > 0);

    var ops_replayed: usize = 0;
    for (scenarios) |scenario| {
        const name = try cj.asStr(try cj.required(scenario, "name"));
        var expect = cj.AssertionKeys.init(
            "distributed/anti_entropy_converge.json expect",
            try cj.required(scenario, "expect"),
        );

        // This fixture pins the LWW-at-plane model: the greatest WireStamp
        // wins. A corpus that grew a second resolution would silently be
        // replayed against the wrong engine here.
        try expect.assertKey("resolution", RESOLUTION_IMPLEMENTED);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const ops = try decodeOps(arena.allocator(), try cj.asArray(try cj.required(scenario, "ops")));
        try testing.expect(ops.len > 0);

        var rt = crdt_plane.CrdtPlaneRuntime.init(allocator, 0);
        defer rt.deinit();

        const applied = try rt.ingest(ipc.CrdtSync.init(&.{}, ops), 0);
        try expect.assertKey("applied_count", applied);
        try expect.assertKeyWith(
            "converged",
            ConvergeCheck{ .rt = &rt, .name = name },
            ConvergeCheck.check,
        );
        ops_replayed += ops.len;

        // `redeliver_applied_count` and `order_independent` are only ASSERTED on
        // the scenarios that opt into those runs. On the others there is no run
        // to compare against, so say so rather than reading the key and
        // dropping it (#lzconsumednotasserted).
        if (try cj.boolOr(scenario, "redeliver", false)) {
            const again = try rt.ingest(ipc.CrdtSync.init(&.{}, ops), 0);
            try expect.assertKey("redeliver_applied_count", again);
            // Idempotence is about the state too, not just the counter.
            try expectConverged(&rt, try expect.arrayOr("converged"), name);
        } else {
            try expect.excuseKey(
                "redeliver_applied_count",
                "this scenario does not set `redeliver`, so there is no second ingest to count",
            );
        }

        if (try cj.boolOr(scenario, "reverse_order_equivalent", false)) {
            const reversed = try arena.allocator().alloc(ipc.CrdtOp, ops.len);
            for (ops, 0..) |op, i| reversed[ops.len - 1 - i] = op;

            var rev_rt = crdt_plane.CrdtPlaneRuntime.init(allocator, 0);
            defer rev_rt.deinit();
            const rev_applied = try rev_rt.ingest(ipc.CrdtSync.init(&.{}, reversed), 0);
            try expectConverged(&rev_rt, try expect.arrayOr("converged"), name);
            // OBSERVED order independence, not the fixture's own claim handed
            // back to itself: the reversed replay has to land the same op count
            // and the same converged state.
            try expect.assertKey("order_independent", rev_applied == applied);
        } else {
            try expect.excuseKey(
                "order_independent",
                "this scenario does not set `reverse_order_equivalent`, so no reversed " ++
                    "replay runs to observe independence",
            );
        }
        try expect.finish();
    }
    try testing.expect(ops_replayed > 0);
}

// ---------------------------------------------------------------------------
// crdt_sync_frames.json
// ---------------------------------------------------------------------------

/// Assert one `assertions` entry against the decoded frame. Unknown keys are a
/// hard error: a fixture that grew a claim this binding does not check would
/// otherwise keep reporting green while asserting less than the corpus asks.
fn checkFrameAssertion(sync: ipc.CrdtSync, name: []const u8, want: Value) !void {
    if (std.mem.eql(u8, name, "frontier_len")) {
        return testing.expectEqual(try cj.asUsize(want), sync.frontier.len);
    }
    if (std.mem.eql(u8, name, "op_count")) {
        return testing.expectEqual(try cj.asUsize(want), sync.ops.len);
    }
    if (std.mem.eql(u8, name, "frontier_omitted")) {
        // An omitted frontier decodes as empty — see `CrdtSync.fromJson`.
        try testing.expect(try cj.asBool(want));
        return testing.expectEqual(@as(usize, 0), sync.frontier.len);
    }
    if (std.mem.eql(u8, name, "has_keyed_op") or std.mem.eql(u8, name, "has_keyless_op")) {
        const want_keyed = std.mem.eql(u8, name, "has_keyed_op");
        var found = false;
        for (sync.ops) |op| {
            if ((op.key != null) == want_keyed) found = true;
        }
        try testing.expectEqual(try cj.asBool(want), found);
        return;
    }
    std.debug.print("unhandled crdt_sync_frames assertion `{s}`\n", .{name});
    return error.UnhandledAssertion;
}

test "distributed conformance: crdt_sync_frames.json" {
    const allocator = testing.allocator;
    var parsed = (try cj.load("distributed/crdt_sync_frames.json")) orelse {
        skipAbsent("crdt_sync_frames.json");
        return;
    };
    defer parsed.deinit();

    const frames = try cj.asArray(try cj.required(parsed.value, "frames"));
    try testing.expect(frames.len > 0);

    var assertions_checked: usize = 0;
    for (frames) |frame| {
        const label = try cj.asStr(try cj.required(frame, "label"));
        const wire = try cj.required(frame, "wire");

        // Round-trip through the real wire path, envelope tag included.
        const wire_bytes = try cj.json.Stringify.valueAlloc(allocator, wire, .{});
        defer allocator.free(wire_bytes);
        var decoded = ipc.IpcMessage.decodeJson(allocator, wire_bytes) catch |err| {
            std.debug.print("frame `{s}` failed to decode: {s}\n", .{ label, @errorName(err) });
            return err;
        };
        defer decoded.deinit();
        const sync = switch (decoded.message) {
            .CrdtSync => |s| s,
            else => return error.ExpectedCrdtSyncEnvelope,
        };

        const assertions = try cj.required(frame, "assertions");
        var it = switch (assertions) {
            .object => |o| o.iterator(),
            else => return error.ExpectedObject,
        };
        while (it.next()) |entry| {
            checkFrameAssertion(sync, entry.key_ptr.*, entry.value_ptr.*) catch |err| {
                std.debug.print("frame `{s}` assertion `{s}` failed\n", .{ label, entry.key_ptr.* });
                return err;
            };
            assertions_checked += 1;
        }

        // Re-encode and compare against the canonical bytes.
        var reencoded = try cj.encodeToValue(decoded.message);
        defer reencoded.deinit();
        const got_sync = try cj.required(reencoded.value, "CrdtSync");
        const want_sync = try cj.required(wire, "CrdtSync");

        if (cj.field(want_sync, "frontier")) |want_frontier| {
            try cj.expectJsonEql(want_frontier, try cj.required(got_sync, "frontier"));
        } else {
            // The suppressed-frontier frame re-encodes an explicit empty list.
            try testing.expectEqual(@as(usize, 0), (try cj.asArray(try cj.required(got_sync, "frontier"))).len);
        }
        try cj.expectJsonEql(try cj.required(want_sync, "ops"), try cj.required(got_sync, "ops"));
    }
    try testing.expect(assertions_checked > 0);
}
