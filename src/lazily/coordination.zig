//! Distributed coordination primitives (`#lzcoord`) — the Zig port of lazily-rs
//! `src/coordination.rs` (see `lazily-spec/docs/coordination.md` and the formal
//! model `lazily-formal/LazilyFormal/Coordination.lean`).
//!
//! Lease / leader / lock / semaphore / barrier + quorum primitives, each a pure
//! compute **core** (a side-effect-free state machine over integers / peer ids)
//! split from a thin reactive **cell** that projects the salient reader. Time is
//! a **logical clock**: a runtime drives the cores by feeding a monotone
//! `now: u64` tick; `expiry` is a tick value the runtime owns. Peer ids are `u64`.
//!
//! Reactive-cell model (matching `temporal.zig`): each cell owns a per-reader
//! logical version counter that is bumped **only when the projected reader value
//! provably changes** — the edge-only invalidation contract (the Zig analogue of
//! the rs `Cell<T>` `PartialEq` store-guard). A conformance test diffs the
//! version snapshot across a step to assert the fixture's `invalidates` matrix.

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("context.zig").Context;

// ===========================================================================
// Lease + fencing token
// ===========================================================================

/// Single-writer lease authority with a monotone fencing token. The fence is
/// monotone and does NOT reset on expiry.
pub const LeaseCore = struct {
    holder: ?u64 = null,
    expiry: u64 = 0,
    fence: u64 = 0,

    pub fn init() LeaseCore {
        return .{};
    }

    fn isExpired(self: *const LeaseCore, now: u64) bool {
        return self.holder != null and now >= self.expiry;
    }

    /// Whether the lease is currently held (and not expired at `now`).
    pub fn isHeld(self: *const LeaseCore, now: u64) bool {
        return self.holder != null and !self.isExpired(now);
    }

    /// The live holder at `now`, or `null` when free/expired.
    pub fn holderAt(self: *const LeaseCore, now: u64) ?u64 {
        return if (self.isHeld(now)) self.holder else null;
    }

    pub fn fenceValue(self: *const LeaseCore) u64 {
        return self.fence;
    }

    /// Grant if free/expired (a new grant increments `fence`); a renew by the
    /// holder keeps the same fence; held by another → `null`.
    pub fn acquire(self: *LeaseCore, peer: u64, now: u64, ttl: u64) ?u64 {
        const free = self.holder == null or self.isExpired(now);
        if (free) {
            self.fence += 1;
            self.holder = peer;
            self.expiry = now + ttl;
            return self.fence;
        }
        if (self.holder.? == peer) {
            self.expiry = now + ttl; // renew keeps fence
            return self.fence;
        }
        return null;
    }

    /// Extend the expiry if `peer` is the live holder.
    pub fn renew(self: *LeaseCore, peer: u64, now: u64, ttl: u64) bool {
        if (self.isHeld(now) and self.holder.? == peer) {
            self.expiry = now + ttl;
            return true;
        }
        return false;
    }

    /// Drop the grant if `peer` holds it.
    pub fn release(self: *LeaseCore, peer: u64) void {
        if (self.holder != null and self.holder.? == peer) {
            self.holder = null;
        }
    }

    /// Expire the grant when `now >= expiry`; returns the expiry edge.
    pub fn tick(self: *LeaseCore, now: u64) bool {
        if (self.isExpired(now)) {
            self.holder = null;
            return true;
        }
        return false;
    }
};

/// Reactive lease: projects the live `holder` (`?u64`); invalidates only when
/// the holder changes.
pub const LeaseCell = struct {
    ctx: *Context,
    core: LeaseCore = LeaseCore.init(),
    stored_holder: ?u64 = null,
    holder_version: u64 = 0,

    pub fn init(ctx: *Context) LeaseCell {
        return .{ .ctx = ctx };
    }

    fn refresh(self: *LeaseCell, now: u64) void {
        const h = self.core.holderAt(now);
        if (h != self.stored_holder) {
            self.stored_holder = h;
            self.holder_version += 1;
        }
    }

    pub fn acquire(self: *LeaseCell, peer: u64, now: u64, ttl: u64) ?u64 {
        const r = self.core.acquire(peer, now, ttl);
        self.refresh(now);
        return r;
    }

    pub fn renew(self: *LeaseCell, peer: u64, now: u64, ttl: u64) bool {
        const r = self.core.renew(peer, now, ttl);
        self.refresh(now);
        return r;
    }

    pub fn release(self: *LeaseCell, peer: u64, now: u64) void {
        self.core.release(peer);
        self.refresh(now);
    }

    pub fn tick(self: *LeaseCell, now: u64) bool {
        const r = self.core.tick(now);
        self.refresh(now);
        return r;
    }

    pub fn holderAt(self: *const LeaseCell, now: u64) ?u64 {
        return self.core.holderAt(now);
    }
    pub fn isHeld(self: *const LeaseCell, now: u64) bool {
        return self.core.isHeld(now);
    }
    pub fn fenceValue(self: *const LeaseCell) u64 {
        return self.core.fenceValue();
    }
    pub fn holderVersion(self: *const LeaseCell) u64 {
        return self.holder_version;
    }
};

// ===========================================================================
// Leader / follower / candidate
// ===========================================================================

/// The local node's role, derived from lease ownership.
pub const LeaderRole = enum { Leader, Follower, Candidate };

pub fn leaderRoleName(role: LeaderRole) []const u8 {
    return switch (role) {
        .Leader => "Leader",
        .Follower => "Follower",
        .Candidate => "Candidate",
    };
}

/// Reactive leadership over a lease from node `me`'s perspective. Projects
/// `current_leader` (`?u64`); invalidates on re-election.
pub const LeaderCell = struct {
    ctx: *Context,
    core: LeaseCore = LeaseCore.init(),
    me: u64,
    stored_leader: ?u64 = null,
    leader_version: u64 = 0,

    pub fn init(ctx: *Context, me: u64) LeaderCell {
        return .{ .ctx = ctx, .me = me };
    }

    fn refresh(self: *LeaderCell, now: u64) void {
        const l = self.core.holderAt(now);
        if (l != self.stored_leader) {
            self.stored_leader = l;
            self.leader_version += 1;
        }
    }

    /// Try to acquire leadership for `me`.
    pub fn campaign(self: *LeaderCell, now: u64, ttl: u64) LeaderRole {
        _ = self.core.acquire(self.me, now, ttl);
        self.refresh(now);
        return self.role(now);
    }

    /// Simulate another peer contending (for tests / co-hosted nodes).
    pub fn contend(self: *LeaderCell, peer: u64, now: u64, ttl: u64) LeaderRole {
        _ = self.core.acquire(peer, now, ttl);
        self.refresh(now);
        return self.role(now);
    }

    pub fn tick(self: *LeaderCell, now: u64) LeaderRole {
        _ = self.core.tick(now);
        self.refresh(now);
        return self.role(now);
    }

    pub fn currentLeader(self: *const LeaderCell, now: u64) ?u64 {
        return self.core.holderAt(now);
    }

    pub fn role(self: *const LeaderCell, now: u64) LeaderRole {
        if (self.core.holderAt(now)) |h| {
            return if (h == self.me) .Leader else .Follower;
        }
        return .Candidate;
    }

    pub fn leaderVersion(self: *const LeaderCell) u64 {
        return self.leader_version;
    }
};

// ===========================================================================
// Distributed lock + fencing
// ===========================================================================

/// Reactive distributed mutex over a lease + fencing token. Projects
/// `is_locked` (`bool`); invalidates only when the lock state flips.
pub const LockCell = struct {
    ctx: *Context,
    core: LeaseCore = LeaseCore.init(),
    stored_locked: bool = false,
    locked_version: u64 = 0,

    pub fn init(ctx: *Context) LockCell {
        return .{ .ctx = ctx };
    }

    fn refresh(self: *LockCell, now: u64) void {
        const held = self.core.isHeld(now);
        if (held != self.stored_locked) {
            self.stored_locked = held;
            self.locked_version += 1;
        }
    }

    /// Acquire the lock, returning a fencing token, or `null` if held.
    pub fn acquire(self: *LockCell, peer: u64, now: u64, ttl: u64) ?u64 {
        const r = self.core.acquire(peer, now, ttl);
        self.refresh(now);
        return r;
    }

    pub fn release(self: *LockCell, peer: u64, now: u64) void {
        self.core.release(peer);
        self.refresh(now);
    }

    pub fn tick(self: *LockCell, now: u64) bool {
        const r = self.core.tick(now);
        self.refresh(now);
        return r;
    }

    /// Whether `fence` is the current (non-stale) fencing token.
    pub fn validate(self: *const LockCell, fence: u64) bool {
        return self.core.fenceValue() == fence;
    }

    pub fn isLocked(self: *const LockCell, now: u64) bool {
        return self.core.isHeld(now);
    }
    pub fn fenceValue(self: *const LockCell) u64 {
        return self.core.fenceValue();
    }
    pub fn lockedVersion(self: *const LockCell) u64 {
        return self.locked_version;
    }
};

// ===========================================================================
// Semaphore
// ===========================================================================

/// Bounded permit pool compute core.
pub const SemaphoreCore = struct {
    capacity: u64,
    acquired: u64 = 0,

    pub fn init(capacity: u64) SemaphoreCore {
        return .{ .capacity = capacity };
    }
    pub fn available(self: *const SemaphoreCore) u64 {
        return self.capacity - self.acquired;
    }
    pub fn acquire(self: *SemaphoreCore) bool {
        if (self.acquired < self.capacity) {
            self.acquired += 1;
            return true;
        }
        return false;
    }
    pub fn release(self: *SemaphoreCore) void {
        if (self.acquired > 0) {
            self.acquired -= 1;
        }
    }
};

/// Reactive semaphore: projects `permits_available` (`u64`); invalidates only
/// when it changes.
pub const SemaphoreCell = struct {
    ctx: *Context,
    core: SemaphoreCore,
    stored_available: u64,
    available_version: u64 = 0,

    pub fn init(ctx: *Context, capacity: u64) SemaphoreCell {
        return .{
            .ctx = ctx,
            .core = SemaphoreCore.init(capacity),
            .stored_available = capacity,
        };
    }

    fn refresh(self: *SemaphoreCell) void {
        const a = self.core.available();
        if (a != self.stored_available) {
            self.stored_available = a;
            self.available_version += 1;
        }
    }

    pub fn acquire(self: *SemaphoreCell) bool {
        const r = self.core.acquire();
        self.refresh();
        return r;
    }

    pub fn release(self: *SemaphoreCell) void {
        self.core.release();
        self.refresh();
    }

    pub fn permitsAvailable(self: *const SemaphoreCell) u64 {
        return self.core.available();
    }
    pub fn permitsVersion(self: *const SemaphoreCell) u64 {
        return self.available_version;
    }
};

// ===========================================================================
// Barrier / quorum
// ===========================================================================

/// Wait-for-N gate compute core over distinct arriving peers.
pub const BarrierCore = struct {
    required: u64,
    arrived: std.AutoHashMap(u64, void),

    pub fn init(allocator: std.mem.Allocator, required: u64) BarrierCore {
        return .{
            .required = required,
            .arrived = std.AutoHashMap(u64, void).init(allocator),
        };
    }
    pub fn deinit(self: *BarrierCore) void {
        self.arrived.deinit();
    }
    /// Register a distinct arrival; returns whether the gate is open afterward.
    pub fn arrive(self: *BarrierCore, peer: u64) !bool {
        try self.arrived.put(peer, {});
        return self.isOpen();
    }
    pub fn count(self: *const BarrierCore) u64 {
        return @as(u64, self.arrived.count());
    }
    pub fn isOpen(self: *const BarrierCore) bool {
        return self.count() >= self.required;
    }
};

/// Reactive wait-for-N gate. Projects `is_open` (`bool`); invalidates only when
/// it flips. A `QuorumCell` is a barrier with `required = total / 2 + 1`.
pub const BarrierCell = struct {
    ctx: *Context,
    core: BarrierCore,
    stored_open: bool,
    open_version: u64 = 0,

    pub fn init(ctx: *Context, allocator: std.mem.Allocator, required: u64) BarrierCell {
        var core = BarrierCore.init(allocator, required);
        const open = core.isOpen();
        return .{ .ctx = ctx, .core = core, .stored_open = open };
    }

    /// A quorum gate: opens at strict majority of `total`.
    pub fn quorum(ctx: *Context, allocator: std.mem.Allocator, total: u64) BarrierCell {
        return BarrierCell.init(ctx, allocator, total / 2 + 1);
    }

    pub fn deinit(self: *BarrierCell) void {
        self.core.deinit();
    }

    fn refresh(self: *BarrierCell) void {
        const o = self.core.isOpen();
        if (o != self.stored_open) {
            self.stored_open = o;
            self.open_version += 1;
        }
    }

    /// Register an arrival / vote; returns whether the gate is open afterward.
    pub fn arrive(self: *BarrierCell, peer: u64) !bool {
        const r = try self.core.arrive(peer);
        self.refresh();
        return r;
    }

    pub fn count(self: *const BarrierCell) u64 {
        return self.core.count();
    }
    pub fn isOpen(self: *const BarrierCell) bool {
        return self.core.isOpen();
    }
    pub fn openVersion(self: *const BarrierCell) u64 {
        return self.open_version;
    }
};

// ===========================================================================
// Unit tests (pure cores)
// ===========================================================================

test "coordination: lease fence monotone, renew keeps fence" {
    var l = LeaseCore.init();
    try std.testing.expectEqual(@as(?u64, 1), l.acquire(1, 0, 10));
    try std.testing.expectEqual(@as(?u64, null), l.acquire(2, 1, 10)); // held
    try std.testing.expect(l.renew(1, 5, 10));
    try std.testing.expectEqual(@as(u64, 1), l.fenceValue()); // renew keeps fence
    try std.testing.expect(l.tick(15)); // expired
    try std.testing.expectEqual(@as(?u64, 2), l.acquire(2, 16, 10)); // new grant increments
}

test "coordination: semaphore bounded ops" {
    var s = SemaphoreCore.init(2);
    try std.testing.expect(s.acquire());
    try std.testing.expect(s.acquire());
    try std.testing.expect(!s.acquire()); // full
    try std.testing.expectEqual(@as(u64, 0), s.available());
    s.release();
    try std.testing.expectEqual(@as(u64, 1), s.available());
}

test "coordination: quorum opens at majority" {
    var b = BarrierCore.init(std.testing.allocator, 5 / 2 + 1); // 3
    defer b.deinit();
    try std.testing.expect(!(try b.arrive(1)));
    try std.testing.expect(!(try b.arrive(2)));
    try std.testing.expect(try b.arrive(3)); // majority
    try std.testing.expect(try b.arrive(1)); // idempotent, still open
    try std.testing.expectEqual(@as(u64, 3), b.count());
}

// ===========================================================================
// lazily-spec conformance fixture replay
// `../lazily-spec/conformance/coordination/*.json` (mirrors lazily-rs
// `tests/coordination_conformance.rs`).
// ===========================================================================

const json = std.json;
const SPEC_DIR = "../lazily-spec/conformance/coordination";

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
    const raw = readFixtureFile(SPEC_DIR ++ "/lease.json") catch return false;
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
/// `?u64` from a JSON field that may be null / absent.
fn optU64(value: json.Value) !?u64 {
    return switch (value) {
        .null => null,
        else => try jsonAsU64(value),
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

/// The fixture's `invalidates[reader]` flag for a step.
fn invalidates(step: json.Value, reader: []const u8) !bool {
    const exp = try jsonFieldRequired(step, "expected");
    const inv = try jsonFieldRequired(exp, "invalidates");
    return jsonAsBool(try jsonFieldRequired(inv, reader));
}

fn opType(step: json.Value) ![]const u8 {
    return jsonAsString(try jsonFieldRequired(try jsonFieldRequired(step, "op"), "type"));
}
fn opField(step: json.Value, name: []const u8) !json.Value {
    return jsonFieldRequired(try jsonFieldRequired(step, "op"), name);
}

test "coordination conformance: lease" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("lease.json");
    defer parsed.deinit();
    const fx = parsed.value;

    var cell = LeaseCell.init(ctx);

    for (try steps(fx)) |step| {
        const ty = try opType(step);
        const now = try jsonAsU64(try opField(step, "now"));
        const pre = cell.holderVersion();

        if (std.mem.eql(u8, ty, "acquire")) {
            const peer = try jsonAsU64(try opField(step, "peer"));
            const ttl = try jsonAsU64(try opField(step, "ttl"));
            const r = cell.acquire(peer, now, ttl);
            try std.testing.expectEqual(try optU64(try jsonFieldRequired(step, "returns")), r);
        } else if (std.mem.eql(u8, ty, "renew")) {
            const peer = try jsonAsU64(try opField(step, "peer"));
            const ttl = try jsonAsU64(try opField(step, "ttl"));
            const r = cell.renew(peer, now, ttl);
            try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(step, "returns")), r);
        } else if (std.mem.eql(u8, ty, "tick")) {
            const r = cell.tick(now);
            try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(step, "returns")), r);
        } else return error.UnknownOp;

        const exp = try jsonFieldRequired(step, "expected");
        try std.testing.expectEqual(try optU64(try jsonFieldRequired(exp, "holder")), cell.holderAt(now));
        try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(exp, "held")), cell.isHeld(now));
        try std.testing.expectEqual(try jsonAsU64(try jsonFieldRequired(exp, "fence")), cell.fenceValue());
        try std.testing.expectEqual(try invalidates(step, "holder"), cell.holderVersion() != pre);
    }
}

test "coordination conformance: leader" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("leader.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const me = try jsonAsU64(try jsonFieldRequired(try jsonFieldRequired(fx, "config"), "me"));
    var cell = LeaderCell.init(ctx, me);

    for (try steps(fx)) |step| {
        const ty = try opType(step);
        const now = try jsonAsU64(try opField(step, "now"));
        const pre = cell.leaderVersion();

        if (std.mem.eql(u8, ty, "campaign")) {
            const ttl = try jsonAsU64(try opField(step, "ttl"));
            _ = cell.campaign(now, ttl);
        } else if (std.mem.eql(u8, ty, "contend")) {
            const peer = try jsonAsU64(try opField(step, "peer"));
            const ttl = try jsonAsU64(try opField(step, "ttl"));
            _ = cell.contend(peer, now, ttl);
        } else if (std.mem.eql(u8, ty, "tick")) {
            _ = cell.tick(now);
        } else return error.UnknownOp;

        const exp = try jsonFieldRequired(step, "expected");
        try std.testing.expectEqualStrings(
            try jsonAsString(try jsonFieldRequired(exp, "role")),
            leaderRoleName(cell.role(now)),
        );
        try std.testing.expectEqual(try optU64(try jsonFieldRequired(exp, "current_leader")), cell.currentLeader(now));
        try std.testing.expectEqual(try invalidates(step, "current_leader"), cell.leaderVersion() != pre);
    }
}

test "coordination conformance: lock" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("lock.json");
    defer parsed.deinit();
    const fx = parsed.value;

    var cell = LockCell.init(ctx);

    for (try steps(fx)) |step| {
        const ty = try opType(step);
        const now = try jsonAsU64(try opField(step, "now"));
        const pre = cell.lockedVersion();

        if (std.mem.eql(u8, ty, "acquire")) {
            const peer = try jsonAsU64(try opField(step, "peer"));
            const ttl = try jsonAsU64(try opField(step, "ttl"));
            const r = cell.acquire(peer, now, ttl);
            try std.testing.expectEqual(try optU64(try jsonFieldRequired(step, "returns")), r);
        } else if (std.mem.eql(u8, ty, "validate")) {
            const fence = try jsonAsU64(try opField(step, "fence"));
            const r = cell.validate(fence);
            try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(step, "returns")), r);
        } else if (std.mem.eql(u8, ty, "tick")) {
            const r = cell.tick(now);
            try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(step, "returns")), r);
        } else return error.UnknownOp;

        const exp = try jsonFieldRequired(step, "expected");
        try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(exp, "is_locked")), cell.isLocked(now));
        try std.testing.expectEqual(try jsonAsU64(try jsonFieldRequired(exp, "fence")), cell.fenceValue());
        try std.testing.expectEqual(try invalidates(step, "is_locked"), cell.lockedVersion() != pre);
    }
}

test "coordination conformance: semaphore" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("semaphore.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const capacity = try jsonAsU64(try jsonFieldRequired(try jsonFieldRequired(fx, "config"), "capacity"));
    var cell = SemaphoreCell.init(ctx, capacity);

    for (try steps(fx)) |step| {
        const ty = try opType(step);
        const pre = cell.permitsVersion();

        if (std.mem.eql(u8, ty, "acquire")) {
            const r = cell.acquire();
            try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(step, "returns")), r);
        } else if (std.mem.eql(u8, ty, "release")) {
            cell.release(); // returns: null
        } else return error.UnknownOp;

        const exp = try jsonFieldRequired(step, "expected");
        try std.testing.expectEqual(try jsonAsU64(try jsonFieldRequired(exp, "permits_available")), cell.permitsAvailable());
        try std.testing.expectEqual(try invalidates(step, "permits_available"), cell.permitsVersion() != pre);
    }
}

test "coordination conformance: quorum" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("quorum.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const total = try jsonAsU64(try jsonFieldRequired(try jsonFieldRequired(fx, "config"), "total"));
    var cell = BarrierCell.quorum(ctx, std.testing.allocator, total);
    defer cell.deinit();

    for (try steps(fx)) |step| {
        const ty = try opType(step);
        const pre = cell.openVersion();

        if (std.mem.eql(u8, ty, "vote")) {
            const peer = try jsonAsU64(try opField(step, "peer"));
            const r = try cell.arrive(peer);
            try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(step, "returns")), r);
        } else return error.UnknownOp;

        const exp = try jsonFieldRequired(step, "expected");
        try std.testing.expectEqual(try jsonAsU64(try jsonFieldRequired(exp, "votes")), cell.count());
        try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(exp, "is_open")), cell.isOpen());
        try std.testing.expectEqual(try invalidates(step, "is_open"), cell.openVersion() != pre);
    }
}
