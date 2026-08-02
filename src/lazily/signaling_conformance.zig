//! Canonical replays for the two `signaling/*.json` fixtures this binding used
//! to assert with INLINE MIRRORS (`#lazilyzigconformance`).
//!
//! `frames.json` and `anti_spoof_session.json` were "covered" by four tests in
//! `signaling.zig` that compared hand-typed JSON strings and drove the room
//! with hand-written steps. Between them they exercised 3 of the corpus's 17
//! frame variants and none of its `assertions`, and the routing mirror agreed
//! with the transcript on neither the roster ordering nor the error wording —
//! two real defects the mirrors could not see, because they were transcribed
//! from the implementation rather than from the corpus:
//!
//!   1. `welcome.peers` came out of hash-map iteration order, while the fixture
//!      asserts `roster_sorted_ascending`. Every broadcast recipient order had
//!      the same problem, so a multi-peer room was not reproducible run to run.
//!   2. the unknown-target error said "target peer not in room" where the
//!      canonical wording is "peer 99 is not in this session" — a client
//!      matching on the documented message would never have matched.
//!
//! - **frames.json** — every frame is decoded through `ClientMessage.fromJson`
//!   / `ServerMessage.fromJson` (the decode half of the wire contract, which
//!   this binding did not previously implement), its `assertions` are checked
//!   against the decoded value, and re-encoding must reproduce the canonical
//!   bytes exactly.
//! - **anti_spoof_session.json** — the `inputs` are replayed through a real
//!   `SignalingRoom` and every outbound frame must match the transcript, both
//!   in destination connection and in wire shape. The three fixture-level
//!   `assertions` are then checked against what the room actually emitted.

const std = @import("std");
const testing = std.testing;

const cj = @import("conformance_json.zig");
const Value = cj.Value;

const ipc = @import("ipc.zig");
const signaling = @import("signaling.zig");

fn skipAbsent(name: []const u8) void {
    std.debug.print(
        "skipping {s}: {s}/signaling absent - run with the lazily-spec sibling\n",
        .{ name, cj.CONFORMANCE_ROOT },
    );
}

// ---------------------------------------------------------------------------
// frames.json
// ---------------------------------------------------------------------------

/// Assert one `assertions` entry against a decoded frame. Unknown keys are a
/// hard error: a corpus that grew a claim this binding does not check would
/// otherwise keep reporting green while asserting less than it is asked to.
fn checkClientAssertion(msg: signaling.ClientMessage, name: []const u8, want: Value) !void {
    if (std.mem.eql(u8, name, "peer")) {
        return testing.expectEqual(try cj.asU64(want), msg.join.peer);
    }
    if (std.mem.eql(u8, name, "to")) {
        const to = switch (msg) {
            .offer, .answer => |s| s.to,
            .ice => |i| i.to,
            .relay => |r| r.to,
            else => return error.FrameHasNoTarget,
        };
        return testing.expectEqual(try cj.asU64(want), to);
    }
    if (std.mem.eql(u8, name, "has_capabilities")) {
        return testing.expectEqual(try cj.asBool(want), msg.join.capabilities != null);
    }
    if (std.mem.eql(u8, name, "capabilities")) {
        const caps = msg.join.capabilities orelse return error.MissingCapabilities;
        const wanted = try cj.asArray(want);
        try testing.expectEqual(wanted.len, caps.len);
        for (wanted, caps) |w, got| try testing.expectEqualStrings(try cj.asStr(w), got);
        return;
    }
    std.debug.print("unhandled client frame assertion `{s}`\n", .{name});
    return error.UnhandledAssertion;
}

fn checkServerAssertion(msg: signaling.ServerMessage, name: []const u8, want: Value) !void {
    if (std.mem.eql(u8, name, "peer")) {
        const peer = switch (msg) {
            .welcome => |w| w.peer,
            .peer_joined, .peer_left => |p| p.peer,
            else => return error.FrameHasNoPeer,
        };
        return testing.expectEqual(try cj.asU64(want), peer);
    }
    if (std.mem.eql(u8, name, "peers")) {
        const wanted = try cj.asArray(want);
        try testing.expectEqual(wanted.len, msg.welcome.peers.len);
        for (wanted, msg.welcome.peers) |w, got| try testing.expectEqual(try cj.asU64(w), got);
        return;
    }
    if (std.mem.eql(u8, name, "roster_excludes_self")) {
        try testing.expect(try cj.asBool(want));
        for (msg.welcome.peers) |p| try testing.expect(p != msg.welcome.peer);
        return;
    }
    if (std.mem.eql(u8, name, "from") or std.mem.eql(u8, name, "server_stamped_from")) {
        const from = switch (msg) {
            .offer, .answer => |s| s.from,
            .ice => |i| i.from,
            .relay => |r| r.from,
            else => return error.FrameHasNoFrom,
        };
        // `server_stamped_from` is a claim about provenance, which a single
        // frame cannot show; what it pins HERE is that the forwarded shape
        // carries `from` and never `to`. The provenance itself is asserted by
        // the anti_spoof_session replay below, against a live room.
        if (std.mem.eql(u8, name, "from")) return testing.expectEqual(try cj.asU64(want), from);
        try testing.expect(try cj.asBool(want));
        return;
    }
    if (std.mem.eql(u8, name, "code")) {
        return testing.expectEqualStrings(try cj.asStr(want), msg.error_msg.code);
    }
    std.debug.print("unhandled server frame assertion `{s}`\n", .{name});
    return error.UnhandledAssertion;
}

test "signaling conformance: frames.json" {
    const allocator = testing.allocator;
    var parsed = (try cj.load("signaling/frames.json")) orelse {
        skipAbsent("frames.json");
        return;
    };
    defer parsed.deinit();

    const frames = try cj.asArray(try cj.required(parsed.value, "frames"));
    try testing.expect(frames.len > 0);

    var client_frames: usize = 0;
    var server_frames: usize = 0;
    var assertions_checked: usize = 0;

    for (frames) |frame| {
        const label = try cj.asStr(try cj.required(frame, "label"));
        const direction = try cj.asStr(try cj.required(frame, "direction"));
        const variant = try cj.asStr(try cj.required(frame, "variant"));
        const wire = try cj.required(frame, "wire");
        const assertions = try cj.required(frame, "assertions");

        // The wire tag and the fixture's declared variant must agree — the tag
        // table is the only thing standing between a renamed variant and a
        // silently dropped frame.
        try testing.expectEqualStrings(variant, try cj.asStr(try cj.required(wire, "type")));

        var it = switch (assertions) {
            .object => |o| o.iterator(),
            else => return error.ExpectedObject,
        };

        if (std.mem.eql(u8, direction, "client")) {
            const msg = signaling.ClientMessage.fromJson(allocator, wire) catch |err| {
                std.debug.print("frame `{s}` failed to decode: {s}\n", .{ label, @errorName(err) });
                return err;
            };
            defer msg.deinitDecoded(allocator);
            try testing.expectEqualStrings(variant, std.meta.activeTag(msg).wireName());
            while (it.next()) |entry| {
                checkClientAssertion(msg, entry.key_ptr.*, entry.value_ptr.*) catch |err| {
                    std.debug.print("frame `{s}` assertion `{s}` failed\n", .{ label, entry.key_ptr.* });
                    return err;
                };
                assertions_checked += 1;
            }
            var reencoded = try cj.encodeToValue(msg);
            defer reencoded.deinit();
            try cj.expectJsonEql(wire, reencoded.value);
            client_frames += 1;
        } else if (std.mem.eql(u8, direction, "server")) {
            const msg = signaling.ServerMessage.fromJson(allocator, wire) catch |err| {
                std.debug.print("frame `{s}` failed to decode: {s}\n", .{ label, @errorName(err) });
                return err;
            };
            defer msg.deinitDecoded(allocator);
            try testing.expectEqualStrings(variant, std.meta.activeTag(msg).wireName());
            while (it.next()) |entry| {
                checkServerAssertion(msg, entry.key_ptr.*, entry.value_ptr.*) catch |err| {
                    std.debug.print("frame `{s}` assertion `{s}` failed\n", .{ label, entry.key_ptr.* });
                    return err;
                };
                assertions_checked += 1;
            }
            var reencoded = try cj.encodeToValue(msg);
            defer reencoded.deinit();
            try cj.expectJsonEql(wire, reencoded.value);
            server_frames += 1;
        } else {
            return error.UnknownFrameDirection;
        }
    }

    const rejects = try cj.asArray(try cj.required(parsed.value, "rejects"));
    for (rejects) |reject| {
        const direction = try cj.asStr(try cj.required(reject, "direction"));
        const wire = try cj.required(reject, "wire");
        if (std.mem.eql(u8, direction, "client")) {
            if (signaling.ClientMessage.fromJson(allocator, wire)) |message| {
                defer message.deinitDecoded(allocator);
                return error.RejectedClientFrameWasAccepted;
            } else |_| {}
        } else if (std.mem.eql(u8, direction, "server")) {
            if (signaling.ServerMessage.fromJson(allocator, wire)) |message| {
                defer message.deinitDecoded(allocator);
                return error.RejectedServerFrameWasAccepted;
            } else |_| {}
        } else {
            return error.UnknownFrameDirection;
        }
    }

    // Both halves of the protocol must actually have been exercised.
    try testing.expect(client_frames > 0 and server_frames > 0);
    try testing.expect(assertions_checked > 0);
}

// ---------------------------------------------------------------------------
// anti_spoof_session.json
// ---------------------------------------------------------------------------

/// The transcript names connections `"a"`, `"b"`, … — assign each a stable
/// numeric connection id on first sight.
const ConnTable = struct {
    ids: std.StringHashMap(u64),
    next: u64 = 100,

    fn init(allocator: std.mem.Allocator) ConnTable {
        return .{ .ids = std.StringHashMap(u64).init(allocator) };
    }
    fn deinit(self: *ConnTable) void {
        self.ids.deinit();
    }
    fn idOf(self: *ConnTable, name: []const u8) !u64 {
        const gop = try self.ids.getOrPut(name);
        if (!gop.found_existing) {
            gop.value_ptr.* = self.next;
            self.next += 1;
        }
        return gop.value_ptr.*;
    }
};

test "signaling conformance: anti_spoof_session.json" {
    const allocator = testing.allocator;
    var parsed = (try cj.load("signaling/anti_spoof_session.json")) orelse {
        skipAbsent("anti_spoof_session.json");
        return;
    };
    defer parsed.deinit();
    const fixture = parsed.value;

    const steps = try cj.asArray(try cj.required(fixture, "steps"));
    try testing.expect(steps.len > 0);

    var conns = ConnTable.init(allocator);
    defer conns.deinit();

    var room = signaling.SignalingRoom.init(allocator);
    defer room.deinit();

    var out = std.ArrayList(signaling.SignalingRoom.Outbound).empty;
    defer {
        signaling.freeOutbound(allocator, &out);
        out.deinit(allocator);
    }

    // Fixture-level claims, checked against what the room emitted rather than
    // asserted as prose.
    var assertions = cj.AssertionKeys.init(
        "signaling/anti_spoof_session.json assertions",
        try cj.required(fixture, "assertions"),
    );
    // These three used to be read as GATES — `if (want_excludes_self) { ... }`
    // — so flipping any of them to `false` in the corpus deleted the check and
    // the suite stayed green. Now the invariant is observed unconditionally and
    // the fixture's own claim is asserted against what was observed
    // (#lzconsumednotasserted).
    var rosters_seen: usize = 0;
    var forwards_seen: usize = 0;
    var saw_self_in_roster = false;
    var saw_unsorted_roster = false;
    var saw_foreign_from = false;

    for (steps, 0..) |step, si| {
        const input = try cj.required(step, "input");
        const conn_name = try cj.asStr(try cj.required(input, "conn"));
        const conn = try conns.idOf(conn_name);
        const recv = try cj.required(input, "recv");

        // The peer this connection is registered as, sampled BEFORE the step —
        // that is the value a forwarded `from` must carry, and it is server
        // state, not anything the client sent.
        const registered_peer = room.roster.get(conn);

        const msg = try signaling.ClientMessage.fromJson(allocator, recv);
        defer msg.deinitDecoded(allocator);
        // A client frame must never carry `from`: `to`/`from` are never both
        // present, and `from` is the server's to stamp.
        try testing.expect(cj.field(recv, "from") == null);

        signaling.freeOutbound(allocator, &out);
        try room.apply(&out, conn, msg);

        const expect = try cj.asArray(try cj.required(step, "expect"));
        if (expect.len != out.items.len) {
            std.debug.print(
                "step {d} ({s}): room emitted {d} frame(s), transcript expects {d}\n",
                .{ si, conn_name, out.items.len, expect.len },
            );
            return error.OutboundCountMismatch;
        }

        for (expect, out.items, 0..) |want, got, fi| {
            const want_conn = try conns.idOf(try cj.asStr(try cj.required(want, "to")));
            if (want_conn != got.to_conn) {
                std.debug.print(
                    "step {d} frame {d}: delivered to conn {d}, transcript says {s}\n",
                    .{ si, fi, got.to_conn, try cj.asStr(try cj.required(want, "to")) },
                );
                return error.OutboundRoutedToWrongConnection;
            }
            var encoded = try cj.encodeToValue(got.frame);
            defer encoded.deinit();
            cj.expectJsonEql(try cj.required(want, "frame"), encoded.value) catch |err| {
                std.debug.print("step {d} frame {d} diverged\n", .{ si, fi });
                return err;
            };

            switch (got.frame) {
                .welcome => |w| {
                    for (w.peers) |p| {
                        if (p == w.peer) saw_self_in_roster = true;
                    }
                    var prev: ?ipc.PeerId = null;
                    for (w.peers) |p| {
                        if (prev) |q| {
                            if (q >= p) saw_unsorted_roster = true;
                        }
                        prev = p;
                    }
                    rosters_seen += 1;
                },
                .offer, .answer, .ice, .relay => {
                    const from = switch (got.frame) {
                        .offer, .answer => |sig| sig.from,
                        .ice => |i| i.from,
                        .relay => |r| r.from,
                        // The enclosing prong already narrowed the tag, so this
                        // is compiler-narrowed rather than fixture-driven — but
                        // `unreachable` is UNCHECKED undefined behaviour in
                        // ReleaseFast/ReleaseSmall, so a runner must not spell a
                        // refusal that way in any build mode
                        // (#lzscenariobodyskip).
                        else => return error.UnexpectedForwardedFrameVariant,
                    };
                    // The load-bearing invariant: `from` is the SENDER's
                    // server-registered peer id, not anything in `recv`.
                    if (registered_peer == null or registered_peer.? != from) {
                        saw_foreign_from = true;
                    }
                    forwards_seen += 1;
                },
                else => {},
            }
        }
    }

    // The three claims above are only meaningful if the transcript actually
    // produced frames of each kind.
    try testing.expect(rosters_seen > 0);
    try testing.expect(forwards_seen > 0);

    try assertions.assertKey("roster_excludes_self", !saw_self_in_roster);
    try assertions.assertKey("roster_sorted_ascending", !saw_unsorted_roster);
    try assertions.assertKey("forwarded_from_is_server_registered", !saw_foreign_from);
    // The per-frame blocks in `frames.json` already refuse an unrecognised key;
    // this fixture-level block did not (#lzassertunknownkeys).
    try assertions.finish();

    const rejects = try cj.asArray(try cj.required(fixture, "rejects"));
    for (rejects) |reject| {
        const input = try cj.required(reject, "input");
        const recv = try cj.required(input, "recv");
        if (signaling.ClientMessage.fromJson(allocator, recv)) |message| {
            defer message.deinitDecoded(allocator);
            return error.RejectedClientFrameWasAccepted;
        } else |_| {}
    }
}
