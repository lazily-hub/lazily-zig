const std = @import("std");
const ipc = @import("ipc.zig");

/// HLC stamp — re-exports the wire form (`WireStamp`) because the runtime and
/// wire orders are identical: `(wall_time, logical, peer)` lexicographic.
/// Mirrors lazily-rs `HlcStamp` (`crdt.rs:104-114`).
pub const HlcStamp = ipc.WireStamp;
pub const PeerId = ipc.PeerId;

pub const order = HlcStamp.compare;

// ---------------------------------------------------------------------------
// HLC — hybrid logical clock (caller supplies `now_micros`, never reads the
// system clock — deterministic tests). Mirrors lazily-rs `Hlc`
// (`crdt.rs:160-203`).
// ---------------------------------------------------------------------------

pub const Hlc = struct {
    peer: PeerId,
    last_wall: u64 = 0,
    last_logical: u64 = 0,

    pub fn init(peer: PeerId) Hlc {
        return .{ .peer = peer };
    }

    /// Local event: advance the clock and return a fresh stamp.
    pub fn send(self: *Hlc, now_micros: u64) HlcStamp {
        if (now_micros > self.last_wall) {
            self.last_wall = now_micros;
            self.last_logical = 0;
        } else {
            self.last_logical += 1;
        }
        return .{ .wall_time = self.last_wall, .logical = self.last_logical, .peer = self.peer };
    }

    /// Observe a remote stamp: advance the clock past it, then return the
    /// stamp to use for the receiving event.
    pub fn recv(self: *Hlc, remote: HlcStamp, now_micros: u64) HlcStamp {
        const remote_wall = remote.wall_time;
        if (now_micros > remote_wall and now_micros > self.last_wall) {
            self.last_wall = now_micros;
            self.last_logical = 0;
        } else if (remote_wall > self.last_wall) {
            self.last_wall = remote_wall;
            self.last_logical = remote.logical + 1;
        } else if (self.last_wall > remote_wall) {
            self.last_logical += 1;
        } else {
            // equal wall
            const next_logical = @max(self.last_logical, remote.logical) + 1;
            self.last_logical = next_logical;
        }
        return .{ .wall_time = self.last_wall, .logical = self.last_logical, .peer = self.peer };
    }
};

// ---------------------------------------------------------------------------
// Version vector — `peer -> counter`, componentwise-max semilattice.
// Used by MvRegister causal dominance checks.
// ---------------------------------------------------------------------------

pub const VersionVector = struct {
    entries: std.AutoHashMap(u64, u64),

    pub fn init(allocator: std.mem.Allocator) VersionVector {
        return .{ .entries = std.AutoHashMap(u64, u64).init(allocator) };
    }

    pub fn deinit(self: *VersionVector) void {
        self.entries.deinit();
    }

    pub fn clone(self: *const VersionVector, allocator: std.mem.Allocator) !VersionVector {
        var out = VersionVector.init(allocator);
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            try out.entries.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return out;
    }

    pub fn get(self: *const VersionVector, peer: u64) u64 {
        return self.entries.get(peer) orelse 0;
    }

    /// Componentwise-max with `other`. Returns true if any component changed.
    pub fn merge(self: *VersionVector, other: *const VersionVector) !bool {
        var changed = false;
        var iter = other.entries.iterator();
        while (iter.next()) |entry| {
            const peer = entry.key_ptr.*;
            const their_counter = entry.value_ptr.*;
            const our_counter = self.get(peer);
            if (their_counter > our_counter) {
                try self.entries.put(peer, their_counter);
                changed = true;
            }
        }
        return changed;
    }

    /// True if every component of `self` is >= the corresponding component of
    /// `other`. Used by MvRegister to drop dominated concurrent values.
    pub fn dominates(self: *const VersionVector, other: *const VersionVector) bool {
        var iter = other.entries.iterator();
        while (iter.next()) |entry| {
            if (self.get(entry.key_ptr.*) < entry.value_ptr.*) return false;
        }
        return true;
    }

    pub fn equal(self: *const VersionVector, other: *const VersionVector) bool {
        if (self.entries.count() != other.entries.count()) return false;
        var iter = self.entries.iterator();
        while (iter.next()) |entry| {
            if (other.get(entry.key_ptr.*) != entry.value_ptr.*) return false;
        }
        return true;
    }

    /// Bump the writer's component past the floor and componentwise-max the
    /// floor in (MvRegister local-write semantics).
    pub fn bump(self: *VersionVector, peer: u64, floor: *const VersionVector) !void {
        _ = try self.merge(floor);
        const next = self.get(peer) + 1;
        try self.entries.put(peer, next);
    }
};

// ---------------------------------------------------------------------------
// LwwRegister — last-writer-wins by HLC stamp. Mirrors lazily-rs
// `LwwRegister` (`crdt.rs:239-290`). Tiebreak: highest stamp wins; a strictly
// greater stamp replaces the value (>= would let a re-applied equal stamp
/// re-trigger downstream cascades, so the comparison is `>` strictly).
// ---------------------------------------------------------------------------

pub fn LwwRegister(comptime V: type) type {
    return struct {
        const Self = @This();
        pub const MergeMechanism = enum { lww };

        value: V,
        stamp: HlcStamp,

        pub fn init(value: V, stamp: HlcStamp) Self {
            return .{ .value = value, .stamp = stamp };
        }

        /// Replace the value iff `stamp` is strictly greater than the current
        /// stamp. Returns true iff applied.
        pub fn set(self: *Self, value: V, stamp: HlcStamp) bool {
            if (stamp.compare(self.stamp) == .gt) {
                self.value = value;
                self.stamp = stamp;
                return true;
            }
            return false;
        }

        pub fn getStamp(self: *const Self) HlcStamp {
            return self.stamp;
        }

        pub fn mergeFrom(self: *Self, other: *const Self) bool {
            if (other.stamp.compare(self.stamp) == .gt) {
                const changed = !valuesEqual(V, self.value, other.value);
                self.value = other.value;
                self.stamp = other.stamp;
                return changed;
            }
            return false;
        }
    };
}

/// Value equality that handles both scalar types (via std.meta.eql) and slice
/// types (via std.mem.eql). CRDT values are either scalars or borrowed slices
/// owned elsewhere; the registers do not allocate.
fn valuesEqual(comptime V: type, a: V, b: V) bool {
    return switch (@typeInfo(V)) {
        .pointer => |p| if (p.size == .slice) std.mem.eql(p.child, a, b) else a == b,
        else => std.meta.eql(a, b),
    };
}

fn freeValues(comptime V: type, allocator: std.mem.Allocator, slice: []V) void {
    _ = comptime V;
    allocator.free(slice);
}

/// Order-insensitive multiset equality over two value slices.
///
/// `#lzzigcrdtstack` — for the overwhelmingly common case (`b.len ≤ 128`, which
/// covers every realistic CRDT register entry count) the matched-flags buffer
/// lives on the call stack, removing a global-lock allocation per merge. Only
/// pathological wide registers fall back to the caller-supplied allocator. The
/// previous implementation unconditionally used `std.heap.page_allocator`, which
/// takes the global allocator mutex on every merge.
fn sameValues(
    comptime V: type,
    a: []const V,
    b: []const V,
    allocator: std.mem.Allocator,
) bool {
    if (a.len != b.len) return false;
    var stack_buf: [128]bool = undefined;
    const matched: []bool = if (b.len <= stack_buf.len) stack_buf[0..b.len] else blk: {
        const allocated = allocator.alloc(bool, b.len) catch return false;
        break :blk allocated;
    };
    defer if (matched.len > stack_buf.len) allocator.free(matched);
    @memset(matched, false);
    for (a) |av| {
        var found = false;
        for (b, 0..) |bv, j| {
            if (!matched[j] and valuesEqual(V, av, bv)) {
                matched[j] = true;
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// MvRegister — multi-value register. Each write is tagged with a version
// vector; merge keeps only values whose vector is not dominated by another.
// Mirrors lazily-rs `MvRegister` (`crdt.rs:529-604`).
// ---------------------------------------------------------------------------

pub fn MvRegister(comptime V: type) type {
    return struct {
        const Self = @This();
        pub const MergeMechanism = enum { crdt };

        pub const Entry = struct {
            vv: VersionVector,
            value: V,
        };

        allocator: std.mem.Allocator,
        entries: std.ArrayList(Entry),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .entries = .empty };
        }

        pub fn deinit(self: *Self) void {
            for (self.entries.items) |*e| e.vv.deinit();
            self.entries.deinit(self.allocator);
        }

        pub fn clone(self: *const Self, allocator: std.mem.Allocator) !Self {
            var out = Self.init(allocator);
            errdefer out.deinit();
            try out.entries.ensureTotalCapacity(allocator, self.entries.items.len);
            for (self.entries.items) |e| {
                try out.entries.append(allocator, .{
                    .vv = try e.vv.clone(allocator),
                    .value = e.value,
                });
            }
            return out;
        }

        /// Local write collapses all visible entries to one and bumps the
        /// writer's component past the current floor.
        pub fn set(self: *Self, value: V, peer: PeerId) !void {
            // Floor = componentwise max over all current entries.
            var floor = VersionVector.init(self.allocator);
            defer floor.deinit();
            for (self.entries.items) |e| {
                _ = try floor.merge(&e.vv);
            }
            var next_vv = VersionVector.init(self.allocator);
            errdefer next_vv.deinit();
            try next_vv.bump(peer, &floor);

            for (self.entries.items) |*e| e.vv.deinit();
            self.entries.clearRetainingCapacity();
            try self.entries.append(self.allocator, .{ .vv = next_vv, .value = value });
        }

        /// Read the concurrent values (deterministic order: by entry index).
        pub fn values(self: *const Self, allocator: std.mem.Allocator) ![]V {
            const out = try allocator.alloc(V, self.entries.items.len);
            for (self.entries.items, 0..) |e, i| out[i] = e.value;
            return out;
        }

        pub fn mergeFrom(self: *Self, other: *const Self) !bool {
            const before = try self.values(self.allocator);
            defer self.allocator.free(before);
            for (other.entries.items) |oe| {
                try self.entries.append(self.allocator, .{
                    .vv = try oe.vv.clone(self.allocator),
                    .value = oe.value,
                });
            }
            try self.normalize();
            const after = try self.values(self.allocator);
            defer self.allocator.free(after);
            return !sameValues(V, before, after, self.allocator);
        }

        /// Drop entries whose version vector is strictly dominated by another,
        /// and dedup equal entries. Mirrors lazily-rs `MvRegister::normalize`.
        fn normalize(self: *Self) !void {
            var keep = try self.allocator.alloc(bool, self.entries.items.len);
            defer self.allocator.free(keep);
            @memset(keep, true);

            var i: usize = 0;
            while (i < self.entries.items.len) : (i += 1) {
                if (!keep[i]) continue;
                var j: usize = i + 1;
                while (j < self.entries.items.len) : (j += 1) {
                    if (!keep[j]) continue;
                    const a = &self.entries.items[i].vv;
                    const b = &self.entries.items[j].vv;
                    if (a.dominates(b) and !b.dominates(a)) {
                        // b strictly dominated — drop it.
                        keep[j] = false;
                    } else if (b.dominates(a) and !a.dominates(b)) {
                        // a strictly dominated — drop it, stop comparing a.
                        keep[i] = false;
                        break;
                    } else if (a.equal(b)) {
                        // equal vv — keep the earlier index, drop the later.
                        if (valuesEqual(V, self.entries.items[i].value, self.entries.items[j].value)) {
                            keep[j] = false;
                        }
                    }
                }
            }

            var compact = std.ArrayList(Entry).empty;
            for (self.entries.items, 0..) |e, idx| {
                if (keep[idx]) {
                    try compact.append(self.allocator, e);
                } else {
                    var vv = e.vv;
                    vv.deinit();
                }
            }
            self.entries.deinit(self.allocator);
            self.entries = compact;
        }
    };
}

// ---------------------------------------------------------------------------
// PnCounter — positive-negative counter. Per-peer increment/decrement tallies
// merged by per-peer max; value = sum(incr) − sum(decr). Mirrors lazily-rs
// `PnCounter` (`crdt.rs:608-658`).
// ---------------------------------------------------------------------------

pub const PnCounter = struct {
    pub const MergeMechanism = enum { crdt };

    incr: std.AutoHashMap(PeerId, u64),
    decr: std.AutoHashMap(PeerId, u64),

    pub fn init(allocator: std.mem.Allocator) PnCounter {
        return .{
            .incr = std.AutoHashMap(PeerId, u64).init(allocator),
            .decr = std.AutoHashMap(PeerId, u64).init(allocator),
        };
    }

    pub fn deinit(self: *PnCounter) void {
        self.incr.deinit();
        self.decr.deinit();
    }

    pub fn increment(self: *PnCounter, peer: PeerId, amount: u64) !void {
        const cur = self.incr.get(peer) orelse 0;
        try self.incr.put(peer, cur + amount);
    }

    pub fn decrement(self: *PnCounter, peer: PeerId, amount: u64) !void {
        const cur = self.decr.get(peer) orelse 0;
        try self.decr.put(peer, cur + amount);
    }

    pub fn value(self: *const PnCounter) i64 {
        var sum_incr: i64 = 0;
        var ii = self.incr.valueIterator();
        while (ii.next()) |v| sum_incr += @intCast(v.*);
        var sum_decr: i64 = 0;
        var di = self.decr.valueIterator();
        while (di.next()) |v| sum_decr += @intCast(v.*);
        return sum_incr - sum_decr;
    }

    pub fn mergeFrom(self: *PnCounter, other: *const PnCounter) !bool {
        const before = self.value();
        try mergeMax(&self.incr, &other.incr);
        try mergeMax(&self.decr, &other.decr);
        return self.value() != before;
    }
};

fn mergeMax(into: *std.AutoHashMap(PeerId, u64), from: *const std.AutoHashMap(PeerId, u64)) !void {
    var iter = from.iterator();
    while (iter.next()) |entry| {
        const peer = entry.key_ptr.*;
        const their = entry.value_ptr.*;
        const our = into.get(peer) orelse 0;
        if (their > our) {
            try into.put(peer, their);
        }
    }
}

// ---------------------------------------------------------------------------
// StampFrontier — per-peer HLC stamp max semilattice. The causal-stability
// watermark is the min over membership. Mirrors lazily-rs `StampFrontier`
// (`crdt.rs:338-426`).
// ---------------------------------------------------------------------------

pub const StampFrontier = struct {
    entries: std.AutoHashMap(PeerId, HlcStamp),

    pub fn init(allocator: std.mem.Allocator) StampFrontier {
        return .{ .entries = std.AutoHashMap(PeerId, HlcStamp).init(allocator) };
    }

    pub fn deinit(self: *StampFrontier) void {
        self.entries.deinit();
    }

    /// Record a stamp for `peer`; per-peer max. Returns true if updated.
    pub fn observe(self: *StampFrontier, peer: PeerId, stamp: HlcStamp) !bool {
        if (self.entries.get(peer)) |existing| {
            if (stamp.compare(existing) != .gt) return false;
        }
        try self.entries.put(peer, stamp);
        return true;
    }

    /// Componentwise-max merge. Returns true if any component changed.
    pub fn merge(self: *StampFrontier, other: *const StampFrontier) !bool {
        var changed = false;
        var iter = other.entries.iterator();
        while (iter.next()) |entry| {
            if (try self.observe(entry.key_ptr.*, entry.value_ptr.*)) changed = true;
        }
        return changed;
    }

    /// The min stamp over `membership` — the causal point every listed peer has
    /// provably passed. null until every member has been observed.
    pub fn frontier(self: *const StampFrontier, membership: []const PeerId) ?HlcStamp {
        var min: ?HlcStamp = null;
        for (membership) |peer| {
            const stamp = self.entries.get(peer) orelse return null;
            if (min) |m| {
                if (stamp.compare(m) == .lt) min = stamp;
            } else {
                min = stamp;
            }
        }
        return min;
    }
};

// ---------------------------------------------------------------------------
// OpId — Lamport position for TextCrdt. Total order `(counter, peer)`.
// Mirrors lazily-rs `OpId` (`text_crdt.rs:43-63`).
// ---------------------------------------------------------------------------

pub const OpId = struct {
    counter: u64,
    peer: u64,

    pub fn compare(self: OpId, other: OpId) std.math.Order {
        if (self.counter < other.counter) return .lt;
        if (self.counter > other.counter) return .gt;
        if (self.peer < other.peer) return .lt;
        if (self.peer > other.peer) return .gt;
        return .eq;
    }

    pub fn eql(self: OpId, other: OpId) bool {
        return self.counter == other.counter and self.peer == other.peer;
    }

    pub fn hash(self: OpId) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&self.counter));
        h.update(std.mem.asBytes(&self.peer));
        return h.final();
    }
};

const OpIdContext = struct {
    pub fn hash(_: OpIdContext, key: OpId) u64 {
        return key.hash();
    }
    pub fn eql(_: OpIdContext, a: OpId, b: OpId) bool {
        return a.eql(b);
    }
};

const OptionalOpIdContext = struct {
    pub fn hash(_: OptionalOpIdContext, key: ?OpId) u64 {
        if (key) |k| return k.hash() +% 1;
        return 0;
    }
    pub fn eql(_: OptionalOpIdContext, a: ?OpId, b: ?OpId) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return a.?.eql(b.?);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "lazily/crdt.Hlc: send advances logical on tie, recv past remote" {
    var hlc = Hlc.init(1);
    const s1 = hlc.send(100);
    const s2 = hlc.send(100); // same wall → logical bump
    try std.testing.expectEqual(@as(u64, 100), s1.wall_time);
    try std.testing.expectEqual(@as(u64, 0), s1.logical);
    try std.testing.expectEqual(@as(u64, 1), s2.logical);

    var hlc2 = Hlc.init(2);
    const r = hlc2.recv(.{ .wall_time = 200, .logical = 5, .peer = 7 }, 50);
    try std.testing.expectEqual(@as(u64, 200), r.wall_time);
    try std.testing.expectEqual(@as(u64, 6), r.logical);
    try std.testing.expectEqual(@as(u64, 2), r.peer);
}

test "lazily/crdt.LwwRegister: highest stamp wins, merge is commutative+idempotent" {
    var a = LwwRegister(u32).init(1, .{ .wall_time = 10, .logical = 0, .peer = 1 });
    var b = LwwRegister(u32).init(2, .{ .wall_time = 12, .logical = 0, .peer = 2 });

    try std.testing.expect(a.mergeFrom(&b));
    try std.testing.expectEqual(@as(u32, 2), a.value);
    try std.testing.expect(!a.mergeFrom(&b)); // idempotent
    try std.testing.expectEqual(@as(u32, 2), a.value);

    // commutative: merging into a fresh copy of a from b yields the same value.
    var b2 = LwwRegister(u32).init(2, .{ .wall_time = 12, .logical = 0, .peer = 2 });
    try std.testing.expect(!b2.mergeFrom(&a)); // a's stamp (12,0,2) is not > b2's (12,0,2)
    try std.testing.expectEqual(@as(u32, 2), b2.value);
}

test "lazily/crdt.PnCounter: per-peer max merge, value = sum(incr) - sum(decr)" {
    const allocator = std.testing.allocator;
    var a = PnCounter.init(allocator);
    defer a.deinit();
    var b = PnCounter.init(allocator);
    defer b.deinit();

    try a.increment(1, 5);
    try a.increment(2, 3);
    try b.increment(1, 7); // peer 1's max
    try b.increment(3, 4); // new peer → changes the total
    try b.decrement(2, 2);

    // value before = (5+3) - 0 = 8; value after = (7+3+4) - 2 = 12.
    try std.testing.expect(try a.mergeFrom(&b));
    try std.testing.expectEqual(@as(i64, 12), a.value());
}

test "lazily/crdt.MvRegister: concurrent writes surface as multi-value, causal write collapses" {
    const allocator = std.testing.allocator;
    var a = MvRegister(u32).init(allocator);
    defer a.deinit();
    var b = MvRegister(u32).init(allocator);
    defer b.deinit();

    try a.set(10, 1);
    try b.set(20, 2);

    // Concurrent writes → merge keeps both.
    _ = try a.mergeFrom(&b);
    const vals = try a.values(allocator);
    defer allocator.free(vals);
    try std.testing.expectEqual(@as(usize, 2), vals.len);

    // A causal write after seeing both collapses to a single value.
    try a.set(30, 1);
    const vals2 = try a.values(allocator);
    defer allocator.free(vals2);
    try std.testing.expectEqual(@as(usize, 1), vals2.len);
    try std.testing.expectEqual(@as(u32, 30), vals2[0]);
}

test "lazily/crdt.StampFrontier: min-over-membership watermark" {
    const allocator = std.testing.allocator;
    var f = StampFrontier.init(allocator);
    defer f.deinit();

    const membership = [_]PeerId{ 1, 2, 3 };
    try std.testing.expect(f.frontier(&membership) == null);

    _ = try f.observe(1, .{ .wall_time = 10, .logical = 0, .peer = 1 });
    _ = try f.observe(2, .{ .wall_time = 5, .logical = 0, .peer = 2 });
    try std.testing.expect(f.frontier(&membership) == null); // peer 3 missing

    _ = try f.observe(3, .{ .wall_time = 20, .logical = 0, .peer = 3 });
    const wm = f.frontier(&membership).?;
    try std.testing.expectEqual(@as(u64, 5), wm.wall_time); // min
}
