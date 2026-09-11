//! Canonical lazily-spec v0.38.0 replay across all three Zig flavors.

const std = @import("std");
const testing = std.testing;
const cj = @import("conformance_json.zig");
const Context = @import("context.zig").Context;
const AsyncContext = @import("async_context.zig").AsyncContext;
const projection_mod = @import("latest_durable_projection.zig");
const thread_safe_mod = @import("thread_safe_latest_durable_projection.zig");
const async_mod = @import("async_latest_durable_projection.zig");
const core_mod = @import("latest_durable_projection_core.zig");

const fixture_path = "egress/latest_durable_projection.json";
const Key = []const u8;
const Payload = []const u8;

fn expectRevision(actual: ?core_mod.LatestDurableRevision(Payload), expected: cj.Value) !void {
    if (expected == .null) return testing.expect(actual == null);
    const revision = actual orelse return error.ExpectedRevision;
    try testing.expectEqual(try cj.asU64(try cj.required(expected, "epoch")), revision.epoch);
    try testing.expectEqualStrings(try cj.asStr(try cj.required(expected, "value")), revision.value);
}

fn expectEnvelope(actual: ?core_mod.LatestDurableEnvelope(Key, Payload), expected: cj.Value) !void {
    if (expected == .null) return testing.expect(actual == null);
    const envelope = actual orelse return error.ExpectedEnvelope;
    try testing.expectEqual(try cj.asU64(try cj.required(expected, "generation")), envelope.generation);
    try testing.expectEqualStrings(try cj.asStr(try cj.required(expected, "key")), envelope.key);
    try testing.expectEqual(try cj.asU64(try cj.required(expected, "epoch")), envelope.epoch);
    try testing.expectEqualStrings(try cj.asStr(try cj.required(expected, "value")), envelope.value);
}

fn expectOptionalU64(actual: ?u64, expected: cj.Value) !void {
    if (expected == .null) return testing.expect(actual == null);
    try testing.expectEqual(try cj.asU64(expected), actual orelse return error.ExpectedEpoch);
}

fn expectUpsert(actual: core_mod.LatestDurableUpsert, expected: cj.Value) !void {
    const tag = try cj.asStr(try cj.required(expected, "upsert"));
    switch (actual) {
        .accepted => try testing.expectEqualStrings("accepted", tag),
        .unchanged => try testing.expectEqualStrings("unchanged", tag),
        .already_durable => |durable| {
            try testing.expectEqualStrings("already_durable", tag);
            try testing.expectEqual(try cj.asU64(try cj.required(expected, "durable_through")), durable);
        },
        .stale_epoch => |current| {
            try testing.expectEqualStrings("stale_epoch", tag);
            try testing.expectEqual(try cj.asU64(try cj.required(expected, "current")), current);
        },
        .epoch_conflict => try testing.expectEqualStrings("epoch_conflict", tag),
    }
}

fn expectClaim(actual: core_mod.LatestDurableClaim(Key, Payload), expected: cj.Value) !void {
    const tag = try cj.asStr(try cj.required(expected, "claim"));
    switch (actual) {
        .claimed => |envelope| {
            try testing.expectEqualStrings("claimed", tag);
            try expectEnvelope(envelope, try cj.required(expected, "envelope"));
        },
        .empty => try testing.expectEqualStrings("empty", tag),
        .busy => try testing.expectEqualStrings("busy", tag),
        .stale_generation => |current| {
            try testing.expectEqualStrings("stale_generation", tag);
            try testing.expectEqual(try cj.asU64(try cj.required(expected, "current")), current);
        },
    }
}

fn expectAck(actual: core_mod.LatestDurableAck, expected: cj.Value) !void {
    const tag = try cj.asStr(try cj.required(expected, "ack"));
    switch (actual) {
        .advanced => |durable| {
            try testing.expectEqualStrings("advanced", tag);
            try testing.expectEqual(try cj.asU64(try cj.required(expected, "durable_through")), durable);
        },
        .unchanged => |durable| {
            try testing.expectEqualStrings("unchanged", tag);
            try testing.expectEqual(try cj.asU64(try cj.required(expected, "durable_through")), durable);
        },
        .unknown_epoch => try testing.expectEqualStrings("unknown_epoch", tag),
        .stale_generation => |current| {
            try testing.expectEqualStrings("stale_generation", tag);
            try testing.expectEqual(try cj.asU64(try cj.required(expected, "current")), current);
        },
    }
}

fn expectFailure(actual: core_mod.LatestDurableFailure, expected: cj.Value) !void {
    const tag = try cj.asStr(try cj.required(expected, "failure"));
    switch (actual) {
        .pending => try testing.expectEqualStrings("pending", tag),
        .superseded => try testing.expectEqualStrings("superseded", tag),
        .unknown_epoch => try testing.expectEqualStrings("unknown_epoch", tag),
        .stale_generation => |current| {
            try testing.expectEqualStrings("stale_generation", tag);
            try testing.expectEqual(try cj.asU64(try cj.required(expected, "current")), current);
        },
    }
}

fn expectReconnect(actual: core_mod.LatestDurableReconnect, expected: cj.Value) !void {
    const tag = try cj.asStr(try cj.required(expected, "reconnect"));
    switch (actual) {
        .advanced => |result| {
            try testing.expectEqualStrings("advanced", tag);
            try testing.expectEqual(try cj.asU64(try cj.required(expected, "generation")), result.generation);
            try testing.expectEqual(try cj.asUsize(try cj.required(expected, "requeued")), result.requeued);
            try testing.expectEqual(try cj.asUsize(try cj.required(expected, "superseded")), result.superseded);
        },
        .unchanged => |generation| {
            try testing.expectEqualStrings("unchanged", tag);
            try testing.expectEqual(try cj.asU64(try cj.required(expected, "generation")), generation);
        },
        .stale_generation => |current| {
            try testing.expectEqualStrings("stale_generation", tag);
            try testing.expectEqual(try cj.asU64(try cj.required(expected, "current")), current);
        },
    }
}

/// Compare a step's `expected` block against the projection, THROUGH an
/// `AssertionKeys` tracker (`#lzzigblockwalk`).
///
/// The reads this replaces were real comparisons that bound nothing, so all 22
/// per-step `expected` blocks of `egress/latest_durable_projection.json` sat
/// outside rung 0 — a runner that stopped evaluating them would have reported
/// nothing rather than a gap. `entries` is array-valued, so it carries no
/// key-set obligation and its per-entry sweep stays inside `assertKeyWith`.
fn expectState(where: []const u8, projection: anytype, expected: cj.Value) !void {
    var block = cj.AssertionKeys.init(where, expected);
    try block.assertKey("generation", projection.generation());
    try block.assertKeyWith("entries", projection, struct {
        fn check(p: @TypeOf(projection), want: cj.Value) anyerror!void {
            const entries = try cj.asArray(want);
            try testing.expectEqual(entries.len, p.count());
            for (entries) |expected_entry| {
                const key = try cj.asStr(try cj.required(expected_entry, "key"));
                const state = p.state(key) orelse return error.ExpectedKey;
                try expectRevision(state.desired, try cj.required(expected_entry, "desired"));
                try expectEnvelope(state.inflight, try cj.required(expected_entry, "inflight"));
                try expectOptionalU64(
                    state.durable_through,
                    try cj.required(expected_entry, "durable_through"),
                );
            }
        }
    }.check);
    try block.finish();
}

fn replay(projection: anytype, scenario: cj.Value) !usize {
    var count: usize = 0;
    for (try cj.asArray(try cj.required(scenario, "steps")), 0..) |step, index| {
        var where_buf: [192]u8 = undefined;
        const where = std.fmt.bufPrint(
            &where_buf,
            "{s} #{d}.expected",
            .{ fixture_path, index },
        ) catch fixture_path;
        const op = try cj.required(step, "op");
        const expected_return = try cj.required(step, "returns");
        const key = try cj.optStr(op, "key");
        const kind = try cj.asStr(try cj.required(op, "type"));
        if (std.mem.eql(u8, kind, "upsert_desired")) {
            try expectUpsert(
                try projection.upsert_desired(
                    key orelse return error.MissingKey,
                    try cj.asU64(try cj.required(op, "epoch")),
                    try cj.asStr(try cj.required(op, "value")),
                ),
                expected_return,
            );
        } else if (std.mem.eql(u8, kind, "claim")) {
            try expectClaim(
                try projection.claim(
                    key orelse return error.MissingKey,
                    try cj.asU64(try cj.required(op, "generation")),
                ),
                expected_return,
            );
        } else if (std.mem.eql(u8, kind, "ack_applied")) {
            try expectAck(
                try projection.ack_applied(
                    key orelse return error.MissingKey,
                    try cj.asU64(try cj.required(op, "generation")),
                    try cj.asU64(try cj.required(op, "epoch")),
                ),
                expected_return,
            );
        } else if (std.mem.eql(u8, kind, "fail_retryable")) {
            try expectFailure(
                try projection.fail_retryable(
                    key orelse return error.MissingKey,
                    try cj.asU64(try cj.required(op, "generation")),
                    try cj.asU64(try cj.required(op, "epoch")),
                ),
                expected_return,
            );
        } else if (std.mem.eql(u8, kind, "reconnect")) {
            try expectReconnect(
                try projection.reconnect(try cj.asU64(try cj.required(op, "generation"))),
                expected_return,
            );
        } else return error.UnknownOperation;
        try expectState(where, projection, try cj.required(step, "expected"));
        count += 1;
    }
    return count;
}

test "latest durable canonical fixture replays across reactive thread-safe and async flavors" {
    var parsed = (try cj.load(fixture_path)) orelse return error.SpecFixtureMissing;
    defer parsed.deinit();
    try testing.expectEqualStrings(
        "LatestDurableProjection",
        try cj.asStr(try cj.required(parsed.value, "kind")),
    );
    try testing.expectEqualStrings(
        "LatestDurableProjectionCore",
        try cj.asStr(try cj.required(parsed.value, "model")),
    );

    var scenarios = try cj.scenarios(fixture_path, parsed.value);
    var total_steps: usize = 0;
    while (scenarios.next()) |scenario_handle| {
        const scenario = try scenario_handle.replay();
        const generation = try cj.asU64(try cj.required(scenario, "generation"));

        const sync_context = try Context.init(testing.allocator);
        defer sync_context.deinit();
        var sync_projection = try projection_mod.LatestDurableProjection(Key, Payload).init(sync_context, generation);
        defer sync_projection.deinit();
        const sync_steps = try replay(&sync_projection, scenario);

        var thread_projection = thread_safe_mod.ThreadSafeLatestDurableProjection(Key, Payload).init(testing.allocator, generation);
        defer thread_projection.deinit();
        const thread_steps = try replay(&thread_projection, scenario);

        const AsyncCtx = AsyncContext(u64);
        var async_context = AsyncCtx.init(testing.allocator);
        defer async_context.deinit();
        var async_projection = try async_mod.AsyncLatestDurableProjection(Key, Payload).init(&async_context, generation);
        defer async_projection.deinit();
        const async_steps = try replay(&async_projection, scenario);

        try testing.expect(sync_steps > 0);
        try testing.expectEqual(sync_steps, thread_steps);
        try testing.expectEqual(sync_steps, async_steps);
        total_steps += sync_steps;
    }
    try testing.expect(total_steps > 0);
}
