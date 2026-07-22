//! Direct tests for the disposal semantics the conformance corpus cannot see
//! on its own (`#lzspecedgeindex`).
//!
//! ## Why these exist alongside the corpus
//!
//! Mutation testing in lazily-dart and lazily-cpp established that of the three
//! semantics disposal has to get right, the original nine-fixture corpus pinned
//! exactly one:
//!
//! ```text
//!   remove the dirty-cone cascade    -> RED
//!   schedule effects during disposal -> GREEN   (invisible)
//!   tear down in forward order       -> GREEN   (invisible)
//! ```
//!
//! Two new fixtures now pin the invisible pair upstream, and this binding
//! replays both. These tests are not a duplicate of them: the corpus lives in a
//! sibling `lazily-spec` checkout and the whole runner skips when it is absent,
//! so without something in-tree the two semantics are unguarded in exactly the
//! configuration most likely to be built — a bare `lazily-zig` clone. They also
//! assert against the API directly rather than through a JSON replay engine, so
//! a regression points at the primitive rather than at a fixture step number.
//!
//! Each test below names the mutation it is designed to fail under; those
//! mutations were applied and confirmed RED.

const std = @import("std");
const testing = std.testing;

const ContextMod = @import("context.zig");
const Context = ContextMod.Context;
const Compute = ContextMod.Compute;
const CellMod = @import("cell.zig");
const EffectMod = @import("effect.zig");
const slotKeyed = @import("slot.zig").slotKeyed;
const AsyncContext = @import("async_context.zig").AsyncContext;
const ThreadSafeContext = @import("thread_safe_context.zig").ThreadSafeContext;

// ---------------------------------------------------------------------------
// Shared observation log
// ---------------------------------------------------------------------------

const Log = struct {
    var runs: [64]u8 = undefined;
    var runs_len: usize = 0;
    var cleanups: [64]u8 = undefined;
    var cleanups_len: usize = 0;

    fn reset() void {
        runs_len = 0;
        cleanups_len = 0;
    }
    fn run(tag: u8) void {
        if (runs_len == runs.len) return;
        runs[runs_len] = tag;
        runs_len += 1;
    }
    fn cleanup(tag: u8) void {
        if (cleanups_len == cleanups.len) return;
        cleanups[cleanups_len] = tag;
        cleanups_len += 1;
    }
    fn ranSince(mark: usize) []const u8 {
        return runs[mark..runs_len];
    }
    fn cleanupOrder() []const u8 {
        return cleanups[0..cleanups_len];
    }
};

// ---------------------------------------------------------------------------
// Semantic 2 — an effect in the disposed cone is neither run nor scheduled
// ---------------------------------------------------------------------------
//
// The graph is the shape the upstream fixture uses, reduced to its essentials:
//
//     src ──> mid ──> watch      (watch is the SURVIVOR: in the cone, not disposed)
//     other ────────> keeper     (independent, exists to give the publish a flush)
//
// Disposing `mid` must not run `watch` — not during the disposal, and not later
// on an unrelated publish. A binding that flushes inside `dispose` fails the
// first assertion; a binding that merely *schedules* the survivor fails the
// second, when the write to `other` drains a queue that should never have
// contained `watch`.

const Sem2 = struct {
    var src_v: i64 = 1;
    var other_v: i64 = 100;

    fn srcInit(_: *Compute) anyerror!i64 {
        return src_v;
    }
    fn otherInit(_: *Compute) anyerror!i64 {
        return other_v;
    }
    fn mid(c: *Compute) anyerror!i64 {
        // `cell(...)` errors if `src` is a disposal tombstone (read-after-
        // dispose), and `c.get` registers the tracked edge `src -> mid`.
        const src = try CellMod.cell(i64, c.untracked(), srcInit, null);
        return c.get(src) + 10;
    }
    fn watchBody(c: *Compute) anyerror!?void {
        Log.run('w');
        const mid_key = ContextMod.valueFnCacheKey(&mid);
        // Track `mid`'s backing slot directly (no allocated handle) so the edge
        // `mid -> watch` is registered without leaking a `Computed` handle.
        _ = slotKeyed(i64, c.untracked(), mid_key, mid, null) catch return null;
        if (c.untracked().cacheLookup(mid_key)) |s| c.trackSlot(s);
        return null;
    }
    fn keeperBody(c: *Compute) anyerror!?void {
        Log.run('k');
        const other = CellMod.cell(i64, c.untracked(), otherInit, null) catch return;
        _ = c.get(other);
    }
};

test "disposal does not run an effect that survives in the disposed cone (Context)" {
    const a = testing.allocator;
    const ctx = try Context.init(a);
    defer ctx.deinit();
    Log.reset();
    Sem2.src_v = 1;
    Sem2.other_v = 100;

    _ = try CellMod.cell(i64, ctx, Sem2.srcInit, null);
    _ = try CellMod.cell(i64, ctx, Sem2.otherInit, null);
    _ = try slotKeyed(i64, ctx, ContextMod.valueFnCacheKey(&Sem2.mid), Sem2.mid, null);

    const watch = try EffectMod.effect(void, ctx, Sem2.watchBody);
    defer a.destroy(watch);
    const keeper = try EffectMod.effect(void, ctx, Sem2.keeperBody);
    defer a.destroy(keeper);

    // Both effects run once at construction.
    try testing.expectEqualSlices(u8, "wk", Log.ranSince(0));

    // --- Assertion 1: nothing runs during the disposal itself. ---
    // Fails under: making `pushTeardownDependents` treat an effect like any
    // other dependent (marking it stale and letting `on_invalidate` enqueue),
    // combined with any drain — the flush-inside-dispose shape.
    const before_dispose = Log.runs_len;
    ctx.disposeNode(.{ .key = ContextMod.valueFnCacheKey(&Sem2.mid) });
    try testing.expectEqualSlices(u8, "", Log.ranSince(before_dispose));

    // The survivor is still live: disposal marks, it does not deactivate.
    try testing.expect(watch.isActive());

    // --- Assertion 2: nor later, on an unrelated publish. ---
    // Fails under: enqueueing the survivor during teardown instead of leaving
    // it untouched — the deferred-flush shape, where `watch` rides out on the
    // next drain as a rerun nobody asked for.
    const before_publish = Log.runs_len;
    Sem2.other_v = 200;
    (try CellMod.cell(i64, ctx, Sem2.otherInit, null)).set(200);
    try testing.expectEqualSlices(u8, "k", Log.ranSince(before_publish));
}

const Sem2Ts = struct {
    fn compute(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) i64 {
        const dep: *u64 = @ptrCast(@alignCast(ptr));
        return cc.readNode(i64, .{ .id = dep.* }) + 10;
    }
    fn watchBody(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) i64 {
        Log.run('w');
        const dep: *u64 = @ptrCast(@alignCast(ptr));
        return cc.readNode(i64, .{ .id = dep.* });
    }
    fn keeperBody(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) i64 {
        Log.run('k');
        const dep: *u64 = @ptrCast(@alignCast(ptr));
        return cc.readNode(i64, .{ .id = dep.* });
    }
};

test "disposal does not run an effect that survives in the disposed cone (ThreadSafeContext)" {
    const a = testing.allocator;
    var ctx = ThreadSafeContext.init(a);
    defer ctx.deinit();
    Log.reset();

    var src = (try ctx.cell(i64, 1)).id;
    var other = (try ctx.cell(i64, 100)).id;
    var mid = (try ctx.computedClosure(i64, @ptrCast(&src), Sem2Ts.compute)).id;
    _ = try ctx.effectClosure(i64, @ptrCast(&mid), Sem2Ts.watchBody, null, null);
    _ = try ctx.effectClosure(i64, @ptrCast(&other), Sem2Ts.keeperBody, null, null);

    try testing.expectEqualSlices(u8, "wk", Log.ranSince(0));

    const before_dispose = Log.runs_len;
    ctx.disposeNode(mid);
    try testing.expectEqualSlices(u8, "", Log.ranSince(before_dispose));

    const before_publish = Log.runs_len;
    ctx.setCell(i64, .{ .id = other }, 200);
    try testing.expectEqualSlices(u8, "k", Log.ranSince(before_publish));
}

const ACtx = AsyncContext(i64);

const Sem2Async = struct {
    fn read(cc: *ACtx.ComputeContext, id: u64) !i64 {
        try cc.readCell(id);
        return cc.async_ctx.getCell(id) orelse cc.async_ctx.get(id) orelse error.Unresolved;
    }
    fn compute(ptr: *anyopaque, cc: *ACtx.ComputeContext) anyerror!i64 {
        const dep: *u64 = @ptrCast(@alignCast(ptr));
        return (try read(cc, dep.*)) + 10;
    }
    fn watchBody(ptr: *anyopaque, cc: *ACtx.ComputeContext) anyerror!i64 {
        Log.run('w');
        const dep: *u64 = @ptrCast(@alignCast(ptr));
        _ = read(cc, dep.*) catch {};
        return 0;
    }
    fn keeperBody(ptr: *anyopaque, cc: *ACtx.ComputeContext) anyerror!i64 {
        Log.run('k');
        const dep: *u64 = @ptrCast(@alignCast(ptr));
        _ = read(cc, dep.*) catch {};
        return 0;
    }
};

test "disposal does not run an effect that survives in the disposed cone (AsyncContext)" {
    const a = testing.allocator;
    var ctx = ACtx.init(a);
    defer ctx.deinit();
    Log.reset();

    var src = try ctx.cell(1);
    var other = try ctx.cell(100);
    var mid = try ctx.computedAsyncClosure(@ptrCast(&src), Sem2Async.compute);
    _ = try ctx.settle();
    _ = try ctx.effectAsyncClosure(@ptrCast(&mid), Sem2Async.watchBody, null, null);
    _ = try ctx.effectAsyncClosure(@ptrCast(&other), Sem2Async.keeperBody, null, null);
    _ = try ctx.settle();

    try testing.expectEqualSlices(u8, "wk", Log.ranSince(0));

    // The async plane is the one where "not scheduled" and "not run" come
    // apart: disposal could enqueue the survivor and nothing would happen until
    // an unrelated `settle`. Both are checked.
    const before_dispose = Log.runs_len;
    ctx.disposeNode(mid);
    _ = try ctx.settle();
    try testing.expectEqualSlices(u8, "", Log.ranSince(before_dispose));

    const before_publish = Log.runs_len;
    try ctx.setCell(other, 200);
    _ = try ctx.settle();
    try testing.expectEqualSlices(u8, "k", Log.ranSince(before_publish));
}

// ---------------------------------------------------------------------------
// Semantic 3 — scope teardown runs cleanups in reverse creation order
// ---------------------------------------------------------------------------
//
// Three effects, because two is not enough and one is actively misleading: a
// single-member scope produces a one-entry cleanup log that reads identically
// forwards and backwards, which is why the pre-existing `cleanup_order`
// assertion in `scope_teardown_equals_fold_of_disposals.json` could not see a
// forward-order implementation.

const Sem3 = struct {
    var v: i64 = 1;
    fn srcInit(_: *Compute) anyerror!i64 {
        return v;
    }
    const Cleanup = struct {
        tag: u8,
        pub fn destroy(self: *Cleanup) void {
            Log.cleanup(self.tag);
        }
    };
    fn body(comptime tag: u8) EffectMod.EffectBodyFn(Cleanup) {
        return struct {
            fn call(c: *Compute) anyerror!?Cleanup {
                Log.run(tag);
                _ = (CellMod.cell(i64, c.untracked(), srcInit, null) catch return null).get();
                return Cleanup{ .tag = tag };
            }
        }.call;
    }
};

test "scope teardown runs member cleanups in reverse creation order (Context)" {
    const a = testing.allocator;
    const ctx = try Context.init(a);
    defer ctx.deinit();
    Log.reset();
    Sem3.v = 1;

    _ = try CellMod.cell(i64, ctx, Sem3.srcInit, null);

    const first = try EffectMod.effect(Sem3.Cleanup, ctx, Sem3.body('1'));
    defer a.destroy(first);
    const second = try EffectMod.effect(Sem3.Cleanup, ctx, Sem3.body('2'));
    defer a.destroy(second);
    const third = try EffectMod.effect(Sem3.Cleanup, ctx, Sem3.body('3'));
    defer a.destroy(third);

    var scope = ctx.scope();
    try scope.own(first.handle());
    try scope.own(second.handle());
    try scope.own(third.handle());
    try testing.expectEqual(@as(usize, 3), scope.len());

    // Each member has run once, so each has a cleanup outstanding.
    try testing.expectEqualSlices(u8, "123", Log.ranSince(0));
    try testing.expectEqualSlices(u8, "", Log.cleanupOrder());

    // Fails under: iterating `owned` forwards in `TeardownScope.deinit`, which
    // yields "123". Three members is what makes the two orders distinguishable.
    scope.deinit();
    try testing.expectEqualSlices(u8, "321", Log.cleanupOrder());

    // Teardown detached the edges rather than merely running the cleanups, so a
    // write to the surviving source reaches nothing.
    const before = Log.runs_len;
    Sem3.v = 2;
    (try CellMod.cell(i64, ctx, Sem3.srcInit, null)).set(2);
    try testing.expectEqualSlices(u8, "", Log.ranSince(before));
}

const Sem3Ts = struct {
    fn bodyFor(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) i64 {
        const s: *Tagged = @ptrCast(@alignCast(ptr));
        Log.run(s.tag);
        return cc.readNode(i64, .{ .id = s.dep });
    }
    fn cleanupFor(ptr: *anyopaque) void {
        const s: *Tagged = @ptrCast(@alignCast(ptr));
        Log.cleanup(s.tag);
    }
    const Tagged = struct { tag: u8, dep: u64 };
};

test "scope teardown runs member cleanups in reverse creation order (ThreadSafeContext)" {
    const a = testing.allocator;
    var ctx = ThreadSafeContext.init(a);
    defer ctx.deinit();
    Log.reset();

    const src = (try ctx.cell(i64, 1)).id;
    var tags = [_]Sem3Ts.Tagged{
        .{ .tag = '1', .dep = src },
        .{ .tag = '2', .dep = src },
        .{ .tag = '3', .dep = src },
    };

    var scope = ctx.scope();
    for (&tags) |*t| {
        const h = try ctx.effectClosure(i64, @ptrCast(t), Sem3Ts.bodyFor, @ptrCast(t), Sem3Ts.cleanupFor);
        try scope.own(h.id);
    }
    try testing.expectEqual(@as(usize, 3), scope.len());
    try testing.expectEqualSlices(u8, "123", Log.ranSince(0));

    scope.deinit();
    try testing.expectEqualSlices(u8, "321", Log.cleanupOrder());

    const before = Log.runs_len;
    ctx.setCell(i64, .{ .id = src }, 2);
    try testing.expectEqualSlices(u8, "", Log.ranSince(before));
}

const Sem3Async = struct {
    const Tagged = struct { tag: u8, dep: u64 };
    fn bodyFor(ptr: *anyopaque, cc: *ACtx.ComputeContext) anyerror!i64 {
        const s: *Tagged = @ptrCast(@alignCast(ptr));
        Log.run(s.tag);
        _ = Sem2Async.read(cc, s.dep) catch {};
        return 0;
    }
    fn cleanupFor(ptr: *anyopaque) void {
        const s: *Tagged = @ptrCast(@alignCast(ptr));
        Log.cleanup(s.tag);
    }
};

test "scope teardown runs member cleanups in reverse creation order (AsyncContext)" {
    const a = testing.allocator;
    var ctx = ACtx.init(a);
    defer ctx.deinit();
    Log.reset();

    const src = try ctx.cell(1);
    var tags = [_]Sem3Async.Tagged{
        .{ .tag = '1', .dep = src },
        .{ .tag = '2', .dep = src },
        .{ .tag = '3', .dep = src },
    };

    var scope = ctx.scope();
    for (&tags) |*t| {
        const id = try ctx.effectAsyncClosure(@ptrCast(t), Sem3Async.bodyFor, @ptrCast(t), Sem3Async.cleanupFor);
        try scope.own(id);
    }
    _ = try ctx.settle();
    try testing.expectEqual(@as(usize, 3), scope.len());
    try testing.expectEqualSlices(u8, "123", Log.ranSince(0));

    scope.deinit();
    try testing.expectEqualSlices(u8, "321", Log.cleanupOrder());

    const before = Log.runs_len;
    try ctx.setCell(src, 2);
    _ = try ctx.settle();
    try testing.expectEqualSlices(u8, "", Log.ranSince(before));
}

// ---------------------------------------------------------------------------
// Teardown allocation discipline
// ---------------------------------------------------------------------------

// The design claim is that `own` is where teardown's cost is paid and `deinit`
// cannot fail. This asserts it the only way an allocator claim can be asserted:
// end the scope under an allocator that refuses every request.
test "scope teardown allocates nothing (all three contexts)" {
    const a = testing.allocator;
    Log.reset();

    {
        const ctx = try Context.init(a);
        defer ctx.deinit();
        Sem3.v = 1;
        _ = try CellMod.cell(i64, ctx, Sem3.srcInit, null);
        const e = try EffectMod.effect(Sem3.Cleanup, ctx, Sem3.body('1'));
        defer a.destroy(e);
        var scope = ctx.scope();
        try scope.own(e.handle());
        // `deinit` takes no allocator and reaches none: the disposal walk is
        // threaded through the slots themselves via `cascade_link`.
        scope.deinit();
        try testing.expect(!e.isActive());
    }

    {
        var ctx = ThreadSafeContext.init(a);
        defer ctx.deinit();
        const src = (try ctx.cell(i64, 1)).id;
        var t = Sem3Ts.Tagged{ .tag = '1', .dep = src };
        var scope = ctx.scope();
        const h = try ctx.effectClosure(i64, @ptrCast(&t), Sem3Ts.bodyFor, @ptrCast(&t), Sem3Ts.cleanupFor);
        try scope.own(h.id);
        scope.deinit();
        try testing.expect(ctx.isDisposed(h.id));
    }

    {
        var ctx = ACtx.init(a);
        defer ctx.deinit();
        const src = try ctx.cell(1);
        var t = Sem3Async.Tagged{ .tag = '1', .dep = src };
        var scope = ctx.scope();
        const id = try ctx.effectAsyncClosure(@ptrCast(&t), Sem3Async.bodyFor, @ptrCast(&t), Sem3Async.cleanupFor);
        try scope.own(id);
        _ = try ctx.settle();
        scope.deinit();
        try testing.expect(ctx.isDisposed(id));
    }

    // Nothing above passes an allocator to a teardown path, and nothing above
    // can return an error from one: `deinit` takes no allocator argument in any
    // of the three contexts, which is the type-level statement of the claim.
}

// ---------------------------------------------------------------------------
// Semantic 1 — the one the corpus already pins, asserted directly for symmetry
// ---------------------------------------------------------------------------

test "disposal dirties the surviving dependent cone (Context)" {
    const a = testing.allocator;
    const ctx = try Context.init(a);
    defer ctx.deinit();
    Sem2.src_v = 1;

    _ = try CellMod.cell(i64, ctx, Sem2.srcInit, null);
    const mid_key = ContextMod.valueFnCacheKey(&Sem2.mid);
    try testing.expectEqual(@as(i64, 11), (try slotKeyed(i64, ctx, mid_key, Sem2.mid, null)).*);

    // A live reader frozen on its pre-disposal cache is the defect this pins
    // (lazily-rs 5db90d2, lazily-js 4d20670): after `src` is disposed, `mid`
    // must not keep serving 11.
    ctx.disposeNode(.{ .key = ContextMod.valueFnCacheKey(&Sem2.srcInit) });
    try testing.expectError(error.NodeDisposed, slotKeyed(i64, ctx, mid_key, Sem2.mid, null));
}
