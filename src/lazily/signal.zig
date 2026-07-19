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
            naiveDisposeScan(self.slot);
            self.slot.on_invalidate = null;
            self.slot.recompute = null;
            self.active = false;
        }

        pub fn is_active(self: *const Self) bool {
            return self.active;
        }
    };
}

/// AUDIT ONLY (`#lzspecedgeindex`, `build_options.naive_pending_scan`).
///
/// Reinstates the defect the rest of the family shipped: dedupe the pending
/// queue by scanning it instead of by the O(1) `stale` flag. During a wide
/// publish the queue holds every already-enqueued sibling, so this is O(W^2)
/// per publish. Compiles to nothing in shipped builds.
pub var naive_scan_sink: usize = 0;

pub inline fn naiveEnqueueScan(s: *Slot) void {
    if (comptime !build_options.naive_pending_scan) return;
    var hits: usize = 0;
    for (s.ctx.pending_recompute.items) |q| {
        if (q == s) hits += 1;
    }
    // Observable so the scan cannot be elided; the enqueue decision itself is
    // still made by the real (`stale`-flag) logic so semantics are unchanged.
    @atomicStore(usize, &naive_scan_sink, naive_scan_sink +% hits, .monotonic);
}

/// AUDIT ONLY (`#lzspecedgeindex`, `build_options.naive_pending_scan`).
///
/// Reinstates lazily-kt's `disposeEffect` shape: scan the pending collection for
/// an id that cannot be there, over the *retained backing array* rather than the
/// live length. kt's deque was empty at teardown and its `indexOf` still walked
/// the whole never-shrinking array (the wraparound branch fires when
/// `head >= tail`, which empty satisfies), so "the collection is empty, so the
/// scan is free" did not hold. `clearRetainingCapacity`/pop-drain leave the same
/// retained capacity here, so the emulation walks `allocatedSlice()`.
pub inline fn naiveDisposeScan(s: *Slot) void {
    const form = comptime build_options.naive_dispose_scan;
    if (comptime std.mem.eql(u8, form, "none")) return;
    const region = if (comptime std.mem.eql(u8, form, "capacity"))
        s.ctx.pending_recompute.allocatedSlice()
    else
        s.ctx.pending_recompute.items;
    var hits: usize = 0;
    for (region) |q| {
        if (q == s) hits += 1;
    }
    @atomicStore(usize, &naive_scan_sink, naive_scan_sink +% hits, .monotonic);
}

fn on_invalidate_hook(s: *Slot) void {
    naiveEnqueueScan(s);
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

/// Runtime-keyed `signal`, mirroring `slotKeyed` vs `slot`. `signal` keys the
/// backing slot by its comptime `valueFn` pointer, so a single body can only
/// ever back one Signal. This variant takes the cache key explicitly, so N
/// distinct eager nodes can share one body — required to vary fan-out width
/// with node count held fixed (`#lzspecedgeindex`, src/benches/pending_audit.zig).
/// Hooks are the same `on_invalidate_hook` / `makeRecomputeFn` `signal` installs.
pub fn signalKeyed(
    comptime T: type,
    ctx: *Context,
    cache_key: usize,
    valueFn: *const ValueFn(T),
    deinitPayload: ?DeinitPayloadFn,
) !*Signal(T) {
    _ = try slotKeyed(T, ctx, cache_key, valueFn, deinitPayload);

    const slot_ptr = ctx.cacheLookup(cache_key) orelse return error.SlotNotFound;
    slot_ptr.on_invalidate = &on_invalidate_hook;
    slot_ptr.recompute = makeRecomputeFn(T);

    const self = try ctx.allocator.create(Signal(T));
    self.* = .{ .ctx = ctx, .slot = slot_ptr, .active = true };
    return self;
}

const KeyedTestState = struct {
    var source_value: i64 = 0;
};

fn keyedSourceFn(_: *Context) anyerror!i64 {
    return KeyedTestState.source_value;
}

fn keyedDerivedFn(ctx: *Context) anyerror!i64 {
    const p = try slotKeyed(i64, ctx, 100, keyedSourceFn, null);
    return p.* * 2;
}

test "lazily/signal: signalKeyed gives distinct eager nodes from one body" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    KeyedTestState.source_value = 1;
    _ = try slotKeyed(i64, ctx, 100, keyedSourceFn, null);

    // Two Signals over the SAME body fn — impossible with `signal`, which keys
    // the backing slot by the body pointer.
    const a = try signalKeyed(i64, ctx, 201, keyedDerivedFn, null);
    defer ctx.allocator.destroy(a);
    const b = try signalKeyed(i64, ctx, 202, keyedDerivedFn, null);
    defer ctx.allocator.destroy(b);

    try std.testing.expect(a.slot != b.slot);
    try std.testing.expectEqual(@as(i64, 2), a.get().*);
    try std.testing.expectEqual(@as(i64, 2), b.get().*);

    // Both are on the eager path: the hooks `signal` installs are installed here.
    try std.testing.expect(a.slot.on_invalidate != null);
    try std.testing.expect(a.slot.recompute != null);

    // A publish reaches both, eagerly (no read in between).
    KeyedTestState.source_value = 5;
    const src = ctx.cacheLookup(100).?;
    const src_ptr = try src.getPtr(i64);
    src_ptr.* = 5;
    src.emitChange();

    try std.testing.expectEqual(@as(i64, 10), a.get().*);
    try std.testing.expectEqual(@as(i64, 10), b.get().*);

    a.dispose();
    try std.testing.expect(!a.is_active());
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
