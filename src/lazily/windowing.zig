//! Stream windowing primitives (`#lzwindow`) — the Zig port of lazily-rs
//! `src/windowing.rs` (see `lazily-spec/docs/windowing.md` and the formal model
//! `lazily-formal/LazilyFormal/Windowing.lean`).
//!
//! Window aggregation *is* a merge, so the merge algebra (`merge.MergePolicy`)
//! composes: the aggregate of a window equals the associative fold of its
//! elements. Each primitive is a pure compute **core** (window bookkeeping + a
//! `MergePolicy` fold) split from a thin reactive **cell** projecting the last
//! emitted aggregate.
//!
//! Reactive-cell model (matching `temporal.zig`): the shell owns a per-reader
//! logical version counter bumped **only when the projected `output` reader
//! provably changes** — the edge-only invalidation contract. The rs
//! `set_output` writes the cell only when the operator emits `Some(v)`, and the
//! `Cell<T>` `PartialEq` store-guard suppresses invalidation when the emitted
//! value equals the held one. Replicated here: a `null` emit (or an
//! equal-value emit) does not bump; only a distinct emitted value does.
//!
//! Unlike rs (a compile-time `M: MergePolicy<T>` type param), Zig has no trait
//! type params, so each core stores a runtime `merge.MergePolicy(T)` value and
//! calls `policy.merge(old, op)`.

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("context.zig").Context;
const merge = @import("merge.zig");

/// Fold `v` into an optional accumulator under `policy` (identity when empty).
fn mergeInto(comptime T: type, policy: merge.MergePolicy(T), acc: *?T, v: T) void {
    if (acc.*) |cur| {
        acc.* = policy.merge(cur, v);
    } else {
        acc.* = v;
    }
}

/// Fold a slice of elements under `policy` (`null` for an empty window).
fn foldWindow(comptime T: type, policy: merge.MergePolicy(T), items: []const T) ?T {
    var acc: ?T = null;
    for (items) |v| mergeInto(T, policy, &acc, v);
    return acc;
}

// ===========================================================================
// Tumbling (count)
// ===========================================================================

/// Count-based tumbling window compute core.
pub fn TumblingCountCore(comptime T: type) type {
    return struct {
        n: u64,
        policy: merge.MergePolicy(T),
        acc: ?T = null,
        count: u64 = 0,

        const Self = @This();

        pub fn init(n: u64, policy: merge.MergePolicy(T)) Self {
            return .{ .n = @max(n, 1), .policy = policy };
        }
        /// Push an element; emit the window aggregate on the `n`-th and reset.
        pub fn push(self: *Self, v: T) ?T {
            mergeInto(T, self.policy, &self.acc, v);
            self.count += 1;
            if (self.count >= self.n) {
                self.count = 0;
                const emit = self.acc;
                self.acc = null;
                return emit;
            }
            return null;
        }
    };
}

// ===========================================================================
// Tumbling (time)
// ===========================================================================

/// Time-based tumbling window compute core.
pub fn TumblingTimeCore(comptime T: type) type {
    return struct {
        period: u64,
        next: u64,
        policy: merge.MergePolicy(T),
        acc: ?T = null,

        const Self = @This();

        pub fn init(period: u64, policy: merge.MergePolicy(T)) Self {
            const p = @max(period, 1);
            return .{ .period = p, .next = p, .policy = policy };
        }
        /// Accumulate an element into the current window.
        pub fn push(self: *Self, now: u64, v: T) void {
            _ = now;
            mergeInto(T, self.policy, &self.acc, v);
        }
        /// At a period boundary emit the window aggregate (empty window → null).
        pub fn tick(self: *Self, now: u64) ?T {
            if (now < self.next) return null;
            while (self.next <= now) self.next += self.period;
            const emit = self.acc;
            self.acc = null;
            return emit;
        }
    };
}

// ===========================================================================
// Sliding (count)
// ===========================================================================

/// Count-based sliding window compute core (fold-recompute, correct for any
/// associative merge).
pub fn SlidingCore(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        size: usize,
        slide: u64,
        buffer: std.ArrayList(T),
        since: u64 = 0,
        policy: merge.MergePolicy(T),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, size: usize, slide: u64, policy: merge.MergePolicy(T)) Self {
            return .{
                .allocator = allocator,
                .size = @max(size, 1),
                .slide = @max(slide, 1),
                .buffer = std.ArrayList(T).empty,
                .policy = policy,
            };
        }
        pub fn deinit(self: *Self) void {
            self.buffer.deinit(self.allocator);
        }
        /// Push an element; every `slide` pushes emit the fold over the last `size`.
        pub fn push(self: *Self, v: T) !?T {
            try self.buffer.append(self.allocator, v);
            while (self.buffer.items.len > self.size) _ = self.buffer.orderedRemove(0);
            self.since += 1;
            if (self.since >= self.slide) {
                self.since = 0;
                return foldWindow(T, self.policy, self.buffer.items);
            }
            return null;
        }
    };
}

// ===========================================================================
// Session (gap-based)
// ===========================================================================

/// Gap-based sessionization compute core.
pub fn SessionCore(comptime T: type) type {
    return struct {
        gap: u64,
        policy: merge.MergePolicy(T),
        acc: ?T = null,
        last: ?u64 = null,

        const Self = @This();

        pub fn init(gap: u64, policy: merge.MergePolicy(T)) Self {
            return .{ .gap = gap, .policy = policy };
        }
        /// Push an element; a gap larger than `gap` closes the session (emitting
        /// its aggregate) and opens a new one.
        pub fn push(self: *Self, now: u64, v: T) ?T {
            const idle_break = if (self.last) |l|
                (now -| l > self.gap) and (self.acc != null)
            else
                false;
            if (idle_break) {
                const emit = self.acc;
                self.acc = v;
                self.last = now;
                return emit;
            }
            mergeInto(T, self.policy, &self.acc, v);
            self.last = now;
            return null;
        }
        /// Close the open session if it has been idle longer than `gap`.
        pub fn flush(self: *Self, now: u64) ?T {
            const idle = if (self.last) |l|
                (now -| l > self.gap) and (self.acc != null)
            else
                false;
            if (idle) {
                const emit = self.acc;
                self.acc = null;
                return emit;
            }
            return null;
        }
    };
}

// ===========================================================================
// Reactive cells
// ===========================================================================

/// Shared edge-only `output` projection: only a distinct emitted value bumps
/// the version (the Zig analogue of the rs `Cell` `PartialEq` store-guard).
fn OutputProjection(comptime T: type) type {
    return struct {
        output_value: ?T = null,
        output_version: u64 = 0,

        const Self = @This();

        fn set(self: *Self, emitted: ?T) void {
            if (emitted) |v| {
                const changed = if (self.output_value) |cur| !std.meta.eql(cur, v) else true;
                if (changed) {
                    self.output_value = v;
                    self.output_version += 1;
                }
            }
        }
    };
}

/// Reactive count-tumbling window; projects the last emitted aggregate.
pub fn TumblingCountWindow(comptime T: type) type {
    return struct {
        ctx: *Context,
        core: TumblingCountCore(T),
        proj: OutputProjection(T) = .{},

        const Self = @This();

        pub fn init(ctx: *Context, n: u64, policy: merge.MergePolicy(T)) Self {
            return .{ .ctx = ctx, .core = TumblingCountCore(T).init(n, policy) };
        }
        pub fn push(self: *Self, v: T) ?T {
            const emit = self.core.push(v);
            self.proj.set(emit);
            return emit;
        }
        pub fn output(self: *const Self) ?T {
            return self.proj.output_value;
        }
        pub fn outputVersion(self: *const Self) u64 {
            return self.proj.output_version;
        }
    };
}

/// Reactive time-tumbling window (`push(now, v)` + `tick(now)`).
pub fn TumblingTimeWindow(comptime T: type) type {
    return struct {
        ctx: *Context,
        core: TumblingTimeCore(T),
        proj: OutputProjection(T) = .{},

        const Self = @This();

        pub fn init(ctx: *Context, period: u64, policy: merge.MergePolicy(T)) Self {
            return .{ .ctx = ctx, .core = TumblingTimeCore(T).init(period, policy) };
        }
        pub fn push(self: *Self, now: u64, v: T) void {
            self.core.push(now, v);
        }
        pub fn tick(self: *Self, now: u64) ?T {
            const emit = self.core.tick(now);
            self.proj.set(emit);
            return emit;
        }
        pub fn output(self: *const Self) ?T {
            return self.proj.output_value;
        }
        pub fn outputVersion(self: *const Self) u64 {
            return self.proj.output_version;
        }
    };
}

/// Reactive count-sliding window; projects the last emitted aggregate.
pub fn SlidingWindow(comptime T: type) type {
    return struct {
        ctx: *Context,
        core: SlidingCore(T),
        proj: OutputProjection(T) = .{},

        const Self = @This();

        pub fn init(ctx: *Context, allocator: std.mem.Allocator, size: usize, slide: u64, policy: merge.MergePolicy(T)) Self {
            return .{ .ctx = ctx, .core = SlidingCore(T).init(allocator, size, slide, policy) };
        }
        pub fn deinit(self: *Self) void {
            self.core.deinit();
        }
        pub fn push(self: *Self, v: T) !?T {
            const emit = try self.core.push(v);
            self.proj.set(emit);
            return emit;
        }
        pub fn output(self: *const Self) ?T {
            return self.proj.output_value;
        }
        pub fn outputVersion(self: *const Self) u64 {
            return self.proj.output_version;
        }
    };
}

/// Reactive session window (`push(now, v)` + `flush(now)`).
pub fn SessionWindow(comptime T: type) type {
    return struct {
        ctx: *Context,
        core: SessionCore(T),
        proj: OutputProjection(T) = .{},

        const Self = @This();

        pub fn init(ctx: *Context, gap: u64, policy: merge.MergePolicy(T)) Self {
            return .{ .ctx = ctx, .core = SessionCore(T).init(gap, policy) };
        }
        pub fn push(self: *Self, now: u64, v: T) ?T {
            const emit = self.core.push(now, v);
            self.proj.set(emit);
            return emit;
        }
        pub fn flush(self: *Self, now: u64) ?T {
            const emit = self.core.flush(now);
            self.proj.set(emit);
            return emit;
        }
        pub fn output(self: *const Self) ?T {
            return self.proj.output_value;
        }
        pub fn outputVersion(self: *const Self) u64 {
            return self.proj.output_version;
        }
    };
}

// ===========================================================================
// Unit tests (pure cores)
// ===========================================================================

test "windowing: tumbling count emits fold" {
    var w = TumblingCountCore(i64).init(3, merge.sum(i64));
    try std.testing.expectEqual(@as(?i64, null), w.push(1));
    try std.testing.expectEqual(@as(?i64, null), w.push(2));
    try std.testing.expectEqual(@as(?i64, 6), w.push(3));
    try std.testing.expectEqual(@as(?i64, null), w.push(4));
    try std.testing.expectEqual(@as(?i64, null), w.push(5));
    try std.testing.expectEqual(@as(?i64, 15), w.push(6));
}

test "windowing: tumbling time boundaries" {
    var w = TumblingTimeCore(i64).init(2, merge.sum(i64));
    w.push(0, 1);
    w.push(1, 2);
    try std.testing.expectEqual(@as(?i64, 3), w.tick(2));
    w.push(3, 4);
    try std.testing.expectEqual(@as(?i64, 4), w.tick(4));
    try std.testing.expectEqual(@as(?i64, null), w.tick(6)); // empty window
}

test "windowing: sliding fold over window" {
    var w = SlidingCore(i64).init(std.testing.allocator, 3, 1, merge.sum(i64));
    defer w.deinit();
    try std.testing.expectEqual(@as(?i64, 1), try w.push(1));
    try std.testing.expectEqual(@as(?i64, 3), try w.push(2));
    try std.testing.expectEqual(@as(?i64, 6), try w.push(3));
    try std.testing.expectEqual(@as(?i64, 9), try w.push(4));
    try std.testing.expectEqual(@as(?i64, 12), try w.push(5));
}

test "windowing: session gap close" {
    var w = SessionCore(i64).init(3, merge.sum(i64));
    try std.testing.expectEqual(@as(?i64, null), w.push(0, 1));
    try std.testing.expectEqual(@as(?i64, null), w.push(1, 2));
    try std.testing.expectEqual(@as(?i64, 3), w.push(10, 5)); // gap closes previous
    try std.testing.expectEqual(@as(?i64, 5), w.flush(20));
    try std.testing.expectEqual(@as(?i64, null), w.push(21, 7));
    try std.testing.expectEqual(@as(?i64, 7), w.flush(30));
}

// ===========================================================================
// lazily-spec conformance fixture replay
// `../lazily-spec/conformance/windowing/*.json` (mirrors lazily-rs
// `tests/windowing_conformance.rs`). Sum aggregate, i64 values.
// ===========================================================================

const json = std.json;
const SPEC_DIR = "../lazily-spec/conformance/windowing";

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
    const raw = readFixtureFile(SPEC_DIR ++ "/tumbling_count.json") catch return false;
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
fn jsonAsI64(value: json.Value) !i64 {
    return switch (value) {
        .integer => |n| n,
        .number_string => |s| try std.fmt.parseInt(i64, s, 10),
        else => error.ExpectedInteger,
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
/// `?i64` from a JSON field that may be null.
fn optI64(value: json.Value) !?i64 {
    return switch (value) {
        .null => null,
        else => try jsonAsI64(value),
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

fn config(fx: json.Value) !json.Value {
    return jsonFieldRequired(fx, "config");
}

test "windowing conformance: tumbling_count" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("tumbling_count.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const n = try jsonAsU64(try jsonFieldRequired(try config(fx), "n"));
    var w = TumblingCountWindow(i64).init(ctx, n, merge.sum(i64));

    for (try steps(fx)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const v = try jsonAsI64(try jsonFieldRequired(op, "value"));
        const pre = w.outputVersion();
        const emit = w.push(v);

        try std.testing.expectEqual(try optI64(try jsonFieldRequired(step, "returns")), emit);
        const exp = try jsonFieldRequired(step, "expected");
        try std.testing.expectEqual(try optI64(try jsonFieldRequired(exp, "output")), w.output());
        try std.testing.expectEqual(try invalidates(step, "output"), w.outputVersion() != pre);
    }
}

test "windowing conformance: tumbling_time" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("tumbling_time.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const period = try jsonAsU64(try jsonFieldRequired(try config(fx), "period"));
    var w = TumblingTimeWindow(i64).init(ctx, period, merge.sum(i64));

    for (try steps(fx)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const op_type = try jsonAsString(try jsonFieldRequired(op, "type"));
        const now = try jsonAsU64(try jsonFieldRequired(op, "now"));
        const pre = w.outputVersion();

        var emit: ?i64 = null;
        if (std.mem.eql(u8, op_type, "push")) {
            w.push(now, try jsonAsI64(try jsonFieldRequired(op, "value")));
        } else {
            emit = w.tick(now);
        }

        try std.testing.expectEqual(try optI64(try jsonFieldRequired(step, "returns")), emit);
        const exp = try jsonFieldRequired(step, "expected");
        try std.testing.expectEqual(try optI64(try jsonFieldRequired(exp, "output")), w.output());
        try std.testing.expectEqual(try invalidates(step, "output"), w.outputVersion() != pre);
    }
}

test "windowing conformance: sliding_count" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("sliding_count.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const cfg = try config(fx);
    const size: usize = @intCast(try jsonAsU64(try jsonFieldRequired(cfg, "size")));
    const slide = try jsonAsU64(try jsonFieldRequired(cfg, "slide"));
    var w = SlidingWindow(i64).init(ctx, std.testing.allocator, size, slide, merge.sum(i64));
    defer w.deinit();

    for (try steps(fx)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const v = try jsonAsI64(try jsonFieldRequired(op, "value"));
        const pre = w.outputVersion();
        const emit = try w.push(v);

        try std.testing.expectEqual(try optI64(try jsonFieldRequired(step, "returns")), emit);
        const exp = try jsonFieldRequired(step, "expected");
        try std.testing.expectEqual(try optI64(try jsonFieldRequired(exp, "output")), w.output());
        try std.testing.expectEqual(try invalidates(step, "output"), w.outputVersion() != pre);
    }
}

test "windowing conformance: session" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("session.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const gap = try jsonAsU64(try jsonFieldRequired(try config(fx), "gap"));
    var w = SessionWindow(i64).init(ctx, gap, merge.sum(i64));

    for (try steps(fx)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const op_type = try jsonAsString(try jsonFieldRequired(op, "type"));
        const now = try jsonAsU64(try jsonFieldRequired(op, "now"));
        const pre = w.outputVersion();

        var emit: ?i64 = null;
        if (std.mem.eql(u8, op_type, "push")) {
            emit = w.push(now, try jsonAsI64(try jsonFieldRequired(op, "value")));
        } else {
            emit = w.flush(now);
        }

        try std.testing.expectEqual(try optI64(try jsonFieldRequired(step, "returns")), emit);
        const exp = try jsonFieldRequired(step, "expected");
        try std.testing.expectEqual(try optI64(try jsonFieldRequired(exp, "output")), w.output());
        try std.testing.expectEqual(try invalidates(step, "output"), w.outputVersion() != pre);
    }
}
