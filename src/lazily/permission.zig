const std = @import("std");
const ipc = @import("ipc.zig");
const NodeId = ipc.NodeId;
const PeerId = ipc.PeerId;

/// Operation kind gated by the permission boundary
/// (`protocol.md § Permission Boundary (RemoteOp)`).
///
/// Three kinds are gated **independently**: a read grant never implies write
/// or effect-trigger.
pub const OpKind = enum {
    read,
    write,
    trigger_effect,
};

/// A per-node operation gated by peer permissions.
///
/// ```
/// RemoteOp = { kind: OpKind, node: NodeId }
/// ```
pub const RemoteOp = struct {
    kind: OpKind,
    node: NodeId,
};

/// Default-deny per-peer permission allowlist.
///
/// A peer with no grants can access nothing. Each `(peer, node, kind)` triple
/// is tracked independently — granting `read` on node N to peer P does NOT
/// grant `write` or `trigger_effect`.
///
/// `filter_readable(peer, nodes)` drops non-readable nodes from results before
/// serialization (omission, not redaction — like `Delta`).
pub const PeerPermissions = struct {
    /// Map key: composite of (peer, node, kind) for O(1) lookup.
    grants: std.AutoHashMap(GrantKey, void),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PeerPermissions {
        return .{
            .grants = std.AutoHashMap(GrantKey, void).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PeerPermissions) void {
        self.grants.deinit();
    }

    /// Grant `kind` on `node` to `peer`.
    pub fn grant(self: *PeerPermissions, peer: PeerId, node: NodeId, kind: OpKind) !void {
        const gop = try self.grants.getOrPut(grantKey(peer, node, kind));
        _ = gop;
    }

    /// Revoke `kind` on `node` from `peer`.
    pub fn revoke(self: *PeerPermissions, peer: PeerId, node: NodeId, kind: OpKind) bool {
        return self.grants.remove(grantKey(peer, node, kind));
    }

    /// Check if `peer` has `kind` permission on `node`. Default-deny: returns
    /// `false` if no explicit grant exists.
    pub fn isAllowed(self: *const PeerPermissions, peer: PeerId, node: NodeId, kind: OpKind) bool {
        return self.grants.contains(grantKey(peer, node, kind));
    }

    /// Check if `peer` can read `node`.
    pub fn canRead(self: *const PeerPermissions, peer: PeerId, node: NodeId) bool {
        return self.isAllowed(peer, node, .read);
    }

    /// Collect all node IDs from `nodes` that `peer` is allowed to read.
    /// Non-readable nodes are omitted entirely (not redacted).
    pub fn filterReadable(
        self: *const PeerPermissions,
        peer: PeerId,
        nodes: []const NodeSnapshot,
        out: *std.ArrayList(NodeSnapshot),
    ) !void {
        for (nodes) |node| {
            if (self.canRead(peer, node.node)) {
                try out.append(self.allocator, node);
            }
        }
    }

    /// Collect all node IDs from `nodes` that `peer` is allowed to read,
    /// returning a new slice.
    pub fn readableNodes(
        self: *const PeerPermissions,
        peer: PeerId,
        nodes: []const NodeSnapshot,
    ) ![]NodeSnapshot {
        var out: std.ArrayList(NodeSnapshot) = .empty;
        try self.filterReadable(peer, nodes, &out);
        return out.toOwnedSlice(self.allocator);
    }
};

/// Composite key for the grants map: packs (peer, node, kind) into a single
/// integer for O(1) AutoHashMap lookup.
const GrantKey = u128;

fn grantKey(peer: PeerId, node: NodeId, kind: OpKind) GrantKey {
    // Pack: peer (64 bits) | node (48 bits) | kind (2 bits) into 128 bits.
    // Node is unlikely to exceed 48 bits; kind is 0/1/2.
    const kind_bits: u128 = @intFromEnum(kind);
    const node_bits: u128 = @as(u128, node);
    const peer_bits: u128 = @as(u128, peer);
    return (peer_bits << 64) | (node_bits << 2) | kind_bits;
}

const NodeSnapshot = ipc.NodeSnapshot;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "lazily/permission: default-deny" {
    const allocator = std.testing.allocator;
    var perms = PeerPermissions.init(allocator);
    defer perms.deinit();

    try std.testing.expect(!perms.canRead(1, 100));
    try std.testing.expect(!perms.isAllowed(1, 100, .write));
    try std.testing.expect(!perms.isAllowed(1, 100, .trigger_effect));
}

test "lazily/permission: grant is kind-specific" {
    const allocator = std.testing.allocator;
    var perms = PeerPermissions.init(allocator);
    defer perms.deinit();

    try perms.grant(1, 100, .read);

    try std.testing.expect(perms.canRead(1, 100));
    try std.testing.expect(!perms.isAllowed(1, 100, .write));
    try std.testing.expect(!perms.isAllowed(1, 100, .trigger_effect));

    // Different peer
    try std.testing.expect(!perms.canRead(2, 100));

    // Different node
    try std.testing.expect(!perms.canRead(1, 200));
}

test "lazily/permission: revoke" {
    const allocator = std.testing.allocator;
    var perms = PeerPermissions.init(allocator);
    defer perms.deinit();

    try perms.grant(1, 100, .read);
    try std.testing.expect(perms.canRead(1, 100));

    try std.testing.expect(perms.revoke(1, 100, .read));
    try std.testing.expect(!perms.canRead(1, 100));
}

test "lazily/permission: filter_readable omits non-readable nodes" {
    const allocator = std.testing.allocator;
    var perms = PeerPermissions.init(allocator);
    defer perms.deinit();

    try perms.grant(1, 10, .read);
    try perms.grant(1, 30, .read);
    // Node 20 is NOT readable by peer 1.

    const nodes = [_]NodeSnapshot{
        .{ .node = 10, .type_tag = "i32", .state = .{ .Opaque = {} } },
        .{ .node = 20, .type_tag = "i32", .state = .{ .Opaque = {} } },
        .{ .node = 30, .type_tag = "i32", .state = .{ .Opaque = {} } },
    };

    const readable = try perms.readableNodes(1, &nodes);
    defer allocator.free(readable);

    try std.testing.expectEqual(@as(usize, 2), readable.len);
    try std.testing.expectEqual(@as(NodeId, 10), readable[0].node);
    try std.testing.expectEqual(@as(NodeId, 30), readable[1].node);
}
