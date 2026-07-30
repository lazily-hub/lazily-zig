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

/// Runtime scenario ledger (`#lzscenariocoverage`). See `Scenarios` below.
pub const recordScenario = @import("conformance_manifest.zig").recordScenario;

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

// ---------------------------------------------------------------------------
// Per-scenario replay accounting (#lzscenariocoverage)
// ---------------------------------------------------------------------------

/// A scenario id spelled positionally is at most `#` plus 20 digits.
const POSITIONAL_ID_MAX = 24;

/// Resolve a scenario's identifier in the order every binding uses:
///
///   1. `id` if present
///   2. else `name` if present
///   3. else the positional index, spelled `#<n>` (0-based)
///
/// The corpus is not uniform — three `stdlib` fixtures key by `id`, 28 by
/// `name`, and `collections/mergecell_algebra.json` carries no identifier at
/// all (its scenarios are told apart only by `policy`). The positional fallback
/// exists so per-scenario accounting is not blocked on a shared-corpus edit;
/// the coverage guard REPORTS every id that fell back to it, because the
/// visibility is what makes the corpus gap fixable later.
pub fn scenarioIdInto(scenario: Value, index: usize, buf: []u8) []const u8 {
    if (field(scenario, "id")) |v| {
        if (v == .string and v.string.len > 0) return v.string;
    }
    if (field(scenario, "name")) |v| {
        if (v == .string and v.string.len > 0) return v.string;
    }
    return std.fmt.bufPrint(buf, "#{d}", .{index}) catch "#?";
}

/// The shared scenario-iteration helper, and the one place a scenario is
/// entered into the runtime ledger.
///
/// `next()` deliberately does NOT record. The runner calls `replaying()` at the
/// top of the loop body — AFTER any `continue` — so a scenario the runner skips
/// does not record itself, which is exactly the case this accounting exists to
/// catch. Forgetting the call is not silent either: the fixture's bytes were
/// still opened, so the guard sees a scenario on disk with no ledger entry and
/// fails naming both. The helper is fail-closed in both directions.
pub const Scenarios = struct {
    /// Corpus-relative fixture id, e.g. `stdlib/timer.json`.
    fixture: []const u8,
    items: []const Value,
    index: usize = 0,
    id_buf: [POSITIONAL_ID_MAX]u8 = undefined,

    pub fn len(self: Scenarios) usize {
        return self.items.len;
    }

    /// Yield the next scenario without recording it.
    pub fn next(self: *Scenarios) ?Value {
        if (self.index >= self.items.len) return null;
        self.index += 1;
        return self.items[self.index - 1];
    }

    /// 0-based index of the scenario `next()` last yielded.
    pub fn at(self: Scenarios) usize {
        return self.index - 1;
    }

    /// The resolved id of the scenario `next()` last yielded, WITHOUT recording
    /// it. For a skip decision that needs to name the scenario it is skipping.
    /// The slice may borrow `id_buf`, so it does not outlive the iteration.
    pub fn currentId(self: *Scenarios) []const u8 {
        return scenarioIdInto(self.items[self.index - 1], self.index - 1, &self.id_buf);
    }

    /// Record the scenario `next()` last yielded as REPLAYED and return its
    /// resolved id.
    pub fn replaying(self: *Scenarios) []const u8 {
        const id = self.currentId();
        recordScenario(self.fixture, id);
        return id;
    }
};

/// Iterate `fx.scenarios`, recording each replay into the runtime ledger.
pub fn scenarios(fixture: []const u8, fx: Value) !Scenarios {
    return .{ .fixture = fixture, .items = try asArray(try required(fx, "scenarios")) };
}

/// Find the scenario whose resolved id is `id`, record it as replayed, and hand
/// it back.
///
/// For the replays that are one hand-written test per scenario rather than a
/// loop. Errors when the fixture carries no such scenario, so an upstream
/// rename breaks the runner instead of quietly dropping it out of the ledger —
/// a bare `recordScenario("...", "some_name")` would keep claiming an id the
/// corpus no longer has.
pub fn replayingScenario(fixture: []const u8, fx: Value, id: []const u8) !Value {
    return replayingScenarioImpl(fixture, fx, id, false);
}

/// `quiet` suppresses the diagnostic. Only for this module's own self-test,
/// which asserts the failure and must not pollute the suite's stderr — the
/// build runner surfaces any stderr from a test binary as a failed command.
fn replayingScenarioImpl(fixture: []const u8, fx: Value, id: []const u8, quiet: bool) !Value {
    var it = try scenarios(fixture, fx);
    while (it.next()) |scenario| {
        if (!std.mem.eql(u8, it.currentId(), id)) continue;
        _ = it.replaying();
        return scenario;
    }
    if (!quiet) std.debug.print(
        "{s}: no scenario resolves to id '{s}' — the corpus renamed or dropped it, " ++
            "and this runner is replaying something that is no longer there " ++
            "(#lzscenariocoverage)\n",
        .{ fixture, id },
    );
    return error.UnknownScenarioId;
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
/// Reading is not asserting — `#lzconsumednotasserted`. A runner can read a key
/// (marking it consumed) and then drop it on the floor: a named `continue` in a
/// consuming loop, a value bound and never compared, or an arm that gates on the
/// fixture value but asserts against a hardcoded literal. All three satisfy the
/// consumed set while proving nothing, so the fixture could change and the
/// runner would stay green.
///
/// So `asserted` tracks the narrower fact: the key's own fixture value reached a
/// comparison. Only `assertKey` / `assertKeyWith` can put a key there, which is
/// why an arm comparing against a literal never marks it. `excuseKey` is the
/// declared fallback for a key with nothing to compare here, and it is checked
/// in both directions — excusing a key the same run also asserts is a failure,
/// because that excuse has gone stale and is hiding nothing.
///
/// No allocation: the sets are bounded inline arrays, so a replay can build one
/// per step without touching an allocator.
pub const AssertionKeys = struct {
    pub const MAX_KEYS = 64;

    /// Prose keys that carry no assertion and are documentation only. Exempt
    /// from all three checks: unconsumed, read-but-not-asserted, stale excuse.
    pub const NARRATIVE = [_][]const u8{ "note", "notes", "comment", "description", "why" };

    const Excuse = struct { name: []const u8, reason: []const u8 };

    where: []const u8,
    object: Value,
    consumed: [MAX_KEYS][]const u8 = undefined,
    len: usize = 0,
    asserted: [MAX_KEYS][]const u8 = undefined,
    asserted_len: usize = 0,
    excused: [MAX_KEYS]Excuse = undefined,
    excused_len: usize = 0,
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

    fn markAsserted(self: *AssertionKeys, name: []const u8) void {
        self.mark(name);
        for (self.asserted[0..self.asserted_len]) |seen| {
            if (std.mem.eql(u8, seen, name)) return;
        }
        if (self.asserted_len == MAX_KEYS) @panic("AssertionKeys.MAX_KEYS exceeded");
        self.asserted[self.asserted_len] = name;
        self.asserted_len += 1;
    }

    fn isNarrative(name: []const u8) bool {
        for (NARRATIVE) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    fn wasAsserted(self: *const AssertionKeys, name: []const u8) bool {
        for (self.asserted[0..self.asserted_len]) |a| {
            if (std.mem.eql(u8, a, name)) return true;
        }
        return false;
    }

    fn excuseFor(self: *const AssertionKeys, name: []const u8) ?[]const u8 {
        for (self.excused[0..self.excused_len]) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.reason;
        }
        return null;
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

    /// Read `name`, mark it ASSERTED, and compare the fixture's own value
    /// against `actual`. This is the only path (with `assertKeyWith`) that can
    /// satisfy the read-but-not-asserted check, which is the point: an arm that
    /// compares against a hardcoded literal never reaches here, so editing the
    /// fixture would change nothing and `finish()` says so.
    ///
    /// `actual` is compared by its own Zig type — bool, any integer, any float,
    /// string, enum (by tag name), `Value` (structurally), or an optional of
    /// any of those against a fixture `null`.
    pub fn assertKey(self: *AssertionKeys, name: []const u8, actual: anytype) !void {
        const expected = try self.required(name);
        self.markAsserted(name);
        try self.compare(name, expected, actual);
    }

    /// As `assertKey`, but only when the fixture carries `name`. The key is
    /// consumed either way — an optional assertion is still a declaration that
    /// the runner knows about the key — and marked asserted only when the
    /// fixture's value actually reached the comparison. Reports whether it did.
    pub fn assertKeyOpt(self: *AssertionKeys, name: []const u8, actual: anytype) !bool {
        const expected = self.field(name) orelse return false;
        self.markAsserted(name);
        try self.compare(name, expected, actual);
        return true;
    }

    /// Read `name`, mark it ASSERTED, and hand the fixture's value to the
    /// caller's own check. For comparisons that are not an equality — a
    /// tolerance, a set containment, a per-entry sweep of an object. What
    /// matters is that the fixture's value reaches the comparison, not that the
    /// comparison is `==`.
    pub fn assertKeyWith(
        self: *AssertionKeys,
        name: []const u8,
        context: anytype,
        comptime check: fn (@TypeOf(context), Value) anyerror!void,
    ) !void {
        const expected = try self.required(name);
        self.markAsserted(name);
        try check(context, expected);
    }

    /// As `assertKeyWith`, but a no-op when the fixture omits `name`. Reports
    /// whether the check ran.
    pub fn assertKeyWithOpt(
        self: *AssertionKeys,
        name: []const u8,
        context: anytype,
        comptime check: fn (@TypeOf(context), Value) anyerror!void,
    ) !bool {
        const expected = self.field(name) orelse return false;
        self.markAsserted(name);
        try check(context, expected);
        return true;
    }

    /// Declare that `name` cannot be asserted at this call site, and say why.
    /// The fallback when there is genuinely nothing to compare — the fact is
    /// proven elsewhere, or the field is a discriminator selecting a code path
    /// rather than a value to check. Prefer converting the skip into a real
    /// assertion; an excuse is a promise the reason text has to keep.
    ///
    /// Checked in BOTH directions: `finish()` fails when the same run also
    /// asserts an excused key, because that excuse is stale and hides nothing.
    pub fn excuseKey(self: *AssertionKeys, name: []const u8, reason: []const u8) !void {
        if (reason.len == 0) return error.EmptyExcuseReason;
        self.mark(name);
        for (self.excused[0..self.excused_len]) |e| {
            if (std.mem.eql(u8, e.name, name)) return;
        }
        if (self.excused_len == MAX_KEYS) @panic("AssertionKeys.MAX_KEYS exceeded");
        self.excused[self.excused_len] = .{ .name = name, .reason = reason };
        self.excused_len += 1;
    }

    fn mismatch(
        self: *const AssertionKeys,
        name: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) error{AssertionValueMismatch} {
        if (!self.quiet) {
            std.debug.print("{s}: assertion key '{s}' ", .{ self.where, name });
            std.debug.print(fmt ++ " (#lzconsumednotasserted)\n", args);
        }
        return error.AssertionValueMismatch;
    }

    fn compare(self: *AssertionKeys, name: []const u8, expected: Value, actual: anytype) !void {
        const T = @TypeOf(actual);
        if (T == Value) return expectJsonEql(expected, actual);
        switch (@typeInfo(T)) {
            .optional => {
                if (actual) |inner| {
                    if (expected == .null) {
                        return self.mismatch(name, "want null, got a value", .{});
                    }
                    return self.compare(name, expected, inner);
                }
                if (expected != .null) {
                    return self.mismatch(name, "want a value, got null", .{});
                }
            },
            .null => {
                if (expected != .null) {
                    return self.mismatch(name, "want a value, got null", .{});
                }
            },
            .bool => {
                const want = try asBool(expected);
                if (want != actual) {
                    return self.mismatch(name, "want {}, got {}", .{ want, actual });
                }
            },
            .comptime_int => return self.compare(name, expected, @as(i64, actual)),
            .comptime_float => return self.compare(name, expected, @as(f64, actual)),
            .int => |int| {
                if (int.signedness == .unsigned) {
                    const want = try asU64(expected);
                    const got: u64 = @intCast(actual);
                    if (want != got) {
                        return self.mismatch(name, "want {d}, got {d}", .{ want, got });
                    }
                } else {
                    const want = try asI64(expected);
                    const got: i64 = @intCast(actual);
                    if (want != got) {
                        return self.mismatch(name, "want {d}, got {d}", .{ want, got });
                    }
                }
            },
            .float => {
                const want = try asF64(expected);
                const got: f64 = @floatCast(actual);
                if (want != got) {
                    return self.mismatch(name, "want {d}, got {d}", .{ want, got });
                }
            },
            .@"enum", .enum_literal => {
                const want = try asStr(expected);
                const got = @tagName(actual);
                if (!std.mem.eql(u8, want, got)) {
                    return self.mismatch(name, "want '{s}', got '{s}'", .{ want, got });
                }
            },
            else => {
                if (comptime isStringLike(T)) {
                    const want = try asStr(expected);
                    const got: []const u8 = actual;
                    if (!std.mem.eql(u8, want, got)) {
                        return self.mismatch(name, "want '{s}', got '{s}'", .{ want, got });
                    }
                } else {
                    @compileError("AssertionKeys.assertKey: unsupported actual type " ++ @typeName(T));
                }
            },
        }
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

    /// Three failure modes, all naming the fixture and the key because "some
    /// assertion went unread" is not actionable:
    ///
    /// 1. a key the runner never asked for (`#lzassertunknownkeys`);
    /// 2. a key the runner READ but never asserted or excused
    ///    (`#lzconsumednotasserted`);
    /// 3. an excuse for a key the same run also asserted — stale, hiding
    ///    nothing (`#lzconsumednotasserted`).
    pub fn finish(self: *const AssertionKeys) !void {
        for (self.excused[0..self.excused_len]) |e| {
            if (!self.wasAsserted(e.name)) continue;
            if (self.quiet) return error.StaleAssertionExcuse;
            std.debug.print(
                "{s}: assertion key '{s}' is excused (\"{s}\") but this same run asserts " ++
                    "it. The excuse is stale and now hides nothing — drop the excuseKey " ++
                    "call (#lzconsumednotasserted)\n",
                .{ self.where, e.name, e.reason },
            );
            return error.StaleAssertionExcuse;
        }

        const obj = switch (self.object) {
            .object => |o| o,
            else => return,
        };
        var it = obj.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            if (isNarrative(name)) continue;

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

            if (self.wasAsserted(name)) continue;
            if (self.excuseFor(name) != null) continue;

            if (self.quiet) return error.AssertionKeyReadButNotAsserted;
            std.debug.print(
                "{s}: assertion key '{s}' was READ but its value never reached a " ++
                    "comparison. Reading a key marks it consumed and proves nothing — the " ++
                    "fixture could change and this runner would stay green. Assert it with " ++
                    "assertKey/assertKeyWith, or declare excuseKey(\"{s}\", <reason>) " ++
                    "(#lzconsumednotasserted)\n",
                .{ self.where, name, name },
            );
            return error.AssertionKeyReadButNotAsserted;
        }
    }
};

/// `[]const u8`, `[]u8`, and string literals (`*const [N:0]u8`).
fn isStringLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

/// Assert `expected.invalidates[reader]` against an observed version bump.
///
/// The per-reader invalidation flag is nested one level down, so `reader` picks
/// the sub-key rather than being a value to compare — but the flag itself is a
/// real fact about the library and goes through the tracker as an ASSERTION,
/// not a bare read (`#lzconsumednotasserted`).
pub fn assertInvalidates(
    keys: *AssertionKeys,
    comptime reader: []const u8,
    changed: bool,
) !void {
    try keys.assertKeyWith("invalidates", changed, struct {
        fn check(observed: bool, inv: Value) !void {
            try std.testing.expectEqual(try asBool(try required(inv, reader)), observed);
        }
    }.check);
}

/// Build a consumption-tracking view over `value.name` (the fixture's assertion
/// block), or null when the fixture carries no such block.
pub fn assertionKeys(where: []const u8, value: Value, name: []const u8) ?AssertionKeys {
    const block = field(value, name) orelse return null;
    return AssertionKeys.init(where, block);
}

test "conformance_json: scenario ids resolve id -> name -> positional" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(
        Value,
        allocator,
        \\{"scenarios":[
        \\  {"id":"by_id","name":"ignored"},
        \\  {"name":"by_name"},
        \\  {"policy":"Sum"}
        \\]}
    ,
        .{},
    );
    defer parsed.deinit();

    var it = try scenarios("fake/fixture.json", parsed.value);
    try std.testing.expectEqual(@as(usize, 3), it.len());

    var seen: [3][]const u8 = undefined;
    var buf: [3][POSITIONAL_ID_MAX]u8 = undefined;
    var n: usize = 0;
    while (it.next()) |sc| {
        // `currentId` borrows the iterator's buffer for the positional case, so
        // copy before advancing.
        const id = scenarioIdInto(sc, it.at(), &buf[n]);
        seen[n] = id;
        n += 1;
    }
    try std.testing.expectEqualStrings("by_id", seen[0]);
    try std.testing.expectEqualStrings("by_name", seen[1]);
    try std.testing.expectEqualStrings("#2", seen[2]);
}

test "conformance_json: replayingScenario refuses an id the fixture does not carry" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(
        Value,
        allocator,
        "{\"scenarios\":[{\"name\":\"present\"}]}",
        .{},
    );
    defer parsed.deinit();
    // No ledger write reaches disk here: the recorder is a no-op unless
    // LAZILY_CONFORMANCE_MANIFEST is set, and `fake/fixture.json` is not in the
    // corpus, so the guard would flag it if it ever were.
    try std.testing.expectError(
        error.UnknownScenarioId,
        replayingScenarioImpl("fake/fixture.json", parsed.value, "absent", true),
    );
}

test "conformance_json: an unconsumed assertion key fails, an asserted one does not" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(Value, allocator, "{\"a\":1,\"note\":\"x\",\"b\":2}", .{});
    defer parsed.deinit();

    var all = AssertionKeys.init("fixture", parsed.value);
    try all.assertKey("a", @as(i64, 1));
    try all.assertKey("b", @as(i64, 2));
    try all.finish();

    var partial = AssertionKeys.init("fixture", parsed.value);
    partial.quiet = true;
    try partial.assertKey("a", @as(i64, 1));
    try std.testing.expectError(error.UnconsumedAssertionKey, partial.finish());
}

test "conformance_json: reading a key without asserting it fails" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(Value, allocator, "{\"a\":1,\"b\":2}", .{});
    defer parsed.deinit();

    // Both keys READ — the `#lzassertunknownkeys` consumed set is satisfied —
    // but only one of them reached a comparison.
    var keys = AssertionKeys.init("fixture", parsed.value);
    keys.quiet = true;
    try keys.assertKey("a", @as(i64, 1));
    _ = keys.field("b");
    try std.testing.expectError(error.AssertionKeyReadButNotAsserted, keys.finish());

    // An excuse satisfies it; the reason must be non-empty.
    var excused = AssertionKeys.init("fixture", parsed.value);
    try excused.assertKey("a", @as(i64, 1));
    try excused.excuseKey("b", "asserted by the sibling replay in this module");
    try excused.finish();

    var empty = AssertionKeys.init("fixture", parsed.value);
    try std.testing.expectError(error.EmptyExcuseReason, empty.excuseKey("b", ""));
}

test "conformance_json: an excuse for a key the same run asserts is stale" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(Value, allocator, "{\"a\":1}", .{});
    defer parsed.deinit();

    var keys = AssertionKeys.init("fixture", parsed.value);
    keys.quiet = true;
    try keys.excuseKey("a", "proven elsewhere");
    try keys.assertKey("a", @as(i64, 1));
    try std.testing.expectError(error.StaleAssertionExcuse, keys.finish());
}

test "conformance_json: assertKey compares against the fixture's own value" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(
        Value,
        allocator,
        "{\"s\":\"x\",\"b\":true,\"i\":-3,\"u\":7,\"f\":1.5,\"n\":null,\"o\":{\"k\":1}}",
        .{},
    );
    defer parsed.deinit();

    var keys = AssertionKeys.init("fixture", parsed.value);
    keys.quiet = true;
    try keys.assertKey("s", "x");
    try keys.assertKey("b", true);
    try keys.assertKey("i", @as(i64, -3));
    try keys.assertKey("u", @as(usize, 7));
    try keys.assertKey("f", @as(f64, 1.5));
    try keys.assertKey("n", @as(?[]const u8, null));
    try keys.assertKeyWith("o", @as(i64, 1), struct {
        fn check(want_k: i64, v: Value) !void {
            try std.testing.expectEqual(want_k, try asI64(try required(v, "k")));
        }
    }.check);
    try keys.finish();

    var wrong = AssertionKeys.init("fixture", parsed.value);
    wrong.quiet = true;
    try std.testing.expectError(error.AssertionValueMismatch, wrong.assertKey("s", "y"));
    try std.testing.expectError(error.AssertionValueMismatch, wrong.assertKey("b", false));
    try std.testing.expectError(error.AssertionValueMismatch, wrong.assertKey("u", @as(usize, 8)));
    try std.testing.expectError(
        error.AssertionValueMismatch,
        wrong.assertKey("n", @as(?[]const u8, "x")),
    );
}
