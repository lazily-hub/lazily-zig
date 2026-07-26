const std = @import("std");
const ipc = @import("ipc.zig");

// --- minimal JSON accessors for the decode half of the wire contract -------

fn jsonGet(value: std.json.Value, name: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |o| o.get(name),
        else => null,
    };
}

fn jsonField(value: std.json.Value, name: []const u8) !std.json.Value {
    return jsonGet(value, name) orelse error.MissingField;
}

fn jsonStr(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}

fn jsonU64(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |n| if (n < 0) error.ExpectedUnsigned else @intCast(n),
        .number_string => |s| try std.fmt.parseInt(u64, s, 10),
        else => error.ExpectedInteger,
    };
}

/// Signaling protocol wire types (`lazily-spec/protocol.md § Signaling
/// Protocol (WebSocket)`). Type discriminator is `"type"`; variants are
/// kebab-case. The `from` field on every forwarded frame is the sender
/// connection's registered peer id, never client-supplied (anti-spoofing).
///
/// These are the portable wire shapes — they round-trip the
/// `lazily-spec/conformance/signaling/frames.json` fixtures. A native
/// WebSocket client is a platform adapter (optional behind the seam).
///
/// The `"type"` discriminator is the union's own tag enum rather than a string
/// literal repeated in the encoder and the decoder: one `wireName` table means
/// the two halves cannot disagree about a spelling, and a variant added to the
/// union is a compile error in both until it is handled.
pub const ClientTag = enum {
    join,
    offer,
    answer,
    ice,
    relay,
    leave,

    /// The stable wire spelling. Every client tag is already spelled the way it
    /// goes on the wire, so this is `@tagName` — written out anyway so the
    /// server side's kebab-case mapping has a symmetric counterpart.
    pub fn wireName(self: ClientTag) []const u8 {
        return @tagName(self);
    }

    pub fn fromWireName(name: []const u8) error{UnknownClientTag}!ClientTag {
        return std.meta.stringToEnum(ClientTag, name) orelse error.UnknownClientTag;
    }
};

pub const ClientMessage = union(ClientTag) {
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

    /// Decode a canonical client frame. String fields BORROW `value`, so the
    /// parsed document must outlive the message; `capabilities` is the one
    /// allocation (a `[]const []const u8` has no borrowable JSON counterpart)
    /// and is owned by the caller.
    ///
    /// The signaling corpus asks a binding to encode a typed message to the
    /// canonical JSON *and decode it back*; without this the decode half of
    /// `signaling/frames.json` had no implementation to replay against.
    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !ClientMessage {
        return switch (try ClientTag.fromWireName(try jsonStr(try jsonField(value, "type")))) {
            .join => blk: {
                var caps: ?[]const []const u8 = null;
                if (jsonGet(value, "capabilities")) |raw| {
                    const items = switch (raw) {
                        .array => |a| a.items,
                        else => return error.ExpectedArray,
                    };
                    const out = try allocator.alloc([]const u8, items.len);
                    errdefer allocator.free(out);
                    for (items, out) |item, *slot| slot.* = try jsonStr(item);
                    caps = out;
                }
                break :blk .{ .join = .{
                    .peer = try jsonU64(try jsonField(value, "peer")),
                    .capabilities = caps,
                } };
            },
            .offer => .{ .offer = try sdpFromJson(value) },
            .answer => .{ .answer = try sdpFromJson(value) },
            .ice => .{ .ice = .{
                .to = try jsonU64(try jsonField(value, "to")),
                .candidate = try jsonStr(try jsonField(value, "candidate")),
            } },
            .relay => .{ .relay = .{
                .to = try jsonU64(try jsonField(value, "to")),
                .payload = try jsonField(value, "payload"),
            } },
            .leave => .leave,
        };
    }

    fn sdpFromJson(value: std.json.Value) !Sdp {
        return .{
            .to = try jsonU64(try jsonField(value, "to")),
            .sdp = try jsonStr(try jsonField(value, "sdp")),
        };
    }

    /// Free the one owned allocation a decoded client frame can carry.
    pub fn deinitDecoded(self: ClientMessage, allocator: std.mem.Allocator) void {
        switch (self) {
            .join => |j| if (j.capabilities) |caps| allocator.free(caps),
            else => {},
        }
    }

    pub fn jsonStringify(self: ClientMessage, jw: anytype) !void {
        try jw.beginObject();
        // One spelling, shared with `fromJson` through `ClientTag.wireName`.
        try jw.objectField("type");
        try jw.write(std.meta.activeTag(self).wireName());
        switch (self) {
            .join => |j| {
                try jw.objectField("peer");
                try jw.write(j.peer);
                if (j.capabilities) |caps| {
                    try jw.objectField("capabilities");
                    try jw.write(caps);
                }
            },
            .offer, .answer => |s| {
                try jw.objectField("to");
                try jw.write(s.to);
                try jw.objectField("sdp");
                try jw.write(s.sdp);
            },
            .ice => |i| {
                try jw.objectField("to");
                try jw.write(i.to);
                try jw.objectField("candidate");
                try jw.write(i.candidate);
            },
            .relay => |r| {
                try jw.objectField("to");
                try jw.write(r.to);
                try jw.objectField("payload");
                try jw.write(r.payload);
            },
            .leave => {},
        }
        try jw.endObject();
    }
};

/// The server-frame discriminator. Three variants are spelled differently on
/// the wire than in Zig (`peer-joined`, `peer-left`, `error`), which is exactly
/// why the mapping is a table on the tag enum rather than a string literal in
/// the encoder and a second one in the decoder.
pub const ServerTag = enum {
    welcome,
    peer_joined,
    peer_left,
    offer,
    answer,
    ice,
    relay,
    error_msg,

    /// The stable wire spelling — kebab-case, and `error_msg` goes out as the
    /// bare `"error"` (`error` is a Zig keyword, so the union field cannot be).
    pub fn wireName(self: ServerTag) []const u8 {
        return switch (self) {
            .peer_joined => "peer-joined",
            .peer_left => "peer-left",
            .error_msg => "error",
            else => @tagName(self),
        };
    }

    /// Parse a wire `type` field. Anything unrecognized is an error — never a
    /// silent default, which is how a renamed variant becomes a dropped frame.
    pub fn fromWireName(name: []const u8) error{UnknownServerTag}!ServerTag {
        // Derived from the same `wireName` table the encoder uses, over the
        // enum's own tag list — the two halves cannot drift apart, and a
        // variant added to the union appears here without being retyped.
        inline for (comptime std.meta.tags(ServerTag)) |tag| {
            if (std.mem.eql(u8, name, tag.wireName())) return tag;
        }
        return error.UnknownServerTag;
    }
};

pub const ServerMessage = union(ServerTag) {
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

    /// Decode a canonical server frame. String fields and the relay payload
    /// BORROW `value`; `welcome.peers` is the one allocation and is owned by
    /// the caller (see `deinitDecoded`).
    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !ServerMessage {
        return switch (try ServerTag.fromWireName(try jsonStr(try jsonField(value, "type")))) {
            .welcome => blk: {
                const items = switch (try jsonField(value, "peers")) {
                    .array => |a| a.items,
                    else => return error.ExpectedArray,
                };
                const peers = try allocator.alloc(ipc.PeerId, items.len);
                errdefer allocator.free(peers);
                for (items, peers) |item, *slot| slot.* = try jsonU64(item);
                break :blk .{ .welcome = .{
                    .peer = try jsonU64(try jsonField(value, "peer")),
                    .peers = peers,
                } };
            },
            .peer_joined => .{ .peer_joined = .{ .peer = try jsonU64(try jsonField(value, "peer")) } },
            .peer_left => .{ .peer_left = .{ .peer = try jsonU64(try jsonField(value, "peer")) } },
            .offer => .{ .offer = try fromSdpFromJson(value) },
            .answer => .{ .answer = try fromSdpFromJson(value) },
            .ice => .{ .ice = .{
                .from = try jsonU64(try jsonField(value, "from")),
                .candidate = try jsonStr(try jsonField(value, "candidate")),
            } },
            .relay => .{ .relay = .{
                .from = try jsonU64(try jsonField(value, "from")),
                .payload = try jsonField(value, "payload"),
            } },
            .error_msg => .{ .error_msg = .{
                .code = try jsonStr(try jsonField(value, "code")),
                .message = try jsonStr(try jsonField(value, "message")),
            } },
        };
    }

    fn fromSdpFromJson(value: std.json.Value) !FromSdp {
        return .{
            .from = try jsonU64(try jsonField(value, "from")),
            .sdp = try jsonStr(try jsonField(value, "sdp")),
        };
    }

    /// Free the one owned allocation a decoded server frame can carry.
    pub fn deinitDecoded(self: ServerMessage, allocator: std.mem.Allocator) void {
        switch (self) {
            .welcome => |w| allocator.free(w.peers),
            else => {},
        }
    }

    pub fn jsonStringify(self: ServerMessage, jw: anytype) !void {
        try jw.beginObject();
        // One spelling, shared with `fromJson` through `ServerTag.wireName`.
        try jw.objectField("type");
        try jw.write(std.meta.activeTag(self).wireName());
        switch (self) {
            .welcome => |m| {
                try jw.objectField("peer");
                try jw.write(m.peer);
                try jw.objectField("peers");
                try jw.write(m.peers);
            },
            .peer_joined, .peer_left => |m| {
                try jw.objectField("peer");
                try jw.write(m.peer);
            },
            .offer, .answer => |m| {
                try jw.objectField("from");
                try jw.write(m.from);
                try jw.objectField("sdp");
                try jw.write(m.sdp);
            },
            .ice => |m| {
                try jw.objectField("from");
                try jw.write(m.from);
                try jw.objectField("candidate");
                try jw.write(m.candidate);
            },
            .relay => |m| {
                try jw.objectField("from");
                try jw.write(m.from);
                try jw.objectField("payload");
                try jw.write(m.payload);
            },
            .error_msg => |m| {
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

    /// Every joined `(peer, conn)` pair in ASCENDING peer order, excluding
    /// `exclude_peer`. Ordering is part of the wire contract — the canonical
    /// `anti_spoof_session.json` asserts `roster_sorted_ascending`, and a
    /// broadcast whose recipient order came from hash-map iteration is not
    /// reproducible across runs, let alone across bindings. Caller frees.
    fn joinedSorted(self: *const SignalingRoom, exclude_peer: ?ipc.PeerId) ![]Member {
        var members = std.ArrayList(Member).empty;
        errdefer members.deinit(self.allocator);
        var iter = self.roster.iterator();
        while (iter.next()) |entry| {
            if (exclude_peer) |ex| {
                if (entry.value_ptr.* == ex) continue;
            }
            try members.append(self.allocator, .{ .peer = entry.value_ptr.*, .conn = entry.key_ptr.* });
        }
        std.mem.sort(Member, members.items, {}, Member.lessThan);
        return members.toOwnedSlice(self.allocator);
    }

    pub const Member = struct {
        peer: ipc.PeerId,
        conn: u64,

        fn lessThan(_: void, a: Member, b: Member) bool {
            return a.peer < b.peer;
        }
    };

    /// Apply an inbound client frame from `from_conn`, appending any directed
    /// outbound server frames to `out`. `from_conn` MUST be a registered joiner
    /// for offer/answer/ice/relay/leave.
    ///
    /// Outbound frames own two allocations — `welcome.peers` and an
    /// `error_msg.message` — both released by `freeOutbound`.
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
                // welcome: currently-joined peers, ascending, excluding self.
                const others = try self.joinedSorted(j.peer);
                defer self.allocator.free(others);
                const peers = try self.allocator.alloc(ipc.PeerId, others.len);
                errdefer self.allocator.free(peers);
                for (others, peers) |m, *slot| slot.* = m.peer;
                try out.append(self.allocator, .{
                    .to_conn = from_conn,
                    .frame = .{ .welcome = .{ .peer = j.peer, .peers = peers } },
                });
                // broadcast peer-joined to everyone else, in the same order.
                for (others) |m| {
                    try out.append(self.allocator, .{
                        .to_conn = m.conn,
                        .frame = .{ .peer_joined = .{ .peer = j.peer } },
                    });
                }
            },
            .leave => {
                if (self.roster.fetchRemove(from_conn)) |kv| {
                    _ = self.conn_of_peer.remove(kv.value);
                    // broadcast peer-left.
                    const remaining = try self.joinedSorted(null);
                    defer self.allocator.free(remaining);
                    for (remaining) |m| {
                        try out.append(self.allocator, .{
                            .to_conn = m.conn,
                            .frame = .{ .peer_left = .{ .peer = kv.value } },
                        });
                    }
                }
            },
            .offer, .answer, .ice, .relay => {
                const sender = self.roster.get(from_conn) orelse {
                    try out.append(self.allocator, .{
                        .to_conn = from_conn,
                        .frame = .{ .error_msg = .{
                            .code = "not_joined",
                            .message = try self.allocator.dupe(u8, "sender has not joined"),
                        } },
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
                        // Canonical wording, pinned by `anti_spoof_session.json`
                        // and `frames.json`: naming the peer is what makes the
                        // error actionable on the client.
                        .frame = .{ .error_msg = .{
                            .code = "unknown_target",
                            .message = try std.fmt.allocPrint(
                                self.allocator,
                                "peer {d} is not in this session",
                                .{target_peer},
                            ),
                        } },
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

/// Free any owned allocations in an Outbound list (the `welcome.peers` slice
/// and an `error_msg.message`), then clear the list.
pub fn freeOutbound(allocator: std.mem.Allocator, out: *std.ArrayList(SignalingRoom.Outbound)) void {
    for (out.items) |o| {
        switch (o.frame) {
            .welcome => |w| allocator.free(w.peers),
            .error_msg => |e| allocator.free(e.message),
            else => {},
        }
    }
    out.clearRetainingCapacity();
}

// ---------------------------------------------------------------------------
// Tests. The wire shapes and the routing transcript are now replayed from the
// canonical corpus in `signaling_conformance.zig` — the inline mirrors that
// used to live here asserted values typed into this file, so upstream could
// change `frames.json` / `anti_spoof_session.json` and they stayed green.
// What remains here is the behaviour the corpus does NOT pin.
// ---------------------------------------------------------------------------

test "lazily/signaling: a frame from an unjoined connection is rejected, not routed" {
    const allocator = std.testing.allocator;
    var room = SignalingRoom.init(allocator);
    defer room.deinit();

    var out = std.ArrayList(SignalingRoom.Outbound).empty;
    defer {
        freeOutbound(allocator, &out);
        out.deinit(allocator);
    }

    try room.apply(&out, 100, .{ .join = .{ .peer = 1 } });
    freeOutbound(allocator, &out);

    // conn 999 never joined: it cannot be given a server-registered `from`, so
    // the frame must not be forwarded at all.
    try room.apply(&out, 999, .{ .offer = .{ .to = 1, .sdp = "x" } });
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(u64, 999), out.items[0].to_conn);
    try std.testing.expect(out.items[0].frame == .error_msg);
    try std.testing.expectEqualStrings("not_joined", out.items[0].frame.error_msg.code);
}

test "lazily/signaling: the welcome roster is sorted ascending regardless of join order" {
    const allocator = std.testing.allocator;
    var room = SignalingRoom.init(allocator);
    defer room.deinit();

    var out = std.ArrayList(SignalingRoom.Outbound).empty;
    defer {
        freeOutbound(allocator, &out);
        out.deinit(allocator);
    }

    // Join descending so hash-map iteration order cannot accidentally pass.
    for ([_]ipc.PeerId{ 9, 3, 7, 1 }) |peer| {
        try room.apply(&out, 100 + peer, .{ .join = .{ .peer = peer } });
    }
    freeOutbound(allocator, &out);

    try room.apply(&out, 500, .{ .join = .{ .peer = 5 } });
    try std.testing.expect(out.items[0].frame == .welcome);
    try std.testing.expectEqualSlices(
        ipc.PeerId,
        &[_]ipc.PeerId{ 1, 3, 7, 9 },
        out.items[0].frame.welcome.peers,
    );
}

test "lazily/signaling: decode is the inverse of encode for a relay payload" {
    // `relay.payload` is an opaque `std.json.Value` passthrough — the one field
    // whose round-trip is not covered by a scalar comparison.
    const allocator = std.testing.allocator;
    const wire =
        \\{"type":"relay","to":2,"payload":{"type":"delta","base_epoch":0,"epoch":1,"ops":[]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, wire, .{});
    defer parsed.deinit();

    const msg = try ClientMessage.fromJson(allocator, parsed.value);
    defer msg.deinitDecoded(allocator);
    try std.testing.expectEqual(@as(ipc.PeerId, 2), msg.relay.to);

    const encoded = try msg.encodeJsonAlloc(allocator);
    defer allocator.free(encoded);
    try std.testing.expectEqualStrings(wire, encoded);
}
