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

/// Locally-private base for minted family entry node ids (`#lzfamilysync`), set
/// far above any application-registered id so a materialized family entry can
/// never collide with an app cell. Mirrors lazily-rs `FAMILY_NODE_BASE`.
const FAMILY_NODE_BASE: NodeId = 1 << 48;

/// The first `NodeKey` segment (before the first `/`) — the family namespace.
fn keyNamespace(key: NodeKey) NodeKey {
    if (std.mem.indexOfScalar(u8, key, '/')) |slash| return key[0..slash];
    return key;
}

/// A CrdtPlaneRuntime owns the plane, the op log, and the per-node LWW
/// register map. It is the wire-facing anti-entropy engine: `ingest` applies a
/// received `CrdtSync` (idempotent on re-delivery), `localUpdate` mints a new
/// op, and `syncFrameSince` produces a pull reply.
///
/// It also carries the reactive family-granularity sync vehicle
/// (`#lzfamilysync`): registered family namespaces, a wire-stable
/// `NodeKey → NodeId` index, per-namespace present sets, and a membership epoch,
/// so an inbound keyed op for an unregistered family entry **materializes** the
/// entry on ingest instead of being dropped.
///
/// Mirrors lazily-rs `CrdtPlaneRuntime` (`crdt_plane.rs`), specialized to the
/// LWW-at-plane model the conformance fixtures pin.
pub const CrdtPlaneRuntime = struct {
    allocator: std.mem.Allocator,
    plane: CrdtPlane,
    log: OpLog,
    cells: std.AutoHashMap(NodeId, PlaneLwwCell),
    /// Registered family namespaces (`#lzfamilysync`). An inbound keyed op whose
    /// first `NodeKey` segment is a member materializes on ingest.
    families: std.StringHashMap(void),
    /// Wire-stable `NodeKey → NodeId` index so a family entry stays addressable
    /// across a peer's `NodeId` churn (a remote's minted id differs from ours).
    keys: std.StringHashMap(NodeId),
    /// Per-namespace materialized keys, in first-materialization order (present
    /// set only grows: deferral-not-dealloc). The `[]const u8` entries are owned
    /// here — the single owner of every family key string.
    family_members: std.StringHashMap(std.ArrayList(NodeKey)),
    /// Reactive membership signal, bumped whenever a family entry materializes —
    /// a derived aggregate over a family reads it so a remote-added key forces a
    /// recompute (a brand-new entry is not yet a dependency; the epoch is).
    membership_epoch: u64,
    /// Monotonic allocator for locally-private family entry node ids.
    next_family_node: NodeId,

    pub fn init(allocator: std.mem.Allocator, peer: PeerId) CrdtPlaneRuntime {
        return .{
            .allocator = allocator,
            .plane = CrdtPlane.init(allocator, peer),
            .log = OpLog.init(allocator),
            .cells = std.AutoHashMap(NodeId, PlaneLwwCell).init(allocator),
            .families = std.StringHashMap(void).init(allocator),
            .keys = std.StringHashMap(NodeId).init(allocator),
            .family_members = std.StringHashMap(std.ArrayList(NodeKey)).init(allocator),
            .membership_epoch = 0,
            .next_family_node = FAMILY_NODE_BASE,
        };
    }

    pub fn deinit(self: *CrdtPlaneRuntime) void {
        self.plane.deinit();
        self.log.deinit();
        self.cells.deinit();
        self.families.deinit();
        self.keys.deinit();
        // Free every owned family key string, then the per-namespace lists.
        var it = self.family_members.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |k| self.allocator.free(k);
            entry.value_ptr.deinit(self.allocator);
        }
        self.family_members.deinit();
    }

    /// Register a last-writer-wins **family** (`#lzfamilysync`) under `namespace`,
    /// so a keyed op an entry of this family produces on a peer materializes an
    /// entry here on `ingest` instead of being dropped. Entries are LWW cells
    /// addressed by `NodeKey` `namespace/<suffix>`. Replicas that share a session
    /// must register the same family namespace.
    pub fn registerFamilyLww(self: *CrdtPlaneRuntime, namespace: []const u8) !void {
        try self.families.put(namespace, {});
        if (!self.family_members.contains(namespace)) {
            try self.family_members.put(namespace, .empty);
        }
    }

    /// The reactive membership signal (`#lzfamilysync`): a derived aggregate over
    /// a family depends on it so a remote-materialized key forces a recompute.
    pub fn membershipEpoch(self: *const CrdtPlaneRuntime) u64 {
        return self.membership_epoch;
    }

    /// Bump the membership epoch so a derived aggregate over a family recomputes
    /// when its present set grows.
    fn bumpMembershipEpoch(self: *CrdtPlaneRuntime) void {
        self.membership_epoch +%= 1;
    }

    /// Mint a locally-private node id for a family entry, skipping any id already
    /// in use so a family node can never collide with an app-registered cell.
    fn mintFamilyNode(self: *CrdtPlaneRuntime) NodeId {
        while (true) {
            const candidate = self.next_family_node;
            self.next_family_node +%= 1;
            if (!self.cells.contains(candidate)) return candidate;
        }
    }

    /// Record a newly-materialized key in its family's present set (dedup so a
    /// re-observed key does not duplicate), returning the runtime-owned key slice
    /// (the single owner of the string). Only called for a genuinely new key.
    fn recordFamilyMember(self: *CrdtPlaneRuntime, namespace: []const u8, key: NodeKey) !NodeKey {
        const gop = try self.family_members.getOrPut(namespace);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        const owned = try self.allocator.dupe(u8, key);
        try gop.value_ptr.append(self.allocator, owned);
        return owned;
    }

    /// Materialize a fresh family entry for `key` seeded from `state`/`stamp`:
    /// mint a local node, index the key, record membership, bump the epoch.
    /// Returns the local node id.
    fn materializeFamilyEntry(
        self: *CrdtPlaneRuntime,
        namespace: []const u8,
        key: NodeKey,
        state: IpcValue,
        stamp: HlcStamp,
    ) !NodeId {
        const owned = try self.recordFamilyMember(namespace, key);
        const node = self.mintFamilyNode();
        try self.cells.put(node, .{ .state = state, .stamp = stamp, .key = owned });
        try self.keys.put(owned, node);
        self.bumpMembershipEpoch();
        return node;
    }

    /// Insert or update a local LWW family entry `namespace/<key_suffix>` to
    /// `state` at `now_micros`, returning the `CrdtOp` to broadcast (or null if
    /// the value was stamp-dominated). Materializes the entry (and bumps
    /// membership) on first insert. `state` is the caller-encoded converged
    /// register — the LWW-at-plane model treats it as the whole register.
    pub fn familySetLww(
        self: *CrdtPlaneRuntime,
        namespace: []const u8,
        key_suffix: []const u8,
        state: IpcValue,
        now_micros: u64,
    ) !?CrdtOp {
        const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ namespace, key_suffix });
        defer self.allocator.free(key);
        const stamp = try self.plane.tick(now_micros);
        if (self.keys.get(key)) |node| {
            // Existing entry: a normal stamped LWW update.
            const existing = self.cells.get(node).?;
            if (existing.stamp.compare(stamp) != .lt) return null;
            try self.cells.put(node, .{ .state = state, .stamp = stamp, .key = existing.key });
            const op = CrdtOp{ .node = node, .key = existing.key, .stamp = stamp, .state = state };
            _ = try self.log.record(op);
            return op;
        }
        // First local insert: materialize a fresh entry seeded with `state`.
        const node = try self.materializeFamilyEntry(namespace, key, state, stamp);
        const op = CrdtOp{ .node = node, .key = self.cells.get(node).?.key, .stamp = stamp, .state = state };
        _ = try self.log.record(op);
        return op;
    }

    /// The materialized keys of family `namespace`, in first-materialization
    /// order (owned by the runtime; do not free).
    pub fn familyKeys(self: *const CrdtPlaneRuntime, namespace: []const u8) []const NodeKey {
        const members = self.family_members.get(namespace) orelse return &.{};
        return members.items;
    }

    /// The current converged state of family entry `namespace/<key_suffix>`,
    /// or null if the key is not present.
    pub fn familyValueLww(self: *const CrdtPlaneRuntime, namespace: []const u8, key_suffix: []const u8) ?IpcValue {
        var buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&buf, "{s}/{s}", .{ namespace, key_suffix }) catch return null;
        const node = self.keys.get(key) orelse return null;
        return (self.cells.get(node) orelse return null).state;
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
            // Key-aware resolution (`#lzfamilysync`): a keyed op for an
            // already-materialized family entry resolves to its LOCAL node (the
            // remote's minted id differs from ours); an unmatched key whose
            // namespace is a registered family MATERIALIZES a fresh entry seeded
            // from the op state (materialize-on-ingest) instead of being dropped.
            var target: NodeId = op.node;
            var resolved_via_key = false;
            if (op.key) |k| {
                if (self.keys.get(k)) |local| {
                    target = local;
                    resolved_via_key = true;
                } else if (self.families.contains(keyNamespace(k))) {
                    // Seeding from the op state IS the pointwise CRDT merge, so
                    // this inherits full semilattice convergence.
                    _ = try self.materializeFamilyEntry(keyNamespace(k), k, op.state, op.stamp);
                    _ = try self.plane.frontier.observe(op.stamp.peer, op.stamp);
                    continue;
                }
            }
            if (resolved_via_key) {
                // Family entry LWW update — greatest stamp wins; preserve the
                // runtime-owned key (op.key is a transient wire slice).
                const cell = self.cells.getPtr(target).?;
                if (op.stamp.compare(cell.stamp) == .gt) {
                    cell.state = op.state;
                    cell.stamp = op.stamp;
                }
            } else {
                // Base LWW-at-plane: greatest stamp wins.
                const gop = try self.cells.getOrPut(target);
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

// ---------------------------------------------------------------------------
// Reactive family-granularity sync (#lzfamilysync). Mirrors lazily-rs
// tests/familysync_conformance.rs + the FamilySync.lean laws.
// ---------------------------------------------------------------------------

const builtin = @import("builtin");
const json = std.json;
const FAMILY_FIXTURE = "../lazily-spec/conformance/familysync/materialize_on_ingest.json";

const TRUE_STATE = [_]u8{1};
const FALSE_STATE = [_]u8{0};

/// Encode a bool family value as a one-byte inline register (static storage —
/// the plane borrows state bytes, so they must outlive ingest).
fn boolState(v: bool) IpcValue {
    return IpcValue.fromInline(if (v) &TRUE_STATE else &FALSE_STATE);
}

/// Decode a bool family register.
fn stateBool(state: IpcValue) bool {
    return state.Inline[0] != 0;
}

/// The suffix after the first `/` of a `NodeKey` — the fixture keys by suffix.
fn suffixOf(key: NodeKey) NodeKey {
    if (std.mem.lastIndexOfScalar(u8, key, '/')) |slash| return key[slash + 1 ..];
    return key;
}

test "lazily/crdt_plane: family sync materializes remote keys on ingest" {
    const allocator = std.testing.allocator;
    var origin = CrdtPlaneRuntime.init(allocator, 1);
    defer origin.deinit();
    try origin.registerFamilyLww("live");

    var target = CrdtPlaneRuntime.init(allocator, 2);
    defer target.deinit();
    try target.registerFamilyLww("live");
    const epoch_before = target.membershipEpoch();

    // Origin adds two entries under `live`.
    _ = try origin.familySetLww("live", "2", boolState(true), 100);
    _ = try origin.familySetLww("live", "3", boolState(true), 101);

    const frame = try origin.syncFrame(allocator);
    defer {
        allocator.free(frame.frontier);
        allocator.free(frame.ops);
    }
    const applied = try target.ingest(frame, 1000);
    try std.testing.expect(applied >= 2);

    // Membership propagated + epoch bumped.
    try std.testing.expectEqual(@as(usize, 2), target.familyKeys("live").len);
    try std.testing.expect(target.membershipEpoch() != epoch_before);
    try std.testing.expect(stateBool(target.familyValueLww("live", "2").?));
    try std.testing.expect(stateBool(target.familyValueLww("live", "3").?));

    // Re-ingest is idempotent.
    const reapplied = try target.ingest(frame, 1001);
    try std.testing.expectEqual(@as(usize, 0), reapplied);
}

fn readFamilyFixture(path: []const u8) ![]u8 {
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

test "lazily/crdt_plane: family sync conformance (materialize_on_ingest.json)" {
    const allocator = std.testing.allocator;
    const raw = readFamilyFixture(FAMILY_FIXTURE) catch return error.SkipZigTest;
    defer allocator.free(raw);

    var parsed = try json.parseFromSlice(json.Value, allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const fixture = parsed.value;
    const namespace = fixture.object.get("namespace").?.string;
    try std.testing.expectEqualStrings("bool", fixture.object.get("value_type").?.string);

    for (fixture.object.get("scenarios").?.array.items) |scenario| {
        const obj = scenario.object;
        const origin_peer: PeerId = @intCast(obj.get("origin_peer").?.integer);
        const target_peer: PeerId = @intCast(obj.get("target_peer").?.integer);

        var origin = CrdtPlaneRuntime.init(allocator, origin_peer);
        defer origin.deinit();
        try origin.registerFamilyLww(namespace);

        var target = CrdtPlaneRuntime.init(allocator, target_peer);
        defer target.deinit();
        try target.registerFamilyLww(namespace);
        const epoch_before = target.membershipEpoch();

        // Apply origin family writes in fixture order.
        for (obj.get("origin_sets").?.array.items) |set| {
            const so = set.object;
            const key = so.get("key").?.string;
            const value = so.get("value").?.bool;
            const now: u64 = @intCast(so.get("now").?.integer);
            _ = try origin.familySetLww(namespace, key, boolState(value), now);
        }

        const frame = try origin.syncFrame(allocator);
        defer {
            allocator.free(frame.frontier);
            allocator.free(frame.ops);
        }
        const applied = try target.ingest(frame, 1_000);
        try std.testing.expect(applied > 0);

        const expect = obj.get("expect").?.object;

        if (obj.get("reingest")) |ri| {
            if (ri.bool) {
                const reapplied = try target.ingest(frame, 1_001);
                const want: usize = @intCast(expect.get("reingest_applied").?.integer);
                try std.testing.expectEqual(want, reapplied);
            }
        }

        // Membership propagation: exact key set (order-independent).
        const want_keys = expect.get("target_keys").?.array.items;
        const got_keys = target.familyKeys(namespace);
        try std.testing.expectEqual(want_keys.len, got_keys.len);
        for (want_keys) |wk| {
            var found = false;
            for (got_keys) |gk| {
                if (std.mem.eql(u8, wk.string, suffixOf(gk))) {
                    found = true;
                    break;
                }
            }
            try std.testing.expect(found);
        }

        try std.testing.expectEqual(
            @as(usize, @intCast(expect.get("target_present_count").?.integer)),
            got_keys.len,
        );

        // Value adoption / LWW convergence.
        var vit = expect.get("target_values").?.object.iterator();
        while (vit.next()) |entry| {
            const want = entry.value_ptr.bool;
            const got = stateBool(target.familyValueLww(namespace, entry.key_ptr.*).?);
            try std.testing.expectEqual(want, got);
        }

        // Derived-aggregate transparency: count of `true` entries converges.
        var count_true: usize = 0;
        for (got_keys) |gk| {
            if (stateBool(target.familyValueLww(namespace, suffixOf(gk)).?)) count_true += 1;
        }
        try std.testing.expectEqual(
            @as(usize, @intCast(expect.get("target_count_true").?.integer)),
            count_true,
        );

        if (expect.get("target_epoch_bumped")) |eb| {
            if (eb.bool) try std.testing.expect(target.membershipEpoch() != epoch_before);
        }
    }
}
