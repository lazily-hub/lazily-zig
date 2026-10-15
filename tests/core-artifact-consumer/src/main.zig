const std = @import("std");
const lazily = @import("lazily");

const ConsumerSchema = struct { label: []const u8 };

const State = struct {
    var value: i32 = 1;
    var source: *lazily.Source(i32) = undefined;
    var runs: usize = 0;

    fn sourceValue(_: *lazily.Context) anyerror!i32 {
        return value;
    }

    fn computedValue(c: *lazily.Compute) anyerror!i32 {
        return c.get(source) * 2;
    }

    fn effectBody(c: *lazily.Compute) anyerror!void {
        if (c.get(computed).* < 2) return error.InvalidComputedValue;
        runs += 1;
    }

    var computed: *lazily.Computed(i32) = undefined;

    fn writeBatch(_: *lazily.Context) void {
        value = 2;
        source.set(value);
        value = 3;
        source.set(value);
    }
};

const Typed = struct {
    fn initial(_: *lazily.Context) anyerror!ConsumerSchema {
        return .{ .label = "typed" };
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const ctx = try lazily.Context.init(allocator);
    defer ctx.deinit();

    State.value = 1;
    State.runs = 0;
    State.source = try lazily.source(i32, ctx, State.sourceValue, null);
    State.computed = try lazily.computed(i32, ctx, State.computedValue, null);
    defer allocator.destroy(State.computed);
    const effect = try lazily.effectNoCleanupC(ctx, State.effectBody);
    defer allocator.destroy(effect);
    var scope = ctx.scope();
    try scope.own(effect.handle());

    ctx.batch(State.writeBatch);
    if (State.computed.get().* != 6 or State.runs != 2) return error.BatchDidNotCoalesce;
    scope.deinit();
    State.value = 4;
    State.source.set(State.value);
    if (State.runs != 2) return error.ClosedScopeObservedUpdate;

    const typed = try lazily.source(ConsumerSchema, ctx, Typed.initial, null);
    if (!std.mem.eql(u8, typed.get().label, "typed")) return error.TypedValueLost;
    std.debug.print("lazily-zig artifact consumer: OK\n", .{});
}
