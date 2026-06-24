const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Context = @import("context.zig").Context;
const currentSlotFor = @import("context.zig").currentSlotFor;
const Owned = @import("context.zig").Owned;
const OwnedString = @import("context.zig").OwnedString;
const Slot = @import("context.zig").Slot;
const String = @import("context.zig").String;
const subscriberKey = @import("context.zig").subscriberKey;
const SubscriberKey = @import("context.zig").SubscriberKey;
const ValueFn = @import("context.zig").ValueFn;
const valueFnCacheKey = @import("context.zig").valueFnCacheKey;
const deinitSlotValue = @import("slot.zig").deinitSlotValue;
const slot = @import("slot.zig").slot;
const slotKeyed = @import("slot.zig").slotKeyed;
const initSlotFn = @import("slot.zig").initSlotFn;
const DeinitPayloadFn = Slot.DeinitPayloadFn;
const slotEventLog = @import("test.zig").slotEventLog;
const expectEventLog = @import("test.zig").expectEventLog;

pub fn DeinitCellValueFn(comptime T: type) type {
    return *const fn (*Cell(T)) void;
}
pub fn ChangeCallback(comptime T: type) type {
    return *const fn (*Cell(T)) void;
}

/// A mutable container to be stored as a slot via the cell function
pub fn Cell(comptime T: type) type {
    return struct {
        ctx: *Context,
        slot: *Slot,
        value: T,
        // TODO: Add before_change_subscribers
        change_subscribers: std.AutoHashMap(SubscriberKey, void),
        deinitCellValue: ?DeinitCellValueFn(T),

        pub const MissingCurrentSlotError = error{MissingCurrentSlot};

        pub fn init(
            ctx: *Context,
            comptime valueFn: *const ValueFn(T),
            comptime deinitCellValue: ?DeinitCellValueFn(T),
        ) !*@This() {
            const getCell = struct {
                fn call(_ctx: *Context) anyerror!Cell(T) {
                    const initial_value = try valueFn(_ctx);
                    const maybe_cell_slot = currentSlotFor(_ctx);
                    if (maybe_cell_slot) |cell_slot| {
                        return Cell(T){
                            .ctx = _ctx,
                            .slot = cell_slot,
                            .value = initial_value,
                            .change_subscribers = std.AutoHashMap(
                                SubscriberKey,
                                void,
                            ).init(_ctx.allocator),
                            .deinitCellValue = deinitCellValue,
                        };
                    } else return error.MissingCurrentSlot;
                }
            }.call;
            const self = try slotKeyed(
                Cell(T),
                ctx,
                valueFnCacheKey(valueFn),
                getCell,
                deinitSlotValue(Cell(T), struct {
                    fn deinitValue(
                        _ctx: *Context,
                        _getCell: *const ValueFn(Cell(T)),
                        _cell: Cell(T),
                    ) void {
                        _ = _ctx;
                        _ = _getCell;
                        var mutable_cell = _cell;
                        mutable_cell.deinit();
                    }
                }.deinitValue),
            );
            return self;
        }

        pub fn deinit(self: *@This()) void {
            if (self.deinitCellValue) |deinit_fn| {
                std.debug.print("Cell.deinit#1, deinit_fn={}\n", .{deinit_fn});
                deinit_fn(self);
            }
            self.change_subscribers.deinit();
        }

        pub fn get(self: *const @This()) T {
            return self.value;
        }

        pub fn set(self: *@This(), new_value: T) void {
            self.ctx.mutex.lock();

            // Only emit change if the value actually changed.
            if (std.meta.eql(self.value, new_value)) {
                self.ctx.mutex.unlock();
                return;
            }

            self.value = new_value;
            self.slot.emitChangeUnlocked();

            // Callbacks may call into the context so unlock here.
            self.ctx.mutex.unlock();

            var iter = self.change_subscribers.iterator();
            while (iter.next()) |entry| {
                const subscriber_key = entry.key_ptr.*;
                const cb: ChangeCallback(T) = @ptrFromInt(subscriber_key.cb_ptr);
                cb(self);
            }

            self.ctx.drainPendingRecompute();
        }

        pub fn subscribe(self: *@This(), cb: ChangeCallback(T)) !bool {
            self.ctx.mutex.lock();
            defer self.ctx.mutex.unlock();

            const subscriber_key = subscriberKey(self.ctx, cb);

            const gop = try self.change_subscribers.getOrPut(subscriber_key);
            if (gop.found_existing) return false; // duplicate, not added

            // Value type is void, nothing to store.
            return true; // newly added
        }

        pub fn unsubscribe(self: *@This(), cb: ChangeCallback(T)) bool {
            self.ctx.mutex.lock();
            defer self.ctx.mutex.unlock();

            // Remove by swap-remove for O(1) erase (order not preserved).
            const subscriber_key = subscriberKey(self.ctx, cb);
            return self.change_subscribers.remove(subscriber_key);
        }
    };
}

test "lazily/cell.Cell: subscribe dedup" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var test_cell = try Cell(i32).init(ctx, struct {
        fn call(_ctx: *Context) !i32 {
            _ = _ctx;
            return 1;
        }
    }.call, null);

    try std.testing.expectEqual(@as(i32, 1), test_cell.get());

    const TestState = struct {
        var called = std.atomic.Value(usize).init(0);
        var value = std.atomic.Value(i32).init(-1);

        fn onChange(_cell: *Cell(i32)) void {
            _ = called.fetchAdd(1, .seq_cst);
            _ = value.swap(_cell.get(), .seq_cst);
        }
    };

    TestState.called.store(0, .seq_cst);

    // First subscription adds, second is rejected as duplicate (same ctx+cb).
    try std.testing.expect(try test_cell.subscribe(TestState.onChange));
    try std.testing.expect(!(try test_cell.subscribe(TestState.onChange)));
    try std.testing.expectEqual(@as(i32, -1), TestState.value.load(.seq_cst));

    test_cell.set(2);
    try std.testing.expectEqual(@as(i32, 2), test_cell.get());
    try std.testing.expectEqual(@as(usize, 1), TestState.called.load(.seq_cst));
    try std.testing.expectEqual(@as(i32, 2), TestState.value.load(.seq_cst));

    // Unsubscribe and ensure no further notifications.
    try std.testing.expect(test_cell.unsubscribe(TestState.onChange));
    test_cell.set(3);
    try std.testing.expectEqual(@as(usize, 1), TestState.called.load(.seq_cst));
    try std.testing.expectEqual(@as(i32, 2), TestState.value.load(.seq_cst));
}

/// Init a slot that stores the `Cell(T)` with the initial value defined by `valueFn`.
/// `deinit` is called during `Cell.deinit`.
/// `valueFn` and `deinit` must be `comptime` because `cell()` generates a trampoline function
/// (Zig 0.15 has no runtime closures).
/// If you need a runtime `valueFn` or `deinit`, you can create a `slot` that returns a `Cell(T)`.
pub fn cell(
    comptime T: type,
    ctx: *Context,
    comptime valueFn: *const ValueFn(T),
    comptime deinitFn: ?DeinitCellValueFn(T),
) !*Cell(T) {
    if (ctx.getSlot(valueFn)) |cell_slot| {
        return cell_slot.get(Cell(T));
    }
    const _cell = try Cell(T).init(
        ctx,
        valueFn,
        deinitFn,
    );
    return _cell;
}

test "lazily/cell.cell: returns Cell(T) with initial value and caches computation" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const State = struct {
        var calls = std.atomic.Value(usize).init(0);

        fn getNumber(_: *Context) anyerror!i32 {
            _ = calls.fetchAdd(1, .seq_cst);
            return 123;
        }
    };

    State.calls.store(0, .seq_cst);

    const c1 = try cell(i32, ctx, State.getNumber, null);
    try std.testing.expectEqual(@as(i32, 123), c1.get());
    try std.testing.expectEqual(@as(usize, 1), State.calls.load(.seq_cst));

    const c2 = try cell(i32, ctx, State.getNumber, null);
    try std.testing.expectEqual(@as(i32, 123), c2.get());
    // The slot should compute the value once per Context for the same getter.
    try std.testing.expectEqual(@as(usize, 1), State.calls.load(.seq_cst));
}

pub fn CellFn(comptime T: type) type {
    return fn (*Context) anyerror!*Cell(T);
}

pub fn initCellFn(
    comptime T: type,
    comptime valueFn: ValueFn(T),
    comptime deinitCellValue: ?DeinitCellValueFn(T),
) *const CellFn(T) {
    return struct {
        fn call(ctx: *Context) anyerror!*Cell(T) {
            return cell(T, ctx, valueFn, deinitCellValue);
        }
    }.call;
}

test "lazily/cell.cellFn: get/set + invalidate cache" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const hello = comptime initCellFn(
        String,
        struct {
            fn call(_ctx: *Context) anyerror!String {
                try (try slotEventLog(_ctx)).append("hello|");
                return "Hello";
            }
        }.call,
        null,
    );

    const getName = struct {
        fn call(_ctx: *Context) !String {
            try (try slotEventLog(_ctx)).append("name|");
            return "World";
        }
    }.call;

    const name = comptime initCellFn(
        String,
        getName,
        null,
    );

    const getGreeting = struct {
        fn call(_ctx: *Context) !OwnedString {
            try (try slotEventLog(_ctx)).append("greeting|");

            const greeting = std.fmt.allocPrint(
                _ctx.allocator,
                "{s} {s}!",
                .{ (try hello(_ctx)).get(), (try name(_ctx)).get() },
            ) catch unreachable;
            return OwnedString.managed(greeting);
        }
    }.call;
    const greeting = comptime initSlotFn(
        OwnedString,
        getGreeting,
        deinitSlotValue(OwnedString, null),
    );

    const response = comptime initCellFn(String, struct {
        fn call(_ctx: *Context) !String {
            try (try slotEventLog(_ctx)).append("response|");
            return "How are you?";
        }
    }.call, null);

    const getGreetingAndResponse = struct {
        fn call(_ctx: *Context) !OwnedString {
            try (try slotEventLog(_ctx)).append("greetingAndResponse|");
            return OwnedString.managed(
                std.fmt.allocPrint(
                    _ctx.allocator,
                    "{s} {s}",
                    .{ (try greeting(_ctx)).value, (try response(_ctx)).get() },
                ) catch unreachable,
            );
        }
    }.call;
    const greetingAndResponse = comptime initSlotFn(
        OwnedString,
        getGreetingAndResponse,
        deinitSlotValue(OwnedString, null),
    );

    try std.testing.expectEqual(null, ctx.getSlot(getName));
    try std.testing.expectEqual(null, ctx.getSlot(getGreeting));
    try std.testing.expectEqual(null, ctx.getSlot(getGreetingAndResponse));
    try std.testing.expectEqual(0, (try slotEventLog(ctx)).items.len);

    try std.testing.expectEqualStrings(
        "Hello World!",
        (try greeting(ctx)).value,
    );
    try std.testing.expect(ctx.getSlot(getName) != null);
    try std.testing.expect(ctx.getSlot(getGreeting) != null);
    try std.testing.expectEqual(null, ctx.getSlot(getGreetingAndResponse));

    try expectEventLog(ctx, "greeting|hello|name|");
    try std.testing.expectEqualStrings(
        "Hello World! How are you?",
        (try greetingAndResponse(ctx)).value,
    );
    try std.testing.expect(ctx.getSlot(getName) != null);
    try std.testing.expect(ctx.getSlot(getGreeting) != null);
    try std.testing.expect(ctx.getSlot(getGreetingAndResponse) != null);

    try expectEventLog(ctx, "greeting|hello|name|greetingAndResponse|response|");
    try std.testing.expectEqualStrings(
        "Hello World! How are you?",
        (try greetingAndResponse(ctx)).value,
    );

    try expectEventLog(ctx, "greeting|hello|name|greetingAndResponse|response|");
    {
        var name_cell = try name(ctx);
        name_cell.set("You");
        try std.testing.expectEqualStrings("You", name_cell.get());
        try std.testing.expectEqualStrings("You", (try name(ctx)).get());
    }
    try std.testing.expect(ctx.getSlot(getName) != null);
    try std.testing.expectEqual(null, ctx.getSlot(getGreeting));
    try std.testing.expectEqual(null, ctx.getSlot(getGreetingAndResponse));
    try expectEventLog(ctx, "greeting|hello|name|greetingAndResponse|response|");

    var greeting_slot = try getGreeting(ctx);
    defer greeting_slot.deinit(ctx);
    try std.testing.expectEqualStrings("Hello You!", greeting_slot.value);

    try std.testing.expectEqualStrings("Hello You!", (try greeting(ctx)).value);

    try std.testing.expectEqualStrings(
        "Hello You! How are you?",
        (try greetingAndResponse(ctx)).value,
    );
    try std.testing.expect(ctx.getSlot(getName) != null);
    try std.testing.expect(ctx.getSlot(getGreeting) != null);
    try std.testing.expect(ctx.getSlot(getGreetingAndResponse) != null);
    try expectEventLog(ctx, "greeting|hello|name|greetingAndResponse|response|greeting|greeting|greetingAndResponse|");
}

test "lazily/cell.thread_safe Cell updates" {
    if (!build_options.thread_safe) return error.SkipZigTest;
    if (builtin.zig_version.minor >= 16) return error.SkipZigTest; // ThreadSafeAllocator removed in 0.16

    var ts_allocator = std.heap.ThreadSafeAllocator{
        .child_allocator = std.testing.allocator,
    };
    const allocator = ts_allocator.allocator();

    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const counter = try Cell(i32).init(ctx, struct {
        fn call(_: *Context) anyerror!i32 {
            return 0;
        }
    }.call, null);

    const num_threads = 4;
    const increments_per_thread = 1000;
    var threads: [num_threads]std.Thread = undefined;

    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(_cell: *Cell(i32), count: usize) void {
                for (0..count) |_| {
                    // This tests the thread-safety of cell.set()
                    // and the resulting graph invalidation.
                    const current = _cell.get();
                    _cell.set(current + 1);
                }
            }
        }.run, .{ counter, increments_per_thread });
    }

    for (threads) |t| t.join();

    // Since updates are non-atomic relative to each other (get then set),
    // the final value isn't guaranteed to be num_threads * increments,
    // but the test confirms that the internal HashMaps and Mutexes
    // didn't deadlock or crash during high-frequency contention.
    _ = counter.get();
}
