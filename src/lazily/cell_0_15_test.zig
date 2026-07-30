const std = @import("std");
const build_options = @import("build_options");
const Context = @import("context.zig").Context;
const deinitSlotValue = @import("slot.zig").deinitSlotValue;
const initSlotFn = @import("slot.zig").initSlotFn;
const ValueFn = @import("context.zig").ValueFn;
const slot = @import("slot.zig").slot;

test "0.15:lazily/cell.cell: thread_safe slot contention" {
    if (!build_options.thread_safe) return error.SkipZigTest;

    // We must use a thread-safe allocator for multithreaded tests.
    var ts_allocator = std.heap.ThreadSafeAllocator{
        .child_allocator = std.testing.allocator,
    };
    const allocator = ts_allocator.allocator();

    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const SharedState = struct {
        // Track how many times the actual computation ran
        computations: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        fn compute(_: *Context) anyerror!i32 {
            // Simulate some work
            std.Thread.sleep(10 * std.time.ns_per_ms);
            // This is a global pointer in the test, so we can access it
            // via a capture or a static.
            return 42;
        }
    };

    var state = SharedState{};

    // We define the valueFn here to increment the counter
    const valueFn = struct {
        var static_state: *SharedState = undefined;
        fn call(_: *Context) anyerror!i32 {
            _ = static_state.computations.fetchAdd(1, .seq_cst);
            std.Thread.sleep(50 * std.time.ns_per_ms);
            return 42;
        }
    };
    valueFn.static_state = &state;

    const num_threads = 8;
    var threads: [num_threads]std.Thread = undefined;

    // Spawn multiple threads all trying to get the same slot at once.
    //
    // `slot`'s `valueFn` parameter is `comptime`, so the racing closure has to be
    // named at comptime inside `run`. Threading it in as a runtime
    // `*const fn (*Context) anyerror!i32` argument cannot work — a thread
    // argument is never comptime-known — and that is why this module had never
    // compiled: it only builds on 0.15, so no green job ever analyzed it.
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, struct {
            fn run(c: *Context) void {
                const val = slot(i32, c, valueFn.call, null) catch unreachable;
                std.testing.expectEqual(@as(i32, 42), val.*) catch @panic("Value mismatch");
            }
        }.run, .{ctx});
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
