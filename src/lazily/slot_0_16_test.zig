const std = @import("std");
const build_options = @import("build_options");
const Context = @import("context.zig").Context;
const deinitSlotValue = @import("slot.zig").deinitSlotValue;
const initSlotFn = @import("slot.zig").initSlotFn;
const ValueFn = @import("context.zig").ValueFn;

test "0.16:lazily/slot.Slot: with ThreadPool Future" {
    if (!build_options.thread_safe) return error.SkipZigTest;

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

    const getValue = struct {
        fn getValue(_ctx: *Context) !i32 {
            const io = try slotIo(_ctx);
            try io.sleep(std.Io.Duration.fromMilliseconds(5), .awake);
            return 42;
        }
    }.getValue;

    const FutureI32 = std.Io.Future(@typeInfo(
        @typeInfo(
            @TypeOf(getValue),
        ).@"fn".return_type.?,
    ).error_union.error_set!i32);

    const getFuture = struct {
        fn getFuture(_ctx: *Context) !FutureI32 {
            const io = try slotIo(_ctx);
            return io.async(getValue, .{_ctx});
        }
    }.getFuture;

    const slotFuture = initSlotFn(
        FutureI32,
        getFuture,
        null,
    );

    const actual_fut = try slotFuture(ctx);

    // "Await" the result using the 0.16 wait() API
    const result = try actual_fut.await((try slotIo(ctx)).*);
    try std.testing.expectEqual(@as(i32, 42), result);
}

test {
    std.testing.refAllDecls(@This());
}
