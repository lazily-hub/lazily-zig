//! Rate-shaping source primitives (`#lzrateshape`) — the Zig port of the source
//! operators in lazily-rs `src/rateshape.rs` (see `lazily-spec/docs/rate-shaping.md`
//! and the formal model `lazily-formal/LazilyFormal/RateShape.lean`).
//!
//! Debounce / throttle / time-sampling already exist algorithmically inside the
//! relay plane (`src/lazily/relay.zig` — `RatePolicy` / `WindowPolicy` /
//! `ExpiryPolicy`); those are intentionally NOT re-added here. This module hosts
//! the four **source operators** so any reactive source can be rate-shaped, not
//! just a relay egress: `DebounceCell`, `ThrottleCell`, `SampleCell`, and
//! `ProbabilisticSampleCell`.
//!
//! Each operator is a pure compute **core** — the emit/drop decision over plain
//! state — split from a thin reactive **cell** that projects the emitted value.
//!
//! Reactive-cell model (matching `temporal.zig`): the shell owns a per-reader
//! logical version counter that is bumped **only when the projected reader value
//! provably changes**. All these cells have one reader named `output` of type
//! `?[]const u8`. On an emit of value `v`, if the held output is null OR not
//! byte-equal to `v`, store `v` and bump `output_version`; a null emit or an
//! equal-value emit does NOT bump. This is the Zig analogue of the rs
//! `Cell<Option<T>>` `PartialEq` store-guard: a dropped input never invalidates
//! dependents. String values are borrowed slices from the parsed JSON (which
//! outlives the replay) — they are not duplicated.

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("context.zig").Context;

/// Values carried by these source operators.
pub const Value = []const u8;

/// Shared output projection: hold the last emitted value + a per-reader version
/// bumped only when the projected value provably changes (emit-only invalidation).
const OutputProjection = struct {
    value: ?Value = null,
    version: u64 = 0,

    /// Project an operator emit onto the output reader. A `null` emit (a drop /
    /// hold) or an emit byte-equal to the held value does NOT bump the version.
    fn set(self: *OutputProjection, emitted: ?Value) void {
        const v = emitted orelse return;
        if (self.value == null or !std.mem.eql(u8, self.value.?, v)) {
            self.value = v;
            self.version += 1;
        }
    }
};

// ===========================================================================
// Debounce
// ===========================================================================

/// Debounce compute core: coalesce inputs (KeepLatest) and emit the latest value
/// only after `quiet` ticks with no new input — every input resets the deadline.
pub const DebounceCore = struct {
    quiet: u64,
    pending: ?Value = null,
    fire_at: u64 = 0,
    armed: bool = false,

    pub fn init(quiet: u64) DebounceCore {
        return .{ .quiet = quiet };
    }

    /// Record an input; resets the quiet deadline to `now + quiet`.
    pub fn input(self: *DebounceCore, now: u64, v: Value) void {
        self.pending = v;
        self.fire_at = now + self.quiet;
        self.armed = true;
    }

    /// Advance; emits the latest value once the quiet period has elapsed.
    pub fn tick(self: *DebounceCore, now: u64) ?Value {
        if (self.armed and self.pending != null and self.fire_at <= now) {
            self.armed = false;
            const v = self.pending;
            self.pending = null;
            return v;
        }
        return null;
    }
};

/// Reactive debounce. `output` invalidates only on the emit edge.
pub const DebounceCell = struct {
    ctx: *Context,
    core: DebounceCore,
    out: OutputProjection = .{},

    pub fn init(ctx: *Context, quiet: u64) DebounceCell {
        return .{ .ctx = ctx, .core = DebounceCore.init(quiet) };
    }
    pub fn input(self: *DebounceCell, now: u64, v: Value) void {
        self.core.input(now, v);
    }
    pub fn tick(self: *DebounceCell, now: u64) ?Value {
        const emitted = self.core.tick(now);
        self.out.set(emitted);
        return emitted;
    }
    pub fn output(self: *const DebounceCell) ?Value {
        return self.out.value;
    }
    pub fn outputVersion(self: *const DebounceCell) u64 {
        return self.out.version;
    }
};

// ===========================================================================
// Throttle
// ===========================================================================

/// Which edge of the window a [`ThrottleCore`] emits on.
pub const ThrottleEdge = enum {
    /// First input of a window passes immediately; the rest are dropped.
    leading,
    /// First input opens the window; the latest is emitted at the boundary.
    trailing,
};

/// Throttle compute core: at most one emit per `window`.
pub const ThrottleCore = struct {
    edge: ThrottleEdge,
    window: u64,
    // Leading: end of the currently-open window.
    window_end: ?u64 = null,
    // Trailing: start of the currently-open window.
    window_start: ?u64 = null,
    pending: ?Value = null,

    pub fn init(edge: ThrottleEdge, window: u64) ThrottleCore {
        return .{ .edge = edge, .window = window };
    }

    /// Record an input. Leading emits (or drops); Trailing coalesces and holds.
    pub fn input(self: *ThrottleCore, now: u64, v: Value) ?Value {
        switch (self.edge) {
            .leading => {
                if (self.window_end) |we| {
                    if (now < we) return null;
                }
                self.window_end = now + self.window;
                return v;
            },
            .trailing => {
                if (self.window_start == null) self.window_start = now;
                self.pending = v;
                return null;
            },
        }
    }

    /// Advance. Trailing emits the coalesced latest at the window boundary.
    pub fn tick(self: *ThrottleCore, now: u64) ?Value {
        switch (self.edge) {
            .leading => return null,
            .trailing => {
                const ws = self.window_start orelse return null;
                if (now >= ws + self.window and self.pending != null) {
                    self.window_start = null;
                    const v = self.pending;
                    self.pending = null;
                    return v;
                }
                return null;
            },
        }
    }
};

/// Reactive throttle. `output` invalidates only on the emit edge.
pub const ThrottleCell = struct {
    ctx: *Context,
    core: ThrottleCore,
    out: OutputProjection = .{},

    pub fn init(ctx: *Context, edge: ThrottleEdge, window: u64) ThrottleCell {
        return .{ .ctx = ctx, .core = ThrottleCore.init(edge, window) };
    }
    pub fn input(self: *ThrottleCell, now: u64, v: Value) ?Value {
        const emitted = self.core.input(now, v);
        self.out.set(emitted);
        return emitted;
    }
    pub fn tick(self: *ThrottleCell, now: u64) ?Value {
        const emitted = self.core.tick(now);
        self.out.set(emitted);
        return emitted;
    }
    pub fn output(self: *const ThrottleCell) ?Value {
        return self.out.value;
    }
    pub fn outputVersion(self: *const ThrottleCell) u64 {
        return self.out.version;
    }
};

// ===========================================================================
// Sample
// ===========================================================================

/// Sampling mode tag for [`SampleCore`].
pub const SampleModeTag = enum { count, time };

/// Sampling mode: `count` emits every `n`-th input; `time` emits the held latest
/// at each `period` boundary.
pub const SampleMode = union(SampleModeTag) {
    count: u64,
    time: u64,
};

/// Deterministic sampling compute core.
pub const SampleCore = struct {
    mode: SampleMode,
    counter: u64 = 0,
    next: u64 = 0,
    held: ?Value = null,

    pub fn init(mode: SampleMode) SampleCore {
        const next: u64 = switch (mode) {
            .time => |p| @max(p, 1),
            .count => 0,
        };
        return .{ .mode = mode, .next = next };
    }

    /// Record an input. Count emits on every `n`-th; Time holds the latest.
    pub fn input(self: *SampleCore, v: Value) ?Value {
        switch (self.mode) {
            .count => |n_raw| {
                const n = @max(n_raw, 1);
                self.counter += 1;
                if (self.counter % n == 0) return v;
                return null;
            },
            .time => {
                self.held = v;
                return null;
            },
        }
    }

    /// Advance. Time emits the held latest once per period boundary crossed.
    pub fn tick(self: *SampleCore, now: u64) ?Value {
        switch (self.mode) {
            .count => return null,
            .time => |period_raw| {
                const period = @max(period_raw, 1);
                if (now < self.next) return null;
                const fires = (now - self.next) / period + 1;
                self.next += fires * period;
                // Emit the held latest; it persists (sampling the current value).
                return self.held;
            },
        }
    }
};

/// Reactive sampler. `output` invalidates only on the emit edge.
pub const SampleCell = struct {
    ctx: *Context,
    core: SampleCore,
    out: OutputProjection = .{},

    pub fn init(ctx: *Context, mode: SampleMode) SampleCell {
        return .{ .ctx = ctx, .core = SampleCore.init(mode) };
    }
    pub fn input(self: *SampleCell, v: Value) ?Value {
        const emitted = self.core.input(v);
        self.out.set(emitted);
        return emitted;
    }
    pub fn tick(self: *SampleCell, now: u64) ?Value {
        const emitted = self.core.tick(now);
        self.out.set(emitted);
        return emitted;
    }
    pub fn output(self: *const SampleCell) ?Value {
        return self.out.value;
    }
    pub fn outputVersion(self: *const SampleCell) u64 {
        return self.out.version;
    }
};

// ===========================================================================
// Probabilistic sample
// ===========================================================================

/// A small deterministic LCG (SplitMix64-style) — no external RNG dependency,
/// reproducible. `nextF64` yields a draw in `[0, 1)`.
pub const Lcg = struct {
    state: u64,

    pub fn init(seed: u64) Lcg {
        return .{ .state = seed };
    }

    /// SplitMix64 → a 53-bit-mantissa draw in `[0, 1)`.
    pub fn nextF64(self: *Lcg) f64 {
        self.state = self.state +% 0x9E37_79B9_7F4A_7C15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xBF58_476D_1CE4_E5B9;
        z = (z ^ (z >> 27)) *% 0x94D0_49BB_1331_11EB;
        z ^= z >> 31;
        const mant: f64 = @floatFromInt(z >> 11);
        return mant / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    }
};

/// An injectable RNG so probabilistic sampling is deterministic under a fixed
/// seed. Any struct with `pub fn nextF64(self: *Self) f64` satisfies it; `Lcg`
/// is the built-in implementation.
pub const SampleRng = Lcg;

/// Probabilistic (tail) sampling compute core. A draw in `[0, 1)` passes iff
/// `draw < rate` (strict). `rate` is clamped to `[0, 1]`.
pub const ProbabilisticSampleCore = struct {
    rate_value: f64,

    pub fn init(rate_arg: f64) ProbabilisticSampleCore {
        return .{ .rate_value = std.math.clamp(rate_arg, 0.0, 1.0) };
    }
    pub fn rate(self: *const ProbabilisticSampleCore) f64 {
        return self.rate_value;
    }
    /// Whether an input with this random `draw` is sampled.
    pub fn decide(self: *const ProbabilisticSampleCore, draw: f64) bool {
        return draw < self.rate_value;
    }
};

/// Reactive probabilistic sampler; owns an injectable RNG. `output` invalidates
/// only when an input passes.
pub fn ProbabilisticSampleCell(comptime Rng: type) type {
    return struct {
        ctx: *Context,
        core: ProbabilisticSampleCore,
        rng: Rng,
        out: OutputProjection = .{},

        const Self = @This();

        pub fn init(ctx: *Context, rate: f64, rng: Rng) Self {
            return .{ .ctx = ctx, .core = ProbabilisticSampleCore.init(rate), .rng = rng };
        }

        /// Sample an input using the owned RNG.
        pub fn input(self: *Self, v: Value) ?Value {
            const draw = self.rng.nextF64();
            return self.inputWithDraw(v, draw);
        }

        /// Sample an input against an explicit `draw` (deterministic / conformance).
        pub fn inputWithDraw(self: *Self, v: Value, draw: f64) ?Value {
            if (self.core.decide(draw)) {
                self.out.set(v);
                return v;
            }
            return null;
        }

        pub fn output(self: *const Self) ?Value {
            return self.out.value;
        }
        pub fn outputVersion(self: *const Self) u64 {
            return self.out.version;
        }
    };
}

// ===========================================================================
// Unit tests (pure cores) — mirror the rs `#[cfg(test)]` tests.
// ===========================================================================

test "rateshape: debounce emits latest after quiet" {
    var d = DebounceCore.init(3);
    d.input(0, "a");
    d.input(1, "b");
    try std.testing.expectEqual(@as(?Value, null), d.tick(3)); // before deadline (4)
    try std.testing.expectEqualStrings("b", d.tick(4).?);
    try std.testing.expectEqual(@as(?Value, null), d.tick(5));
}

test "rateshape: throttle leading one per window" {
    var t = ThrottleCore.init(.leading, 5);
    try std.testing.expectEqualStrings("a", t.input(0, "a").?);
    try std.testing.expectEqual(@as(?Value, null), t.input(2, "b"));
    try std.testing.expectEqualStrings("c", t.input(5, "c").?);
}

test "rateshape: throttle trailing emits latest at boundary" {
    var t = ThrottleCore.init(.trailing, 5);
    try std.testing.expectEqual(@as(?Value, null), t.input(0, "a"));
    try std.testing.expectEqual(@as(?Value, null), t.input(2, "b"));
    try std.testing.expectEqualStrings("b", t.tick(5).?);
    try std.testing.expectEqual(@as(?Value, null), t.tick(6));
}

test "rateshape: sample count every nth" {
    var s = SampleCore.init(.{ .count = 3 });
    try std.testing.expectEqual(@as(?Value, null), s.input("a"));
    try std.testing.expectEqual(@as(?Value, null), s.input("b"));
    try std.testing.expectEqualStrings("c", s.input("c").?);
    try std.testing.expectEqual(@as(?Value, null), s.input("d"));
}

test "rateshape: sample time emits held latest" {
    var s = SampleCore.init(.{ .time = 2 });
    _ = s.input("a");
    _ = s.input("b");
    try std.testing.expectEqualStrings("b", s.tick(2).?);
    _ = s.input("c");
    try std.testing.expectEqualStrings("c", s.tick(4).?);
    try std.testing.expectEqual(@as(?Value, null), s.tick(5));
}

test "rateshape: probabilistic threshold" {
    const c = ProbabilisticSampleCore.init(0.5);
    try std.testing.expect(c.decide(0.2));
    try std.testing.expect(!c.decide(0.7));
    try std.testing.expect(!c.decide(0.5)); // strict <
}

test "rateshape: lcg draws are in [0,1)" {
    var rng = Lcg.init(42);
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const d = rng.nextF64();
        try std.testing.expect(d >= 0.0 and d < 1.0);
    }
}

// ===========================================================================
// lazily-spec conformance fixture replay
// `../lazily-spec/conformance/rateshape/*.json` (mirrors lazily-rs
// `tests/rateshape_conformance.rs`).
// ===========================================================================

const json = std.json;
const SPEC_DIR = "../lazily-spec/conformance/rateshape";

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
    const raw = readFixtureFile(SPEC_DIR ++ "/debounce.json") catch return false;
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
fn jsonAsF64(value: json.Value) !f64 {
    return switch (value) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        .number_string => |s| try std.fmt.parseFloat(f64, s),
        else => error.ExpectedFloat,
    };
}
/// `?[]const u8` from a JSON field that may be null / absent (string or null).
fn optString(value: json.Value) !?[]const u8 {
    return switch (value) {
        .null => null,
        else => try jsonAsString(value),
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

/// Assert the step's `returns` (string emit or null) and the `output` /
/// `invalidates.output` expectations against an operator emit + projection.
fn expectStep(step: json.Value, emitted: ?Value, out: ?Value, out_changed: bool) !void {
    // returns
    const want_return = try optString(try jsonFieldRequired(step, "returns"));
    if (want_return) |wr| {
        try std.testing.expect(emitted != null);
        try std.testing.expectEqualStrings(wr, emitted.?);
    } else {
        try std.testing.expectEqual(@as(?Value, null), emitted);
    }
    // expected.output
    const exp = try jsonFieldRequired(step, "expected");
    const want_out = try optString(try jsonFieldRequired(exp, "output"));
    if (want_out) |wo| {
        try std.testing.expect(out != null);
        try std.testing.expectEqualStrings(wo, out.?);
    } else {
        try std.testing.expectEqual(@as(?Value, null), out);
    }
    // expected.invalidates.output
    try std.testing.expectEqual(try invalidates(step, "output"), out_changed);
}

test "rateshape conformance: debounce" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("debounce.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const quiet = try jsonAsU64(try jsonFieldRequired(try jsonFieldRequired(fx, "initial"), "quiet"));
    var cell = DebounceCell.init(ctx, quiet);

    for (try steps(fx)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const ty = try jsonAsString(try jsonFieldRequired(op, "type"));
        const pre = cell.outputVersion();
        var emitted: ?Value = null;
        if (std.mem.eql(u8, ty, "input")) {
            const now = try jsonAsU64(try jsonFieldRequired(op, "now"));
            const v = try jsonAsString(try jsonFieldRequired(op, "value"));
            cell.input(now, v);
        } else {
            const now = try jsonAsU64(try jsonFieldRequired(op, "now"));
            emitted = cell.tick(now);
        }
        try expectStep(step, emitted, cell.output(), cell.outputVersion() != pre);
    }
}

test "rateshape conformance: throttle_leading" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    try runThrottle("throttle_leading.json", .leading);
}

test "rateshape conformance: throttle_trailing" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    try runThrottle("throttle_trailing.json", .trailing);
}

fn runThrottle(name: []const u8, edge: ThrottleEdge) !void {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture(name);
    defer parsed.deinit();
    const fx = parsed.value;

    const window = try jsonAsU64(try jsonFieldRequired(try jsonFieldRequired(fx, "initial"), "window"));
    var cell = ThrottleCell.init(ctx, edge, window);

    for (try steps(fx)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const ty = try jsonAsString(try jsonFieldRequired(op, "type"));
        const now = try jsonAsU64(try jsonFieldRequired(op, "now"));
        const pre = cell.outputVersion();
        const emitted = if (std.mem.eql(u8, ty, "input"))
            cell.input(now, try jsonAsString(try jsonFieldRequired(op, "value")))
        else
            cell.tick(now);
        try expectStep(step, emitted, cell.output(), cell.outputVersion() != pre);
    }
}

test "rateshape conformance: sample_count" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("sample_count.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const n = try jsonAsU64(try jsonFieldRequired(try jsonFieldRequired(fx, "initial"), "n"));
    var cell = SampleCell.init(ctx, .{ .count = n });

    for (try steps(fx)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const pre = cell.outputVersion();
        // sample_count is all `input` ops.
        const emitted = cell.input(try jsonAsString(try jsonFieldRequired(op, "value")));
        try expectStep(step, emitted, cell.output(), cell.outputVersion() != pre);
    }
}

test "rateshape conformance: sample_time" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("sample_time.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const period = try jsonAsU64(try jsonFieldRequired(try jsonFieldRequired(fx, "initial"), "period"));
    var cell = SampleCell.init(ctx, .{ .time = period });

    for (try steps(fx)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const ty = try jsonAsString(try jsonFieldRequired(op, "type"));
        const pre = cell.outputVersion();
        var emitted: ?Value = null;
        if (std.mem.eql(u8, ty, "input")) {
            _ = cell.input(try jsonAsString(try jsonFieldRequired(op, "value")));
        } else {
            emitted = cell.tick(try jsonAsU64(try jsonFieldRequired(op, "now")));
        }
        try expectStep(step, emitted, cell.output(), cell.outputVersion() != pre);
    }
}

test "rateshape conformance: probabilistic_sample" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var parsed = try loadFixture("probabilistic_sample.json");
    defer parsed.deinit();
    const fx = parsed.value;

    const rate = try jsonAsF64(try jsonFieldRequired(try jsonFieldRequired(fx, "initial"), "rate"));
    var cell = ProbabilisticSampleCell(Lcg).init(ctx, rate, Lcg.init(0));

    for (try steps(fx)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const v = try jsonAsString(try jsonFieldRequired(op, "value"));
        const draw = try jsonAsF64(try jsonFieldRequired(op, "draw"));
        const pre = cell.outputVersion();
        const emitted = cell.inputWithDraw(v, draw);
        try expectStep(step, emitted, cell.output(), cell.outputVersion() != pre);
    }
}
