const std = @import("std");
const crdt = @import("crdt.zig");
const ipc = @import("ipc.zig");
const Hlc = crdt.Hlc;
const HlcStamp = crdt.HlcStamp;
const StampFrontier = crdt.StampFrontier;
const PeerId = crdt.PeerId;
const NodeId = ipc.NodeId;
const NodeKey = ipc.NodeKey;
const CrdtOp = ipc.CrdtOp;
const CrdtSync = ipc.CrdtSync;
const IpcValue = ipc.IpcValue;
const WireStamp = ipc.WireStamp;

/// An idempotent op log keyed by `(node, stamp)` — the anti-entropy substrate.
/// Re-delivering an already-seen frame applies 0 new ops (state-based CvRDT
/// idempotence). Mirrors lazily-rs `OpLog` (`crdt.rs:987-1071`).
pub const OpLog = struct {
    allocator: std.mem.Allocator,
    /// (node, stamp) → op, dedup key.
    seen: std.AutoHashMap(DedupKey, CrdtOp),
    /// All ops in insertion order.
    ops: std.ArrayList(CrdtOp),

    pub const DedupKey = struct {
        node: NodeId,
        stamp: WireStamp,
    };

    pub fn init(allocator: std.mem.Allocator) OpLog {
        return .{
            .allocator = allocator,
            .seen = std.AutoHashMap(DedupKey, CrdtOp).init(allocator),
            .ops = .empty,
        };
    }

    pub fn deinit(self: *OpLog) void {
        self.seen.deinit();
        self.ops.deinit(self.allocator);
    }

    /// Record an op if its `(node, stamp)` hasn't been seen. Returns true iff
    /// newly recorded.
    pub fn record(self: *OpLog, op: CrdtOp) !bool {
        const key = DedupKey{ .node = op.node, .stamp = op.stamp };
        const gop = try self.seen.getOrPut(key);
        if (gop.found_existing) return false;
        gop.value_ptr.* = op;
        try self.ops.append(self.allocator, op);
        return true;
    }

    pub fn count(self: *const OpLog) usize {
        return self.ops.items.len;
    }
};

/// The CRDT plane session: peer identity, HLC, membership, and the per-peer
/// stamp frontier whose min-over-membership is the causal-stability watermark.
/// Mirrors lazily-rs `CrdtPlane` (`crdt.rs:793-960`).
pub const CrdtPlane = struct {
    peer: PeerId,
    clock: Hlc,
    membership: std.ArrayList(PeerId),
    frontier: StampFrontier,

    pub fn init(allocator: std.mem.Allocator, peer: PeerId) CrdtPlane {
        var plane = CrdtPlane{
            .peer = peer,
            .clock = Hlc.init(peer),
            .membership = .empty,
            .frontier = StampFrontier.init(allocator),
        };
        // A peer is always a member of its own membership, seeded in the
        // frontier at the bootstrap stamp so the stability watermark is
        // defined as soon as every OTHER member is observed.
        plane.membership.append(allocator, peer) catch {};
        _ = plane.frontier.observe(peer, .{ .wall_time = 0, .logical = 0, .peer = peer }) catch {};
        return plane;
    }

    pub fn deinit(self: *CrdtPlane) void {
        self.membership.deinit(self.frontier.entries.allocator);
        self.frontier.deinit();
    }

    /// Local event: stamp the clock and observe the local peer.
    pub fn tick(self: *CrdtPlane, now_micros: u64) !HlcStamp {
        const stamp = self.clock.send(now_micros);
        _ = try self.frontier.observe(self.peer, stamp);
        return stamp;
    }

    /// Observe a remote stamp: expand membership if the peer is new, advance
    /// the frontier, and tick the local clock past it.
    pub fn observeRemote(self: *CrdtPlane, remote: HlcStamp, now_micros: u64) !HlcStamp {
        try self.expandMembership(remote.peer);
        _ = try self.frontier.observe(remote.peer, remote);
        return self.clock.recv(remote, now_micros);
    }

    fn expandMembership(self: *CrdtPlane, peer: PeerId) !void {
        for (self.membership.items) |p| {
            if (p == peer) return;
        }
        try self.membership.append(self.frontier.entries.allocator, peer);
    }

    /// The min stamp over the full membership — the causal point every peer
    /// has provably passed. null until every member has been observed.
    pub fn stabilityFrontier(self: *const CrdtPlane) ?HlcStamp {
        return self.frontier.frontier(self.membership.items);
    }

    pub fn isCollectable(self: *const CrdtPlane, stamp: HlcStamp) bool {
        const wm = self.stabilityFrontier() orelse return false;
        return stamp.compare(wm) != .gt;
    }
};

/// LWW-at-the-plane cell state: the op with the greatest stamp wins. This is
/// the model the `anti_entropy_converge.json` fixture asserts.
pub const PlaneLwwCell = struct {
    state: ?IpcValue = null,
    stamp: HlcStamp = .{ .wall_time = 0, .logical = 0, .peer = 0 },
    key: ?NodeKey = null,
};

/// A CrdtPlaneRuntime owns the plane, the op log, and the per-node LWW
/// register map. It is the wire-facing anti-entropy engine: `ingest` applies a
/// received `CrdtSync` (idempotent on re-delivery), `localUpdate` mints a new
/// op, and `syncFrameSince` produces a pull reply.
///
/// Mirrors lazily-rs `CrdtPlaneRuntime` (`crdt_plane.rs:90-296`), specialized
/// to the LWW-at-plane model the conformance fixture pins.
pub const CrdtPlaneRuntime = struct {
    allocator: std.mem.Allocator,
    plane: CrdtPlane,
    log: OpLog,
    cells: std.AutoHashMap(NodeId, PlaneLwwCell),

    pub fn init(allocator: std.mem.Allocator, peer: PeerId) CrdtPlaneRuntime {
        return .{
            .allocator = allocator,
            .plane = CrdtPlane.init(allocator, peer),
            .log = OpLog.init(allocator),
            .cells = std.AutoHashMap(NodeId, PlaneLwwCell).init(allocator),
        };
    }

    pub fn deinit(self: *CrdtPlaneRuntime) void {
        self.plane.deinit();
        self.log.deinit();
        self.cells.deinit();
    }

    /// Apply a local write: stamp the plane, record the op, update the cell.
    /// Returns the op to broadcast, or null if value unchanged / unknown node.
    pub fn localUpdate(
        self: *CrdtPlaneRuntime,
        node: NodeId,
        state: IpcValue,
        now_micros: u64,
    ) !?CrdtOp {
        const stamp = try self.plane.tick(now_micros);
        const existing = self.cells.get(node);
        if (existing) |e| {
            if (e.stamp.compare(stamp) != .lt) return null;
        }
        const key = if (existing) |e| e.key else null;
        try self.cells.put(node, .{ .state = state, .stamp = stamp, .key = key });
        const op = CrdtOp{
            .node = node,
            .key = key,
            .stamp = stamp,
            .state = state,
        };
        _ = try self.log.record(op);
        return op;
    }

    /// Declare a node's stable key (#lzwirekey).
    pub fn registerKey(self: *CrdtPlaneRuntime, node: NodeId, key: ?NodeKey) !void {
        const gop = try self.cells.getOrPut(node);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .key = key };
        } else if (key != null) {
            gop.value_ptr.key = key;
        }
    }

    /// Ingest a `CrdtSync` frame. Idempotent: re-delivery applies 0 new ops.
    /// Returns the number of newly applied ops.
    pub fn ingest(self: *CrdtPlaneRuntime, sync: CrdtSync, now_micros: u64) !usize {
        // Observe every frontier stamp (expand membership + advance clock).
        for (sync.frontier) |entry| {
            _ = try self.plane.observeRemote(entry.stamp, now_micros);
        }
        var applied: usize = 0;
        for (sync.ops) |op| {
            if (!try self.log.record(op)) continue; // dedup by (node, stamp)
            applied += 1;
            // LWW-at-plane: greatest stamp wins.
            const gop = try self.cells.getOrPut(op.node);
            if (gop.found_existing) {
                if (op.stamp.compare(gop.value_ptr.stamp) == .gt) {
                    gop.value_ptr.* = .{
                        .state = op.state,
                        .stamp = op.stamp,
                        .key = op.key orelse gop.value_ptr.key,
                    };
                }
            } else {
                gop.value_ptr.* = .{ .state = op.state, .stamp = op.stamp, .key = op.key };
            }
            _ = try self.plane.frontier.observe(op.stamp.peer, op.stamp);
        }
        return applied;
    }

    /// The wire frontier (`peer → max stamp`) for advertisement.
    pub fn wireFrontier(self: *const CrdtPlaneRuntime, allocator: std.mem.Allocator) ![]ipc.FrontierEntry {
        var out = std.ArrayList(ipc.FrontierEntry).empty;
        errdefer out.deinit(allocator);
        var iter = self.plane.frontier.entries.iterator();
        while (iter.next()) |entry| {
            try out.append(allocator, .{ .peer = entry.key_ptr.*, .stamp = entry.value_ptr.* });
        }
        return out.toOwnedSlice(allocator);
    }

    /// Full sync frame (all ops).
    pub fn syncFrame(self: *const CrdtPlaneRuntime, allocator: std.mem.Allocator) !CrdtSync {
        const frontier = try self.wireFrontier(allocator);
        const ops = try allocator.dupe(CrdtOp, self.log.ops.items);
        return CrdtSync.init(frontier, ops);
    }
};

// ---------------------------------------------------------------------------
// Tests (mirror anti_entropy_converge.json + crdt_sync_frames.json)
// ---------------------------------------------------------------------------

fn makeInlineState(comptime byte: u8) IpcValue {
    return IpcValue.fromInline(&[_]u8{byte});
}

test "lazily/crdt_plane: LWW last-writer-wins over out-of-order delivery" {
    const allocator = std.testing.allocator;
    var rt = CrdtPlaneRuntime.init(allocator, 0);
    defer rt.deinit();

    const ops = [_]CrdtOp{
        .{ .node = 1, .key = "doc/title", .stamp = .{ .wall_time = 10, .logical = 0, .peer = 1 }, .state = makeInlineState(65) },
        .{ .node = 1, .key = "doc/title", .stamp = .{ .wall_time = 12, .logical = 0, .peer = 2 }, .state = makeInlineState(66) },
        .{ .node = 1, .key = "doc/title", .stamp = .{ .wall_time = 11, .logical = 0, .peer = 1 }, .state = makeInlineState(67) },
        .{ .node = 2, .key = "doc/count", .stamp = .{ .wall_time = 5, .logical = 3, .peer = 1 }, .state = makeInlineState(9) },
        .{ .node = 2, .key = "doc/count", .stamp = .{ .wall_time = 5, .logical = 3, .peer = 2 }, .state = makeInlineState(7) },
    };
    const applied = try rt.ingest(CrdtSync.init(&.{}, &ops), 0);
    try std.testing.expectEqual(@as(usize, 5), applied);

    // Node 1 winner = (12,0,2) → byte 66; node 2 tie (5,3,1) vs (5,3,2) → peer 2 → byte 7.
    const n1 = rt.cells.get(1).?;
    try std.testing.expectEqual(@as(u8, 66), n1.state.?.Inline[0]);
    const n2 = rt.cells.get(2).?;
    try std.testing.expectEqual(@as(u8, 7), n2.state.?.Inline[0]);
}

test "lazily/crdt_plane: idempotent re-delivery applies 0 new ops" {
    const allocator = std.testing.allocator;
    var rt = CrdtPlaneRuntime.init(allocator, 0);
    defer rt.deinit();

    const ops = [_]CrdtOp{
        .{ .node = 1, .key = null, .stamp = .{ .wall_time = 10, .logical = 0, .peer = 1 }, .state = makeInlineState(65) },
        .{ .node = 1, .key = null, .stamp = .{ .wall_time = 11, .logical = 0, .peer = 1 }, .state = makeInlineState(66) },
    };
    const first = try rt.ingest(CrdtSync.init(&.{}, &ops), 0);
    try std.testing.expectEqual(@as(usize, 2), first);
    const redeliver = try rt.ingest(CrdtSync.init(&.{}, &ops), 0);
    try std.testing.expectEqual(@as(usize, 0), redeliver);
}

test "lazily/crdt_plane: reverse-order delivery converges identically" {
    const allocator = std.testing.allocator;
    var forward = CrdtPlaneRuntime.init(allocator, 0);
    defer forward.deinit();
    var reverse = CrdtPlaneRuntime.init(allocator, 0);
    defer reverse.deinit();

    const ops = [_]CrdtOp{
        .{ .node = 1, .key = null, .stamp = .{ .wall_time = 10, .logical = 0, .peer = 1 }, .state = makeInlineState(65) },
        .{ .node = 1, .key = null, .stamp = .{ .wall_time = 12, .logical = 0, .peer = 2 }, .state = makeInlineState(66) },
    };
    _ = try forward.ingest(CrdtSync.init(&.{}, &ops), 0);
    const reversed = [_]CrdtOp{ ops[1], ops[0] };
    _ = try reverse.ingest(CrdtSync.init(&.{}, &reversed), 0);

    try std.testing.expectEqual(
        forward.cells.get(1).?.state.?.Inline[0],
        reverse.cells.get(1).?.state.?.Inline[0],
    );
}

test "lazily/crdt_plane: local_update emits keyed op and records it" {
    const allocator = std.testing.allocator;
    var rt = CrdtPlaneRuntime.init(allocator, 1);
    defer rt.deinit();
    try rt.registerKey(7, "scores/alice");

    const op = (try rt.localUpdate(7, makeInlineState(42), 100)).?;
    try std.testing.expectEqualStrings("scores/alice", op.key.?);
    try std.testing.expectEqual(@as(NodeId, 7), op.node);
    try std.testing.expectEqual(@as(u64, 100), op.stamp.wall_time);
    try std.testing.expectEqual(@as(usize, 1), rt.log.count());
}

test "lazily/crdt_plane: stability frontier expands with membership" {
    const allocator = std.testing.allocator;
    var rt = CrdtPlaneRuntime.init(allocator, 1);
    defer rt.deinit();

    // Observe a remote stamp from peer 2.
    _ = try rt.plane.observeRemote(.{ .wall_time = 50, .logical = 0, .peer = 2 }, 60);
    // Both peers have observed → frontier is min(50-ish, local).
    const wm = rt.plane.stabilityFrontier();
    try std.testing.expect(wm != null);
}
