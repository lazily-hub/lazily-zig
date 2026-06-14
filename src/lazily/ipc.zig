const std = @import("std");
const builtin = @import("builtin");

pub const NodeId = u64;
pub const PeerId = u64;

pub const protocol_id = "lazily-ipc";
pub const protocol_major_version: u64 = 1;
pub const max_js_safe_integer: u64 = 9_007_199_254_740_991;

pub const Codec = enum {
    json,
    binary,
};

pub const CapabilityHandshake = struct {
    protocol_id: []const u8 = protocol_id,
    protocol_major_version: u64 = protocol_major_version,
    codec: Codec = .json,
    max_frame_size: u64,
    fragmentation_supported: bool = false,
    ordered_reliable: bool = true,
    peer_id: PeerId,
    session_id: []const u8,
    features: []const []const u8 = &.{},

    pub fn isCompatibleWith(self: CapabilityHandshake, other: CapabilityHandshake) bool {
        return std.mem.eql(u8, self.protocol_id, protocol_id) and
            std.mem.eql(u8, other.protocol_id, protocol_id) and
            self.protocol_major_version == other.protocol_major_version and
            self.protocol_major_version == protocol_major_version and
            self.codec == other.codec and
            self.ordered_reliable and
            other.ordered_reliable;
    }
};

pub const ShmBlobRef = struct {
    offset: u64,
    len: u64,
    generation: u64,
    epoch: u64,
    checksum: u64,
};

pub const IpcValue = union(enum) {
    Inline: []const u8,
    SharedBlob: ShmBlobRef,

    pub fn fromInline(payload: []const u8) IpcValue {
        return .{ .Inline = payload };
    }

    pub fn sharedBlob(blob: ShmBlobRef) IpcValue {
        return .{ .SharedBlob = blob };
    }

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !IpcValue {
        const tagged = try singleField(value);
        if (std.mem.eql(u8, tagged.name, "Inline")) {
            return .{ .Inline = try parseByteArray(allocator, tagged.value) };
        }
        if (std.mem.eql(u8, tagged.name, "SharedBlob")) {
            return .{ .SharedBlob = try parseShmBlobRef(tagged.value) };
        }
        return error.UnknownIpcValue;
    }

    pub fn jsonStringify(self: IpcValue, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .Inline => |payload| {
                try jw.objectField("Inline");
                try writeByteArray(payload, jw);
            },
            .SharedBlob => |blob| {
                try jw.objectField("SharedBlob");
                try jw.write(blob);
            },
        }
        try jw.endObject();
    }
};

pub const NodeState = union(enum) {
    Payload: []const u8,
    SharedBlob: ShmBlobRef,
    Opaque: void,

    pub fn fromPayload(bytes: []const u8) NodeState {
        return .{ .Payload = bytes };
    }

    pub fn sharedBlob(blob: ShmBlobRef) NodeState {
        return .{ .SharedBlob = blob };
    }

    pub fn fromOpaque() NodeState {
        return .{ .Opaque = {} };
    }

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !NodeState {
        switch (value) {
            .string => |name| {
                if (std.mem.eql(u8, name, "Opaque")) return .{ .Opaque = {} };
                return error.UnknownNodeState;
            },
            .object => {
                const tagged = try singleField(value);
                if (std.mem.eql(u8, tagged.name, "Payload")) {
                    return .{ .Payload = try parseByteArray(allocator, tagged.value) };
                }
                if (std.mem.eql(u8, tagged.name, "SharedBlob")) {
                    return .{ .SharedBlob = try parseShmBlobRef(tagged.value) };
                }
                return error.UnknownNodeState;
            },
            else => return error.ExpectedNodeState,
        }
    }

    pub fn jsonStringify(self: NodeState, jw: anytype) !void {
        switch (self) {
            .Payload => |payload_bytes| {
                try jw.beginObject();
                try jw.objectField("Payload");
                try writeByteArray(payload_bytes, jw);
                try jw.endObject();
            },
            .SharedBlob => |blob| {
                try jw.beginObject();
                try jw.objectField("SharedBlob");
                try jw.write(blob);
                try jw.endObject();
            },
            .Opaque => try jw.write("Opaque"),
        }
    }
};

pub const NodeSnapshot = struct {
    node: NodeId,
    type_tag: []const u8,
    state: NodeState,

    pub fn fromPayload(node: NodeId, type_tag: []const u8, bytes: []const u8) NodeSnapshot {
        return .{ .node = node, .type_tag = type_tag, .state = NodeState.fromPayload(bytes) };
    }

    pub fn sharedBlob(node: NodeId, type_tag: []const u8, blob: ShmBlobRef) NodeSnapshot {
        return .{ .node = node, .type_tag = type_tag, .state = NodeState.sharedBlob(blob) };
    }

    pub fn fromOpaque(node: NodeId, type_tag: []const u8) NodeSnapshot {
        return .{ .node = node, .type_tag = type_tag, .state = NodeState.fromOpaque() };
    }

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !NodeSnapshot {
        return .{
            .node = try asU64(try field(value, "node")),
            .type_tag = try asString(try field(value, "type_tag")),
            .state = try NodeState.fromJson(allocator, try field(value, "state")),
        };
    }
};

pub const EdgeSnapshot = struct {
    dependent: NodeId,
    dependency: NodeId,

    pub fn init(dependent: NodeId, dependency: NodeId) EdgeSnapshot {
        return .{ .dependent = dependent, .dependency = dependency };
    }

    pub fn fromJson(value: std.json.Value) !EdgeSnapshot {
        return .{
            .dependent = try asU64(try field(value, "dependent")),
            .dependency = try asU64(try field(value, "dependency")),
        };
    }
};

pub const Snapshot = struct {
    epoch: u64,
    nodes: []const NodeSnapshot,
    edges: []const EdgeSnapshot,
    roots: []const NodeId,

    pub fn init(
        epoch: u64,
        nodes: []const NodeSnapshot,
        edges: []const EdgeSnapshot,
        roots: []const NodeId,
    ) Snapshot {
        return .{ .epoch = epoch, .nodes = nodes, .edges = edges, .roots = roots };
    }

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !Snapshot {
        return .{
            .epoch = try asU64(try field(value, "epoch")),
            .nodes = try parseNodeSnapshots(allocator, try field(value, "nodes")),
            .edges = try parseEdgeSnapshots(allocator, try field(value, "edges")),
            .roots = try parseNodeIds(allocator, try field(value, "roots")),
        };
    }
};

pub const DeltaOp = union(enum) {
    CellSet: NodeValueOp,
    SlotValue: NodeValueOp,
    Invalidate: NodeOnlyOp,
    NodeAdd: NodeAddOp,
    NodeRemove: NodeOnlyOp,
    EdgeAdd: EdgeSnapshot,
    EdgeRemove: EdgeSnapshot,

    pub const NodeValueOp = struct {
        node: NodeId,
        payload: IpcValue,
    };

    pub const NodeOnlyOp = struct {
        node: NodeId,
    };

    pub const NodeAddOp = struct {
        node: NodeId,
        type_tag: []const u8,
        state: NodeState,
    };

    pub fn cellSet(node: NodeId, payload: IpcValue) DeltaOp {
        return .{ .CellSet = .{ .node = node, .payload = payload } };
    }

    pub fn slotValue(node: NodeId, payload: IpcValue) DeltaOp {
        return .{ .SlotValue = .{ .node = node, .payload = payload } };
    }

    pub fn invalidate(node: NodeId) DeltaOp {
        return .{ .Invalidate = .{ .node = node } };
    }

    pub fn nodeRemove(node: NodeId) DeltaOp {
        return .{ .NodeRemove = .{ .node = node } };
    }

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !DeltaOp {
        const tagged = try singleField(value);
        if (std.mem.eql(u8, tagged.name, "CellSet")) {
            return .{ .CellSet = try parseNodeValueOp(allocator, tagged.value) };
        }
        if (std.mem.eql(u8, tagged.name, "SlotValue")) {
            return .{ .SlotValue = try parseNodeValueOp(allocator, tagged.value) };
        }
        if (std.mem.eql(u8, tagged.name, "Invalidate")) {
            return .{ .Invalidate = try parseNodeOnlyOp(tagged.value) };
        }
        if (std.mem.eql(u8, tagged.name, "NodeAdd")) {
            return .{ .NodeAdd = .{
                .node = try asU64(try field(tagged.value, "node")),
                .type_tag = try asString(try field(tagged.value, "type_tag")),
                .state = try NodeState.fromJson(allocator, try field(tagged.value, "state")),
            } };
        }
        if (std.mem.eql(u8, tagged.name, "NodeRemove")) {
            return .{ .NodeRemove = try parseNodeOnlyOp(tagged.value) };
        }
        if (std.mem.eql(u8, tagged.name, "EdgeAdd")) {
            return .{ .EdgeAdd = try EdgeSnapshot.fromJson(tagged.value) };
        }
        if (std.mem.eql(u8, tagged.name, "EdgeRemove")) {
            return .{ .EdgeRemove = try EdgeSnapshot.fromJson(tagged.value) };
        }
        return error.UnknownDeltaOp;
    }

    pub fn jsonStringify(self: DeltaOp, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .CellSet => |op| {
                try jw.objectField("CellSet");
                try jw.write(op);
            },
            .SlotValue => |op| {
                try jw.objectField("SlotValue");
                try jw.write(op);
            },
            .Invalidate => |op| {
                try jw.objectField("Invalidate");
                try jw.write(op);
            },
            .NodeAdd => |op| {
                try jw.objectField("NodeAdd");
                try jw.write(op);
            },
            .NodeRemove => |op| {
                try jw.objectField("NodeRemove");
                try jw.write(op);
            },
            .EdgeAdd => |edge| {
                try jw.objectField("EdgeAdd");
                try jw.write(edge);
            },
            .EdgeRemove => |edge| {
                try jw.objectField("EdgeRemove");
                try jw.write(edge);
            },
        }
        try jw.endObject();
    }
};

pub const Delta = struct {
    base_epoch: u64,
    epoch: u64,
    ops: []const DeltaOp,

    pub fn init(base_epoch: u64, epoch: u64, ops: []const DeltaOp) Delta {
        return .{ .base_epoch = base_epoch, .epoch = epoch, .ops = ops };
    }

    pub fn next(base_epoch: u64, ops: []const DeltaOp) !Delta {
        return .{
            .base_epoch = base_epoch,
            .epoch = try std.math.add(u64, base_epoch, 1),
            .ops = ops,
        };
    }

    pub fn isNextAfter(self: Delta, last_epoch: u64) bool {
        return self.base_epoch == last_epoch and
            self.base_epoch != std.math.maxInt(u64) and
            self.epoch == self.base_epoch + 1;
    }

    pub fn applyStatus(self: Delta, last_epoch: u64) DeltaApplyStatus {
        if (self.isNextAfter(last_epoch)) return .apply;
        return .{ .resync_required = .{
            .last_epoch = last_epoch,
            .base_epoch = self.base_epoch,
            .epoch = self.epoch,
        } };
    }

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !Delta {
        return .{
            .base_epoch = try asU64(try field(value, "base_epoch")),
            .epoch = try asU64(try field(value, "epoch")),
            .ops = try parseDeltaOps(allocator, try field(value, "ops")),
        };
    }
};

pub const DeltaApplyStatus = union(enum) {
    apply,
    resync_required: struct {
        last_epoch: u64,
        base_epoch: u64,
        epoch: u64,
    },
};

pub const IpcMessage = union(enum) {
    Snapshot: Snapshot,
    Delta: Delta,

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !IpcMessage {
        const tagged = try singleField(value);
        if (std.mem.eql(u8, tagged.name, "Snapshot")) {
            return .{ .Snapshot = try Snapshot.fromJson(allocator, tagged.value) };
        }
        if (std.mem.eql(u8, tagged.name, "Delta")) {
            return .{ .Delta = try Delta.fromJson(allocator, tagged.value) };
        }
        return error.UnknownIpcMessage;
    }

    pub fn decodeJson(allocator: std.mem.Allocator, bytes: []const u8) !ParsedMessage {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
            .allocate = .alloc_always,
        });
        errdefer parsed.deinit();
        const message = try IpcMessage.fromJson(parsed.arena.allocator(), parsed.value);
        return .{ .parsed = parsed, .message = message };
    }

    pub fn encodeJsonAlloc(self: IpcMessage, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }

    pub fn jsonStringify(self: IpcMessage, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .Snapshot => |snapshot| {
                try jw.objectField("Snapshot");
                try jw.write(snapshot);
            },
            .Delta => |delta| {
                try jw.objectField("Delta");
                try jw.write(delta);
            },
        }
        try jw.endObject();
    }
};

pub const ParsedMessage = struct {
    parsed: std.json.Parsed(std.json.Value),
    message: IpcMessage,

    pub fn deinit(self: *@This()) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

const TaggedValue = struct {
    name: []const u8,
    value: std.json.Value,
};

fn singleField(value: std.json.Value) !TaggedValue {
    switch (value) {
        .object => |object| {
            if (object.count() != 1) return error.ExpectedSingleFieldObject;
            var iter = object.iterator();
            const entry = iter.next() orelse return error.ExpectedSingleFieldObject;
            return .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* };
        },
        else => return error.ExpectedObject,
    }
}

fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    switch (value) {
        .object => |object| return object.get(name) orelse error.MissingField,
        else => return error.ExpectedObject,
    }
}

fn asString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}

fn asU64(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |n| if (n >= 0) @as(u64, @intCast(n)) else error.ExpectedUnsignedInteger,
        .number_string => |s| try std.fmt.parseInt(u64, s, 10),
        else => error.ExpectedUnsignedInteger,
    };
}

fn parseByteArray(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    switch (value) {
        .array => |array| {
            const bytes = try allocator.alloc(u8, array.items.len);
            for (array.items, bytes) |item, *out| {
                const n = try asU64(item);
                if (n > std.math.maxInt(u8)) return error.ByteOutOfRange;
                out.* = @intCast(n);
            }
            return bytes;
        },
        else => return error.ExpectedArray,
    }
}

fn parseNodeIds(allocator: std.mem.Allocator, value: std.json.Value) ![]const NodeId {
    switch (value) {
        .array => |array| {
            const out = try allocator.alloc(NodeId, array.items.len);
            for (array.items, out) |item, *node| node.* = try asU64(item);
            return out;
        },
        else => return error.ExpectedArray,
    }
}

fn parseNodeSnapshots(allocator: std.mem.Allocator, value: std.json.Value) ![]const NodeSnapshot {
    switch (value) {
        .array => |array| {
            const out = try allocator.alloc(NodeSnapshot, array.items.len);
            for (array.items, out) |item, *node| node.* = try NodeSnapshot.fromJson(allocator, item);
            return out;
        },
        else => return error.ExpectedArray,
    }
}

fn parseEdgeSnapshots(allocator: std.mem.Allocator, value: std.json.Value) ![]const EdgeSnapshot {
    switch (value) {
        .array => |array| {
            const out = try allocator.alloc(EdgeSnapshot, array.items.len);
            for (array.items, out) |item, *edge| edge.* = try EdgeSnapshot.fromJson(item);
            return out;
        },
        else => return error.ExpectedArray,
    }
}

fn parseDeltaOps(allocator: std.mem.Allocator, value: std.json.Value) ![]const DeltaOp {
    switch (value) {
        .array => |array| {
            const out = try allocator.alloc(DeltaOp, array.items.len);
            for (array.items, out) |item, *op| op.* = try DeltaOp.fromJson(allocator, item);
            return out;
        },
        else => return error.ExpectedArray,
    }
}

fn parseNodeValueOp(allocator: std.mem.Allocator, value: std.json.Value) !DeltaOp.NodeValueOp {
    return .{
        .node = try asU64(try field(value, "node")),
        .payload = try IpcValue.fromJson(allocator, try field(value, "payload")),
    };
}

fn parseNodeOnlyOp(value: std.json.Value) !DeltaOp.NodeOnlyOp {
    return .{ .node = try asU64(try field(value, "node")) };
}

fn parseShmBlobRef(value: std.json.Value) !ShmBlobRef {
    return .{
        .offset = try asU64(try field(value, "offset")),
        .len = try asU64(try field(value, "len")),
        .generation = try asU64(try field(value, "generation")),
        .epoch = try asU64(try field(value, "epoch")),
        .checksum = try asU64(try field(value, "checksum")),
    };
}

fn writeByteArray(bytes: []const u8, jw: anytype) !void {
    try jw.beginArray();
    for (bytes) |byte| try jw.write(byte);
    try jw.endArray();
}

fn assertFixtureRoundTripFromFile(comptime fixture_name: []const u8) !ParsedMessage {
    const fixture_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "../lazily-spec/conformance/{s}",
        .{fixture_name},
    );
    defer std.testing.allocator.free(fixture_path);

    const fixture = try readFixtureFile(fixture_path);
    defer std.testing.allocator.free(fixture);

    var parsed_fixture = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fixture, .{
        .allocate = .alloc_always,
    });
    defer parsed_fixture.deinit();

    const wire_json = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        try field(parsed_fixture.value, "wire"),
        .{},
    );
    defer std.testing.allocator.free(wire_json);

    var parsed_message = try IpcMessage.decodeJson(std.testing.allocator, wire_json);
    errdefer parsed_message.deinit();

    const encoded = try parsed_message.message.encodeJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, wire_json, encoded);

    return parsed_message;
}

fn readFixtureFile(path: []const u8) ![]u8 {
    if (comptime builtin.zig_version.minor >= 16) {
        return std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            path,
            std.testing.allocator,
            .limited(1024 * 1024),
        );
    }
    return std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024 * 1024);
}

test "lazily/ipc: snapshot_minimal fixture" {
    var parsed = try assertFixtureRoundTripFromFile("snapshot_minimal.json");
    defer parsed.deinit();
    const message = parsed.message;
    const snapshot = message.Snapshot;
    try std.testing.expectEqual(@as(u64, 1), snapshot.epoch);
    try std.testing.expectEqual(@as(usize, 1), snapshot.nodes.len);
    try std.testing.expectEqualSlices(u8, "i32", snapshot.nodes[0].type_tag);
    try std.testing.expectEqual(@as(NodeId, 1), snapshot.roots[0]);
}

test "lazily/ipc: snapshot_multi_node fixture" {
    var parsed = try assertFixtureRoundTripFromFile("snapshot_multi_node.json");
    defer parsed.deinit();
    const message = parsed.message;
    const snapshot = message.Snapshot;
    try std.testing.expectEqual(@as(usize, 3), snapshot.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), snapshot.edges.len);
    try std.testing.expectEqual(@as(NodeId, 3), snapshot.nodes[2].node);
    try std.testing.expect(snapshot.nodes[2].state == .Opaque);
}

test "lazily/ipc: snapshot_shared_blob fixture" {
    var parsed = try assertFixtureRoundTripFromFile("snapshot_shared_blob.json");
    defer parsed.deinit();
    const message = parsed.message;
    const snapshot = message.Snapshot;
    const blob = snapshot.nodes[0].state.SharedBlob;
    try std.testing.expectEqual(@as(u64, 0), blob.offset);
    try std.testing.expectEqual(@as(u64, 16), blob.len);
    try std.testing.expectEqual(@as(u64, 9), blob.epoch);
}

test "lazily/ipc: delta_sequential fixture" {
    var parsed = try assertFixtureRoundTripFromFile("delta_sequential.json");
    defer parsed.deinit();
    const message = parsed.message;
    const delta = message.Delta;
    try std.testing.expect(delta.isNextAfter(40));
    try std.testing.expect(!delta.isNextAfter(39));
    try std.testing.expectEqual(@as(usize, 7), delta.ops.len);
    try std.testing.expect(delta.ops[0] == .CellSet);
    try std.testing.expect(delta.ops[1] == .SlotValue);
    try std.testing.expect(delta.ops[2] == .Invalidate);
    try std.testing.expect(delta.ops[3] == .NodeAdd);
    try std.testing.expect(delta.ops[4] == .NodeRemove);
    try std.testing.expect(delta.ops[5] == .EdgeAdd);
    try std.testing.expect(delta.ops[6] == .EdgeRemove);
}

test "lazily/ipc: delta_non_sequential fixture requires resync after older epoch" {
    var parsed = try assertFixtureRoundTripFromFile("delta_non_sequential.json");
    defer parsed.deinit();
    const message = parsed.message;
    const delta = message.Delta;
    try std.testing.expect(delta.isNextAfter(12));
    try std.testing.expectEqual(
        DeltaApplyStatus{ .resync_required = .{ .last_epoch = 10, .base_epoch = 12, .epoch = 13 } },
        delta.applyStatus(10),
    );
}

test "lazily/ipc: delta_shared_blob fixture" {
    var parsed = try assertFixtureRoundTripFromFile("delta_shared_blob.json");
    defer parsed.deinit();
    const message = parsed.message;
    const delta = message.Delta;
    const payload = delta.ops[0].SlotValue.payload.SharedBlob;
    try std.testing.expectEqual(@as(u64, 40), payload.offset);
    try std.testing.expectEqual(@as(u64, 17), payload.len);
    try std.testing.expectEqual(@as(u64, 9), payload.epoch);
}
