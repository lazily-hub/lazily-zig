//! Canonical `simulation/consumer_testkit.json` replay.

const std = @import("std");
const testing = std.testing;

const cj = @import("conformance_json.zig");
const kit = @import("sim_consumer_testkit.zig");

const Value = cj.Value;
const fixture_path = "simulation/consumer_testkit.json";
const max_actions = 8;

const State = struct {
    value: i64 = 0,
    probes: usize = 0,
    resets: usize = 0,
    applications: usize = 0,
    steps: u64 = 0,
    trace: [max_actions]kit.TraceEntry = undefined,
    trace_len: usize = 0,
    history: [max_actions]kit.Action = undefined,
    history_len: usize = 0,
    bias: i64 = 0,
    memory: bool = false,
    bypass: bool = false,
    empty_history: bool = false,
};

fn stateOf(context: *anyopaque) *State {
    return @ptrCast(@alignCast(context));
}

fn probe(context: *anyopaque) anyerror!void {
    stateOf(context).probes += 1;
}

fn reset(context: *anyopaque) anyerror!void {
    const state = stateOf(context);
    state.value = 0;
    state.resets += 1;
    state.applications = 0;
    state.steps = 0;
    state.trace_len = 0;
    state.history_len = 0;
}

fn apply(context: *anyopaque, action: kit.Action) anyerror!void {
    const state = stateOf(context);
    const delta = switch (action.payload) {
        .int => |value| value,
        else => return error.ExpectedIntegerPayload,
    };
    state.value += delta + state.bias;
    state.applications += 1;
    if (state.memory and !state.bypass) {
        if (state.trace_len == state.trace.len) return error.TraceCapacity;
        state.steps += 1;
        state.trace[state.trace_len] = .{ .action_id = action.id, .kind = "action_accepted" };
        state.trace_len += 1;
    }
    if (!state.memory and !state.empty_history) {
        if (state.history_len == state.history.len) return error.HistoryCapacity;
        state.history[state.history_len] = action;
        state.history_len += 1;
    }
}

fn observe(context: *anyopaque, allocator: std.mem.Allocator) anyerror![]const kit.Observation {
    const out = try allocator.alloc(kit.Observation, 1);
    out[0] = .{ .id = "consumer.value", .value = .{ .int = stateOf(context).value } };
    return out;
}

fn history(context: *anyopaque, allocator: std.mem.Allocator) anyerror![]const kit.Action {
    _ = allocator;
    const state = stateOf(context);
    if (state.empty_history) return &.{};
    return state.history[0..state.history_len];
}

fn world(context: *anyopaque) ?kit.WorldEvidence {
    const state = stateOf(context);
    return .{
        .identity = context,
        .steps = state.steps,
        .trace = state.trace[0..state.trace_len],
    };
}

fn adapterKind(raw: []const u8) !kit.AdapterKind {
    return std.meta.stringToEnum(kit.AdapterKind, raw) orelse error.UnknownAdapterKind;
}

fn externalPort(raw: []const u8) !kit.ExternalPortKind {
    return std.meta.stringToEnum(kit.ExternalPortKind, raw) orelse error.UnknownExternalPort;
}

fn determinism(raw: []const u8) !kit.PortDeterminism {
    return std.meta.stringToEnum(kit.PortDeterminism, raw) orelse error.UnknownPortDeterminism;
}

fn generatedScenario(allocator: std.mem.Allocator, fixture: Value) !kit.GeneratedScenario {
    const raw_actions = try cj.asArray(try cj.required(fixture, "actions"));
    const actions = try allocator.alloc(kit.GeneratedAction, raw_actions.len);
    for (raw_actions, 0..) |raw, index| {
        actions[index] = .{
            .command = "increment",
            .action = .{
                .id = try cj.asStr(try cj.required(raw, "id")),
                .actor_id = try cj.asStr(try cj.required(raw, "actor_id")),
                .kind = try cj.asStr(try cj.required(raw, "kind")),
                .version = try cj.asStr(try cj.required(raw, "version")),
                .payload = .{ .int = try cj.asI64(try cj.required(raw, "payload")) },
                .cause_id = try cj.optStr(raw, "cause_id") orelse "",
            },
        };
    }
    const generator = try cj.required(fixture, "generator");
    return .{
        .generator_name = "consumer.scenario",
        .generator_version = try cj.asStr(try cj.required(generator, "version")),
        .seed_hex = try cj.asStr(try cj.required(fixture, "seed")),
        .actions = actions,
    };
}

const BuiltAdapters = struct {
    adapters: []kit.Adapter,
    states: []State,
};

fn buildPorts(
    allocator: std.mem.Allocator,
    fixture: Value,
    adapter_kind: kit.AdapterKind,
) ![]kit.Port {
    const raw_ports = try cj.asArray(try cj.required(fixture, "ports"));
    const ports = try allocator.alloc(kit.Port, raw_ports.len);
    for (raw_ports, 0..) |raw, index| {
        const port_determinism = determinism(try cj.asStr(try cj.required(raw, "determinism"))) catch |err| return err;
        ports[index] = .{
            .id = try cj.asStr(try cj.required(raw, "id")),
            .kind = try cj.asStr(try cj.required(raw, "kind")),
            .determinism = port_determinism,
            .stubbed = adapter_kind == .in_memory and port_determinism == .nondeterministic,
        };
    }
    return ports;
}

fn buildAdapters(
    allocator: std.mem.Allocator,
    fixture: Value,
    scenario: Value,
) !BuiltAdapters {
    const raw_adapters = try cj.asArray(try cj.required(scenario, "adapters"));
    const adapters = try allocator.alloc(kit.Adapter, raw_adapters.len);
    const states = try allocator.alloc(State, raw_adapters.len);
    for (states) |*state| state.* = .{};
    for (raw_adapters, 0..) |raw, index| {
        const kind = try adapterKind(try cj.asStr(try cj.required(raw, "kind")));
        const history_mode = try cj.asStr(try cj.required(raw, "history_mode"));
        const execution_mode = try cj.asStr(try cj.required(raw, "execution_mode"));
        const clock_stub = try cj.asStr(try cj.required(raw, "clock_stub"));
        if (!std.mem.eql(u8, clock_stub, "none") and !std.mem.eql(u8, clock_stub, "stubbed"))
            return error.UnknownClockStub;
        if (kind != .in_memory and std.mem.eql(u8, clock_stub, "stubbed"))
            return error.RealAdapterStubbedClock;
        if (!std.mem.eql(u8, history_mode, "none") and
            !std.mem.eql(u8, history_mode, "exact") and
            !std.mem.eql(u8, history_mode, "empty")) return error.UnknownHistoryMode;
        if (!std.mem.eql(u8, execution_mode, "sim_world") and
            !std.mem.eql(u8, execution_mode, "real") and
            !std.mem.eql(u8, execution_mode, "bypass")) return error.UnknownExecutionMode;

        states[index].bias = try cj.asI64(try cj.required(raw, "delta_bias"));
        states[index].memory = kind == .in_memory;
        states[index].bypass = std.mem.eql(u8, execution_mode, "bypass");
        states[index].empty_history = std.mem.eql(u8, history_mode, "empty");
        adapters[index] = .{
            .id = try cj.asStr(try cj.required(raw, "id")),
            .kind = kind,
            .production_reducer_id = try cj.asStr(try cj.required(raw, "production_reducer_id")),
            .protocol_id = try cj.asStr(try cj.required(raw, "protocol_id")),
            .reducer_id = try cj.asStr(try cj.required(raw, "reducer_id")),
            .service_id = try cj.asStr(try cj.required(raw, "service_id")),
            .external_port = if (try cj.optStr(raw, "external_port")) |port| try externalPort(port) else null,
            .ports = try buildPorts(allocator, fixture, kind),
            .context = &states[index],
            .probe = if (kind.isReal()) probe else null,
            .simulation_world = if (kind == .in_memory) world else null,
            .reset = reset,
            .apply = apply,
            .observe = observe,
            .materialized_history = if (kind.isReal()) history else null,
        };
    }
    return .{ .adapters = adapters, .states = states };
}

fn requiredKinds(allocator: std.mem.Allocator, scenario: Value) ![]kit.AdapterKind {
    const raw = try cj.asArray(try cj.required(scenario, "required_real_adapters"));
    const kinds = try allocator.alloc(kit.AdapterKind, raw.len);
    for (raw, 0..) |item, index| kinds[index] = try adapterKind(try cj.asStr(item));
    return kinds;
}

fn requiredExternal(allocator: std.mem.Allocator, scenario: Value) ![]kit.ExternalProcessSelection {
    const raw = try cj.asArray(try cj.required(scenario, "required_external_processes"));
    const selections = try allocator.alloc(kit.ExternalProcessSelection, raw.len);
    for (raw, 0..) |item, index| {
        selections[index] = .{
            .adapter_id = try cj.asStr(try cj.required(item, "adapter_id")),
            .port = try externalPort(try cj.asStr(try cj.required(item, "port"))),
        };
    }
    return selections;
}

const StringSliceCheck = struct { actual: []const []const u8 };
fn checkStrings(context: StringSliceCheck, expected: Value) !void {
    const want = try cj.asArray(expected);
    try testing.expectEqual(want.len, context.actual.len);
    for (want, context.actual) |item, actual| try testing.expectEqualStrings(try cj.asStr(item), actual);
}

const CheckpointSteps = struct { actual: []const kit.Checkpoint };
fn checkSteps(context: CheckpointSteps, expected: Value) !void {
    const want = try cj.asArray(expected);
    try testing.expectEqual(want.len, context.actual.len);
    for (want, context.actual) |item, actual| try testing.expectEqual(try cj.asU64(item), actual.step);
}

fn checkActionIds(context: CheckpointSteps, expected: Value) !void {
    const want = try cj.asArray(expected);
    try testing.expectEqual(want.len, context.actual.len);
    for (want, context.actual) |item, actual| try testing.expectEqualStrings(try cj.asStr(item), actual.action_id);
}

const ScenarioValues = struct { actions: []const kit.GeneratedAction };
fn checkValues(context: ScenarioValues, expected: Value) !void {
    const want = try cj.asArray(expected);
    try testing.expectEqual(context.actions.len, want.len);
    var sum: i64 = 0;
    for (context.actions, want) |generated, item| {
        sum += generated.action.payload.int;
        try testing.expectEqual(try cj.asI64(item), sum);
    }
}

test "canonical consumer simulation testkit corpus" {
    var fixture = (try cj.load(fixture_path)) orelse return;
    defer fixture.deinit();
    try testing.expectEqual(@as(i64, 1), try cj.asI64(try cj.required(fixture.value, "schema_version")));
    try testing.expectEqualStrings("ConsumerSimulationTestkit", try cj.asStr(try cj.required(fixture.value, "kind")));

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const generated = try generatedScenario(allocator, fixture.value);

    var scenarios = try cj.scenarios(fixture_path, fixture.value);
    while (scenarios.next()) |handle| {
        const scenario = try handle.replay();
        const built = try buildAdapters(allocator, fixture.value, scenario);
        var testkit = try kit.Testkit.init(testing.allocator, .{
            .simulation_adapter_id = try cj.asStr(try cj.required(scenario, "simulation_adapter_id")),
            .required_real_adapters = try requiredKinds(allocator, scenario),
            .required_external_processes = try requiredExternal(allocator, scenario),
            .adapters = built.adapters,
        });
        defer testkit.deinit();

        var expected = cj.AssertionKeys.init(fixture_path, try cj.required(scenario, "expected"));
        const outcome = try cj.asStr(try expected.required("outcome"));
        if (std.mem.eql(u8, outcome, "success")) {
            var result = try testkit.run(testing.allocator, generated);
            defer result.deinit();
            try expected.assertKey("outcome", "success");
            try expected.assertKeyWith("adapter_ids", StringSliceCheck{ .actual = result.adapter_ids }, checkStrings);
            try expected.assertKeyWith("checkpoint_steps", CheckpointSteps{ .actual = result.checkpoints }, checkSteps);
            try expected.assertKeyWith("checkpoint_values", ScenarioValues{ .actions = generated.actions }, checkValues);
            _ = try expected.assertKeyWithOpt("checkpoint_action_ids", CheckpointSteps{ .actual = result.checkpoints }, checkActionIds);
            if (expected.has("observation_relation")) {
                try expected.assertKey("observation_relation", "all_equal_at_every_checkpoint");
                for (result.checkpoints) |checkpoint| {
                    for (checkpoint.observation_digests[1..]) |digest| {
                        try testing.expectEqualSlices(u8, &checkpoint.observation_digests[0].digest, &digest.digest);
                    }
                }
                try expected.assertKey("materialized_history_relation", "exact_prefix_at_every_checkpoint");
                try expected.assertKey("probe_relation", "every_real_adapter_once");
                for (built.adapters, built.states) |adapter, state| {
                    if (adapter.kind.isReal()) try testing.expectEqual(@as(usize, 1), state.probes);
                }
            }
            if (expected.has("external_adapter_id")) {
                var evidence: ?kit.AdapterEvidence = null;
                for (result.adapter_evidence) |item| {
                    if (item.kind == .external_process) evidence = item;
                }
                const actual = evidence orelse return error.MissingExternalEvidence;
                try expected.assertKey("external_adapter_id", actual.adapter_id);
                try expected.assertKey("external_port", actual.external_port.?);
                try expected.assertKey("external_protocol_id", actual.protocol_id);
                try expected.assertKey("external_reducer_id", actual.reducer_id);
                try expected.assertKey("external_production_reducer_id", actual.production_reducer_id);
            }
        } else if (std.mem.eql(u8, outcome, "observation_divergence")) {
            try testing.expectError(error.ObservationDivergence, testkit.run(testing.allocator, generated));
            const failure = testkit.failure.?;
            try expected.assertKey("outcome", @tagName(failure.kind));
            try expected.assertKey("step", failure.step);
            try expected.assertKey("action_id", failure.action_id);
            try expected.assertKey("adapter_id", failure.adapter_id);
            try expected.assertKey("observation_id", failure.observation_id);
        } else if (std.mem.eql(u8, outcome, "materialized_history_mismatch")) {
            try testing.expectError(error.MaterializedHistoryMismatch, testkit.run(testing.allocator, generated));
            const failure = testkit.failure.?;
            try expected.assertKey("outcome", @tagName(failure.kind));
            try expected.assertKey("step", failure.step);
            try expected.assertKey("action_id", failure.action_id);
            try expected.assertKey("adapter_id", failure.adapter_id);
            try expected.assertKey("expected_prefix_length", failure.expected_prefix_length);
            try expected.assertKey("actual_prefix_length", failure.actual_prefix_length);
        } else if (std.mem.eql(u8, outcome, "simulation_world_bypass")) {
            try testing.expectError(error.SimulationWorldBypass, testkit.run(testing.allocator, generated));
            const failure = testkit.failure.?;
            try expected.assertKey("outcome", @tagName(failure.kind));
            try expected.assertKey("step", failure.step);
            try expected.assertKey("action_id", failure.action_id);
            try expected.assertKey("adapter_id", failure.adapter_id);
        } else return error.UnknownConsumerSimulationOutcome;
        try expected.finish();
    }
}

fn minimalAdapter(id: []const u8, kind: kit.AdapterKind, state: *State, ports: []const kit.Port) kit.Adapter {
    state.memory = kind == .in_memory;
    return .{
        .id = id,
        .kind = kind,
        .production_reducer_id = "counter.reducer.v1",
        .protocol_id = "counter.protocol.v1",
        .reducer_id = "counter.reducer.v1",
        .service_id = if (kind.isReal()) "postgres.integration.service" else "",
        .ports = ports,
        .context = state,
        .probe = if (kind.isReal()) probe else null,
        .simulation_world = if (kind == .in_memory) world else null,
        .reset = reset,
        .apply = apply,
        .observe = observe,
        .materialized_history = if (kind.isReal()) history else null,
    };
}

test "consumer simulation rejects construction and run before callbacks" {
    var memory_state = State{};
    var postgres_state = State{};
    const bad_ports = [_]kit.Port{.{
        .id = "state.store",
        .kind = "storage",
        .determinism = .deterministic,
        .stubbed = true,
    }};
    const real_ports = [_]kit.Port{.{
        .id = "state.store",
        .kind = "storage",
        .determinism = .deterministic,
    }};
    const bad_adapters = [_]kit.Adapter{
        minimalAdapter("memory", .in_memory, &memory_state, &bad_ports),
        minimalAdapter("postgres.integration", .postgres, &postgres_state, &real_ports),
    };
    try testing.expectError(error.InvalidConsumerSimulationSpec, kit.Testkit.init(testing.allocator, .{
        .simulation_adapter_id = "memory",
        .required_real_adapters = &.{.postgres},
        .adapters = &bad_adapters,
    }));
    try testing.expectEqual(@as(usize, 0), memory_state.resets + postgres_state.resets + postgres_state.probes);

    memory_state = .{};
    postgres_state = .{};
    const good_adapters = [_]kit.Adapter{
        minimalAdapter("memory", .in_memory, &memory_state, &real_ports),
        minimalAdapter("postgres.integration", .postgres, &postgres_state, &real_ports),
    };
    var testkit = try kit.Testkit.init(testing.allocator, .{
        .simulation_adapter_id = "memory",
        .required_real_adapters = &.{.postgres},
        .adapters = &good_adapters,
    });
    defer testkit.deinit();
    const actions = [_]kit.GeneratedAction{.{
        .command = "increment",
        .action = .{
            .id = "increment.0",
            .actor_id = "consumer",
            .kind = "counter.increment",
            .version = "1",
            .payload = .{ .int = 1 },
        },
    }};
    try testing.expectError(error.InvalidConsumerSimulationScenario, testkit.run(testing.allocator, .{
        .generator_name = "consumer.scenario",
        .generator_version = "1",
        .seed_hex = "not-a-seed",
        .actions = &actions,
    }));
    try testing.expectEqual(@as(usize, 0), memory_state.resets + postgres_state.resets + postgres_state.probes);
}
