const std = @import("std");
const crdt = @import("crdt.zig");
const Hlc = crdt.Hlc;
const HlcStamp = crdt.HlcStamp;
const PeerId = crdt.PeerId;

/// Fractional-index position: an orderable byte key + originating peer.
/// `(frac, peer)` lexicographic total order. Mirrors lazily-rs `Position`
/// (`seq_crdt.rs:32-43`).
pub const Position = struct {
    frac: []u8,
    peer: PeerId,

    pub fn compare(self: Position, other: Position) std.math.Order {
        const n = @min(self.frac.len, other.frac.len);
        for (self.frac[0..n], other.frac[0..n]) |a, b| {
            if (a < b) return .lt;
            if (a > b) return .gt;
        }
        if (self.frac.len < other.frac.len) return .lt;
        if (self.frac.len > other.frac.len) return .gt;
        if (self.peer < other.peer) return .lt;
        if (self.peer > other.peer) return .gt;
        return .eq;
    }

    pub fn clone(self: Position, allocator: std.mem.Allocator) !Position {
        const new_frac = try allocator.dupe(u8, self.frac);
        return .{ .frac = new_frac, .peer = self.peer };
    }

    pub fn deinit(self: *Position, allocator: std.mem.Allocator) void {
        allocator.free(self.frac);
        self.frac = &.{};
    }
};

/// Per-element entry: three independent LWW registers (value, position,
/// deleted). A move is a single LWW reassignment of position — not delete +
/// reinsert — so concurrent moves of the same element converge to the later
/// stamp without duplication, and a concurrent move + value-edit both apply
/// (independent registers). Mirrors lazily-rs `Entry`
/// (`seq_crdt.rs:45-51`).
pub fn Entry(comptime V: type) type {
    return struct {
        value: V,
        value_stamp: HlcStamp,
        position: Position,
        position_stamp: HlcStamp,
        deleted: bool,
        deleted_stamp: HlcStamp,

        const Self = @This();

        fn mergeValue(self: *Self, other: *const Self) bool {
            if (other.value_stamp.compare(self.value_stamp) == .gt) {
                const changed = !crdtEq(V, self.value, other.value);
                self.value = other.value;
                self.value_stamp = other.value_stamp;
                return changed;
            }
            return false;
        }

        fn mergePosition(self: *Self, other: *const Self, allocator: std.mem.Allocator) !bool {
            if (other.position_stamp.compare(self.position_stamp) == .gt) {
                const new_pos = try other.position.clone(allocator);
                self.position.deinit(allocator);
                self.position = new_pos;
                self.position_stamp = other.position_stamp;
                return true;
            }
            return false;
        }

        fn mergeDeleted(self: *Self, other: *const Self) bool {
            if (other.deleted_stamp.compare(self.deleted_stamp) == .gt) {
                const changed = self.deleted != other.deleted;
                self.deleted = other.deleted;
                self.deleted_stamp = other.deleted_stamp;
                return changed;
            }
            return false;
        }
    };
}

fn crdtEq(comptime V: type, a: V, b: V) bool {
    return switch (@typeInfo(V)) {
        .pointer => |p| if (p.size == .slice) std.mem.eql(p.child, a, b) else a == b,
        else => std.meta.eql(a, b),
    };
}

/// A move-aware sequence CRDT. Each element is keyed by a stable `Id` and
/// carries three independent LWW registers (value, position, deleted). Removal
/// is an LWW tombstone. Order is the `(frac, peer)` total order over positions.
///
/// Mirrors lazily-rs `SeqCrdt` (`seq_crdt.rs:67-316`). See
/// `lazily-spec/cell-model.md § Move-aware sequence order`.
pub fn SeqCrdt(comptime Id: type, comptime V: type) type {
    return struct {
        allocator: std.mem.Allocator,
        entries: std.HashMap(Id, Entry(V), IdContext(Id), std.hash_map.default_max_load_percentage),
        hlc: Hlc,
        peer: PeerId,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, peer: PeerId) Self {
            return .{
                .allocator = allocator,
                .entries = std.HashMap(Id, Entry(V), IdContext(Id), std.hash_map.default_max_load_percentage).init(allocator),
                .hlc = Hlc.init(peer),
                .peer = peer,
            };
        }

        pub fn deinit(self: *Self) void {
            var iter = self.entries.valueIterator();
            while (iter.next()) |e| {
                e.position.deinit(self.allocator);
            }
            self.entries.deinit();
        }

        pub fn fork(self: *const Self, peer: PeerId) !Self {
            var out = Self.init(self.allocator, peer);
            errdefer out.deinit();
            out.hlc = self.hlc;
            var iter = self.entries.iterator();
            while (iter.next()) |entry| {
                const pos = try entry.value_ptr.position.clone(self.allocator);
                try out.entries.put(entry.key_ptr.*, .{
                    .value = entry.value_ptr.value,
                    .value_stamp = entry.value_ptr.value_stamp,
                    .position = pos,
                    .position_stamp = entry.value_ptr.position_stamp,
                    .deleted = entry.value_ptr.deleted,
                    .deleted_stamp = entry.value_ptr.deleted_stamp,
                });
            }
            return out;
        }

        pub fn contains(self: *const Self, id: Id) bool {
            return self.entries.contains(id);
        }

        pub fn get(self: *const Self, id: Id) ?V {
            if (self.entries.get(id)) |e| {
                if (!e.deleted) return e.value;
            }
            return null;
        }

        fn fracOf(self: *const Self, id: Id) ?[]const u8 {
            const e = self.entries.get(id) orelse return null;
            return e.position.frac;
        }

        pub fn insertBack(self: *Self, id: Id, value: V, now_micros: u64) !void {
            const last_id = self.lastLiveId();
            const lo: ?[]const u8 = if (last_id) |lid| self.fracOf(lid) else null;
            const frac = try keyBetween(self.allocator, lo, null);
            const stamp = self.hlc.send(now_micros);
            try self.entries.put(id, .{
                .value = value,
                .value_stamp = stamp,
                .position = .{ .frac = frac, .peer = self.peer },
                .position_stamp = stamp,
                .deleted = false,
                .deleted_stamp = stamp,
            });
        }

        pub fn insertFront(self: *Self, id: Id, value: V, now_micros: u64) !void {
            const first_id = self.firstLiveId();
            const hi: ?[]const u8 = if (first_id) |fid| self.fracOf(fid) else null;
            const frac = try keyBetween(self.allocator, null, hi);
            const stamp = self.hlc.send(now_micros);
            try self.entries.put(id, .{
                .value = value,
                .value_stamp = stamp,
                .position = .{ .frac = frac, .peer = self.peer },
                .position_stamp = stamp,
                .deleted = false,
                .deleted_stamp = stamp,
            });
        }

        pub fn insertBetween(
            self: *Self,
            id: Id,
            value: V,
            left: ?Id,
            right: ?Id,
            now_micros: u64,
        ) !void {
            const lo: ?[]const u8 = if (left) |l| self.fracOf(l) else null;
            const hi: ?[]const u8 = if (right) |r| self.fracOf(r) else null;
            const frac = try keyBetween(self.allocator, lo, hi);
            const stamp = self.hlc.send(now_micros);
            try self.entries.put(id, .{
                .value = value,
                .value_stamp = stamp,
                .position = .{ .frac = frac, .peer = self.peer },
                .position_stamp = stamp,
                .deleted = false,
                .deleted_stamp = stamp,
            });
        }

        pub fn setValue(self: *Self, id: Id, value: V, now_micros: u64) !bool {
            const e = self.entries.getPtr(id) orelse return false;
            const stamp = self.hlc.send(now_micros);
            if (stamp.compare(e.value_stamp) == .gt) {
                e.value = value;
                e.value_stamp = stamp;
                return true;
            }
            return false;
        }

        pub fn moveAfter(self: *Self, id: Id, anchor: Id, now_micros: u64) !bool {
            const seq = try self.liveOrder(self.allocator);
            defer self.allocator.free(seq);
            const anchor_pos = for (seq, 0..) |entry, i| {
                if (equalsId(Id, entry.id, anchor)) break i;
            } else return false;
            const left = if (anchor_pos + 1 < seq.len) seq[anchor_pos + 1].id else null;
            return self.moveBetween(id, anchor, left, now_micros);
        }

        pub fn moveBefore(self: *Self, id: Id, anchor: Id, now_micros: u64) !bool {
            const seq = try self.liveOrder(self.allocator);
            defer self.allocator.free(seq);
            const anchor_pos = for (seq, 0..) |entry, i| {
                if (equalsId(Id, entry.id, anchor)) break i;
            } else return false;
            const left = if (anchor_pos > 0) seq[anchor_pos - 1].id else null;
            return self.moveBetween(id, left, anchor, now_micros);
        }

        pub fn moveBetween(
            self: *Self,
            id: Id,
            left: ?Id,
            right: ?Id,
            now_micros: u64,
        ) !bool {
            if (!self.entries.contains(id)) return false;
            const lo: ?[]const u8 = if (left) |l| self.fracOf(l) else null;
            const hi: ?[]const u8 = if (right) |r| self.fracOf(r) else null;
            const frac = try keyBetween(self.allocator, lo, hi);
            const stamp = self.hlc.send(now_micros);
            const e = self.entries.getPtr(id).?;
            e.position.deinit(self.allocator);
            e.position = .{ .frac = frac, .peer = self.peer };
            e.position_stamp = stamp;
            return true;
        }

        pub fn remove(self: *Self, id: Id, now_micros: u64) bool {
            const e = self.entries.getPtr(id) orelse return false;
            const stamp = self.hlc.send(now_micros);
            if (stamp.compare(e.deleted_stamp) == .gt) {
                e.deleted = true;
                e.deleted_stamp = stamp;
                return true;
            }
            return false;
        }

        pub const OrderedEntry = struct { id: Id, value: V };

        /// Live entries in `(frac, peer)` order.
        pub fn liveOrder(self: *const Self, allocator: std.mem.Allocator) ![]OrderedEntry {
            var all = std.ArrayList(Entry(V)).empty;
            defer all.deinit(allocator);
            var ids = std.ArrayList(Id).empty;
            defer ids.deinit(allocator);
            var iter = self.entries.iterator();
            while (iter.next()) |entry| {
                if (!entry.value_ptr.deleted) {
                    try all.append(allocator, entry.value_ptr.*);
                    try ids.append(allocator, entry.key_ptr.*);
                }
            }
            // Sort indices by position.
            const indices = try allocator.alloc(usize, all.items.len);
            defer allocator.free(indices);
            for (indices, 0..) |*c, i| c.* = i;
            std.mem.sort(usize, indices, all.items, struct {
                fn lt(entries: []const Entry(V), a: usize, b: usize) bool {
                    return entries[a].position.compare(entries[b].position) == .lt;
                }
            }.lt);
            const out = try allocator.alloc(OrderedEntry, indices.len);
            for (indices, 0..) |idx, i| {
                out[i] = .{ .id = ids.items[idx], .value = all.items[idx].value };
            }
            return out;
        }

        /// Ordered live ids.
        pub fn order(self: *const Self, allocator: std.mem.Allocator) ![]Id {
            const live = try self.liveOrder(allocator);
            defer allocator.free(live);
            const out = try allocator.alloc(Id, live.len);
            for (live, 0..) |e, i| out[i] = e.id;
            return out;
        }

        /// `(id, value)` pairs in sequence order.
        pub fn values(self: *const Self, allocator: std.mem.Allocator) ![]OrderedEntry {
            return self.liveOrder(allocator);
        }

        pub fn tombstoneCount(self: *const Self) usize {
            var n: usize = 0;
            var iter = self.entries.valueIterator();
            while (iter.next()) |e| {
                if (e.deleted) n += 1;
            }
            return n;
        }

        /// Per-entry LWW merge of value/position/deleted; unknown entries
        /// adopted; HLC advanced past the highest observed stamp.
        pub fn merge(self: *Self, other: *const Self, now_micros: u64) !bool {
            // Advance HLC past the highest observed stamp.
            var max_stamp: ?HlcStamp = null;
            var iter_max = other.entries.valueIterator();
            while (iter_max.next()) |e| {
                inline for ([_]HlcStamp{ e.value_stamp, e.position_stamp, e.deleted_stamp }) |s| {
                    if (max_stamp == null or s.compare(max_stamp.?) == .gt) {
                        max_stamp = s;
                    }
                }
            }
            if (max_stamp) |s| _ = self.hlc.recv(s, now_micros);

            var changed = false;
            var iter = other.entries.iterator();
            while (iter.next()) |entry| {
                const id = entry.key_ptr.*;
                const oe = entry.value_ptr.*;
                if (self.entries.getPtr(id)) |e| {
                    if (try e.mergePosition(&oe, self.allocator)) changed = true;
                    if (e.mergeValue(&oe)) changed = true;
                    if (e.mergeDeleted(&oe)) changed = true;
                } else {
                    const pos = try oe.position.clone(self.allocator);
                    try self.entries.put(id, .{
                        .value = oe.value,
                        .value_stamp = oe.value_stamp,
                        .position = pos,
                        .position_stamp = oe.position_stamp,
                        .deleted = oe.deleted,
                        .deleted_stamp = oe.deleted_stamp,
                    });
                    changed = true;
                }
            }
            return changed;
        }

        fn lastLiveId(self: *const Self) ?Id {
            const live = self.liveOrder(self.allocator) catch return null;
            defer self.allocator.free(live);
            if (live.len == 0) return null;
            return live[live.len - 1].id;
        }

        fn firstLiveId(self: *const Self) ?Id {
            const live = self.liveOrder(self.allocator) catch return null;
            defer self.allocator.free(live);
            if (live.len == 0) return null;
            return live[0].id;
        }
    };
}

fn equalsId(comptime Id: type, a: Id, b: Id) bool {
    return switch (@typeInfo(Id)) {
        .pointer => std.mem.eql(u8, a, b),
        else => a == b,
    };
}

/// HashMap context that hashes `[]const u8` by content and other keys by
/// `std.hash.autoHash` over their bytes. Lets `SeqCrdt` key on string ids.
fn IdContext(comptime Id: type) type {
    return struct {
        pub fn hash(_: @This(), key: Id) u64 {
            switch (@typeInfo(Id)) {
                .pointer => |p| {
                    if (p.size == .slice) {
                        var h = std.hash.Wyhash.init(0);
                        h.update(key);
                        return h.final();
                    }
                },
                else => {},
            }
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&key));
            return h.final();
        }
        pub fn eql(_: @This(), a: Id, b: Id) bool {
            return equalsId(Id, a, b);
        }
    };
}

/// Fractional-index midpoint. `lo`/`hi` are open bounds (`null` = open end).
/// Produces a byte key strictly between them. Mirrors lazily-rs `key_between`
/// (`seq_crdt.rs:322-355`).
pub fn keyBetween(allocator: std.mem.Allocator, lo: ?[]const u8, hi: ?[]const u8) ![]u8 {
    const lob = lo orelse &.{};
    const hib = hi orelse &.{};
    var i: usize = 0;
    while (true) : (i += 1) {
        const a: u16 = if (i < lob.len) lob[i] else 0;
        const b: u16 = if (i < hib.len) hib[i] else 256;
        if (a + 1 < b) {
            // Midpoint digit at this position; emit prefix + midpoint.
            const prefix_len = i;
            const mid: u8 = @intCast(@divTrunc(a + b, 2));
            var out = try allocator.alloc(u8, prefix_len + 1);
            @memcpy(out[0..prefix_len], lob[0..prefix_len]);
            out[prefix_len] = mid;
            return out;
        }
        if (a < b) {
            // Commit a, descend with open top.
            const out = try allocator.alloc(u8, i + 2);
            @memcpy(out[0..i], lob[0..i]);
            out[i] = @intCast(a);
            out[i + 1] = 128; // midpoint of open top
            return out;
        }
        // a == b, continue.
        if (i >= lob.len and i >= hib.len) {
            // Degenerate: lo not < hi (equal). Append a midpoint and stop.
            const out = try allocator.alloc(u8, lob.len + 1);
            @memcpy(out[0..lob.len], lob);
            out[lob.len] = 128;
            return out;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "lazily/seq_crdt: insert back and front orders" {
    const allocator = std.testing.allocator;
    var s = SeqCrdt([]const u8, i64).init(allocator, 1);
    defer s.deinit();

    try s.insertBack("a", 0, 1);
    try s.insertBack("b", 1, 2);
    try s.insertBack("c", 2, 3);
    try s.insertFront("z", 9, 4);

    const ord = try s.order(allocator);
    defer allocator.free(ord);
    try std.testing.expectEqualSlices([]const u8, &.{ "z", "a", "b", "c" }, ord);
    try std.testing.expectEqual(@as(?i64, 1), s.get("b"));
}

test "lazily/seq_crdt: move is single reassignment, no duplication" {
    const allocator = std.testing.allocator;
    var s = SeqCrdt([]const u8, i64).init(allocator, 1);
    defer s.deinit();

    try s.insertBack("a", 0, 1);
    try s.insertBack("b", 1, 2);
    try s.insertBack("c", 2, 3);
    try s.insertBack("d", 3, 4);
    _ = try s.moveAfter("a", "d", 10);

    const ord = try s.order(allocator);
    defer allocator.free(ord);
    try std.testing.expectEqualSlices([]const u8, &.{ "b", "c", "d", "a" }, ord);
    try std.testing.expectEqual(@as(?i64, 0), s.get("a"));
}

test "lazily/seq_crdt: concurrent inserts same gap converge (peer tiebreak)" {
    const allocator = std.testing.allocator;
    var a = SeqCrdt([]const u8, []const u8).init(allocator, 1);
    defer a.deinit();
    try a.insertBack("root", "R", 1);

    var b = try a.fork(2);
    defer b.deinit();

    try a.insertBack("a1", "A", 10);
    try b.insertBack("b1", "B", 10);

    var a2 = try a.fork(1);
    defer a2.deinit();
    _ = try a2.merge(&b, 20);
    var b2 = try b.fork(2);
    defer b2.deinit();
    _ = try b2.merge(&a, 20);

    const oa = try a2.order(allocator);
    defer allocator.free(oa);
    const ob = try b2.order(allocator);
    defer allocator.free(ob);
    try std.testing.expectEqualSlices([]const u8, oa, ob);
    try std.testing.expectEqual(@as(usize, 3), oa.len);
}

test "lazily/seq_crdt: concurrent move converges to later stamp, no duplication" {
    const allocator = std.testing.allocator;
    var a = SeqCrdt([]const u8, []const u8).init(allocator, 1);
    defer a.deinit();
    try a.insertBack("x", "X", 1);
    try a.insertBack("y", "Y", 2);
    try a.insertBack("z", "Z", 3);

    var b = try a.fork(2);
    defer b.deinit();

    _ = try a.moveAfter("x", "y", 10);
    _ = try b.moveAfter("x", "z", 20);

    var merged = try a.fork(1);
    defer merged.deinit();
    _ = try merged.merge(&b, 30);

    const ord = try merged.order(allocator);
    defer allocator.free(ord);
    try std.testing.expectEqualSlices([]const u8, &.{ "y", "z", "x" }, ord);
}

test "lazily/seq_crdt: concurrent move and value edit do not conflict" {
    const allocator = std.testing.allocator;
    var a = SeqCrdt([]const u8, i64).init(allocator, 1);
    defer a.deinit();
    try a.insertBack("a", 1, 1);
    try a.insertBack("b", 2, 2);

    var b = try a.fork(2);
    defer b.deinit();

    _ = try a.moveAfter("a", "b", 10);
    _ = try b.setValue("a", 99, 10);

    var merged = try a.fork(1);
    defer merged.deinit();
    _ = try merged.merge(&b, 20);

    const ord = try merged.order(allocator);
    defer allocator.free(ord);
    try std.testing.expectEqualSlices([]const u8, &.{ "b", "a" }, ord);
    try std.testing.expectEqual(@as(?i64, 99), merged.get("a"));
}

test "lazily/seq_crdt: remove tombstone converges; merge is commutative" {
    const allocator = std.testing.allocator;
    var a = SeqCrdt([]const u8, i64).init(allocator, 1);
    defer a.deinit();
    try a.insertBack("a", 1, 1);
    try a.insertBack("b", 2, 2);
    try a.insertBack("c", 3, 3);

    var b = try a.fork(2);
    defer b.deinit();

    _ = a.remove("b", 10);
    _ = try b.moveAfter("a", "c", 11);

    var ab = try a.fork(1);
    defer ab.deinit();
    _ = try ab.merge(&b, 20);
    var ba = try b.fork(2);
    defer ba.deinit();
    _ = try ba.merge(&a, 20);

    const oab = try ab.order(allocator);
    defer allocator.free(oab);
    const oba = try ba.order(allocator);
    defer allocator.free(oba);
    try std.testing.expectEqualSlices([]const u8, oab, oba);
    try std.testing.expect(!ab.contains("b") or ab.get("b") == null);
}
