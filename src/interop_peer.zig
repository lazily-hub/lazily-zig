//! The peer protocol and its self-check. The process ENTRY POINT lives in
//! `interop_peer_main.zig` (Zig 0.16+) and `interop_peer_main_0_15.zig` (0.15.x),
//! selected by `build.zig`, because `std.process.Init` and `std.Io` exist only on
//! 0.16+ and this file is the only place in the tree that touches either
//! (#lzinteroppeerci). Splitting the entry point is the same shape `build.zig`
//! already uses for `cell_0_16_test.zig`.
//!
//! The peer had silently stopped compiling on the pinned 0.15.2 toolchain: it
//! ran only from `make check` on a developer's default toolchain, so nothing
//! ever built it for the other two in the matrix. Wiring the gate into CI is
//! what surfaced it.
const std = @import("std");
const lazily = @import("lazily");

const PROTOCOL_VERSION: u64 = 1;
const portable = lazily.stdlib;

const SnapshotCell = struct {
    node: lazily.NodeId,
    key: ?lazily.NodeKey,
    state: lazily.IpcValue,
};

const EmptyObject = struct {};

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
        if (std.mem.eql(u8, self.state, "unavailable")) return .{ .state = .unavailable };
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

pub const Peer = struct {
    arena: std.heap.ArenaAllocator,
    peer_id: ?lazily.PeerId = null,
    runtime: ?lazily.CrdtPlaneRuntime = null,
    timer: ?portable.Timer = null,
    timeout: ?portable.Timeout = null,
    barrier: ?portable.RevisionBarrier = null,
    last_feature: ?[]const u8 = null,
    last_observation: ?[]const u8 = null,

    pub fn init(backing: std.mem.Allocator) Peer {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    pub fn deinit(self: *Peer) void {
        if (self.runtime) |*runtime| runtime.deinit();
        self.arena.deinit();
    }

    pub fn requestAlloc(self: *Peer, line: []const u8) ![]u8 {
        const allocator = self.arena.allocator();
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{
            .allocate = .alloc_always,
        });
        const request = parsed.value;
        const command = try stringField(request, "cmd");
        if (std.mem.eql(u8, command, "hello")) return self.helloAlloc(request);
        if (std.mem.eql(u8, command, "local_set")) return self.localSetAlloc(request);
        if (std.mem.eql(u8, command, "deliver")) return self.deliverAlloc(request);
        if (std.mem.eql(u8, command, "snapshot")) return self.snapshotAlloc();
        if (std.mem.eql(u8, command, "feature_reset")) return self.featureResetAlloc(request);
        if (std.mem.eql(u8, command, "feature_step")) return self.featureStepAlloc(request);
        if (std.mem.eql(u8, command, "feature_observe")) return self.featureObserveAlloc(request);
        if (std.mem.eql(u8, command, "bye")) {
            return stringifyAlloc(allocator, .{ .ok = true });
        }
        if (std.mem.startsWith(u8, command, "link_")) {
            return stringifyAlloc(allocator, .{
                .ok = false,
                .@"error" = "unsupported channel",
                .unsupported = true,
            });
        }
        return self.errorAlloc("unknown command");
    }

    fn helloAlloc(self: *Peer, request: std.json.Value) ![]u8 {
        const version = try u64Field(request, "protocol_version");
        if (version != PROTOCOL_VERSION) return self.errorAlloc("unsupported protocol_version");
        const peer = try u64Field(request, "peer");
        if (self.runtime) |*runtime| runtime.deinit();
        self.peer_id = peer;
        self.runtime = lazily.CrdtPlaneRuntime.init(self.arena.allocator(), peer);
        self.timer = null;
        self.timeout = null;
        self.barrier = null;
        self.last_feature = null;
        self.last_observation = null;
        return stringifyAlloc(self.arena.allocator(), .{
            .ok = true,
            .binding = "lazily-zig",
            .version = "0.33.0",
            .protocol_version = PROTOCOL_VERSION,
            .features = [_][]const u8{
                "distributed_crdt",
                "stdlib_timer_v1",
                "stdlib_timeout_v1",
                "stdlib_revision_barrier_v1",
            },
            // Both MUST-level codecs (`#lzmsgpackseven`). This once advertised
            // `msgpack` with no encoder behind it (`#lzmsgpackparity`) — a peer
            // that negotiated it would have gotten a frame this binding cannot
            // produce — and then carve_outed it, which was the fail-CLOSED form
            // of the same gap. `src/lazily/msgpack.zig` now encodes and decodes
            // the named-field wire, replayed against the canonical fixture in
            // `codec_conformance.zig`, so the advertisement is backed and the
            // carve_out would now UNDERSTATE what this binding speaks.
            .codecs = [_][]const u8{ "json", "msgpack" },
            .channels = [_][]const u8{},
            .channel_variants = EmptyObject{},
            .platform_profile = "portable",
            .carve_outs = [_][]const u8{"transport_links"},
        });
    }

    fn localSetAlloc(self: *Peer, request: std.json.Value) ![]u8 {
        const runtime = &(self.runtime orelse return self.errorAlloc("hello must run first"));
        const node = try u64Field(request, "node");
        const at = try u64Field(request, "at");
        const key_value = try objectField(request, "key");
        const key: ?[]const u8 = switch (key_value) {
            .null => null,
            .string => |value| value,
            else => return self.errorAlloc("local_set requires nullable key"),
        };
        const state = try lazily.IpcValue.fromJson(
            self.arena.allocator(),
            try objectField(request, "state"),
        );
        try runtime.registerKey(node, key);
        const op = (try runtime.localUpdate(node, state, at)) orelse
            return self.errorAlloc("production runtime rejected fresh local op");
        const frontier = try runtime.wireFrontier(self.arena.allocator());
        const ops = try self.arena.allocator().alloc(lazily.CrdtOp, 1);
        ops[0] = op;
        const frame = lazily.IpcMessage{
            .CrdtSync = lazily.CrdtSync.init(frontier, ops),
        };
        return stringifyAlloc(self.arena.allocator(), .{ .ok = true, .frame = frame });
    }

    fn deliverAlloc(self: *Peer, request: std.json.Value) ![]u8 {
        const runtime = &(self.runtime orelse return self.errorAlloc("hello must run first"));
        const message = try lazily.IpcMessage.fromJson(
            self.arena.allocator(),
            try objectField(request, "frame"),
        );
        const sync = switch (message) {
            .CrdtSync => |sync| sync,
            else => return self.errorAlloc("deliver requires CrdtSync"),
        };
        const applied = try runtime.ingest(sync, try u64Field(request, "at"));
        return stringifyAlloc(self.arena.allocator(), .{ .ok = true, .applied = applied });
    }

    fn snapshotAlloc(self: *Peer) ![]u8 {
        const runtime = &(self.runtime orelse return self.errorAlloc("hello must run first"));
        const entries = try runtime.converged(self.arena.allocator());
        const cells = try self.arena.allocator().alloc(SnapshotCell, entries.len);
        for (entries, cells) |entry, *cell| {
            cell.* = .{ .node = entry.node, .key = entry.key, .state = entry.state };
        }
        return stringifyAlloc(self.arena.allocator(), .{ .ok = true, .cells = cells });
    }

    fn featureResetAlloc(self: *Peer, request: std.json.Value) ![]u8 {
        const feature = try stringField(request, "feature");
        if (!supportedFeature(feature)) {
            return stringifyAlloc(self.arena.allocator(), .{
                .ok = false,
                .@"error" = "unsupported feature",
                .unsupported = true,
            });
        }
        if (std.mem.eql(u8, feature, "stdlib_timer_v1")) self.timer = null;
        if (std.mem.eql(u8, feature, "stdlib_timeout_v1")) self.timeout = null;
        if (std.mem.eql(u8, feature, "stdlib_revision_barrier_v1")) self.barrier = null;
        self.last_feature = feature;
        self.last_observation = null;
        return stringifyAlloc(self.arena.allocator(), .{ .ok = true, .feature = feature });
    }

    fn featureStepAlloc(self: *Peer, request: std.json.Value) ![]u8 {
        const feature = try stringField(request, "feature");
        if (!supportedFeature(feature)) return self.errorAlloc("unsupported feature");
        const step = try objectField(request, "step");
        const observation = if (std.mem.eql(u8, feature, "stdlib_timer_v1"))
            try self.timerStepAlloc(step)
        else if (std.mem.eql(u8, feature, "stdlib_timeout_v1"))
            try self.timeoutStepAlloc(step)
        else
            try self.barrierStepAlloc(step);
        self.last_feature = feature;
        self.last_observation = observation;
        return std.fmt.allocPrint(
            self.arena.allocator(),
            "{{\"ok\":true,\"feature\":\"{s}\",\"observation\":{s}}}",
            .{ feature, observation },
        );
    }

    fn featureObserveAlloc(self: *Peer, request: std.json.Value) ![]u8 {
        const feature = try stringField(request, "feature");
        if (self.last_feature == null or
            !std.mem.eql(u8, self.last_feature.?, feature) or
            self.last_observation == null)
        {
            return self.errorAlloc("feature has no observation");
        }
        return std.fmt.allocPrint(
            self.arena.allocator(),
            "{{\"ok\":true,\"feature\":\"{s}\",\"observation\":{s}}}",
            .{ feature, self.last_observation.? },
        );
    }

    fn timerStepAlloc(self: *Peer, step: std.json.Value) ![]u8 {
        const allocator = self.arena.allocator();
        const op = try stringField(step, "op");
        if (std.mem.eql(u8, op, "start")) {
            self.timer = portable.Timer.start(
                try u64Field(step, "now"),
                try u64Field(step, "duration"),
            ) catch |err| {
                return std.fmt.allocPrint(
                    allocator,
                    "{{\"outcome\":\"unavailable\",\"reason\":\"{s}\"}}",
                    .{timerError(err)},
                );
            };
            return std.fmt.allocPrint(
                allocator,
                "{{\"outcome\":\"pending\",\"deadline\":{d}}}",
                .{self.timer.?.deadline},
            );
        }
        if (!std.mem.eql(u8, op, "observe")) return error.UnsupportedTimerStep;
        const observation = self.timer.?.observe(try u64Field(step, "now")) catch |err| {
            return std.fmt.allocPrint(
                allocator,
                "{{\"outcome\":\"unavailable\",\"reason\":\"{s}\",\"deadline\":{d}}}",
                .{ timerError(err), self.timer.?.deadline },
            );
        };
        return switch (observation.outcome) {
            .pending => std.fmt.allocPrint(
                allocator,
                "{{\"outcome\":\"pending\",\"deadline\":{d}}}",
                .{observation.deadline.?},
            ),
            .fired => std.fmt.allocPrint(
                allocator,
                "{{\"outcome\":\"fired\",\"fired_at\":{d}}}",
                .{observation.fired_at.?},
            ),
        };
    }

    fn timeoutStepAlloc(self: *Peer, step: std.json.Value) ![]u8 {
        const allocator = self.arena.allocator();
        const op = try stringField(step, "op");
        if (std.mem.eql(u8, op, "start")) {
            self.timeout = try portable.Timeout.start(
                try u64Field(step, "now"),
                try u64Field(step, "duration"),
            );
            return std.fmt.allocPrint(
                allocator,
                "{{\"outcome\":\"pending\",\"deadline\":{d}}}",
                .{self.timeout.?.deadline},
            );
        }
        if (!std.mem.eql(u8, op, "poll")) return error.UnsupportedTimeoutStep;
        var operation = OperationContext{
            .state = try stringField(step, "operation"),
            .value = try optionalStringField(step, "value"),
        };
        var cancellation = CancellationContext{
            .state = try stringField(step, "cancellation"),
        };
        const observation = self.timeout.?.poll(
            try u64Field(step, "now"),
            operationAdapter(&operation),
            cancellationAdapter(&cancellation),
        );
        return switch (observation.outcome) {
            .pending => std.fmt.allocPrint(
                allocator,
                "{{\"outcome\":\"pending\",\"deadline\":{d},\"operation_calls\":{d},\"cancellation_calls\":{d}}}",
                .{ observation.deadline.?, operation.calls, cancellation.calls },
            ),
            .completed => std.fmt.allocPrint(
                allocator,
                "{{\"outcome\":\"completed\",\"value\":\"{s}\",\"operation_calls\":{d},\"cancellation_calls\":{d}}}",
                .{ observation.value.?, operation.calls, cancellation.calls },
            ),
            .timed_out => std.fmt.allocPrint(
                allocator,
                "{{\"outcome\":\"timed_out\",\"operation_calls\":{d},\"cancellation_calls\":{d}}}",
                .{ operation.calls, cancellation.calls },
            ),
            .cancelled => std.fmt.allocPrint(
                allocator,
                "{{\"outcome\":\"cancelled\",\"operation_calls\":{d},\"cancellation_calls\":{d}}}",
                .{ operation.calls, cancellation.calls },
            ),
            .unavailable => std.fmt.allocPrint(
                allocator,
                "{{\"outcome\":\"unavailable\",\"reason\":\"{s}\",\"operation_calls\":{d},\"cancellation_calls\":{d}}}",
                .{ observation.reason.?, operation.calls, cancellation.calls },
            ),
        };
    }

    fn barrierStepAlloc(self: *Peer, step: std.json.Value) ![]u8 {
        const allocator = self.arena.allocator();
        const op = try stringField(step, "op");
        var observation: portable.BarrierObservation = undefined;
        var cancellation = CancellationContext{ .state = "pending" };
        if (std.mem.eql(u8, op, "start")) {
            self.barrier = portable.RevisionBarrier.init(
                try u64Field(step, "revision"),
                try u64Field(step, "required_revision"),
                try optionalU64Field(step, "deadline"),
            );
            observation = self.barrier.?.receipt("");
        } else if (std.mem.eql(u8, op, "observe")) {
            cancellation.state = try stringField(step, "cancellation");
            observation = self.barrier.?.observe(
                try u64Field(step, "now"),
                try boolField(step, "predicate"),
                cancellationAdapter(&cancellation),
            );
        } else if (std.mem.eql(u8, op, "register_recheck")) {
            observation = self.barrier.?.registerRecheck(
                try u64Field(step, "now"),
                try u64Field(step, "observed_revision"),
                try boolField(step, "predicate"),
            );
        } else if (std.mem.eql(u8, op, "advance")) {
            observation = self.barrier.?.advance(
                try u64Field(step, "revision"),
                try boolField(step, "predicate"),
            );
        } else if (std.mem.eql(u8, op, "dispose")) {
            observation = self.barrier.?.dispose();
        } else if (std.mem.eql(u8, op, "receipt")) {
            observation = self.barrier.?.receipt(try stringField(step, "key"));
        } else return error.UnsupportedBarrierStep;
        if (std.mem.eql(u8, op, "observe")) {
            if (observation.reason) |reason| {
                return std.fmt.allocPrint(
                    allocator,
                    "{{\"outcome\":\"{s}\",\"reason\":\"{s}\",\"revision\":{d},\"generation\":{d},\"cancellation_calls\":{d}}}",
                    .{
                        barrierOutcome(observation.outcome),
                        reason,
                        observation.revision,
                        observation.generation,
                        cancellation.calls,
                    },
                );
            }
            return std.fmt.allocPrint(
                allocator,
                "{{\"outcome\":\"{s}\",\"revision\":{d},\"generation\":{d},\"cancellation_calls\":{d}}}",
                .{
                    barrierOutcome(observation.outcome),
                    observation.revision,
                    observation.generation,
                    cancellation.calls,
                },
            );
        }
        if (observation.reason) |reason| {
            return std.fmt.allocPrint(
                allocator,
                "{{\"outcome\":\"{s}\",\"reason\":\"{s}\",\"revision\":{d},\"generation\":{d}}}",
                .{ barrierOutcome(observation.outcome), reason, observation.revision, observation.generation },
            );
        }
        return std.fmt.allocPrint(
            allocator,
            "{{\"outcome\":\"{s}\",\"revision\":{d},\"generation\":{d}}}",
            .{ barrierOutcome(observation.outcome), observation.revision, observation.generation },
        );
    }

    pub fn errorAlloc(self: *Peer, message: []const u8) ![]u8 {
        return stringifyAlloc(self.arena.allocator(), .{
            .ok = false,
            .@"error" = message,
        });
    }
};

pub fn selfCheck(peer: *Peer) !void {
    const hello = try peer.requestAlloc(
        \\{"cmd":"hello","peer":1,"protocol_version":1}
    );
    if (std.mem.indexOf(u8, hello, "\"ok\":true") == null) return error.SelfCheckHello;
    const local = try peer.requestAlloc(
        \\{"cmd":"local_set","node":7,"key":null,"state":{"Inline":[65]},"at":10}
    );
    if (std.mem.indexOf(u8, local, "\"key\":null") == null) return error.SelfCheckKey;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        peer.arena.allocator(),
        local,
        .{ .allocate = .alloc_always },
    );
    const frame = try objectField(parsed.value, "frame");
    const delivery = try stringifyAlloc(peer.arena.allocator(), .{
        .cmd = "deliver",
        .frame = frame,
        .at = 11,
    });
    const duplicate = try peer.requestAlloc(delivery);
    if (std.mem.indexOf(u8, duplicate, "\"applied\":0") == null)
        return error.SelfCheckIdempotence;

    const feature_cases = [_]struct {
        feature: []const u8,
        step: []const u8,
    }{
        .{
            .feature = "stdlib_timer_v1",
            .step = "{\"op\":\"start\",\"now\":0,\"duration\":0}",
        },
        .{
            .feature = "stdlib_timeout_v1",
            .step = "{\"op\":\"start\",\"now\":0,\"duration\":1}",
        },
        .{
            .feature = "stdlib_revision_barrier_v1",
            .step = "{\"op\":\"start\",\"revision\":1,\"required_revision\":1,\"deadline\":null}",
        },
    };
    for (feature_cases) |case| {
        const reset = try std.fmt.allocPrint(
            peer.arena.allocator(),
            "{{\"cmd\":\"feature_reset\",\"feature\":\"{s}\"}}",
            .{case.feature},
        );
        const reset_response = try peer.requestAlloc(reset);
        if (std.mem.indexOf(u8, reset_response, "\"ok\":true") == null)
            return error.SelfCheckFeatureReset;
        const step_request = try std.fmt.allocPrint(
            peer.arena.allocator(),
            "{{\"cmd\":\"feature_step\",\"feature\":\"{s}\",\"step\":{s}}}",
            .{ case.feature, case.step },
        );
        const step_response = try peer.requestAlloc(step_request);
        if (std.mem.indexOf(u8, step_response, "\"ok\":true") == null)
            return error.SelfCheckFeatureStep;
    }
}

fn supportedFeature(feature: []const u8) bool {
    return std.mem.eql(u8, feature, "stdlib_timer_v1") or
        std.mem.eql(u8, feature, "stdlib_timeout_v1") or
        std.mem.eql(u8, feature, "stdlib_revision_barrier_v1");
}

fn timerError(err: portable.TimerError) []const u8 {
    return switch (err) {
        error.DeadlineOverflow => "deadline_overflow",
        error.ClockRegression => "clock_regression",
    };
}

fn timeoutOutcome(outcome: portable.TimeoutOutcome) []const u8 {
    return switch (outcome) {
        .pending => "pending",
        .completed => "completed",
        .timed_out => "timed_out",
        .cancelled => "cancelled",
        .unavailable => "unavailable",
    };
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

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn objectField(value: std.json.Value, name: []const u8) !std.json.Value {
    return switch (value) {
        .object => |object| object.get(name) orelse error.MissingField,
        else => error.ExpectedObject,
    };
}

fn stringField(value: std.json.Value, name: []const u8) ![]const u8 {
    return switch (try objectField(value, name)) {
        .string => |string| string,
        else => error.ExpectedString,
    };
}

fn u64Field(value: std.json.Value, name: []const u8) !u64 {
    return switch (try objectField(value, name)) {
        .integer => |integer| std.math.cast(u64, integer) orelse error.ExpectedU64,
        .number_string => |string| try std.fmt.parseInt(u64, string, 10),
        .string => |string| try std.fmt.parseInt(u64, string, 10),
        else => error.ExpectedU64,
    };
}

fn boolField(value: std.json.Value, name: []const u8) !bool {
    return switch (try objectField(value, name)) {
        .bool => |boolean| boolean,
        else => error.ExpectedBool,
    };
}

fn optionalStringField(value: std.json.Value, name: []const u8) !?[]const u8 {
    const field = switch (value) {
        .object => |object| object.get(name) orelse return null,
        else => return error.ExpectedObject,
    };
    return switch (field) {
        .null => null,
        .string => |string| string,
        else => error.ExpectedString,
    };
}

fn optionalU64Field(value: std.json.Value, name: []const u8) !?u64 {
    const field = try objectField(value, name);
    return switch (field) {
        .null => null,
        .integer => |integer| std.math.cast(u64, integer) orelse error.ExpectedU64,
        .number_string => |string| try std.fmt.parseInt(u64, string, 10),
        .string => |string| try std.fmt.parseInt(u64, string, 10),
        else => error.ExpectedU64,
    };
}
