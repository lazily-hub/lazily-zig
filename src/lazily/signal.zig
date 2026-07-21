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
        // Same ordering fix as `effect.zig`'s hook, and for a stronger reason
        // than "laziness covers it".
        //
        // Laziness does cover a *graph* reader: another slot pulling this
        // Signal's value goes through `slotKeyed`, which sees `stale`, orphans
        // the slot and recomputes. But `Signal.get` does not take that path —
        // it calls `self.slot.get(T)` directly, and `Slot.get` reads `storage`
        // without consulting `stale`. The handle read is served entirely by the
        // eager recompute, so a dropped enqueue that also latched `stale`
        // wedged the node (the `!s.stale` guard never fires again) and
        // `Signal.get` returned the pre-invalidation value for the life of the
        // Context. Worse, the first graph read orphans the wedged slot and
        // installs a fresh one, while the `Signal` handle keeps pointing at the
        // orphan — so the handle and the graph then disagree forever.
        //
        // `signal()` therefore reserves this queue entry at construction
        // (`Context.reserveEagerRecomputeSlot`), so the append below runs into
        // spare capacity and cannot fail. The reservation — not the `catch` —
        // is the fix, because this site has no recovery available: by the time
        // the hook runs, `emitChangeUnlocked` has already dropped the edge that
        // would deliver the next invalidation, and only the recompute being
        // cancelled would have rebuilt it.
        //
        // The `catch` covers only the residual case (a caller that discarded
        // the reservation). It enqueues before latching `stale` and does not
        // latch on failure, so no "already queued" flag is left behind with no
        // queue entry to clear it.
        s.ctx.pending_recompute.append(s.ctx.allocator, s) catch {
            s.ctx.eager_enqueue_drops += 1;
            return;
        };
        s.stale = true;
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

                // Deinit old payload value.
                //
                // This is the *second* `deinitPayload` call site — a mid-session
                // value change, not teardown (`#lzspecedgeindex`). A destructor
                // that destroys its own slot here would free `old_storage` and
                // return `s` to the arena while this frame still holds both, so
                // latch the same re-entrancy guard `destroySingleNodeUnlocked`
                // uses. `destroyUnlocked` then records the request instead of
                // acting on it, and it is honored below once `s` is idle.
                if (s.deinitPayload) |deinit_fn| {
                    s.destroying = true;
                    deinit_fn(s); // reads s.storage (old)
                    s.destroying = false;
                }

                // Free old allocation for indirect mode — but NOT inline storage
                // (`#lzinline`): `single_ptr` points into `s.inline_buf`, which
                // was never heap-allocated.
                if (s.mode == .indirect and !s.storage_inline) {
                    if (s.free) |free_fn| {
                        free_fn(ctx.allocator, old_storage.payload.single_ptr);
                    }
                }

                // Deferred teardown requested from inside the destructor above.
                // The old box is already freed, so drop `storage` before handing
                // off — otherwise `destroySingleNodeUnlocked` frees it again and
                // re-runs the payload destructor. No new value is published: the
                // node is gone, so there is nothing to emit a change for.
                if (s.destroy_requested) {
                    s.destroy_requested = false;
                    s.storage = null;
                    s.destroyUnlocked(true);
                    return;
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

/// Install the eager-recompute puller on `slot_ptr` — the mechanism behind a
/// **driven** `FormulaCell` (`formula().drive()`), which retires the standalone
/// `Signal`. Reserves the `pending_recompute` entry up front (so the hook can
/// never fail to enqueue) and installs the same `on_invalidate` / `recompute`
/// hooks `signal()` uses. The coalescing is provided by the batch-gated flush
/// in `Cell.set` + `drainPendingRecompute`, so N writes in a batch materialize
/// the formula once (the `#lzsignaleager` clause-3 property).
pub fn installEagerHooks(comptime T: type, slot_ptr: *Slot) !void {
    try slot_ptr.ctx.reserveEagerRecomputeSlot();
    slot_ptr.on_invalidate = &on_invalidate_hook;
    slot_ptr.recompute = makeRecomputeFn(T);
}

/// Remove the eager-recompute puller installed by `installEagerHooks` — the
/// `undrive` transition. Reverts the node to lazy (recomputed on next read).
pub fn removeEagerHooks(slot_ptr: *Slot) void {
    naiveDisposeScan(slot_ptr);
    slot_ptr.on_invalidate = null;
    slot_ptr.recompute = null;
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

    // Reserve this Signal's `pending_recompute` entry up front so
    // `on_invalidate_hook` never has to allocate. See
    // `Context.reserveEagerRecomputeSlot` — a dropped enqueue leaves
    // `Signal.get` serving the pre-invalidation value permanently, because the
    // cascade has already dropped the edge that would deliver the next one.
    try ctx.reserveEagerRecomputeSlot();

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


// ---------------------------------------------------------------------------
// Destroying a slot that is queued in `pending_recompute` (`#lzspecedgeindex`)
// ---------------------------------------------------------------------------
//
// `Slot.destroy` tears a node down and returns its arena memory to the reuse
// free-list. A Signal/Effect-backed slot destroyed *between* its
// `on_invalidate` enqueue and the next drain used to leave its pointer in
// `pending_recompute`; the drain then popped it and ran `recompute`, which
// iterates the slot's now-deinit'd `parents` edge set. Before the tombstone
// fix the first test below aborts with a general protection exception at
// `signal.zig` `const parent = ptr.*` inside `recompute`, called from
// `drainPendingRecompute` at the batch exit.
//
// The fix does not *remove* the entry — the queue is scan-free (audit 70cf3e5)
// and removal by search would make `destroy` O(pending). Teardown clears the
// `stale` flag in O(1) and the drain discards entries whose flag is clear, so
// the entry survives as a tombstone and dies at pop.

const DestroyWhileQueuedState = struct {
    var source: u32 = 0;
    var runs: usize = 0;
    var victim: ?*Slot = null;
    /// Queue depth sampled inside the batch, right after the victim was
    /// destroyed. The batch exit drains, so it has to be read before then.
    var depth_after_destroy: usize = 0;

    fn sourceFn(_: *Context) anyerror!u32 {
        return source;
    }

    fn derivedFn(c: *Context) anyerror!u32 {
        const src = try CellMod.cell(u32, c, sourceFn, null);
        runs += 1;
        return src.get() + 1;
    }

    fn runBatch(c: *Context) void {
        const src = CellMod.cell(u32, c, sourceFn, null) catch return;
        // Invalidates the Signal's slot -> `on_invalidate_hook` appends it to
        // `pending_recompute`. The drain is deferred to the batch exit.
        src.set(7);
        std.debug.assert(c.pending_recompute.items.len == 1);
        // Explicit teardown while the slot is queued.
        victim.?.destroy(false);
        depth_after_destroy = c.pending_recompute.items.len;
    }
};

test "lazily/signal: destroying a queued slot tombstones its pending entry" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    DestroyWhileQueuedState.source = 0;
    DestroyWhileQueuedState.runs = 0;
    DestroyWhileQueuedState.depth_after_destroy = 0;

    const sig = try signal(u32, ctx, DestroyWhileQueuedState.derivedFn, null);
    defer ctx.allocator.destroy(sig);
    try std.testing.expectEqual(@as(usize, 1), DestroyWhileQueuedState.runs);

    DestroyWhileQueuedState.victim = sig.slot;

    // enqueue -> destroy -> drain, all inside one batch boundary.
    ctx.batch(DestroyWhileQueuedState.runBatch);

    // The entry is left in place by design (O(1) teardown, no scan)...
    try std.testing.expectEqual(@as(usize, 1), DestroyWhileQueuedState.depth_after_destroy);
    // ...and the flag is cleared, so the drain discards it instead of running
    // `recompute` on a torn-down slot. Pre-fix this crashed here.
    try std.testing.expect(!sig.slot.stale);
    try std.testing.expectEqual(@as(usize, 1), DestroyWhileQueuedState.runs);
    // Drain still consumes the whole queue — the tombstone does not linger.
    try std.testing.expectEqual(@as(usize, 0), ctx.pending_recompute.items.len);
}

// A tombstone must also survive arena recycling: `destroy` returns the slot's
// memory to `SlotArena`'s free-list, so the very next materialization can hand
// the same address back out. The stale tombstone pointer then aliases a live,
// unrelated slot. Popping it must not clear that slot's flag or run its body.

const RecycleAfterDestroyState = struct {
    var a_source: u32 = 0;
    var victim_runs: usize = 0;
    var survivor_runs: usize = 0;
    var victim: ?*Slot = null;
    var recycled_same_address = false;

    fn sourceFn(_: *Context) anyerror!u32 {
        return a_source;
    }

    fn victimFn(c: *Context) anyerror!u32 {
        const src = try CellMod.cell(u32, c, sourceFn, null);
        victim_runs += 1;
        return src.get() + 1;
    }

    fn survivorFn(c: *Context) anyerror!u32 {
        const src = try CellMod.cell(u32, c, sourceFn, null);
        survivor_runs += 1;
        return src.get() + 2;
    }

    fn runBatch(c: *Context) void {
        const src = CellMod.cell(u32, c, sourceFn, null) catch return;
        src.set(3);
        victim.?.destroy(false);
        // Recycles the freed arena slot (LIFO inline free-stack) for a brand
        // new eager node, which then enqueues itself under the same address.
        const survivor = signalKeyed(u32, c, 0xDEADBEEF, survivorFn, null) catch return;
        recycled_same_address = (survivor.slot == victim.?);
        c.allocator.destroy(survivor);
        src.set(4);
    }
};

test "lazily/signal: tombstone is safe when the arena recycles the slot" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    RecycleAfterDestroyState.a_source = 0;
    RecycleAfterDestroyState.victim_runs = 0;
    RecycleAfterDestroyState.survivor_runs = 0;
    RecycleAfterDestroyState.recycled_same_address = false;

    const sig = try signal(u32, ctx, RecycleAfterDestroyState.victimFn, null);
    defer ctx.allocator.destroy(sig);
    try std.testing.expectEqual(@as(usize, 1), RecycleAfterDestroyState.victim_runs);
    RecycleAfterDestroyState.victim = sig.slot;

    ctx.batch(RecycleAfterDestroyState.runBatch);

    // The victim never ran again after teardown.
    try std.testing.expectEqual(@as(usize, 1), RecycleAfterDestroyState.victim_runs);
    // The queue drained fully, tombstone included.
    try std.testing.expectEqual(@as(usize, 0), ctx.pending_recompute.items.len);
}

// Reentrancy (`lazily-rs` de6b67b analogue): tearing a node down from *inside*
// a recompute that the drain is currently running. The Zig drain is
// `pop()`-based rather than a retain/iterate under a borrow, and teardown now
// touches only a flag, so the reentrant destroy cannot invalidate an iterator.
// `destroySelf` does share `Context.cascade_scratch` with the invalidation
// cascade, but the pending drain runs outside that worklist, so the
// `wl.items.len == 0` entry assert holds.

const ReentrantDestroyState = struct {
    var source: u32 = 0;
    var neighbor: ?*Slot = null;
    var neighbor_runs: usize = 0;
    var destroyer_runs: usize = 0;
    var did_destroy = false;
    var neighbor_was_queued = false;

    fn sourceFn(_: *Context) anyerror!u32 {
        return source;
    }

    fn neighborFn(c: *Context) anyerror!u32 {
        const src = try CellMod.cell(u32, c, sourceFn, null);
        neighbor_runs += 1;
        return src.get() + 1;
    }

    fn destroyerFn(c: *Context) anyerror!u32 {
        const src = try CellMod.cell(u32, c, sourceFn, null);
        destroyer_runs += 1;
        // Runs from inside `drainPendingRecompute`, while the neighbor is
        // still sitting in the queue below us.
        if (!did_destroy) {
            if (neighbor) |n| {
                did_destroy = true;
                // `stale` is set at enqueue and cleared at pop, so this proves
                // the neighbor's entry is still live in the queue below us —
                // i.e. the test is actually exercising destroy-during-drain
                // and not just destroying an already-drained node.
                neighbor_was_queued = n.stale;
                n.destroy(false);
            }
        }
        return src.get() + 5;
    }

    fn runBatch(c: *Context) void {
        const src = CellMod.cell(u32, c, sourceFn, null) catch return;
        src.set(11);
    }
};

test "lazily/signal: destroying another slot from inside a drain is safe" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    ReentrantDestroyState.source = 0;
    ReentrantDestroyState.neighbor_runs = 0;
    ReentrantDestroyState.destroyer_runs = 0;
    ReentrantDestroyState.did_destroy = false;
    ReentrantDestroyState.neighbor_was_queued = false;

    const victim = try signal(u32, ctx, ReentrantDestroyState.neighborFn, null);
    defer ctx.allocator.destroy(victim);
    const destroyer = try signal(u32, ctx, ReentrantDestroyState.destroyerFn, null);
    defer ctx.allocator.destroy(destroyer);
    ReentrantDestroyState.neighbor = victim.slot;

    const neighbor_runs_before = ReentrantDestroyState.neighbor_runs;

    // Both are queued by the single `set`; the drain pops the destroyer, which
    // tears the still-queued neighbor down mid-drain.
    ctx.batch(ReentrantDestroyState.runBatch);

    try std.testing.expect(ReentrantDestroyState.did_destroy);
    try std.testing.expect(ReentrantDestroyState.neighbor_was_queued);
    // The torn-down neighbor was discarded, not recomputed.
    try std.testing.expectEqual(neighbor_runs_before, ReentrantDestroyState.neighbor_runs);
    try std.testing.expectEqual(@as(usize, 0), ctx.pending_recompute.items.len);
}


// ---------------------------------------------------------------------------
// The OTHER `deinitPayload` call site (`#lzspecedgeindex`)
// ---------------------------------------------------------------------------
//
// `destroySingleNodeUnlocked` is not the only place user payload destructors
// run. `makeRecomputeFn`'s step 3 calls `deinitPayload` on every value change
// where the memo guard fails — a mid-session path with no teardown involved at
// all, and reachable from a plain `Cell.set` rather than an explicit `destroy`.
//
// Pre-fix, a destructor that destroyed its own slot here ran a full, real
// teardown (nothing was in progress to absorb it): the old box was freed and
// `s` was handed back to the arena, and then the recompute frame carried on and
// freed `old_storage` a second time and wrote the new value into a slot that
// had already been recycled. Under `std.testing.allocator` in Debug:
//
//     panic: double free of [addr: 7f3a1f2a0598, len: 32 (0x20) align: 8]
//
// The fix latches `Slot.destroying` around this call site too, so the nested
// destroy is recorded rather than performed, and the teardown is run by this
// frame once `s` is no longer in use.

const RecomputeReentrantDestroyState = struct {
    const Big = struct { words: [4]u64 };
    const cache_key: usize = 0x5164_0001;

    var source: u64 = 0;
    var payload_deinits: usize = 0;

    fn sourceFn(_: *Context) anyerror!u64 {
        return source;
    }

    fn derivedFn(c: *Context) anyerror!Big {
        const src = try CellMod.cell(u64, c, sourceFn, null);
        return .{ .words = .{ src.get(), 0, 0, 0 } };
    }

    fn deinitBig(s: *Slot) void {
        payload_deinits += 1;
        if (payload_deinits > 1) return;
        s.destroy(true);
    }

    fn runBatch(c: *Context) void {
        const src = CellMod.cell(u64, c, sourceFn, null) catch return;
        src.set(99); // invalidate -> enqueue; drain at batch exit -> recompute
    }
};

test "lazily/signal: destroying a slot from its payload destructor during recompute" {
    const S = RecomputeReentrantDestroyState;
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    S.source = 1;
    S.payload_deinits = 0;

    const sig = try signalKeyed(S.Big, ctx, S.cache_key, S.derivedFn, S.deinitBig);
    defer ctx.allocator.destroy(sig);

    ctx.batch(S.runBatch);

    // Destructor ran once, for the old value being replaced.
    try std.testing.expectEqual(@as(usize, 1), S.payload_deinits);
    // The deferred destroy was honored: the slot is gone from the cache and no
    // new value was published in its place.
    try std.testing.expect(ctx.cacheLookup(S.cache_key) == null);
    // Queue fully drained, scratch worklist balanced.
    try std.testing.expectEqual(@as(usize, 0), ctx.pending_recompute.items.len);
    try std.testing.expectEqual(@as(usize, 0), ctx.cascade_scratch.items.len);
}

// ---------------------------------------------------------------------------
// OOM regression: a dropped eager-enqueue makes `Signal.get` serve a stale
// value permanently. Laziness does NOT cover this site.
// ---------------------------------------------------------------------------

const OomSignalState = struct {
    var source_value: u32 = 0;

    fn getSource(_: *Context) anyerror!u32 {
        return source_value;
    }

    fn getDerived(c: *Context) anyerror!u32 {
        const src = try CellMod.cell(u32, c, getSource, null);
        return src.get() * 10;
    }
};

test "lazily/signal: Signal.get must not serve a stale value after an OOM enqueue" {
    // The prior judgement on this hook was that laziness covers a dropped
    // enqueue, because `stale` is set first and a later read recomputes. That
    // holds for a *graph* reader — another slot pulling this value goes through
    // `slotKeyed`, which sees `stale`, orphans the slot and recomputes.
    //
    // It does not hold for the handle. `Signal.get` calls `self.slot.get(T)`
    // directly, and `Slot.get` reads `storage` without ever consulting `stale`.
    // So the handle read is served entirely by the eager recompute, and a
    // dropped enqueue that also latched `stale` wedged the node: the `!s.stale`
    // guard never fired again, and `Signal.get` returned the pre-invalidation
    // value for the life of the Context. Worse, the first graph read then
    // orphans the wedged slot and installs a fresh one while the handle keeps
    // pointing at the orphan, so handle and graph disagree permanently.
    //
    // `signal()` now reserves the queue entry at construction, so the hook
    // cannot fail. This pins that.
    const S = OomSignalState;
    const backing = std.testing.allocator;
    const ctx = try Context.init(backing);
    defer ctx.deinit();

    S.source_value = 0;
    const source = try CellMod.cell(u32, ctx, S.getSource, null);
    const sig = try signal(u32, ctx, S.getDerived, null);
    defer ctx.allocator.destroy(sig);

    try std.testing.expectEqual(@as(u32, 0), sig.get().*);
    try std.testing.expect(ctx.pending_recompute.capacity >= 1);

    // Warm the edge-set capacity so the recompute's re-subscribe needs no
    // allocation either, then starve the allocator completely.
    S.source_value = 1;
    source.set(1);
    try std.testing.expectEqual(@as(u32, 10), sig.get().*);

    var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 0 });
    ctx.allocator = failing.allocator();
    defer ctx.allocator = backing;

    S.source_value = 2;
    source.set(2);

    // The assertion that fails against the old `catch {}`: the handle observes
    // the new value even with no memory available.
    try std.testing.expectEqual(@as(u32, 20), sig.get().*);
    try std.testing.expectEqual(@as(u64, 0), ctx.eager_enqueue_drops);

    // Still attached — a second starved write reaches it too.
    S.source_value = 3;
    source.set(3);
    try std.testing.expectEqual(@as(u32, 30), sig.get().*);
}
