const std = @import("std");
const ipc = @import("ipc.zig");

/// A read-only projection of a remote lazily-spec graph. The binary owns the
/// authoritative reactive graph; the mirror applies lazily-spec `Snapshot` /
/// `Delta` messages so consumers read tracked slot payloads instead of
/// re-rendering full JSON on every event.
///
/// The mirror converges identically to a full re-render because the projection
/// is a pure fold of deduped events (the IPC consistency invariants:
/// PartialEq cell guard, memo equality suppression, coalesced frontier).
///
/// Mirrors lazily-kt `StateGraphMirror`. The wire shapes (`Snapshot`, `Delta`,
/// `DeltaOp`) are the existing `lazily/ipc.zig` types.
pub const StateGraphMirror = struct {
    allocator: std.mem.Allocator,
    /// Slot id -> node image (insertion-stable via parallel id list).
    nodes: std.AutoHashMap(ipc.NodeId, Node),
    /// Insertion order of node ids (deterministic iteration for UI rendering).
    node_order: std.ArrayList(ipc.NodeId),
    /// Edge multiset.
    edges: std.AutoHashMap(Edge, void),
    edge_order: std.ArrayList(Edge),
    /// Monotonic frontier — the highest lazily-spec epoch applied so far.
    epoch: u64 = 0,
    declared_hash: ?[]const u8 = null,

    pub const Node = struct {
        node_id: ipc.NodeId,
        type_tag: []const u8,
        /// Raw payload bytes (Inline or SharedBlob). Kept as-is; the mirror
        /// does NOT eagerly decode. `null` when the node is `Opaque`.
        payload: ?[]const u8 = null,
        is_shared_blob: bool = false,
    };

    pub const Edge = struct {
        dependent: ipc.NodeId,
        dependency: ipc.NodeId,

        pub fn eql(a: Edge, b: Edge) bool {
            return a.dependent == b.dependent and a.dependency == b.dependency;
        }
    };

    pub fn init(allocator: std.mem.Allocator) StateGraphMirror {
        return .{
            .allocator = allocator,
            .nodes = std.AutoHashMap(ipc.NodeId, Node).init(allocator),
            .node_order = .empty,
            .edges = std.AutoHashMap(Edge, void).init(allocator),
            .edge_order = .empty,
        };
    }

    pub fn deinit(self: *StateGraphMirror) void {
        self.nodes.deinit();
        self.node_order.deinit(self.allocator);
        self.edges.deinit();
        self.edge_order.deinit(self.allocator);
    }

    pub fn nodeCount(self: *const StateGraphMirror) usize {
        return self.nodes.count();
    }

    pub fn edgeCount(self: *const StateGraphMirror) usize {
        return self.edges.count();
    }

    pub fn isInitialized(self: *const StateGraphMirror) bool {
        return self.epoch > 0;
    }

    /// Apply a cold-read snapshot, replacing the whole graph image.
    pub fn applySnapshot(self: *StateGraphMirror, snapshot: ipc.Snapshot) !void {
        self.nodes.clearRetainingCapacity();
        self.node_order.clearRetainingCapacity();
        self.edges.clearRetainingCapacity();
        self.edge_order.clearRetainingCapacity();

        for (snapshot.nodes) |ns| {
            const img = nodeImage(ns);
            if (!self.nodes.contains(ns.node)) {
                try self.node_order.append(self.allocator, ns.node);
            }
            try self.nodes.put(ns.node, img);
        }
        for (snapshot.edges) |es| {
            const edge = Edge{ .dependent = es.dependent, .dependency = es.dependency };
            if (!self.edges.contains(edge)) {
                try self.edge_order.append(self.allocator, edge);
            }
            try self.edges.put(edge, {});
        }
        self.epoch = snapshot.epoch;
    }

    /// Apply a warm delta. Ops applied verbatim in emission order; frontier
    /// advances to `delta.epoch`. `Invalidate` is a no-op on the mirror — the
    /// derived recompute is consumer-side; the mirror keeps the stale payload
    /// until a fresh `CellSet`/`SlotValue` arrives.
    pub fn applyDelta(self: *StateGraphMirror, delta: ipc.Delta) !void {
        for (delta.ops) |op| {
            switch (op) {
                .NodeAdd => |na| {
                    const img = Node{
                        .node_id = na.node,
                        .type_tag = na.type_tag,
                        .payload = switch (na.state) {
                            .Payload => |p| p,
                            .SharedBlob => null,
                            .Opaque => null,
                        },
                        .is_shared_blob = na.state == .SharedBlob,
                    };
                    if (!self.nodes.contains(na.node)) {
                        try self.node_order.append(self.allocator, na.node);
                    }
                    try self.nodes.put(na.node, img);
                },
                .CellSet => |cs| {
                    if (self.nodes.getPtr(cs.node)) |n| {
                        n.payload = switch (cs.payload) {
                            .Inline => |p| p,
                            .SharedBlob => null,
                        };
                        n.is_shared_blob = cs.payload == .SharedBlob;
                    }
                },
                .SlotValue => |sv| {
                    if (self.nodes.getPtr(sv.node)) |n| {
                        n.payload = switch (sv.payload) {
                            .Inline => |p| p,
                            .SharedBlob => null,
                        };
                        n.is_shared_blob = sv.payload == .SharedBlob;
                    }
                },
                .Invalidate => {},
                .NodeRemove => |nr| {
                    if (self.nodes.remove(nr.node)) {
                        for (self.node_order.items, 0..) |id, i| {
                            if (id == nr.node) {
                                _ = self.node_order.orderedRemove(i);
                                break;
                            }
                        }
                    }
                },
                .EdgeAdd => |ea| {
                    const edge = Edge{ .dependent = ea.dependent, .dependency = ea.dependency };
                    if (!self.edges.contains(edge)) {
                        try self.edge_order.append(self.allocator, edge);
                    }
                    try self.edges.put(edge, {});
                },
                .EdgeRemove => |er| {
                    const edge = Edge{ .dependent = er.dependent, .dependency = er.dependency };
                    if (self.edges.remove(edge)) {
                        for (self.edge_order.items, 0..) |e, i| {
                            if (e.eql(edge)) {
                                _ = self.edge_order.orderedRemove(i);
                                break;
                            }
                        }
                    }
                },
            }
        }
        if (delta.epoch > self.epoch) self.epoch = delta.epoch;
    }

    /// Apply either message kind.
    pub fn apply(self: *StateGraphMirror, message: ipc.IpcMessage) !void {
        switch (message) {
            .Snapshot => |s| try self.applySnapshot(s),
            .Delta => |d| try self.applyDelta(d),
            .CrdtSync => {}, // CRDT plane is a separate feature surface
            // Reliable-sync control frames are handled by the sender driver.
            .ResyncRequest, .OutboxAck => {},
        }
    }

    /// Snapshot payload bytes for the node (Inline only). null otherwise.
    pub fn payloadOf(self: *const StateGraphMirror, node_id: ipc.NodeId) ?[]const u8 {
        const n = self.nodes.get(node_id) orelse return null;
        if (n.is_shared_blob) return null;
        return n.payload;
    }

    /// All node ids carrying the given type tag.
    pub fn nodesOfType(self: *const StateGraphMirror, allocator: std.mem.Allocator, type_tag: []const u8) ![]ipc.NodeId {
        var out = std.ArrayList(ipc.NodeId).empty;
        errdefer out.deinit(allocator);
        for (self.node_order.items) |id| {
            const n = self.nodes.get(id).?;
            if (std.mem.eql(u8, n.type_tag, type_tag)) {
                try out.append(allocator, id);
            }
        }
        return out.toOwnedSlice(allocator);
    }
};

fn nodeImage(ns: ipc.NodeSnapshot) StateGraphMirror.Node {
    return .{
        .node_id = ns.node,
        .type_tag = ns.type_tag,
        .payload = switch (ns.state) {
            .Payload => |p| p,
            .SharedBlob => null,
            .Opaque => null,
        },
        .is_shared_blob = ns.state == .SharedBlob,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "lazily/state_mirror: snapshot + delta round-trip" {
    const allocator = std.testing.allocator;
    var mirror = StateGraphMirror.init(allocator);
    defer mirror.deinit();

    const snapshot = ipc.Snapshot.init(
        3,
        &.{
            .{ .node = 101, .type_tag = "doc.baseline", .state = ipc.NodeState.fromOpaque() },
            .{ .node = 102, .type_tag = "doc.cycle", .state = ipc.NodeState.fromPayload(&.{1, 2, 3}) },
        },
        &.{.{ .dependent = 102, .dependency = 101 }},
        &.{101},
    );
    try mirror.applySnapshot(snapshot);
    try std.testing.expectEqual(@as(u64, 3), mirror.epoch);
    try std.testing.expectEqual(@as(usize, 2), mirror.nodeCount());
    try std.testing.expectEqual(@as(usize, 1), mirror.edgeCount());

    const delta = ipc.Delta.init(3, 6, &.{
        .{ .CellSet = .{ .node = 102, .payload = ipc.IpcValue.fromInline(&.{9, 9}) } },
        .{ .NodeAdd = .{ .node = 104, .type_tag = "doc.patch", .state = ipc.NodeState.fromOpaque() } },
        .{ .EdgeAdd = .{ .dependent = 104, .dependency = 102 } },
        .{ .NodeRemove = .{ .node = 101 } },
    });
    try mirror.applyDelta(delta);
    try std.testing.expectEqual(@as(u64, 6), mirror.epoch);
    try std.testing.expectEqual(@as(usize, 2), mirror.nodeCount()); // 102 + 104 (101 removed)
    try std.testing.expectEqualSlices(u8, &.{ 9, 9 }, mirror.payloadOf(102).?);
    try std.testing.expect(mirror.payloadOf(104) == null); // opaque

    const cycle_ids = try mirror.nodesOfType(allocator, "doc.cycle");
    defer allocator.free(cycle_ids);
    try std.testing.expectEqual(@as(usize, 1), cycle_ids.len);
    try std.testing.expectEqual(@as(ipc.NodeId, 102), cycle_ids[0]);
}

test "lazily/state_mirror: invalidate is a no-op (payload kept stale)" {
    const allocator = std.testing.allocator;
    var mirror = StateGraphMirror.init(allocator);
    defer mirror.deinit();

    try mirror.applySnapshot(ipc.Snapshot.init(
        1,
        &.{.{ .node = 1, .type_tag = "t", .state = ipc.NodeState.fromPayload(&.{42}) }},
        &.{},
        &.{1},
    ));
    try mirror.applyDelta(ipc.Delta.init(1, 2, &.{
        .{ .Invalidate = .{ .node = 1 } },
    }));
    // Invalidate did not clear the payload — consumer recompute is plugin-side.
    try std.testing.expectEqualSlices(u8, &.{42}, mirror.payloadOf(1).?);
}
