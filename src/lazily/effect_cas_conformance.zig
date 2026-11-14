//! The canonical generic effect-CAS corpus (`#lzeffectcas`), replayed against
//! [`EffectCasCore`](effect_cas_core.zig).
//!
//! * The fixture is REQUIRED: a missing file fails, never skips.
//! * Every scenario is booked into the runtime scenario ledger by `replay()`,
//!   every step is executed and counted, and the executed scenario and step
//!   counts must equal what the corpus carries. An unknown `op.type` fails.
//! * Each step's `returns` object and each scenario's `final` key states are
//!   bound to `AssertionKeys` trackers, so an unread, unasserted, or newly
//!   added corpus key fails; the `final` key SET is checked against the keys
//!   the core actually holds, in both directions.
//! * Saved attempts are the identities the core HANDED OUT on `claim`, replayed
//!   verbatim — so exact receipt matching, duplicate detection, and stale
//!   generation fencing are exercised against real attempt identities rather
//!   than ones the runner reconstructed.

const std = @import("std");
const testing = std.testing;
const cj = @import("conformance_json.zig");
const core_mod = @import("effect_cas_core.zig");

const Core = core_mod.EffectCasCore([]const u8, u64, []const u8, []const u8, []const u8);
const AttemptIdentity = core_mod.EffectAttemptIdentity;

const FIXTURE = "egress/effect_cas.json";

const Saved = std.StringHashMap(AttemptIdentity);

fn savedAttempt(saved: *const Saved, op: cj.Value) !AttemptIdentity {
    const label = try cj.asStr(try cj.required(op, "attempt"));
    return saved.get(label) orelse {
        std.debug.print("{s}: attempt label `{s}` was never saved by a successful claim\n", .{ FIXTURE, label });
        return error.UnknownAttemptLabel;
    };
}

/// Execute one op and assert its `returns` object. Returns the attempt a
/// successful claim handed out, for `save`.
fn runStep(
    where: []const u8,
    arena: std.mem.Allocator,
    core: *Core,
    saved: *const Saved,
    op: cj.Value,
    want: cj.Value,
) !?AttemptIdentity {
    var keys = cj.AssertionKeys.init(where, want);
    var handed_out: ?AttemptIdentity = null;
    const op_type = try cj.asStr(try cj.required(op, "type"));
    if (std.mem.eql(u8, op_type, "upsert")) {
        const raw_plan = try cj.asArray(try cj.required(op, "plan"));
        const plan = try arena.alloc([]const u8, raw_plan.len);
        for (raw_plan, plan) |raw, *slot| slot.* = try cj.asStr(raw);
        const desired = try Core.intent(
            try cj.asStr(try cj.required(op, "identity")),
            try cj.asU64(try cj.required(op, "epoch")),
            try cj.asStr(try cj.required(op, "key")),
            try cj.asU64(try cj.required(op, "expected")),
            plan,
        );
        const outcome = (try core.upsertDesired(desired)).outcome;
        try keys.assertKey("upsert", std.meta.activeTag(outcome));
        switch (outcome) {
            .already_applied => |applied| try keys.assertKey("applied_through", applied),
            .stale_epoch => |current| try keys.assertKey("current", current),
            .accepted, .unchanged, .epoch_conflict => {},
        }
    } else if (std.mem.eql(u8, op_type, "claim")) {
        const outcome = core.claim(
            try cj.asStr(try cj.required(op, "key")),
            try cj.asU64(try cj.required(op, "generation")),
            try cj.asU64(try cj.required(op, "now")),
        ).outcome;
        try keys.assertKey("claim", std.meta.activeTag(outcome));
        switch (outcome) {
            .claimed => |attempt| {
                try keys.assertKey("identity", attempt.identity.effect);
                try keys.assertKey("step", attempt.identity.step);
                try keys.assertKey("attempt", attempt.identity.attempt);
                try keys.assertKey("expected", attempt.expected);
                try keys.assertKey("payload", attempt.payload);
                handed_out = attempt.identity;
            },
            .waiting => |retry_at| try keys.assertKey("retry_at", retry_at),
            .stale_generation => |current| try keys.assertKey("current", current),
            .empty, .busy => {},
        }
    } else if (std.mem.eql(u8, op_type, "applied")) {
        const outcome = (try core.recordApplied(
            try cj.asStr(try cj.required(op, "key")),
            try savedAttempt(saved, op),
            try cj.asStr(try cj.required(op, "receipt")),
            try cj.asU64(try cj.required(op, "authority")),
        )).outcome;
        try keys.assertKey("applied", std.meta.activeTag(outcome));
        switch (outcome) {
            .step_applied => |next_step| try keys.assertKey("next_step", next_step),
            .completed => |applied| try keys.assertKey("applied_through", applied),
            .stale_generation => |current| try keys.assertKey("current", current),
            .superseded, .duplicate, .unknown_attempt => {},
        }
    } else if (std.mem.eql(u8, op_type, "superseded") or
        std.mem.eql(u8, op_type, "retryable") or
        std.mem.eql(u8, op_type, "rejected"))
    {
        const key = try cj.asStr(try cj.required(op, "key"));
        const attempt = try savedAttempt(saved, op);
        const outcome = if (std.mem.eql(u8, op_type, "superseded")) blk: {
            // An authority mismatch is a ZERO-mutation outcome at the backend:
            // the fixture pins the backend's authority before and after.
            try testing.expectEqual(
                try cj.asU64(try cj.required(op, "backend_before")),
                try cj.asU64(try cj.required(op, "backend_after")),
            );
            break :blk core.recordSuperseded(key, attempt, try cj.asU64(try cj.required(op, "observed"))).outcome;
        } else if (std.mem.eql(u8, op_type, "retryable"))
            core.recordRetryable(
                key,
                attempt,
                try cj.asStr(try cj.required(op, "error")),
                try cj.asU64(try cj.required(op, "retry_at")),
            ).outcome
        else
            core.recordRejected(key, attempt, try cj.asStr(try cj.required(op, "error"))).outcome;
        try keys.assertKey("failure", std.meta.activeTag(outcome));
        switch (outcome) {
            .retrying => |retry_at| try keys.assertKey("retry_at", retry_at),
            .stale_generation => |current| try keys.assertKey("current", current),
            .superseded, .rejected, .unknown_attempt => {},
        }
    } else if (std.mem.eql(u8, op_type, "reconnect")) {
        const outcome = core.reconnect(try cj.asU64(try cj.required(op, "generation"))).outcome;
        try keys.assertKey("reconnect", std.meta.activeTag(outcome));
        switch (outcome) {
            .advanced => |a| {
                try keys.assertKey("generation", a.generation);
                try keys.assertKey("requeued", a.requeued);
                try keys.assertKey("superseded", a.superseded);
            },
            .unchanged => |g| try keys.assertKey("generation", g),
            .stale_generation => |current| try keys.assertKey("current", current),
        }
    } else {
        std.debug.print("{s}: unknown effect-CAS op `{s}`\n", .{ where, op_type });
        return error.UnknownOperation;
    }
    try keys.finish();
    return handed_out;
}

/// Assert the scenario's `final` key states against the core's projection.
fn expectFinal(where: []const u8, core: *const Core, final: cj.Value) !void {
    const object = switch (final) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };
    // Key SET, the direction the per-key loop below cannot see: a key the core
    // holds and the fixture does not name.
    if (object.count() != core.keyCount()) {
        std.debug.print("{s}: final names {d} keys, the core holds {d}\n", .{ where, object.count(), core.keyCount() });
        return error.TestExpectedEqual;
    }
    var keys = cj.AssertionKeys.init(where, final);
    var it = object.iterator();
    while (it.next()) |kv| {
        const name = kv.key_ptr.*;
        const st = core.state(name) orelse {
            std.debug.print("{s}: final names key `{s}` the core never saw\n", .{ where, name });
            return error.TestExpectedEqual;
        };
        var sub = try keys.sub(name);
        try sub.assertKey("pending_identity", if (st.pending) |p| p.intent.identity else null);
        try sub.assertKey("inflight_identity", if (st.inflight) |f| f.identity.effect else null);
        try sub.assertKey("applied_through", st.applied_through);
        try sub.assertKey("terminal", if (st.terminal) |t| t.kind else null);
        try sub.assertKey("receipt_count", if (st.terminal) |t| t.receipts.items.len else 0);
        try sub.assertKey("retry_at", if (st.retry) |r| r.retry_at else null);
        try sub.finish();
    }
    try keys.finish();
}

test "effect-CAS corpus: EffectCasCore executes every scenario and step" {
    var parsed = (try cj.load(FIXTURE)) orelse {
        std.debug.print("{s} missing (a missing fixture is a FAILURE, never a skip)\n", .{FIXTURE});
        return error.SpecFixtureMissing;
    };
    defer parsed.deinit();
    try testing.expectEqualStrings("EffectCas", try cj.asStr(try cj.required(parsed.value, "kind")));
    try testing.expectEqualStrings("EffectCasCore", try cj.asStr(try cj.required(parsed.value, "model")));

    var scenarios = try cj.scenarios(FIXTURE, parsed.value);
    const carried_scenarios = scenarios.len();
    var carried_steps: usize = 0;
    var executed_scenarios: usize = 0;
    var executed_steps: usize = 0;
    while (scenarios.next()) |handle| {
        const scenario = try handle.replay();
        const id = try handle.id();
        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var core = Core.init(testing.allocator, try cj.asU64(try cj.required(scenario, "generation")));
        defer core.deinit();
        var saved = Saved.init(testing.allocator);
        defer saved.deinit();

        const steps = try cj.asArray(try cj.required(scenario, "steps"));
        if (steps.len == 0) return error.VacuousScenario;
        carried_steps += steps.len;
        for (steps, 0..) |step, index| {
            var where_buf: [192]u8 = undefined;
            const where = std.fmt.bufPrint(&where_buf, "{s} {s} steps[{d}].returns", .{ FIXTURE, id, index }) catch FIXTURE;
            const handed_out = try runStep(where, arena, &core, &saved, try cj.required(step, "op"), try cj.required(step, "returns"));
            if (try cj.optStr(step, "save")) |label| {
                const identity = handed_out orelse {
                    std.debug.print("{s}: `save` on a step whose claim did not succeed\n", .{where});
                    return error.SaveWithoutClaim;
                };
                try saved.put(label, identity);
            }
            executed_steps += 1;
        }
        var final_buf: [192]u8 = undefined;
        const final_where = std.fmt.bufPrint(&final_buf, "{s} {s} final", .{ FIXTURE, id }) catch FIXTURE;
        try expectFinal(final_where, &core, try cj.required(scenario, "final"));
        executed_scenarios += 1;
    }
    try testing.expect(carried_scenarios > 0);
    try testing.expectEqual(carried_scenarios, executed_scenarios);
    try testing.expectEqual(carried_steps, executed_steps);
}
