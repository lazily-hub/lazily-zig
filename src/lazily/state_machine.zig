const std = @import("std");
const build_options = @import("build_options");
const Context = @import("context.zig").Context;
// The machine's state is a plain source cell (`#lzcellkernel`).
const Cell = @import("cell.zig").Source;
const cell = @import("cell.zig").source;
const ValueFn = @import("context.zig").ValueFn;

/// A finite state machine backed by a reactive `Cell`.
///
/// Mirrors `StateMachine<S, E>` in lazily-rs and `StateMachine[S, E]` in lazily-py.
/// The state lives in a `Cell(S)` so any Slot that reads the machine's state
/// is automatically invalidated when the machine transitions.
///
/// The transition function is pure: `fn(*const S, E) ?S`.
/// Returning `null` rejects the event (guard); returning a value accepts
/// the event and sets the cell to the new state. A self-transition that
/// returns an equal state is accepted but suppressed by the Cell's
/// `std.meta.eql` guard, so no downstream cascade fires.
///
/// Zig has no closures, so the initial state is passed through a threadlocal
/// during construction. This means one `StateMachine(S, E)` per `Context`
/// per type instantiation (matching the slot cache-by-function design).
pub fn StateMachine(comptime S: type, comptime E: type) type {
    return struct {
        const Self = @This();

        ctx: *Context,
        state_cell: *Cell(S),
        transition: *const fn (*const S, E) ?S,

        threadlocal var _initial: ?S = null;

        fn initialFn(_: *Context) anyerror!S {
            return _initial orelse return error.NoInitialState;
        }

        pub fn init(
            ctx: *Context,
            initial: S,
            transition: *const fn (*const S, E) ?S,
        ) !*Self {
            _initial = initial;
            defer _initial = null;

            const state_cell = try cell(S, ctx, initialFn, null);

            const self = try ctx.allocator.create(Self);
            self.* = .{
                .ctx = ctx,
                .state_cell = state_cell,
                .transition = transition,
            };
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.ctx.allocator.destroy(self);
        }

        pub fn send(self: *Self, event: E) bool {
            const current = self.state_cell.get();
            if (self.transition(&current, event)) |next| {
                self.state_cell.set(next);
                return true;
            }
            return false;
        }

        pub fn state(self: *const Self) S {
            return self.state_cell.get();
        }

        pub fn cellHandle(self: *const Self) *Cell(S) {
            return self.state_cell;
        }
    };
}

test "lazily/state_machine: traffic light transitions" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const Light = enum { Red, Green, Yellow };
    const Tick = enum { Advance };

    const transition = struct {
        fn call(s: *const Light, e: Tick) ?Light {
            if (e != .Advance) return null;
            return switch (s.*) {
                .Red => .Green,
                .Green => .Yellow,
                .Yellow => .Red,
            };
        }
    }.call;

    const m = try StateMachine(Light, Tick).init(ctx, .Red, transition);
    defer m.deinit();

    try std.testing.expectEqual(Light.Red, m.state());

    try std.testing.expect(m.send(.Advance));
    try std.testing.expectEqual(Light.Green, m.state());

    try std.testing.expect(m.send(.Advance));
    try std.testing.expectEqual(Light.Yellow, m.state());

    try std.testing.expect(m.send(.Advance));
    try std.testing.expectEqual(Light.Red, m.state());
}

test "lazily/state_machine: guard rejection" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const Door = enum { Open, Closed };
    const Action = enum { open, close };

    const transition = struct {
        fn call(s: *const Door, a: Action) ?Door {
            return switch (s.*) {
                .Open => switch (a) {
                    .close => .Closed,
                    .open => null,
                },
                .Closed => switch (a) {
                    .open => .Open,
                    .close => null,
                },
            };
        }
    }.call;

    const m = try StateMachine(Door, Action).init(ctx, .Open, transition);
    defer m.deinit();

    try std.testing.expect(!m.send(.open));
    try std.testing.expectEqual(Door.Open, m.state());

    try std.testing.expect(m.send(.close));
    try std.testing.expectEqual(Door.Closed, m.state());

    try std.testing.expect(!m.send(.close));
    try std.testing.expectEqual(Door.Closed, m.state());
}

test "lazily/state_machine: self-transition suppressed by eql guard" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const Identity = struct {
        fn call(s: *const i32, _: u8) ?i32 {
            return s.*;
        }
    }.call;

    const m = try StateMachine(i32, u8).init(ctx, 42, Identity);
    defer m.deinit();

    _ = m.send(0);
    try std.testing.expectEqual(@as(i32, 42), m.state());
}

test "lazily/state_machine: multiple transitions cycle back" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const Light = enum { Red, Green, Yellow };
    const Tick = enum { Advance };

    const transition = struct {
        fn call(s: *const Light, e: Tick) ?Light {
            if (e != .Advance) return null;
            return switch (s.*) {
                .Red => .Green,
                .Green => .Yellow,
                .Yellow => .Red,
            };
        }
    }.call;

    const m = try StateMachine(Light, Tick).init(ctx, .Red, transition);
    defer m.deinit();

    for (0..6) |_| {
        _ = m.send(.Advance);
    }
    try std.testing.expectEqual(Light.Red, m.state());
}
