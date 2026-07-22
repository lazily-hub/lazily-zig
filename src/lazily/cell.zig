const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Context = @import("context.zig").Context;
const Owned = @import("context.zig").Owned;
const OwnedString = @import("context.zig").OwnedString;
const Slot = @import("context.zig").Slot;
const String = @import("context.zig").String;
const ValueFn = @import("context.zig").ValueFn;
const normalizeValueFn = @import("context.zig").normalizeValueFn;
const valueFnCacheKey = @import("context.zig").valueFnCacheKey;
const deinitSlotValue = @import("slot.zig").deinitSlotValue;
const slot = @import("slot.zig").slot;
const slotKeyed = @import("slot.zig").slotKeyed;
const initSlotFn = @import("slot.zig").initSlotFn;
const DeinitPayloadFn = Slot.DeinitPayloadFn;
const slotEventLog = @import("test.zig").slotEventLog;
const expectEventLog = @import("test.zig").expectEventLog;

// ---------------------------------------------------------------------------
// The Cell kernel (`#lzcellkernel`) — the two concrete handle structs
// `Source(T[, M])` and `Computed(T)`.
//
// See `tasks/software/lazily-cell-kernel-design.md`. **`Cell` is a conceptual
// word, not a type**: a *cell* is a value-bearing reactive node, and the two
// kinds of cell are named by the two handles a caller holds:
//
//   Source(T, M)                  handle to a source cell — written from
//                                 outside; folds under merge policy M
//   Computed(T)                   handle to a computed cell — computed from
//                                 upstream (guarded; `.eager()` = eager)
//
//   Effect                        no value; sink — outside the hierarchy
//
// There is **no `Cell(T, K)` genus struct** and no `Source(M)` / `Formula`
// *kind markers*: the former genus dissolves into these two concrete structs,
// and `M` is now `Source`'s own policy parameter. A single private
// comptime factory (`CellHandle`) still shares the read/dispose implementation
// between them — an impl detail, not a public handle.
//
// `Slot` keeps its *storage* meaning (§5.0): it is the arena position that
// holds a node of any kind, so `Slot`, `SlotId`, and the slab vocabulary stay.
// The raw `slot()` primitive is the deliberately non-guarded storage escape for
// non-equatable values; it is the storage sense, not a cell.
//
// ## Write protection via comptime (§3, §4)
//
// Reads live on both handles (`get`). `set`/`merge` are guarded by a comptime
// `@compileError` on the computed handle, so `computed.set(…)` does not
// compile — the same guarantee the Rust binding gets from a missing method on
// `Computed<T>`, realized here with Zig comptime. See the `computed.set()`
// compile-fail note on `set` and the positive tests below.
//
// ## Guard (§3, final 2026-07-21)
//
// All cells are guarded, always. `Source` suppresses an equal *write* (the
// `==` store-guard in `set`); `Computed` suppresses an equal *recompute* (the
// storage-layer equality guard, matching TC39 `Signal.Computed`). There is no
// unguarded mode and no separate `memo` — a guarded `computed` subsumes it.
// ---------------------------------------------------------------------------

/// Per-instantiation cleanup hook for a `Source`'s stored value. Retained under
/// the historical name; every non-null user is internal (all external call
/// sites pass `null`).
pub fn DeinitCellValueFn(comptime T: type) type {
    return *const fn (*Source(T)) void;
}
pub fn ChangeCallback(comptime T: type) type {
    return *const fn (*Source(T)) void;
}

// -- Merge-policy markers ---------------------------------------------------

/// Merge-policy marker for the last-writer-wins band — the policy behind a
/// plain source cell (`Source(T) ≡ SourceCellWith(T, KeepLatest)`).
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

// -- The private shared factory ---------------------------------------------

/// Private comptime factory shared by the two public handles. `is_source`
/// selects the source arm (inline value + `set`/`merge`) or the computed arm
/// (reads through the backing storage `Slot`); `M` is the source merge policy
/// (ignored on the computed arm). NOT exported — callers spell `Source(T)` /
/// `SourceCellWith(T, M)` / `Computed(T)`.
fn CellHandle(comptime T: type, comptime is_source: bool, comptime M: type) type {
    return struct {
        const Self = @This();

        /// The value type this cell reads.
        pub const Value = T;
        /// The source merge policy (meaningful only on the source arm).
        pub const Policy = M;
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
        // computed cells read from their backing `Slot`, so carry no value here.
        // `@sizeOf(Source(i32)) == 32` is asserted below and must not grow.
        value: if (is_source) T else void,
        deinitCellValue: if (is_source) ?DeinitFn else void,

        pub const MissingCurrentSlotError = error{MissingCurrentSlot};

        // ---- shared reads (every kind) ------------------------------------

        /// Read this cell's current value. Source cells return the inline value;
        /// computed cells return their backing slot's materialized value
        /// (`Slot.Result(T)` — `T` for value types, `*T` for indirect).
        pub fn get(self: *const Self) if (is_source) T else Slot.Result(T) {
            if (comptime is_source) {
                return self.value;
            } else {
                // Re-materialize through the storage layer (`slotKeyed`) rather
                // than reading `slot.storage` directly: a lazy computed cell
                // whose upstream changed is `stale`, and `Slot.get` reads storage
                // without consulting `stale` (see signal.zig). Routing through
                // `slotKeyed` recomputes when stale, registers the dependency
                // when read inside another reactive computation, and — for an
                // eager computed cell (kept fresh in place) — returns the cached
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

        /// Computed-only: recompute-on-read through the storage `Slot` keyed by
        /// this handle's identity.
        fn materialize(self: *const Self) Slot.Result(T) {
            const vfn: *const ValueFn(T) = @ptrCast(@alignCast(self.slot.value_fn_ptr.?));
            return slotKeyed(T, self.ctx, self.slot.cache_key.?, vfn, self.slot.deinitPayload) catch unreachable;
        }

        pub fn handle(self: *const Self) Context.NodeHandle {
            return .{ .key = self.slot.cache_key.? };
        }

        /// Tear this node out of the graph. Kind-agnostic — a disposed eager
        /// computed cell also tears down its puller (the computed arm clears the
        /// eager bit + side table first).
        pub fn disposeNode(self: *Self) void {
            if (comptime !is_source) {
                // Disposing an eager computed cell must not strand its puller.
                if (self.slot.eager) self.lazyInternal();
            }
            self.ctx.disposeNode(self.handle());
        }

        // ---- source-only construction + writes (§3) -----------------------

        pub fn init(
            ctx: *Context,
            comptime valueFn: anytype,
            comptime deinitCellValue: ?DeinitFn,
        ) !*Self {
            if (comptime !is_source) @compileError("init is only available on a Source; build a Computed with `computed(...)`");
            // Key by the ORIGINAL closure so `getSlot(fn)` / explicit re-keying
            // stays stable across normalization (`#lzcellkernel`); the stored
            // callable is the normalized `*Compute` form.
            return initKeyed(ctx, valueFnCacheKey(valueFn), valueFn, deinitCellValue);
        }

        /// `init` with a caller-supplied cache key, mirroring `slotKeyed`.
        /// Needed wherever one comptime `valueFn` must back many distinct nodes
        /// — including a disposed cell's replacement, which must be a *new* node
        /// rather than a resurrection of the tombstone.
        pub fn initKeyed(
            ctx: *Context,
            cache_key: usize,
            comptime valueFn: anytype,
            comptime deinitCellValue: ?DeinitFn,
        ) !*Self {
            if (comptime !is_source) @compileError("initKeyed is only available on a Source");
            const nf = comptime normalizeValueFn(T, valueFn);
            const getCell = struct {
                fn call(c: *Compute) anyerror!Self {
                    // The cell's OWN slot is value-threaded in as `c.node`; no
                    // ambient lookup (`#lzcellkernel`). A source `valueFn`
                    // ignores `c`; a reader would track via `c.get`.
                    const initial_value = try nf(c);
                    return Self{
                        .ctx = c.untracked(),
                        .slot = c.node,
                        .value = initial_value,
                        .deinitCellValue = deinitCellValue,
                    };
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
        /// `computed.set(…)` is a comptime error — the kernel's write protection
        /// (§3/§4) realized with Zig comptime rather than a trait:
        ///
        /// ```zig
        /// // const f = try computed(i32, ctx, computeFn, null);
        /// // f.set(2);  // => error: `set` is only available on a Source ...
        /// ```
        pub fn set(self: *Self, new_value: T) void {
            if (comptime !is_source) @compileError("`set` is only available on a Source; a Computed is computed from upstream and cannot be written");
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
            // flush so N `set` calls coalesce into one eager-computed/Effect
            // rerun at the outermost batch exit (`reactive-graph.md` § batch).
            //
            // Store-without-cascade: skip the drain entirely when nothing is
            // pending — a `set` whose cone held no eager computed cell / Effect
            // leaves `pending_recompute` empty (mirrors lazily-rs `set_cell`,
            // which only flushes when the cone actually contained an Effect).
            if (!self.ctx.isBatching() and self.ctx.pending_recompute.items.len > 0) {
                self.ctx.drainPendingRecompute();
            }
        }

        /// Fold `op` into the current value under the source's policy `M`.
        /// **Source-only.** `Source(T) ≡ SourceCellWith(T, KeepLatest)`, whose
        /// merge is a replace; `SourceCellWith(T, SumPolicy)` accumulates, etc.
        /// Routes through the ==-guarded `set`, so an idempotent policy's no-op
        /// merge fires no cascade (free dedup).
        pub fn merge(self: *Self, op: T) void {
            if (comptime !is_source) @compileError("`merge` is only available on a Source");
            const p = comptime M.policy(T);
            self.set(p.merge(self.value, op));
        }

        // ---- computed-only lifecycle (eager/lazy) -------------------------

        /// Transition this computed cell to **eager**. Attaches the
        /// eager-recompute puller so the value re-materializes after every
        /// invalidation (through the batch-gated flush, so N writes coalesce
        /// into one recompute — the `#lzsignaleager` clause-3 property).
        /// Idempotent — a second `eager` is a no-op — and returns the **same**
        /// handle (mutated graph state), so the caller keeps reading the
        /// computed cell it already holds. This is the eager construction that
        /// retires the former `Signal`.
        pub fn eager(self: *Self) *Self {
            if (comptime is_source) @compileError("`eager` is only available on a Computed; a Source is already eager (its value is set from outside)");
            if (!self.slot.eager) {
                @import("signal.zig").installEagerHooks(T, self.slot) catch {
                    // Reservation failed: leave the computed cell lazy rather
                    // than installing a puller that could drop an enqueue.
                    // `eager` stays a no-op; the value is still correct on read.
                    return self;
                };
                self.slot.eager = true;
                self.ctx.recordEager(self.slot);
            }
            return self;
        }

        /// Reverse of `eager`: stop eager recomputation and remove the puller.
        /// The value stays readable and reverts to lazy. No-op if not eager.
        pub fn lazy(self: *Self) void {
            if (comptime is_source) @compileError("`lazy` is only available on a Computed");
            self.lazyInternal();
        }

        fn lazyInternal(self: *Self) void {
            if (comptime is_source) return;
            if (!self.slot.eager) return;
            @import("signal.zig").removeEagerHooks(self.slot);
            self.slot.eager = false;
            self.ctx.forgetEager(self.slot);
        }

        /// Whether this computed cell is currently eager (has an active puller).
        pub fn isEager(self: *const Self) bool {
            if (comptime is_source) return false;
            return self.slot.eager;
        }

        /// Tear this node out of the graph. Alias for `disposeNode`, matching
        /// the Rust binding's `Computed::dispose`/`Source::dispose`. To merely
        /// stop eager recomputation without removing the node, use `lazy`.
        pub fn dispose(self: *Self) void {
            self.disposeNode();
        }
    };
}

/// Handle to a **source cell** — written from outside, folding writes under
/// merge policy `M` (default `KeepLatest`). `Source(T)` is a plain input cell;
/// `SourceCellWith(T, SumPolicy)` folds additively; etc. Subsumes the former
/// plain `Cell` and `MergeCell`.
pub fn Source(comptime T: type) type {
    return CellHandle(T, true, KeepLatest);
}

/// `Source` with an explicit merge-policy marker (`KeepLatest` / `SumPolicy`
/// / `MaxPolicy`). `SourceCellWith(T, KeepLatest) == Source(T)`.
pub fn SourceCellWith(comptime T: type, comptime M: type) type {
    return CellHandle(T, true, M);
}

/// Handle to a **computed cell** — computed from upstream. Lazy + guarded by
/// default; `computed().eager()` makes it eager (an eager computed cell).
/// Replaces the former `Slot`-as-value and `Signal`.
pub fn Computed(comptime T: type) type {
    return CellHandle(T, false, KeepLatest);
}

// -- Constructors (§9.3) ----------------------------------------------------

/// Construct a `Source(T)` (KeepLatest). The canonical source constructor;
/// subsumes the former `cell`/`merge_cell`. Reads via `get`, writes via
/// `set`/`merge`.
pub fn source(
    comptime T: type,
    ctx: *Context,
    comptime valueFn: anytype,
    comptime deinitFn: ?DeinitCellValueFn(T),
) !*Source(T) {
    return Source(T).init(ctx, valueFn, deinitFn);
}

/// `source` with an explicit policy marker `M` (subsumes the former
/// `merge_cell`). `sourceWith(T, KeepLatest, …)` == `source(T, …)`.
pub fn sourceWith(
    comptime T: type,
    comptime M: type,
    ctx: *Context,
    comptime valueFn: anytype,
    comptime deinitFn: ?SourceCellWith(T, M).DeinitFn,
) !*SourceCellWith(T, M) {
    return SourceCellWith(T, M).init(ctx, valueFn, deinitFn);
}

/// `source` with a caller-supplied cache key. See `Source(T).initKeyed`.
pub fn sourceKeyed(
    comptime T: type,
    ctx: *Context,
    cache_key: usize,
    comptime valueFn: anytype,
    comptime deinitFn: ?DeinitCellValueFn(T),
) !*Source(T) {
    return Source(T).initKeyed(ctx, cache_key, valueFn, deinitFn);
}

/// Construct a `Computed(T)` — a guarded, lazy derived value. `.eager()` it
/// for eager materialization. Built over the backing storage `Slot` (§5.0), the
/// same node `slot()` returns as a raw value; `computed` is the handle form that
/// carries the kernel surface (`get`/`eager`/`lazy`/`dispose`). Guarded by
/// default: an equal recompute suppresses the downstream cascade (the
/// storage-layer equality guard), matching TC39 `Signal.Computed`.
pub fn computed(
    comptime T: type,
    ctx: *Context,
    comptime valueFn: anytype,
    comptime deinitPayload: ?DeinitPayloadFn,
) !*Computed(T) {
    const nf = comptime normalizeValueFn(T, valueFn);
    return computedKeyed(T, ctx, valueFnCacheKey(valueFn), nf, deinitPayload);
}

/// `computed` with a caller-supplied cache key, mirroring `slotKeyed`. Takes a
/// runtime `*Compute` closure (already normalized) so one comptime body can back
/// N distinct nodes via distinct keys (dispatched through a runtime array).
pub fn computedKeyed(
    comptime T: type,
    ctx: *Context,
    cache_key: usize,
    valueFn: *const ValueFn(T),
    deinitPayload: ?DeinitPayloadFn,
) !*Computed(T) {
    // Establish the backing slot (initial dependency edges + guard cache).
    _ = try slotKeyed(T, ctx, cache_key, valueFn, deinitPayload);
    const slot_ptr = ctx.cacheLookup(cache_key) orelse return error.SlotNotFound;
    const self = try ctx.allocator.create(Computed(T));
    self.* = .{
        .ctx = ctx,
        .slot = slot_ptr,
        .value = {},
        .deinitCellValue = {},
    };
    return self;
}

/// Construct a **guarded computed cell** with an explicit change predicate
/// (`#lzcellkernel`) — the propagate-guard escape hatch.
///
/// Like [`computed`], but the downstream cascade is gated by `changed(old, new)`
/// instead of the value's natural `std.meta.eql`: `changed` returns `true` to
/// **propagate** the recompute to dependents and `false` to **suppress** it
/// (treat it as "no meaningful change"). So:
///
///   - `computed(f)` == `computedRippleWhen(f, |o, n| o.* != n.*)` (natural
///     equality), and
///   - the unguarded `slot(f)` == `computedRippleWhen(f, |_, _| true)` (always
///     propagate — the pass-through).
///
/// Use it for a **custom significance policy**: dedup a large value by a
/// version/hash field, epsilon float compare, hysteresis, a monotonic gate, or
/// "propagate every N" when the counter lives in the value.
///
/// The value is **always computed and published** (the predicate needs `new`);
/// `changed` gates only the downstream cascade, never the computation or the
/// stored value. Returned **eager**: the propagate guard runs on the eager
/// recompute path (`makeRecomputeFn`), which is where the storage-layer guard
/// lives — a purely lazy node has no cascade to suppress.
///
/// `changed` MUST be a **pure** function of `(old, new)`. Reading value-carried
/// state (a version/counter/sequence embedded in `T`) is fine and stays
/// deterministic; capturing external mutable state is not — it would key off
/// recompute/read frequency under laziness and break determinism.
pub fn computedRippleWhen(
    comptime T: type,
    ctx: *Context,
    comptime valueFn: anytype,
    comptime changed: *const fn (old: *const T, new: *const T) bool,
    comptime deinitPayload: ?DeinitPayloadFn,
) !*Computed(T) {
    const nf = comptime normalizeValueFn(T, valueFn);
    return computedRippleWhenKeyed(T, ctx, valueFnCacheKey(valueFn), nf, changed, deinitPayload);
}

/// `computedRippleWhen` with a caller-supplied cache key, mirroring
/// `computedKeyed` vs `computed`.
pub fn computedRippleWhenKeyed(
    comptime T: type,
    ctx: *Context,
    cache_key: usize,
    comptime valueFn: anytype,
    comptime changed: *const fn (old: *const T, new: *const T) bool,
    comptime deinitPayload: ?DeinitPayloadFn,
) !*Computed(T) {
    const c = try computedKeyed(T, ctx, cache_key, comptime normalizeValueFn(T, valueFn), deinitPayload);
    // Comptime trampoline: restore `*const T` from the type-erased slot field
    // and call the caller's pure predicate. The slot is not generic over `T`.
    const erased = struct {
        fn call(old: *const anyopaque, new: *const anyopaque) bool {
            return changed(
                @as(*const T, @ptrCast(@alignCast(old))),
                @as(*const T, @ptrCast(@alignCast(new))),
            );
        }
    }.call;
    c.slot.ripple_when = &erased;
    // The propagate guard only runs on the eager recompute path, so a
    // ripple-when node is eager (it always computes; the guard gates the
    // cascade). `.eager()` returns the same handle.
    return c.eager();
}

// -- Value-threaded (fortified) constructors (`#lzcellkernel`) ---------------
//
// The primary fortified surface: the compute closure receives a `*Compute`
// (the value-threaded view carrying the recomputing node id), NOT the ambient
// `*Context`. Reads through `Compute.get` register a dependency edge against
// that node by value; the ambient thread-local frame is DETACHED for the
// duration of the closure, so it is the sole tracking surface. This mirrors
// lazily-rs `Context::computed`/`effect` taking `Fn(&Compute)` (commits
// 6209f1d + 47992d9). The legacy `computed`/`slot`/`effect` constructors that
// take `fn(*Context)` remain on the retained thread-local bridge (exactly as
// lazily-rs kept its thread-local frame for the SyncReactiveGraph closures).

const Compute = @import("context.zig").Compute;

/// The value-threaded compute closure type: receives the fortified `*Compute`
/// view instead of the ambient `*Context`. Now identical to the canonical
/// `ValueFn(T)` — the ambient path is gone, so every compute closure is
/// value-threaded (`#lzcellkernel`).
pub fn ComputeFn(comptime T: type) type {
    return fn (*Compute) anyerror!T;
}

/// `computedC` is now just `computed` — the canonical constructor already takes
/// a `*Compute` closure (or auto-wraps a legacy `fn(*Context)` source). Kept as
/// an alias so existing `computedC(...)` call sites keep compiling.
pub fn computedC(
    comptime T: type,
    ctx: *Context,
    comptime computeFn: *const ComputeFn(T),
    comptime deinitPayload: ?DeinitPayloadFn,
) !*Computed(T) {
    return computed(T, ctx, computeFn, deinitPayload);
}

/// `computedRippleWhenC` is now just `computedRippleWhen` (value-threaded
/// compute + custom propagate guard). Alias kept for call-site compatibility.
pub fn computedRippleWhenC(
    comptime T: type,
    ctx: *Context,
    comptime computeFn: *const ComputeFn(T),
    comptime changed: *const fn (old: *const T, new: *const T) bool,
    comptime deinitPayload: ?DeinitPayloadFn,
) !*Computed(T) {
    return computedRippleWhen(T, ctx, computeFn, changed, deinitPayload);
}

// -- Backward-compatible aliases (former vocabulary) ------------------------

/// Deprecated alias for `source` — the plain source constructor. Prefer
/// `source(...)`. Kept so existing `cell(...)` call sites keep compiling.
pub fn cell(
    comptime T: type,
    ctx: *Context,
    comptime valueFn: anytype,
    comptime deinitFn: ?DeinitCellValueFn(T),
) !*Source(T) {
    return Source(T).init(ctx, valueFn, deinitFn);
}

/// Deprecated alias for `sourceKeyed`.
pub fn cellKeyed(
    comptime T: type,
    ctx: *Context,
    cache_key: usize,
    comptime valueFn: anytype,
    comptime deinitFn: ?DeinitCellValueFn(T),
) !*Source(T) {
    return Source(T).initKeyed(ctx, cache_key, valueFn, deinitFn);
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
    return fn (*Context) anyerror!*Source(T);
}

pub fn initCellFn(
    comptime T: type,
    comptime valueFn: anytype,
    comptime deinitCellValue: ?DeinitCellValueFn(T),
) *const CellFn(T) {
    return struct {
        fn call(ctx: *Context) anyerror!*Source(T) {
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
        fn call(c: *Compute) !OwnedString {
            const _ctx = c.untracked();
            try (try slotEventLog(_ctx)).append("greeting|");

            const greeting = std.fmt.allocPrint(
                _ctx.allocator,
                "{s} {s}!",
                .{ c.get(try hello(_ctx)), c.get(try name(_ctx)) },
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
        fn call(c: *Compute) !OwnedString {
            const _ctx = c.untracked();
            try (try slotEventLog(_ctx)).append("greetingAndResponse|");
            const g = (try greeting(_ctx)).value;
            if (_ctx.getSlot(getGreeting)) |s| c.trackSlot(s);
            const out = OwnedString.managed(
                std.fmt.allocPrint(
                    _ctx.allocator,
                    "{s} {s}",
                    .{ g, c.get(try response(_ctx)) },
                ) catch unreachable,
            );
            return out;
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

    // Re-materialize through the pull helper (the compute closure is now
    // value-threaded and cannot be invoked bare with a `*Context`).
    try std.testing.expectEqualStrings("Hello You!", (try greeting(ctx)).value);

    try std.testing.expectEqualStrings(
        "Hello You! How are you?",
        (try greetingAndResponse(ctx)).value,
    );
    try std.testing.expect(ctx.getSlot(getName) != null);
    try std.testing.expect(ctx.getSlot(getGreeting) != null);
    try std.testing.expect(ctx.getSlot(getGreetingAndResponse) != null);
    // The value-threaded kernel recomputes `greeting` exactly once here: the
    // direct read above refreshes it, and `greetingAndResponse`'s recompute then
    // reads the fresh cached value without a redundant second recompute. (The
    // former ambient path recomputed it twice; the identical flow in
    // `examples/cells` already pins this single-recompute schedule.)
    try expectEventLog(ctx, "greeting|hello|name|greetingAndResponse|response|greeting|greetingAndResponse|");
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
            fn call(c: *Compute) anyerror!u32 {
                _ = c.get(try @import("cell.zig").cell(u32, c.untracked(), getSourceA, null));
                _ = c.get(try @import("cell.zig").cell(u32, c.untracked(), getSourceB, null));
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

    const counter = try Source(i32).init(ctx, struct {
        fn call(_: *Context) anyerror!i32 {
            return 0;
        }
    }.call, null);

    const num_threads = 4;
    const increments_per_thread = 1000;
    var threads: [num_threads]std.Thread = undefined;

    for (0..num_threads) |i| {
        threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(_cell: *Source(i32), count: usize) void {
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

    fn getA(cc: *Compute) !u32 {
        const s = try srcCell(cc.untracked());
        return cc.get(s) + 10;
    }
    const a = initSlotFn(u32, getA, null);

    fn getB(cc: *Compute) !u32 {
        const pa = try a(cc.untracked());
        if (cc.untracked().getSlot(getA)) |s| cc.trackSlot(s);
        return pa.* + 100;
    }
    const b = initSlotFn(u32, getB, null);

    fn getC(cc: *Compute) !u32 {
        const pb = try b(cc.untracked());
        if (cc.untracked().getSlot(getB)) |s| cc.trackSlot(s);
        return pb.* + 1000;
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
    fn getB(c: *Compute) anyerror!u32 {
        const pa = try @import("slot.zig").slot(u32, c.untracked(), getA, null);
        if (c.untracked().getSlot(getA)) |s| c.trackSlot(s);
        return pa.* + 100;
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

test "lazily/cell kernel: Source handle stays 32 bytes; eager bit is free" {
    // The earlier observer removal got the source-cell handle to 32B; the
    // kernel migration must not regrow it. The eager bit lives on the storage
    // `Slot` (in its existing tail padding, `@sizeOf(Slot)` unchanged), not on
    // this handle, so a Computed carries no inline value and is leaner still.
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Source(i32)));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Computed(i32)));
    // Kind is compile-time; sanity-check the markers.
    try std.testing.expect(Source(i32).is_source_cell);
    try std.testing.expect(!Computed(i32).is_source_cell);
}

// A Computed has no `set`/`merge`/`init` — those are guarded by comptime
// `@compileError` on the source kind (§3/§4). Zig's `zig build test` has no
// built-in compile-fail harness, so the guarantee is documented here and the
// guard verified manually: uncommenting either line below fails to compile with
// "`set` is only available on a Source ...":
//
//     const f = try computed(i32, ctx, computeFn, null);
//     f.set(2);          // error: `set` is only available on a Source ...
//     _ = source(i32, ...).eager();   // error: `eager` is only available on a Computed ...
//
// The positive side (writes work on Source, eager works on Computed) is
// exercised by the tests below and across the suite.

const KernelChain = struct {
    var base: i32 = 0;
    fn getBase(_: *Context) anyerror!i32 {
        return base;
    }
    const baseCell = initCellFn(i32, getBase, null);
    fn getDoubled(c: *Compute) anyerror!i32 {
        const b = try baseCell(c.untracked());
        return c.get(b) * 2;
    }
};

test "lazily/cell kernel: source/computed/get — both handles read uniformly" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    KernelChain.base = 3;
    const n = try source(i32, ctx, KernelChain.getBase, null);
    try std.testing.expectEqual(@as(i32, 3), n.get());

    // A computed cell computed from the source — read with the same `get`. For
    // a value type `get` returns `Slot.Result(T)` (`*T` here), matching the
    // former `Signal.get`; deref for the value.
    const doubled = try computed(i32, ctx, KernelChain.getDoubled, null);
    defer ctx.allocator.destroy(doubled);
    try std.testing.expectEqual(@as(i32, 6), doubled.get().*);
    try std.testing.expect(!doubled.isEager());

    // set flows through to dependents (pulled lazily).
    n.set(5);
    try std.testing.expectEqual(@as(i32, 10), doubled.get().*);
}

test "lazily/cell kernel: Source(T, SumPolicy) folds; merge subsumes MergeCell" {
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

// Clause-3 eager coalescing (`#lzsignaleager`): an **eager** computed cell
// materializes once per batch, not once per write. This is the property a
// binding shipped a per-write puller against; `computed().eager()` reuses the
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
    fn getDerived(c: *Compute) anyerror!u32 {
        _ = c.get(try cell(u32, c.untracked(), getA, null));
        _ = c.get(try cell(u32, c.untracked(), getB, null));
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

test "lazily/cell kernel: eager computed materializes once per batch (clause 3)" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    DrivenBatch.runs.store(0, .seq_cst);
    const f = try computed(u32, ctx, DrivenBatch.getDerived, null);
    defer ctx.allocator.destroy(f);

    // Not eager yet — one compute at construction.
    try std.testing.expectEqual(@as(usize, 1), DrivenBatch.runs.load(.seq_cst));
    try std.testing.expect(!f.isEager());

    // eager() is idempotent and returns the same handle (mutated graph state).
    const g = f.eager();
    try std.testing.expect(g == f);
    try std.testing.expect(f.isEager());
    _ = f.eager(); // no-op; still one puller
    try std.testing.expect(f.slot.eager);

    // 3 writes inside one batch → exactly one eager recompute at flush.
    ctx.batch(DrivenBatch.runBatch);
    try std.testing.expectEqual(@as(usize, 2), DrivenBatch.runs.load(.seq_cst));

    // lazy() reverts to lazy and clears the bit + side table entry.
    f.lazy();
    try std.testing.expect(!f.isEager());
    try std.testing.expect(!f.slot.eager);
    try std.testing.expect(ctx.eager_by.count() == 0);
}

// ---------------------------------------------------------------------------
// `computedRippleWhen` (`#lzcellkernel`) — a guarded computed with an explicit,
// PURE change predicate (`true` = propagate). Mirrors lazily-rs
// `tests/computed_ripple_when.rs`. The propagate guard runs on the eager
// recompute path (`makeRecomputeFn`), which is where the storage-layer equality
// guard lives, so a ripple-when node is eager and the observers below read it
// through the eager cascade rather than the coarse lazy staleness sweep.
// ---------------------------------------------------------------------------

// (1) Custom significance: the derived value carries a `bucket` proxy; propagate
// only when the bucket changes, ignoring the raw payload.
const RippleBucket = struct {
    const Pair = struct { payload: u64, bucket: u64 };
    var derived: ?*Computed(Pair) = null;
    var observer_recomputes: u32 = 0;

    fn inputInit(_: *Context) anyerror!u64 {
        return 0;
    }
    fn derivedFn(c: *Compute) anyerror!Pair {
        const in = try source(u64, c.untracked(), inputInit, null);
        const v = c.get(in);
        return .{ .payload = v, .bucket = v / 10 };
    }
    fn changedByBucket(old: *const Pair, new: *const Pair) bool {
        return old.bucket != new.bucket; // propagate when the bucket changed
    }
    fn observerFn(c: *Compute) anyerror!u64 {
        observer_recomputes += 1;
        return c.get(derived.?).payload;
    }
};

test "lazily/cell computedRippleWhen: custom significance propagates on proxy change" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    RippleBucket.derived = null;
    RippleBucket.observer_recomputes = 0;

    const input = try source(u64, ctx, RippleBucket.inputInit, null);
    const derived = try computedRippleWhen(RippleBucket.Pair, ctx, RippleBucket.derivedFn, RippleBucket.changedByBucket, null);
    defer ctx.allocator.destroy(derived);
    RippleBucket.derived = derived;

    const observer = try computed(u64, ctx, RippleBucket.observerFn, null);
    defer ctx.allocator.destroy(observer);

    try std.testing.expectEqual(@as(u64, 0), observer.get().*);
    const base = RippleBucket.observer_recomputes;

    // Same bucket (0..9): dependent stays cached, no recompute.
    input.set(3);
    try std.testing.expectEqual(@as(u64, 0), observer.get().*); // suppressed: bucket unchanged
    try std.testing.expectEqual(base, RippleBucket.observer_recomputes);

    // Crossing a bucket boundary propagates.
    input.set(12);
    try std.testing.expectEqual(@as(u64, 12), observer.get().*); // propagated: bucket changed
    try std.testing.expectEqual(base + 1, RippleBucket.observer_recomputes);
}

// (2) "Propagate every N": the evidence (the counter) is IN the value, so the
// predicate is a pure function of (old, new) — propagate only when the count
// crosses a size-3 window boundary.
const RippleEveryN = struct {
    var sampled: ?*Computed(u64) = null;
    var observer_recomputes: u32 = 0;

    fn inputInit(_: *Context) anyerror!u64 {
        return 0;
    }
    fn sampledFn(c: *Compute) anyerror!u64 {
        const in = try source(u64, c.untracked(), inputInit, null);
        return c.get(in);
    }
    fn changedEvery3(old: *const u64, new: *const u64) bool {
        return new.* / 3 != old.* / 3;
    }
    fn observerFn(c: *Compute) anyerror!u64 {
        observer_recomputes += 1;
        return c.get(sampled.?).*;
    }
};

test "lazily/cell computedRippleWhen: propagate every N via value-carried counter" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    RippleEveryN.sampled = null;
    RippleEveryN.observer_recomputes = 0;

    const input = try source(u64, ctx, RippleEveryN.inputInit, null);
    const sampled = try computedRippleWhen(u64, ctx, RippleEveryN.sampledFn, RippleEveryN.changedEvery3, null);
    defer ctx.allocator.destroy(sampled);
    RippleEveryN.sampled = sampled;

    const observer = try computed(u64, ctx, RippleEveryN.observerFn, null);
    defer ctx.allocator.destroy(observer);

    try std.testing.expectEqual(@as(u64, 0), observer.get().*);
    const base = RippleEveryN.observer_recomputes;

    // 0 -> 1 -> 2 stay in window [0,3): suppressed.
    input.set(1);
    input.set(2);
    try std.testing.expectEqual(@as(u64, 0), observer.get().*);
    try std.testing.expectEqual(base, RippleEveryN.observer_recomputes);

    // 3 crosses into [3,6): propagate.
    input.set(3);
    try std.testing.expectEqual(@as(u64, 3), observer.get().*);
    try std.testing.expectEqual(base + 1, RippleEveryN.observer_recomputes);
}

// (3) `computed(f).eager()` behaves as `computedRippleWhen(f, |o, n| o.* != n.*)`
// — both guard on natural equality on the eager recompute path.
const RippleEqIdentity = struct {
    var via_computed: ?*Computed(i64) = null;
    var via_when: ?*Computed(i64) = null;
    var a_recomputes: u32 = 0;
    var b_recomputes: u32 = 0;

    fn inputInit(_: *Context) anyerror!i64 {
        return 0;
    }
    fn clampFnA(c: *Compute) anyerror!i64 {
        const in = try source(i64, c.untracked(), inputInit, null);
        return @min(c.get(in), 1);
    }
    // Distinct comptime body so it gets its own cache key / node.
    fn clampFnB(c: *Compute) anyerror!i64 {
        const in = try source(i64, c.untracked(), inputInit, null);
        return @min(c.get(in), 1);
    }
    fn notEqual(old: *const i64, new: *const i64) bool {
        return old.* != new.*;
    }
    fn obsAFn(c: *Compute) anyerror!i64 {
        a_recomputes += 1;
        return c.get(via_computed.?).*;
    }
    fn obsBFn(c: *Compute) anyerror!i64 {
        b_recomputes += 1;
        return c.get(via_when.?).*;
    }
};

test "lazily/cell computedRippleWhen: computed(eager) matches ripple-when(!=)" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    RippleEqIdentity.via_computed = null;
    RippleEqIdentity.via_when = null;
    RippleEqIdentity.a_recomputes = 0;
    RippleEqIdentity.b_recomputes = 0;

    const input = try source(i64, ctx, RippleEqIdentity.inputInit, null);

    const via_computed = (try computed(i64, ctx, RippleEqIdentity.clampFnA, null)).eager();
    defer ctx.allocator.destroy(via_computed);
    const via_when = try computedRippleWhen(i64, ctx, RippleEqIdentity.clampFnB, RippleEqIdentity.notEqual, null);
    defer ctx.allocator.destroy(via_when);
    RippleEqIdentity.via_computed = via_computed;
    RippleEqIdentity.via_when = via_when;

    const obs_a = try computed(i64, ctx, RippleEqIdentity.obsAFn, null);
    defer ctx.allocator.destroy(obs_a);
    const obs_b = try computed(i64, ctx, RippleEqIdentity.obsBFn, null);
    defer ctx.allocator.destroy(obs_b);

    try std.testing.expectEqual(@as(i64, 0), obs_a.get().*);
    try std.testing.expectEqual(@as(i64, 0), obs_b.get().*);
    const base_a = RippleEqIdentity.a_recomputes;
    const base_b = RippleEqIdentity.b_recomputes;

    // 0 -> 5 both clamp to 1: both propagate identically.
    input.set(5);
    try std.testing.expectEqual(@as(i64, 1), obs_a.get().*);
    try std.testing.expectEqual(@as(i64, 1), obs_b.get().*);
    try std.testing.expectEqual(base_a + 1, RippleEqIdentity.a_recomputes);
    try std.testing.expectEqual(base_b + 1, RippleEqIdentity.b_recomputes);

    // 5 -> 9 both stay 1: both suppress the dependent identically.
    input.set(9);
    try std.testing.expectEqual(@as(i64, 1), obs_a.get().*);
    try std.testing.expectEqual(@as(i64, 1), obs_b.get().*);
    try std.testing.expectEqual(base_a + 1, RippleEqIdentity.a_recomputes); // computed suppressed equal recompute
    try std.testing.expectEqual(base_b + 1, RippleEqIdentity.b_recomputes); // ripple-when(!=) matches computed
}

// (4) Pass-through: an always-true predicate propagates even when the value is
// unchanged — the `slot(f)` identity on the eager surface.
const RipplePassThrough = struct {
    var passthrough: ?*Computed(u64) = null;
    var observer_recomputes: u32 = 0;

    fn inputInit(_: *Context) anyerror!u64 {
        return 0;
    }
    fn constFn(c: *Compute) anyerror!u64 {
        _ = c.get(try source(u64, c.untracked(), inputInit, null)); // depend on input, always yield 0
        return 0;
    }
    fn alwaysPropagate(_: *const u64, _: *const u64) bool {
        return true;
    }
    fn observerFn(c: *Compute) anyerror!u64 {
        observer_recomputes += 1;
        return c.get(passthrough.?).*;
    }
};

test "lazily/cell computedRippleWhen: pass-through (always true) always propagates" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    RipplePassThrough.passthrough = null;
    RipplePassThrough.observer_recomputes = 0;

    const input = try source(u64, ctx, RipplePassThrough.inputInit, null);
    const passthrough = try computedRippleWhen(u64, ctx, RipplePassThrough.constFn, RipplePassThrough.alwaysPropagate, null);
    defer ctx.allocator.destroy(passthrough);
    RipplePassThrough.passthrough = passthrough;

    const observer = try computed(u64, ctx, RipplePassThrough.observerFn, null);
    defer ctx.allocator.destroy(observer);

    try std.testing.expectEqual(@as(u64, 0), observer.get().*);
    const base = RipplePassThrough.observer_recomputes;

    // Value stays 0, but the always-true guard propagates, so the dependent re-fires.
    input.set(5);
    try std.testing.expectEqual(@as(u64, 0), observer.get().*);
    try std.testing.expect(RipplePassThrough.observer_recomputes > base);
}
