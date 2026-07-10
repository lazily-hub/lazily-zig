const std = @import("std");
const build_options = @import("build_options");
const builtin = @import("builtin");
const Context = @import("context.zig").Context;
const Slot = @import("context.zig").Slot;
const ValueFn = @import("context.zig").ValueFn;
const TrackingFrame = @import("context.zig").TrackingFrame;
const pushTracking = @import("context.zig").pushTracking;
const popTracking = @import("context.zig").popTracking;
const currentSlotFor = @import("context.zig").currentSlotFor;
const valueFnCacheKey = @import("context.zig").valueFnCacheKey;
const slot = @import("slot.zig").slot;
const slotKeyed = @import("slot.zig").slotKeyed;
const initSlotFn = @import("slot.zig").initSlotFn;
const deinitSlotValue = @import("slot.zig").deinitSlotValue;
const DeinitPayloadFn = Slot.DeinitPayloadFn;
const Mode = Slot.Mode;
const Storage = Slot.Storage;

/// An eager derived value backed by a memoized slot with deferred recompute.
///
/// Mirrors lazily-rs `SignalHandle<T>` and lazily-py `Signal[T]`.
/// Unlike a lazy Slot (which recomputes on read), a Signal **eagerly**
/// recomputes the instant any of its dependencies are invalidated — via
/// the `on_invalidate`/`recompute` hooks installed in Phase 1.
///
/// The recompute happens outside the graph mutex (via `Context.drainPendingRecompute`),
/// so user `valueFn`s can re-lock per-op without deadlock. A memo guard
/// (`std.meta.eql`) suppresses downstream cascades when the recomputed
/// value is unchanged.
pub fn Signal(comptime T: type) type {
    return struct {
        ctx: *Context,
        slot: *Slot,
        active: bool,

        const Self = @This();

        pub fn get(self: *const Self) Slot.Result(T) {
            return self.slot.get(T) catch unreachable;
        }

        pub fn dispose(self: *Self) void {
            self.slot.on_invalidate = null;
            self.slot.recompute = null;
            self.active = false;
        }

        pub fn is_active(self: *const Self) bool {
            return self.active;
        }
    };
}

fn on_invalidate_hook(s: *Slot) void {
    if (!s.stale) {
        s.stale = true;
        s.ctx.pending_recompute.append(s.ctx.allocator, s) catch {};
        s.ctx.instrumentation.effect_queue_pushes += 1;
    }
}

fn makeRecomputeFn(comptime T: type) *const fn (*Slot) void {
    return struct {
        fn recompute(s: *Slot) void {
            const ctx = s.ctx;

            // Step 1: Unsubscribe from old parents (under lock)
            ctx.mutex.lock();
            {
                var iter = s.parents.keyIterator();
                while (iter.next()) |ptr| {
                    const parent = ptr.*;
                    _ = parent.change_subscribers.remove(s);
                }
                s.parents.clearRetainingCapacity();
            }
            ctx.mutex.unlock();

            // Step 2: Re-run valueFn with tracking frame (outside lock)
            var frame = TrackingFrame{ .prev = null, .ctx = ctx, .slot = s };
            pushTracking(&frame);
            defer popTracking(&frame);

            const value_fn: *const ValueFn(T) = @ptrCast(@alignCast(s.value_fn_ptr orelse return));
            const new_value = value_fn(ctx) catch return;

            // Step 3: Compare + swap (under lock)
            ctx.mutex.lock();
            var changed = false;
            {
                defer ctx.mutex.unlock();

                const old_storage = s.storage orelse return;

                // Extract old value for comparison
                const old_value: T = switch (comptime Mode(T)) {
                    .literal => switch (comptime Slot.PtrSize(T)) {
                        .slice => old_storage.payload.slice.toSlice(T),
                        .one, .many, .c => @as(T, @ptrCast(@alignCast(old_storage.payload.single_ptr))),
                    },
                    .indirect => @as(*T, @ptrCast(@alignCast(old_storage.payload.single_ptr))).*,
                };

                if (std.meta.eql(old_value, new_value)) return; // memo guard

                changed = true;

                // Deinit old payload value
                if (s.deinitPayload) |deinit_fn| {
                    deinit_fn(s); // reads s.storage (old)
                }

                // Free old allocation for indirect mode — but NOT inline storage
                // (`#lzinline`): `single_ptr` points into `s.inline_buf`, which
                // was never heap-allocated.
                if (s.mode == .indirect and !s.storage_inline) {
                    if (s.free) |free_fn| {
                        free_fn(ctx.allocator, old_storage.payload.single_ptr);
                    }
                }

                // Store new value. Mirror initKeyed: inline small indirect
                // values in the slot itself, heap-box everything else.
                if (comptime Slot.inlineEligible(T)) {
                    const inline_ptr: *T = @ptrCast(@alignCast(&s.inline_buf));
                    inline_ptr.* = new_value;
                    s.storage_inline = true;
                    s.storage = Storage.init(.{ .single_ptr = @ptrCast(inline_ptr) });
                } else {
                    const stored = Storage.toStoredType(T, ctx, new_value) catch return;
                    s.storage = Storage.init(switch (comptime Mode(T)) {
                        .literal => switch (comptime Slot.PtrSize(T)) {
                            .slice => Slot.Storage.Payload{ .slice = Slot.SliceStorage.init(T, stored) },
                            .one, .many, .c => Slot.Storage.Payload{ .single_ptr = @ptrCast(@constCast(stored)) },
                        },
                        .indirect => Slot.Storage.Payload{ .single_ptr = @ptrCast(stored) },
                    });
                }
            }

            // Step 4: Cascade if changed (outside lock)
            if (changed) {
                ctx.drainPendingRecompute();
                s.emitChange();
            }
        }
    }.recompute;
}

pub fn signal(
    comptime T: type,
    ctx: *Context,
    comptime valueFn: *const ValueFn(T),
    comptime deinitPayload: ?DeinitPayloadFn,
) !*Signal(T) {
    // Create the backing slot (establishes initial dependency edges + memo cache)
    _ = try slot(T, ctx, valueFn, deinitPayload);

    // Get the slot pointer from cache
    const slot_ptr = ctx.getSlot(valueFn) orelse return error.SlotNotFound;

    // Install eager-Signal hooks
    slot_ptr.on_invalidate = &on_invalidate_hook;
    slot_ptr.recompute = makeRecomputeFn(T);

    const self = try ctx.allocator.create(Signal(T));
    self.* = .{
        .ctx = ctx,
        .slot = slot_ptr,
        .active = true,
    };
    return self;
}

const SignalTestState = struct {
    var counter: u32 = 0;
};

const getSourceU32 = struct {
    fn call(_: *Context) anyerror!u32 {
        return 0;
    }
}.call;

const CellMod = @import("cell.zig");

test "lazily/signal: eager recompute on dependency change" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    SignalTestState.counter = 0;
    const source = try CellMod.cell(u32, ctx, getSourceU32, null);

    const getDerived = struct {
        fn call(c: *Context) anyerror!u32 {
            SignalTestState.counter += 1;
            const src = try CellMod.cell(u32, c, getSourceU32, null);
            return src.get() * 10;
        }
    }.call;
    const sig = try signal(u32, ctx, getDerived, null);
    defer ctx.allocator.destroy(sig);

    try std.testing.expectEqual(@as(u32, 0), sig.get().*);
    try std.testing.expectEqual(@as(u32, 1), SignalTestState.counter);

    source.set(5);
    try std.testing.expectEqual(@as(u32, 50), sig.get().*);
    try std.testing.expectEqual(@as(u32, 2), SignalTestState.counter);
}

test "lazily/signal: memo guard suppresses equal recompute cascade" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    SignalTestState.counter = 0;
    const source = try CellMod.cell(u32, ctx, getSourceU32, null);

    const getConstant = struct {
        fn call(c: *Context) anyerror!u32 {
            SignalTestState.counter += 1;
            _ = try CellMod.cell(u32, c, getSourceU32, null);
            return 42;
        }
    }.call;
    const sig = try signal(u32, ctx, getConstant, null);
    defer ctx.allocator.destroy(sig);

    try std.testing.expectEqual(@as(u32, 42), sig.get().*);
    try std.testing.expectEqual(@as(u32, 1), SignalTestState.counter);

    source.set(99);
    try std.testing.expectEqual(@as(u32, 42), sig.get().*);
    try std.testing.expectEqual(@as(u32, 2), SignalTestState.counter);
}

test "lazily/signal: dispose reverts to lazy semantics" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    SignalTestState.counter = 0;
    const source = try CellMod.cell(u32, ctx, getSourceU32, null);

    const getDerived = struct {
        fn call(c: *Context) anyerror!u32 {
            SignalTestState.counter += 1;
            const src = try CellMod.cell(u32, c, getSourceU32, null);
            return src.get() + 1;
        }
    }.call;
    const sig = try signal(u32, ctx, getDerived, null);
    defer ctx.allocator.destroy(sig);

    try std.testing.expectEqual(@as(u32, 1), sig.get().*);
    try std.testing.expectEqual(@as(u32, 1), SignalTestState.counter);

    sig.dispose();
    try std.testing.expect(!sig.is_active());

    source.set(20);
    try std.testing.expectEqual(@as(u32, 1), SignalTestState.counter);
}
