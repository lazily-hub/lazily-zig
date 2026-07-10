const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const Context = @import("./context.zig").Context;
const currentSlotFor = @import("./context.zig").currentSlotFor;
const popTracking = @import("./context.zig").popTracking;
const pushTracking = @import("./context.zig").pushTracking;
const Slot = @import("./context.zig").Slot;
const String = @import("./context.zig").String;
const TrackingFrame = @import("./context.zig").TrackingFrame;
const ValueFn = @import("./context.zig").ValueFn;
const valueFnCacheKey = @import("./context.zig").valueFnCacheKey;
const DeinitPayloadFn = Slot.DeinitPayloadFn;
const DeinitValueFn = Slot.DeinitValueFn;
const Free = Slot.Free;
const Mode = Slot.Mode;
const Storage = Slot.Storage;
const StorageKind = Slot.StorageKind;
const StoredType = Slot.Result;
const slotEventLog = @import("test.zig").slotEventLog;
const expectEventLog = @import("test.zig").expectEventLog;

pub fn initSlotFn(
    comptime T: type,
    comptime valueFn: *const ValueFn(T),
    comptime deinitPayload: ?DeinitPayloadFn,
) *const fn (*Context) anyerror!Slot.Result(T) {
    return struct {
        fn call(ctx: *Context) !Slot.Result(T) {
            return try slot(T, ctx, valueFn, deinitPayload);
        }
    }.call;
}

/// Accepts a separate value getter function and optional `deinit` function.
/// See `slotFn` for alternative api.
pub fn slot(
    comptime T: type,
    ctx: *Context,
    valueFn: *const ValueFn(T),
    deinitPayload: ?DeinitPayloadFn,
) !Slot.Result(T) {
    return slotKeyed(
        T,
        ctx,
        valueFnCacheKey(valueFn),
        valueFn,
        deinitPayload,
    );
}

pub fn slotKeyed(
    comptime T: type,
    ctx: *Context,
    cache_key: usize,
    valueFn: *const ValueFn(T),
    deinitPayload: ?DeinitPayloadFn,
) !Slot.Result(T) {
    // Fast path: cached read. The lock is scoped with `defer` so it is ALWAYS
    // released — even if `subscribeChangeUnlocked` errors (OutOfMemory from
    // getOrPut). Without `defer`, an error here would leak the reentrant lock
    // (depth not decremented → inner never released → permanent deadlock).
    // The cache-miss path falls through the block (lock released by defer),
    // then calls `initKeyed` which does its own locking.
    {
        ctx.mutex.lock();
        defer ctx.mutex.unlock();

        if (ctx.cache.get(cache_key)) |cached_slot| {
            if (cached_slot.storage != null and !cached_slot.stale) {
                // Fresh cached value — return it.
                const current_slot: ?*Slot = currentSlotFor(ctx);
                if (current_slot) |child_slot| {
                    try cached_slot.subscribeChangeUnlocked(child_slot);
                }
                return cached_slot.get(T);
            }
            // Stale slot in cache — remove + orphan it so initKeyed creates
            // a fresh slot. The orphaned slot is NOT freed (#lzinplace): its
            // storage pointer may be held by a reader on another thread.
            // It's freed at Context.deinit.
            if (cached_slot.stale) {
                _ = ctx.cache.remove(cache_key);
                ctx.orphaned_slots.append(ctx.allocator, cached_slot) catch {};
            }
        }
    }

    // Cache miss — create a free function that knows the type T.
    var new_slot = try Slot.initKeyed(
        T,
        ctx,
        cache_key,
        valueFn,
        deinitPayload,
    );

    return new_slot.get(T);
}

const SlotError = error{MissingStorage};

/// Test helper: assert a slot exists in the cache and is stale.
/// Used after touch/emitChange to verify invalidate-in-place (#lzinplace).
fn expectStale(ctx: *Context, fnc: anytype) !void {
    if (ctx.getSlot(fnc)) |s| {
        try std.testing.expect(s.stale);
    } else return error.TestExpectedStaleSlot;
}

pub fn deinitSlotValue(
    comptime T: type,
    comptime deinitValueFn: ?DeinitValueFn(T),
) DeinitPayloadFn {
    // If they try to use the default "free" on a raw pointer/slice, error out.
    if (deinitValueFn == null and (comptime Mode(T) == .literal)) {
        const message = std.fmt.comptimePrint(
            "To prevent accidental freeing of string literals or unowned memory, " ++
                "deinitValue cannot be used directly with raw slices/pointers. " ++
                "Please return an Owned(T) or provide a custom deinit function. " ++
                "Got {}",
            .{T},
        );
        @compileError(message);
    }
    const effective_deinitValueFn = deinitValueFn orelse struct {
        fn call(_ctx: *Context, valueFn: *const ValueFn(T), value: T) void {
            _ = valueFn;
            switch (comptime Mode(T)) {
                .literal => unreachable,
                .indirect => {
                    // T is not a pointer, check for deinit method
                    if (comptime @typeInfo(T) == .@"struct" and
                        @hasDecl(T, "deinit"))
                        {
                            // For indirect, val should be single_ptr pointing to T
                        var mutable_value = value;
                            mutable_value.deinit(_ctx);
                        }
                },
            }
        }
    }.call;
    return struct {
        pub fn deinit(_slot: *Slot) void {
            if (_slot.storage) |storage| {
                const actual_value: T = switch (comptime Mode(T)) {
                    .literal => switch (comptime Slot.PtrSize(T)) {
                        .slice => storage.payload.slice.toSlice(T),
                        .one, .many, .c => @as(T, @ptrCast(@alignCast(storage.payload.single_ptr))),
                    },
                    .indirect => @as(*T, @ptrCast(@alignCast(storage.payload.single_ptr))).*,
                };
                if (_slot.value_fn_ptr) |value_fn_ptr| {
                    const typed_value_fn_ptr: *ValueFn(T) = @ptrCast(@alignCast(value_fn_ptr));
                    effective_deinitValueFn(_slot.ctx, typed_value_fn_ptr, actual_value);
                }
            }
        }
    }.deinit;
}

pub const StringView = extern struct {
    ptr: [*]const u8, // Plain pointer for C ABI compatibility
    len: usize, // Byte length (excluding \0)
    errno: c_uint,
    errmsg: ?[*]const u8,

    pub fn fromSlice(slice: []const u8) StringView {
        return StringView{
            .ptr = slice.ptr,
            .len = slice.len,
            .errno = 0,
            .errmsg = &.{},
        };
    }
};

fn SlotAndValue(comptime T: type) type {
    return struct { slot: Slot, value: T };
}

fn deinitIndirect(comptime T: type, comptime deinitFromUser: ?DeinitPayloadFn) DeinitPayloadFn {
    return struct {
        pub fn deinit(ctx: *Context, val: Storage) void {
            if (deinitFromUser) {
                deinitFromUser(ctx, val);
            }

            switch (comptime Mode(T)) {
                .literal => unreachable,
                .indirect => {
                    ctx.allocator.destroy(
                        @as(
                            *T,
                            @ptrCast(@alignCast(val.single_ptr)),
                        ),
                    );
                },
            }
        }
    }.deinit;
}

test "lazily/slot.Context.init, slotFn, Context.getSlot, Context.deinit" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    const getFoo = struct {
        fn call(_: *Context) !u8 {
            return 1;
        }
    }.call;
    const lazyFoo = initSlotFn(u8, getFoo, null);

    try std.testing.expectEqual(null, ctx.getSlot(getFoo));
    try std.testing.expectEqual(@as(u8, 1), (try lazyFoo(ctx)).*);
    try std.testing.expect(ctx.getSlot(getFoo) != null);
}

test "lazily/slot.Slot.emitChange" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const getFoo = struct {
        fn call(_ctx: *Context) !u8 {
            try (try slotEventLog(_ctx)).append("foo|");
            return 1;
        }
    }.call;
    const foo = comptime initSlotFn(
        u8,
        getFoo,
        null,
    );

    const getBar = struct {
        fn call(_ctx: *Context) !u8 {
            try (try slotEventLog(_ctx)).append("bar|");
            return (try foo(_ctx)).* * 10;
        }
    }.call;
    const bar = comptime initSlotFn(
        u8,
        getBar,
        null,
    );

    const getBaz = struct {
        fn call(_ctx: *Context) !u8 {
            try (try slotEventLog(_ctx)).append("baz|");
            return (try bar(_ctx)).* + 1;
        }
    }.call;
    const baz = comptime initSlotFn(
        u8,
        getBaz,
        null,
    );

    try std.testing.expectEqual(null, ctx.getSlot(getFoo));
    try std.testing.expectEqual(null, ctx.getSlot(getBar));
    try std.testing.expectEqual(null, ctx.getSlot(getBaz));
    try expectEventLog(ctx, "");

    try std.testing.expectEqual(11, (try baz(ctx)).*);
    try std.testing.expect(ctx.getSlot(getFoo) != null);
    try std.testing.expect(ctx.getSlot(getBar) != null);
    try std.testing.expect(ctx.getSlot(getBaz) != null);
    try expectEventLog(ctx, "baz|bar|foo|");

    if (ctx.getSlot(getFoo)) |foo_slot| {
        foo_slot.emitChange();
    } else {
        return error.FooNotFound;
    }

    try std.testing.expect(ctx.getSlot(getFoo) != null);
    // emitChange invalidates dependents in-place (#lzinplace): bar/baz stay
    // in cache but are marked stale (not destroyed/removed as before).
    try expectStale(ctx, getBar);
    try expectStale(ctx, getBaz);
    try expectEventLog(ctx, "baz|bar|foo|");

    try std.testing.expectEqual(11, (try baz(ctx)).*);
    try std.testing.expect(ctx.getSlot(getFoo) != null);
    try std.testing.expect(ctx.getSlot(getBar) != null);
    try std.testing.expect(ctx.getSlot(getBaz) != null);
    try expectEventLog(ctx, "baz|bar|foo|baz|bar|");
}

test "lazily/slot.Slot.touch" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const getFoo = struct {
        fn call(_ctx: *Context) !u8 {
            try (try slotEventLog(_ctx)).append("foo|");
            return 1;
        }
    }.call;
    const foo = comptime initSlotFn(
        u8,
        getFoo,
        null,
    );

    const getBar = struct {
        fn call(_ctx: *Context) !u8 {
            try (try slotEventLog(_ctx)).append("bar|");
            return (try foo(_ctx)).* * 10;
        }
    }.call;
    const bar = comptime initSlotFn(
        u8,
        getBar,
        null,
    );

    const getBaz = struct {
        fn call(_ctx: *Context) !u8 {
            try (try slotEventLog(_ctx)).append("baz|");
            return (try bar(_ctx)).* + 1;
        }
    }.call;
    const baz = comptime initSlotFn(
        u8,
        getBaz,
        null,
    );

    try std.testing.expectEqual(null, ctx.getSlot(getFoo));
    try std.testing.expectEqual(null, ctx.getSlot(getBar));
    try std.testing.expectEqual(null, ctx.getSlot(getBaz));
    try expectEventLog(ctx, "");

    try std.testing.expectEqual(11, (try baz(ctx)).*);
    try std.testing.expect(ctx.getSlot(getFoo) != null);
    try std.testing.expect(ctx.getSlot(getBar) != null);
    try std.testing.expect(ctx.getSlot(getBaz) != null);
    try expectEventLog(ctx, "baz|bar|foo|");

    if (ctx.getSlot(getFoo)) |foo_slot| {
        foo_slot.touch();
    } else {
        return error.FooNotFound;
    }

    // touch invalidates foo + cascades to bar, baz (#lzinplace: stale, not freed)
    try expectStale(ctx, getFoo);
    try expectStale(ctx, getBar);
    try expectStale(ctx, getBaz);
    try expectEventLog(ctx, "baz|bar|foo|");

    try std.testing.expectEqual(11, (try baz(ctx)).*);
    try std.testing.expect(ctx.getSlot(getFoo) != null);
    try std.testing.expect(ctx.getSlot(getBar) != null);
    try std.testing.expect(ctx.getSlot(getBaz) != null);
    try expectEventLog(ctx, "baz|bar|foo|baz|bar|foo|");
}

test "lazily/slot.Slot destroy/unsubscribe soak — diamond DAG" {
    // Guards the Slot destroy↔unsubscribeChangeUnlocked ordering fixed by
    // 1dd8998 (capture ctx before destroy — UAF on deferred unlock) and the
    // emitChangeUnlocked snapshot-before-iterate fix. `sink` has TWO parents
    // (`left`, `right`): its teardown unsubscribes from both while each
    // parent's destroy cascades into it — the exact ordering the fixes guard.
    // The soak loop amplifies any corruption/UAF into a testing-allocator or
    // runtime failure across many build→teardown cycles.
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const getSrc = struct {
        fn call(_ctx: *Context) !u8 {
            try (try slotEventLog(_ctx)).append("src|");
            return 1;
        }
    }.call;
    const src = comptime initSlotFn(u8, getSrc, null);

    const getLeft = struct {
        fn call(_ctx: *Context) !u8 {
            try (try slotEventLog(_ctx)).append("left|");
            return (try src(_ctx)).* + 1;
        }
    }.call;
    const left = comptime initSlotFn(u8, getLeft, null);

    const getRight = struct {
        fn call(_ctx: *Context) !u8 {
            try (try slotEventLog(_ctx)).append("right|");
            return (try src(_ctx)).* + 2;
        }
    }.call;
    const right = comptime initSlotFn(u8, getRight, null);

    const getSink = struct {
        fn call(_ctx: *Context) !u8 {
            try (try slotEventLog(_ctx)).append("sink|");
            return (try left(_ctx)).* + (try right(_ctx)).*;
        }
    }.call;
    const sink = comptime initSlotFn(u8, getSink, null);

    const n: usize = 300;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        // Build the diamond: pulls src, left, right, sink (sink depends on both).
        try std.testing.expectEqual(5, (try sink(ctx)).*); // (1+1) + (1+2)

        // Teardown from the root: src.touch() cascades destroy through both
        // branches and the shared two-parent sink.
        if (ctx.getSlot(getSrc)) |src_slot| {
            src_slot.touch();
        } else {
            return error.SrcNotFound;
        }

        // Whole graph invalidated each cycle (#lzinplace: stale, not freed)
        try expectStale(ctx, getSrc);
        try expectStale(ctx, getLeft);
        try expectStale(ctx, getRight);
        try expectStale(ctx, getSink);
    }
}

test "lazily/slot.Slot.emitChange soak — multi-subscriber invalidation" {
    // Guards emitChangeUnlocked's snapshot+clear-before-iterate fix
    // (iteration-during-mutation): `src` has three direct dependents
    // (a, b, c), each pulled into a shared `agg`. emitChange iterates src's
    // subscriber map and destroys each; without the snapshot fix,
    // destroyUnlocked→unsubscribeChangeUnlocked mutated the map mid-iteration.
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const getSrc = struct {
        fn call(_ctx: *Context) !u8 {
            try (try slotEventLog(_ctx)).append("src|");
            return 2;
        }
    }.call;
    const src = comptime initSlotFn(u8, getSrc, null);

    const getA = struct {
        fn call(_ctx: *Context) !u8 {
            try (try slotEventLog(_ctx)).append("a|");
            return (try src(_ctx)).* + 1;
        }
    }.call;
    const a = comptime initSlotFn(u8, getA, null);

    const getB = struct {
        fn call(_ctx: *Context) !u8 {
            try (try slotEventLog(_ctx)).append("b|");
            return (try src(_ctx)).* + 2;
        }
    }.call;
    const b = comptime initSlotFn(u8, getB, null);

    const getC = struct {
        fn call(_ctx: *Context) !u8 {
            try (try slotEventLog(_ctx)).append("c|");
            return (try src(_ctx)).* + 3;
        }
    }.call;
    const c = comptime initSlotFn(u8, getC, null);

    const getAgg = struct {
        fn call(_ctx: *Context) !u8 {
            try (try slotEventLog(_ctx)).append("agg|");
            return (try a(_ctx)).* + (try b(_ctx)).* + (try c(_ctx)).*;
        }
    }.call;
    const agg = comptime initSlotFn(u8, getAgg, null);

    const n: usize = 300;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try std.testing.expectEqual(12, (try agg(ctx)).*); // 3+4+5

        // emitChange invalidates dependents but keeps src (eager-invalidation
        // path that runs emitChangeUnlocked's snapshot-then-clear loop).
        if (ctx.getSlot(getSrc)) |src_slot| {
            src_slot.emitChange();
        } else {
            return error.SrcNotFound;
        }

        try std.testing.expect(ctx.getSlot(getSrc) != null);
        // emitChange invalidates dependents in-place (#lzinplace)
        try expectStale(ctx, getA);
        try expectStale(ctx, getB);
        try expectStale(ctx, getC);
        try expectStale(ctx, getAgg);
    }
}

// ---------------------------------------------------------------------------
// Concurrency: cached slot reads under N-thread contention
//
// Regression guard for the v0.9.0 fixes: the cached-read path in slotKeyed
// previously could leak the reentrant lock on a subscribeChangeUnlocked error
// (depth not decremented → permanent deadlock). The defer-scoped lock in
// slotKeyed closes that. This test exercises the path under 4-thread
// contention to catch any regression.
// ---------------------------------------------------------------------------

fn getConstantU32(_: *Context) anyerror!u32 {
    return 42;
}

const SlotConcArgs = struct {
    ctx: *Context,
    barrier: *std.atomic.Value(i32),
    done: *std.atomic.Value(u32),
    err: *?anyerror,
};

fn slotConcWorker(args: *SlotConcArgs) void {
    _ = args.barrier.fetchSub(1, .seq_cst);
    while (args.barrier.load(.acquire) > 0) std.atomic.spinLoopHint();

    const ctx = args.ctx;
    _ = slot(u32, ctx, getConstantU32, null) catch |e| {
        args.err.* = e;
    };
    _ = args.done.fetchAdd(1, .seq_cst);
}

test "lazily/slot: cached read under 4-thread contention" {
    // Use page_allocator (same as the bench) to match the failure conditions.
    const ctx = try Context.init(std.heap.page_allocator);
    defer ctx.deinit();
    // Prime the cache so all workers hit the cached-read path.
    _ = try slot(u32, ctx, getConstantU32, null);

    const n_threads: usize = 4;
    var barrier = std.atomic.Value(i32).init(@intCast(n_threads));
    var done = std.atomic.Value(u32).init(0);
    var err: ?anyerror = null;

    var args = SlotConcArgs{
        .ctx = ctx,
        .barrier = &barrier,
        .done = &done,
        .err = &err,
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, slotConcWorker, .{&args});
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(u32, @intCast(n_threads)), done.load(.seq_cst));
    if (err) |e| return e;
}

// ---------------------------------------------------------------------------
// Concurrency: set+get under N-thread contention (#lzinplace soak)
//
// The destroy-on-invalidate UAF regression test. Before #lzinplace, N threads
// concurrently calling Cell.set + slot.get on the same cell caused SEGV after
// many iterations: emitChange freed a slot whose storage pointer another
// thread held. With invalidate-in-place (mark stale, don't free), the slot
// stays alive — no UAF. This test runs 4 threads × 5000 iterations each as a
// soak. If it completes without error, the fix holds.
// ---------------------------------------------------------------------------

fn getSourceU32(_: *Context) anyerror!u32 {
    return 0;
}

fn getDerivedU32(c: *Context) anyerror!u32 {
    const CellMod = @import("cell.zig");
    const s = try CellMod.cell(u32, c, getSourceU32, null);
    return s.get() +% 1;
}

const SetGetArgs = struct {
    ctx: *Context,
    barrier: *std.atomic.Value(i32),
    ops: *std.atomic.Value(u64),
    err: *?anyerror,
};

fn setGetWorker(args: *SetGetArgs) void {
    _ = args.barrier.fetchSub(1, .seq_cst);
    while (args.barrier.load(.acquire) > 0) std.atomic.spinLoopHint();

    const ctx = args.ctx;
    const CellMod = @import("cell.zig");
    const c = CellMod.cell(u32, ctx, getSourceU32, null) catch |e| {
        args.err.* = e;
        return;
    };

    var i: u32 = 0;
    const iters: u32 = 5000;
    while (i < iters) : (i += 1) {
        c.set(i);
        _ = slot(u32, ctx, getDerivedU32, null) catch |e| {
            args.err.* = e;
            return;
        };
    }
    _ = args.ops.fetchAdd(iters, .monotonic);
}

test "lazily/slot: concurrent set+get soak — invalidate-in-place (#lzinplace)" {
    const ctx = try Context.init(std.heap.page_allocator);
    defer ctx.deinit();
    // Prime the cell + derived slot.
    const CellMod = @import("cell.zig");
    _ = try CellMod.cell(u32, ctx, getSourceU32, null);
    _ = try slot(u32, ctx, getDerivedU32, null);

    const n_threads: usize = 4;
    var barrier = std.atomic.Value(i32).init(@intCast(n_threads));
    var ops = std.atomic.Value(u64).init(0);
    var err: ?anyerror = null;

    var args = SetGetArgs{
        .ctx = ctx,
        .barrier = &barrier,
        .ops = &ops,
        .err = &err,
    };

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, setGetWorker, .{&args});
    }
    for (threads) |t| t.join();

    // All 4 threads × 5000 iterations should complete without SEGV.
    try std.testing.expectEqual(@as(u64, 20_000), ops.load(.monotonic));
    if (err) |e| return e;
}
