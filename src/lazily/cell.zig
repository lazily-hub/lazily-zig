const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Context = @import("context.zig").Context;
const currentSlotFor = @import("context.zig").currentSlotFor;
const EdgeSet = @import("context.zig").EdgeSet;
const Owned = @import("context.zig").Owned;
const OwnedString = @import("context.zig").OwnedString;
const Slot = @import("context.zig").Slot;
const String = @import("context.zig").String;
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

/// A single observer registration (`#lzdartobservercow`).
///
/// The observer collection is keyed by REGISTRATION, never by callback: the
/// spec's no-deduplication clause makes "subscribe the same callback twice"
/// two independent observers, both invoked per notification, each removed by
/// exactly its own token. Keying by callback address — what this file did
/// before, returning "not added" for a callback already present — silently
/// couples unrelated callers: two components that happen to subscribe the same
/// function share one registration, so the first to unsubscribe cancels the
/// second's subscription.
///
/// `id` is a per-cell monotonic counter starting at 1, so it is also what
/// makes disposal latch: a spent token names an id that is no longer in the
/// set, and every call after the first is a no-op that cannot reach a later
/// registration of an equal callable.
pub const Subscription = struct {
    /// Unique per `Cell`, monotonic, never reused. `0` is the tombstone.
    id: u64,
    /// Erased `ChangeCallback(T)`; `Subscription` is not generic so a caller
    /// can store tokens for cells of different value types together.
    cb: usize,

    /// `EdgeSet` index hook: hash the registration id, which is unique, rather
    /// than the whole key.
    pub inline fn edgeHashKey(self: Subscription) u64 {
        return self.id;
    }
};

/// `EdgeSet(Subscription, 1)` (`#lzzigcellslotedgeset`): the same
/// inline-capacity container the `Slot` graph uses for its dependency edges.
/// `inline_cap = 1` keeps the common 0-1 subscriber cell allocation-free.
///
/// The set's dedup scan never fires here — registration ids are unique by
/// construction — but the container is still the right one: it preserves
/// insertion order (which IS firing order), it supports the in-place
/// tombstone the mid-notification `unsubscribe` path needs, and its wide-fanout
/// hash index still applies via `Subscription.edgeHashKey`.
const SubscriberEdgeSet = EdgeSet(Subscription, 1);

/// Sentinel written over an entry unsubscribed while a notification is in
/// flight (`#lzdartobservercow`). Registration ids start at 1, so id `0` is
/// never a real member.
const subscriber_tomb: Subscription = .{ .id = 0, .cb = 0 };

/// A mutable container to be stored as a slot via the cell function
pub fn Cell(comptime T: type) type {
    return struct {
        ctx: *Context,
        slot: *Slot,
        value: T,
        before_change_subscribers: SubscriberEdgeSet,
        change_subscribers: SubscriberEdgeSet,
        deinitCellValue: ?DeinitCellValueFn(T),

        // --- observer reentrancy (`#lzdartobservercow`) ----------------------
        //
        // Reentrancy semantics, pinned by the tests at the bottom of this file
        // (the family had no written position before this):
        //
        //   * `subscribe` during a notification is DEFERRED — the new observer
        //     first runs on the NEXT notification. Matches lazily-dart and
        //     lazily-go, whose notify loops hold a snapshot taken before the
        //     first callback, and makes a self-feeding subscriber unable to
        //     extend the in-flight loop.
        //   * `unsubscribe` during a notification takes effect IMMEDIATELY — an
        //     observer removed before the loop reaches it is not invoked in
        //     that notification. This is a deliberate divergence from
        //     dart/go, whose stable snapshot still calls a disposed observer
        //     once more: those runtimes are garbage-collected, so a stale
        //     closure is harmless, whereas here `unsubscribe` is routinely the
        //     step before tearing down the memory the callback reads. It is
        //     also what this implementation already did in the case where the
        //     swap-remove happened to be a plain pop.
        //   * Observers already visited are unaffected by either.
        //
        // Mechanism: the notify loop indexes by position rather than holding a
        // `KeyIterator`, and while `notify_depth > 0` an `unsubscribe`
        // tombstones its entry instead of swap-removing it, so no live entry
        // is ever relocated past the cursor. The holes are compacted when the
        // outermost notification returns. The steady-state notify path is
        // unchanged and still allocation-free: no snapshot is taken, and the
        // compaction pass is skipped entirely unless something was actually
        // unsubscribed mid-flight.
        //
        // These four are plain fields, not atomics. Making the change-notify
        // pair atomic cost ~7ns of fixed overhead per notifying `set` (two
        // locked RMWs), which measured as a 1.74x regression of the w=1
        // publish arm — the exact shape of the `lazily-cpp` `ba9ba34`
        // regression. They are safe as plain fields under the same contract
        // the surrounding code already relies on: concurrent `set` of one
        // `Cell` is unsupported, because the change-notify loop deliberately
        // runs with `ctx.mutex` released and a concurrent `subscribe` can
        // reallocate the set out from under it. `notify_depth` is incremented
        // under the lock and decremented on the same thread that incremented
        // it.
        //
        // Compaction of the change set is deferred to the next `subscribe` /
        // `unsubscribe` / `set`, each of which already holds `ctx.mutex`, so
        // the notify path never re-acquires the lock to clean up. That
        // deferral is what keeps `remove`'s swap — which cannot repair the
        // index for a sentinel that is deliberately absent from it — from ever
        // running while a tombstone is live.
        notify_depth: u32 = 0,
        change_tombstoned: bool = false,
        before_notify_depth: u32 = 0,
        before_tombstoned: bool = false,

        /// Registration counter shared by both observer lists. Starts at 1 so
        /// `subscriber_tomb.id == 0` is never issued; never reset, so a token
        /// for a disposed registration can never collide with a later one.
        next_subscription_id: u64 = 1,

        /// Allocate the next registration id. Caller must hold `ctx.mutex`.
        fn nextSubscriptionId(self: *@This()) u64 {
            const id = self.next_subscription_id;
            self.next_subscription_id += 1;
            return id;
        }

        /// Close the holes left by a mid-notification `unsubscribe`. Callers
        /// must hold `ctx.mutex`.
        fn compactChangeSubscribers(self: *@This()) void {
            if (self.change_tombstoned and self.notify_depth == 0) {
                self.change_subscribers.compactTombstones(subscriber_tomb);
                self.change_tombstoned = false;
            }
        }

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
                            .before_change_subscribers = SubscriberEdgeSet.init(),
                            .change_subscribers = SubscriberEdgeSet.init(),
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
                deinit_fn(self);
            }
            self.before_change_subscribers.deinit(self.ctx.allocator);
            self.change_subscribers.deinit(self.ctx.allocator);
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

            // before_change subscribers fire BEFORE the value is committed, so
            // `get()` still returns the outgoing value. Invoked under the
            // context lock (like emitChangeUnlocked): callbacks must not
            // re-enter Context/Cell methods that acquire `ctx.mutex` —
            // `Cell.get` is lock-free and safe for reading the old value.
            {
                // Position-indexed rather than iterator-based, and bounded by
                // the count captured before the first callback, so a reentrant
                // subscribe (append) or unsubscribe (tombstone) cannot skip,
                // repeat, or extend this pass (`#lzdartobservercow`).
                const before_n = self.before_change_subscribers.count();
                if (before_n > 0) {
                    self.before_notify_depth += 1;
                    var i: usize = 0;
                    while (i < before_n) : (i += 1) {
                        const reg = self.before_change_subscribers.at(i);
                        if (reg.id == subscriber_tomb.id) continue;
                        const before_cb: ChangeCallback(T) = @ptrFromInt(reg.cb);
                        before_cb(self);
                    }
                    self.before_notify_depth -= 1;
                    if (self.before_notify_depth == 0 and self.before_tombstoned) {
                        self.before_change_subscribers.compactTombstones(subscriber_tomb);
                        self.before_tombstoned = false;
                    }
                }
            }

            self.value = new_value;
            self.slot.emitChangeUnlocked();

            self.compactChangeSubscribers();
            const change_n = self.change_subscribers.count();
            if (change_n > 0) self.notify_depth += 1;

            // Callbacks may call into the context so unlock here.
            self.ctx.mutex.unlock();

            if (change_n > 0) {
                var i: usize = 0;
                while (i < change_n) : (i += 1) {
                    const reg = self.change_subscribers.at(i);
                    if (reg.id == subscriber_tomb.id) continue;
                    const cb: ChangeCallback(T) = @ptrFromInt(reg.cb);
                    cb(self);
                }
                self.notify_depth -= 1;
            }

            // While inside a `batch(run)` boundary, defer the eager-recompute
            // flush so N `set` calls coalesce into one Signal/Effect rerun at
            // the outermost batch exit (`reactive-graph.md` § batch).
            //
            // Store-without-cascade: skip the drain entirely when nothing is
            // pending. A `set` whose invalidation cone held no eager
            // Signal/Effect leaves `pending_recompute` empty, so entering
            // `drainPendingRecompute` would just re-check the empty queue.
            // Gating on the length avoids that call on every store (mirrors
            // lazily-rs `set_cell`, which only flushes when invalidate returned
            // true — i.e. when the cone actually contained an Effect).
            if (!self.ctx.isBatching() and self.ctx.pending_recompute.items.len > 0) {
                self.ctx.drainPendingRecompute();
            }
        }

        /// Register `cb` as a change observer and return the token that
        /// disposes it (`#lzdartobservercow`).
        ///
        /// Every call produces an independent registration, including repeat
        /// calls with the same `cb`: both are invoked on each notification, in
        /// registration order, and each token removes exactly one of them.
        pub fn subscribe(self: *@This(), cb: ChangeCallback(T)) !Subscription {
            self.ctx.mutex.lock();
            defer self.ctx.mutex.unlock();

            // Settle any deferred tombstones first: `getOrPut`'s indexed path
            // can rebuild the index, and the sentinel must not be indexed.
            self.compactChangeSubscribers();

            const sub = Subscription{
                .id = self.nextSubscriptionId(),
                .cb = @intFromPtr(cb),
            };
            // Appends: the id is fresh, so the dedup scan never matches and
            // the entry lands at the back — registration order is firing order.
            try self.change_subscribers.getOrPut(sub, self.ctx.allocator);
            return sub;
        }

        /// Dispose the registration named by `sub`. Latching and single-shot:
        /// the first call removes it, every later call is a no-op returning
        /// `false`, and it can never reach a later registration of an equal
        /// callback because ids are never reused.
        pub fn unsubscribe(self: *@This(), sub: Subscription) bool {
            self.ctx.mutex.lock();
            defer self.ctx.mutex.unlock();

            // Removal is always tombstone-then-compact, never `remove`'s
            // swap. Two reasons, and both are normative:
            //
            //   * Mid-notification, a swap-remove would relocate the tail
            //     entry behind the notify cursor and that observer would
            //     silently never be called (`#lzdartobservercow`) — the defect
            //     the spec section was written from.
            //   * In steady state, a swap-remove leaves the survivors in an
            //     order that is not registration order. The spec explicitly
            //     licenses paying the O(n) erase the notify path already
            //     tolerates rather than keeping the O(1) swap.
            if (!self.change_subscribers.tombstone(sub, subscriber_tomb)) return false;
            if (self.notify_depth > 0) {
                // Compaction is deferred to the outermost notification's exit
                // (or the next `subscribe`/`set`), so no live entry moves
                // while the position-indexed loop is walking the list.
                self.change_tombstoned = true;
                return true;
            }
            self.change_subscribers.compactTombstones(subscriber_tomb);
            self.change_tombstoned = false;
            return true;
        }

        /// Subscribe a callback that fires BEFORE a `set` commits its new
        /// value (see `set` for the under-lock invocation contract). Same
        /// registration keying as `subscribe`.
        pub fn subscribeBeforeChange(self: *@This(), cb: ChangeCallback(T)) !Subscription {
            self.ctx.mutex.lock();
            defer self.ctx.mutex.unlock();

            if (self.before_tombstoned and self.before_notify_depth == 0) {
                self.before_change_subscribers.compactTombstones(subscriber_tomb);
                self.before_tombstoned = false;
            }

            const sub = Subscription{
                .id = self.nextSubscriptionId(),
                .cb = @intFromPtr(cb),
            };
            try self.before_change_subscribers.getOrPut(sub, self.ctx.allocator);
            return sub;
        }

        pub fn unsubscribeBeforeChange(self: *@This(), sub: Subscription) bool {
            self.ctx.mutex.lock();
            defer self.ctx.mutex.unlock();

            if (!self.before_change_subscribers.tombstone(sub, subscriber_tomb)) return false;
            if (self.before_notify_depth > 0) {
                self.before_tombstoned = true;
                return true;
            }
            self.before_change_subscribers.compactTombstones(subscriber_tomb);
            self.before_tombstoned = false;
            return true;
        }
    };
}

// Replaces the former `test "lazily/cell.Cell: subscribe dedup"`, which
// asserted the pre-migration behavior (`subscribe` returning `false` for a
// callback already present). Deduplication by callback address is now a
// `MUST NOT` — see `reactive-graph.md` § observer semantics — so the test
// asserts its inverse. The cross-language fixtures for the same clause run in
// `observer_conformance_test.zig`.
test "lazily/cell.Cell: subscribe returns an independent registration per call" {
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

    // Two subscribes of the SAME callback are two registrations, with
    // distinct tokens.
    const first = try test_cell.subscribe(TestState.onChange);
    const second = try test_cell.subscribe(TestState.onChange);
    try std.testing.expect(first.id != second.id);
    try std.testing.expectEqual(@as(i32, -1), TestState.value.load(.seq_cst));

    // ...so the callback runs twice per notification, once per registration.
    test_cell.set(2);
    try std.testing.expectEqual(@as(i32, 2), test_cell.get());
    try std.testing.expectEqual(@as(usize, 2), TestState.called.load(.seq_cst));
    try std.testing.expectEqual(@as(i32, 2), TestState.value.load(.seq_cst));

    // Each token removes exactly one; the other keeps firing.
    try std.testing.expect(test_cell.unsubscribe(first));
    test_cell.set(3);
    try std.testing.expectEqual(@as(usize, 3), TestState.called.load(.seq_cst));

    // A spent token latches: repeat disposal is a silent no-op and must not
    // reach the surviving registration.
    try std.testing.expect(!test_cell.unsubscribe(first));
    try std.testing.expect(!test_cell.unsubscribe(first));
    test_cell.set(4);
    try std.testing.expectEqual(@as(usize, 4), TestState.called.load(.seq_cst));

    try std.testing.expect(test_cell.unsubscribe(second));
    test_cell.set(5);
    try std.testing.expectEqual(@as(usize, 4), TestState.called.load(.seq_cst));
    try std.testing.expectEqual(@as(i32, 4), TestState.value.load(.seq_cst));
}

test "lazily/cell.Cell: before_change fires before commit" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var test_cell = try Cell(i32).init(ctx, struct {
        fn call(_ctx: *Context) !i32 {
            _ = _ctx;
            return 1;
        }
    }.call, null);

    const TestState = struct {
        var called = std.atomic.Value(usize).init(0);
        // Snapshot of the value observed when before_change fires.
        var observed = std.atomic.Value(i32).init(-1);

        fn onBeforeChange(_cell: *Cell(i32)) void {
            _ = called.fetchAdd(1, .seq_cst);
            // Before commit: get() must still return the OLD value.
            _ = observed.swap(_cell.get(), .seq_cst);
        }
    };

    TestState.called.store(0, .seq_cst);

    const before_token = try test_cell.subscribeBeforeChange(TestState.onBeforeChange);

    // Unchanged value: before_change must NOT fire.
    test_cell.set(1);
    try std.testing.expectEqual(@as(usize, 0), TestState.called.load(.seq_cst));

    // Changed value: before_change fires once, observing the OLD value (1).
    test_cell.set(2);
    try std.testing.expectEqual(@as(usize, 1), TestState.called.load(.seq_cst));
    try std.testing.expectEqual(@as(i32, 1), TestState.observed.load(.seq_cst));
    try std.testing.expectEqual(@as(i32, 2), test_cell.get());

    // Unsubscribe stops before-change notifications.
    try std.testing.expect(test_cell.unsubscribeBeforeChange(before_token));
    test_cell.set(3);
    try std.testing.expectEqual(@as(usize, 1), TestState.called.load(.seq_cst));
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
    // Always go through Cell.init → slotKeyed so dependency edges are
    // (re-)established on every read, not just the first.  This is critical
    // for eager Signal recompute: after clearing parents, the valueFn must
    // re-subscribe to its dependencies.  slotKeyed returns the cached slot
    // when it exists, so the valueFn is not re-run.
    return Cell(T).init(ctx, valueFn, deinitFn);
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
    // Invalidate-in-place (`#lzinplace`, v1.0.0): setting `name` invalidates its
    // dependents (`greeting`, and transitively `greetingAndResponse`) in place
    // — they stay in the cache marked STALE rather than being removed, and are
    // refreshed on the next read. (Pre-#lzinplace this asserted the dependent
    // slots were absent from the cache; that model freed slots whose storage a
    // concurrent reader could still hold — the destroy-on-invalidate UAF.)
    if (ctx.getSlot(getGreeting)) |s| {
        try std.testing.expect(s.stale);
    } else return error.TestExpectedStaleGreeting;
    if (ctx.getSlot(getGreetingAndResponse)) |s| {
        try std.testing.expect(s.stale);
    } else return error.TestExpectedStaleGreetingAndResponse;
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

test "lazily/cell.Cell: batch coalesces eager recomputes into one flush" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const BatchState = struct {
        var runs = std.atomic.Value(usize).init(0);

        const getSourceA = struct {
            fn call(_: *Context) anyerror!u32 {
                return 0;
            }
        }.call;
        const getSourceB = struct {
            fn call(_: *Context) anyerror!u32 {
                return 0;
            }
        }.call;

        const getDerived = struct {
            fn call(c: *Context) anyerror!u32 {
                _ = try @import("cell.zig").cell(u32, c, getSourceA, null);
                _ = try @import("cell.zig").cell(u32, c, getSourceB, null);
                _ = runs.fetchAdd(1, .seq_cst);
                return 0;
            }
        }.call;

        fn runBatch(c: *Context) void {
            const a = @import("cell.zig").cell(u32, c, getSourceA, null) catch return;
            const b = @import("cell.zig").cell(u32, c, getSourceB, null) catch return;
            a.set(10);
            b.set(20);
            a.set(11);
        }
    };

    BatchState.runs.store(0, .seq_cst);
    const sig = try @import("signal.zig").signal(u32, ctx, BatchState.getDerived, null);
    defer ctx.allocator.destroy(sig);
    try std.testing.expectEqual(@as(usize, 1), BatchState.runs.load(.seq_cst));

    ctx.batch(BatchState.runBatch);
    // 3 setCell calls inside the batch → exactly one eager recompute at flush.
    try std.testing.expectEqual(@as(usize, 2), BatchState.runs.load(.seq_cst));
}

/// A thread-safe allocator for the `Cell` contention soak below.
/// `std.heap.ThreadSafeAllocator` was removed in Zig 0.16, so on 0.16+ this is a
/// minimal mutex-wrapped shim over a child allocator; on <0.16 it defers to the
/// std type. Wrapping `std.testing.allocator` keeps leak detection while making
/// concurrent allocation (from the soak's N threads, some outside the graph
/// lock) safe. Selected at comptime by feature-detecting the std decl.
const ThreadSafeTestAllocator = if (@hasDecl(std.heap, "ThreadSafeAllocator"))
    struct {
        inner: std.heap.ThreadSafeAllocator,
        fn init(child: std.mem.Allocator) @This() {
            return .{ .inner = .{ .child_allocator = child } };
        }
        fn allocator(self: *@This()) std.mem.Allocator {
            return self.inner.allocator();
        }
    }
else
    struct {
        child: std.mem.Allocator,
        // std.Thread.Mutex was removed alongside ThreadSafeAllocator in 0.16;
        // use the repo's futex-backed ParkingMutex.
        mutex: @import("parking_mutex.zig").ParkingMutex = .{},

        fn init(child: std.mem.Allocator) @This() {
            return .{ .child = child };
        }
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &vtable };
        }
        const vtable: std.mem.Allocator.VTable = .{
            .alloc = allocFn,
            .resize = resizeFn,
            .remap = remapFn,
            .free = freeFn,
        };
        fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.child.rawAlloc(len, alignment, ret_addr);
        }
        fn resizeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.child.rawResize(memory, alignment, new_len, ret_addr);
        }
        fn remapFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.child.rawRemap(memory, alignment, new_len, ret_addr);
        }
        fn freeFn(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.mutex.lock();
            defer self.mutex.unlock();
            self.child.rawFree(memory, alignment, ret_addr);
        }
    };

test "lazily/cell.thread_safe Cell updates" {
    if (!build_options.thread_safe) return error.SkipZigTest;

    var ts_allocator = ThreadSafeTestAllocator.init(std.testing.allocator);
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


// --- observer-list reentrancy (`#lzdartobservercow`) -------------------------
//
// Shared probe for the reentrancy tests below. `action` selects which
// subscribe/unsubscribe a callback performs while the notify loop is in
// flight; `log` records the visit order so a skipped or double-visited
// observer is directly observable.
const ReentrancyProbe = struct {
    var log: [32]u8 = undefined;
    var log_len: usize = 0;
    var action: u8 = 0;

    // Registration tokens (`#lzdartobservercow`): removal is keyed by
    // registration, so a reentrant `unsubscribe` needs the token the matching
    // `subscribe` returned, not the callback.
    var tok_a: Subscription = undefined;
    var tok_c: Subscription = undefined;
    var tok_before_a: Subscription = undefined;

    fn reset(new_action: u8) void {
        log_len = 0;
        action = new_action;
    }

    fn record(c: u8) void {
        log[log_len] = c;
        log_len += 1;
    }

    fn seen() []const u8 {
        return log[0..log_len];
    }

    fn onA(c: *Cell(i32)) void {
        record('a');
        switch (action) {
            1 => _ = c.unsubscribe(tok_a),
            3 => _ = c.unsubscribe(tok_c),
            4 => _ = c.subscribe(onD) catch unreachable,
            else => {},
        }
    }
    fn onB(c: *Cell(i32)) void {
        record('b');
        if (action == 2) _ = c.unsubscribe(tok_a);
    }
    fn onC(c: *Cell(i32)) void {
        _ = c;
        record('c');
    }
    fn onD(c: *Cell(i32)) void {
        _ = c;
        record('d');
    }

    fn onBeforeA(c: *Cell(i32)) void {
        record('A');
        if (action == 5) _ = c.unsubscribeBeforeChange(tok_before_a);
    }
    fn onBeforeB(c: *Cell(i32)) void {
        _ = c;
        record('B');
    }
    fn onBeforeC(c: *Cell(i32)) void {
        _ = c;
        record('C');
    }
};

fn reentrancyCell(ctx: *Context) !*Cell(i32) {
    return Cell(i32).init(ctx, struct {
        fn call(_ctx: *Context) !i32 {
            _ = _ctx;
            return 1;
        }
    }.call, null);
}

test "lazily/cell.Cell: self-unsubscribe during notify still visits every live observer" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();
    var test_cell = try reentrancyCell(ctx);

    ReentrancyProbe.reset(1);
    ReentrancyProbe.tok_a = try test_cell.subscribe(ReentrancyProbe.onA);
    _ = try test_cell.subscribe(ReentrancyProbe.onB);
    ReentrancyProbe.tok_c = try test_cell.subscribe(ReentrancyProbe.onC);

    test_cell.set(2);
    // `onA` removes itself while the loop is mid-iteration. `onB` and `onC`
    // are live subscribers and must both still be visited exactly once.
    try std.testing.expectEqualStrings("abc", ReentrancyProbe.seen());
}

test "lazily/cell.Cell: unsubscribing an already-visited observer during notify does not skip the tail" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();
    var test_cell = try reentrancyCell(ctx);

    ReentrancyProbe.reset(2);
    ReentrancyProbe.tok_a = try test_cell.subscribe(ReentrancyProbe.onA);
    _ = try test_cell.subscribe(ReentrancyProbe.onB);
    ReentrancyProbe.tok_c = try test_cell.subscribe(ReentrancyProbe.onC);
    _ = try test_cell.subscribe(ReentrancyProbe.onD);

    test_cell.set(2);
    // `onB` removes `onA`, which the loop has already visited. `onC`/`onD`
    // are untouched and must still fire.
    try std.testing.expectEqualStrings("abcd", ReentrancyProbe.seen());
}

test "lazily/cell.Cell: unsubscribing a not-yet-visited observer during notify suppresses it" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();
    var test_cell = try reentrancyCell(ctx);

    ReentrancyProbe.reset(3);
    ReentrancyProbe.tok_a = try test_cell.subscribe(ReentrancyProbe.onA);
    _ = try test_cell.subscribe(ReentrancyProbe.onB);
    ReentrancyProbe.tok_c = try test_cell.subscribe(ReentrancyProbe.onC);

    test_cell.set(2);
    // Pinned semantics: `unsubscribe` takes effect immediately, so an observer
    // removed before the loop reaches it is NOT invoked in that notification.
    try std.testing.expectEqualStrings("ab", ReentrancyProbe.seen());

    // ...and stays unsubscribed on the next notification.
    ReentrancyProbe.reset(0);
    test_cell.set(3);
    try std.testing.expectEqualStrings("ab", ReentrancyProbe.seen());
}

test "lazily/cell.Cell: subscribing during notify defers to the next notification" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();
    var test_cell = try reentrancyCell(ctx);

    ReentrancyProbe.reset(4);
    ReentrancyProbe.tok_a = try test_cell.subscribe(ReentrancyProbe.onA);

    test_cell.set(2);
    // Pinned semantics: the observer added mid-notification does not run in
    // that notification.
    try std.testing.expectEqualStrings("a", ReentrancyProbe.seen());

    ReentrancyProbe.reset(0);
    test_cell.set(3);
    try std.testing.expectEqualStrings("ad", ReentrancyProbe.seen());
}

test "lazily/cell.Cell: self-unsubscribe during before_change notify still visits every live observer" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();
    var test_cell = try reentrancyCell(ctx);

    ReentrancyProbe.reset(5);
    ReentrancyProbe.tok_before_a = try test_cell.subscribeBeforeChange(ReentrancyProbe.onBeforeA);
    _ = try test_cell.subscribeBeforeChange(ReentrancyProbe.onBeforeB);
    _ = try test_cell.subscribeBeforeChange(ReentrancyProbe.onBeforeC);

    test_cell.set(2);
    try std.testing.expectEqualStrings("ABC", ReentrancyProbe.seen());
}

// Wide-fanout reentrancy: past `EdgeSet.promote_threshold` the subscriber set
// runs on the open-addressed hash index, so a mid-notification `unsubscribe`
// exercises the tombstone/swap-remove index-repair path while the loop is
// still walking `spill`.
const WideProbe = struct {
    const width: usize = 96;

    var visits: [width]u8 = undefined;
    var tokens: [width]Subscription = undefined;
    var unsubscribed = false;

    fn reset() void {
        @memset(&visits, 0);
        unsubscribed = false;
    }

    fn Observer(comptime i: usize) type {
        return struct {
            fn cb(c: *Cell(i32)) void {
                visits[i] += 1;
                // The first observer drops itself mid-flight.
                if (i == 0 and !unsubscribed) {
                    unsubscribed = true;
                    _ = c.unsubscribe(tokens[0]);
                }
            }
        };
    }
};

test "lazily/cell.Cell: unsubscribe during notify on the wide/indexed path visits every observer once" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();
    var test_cell = try reentrancyCell(ctx);

    WideProbe.reset();
    inline for (0..WideProbe.width) |i| {
        WideProbe.tokens[i] = try test_cell.subscribe(WideProbe.Observer(i).cb);
    }

    test_cell.set(2);
    for (WideProbe.visits, 0..) |n, i| {
        std.testing.expectEqual(@as(u8, 1), n) catch |e| {
            std.debug.print("observer {d} visited {d} times (expected 1)\n", .{ i, n });
            return e;
        };
    }

    // The hole left by the mid-notification unsubscribe is compacted lazily,
    // so the next ordinary churn + notify runs `remove`/`getOrPut` against a
    // set that still carries a sentinel until it settles. Exercise that: drop
    // half the observers the normal way, re-add one, and notify again.
    var expected: [WideProbe.width]u8 = undefined;
    @memset(&expected, 1);
    expected[0] = 0; // unsubscribed itself above
    inline for (0..WideProbe.width) |i| {
        if (i % 2 == 1) {
            try std.testing.expect(test_cell.unsubscribe(WideProbe.tokens[i]));
            expected[i] = 0;
        }
    }
    WideProbe.tokens[0] = try test_cell.subscribe(WideProbe.Observer(0).cb);
    expected[0] = 1;

    @memset(&WideProbe.visits, 0);
    test_cell.set(3);
    try std.testing.expectEqualSlices(u8, &expected, &WideProbe.visits);
}
