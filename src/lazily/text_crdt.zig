const std = @import("std");
const crdt = @import("crdt.zig");
const OpId = crdt.OpId;

/// Wire form of one TextCrdt element. Mirrors lazily-rs `TextOp`
/// (`text_crdt.rs:72-83`).
pub const TextOp = struct {
    id: OpId,
    /// Unicode scalar value. ASCII fixtures store code points < 128.
    ch: u21,
    /// Element this char was typed AFTER (null = document start).
    origin: ?OpId,
    /// Delete op id once tombstoned; null while live.
    deleted: ?OpId,
};

const Elem = struct {
    ch: u21,
    origin: ?OpId,
    deleted: ?OpId,
};

/// A Fugue/RGA-style free-text character CRDT. Each char is an element with a
/// unique Lamport id `(counter, peer)` and a left `origin`; deletes tombstone.
/// Order is a pure function of the element set (pre-order DFS of the origin
/// tree, same-origin siblings sorted by `OpId` DESCENDING — the RGA "newest
/// after origin first" tiebreak), so merge is commutative, associative,
/// idempotent and concurrent same-point inserts converge with both preserved.
///
/// Mirrors lazily-rs `TextCrdt` (`text_crdt.rs:105-332`). See
/// `lazily-spec/cell-model.md § Free-text CRDT + re-parse`.
pub const TextCrdt = struct {
    allocator: std.mem.Allocator,
    elems: std.HashMap(OpId, Elem, OpIdContext, std.hash_map.default_max_load_percentage),
    peer: u64,
    counter: u64,

    const OpIdContext = struct {
        pub fn hash(_: OpIdContext, key: OpId) u64 {
            return key.hash();
        }
        pub fn eql(_: OpIdContext, a: OpId, b: OpId) bool {
            return a.eql(b);
        }
    };

    pub fn init(allocator: std.mem.Allocator, peer: u64) TextCrdt {
        return .{
            .allocator = allocator,
            .elems = std.HashMap(OpId, Elem, OpIdContext, std.hash_map.default_max_load_percentage).init(allocator),
            .peer = peer,
            .counter = 0,
        };
    }

    pub fn deinit(self: *TextCrdt) void {
        self.elems.deinit();
    }

    pub fn fromStr(allocator: std.mem.Allocator, peer: u64, s: []const u8) !TextCrdt {
        var t = TextCrdt.init(allocator, peer);
        errdefer t.deinit();
        var view = try std.unicode.Utf8View.init(s);
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            try t.insertBackCp(cp);
        }
        return t;
    }

    pub fn fork(self: *const TextCrdt, peer: u64) !TextCrdt {
        var out = TextCrdt.init(self.allocator, peer);
        errdefer out.deinit();
        out.counter = self.counter;
        var iter = self.elems.iterator();
        while (iter.next()) |entry| {
            try out.elems.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return out;
    }

    pub fn clock(self: *const TextCrdt) OpId {
        return .{ .counter = self.counter, .peer = self.peer };
    }

    fn nextId(self: *TextCrdt) OpId {
        self.counter += 1;
        return .{ .counter = self.counter, .peer = self.peer };
    }

    /// Append a single code point at the end of the document.
    pub fn insertBackCp(self: *TextCrdt, ch: u21) !void {
        const visible = try self.orderedIds(self.allocator, false);
        defer self.allocator.free(visible);
        const origin: ?OpId = if (visible.len > 0) visible[visible.len - 1] else null;
        const id = self.nextId();
        try self.elems.put(id, .{ .ch = ch, .origin = origin, .deleted = null });
    }

    /// Insert `ch` at a visible `index`. `origin` is the visible char at
    /// `index-1` (null at document start), matching RGA "insert after origin".
    pub fn insert(self: *TextCrdt, index: usize, ch: u21) !void {
        const visible = try self.orderedIds(self.allocator, false);
        defer self.allocator.free(visible);
        if (index > visible.len) return error.IndexOutOfBounds;
        const origin: ?OpId = if (index == 0) null else visible[index - 1];
        const id = self.nextId();
        try self.elems.put(id, .{ .ch = ch, .origin = origin, .deleted = null });
    }

    pub fn insertStr(self: *TextCrdt, index: usize, s: []const u8) !void {
        var view = try std.unicode.Utf8View.init(s);
        var it = view.iterator();
        var at = index;
        while (it.nextCodepoint()) |cp| {
            try self.insert(at, cp);
            at += 1;
        }
    }

    /// Tombstone the visible char at `index`. Mints a distinct delete OpId so
    /// the version vector covers delete stamps.
    pub fn delete(self: *TextCrdt, index: usize) !void {
        const visible = try self.orderedIds(self.allocator, false);
        defer self.allocator.free(visible);
        if (index >= visible.len) return error.IndexOutOfBounds;
        const del_id = self.nextId();
        if (self.elems.getPtr(visible[index])) |elem| {
            elem.deleted = del_id;
        }
    }

    /// Visible text in converged order.
    pub fn text(self: *const TextCrdt, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);
        const visible = try self.orderedIds(allocator, false);
        defer allocator.free(visible);
        for (visible) |id| {
            const elem = self.elems.get(id).?;
            // Encode the code point as UTF-8.
            var tmp: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(elem.ch, &tmp) catch continue;
            try buf.appendSlice(allocator, tmp[0..n]);
        }
        return buf.toOwnedSlice(allocator);
    }

    pub fn len(self: *const TextCrdt) !usize {
        const visible = try self.orderedIds(self.allocator, false);
        defer self.allocator.free(visible);
        return visible.len;
    }

    pub fn tombstoneCount(self: *const TextCrdt) usize {
        var n: usize = 0;
        var iter = self.elems.valueIterator();
        while (iter.next()) |e| {
            if (e.deleted != null) n += 1;
        }
        return n;
    }

    pub fn isEmpty(self: *const TextCrdt) !bool {
        return (try self.len()) == 0;
    }

    /// Commutative / associative / idempotent merge. Union of elements by id;
    /// tombstone is sticky-min so concurrent deletes converge commutatively.
    /// The local counter advances past every observed id (insert OR delete).
    /// Returns true iff the visible text changed.
    pub fn merge(self: *TextCrdt, other: *const TextCrdt) !bool {
        const before = try self.text(self.allocator);
        defer self.allocator.free(before);

        var iter = other.elems.iterator();
        while (iter.next()) |entry| {
            const id = entry.key_ptr.*;
            const oe = entry.value_ptr.*;
            self.counter = @max(self.counter, id.counter);
            if (oe.deleted) |d| self.counter = @max(self.counter, d.counter);
            if (self.elems.getPtr(id)) |e| {
                e.deleted = stickyMinDeleted(e.deleted, oe.deleted);
            } else {
                try self.elems.put(id, oe);
            }
        }
        const after = try self.text(self.allocator);
        defer self.allocator.free(after);
        return !std.mem.eql(u8, before, after);
    }

    /// `peer -> greatest counter` over both insert ids and tombstone ids.
    pub fn versionVector(self: *const TextCrdt, allocator: std.mem.Allocator) !std.AutoHashMap(u64, u64) {
        var vv = std.AutoHashMap(u64, u64).init(allocator);
        errdefer vv.deinit();
        var iter = self.elems.iterator();
        while (iter.next()) |entry| {
            const id = entry.key_ptr.*;
            try bumpVV(&vv, id.peer, id.counter);
            if (entry.value_ptr.deleted) |d| {
                try bumpVV(&vv, d.peer, d.counter);
            }
        }
        return vv;
    }

    /// Ops this replica holds that `their_vv` has not observed. A whole-state
    /// snapshot is `delta_since({})`.
    pub fn deltaSince(
        self: *const TextCrdt,
        their_vv: *const std.AutoHashMap(u64, u64),
        allocator: std.mem.Allocator,
    ) ![]TextOp {
        var out = std.ArrayList(TextOp).empty;
        errdefer out.deinit(allocator);
        var iter = self.elems.iterator();
        while (iter.next()) |entry| {
            const id = entry.key_ptr.*;
            const elem = entry.value_ptr.*;
            const insert_new = !seen(their_vv, id);
            const delete_new = if (elem.deleted) |d| !seen(their_vv, d) else false;
            if (insert_new or delete_new) {
                try out.append(allocator, .{
                    .id = id,
                    .ch = elem.ch,
                    .origin = elem.origin,
                    .deleted = elem.deleted,
                });
            }
        }
        return out.toOwnedSlice(allocator);
    }

    /// Apply a delta op list with the same algebra as `merge`. Commutative,
    /// associative, idempotent; re-applying a delta is a no-op.
    pub fn applyDelta(self: *TextCrdt, ops: []const TextOp) !bool {
        const before = try self.text(self.allocator);
        defer self.allocator.free(before);
        for (ops) |op| {
            self.counter = @max(self.counter, op.id.counter);
            if (op.deleted) |d| self.counter = @max(self.counter, d.counter);
            if (self.elems.getPtr(op.id)) |e| {
                e.deleted = stickyMinDeleted(e.deleted, op.deleted);
            } else {
                try self.elems.put(op.id, .{
                    .ch = op.ch,
                    .origin = op.origin,
                    .deleted = op.deleted,
                });
            }
        }
        const after = try self.text(self.allocator);
        defer self.allocator.free(after);
        return !std.mem.eql(u8, before, after);
    }

    /// Conservative GC: collect a tombstoned element iff (a) its delete is
    /// stable per `is_stable` AND (b) nothing references it as a left origin.
    /// Returns the number of elements reclaimed.
    pub fn gcWith(
        self: *TextCrdt,
        is_stable: *const fn (OpId) bool,
    ) !usize {
        var referenced = std.HashMap(OpId, void, OpIdContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer referenced.deinit();
        var iter = self.elems.valueIterator();
        while (iter.next()) |e| {
            if (e.origin) |o| {
                _ = try referenced.getOrPut(o);
            }
        }
        var to_remove = std.ArrayList(OpId).empty;
        defer to_remove.deinit(self.allocator);
        var iter2 = self.elems.iterator();
        while (iter2.next()) |entry| {
            const id = entry.key_ptr.*;
            const elem = entry.value_ptr.*;
            if (elem.deleted) |d| {
                if (is_stable(d) and !referenced.contains(id)) {
                    try to_remove.append(self.allocator, id);
                }
            }
        }
        for (to_remove.items) |id| {
            _ = self.elems.remove(id);
        }
        return to_remove.items.len;
    }

    /// Pre-order DFS of the origin tree. Same-origin siblings sorted by OpId
    /// DESCENDING (RGA tiebreak). `include_deleted=false` skips tombstoned
    /// elements from the output but still descends through them.
    fn orderedIds(self: *const TextCrdt, allocator: std.mem.Allocator, include_deleted: bool) ![]OpId {
        // Group children by origin.
        var children = std.HashMap(?OpId, std.ArrayList(OpId), OptionalOpIdContext, std.hash_map.default_max_load_percentage).init(allocator);
        defer {
            var ci = children.valueIterator();
            while (ci.next()) |list| {
                list.deinit(allocator);
            }
            children.deinit();
        }

        var iter = self.elems.iterator();
        while (iter.next()) |entry| {
            const origin = entry.value_ptr.origin;
            const gop = try children.getOrPut(origin);
            if (!gop.found_existing) {
                gop.value_ptr.* = std.ArrayList(OpId).empty;
            }
            try gop.value_ptr.append(allocator, entry.key_ptr.*);
        }

        // Sort each sibling list DESCENDING by OpId.
        var si = children.valueIterator();
        while (si.next()) |list| {
            std.mem.sort(OpId, list.items, {}, struct {
                fn lt(_: void, a: OpId, b: OpId) bool {
                    return a.compare(b) == .gt; // descending
                }
            }.lt);
        }

        var out = std.ArrayList(OpId).empty;
        errdefer out.deinit(allocator);

        // Iterative pre-order DFS. Push roots reversed so highest pops first.
        const roots = children.get(null);
        if (roots) |r| {
            var i: usize = r.items.len;
            while (i > 0) {
                i -= 1;
                try out.append(allocator, r.items[i]);
            }
        }

        var pos: usize = 0;
        while (pos < out.items.len) : (pos += 1) {
            const id = out.items[pos];
            const kids = children.get(id);
            if (kids) |k| {
                // Push reversed so highest pops first.
                var j: usize = k.items.len;
                while (j > 0) {
                    j -= 1;
                    try out.append(allocator, k.items[j]);
                }
            }
        }

        if (!include_deleted) {
            var compact = std.ArrayList(OpId).empty;
            for (out.items) |id| {
                if (self.elems.get(id)) |elem| {
                    if (elem.deleted == null) {
                        try compact.append(allocator, id);
                    }
                }
            }
            out.deinit(allocator);
            return compact.toOwnedSlice(allocator);
        }
        return out.toOwnedSlice(allocator);
    }
};

fn seen(vv: *const std.AutoHashMap(u64, u64), id: OpId) bool {
    return id.counter <= (vv.get(id.peer) orelse 0);
}

fn bumpVV(vv: *std.AutoHashMap(u64, u64), peer: u64, counter: u64) !void {
    const cur = vv.get(peer) orelse 0;
    if (counter > cur) {
        try vv.put(peer, counter);
    }
}

fn stickyMinDeleted(a: ?OpId, b: ?OpId) ?OpId {
    if (a == null and b == null) return null;
    if (a == null) return b;
    if (b == null) return a;
    return if (a.?.compare(b.?) == .lt) a.? else b.?;
}

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
// Tests (logic-level replay of the conformance scenarios)
// ---------------------------------------------------------------------------

test "lazily/text_crdt: insert + delete converges; tombstones sticky-min" {
    const allocator = std.testing.allocator;
    var a = try TextCrdt.fromStr(allocator, 1, "abc");
    defer a.deinit();
    {
        const s = try a.text(allocator);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("abc", s);
    }

    try a.delete(1); // delete 'b'
    {
        const s = try a.text(allocator);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("ac", s);
    }
    try std.testing.expectEqual(@as(usize, 1), a.tombstoneCount());
}

test "lazily/text_crdt: concurrent inserts at same point both survive, ordered by OpId desc" {
    const allocator = std.testing.allocator;
    var a = try TextCrdt.fromStr(allocator, 1, "A");
    defer a.deinit();
    var b = try a.fork(2);
    defer b.deinit();

    // Both insert after 'A' (index 1).
    try a.insert(1, 'X'); // peer 1
    try b.insert(1, 'Y'); // peer 2

    _ = try a.merge(&b);
    _ = try b.merge(&a);
    const ta = try a.text(allocator);
    defer allocator.free(ta);
    const tb = try b.text(allocator);
    defer allocator.free(tb);
    try std.testing.expectEqualStrings(ta, tb); // convergence
    // Both X and Y present.
    try std.testing.expect(std.mem.indexOfScalar(u8, ta, 'X') != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, ta, 'Y') != null);
}

test "lazily/text_crdt: delta sync round-trip + idempotent apply" {
    const allocator = std.testing.allocator;
    var a = try TextCrdt.fromStr(allocator, 1, "hello\n");
    defer a.deinit();

    var empty_vv = std.AutoHashMap(u64, u64).init(allocator);
    defer empty_vv.deinit();
    const snapshot = try a.deltaSince(&empty_vv, allocator);
    defer allocator.free(snapshot);

    var b = TextCrdt.init(allocator, 2);
    defer b.deinit();
    try std.testing.expect(try b.applyDelta(snapshot));
    {
        const s = try b.text(allocator);
        defer allocator.free(s);
        try std.testing.expectEqualStrings("hello\n", s);
    }

    // Idempotent re-apply.
    try std.testing.expect(!try b.applyDelta(snapshot));
}

test "lazily/text_crdt: bidirectional delta exchange converges (concurrent insert + delete)" {
    const allocator = std.testing.allocator;
    var a = try TextCrdt.fromStr(allocator, 1, "hello\n");
    defer a.deinit();
    var a1 = try a.fork(2);
    defer a1.deinit();
    var b = try a.fork(3);
    defer b.deinit();

    try a1.insertStr(6, "world\n");
    try b.delete(0);

    // exchange: each applies the other's delta since its own vv
    var vv_a1 = try a1.versionVector(allocator);
    defer vv_a1.deinit();
    var vv_b = try b.versionVector(allocator);
    defer vv_b.deinit();

    const d_a1_to_b = try a1.deltaSince(&vv_b, allocator);
    defer allocator.free(d_a1_to_b);
    const d_b_to_a1 = try b.deltaSince(&vv_a1, allocator);
    defer allocator.free(d_b_to_a1);

    _ = try b.applyDelta(d_a1_to_b);
    _ = try a1.applyDelta(d_b_to_a1);

    const ta = try a1.text(allocator);
    defer allocator.free(ta);
    const tb = try b.text(allocator);
    defer allocator.free(tb);
    try std.testing.expectEqualStrings(ta, tb);
    try std.testing.expectEqualStrings("ello\nworld\n", ta);
}

test "lazily/text_crdt: version_vector covers inserts and delete ids" {
    const allocator = std.testing.allocator;
    var t = try TextCrdt.fromStr(allocator, 1, "ab");
    defer t.deinit();
    try t.delete(0); // delete 'a' — mints a delete op for peer 1
    var vv = try t.versionVector(allocator);
    defer vv.deinit();
    // inserts: counter 1,2 ; delete: counter 3 → peer 1 max is 3.
    try std.testing.expectEqual(@as(u64, 3), vv.get(1).?);
}
