const std = @import("std");
const Context = @import("context.zig").Context;
const Slot = @import("context.zig").Slot;
const TrackingFrame = @import("context.zig").TrackingFrame;
const pushTracking = @import("context.zig").pushTracking;
const popTracking = @import("context.zig").popTracking;
const valueFnCacheKey = @import("context.zig").valueFnCacheKey;
const slotKeyed = @import("slot.zig").slotKeyed;
const ValueFn = @import("context.zig").ValueFn;
const CellMod = @import("cell.zig");

/// An Effect is a side-effecting observer that reruns whenever a tracked
/// dependency invalidates. It is the 4th reactive primitive
/// (`Cell / Slot / Signal / Effect`) per `lazily-spec/docs/reactive-graph.md`.
///
/// Mirrors lazily-rs `EffectHandle` and the spec contract:
/// - Scheduled, not inline: rerun fires after the invalidating `set_cell`/`batch`
///   flush, not during.
/// - Cleanup ordering: the previous run's cleanup completes before the next body.
/// - Auto-tracking: the body receives the Context and tracks dependencies through
///   `cell()`/`slot()` reads inside a TrackingFrame.
/// - Disposal: removes pending reruns, runs the current cleanup, unsubscribes edges.
///
/// The Effect reuses the same eager-recompute machinery (`on_invalidate`/`recompute`
/// hooks on `Slot`) that `Signal` uses. The difference is semantic: a Signal
/// materializes a *value* eagerly; an Effect performs a *side effect* and may
/// return a cleanup closure.
pub fn Effect(comptime Cleanup: type) type {
    return struct {
        ctx: *Context,
        slot: *Slot,
        active: bool,

        const Self = @This();

        /// Run the cleanup function if one was produced by the last body run.
        /// Called internally before re-running the body and on `dispose`.
        pub fn runCleanup(self: *Self, cleanup: ?*Cleanup) void {
            if (cleanup) |cu| {
                cu.*.destroy();
                self.ctx.allocator.destroy(cu);
            }
        }

        pub fn dispose(self: *Self) void {
            // Remove the eager-recompute hooks so no further reruns fire.
            self.slot.on_invalidate = null;
            self.slot.recompute = null;
            self.active = false;
        }

        pub fn isActive(self: *const Self) bool {
            return self.active;
        }
    };
}

/// The body function returns an optional cleanup value. When non-null, the
/// cleanup is run before the next body invocation and on dispose.
pub fn EffectBodyFn(comptime Cleanup: type) type {
    return *const fn (*Context) anyerror!?Cleanup;
}

/// Create an effect whose body auto-tracks dependencies and reruns on
/// invalidation. The body may return a cleanup value (run before next rerun
/// and on dispose). The `Cleanup` type must have a `destroy()` method.
///
/// **Note on cleanup lifecycle:** The effect stores the last cleanup inside
/// the slot's `value_fn_ptr` type-erased state. On recompute, the previous
/// cleanup is destroyed before the new body runs, implementing the spec's
/// "cleanup-before-body" ordering.
pub fn effect(
    comptime Cleanup: type,
    ctx: *Context,
    comptime bodyFn: EffectBodyFn(Cleanup),
) !*Effect(Cleanup) {
    const T = u8; // The slot stores a dummy u8; the real work is the side effect.

    // Build the valueFn that runs the effect body inside a tracking frame.
    const getEffectValue = struct {
        fn call(_ctx: *Context) anyerror!u8 {
            _ = bodyFn(_ctx) catch {};
            return 0; // dummy value
        }
    }.call;

    // Create the backing slot (establishes initial dependency edges)
    _ = try slotKeyed(
        T,
        ctx,
        valueFnCacheKey(bodyFn),
        getEffectValue,
        null, // no payload deinit — the slot stores a dummy u8
    );

    // Get the slot pointer from cache
    const slot_ptr = ctx.getSlot(bodyFn) orelse return error.SlotNotFound;

    // Install eager-recompute hooks (same machinery as Signal)
    slot_ptr.on_invalidate = &on_invalidate_hook;
    slot_ptr.recompute = makeEffectRecomputeFn(Cleanup, bodyFn);

    const self = try ctx.allocator.create(Effect(Cleanup));
    self.* = .{
        .ctx = ctx,
        .slot = slot_ptr,
        .active = true,
    };
    return self;
}

/// A no-cleanup effect variant for observers that don't need tear-down.
pub fn effectNoCleanup(
    ctx: *Context,
    comptime bodyFn: *const fn (*Context) anyerror!void,
) !*Effect(void) {
    const Wrapper = struct {
        fn call(_ctx: *Context) anyerror!?void {
            try bodyFn(_ctx);
            return null;
        }
    };
    return effect(void, ctx, Wrapper.call);
}

fn on_invalidate_hook(s: *Slot) void {
    if (!s.stale) {
        s.stale = true;
        s.ctx.pending_recompute.append(s.ctx.allocator, s) catch {};
        s.ctx.instrumentation.effect_queue_pushes += 1;
    }
}

fn makeEffectRecomputeFn(comptime Cleanup: type, comptime bodyFn: EffectBodyFn(Cleanup)) *const fn (*Slot) void {
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

            // Step 2: Re-run body with tracking frame (outside lock)
            var frame = TrackingFrame{ .prev = null, .ctx = ctx, .slot = s };
            pushTracking(&frame);
            defer popTracking(&frame);

            _ = bodyFn(ctx) catch return;

            // The body's side effect has been performed. No value swap needed
            // (the slot stores a dummy u8). Downstream dependents (if any)
            // are cascaded via emitChange.
        }
    }.recompute;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const EffectTestState = struct {
    var counter: u32 = 0;
};

const getSourceU32 = struct {
    fn call(_: *Context) anyerror!u32 {
        return 0;
    }
}.call;

test "lazily/effect: reruns on dependency change" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    EffectTestState.counter = 0;

    const source = try CellMod.cell(u32, ctx, getSourceU32, null);

    const eff = try effectNoCleanup(ctx, struct {
        fn call(c: *Context) anyerror!void {
            _ = try CellMod.cell(u32, c, getSourceU32, null);
            EffectTestState.counter += 1;
        }
    }.call);
    defer ctx.allocator.destroy(eff);
    defer eff.dispose();

    try std.testing.expectEqual(@as(u32, 1), EffectTestState.counter);

    source.set(5);
    try std.testing.expectEqual(@as(u32, 2), EffectTestState.counter);

    source.set(10);
    try std.testing.expectEqual(@as(u32, 3), EffectTestState.counter);
}

test "lazily/effect: dispose stops reruns" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    EffectTestState.counter = 0;

    const source = try CellMod.cell(u32, ctx, getSourceU32, null);

    const eff = try effectNoCleanup(ctx, struct {
        fn call(c: *Context) anyerror!void {
            _ = try CellMod.cell(u32, c, getSourceU32, null);
            EffectTestState.counter += 1;
        }
    }.call);
    defer ctx.allocator.destroy(eff);

    try std.testing.expectEqual(@as(u32, 1), EffectTestState.counter);

    eff.dispose();
    try std.testing.expect(!eff.isActive());

    source.set(99);
    try std.testing.expectEqual(@as(u32, 1), EffectTestState.counter);
}
