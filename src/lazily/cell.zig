const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Context = @import("context.zig").Context;
const currentSlotFor = @import("context.zig").currentSlotFor;
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

// ---------------------------------------------------------------------------
// The Cell kernel (`#lzcellkernel`) — `SourceCell` / `FormulaCell` over a single
// genus `Cell(T, K)`.
//
// See `tasks/software/lazily-cell-kernel-design.md`. One genus with a **kind**
// type parameter `K` replaces the former split of `Cell` (source) / `Slot` /
// `Signal` (eager) reactive-*value* types:
//
//   Cell(T, K)                    genus — a node with a readable value
//   ├─ SourceCell(T, M)           written from outside; folds under policy M
//   └─ FormulaCell(T)             computed from upstream (guarded; `.drive()` = eager)
//
//   Effect                        no value; sink — outside the hierarchy
//
// `Slot` keeps its *storage* meaning (§5.0): it is the arena position that
// holds a node of any kind, so `Slot`, `SlotId`, and the slab vocabulary stay.
// Only the reactive-value sense of "slot" moves to `FormulaCell`.
//
// ## Write protection via comptime (§3, §4)
//
// Reads live on every kind (`get`). `set`/`merge` are guarded by a comptime
// `@compileError` keyed on the kind marker, so `formula.set(…)` does not
// compile — the same guarantee the Rust binding gets from an inherent impl on
// `Cell<T, Source<M>>`, realized here with Zig comptime. See the
// `formula.set()` compile-fail note on `set` and the positive tests below.
// ---------------------------------------------------------------------------

/// Per-instantiation cleanup hook for a `SourceCell`'s stored value. Retained
/// under the historical name; every non-null user is internal (all external
/// call sites pass `null`).
pub fn DeinitCellValueFn(comptime T: type) type {
    return *const fn (*SourceCell(T)) void;
}
pub fn ChangeCallback(comptime T: type) type {
    return *const fn (*SourceCell(T)) void;
}

// -- Kind markers -----------------------------------------------------------

/// Merge-policy marker for the last-writer-wins band — the policy behind a
/// plain source cell (`SourceCell(T) ≡ SourceCell(T, KeepLatest)`).
pub const KeepLatest = struct {
    pub fn policy(comptime T: type) @import("merge.zig").MergePolicy(T) {
        return @import("merge.zig").keepLatest(T);
    }
};
/// Additive commutative monoid policy marker (`old + op`).
pub const SumPolicy = struct {
    pub fn policy(comptime T: type) @import("merge.zig").MergePolicy(T) {
        return @import("merge.zig").sum(T);
    }
};
/// Max semilattice policy marker (`max(old, op)`).
pub const MaxPolicy = struct {
    pub fn policy(comptime T: type) @import("merge.zig").MergePolicy(T) {
        return @import("merge.zig").max(T);
    }
};

/// Kind marker for a **source** cell — a node written from outside, folding
/// accumulated writes under merge policy marker `M`. `M` lives inside the kind,
/// so `set`/`merge` (and the policy) exist exactly where writes exist. Reuses
/// the name of the former `Source<T>` write concept.
pub fn Source(comptime M: type) type {
    return struct {
        pub const is_source = true;
        pub const Policy = M;
    };
}

/// Kind marker for a **formula** cell — a node computed from upstream. A driven
/// formula (`formula().drive()`) is still this kind; drivenness is graph state
/// (a bit on the storage `Slot` + the `driven_by` side table), not a distinct
/// type. This retires the former `Signal`.
pub const Formula = struct {
    pub const is_source = false;
};

// -- The genus --------------------------------------------------------------

/// The kernel genus: a typed handle to a reactive node of kind `K`. `K` is one
/// of `Source(M)` or `Formula`. Callers normally spell `SourceCell(T)` /
/// `FormulaCell(T)`; generic code can take `Cell(T, K)`.
pub fn Cell(comptime T: type, comptime K: type) type {
    const is_source = @hasDecl(K, "is_source") and K.is_source;
    return struct {
        const Self = @This();

        /// The value type this cell reads.
        pub const Value = T;
        /// The kind marker (`Source(M)` or `Formula`).
        pub const Kind = K;
        /// Whether writes are permitted on this kind (comptime).
        pub const is_source_cell = is_source;
        /// Per-instantiation cleanup hook for this cell's stored value. Typed on
        /// `*Self` so a non-`KeepLatest` source cell's deinit matches its own
        /// type (the public `DeinitCellValueFn(T)` alias is the `KeepLatest`
        /// case). Every external caller passes `null`.
        pub const DeinitFn = *const fn (*Self) void;

        ctx: *Context,
        slot: *Slot,
        // Source cells embed their value inline (the synchronous input layer);
        // formula cells read from their backing `Slot`, so carry no value here.
        // `@sizeOf(SourceCell(i32)) == 32` is asserted below and must not grow.
        value: if (is_source) T else void,
        deinitCellValue: if (is_source) ?DeinitFn else void,

        pub const MissingCurrentSlotError = error{MissingCurrentSlot};

        // ---- shared reads (every kind) ------------------------------------

        /// Read this cell's current value. Source cells return the inline value;
        /// formula cells return their backing slot's materialized value
        /// (`Slot.Result(T)` — `T` for value types, `*T` for indirect).
        pub fn get(self: *const Self) if (is_source) T else Slot.Result(T) {
            if (comptime is_source) {
                return self.value;
            } else {
                // Re-materialize through the storage layer (`slotKeyed`) rather
                // than reading `slot.storage` directly: a lazy formula whose
                // upstream changed is `stale`, and `Slot.get` reads storage
                // without consulting `stale` (see signal.zig). Routing through
                // `slotKeyed` recomputes when stale, registers the dependency
                // when read inside another reactive computation, and — for a
                // driven formula (kept fresh in place) — returns the cached
                // value unchanged.
                return self.materialize();
            }
        }

        /// The checked read (`#lzspecedgeindex`): a disposed node reads as an
        /// error, never as a stale, default, or recycled value.
        pub fn tryGet(self: *const Self) error{NodeDisposed}!(if (is_source) T else Slot.Result(T)) {
            if (self.slot.disposed) return error.NodeDisposed;
            if (comptime is_source) {
                return self.value;
            } else {
                return self.materialize();
            }
        }

        /// Formula-only: recompute-on-read through the storage `Slot` keyed by
        /// this handle's identity.
        fn materialize(self: *const Self) Slot.Result(T) {
            const vfn: *const ValueFn(T) = @ptrCast(@alignCast(self.slot.value_fn_ptr.?));
            return slotKeyed(T, self.ctx, self.slot.cache_key.?, vfn, self.slot.deinitPayload) catch unreachable;
        }

        pub fn handle(self: *const Self) Context.NodeHandle {
            return .{ .key = self.slot.cache_key.? };
        }

        /// Tear this node out of the graph. Kind-agnostic — a disposed driven
        /// formula also tears down its puller (see `disposeNode` on the formula
        /// arm below, which clears the driven bit + side table first).
        pub fn disposeNode(self: *Self) void {
            if (comptime !is_source) {
                // Disposing a driven formula must not strand its puller.
                if (self.slot.driven) self.undriveInternal();
            }
            self.ctx.disposeNode(self.handle());
        }

        // ---- source-only construction + writes (§3) -----------------------

        pub fn init(
            ctx: *Context,
            comptime valueFn: *const ValueFn(T),
            comptime deinitCellValue: ?DeinitFn,
        ) !*Self {
            if (comptime !is_source) @compileError("init is only available on a SourceCell; build a FormulaCell with `formula(...)`");
            return initKeyed(ctx, valueFnCacheKey(valueFn), valueFn, deinitCellValue);
        }

        /// `init` with a caller-supplied cache key, mirroring `slotKeyed`.
        /// Needed wherever one comptime `valueFn` must back many distinct nodes
        /// — including a disposed cell's replacement, which must be a *new* node
        /// rather than a resurrection of the tombstone.
        pub fn initKeyed(
            ctx: *Context,
            cache_key: usize,
            comptime valueFn: *const ValueFn(T),
            comptime deinitCellValue: ?DeinitFn,
        ) !*Self {
            if (comptime !is_source) @compileError("initKeyed is only available on a SourceCell");
            const getCell = struct {
                fn call(_ctx: *Context) anyerror!Self {
                    const initial_value = try valueFn(_ctx);
                    const maybe_cell_slot = currentSlotFor(_ctx);
                    if (maybe_cell_slot) |cell_slot| {
                        return Self{
                            .ctx = _ctx,
                            .slot = cell_slot,
                            .value = initial_value,
                            .deinitCellValue = deinitCellValue,
                        };
                    } else return error.MissingCurrentSlot;
                }
            }.call;
            const self = try slotKeyed(
                Self,
                ctx,
                cache_key,
                getCell,
                deinitSlotValue(Self, struct {
                    fn deinitValue(
                        _ctx: *Context,
                        _getCell: *const ValueFn(Self),
                        _cell: Self,
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

        pub fn deinit(self: *Self) void {
            if (comptime !is_source) return;
            if (self.deinitCellValue) |deinit_fn| {
                deinit_fn(self);
            }
        }

        /// Replace the value outright (the keep-latest write). **Source-only.**
        /// `formula.set(…)` is a comptime error — the kernel's write protection
        /// (§3/§4) realized with Zig comptime rather than a trait:
        ///
        /// ```zig
        /// // const f = try formula(i32, ctx, computeFn, null);
        /// // f.set(2);  // => error: `set` is only available on a SourceCell ...
        /// ```
        pub fn set(self: *Self, new_value: T) void {
            if (comptime !is_source) @compileError("`set` is only available on a SourceCell; a FormulaCell is computed from upstream and cannot be written");
            self.ctx.mutex.lock();

            // Only emit change if the value actually changed.
            if (std.meta.eql(self.value, new_value)) {
                self.ctx.mutex.unlock();
                return;
            }

            self.value = new_value;
            self.slot.emitChangeUnlocked();

            // The recompute drain below re-enters the context, so unlock here.
            self.ctx.mutex.unlock();

            // While inside a `batch(run)` boundary, defer the eager-recompute
            // flush so N `set` calls coalesce into one driven-formula/Effect
            // rerun at the outermost batch exit (`reactive-graph.md` § batch).
            //
            // Store-without-cascade: skip the drain entirely when nothing is
            // pending — a `set` whose cone held no driven formula / Effect
            // leaves `pending_recompute` empty (mirrors lazily-rs `set_cell`,
            // which only flushes when the cone actually contained an Effect).
            if (!self.ctx.isBatching() and self.ctx.pending_recompute.items.len > 0) {
                self.ctx.drainPendingRecompute();
            }
        }

        /// Fold `op` into the current value under the kind's policy marker `M`.
        /// **Source-only.** `SourceCell(T) ≡ SourceCell(T, KeepLatest)`, whose
        /// merge is a replace; `SourceCell(T, SumPolicy)` accumulates, etc.
        /// Routes through the ==-guarded `set`, so an idempotent policy's no-op
        /// merge fires no cascade (free dedup).
        pub fn merge(self: *Self, op: T) void {
            if (comptime !is_source) @compileError("`merge` is only available on a SourceCell");
            const p = comptime K.Policy.policy(T);
            self.set(p.merge(self.value, op));
        }

        // ---- formula-only lifecycle (drive/undrive) -----------------------

        /// **Drive** this formula: make it eager. Attaches the eager-recompute
        /// puller so the value re-materializes after every invalidation (through
        /// the batch-gated flush, so N writes coalesce into one recompute —
        /// the `#lzsignaleager` clause-3 property). Idempotent — a second
        /// `drive` is a no-op — and returns the **same** handle (mutated graph
        /// state), so the caller keeps reading the formula it already holds.
        /// This is the eager construction that retires the former `Signal`.
        pub fn drive(self: *Self) *Self {
            if (comptime is_source) @compileError("`drive` is only available on a FormulaCell; a SourceCell is already eager (its value is set from outside)");
            if (!self.slot.driven) {
                @import("signal.zig").installEagerHooks(T, self.slot) catch {
                    // Reservation failed: leave the formula lazy rather than
                    // installing a puller that could drop an enqueue. `drive`
                    // stays a no-op; the value is still correct on read.
                    return self;
                };
                self.slot.driven = true;
                self.ctx.recordDriven(self.slot);
            }
            return self;
        }

        /// Reverse of `drive`: stop eager recomputation and remove the puller.
        /// The value stays readable and reverts to lazy. No-op if not driven.
        pub fn undrive(self: *Self) void {
            if (comptime is_source) @compileError("`undrive` is only available on a FormulaCell");
            self.undriveInternal();
        }

        fn undriveInternal(self: *Self) void {
            if (comptime is_source) return;
            if (!self.slot.driven) return;
            @import("signal.zig").removeEagerHooks(self.slot);
            self.slot.driven = false;
            self.ctx.forgetDriven(self.slot);
        }

        /// Whether this formula is currently driven (has an active puller).
        pub fn isDriven(self: *const Self) bool {
            if (comptime is_source) return false;
            return self.slot.driven;
        }

        // -- Retired-`Signal` compatibility shims ---------------------------
        // A driven `FormulaCell` is what `Signal` used to be; these keep the
        // former handle's surface (`is_active`, `dispose`) working.

        /// Compat alias for the retired `Signal.is_active` — true while driven.
        pub fn is_active(self: *const Self) bool {
            return self.isDriven();
        }

        /// Compat alias for the retired `Signal.dispose` — undrive + detach.
        pub fn dispose(self: *Self) void {
            self.disposeNode();
        }
    };
}

/// A cell written from outside, folding writes under policy marker `M`
/// (default `KeepLatest`). `SourceCell(T)` is a plain input cell;
/// `SourceCell(T, SumPolicy)` folds additively; etc. Subsumes the former plain
/// `Cell` and `MergeCell`.
pub fn SourceCell(comptime T: type) type {
    return Cell(T, Source(KeepLatest));
}

/// `SourceCell` with an explicit merge-policy marker (`KeepLatest` / `SumPolicy`
/// / `MaxPolicy`). `SourceCellWith(T, KeepLatest) == SourceCell(T)`.
pub fn SourceCellWith(comptime T: type, comptime M: type) type {
    return Cell(T, Source(M));
}

/// A cell computed from upstream. Lazy + guarded by default; `formula().drive()`
/// makes it eager (a driven formula). Replaces the former `Slot`-as-value and
/// `Signal`.
pub fn FormulaCell(comptime T: type) type {
    return Cell(T, Formula);
}

// -- Constructors (§9.3) ----------------------------------------------------

/// Construct a `SourceCell(T)` (KeepLatest). The canonical source constructor;
/// subsumes the former `cell`/`merge_cell`. Reads via `get`, writes via
/// `set`/`merge`.
pub fn source(
    comptime T: type,
    ctx: *Context,
    comptime valueFn: *const ValueFn(T),
    comptime deinitFn: ?DeinitCellValueFn(T),
) !*SourceCell(T) {
    return SourceCell(T).init(ctx, valueFn, deinitFn);
}

/// `source` with an explicit policy marker `M` (subsumes the former
/// `merge_cell`). `sourceWith(T, KeepLatest, …)` == `source(T, …)`.
pub fn sourceWith(
    comptime T: type,
    comptime M: type,
    ctx: *Context,
    comptime valueFn: *const ValueFn(T),
    comptime deinitFn: ?SourceCellWith(T, M).DeinitFn,
) !*SourceCellWith(T, M) {
    return SourceCellWith(T, M).init(ctx, valueFn, deinitFn);
}

/// `source` with a caller-supplied cache key. See `SourceCell(T).initKeyed`.
pub fn sourceKeyed(
    comptime T: type,
    ctx: *Context,
    cache_key: usize,
    comptime valueFn: *const ValueFn(T),
    comptime deinitFn: ?DeinitCellValueFn(T),
) !*SourceCell(T) {
    return SourceCell(T).initKeyed(ctx, cache_key, valueFn, deinitFn);
}

/// Construct a `FormulaCell(T)` — a guarded, lazy derived value. `.drive()` it
/// for eager materialization. Built over the backing storage `Slot` (§5.0), the
/// same node `slot()` returns as a raw value; `formula` is the handle form that
/// carries the kernel surface (`get`/`drive`/`undrive`/`dispose`).
pub fn formula(
    comptime T: type,
    ctx: *Context,
    comptime valueFn: *const ValueFn(T),
    comptime deinitPayload: ?DeinitPayloadFn,
) !*FormulaCell(T) {
    return formulaKeyed(T, ctx, valueFnCacheKey(valueFn), valueFn, deinitPayload);
}

/// `formula` with a caller-supplied cache key, mirroring `slotKeyed`.
pub fn formulaKeyed(
    comptime T: type,
    ctx: *Context,
    cache_key: usize,
    valueFn: *const ValueFn(T),
    deinitPayload: ?DeinitPayloadFn,
) !*FormulaCell(T) {
    // Establish the backing slot (initial dependency edges + memo cache).
    _ = try slotKeyed(T, ctx, cache_key, valueFn, deinitPayload);
    const slot_ptr = ctx.cacheLookup(cache_key) orelse return error.SlotNotFound;
    const self = try ctx.allocator.create(FormulaCell(T));
    self.* = .{
        .ctx = ctx,
        .slot = slot_ptr,
        .value = {},
        .deinitCellValue = {},
    };
    return self;
}

// -- Backward-compatible aliases (former vocabulary) ------------------------

/// Deprecated alias for `source` — the plain source constructor. Prefer
/// `source(...)`. Kept so existing `cell(...)` call sites keep compiling.
pub fn cell(
    comptime T: type,
    ctx: *Context,
    comptime valueFn: *const ValueFn(T),
    comptime deinitFn: ?DeinitCellValueFn(T),
) !*SourceCell(T) {
    return SourceCell(T).init(ctx, valueFn, deinitFn);
}

/// Deprecated alias for `sourceKeyed`.
pub fn cellKeyed(
    comptime T: type,
    ctx: *Context,
    cache_key: usize,
    comptime valueFn: *const ValueFn(T),
    comptime deinitFn: ?DeinitCellValueFn(T),
) !*SourceCell(T) {
    return SourceCell(T).initKeyed(ctx, cache_key, valueFn, deinitFn);
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
    return fn (*Context) anyerror!*SourceCell(T);
}

pub fn initCellFn(
    comptime T: type,
    comptime valueFn: ValueFn(T),
    comptime deinitCellValue: ?DeinitCellValueFn(T),
) *const CellFn(T) {
    return struct {
        fn call(ctx: *Context) anyerror!*SourceCell(T) {
            return source(T, ctx, valueFn, deinitCellValue);
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

    const counter = try SourceCell(i32).init(ctx, struct {
        fn call(_: *Context) anyerror!i32 {
            return 0;
        }
    }.call, null);

    const num_threads = 4;
    const increments_per_thread = 1000;
    var threads: [num_threads]std.Thread = undefined;

    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(_cell: *SourceCell(i32), count: usize) void {
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

// Depth-3 chain used by the OOM-cascade regression test below. Declared at
// file scope so each level is a distinct, stable cache key.
const CascadeOomChain = struct {
    var src_val: u32 = 1;

    fn getSource(_ctx: *Context) !u32 {
        _ = _ctx;
        return src_val;
    }
    const srcCell = initCellFn(u32, getSource, null);

    fn getA(_ctx: *Context) !u32 {
        return (try srcCell(_ctx)).get() + 10;
    }
    const a = initSlotFn(u32, getA, null);

    fn getB(_ctx: *Context) !u32 {
        return (try a(_ctx)).* + 100;
    }
    const b = initSlotFn(u32, getB, null);

    fn getC(_ctx: *Context) !u32 {
        return (try b(_ctx)).* + 1000;
    }
    const c = initSlotFn(u32, getC, null);
};

test "lazily/cell: OOM growing the cascade worklist must not strand a dependent subgraph" {
    // Regression guard for the `wl.append(...) catch {}` that used to sit in
    // `emitChangeUnlocked`/`drainCascadeWorklist`. Swallowing that failure
    // dropped a dependent from the invalidation cascade, and because
    // `drainCascadeWorklist` short-circuits on `node.stale` the whole subgraph
    // below it stayed fresh-but-wrong forever. The fix degrades to
    // `cascadeFallbackMarkAllStaleUnlocked` instead.
    const S = CascadeOomChain;
    const backing = std.testing.allocator;
    const ctx = try Context.init(backing);
    defer ctx.deinit();

    S.src_val = 1;
    try std.testing.expectEqual(@as(u32, 1111), (try S.c(ctx)).*);

    // Force the very next allocation — the cascade worklist growth — to fail.
    var failing = std.testing.FailingAllocator.init(backing, .{ .fail_index = 0 });
    ctx.allocator = failing.allocator();

    S.src_val = 2;
    (try S.srcCell(ctx)).set(2);

    ctx.allocator = backing;

    try std.testing.expect(failing.has_induced_failure);

    // The invariant holds: every level below the cell is stale, including the
    // deepest one the dropped push would have stranded. This is the assertion
    // that actually fails against the old `catch {}`.
    try std.testing.expect(ctx.getSlot(S.getA).?.stale);
    try std.testing.expect(ctx.getSlot(S.getB).?.stale);
    try std.testing.expect(ctx.getSlot(S.getC).?.stale);

    // The cascade degraded observably rather than silently.
    try std.testing.expectEqual(@as(u64, 1), ctx.cascade_oom_fallbacks);

    // And the observable value is correct on the next read.
    try std.testing.expectEqual(@as(u32, 1112), (try S.c(ctx)).*);
    try std.testing.expectEqual(@as(usize, 0), ctx.cascade_scratch.items.len);
}

// `invalidateSlotUnlocked`'s seed push had the same hole its own drain loop and
// `emitChangeUnlocked` already closed — and worse placed: the function's early
// `if (self.stale) return` means `stale` is still false when the push happens,
// so a dropped seed left the slot itself, not just its cone, fresh-but-wrong.

const InvalidateSeedOomChain = struct {
    var src_val: u32 = 0;

    fn getA(_: *Context) anyerror!u32 {
        return src_val;
    }
    fn getB(c: *Context) anyerror!u32 {
        return (try @import("slot.zig").slot(u32, c, getA, null)).* + 100;
    }
};

test "lazily/cell: OOM seeding an invalidation must not leave the slot fresh-but-wrong" {
    const S = InvalidateSeedOomChain;
    const backing = std.testing.allocator;
    const ctx = try Context.init(backing);
    defer ctx.deinit();

    S.src_val = 1;
    try std.testing.expectEqual(@as(u32, 101), (try @import("slot.zig").slot(u32, ctx, S.getB, null)).*);

    const a = ctx.getSlot(S.getA).?;
    try std.testing.expect(!a.stale);

    var failing = std.testing.FailingAllocator.init(backing, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    ctx.allocator = failing.allocator();
    ctx.mutex.lock();
    a.invalidateSlotUnlocked();
    ctx.mutex.unlock();
    ctx.allocator = backing;

    try std.testing.expect(failing.has_induced_failure);

    // The assertions that fail against the old bare `catch return`: the slot
    // that was being invalidated is stale, and so is its dependent. Under the
    // old code BOTH stayed false and nothing would ever retry.
    try std.testing.expect(a.stale);
    try std.testing.expect(ctx.getSlot(S.getB).?.stale);

    // And the next read is correct.
    S.src_val = 5;
    try std.testing.expectEqual(@as(u32, 105), (try @import("slot.zig").slot(u32, ctx, S.getB, null)).*);

    try std.testing.expectEqual(@as(u64, 1), ctx.cascade_oom_fallbacks);
}

// ---------------------------------------------------------------------------
// Cell kernel tests (`#lzcellkernel`)
// ---------------------------------------------------------------------------

test "lazily/cell kernel: SourceCell handle stays 32 bytes; driven bit is free" {
    // The earlier observer removal got the source-cell handle to 32B; the
    // kernel migration must not regrow it. The driven bit lives on the storage
    // `Slot` (in its existing tail padding, `@sizeOf(Slot)` unchanged), not on
    // this handle, so a FormulaCell carries no inline value and is leaner still.
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(SourceCell(i32)));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(FormulaCell(i32)));
    // Kind is compile-time; sanity-check the markers.
    try std.testing.expect(SourceCell(i32).is_source_cell);
    try std.testing.expect(!FormulaCell(i32).is_source_cell);
}

// A FormulaCell has no `set`/`merge`/`init` — those are guarded by comptime
// `@compileError` on the source kind (§3/§4). Zig's `zig build test` has no
// built-in compile-fail harness, so the guarantee is documented here and the
// guard verified manually: uncommenting either line below fails to compile with
// "`set` is only available on a SourceCell ...":
//
//     const f = try formula(i32, ctx, computeFn, null);
//     f.set(2);          // error: `set` is only available on a SourceCell ...
//     _ = source(i32, ...).drive();   // error: `drive` is only available on a FormulaCell ...
//
// The positive side (writes work on SourceCell, drive works on FormulaCell) is
// exercised by the tests below and across the suite.

const KernelChain = struct {
    var base: i32 = 0;
    fn getBase(_: *Context) anyerror!i32 {
        return base;
    }
    const baseCell = initCellFn(i32, getBase, null);
    fn getDoubled(c: *Context) anyerror!i32 {
        return (try baseCell(c)).get() * 2;
    }
};

test "lazily/cell kernel: source/formula/get — the genus reads uniformly" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    KernelChain.base = 3;
    const n = try source(i32, ctx, KernelChain.getBase, null);
    try std.testing.expectEqual(@as(i32, 3), n.get());

    // A formula computed from the source — read with the same `get`. For a
    // value type `get` returns `Slot.Result(T)` (`*T` here), matching the
    // former `Signal.get`; deref for the value.
    const doubled = try formula(i32, ctx, KernelChain.getDoubled, null);
    defer ctx.allocator.destroy(doubled);
    try std.testing.expectEqual(@as(i32, 6), doubled.get().*);
    try std.testing.expect(!doubled.isDriven());

    // set flows through to dependents (pulled lazily).
    n.set(5);
    try std.testing.expectEqual(@as(i32, 10), doubled.get().*);
}

test "lazily/cell kernel: SourceCell(T, SumPolicy) folds; merge subsumes MergeCell" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const acc = try sourceWith(i64, SumPolicy, ctx, struct {
        fn f(_: *Context) anyerror!i64 {
            return 0;
        }
    }.f, null);
    for ([_]i64{ 1, 2, 3, 4 }) |d| acc.merge(d);
    try std.testing.expectEqual(@as(i64, 10), acc.get());

    // KeepLatest merge is a replace (Cell ≡ MergeCell(KeepLatest)).
    const kl = try source(i32, ctx, struct {
        fn f(_: *Context) anyerror!i32 {
            return 0;
        }
    }.f, null);
    kl.merge(7);
    try std.testing.expectEqual(@as(i32, 7), kl.get());
}

// Clause-3 eager coalescing (`#lzsignaleager`): a **driven** formula
// materializes once per batch, not once per write. This is the property a
// binding shipped a per-write puller against; `formula().drive()` reuses the
// batch-gated flush so it holds structurally.
const DrivenBatch = struct {
    var runs = std.atomic.Value(usize).init(0);
    const getA = struct {
        fn call(_: *Context) anyerror!u32 {
            return 0;
        }
    }.call;
    const getB = struct {
        fn call(_: *Context) anyerror!u32 {
            return 0;
        }
    }.call;
    fn getDerived(c: *Context) anyerror!u32 {
        _ = try cell(u32, c, getA, null);
        _ = try cell(u32, c, getB, null);
        _ = runs.fetchAdd(1, .seq_cst);
        return 0;
    }
    fn runBatch(c: *Context) void {
        const a = cell(u32, c, getA, null) catch return;
        const b = cell(u32, c, getB, null) catch return;
        a.set(10);
        b.set(20);
        a.set(11);
    }
};

test "lazily/cell kernel: driven formula materializes once per batch (clause 3)" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    DrivenBatch.runs.store(0, .seq_cst);
    const f = try formula(u32, ctx, DrivenBatch.getDerived, null);
    defer ctx.allocator.destroy(f);

    // Not eager yet — one compute at construction.
    try std.testing.expectEqual(@as(usize, 1), DrivenBatch.runs.load(.seq_cst));
    try std.testing.expect(!f.isDriven());

    // drive() is idempotent and returns the same handle (mutated graph state).
    const g = f.drive();
    try std.testing.expect(g == f);
    try std.testing.expect(f.isDriven());
    _ = f.drive(); // no-op; still one driver
    try std.testing.expect(f.slot.driven);

    // 3 writes inside one batch → exactly one eager recompute at flush.
    ctx.batch(DrivenBatch.runBatch);
    try std.testing.expectEqual(@as(usize, 2), DrivenBatch.runs.load(.seq_cst));

    // undrive reverts to lazy and clears the bit + side table entry.
    f.undrive();
    try std.testing.expect(!f.isDriven());
    try std.testing.expect(!f.slot.driven);
    try std.testing.expect(ctx.driven_by.count() == 0);
}
