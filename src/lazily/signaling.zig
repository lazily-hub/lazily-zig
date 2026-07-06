const std = @import("std");
const ipc = @import("ipc.zig");

/// Signaling protocol wire types (`lazily-spec/protocol.md § Signaling
/// Protocol (WebSocket)`). Type discriminator is `"type"`; variants are
/// kebab-case. The `from` field on every forwarded frame is the sender
/// connection's registered peer id, never client-supplied (anti-spoofing).
///
/// These are the portable wire shapes — they round-trip the
/// `lazily-spec/conformance/signaling/frames.json` fixtures. A native
/// WebSocket client is a platform adapter (optional behind the seam).
pub const ClientMessage = union(enum) {
    join: Join,
    offer: Sdp,
    answer: Sdp,
    ice: Ice,
    relay: Relay,
    leave,

    pub const Join = struct {
        peer: ipc.PeerId,
        capabilities: ?[]const []const u8 = null,
    };

    pub const Sdp = struct {
        to: ipc.PeerId,
        sdp: []const u8,
    };

    pub const Ice = struct {
        to: ipc.PeerId,
        candidate: []const u8,
    };

    pub const Relay = struct {
        to: ipc.PeerId,
        payload: std.json.Value,
    };

    pub fn encodeJsonAlloc(self: ClientMessage, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }

    pub fn jsonStringify(self: ClientMessage, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .join => |j| {
                try jw.objectField("type");
                try jw.write("join");
                try jw.objectField("peer");
                try jw.write(j.peer);
                if (j.capabilities) |caps| {
                    try jw.objectField("capabilities");
                    try jw.write(caps);
                }
            },
            .offer => |o| {
                try jw.objectField("type");
                try jw.write("offer");
                try jw.objectField("to");
                try jw.write(o.to);
                try jw.objectField("sdp");
                try jw.write(o.sdp);
            },
            .answer => |a| {
                try jw.objectField("type");
                try jw.write("answer");
                try jw.objectField("to");
                try jw.write(a.to);
                try jw.objectField("sdp");
                try jw.write(a.sdp);
            },
            .ice => |i| {
                try jw.objectField("type");
                try jw.write("ice");
                try jw.objectField("to");
                try jw.write(i.to);
                try jw.objectField("candidate");
                try jw.write(i.candidate);
            },
            .relay => |r| {
                try jw.objectField("type");
                try jw.write("relay");
                try jw.objectField("to");
                try jw.write(r.to);
                try jw.objectField("payload");
                try jw.write(r.payload);
            },
            .leave => {
                try jw.objectField("type");
                try jw.write("leave");
            },
        }
        try jw.endObject();
    }
};

pub const ServerMessage = union(enum) {
    welcome: Welcome,
    peer_joined: PeerIdOnly,
    peer_left: PeerIdOnly,
    offer: FromSdp,
    answer: FromSdp,
    ice: FromIce,
    relay: FromRelay,
    error_msg: ErrorMsg,

    pub const Welcome = struct {
        peer: ipc.PeerId,
        peers: []const ipc.PeerId,
    };

    pub const PeerIdOnly = struct { peer: ipc.PeerId };

    pub const FromSdp = struct {
        from: ipc.PeerId,
        sdp: []const u8,
    };

    pub const FromIce = struct {
        from: ipc.PeerId,
        candidate: []const u8,
    };

    pub const FromRelay = struct {
        from: ipc.PeerId,
        payload: std.json.Value,
    };

    pub const ErrorMsg = struct {
        code: []const u8,
        message: []const u8,
    };

    pub fn encodeJsonAlloc(self: ServerMessage, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }

    pub fn jsonStringify(self: ServerMessage, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .welcome => |m| {
                try jw.objectField("type");
                try jw.write("welcome");
                try jw.objectField("peer");
                try jw.write(m.peer);
                try jw.objectField("peers");
                try jw.write(m.peers);
            },
            .peer_joined => |m| {
                try jw.objectField("type");
                try jw.write("peer-joined");
                try jw.objectField("peer");
                try jw.write(m.peer);
            },
            .peer_left => |m| {
                try jw.objectField("type");
                try jw.write("peer-left");
                try jw.objectField("peer");
                try jw.write(m.peer);
            },
            .offer => |m| {
                try jw.objectField("type");
                try jw.write("offer");
                try jw.objectField("from");
                try jw.write(m.from);
                try jw.objectField("sdp");
                try jw.write(m.sdp);
            },
            .answer => |m| {
                try jw.objectField("type");
                try jw.write("answer");
                try jw.objectField("from");
                try jw.write(m.from);
                try jw.objectField("sdp");
                try jw.write(m.sdp);
            },
            .ice => |m| {
                try jw.objectField("type");
                try jw.write("ice");
                try jw.objectField("from");
                try jw.write(m.from);
                try jw.objectField("candidate");
                try jw.write(m.candidate);
            },
            .relay => |m| {
                try jw.objectField("type");
                try jw.write("relay");
                try jw.objectField("from");
                try jw.write(m.from);
                try jw.objectField("payload");
                try jw.write(m.payload);
            },
            .error_msg => |m| {
                try jw.objectField("type");
                try jw.write("error");
                try jw.objectField("code");
                try jw.write(m.code);
                try jw.objectField("message");
                try jw.write(m.message);
            },
        }
        try jw.endObject();
    }
};

/// Minimal in-process signaling room: routes directed frames between joined
/// peers and stamps `from` from the sender's registered id (never
/// client-supplied). Mirrors the `RoomCore` contract pinned by
/// `lazily-spec/conformance/signaling/anti_spoof_session.json`.
pub const SignalingRoom = struct {
    allocator: std.mem.Allocator,
    /// connection id -> registered peer id.
    roster: std.AutoHashMap(u64, ipc.PeerId),
    /// peer id -> connection id (for directed delivery).
    conn_of_peer: std.AutoHashMap(ipc.PeerId, u64),

    pub const Outbound = struct {
        to_conn: u64,
        frame: ServerMessage,
    };

    pub fn init(allocator: std.mem.Allocator) SignalingRoom {
        return .{
            .allocator = allocator,
            .roster = std.AutoHashMap(u64, ipc.PeerId).init(allocator),
            .conn_of_peer = std.AutoHashMap(ipc.PeerId, u64).init(allocator),
        };
    }

    pub fn deinit(self: *SignalingRoom) void {
        self.roster.deinit();
        self.conn_of_peer.deinit();
    }

    /// Apply an inbound client frame from `from_conn`, appending any directed
    /// outbound server frames to `out`. `from_conn` MUST be a registered joiner
    /// for offer/answer/ice/relay/leave.
    pub fn apply(
        self: *SignalingRoom,
        out: *std.ArrayList(Outbound),
        from_conn: u64,
        msg: ClientMessage,
    ) !void {
        switch (msg) {
            .join => |j| {
                try self.roster.put(from_conn, j.peer);
                try self.conn_of_peer.put(j.peer, from_conn);
                // welcome: list of currently-joined peers (excluding self).
                var peers = std.ArrayList(ipc.PeerId).empty;
                defer peers.deinit(self.allocator);
                var iter = self.roster.valueIterator();
                while (iter.next()) |p| {
                    if (p.* != j.peer) try peers.append(self.allocator, p.*);
                }
                try out.append(self.allocator, .{
                    .to_conn = from_conn,
                    .frame = .{ .welcome = .{ .peer = j.peer, .peers = try peers.toOwnedSlice(self.allocator) } },
                });
                // broadcast peer-joined to everyone else.
                var iter2 = self.roster.iterator();
                while (iter2.next()) |entry| {
                    if (entry.value_ptr.* != j.peer) {
                        try out.append(self.allocator, .{
                            .to_conn = entry.key_ptr.*,
                            .frame = .{ .peer_joined = .{ .peer = j.peer } },
                        });
                    }
                }
            },
            .leave => {
                if (self.roster.fetchRemove(from_conn)) |kv| {
                    _ = self.conn_of_peer.remove(kv.value);
                    // broadcast peer-left.
                    var iter = self.roster.iterator();
                    while (iter.next()) |entry| {
                        try out.append(self.allocator, .{
                            .to_conn = entry.key_ptr.*,
                            .frame = .{ .peer_left = .{ .peer = kv.value } },
                        });
                    }
                }
            },
            .offer, .answer, .ice, .relay => {
                const sender = self.roster.get(from_conn) orelse {
                    try out.append(self.allocator, .{
                        .to_conn = from_conn,
                        .frame = .{ .error_msg = .{ .code = "not_joined", .message = "sender has not joined" } },
                    });
                    return;
                };
                const target_peer = switch (msg) {
                    .offer => |o| o.to,
                    .answer => |a| a.to,
                    .ice => |i| i.to,
                    .relay => |r| r.to,
                    .leave, .join => unreachable,
                };
                const target_conn = self.conn_of_peer.get(target_peer) orelse {
                    try out.append(self.allocator, .{
                        .to_conn = from_conn,
                        .frame = .{ .error_msg = .{ .code = "unknown_target", .message = "target peer not in room" } },
                    });
                    return;
                };
                const forwarded: ServerMessage = switch (msg) {
                    .offer => |o| .{ .offer = .{ .from = sender, .sdp = o.sdp } },
                    .answer => |a| .{ .answer = .{ .from = sender, .sdp = a.sdp } },
                    .ice => |i| .{ .ice = .{ .from = sender, .candidate = i.candidate } },
                    .relay => |r| .{ .relay = .{ .from = sender, .payload = r.payload } },
                    .leave, .join => unreachable,
                };
                try out.append(self.allocator, .{ .to_conn = target_conn, .frame = forwarded });
            },
        }
    }
};

/// Free any owned allocations in an Outbound list (currently the
/// `welcome.peers` slice), then clear the list.
pub fn freeOutbound(allocator: std.mem.Allocator, out: *std.ArrayList(SignalingRoom.Outbound)) void {
    for (out.items) |o| {
        switch (o.frame) {
            .welcome => |w| allocator.free(w.peers),
            else => {},
        }
    }
    out.clearRetainingCapacity();
}

// ---------------------------------------------------------------------------
// Tests (mirror signaling/frames.json wire shapes + anti_spoof_session.json)
// ---------------------------------------------------------------------------

test "lazily/signaling: client join encodes without capabilities key" {
    const allocator = std.testing.allocator;
    const msg = ClientMessage{ .join = .{ .peer = 1 } };
    const json = try msg.encodeJsonAlloc(allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"type\":\"join\",\"peer\":1}", json);
}

test "lazily/signaling: client join with capabilities" {
    const allocator = std.testing.allocator;
    const caps = [_][]const u8{"crdt"};
    const msg = ClientMessage{ .join = .{ .peer = 7, .capabilities = &caps } };
    const json = try msg.encodeJsonAlloc(allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"type\":\"join\",\"peer\":7,\"capabilities\":[\"crdt\"]}", json);
}

test "lazily/signaling: server welcome + peer-joined" {
    const allocator = std.testing.allocator;
    const peers = [_]ipc.PeerId{};
    const welcome = ServerMessage{ .welcome = .{ .peer = 1, .peers = &peers } };
    const wj = try welcome.encodeJsonAlloc(allocator);
    defer allocator.free(wj);
    try std.testing.expectEqualStrings("{\"type\":\"welcome\",\"peer\":1,\"peers\":[]}", wj);

    const pj = ServerMessage{ .peer_joined = .{ .peer = 5 } };
    const pjj = try pj.encodeJsonAlloc(allocator);
    defer allocator.free(pjj);
    try std.testing.expectEqualStrings("{\"type\":\"peer-joined\",\"peer\":5}", pjj);
}

test "lazily/signaling: room stamps from from registered id, rejects unknown target" {
    const allocator = std.testing.allocator;
    var room = SignalingRoom.init(allocator);
    defer room.deinit();

    var out = std.ArrayList(SignalingRoom.Outbound).empty;
    defer {
        for (out.items) |o| {
            switch (o.frame) {
                .welcome => |w| allocator.free(w.peers),
                else => {},
            }
        }
        out.deinit(allocator);
    }

    // peer 1 joins from conn 100.
    try room.apply(&out, 100, .{ .join = .{ .peer = 1 } });
    // peer 2 joins from conn 200.
    try room.apply(&out, 200, .{ .join = .{ .peer = 2 } });

    freeOutbound(allocator, &out);

    // peer 1 offers to peer 2 — forwarded with from=1 (server-stamped).
    try room.apply(&out, 100, .{ .offer = .{ .to = 2, .sdp = "offer-sdp" } });
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(u64, 200), out.items[0].to_conn);
    try std.testing.expect(out.items[0].frame == .offer);
    try std.testing.expectEqual(@as(ipc.PeerId, 1), out.items[0].frame.offer.from);

    freeOutbound(allocator, &out);
    // peer 1 offers to unknown peer 99.
    try room.apply(&out, 100, .{ .offer = .{ .to = 99, .sdp = "x" } });
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expect(out.items[0].frame == .error_msg);
    try std.testing.expectEqualStrings("unknown_target", out.items[0].frame.error_msg.code);
}
