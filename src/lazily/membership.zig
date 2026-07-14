//! Membership + failure detection (`#lzmemb`) — the Zig port of lazily-rs
//! `src/membership.rs` (see `lazily-spec/docs/membership.md` and the formal
//! model `lazily-formal/LazilyFormal/Membership.lean`).
//!
//! A [`MembershipCell`] is a reactive view of the live peer set, backed by a
//! SWIM-style heartbeat protocol + a **Phi-accrual** failure detector. Per-peer
//! state is `Alive | Suspect | Dead | Left`; the derived `PeerSet` is the set of
//! `Alive` peers.
//!
//! The pure compute **core** ([`MembershipCore`] + [`PhiAccrual`]) is the
//! Phi-accrual math + SWIM state machine over plain integer state; the reactive
//! **cell** projects the alive set so `PeerSet` invalidates only when the set
//! changes. Because the reader is a **set**, invalidation is content-aware: after
//! each op the cell recomputes the sorted alive-id list and bumps a per-reader
//! version counter only when that signature changes (the edge-only invalidation
//! contract — the Zig analogue of the rs `Cell<BTreeSet<P>>` `PartialEq` guard).
//! The peer id type is `u64`.

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("context.zig").Context;

// ===========================================================================
// Peer state + change events
// ===========================================================================

/// Per-peer liveness state (SWIM).
pub const PeerState = enum {
    /// Heartbeats current; a valid CRDT sync target.
    alive,
    /// Phi crossed the threshold; awaiting a refuting heartbeat or the timeout.
    suspect,
    /// Suspect long enough to declare failed.
    dead,
    /// Gracefully departed.
    left,
};

/// A diff event over the membership core.
pub const PeerChangeEvent = union(enum) {
    joined: u64,
    left: u64,
    state_changed: struct { peer: u64, from: PeerState, to: PeerState },
};

/// Tunables for the failure detector + SWIM state machine.
pub const MembershipConfig = struct {
    /// `phi > phi_threshold` marks a peer `Suspect`.
    phi_threshold: f64,
    /// Ticks a peer stays `Suspect` before being declared `Dead`.
    suspect_timeout: u64,
    /// Sliding window size for heartbeat inter-arrival samples.
    max_samples: usize,
    /// Floor on the sample standard deviation (avoids div-by-zero).
    min_std: f64,

    pub fn default() MembershipConfig {
        return .{
            .phi_threshold = 8.0,
            .suspect_timeout = 5,
            .max_samples = 100,
            .min_std = 0.1,
        };
    }
};

// ===========================================================================
// Phi-accrual failure detector
// ===========================================================================

/// Phi-accrual failure detector over a sliding window of heartbeat
/// inter-arrival times. `phi` is bit-portable across bindings via the Akka-style
/// logistic approximation of the normal CDF.
pub const PhiAccrual = struct {
    allocator: std.mem.Allocator,
    window: std.ArrayList(f64),
    max_samples: usize,
    min_std: f64,
    last_heartbeat: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator, max_samples: usize, min_std: f64) PhiAccrual {
        return .{
            .allocator = allocator,
            .window = .empty,
            .max_samples = @max(max_samples, 1),
            .min_std = min_std,
            .last_heartbeat = null,
        };
    }

    pub fn deinit(self: *PhiAccrual) void {
        self.window.deinit(self.allocator);
    }

    /// Record a heartbeat arrival, appending its inter-arrival sample and
    /// popping the front while over `max_samples`.
    pub fn heartbeat(self: *PhiAccrual, now: u64) !void {
        if (self.last_heartbeat) |last| {
            const interval: f64 = @floatFromInt(now -| last); // saturating sub
            try self.window.append(self.allocator, interval);
            while (self.window.items.len > self.max_samples) {
                _ = self.window.orderedRemove(0);
            }
        }
        self.last_heartbeat = now;
    }

    fn mean(self: *const PhiAccrual) f64 {
        const n: f64 = @floatFromInt(self.window.items.len);
        var sum: f64 = 0.0;
        for (self.window.items) |x| sum += x;
        return sum / n;
    }

    fn stddev(self: *const PhiAccrual, m: f64) f64 {
        const n: f64 = @floatFromInt(self.window.items.len);
        var acc: f64 = 0.0;
        for (self.window.items) |x| acc += (x - m) * (x - m);
        return @max(@sqrt(acc / n), self.min_std);
    }

    /// The suspicion level at `now`. `0.0` when there is no estimate yet.
    pub fn phi(self: *const PhiAccrual, now: u64) f64 {
        const last = self.last_heartbeat orelse return 0.0;
        if (self.window.items.len == 0) return 0.0;
        const elapsed: f64 = @floatFromInt(now -| last);
        const m = self.mean();
        const s = self.stddev(m);
        const y = (elapsed - m) / s;
        const e = @exp(-y * (1.5976 + 0.070566 * y * y));
        if (elapsed > m) {
            return -std.math.log10(e / (1.0 + e));
        } else {
            return -std.math.log10(1.0 - 1.0 / (1.0 + e));
        }
    }
};

// ===========================================================================
// Membership compute core (SWIM state machine)
// ===========================================================================

const PeerRecord = struct {
    state: PeerState,
    detector: PhiAccrual,
    suspect_since: ?u64,
};

/// The pure membership compute core: the SWIM state machine over a keyed peer
/// map, driven by heartbeats and a logical clock. Emits [`PeerChangeEvent`]s
/// into a caller-owned list. `std.AutoArrayHashMap` gives deterministic storage;
/// outputs (`aliveInto`, `tick` order) are sorted by peer id.
pub const MembershipCore = struct {
    allocator: std.mem.Allocator,
    config: MembershipConfig,
    peers: std.AutoArrayHashMapUnmanaged(u64, PeerRecord),

    pub fn init(allocator: std.mem.Allocator, config: MembershipConfig) MembershipCore {
        return .{
            .allocator = allocator,
            .config = config,
            .peers = .empty,
        };
    }

    pub fn deinit(self: *MembershipCore) void {
        var it = self.peers.iterator();
        while (it.next()) |entry| entry.value_ptr.detector.deinit();
        self.peers.deinit(self.allocator);
    }

    fn newDetector(self: *const MembershipCore) PhiAccrual {
        return PhiAccrual.init(self.allocator, self.config.max_samples, self.config.min_std);
    }

    /// The current alive peer set (the reactive `PeerSet`), sorted ascending.
    /// Clears and refills `out`.
    pub fn aliveInto(self: *MembershipCore, out: *std.ArrayList(u64)) !void {
        out.clearRetainingCapacity();
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.state == .alive) try out.append(self.allocator, entry.key_ptr.*);
        }
        std.mem.sort(u64, out.items, {}, std.sort.asc(u64));
    }

    /// The state of a known peer.
    pub fn state(self: *MembershipCore, peer: u64) ?PeerState {
        const rec = self.peers.getPtr(peer) orelse return null;
        return rec.state;
    }

    /// Join a peer (or refresh a re-joining one): `Alive` with a fresh detector.
    pub fn join(self: *MembershipCore, peer: u64, now: u64, events: *std.ArrayList(PeerChangeEvent)) !void {
        var detector = self.newDetector();
        errdefer detector.deinit();
        try detector.heartbeat(now);
        if (self.peers.getPtr(peer)) |rec| {
            const prev = rec.state;
            rec.detector.deinit();
            rec.detector = detector;
            rec.state = .alive;
            rec.suspect_since = null;
            if (prev != .alive) {
                try events.append(self.allocator, .{ .state_changed = .{ .peer = peer, .from = prev, .to = .alive } });
            }
        } else {
            try self.peers.put(self.allocator, peer, .{ .state = .alive, .detector = detector, .suspect_since = null });
            try events.append(self.allocator, .{ .joined = peer });
        }
    }

    /// Record a heartbeat. An unknown peer is a join; a `Suspect`/`Dead` peer
    /// returns to `Alive` (SWIM refutation).
    pub fn heartbeat(self: *MembershipCore, peer: u64, now: u64, events: *std.ArrayList(PeerChangeEvent)) !void {
        const rec = self.peers.getPtr(peer) orelse return self.join(peer, now, events);
        try rec.detector.heartbeat(now);
        const from = rec.state;
        if (from != .alive and from != .left) {
            rec.state = .alive;
            rec.suspect_since = null;
            try events.append(self.allocator, .{ .state_changed = .{ .peer = peer, .from = from, .to = .alive } });
        }
    }

    /// Graceful departure.
    pub fn leave(self: *MembershipCore, peer: u64, now: u64, events: *std.ArrayList(PeerChangeEvent)) !void {
        _ = now;
        const rec = self.peers.getPtr(peer) orelse return;
        if (rec.state == .left) return;
        rec.state = .left;
        rec.suspect_since = null;
        try events.append(self.allocator, .{ .left = peer });
    }

    /// Advance the clock: escalate `Alive → Suspect` (phi crossed) and
    /// `Suspect → Dead` (timeout elapsed). Processes peers in sorted id order.
    pub fn tick(self: *MembershipCore, now: u64, events: *std.ArrayList(PeerChangeEvent)) !void {
        var keys = std.ArrayList(u64).empty;
        defer keys.deinit(self.allocator);
        var it = self.peers.iterator();
        while (it.next()) |entry| try keys.append(self.allocator, entry.key_ptr.*);
        std.mem.sort(u64, keys.items, {}, std.sort.asc(u64));

        const threshold = self.config.phi_threshold;
        const timeout = self.config.suspect_timeout;
        for (keys.items) |peer| {
            const rec = self.peers.getPtr(peer).?;
            switch (rec.state) {
                .alive => {
                    if (rec.detector.phi(now) > threshold) {
                        rec.state = .suspect;
                        rec.suspect_since = now;
                        try events.append(self.allocator, .{ .state_changed = .{ .peer = peer, .from = .alive, .to = .suspect } });
                    }
                },
                .suspect => {
                    const expired = if (rec.suspect_since) |since| (now -| since) >= timeout else false;
                    if (expired) {
                        rec.state = .dead;
                        try events.append(self.allocator, .{ .state_changed = .{ .peer = peer, .from = .suspect, .to = .dead } });
                    }
                },
                .dead, .left => {},
            }
        }
    }
};

// ===========================================================================
// Reactive membership cell
// ===========================================================================

/// Reactive membership: drives a [`MembershipCore`] and projects the alive set
/// so the `PeerSet` reader (`peerSetVersion`) invalidates only on a set change.
/// The stored signature `prev_alive` is the sorted alive-id list; it is owned
/// and freed on `deinit`.
pub const MembershipCell = struct {
    ctx: *Context,
    core: MembershipCore,
    prev_alive: std.ArrayList(u64),
    peer_set_version: u64 = 0,

    pub fn init(ctx: *Context, allocator: std.mem.Allocator, config: MembershipConfig) MembershipCell {
        return .{
            .ctx = ctx,
            .core = MembershipCore.init(allocator, config),
            .prev_alive = .empty,
        };
    }

    pub fn deinit(self: *MembershipCell) void {
        self.core.deinit();
        self.prev_alive.deinit(self.core.allocator);
    }

    /// Recompute the alive-set signature; bump the version on a content change.
    fn refresh(self: *MembershipCell) !void {
        var current = std.ArrayList(u64).empty;
        defer current.deinit(self.core.allocator);
        try self.core.aliveInto(&current);
        if (!std.mem.eql(u64, current.items, self.prev_alive.items)) {
            self.prev_alive.clearRetainingCapacity();
            try self.prev_alive.appendSlice(self.core.allocator, current.items);
            self.peer_set_version += 1;
        }
    }

    pub fn join(self: *MembershipCell, peer: u64, now: u64) !void {
        var events = std.ArrayList(PeerChangeEvent).empty;
        defer events.deinit(self.core.allocator);
        try self.core.join(peer, now, &events);
        try self.refresh();
    }

    pub fn heartbeat(self: *MembershipCell, peer: u64, now: u64) !void {
        var events = std.ArrayList(PeerChangeEvent).empty;
        defer events.deinit(self.core.allocator);
        try self.core.heartbeat(peer, now, &events);
        try self.refresh();
    }

    pub fn leave(self: *MembershipCell, peer: u64, now: u64) !void {
        var events = std.ArrayList(PeerChangeEvent).empty;
        defer events.deinit(self.core.allocator);
        try self.core.leave(peer, now, &events);
        try self.refresh();
    }

    pub fn tick(self: *MembershipCell, now: u64) !void {
        var events = std.ArrayList(PeerChangeEvent).empty;
        defer events.deinit(self.core.allocator);
        try self.core.tick(now, &events);
        try self.refresh();
    }

    /// The reactive alive peer set (`PeerSet`), sorted ascending into `out`.
    pub fn aliveInto(self: *MembershipCell, out: *std.ArrayList(u64)) !void {
        return self.core.aliveInto(out);
    }

    pub fn state(self: *MembershipCell, peer: u64) ?PeerState {
        return self.core.state(peer);
    }

    /// The per-reader version of the `PeerSet` (bumped only on a set change).
    pub fn peerSetVersion(self: *const MembershipCell) u64 {
        return self.peer_set_version;
    }
};

// ===========================================================================
// Unit tests (pure core + phi detector)
// ===========================================================================

test "membership: phi low at last heartbeat, high after long gap" {
    var d = PhiAccrual.init(std.testing.allocator, 100, 0.1);
    defer d.deinit();
    try d.heartbeat(0);
    try d.heartbeat(1);
    try d.heartbeat(2);
    try d.heartbeat(3);
    try std.testing.expect(d.phi(3) < 8.0); // at the last heartbeat: low
    try std.testing.expect(d.phi(100) > 8.0); // after a long gap: high
}

test "membership: lifecycle join->Alive, tick->Suspect->Dead" {
    var m = MembershipCore.init(std.testing.allocator, MembershipConfig.default());
    defer m.deinit();
    var ev = std.ArrayList(PeerChangeEvent).empty;
    defer ev.deinit(std.testing.allocator);

    try m.join(1, 0, &ev);
    try std.testing.expectEqual(@as(usize, 1), ev.items.len);
    try std.testing.expectEqual(@as(u64, 1), ev.items[0].joined);

    try m.heartbeat(1, 1, &ev);
    try m.heartbeat(1, 2, &ev);
    try m.heartbeat(1, 3, &ev);

    ev.clearRetainingCapacity();
    try m.tick(3, &ev); // still Alive, no change
    try std.testing.expectEqual(@as(usize, 0), ev.items.len);
    try std.testing.expectEqual(PeerState.alive, m.state(1).?);

    ev.clearRetainingCapacity();
    try m.tick(100, &ev); // phi crosses -> Suspect
    try std.testing.expectEqual(PeerState.suspect, m.state(1).?);
    try std.testing.expectEqual(@as(usize, 1), ev.items.len);
    try std.testing.expectEqual(PeerState.alive, ev.items[0].state_changed.from);
    try std.testing.expectEqual(PeerState.suspect, ev.items[0].state_changed.to);

    ev.clearRetainingCapacity();
    try m.tick(106, &ev); // timeout -> Dead
    try std.testing.expectEqual(PeerState.dead, m.state(1).?);
    try std.testing.expectEqual(PeerState.dead, ev.items[0].state_changed.to);

    var alive = std.ArrayList(u64).empty;
    defer alive.deinit(std.testing.allocator);
    try m.aliveInto(&alive);
    try std.testing.expectEqual(@as(usize, 0), alive.items.len);
}

test "membership: heartbeat refutes suspicion" {
    var m = MembershipCore.init(std.testing.allocator, MembershipConfig.default());
    defer m.deinit();
    var ev = std.ArrayList(PeerChangeEvent).empty;
    defer ev.deinit(std.testing.allocator);

    try m.join(1, 0, &ev);
    try m.heartbeat(1, 1, &ev);
    try m.heartbeat(1, 2, &ev);

    ev.clearRetainingCapacity();
    try m.tick(100, &ev); // -> Suspect
    try std.testing.expectEqual(PeerState.suspect, m.state(1).?);

    ev.clearRetainingCapacity();
    try m.heartbeat(1, 101, &ev); // refute -> Alive
    try std.testing.expectEqual(PeerState.alive, m.state(1).?);
    try std.testing.expectEqual(@as(usize, 1), ev.items.len);
    try std.testing.expectEqual(PeerState.suspect, ev.items[0].state_changed.from);
    try std.testing.expectEqual(PeerState.alive, ev.items[0].state_changed.to);
}

// ===========================================================================
// lazily-spec conformance fixture replay
// `../lazily-spec/conformance/membership/*.json` (mirrors lazily-rs
// `tests/membership_conformance.rs`).
// ===========================================================================

const json = std.json;
const SPEC_DIR = "../lazily-spec/conformance/membership";

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

fn specFixturesPresent() bool {
    const raw = readFixtureFile(SPEC_DIR ++ "/membership_lifecycle.json") catch return false;
    std.testing.allocator.free(raw);
    return true;
}

fn jsonField(value: json.Value, name: []const u8) ?json.Value {
    return switch (value) {
        .object => |object| object.get(name),
        else => null,
    };
}
fn jsonFieldRequired(value: json.Value, name: []const u8) !json.Value {
    return jsonField(value, name) orelse error.MissingField;
}
fn jsonAsU64(value: json.Value) !u64 {
    return switch (value) {
        .integer => |n| if (n >= 0) @as(u64, @intCast(n)) else error.ExpectedUnsigned,
        .number_string => |s| try std.fmt.parseInt(u64, s, 10),
        else => error.ExpectedUnsignedInteger,
    };
}
fn jsonAsBool(value: json.Value) !bool {
    return switch (value) {
        .bool => |b| b,
        else => error.ExpectedBool,
    };
}
fn jsonAsString(value: json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}
fn jsonAsF64(value: json.Value) !f64 {
    return switch (value) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        .number_string => |s| try std.fmt.parseFloat(f64, s),
        else => error.ExpectedFloat,
    };
}

fn loadFixture(name: []const u8) !json.Parsed(json.Value) {
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ SPEC_DIR, name });
    defer std.testing.allocator.free(path);
    const raw = try readFixtureFile(path);
    defer std.testing.allocator.free(raw);
    return json.parseFromSlice(json.Value, std.testing.allocator, raw, .{ .allocate = .alloc_always });
}

fn steps(fx: json.Value) ![]const json.Value {
    return switch (try jsonFieldRequired(fx, "steps")) {
        .array => |a| a.items,
        else => error.ExpectedArray,
    };
}

fn peerStateName(s: PeerState) []const u8 {
    return switch (s) {
        .alive => "Alive",
        .suspect => "Suspect",
        .dead => "Dead",
        .left => "Left",
    };
}

test "membership conformance: membership_lifecycle" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("membership_lifecycle.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const cfg_json = try jsonFieldRequired(fx, "config");
    const config = MembershipConfig{
        .phi_threshold = try jsonAsF64(try jsonFieldRequired(cfg_json, "phi_threshold")),
        .suspect_timeout = try jsonAsU64(try jsonFieldRequired(cfg_json, "suspect_timeout")),
        .max_samples = @intCast(try jsonAsU64(try jsonFieldRequired(cfg_json, "max_samples"))),
        .min_std = try jsonAsF64(try jsonFieldRequired(cfg_json, "min_std")),
    };

    var cell = MembershipCell.init(ctx, std.testing.allocator, config);
    defer cell.deinit();

    for (try steps(fx)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const typ = try jsonAsString(try jsonFieldRequired(op, "type"));
        const now = try jsonAsU64(try jsonFieldRequired(op, "now"));
        const pre = cell.peerSetVersion();

        if (std.mem.eql(u8, typ, "join")) {
            try cell.join(try jsonAsU64(try jsonFieldRequired(op, "peer")), now);
        } else if (std.mem.eql(u8, typ, "heartbeat")) {
            try cell.heartbeat(try jsonAsU64(try jsonFieldRequired(op, "peer")), now);
        } else if (std.mem.eql(u8, typ, "leave")) {
            try cell.leave(try jsonAsU64(try jsonFieldRequired(op, "peer")), now);
        } else if (std.mem.eql(u8, typ, "tick")) {
            try cell.tick(now);
        } else {
            return error.UnknownOp;
        }

        const exp = try jsonFieldRequired(step, "expected");

        // Per-peer state assertions.
        const states = try jsonFieldRequired(exp, "states");
        var sit = states.object.iterator();
        while (sit.next()) |kv| {
            const peer_id = try std.fmt.parseInt(u64, kv.key_ptr.*, 10);
            const want = try jsonAsString(kv.value_ptr.*);
            const got = cell.state(peer_id) orelse return error.MissingPeer;
            try std.testing.expectEqualStrings(want, peerStateName(got));
        }

        // Alive-set equality (as a sorted set).
        var alive = std.ArrayList(u64).empty;
        defer alive.deinit(std.testing.allocator);
        try cell.aliveInto(&alive);
        var want_alive = std.ArrayList(u64).empty;
        defer want_alive.deinit(std.testing.allocator);
        for ((try jsonFieldRequired(exp, "alive_set")).array.items) |v| {
            try want_alive.append(std.testing.allocator, try jsonAsU64(v));
        }
        std.mem.sort(u64, want_alive.items, {}, std.sort.asc(u64));
        try std.testing.expect(std.mem.eql(u64, want_alive.items, alive.items));

        // Reader invalidation: scalar bool (not a {reader: bool} map).
        const want_inv = try jsonAsBool(try jsonFieldRequired(exp, "invalidates"));
        try std.testing.expectEqual(want_inv, cell.peerSetVersion() != pre);
    }
}
