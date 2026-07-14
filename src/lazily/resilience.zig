//! Fault-tolerance primitives (`#lzresilience`) — the Zig port of lazily-rs
//! `src/resilience.rs` (see `lazily-spec/docs/resilience.md` and the formal
//! model `lazily-formal/LazilyFormal/Resilience.lean`).
//!
//! Circuit breaker / retry / bulkhead / timeout, each a pure compute **core** (a
//! state machine / counter over the logical clock) split from a thin reactive
//! **cell** projecting the salient reader onto a per-reader logical version
//! counter.
//!
//! Reactive-cell model (matching `temporal.zig`): the shell owns a per-reader
//! logical version counter that is bumped **only when the projected reader value
//! provably changes** — the edge-only invalidation contract. A conformance test
//! diffs the version snapshot across a step to assert the fixture's `invalidates`
//! matrix. This is the Zig analogue of the rs `Cell<T>` `PartialEq` store-guard.

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("context.zig").Context;

// ===========================================================================
// Circuit breaker
// ===========================================================================

/// Circuit-breaker state.
pub const BreakerState = enum {
    /// Calls pass; failures accumulate in the window.
    closed,
    /// Fast-fail until the reset deadline.
    open,
    /// Allow a single probe.
    half_open,

    /// The lazily-spec fixture spelling of the state.
    pub fn specName(self: BreakerState) []const u8 {
        return switch (self) {
            .closed => "Closed",
            .open => "Open",
            .half_open => "HalfOpen",
        };
    }
};

/// Circuit-breaker compute core: a sliding window of outcomes trips
/// `Closed → Open` at `failure_threshold`; `Open → HalfOpen` at the deadline; a
/// HalfOpen success closes, a failure re-opens.
pub const CircuitBreakerCore = struct {
    allocator: std.mem.Allocator,
    window: usize,
    failure_threshold: usize,
    reset_timeout: u64,
    state_value: BreakerState = .closed,
    outcomes: std.ArrayList(bool), // true = success (used as a deque)
    open_until: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, window: usize, failure_threshold: usize, reset_timeout: u64) CircuitBreakerCore {
        return .{
            .allocator = allocator,
            .window = @max(window, 1),
            .failure_threshold = @max(failure_threshold, 1),
            .reset_timeout = reset_timeout,
            .state_value = .closed,
            .outcomes = std.ArrayList(bool).empty,
            .open_until = 0,
        };
    }
    pub fn deinit(self: *CircuitBreakerCore) void {
        self.outcomes.deinit(self.allocator);
    }
    pub fn state(self: *const CircuitBreakerCore) BreakerState {
        return self.state_value;
    }
    fn failures(self: *const CircuitBreakerCore) usize {
        var n: usize = 0;
        for (self.outcomes.items) |s| {
            if (!s) n += 1;
        }
        return n;
    }
    /// Whether a call is permitted; performs the `Open → HalfOpen` transition at
    /// the deadline.
    pub fn allow(self: *CircuitBreakerCore, now: u64) bool {
        switch (self.state_value) {
            .closed => return true,
            .open => {
                if (now >= self.open_until) {
                    self.state_value = .half_open;
                    return true;
                }
                return false;
            },
            .half_open => return true,
        }
    }
    /// Feed a call outcome and drive the state machine.
    pub fn record(self: *CircuitBreakerCore, success: bool, now: u64) !void {
        switch (self.state_value) {
            .half_open => {
                if (success) {
                    self.state_value = .closed;
                    self.outcomes.clearRetainingCapacity();
                } else {
                    self.state_value = .open;
                    self.open_until = now + self.reset_timeout;
                }
            },
            .closed => {
                try self.outcomes.append(self.allocator, success);
                while (self.outcomes.items.len > self.window) {
                    _ = self.outcomes.orderedRemove(0);
                }
                if (self.failures() >= self.failure_threshold) {
                    self.state_value = .open;
                    self.open_until = now + self.reset_timeout;
                }
            },
            .open => {},
        }
    }
};

/// Reactive circuit breaker: projects the `state` reader. The version bumps only
/// when the projected `BreakerState` provably changes.
pub const CircuitBreakerCell = struct {
    ctx: *Context,
    core: CircuitBreakerCore,
    state_version: u64 = 0,

    pub fn init(ctx: *Context, allocator: std.mem.Allocator, window: usize, failure_threshold: usize, reset_timeout: u64) CircuitBreakerCell {
        return .{ .ctx = ctx, .core = CircuitBreakerCore.init(allocator, window, failure_threshold, reset_timeout) };
    }
    pub fn deinit(self: *CircuitBreakerCell) void {
        self.core.deinit();
    }
    pub fn allow(self: *CircuitBreakerCell, now: u64) bool {
        const before = self.core.state();
        const r = self.core.allow(now);
        if (self.core.state() != before) self.state_version += 1;
        return r;
    }
    pub fn record(self: *CircuitBreakerCell, success: bool, now: u64) !void {
        const before = self.core.state();
        try self.core.record(success, now);
        if (self.core.state() != before) self.state_version += 1;
    }
    pub fn state(self: *const CircuitBreakerCell) BreakerState {
        return self.core.state();
    }
    pub fn stateVersion(self: *const CircuitBreakerCell) u64 {
        return self.state_version;
    }
};

// ===========================================================================
// Retry backoff
// ===========================================================================

/// Exponential-backoff compute core: `delay(attempt) = min(cap, base·2^attempt)`,
/// saturating to `cap` on shift overflow.
pub const RetryPolicyCore = struct {
    base: u64,
    cap: u64,
    attempt: u64 = 0,

    pub fn init(base: u64, cap: u64) RetryPolicyCore {
        return .{ .base = base, .cap = cap, .attempt = 0 };
    }
    /// The delay for `attempt` (saturating at `cap`).
    pub fn delay(self: *const RetryPolicyCore, attempt: u64) u64 {
        if (attempt >= 64) return self.cap;
        const d = @as(u128, self.base) << @intCast(attempt);
        return @intCast(@min(d, @as(u128, self.cap)));
    }
    /// The current attempt's delay, then advance (saturating).
    pub fn nextDelay(self: *RetryPolicyCore) u64 {
        const d = self.delay(self.attempt);
        self.attempt +|= 1;
        return d;
    }
    pub fn reset(self: *RetryPolicyCore) void {
        self.attempt = 0;
    }
};

/// Reactive retry policy: projects the current `delay` reader. The version bumps
/// only when the projected delay provably changes (a repeated saturated `cap`
/// does not bump).
pub const RetryPolicyCell = struct {
    ctx: *Context,
    core: RetryPolicyCore,
    delay_value: u64 = 0,
    delay_version: u64 = 0,

    pub fn init(ctx: *Context, base: u64, cap: u64) RetryPolicyCell {
        return .{ .ctx = ctx, .core = RetryPolicyCore.init(base, cap) };
    }
    pub fn nextDelay(self: *RetryPolicyCell) u64 {
        const d = self.core.nextDelay();
        if (d != self.delay_value) self.delay_version += 1;
        self.delay_value = d;
        return d;
    }
    pub fn reset(self: *RetryPolicyCell) void {
        self.core.reset();
        if (self.delay_value != 0) self.delay_version += 1;
        self.delay_value = 0;
    }
    pub fn delay(self: *const RetryPolicyCell) u64 {
        return self.delay_value;
    }
    pub fn delayVersion(self: *const RetryPolicyCell) u64 {
        return self.delay_version;
    }
};

// ===========================================================================
// Bulkhead
// ===========================================================================

/// Bounded isolation-pool compute core.
pub const BulkheadCore = struct {
    capacity: u64,
    in_use_value: u64 = 0,

    pub fn init(capacity: u64) BulkheadCore {
        return .{ .capacity = capacity, .in_use_value = 0 };
    }
    pub fn inUse(self: *const BulkheadCore) u64 {
        return self.in_use_value;
    }
    pub fn acquire(self: *BulkheadCore) bool {
        if (self.in_use_value < self.capacity) {
            self.in_use_value += 1;
            return true;
        }
        return false;
    }
    pub fn release(self: *BulkheadCore) void {
        if (self.in_use_value > 0) {
            self.in_use_value -= 1;
        }
    }
};

/// Reactive bulkhead: projects the `in_use` reader. The version bumps only when
/// `in_use` provably changes.
pub const BulkheadCell = struct {
    ctx: *Context,
    core: BulkheadCore,
    in_use_version: u64 = 0,

    pub fn init(ctx: *Context, capacity: u64) BulkheadCell {
        return .{ .ctx = ctx, .core = BulkheadCore.init(capacity) };
    }
    pub fn acquire(self: *BulkheadCell) bool {
        const before = self.core.inUse();
        const r = self.core.acquire();
        if (self.core.inUse() != before) self.in_use_version += 1;
        return r;
    }
    pub fn release(self: *BulkheadCell) void {
        const before = self.core.inUse();
        self.core.release();
        if (self.core.inUse() != before) self.in_use_version += 1;
    }
    pub fn inUse(self: *const BulkheadCell) u64 {
        return self.core.inUse();
    }
    pub fn inUseVersion(self: *const BulkheadCell) u64 {
        return self.in_use_version;
    }
};

// ===========================================================================
// Timeout
// ===========================================================================

/// Deadline-bounded call compute core.
pub const TimeoutCore = struct {
    deadline: u64 = 0,
    armed: bool = false,
    timed_out: bool = false,

    pub fn init() TimeoutCore {
        return .{ .deadline = 0, .armed = false, .timed_out = false };
    }
    /// Arm the timeout with `deadline = now + timeout`.
    pub fn arm(self: *TimeoutCore, now: u64, timeout: u64) void {
        self.deadline = now + timeout;
        self.armed = true;
        self.timed_out = false;
    }
    /// Fast-fail when `now >= deadline`; returns the timeout edge (once).
    pub fn tick(self: *TimeoutCore, now: u64) bool {
        if (self.armed and !self.timed_out and now >= self.deadline) {
            self.timed_out = true;
            return true;
        }
        return false;
    }
    pub fn isTimedOut(self: *const TimeoutCore) bool {
        return self.timed_out;
    }
};

/// Reactive timeout: projects the `is_timed_out` reader. The version bumps only
/// on the timeout edge.
pub const TimeoutCell = struct {
    ctx: *Context,
    core: TimeoutCore,
    timed_out_version: u64 = 0,

    pub fn init(ctx: *Context) TimeoutCell {
        return .{ .ctx = ctx, .core = TimeoutCore.init() };
    }
    pub fn arm(self: *TimeoutCell, now: u64, timeout: u64) void {
        const before = self.core.isTimedOut();
        self.core.arm(now, timeout);
        if (self.core.isTimedOut() != before) self.timed_out_version += 1;
    }
    pub fn tick(self: *TimeoutCell, now: u64) bool {
        const edge = self.core.tick(now);
        if (edge) self.timed_out_version += 1;
        return edge;
    }
    pub fn isTimedOut(self: *const TimeoutCell) bool {
        return self.core.isTimedOut();
    }
    pub fn timedOutVersion(self: *const TimeoutCell) u64 {
        return self.timed_out_version;
    }
};

// ===========================================================================
// Unit tests (pure cores)
// ===========================================================================

test "resilience: breaker trips and recovers" {
    var b = CircuitBreakerCore.init(std.testing.allocator, 3, 2, 5);
    defer b.deinit();
    try b.record(false, 0);
    try std.testing.expectEqual(BreakerState.closed, b.state());
    try b.record(false, 1);
    try std.testing.expectEqual(BreakerState.open, b.state());
    try std.testing.expect(!b.allow(2)); // fast-fail
    try std.testing.expect(b.allow(6)); // -> HalfOpen probe
    try std.testing.expectEqual(BreakerState.half_open, b.state());
    try b.record(true, 6); // close
    try std.testing.expectEqual(BreakerState.closed, b.state());
}

test "resilience: retry exponential saturates" {
    var r = RetryPolicyCore.init(100, 2000);
    try std.testing.expectEqual(@as(u64, 100), r.nextDelay());
    try std.testing.expectEqual(@as(u64, 200), r.nextDelay());
    try std.testing.expectEqual(@as(u64, 400), r.nextDelay());
    try std.testing.expectEqual(@as(u64, 800), r.nextDelay());
    try std.testing.expectEqual(@as(u64, 1600), r.nextDelay());
    try std.testing.expectEqual(@as(u64, 2000), r.nextDelay());
    try std.testing.expectEqual(@as(u64, 2000), r.nextDelay());
    r.reset();
    try std.testing.expectEqual(@as(u64, 100), r.nextDelay());
}

test "resilience: bulkhead bounded" {
    var b = BulkheadCore.init(2);
    try std.testing.expect(b.acquire());
    try std.testing.expect(b.acquire());
    try std.testing.expect(!b.acquire());
    b.release();
    try std.testing.expectEqual(@as(u64, 1), b.inUse());
}

test "resilience: timeout fires once" {
    var t = TimeoutCore.init();
    t.arm(0, 5);
    try std.testing.expect(!t.tick(3));
    try std.testing.expect(t.tick(5));
    try std.testing.expect(!t.tick(9)); // idempotent
    try std.testing.expect(t.isTimedOut());
}

// ===========================================================================
// lazily-spec conformance fixture replay
// `../lazily-spec/conformance/resilience/*.json` (mirrors lazily-rs
// `tests/resilience_conformance.rs`).
// ===========================================================================

const json = std.json;
const SPEC_DIR = "../lazily-spec/conformance/resilience";

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
    const raw = readFixtureFile(SPEC_DIR ++ "/circuit_breaker.json") catch return false;
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

test "resilience conformance: circuit_breaker" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("circuit_breaker.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const config = try jsonFieldRequired(fx, "config");
    const window: usize = @intCast(try jsonAsU64(try jsonFieldRequired(config, "window")));
    const failure_threshold: usize = @intCast(try jsonAsU64(try jsonFieldRequired(config, "failure_threshold")));
    const reset_timeout = try jsonAsU64(try jsonFieldRequired(config, "reset_timeout"));
    var breaker = CircuitBreakerCell.init(ctx, std.testing.allocator, window, failure_threshold, reset_timeout);
    defer breaker.deinit();

    for (try steps(fx)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const op_type = try jsonAsString(try jsonFieldRequired(op, "type"));
        const now = try jsonAsU64(try jsonFieldRequired(op, "now"));
        const pre = breaker.stateVersion();

        if (std.mem.eql(u8, op_type, "record")) {
            const success = try jsonAsBool(try jsonFieldRequired(op, "success"));
            try breaker.record(success, now);
        } else if (std.mem.eql(u8, op_type, "allow")) {
            const r = breaker.allow(now);
            try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(step, "returns")), r);
        } else {
            return error.UnknownOp;
        }

        const exp = try jsonFieldRequired(step, "expected");
        try std.testing.expectEqualStrings(
            try jsonAsString(try jsonFieldRequired(exp, "state")),
            breaker.state().specName(),
        );
        try std.testing.expectEqual(try invalidates(step, "state"), breaker.stateVersion() != pre);
    }
}

test "resilience conformance: retry" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("retry.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const config = try jsonFieldRequired(fx, "config");
    const base = try jsonAsU64(try jsonFieldRequired(config, "base"));
    const cap = try jsonAsU64(try jsonFieldRequired(config, "cap"));
    var retry = RetryPolicyCell.init(ctx, base, cap);

    for (try steps(fx)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const op_type = try jsonAsString(try jsonFieldRequired(op, "type"));
        const pre = retry.delayVersion();

        if (std.mem.eql(u8, op_type, "next")) {
            const d = retry.nextDelay();
            try std.testing.expectEqual(try jsonAsU64(try jsonFieldRequired(step, "returns")), d);
        } else {
            return error.UnknownOp;
        }

        const exp = try jsonFieldRequired(step, "expected");
        try std.testing.expectEqual(try jsonAsU64(try jsonFieldRequired(exp, "delay")), retry.delay());
        try std.testing.expectEqual(try invalidates(step, "delay"), retry.delayVersion() != pre);
    }
}

test "resilience conformance: bulkhead" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("bulkhead.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const config = try jsonFieldRequired(fx, "config");
    const capacity = try jsonAsU64(try jsonFieldRequired(config, "capacity"));
    var bulkhead = BulkheadCell.init(ctx, capacity);

    for (try steps(fx)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const op_type = try jsonAsString(try jsonFieldRequired(op, "type"));
        const pre = bulkhead.inUseVersion();

        if (std.mem.eql(u8, op_type, "acquire")) {
            const r = bulkhead.acquire();
            try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(step, "returns")), r);
        } else if (std.mem.eql(u8, op_type, "release")) {
            bulkhead.release();
            // `returns` is JSON null for release — assert it is present-and-null.
            try std.testing.expect(try jsonFieldRequired(step, "returns") == .null);
        } else {
            return error.UnknownOp;
        }

        const exp = try jsonFieldRequired(step, "expected");
        try std.testing.expectEqual(try jsonAsU64(try jsonFieldRequired(exp, "in_use")), bulkhead.inUse());
        try std.testing.expectEqual(try invalidates(step, "in_use"), bulkhead.inUseVersion() != pre);
    }
}

test "resilience conformance: timeout" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("timeout.json");
    defer parsed.deinit();
    const fx = parsed.value;

    var timeout = TimeoutCell.init(ctx);

    for (try steps(fx)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const op_type = try jsonAsString(try jsonFieldRequired(op, "type"));
        const now = try jsonAsU64(try jsonFieldRequired(op, "now"));
        const pre = timeout.timedOutVersion();

        if (std.mem.eql(u8, op_type, "arm")) {
            const timeout_ms = try jsonAsU64(try jsonFieldRequired(op, "timeout"));
            timeout.arm(now, timeout_ms);
            try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(step, "returns")), false);
        } else if (std.mem.eql(u8, op_type, "tick")) {
            const edge = timeout.tick(now);
            try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(step, "returns")), edge);
        } else {
            return error.UnknownOp;
        }

        const exp = try jsonFieldRequired(step, "expected");
        try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(exp, "is_timed_out")), timeout.isTimedOut());
        try std.testing.expectEqual(try invalidates(step, "is_timed_out"), timeout.timedOutVersion() != pre);
    }
}
