//! Cross-adapter consumer simulation conformance testkit.
//!
//! The simulation seam is intentionally narrow: callers expose only stable
//! world identity, monotonic steps, and append-only trace evidence. The
//! testkit does not port or prescribe a scheduler.

const std = @import("std");
const replay = @import("replay.zig");

const Allocator = std.mem.Allocator;

pub const AdapterKind = enum {
    in_memory,
    postgres,
    nats,
    external_process,

    pub fn isReal(self: AdapterKind) bool {
        return self != .in_memory;
    }

    fn isLegacyReal(self: AdapterKind) bool {
        return self == .postgres or self == .nats;
    }
};

pub const ExternalPortKind = enum {
    cli,
    filesystem,
    local_socket,
    editor_replica,
};

pub const PortDeterminism = enum {
    deterministic,
    nondeterministic,
};

pub const Port = struct {
    id: []const u8,
    kind: []const u8,
    determinism: PortDeterminism,
    stubbed: bool = false,
};

pub const ExternalProcessSelection = struct {
    adapter_id: []const u8,
    port: ExternalPortKind,
};

pub const TraceEntry = struct {
    action_id: []const u8,
    kind: []const u8,
};

/// The complete evidence the testkit needs from a deterministic world.
pub const WorldEvidence = struct {
    identity: *const anyopaque,
    steps: u64,
    trace: []const TraceEntry,
};

pub const Action = struct {
    id: []const u8,
    actor_id: []const u8,
    kind: []const u8,
    version: []const u8,
    payload: replay.Value,
    cause_id: []const u8 = "",
};

pub const GeneratedAction = struct {
    command: []const u8,
    action: Action,
};

pub const GeneratedScenario = struct {
    generator_name: []const u8,
    generator_version: []const u8,
    seed_hex: []const u8,
    actions: []const GeneratedAction,
};

pub const Observation = struct {
    id: []const u8,
    value: replay.Value,
};

pub const Adapter = struct {
    id: []const u8,
    kind: AdapterKind,
    production_reducer_id: []const u8 = "",
    protocol_id: []const u8,
    reducer_id: []const u8,
    service_id: []const u8 = "",
    external_port: ?ExternalPortKind = null,
    ports: []const Port,
    context: *anyopaque,
    probe: ?*const fn (*anyopaque) anyerror!void = null,
    simulation_world: ?*const fn (*anyopaque) ?WorldEvidence = null,
    reset: ?*const fn (*anyopaque) anyerror!void,
    apply: ?*const fn (*anyopaque, Action) anyerror!void,
    observe: ?*const fn (*anyopaque, Allocator) anyerror![]const Observation,
    materialized_history: ?*const fn (*anyopaque, Allocator) anyerror![]const Action = null,
};

pub const Spec = struct {
    simulation_adapter_id: []const u8,
    required_real_adapters: []const AdapterKind = &.{},
    required_external_processes: []const ExternalProcessSelection = &.{},
    adapters: []const Adapter,
};

pub const AdapterEvidence = struct {
    adapter_id: []const u8,
    kind: AdapterKind,
    service_id: []const u8,
    external_port: ?ExternalPortKind,
    protocol_id: []const u8,
    reducer_id: []const u8,
    production_reducer_id: []const u8,
};

pub const AdapterDigest = struct {
    adapter_id: []const u8,
    digest: replay.Digest,
};

pub const Checkpoint = struct {
    step: u64,
    action_id: []const u8,
    observation_digests: []const AdapterDigest,
};

pub const RunResult = struct {
    arena: *std.heap.ArenaAllocator,
    scenario_digest: replay.Digest,
    adapter_ids: []const []const u8,
    adapter_evidence: []const AdapterEvidence,
    checkpoints: []const Checkpoint,

    pub fn deinit(self: *RunResult) void {
        const parent = self.arena.child_allocator;
        self.arena.deinit();
        parent.destroy(self.arena);
        self.* = undefined;
    }
};

pub const FailureKind = enum {
    observation_divergence,
    materialized_history_mismatch,
    simulation_world_bypass,
};

/// Structured detail for the most recent typed run failure.
pub const Failure = struct {
    kind: FailureKind,
    step: u64,
    action_id: []const u8,
    adapter_id: []const u8,
    baseline_adapter_id: []const u8 = "",
    observation_id: []const u8 = "",
    expected_prefix_length: usize = 0,
    actual_prefix_length: usize = 0,
};

pub const InitError = Allocator.Error || error{InvalidConsumerSimulationSpec};
pub const RunError = Allocator.Error || replay.EncodeError || error{
    InvalidConsumerSimulationScenario,
    AdapterCallbackFailed,
    ObservationDivergence,
    MaterializedHistoryMismatch,
    SimulationWorldBypass,
};

pub const Testkit = struct {
    allocator: Allocator,
    adapters: []Adapter,
    baseline_index: usize,
    failure: ?Failure = null,

    /// Validate and normalize the topology before any callback is invoked.
    pub fn init(allocator: Allocator, spec: Spec) InitError!Testkit {
        if (!validId(spec.simulation_adapter_id)) return error.InvalidConsumerSimulationSpec;
        if (spec.required_real_adapters.len == 0 and spec.required_external_processes.len == 0)
            return error.InvalidConsumerSimulationSpec;
        if (spec.adapters.len < 2) return error.InvalidConsumerSimulationSpec;

        for (spec.required_real_adapters, 0..) |kind, index| {
            if (!kind.isLegacyReal()) return error.InvalidConsumerSimulationSpec;
            for (spec.required_real_adapters[0..index]) |seen| {
                if (seen == kind) return error.InvalidConsumerSimulationSpec;
            }
        }
        for (spec.required_external_processes, 0..) |selection, index| {
            if (!validId(selection.adapter_id)) return error.InvalidConsumerSimulationSpec;
            for (spec.required_external_processes[0..index]) |seen| {
                if (std.mem.eql(u8, seen.adapter_id, selection.adapter_id))
                    return error.InvalidConsumerSimulationSpec;
            }
        }

        const adapters = try allocator.dupe(Adapter, spec.adapters);
        errdefer allocator.free(adapters);
        std.mem.sort(Adapter, adapters, {}, struct {
            fn lessThan(_: void, left: Adapter, right: Adapter) bool {
                return std.mem.order(u8, left.id, right.id) == .lt;
            }
        }.lessThan);

        var baseline_index: ?usize = null;
        var production_reducer_id: ?[]const u8 = null;
        var protocol_id: ?[]const u8 = null;
        for (adapters, 0..) |adapter, index| {
            try validateAdapter(adapter);
            if (index > 0 and std.mem.eql(u8, adapters[index - 1].id, adapter.id))
                return error.InvalidConsumerSimulationSpec;

            const selected_external = selectedExternal(spec.required_external_processes, adapter.id);
            if (selected_external != null and adapter.kind != .external_process)
                return error.InvalidConsumerSimulationSpec;
            if (adapter.kind.isLegacyReal() and !containsKind(spec.required_real_adapters, adapter.kind))
                return error.InvalidConsumerSimulationSpec;
            if (adapter.kind == .external_process) {
                if (selected_external == null or adapter.external_port != selected_external.?)
                    return error.InvalidConsumerSimulationSpec;
            }

            if (adapter.kind != .external_process) {
                if (production_reducer_id) |want| {
                    if (!std.mem.eql(u8, want, adapter.production_reducer_id))
                        return error.InvalidConsumerSimulationSpec;
                } else production_reducer_id = adapter.production_reducer_id;
            }
            if (protocol_id) |want| {
                if (!std.mem.eql(u8, want, adapter.protocol_id))
                    return error.InvalidConsumerSimulationSpec;
            } else protocol_id = adapter.protocol_id;
            if (!samePortContract(adapters[0].ports, adapter.ports))
                return error.InvalidConsumerSimulationSpec;

            if (std.mem.eql(u8, adapter.id, spec.simulation_adapter_id)) baseline_index = index;
        }
        if (adapters[0].ports.len == 0) return error.InvalidConsumerSimulationSpec;
        for (spec.required_real_adapters) |kind| {
            var found = false;
            for (adapters) |adapter| found = found or adapter.kind == kind;
            if (!found) return error.InvalidConsumerSimulationSpec;
        }
        for (spec.required_external_processes) |selection| {
            var found = false;
            for (adapters) |adapter| found = found or std.mem.eql(u8, adapter.id, selection.adapter_id);
            if (!found) return error.InvalidConsumerSimulationSpec;
        }
        const baseline = baseline_index orelse return error.InvalidConsumerSimulationSpec;
        if (adapters[baseline].kind != .in_memory) return error.InvalidConsumerSimulationSpec;
        return .{ .allocator = allocator, .adapters = adapters, .baseline_index = baseline };
    }

    pub fn deinit(self: *Testkit) void {
        self.allocator.free(self.adapters);
        self.* = undefined;
    }

    pub fn run(self: *Testkit, allocator: Allocator, scenario: GeneratedScenario) RunError!RunResult {
        self.failure = null;
        try validateScenario(scenario);

        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer {
            arena.deinit();
            allocator.destroy(arena);
        }
        const alloc = arena.allocator();
        const scenario_value = try scenarioValue(alloc, scenario);
        const scenario_digest = try replay.canonicalDigest(alloc, scenario_value);

        for (self.adapters) |adapter| {
            if (adapter.kind.isReal()) {
                (adapter.probe orelse unreachable)(adapter.context) catch return error.AdapterCallbackFailed;
            }
            (adapter.reset orelse unreachable)(adapter.context) catch return error.AdapterCallbackFailed;
            if (adapter.kind == .in_memory and
                (adapter.simulation_world orelse unreachable)(adapter.context) == null)
                return error.AdapterCallbackFailed;
            if (adapter.kind.isReal()) try self.validateHistory(alloc, adapter, &.{}, 0, "");
        }

        const checkpoints = try alloc.alloc(Checkpoint, scenario.actions.len);
        for (scenario.actions, 0..) |generated, action_index| {
            const step: u64 = @intCast(action_index + 1);
            const observations = try alloc.alloc([]const Observation, self.adapters.len);
            const digests = try alloc.alloc(AdapterDigest, self.adapters.len);
            for (self.adapters, 0..) |adapter, adapter_index| {
                const before_world = if (adapter.kind == .in_memory)
                    (adapter.simulation_world orelse unreachable)(adapter.context)
                else
                    null;
                const before_steps = if (before_world) |world| world.steps else 0;
                const before_trace = if (before_world) |world| world.trace.len else 0;

                const action = try cloneAction(alloc, generated.action);
                (adapter.apply orelse unreachable)(adapter.context, action) catch return error.AdapterCallbackFailed;

                if (before_world) |before| {
                    const after = (adapter.simulation_world orelse unreachable)(adapter.context);
                    var executed = false;
                    if (after) |world| {
                        if (world.identity == before.identity and world.steps > before_steps and world.trace.len >= before_trace) {
                            for (world.trace[before_trace..]) |entry| {
                                if (std.mem.eql(u8, entry.action_id, generated.action.id) and
                                    std.mem.startsWith(u8, entry.kind, "action_")) executed = true;
                            }
                        }
                    }
                    if (!executed) {
                        self.failure = .{ .kind = .simulation_world_bypass, .step = step, .action_id = generated.action.id, .adapter_id = adapter.id };
                        return error.SimulationWorldBypass;
                    }
                }
                if (adapter.kind.isReal())
                    try self.validateHistory(alloc, adapter, scenario.actions[0 .. action_index + 1], step, generated.action.id);

                const current = (adapter.observe orelse unreachable)(adapter.context, alloc) catch return error.AdapterCallbackFailed;
                if (current.len == 0) return error.AdapterCallbackFailed;
                observations[adapter_index] = try normalizeObservations(alloc, current);
                digests[adapter_index] = .{
                    .adapter_id = adapter.id,
                    .digest = try observationDigest(alloc, observations[adapter_index]),
                };
            }

            const baseline = observations[self.baseline_index];
            const baseline_id = self.adapters[self.baseline_index].id;
            for (self.adapters, 0..) |adapter, adapter_index| {
                if (adapter_index == self.baseline_index) continue;
                if (try firstObservationDifference(alloc, baseline, observations[adapter_index])) |difference| {
                    self.failure = .{
                        .kind = .observation_divergence,
                        .step = step,
                        .action_id = generated.action.id,
                        .adapter_id = adapter.id,
                        .baseline_adapter_id = baseline_id,
                        .observation_id = difference,
                    };
                    return error.ObservationDivergence;
                }
            }
            checkpoints[action_index] = .{
                .step = step,
                .action_id = generated.action.id,
                .observation_digests = digests,
            };
        }

        const adapter_ids = try alloc.alloc([]const u8, self.adapters.len);
        const evidence = try alloc.alloc(AdapterEvidence, self.adapters.len);
        for (self.adapters, 0..) |adapter, index| {
            adapter_ids[index] = adapter.id;
            evidence[index] = .{
                .adapter_id = adapter.id,
                .kind = adapter.kind,
                .service_id = adapter.service_id,
                .external_port = adapter.external_port,
                .protocol_id = adapter.protocol_id,
                .reducer_id = adapter.reducer_id,
                .production_reducer_id = adapter.production_reducer_id,
            };
        }
        return .{
            .arena = arena,
            .scenario_digest = scenario_digest,
            .adapter_ids = adapter_ids,
            .adapter_evidence = evidence,
            .checkpoints = checkpoints,
        };
    }

    fn validateHistory(
        self: *Testkit,
        allocator: Allocator,
        adapter: Adapter,
        expected: []const GeneratedAction,
        step: u64,
        action_id: []const u8,
    ) RunError!void {
        const history = (adapter.materialized_history orelse unreachable)(adapter.context, allocator) catch
            return error.AdapterCallbackFailed;
        if (history.len != expected.len) {
            self.failure = .{
                .kind = .materialized_history_mismatch,
                .step = step,
                .action_id = action_id,
                .adapter_id = adapter.id,
                .expected_prefix_length = expected.len,
                .actual_prefix_length = history.len,
            };
            return error.MaterializedHistoryMismatch;
        }
        for (expected, history) |want, actual| {
            const want_value = try actionValue(allocator, want.action);
            const actual_value = try actionValue(allocator, actual);
            const want_bytes = try replay.canonicalBytes(allocator, want_value);
            const actual_bytes = try replay.canonicalBytes(allocator, actual_value);
            if (!std.mem.eql(u8, want_bytes, actual_bytes)) {
                self.failure = .{
                    .kind = .materialized_history_mismatch,
                    .step = step,
                    .action_id = action_id,
                    .adapter_id = adapter.id,
                    .expected_prefix_length = expected.len,
                    .actual_prefix_length = history.len,
                };
                return error.MaterializedHistoryMismatch;
            }
        }
    }
};

fn validateAdapter(adapter: Adapter) InitError!void {
    if (!validId(adapter.id) or !validId(adapter.protocol_id) or !validId(adapter.reducer_id))
        return error.InvalidConsumerSimulationSpec;
    if (adapter.reset == null or adapter.apply == null or adapter.observe == null)
        return error.InvalidConsumerSimulationSpec;
    switch (adapter.kind) {
        .in_memory => {
            if (!validId(adapter.production_reducer_id) or adapter.service_id.len != 0 or
                adapter.probe != null or adapter.external_port != null or
                adapter.materialized_history != null or adapter.simulation_world == null)
                return error.InvalidConsumerSimulationSpec;
        },
        .postgres, .nats => {
            if (!validId(adapter.production_reducer_id) or
                !std.mem.eql(u8, adapter.reducer_id, adapter.production_reducer_id) or
                adapter.external_port != null)
                return error.InvalidConsumerSimulationSpec;
            try validateRealAdapter(adapter);
        },
        .external_process => {
            try validateRealAdapter(adapter);
            if (adapter.external_port == null or adapter.production_reducer_id.len != 0)
                return error.InvalidConsumerSimulationSpec;
        },
    }
    for (adapter.ports, 0..) |port, index| {
        if (!validId(port.id) or !validId(port.kind)) return error.InvalidConsumerSimulationSpec;
        for (adapter.ports[0..index]) |seen| {
            if (std.mem.eql(u8, seen.id, port.id)) return error.InvalidConsumerSimulationSpec;
        }
        if (port.stubbed and port.determinism != .nondeterministic)
            return error.InvalidConsumerSimulationSpec;
        if (adapter.kind.isReal() and port.stubbed) return error.InvalidConsumerSimulationSpec;
    }
}

fn validateRealAdapter(adapter: Adapter) InitError!void {
    if (!validId(adapter.service_id) or adapter.probe == null or adapter.materialized_history == null or
        adapter.simulation_world != null)
        return error.InvalidConsumerSimulationSpec;
}

fn validateScenario(scenario: GeneratedScenario) RunError!void {
    if (std.mem.trim(u8, scenario.generator_name, " \t\r\n").len == 0 or
        scenario.generator_version.len == 0 or scenario.actions.len == 0 or
        scenario.seed_hex.len != 64)
        return error.InvalidConsumerSimulationScenario;
    for (scenario.seed_hex) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f'))
            return error.InvalidConsumerSimulationScenario;
    }
    for (scenario.actions, 0..) |generated, index| {
        const action = generated.action;
        if (!validId(generated.command) or !validId(action.id) or !validId(action.actor_id) or
            !validId(action.kind) or action.version.len == 0)
            return error.InvalidConsumerSimulationScenario;
        for (scenario.actions[0..index]) |seen| {
            if (std.mem.eql(u8, seen.action.id, action.id))
                return error.InvalidConsumerSimulationScenario;
        }
        if (action.cause_id.len != 0) {
            var found = false;
            for (scenario.actions[0..index]) |seen| found = found or std.mem.eql(u8, seen.action.id, action.cause_id);
            if (!found) return error.InvalidConsumerSimulationScenario;
        }
    }
}

fn normalizeObservations(allocator: Allocator, input: []const Observation) RunError![]const Observation {
    const out = try allocator.dupe(Observation, input);
    std.mem.sort(Observation, out, {}, struct {
        fn lessThan(_: void, left: Observation, right: Observation) bool {
            return std.mem.order(u8, left.id, right.id) == .lt;
        }
    }.lessThan);
    for (out, 0..) |item, index| {
        if (!validId(item.id)) return error.AdapterCallbackFailed;
        if (index > 0 and std.mem.eql(u8, out[index - 1].id, item.id))
            return error.AdapterCallbackFailed;
    }
    return out;
}

fn firstObservationDifference(
    allocator: Allocator,
    baseline: []const Observation,
    actual: []const Observation,
) RunError!?[]const u8 {
    if (baseline.len != actual.len) return "";
    for (baseline, actual) |want, got| {
        if (!std.mem.eql(u8, want.id, got.id)) return want.id;
        const want_bytes = try replay.canonicalBytes(allocator, want.value);
        const got_bytes = try replay.canonicalBytes(allocator, got.value);
        if (!std.mem.eql(u8, want_bytes, got_bytes)) return want.id;
    }
    return null;
}

fn observationDigest(allocator: Allocator, observations: []const Observation) RunError!replay.Digest {
    const entries = try allocator.alloc(replay.MapEntry, observations.len);
    for (observations, 0..) |observation, index| {
        entries[index] = .{ .key = .{ .str = observation.id }, .value = observation.value };
    }
    return replay.canonicalDigest(allocator, .{ .map = entries });
}

fn actionValue(allocator: Allocator, action: Action) Allocator.Error!replay.Value {
    const entries = try allocator.alloc(replay.MapEntry, 6);
    entries[0] = .{ .key = .{ .str = "id" }, .value = .{ .str = action.id } };
    entries[1] = .{ .key = .{ .str = "actor_id" }, .value = .{ .str = action.actor_id } };
    entries[2] = .{ .key = .{ .str = "kind" }, .value = .{ .str = action.kind } };
    entries[3] = .{ .key = .{ .str = "version" }, .value = .{ .str = action.version } };
    entries[4] = .{ .key = .{ .str = "payload" }, .value = action.payload };
    entries[5] = .{ .key = .{ .str = "cause_id" }, .value = .{ .str = action.cause_id } };
    return .{ .map = entries };
}

fn scenarioValue(allocator: Allocator, scenario: GeneratedScenario) Allocator.Error!replay.Value {
    const generated_values = try allocator.alloc(replay.Value, scenario.actions.len);
    for (scenario.actions, 0..) |generated, index| {
        const entries = try allocator.alloc(replay.MapEntry, 2);
        entries[0] = .{ .key = .{ .str = "command" }, .value = .{ .str = generated.command } };
        entries[1] = .{ .key = .{ .str = "action" }, .value = try actionValue(allocator, generated.action) };
        generated_values[index] = .{ .map = entries };
    }
    const entries = try allocator.alloc(replay.MapEntry, 4);
    entries[0] = .{ .key = .{ .str = "generator_name" }, .value = .{ .str = scenario.generator_name } };
    entries[1] = .{ .key = .{ .str = "generator_version" }, .value = .{ .str = scenario.generator_version } };
    entries[2] = .{ .key = .{ .str = "seed_hex" }, .value = .{ .str = scenario.seed_hex } };
    entries[3] = .{ .key = .{ .str = "actions" }, .value = .{ .seq = generated_values } };
    return .{ .map = entries };
}

fn cloneAction(allocator: Allocator, action: Action) Allocator.Error!Action {
    var out = action;
    out.payload = try cloneValue(allocator, action.payload);
    return out;
}

fn cloneValue(allocator: Allocator, value: replay.Value) Allocator.Error!replay.Value {
    return switch (value) {
        .null => .null,
        .bool => |item| .{ .bool = item },
        .int => |item| .{ .int = item },
        .float => |item| .{ .float = item },
        .str => |item| .{ .str = try allocator.dupe(u8, item) },
        .bytes => |item| .{ .bytes = try allocator.dupe(u8, item) },
        .opaque_value => .opaque_value,
        .seq => |items| .{ .seq = try cloneValues(allocator, items) },
        .set => |items| .{ .set = try cloneValues(allocator, items) },
        .map => |items| blk: {
            const entries = try allocator.alloc(replay.MapEntry, items.len);
            for (items, 0..) |entry, index| {
                entries[index] = .{
                    .key = try cloneValue(allocator, entry.key),
                    .value = try cloneValue(allocator, entry.value),
                };
            }
            break :blk .{ .map = entries };
        },
    };
}

fn cloneValues(allocator: Allocator, items: []const replay.Value) Allocator.Error![]const replay.Value {
    const out = try allocator.alloc(replay.Value, items.len);
    for (items, 0..) |item, index| out[index] = try cloneValue(allocator, item);
    return out;
}

fn containsKind(kinds: []const AdapterKind, needle: AdapterKind) bool {
    for (kinds) |kind| if (kind == needle) return true;
    return false;
}

fn selectedExternal(selections: []const ExternalProcessSelection, id: []const u8) ?ExternalPortKind {
    for (selections) |selection| {
        if (std.mem.eql(u8, selection.adapter_id, id)) return selection.port;
    }
    return null;
}

fn samePortContract(left: []const Port, right: []const Port) bool {
    if (left.len != right.len) return false;
    for (left) |want| {
        var found = false;
        for (right) |actual| {
            if (std.mem.eql(u8, want.id, actual.id) and
                std.mem.eql(u8, want.kind, actual.kind) and want.determinism == actual.determinism)
                found = true;
        }
        if (!found) return false;
    }
    return true;
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 128 or id[0] < 'a' or id[0] > 'z') return false;
    for (id[1..]) |byte| {
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and
            byte != '.' and byte != '_' and byte != ':' and byte != '-') return false;
    }
    return true;
}
