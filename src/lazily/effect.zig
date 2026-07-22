const std = @import("std");
const Context = @import("context.zig").Context;
const Slot = @import("context.zig").Slot;
const Compute = @import("context.zig").Compute;
const normalizeCompute = @import("context.zig").normalizeCompute;
const valueFnCacheKey = @import("context.zig").valueFnCacheKey;
const slotKeyed = @import("slot.zig").slotKeyed;
const ValueFn = @import("context.zig").ValueFn;
const CellMod = @import("cell.zig");
const SignalMod = @import("signal.zig");

/// An Effect is a side-effecting observer that reruns whenever a tracked
/// dependency invalidates. It is the 4th reactive primitive
/// (`Cell / Slot / Signal / Effect`) per `lazily-spec/docs/reactive-graph.md`.
///
/// Mirrors lazily-rs `Effect` (the bare handle, sibling to `Source`/`Computed`)
/// and the spec contract:
/// - Scheduled, not inline: rerun fires after the invalidating `set_cell`/`batch`
///   flush, not during.
/// - Cleanup ordering: the previous run's cleanup completes before the next body.
/// - Tracking: the body receives a value-threaded `*Compute` view and tracks
///   dependencies through `Compute.get` reads (no ambient frame).
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
            // AUDIT ONLY (#lzspecedgeindex): kt's `disposeEffect` scanned here.
            SignalMod.naiveDisposeScan(self.slot);
            // Remove the eager-recompute hooks so no further reruns fire.
            self.slot.on_invalidate = null;
            self.slot.recompute = null;
            self.active = false;
        }

        pub fn isActive(self: *const Self) bool {
            return self.active and !self.slot.disposed;
        }

        pub fn handle(self: *const Self) Context.NodeHandle {
            return .{ .key = self.slot.cache_key.? };
        }

        /// Tear this effect out of the *graph* (`#lzspecedgeindex`).
        ///
        /// `dispose` keeps its older, narrower meaning — deactivate the eager
        /// puller and leave the node in place — so graph teardown takes the new
        /// name, exactly as it does for `Signal` in lazily-go. This runs the
        /// pending cleanup, detaches both edge directions, and tombstones the
        /// node so a later read of it is an error.
        pub fn disposeNode(self: *Self) void {
            self.active = false;
            self.ctx.disposeNode(self.handle());
        }
    };
}

/// The body function returns an optional cleanup value. When non-null, the
/// cleanup is run before the next body invocation and on dispose.
pub fn EffectBodyFn(comptime Cleanup: type) type {
    return *const fn (*Compute) anyerror!?Cleanup;
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
    comptime bodyFn: anytype,
) !*Effect(Cleanup) {
    const nb = comptime normalizeCompute(?Cleanup, bodyFn);
    return effectKeyed(Cleanup, ctx, valueFnCacheKey(nb), nb);
}

/// Store the cleanup a body run just produced on the slot, replacing any
/// previous one. Held on the slot rather than on the `Effect(Cleanup)` handle
/// because the recompute and teardown paths only ever have the `*Slot`.
///
/// A zero-sized `Cleanup` (the `effectNoCleanup` case) is never boxed: there is
/// nothing to run and nothing to free.
fn storeCleanup(comptime Cleanup: type, s: *Slot, produced: ?Cleanup) void {
    if (comptime @sizeOf(Cleanup) == 0) return;
    const value = produced orelse return;
    const boxed = s.ctx.allocator.create(Cleanup) catch {
        // Same class as the eager-enqueue drop: the body already ran, so this
        // cannot be un-done, and there is no caller to report to. Count it.
        s.ctx.effect_body_errors += 1;
        return;
    };
    boxed.* = value;
    s.cleanup_state = @ptrCast(boxed);
    s.run_cleanup = makeRunCleanup(Cleanup);
}

fn runStoredCleanup(s: *Slot) void {
    if (s.run_cleanup) |run| run(s);
}

fn makeRunCleanup(comptime Cleanup: type) *const fn (*Slot) void {
    return struct {
        fn run(s: *Slot) void {
            const state = s.cleanup_state orelse return;
            const boxed: *Cleanup = @ptrCast(@alignCast(state));
            // Clear first: `destroy()` is user code and may re-enter teardown.
            s.cleanup_state = null;
            boxed.destroy();
            s.ctx.allocator.destroy(boxed);
        }
    }.run;
}

/// `effect` with a caller-supplied cache key, mirroring `signalKeyed`.
pub fn effectKeyed(
    comptime Cleanup: type,
    ctx: *Context,
    cache_key: usize,
    comptime bodyFn: anytype,
) !*Effect(Cleanup) {
    const T = u8; // The slot stores a dummy u8; the real work is the side effect.
    const nb = comptime normalizeCompute(?Cleanup, bodyFn);

    // Build the valueFn that runs the effect body value-threaded over the
    // effect's own slot (`c.node`); no ambient frame (`#lzcellkernel`).
    const getEffectValue = struct {
        fn call(c: *Compute) anyerror!u8 {
            // A failing effect body genuinely has nowhere to report: the body
            // runs from an invalidation cascade, not from a caller, so the
            // swallow is intentional and stays. But it was undiagnosable —
            // an Effect whose body errored every run was indistinguishable
            // from one that ran clean. Count it so the failure is at least
            // observable, without changing behaviour or any signature.
            const produced = nb(c) catch blk: {
                c.untracked().effect_body_errors += 1;
                break :blk null;
            };
            storeCleanup(Cleanup, c.node, produced);
            return 0; // dummy value
        }
    }.call;

    // Create the backing slot (establishes initial dependency edges)
    _ = try slotKeyed(
        T,
        ctx,
        cache_key,
        getEffectValue,
        null, // no payload deinit — the slot stores a dummy u8
    );

    // Get the slot pointer from cache
    const slot_ptr = ctx.cacheLookup(cache_key) orelse return error.SlotNotFound;

    // Reserve this Effect's `pending_recompute` entry up front so
    // `on_invalidate_hook` never has to allocate. See
    // `Context.reserveEagerRecomputeSlot` — a dropped enqueue detaches the
    // Effect from the graph permanently, so the OOM is surfaced here (where
    // the caller can see it) rather than swallowed in the cascade.
    try ctx.reserveEagerRecomputeSlot();

    // Install eager-recompute hooks (same machinery as Signal)
    slot_ptr.on_invalidate = &on_invalidate_hook;
    slot_ptr.recompute = makeEffectRecomputeFn(Cleanup, nb);
    // Re-arm a node whose key was disposed and then re-created. `slotKeyed`
    // refuses to resurrect a tombstone, so reaching here means this is a fresh
    // node on a fresh key; the assignment is defensive and free.
    slot_ptr.disposed = false;

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
    comptime bodyFn: anytype,
) !*Effect(void) {
    // Normalize to a `*Compute` void body (auto-wraps a legacy `fn(*Context)`).
    const nb = comptime normalizeCompute(void, bodyFn);
    const Wrapper = struct {
        fn call(c: *Compute) anyerror!?void {
            try nb(c);
            return null;
        }
    };
    return effect(void, ctx, Wrapper.call);
}

// -- Value-threaded (fortified) effect (`#lzcellkernel`) --------------------
//
// The effect body is ALWAYS value-threaded now — `effect`/`effectKeyed` take a
// `*Compute` body (or auto-wrap a legacy `fn(*Context)` body that forms no
// edges). `effectC`/`effectNoCleanupC` are thin aliases kept for call-site
// compatibility.

/// A value-threaded effect body: receives the fortified `*Compute` view and may
/// return a cleanup value.
pub fn ComputeBodyFn(comptime Cleanup: type) type {
    return *const fn (*Compute) anyerror!?Cleanup;
}

/// Alias for `effect` — the primary constructor already takes a `*Compute` body.
pub fn effectC(
    comptime Cleanup: type,
    ctx: *Context,
    comptime bodyFn: ComputeBodyFn(Cleanup),
) !*Effect(Cleanup) {
    return effect(Cleanup, ctx, bodyFn);
}

/// Alias for `effectNoCleanup` — value-threaded body with no teardown.
pub fn effectNoCleanupC(
    ctx: *Context,
    comptime bodyFn: *const fn (*Compute) anyerror!void,
) !*Effect(void) {
    return effectNoCleanup(ctx, bodyFn);
}

fn on_invalidate_hook(s: *Slot) void {
    // AUDIT ONLY (#lzspecedgeindex): rs/cpp `run_effect` scanned here.
    SignalMod.naiveEnqueueScan(s);
    if (!s.stale) {
        // This append cannot fail in practice: `effect()` reserved a
        // `pending_recompute` entry for this node at construction
        // (`Context.reserveEagerRecomputeSlot`), so there is spare capacity and
        // `append` never reaches the allocator. That reservation is the actual
        // fix, and it lives at construction because this site cannot recover:
        // `emitChangeUnlocked` removes the dependent from `parents` and clears
        // `change_subscribers` BEFORE calling this hook, so once the enqueue is
        // dropped the edge that would deliver the next invalidation is gone and
        // only the cancelled recompute would have rebuilt it. The Effect
        // detaches from the graph for the life of the Context — a side effect
        // that silently never happens again, with no reader to pull it back the
        // way a Signal's value can be pulled.
        //
        // Two degradations were rejected. The whole-context
        // `cascadeFallbackMarkAllStaleUnlocked` used for the cascade worklist
        // is no help: over-invalidating the graph puts nothing into
        // `pending_recompute`, which is the resource that ran out. Running the
        // body inline is worse than the bug — this hook fires while
        // `emitChangeUnlocked` iterates `change_subscribers`, and the body
        // re-enters the graph and mutates those very edge sets.
        //
        // The `catch` below therefore covers only the residual case (a caller
        // that discarded the reservation). It enqueues BEFORE latching `stale`
        // and does not latch on failure: `stale` is this queue's O(1) dedupe key
        // (`#lzspecedgeindex`), and leaving it set with no queue entry marks the
        // node "already queued" forever, so nothing could revive it even if the
        // edge were restored by other means. That does not make the drop
        // recoverable — it makes it observable and flag-clean.
        s.ctx.pending_recompute.append(s.ctx.allocator, s) catch {
            s.ctx.eager_enqueue_drops += 1;
            return;
        };
        s.stale = true;
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

            // Step 2: Re-run body with a per-recompute `Compute` view minted
            // over `s` (value-threaded node; no ambient frame). Tracked reads
            // via `Compute.get` re-register dependency edges against `s`.
            var view = Compute.init(ctx, s);

            // The rerun path's copy of the same intentional swallow (see
            // `effect()`); nothing follows but comments, so the `return` is
            // equivalent to `catch {}`. Counted for the same reason.
            //
            // Worth knowing: Step 1 above has already dropped every parent
            // edge, and the body is what re-registers them. A body that errors
            // BEFORE its first dependency read therefore detaches the Effect
            // permanently. The counter is what makes that diagnosable.
            // Cleanup-before-body (`reactive-graph.md`): the previous run's
            // cleanup completes before the next body starts, and it runs outside
            // the graph lock because it is user code.
            runStoredCleanup(s);

            const produced = bodyFn(&view) catch blk: {
                ctx.effect_body_errors += 1;
                break :blk null;
            };
            storeCleanup(Cleanup, s, produced);

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
        fn call(c: *Compute) anyerror!void {
            _ = c.get(try CellMod.cell(u32, c.untracked(), getSourceU32, null));
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
        fn call(c: *Compute) anyerror!void {
            _ = c.get(try CellMod.cell(u32, c.untracked(), getSourceU32, null));
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

// ---------------------------------------------------------------------------
// OOM regression (`#lzspecedgeindex`): a dropped eager-enqueue detaches the
// Effect from the graph permanently, so the enqueue must not be able to fail.
// ---------------------------------------------------------------------------

const OomEffectState = struct {
    var runs: u32 = 0;

    fn getSource(_: *Context) anyerror!u32 {
        return 0;
    }

    fn body(c: *Compute) anyerror!void {
        _ = c.get(try CellMod.cell(u32, c.untracked(), getSource, null));
        runs += 1;
    }
};

test "lazily/effect: an eager rerun must survive an exhausted allocator" {
    // Regression guard for the `pending_recompute.append(...) catch {}` that
    // used to sit in `on_invalidate_hook`.
    //
    // The hook is called from `emitChangeUnlocked`, which removes the
    // dependent from `parents` and then clears `change_subscribers` — so by the
    // time the hook runs, the `cell -> effect` edge is ALREADY gone, and the
    // only thing that rebuilds it is the recompute the hook is trying to
    // schedule. Dropping that enqueue therefore does not cost one rerun; it
    // detaches the Effect from the graph for the life of the Context, and no
    // reader exists to pull the side effect back the way one would pull a
    // Signal's value.
    //
    // The fix is `Context.reserveEagerRecomputeSlot`, called by `effect()`:
    // the queue entry is paid for at construction, where OOM is reportable, so
    // the hook's `append` runs into spare capacity and cannot fail.
    const S = OomEffectState;
    const backing = std.testing.allocator;
    const ctx = try Context.init(backing);
    defer ctx.deinit();

    S.runs = 0;
    const source = try CellMod.cell(u32, ctx, S.getSource, null);

    const eff = try effectNoCleanup(ctx, S.body);
    defer ctx.allocator.destroy(eff);
    defer eff.dispose();

    try std.testing.expectEqual(@as(u32, 1), S.runs);
    // The reservation exists before any invalidation has occurred.
    try std.testing.expect(ctx.pending_recompute.capacity >= 1);

    // Warm the edge-set capacity so the recompute's re-subscribe is also
    // allocation-free, then starve the allocator completely.
    source.set(1);
    try std.testing.expectEqual(@as(u32, 2), S.runs);

    var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 0 });
    ctx.allocator = failing.allocator();
    defer ctx.allocator = backing;

    // The assertion that fails against the old `catch {}`: with no memory
    // available at all, the Effect still reruns.
    source.set(2);
    try std.testing.expectEqual(@as(u32, 3), S.runs);
    try std.testing.expectEqual(@as(u64, 0), ctx.eager_enqueue_drops);

    // And it is still attached — a second write under the same starvation
    // reaches it, which a detached Effect could never do.
    source.set(3);
    try std.testing.expectEqual(@as(u32, 4), S.runs);
}

test "lazily/effect: a genuinely undeliverable enqueue is counted, not latched" {
    // The residual path. `reserveEagerRecomputeSlot` makes the hook's append
    // allocation-free, so reaching the `catch` requires deliberately throwing
    // the reservation away. What is pinned here is that the hook does not
    // latch `stale` on the way out: `stale` is the queue's O(1) dedupe key, and
    // leaving it set with no queue entry would mark the node "already queued"
    // forever, so even restoring the edge by other means could not revive it.
    //
    // This does NOT claim the Effect recovers — the cascade dropped its edge
    // before the hook ran. It claims the failure is observable and leaves no
    // corrupt flag behind.
    const S = OomEffectState;
    const backing = std.testing.allocator;
    const ctx = try Context.init(backing);
    defer ctx.deinit();

    S.runs = 0;
    const source = try CellMod.cell(u32, ctx, S.getSource, null);

    const eff = try effectNoCleanup(ctx, S.body);
    defer ctx.allocator.destroy(eff);
    defer eff.dispose();

    try std.testing.expectEqual(@as(u32, 1), S.runs);

    // Throw away the reservation, then starve the allocator.
    ctx.pending_recompute.clearAndFree(ctx.allocator);
    try std.testing.expectEqual(@as(usize, 0), ctx.pending_recompute.capacity);

    var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 0 });
    ctx.allocator = failing.allocator();

    source.set(1);

    ctx.allocator = backing;
    try std.testing.expect(failing.has_induced_failure);

    try std.testing.expectEqual(@as(u32, 1), S.runs);
    try std.testing.expectEqual(@as(u64, 1), ctx.eager_enqueue_drops);

    // Not queued implies not stale.
    try std.testing.expect(!eff.slot.stale);
    try std.testing.expectEqual(@as(usize, 0), ctx.pending_recompute.items.len);
}

const FailingBodyState = struct {
    var runs: u64 = 0;

    fn getSource(_: *Context) anyerror!u32 {
        return source;
    }
    var source: u32 = 0;

    fn body(c: *Compute) anyerror!void {
        _ = c.get(try CellMod.cell(u32, c.untracked(), getSource, null));
        runs += 1;
        return error.EffectBodyFailed;
    }
};

test "lazily/effect: a failing effect body is counted rather than invisible" {
    // The swallow at the top of `effect()` is intentional — the body runs from
    // an invalidation cascade, so its error has no caller to reach. What it was
    // NOT allowed to stay is undiagnosable: an Effect erroring on every run
    // looked exactly like one running clean.
    const S = FailingBodyState;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    S.runs = 0;
    S.source = 1;
    const src = try CellMod.cell(u32, ctx, S.getSource, null);

    const eff = try effectNoCleanup(ctx, S.body);
    defer ctx.allocator.destroy(eff);
    defer eff.dispose();

    // The body ran and failed, and the Effect still constructed — behaviour is
    // unchanged. The failure is simply visible now.
    try std.testing.expectEqual(@as(u64, 1), S.runs);
    try std.testing.expectEqual(@as(u64, 1), ctx.effect_body_errors);

    // Every subsequent rerun is counted too, so a persistently broken body
    // shows a climbing count rather than silence.
    //
    // This half of the test is what found the SECOND swallow: the first run
    // goes through `effect()`'s `catch`, the rerun through
    // `makeEffectRecomputeFn`'s separate `catch return`. With only the first
    // one counted this read 1, not 2. Keep both paths covered.
    src.set(2);
    try std.testing.expectEqual(@as(u64, 2), S.runs);
    try std.testing.expectEqual(@as(u64, 2), ctx.effect_body_errors);
}
