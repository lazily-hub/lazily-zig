//! Shared JSON accessors for the canonical-corpus replays
//! (`#lazilyupgradeconformance`, `#lazilyzigconformance`).
//!
//! Eight fixtures in this binding used to be asserted by INLINE MIRRORS: the
//! expected values were typed into the `.zig` source and the fixture was named
//! only in a comment, so upstream could change the corpus and the mirror stayed
//! green. The runtime manifest catches "nobody opened this file"; it cannot
//! make a runner exist. These accessors are that runner's shared half — kept in
//! one module rather than copied into a sixth conformance file.
//!
//! Everything here is test-only. `load` reads through the manifest recorder, so
//! a replay built on it feeds the coverage guard by construction.

const std = @import("std");

pub const json = std.json;
pub const Value = json.Value;

/// Reads through the runtime conformance manifest recorder: naming a fixture is
/// not replaying it, so the coverage guard is fed by observed reads rather than
/// a source grep.
pub const specReadFile = @import("conformance_manifest.zig").specReadFile;

pub const CONFORMANCE_ROOT = "../lazily-spec/conformance";

pub const Fixture = json.Parsed(Value);

/// Load and parse `<corpus>/<rel_path>`. `null` means the `lazily-spec` sibling
/// checkout is absent — the same skip every replay in this repo takes locally.
/// CI asserts the directories are present so a skip cannot report green there.
///
/// `alloc_always` copies every string into the parse arena, so the returned
/// fixture outlives the raw bytes and a replay may hold slices into it for the
/// whole test.
pub fn load(rel_path: []const u8) !?Fixture {
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(allocator, CONFORMANCE_ROOT ++ "/{s}", .{rel_path});
    defer allocator.free(path);
    const raw = specReadFile(path) catch return null;
    defer allocator.free(raw);
    return try json.parseFromSlice(Value, allocator, raw, .{ .allocate = .alloc_always });
}

pub fn field(value: Value, name: []const u8) ?Value {
    return switch (value) {
        .object => |o| o.get(name),
        else => null,
    };
}

pub fn required(value: Value, name: []const u8) !Value {
    return field(value, name) orelse error.MissingField;
}

pub fn asStr(value: Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}

pub fn asI64(value: Value) !i64 {
    return switch (value) {
        .integer => |n| n,
        .number_string => |s| try std.fmt.parseInt(i64, s, 10),
        else => error.ExpectedInteger,
    };
}

pub fn asU64(value: Value) !u64 {
    return switch (value) {
        .integer => |n| if (n < 0) error.ExpectedUnsigned else @intCast(n),
        .number_string => |s| try std.fmt.parseInt(u64, s, 10),
        else => error.ExpectedInteger,
    };
}

pub fn asUsize(value: Value) !usize {
    return @intCast(try asU64(value));
}

pub fn asF64(value: Value) !f64 {
    return switch (value) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        .number_string => |s| try std.fmt.parseFloat(f64, s),
        else => error.ExpectedNumber,
    };
}

pub fn asBool(value: Value) !bool {
    return switch (value) {
        .bool => |b| b,
        else => error.ExpectedBool,
    };
}

pub fn asArray(value: Value) ![]const Value {
    return switch (value) {
        .array => |a| a.items,
        else => error.ExpectedArray,
    };
}

/// `value.name` as an array, or an empty slice when the key is absent.
pub fn arrayOr(value: Value, name: []const u8) ![]const Value {
    const v = field(value, name) orelse return &.{};
    return asArray(v);
}

/// `value.name` as a bool, or `fallback` when the key is absent.
pub fn boolOr(value: Value, name: []const u8, fallback: bool) !bool {
    const v = field(value, name) orelse return fallback;
    return asBool(v);
}

/// `value.name` as a string, or null when the key is absent.
pub fn optStr(value: Value, name: []const u8) !?[]const u8 {
    const v = field(value, name) orelse return null;
    return switch (v) {
        .null => null,
        else => try asStr(v),
    };
}

/// Structural (order-independent for objects) equality. Used to compare a
/// re-encoded wire frame against the canonical fixture bytes without pinning
/// this binding's object-key emission order.
pub fn eql(a: Value, b: Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .integer => |x| switch (b) {
            .integer => |y| x == y,
            .float => |y| @as(f64, @floatFromInt(x)) == y,
            else => false,
        },
        .float => |x| switch (b) {
            .float => |y| x == y,
            .integer => |y| x == @as(f64, @floatFromInt(y)),
            else => false,
        },
        .number_string => |x| b == .number_string and std.mem.eql(u8, x, b.number_string),
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (b != .array) break :blk false;
            if (x.items.len != b.array.items.len) break :blk false;
            for (x.items, b.array.items) |i, j| {
                if (!eql(i, j)) break :blk false;
            }
            break :blk true;
        },
        .object => |x| blk: {
            if (b != .object) break :blk false;
            if (x.count() != b.object.count()) break :blk false;
            var it = x.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!eql(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

/// Assert `actual` matches `expected` structurally, printing both encodings on
/// mismatch — a wire diff is unreadable as a pair of `Value` dumps.
pub fn expectJsonEql(expected: Value, actual: Value) !void {
    if (eql(expected, actual)) return;
    const allocator = std.testing.allocator;
    const want = try json.Stringify.valueAlloc(allocator, expected, .{});
    defer allocator.free(want);
    const got = try json.Stringify.valueAlloc(allocator, actual, .{});
    defer allocator.free(got);
    std.debug.print("wire mismatch\n  want: {s}\n  got:  {s}\n", .{ want, got });
    return error.WireMismatch;
}

/// Re-encode `value` (a typed message) and parse the result back into a
/// `Value`, so it can be compared against a fixture's canonical `wire` block.
/// Caller owns the returned `Parsed`.
pub fn encodeToValue(value: anytype) !Fixture {
    const allocator = std.testing.allocator;
    const encoded = try json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(encoded);
    return json.parseFromSlice(Value, allocator, encoded, .{ .allocate = .alloc_always });
}

test "conformance_json: structural equality ignores object key order" {
    const allocator = std.testing.allocator;
    var a = try json.parseFromSlice(Value, allocator, "{\"x\":1,\"y\":[2,3]}", .{});
    defer a.deinit();
    var b = try json.parseFromSlice(Value, allocator, "{\"y\":[2,3],\"x\":1}", .{});
    defer b.deinit();
    var c = try json.parseFromSlice(Value, allocator, "{\"y\":[2,4],\"x\":1}", .{});
    defer c.deinit();
    try std.testing.expect(eql(a.value, b.value));
    try std.testing.expect(!eql(a.value, c.value));
}

test "conformance_json: an absent corpus loads as null rather than failing" {
    const missing = try load("definitely-not-a-corpus-directory/nope.json");
    try std.testing.expect(missing == null);
}

/// Consumption tracking for a conformance fixture's assertion block
/// (`assertions` / `expected` / `expect`) — `#lzassertunknownkeys`.
///
/// The failure this exists to prevent sits one level below "was the fixture
/// replayed". A runner that reads named keys out of an assertion object and
/// lets anything it does not recognise fall through reports the fixture as
/// replayed while never checking the field the fixture exists for: the wire
/// round-trips, the suite goes green, and the assertion proves nothing.
///
/// The manifest recorder proves the bytes were opened. It cannot prove the keys
/// inside them were consumed. This does.
///
/// Every accessor marks its key consumed whether or not the key is present, so
/// an *optional* assertion is still a declaration that the runner knows about
/// the key. `finish()` then fails, naming the fixture and the offending key,
/// when the block carried one the runner never asked for.
///
/// No allocation: the consumed set is a bounded inline array, so a replay can
/// build one per step without touching an allocator.
pub const AssertionKeys = struct {
    pub const MAX_KEYS = 64;

    /// Prose keys that carry no assertion and are documentation only.
    pub const NARRATIVE = [_][]const u8{ "note", "notes", "comment", "description", "why" };

    where: []const u8,
    object: Value,
    consumed: [MAX_KEYS][]const u8 = undefined,
    len: usize = 0,
    /// Suppress the diagnostic print. Only for this module's own self-test,
    /// which asserts the failure and must not pollute the suite's stderr.
    quiet: bool = false,

    pub fn init(where: []const u8, object: Value) AssertionKeys {
        var self = AssertionKeys{ .where = where, .object = object };
        for (NARRATIVE) |name| self.mark(name);
        return self;
    }

    fn mark(self: *AssertionKeys, name: []const u8) void {
        for (self.consumed[0..self.len]) |seen| {
            if (std.mem.eql(u8, seen, name)) return;
        }
        if (self.len == MAX_KEYS) @panic("AssertionKeys.MAX_KEYS exceeded");
        self.consumed[self.len] = name;
        self.len += 1;
    }

    /// Consume `name`; null when the fixture does not carry it.
    pub fn field(self: *AssertionKeys, name: []const u8) ?Value {
        self.mark(name);
        return switch (self.object) {
            .object => |o| o.get(name),
            else => null,
        };
    }

    /// Consume `name`; fails when the fixture does not carry it.
    pub fn required(self: *AssertionKeys, name: []const u8) !Value {
        return self.field(name) orelse error.MissingField;
    }

    /// Consume `name` and report whether the fixture carries it.
    pub fn has(self: *AssertionKeys, name: []const u8) bool {
        return self.field(name) != null;
    }

    /// Declare keys consumed without reading them here. Only for keys a
    /// DIFFERENT code path in the same replay evaluates — never to silence a
    /// key nothing evaluates, which is the allowlist this exists to replace.
    pub fn consume(self: *AssertionKeys, names: []const []const u8) void {
        for (names) |name| self.mark(name);
    }

    pub fn arrayOr(self: *AssertionKeys, name: []const u8) ![]const Value {
        const v = self.field(name) orelse return &.{};
        return asArray(v);
    }

    pub fn boolOr(self: *AssertionKeys, name: []const u8, fallback: bool) !bool {
        const v = self.field(name) orelse return fallback;
        return asBool(v);
    }

    pub fn optStr(self: *AssertionKeys, name: []const u8) !?[]const u8 {
        const v = self.field(name) orelse return null;
        return switch (v) {
            .null => null,
            else => try asStr(v),
        };
    }

    /// Fail when the fixture carried an assertion key this runner never asked
    /// for. Names the key and the fixture, because "some assertion went unread"
    /// is not actionable.
    pub fn finish(self: *const AssertionKeys) !void {
        const obj = switch (self.object) {
            .object => |o| o,
            else => return,
        };
        var it = obj.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            var seen = false;
            for (self.consumed[0..self.len]) |c| {
                if (std.mem.eql(u8, c, name)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                if (self.quiet) return error.UnconsumedAssertionKey;
                std.debug.print(
                    "{s}: assertion key '{s}' is present in the fixture but was never " ++
                        "consumed by this runner. Replaying a fixture without evaluating " ++
                        "its assertion reports green while proving nothing — implement the " ++
                        "assertion rather than ignoring the key (#lzassertunknownkeys)\n",
                    .{ self.where, name },
                );
                return error.UnconsumedAssertionKey;
            }
        }
    }
};

/// Build a consumption-tracking view over `value.name` (the fixture's assertion
/// block), or null when the fixture carries no such block.
pub fn assertionKeys(where: []const u8, value: Value, name: []const u8) ?AssertionKeys {
    const block = field(value, name) orelse return null;
    return AssertionKeys.init(where, block);
}

test "conformance_json: an unconsumed assertion key fails, a consumed one does not" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(Value, allocator, "{\"a\":1,\"note\":\"x\",\"b\":2}", .{});
    defer parsed.deinit();

    var all = AssertionKeys.init("fixture", parsed.value);
    _ = all.field("a");
    _ = all.field("b");
    try all.finish();

    var partial = AssertionKeys.init("fixture", parsed.value);
    partial.quiet = true;
    _ = partial.field("a");
    try std.testing.expectError(error.UnconsumedAssertionKey, partial.finish());
}
