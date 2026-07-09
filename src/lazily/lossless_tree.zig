const std = @import("std");
const crdt = @import("crdt.zig");
const text_crdt = @import("text_crdt.zig");
const seq_crdt = @import("seq_crdt.zig");
const OpId = crdt.OpId;
const TextCrdt = text_crdt.TextCrdt;
const TextOp = text_crdt.TextOp;

// Lossless full-document tree CRDT — M1 syntax-agnostic core (#lzlosstree).
//
// A single rooted concrete-syntax tree whose *leaves own every rendered byte*.
// The defining invariant is losslessness — render(tree) == source_text for
// valid, invalid, and unknown source alike — so the tree itself can be the wire
// authority instead of a semantic AST over a separate text floor. Internal
// element nodes own *structure only*; all text lives in leaf nodes tagged
// Token / Trivia / Raw / Error, so unknown/invalid spans round-trip exactly as
// Raw/Error leaves rather than being discarded.
//
// M1 scope: create / tombstone / intra-parent reorder / leaf-edit / split-leaf /
// merge-adjacent-leaves, plus op-based delta sync over a dotted, non-contiguous
// version frontier. Positions and seed text travel inside ops so both replicas
// store byte-identical keys and converge. Leaf text embeds TextCrdt wholesale;
// child order is a minimal fractional index (keyBetween, mirroring SeqCrdt);
// the clock is a Lamport op id (the shared OpId type). Leaf-local wire offsets
// are UTF-8 bytes; Zig strings are natively UTF-8, so byteToCodePoint is a
// scalar-boundary check rather than a UTF-16 conversion.
//
// Zig port of lazily-go `lossless_tree_crdt.go` and lazily-js
// `src/lossless-tree-crdt.js`, mirroring the lazily-rs reference. Conforms to
// lazily-spec `schemas/lossless-tree.json` + `schemas/lossless-tree-delta.json`
// and replays the shared `conformance/lossless-tree/` compute scenarios.
//
// Wire conventions (NORMATIVE, from lossless-tree.json):
//   - OpId / TreeNodeId is the transparent {counter, peer} form (reuses OpId);
//     the document root is {counter: 0, peer: 0}.
//   - SortKey.frac is a JSON array of u8 (0..255), NOT base64.
//   - LeafKind is PascalCase on the wire (Token/Trivia/Raw/Error).
//   - NodeSeed and TreeOpKind are externally tagged (single-key object).
//   - SplitLeaf carries at_char (a Unicode scalar count); MergeLeaves carries
//     prev_left / prev_right (snake_case on the wire).

// ---------------------------------------------------------------------------
// LeafKind (lossless-tree.json#/$defs/LeafKind)
// ---------------------------------------------------------------------------

/// Classification of a leaf's exact source span. Every rendered byte belongs to
/// a leaf; unknown/invalid spans are Raw/Error so nothing is discarded.
/// Serialized as the PascalCase wire string.
pub const LeafKind = enum {
    token,
    trivia,
    raw,
    err,

    pub fn wireName(self: LeafKind) []const u8 {
        return switch (self) {
            .token => "Token",
            .trivia => "Trivia",
            .raw => "Raw",
            .err => "Error",
        };
    }

    pub fn fromWireName(name: []const u8) error{UnknownLeafKind}!LeafKind {
        if (std.mem.eql(u8, name, "Token")) return .token;
        if (std.mem.eql(u8, name, "Trivia")) return .trivia;
        if (std.mem.eql(u8, name, "Raw")) return .raw;
        if (std.mem.eql(u8, name, "Error")) return .err;
        return error.UnknownLeafKind;
    }

    /// Accept the lowercase fixture seed-leaf kind ("token"/"trivia"/…).
    pub fn fromSeedKind(name: []const u8) error{UnknownLeafKind}!LeafKind {
        if (std.mem.eql(u8, name, "token")) return .token;
        if (std.mem.eql(u8, name, "trivia")) return .trivia;
        if (std.mem.eql(u8, name, "raw")) return .raw;
        if (std.mem.eql(u8, name, "error")) return .err;
        return error.UnknownLeafKind;
    }
};

// ---------------------------------------------------------------------------
// SortKey (lossless-tree.json#/$defs/SortKey)
// ---------------------------------------------------------------------------

/// A fractional-index child position: orderable bytes (0..255) tiebroken by the
/// minting peer. `(frac, peer)` lexicographic total order. `frac` is owned by
/// the carrier (allocated via `keyBetween`); clone/deinit manage it.
pub const SortKey = struct {
    frac: []u8,
    peer: u64,

    pub fn compare(self: SortKey, other: SortKey) std.math.Order {
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

    pub fn clone(self: SortKey, allocator: std.mem.Allocator) !SortKey {
        return .{ .frac = try allocator.dupe(u8, self.frac), .peer = self.peer };
    }

    pub fn deinit(self: *SortKey, allocator: std.mem.Allocator) void {
        allocator.free(self.frac);
        self.frac = &.{};
    }
};

// ---------------------------------------------------------------------------
// NodeSeed (lossless-tree.json#/$defs/NodeSeed) — externally tagged
// ---------------------------------------------------------------------------

/// What a CreateNode materializes: an element shell or a text leaf seeded from
/// exact text. Externally tagged on the wire
/// (`{"Element": {"kind": ...}}` or `{"Leaf": {"kind": ..., "text": ...}}`).
pub const NodeSeed = union(enum) {
    element: []const u8, // element kind string (borrowed in op constructors)
    leaf: LeafSeed,

    pub const LeafSeed = struct {
        kind: LeafKind,
        text: []const u8, // seed text (borrowed in op constructors)
    };
};

// ---------------------------------------------------------------------------
// TreeOpKind (lossless-tree.json#/$defs/TreeOpKind) — externally tagged
// ---------------------------------------------------------------------------

/// The M1 op vocabulary. Positions and seed text travel inside the op so both
/// replicas store byte-identical keys and converge without consulting local
/// clocks. Fields borrow caller-owned slices in op constructors; `dup`/`free`
/// manage owned copies for the log.
pub const TreeOpKind = union(enum) {
    create_node: CreateNode,
    tombstone: Tombstone,
    reorder: Reorder,
    leaf_edit: LeafEdit,
    split_leaf: SplitLeaf,
    merge_leaves: MergeLeaves,

    pub const CreateNode = struct {
        id: OpId,
        parent: OpId,
        sort: SortKey,
        seed: NodeSeed,
    };

    pub const Tombstone = struct {
        node: OpId,
    };

    pub const Reorder = struct {
        node: OpId,
        sort: SortKey,
    };

    pub const LeafEdit = struct {
        node: OpId,
        prev: OpId,
        ops: []TextOp,
    };

    pub const SplitLeaf = struct {
        node: OpId,
        new_id: OpId,
        sort: SortKey,
        at_char: usize,
        prev: OpId,
    };

    pub const MergeLeaves = struct {
        left: OpId,
        right: OpId,
        prev_left: OpId,
        prev_right: OpId,
    };
};

/// Deep-copy an op kind into owned allocations. The log stores independent
/// copies so the caller's borrowed slices may go out of scope freely.
fn dupKind(allocator: std.mem.Allocator, kind: TreeOpKind) !TreeOpKind {
    return switch (kind) {
        .create_node => |c| .{ .create_node = .{
            .id = c.id,
            .parent = c.parent,
            .sort = try c.sort.clone(allocator),
            .seed = try dupSeed(allocator, c.seed),
        } },
        .tombstone => |t| .{ .tombstone = t },
        .reorder => |r| .{ .reorder = .{
            .node = r.node,
            .sort = try r.sort.clone(allocator),
        } },
        .leaf_edit => |e| .{ .leaf_edit = .{
            .node = e.node,
            .prev = e.prev,
            .ops = try allocator.dupe(TextOp, e.ops),
        } },
        .split_leaf => |s| .{ .split_leaf = .{
            .node = s.node,
            .new_id = s.new_id,
            .sort = try s.sort.clone(allocator),
            .at_char = s.at_char,
            .prev = s.prev,
        } },
        .merge_leaves => |m| .{ .merge_leaves = m },
    };
}

fn freeKind(allocator: std.mem.Allocator, kind: TreeOpKind) void {
    switch (kind) {
        .create_node => |c| {
            var s = c.sort;
            s.deinit(allocator);
            freeSeed(allocator, c.seed);
        },
        .reorder => |r| {
            var s = r.sort;
            s.deinit(allocator);
        },
        .leaf_edit => |e| allocator.free(e.ops),
        .split_leaf => |s| {
            var sk = s.sort;
            sk.deinit(allocator);
        },
        .tombstone, .merge_leaves => {},
    }
}

fn dupSeed(allocator: std.mem.Allocator, seed: NodeSeed) !NodeSeed {
    return switch (seed) {
        .element => |k| .{ .element = try allocator.dupe(u8, k) },
        .leaf => |l| .{ .leaf = .{
            .kind = l.kind,
            .text = try allocator.dupe(u8, l.text),
        } },
    };
}

fn freeSeed(allocator: std.mem.Allocator, seed: NodeSeed) void {
    switch (seed) {
        .element => |k| allocator.free(k),
        .leaf => |l| allocator.free(l.text),
    }
}

// ---------------------------------------------------------------------------
// TreeOp / TreeUpdate (lossless-tree.json#/$defs/TreeOp, lossless-tree-delta.json)
// ---------------------------------------------------------------------------

/// A transport-ready tree operation: its dotted id plus the change it encodes.
pub const TreeOp = struct {
    id: OpId,
    kind: TreeOpKind,
};

/// The op-delta wire message: the output of `diff` and the input to
/// `applyUpdate`. Ops are ordered by dotted id; dependencies are buffered on
/// apply until they arrive, so delivery need not be contiguous.
pub const TreeUpdate = struct {
    ops: []const TreeOp,

    /// Canonical wire form `{"ops": [TreeOp, …]}` (externally-tagged kinds,
    /// PascalCase leaf kinds, frac as a JSON u8 array).
    pub fn jsonStringify(self: TreeUpdate, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("ops");
        try jw.beginArray();
        for (self.ops) |op| {
            try jw.beginObject();
            try jw.objectField("id");
            try writeOpId(jw, op.id);
            try jw.objectField("kind");
            try writeTreeOpKind(jw, op.kind);
            try jw.endObject();
        }
        try jw.endArray();
        try jw.endObject();
    }
};

// ---------------------------------------------------------------------------
// Dotted version frontier (DotRange / TreeVersionFrontier)
// ---------------------------------------------------------------------------

/// The observed dots for one peer: a contiguous prefix plus out-of-order holes.
/// Never a per-peer max — a hole above `contiguous` stays representable in
/// `sparse` so it is re-requested rather than skipped.
pub const DotRange = struct {
    contiguous: u64 = 0,
    sparse: std.AutoHashMapUnmanaged(u64, void) = .empty,

    pub fn deinit(self: *DotRange, allocator: std.mem.Allocator) void {
        self.sparse.deinit(allocator);
    }

    pub fn contains(self: *const DotRange, counter: u64) bool {
        if (counter <= self.contiguous) return true;
        return self.sparse.contains(counter);
    }

    pub fn observe(self: *DotRange, allocator: std.mem.Allocator, counter: u64) !void {
        if (counter <= self.contiguous) return;
        try self.sparse.put(allocator, counter, {});
        while (self.sparse.remove(self.contiguous + 1)) {
            self.contiguous += 1;
        }
    }
};

/// A dotted version frontier: per peer, exactly which op dots are held. Unlike
/// a version vector (per-peer max), this represents non-contiguous delivery so
/// `diff` never omits a missing interior op.
pub const TreeVersionFrontier = struct {
    allocator: std.mem.Allocator,
    dots: std.AutoHashMapUnmanaged(u64, DotRange) = .empty,

    pub fn init(allocator: std.mem.Allocator) TreeVersionFrontier {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TreeVersionFrontier) void {
        var it = self.dots.valueIterator();
        while (it.next()) |r| r.deinit(self.allocator);
        self.dots.deinit(self.allocator);
    }

    pub fn contains(self: *const TreeVersionFrontier, id: OpId) bool {
        const r = self.dots.get(id.peer) orelse return false;
        return r.contains(id.counter);
    }

    pub fn observe(self: *TreeVersionFrontier, id: OpId) !void {
        const gop = try self.dots.getOrPut(self.allocator, id.peer);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        try gop.value_ptr.observe(self.allocator, id.counter);
    }
};

// ---------------------------------------------------------------------------
// UTF-8 byte offset → code-point index (leaf-local, #lzlosstree Offset policy)
// ---------------------------------------------------------------------------

/// Returns the number of Unicode scalars (code points) before UTF-8 byte offset
/// `b` in `s`. Returns `error.NotOnBoundary` if `b` is out of range or lands
/// inside a multi-byte sequence. Zig strings are natively UTF-8, so this is a
/// scalar-boundary check rather than a UTF-16 conversion.
fn byteToCodePoint(s: []const u8, b: usize) error{ NotOnBoundary, OutOfBounds }!usize {
    if (b > s.len) return error.OutOfBounds;
    var i: usize = 0;
    var cp: usize = 0;
    while (i < b) {
        const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return error.NotOnBoundary;
        i += len;
        if (i > b) return error.NotOnBoundary;
        cp += 1;
    }
    return cp;
}

// ---------------------------------------------------------------------------
// Tree node storage
// ---------------------------------------------------------------------------

const NodeBody = union(enum) {
    element: []const u8, // element kind string, owned by the node's allocator
    leaf: LeafBody,

    const LeafBody = struct {
        kind: LeafKind,
        text: *TextCrdt, // heap-allocated; node owns it
    };
};

const Node = struct {
    id: OpId,
    parent: ?OpId,
    sort: SortKey,
    sort_stamp: OpId,
    body: NodeBody,
    tomb: ?OpId,
    text_head: OpId,
};

const OpIdContext = struct {
    pub fn hash(_: OpIdContext, key: OpId) u64 {
        return key.hash();
    }
    pub fn eql(_: OpIdContext, a: OpId, b: OpId) bool {
        return a.eql(b);
    }
};

fn minOpId(a: OpId, b: OpId) OpId {
    return if (a.compare(b) == .lt) a else b;
}

// ---------------------------------------------------------------------------
// LosslessTreeCrdt
// ---------------------------------------------------------------------------

/// The sentinel id of the document root: `{counter: 0, peer: 0}`. Reuses OpId;
/// the zero value is the root.
pub const root_id: OpId = .{ .counter = 0, .peer = 0 };

/// A lossless concrete-syntax tree CRDT (M1 core).
///
/// Not safe for concurrent use; wrap external access in a lock.
pub const LosslessTreeCrdt = struct {
    allocator: std.mem.Allocator,
    peer: u64,
    counter: u64,
    nodes: std.HashMap(OpId, *Node, OpIdContext, std.hash_map.default_max_load_percentage),
    frontier: TreeVersionFrontier,
    log: std.ArrayListUnmanaged(TreeOp) = .empty,
    buffered: std.ArrayListUnmanaged(TreeOp) = .empty,

    pub fn init(allocator: std.mem.Allocator, peer: u64) !LosslessTreeCrdt {
        var t = LosslessTreeCrdt{
            .allocator = allocator,
            .peer = peer,
            .counter = 0,
            .nodes = std.HashMap(OpId, *Node, OpIdContext, std.hash_map.default_max_load_percentage).init(allocator),
            .frontier = TreeVersionFrontier.init(allocator),
        };
        errdefer t.deinit();
        const root = try allocator.create(Node);
        root.* = .{
            .id = root_id,
            .parent = null,
            .sort = .{ .frac = try allocator.alloc(u8, 0), .peer = 0 },
            .sort_stamp = .{ .counter = 0, .peer = 0 },
            .body = .{ .element = try allocator.dupe(u8, "root") },
            .tomb = null,
            .text_head = .{ .counter = 0, .peer = 0 },
        };
        try t.nodes.put(root_id, root);
        return t;
    }

    pub fn deinit(self: *LosslessTreeCrdt) void {
        var nit = self.nodes.valueIterator();
        while (nit.next()) |n| freeNode(self.allocator, n.*);
        self.nodes.deinit();

        self.frontier.deinit();

        for (self.log.items) |op| freeOp(self.allocator, op);
        self.log.deinit(self.allocator);

        for (self.buffered.items) |op| freeOp(self.allocator, op);
        self.buffered.deinit(self.allocator);

        self.* = undefined;
    }

    fn nextOpId(self: *LosslessTreeCrdt) OpId {
        self.counter += 1;
        return .{ .counter = self.counter, .peer = self.peer };
    }

    pub fn getNode(self: *LosslessTreeCrdt, id: OpId) ?*Node {
        return self.nodes.get(id);
    }

    /// Live children of `parent`, in rendered (SortKey) order.
    fn liveChildren(self: *LosslessTreeCrdt, parent: OpId, allocator: std.mem.Allocator) ![]OpId {
        var kids = std.ArrayList(*Node).empty;
        defer kids.deinit(allocator);
        var it = self.nodes.valueIterator();
        while (it.next()) |n| {
            if (n.*.parent) |p| {
                if (p.eql(parent) and n.*.tomb == null) {
                    try kids.append(allocator, n.*);
                }
            }
        }
        std.mem.sort(*Node, kids.items, {}, struct {
            fn lt(_: void, a: *Node, b: *Node) bool {
                return a.sort.compare(b.sort) == .lt;
            }
        }.lt);
        const out = try allocator.alloc(OpId, kids.items.len);
        for (kids.items, 0..) |n, i| out[i] = n.id;
        return out;
    }

    /// The whole document: concatenating live-leaf text in tree order
    /// (depth-first over live children).
    pub fn render(self: *LosslessTreeCrdt, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        try self.renderInto(allocator, &out, root_id);
        return out.toOwnedSlice(allocator);
    }

    fn renderInto(
        self: *LosslessTreeCrdt,
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        id: OpId,
    ) !void {
        const n = self.nodes.get(id) orelse return;
        switch (n.body) {
            .leaf => |l| {
                const s = try l.text.text(allocator);
                defer allocator.free(s);
                try out.appendSlice(allocator, s);
            },
            .element => {
                const kids = try self.liveChildren(id, allocator);
                defer allocator.free(kids);
                for (kids) |c| try self.renderInto(allocator, out, c);
            },
        }
    }

    /// Live nodes excluding the root — grows by one on split, restored on merge.
    pub fn liveNodeCount(self: *LosslessTreeCrdt) usize {
        var n: usize = 0;
        var it = self.nodes.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.*.eql(root_id)) continue;
            if (entry.value_ptr.*.tomb != null) continue;
            n += 1;
        }
        return n;
    }

    /// This replica's dotted version frontier (what to advertise to a partner).
    pub fn getFrontier(self: *LosslessTreeCrdt) TreeVersionFrontier {
        return self.frontier;
    }

    /// Element kind of an element node, or `null` if absent or a leaf.
    pub fn elementKind(self: *LosslessTreeCrdt, node: OpId) ?[]const u8 {
        const n = self.nodes.get(node) orelse return null;
        return switch (n.body) {
            .element => |k| k,
            .leaf => null,
        };
    }

    /// Leaf kind of a leaf node, or `null` if absent or an element.
    pub fn leafKindOf(self: *LosslessTreeCrdt, node: OpId) ?LeafKind {
        const n = self.nodes.get(node) orelse return null;
        return switch (n.body) {
            .leaf => |l| l.kind,
            .element => null,
        };
    }

    /// Live children of `parent` in rendered order.
    pub fn children(self: *LosslessTreeCrdt, allocator: std.mem.Allocator, parent: OpId) ![]OpId {
        return self.liveChildren(parent, allocator);
    }

    /// A leaf's current text. Returns `error.NotALeaf` / `error.NodeNotFound`.
    pub fn leafText(self: *LosslessTreeCrdt, node: OpId, allocator: std.mem.Allocator) ![]u8 {
        const n = self.nodes.get(node) orelse return error.NodeNotFound;
        return switch (n.body) {
            .leaf => |l| try l.text.text(allocator),
            .element => error.NotALeaf,
        };
    }

    /// Compute a SortKey for a new/reordered child positioned just after
    /// `after` (front when null). Mirrors the lazily-go `keyAfter`.
    fn keyAfter(self: *LosslessTreeCrdt, parent: OpId, after: ?OpId) !SortKey {
        const order = try self.liveChildren(parent, self.allocator);
        defer self.allocator.free(order);
        var lo: ?[]const u8 = null;
        var hi: ?[]const u8 = null;
        if (after) |a| {
            var idx: ?usize = null;
            for (order, 0..) |id, i| {
                if (id.eql(a)) {
                    idx = i;
                    break;
                }
            }
            if (idx) |i| {
                lo = self.nodes.get(order[i]).?.sort.frac;
                if (i + 1 < order.len) hi = self.nodes.get(order[i + 1]).?.sort.frac;
            } else if (order.len > 0) {
                lo = self.nodes.get(order[order.len - 1]).?.sort.frac;
            }
        } else if (order.len > 0) {
            hi = self.nodes.get(order[0]).?.sort.frac;
        }
        const frac = try seq_crdt.keyBetween(self.allocator, lo, hi);
        return .{ .frac = frac, .peer = self.peer };
    }

    /// Create a node under `parent`, positioned after `after` (front when
    /// null), and return the new node's id.
    pub fn createNode(self: *LosslessTreeCrdt, parent: OpId, after: ?OpId, seed: NodeSeed) !OpId {
        if (self.nodes.get(parent) == null) return error.ParentNotFound;
        var sort = try self.keyAfter(parent, after);
        defer sort.deinit(self.allocator);
        const op_id = self.nextOpId();
        const node_id = op_id;
        try self.commitLocal(.{
            .id = op_id,
            .kind = .{ .create_node = .{
                .id = node_id,
                .parent = parent,
                .sort = sort,
                .seed = seed,
            } },
        });
        return node_id;
    }

    /// Tombstone a node (its subtree renders away once the ancestor is gone).
    pub fn tombstoneNode(self: *LosslessTreeCrdt, node: OpId) !void {
        if (node.eql(root_id)) return error.CannotTombstoneRoot;
        if (self.nodes.get(node) == null) return error.NodeNotFound;
        const op_id = self.nextOpId();
        try self.commitLocal(.{
            .id = op_id,
            .kind = .{ .tombstone = .{ .node = node } },
        });
    }

    /// Reorder `node` within its parent to just after `after` (front when null).
    pub fn reorderChild(self: *LosslessTreeCrdt, node: OpId, after: ?OpId) !void {
        const rec = self.nodes.get(node) orelse return error.NodeNotFound;
        const parent = rec.parent orelse return error.NodeNotFound;
        var sort = try self.keyAfter(parent, after);
        defer sort.deinit(self.allocator);
        const op_id = self.nextOpId();
        try self.commitLocal(.{
            .id = op_id,
            .kind = .{ .reorder = .{ .node = node, .sort = sort } },
        });
    }

    /// Edit a leaf's text: delete `delete_bytes` and insert `insert` at UTF-8
    /// byte offset `at_byte` (leaf-local). Offsets must land on scalar
    /// boundaries. Re-owns the leaf's text under this replica so concurrent
    /// edits from different peers mint distinct char ids.
    pub fn editLeaf(self: *LosslessTreeCrdt, node: OpId, at_byte: usize, delete_bytes: usize, insert: []const u8) !void {
        const rec = self.nodes.get(node) orelse return error.NodeNotFound;
        if (rec.body != .leaf) return error.NotALeaf;
        const text_ptr = rec.body.leaf.text; // *TextCrdt (heap slot, mutable through .*)
        const cur = try text_ptr.text(self.allocator);
        defer self.allocator.free(cur);
        const start = try byteToCodePoint(cur, at_byte);
        const end = try byteToCodePoint(cur, at_byte + delete_bytes);
        const delete_count = end - start;

        // Re-own the leaf's text under this replica so concurrent edits from
        // different peers mint distinct char ids (no collision on merge).
        const forked = try text_ptr.fork(self.peer);
        text_ptr.deinit();
        text_ptr.* = forked;

        var vv = try text_ptr.versionVector(self.allocator);
        defer vv.deinit();
        var i: usize = 0;
        while (i < delete_count) : (i += 1) {
            try text_ptr.delete(start);
        }
        try text_ptr.insertStr(start, insert);
        const ops = try text_ptr.deltaSince(&vv, self.allocator);

        const prev = rec.text_head;
        const op_id = self.nextOpId();
        try self.commitLocal(.{
            .id = op_id,
            .kind = .{ .leaf_edit = .{ .node = node, .prev = prev, .ops = ops } },
        });
        self.allocator.free(ops);
    }

    /// Split a leaf at UTF-8 byte offset `at_byte` into two adjacent leaves of
    /// the same kind (head keeps `node`, tail is a fresh node returned here).
    pub fn splitLeaf(self: *LosslessTreeCrdt, node: OpId, at_byte: usize) !OpId {
        const rec = self.nodes.get(node) orelse return error.NodeNotFound;
        const leaf = switch (rec.body) {
            .leaf => |l| l,
            .element => return error.NotALeaf,
        };
        const parent = rec.parent orelse return error.NodeNotFound;
        const cur = try leaf.text.text(self.allocator);
        defer self.allocator.free(cur);
        const at_char = try byteToCodePoint(cur, at_byte);
        var sort = try self.keyAfter(parent, node);
        defer sort.deinit(self.allocator);
        const prev = rec.text_head;
        const op_id = self.nextOpId();
        const new_node = op_id;
        try self.commitLocal(.{
            .id = op_id,
            .kind = .{ .split_leaf = .{
                .node = node,
                .new_id = new_node,
                .sort = sort,
                .at_char = at_char,
                .prev = prev,
            } },
        });
        return new_node;
    }

    /// Merge `right` into `left` when they are adjacent live leaf siblings.
    pub fn mergeAdjacentLeaves(self: *LosslessTreeCrdt, left: OpId, right: OpId) !void {
        const lrec = self.nodes.get(left) orelse return error.NodeNotFound;
        const rrec = self.nodes.get(right) orelse return error.NodeNotFound;
        if (lrec.body != .leaf or rrec.body != .leaf) return error.NotALeaf;
        const parent = lrec.parent orelse return error.NodeNotFound;
        if (rrec.parent == null or !rrec.parent.?.eql(parent)) return error.NotSiblings;

        const order = try self.liveChildren(parent, self.allocator);
        defer self.allocator.free(order);
        var idx: ?usize = null;
        for (order, 0..) |id, i| {
            if (id.eql(left)) {
                idx = i;
                break;
            }
        }
        const adjacent = if (idx) |i|
            (i + 1 < order.len and order[i + 1].eql(right))
        else
            false;
        if (!adjacent) return error.NotAdjacent;

        const prev_left = lrec.text_head;
        const prev_right = rrec.text_head;
        const op_id = self.nextOpId();
        try self.commitLocal(.{
            .id = op_id,
            .kind = .{ .merge_leaves = .{
                .left = left,
                .right = right,
                .prev_left = prev_left,
                .prev_right = prev_right,
            } },
        });
    }

    /// Deep-copy this replica's full state under a new owning peer.
    pub fn fork(self: *const LosslessTreeCrdt, peer: u64) !LosslessTreeCrdt {
        var out = try LosslessTreeCrdt.init(self.allocator, peer);
        errdefer out.deinit();
        out.counter = self.counter;

        // `init` seeded a root; free it so the deep copies below own every
        // entry (no aliasing, no leak when the copy replaces the slot).
        if (out.nodes.fetchRemove(root_id)) |kv| freeNode(self.allocator, kv.value);

        var nit = self.nodes.valueIterator();
        while (nit.next()) |n| {
            const copy = try self.allocator.create(Node);
            copy.* = .{
                .id = n.*.id,
                .parent = n.*.parent,
                .sort = try n.*.sort.clone(self.allocator),
                .sort_stamp = n.*.sort_stamp,
                .body = switch (n.*.body) {
                    .element => |k| .{ .element = try self.allocator.dupe(u8, k) },
                    .leaf => |l| .{ .leaf = .{
                        .kind = l.kind,
                        .text = blk: {
                            const t = try self.allocator.create(TextCrdt);
                            // Same-peer deep copy: a leaf's text keeps its create
                            // peer so char ids stay identical across forks.
                            t.* = try l.text.fork(l.text.peer);
                            break :blk t;
                        },
                    } },
                },
                .tomb = n.*.tomb,
                .text_head = n.*.text_head,
            };
            try out.nodes.put(n.*.id, copy);
        }

        // Frontier: rebuild by re-observing every held op id (cheaper than a
        // deep map copy and avoids private field churn).
        var fit = self.frontier.dots.iterator();
        while (fit.next()) |entry| {
            const peer_id = entry.key_ptr.*;
            const range = entry.value_ptr.*;
            var c: u64 = 1;
            while (c <= range.contiguous) : (c += 1) {
                try out.frontier.observe(.{ .counter = c, .peer = peer_id });
            }
            var sit = range.sparse.iterator();
            while (sit.next()) |sentry| {
                try out.frontier.observe(.{ .counter = sentry.key_ptr.*, .peer = peer_id });
            }
        }

        for (self.log.items) |op| try out.log.append(self.allocator, try dupOp(self.allocator, op));
        for (self.buffered.items) |op| try out.buffered.append(self.allocator, try dupOp(self.allocator, op));
        return out;
    }

    /// Ops this replica holds that `their` frontier lacks, ordered by dotted id.
    pub fn diff(self: *LosslessTreeCrdt, their: *const TreeVersionFrontier, allocator: std.mem.Allocator) !TreeUpdate {
        var out = std.ArrayList(TreeOp).empty;
        errdefer {
            for (out.items) |op| freeOp(allocator, op);
            out.deinit(allocator);
        }
        for (self.log.items) |op| {
            if (!their.contains(op.id)) {
                try out.append(allocator, try dupOp(allocator, op));
            }
        }
        std.mem.sort(TreeOp, out.items, {}, struct {
            fn lt(_: void, a: TreeOp, b: TreeOp) bool {
                return a.id.compare(b.id) == .lt;
            }
        }.lt);
        return .{ .ops = try out.toOwnedSlice(allocator) };
    }

    /// Apply a batch of remote ops. Idempotent (already-held ops skipped) and
    /// order-tolerant (an op whose target/parent has not arrived is buffered
    /// and retried). Advances the Lamport counter past every observed op.
    pub fn applyUpdate(self: *LosslessTreeCrdt, update: TreeUpdate) !void {
        for (update.ops) |op| {
            if (op.id.counter > self.counter) self.counter = op.id.counter;
            if (self.frontier.contains(op.id)) continue;
            try self.buffered.append(self.allocator, try dupOp(self.allocator, op));
        }
        try self.drainBuffered();
    }

    /// Free a `TreeUpdate` produced by `diff` (its ops are owned copies).
    pub fn freeUpdate(self: *LosslessTreeCrdt, update: TreeUpdate) void {
        for (update.ops) |op| freeOp(self.allocator, op);
        self.allocator.free(update.ops);
    }

    fn drainBuffered(self: *LosslessTreeCrdt) !void {
        while (true) {
            var progressed = false;
            var pending = self.buffered;
            self.buffered = .empty;
            var leftover = std.ArrayListUnmanaged(TreeOp).empty;
            errdefer leftover.deinit(self.allocator);
            for (pending.items) |op| {
                if (self.frontier.contains(op.id)) {
                    freeOp(self.allocator, op);
                    continue;
                }
                if (try self.dependenciesReady(op)) {
                    self.applyOp(op);
                    try self.record(op);
                    freeOp(self.allocator, op);
                    progressed = true;
                } else {
                    try leftover.append(self.allocator, op);
                }
            }
            self.buffered = leftover;
            pending.deinit(self.allocator);
            if (!progressed) break;
        }
    }

    fn dependenciesReady(self: *LosslessTreeCrdt, op: TreeOp) !bool {
        return switch (op.kind) {
            .create_node => |c| self.nodes.contains(c.parent),
            .tombstone => |t| self.nodes.contains(t.node),
            .reorder => |r| self.nodes.contains(r.node),
            .leaf_edit => |e| self.nodes.contains(e.node) and self.frontier.contains(e.prev),
            .split_leaf => |s| self.nodes.contains(s.node) and self.frontier.contains(s.prev),
            .merge_leaves => |m| self.nodes.contains(m.left) and self.nodes.contains(m.right) and self.frontier.contains(m.prev_left) and self.frontier.contains(m.prev_right),
        };
    }

    fn commitLocal(self: *LosslessTreeCrdt, op: TreeOp) !void {
        self.applyOp(op);
        try self.record(op);
    }

    fn record(self: *LosslessTreeCrdt, op: TreeOp) !void {
        try self.frontier.observe(op.id);
        try self.log.append(self.allocator, try dupOp(self.allocator, op));
    }

    fn applyOp(self: *LosslessTreeCrdt, op: TreeOp) void {
        switch (op.kind) {
            .create_node => |c| {
                if (self.nodes.contains(c.id)) return;
                const body: NodeBody = switch (c.seed) {
                    .element => |k| blk: {
                        const dup = self.allocator.dupe(u8, k) catch return;
                        break :blk NodeBody{ .element = dup };
                    },
                    .leaf => |l| blk: {
                        const t = self.allocator.create(TextCrdt) catch return;
                        t.* = TextCrdt.fromStr(self.allocator, c.id.peer, l.text) catch return;
                        break :blk NodeBody{ .leaf = .{ .kind = l.kind, .text = t } };
                    },
                };
                const n = self.allocator.create(Node) catch return;
                n.* = .{
                    .id = c.id,
                    .parent = c.parent,
                    .sort = c.sort.clone(self.allocator) catch return,
                    .sort_stamp = op.id,
                    .body = body,
                    .tomb = null,
                    .text_head = op.id,
                };
                self.nodes.put(c.id, n) catch return;
            },
            .tombstone => |t| {
                if (self.nodes.getPtr(t.node)) |slot| {
                    const cur = slot.*.tomb;
                    slot.*.tomb = if (cur) |c| minOpId(c, op.id) else op.id;
                }
            },
            .reorder => |r| {
                if (self.nodes.getPtr(r.node)) |slot| {
                    if (op.id.compare(slot.*.sort_stamp) == .gt) {
                        slot.*.sort.deinit(self.allocator);
                        slot.*.sort = r.sort.clone(self.allocator) catch return;
                        slot.*.sort_stamp = op.id;
                    }
                }
            },
            .leaf_edit => |e| {
                if (self.nodes.getPtr(e.node)) |slot| {
                    if (slot.*.body == .leaf) {
                        _ = slot.*.body.leaf.text.applyDelta(e.ops) catch return;
                        slot.*.text_head = op.id;
                    }
                }
            },
            .split_leaf => |s| self.applySplit(s.node, s.new_id, s.sort, s.at_char, op.id),
            .merge_leaves => |m| self.applyMerge(m.left, m.right, op.id),
        }
    }

    fn applySplit(self: *LosslessTreeCrdt, node: OpId, new_node: OpId, sort: SortKey, at_char: usize, op_id: OpId) void {
        const slot = self.nodes.getPtr(node) orelse return;
        const rec: *Node = slot.*;
        if (rec.body != .leaf) return;
        const leaf = rec.body.leaf;
        const parent = rec.parent;
        const text = leaf.text.text(self.allocator) catch return;
        defer self.allocator.free(text);
        // Code-point slice via a byte-aware scan.
        var head_buf = std.ArrayList(u8).empty;
        defer head_buf.deinit(self.allocator);
        var tail_buf = std.ArrayList(u8).empty;
        defer tail_buf.deinit(self.allocator);
        var cp_idx: usize = 0;
        var bi: usize = 0;
        while (bi < text.len) {
            const len = std.unicode.utf8ByteSequenceLength(text[bi]) catch return;
            const dst = if (cp_idx < at_char) &head_buf else &tail_buf;
            dst.appendSlice(self.allocator, text[bi .. bi + len]) catch return;
            cp_idx += 1;
            bi += len;
        }

        // Reseed head under the original node's create peer so both replicas
        // rebuild byte-identical leaf state.
        leaf.text.deinit();
        leaf.text.* = TextCrdt.fromStr(self.allocator, node.peer, head_buf.items) catch return;
        rec.text_head = op_id;

        if (!self.nodes.contains(new_node)) {
            const t = self.allocator.create(TextCrdt) catch return;
            t.* = TextCrdt.fromStr(self.allocator, new_node.peer, tail_buf.items) catch return;
            const n = self.allocator.create(Node) catch return;
            n.* = .{
                .id = new_node,
                .parent = parent,
                .sort = sort.clone(self.allocator) catch return,
                .sort_stamp = op_id,
                .body = .{ .leaf = .{ .kind = leaf.kind, .text = t } },
                .tomb = null,
                .text_head = op_id,
            };
            self.nodes.put(new_node, n) catch return;
        }
    }

    fn applyMerge(self: *LosslessTreeCrdt, left: OpId, right: OpId, op_id: OpId) void {
        const lslot = self.nodes.getPtr(left) orelse return;
        const rslot = self.nodes.getPtr(right) orelse return;
        const lrec: *Node = lslot.*;
        const rrec: *Node = rslot.*;
        if (lrec.body != .leaf or rrec.body != .leaf) return;
        const lt = lrec.body.leaf.text.text(self.allocator) catch return;
        defer self.allocator.free(lt);
        const rt = rrec.body.leaf.text.text(self.allocator) catch return;
        defer self.allocator.free(rt);
        const combined = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ lt, rt }) catch return;
        defer self.allocator.free(combined);
        lrec.body.leaf.text.deinit();
        lrec.body.leaf.text.* = TextCrdt.fromStr(self.allocator, left.peer, combined) catch return;
        lrec.text_head = op_id;
        const cur = rrec.tomb;
        rrec.tomb = if (cur) |c| minOpId(c, op_id) else op_id;
    }
};

// ---------------------------------------------------------------------------
// Ownership helpers
// ---------------------------------------------------------------------------

fn freeNode(allocator: std.mem.Allocator, n: *Node) void {
    n.sort.deinit(allocator);
    switch (n.body) {
        .element => |k| allocator.free(k),
        .leaf => |l| {
            l.text.deinit();
            allocator.destroy(l.text);
        },
    }
    allocator.destroy(n);
}

pub fn dupOp(allocator: std.mem.Allocator, op: TreeOp) !TreeOp {
    return .{ .id = op.id, .kind = try dupKind(allocator, op.kind) };
}

pub fn freeOp(allocator: std.mem.Allocator, op: TreeOp) void {
    freeKind(allocator, op.kind);
}

// ---------------------------------------------------------------------------
// Wire JSON (lossless-tree.json + lossless-tree-delta.json). Normative form:
// externally-tagged op / seed variants, PascalCase leaf kinds, frac as a JSON
// u8 array (never base64).
// ---------------------------------------------------------------------------

fn singleTagged(value: std.json.Value) !TaggedValue {
    switch (value) {
        .object => |object| {
            if (object.count() != 1) return error.ExpectedSingleFieldObject;
            var it = object.iterator();
            const entry = it.next() orelse return error.ExpectedSingleFieldObject;
            return .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* };
        },
        else => return error.ExpectedObject,
    }
}

const TaggedValue = struct {
    name: []const u8,
    value: std.json.Value,
};

fn jfield(value: std.json.Value, name: []const u8) !std.json.Value {
    return switch (value) {
        .object => |o| o.get(name) orelse error.MissingField,
        else => error.ExpectedObject,
    };
}

fn jobj(value: ?std.json.Value) ?std.json.Value {
    if (value) |v| return switch (v) {
        .null => null,
        .object => v,
        else => null,
    };
    return null;
}

fn jstr(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}

fn ju64(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |n| if (n >= 0) @as(u64, @intCast(n)) else error.ExpectedUnsignedInteger,
        .number_string => |s| try std.fmt.parseInt(u64, s, 10),
        else => error.ExpectedUnsignedInteger,
    };
}

fn joptStr(allocator: std.mem.Allocator, value: ?std.json.Value) !?[]const u8 {
    if (value) |v| switch (v) {
        .null => return null,
        .string => |s| return try allocator.dupe(u8, s),
        else => return error.ExpectedStringOrNull,
    };
    return null;
}

fn jarray(value: std.json.Value) ![]const std.json.Value {
    return switch (value) {
        .array => |a| a.items,
        else => return error.ExpectedArray,
    };
}

fn opIdFromJson(value: std.json.Value) !OpId {
    return .{
        .counter = try ju64(try jfield(value, "counter")),
        .peer = try ju64(try jfield(value, "peer")),
    };
}

fn sortKeyFromJson(allocator: std.mem.Allocator, value: std.json.Value) !SortKey {
    const frac_arr = try jarray(try jfield(value, "frac"));
    const frac = try allocator.alloc(u8, frac_arr.len);
    for (frac_arr, frac) |fv, *out| {
        const n = try ju64(fv);
        if (n > 255) return error.FracOutOfRange;
        out.* = @intCast(n);
    }
    return .{ .frac = frac, .peer = try ju64(try jfield(value, "peer")) };
}

fn nodeSeedFromJson(allocator: std.mem.Allocator, value: std.json.Value) !NodeSeed {
    const tagged = try singleTagged(value);
    if (std.mem.eql(u8, tagged.name, "Element")) {
        return .{ .element = try allocator.dupe(u8, try jstr(try jfield(tagged.value, "kind"))) };
    }
    if (std.mem.eql(u8, tagged.name, "Leaf")) {
        return .{ .leaf = .{
            .kind = try LeafKind.fromWireName(try jstr(try jfield(tagged.value, "kind"))),
            .text = try allocator.dupe(u8, try jstr(try jfield(tagged.value, "text"))),
        } };
    }
    return error.UnknownNodeSeed;
}

fn textOpFromJson(value: std.json.Value) !TextOp {
    const ch_str = try jstr(try jfield(value, "ch"));
    var view = std.unicode.Utf8View.init(ch_str) catch return error.BadTextOpCh;
    var it = view.iterator();
    const cp = it.nextCodepoint() orelse return error.BadTextOpCh;
    return .{
        .id = try opIdFromJson(try jfield(value, "id")),
        .ch = cp,
        .origin = try optionalOpIdFromJson(try jfield(value, "origin")),
        .deleted = try optionalOpIdFromJson(try jfield(value, "deleted")),
    };
}

fn optionalOpIdFromJson(value: std.json.Value) !?OpId {
    switch (value) {
        .null => return null,
        .object => return try opIdFromJson(value),
        else => return error.ExpectedObjectOrNull,
    }
}

fn treeOpKindFromJson(allocator: std.mem.Allocator, value: std.json.Value) !TreeOpKind {
    const tagged = try singleTagged(value);
    if (std.mem.eql(u8, tagged.name, "CreateNode")) {
        const seed_raw = try jfield(tagged.value, "seed");
        return .{ .create_node = .{
            .id = try opIdFromJson(try jfield(tagged.value, "id")),
            .parent = try opIdFromJson(try jfield(tagged.value, "parent")),
            .sort = try sortKeyFromJson(allocator, try jfield(tagged.value, "sort")),
            .seed = try nodeSeedFromJson(allocator, seed_raw),
        } };
    }
    if (std.mem.eql(u8, tagged.name, "Tombstone")) {
        return .{ .tombstone = .{ .node = try opIdFromJson(try jfield(tagged.value, "node")) } };
    }
    if (std.mem.eql(u8, tagged.name, "Reorder")) {
        return .{ .reorder = .{
            .node = try opIdFromJson(try jfield(tagged.value, "node")),
            .sort = try sortKeyFromJson(allocator, try jfield(tagged.value, "sort")),
        } };
    }
    if (std.mem.eql(u8, tagged.name, "LeafEdit")) {
        const ops_arr = try jarray(try jfield(tagged.value, "ops"));
        const ops = try allocator.alloc(TextOp, ops_arr.len);
        for (ops_arr, ops) |ov, *out| out.* = try textOpFromJson(ov);
        return .{ .leaf_edit = .{
            .node = try opIdFromJson(try jfield(tagged.value, "node")),
            .prev = try opIdFromJson(try jfield(tagged.value, "prev")),
            .ops = ops,
        } };
    }
    if (std.mem.eql(u8, tagged.name, "SplitLeaf")) {
        return .{ .split_leaf = .{
            .node = try opIdFromJson(try jfield(tagged.value, "node")),
            .new_id = try opIdFromJson(try jfield(tagged.value, "new")),
            .sort = try sortKeyFromJson(allocator, try jfield(tagged.value, "sort")),
            .at_char = try ju64(try jfield(tagged.value, "at_char")),
            .prev = try opIdFromJson(try jfield(tagged.value, "prev")),
        } };
    }
    if (std.mem.eql(u8, tagged.name, "MergeLeaves")) {
        return .{ .merge_leaves = .{
            .left = try opIdFromJson(try jfield(tagged.value, "left")),
            .right = try opIdFromJson(try jfield(tagged.value, "right")),
            .prev_left = try opIdFromJson(try jfield(tagged.value, "prev_left")),
            .prev_right = try opIdFromJson(try jfield(tagged.value, "prev_right")),
        } };
    }
    return error.UnknownTreeOpKind;
}

/// Decode a `TreeUpdate` (`{"ops": [TreeOp, …]}`) from its canonical JSON.
/// All slices are owned by `allocator`; pass the result to `freeTreeUpdate`.
pub fn treeUpdateFromJson(allocator: std.mem.Allocator, value: std.json.Value) !TreeUpdate {
    const ops_arr = try jarray(try jfield(value, "ops"));
    const ops = try allocator.alloc(TreeOp, ops_arr.len);
    for (ops_arr, ops) |ov, *out| {
        out.* = .{
            .id = try opIdFromJson(try jfield(ov, "id")),
            .kind = try treeOpKindFromJson(allocator, try jfield(ov, "kind")),
        };
    }
    return .{ .ops = ops };
}

pub fn freeTreeUpdate(allocator: std.mem.Allocator, update: TreeUpdate) void {
    for (update.ops) |op| freeOp(allocator, op);
    allocator.free(update.ops);
}

fn writeOpId(jw: anytype, id: OpId) !void {
    try jw.beginObject();
    try jw.objectField("counter");
    try jw.write(id.counter);
    try jw.objectField("peer");
    try jw.write(id.peer);
    try jw.endObject();
}

fn writeOptOpId(jw: anytype, id: ?OpId) !void {
    if (id) |op| {
        try writeOpId(jw, op);
    } else {
        try jw.write(null);
    }
}

fn writeSortKey(jw: anytype, key: SortKey) !void {
    try jw.beginObject();
    try jw.objectField("frac");
    try jw.beginArray();
    for (key.frac) |b| try jw.write(b);
    try jw.endArray();
    try jw.objectField("peer");
    try jw.write(key.peer);
    try jw.endObject();
}

fn writeNodeSeed(jw: anytype, seed: NodeSeed) !void {
    switch (seed) {
        .element => |k| {
            try jw.beginObject();
            try jw.objectField("Element");
            try jw.beginObject();
            try jw.objectField("kind");
            try jw.write(k);
            try jw.endObject();
            try jw.endObject();
        },
        .leaf => |l| {
            try jw.beginObject();
            try jw.objectField("Leaf");
            try jw.beginObject();
            try jw.objectField("kind");
            try jw.write(l.kind.wireName());
            try jw.objectField("text");
            try jw.write(l.text);
            try jw.endObject();
            try jw.endObject();
        },
    }
}

fn writeTextOp(jw: anytype, op: TextOp) !void {
    // `ch` is always a valid decoded scalar, so utf8Encode cannot fail.
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(op.ch, &buf) catch unreachable;
    try jw.beginObject();
    try jw.objectField("id");
    try writeOpId(jw, op.id);
    try jw.objectField("ch");
    try jw.write(buf[0..n]);
    try jw.objectField("origin");
    try writeOptOpId(jw, op.origin);
    try jw.objectField("deleted");
    try writeOptOpId(jw, op.deleted);
    try jw.endObject();
}

fn writeTreeOpKind(jw: anytype, kind: TreeOpKind) !void {
    switch (kind) {
        .create_node => |c| {
            try jw.beginObject();
            try jw.objectField("CreateNode");
            try jw.beginObject();
            try jw.objectField("id");
            try writeOpId(jw, c.id);
            try jw.objectField("parent");
            try writeOpId(jw, c.parent);
            try jw.objectField("sort");
            try writeSortKey(jw, c.sort);
            try jw.objectField("seed");
            try writeNodeSeed(jw, c.seed);
            try jw.endObject();
            try jw.endObject();
        },
        .tombstone => |t| {
            try jw.beginObject();
            try jw.objectField("Tombstone");
            try jw.beginObject();
            try jw.objectField("node");
            try writeOpId(jw, t.node);
            try jw.endObject();
            try jw.endObject();
        },
        .reorder => |r| {
            try jw.beginObject();
            try jw.objectField("Reorder");
            try jw.beginObject();
            try jw.objectField("node");
            try writeOpId(jw, r.node);
            try jw.objectField("sort");
            try writeSortKey(jw, r.sort);
            try jw.endObject();
            try jw.endObject();
        },
        .leaf_edit => |e| {
            try jw.beginObject();
            try jw.objectField("LeafEdit");
            try jw.beginObject();
            try jw.objectField("node");
            try writeOpId(jw, e.node);
            try jw.objectField("prev");
            try writeOpId(jw, e.prev);
            try jw.objectField("ops");
            try jw.beginArray();
            for (e.ops) |op| try writeTextOp(jw, op);
            try jw.endArray();
            try jw.endObject();
            try jw.endObject();
        },
        .split_leaf => |s| {
            try jw.beginObject();
            try jw.objectField("SplitLeaf");
            try jw.beginObject();
            try jw.objectField("node");
            try writeOpId(jw, s.node);
            try jw.objectField("new");
            try writeOpId(jw, s.new_id);
            try jw.objectField("sort");
            try writeSortKey(jw, s.sort);
            try jw.objectField("at_char");
            try jw.write(s.at_char);
            try jw.objectField("prev");
            try writeOpId(jw, s.prev);
            try jw.endObject();
            try jw.endObject();
        },
        .merge_leaves => |m| {
            try jw.beginObject();
            try jw.objectField("MergeLeaves");
            try jw.beginObject();
            try jw.objectField("left");
            try writeOpId(jw, m.left);
            try jw.objectField("right");
            try writeOpId(jw, m.right);
            try jw.objectField("prev_left");
            try writeOpId(jw, m.prev_left);
            try jw.objectField("prev_right");
            try writeOpId(jw, m.prev_right);
            try jw.endObject();
            try jw.endObject();
        },
    }
}

/// Encode a `TreeUpdate` to its canonical JSON (owned by `allocator`). Uses the
/// same `Stringify.valueAlloc` path as the rest of the codebase, driving the
/// externally-tagged wire form via `TreeUpdate.jsonStringify`.
pub fn treeUpdateToJson(allocator: std.mem.Allocator, update: TreeUpdate) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, update, .{});
}
