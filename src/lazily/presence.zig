//! Presence + ephemeral plane primitives (`#lzpresence`) — the Zig port of
//! lazily-rs `src/presence.rs` (see `lazily-spec/docs/presence.md` and the
//! formal model `lazily-formal/LazilyFormal/Presence.lean`).
//!
//! The CRDT plane is durable; collaborative apps also need an **ephemeral**
//! plane that does not persist (live cursors, typing indicators, presence).
//! Each primitive is a pure compute **core** (a keyed map / single value + TTL
//! over the logical clock) split from a thin reactive **cell** projecting the
//! live view (invalidates only on a live-view change).
//!
//! Reactive-cell model (matching `temporal.zig`): the shell owns a per-reader
//! logical version counter bumped **only when the projected reader value
//! provably changes** — the edge-only invalidation contract. A conformance test
//! diffs the version snapshot across a step to assert the fixture's
//! `invalidates` matrix. This is the Zig analogue of the rs `Cell<T>`
//! `PartialEq` store-guard. Collection readers (`present`) compare a canonical
//! signature of the live `peer -> value` map rather than a scalar.
//!
//! Plane markers: the ephemeral plane is distinct from the durable plane. The
//! [`Ephemeral`] marker tags values that MUST NOT be persisted; a durable sink
//! is generic over [`Durable`]. Rust rejects handing an ephemeral value to a
//! durable sink at compile time (a `compile_fail` doctest). Zig has no traits,
//! so these markers exist for API parity only — the static durable-sink
//! rejection cannot be replicated here and is enforced at the type level in the
//! Rust reference.

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("context.zig").Context;

// ===========================================================================
// Plane markers (API parity — see module doc)
// ===========================================================================

/// Marker: a value on the **ephemeral** plane. MUST NOT be persisted. In Rust
/// this is a trait bound the durable sink statically rejects; here it is an
/// empty marker struct kept for API parity only.
pub const Ephemeral = struct {};

/// Marker: a value that may be written to the durable outbox.
pub const Durable = struct {};

/// A newtype witnessing the [`Ephemeral`] marker (the Rust compile-fail doctest
/// hands one of these to a durable sink). Purely a parity shim in Zig.
pub fn EphemeralValue(comptime T: type) type {
    return struct {
        value: T,
        pub fn init(value: T) @This() {
            return .{ .value = value };
        }
    };
}

// ===========================================================================
// Scalar equality helper (edge detection for the value reader)
// ===========================================================================

fn scalarEql(comptime T: type, a: T, b: T) bool {
    if (T == []const u8) return std.mem.eql(u8, a, b);
    return std.meta.eql(a, b);
}

fn optEql(comptime T: type, a: ?T, b: ?T) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return scalarEql(T, a.?, b.?);
}

// ===========================================================================
// Ephemeral single value
// ===========================================================================

/// Single-value auto-expiry compute core — "the last value seen in window N".
/// `set` stamps `expiry = now + ttl`; `tick` clears the value at `now >= expiry`.
pub fn EphemeralCore(comptime T: type) type {
    return struct {
        current: ?T = null,
        expiry: u64 = 0,

        const Self = @This();

        pub fn init() Self {
            return .{};
        }
        /// Set the value, expiring at `now + ttl`.
        pub fn set(self: *Self, val: T, now: u64, ttl: u64) void {
            self.current = val;
            self.expiry = now + ttl;
        }
        /// Clear the value once `now >= expiry`.
        pub fn tick(self: *Self, now: u64) void {
            if (self.current != null and now >= self.expiry) self.current = null;
        }
        pub fn value(self: *const Self) ?T {
            return self.current;
        }
    };
}

/// Reactive single-value ephemeral cell. The `value` reader (`?T`) invalidates
/// only when the live value changes (null<->Some or different bytes). String
/// values are borrowed slices — not duped.
pub fn EphemeralCell(comptime T: type) type {
    return struct {
        ctx: *Context,
        core: EphemeralCore(T),
        stored_value: ?T = null,
        value_version: u64 = 0,

        const Self = @This();

        pub fn init(ctx: *Context) Self {
            return .{ .ctx = ctx, .core = EphemeralCore(T).init() };
        }
        fn refresh(self: *Self) void {
            const v = self.core.value();
            if (!optEql(T, v, self.stored_value)) {
                self.value_version += 1;
                self.stored_value = v;
            }
        }
        pub fn set(self: *Self, val: T, now: u64, ttl: u64) void {
            self.core.set(val, now, ttl);
            self.refresh();
        }
        pub fn tick(self: *Self, now: u64) void {
            self.core.tick(now);
            self.refresh();
        }
        pub fn value(self: *const Self) ?T {
            return self.core.value();
        }
        pub fn valueVersion(self: *const Self) u64 {
            return self.value_version;
        }
    };
}

// ===========================================================================
// Keyed per-peer ephemeral map (shared by presence + awareness)
// ===========================================================================

/// Per-key ephemeral map with TTL eviction — the shared core behind presence
/// and awareness. Each entry carries an expiry; `tick` evicts lapsed entries.
/// Keys are hashed; deterministic output (`presentSignature`) sorts by key.
pub fn EphemeralMapCore(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        pub const Entry = struct { value: V, expiry: u64 };

        allocator: std.mem.Allocator,
        map: std.AutoHashMap(K, Entry),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator, .map = std.AutoHashMap(K, Entry).init(allocator) };
        }
        pub fn deinit(self: *Self) void {
            self.map.deinit();
        }
        /// Set/refresh `key`'s value (last-writer wins), expiring at `now + ttl`.
        pub fn set(self: *Self, key: K, value: V, now: u64, ttl: u64) !void {
            try self.map.put(key, .{ .value = value, .expiry = now + ttl });
        }
        /// Drop `key` immediately (membership `Dead`/`Left`).
        pub fn evict(self: *Self, key: K) void {
            _ = self.map.remove(key);
        }
        /// Evict entries whose TTL has lapsed (`now >= expiry`).
        pub fn tick(self: *Self, now: u64) !void {
            var to_remove = std.ArrayList(K).empty;
            defer to_remove.deinit(self.allocator);
            var it = self.map.iterator();
            while (it.next()) |e| {
                if (now >= e.value_ptr.expiry) try to_remove.append(self.allocator, e.key_ptr.*);
            }
            for (to_remove.items) |k| _ = self.map.remove(k);
        }
        /// The live value for `key` (respecting `now`).
        pub fn get(self: *const Self, key: K, now: u64) ?V {
            if (self.map.get(key)) |e| {
                if (now < e.expiry) return e.value;
            }
            return null;
        }
        /// Count of live entries at `now`.
        pub fn presentCount(self: *const Self, now: u64) usize {
            var n: usize = 0;
            var it = self.map.iterator();
            while (it.next()) |e| {
                if (now < e.value_ptr.expiry) n += 1;
            }
            return n;
        }
        /// A canonical signature of the live `key -> value` map at `now`,
        /// sorted by key (e.g. `"1=away;2=online;"`). Caller owns the returned
        /// slice. Instantiated only with `K = u64`, `V = []const u8`.
        pub fn presentSignature(self: *const Self, allocator: std.mem.Allocator, now: u64) ![]u8 {
            var keys = std.ArrayList(K).empty;
            defer keys.deinit(allocator);
            var it = self.map.iterator();
            while (it.next()) |e| {
                if (now < e.value_ptr.expiry) try keys.append(allocator, e.key_ptr.*);
            }
            std.mem.sort(K, keys.items, {}, std.sort.asc(K));

            var buf = std.ArrayList(u8).empty;
            errdefer buf.deinit(allocator);
            for (keys.items) |k| {
                var numbuf: [20]u8 = undefined;
                const ks = try std.fmt.bufPrint(&numbuf, "{d}", .{k});
                try buf.appendSlice(allocator, ks);
                try buf.append(allocator, '=');
                try buf.appendSlice(allocator, self.map.get(k).?.value);
                try buf.append(allocator, ';');
            }
            return buf.toOwnedSlice(allocator);
        }
    };
}

// ===========================================================================
// Presence + awareness reactive cells (over the shared map core)
// ===========================================================================

const PeerMapCore = EphemeralMapCore(u64, []const u8);

/// Shared body of the `present`-reader reactive cells (presence + awareness).
/// The `present` reader invalidates only when the live map's canonical
/// signature changes. The owned previous signature is managed by the allocator
/// and freed on deinit + on replace.
///
/// Rust splits this into two distinct types (`PresenceCell` / `AwarenessCell`)
/// whose surfaces differ only in verb (`heartbeat`/`evict` vs `set`) over the
/// identical `EphemeralMapCore`. Zig aliases both to this one struct; the
/// presence verbs (`heartbeat`/`evict`) and the awareness verb (`set`) are all
/// present — callers use the pair that matches their plane.
pub const PresentMapCell = struct {
    ctx: *Context,
    core: PeerMapCore,
    ttl: u64,
    present_sig: ?[]u8 = null,
    present_version: u64 = 0,

    const Self = @This();

    pub fn init(ctx: *Context, ttl: u64) Self {
        return .{ .ctx = ctx, .core = PeerMapCore.init(ctx.allocator), .ttl = ttl };
    }
    pub fn deinit(self: *Self) void {
        self.core.deinit();
        if (self.present_sig) |s| self.ctx.allocator.free(s);
        self.present_sig = null;
    }
    fn refresh(self: *Self, now: u64) !void {
        const sig = try self.core.presentSignature(self.ctx.allocator, now);
        if (self.present_sig == null or !std.mem.eql(u8, sig, self.present_sig.?)) {
            self.present_version += 1;
            if (self.present_sig) |old| self.ctx.allocator.free(old);
            self.present_sig = sig;
        } else {
            self.ctx.allocator.free(sig);
        }
    }
    /// Heartbeat a peer's presence (expiring at `now + ttl`). Presence verb.
    pub fn heartbeat(self: *Self, peer: u64, value: []const u8, now: u64) !void {
        try self.core.set(peer, value, now, self.ttl);
        try self.refresh(now);
    }
    /// Evict a peer on membership loss. Presence verb.
    pub fn evict(self: *Self, peer: u64, now: u64) !void {
        self.core.evict(peer);
        try self.refresh(now);
    }
    /// Set a peer's awareness value (last-writer wins, no merge). Awareness verb.
    pub fn set(self: *Self, peer: u64, value: []const u8, now: u64) !void {
        try self.core.set(peer, value, now, self.ttl);
        try self.refresh(now);
    }
    pub fn tick(self: *Self, now: u64) !void {
        try self.core.tick(now);
        try self.refresh(now);
    }
    pub fn get(self: *const Self, peer: u64, now: u64) ?[]const u8 {
        return self.core.get(peer, now);
    }
    /// Canonical signature of the current live map (`""` before any op).
    pub fn presentSig(self: *const Self) []const u8 {
        return self.present_sig orelse "";
    }
    pub fn presentVersion(self: *const Self) u64 {
        return self.present_version;
    }
};

/// Reactive per-peer presence: heartbeat-kept, membership- and TTL-evicted.
/// `heartbeat(peer, value, now)` / `evict(peer, now)` / `tick(now)`.
pub const PresenceCell = PresentMapCell;

/// Reactive typed ephemeral broadcast (cursors / selections): last-writer-
/// per-peer with a TTL. `set(peer, value, now)` / `tick(now)`.
pub const AwarenessCell = PresentMapCell;

// ===========================================================================
// Unit tests (pure cores)
// ===========================================================================

test "presence: ephemeral expires and overwrites" {
    var e = EphemeralCore([]const u8).init();
    e.set("a", 0, 5);
    e.tick(3);
    try std.testing.expectEqualStrings("a", e.value().?);
    e.tick(5);
    try std.testing.expect(e.value() == null);
    e.set("b", 6, 5);
    e.set("c", 10, 5); // overwrite before expiry
    try std.testing.expectEqualStrings("c", e.value().?);
}

test "presence: evict and ttl" {
    var m = EphemeralMapCore(u64, []const u8).init(std.testing.allocator);
    defer m.deinit();
    try m.set(1, "online", 0, 5);
    try m.set(2, "online", 1, 5);
    m.evict(2);
    try std.testing.expectEqual(@as(usize, 1), m.presentCount(2));
    try m.tick(6); // peer 1 expires at 5
    try std.testing.expectEqual(@as(usize, 0), m.presentCount(6));
}

test "presence: awareness last-writer" {
    var m = EphemeralMapCore(u64, []const u8).init(std.testing.allocator);
    defer m.deinit();
    try m.set(1, "cursor-a", 0, 5);
    try m.set(1, "cursor-a2", 2, 5);
    try std.testing.expectEqualStrings("cursor-a2", m.get(1, 2).?);
}

// ===========================================================================
// lazily-spec conformance fixture replay
// `../lazily-spec/conformance/presence/*.json` (mirrors lazily-rs
// `tests/presence_conformance.rs`).
// ===========================================================================

const json = std.json;
const SPEC_DIR = "../lazily-spec/conformance/presence";

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
    const raw = readFixtureFile(SPEC_DIR ++ "/ephemeral.json") catch return false;
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

/// Canonical signature of the fixture's `expected.present` object, sorted by
/// numeric peer key — the reference the cell's `presentSig()` is checked
/// against.
fn expectedPresentSig(allocator: std.mem.Allocator, present: json.Value) ![]u8 {
    const obj = switch (present) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };
    var keys = std.ArrayList(u64).empty;
    defer keys.deinit(allocator);
    var it = obj.iterator();
    while (it.next()) |e| {
        try keys.append(allocator, try std.fmt.parseInt(u64, e.key_ptr.*, 10));
    }
    std.mem.sort(u64, keys.items, {}, std.sort.asc(u64));

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    for (keys.items) |k| {
        var numbuf: [20]u8 = undefined;
        const ks = try std.fmt.bufPrint(&numbuf, "{d}", .{k});
        const v = obj.get(ks) orelse return error.MissingKey;
        try buf.appendSlice(allocator, ks);
        try buf.append(allocator, '=');
        try buf.appendSlice(allocator, try jsonAsString(v));
        try buf.append(allocator, ';');
    }
    return buf.toOwnedSlice(allocator);
}

test "presence conformance: ephemeral" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("ephemeral.json");
    defer parsed.deinit();
    const fx = parsed.value;

    var cell = EphemeralCell([]const u8).init(ctx);

    for (try steps(fx)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const op_type = try jsonAsString(try jsonFieldRequired(op, "type"));
        const now = try jsonAsU64(try jsonFieldRequired(op, "now"));
        const pre = cell.valueVersion();

        if (std.mem.eql(u8, op_type, "set")) {
            const value = try jsonAsString(try jsonFieldRequired(op, "value"));
            const ttl = try jsonAsU64(try jsonFieldRequired(op, "ttl"));
            cell.set(value, now, ttl);
        } else if (std.mem.eql(u8, op_type, "tick")) {
            cell.tick(now);
        } else return error.UnknownOp;

        const exp = try jsonFieldRequired(step, "expected");
        switch (try jsonFieldRequired(exp, "value")) {
            .null => try std.testing.expect(cell.value() == null),
            else => |v| try std.testing.expectEqualStrings(try jsonAsString(v), cell.value().?),
        }
        try std.testing.expectEqual(try invalidates(step, "value"), cell.valueVersion() != pre);
    }
}

test "presence conformance: presence" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("presence.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const ttl = try jsonAsU64(try jsonFieldRequired(try jsonFieldRequired(fx, "config"), "ttl"));
    var cell = PresenceCell.init(ctx, ttl);
    defer cell.deinit();

    for (try steps(fx)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const op_type = try jsonAsString(try jsonFieldRequired(op, "type"));
        const now = try jsonAsU64(try jsonFieldRequired(op, "now"));
        const pre = cell.presentVersion();

        if (std.mem.eql(u8, op_type, "heartbeat")) {
            const peer = try jsonAsU64(try jsonFieldRequired(op, "peer"));
            const value = try jsonAsString(try jsonFieldRequired(op, "value"));
            try cell.heartbeat(peer, value, now);
        } else if (std.mem.eql(u8, op_type, "evict")) {
            const peer = try jsonAsU64(try jsonFieldRequired(op, "peer"));
            try cell.evict(peer, now);
        } else if (std.mem.eql(u8, op_type, "tick")) {
            try cell.tick(now);
        } else return error.UnknownOp;

        const exp = try jsonFieldRequired(step, "expected");
        const want = try expectedPresentSig(std.testing.allocator, try jsonFieldRequired(exp, "present"));
        defer std.testing.allocator.free(want);
        try std.testing.expectEqualStrings(want, cell.presentSig());
        try std.testing.expectEqual(try invalidates(step, "present"), cell.presentVersion() != pre);
    }
}

test "presence conformance: awareness" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("awareness.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const ttl = try jsonAsU64(try jsonFieldRequired(try jsonFieldRequired(fx, "config"), "ttl"));
    var cell = AwarenessCell.init(ctx, ttl);
    defer cell.deinit();

    for (try steps(fx)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const op_type = try jsonAsString(try jsonFieldRequired(op, "type"));
        const now = try jsonAsU64(try jsonFieldRequired(op, "now"));
        const pre = cell.presentVersion();

        if (std.mem.eql(u8, op_type, "set")) {
            const peer = try jsonAsU64(try jsonFieldRequired(op, "peer"));
            const value = try jsonAsString(try jsonFieldRequired(op, "value"));
            try cell.set(peer, value, now);
        } else if (std.mem.eql(u8, op_type, "tick")) {
            try cell.tick(now);
        } else return error.UnknownOp;

        const exp = try jsonFieldRequired(step, "expected");
        const want = try expectedPresentSig(std.testing.allocator, try jsonFieldRequired(exp, "present"));
        defer std.testing.allocator.free(want);
        try std.testing.expectEqualStrings(want, cell.presentSig());
        try std.testing.expectEqual(try invalidates(step, "present"), cell.presentVersion() != pre);
    }
}
