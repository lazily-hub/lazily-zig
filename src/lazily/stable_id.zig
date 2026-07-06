const std = @import("std");

/// FNV-1a (64-bit) over normalized text. Deterministic across runs and
/// languages (matches lazily-kt and lazily-js; Rust uses `DefaultHasher` which
/// is per-process random — the spec pins only "content-derived hashes of
/// normalized text", not the algorithm). The Zig ecosystem already uses
/// FNV-1a-64 for `ShmBlobArena` checksums.
const FNV_OFFSET_BASIS: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

pub fn contentHash(text: []const u8) u64 {
    var h: u64 = FNV_OFFSET_BASIS;
    // Normalize: split on ASCII whitespace runs, join with single space.
    var it = std.mem.tokenizeAny(u8, text, " \t\n\r\x0c\x0b");
    var first = true;
    while (it.next()) |tok| {
        if (!first) h = (h ^ ' ') *% FNV_PRIME;
        for (tok) |b| h = (h ^ @as(u64, b)) *% FNV_PRIME;
        first = false;
    }
    return h;
}

/// A text block with an optional in-band anchor. Anchored keys survive body
/// rewrite; content keys survive reflow/reorder but change on edit.
pub const Block = struct {
    anchor: ?[]const u8 = null,
    text: []const u8,
};

/// Manufactured stable key. `a:`/`c:` prefix keeps anchored and content
/// keyspaces disjoint.
pub const BlockKey = union(enum) {
    anchored: []const u8,
    content: u64,

    pub fn fromBlock(b: Block) BlockKey {
        if (b.anchor) |a| return .{ .anchored = a };
        return .{ .content = contentHash(b.text) };
    }

    /// Stable string form. Writes into `buf`; returns the slice used.
    /// For content keys, requires a 18-byte buffer (`c:` + 16 hex digits).
    pub fn writeString(self: BlockKey, buf: []u8) []const u8 {
        switch (self) {
            .anchored => |a| {
                std.debug.assert(buf.len >= 2 + a.len);
                buf[0] = 'a';
                buf[1] = ':';
                @memcpy(buf[2 .. 2 + a.len], a);
                return buf[0 .. 2 + a.len];
            },
            .content => |h| {
                std.debug.assert(buf.len >= 18);
                buf[0] = 'c';
                buf[1] = ':';
                _ = std.fmt.bufPrint(buf[2..18], "{x:0>16}", .{h}) catch unreachable;
                return buf[0..18];
            },
        }
    }

    pub fn eqlString(self: BlockKey, other: BlockKey) bool {
        return switch (self) {
            .anchored => |a| switch (other) {
                .anchored => |b| std.mem.eql(u8, a, b),
                else => false,
            },
            .content => |a| switch (other) {
                .content => |b| a == b,
                else => false,
            },
        };
    }
};

/// Match classification for aligning a new block against an old sequence.
pub const Match = union(enum) {
    same: usize, // exact key match — key inherited unchanged
    edited: struct { old: usize, similarity: f32 }, // similarity match, content changed
    inserted, // no match — genuine insert
};

pub const Alignment = struct {
    new_matches: []Match,
    removed: []usize,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Alignment) void {
        self.allocator.free(self.new_matches);
        self.allocator.free(self.removed);
    }
};

/// Similarity = 2·|word-LCS| / (|a|+|b|) over whitespace-tokenized text.
pub fn similarity(a: []const u8, b: []const u8, allocator: std.mem.Allocator) !f32 {
    var aw = std.ArrayList([]const u8).empty;
    defer aw.deinit(allocator);
    var bw = std.ArrayList([]const u8).empty;
    defer bw.deinit(allocator);
    var it_a = std.mem.tokenizeAny(u8, a, " \t\n\r\x0c\x0b");
    while (it_a.next()) |t| try aw.append(allocator, t);
    var it_b = std.mem.tokenizeAny(u8, b, " \t\n\r\x0c\x0b");
    while (it_b.next()) |t| try bw.append(allocator, t);

    if (aw.items.len == 0 and bw.items.len == 0) return 1.0;
    const lcs = try lcsLen(allocator, aw.items, bw.items);
    return (2.0 * @as(f32, @floatFromInt(lcs))) / @as(f32, @floatFromInt(aw.items.len + bw.items.len));
}

fn lcsLen(allocator: std.mem.Allocator, a: []const []const u8, b: []const []const u8) !usize {
    var dp = try allocator.alloc(usize, b.len + 1);
    defer allocator.free(dp);
    @memset(dp, 0);
    for (a) |x| {
        var prev: usize = 0;
        for (b, 0..) |y, j| {
            const cur = dp[j + 1];
            dp[j + 1] = if (std.mem.eql(u8, x, y)) prev + 1 else @max(dp[j + 1], dp[j]);
            prev = cur;
        }
    }
    return dp[b.len];
}

pub const EDIT_THRESHOLD: f32 = 0.5;

/// Two-pass alignment. Pass 1: exact key match, left-to-right (duplicates pair
/// deterministically). Pass 2: similarity match (best wins, nearest-index
/// breaks ties) ≥ EDIT_THRESHOLD ⇒ Edited, else Inserted.
pub fn alignBlocks(allocator: std.mem.Allocator, old: []const Block, new: []const Block) !Alignment {
    const old_keys = try allocator.alloc(BlockKey, old.len);
    defer allocator.free(old_keys);
    for (old, old_keys) |b, *k| k.* = BlockKey.fromBlock(b);

    const new_keys = try allocator.alloc(BlockKey, new.len);
    defer allocator.free(new_keys);
    for (new, new_keys) |b, *k| k.* = BlockKey.fromBlock(b);

    var old_used = try allocator.alloc(bool, old.len);
    defer allocator.free(old_used);
    @memset(old_used, false);

    const matches = try allocator.alloc(Match, new.len);
    errdefer allocator.free(matches);
    for (matches) |*m| m.* = .inserted;

    // Pass 1: exact key match.
    for (new_keys, 0..) |nk, ni| {
        var oi: usize = 0;
        while (oi < old.len) : (oi += 1) {
            if (!old_used[oi] and old_keys[oi].eqlString(nk)) {
                old_used[oi] = true;
                matches[ni] = .{ .same = oi };
                break;
            }
        }
    }

    // Pass 2: similarity match.
    for (new, 0..) |nb, ni| {
        if (matches[ni] != .inserted) continue;
        // Skip if this block has an anchor (already pass-1 matched or unique).
        var best: ?struct { oi: usize, sim: f32 } = null;
        var oi: usize = 0;
        while (oi < old.len) : (oi += 1) {
            if (old_used[oi]) continue;
            const sim = try similarity(nb.text, old[oi].text, allocator);
            const better = if (best) |bs| blk: {
                if (sim > bs.sim) break :blk true;
                if (sim == bs.sim) {
                    const dist_new = @as(isize, @intCast(oi)) - @as(isize, @intCast(ni));
                    const dist_best = @as(isize, @intCast(bs.oi)) - @as(isize, @intCast(ni));
                    break :blk @as(usize, @intCast(@abs(dist_new))) < @as(usize, @intCast(@abs(dist_best)));
                }
                break :blk false;
            } else true;
            if (better) best = .{ .oi = oi, .sim = sim };
        }
        if (best) |bs| {
            if (bs.sim >= EDIT_THRESHOLD) {
                old_used[bs.oi] = true;
                matches[ni] = .{ .edited = .{ .old = bs.oi, .similarity = bs.sim } };
            }
        }
    }

    var removed = std.ArrayList(usize).empty;
    errdefer removed.deinit(allocator);
    for (old_used, 0..) |used, oi| {
        if (!used) try removed.append(allocator, oi);
    }

    return .{
        .new_matches = matches,
        .removed = try removed.toOwnedSlice(allocator),
        .allocator = allocator,
    };
}

/// One stable string key per new block. Same/Edited inherit the matched old
/// block's key (so a reconciler emits an Update, not a remove+insert);
/// Inserted mints its own anchor/content key.
pub fn assignStableKeys(allocator: std.mem.Allocator, old: []const Block, new: []const Block) ![][]u8 {
    const old_keys = try allocator.alloc(BlockKey, old.len);
    defer {
        allocator.free(old_keys);
    }
    for (old, old_keys) |b, *k| k.* = BlockKey.fromBlock(b);

    var alignment = try alignBlocks(allocator, old, new);
    defer alignment.deinit();

    const out = try allocator.alloc([]u8, new.len);
    errdefer allocator.free(out);
    for (out) |*s| s.* = &.{};

    for (alignment.new_matches, 0..) |m, ni| {
        var buf: [256]u8 = undefined;
        switch (m) {
            .same => |oi| {
                const key_str = old_keys[oi].writeString(&buf);
                out[ni] = try allocator.dupe(u8, key_str);
            },
            .edited => |e| {
                const key_str = old_keys[e.old].writeString(&buf);
                out[ni] = try allocator.dupe(u8, key_str);
            },
            .inserted => {
                const key = BlockKey.fromBlock(new[ni]);
                const key_str = key.writeString(&buf);
                out[ni] = try allocator.dupe(u8, key_str);
            },
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests (mirror stableid_alignment.json scenarios)
// ---------------------------------------------------------------------------

test "lazily/stable_id: content key survives reflow but not edit" {
    try std.testing.expectEqual(
        contentHash("the quick brown fox"),
        contentHash("the   quick\n  brown   fox\n"),
    );
    try std.testing.expect(contentHash("the quick brown fox") != contentHash("the quick red fox"));
}

test "lazily/stable_id: anchored key survives full body rewrite" {
    const a = Block{ .anchor = "item-1", .text = "original body" };
    const b = Block{ .anchor = "item-1", .text = "completely different prose now" };
    try std.testing.expect(BlockKey.fromBlock(a).eqlString(BlockKey.fromBlock(b)));
}

test "lazily/stable_id: pure reorder is all Same, no removed" {
    const allocator = std.testing.allocator;
    const old = [_]Block{
        .{ .text = "alpha" },
        .{ .text = "beta" },
        .{ .text = "gamma" },
    };
    const new = [_]Block{
        .{ .text = "gamma" },
        .{ .text = "alpha" },
        .{ .text = "beta" },
    };
    var al = try alignBlocks(allocator, &old, &new);
    defer al.deinit();
    try std.testing.expect(al.new_matches[0] == .same and al.new_matches[0].same == 2);
    try std.testing.expect(al.new_matches[1] == .same and al.new_matches[1].same == 0);
    try std.testing.expect(al.new_matches[2] == .same and al.new_matches[2].same == 1);
    try std.testing.expectEqual(@as(usize, 0), al.removed.len);
}

test "lazily/stable_id: small edit is Edited not Insert+Remove" {
    const allocator = std.testing.allocator;
    const old = [_]Block{
        .{ .text = "the quick brown fox jumps over the lazy dog" },
    };
    const new = [_]Block{
        .{ .text = "the quick brown fox jumps over the sleepy dog" },
    };
    var al = try alignBlocks(allocator, &old, &new);
    defer al.deinit();
    try std.testing.expect(al.new_matches[0] == .edited);
    try std.testing.expect(al.new_matches[0].edited.old == 0);
    try std.testing.expect(al.new_matches[0].edited.similarity >= 0.5);
    try std.testing.expectEqual(@as(usize, 0), al.removed.len);
}

test "lazily/stable_id: genuine insert and remove" {
    const allocator = std.testing.allocator;
    const old = [_]Block{
        .{ .text = "keep me" },
        .{ .text = "delete me entirely" },
    };
    const new = [_]Block{
        .{ .text = "keep me" },
        .{ .text = "brand new unrelated content here" },
    };
    var al = try alignBlocks(allocator, &old, &new);
    defer al.deinit();
    try std.testing.expect(al.new_matches[0] == .same and al.new_matches[0].same == 0);
    try std.testing.expect(al.new_matches[1] == .inserted);
    try std.testing.expectEqual(@as(usize, 1), al.removed.len);
    try std.testing.expectEqual(@as(usize, 1), al.removed[0]);
}

test "lazily/stable_id: assign_stable_keys flows identity through edit" {
    const allocator = std.testing.allocator;
    const old = [_]Block{
        .{ .text = "first paragraph stays the same" },
        .{ .text = "second paragraph will be tweaked a little" },
    };
    const new = [_]Block{
        .{ .text = "second paragraph will be tweaked a bit" },
        .{ .text = "first paragraph stays the same" },
    };
    const keys = try assignStableKeys(allocator, &old, &new);
    defer {
        for (keys) |k| allocator.free(k);
        allocator.free(keys);
    }
    // new[0] (edited second) inherits old[1]'s key; new[1] (same first) inherits old[0]'s key.
    var old_key_bufs: [2][256]u8 = undefined;
    const old_keys = [_][]const u8{
        BlockKey.fromBlock(old[0]).writeString(&old_key_bufs[0]),
        BlockKey.fromBlock(old[1]).writeString(&old_key_bufs[1]),
    };
    try std.testing.expectEqualStrings(old_keys[1], keys[0]);
    try std.testing.expectEqualStrings(old_keys[0], keys[1]);
}
