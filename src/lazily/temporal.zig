//! Temporal source primitives (`#lztime`) — the Zig port of lazily-rs
//! `src/time.rs` (see `lazily-spec/docs/temporal-sources.md`).
//!
//! Time is a **logical clock**: a runtime drives the sources by feeding a
//! monotone `now: u64` tick. Each source is a pure compute **core** (a
//! side-effect-free state machine over plain integers) split from a thin
//! reactive **cell** that projects the core's fire edge.
//!
//! Reactive-cell model (matching `queue.zig`): the shell owns a per-reader
//! logical version counter that is bumped **only when the projected reader value
//! provably changes** — the edge-only invalidation contract. A conformance test
//! diffs the version snapshot across a step to assert the fixture's `invalidates`
//! matrix. This is the Zig analogue of the rs `Cell<T>` `PartialEq` store-guard.

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("context.zig").Context;

// ===========================================================================
// Manual logical clock
// ===========================================================================

/// A monotone logical clock a manual runtime (game loop, test) owns to drive
/// sources. `advance` clamps backwards moves so `now` is always non-decreasing.
pub const ManualClock = struct {
    now_value: u64 = 0,

    pub fn init() ManualClock {
        return .{ .now_value = 0 };
    }
    pub fn now(self: *const ManualClock) u64 {
        return self.now_value;
    }
    /// Advance to `now` (monotone: a smaller value is clamped). Returns the
    /// effective `now` a source should be ticked with.
    pub fn advance(self: *ManualClock, now_arg: u64) u64 {
        self.now_value = @max(self.now_value, now_arg);
        return self.now_value;
    }
};

// ===========================================================================
// Single-shot timer
// ===========================================================================

/// Single-shot compute core: `false → true` at the first tick with
/// `now >= fire_at`; fires exactly once (idempotent thereafter).
pub const TimerCore = struct {
    fire_at: u64,
    is_fired: bool = false,

    pub fn init(fire_at: u64) TimerCore {
        return .{ .fire_at = fire_at, .is_fired = false };
    }
    pub fn fired(self: *const TimerCore) bool {
        return self.is_fired;
    }
    /// Advance to logical time `now`. Returns `true` on the fire edge.
    pub fn tick(self: *TimerCore, now: u64) bool {
        if (self.is_fired or now < self.fire_at) return false;
        self.is_fired = true;
        return true;
    }
    /// Logical time of the next fire, or `null` when exhausted.
    pub fn nextFire(self: *const TimerCore) ?u64 {
        return if (self.is_fired) null else self.fire_at;
    }
};

/// Reactive single-shot timer. `fired`/`value` invalidate only on the fire.
pub const TimerCell = struct {
    ctx: *Context,
    core: TimerCore,
    fired_version: u64 = 0,

    pub fn init(ctx: *Context, fire_at: u64) TimerCell {
        return .{ .ctx = ctx, .core = TimerCore.init(fire_at) };
    }
    /// Advance to `now`; returns the fire edge. Bumps the `fired` version once.
    pub fn tick(self: *TimerCell, now: u64) bool {
        const edge = self.core.tick(now);
        if (edge) self.fired_version += 1;
        return edge;
    }
    pub fn hasFired(self: *const TimerCell) bool {
        return self.core.fired();
    }
    /// `null` before the fire, `{}` (unit) after.
    pub fn value(self: *const TimerCell) ?void {
        return if (self.core.fired()) {} else null;
    }
    pub fn nextFire(self: *const TimerCell) ?u64 {
        return self.core.nextFire();
    }
    pub fn firedVersion(self: *const TimerCell) u64 {
        return self.fired_version;
    }
};

// ===========================================================================
// Periodic interval
// ===========================================================================

/// Periodic compute core: fire boundaries at `period, 2*period, ...`. A tick
/// counts every boundary in `(frontier, now]`.
pub const IntervalCore = struct {
    period: u64,
    next: u64,
    count_value: u64 = 0,

    pub fn init(period: u64) IntervalCore {
        const p = @max(period, 1);
        return .{ .period = p, .next = p, .count_value = 0 };
    }
    pub fn count(self: *const IntervalCore) u64 {
        return self.count_value;
    }
    fn firesThisTick(self: *const IntervalCore, now: u64) u64 {
        if (now < self.next) return 0;
        return (now - self.next) / self.period + 1;
    }
    pub fn tick(self: *IntervalCore, now: u64) bool {
        const fires = self.firesThisTick(now);
        if (fires == 0) return false;
        self.count_value += fires;
        self.next += fires * self.period;
        return true;
    }
    pub fn nextFire(self: *const IntervalCore) ?u64 {
        return self.next;
    }
};

/// Reactive periodic interval. `count` invalidates only when it changes.
pub const IntervalCell = struct {
    ctx: *Context,
    core: IntervalCore,
    count_version: u64 = 0,

    pub fn init(ctx: *Context, period: u64) IntervalCell {
        return .{ .ctx = ctx, .core = IntervalCore.init(period) };
    }
    pub fn tick(self: *IntervalCell, now: u64) bool {
        const before = self.core.count();
        const edge = self.core.tick(now);
        if (self.core.count() != before) self.count_version += 1;
        return edge;
    }
    pub fn count(self: *const IntervalCell) u64 {
        return self.core.count();
    }
    pub fn nextFire(self: *const IntervalCell) ?u64 {
        return self.core.nextFire();
    }
    pub fn countVersion(self: *const IntervalCell) u64 {
        return self.count_version;
    }
};

// ===========================================================================
// Cron pattern
// ===========================================================================

/// Count of `m in 1..=n` with `m mod cycle == o` (`0 <= o < cycle`).
fn countUpto(n: u64, o: u64, cycle: u64) u64 {
    if (o == 0) return n / cycle;
    if (o <= n) return (n - o) / cycle + 1;
    return 0;
}

/// Pattern-periodic compute core: a tick `m >= 1` fires iff `m mod cycle` is in
/// `offsets`. The match count in `(cursor, now]` is computed arithmetically.
pub const CronCore = struct {
    allocator: std.mem.Allocator,
    cycle: u64,
    offsets: []u64, // reduced mod cycle, sorted, deduped
    cursor: u64 = 0,
    count_value: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, cycle: u64, offsets_in: []const u64) !CronCore {
        const c = @max(cycle, 1);
        var list = std.ArrayList(u64).empty;
        errdefer list.deinit(allocator);
        for (offsets_in) |o| try list.append(allocator, o % c);
        std.mem.sort(u64, list.items, {}, std.sort.asc(u64));
        // dedup in place
        var w: usize = 0;
        for (list.items, 0..) |v, i| {
            if (i == 0 or v != list.items[w - 1]) {
                list.items[w] = v;
                w += 1;
            }
        }
        list.shrinkRetainingCapacity(w);
        return .{
            .allocator = allocator,
            .cycle = c,
            .offsets = try list.toOwnedSlice(allocator),
        };
    }
    pub fn deinit(self: *CronCore) void {
        self.allocator.free(self.offsets);
    }
    pub fn count(self: *const CronCore) u64 {
        return self.count_value;
    }
    fn matchesIn(self: *const CronCore, lo: u64, hi: u64) u64 {
        var sum: u64 = 0;
        for (self.offsets) |o| {
            sum += countUpto(hi, o, self.cycle) - countUpto(lo, o, self.cycle);
        }
        return sum;
    }
    pub fn tick(self: *CronCore, now: u64) bool {
        if (now <= self.cursor) {
            self.cursor = @max(self.cursor, now);
            return false;
        }
        const fires = self.matchesIn(self.cursor, now);
        self.cursor = now;
        if (fires == 0) return false;
        self.count_value += fires;
        return true;
    }
    pub fn nextFire(self: *const CronCore) ?u64 {
        if (self.offsets.len == 0) return null;
        const start = self.cursor + 1;
        const base = start / self.cycle * self.cycle;
        var cyc: u64 = 0;
        while (cyc < 2) : (cyc += 1) {
            const block = base + cyc * self.cycle;
            for (self.offsets) |o| {
                const cand = block + o;
                if (cand >= start) return cand;
            }
        }
        return null;
    }
};

/// Reactive cron source: same reactive contract as `IntervalCell`.
pub const CronCell = struct {
    ctx: *Context,
    core: CronCore,
    count_version: u64 = 0,

    pub fn init(ctx: *Context, allocator: std.mem.Allocator, cycle: u64, offsets_in: []const u64) !CronCell {
        return .{ .ctx = ctx, .core = try CronCore.init(allocator, cycle, offsets_in) };
    }
    pub fn deinit(self: *CronCell) void {
        self.core.deinit();
    }
    pub fn tick(self: *CronCell, now: u64) bool {
        const before = self.core.count();
        const edge = self.core.tick(now);
        if (self.core.count() != before) self.count_version += 1;
        return edge;
    }
    pub fn count(self: *const CronCell) u64 {
        return self.core.count();
    }
    pub fn nextFire(self: *const CronCell) ?u64 {
        return self.core.nextFire();
    }
    pub fn countVersion(self: *const CronCell) u64 {
        return self.count_version;
    }
};

// ===========================================================================
// Value + deadline
// ===========================================================================

/// A value paired with a liveness state: `Live` until its deadline, then
/// `Expired` — the value is preserved across the flip.
pub const DeadlineState = enum { live, expired };

/// Deadline compute core (bytes-eligible): a `TimerCore` over the deadline.
pub const DeadlineCore = struct {
    timer: TimerCore,

    pub fn init(deadline: u64) DeadlineCore {
        return .{ .timer = TimerCore.init(deadline) };
    }
    pub fn isExpired(self: *const DeadlineCore) bool {
        return self.timer.fired();
    }
    pub fn tick(self: *DeadlineCore, now: u64) bool {
        return self.timer.tick(now);
    }
    pub fn nextFire(self: *const DeadlineCore) ?u64 {
        return self.timer.nextFire();
    }
};

/// Reactive value + deadline: flips `Live(v) -> Expired(v)` at the deadline,
/// preserving the value; the `state` reader invalidates only on the expiry edge.
pub fn DeadlineCell(comptime T: type) type {
    return struct {
        ctx: *Context,
        core: DeadlineCore,
        stored_value: T,
        state_version: u64 = 0,

        const Self = @This();

        pub fn init(ctx: *Context, initial_value: T, deadline: u64) Self {
            return .{ .ctx = ctx, .core = DeadlineCore.init(deadline), .stored_value = initial_value };
        }
        pub fn tick(self: *Self, now: u64) bool {
            const edge = self.core.tick(now);
            if (edge) self.state_version += 1;
            return edge;
        }
        pub fn state(self: *const Self) DeadlineState {
            return if (self.core.isExpired()) .expired else .live;
        }
        pub fn value(self: *const Self) T {
            return self.stored_value;
        }
        pub fn isExpired(self: *const Self) bool {
            return self.core.isExpired();
        }
        pub fn nextFire(self: *const Self) ?u64 {
            return self.core.nextFire();
        }
        pub fn stateVersion(self: *const Self) u64 {
            return self.state_version;
        }
    };
}

// ===========================================================================
// Unit tests (pure cores)
// ===========================================================================

test "temporal: timer fires once" {
    var t = TimerCore.init(3);
    try std.testing.expect(!t.tick(1));
    try std.testing.expectEqual(@as(?u64, 3), t.nextFire());
    try std.testing.expect(t.tick(3));
    try std.testing.expect(!t.tick(5)); // idempotent
    try std.testing.expectEqual(@as(?u64, null), t.nextFire());
    try std.testing.expect(t.fired());
}

test "temporal: interval counts boundaries including jumps" {
    var iv = IntervalCore.init(2);
    try std.testing.expect(!iv.tick(1));
    try std.testing.expectEqual(@as(u64, 0), iv.count());
    try std.testing.expect(iv.tick(2));
    try std.testing.expectEqual(@as(u64, 1), iv.count());
    try std.testing.expect(iv.tick(4));
    try std.testing.expectEqual(@as(u64, 2), iv.count());
    try std.testing.expect(!iv.tick(5));
    try std.testing.expect(iv.tick(8)); // crosses 6 and 8
    try std.testing.expectEqual(@as(u64, 4), iv.count());
    try std.testing.expectEqual(@as(?u64, 10), iv.nextFire());
}

test "temporal: cron fires on pattern" {
    var c = try CronCore.init(std.testing.allocator, 5, &.{ 0, 3 });
    defer c.deinit();
    try std.testing.expect(!c.tick(2));
    try std.testing.expectEqual(@as(u64, 0), c.count());
    try std.testing.expectEqual(@as(?u64, 3), c.nextFire());
    try std.testing.expect(c.tick(3));
    try std.testing.expectEqual(@as(u64, 1), c.count());
    try std.testing.expect(c.tick(5));
    try std.testing.expect(c.tick(8));
    try std.testing.expect(c.tick(10));
    try std.testing.expectEqual(@as(u64, 4), c.count());
    try std.testing.expectEqual(@as(?u64, 13), c.nextFire());
}

// ===========================================================================
// lazily-spec conformance fixture replay
// `../lazily-spec/conformance/temporal/*.json` (mirrors lazily-rs
// `tests/temporal_conformance.rs`).
// ===========================================================================

const json = std.json;
const SPEC_DIR = "../lazily-spec/conformance/temporal";

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
    const raw = readFixtureFile(SPEC_DIR ++ "/timer_single_shot.json") catch return false;
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

test "temporal conformance: timer_single_shot" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("timer_single_shot.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const fire_at = try jsonAsU64(try jsonFieldRequired(try jsonFieldRequired(fx, "initial"), "fire_at"));
    var timer = TimerCell.init(ctx, fire_at);

    for (try steps(fx)) |step| {
        const now = try jsonAsU64(try jsonFieldRequired(try jsonFieldRequired(step, "op"), "now"));
        const pre = timer.firedVersion();
        const edge = timer.tick(now);

        try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(step, "returns")), edge);
        const exp = try jsonFieldRequired(step, "expected");
        try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(exp, "fired")), timer.hasFired());
        const want_value: bool = switch (try jsonFieldRequired(exp, "value")) {
            .null => false,
            else => true,
        };
        try std.testing.expectEqual(want_value, timer.value() != null);
        try std.testing.expectEqual(try optU64(try jsonFieldRequired(exp, "next_fire")), timer.nextFire());

        const changed = timer.firedVersion() != pre;
        try std.testing.expectEqual(try invalidates(step, "fired"), changed);
    }
}

test "temporal conformance: interval_periodic" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("interval_periodic.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const period = try jsonAsU64(try jsonFieldRequired(try jsonFieldRequired(fx, "initial"), "period"));
    var iv = IntervalCell.init(ctx, period);

    for (try steps(fx)) |step| {
        const now = try jsonAsU64(try jsonFieldRequired(try jsonFieldRequired(step, "op"), "now"));
        const pre = iv.countVersion();
        const edge = iv.tick(now);

        try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(step, "returns")), edge);
        const exp = try jsonFieldRequired(step, "expected");
        try std.testing.expectEqual(try jsonAsU64(try jsonFieldRequired(exp, "count")), iv.count());
        try std.testing.expectEqual(try optU64(try jsonFieldRequired(exp, "next_fire")), iv.nextFire());
        try std.testing.expectEqual(try invalidates(step, "count"), iv.countVersion() != pre);
    }
}

test "temporal conformance: cron_pattern" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("cron_pattern.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const initial = try jsonFieldRequired(fx, "initial");
    const cycle = try jsonAsU64(try jsonFieldRequired(initial, "cycle"));
    var offsets = std.ArrayList(u64).empty;
    defer offsets.deinit(std.testing.allocator);
    for ((try jsonFieldRequired(initial, "offsets")).array.items) |o| {
        try offsets.append(std.testing.allocator, try jsonAsU64(o));
    }
    var cron = try CronCell.init(ctx, std.testing.allocator, cycle, offsets.items);
    defer cron.deinit();

    for (try steps(fx)) |step| {
        const now = try jsonAsU64(try jsonFieldRequired(try jsonFieldRequired(step, "op"), "now"));
        const pre = cron.countVersion();
        const edge = cron.tick(now);

        try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(step, "returns")), edge);
        const exp = try jsonFieldRequired(step, "expected");
        try std.testing.expectEqual(try jsonAsU64(try jsonFieldRequired(exp, "count")), cron.count());
        try std.testing.expectEqual(try optU64(try jsonFieldRequired(exp, "next_fire")), cron.nextFire());
        try std.testing.expectEqual(try invalidates(step, "count"), cron.countVersion() != pre);
    }
}

test "temporal conformance: deadline_expiry" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("deadline_expiry.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const initial = try jsonFieldRequired(fx, "initial");
    const val = try jsonAsString(try jsonFieldRequired(initial, "value"));
    const deadline = try jsonAsU64(try jsonFieldRequired(initial, "deadline"));
    var d = DeadlineCell([]const u8).init(ctx, val, deadline);

    for (try steps(fx)) |step| {
        const now = try jsonAsU64(try jsonFieldRequired(try jsonFieldRequired(step, "op"), "now"));
        const pre = d.stateVersion();
        const edge = d.tick(now);

        try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(step, "returns")), edge);
        const exp = try jsonFieldRequired(step, "expected");
        const want_expired = std.mem.eql(u8, try jsonAsString(try jsonFieldRequired(exp, "state")), "Expired");
        try std.testing.expectEqual(want_expired, d.isExpired());
        try std.testing.expectEqualStrings(try jsonAsString(try jsonFieldRequired(exp, "value")), d.value());
        try std.testing.expectEqual(try invalidates(step, "state"), d.stateVersion() != pre);
    }
}
