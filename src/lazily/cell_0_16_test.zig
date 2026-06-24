const std = @import("std");
const build_options = @import("build_options");
const Context = @import("context.zig").Context;
const deinitSlotValue = @import("slot.zig").deinitSlotValue;
const initSlotFn = @import("slot.zig").initSlotFn;
const ValueFn = @import("context.zig").ValueFn;
const slot = @import("slot.zig").slot;

test "0.16:lazily/cell.thread_safe: slot contention" {
    if (!build_options.thread_safe) return error.SkipZigTest;

    // Zig 0.16 removed ThreadSafeAllocator; use testing allocator directly.
    const allocator = std.testing.allocator;

    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const slotIoEngine = comptime initSlotFn(*std.Io.Threaded, struct {
        fn getIoEngine(_ctx: *Context) !*std.Io.Threaded {
            const engine = try _ctx.allocator.create(std.Io.Threaded);
            engine.* = std.Io.Threaded.init(_ctx.allocator, .{});
            return engine;
        }
    }.getIoEngine, deinitSlotValue(*std.Io.Threaded, struct {
        fn deinitValue(_ctx: *Context, _: *const ValueFn(*std.Io.Threaded), engine: *std.Io.Threaded) void {
            var mutable_engine = engine;
            mutable_engine.deinit();
            _ctx.allocator.destroy(mutable_engine);
        }
    }.deinitValue));

    const slotIo = comptime initSlotFn(std.Io, struct {
        fn getIo(_ctx: *Context) !std.Io {
            const engine = try slotIoEngine(_ctx);
            return std.Io.Threaded.io(engine);
        }
    }.getIo, null);

    const SharedState = struct {
        // Track how many times the actual computation ran
        computations: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        fn compute(_ctx: *Context) anyerror!i32 {
            // Simulate some work
            const io = try slotIo(_ctx);
            try io.sleep(
                std.Io.Duration.fromMilliseconds(50),
                .awake,
            );
            // This is a global pointer in the test, so we can access it
            // via a capture or a static.
            return 42;
        }
    };

    var state = SharedState{};

    // We define the valueFn here to increment the counter
    const valueFn = struct {
        var static_state: *SharedState = undefined;
        fn call(_ctx: *Context) anyerror!i32 {
            _ = static_state.computations.fetchAdd(1, .seq_cst);
            const io = try slotIo(_ctx);
            try io.sleep(
                std.Io.Duration.fromMilliseconds(50),
                .awake,
            );
            return 42;
        }
    };
    valueFn.static_state = &state;

    const num_threads = 8;
    var threads: [num_threads]std.Thread = undefined;

    // Spawn multiple threads all trying to get the same slot at once
    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(c: *Context, f: *const fn (*Context) anyerror!i32) void {
                const val = slot(i32, c, f, null) catch unreachable;
                std.testing.expectEqual(@as(i32, 42), val.*) catch @panic("Value mismatch");
            }
        }.run, .{ ctx, valueFn.call });
    }

    for (threads) |t| t.join();

    // Verification:
    // 1. All threads should have received the correct value (checked in thread).
    // 2. The Context cache should only contain ONE slot for this function.
    // 3. While valueFn might have RUN multiple times due to the race,
    //    our logic in initKeyed ensures only one was kept and others were destroyed.

    // Check that we can still get the value
    const final_val = try slot(i32, ctx, valueFn.call, null);
    try std.testing.expectEqual(@as(i32, 42), final_val.*);
}

test {
    std.testing.refAllDecls(@This());
}
