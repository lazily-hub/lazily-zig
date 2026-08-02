const std = @import("std");
const corpus = @import("conformance_json.zig");
const portable = @import("stdlib.zig");

const Actual = struct {
    outcome: []const u8,
    deadline: ?u64 = null,
    fired_at: ?u64 = null,
    reason: ?[]const u8 = null,
    value: ?[]const u8 = null,
    operation_calls: ?u64 = null,
    cancellation_calls: ?u64 = null,
    revision: ?u64 = null,
    generation: ?u64 = null,
};

fn assertExpected(expected: corpus.Value, actual: Actual) !void {
    const object = switch (expected) {
        .object => |object| object,
        else => return error.ExpectedObject,
    };
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (std.mem.eql(u8, key, "outcome")) {
            try std.testing.expectEqualStrings(try corpus.asStr(value), actual.outcome);
        } else if (std.mem.eql(u8, key, "deadline")) {
            try std.testing.expectEqual(try corpus.asU64(value), actual.deadline.?);
        } else if (std.mem.eql(u8, key, "fired_at")) {
            try std.testing.expectEqual(try corpus.asU64(value), actual.fired_at.?);
        } else if (std.mem.eql(u8, key, "reason")) {
            try std.testing.expectEqualStrings(try corpus.asStr(value), actual.reason.?);
        } else if (std.mem.eql(u8, key, "value")) {
            try std.testing.expectEqualStrings(try corpus.asStr(value), actual.value.?);
        } else if (std.mem.eql(u8, key, "operation_calls")) {
            try std.testing.expectEqual(try corpus.asU64(value), actual.operation_calls.?);
        } else if (std.mem.eql(u8, key, "cancellation_calls")) {
            try std.testing.expectEqual(try corpus.asU64(value), actual.cancellation_calls.?);
        } else if (std.mem.eql(u8, key, "revision")) {
            try std.testing.expectEqual(try corpus.asU64(value), actual.revision.?);
        } else if (std.mem.eql(u8, key, "generation")) {
            try std.testing.expectEqual(try corpus.asU64(value), actual.generation.?);
        } else {
            return error.UnknownExpectation;
        }
    }
}

fn stringField(value: corpus.Value, name: []const u8) ![]const u8 {
    return corpus.asStr(try corpus.required(value, name));
}

fn u64Field(value: corpus.Value, name: []const u8) !u64 {
    return corpus.asU64(try corpus.required(value, name));
}

fn boolField(value: corpus.Value, name: []const u8) !bool {
    return corpus.asBool(try corpus.required(value, name));
}

fn timerError(err: portable.TimerError) []const u8 {
    return switch (err) {
        error.DeadlineOverflow => "deadline_overflow",
        error.ClockRegression => "clock_regression",
    };
}

fn replayTimer(scenario: corpus.Value) !void {
    var timer: ?portable.Timer = null;
    for (try corpus.asArray(try corpus.required(scenario, "steps"))) |step| {
        const op = try stringField(step, "op");
        var actual: Actual = undefined;
        if (std.mem.eql(u8, op, "start")) {
            timer = portable.Timer.start(
                try u64Field(step, "now"),
                try u64Field(step, "duration"),
            ) catch |err| {
                actual = .{ .outcome = "unavailable", .reason = timerError(err) };
                try assertExpected(try corpus.required(step, "expect"), actual);
                continue;
            };
            actual = .{ .outcome = "pending", .deadline = timer.?.deadline };
        } else {
            const observation = timer.?.observe(try u64Field(step, "now")) catch |err| {
                actual = .{
                    .outcome = "unavailable",
                    .deadline = timer.?.deadline,
                    .reason = timerError(err),
                };
                try assertExpected(try corpus.required(step, "expect"), actual);
                continue;
            };
            actual = switch (observation.outcome) {
                .pending => .{ .outcome = "pending", .deadline = observation.deadline },
                .fired => .{ .outcome = "fired", .fired_at = observation.fired_at },
            };
        }
        try assertExpected(try corpus.required(step, "expect"), actual);
    }
}

const OperationContext = struct {
    state: []const u8,
    value: ?[]const u8,
    calls: u64 = 0,

    fn run(raw: *anyopaque) portable.Operation {
        const self: *OperationContext = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (std.mem.eql(u8, self.state, "completed")) {
            return .{ .state = .completed, .value = self.value };
        }
        if (std.mem.eql(u8, self.state, "unavailable")) {
            return .{ .state = .unavailable };
        }
        return .{ .state = .pending };
    }
};

const CancellationContext = struct {
    state: []const u8,
    calls: u64 = 0,

    fn run(raw: *anyopaque) portable.Cancellation {
        const self: *CancellationContext = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (std.mem.eql(u8, self.state, "cancelled")) return .cancelled;
        if (std.mem.eql(u8, self.state, "unavailable")) return .unavailable;
        return .pending;
    }
};

fn operationAdapter(context: *OperationContext) portable.OperationAdapter {
    return .{ .context = context, .run_fn = OperationContext.run };
}

fn cancellationAdapter(context: *CancellationContext) portable.CancellationAdapter {
    return .{ .context = context, .run_fn = CancellationContext.run };
}

const ReentrantCancellationContext = struct {
    barrier: *portable.RevisionBarrier,

    fn run(raw: *anyopaque) portable.Cancellation {
        const self: *ReentrantCancellationContext = @ptrCast(@alignCast(raw));
        _ = self.barrier.dispose();
        return .cancelled;
    }
};

fn timeoutOutcome(outcome: portable.TimeoutOutcome) []const u8 {
    return switch (outcome) {
        .pending => "pending",
        .completed => "completed",
        .timed_out => "timed_out",
        .cancelled => "cancelled",
        .unavailable => "unavailable",
    };
}

fn replayTimeout(scenario: corpus.Value) !void {
    var timeout: ?portable.Timeout = null;
    for (try corpus.asArray(try corpus.required(scenario, "steps"))) |step| {
        const op = try stringField(step, "op");
        var actual: Actual = undefined;
        if (std.mem.eql(u8, op, "start")) {
            timeout = try portable.Timeout.start(
                try u64Field(step, "now"),
                try u64Field(step, "duration"),
            );
            actual = .{ .outcome = "pending", .deadline = timeout.?.deadline };
        } else {
            var operation = OperationContext{
                .state = try stringField(step, "operation"),
                .value = try corpus.optStr(step, "value"),
            };
            var cancellation = CancellationContext{
                .state = try stringField(step, "cancellation"),
            };
            const observation = timeout.?.poll(
                try u64Field(step, "now"),
                operationAdapter(&operation),
                cancellationAdapter(&cancellation),
            );
            actual = .{
                .outcome = timeoutOutcome(observation.outcome),
                .deadline = observation.deadline,
                .value = observation.value,
                .reason = observation.reason,
                .operation_calls = operation.calls,
                .cancellation_calls = cancellation.calls,
            };
        }
        try assertExpected(try corpus.required(step, "expect"), actual);
    }
}

fn barrierOutcome(outcome: portable.BarrierOutcome) []const u8 {
    return switch (outcome) {
        .pending => "pending",
        .satisfied => "satisfied",
        .timed_out => "timed_out",
        .cancelled => "cancelled",
        .disposed => "disposed",
        .unavailable => "unavailable",
    };
}

fn barrierActual(observation: portable.BarrierObservation) Actual {
    return .{
        .outcome = barrierOutcome(observation.outcome),
        .reason = observation.reason,
        .revision = observation.revision,
        .generation = observation.generation,
    };
}

fn replayBarrier(scenario: corpus.Value) !void {
    var barrier: ?portable.RevisionBarrier = null;
    for (try corpus.asArray(try corpus.required(scenario, "steps"))) |step| {
        const op = try stringField(step, "op");
        var observation: portable.BarrierObservation = undefined;
        var cancellation = CancellationContext{ .state = "pending" };
        if (std.mem.eql(u8, op, "start")) {
            const deadline_value = try corpus.required(step, "deadline");
            const deadline: ?u64 = switch (deadline_value) {
                .null => null,
                else => try corpus.asU64(deadline_value),
            };
            barrier = portable.RevisionBarrier.init(
                try u64Field(step, "revision"),
                try u64Field(step, "required_revision"),
                deadline,
            );
            observation = barrier.?.receipt("");
        } else if (std.mem.eql(u8, op, "observe")) {
            cancellation.state = try stringField(step, "cancellation");
            observation = barrier.?.observe(
                try u64Field(step, "now"),
                try boolField(step, "predicate"),
                cancellationAdapter(&cancellation),
            );
        } else if (std.mem.eql(u8, op, "register_recheck")) {
            observation = barrier.?.registerRecheck(
                try u64Field(step, "now"),
                try u64Field(step, "observed_revision"),
                try boolField(step, "predicate"),
            );
        } else if (std.mem.eql(u8, op, "advance")) {
            observation = barrier.?.advance(
                try u64Field(step, "revision"),
                try boolField(step, "predicate"),
            );
        } else if (std.mem.eql(u8, op, "dispose")) {
            observation = barrier.?.dispose();
        } else if (std.mem.eql(u8, op, "receipt")) {
            observation = barrier.?.receipt(try stringField(step, "key"));
        } else return error.UnsupportedBarrierStep;
        var actual = barrierActual(observation);
        if (std.mem.eql(u8, op, "observe")) actual.cancellation_calls = cancellation.calls;
        try assertExpected(try corpus.required(step, "expect"), actual);
    }
}

fn replayFixture(name: []const u8) !void {
    var fixture = (try corpus.load(name)) orelse return error.SkipZigTest;
    defer fixture.deinit();
    const feature = try stringField(fixture.value, "feature");
    const scenarios = try corpus.asArray(try corpus.required(fixture.value, "scenarios"));
    // Per-scenario replay accounting (#lzscenariocoverage). These three
    // fixtures key by `id`, so the ledger records the fixture's own ids.
    var ledger = try corpus.scenarios(name, fixture.value);
    while (ledger.next()) |sc| {
        // Rung 4 books on the PAYLOAD handoff (#lzscenariobodyskip), so a
        // body that stops short of replaying stops being booked.
        const scenario = try sc.replay();
        if (std.mem.eql(u8, feature, "stdlib_timer_v1")) {
            try replayTimer(scenario);
        } else if (std.mem.eql(u8, feature, "stdlib_timeout_v1")) {
            try replayTimeout(scenario);
        } else if (std.mem.eql(u8, feature, "stdlib_revision_barrier_v1")) {
            try replayBarrier(scenario);
        } else return error.UnsupportedFeature;
    }
    for (try corpus.asArray(try corpus.required(fixture.value, "mutations"))) |mutation| {
        const must_fail = try corpus.asArray(try corpus.required(mutation, "must_fail"));
        try std.testing.expect(must_fail.len > 0);
        for (must_fail) |id| {
            const target = try corpus.asStr(id);
            var found = false;
            for (scenarios) |scenario| {
                if (std.mem.eql(u8, target, try stringField(scenario, "id"))) found = true;
            }
            try std.testing.expect(found);
        }
    }
}

test "canonical portable stdlib fixtures" {
    inline for ([_][]const u8{
        "stdlib/timer.json",
        "stdlib/timeout.json",
        "stdlib/revision_barrier.json",
    }) |fixture| try replayFixture(fixture);
}

test "revision barrier preserves a reentrant terminal result" {
    var barrier = portable.RevisionBarrier.init(0, 1, null);
    var cancellation = ReentrantCancellationContext{ .barrier = &barrier };

    const observation = barrier.observe(0, false, .{
        .context = &cancellation,
        .run_fn = ReentrantCancellationContext.run,
    });

    try std.testing.expectEqual(portable.BarrierOutcome.disposed, observation.outcome);
}
