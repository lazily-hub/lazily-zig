const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const FfiResult = @import("ffi.zig").FfiResult;
const AllocatorMode = @import("ffi.zig").AllocatorMode;
const AllocatorHandle = @import("ffi.zig").AllocatorHandle;

/// Version-agnostic graph mutex:
/// - Zig < 0.16 uses `std.Thread.Mutex`.
/// - Zig >= 0.16 uses `ReentrantMutex` (`parking_mutex.zig`, `#lzparkingmutex`)
///   — a `ParkingMutex` (Linux futex) wrapped with owner-thread tracking so
///   the same thread can re-acquire the lock without deadlock. Reentrancy is
///   required because `Slot.initKeyed` calls user `valueFn` which re-enters
///   the graph via `cell()`/`slot()` (each locks `ctx.mutex`). The pre-fix
///   engine released the lock before valueFn to avoid the deadlock — which
///   opened a use-after-free race (`#lzuafix`: concurrent `emitChange` freed a
///   slot mid-materialization). Holding the lock across subscribe → valueFn →
///   cache-put closes the window.
const GraphMutex = if (builtin.zig_version.minor < 16)
    std.Thread.Mutex
else
    @import("parking_mutex.zig").ReentrantMutex;

/// Opaque identifier for a `Slot` living in a `SlotArena`. `raw = 0` is the
/// null id (page 0, slot 0 is never handed out — `SlotArena.next_id` starts at
/// 1). A `Slot` carries its own `id` so `destroySingleNodeUnlocked` can return
/// it to the arena free-list without a pointer→page reverse lookup.
const SlotId = struct { raw: u64 };

/// Stable-page node arena (`#lzinplace` stable-address allocator for `Slot`).
///
/// Slots come from fixed-size pages (`[PAGE_SIZE]Slot`) that are allocated ONCE
/// and never moved or realloced, so every `*Slot` — and every raw `*T` reader
/// pointer that aliases a slot's `inline_buf` (`Slot.get` for `.indirect`
/// inline-eligible types, context.zig `inline_ptr = &self.inline_buf`) — stays
/// valid from publication until `Context.deinit`. Pages do not relocate on grow,
/// which is the failure mode that sank a prior dense-slotmap attempt (a
/// geometrically-grown `[]Slot` realloc+memcpy dangled the raw `*T` readers).
///
/// `alloc` returns a slot pulled from the reuse free-list first, then a fresh
/// page slot. Reuse mirrors the pre-arena lifetime exactly: the only
/// non-`deinit` caller of `destroySingleNodeUnlocked` (→ `free`) is the
/// cache-race loser in `Slot.initKeyed` — a slot that was never published to the
/// cache and whose storage was never handed to a reader — so recycling its
/// memory cannot dangle a live `*T`. Stale/orphaned slots
/// (`invalidateSlotUnlocked` → `orphaned_slots`) are NOT freed here until
/// `Context.deinit`, matching the prior `#lzinplace` contract byte-for-byte.
const SlotArena = struct {
    pub const PAGE_BITS: u6 = 9;
    pub const PAGE_SIZE: u32 = 1 << PAGE_BITS;
    pub const PAGE_MASK: u32 = PAGE_SIZE - 1;

    pages: std.ArrayList(*[PAGE_SIZE]Slot),
    free_list: std.ArrayList(SlotId),
    next_id: u64 = 1,
    allocator: std.mem.Allocator,
    /// Inline free-stack (`#lzzigfreestack`): the recycler is LIFO and the
    /// cache-race loser that drives `free()` is overwhelmingly bursty (a
    /// re-entrant valueFn creating + discarding slots on the same thread), so a
    /// 16-slot inline ring absorbs the churn with zero allocator calls. Spills
    /// to `free_list` only when all 16 are live — a 17-deep burst on a single
    /// page before any reader pulls. 16 mirrors `inline_cap * PAGE_SIZE / 256`
    /// — well over the largest realistic reentrant burst the soak tests reach.
    inline_free: [16]SlotId = undefined,
    inline_free_len: u8 = 0,

    fn init(allocator: std.mem.Allocator) SlotArena {
        return .{
            .pages = if (builtin.zig_version.minor < 16) .{} else std.ArrayList(*[PAGE_SIZE]Slot).empty,
            .free_list = if (builtin.zig_version.minor < 16) .{} else std.ArrayList(SlotId).empty,
            .allocator = allocator,
        };
    }

    fn alloc(self: *SlotArena) !*Slot {
        // Pop inline free-stack first (`#lzzigfreestack`): avoids the
        // `free_list.pop()` ArrayList touch on the common churn path.
        if (self.inline_free_len > 0) {
            self.inline_free_len -= 1;
            const id = self.inline_free[self.inline_free_len];
            const slot = self.addrOf(id.raw);
            slot.id = id;
            return slot;
        }
        if (self.free_list.pop()) |id| {
            const slot = self.addrOf(id.raw);
            slot.id = id;
            return slot;
        }
        const idx = self.next_id;
        self.next_id += 1;
        const page_idx: usize = @intCast(idx >> PAGE_BITS);
        if (page_idx >= self.pages.items.len) {
            try self.pages.append(self.allocator, try self.allocator.create([PAGE_SIZE]Slot));
        }
        const slot = self.addrOf(idx);
        slot.id = .{ .raw = idx };
        return slot;
    }

    fn addrOf(self: *SlotArena, id_raw: u64) *Slot {
        const page_idx: usize = @intCast(id_raw >> PAGE_BITS);
        const slot_idx: usize = @intCast(id_raw & @as(u64, PAGE_MASK));
        return &self.pages.items[page_idx][slot_idx];
    }

    fn free(self: *SlotArena, id: SlotId) void {
        // Push inline first (`#lzzigfreestack`); spill to `free_list` only when
        // the 16-entry stack is full.
        if (self.inline_free_len < self.inline_free.len) {
            self.inline_free[self.inline_free_len] = id;
            self.inline_free_len += 1;
            return;
        }
        self.free_list.append(self.allocator, id) catch {};
    }

    fn deinit(self: *SlotArena) void {
        for (self.pages.items) |page| {
            self.allocator.destroy(page);
        }
        self.pages.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
    }
};

/// Context with lazy cache
pub const Context = struct {
    allocator: std.mem.Allocator,
    // Stable-page arena backing every `Slot` (`#lzinplace`). All `*Slot` and
    // interior `*T`-into-`inline_buf` pointers are stable for the Context
    // lifetime because arena pages are allocated once and never moved.
    arena: SlotArena,
    // Function pointer -> cached result
    cache: std.AutoHashMap(usize, *Slot),
    // Optional dense direct-indexed cache for the keyed (runtime-integer-key)
    // path. When non-null, `cacheLookup`/`cachePublish`/`cacheRemove` consult it
    // first, turning a hot keyed read into a single indexed load instead of a
    // hash probe of the 2N-entry `cache` (the dominant cost at 10M-node scale).
    // Opt-in via `initDense`; null by default so the function-pointer-keyed path
    // and all default callers are byte-identical to the map-only model.
    dense_cache: ?[]?*Slot = null,
    // Use a real Mutex if thread_safe is true, otherwise use a "no-op" struct
    mutex: if (build_options.thread_safe) GraphMutex else struct {
        pub fn lock(_: *@This()) void {}
        pub fn unlock(_: *@This()) void {}
    } = .{},
    // Deferred-recompute queue for eager Signal slots. Drained outside the mutex
    // so user valueFn can re-acquire the mutex per-slot without deadlock.
    pending_recompute: std.ArrayList(*Slot),
    draining_recompute: bool = false,
    // `batch` boundary depth (0 == not batching). While > 0, `Cell.set` queues
    // the eager-recompute drain until the outermost `finishBatch` exit, so N
    // writes inside one `batch(run)` produce a single effect/Signal flush
    // (`lazily-spec/docs/reactive-graph.md` § batch, conformance clause #6).
    batch_depth: usize = 0,
    // Instrumentation counters (sync surface). Mirrors lazily-rs
    // `InstrumentationCounters` (`instrumentation.rs:66-97`). Always-on: 6 u64
    // fields, bumped under `mutex` (no extra atomics). Use
    // `instrumentationSnapshot()` / `resetInstrumentation()`.
    instrumentation: Instrumentation = .{},
    // Slots that were invalidated (stale) and subsequently removed from the
    // cache by a reader detecting staleness. They are NOT freed immediately
    // because a reader on another thread may hold a `*T` pointer into the
    // slot's storage. They are freed at `Context.deinit`. This is the
    // invalidate-in-place model (`#lzinplace`) — the fix for the
    // destroy-on-invalidate UAF that caused SEGV under concurrent same-cell
    // writes. Bounded by the number of invalidation cycles between deinits.
    orphaned_slots: std.ArrayList(*Slot),
    // Reusable DFS worklist for the invalidation/destroy cascades
    // (`#lziterbfs`, the #lzbatchborrow port). Grown once on first use and
    // reused across `invalidateSlotUnlocked` / `emitChangeUnlocked` /
    // `destroySelf` calls, replacing the per-cascade-level
    // `allocator.alloc(*Slot, count)` snapshots those functions used to take.
    // Always empty on entry (each cascade drains it to completion under
    // `mutex`); the trailing `defer clearRetainingCapacity()` is a safety net.
    cascade_scratch: std.ArrayList(*Slot),
    // Optional hook invoked AFTER `deinit` frees the Context struct, so it may
    // release a stateful allocator state that backed `allocator`. Used by the
    // FFI `init_context_with_mode` to own arena/debug/smp allocators. Native
    // callers leave these null (they own their allocator themselves).
    post_deinit_fn: ?*const fn (state: *anyopaque) void = null,
    post_deinit_state: ?*anyopaque = null,

    /// Copyable instrumentation snapshot. Fields mirror lazily-rs
    /// `InstrumentationCounters` (`instrumentation.rs:66-97`). Always-on: 6 u64
    /// fields, bumped under `mutex` (no extra atomics).
    pub const Instrumentation = struct {
        node_allocations: u64 = 0,
        slot_recomputes: u64 = 0,
        dependency_edges_added: u64 = 0,
        dependency_edges_removed: u64 = 0,
        effect_queue_pushes: u64 = 0,
        max_effect_queue_depth: u64 = 0,
    };

    pub fn instrumentationSnapshot(self: *Context) Instrumentation {
        return self.instrumentation;
    }

    pub fn resetInstrumentation(self: *Context) void {
        self.instrumentation = .{};
    }

    fn bump(self: *Context, comptime field: []const u8) void {
        @field(self.instrumentation, field) += 1;
    }

    pub fn init(allocator: std.mem.Allocator) !*Context {
        const ctx = try allocator.create(Context);
        ctx.* = .{
            .allocator = allocator,
            .arena = SlotArena.init(allocator),
            .cache = std.AutoHashMap(
                usize,
                *Slot,
            ).init(allocator),
            .pending_recompute = if (builtin.zig_version.minor < 16) .{} else std.ArrayList(*Slot).empty,
            .orphaned_slots = if (builtin.zig_version.minor < 16) .{} else std.ArrayList(*Slot).empty,
            .cascade_scratch = if (builtin.zig_version.minor < 16) .{} else std.ArrayList(*Slot).empty,
        };
        return ctx;
    }

    /// Pre-size the hash-map cache. Eliminates the ~log2(N) rehash storms that
    /// dominate `cold_full_recalc` when the cache grows from empty to 2N entries.
    pub fn ensureCacheCapacity(self: *Context, capacity: usize) !void {
        try self.cache.ensureTotalCapacity(@intCast(capacity));
    }

    /// Opt into a dense direct-indexed cache keyed by `0..=max_key`. After this,
    /// keyed reads whose `cache_key <= max_key` are a single indexed load
    /// (`dense_cache[key]`) instead of a hash probe. Keys outside the range, and
    /// the function-pointer-keyed path (sparse address keys), fall back to the
    /// hash map. The map is also pre-sized so its fallback path avoids rehashing.
    pub fn initDense(self: *Context, max_key: usize) !void {
        const slots = try self.allocator.alloc(?*Slot, max_key + 1);
        @memset(slots, null);
        self.dense_cache = slots;
        try self.cache.ensureTotalCapacity(@intCast(max_key + 1));
    }

    /// Look up a cached slot. Dense array first (if enabled and in range), then
    /// the hash map. Always called under `mutex`.
    pub fn cacheLookup(self: *Context, key: usize) ?*Slot {
        if (self.dense_cache) |arr| {
            if (key < arr.len) return arr[key];
        }
        return self.cache.get(key);
    }

    /// Remove a cache entry from whichever store holds it. Always under `mutex`.
    pub fn cacheRemove(self: *Context, key: usize) void {
        if (self.dense_cache) |arr| {
            if (key < arr.len) arr[key] = null;
        }
        _ = self.cache.remove(key);
    }

    /// Publish a freshly-materialized slot under `key`. The caller must have
    /// already confirmed (via `cacheLookup`) that no entry exists — this is safe
    /// because the whole materialization runs under the reentrant `mutex`.
    /// Dense store wins when enabled and in range; otherwise the hash map.
    pub fn cachePublish(self: *Context, key: usize, slot: *Slot) !void {
        if (self.dense_cache) |arr| {
            if (key < arr.len) {
                arr[key] = slot;
                return;
            }
        }
        const gop = try self.cache.getOrPut(key);
        gop.value_ptr.* = slot;
    }

    pub fn deinit(self: *Context) void {
        self.mutex.lock();
        // The mutex is not unlocked due to this being deinit which deallocates self.

        var iter = self.cache.valueIterator();
        while (iter.next()) |ptr| {
            const context_slot = ptr.*;
            context_slot.destroyUnlocked(false);
        }
        self.cache.deinit();

        // Dense-cache entries are NOT duplicated in the hash map, so destroy any
        // slots held only by the dense array before freeing it.
        if (self.dense_cache) |arr| {
            for (arr) |maybe_slot| {
                if (maybe_slot) |slot| slot.destroyUnlocked(false);
            }
            self.allocator.free(arr);
        }
        self.pending_recompute.deinit(self.allocator);

        // Free orphaned slots (stale-removed from cache but kept alive because
        // reader threads may hold storage pointers into them). At deinit, all
        // readers are done — safe to free. (#lzinplace)
        for (self.orphaned_slots.items) |slot| {
            slot.destroySelf(false);
        }
        self.orphaned_slots.deinit(self.allocator);
        self.cascade_scratch.deinit(self.allocator);

        // Free every arena page. This runs AFTER the cache + orphaned_slots
        // teardown above (which called `destroySingleNodeUnlocked` on each slot,
        // returning it to the arena free-list) — readers are gone at deinit, so
        // releasing the pages is the `#lzinplace` end-of-life point.
        self.arena.deinit();

        // Capture the post-deinit hook before freeing self: `destroy(self)`
        // deallocates the Context struct via `allocator`, and the hook owns
        // (and may free) the stateful allocator state that backs `allocator`,
        // so it must run AFTER self is released. Locals stay valid across the
        // free because they live on the caller's stack, not in self.
        const post_fn = self.post_deinit_fn;
        const post_state = self.post_deinit_state;

        self.allocator.destroy(self);

        // post_state is non-null whenever post_fn is (the only setter,
        // init_context_with_mode, installs both together).
        if (post_fn) |f| f(post_state.?);
    }

    /// Get a Slot. Slot.destroy() will deinit and remove the Slot from the Context.cache.
    pub fn getSlot(self: *Context, fnc: anytype) ?*Slot {
        const cache_key = valueFnCacheKey(fnc);
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cacheLookup(cache_key);
    }

    /// Drain the pending-recompute queue. Called outside the graph mutex so that
    /// each slot's `recompute` fn can re-lock per-op (user valueFn re-enters the
    /// graph via slot()/slotKeyed()). LIFO order (deepest-dependency-first).
    pub fn drainPendingRecompute(self: *Context) void {
        if (self.draining_recompute) return;
        if (self.pending_recompute.items.len == 0) return;

        // Track the high-water mark of the effect queue depth.
        if (@as(u64, @intCast(self.pending_recompute.items.len)) > self.instrumentation.max_effect_queue_depth) {
            self.instrumentation.max_effect_queue_depth = @intCast(self.pending_recompute.items.len);
        }

        self.draining_recompute = true;
        defer self.draining_recompute = false;

        while (self.pending_recompute.pop()) |slot| {
            // Tombstone discard (`#lzspecedgeindex`). `destroySingleNodeUnlocked`
            // clears `stale` in O(1) and leaves the queue entry behind rather
            // than scanning for it, so a cleared flag here means one of:
            //   - the slot was torn down after it was enqueued (the entry is a
            //     tombstone; recomputing it would touch a deinit'd edge set and
            //     freed storage — a use-after-free), or
            //   - the slot's arena memory was recycled into a *fresh* slot that
            //     has not been invalidated (running it would be a spurious
            //     recompute of an unrelated node).
            // Both are discards. A recycled-and-rescheduled slot is still safe:
            // the drain is LIFO and the tombstone was appended first, so the
            // live entry pops first, runs, and clears the flag; the tombstone
            // then pops with the flag clear and is dropped.
            if (!slot.stale) continue;
            slot.stale = false;
            if (slot.recompute) |recompute_fn| {
                self.instrumentation.slot_recomputes += 1;
                recompute_fn(slot);
            }
        }
    }

    /// True when inside a `batch(run)` boundary. `Cell.set` checks this to
    /// defer the eager-recompute drain to the outermost batch exit.
    pub fn isBatching(self: *const Context) bool {
        return self.batch_depth > 0;
    }

    /// Coalesce several `Cell.set` updates into one Signal/Effect flush at the
    /// outermost batch exit (`lazily-spec/docs/reactive-graph.md` § batch).
    ///
    /// Mutation is synchronous — `run`'s `Cell.set` calls commit their values
    /// and propagate invalidation to dependent slots immediately; only the
    /// eager-recompute flush (`drainPendingRecompute`) is deferred, so eager
    /// Signals and Effects rerun once at exit, not once per `set`.
    pub fn batch(
        self: *Context,
        comptime run: anytype,
    ) void {
        self.batch_depth += 1;
        defer self.finishBatch();
        run(self);
    }

    fn finishBatch(self: *Context) void {
        std.debug.assert(self.batch_depth > 0);
        self.batch_depth -= 1;
        if (self.batch_depth == 0) {
            // Outermost exit: flush coalesced eager recomputes.
            self.drainPendingRecompute();
        }
    }
};

pub fn Owned(comptime T: type) type {
    return struct {
        value: T,
        is_managed: bool,

        pub fn managed(value: T) @This() {
            return .{ .value = value, .is_managed = true };
        }

        pub fn literal(value: T) @This() {
            return .{ .value = value, .is_managed = false };
        }

        pub fn deinit(self: *@This(), ctx: *Context) void {
            if (!self.is_managed) return;

            const type_info = @typeInfo(T);
            if (type_info == .pointer) {
                ctx.allocator.free(self.value);
            } else if (type_info == .@"struct" and @hasDecl(T, "deinit")) {
                self.value.deinit(ctx);
            }
        }
    };
}

pub const String = []const u8;
pub const OwnedString = Owned(String);

pub fn valueFnCacheKey(valueFn: anytype) usize {
    const type_info = @typeInfo(@TypeOf(valueFn));

    return switch (type_info) {
        // If caller passes a function (not a pointer), take its address.
        .@"fn" => @intFromPtr(&valueFn),

        // If caller passes a function pointer, use it directly.
        .pointer => |p| blk: {
            if (@typeInfo(p.child) != .@"fn") {
                @compileError("Expected a function pointer");
            }
            break :blk @intFromPtr(valueFn);
        },

        else => @compileError("expected a function or function pointer"),
    };
}

/// Inline-capacity set of keys (`#lzedgeinline`) — the dependency-edge
/// container behind `Slot.change_subscribers` / `Slot.parents` (keyed by
/// `*Slot`) and `Cell` subscriber sets (keyed by `SubscriberKey`).
///
/// Profiling `cold_full_recalc` showed ~21% of wall-clock in growing the
/// per-slot `AutoHashMap` edge sets: every reactive node allocated one map per
/// direction and grew it on the first edge insert, so an N-node graph paid
/// O(N) heap allocations just to record edges. Real reactive graphs are
/// overwhelmingly low-degree (a spreadsheet formula reads 2–3 cells), so this
/// set stores the first `inline_cap` keys inline and only spills to a heap
/// `ArrayList(K)` for genuinely high-fan-out nodes (e.g. one source feeding
/// thousands of dependents). Low-degree graphs allocate zero edge maps.
///
/// `EdgeSet` is generic over an equatable key type `K`
/// (`#lzzigcellslotedgeset`) so the same low-footprint container serves both
/// the `*Slot` graph edges and the `SubscriberKey` callback sets on `Cell`,
/// replacing the per-`Cell` `AutoHashMap(SubscriberKey, void)` pair with two
/// inline edge sets.
///
/// This is a drop-in for the `AutoHashMap(K, void)` surface the graph used
/// (`getOrPut` dedup-add, `remove`, `count`, `keyIterator`,
/// `clearRetainingCapacity`, `deinit`), so the surrounding, concurrency-
/// sensitive snapshot-then-clear-then-iterate control flow is unchanged. Access
/// is always serialized by `ctx.mutex`, exactly as the map was.
pub fn EdgeSet(comptime K: type, comptime cap: usize) type {
    return struct {
        const Self = @This();

        /// Inline edges before spilling. `cap` is chosen per use site: the
        /// `*Slot` graph edges use 2 (mirrors lazily-rs `EdgeVec =
        /// SmallVec<[SlotId; 2]>`, `#lzvecedge` — reactive graphs are
        /// overwhelmingly degree 2-3), while `Cell` subscriber sets use 1
        /// (`#lzzigcellslotedgeset` — a cell usually has 0-1 callbacks). The
        /// first `cap` keys live inline (no heap alloc); higher-fan-out nodes
        /// spill to a heap `ArrayList(K)`.
        pub const inline_cap: usize = cap;

        // NOTE: no stored `allocator` field. It was 16 bytes/direction (a vtable
        // pair) paid by every edge set even though it is needed only on the rare
        // inline→spill transition. The spill allocator is passed to `getOrPut`/
        // `deinit` from the owning Slot's `ctx.allocator`.
        buf: [cap]K = undefined,
        len: usize = 0,
        /// Spill store: a growable `ArrayList(K)` with linear dedup, replacing
        /// the former `AutoHashMap(K, void)` spill (`#lzvecedge`). Linear
        /// `contains` on a small set is cache-friendlier and faster than
        /// hash+probe (no hashing, no bucket chain), matching lazily-rs `EdgeVec` /
        /// `edge_insert` (`SmallVec<[SlotId;2]>` + linear `contains`). Only the
        /// rare high-fan-out node spills; while spilled, `len` is held at 0 and
        /// `buf` is unused.
        ///
        /// Non-optional (`#lzzigslotpack`): the inline-vs-spilled state is
        /// discriminated by `spill.items.len > 0`, not by a null pointer. An
        /// empty spilled set is indistinguishable from an empty inline set, so
        /// `ArrayList(K)` (24B) replaces `?ArrayList(K)` (32B) — 8B fewer per
        /// edge set with no behavioral change.
        spill: std.ArrayList(K) = if (builtin.zig_version.minor < 16) .{} else std.ArrayList(K).empty,

        /// Wide-fanout hash index (`#lzspecedgeindex`), or null while the set
        /// has never been wide. A single nullable pointer, not inline fields:
        /// every `Slot` carries two edge sets, so inlining the table header
        /// would add 48 bytes to a ~256-byte `Slot` that is almost never wide
        /// (`#lzzigslotpack`). Only nodes that actually cross
        /// `promote_threshold` pay for the header.
        index: ?*Index = null,

        // --- wide-fanout hash index (`#lzspecedgeindex`) ---------------------
        //
        // The linear dedup scan above is O(degree) per registration, so building
        // a width-N fan-out is N^2/2 comparisons and `remove` — which runs
        // per-edge during cascade — is another O(degree) scan. Above a measured
        // threshold the spill switches to an open-addressed hash index over
        // `spill`, making both amortized O(1) in degree.
        //
        // Threshold justification (measured on this machine, zig master
        // 0.17.0-dev, ReleaseFast, median of 9, picoseconds/op — see the
        // `#lzspecedgeindex` crossover microbenchmark):
        //
        //     n     build scan / index      remove scan / index
        //     32      2299 /  4327 (0.53)     2080 /  2190 (0.95)
        //     48      3473 /  5505 (0.63)     3118 /  1978 (1.58)
        //     64      5624 /  4567 (1.23)     3849 /  1937 (1.99)
        //     96     12205 /  6114 (2.00)     5446 /  1832 (2.97)
        //    256     31518 /  5437 (5.80)    16886 /  1908 (8.85)
        //   1024    107739 /  5784 (18.6)    57468 /  1859 (30.9)
        //
        // Registration crosses over near degree 56-64; `remove` crosses over
        // near degree 24-32. 64 is the conservative choice: it is at (not past)
        // the registration crossover, so promotion never makes registration
        // slower than the scan it replaces, while `remove` is already ~2x
        // better there. The number is NOT portable — lazily-rs measured ~170
        // with SipHash and ~40 with a multiply-shift finalizer. This is Zig's
        // own measurement with the `mixKey` finalizer below; changing the hash
        // invalidates it. Results were within noise for pointer strides of 256
        // and 1024 bytes, so the finalizer is not sensitive to slot alignment.
        pub const promote_threshold: usize = 64;

        /// Whether `K` can be hashed cheaply (pointer or integer). Non-indexable
        /// key types keep the pure-scan behaviour.
        /// Struct keys opt in by declaring `edgeHashKey`, which projects the
        /// key onto the unique field the index should hash (`Cell`'s
        /// `Subscription` hashes its registration id, not the callback
        /// address). Without the hook a struct key keeps the pure-scan
        /// behaviour, since `mixKey` has nothing safe to hash.
        const indexable = switch (@typeInfo(K)) {
            .pointer, .int => true,
            .@"struct" => @hasDecl(K, "edgeHashKey"),
            else => false,
        };

        const idx_empty: u32 = 0;
        const idx_tomb: u32 = 1;

        /// Open-addressed table of `pos + 2` into `spill` (`0` = empty,
        /// `1` = tombstone). `entries.len` is always a power of two.
        /// `on` is the "currently indexed" discriminator and is separate from
        /// the allocation: `clearRetainingCapacity` turns the index *off* but
        /// keeps the table, so a cleared wide node re-promotes without
        /// reallocating.
        const Index = struct {
            entries: []u32,
            tombs: u32 = 0,
            on: bool = false,
        };

        inline fn mixKey(key: K) u64 {
            var x: u64 = switch (@typeInfo(K)) {
                .pointer => @intFromPtr(key),
                .int => @intCast(key),
                .@"struct" => key.edgeHashKey(),
                else => unreachable,
            };
            // Multiply-shift finalizer (fmix64). Slot pointers stride by a fixed
            // `@sizeOf(Slot)`, i.e. the low bits are near-constant, so the
            // finalizer — not the raw value — is what keeps probe chains short.
            // The measured threshold above is specific to this function.
            x ^= x >> 33;
            x *%= 0xff51afd7ed558ccd;
            x ^= x >> 33;
            x *%= 0xc4ceb9fe1a85ec53;
            x ^= x >> 33;
            return x;
        }

        inline fn indexed(self: *const Self) bool {
            if (!indexable) return false;
            return if (self.index) |ix| ix.on else false;
        }

        /// Table position holding `key`, or null. Requires `indexed()`.
        fn indexFind(self: *Self, key: K) ?usize {
            const ix = self.index.?;
            const mask: u64 = @as(u64, ix.entries.len) - 1;
            var i: u64 = mixKey(key) & mask;
            while (true) : (i = (i + 1) & mask) {
                const e = ix.entries[@intCast(i)];
                if (e == idx_empty) return null;
                if (e == idx_tomb) continue;
                if (std.meta.eql(self.spill.items[e - 2], key)) return @intCast(i);
            }
        }

        /// Record `key` at `pos`. Requires `indexed()` and spare capacity.
        fn indexPut(self: *Self, key: K, pos: usize) void {
            const ix = self.index.?;
            const mask: u64 = @as(u64, ix.entries.len) - 1;
            var i: u64 = mixKey(key) & mask;
            var first_tomb: ?u64 = null;
            while (true) : (i = (i + 1) & mask) {
                const e = ix.entries[@intCast(i)];
                if (e == idx_empty) {
                    const write_at = first_tomb orelse i;
                    if (first_tomb != null) ix.tombs -= 1;
                    ix.entries[@intCast(write_at)] = @intCast(pos + 2);
                    return;
                }
                if (e == idx_tomb and first_tomb == null) first_tomb = i;
            }
        }

        /// (Re)build the index from `spill`, sizing the table to >= 2x the live
        /// count. Also the promotion path.
        fn indexRebuild(self: *Self, allocator: std.mem.Allocator) !void {
            var want: usize = 16;
            while (want < self.spill.items.len * 2) want *= 2;

            if (self.index == null) {
                const ix = try allocator.create(Index);
                ix.* = .{ .entries = allocator.alloc(u32, want) catch |e| {
                    allocator.destroy(ix);
                    return e;
                } };
                self.index = ix;
            } else if (want > self.index.?.entries.len) {
                const ix = self.index.?;
                const grown = try allocator.alloc(u32, want);
                allocator.free(ix.entries);
                ix.entries = grown;
                ix.on = false;
            }

            self.indexRebuildInPlace();
        }

        /// Refill the index from `spill` without touching the allocation.
        /// Valid whenever the live count only shrank (compaction), since the
        /// table was sized to >= 2x a count that is now smaller.
        fn indexRebuildInPlace(self: *Self) void {
            const ix = self.index.?;
            @memset(ix.entries, idx_empty);
            ix.tombs = 0;
            ix.on = true;
            for (self.spill.items, 0..) |k, p| self.indexPut(k, p);
        }

        /// Turn the index off, retaining its allocation. Called whenever the
        /// backing list is cleared or drained: the arena recycles `Slot`s, and a
        /// recycled owner must never inherit a stale index
        /// (`#lzspecedgeindex`). The retained table is safe because
        /// `indexRebuild` always `@memset`s before refilling.
        inline fn indexDeactivate(self: *Self) void {
            if (self.index) |ix| {
                ix.on = false;
                ix.tombs = 0;
            }
        }

        /// Free the index (teardown only).
        fn indexFree(self: *Self, allocator: std.mem.Allocator) void {
            if (self.index) |ix| {
                allocator.free(ix.entries);
                allocator.destroy(ix);
                self.index = null;
            }
        }

        pub fn init() Self {
            return .{};
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.indexFree(allocator);
            self.spill.deinit(allocator);
            self.* = undefined;
        }

        pub fn count(self: *const Self) usize {
            return if (self.spill.items.len > 0) self.spill.items.len else self.len;
        }

        /// Dedup-add `key`. Mirrors `AutoHashMap.getOrPut` for the graph's use
        /// (callers only rely on the dedup side effect). Spills inline→ArrayList
        /// when the inline buffer is full. `allocator` is used only on the (rare)
        /// spill and its amortized growth.
        pub fn getOrPut(self: *Self, key: K, allocator: std.mem.Allocator) !void {
            if (self.spill.items.len > 0) {
                if (self.indexed()) {
                    if (self.indexFind(key) != null) return; // already present
                    try self.spill.append(allocator, key);
                    // Keep the table under a 3/4 load (live + tombstones) so
                    // probe chains stay short and `indexFind` always terminates.
                    const ix = self.index.?;
                    if ((self.spill.items.len + ix.tombs) * 4 >= ix.entries.len * 3) {
                        try self.indexRebuild(allocator);
                    } else {
                        self.indexPut(key, self.spill.items.len - 1);
                    }
                    return;
                }
                for (self.spill.items) |e| {
                    if (std.meta.eql(e, key)) return; // already present
                }
                try self.spill.append(allocator, key);
                // Promote once the scan stops paying for itself. There is no
                // demotion: the index is dropped only when the list is cleared
                // or the owner torn down. A shared promote/demote boundary makes
                // a list oscillating by one rebuild its index on every
                // recompute (~4x steady-state cost at exactly threshold+1), and
                // the spec's other option — demote well below promote — buys
                // nothing here because the cascade clears these sets wholesale.
                if (indexable and self.spill.items.len >= promote_threshold) {
                    try self.indexRebuild(allocator);
                }
                return;
            }
            for (self.buf[0..self.len]) |e| {
                if (std.meta.eql(e, key)) return; // already present
            }
            if (self.len < inline_cap) {
                self.buf[self.len] = key;
                self.len += 1;
                return;
            }
            // Inline buffer full — spill into the (already-empty) ArrayList.
            // Copy the inline entries in, then add the new key. Capacity may be
            // retained from a prior spill→clear cycle, so the alloc is skipped.
            try self.spill.ensureTotalCapacity(allocator, inline_cap + 1);
            for (self.buf[0..self.len]) |e| self.spill.appendAssumeCapacity(e);
            self.spill.appendAssumeCapacity(key);
            self.len = 0;
        }

        /// Membership probe (`#lzzigcontainsfast`). Same linear scan `getOrPut`
        /// performs before its insert, but without the write side effect — so the
        /// cached-read subscribe site can short-circuit an already-tracked edge
        /// without paying for the (cold-path) `getOrPut` bookkeeping on every hit.
        /// Key-identity only (never dereferences `key`).
        pub fn contains(self: *const Self, key: K) bool {
            if (self.spill.items.len > 0) {
                if (self.indexed()) {
                    return @constCast(self).indexFind(key) != null;
                }
                for (self.spill.items) |e| {
                    if (std.meta.eql(e, key)) return true;
                }
                return false;
            }
            for (self.buf[0..self.len]) |e| {
                if (std.meta.eql(e, key)) return true;
            }
            return false;
        }

        /// Remove `key` if present; returns whether it was. Both paths use
        /// swap-remove (set is unordered; all iteration sites snapshot first).
        pub fn remove(self: *Self, key: K) bool {
            if (self.spill.items.len > 0) {
                if (self.indexed()) {
                    const found = self.indexFind(key) orelse return false;
                    const ix = self.index.?;
                    const pos: usize = ix.entries[found] - 2;
                    ix.entries[found] = idx_tomb;
                    ix.tombs += 1;
                    const last = self.spill.items.len - 1;
                    if (pos != last) {
                        // Swap-remove moves the tail entry; repoint its slot.
                        const moved = self.spill.items[last];
                        self.spill.items[pos] = moved;
                        const moved_at = self.indexFind(moved).?;
                        ix.entries[moved_at] = @intCast(pos + 2);
                    }
                    _ = self.spill.pop();
                    // Draining the spill reverts the set to the inline path
                    // (`spill.items.len > 0` is the spilled discriminator), so
                    // the index must go with it — otherwise the next
                    // `contains`/`remove` reads a stale table over inline keys.
                    if (self.spill.items.len == 0) self.indexDeactivate();
                    return true;
                }
                for (self.spill.items, 0..) |e, i| {
                    if (std.meta.eql(e, key)) {
                        self.spill.items[i] = self.spill.items[self.spill.items.len - 1];
                        _ = self.spill.pop();
                        return true;
                    }
                }
                return false;
            }
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (std.meta.eql(self.buf[i], key)) {
                    self.buf[i] = self.buf[self.len - 1];
                    self.len -= 1;
                    return true;
                }
            }
            return false;
        }

        // --- position-stable iteration support (`#lzdartobservercow`) --------
        //
        // `remove` is swap-remove, so it relocates the tail entry. A site that
        // is iterating the set when a callback re-enters `remove` therefore
        // loses whichever entry was swapped backwards past the cursor — the
        // observer-list reentrancy bug. `at` + `tombstone` + `compactTombstones`
        // give such a site position-stable iteration with no snapshot
        // allocation: entries are overwritten with a caller-chosen sentinel
        // that iteration skips, and the holes are compacted once the outermost
        // iteration finishes.
        //
        // Contract: while any tombstone is live, the set must be mutated only
        // via `getOrPut` (append) and `tombstone`. `remove`'s indexed path
        // repairs the index for the entry it swaps in and would see a sentinel
        // that is deliberately absent from the index.

        /// Positional read. `i` must be `< count()`.
        pub fn at(self: *const Self, i: usize) K {
            if (self.spill.items.len > 0) return self.spill.items[i];
            return self.buf[i];
        }

        /// Overwrite `key` with `tomb` in place, preserving every entry's
        /// position (unlike `remove`). Returns whether `key` was present.
        /// `tomb` must never be a real member of the set.
        pub fn tombstone(self: *Self, key: K, tomb: K) bool {
            if (self.spill.items.len > 0) {
                if (self.indexed()) {
                    const found = self.indexFind(key) orelse return false;
                    const ix = self.index.?;
                    const pos: usize = ix.entries[found] - 2;
                    // Drop the key from the index but keep its slot occupied in
                    // `spill`, so no later entry shifts position.
                    ix.entries[found] = idx_tomb;
                    ix.tombs += 1;
                    self.spill.items[pos] = tomb;
                    return true;
                }
                for (self.spill.items) |*e| {
                    if (std.meta.eql(e.*, key)) {
                        e.* = tomb;
                        return true;
                    }
                }
                return false;
            }
            for (self.buf[0..self.len]) |*e| {
                if (std.meta.eql(e.*, key)) {
                    e.* = tomb;
                    return true;
                }
            }
            return false;
        }

        /// Drop every `tomb` entry, keeping the survivors in order. Allocation-
        /// free: the index only ever shrinks here, so it is refilled into its
        /// existing table.
        pub fn compactTombstones(self: *Self, tomb: K) void {
            if (self.spill.items.len > 0) {
                var write: usize = 0;
                for (self.spill.items) |e| {
                    if (std.meta.eql(e, tomb)) continue;
                    self.spill.items[write] = e;
                    write += 1;
                }
                if (write == self.spill.items.len) return;
                self.spill.shrinkRetainingCapacity(write);
                if (self.indexed()) {
                    // An emptied spill reverts the set to the inline path, so
                    // the index must go with it (same rule as `remove`).
                    if (write == 0) self.indexDeactivate() else self.indexRebuildInPlace();
                }
                return;
            }
            var write: usize = 0;
            var i: usize = 0;
            while (i < self.len) : (i += 1) {
                if (std.meta.eql(self.buf[i], tomb)) continue;
                self.buf[write] = self.buf[i];
                write += 1;
            }
            self.len = write;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.spill.clearRetainingCapacity();
            self.len = 0;
            // A recycled owner must not inherit an index (`#lzspecedgeindex`).
            self.indexDeactivate();
        }

        /// Iterator matching `AutoHashMap.keyIterator()`: `next()` yields
        /// `*K` (a pointer to the stored key), so existing call sites'
        /// `ptr.*` continues to work. The returned pointer is stable for the
        /// duration of a snapshot-then-clear iterate cycle (the only mutation
        /// callers perform after iteration is `clearRetainingCapacity`, which
        /// keeps the backing but resets length).
        pub const KeyIterator = struct {
            set: *Self,
            idx: usize = 0,

            pub fn next(self: *KeyIterator) ?*K {
                if (self.set.spill.items.len > 0) {
                    if (self.idx < self.set.spill.items.len) {
                        const p = &self.set.spill.items[self.idx];
                        self.idx += 1;
                        return p;
                    }
                    return null;
                }
                if (self.idx < self.set.len) {
                    const p = &self.set.buf[self.idx];
                    self.idx += 1;
                    return p;
                }
                return null;
            }
        };

        pub fn keyIterator(self: *Self) KeyIterator {
            return .{ .set = self };
        }
    };
}

/// `*Slot`-keyed edge set — the dependency-edge container for
/// `Slot.change_subscribers` and `Slot.parents`.
pub const SlotEdgeSet = EdgeSet(*Slot, 2);

pub const Slot = struct {
    // Inline small-value storage (`#lzinline`). For `.indirect` values whose
    // size/alignment fit `inline_cap`/`inline_align`, the value lives directly
    // in `inline_buf` instead of a separate heap box: `storage.payload.single_ptr`
    // points at `&inline_buf`. This removes one allocation + one pointer chase
    // per materialization (the dominant `cold_full_recalc` cost) and is safe
    // under invalidate-in-place (`#lzinplace`) because a stale slot is orphaned,
    // not freed, so the interior pointer stays valid for concurrent readers.
    // `storage_inline` gates the per-slot free in `destroySelf`.
    inline_buf: [inline_cap]u8 align(inline_align) = undefined,
    storage: ?Storage,
    change_subscribers: SlotEdgeSet,
    parents: SlotEdgeSet,
    ctx: *Context,
    value_fn_ptr: ?*anyopaque,
    cache_key: ?usize = null,
    id: SlotId = .{ .raw = 0 },
    deinitPayload: ?*const fn (*Slot) void,
    free: ?*const fn (std.mem.Allocator, *anyopaque) void = null,
    // Eager-Signal hooks (default null = lazy/destroy-on-invalidate semantics).
    // on_invalidate: fired instead of destroyUnlocked when a dependency invalidates this slot.
    // recompute: type-erased re-materialize (re-run valueFn, memo guard, swap, emitChange).
    on_invalidate: ?*const fn (*Slot) void = null,
    recompute: ?*const fn (*Slot) void = null,
    // Small fields grouped at the tail (`#lzzigslotpack`): the 1-byte enums and
    // bools are clustered so the struct carries no inter-field padding between
    // them. `storage`/`inline_buf` keep their types and the `#lzinplace`
    // page-stable contract is unchanged — this is a declaration-ordering only.
    mode: Modes,
    /// Pointer classification for the cached value type (std.builtin.Type.Pointer.Size): .one, .many, .slice, .c
    ptr_size: std.builtin.Type.Pointer.Size,
    storage_inline: bool = false,
    stale: bool = false,
    /// Teardown re-entrancy guard (`#lzspecedgeindex`). Latched by
    /// `destroySingleNodeUnlocked` before it runs the user's `deinitPayload`
    /// and never cleared — the node is dead once set, and `initKeyed`'s struct
    /// literal resets it to the default when the arena recycles the slot.
    ///
    /// The graph mutex is reentrant, so a payload destructor that touches the
    /// graph re-enters `Slot.destroy` on the same thread and used to complete a
    /// second, nested teardown of a node the outer frame was still midway
    /// through. The outer frame then resumed against its stale locals and freed
    /// the boxed payload, both edge sets, and the arena id a second time. One
    /// bool tested at the three teardown entry points keeps that O(1) — the
    /// cascade stays scan-free (audit 70cf3e5).
    destroying: bool = false,
    /// Set when a `destroy` arrives while `destroying` is latched. The teardown
    /// path ignores it (the node is already dying). `makeRecomputeFn` latches
    /// `destroying` only around its own `deinitPayload` call, so it reads this
    /// afterwards and performs the deferred teardown once `s` is no longer in
    /// use by that frame (`#lzspecedgeindex`).
    destroy_requested: bool = false,

    /// Inline-storage budget (`#lzinline`). 16 bytes / 16-byte alignment covers
    /// the overwhelming majority of reactive value types — `i64`, `f64`,
    /// `usize`, pointers, `u128`, and 2-word POD structs — without bloating the
    /// per-slot footprint. Larger/over-aligned values fall back to a heap box.
    pub const inline_cap: usize = 16;
    pub const inline_align: usize = 16;

    /// A `.indirect` value qualifies for inline storage when it fits the inline
    /// budget. Comptime-evaluated per `T`, so the branch is compiled away.
    pub fn inlineEligible(comptime T: type) bool {
        return comptime Mode(T) == .indirect and
            @sizeOf(T) <= inline_cap and
            @alignOf(T) <= inline_align;
    }

    pub fn init(
        comptime T: type,
        ctx: *Context,
        valueFn: *const ValueFn(T),
        deinitPayload: ?DeinitPayloadFn,
    ) !*@This() {
        return initKeyed(
            T,
            ctx,
            valueFnCacheKey(valueFn),
            valueFn,
            deinitPayload,
        );
    }

    pub fn initKeyed(
        comptime T: type,
        ctx: *Context,
        cache_key: usize,
        valueFn: *const ValueFn(T),
        deinitPayload: ?DeinitPayloadFn,
    ) !*@This() {
        const mode = comptime Mode(T);
        const ptr_size = comptime Slot.PtrSize(T);
        const free = comptime Free(T);

        // Hold the graph lock across slot allocation → subscribe → valueFn →
        // cache-put. The arena (`pages`/`free_list`/`next_id`) and
        // `instrumentation` are Context state protected by this mutex, exactly
        // like `cache`/`orphaned_slots`/`cascade_scratch` — so the arena alloc
        // must run under the lock (concurrent materializations race the arena;
        // `#lzinplace` cross-thread soak in slot.zig exercises this).
        // `GraphMutex` is reentrant (`#lzparkingmutex`), so valueFn's internal
        // `cell()`/`slot()` calls (which re-lock `ctx.mutex`) are no-ops — they
        // just bump the depth counter. This closes the use-after-free race
        // window (`#lzuafix`): without holding the lock here, a concurrent
        // `Cell.set → emitChange` could free `self` (found via a parent's
        // `change_subscribers`) between the subscribe and the cache-put, then
        // the cache-put would write a dangling pointer.
        ctx.mutex.lock();
        defer ctx.mutex.unlock();

        const self = try ctx.arena.alloc();
        // `arena.alloc` stamps `self.id`; preserve it across the struct literal
        // below (the literal re-initializes every field and would zero `id`).
        const slot_id = self.id;
        ctx.instrumentation.node_allocations += 1;
        self.* = Slot{
            .ctx = ctx,
            .value_fn_ptr = null,
            .cache_key = cache_key,
            .id = slot_id,
            .mode = mode,
            .storage = null,
            .ptr_size = ptr_size,
            .change_subscribers = SlotEdgeSet.init(),
            .parents = SlotEdgeSet.init(),
            .deinitPayload = deinitPayload,
            .free = if (mode == .indirect) free else null,
        };

        const current_slot: ?*Slot = currentSlotFor(ctx);
        if (current_slot) |child_slot| {
            try self.subscribeChangeUnlocked(child_slot);
        }

        var frame = TrackingFrame{
            .prev = null,
            .ctx = ctx,
            .slot = self,
        };
        pushTracking(&frame);
        defer popTracking(&frame);

        const value = try valueFn(ctx);
        self.value_fn_ptr = @ptrCast(@constCast(valueFn));

        switch (comptime Mode(T)) {
            .literal => {
                const stored_value = try Storage.toStoredType(T, ctx, value);
                self.storage = Storage.init(switch (comptime Slot.PtrSize(T)) {
                    .slice => Slot.Storage.Payload{
                        .slice = SliceStorage.init(T, stored_value),
                    },
                    .one, .many, .c => Slot.Storage.Payload{
                        .single_ptr = @ptrCast(@constCast(stored_value)),
                    },
                });
            },
            .indirect => {
                if (comptime Slot.inlineEligible(T)) {
                    // Inline the value in the slot itself (`#lzinline`): no heap
                    // box, no per-slot free. `single_ptr` points at the slot's
                    // own `inline_buf`, which is stable for the slot's lifetime
                    // (slots are never moved, and orphaned-not-freed under
                    // `#lzinplace`).
                    const inline_ptr: *T = @ptrCast(@alignCast(&self.inline_buf));
                    inline_ptr.* = value;
                    self.storage_inline = true;
                    self.storage = Storage.init(.{ .single_ptr = @ptrCast(inline_ptr) });
                } else {
                    const stored_value = try Storage.toStoredType(T, ctx, value);
                    self.storage = Storage.init(.{ .single_ptr = @ptrCast(stored_value) });
                }
            },
        }

        // Dedup + publish in one lookup (`#lzcachegop`, now dense-aware). If
        // another thread (or a re-entrant valueFn) already published a slot for
        // this cache_key, discard `self` — use `destroySelf(true)` (recurse=true)
        // so the new slot's parent edges are unsubscribed (`destroySelf(false)`
        // left dangling references in parents' `change_subscribers`, a
        // pre-existing bug surfaced by the reentrant lock change, since valueFn
        // now actually registers edges before we reach this dedup check under a
        // held lock). Otherwise, `self` is the winner: publish it. This whole
        // block runs under the reentrant `mutex`, so check-then-publish is race-
        // free. `cachePublish` writes to the dense array when enabled (one indexed
        // store) instead of a hash `getOrPut` — folding the former `get` + `put`
        // (two hashes of the 2N-entry cache per materialization) into one.
        if (ctx.cacheLookup(cache_key)) |existing| {
            self.destroySelf(true);
            return existing;
        }
        try ctx.cachePublish(cache_key, self);
        return self;
    }

    pub const GetError = error{SlotMissingPtr};

    /// `*const Slot` (`#lzzigslotconstptr`): the cached-read path holds the
    /// slot via `*Slot` already (`cacheLookup` returns `?*Slot`), so taking the
    /// parameter by pointer eliminates a 256-byte `Slot` memcpy on every warm
    /// read. The body only reads `self.storage`, which auto-dereferences the
    /// `*const` exactly as it did the by-value field access.
    pub fn get(self: *const Slot, comptime T: type) GetError!Result(T) {
        const payload = if (self.storage) |storage| blk: {
            break :blk storage.payload;
        } else {
            return error.SlotMissingPtr;
        };

        return switch (comptime Mode(T)) {
            .literal => switch (comptime Slot.PtrSize(T)) {
                .slice => blk: {
                    const slice_storage = payload.slice;
                    break :blk slice_storage.toSlice(T);
                },
                .one, .many, .c => @as(T, @ptrCast(@alignCast(payload.single_ptr))),
            },
            .indirect => @as(*T, @ptrCast(@alignCast(payload.single_ptr))),
        };
    }

    pub const GetPtrError = error{ LiteralHasNoPtr, SlotMissingPtr };

    pub fn getPtr(self: *const Slot, comptime T: type) GetPtrError!*T {
        const payload = if (self.storage) |storage| storage.payload else return error.SlotMissingPtr;
        return switch (comptime Mode(T)) {
            .literal => return error.LiteralHasNoPtr,
            .indirect => @as(*T, @ptrCast(@alignCast(payload.single_ptr))),
        };
    }

    pub fn subscribeChange(self: *Slot, child: *Slot) !void {
        self.ctx.mutex.lock();
        defer self.ctx.mutex.unlock();
        try self.subscribeChangeUnlocked(child);
    }

    pub fn subscribeChangeUnlocked(self: *Slot, child: *Slot) !void {
        try self.change_subscribers.getOrPut(child, self.ctx.allocator);
        try child.parents.getOrPut(self, self.ctx.allocator);
        self.ctx.bump("dependency_edges_added");
    }

    pub fn unsubscribeChange(self: *Slot, child: *Slot) void {
        self.ctx.mutex.lock();
        defer self.ctx.mutex.unlock();
        try self.unsubscribeChangeUnlocked(child);
    }

    pub fn unsubscribeChangeUnlocked(self: *Slot, child: *Slot) void {
        _ = self.change_subscribers.remove(child);
        _ = child.parents.remove(self);
        self.ctx.bump("dependency_edges_removed");
    }

    /// Thread-safe call to Slot.touchUnlocked.
    ///
    /// `ctx` is captured into a local BEFORE `touchUnlocked()` because the
    /// destroy path frees `self` (destroySelf → `allocator.destroy(self)`);
    /// the deferred unlock must not dereference freed `self.ctx`. This was a
    /// latent use-after-free that Zig 0.17's `std.atomic.Mutex.unlock()`
    /// assertion (`state == .locked`) turned into a hard crash.
    pub fn touch(self: *Slot) void {
        const ctx = self.ctx;
        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        self.touchUnlocked();
    }

    /// Slot.touchUnlocked marks self stale and cascades to all dependents.
    /// See `invalidateSlotUnlocked`. Invalidate-in-place (`#lzinplace`): the
    /// slot is NOT freed — its storage pointer stays valid for readers on
    /// other threads. The slot is refreshed (removed from cache + recreated)
    /// on the next read via `slotKeyed`'s stale check.
    pub fn touchUnlocked(self: *Slot) void {
        self.invalidateSlotUnlocked();
    }

    /// Thread-safe call to Slot.emitChangeUnlocked.
    pub fn emitChange(self: *Slot) void {
        self.ctx.mutex.lock();
        self.emitChangeUnlocked();
        self.ctx.mutex.unlock();
        self.ctx.drainPendingRecompute();
    }

    /// Emits the change event to all change_subscribers. See Slot.subscribeChange.
    ///
    /// Dependents are snapshotted into an allocator-backed slice and the
    /// `change_subscribers` map is cleared BEFORE iterating, fixing the latent
    /// iteration-during-mutation bug (destroyUnlocked → unsubscribeChangeUnlocked
    /// previously removed entries from the map mid-iteration).
    ///
    /// For each dependent:
    /// - If `on_invalidate` is set (Signal-backed slot): call the hook (enqueue
    ///   for deferred recompute, mark stale). The slot is NOT destroyed.
    /// - Otherwise: `invalidateSlotUnlocked()` — mark stale + cascade. The
    ///   slot is NOT freed (invalidate-in-place, `#lzinplace`). Its storage
    ///   pointer stays valid for readers on other threads. The slot is
    ///   refreshed on the next read via `slotKeyed`'s stale check.
    pub fn emitChangeUnlocked(self: *Slot) void {
        const subscriber_count = self.change_subscribers.count();
        if (subscriber_count == 0) return;

        // Iterative cascade (`#lziterbfs`, the #lzbatchborrow port): seed the
        // shared worklist with this slot's direct dependents, then drain. This
        // replaces the per-call `allocator.alloc(*Slot, count)` snapshot the
        // recursive version took; the Context-owned `cascade_scratch` is grown
        // once and reused.
        //
        // The snapshot-before-iterate invariant that fixed #lzuafix is
        // preserved: `self.change_subscribers` is drained into the worklist
        // and cleared BEFORE any dependent is processed, so a re-entrant
        // unsubscribe cannot mutate the set mid-iteration. (`on_invalidate`
        // hooks only mutate `s.stale` + `pending_recompute`, never the
        // parent's edge set, so the live drain is safe.)
        const ctx = self.ctx;
        const wl = &ctx.cascade_scratch;
        std.debug.assert(wl.items.len == 0); // always empty on entry
        defer wl.clearRetainingCapacity();

        {
            var iter = self.change_subscribers.keyIterator();
            while (iter.next()) |ptr| {
                const dependent_slot = ptr.*;
                _ = dependent_slot.parents.remove(self);
                if (dependent_slot.on_invalidate) |hook| {
                    hook(dependent_slot);
                } else {
                    wl.append(ctx.allocator, dependent_slot) catch {};
                }
            }
            self.change_subscribers.clearRetainingCapacity();
        }

        drainCascadeWorklist(ctx);
    }

    /// Drain `ctx.cascade_scratch` as an iterative DFS invalidation worklist
    /// (`#lziterbfs`). Each pop is marked stale (idempotency guard skips
    /// already-stale nodes, handling diamonds), then its dependents are pushed.
    /// A node's `change_subscribers` is cleared after its children are pushed,
    /// so children processing (deferred to future pops) never observes a
    /// half-iterated set — the snapshot-before-iterate invariant from #lzuafix.
    fn drainCascadeWorklist(ctx: *Context) void {
        const wl = &ctx.cascade_scratch;
        while (wl.pop()) |node| {
            if (node.stale) continue;
            node.stale = true;

            if (node.change_subscribers.count() == 0) continue;
            var iter = node.change_subscribers.keyIterator();
            while (iter.next()) |ptr| {
                const child = ptr.*;
                _ = child.parents.remove(node);
                if (child.on_invalidate) |hook| {
                    hook(child);
                } else {
                    wl.append(ctx.allocator, child) catch {};
                }
            }
            node.change_subscribers.clearRetainingCapacity();
        }
    }

    /// Invalidate-in-place (`#lzinplace`): mark this slot stale and cascade to
    /// all transitive dependents. Does NOT free the slot, does NOT remove it
    /// from the cache. The slot's storage pointer stays valid for readers on
    /// other threads. On the next read, `slotKeyed` detects staleness, removes
    /// the slot from the cache (orphaning it), and creates a fresh slot via
    /// `initKeyed`. The orphaned slot is freed at `Context.deinit`.
    ///
    /// This replaces the previous `destroyUnlocked(true)` call site in
    /// `emitChangeUnlocked` and `touchUnlocked`. The destroy-on-invalidate
    /// model freed slots whose storage pointers readers on other threads
    /// held — a use-after-free that caused SEGV under concurrent same-cell
    /// writes. Invalidate-in-place eliminates the UAF by never freeing during
    /// invalidation.
    pub fn invalidateSlotUnlocked(self: *Slot) void {
        if (self.stale) return; // already stale — skip (prevents infinite cascade)

        const ctx = self.ctx;
        const wl = &ctx.cascade_scratch;
        std.debug.assert(wl.items.len == 0); // always empty on entry
        defer wl.clearRetainingCapacity();

        wl.append(ctx.allocator, self) catch return;
        drainCascadeWorklist(ctx);
    }

    /// AUDIT ONLY (`#lzspecedgeindex`, `build_options.naive_destroy_scan`).
    ///
    /// The naive alternative to the O(1) tombstone: search `pending_recompute`
    /// for this slot's entry and compact it out. Modelled on lazily-rs's
    /// pre-2b98ca6 `Vec::retain`, which walks `len` unconditionally rather than
    /// stopping at the first hit — so a mass teardown while the queue is
    /// saturated is O(pending) per node, O(W^2) per cohort. Compiles to nothing
    /// in shipped builds.
    inline fn naiveDestroyRemoveScan(self: *Slot) void {
        if (comptime !build_options.naive_destroy_scan) return;
        const items = self.ctx.pending_recompute.items;
        var keep: usize = 0;
        for (items) |q| {
            if (q == self) continue;
            items[keep] = q;
            keep += 1;
        }
        self.ctx.pending_recompute.items.len = keep;
    }

    pub fn destroy(self: *Slot, recurse: ?bool) void {
        // Capture ctx before destroyUnlocked: the destroy path frees `self`,
        // so the deferred unlock must not dereference freed `self.ctx`.
        const ctx = self.ctx;
        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        self.destroyUnlocked(recurse);
    }

    pub fn destroyUnlocked(self: *Slot, recurse: ?bool) void {
        // Already claimed by an outer frame (`#lzspecedgeindex`) — the way to
        // get here is a `deinitPayload` calling back into the graph. That frame
        // owns the node's lifetime, so record the request and absorb this call
        // rather than tearing the same node down a second time. `destroySelf`
        // (teardown) drops the request; `makeRecomputeFn` honors it.
        if (self.destroying) {
            self.destroy_requested = true;
            return;
        }

        // Remove from cache if not already cleared by Context.deinit
        if (self.cache_key) |cache_key| {
            self.ctx.cacheRemove(cache_key);
        } else {
            unreachable;
        }

        self.destroySelf(recurse);
    }

    /// Destroys the value and its subscribers recursively.
    /// Internal version: assumes ctx.mutex is ALREADY held.
    ///
    /// Iterative teardown (`#lziterbfs`): the transitive dependent cone is
    /// pushed onto the shared `cascade_scratch` worklist and each node is
    /// freed as it pops. This replaces the recursive `destroyUnlocked(true)`
    /// cascade and the per-level `allocator.alloc(*Slot, count)` snapshots it
    /// took on both edge maps.
    ///
    /// The snapshot-before-iterate invariant that fixed #lzuafix is preserved
    /// *structurally* rather than via a snapshot buffer: child destruction is
    /// deferred to a future pop, so the only mutations performed while
    /// iterating a node's edge set land on *other* nodes' sets
    /// (`parent.change_subscribers.remove(node)` for parents,
    /// `dependent.parents.remove(node)` for subscribers). The iterated set is
    /// cleared right after the drain, never mutated mid-iteration.
    pub fn destroySelf(self: *Slot, recurse: ?bool) void {
        if (self.destroying) return; // see `destroyUnlocked`

        if (recurse == false) {
            self.destroySingleNodeUnlocked();
            return;
        }

        const ctx = self.ctx;
        const wl = &ctx.cascade_scratch;
        // Nested cascades share this scratch worklist (`#lzspecedgeindex`): a
        // `deinitPayload` running under `destroySingleNodeUnlocked` can destroy
        // some *other* live node, and that cascade nests inside this one. Claim
        // the region above `base` rather than assuming sole ownership. The old
        // `assert(wl.items.len == 0)` tripped on any nested cascade in Debug,
        // and in release the paired `clearRetainingCapacity()` dropped the
        // outer cascade's not-yet-destroyed nodes on the floor — leaking them
        // and leaving their reverse edges pointing at freed parents.
        const base = wl.items.len;
        defer wl.items.len = base;

        wl.append(ctx.allocator, self) catch {
            // OOM seeding the worklist — at least free this node.
            self.destroySingleNodeUnlocked();
            return;
        };

        while (wl.items.len > base) {
            const node = wl.pop().?;
            // Only a node with live storage owns edges to tear down (matches
            // the original `if (self.storage) |storage|` guard).
            if (node.storage != null) {
                // Parents: drop the reverse edge on each parent. Iterating
                // `node.parents` live is safe — `parent.change_subscribers`
                // is a different set; `node.parents` itself is cleared after.
                if (node.parents.count() > 0) {
                    var piter = node.parents.keyIterator();
                    while (piter.next()) |ptr| {
                        const parent_slot = ptr.*;
                        _ = parent_slot.change_subscribers.remove(node);
                        ctx.bump("dependency_edges_removed");
                    }
                    node.parents.clearRetainingCapacity();
                }

                // Subscribers: drop the reverse edge and enqueue the dependent
                // for destruction. `cacheRemove` runs here so a re-entrant
                // materialization cannot re-publish a doomed slot.
                if (node.change_subscribers.count() > 0) {
                    var siter = node.change_subscribers.keyIterator();
                    while (siter.next()) |ptr| {
                        const dependent_slot = ptr.*;
                        _ = dependent_slot.parents.remove(node);
                        if (dependent_slot.cache_key) |ck| ctx.cacheRemove(ck);
                        wl.append(ctx.allocator, dependent_slot) catch {};
                    }
                    node.change_subscribers.clearRetainingCapacity();
                }
            }

            node.destroySingleNodeUnlocked();
        }
    }

    /// Free one slot's payload storage + edge-map backing + the slot struct
    /// itself. No cascade, no reverse-edge cleanup. Used by both the
    /// `recurse == false` fast path and the iterative `destroySelf` per-node
    /// step.
    fn destroySingleNodeUnlocked(self: *Slot) void {
        // Re-entrancy latch (`#lzspecedgeindex`). Set BEFORE `deinitPayload`
        // runs, so a destructor that calls back into the graph finds the node
        // already claimed and its nested teardown is absorbed. Without this the
        // nested frame ran to completion — freeing the boxed payload, both edge
        // sets, and the arena id — and then this frame resumed and freed all
        // three again from its stale `storage` local.
        if (self.destroying) return;
        self.destroying = true;

        // Tombstone this node's `pending_recompute` entry, if it has one
        // (`#lzspecedgeindex`). A Signal/Effect-backed slot destroyed between
        // its `on_invalidate` enqueue and the next drain would otherwise leave
        // a pointer to torn-down (and arena-recycled) memory in the queue for
        // `drainPendingRecompute` to pop and run — a use-after-free reachable
        // from safe user code.
        //
        // The queue is scan-free by design (audit 70cf3e5), so this must NOT
        // search for the entry. `stale` is already the O(1) enqueue guard and
        // is only ever cleared at pop, so clearing it here marks the entry dead
        // in O(1) and the drain discards it. Mirrors lazily-rs 2b98ca6.
        self.stale = false;
        naiveDestroyRemoveScan(self);

        if (self.storage) |storage| {
            if (self.deinitPayload) |deinitPayload| {
                deinitPayload(self);
            }
            if (self.mode == .indirect and !self.storage_inline) {
                if (self.free) |free_fn| {
                    free_fn(self.ctx.allocator, storage.payload.single_ptr);
                }
            } else if (self.ptr_size == .slice) {
                // Direct slices also need to be freed if they were allocated in toStoredType
                // However, toStoredType currently only allocates for .indirect.
                // If toStoredType is updated to dupe slices, this would be needed.
            }
            self.storage = null;
        }
        self.change_subscribers.deinit(self.ctx.allocator);
        self.parents.deinit(self.ctx.allocator);
        self.ctx.arena.free(self.id);
    }

    pub const Modes = enum { literal, indirect };
    pub fn Mode(comptime T: type) Modes {
        const type_info = @typeInfo(T);
        const is_pointer = type_info == .pointer;
        // Storage strategy: .literal for pointers/slices, .indirect others
        return if (is_pointer) .literal else .indirect;
    }

    pub fn Result(comptime T: type) type {
        return switch (comptime Mode(T)) {
            .literal => T,
            .indirect => *T,
        };
    }

    pub fn PtrSize(comptime T: type) std.builtin.Type.Pointer.Size {
        return @typeInfo(Slot.Result(T)).pointer.size;
    }

    pub fn StorageKind(comptime T: type) enum { single_ptr, slice } {
        return switch (comptime Mode(T)) {
            .literal => switch (comptime PtrSize(T)) {
                .slice => .slice,
                .one, .many, .c => .single_ptr,
            },
            .indirect => .single_ptr,
        };
    }

    pub const Storage = struct {
        pub const Payload = union(enum) {
            single_ptr: *anyopaque,
            slice: SliceStorage,
        };

        payload: Payload,
        pub fn init(payload: Payload) Storage {
            return .{ .payload = payload };
        }

        /// Converts a computed value `T` into the storage representation `StoredType(T)`.
        /// - `.literal`: no allocation, returns the value as-is
        /// - `.indirect`: allocates `T` in `ctx.allocator` and returns `*T`
        pub fn toStoredType(comptime T: type, ctx: *Context, value: T) !Result(T) {
            return switch (comptime Mode(T)) {
                .literal => value,
                .indirect => blk: {
                    const stored_value = try ctx.allocator.create(T);
                    stored_value.* = value;
                    break :blk stored_value;
                },
            };
        }
    };

    /// Type-erased slice handler that works with any element type
    /// TODO: Is this needed with the addition of Owned?
    pub const SliceStorage = struct {
        ptr: *anyopaque,
        len: usize, // Number of elements (not bytes)
        mode: Slot.Modes,
        element_size: usize, // @sizeOf(T)
        free: *const fn (std.mem.Allocator, *anyopaque, usize, usize) void,

        /// Create a `SliceStorage` for any slice type
        pub fn init(comptime T: type, value: T) SliceStorage {
            const type_info = @typeInfo(T);
            if (type_info != .pointer) {
                @compileError("SliceStorage.init requires a pointer/slice type");
            }
            const element_type = type_info.pointer.child;

            return .{
                .ptr = @ptrCast(@constCast(value.ptr)),
                .len = value.len,
                .mode = Mode(element_type),
                .element_size = @sizeOf(element_type),
                .free = struct {
                    fn free(
                        allocator: std.mem.Allocator,
                        ptr: *anyopaque,
                        len: usize,
                        element_size: usize,
                    ) void {
                        _ = element_size; // For debugging/validation
                        const slice: T = @as([*]element_type, @ptrCast(@alignCast(ptr)))[0..len];
                        allocator.free(slice);
                    }
                }.free,
            };
        }

        /// Reconstruct the original slice type `T` from this storage.
        /// `T` must be a slice type (pointer size `.slice`), e.g. `[]u8`, `[]const u8`, `[]MyType`.
        pub fn toSlice(self: SliceStorage, comptime T: type) T {
            const type_info = @typeInfo(T);
            if (type_info != .pointer or type_info.pointer.size != .slice) {
                const message = std.fmt.comptimePrint(
                    "SliceStorage.unpack requires a slice type (e.g. []u8, []const u8). Got {}",
                    .{T},
                );
                @compileError(message);
            }

            const element_type = type_info.pointer.child;

            // Best-effort validation: helps catch mismatched T at runtime in Debug/ReleaseSafe.
            std.debug.assert(self.element_size == @sizeOf(element_type));

            return @as([*]element_type, @ptrCast(@alignCast(self.ptr)))[0..self.len];
        }
    };

    /// Create a free function that knows the type `T`
    pub fn Free(comptime T: type) ?*const fn (std.mem.Allocator, *anyopaque) void {
        return switch (comptime Slot.Mode(T)) {
            .literal => null,
            .indirect => struct {
                fn free(allocator: std.mem.Allocator, ptr: *anyopaque) void {
                    allocator.destroy(@as(*T, @ptrCast(@alignCast(ptr))));
                }
            }.free,
        };
    }

    pub fn DeinitValueFn(comptime T: type) type {
        return *const fn (*Context, *const ValueFn(T), T) void;
    }
    pub const DeinitPayloadFn = *const fn (*Slot) void;
};

pub fn ValueFn(comptime T: type) type {
    return fn (*Context) anyerror!T;
}

pub const SubscriberKey = struct {
    ctx_ptr: usize, // @intFromPtr(ctx) or 0 if null
    cb_ptr: usize, // @intFromPtr(callback)
};

pub fn subscriberKey(ctx: *Context, valueFn: anytype) SubscriberKey {
    return .{
        .ctx_ptr = @intFromPtr(ctx),
        .cb_ptr = @intFromPtr(valueFn),
    };
}

pub const SubscriberSet = std.AutoHashMap(SubscriberKey, void);

const SlotCallback = *const fn (ctx: *Context, slot: *Slot) void;

pub const TrackingFrame = struct {
    prev: ?*TrackingFrame,
    ctx: *Context,
    slot: *Slot,
};

/// The top of the stack for the CURRENT thread.
/// This stack may contain frames from different Contexts if they are interleaved.
threadlocal var tracking_top: ?*TrackingFrame = null;

pub fn pushTracking(frame: *TrackingFrame) void {
    frame.prev = tracking_top;
    tracking_top = frame;
}

pub fn popTracking(frame: *TrackingFrame) void {
    // Basic safety check
    if (tracking_top == frame) {
        tracking_top = frame.prev;
    }
}

/// Finds the most recent slot being computed for the given context ON THIS THREAD.
///
/// Fast path (`#lztrackfast`): the overwhelmingly common case is a single
/// tracking frame whose `ctx` matches, so we check the stack top first and
/// return in O(1) without walking the linked list. This mirrors lazily-rs
/// `current_tracking_frame`, which reads only the stack top (O(1)). The walk
/// is retained as the fallback for the rare interleaved-multi-context case.
pub fn currentSlotFor(ctx: *Context) ?*Slot {
    const top = tracking_top orelse return null;
    if (top.ctx == ctx) return top.slot;
    var it = top.prev;
    while (it) |f| : (it = f.prev) {
        if (f.ctx == ctx) return f.slot;
    }
    return null;
}

export fn initContext() FfiResult {
    // Default allocator: c_allocator when libc is linked (max throughput /
    // multi-thread scaling / long-running-process stability), else raw pages.
    // Callers that want a different backing allocator (debug/arena/smp/c/page/
    // wasm) use `init_context_with_mode` instead.
    const allocator = if (comptime build_options.link_libc)
        std.heap.c_allocator
    else
        std.heap.page_allocator;

    const ctx = Context.init(allocator) catch |err| {
        return FfiResult.initError(
            @intFromError(err),
            "Failed to initialize Context",
        );
    };

    return FfiResult.initSuccess(ctx);
}
comptime {
    @export(&initContext, .{ .name = "init_context" });
}

/// FFI entry: create a Context backed by the requested `AllocatorMode`.
///
/// Stateless modes (page/wasm/c) resolve directly to an allocator with no
/// state to own. Stateful modes (debug/arena/smp) are hosted in an
/// `AllocatorHandle` (allocated by a stateless bootstrap allocator) and wired
/// as a Context post-deinit hook so the state is released only after the
/// Context struct has been freed.
export fn initContextWithMode(mode: AllocatorMode) FfiResult {
    if (statelessAllocatorFor(mode)) |a| {
        const ctx = Context.init(a) catch {
            return FfiResult.initError(
                @intFromError(error.OutOfMemory),
                "Failed to initialize Context",
            );
        };
        return FfiResult.initSuccess(ctx);
    }

    const handle = AllocatorHandle.create(mode) catch {
        return FfiResult.initError(
            @intFromError(error.OutOfMemory),
            "Failed to create allocator handle",
        );
    };
    const ctx = Context.init(handle.allocator()) catch {
        handle.destroy();
        return FfiResult.initError(
            @intFromError(error.OutOfMemory),
            "Failed to initialize Context",
        );
    };
    ctx.post_deinit_fn = AllocatorHandle.destroyFromHook;
    ctx.post_deinit_state = handle;
    return FfiResult.initSuccess(ctx);
}
comptime {
    @export(&initContextWithMode, .{ .name = "init_context_with_mode" });
}

/// Resolve a stateless `AllocatorMode` to its allocator, or null for stateful
/// modes. Comptime-guarded so libc/wasm-only allocators are never referenced
/// on targets that lack them.
fn statelessAllocatorFor(mode: AllocatorMode) ?std.mem.Allocator {
    const c_alloc: ?std.mem.Allocator = if (build_options.link_libc)
        std.heap.c_allocator
    else
        null;
    const is_wasm = builtin.target.cpu.arch == .wasm32 or
        builtin.target.cpu.arch == .wasm64;
    const wasm_alloc: ?std.mem.Allocator = if (is_wasm)
        std.heap.wasm_allocator
    else
        null;

    return switch (mode) {
        .page => std.heap.page_allocator,
        .smp => std.heap.smp_allocator,
        .c => c_alloc,
        .wasm => wasm_alloc,
        // Stateful modes own state via an AllocatorHandle instead.
        .debug, .arena => null,
    };
}

export fn deinitContext(ctx: *Context) void {
    ctx.deinit();
}
comptime {
    @export(&deinitContext, .{ .name = "deinit_context" });
}

test "lazily/context.Context: post-deinit hook fires after free" {
    const allocator = std.testing.allocator;
    const HookState = struct {
        var fired = std.atomic.Value(bool).init(false);
        fn hook(state: *anyopaque) void {
            _ = state;
            fired.store(true, .seq_cst);
        }
    };
    HookState.fired.store(false, .seq_cst);

    const ctx = try Context.init(allocator);
    ctx.post_deinit_fn = HookState.hook;
    ctx.post_deinit_state = @ptrCast(ctx);
    ctx.deinit();

    // Hook ran only after the Context struct was released.
    try std.testing.expect(HookState.fired.load(.seq_cst));
}

test "lazily/context.initContextWithMode: stateless page-backed context" {
    const result = initContextWithMode(.page);
    try std.testing.expect(result.isSuccess());
    const ctx: *Context = @ptrCast(@alignCast(result.ptr.?));
    // No post-deinit hook for stateless modes.
    try std.testing.expect(ctx.post_deinit_fn == null);

    const buf = try ctx.allocator.alloc(u8, 64);
    ctx.allocator.free(buf);

    deinitContext(ctx);
}

test "lazily/context.initContextWithMode: arena-backed context soak" {
    // iteration allocates the Context + cache through the arena, exercises the
    // backing allocator, then deinits (Context freed via arena, hook tears the
    // arena down only after).
    const iterations = 50;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const result = initContextWithMode(.arena);
        try std.testing.expect(result.isSuccess());
        const ctx: *Context = @ptrCast(@alignCast(result.ptr.?));
        try std.testing.expect(ctx.post_deinit_fn != null);

        const buf = try ctx.allocator.alloc(u8, 128);
        ctx.allocator.free(buf);

        deinitContext(ctx);
    }
}

test "lazily/context: instrumentation counters track allocations, edges, and recomputes" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const CellMod = @import("cell.zig");
    const sig_mod = @import("signal.zig");

    const getSource = struct {
        fn call(_: *Context) anyerror!u32 {
            return 0;
        }
    }.call;
    const source = try CellMod.cell(u32, ctx, getSource, null);

    const before = ctx.instrumentationSnapshot();
    // A signal that reads the cell establishes a dependency edge.
    const getDerived = struct {
        fn call(c: *Context) anyerror!u32 {
            const src = try CellMod.cell(u32, c, getSource, null);
            return src.get() + 1;
        }
    }.call;
    const sig = try sig_mod.signal(u32, ctx, getDerived, null);
    defer ctx.allocator.destroy(sig);
    const after_setup = ctx.instrumentationSnapshot();
    try std.testing.expect(after_setup.node_allocations > before.node_allocations);
    try std.testing.expect(after_setup.dependency_edges_added > before.dependency_edges_added);

    // Setting the source triggers an eager recompute (Signal).
    source.set(7);
    const after_set = ctx.instrumentationSnapshot();
    try std.testing.expect(after_set.slot_recomputes > after_setup.slot_recomputes);

    ctx.resetInstrumentation();
    try std.testing.expectEqual(@as(u64, 0), ctx.instrumentationSnapshot().node_allocations);
}

// ---------------------------------------------------------------------------
// SlotEdgeSet (`#lzedgeinline`) — the inline-capacity dependency-edge container.
// SlotEdgeSet only stores and compares `*Slot` pointers (never dereferences
// them), so these tests fabricate distinct, well-aligned fake tokens rather
// than materializing real slots. This directly exercises the inline→spill
// transition, dedup, swap-remove, iteration, and clear — the paths not covered
// by the graph's low-degree fixtures.
// ---------------------------------------------------------------------------

fn fakeSlot(i: usize) *Slot {
    // 64-byte stride keeps every token distinct and ≥16-aligned (Slot's
    // alignment). Never dereferenced.
    return @ptrFromInt((i + 1) * 64);
}

test "lazily/context.SlotEdgeSet: inline fill, spill, dedup, iterate, remove, clear" {
    const a = std.testing.allocator;
    var set = SlotEdgeSet.init();
    defer set.deinit(a);

    // Fill exactly to inline capacity — stays inline (no spill).
    var i: usize = 0;
    while (i < SlotEdgeSet.inline_cap) : (i += 1) try set.getOrPut(fakeSlot(i), a);
    try std.testing.expectEqual(SlotEdgeSet.inline_cap, set.count());
    try std.testing.expect(set.spill.items.len == 0);

    // Dedup: re-adding an existing key does not grow the set.
    try set.getOrPut(fakeSlot(0), a);
    try std.testing.expectEqual(SlotEdgeSet.inline_cap, set.count());
    try std.testing.expect(set.spill.items.len == 0);

    // One more distinct key spills to the heap ArrayList, preserving every entry.
    try set.getOrPut(fakeSlot(SlotEdgeSet.inline_cap), a);
    try std.testing.expectEqual(SlotEdgeSet.inline_cap + 1, set.count());
    try std.testing.expect(set.spill.items.len > 0);

    // Iterate: every inserted key appears exactly once.
    var seen: usize = 0;
    var it = set.keyIterator();
    while (it.next()) |ptr| {
        var found = false;
        var j: usize = 0;
        while (j <= SlotEdgeSet.inline_cap) : (j += 1) {
            if (fakeSlot(j) == ptr.*) found = true;
        }
        try std.testing.expect(found);
        seen += 1;
    }
    try std.testing.expectEqual(SlotEdgeSet.inline_cap + 1, seen);

    // Remove from the spilled ArrayList; second remove reports absence.
    try std.testing.expect(set.remove(fakeSlot(0)));
    try std.testing.expect(!set.remove(fakeSlot(0)));
    try std.testing.expectEqual(SlotEdgeSet.inline_cap, set.count());

    set.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), set.count());
}

test "lazily/context.SlotEdgeSet: inline swap-remove keeps remaining keys, no spill" {
    const a = std.testing.allocator;
    var set = SlotEdgeSet.init();
    defer set.deinit(a);

    // Fill exactly to inline capacity (2) — stays inline.
    try set.getOrPut(fakeSlot(0), a);
    try set.getOrPut(fakeSlot(1), a);
    try std.testing.expect(set.spill.items.len == 0);
    try std.testing.expectEqual(SlotEdgeSet.inline_cap, set.count());

    // Swap-remove one entry: the survivor stays, still inline.
    try std.testing.expect(set.remove(fakeSlot(0)));
    try std.testing.expect(!set.remove(fakeSlot(0)));
    try std.testing.expectEqual(@as(usize, 1), set.count());

    // The survivor still resolves via iteration.
    var have1 = false;
    var it = set.keyIterator();
    while (it.next()) |ptr| {
        if (ptr.* == fakeSlot(1)) have1 = true;
    }
    try std.testing.expect(have1);

    // Re-adding fills the freed inline slot without ever spilling.
    try set.getOrPut(fakeSlot(0), a);
    try std.testing.expectEqual(SlotEdgeSet.inline_cap, set.count());
    try std.testing.expect(set.spill.items.len == 0);
}


// ---------------------------------------------------------------------------
// Wide-fanout hash index (`#lzspecedgeindex`).
//
// The pre-existing SlotEdgeSet tests top out at `inline_cap + 1` = 3 entries,
// so they never reach `promote_threshold`. These exercise the promoted path:
// promotion boundary, dedup/remove/contains equivalence with the scan, the
// swap-remove reindex, tombstone reclamation, clear-drops-the-index (recycled
// owners), and the threshold+-1 oscillation that thrashes a naive
// promote/demote pair.
// ---------------------------------------------------------------------------

test "lazily/context.SlotEdgeSet index: promotes exactly at the threshold" {
    const a = std.testing.allocator;
    var set = SlotEdgeSet.init();
    defer set.deinit(a);

    var i: usize = 0;
    while (i < SlotEdgeSet.promote_threshold - 1) : (i += 1) try set.getOrPut(fakeSlot(i), a);
    try std.testing.expect(!set.indexed());
    try std.testing.expectEqual(SlotEdgeSet.promote_threshold - 1, set.count());

    try set.getOrPut(fakeSlot(SlotEdgeSet.promote_threshold - 1), a);
    try std.testing.expect(set.indexed());
    try std.testing.expectEqual(SlotEdgeSet.promote_threshold, set.count());
}

test "lazily/context.SlotEdgeSet index: dedup, contains, remove match the scan" {
    const a = std.testing.allocator;
    const n = SlotEdgeSet.promote_threshold * 8;

    var set = SlotEdgeSet.init();
    defer set.deinit(a);

    var i: usize = 0;
    while (i < n) : (i += 1) try set.getOrPut(fakeSlot(i), a);
    try std.testing.expect(set.indexed());
    try std.testing.expectEqual(n, set.count());

    // Every key present; a key never inserted is absent.
    i = 0;
    while (i < n) : (i += 1) try std.testing.expect(set.contains(fakeSlot(i)));
    try std.testing.expect(!set.contains(fakeSlot(n + 1)));

    // Re-adding every key is a no-op (dedup through the index).
    i = 0;
    while (i < n) : (i += 1) try set.getOrPut(fakeSlot(i), a);
    try std.testing.expectEqual(n, set.count());

    // Remove every *odd* key. The swap-remove has to repoint the moved tail
    // entry or the survivors go missing.
    i = 1;
    while (i < n) : (i += 2) try std.testing.expect(set.remove(fakeSlot(i)));
    try std.testing.expectEqual(n / 2, set.count());
    try std.testing.expect(!set.remove(fakeSlot(1)));

    i = 0;
    while (i < n) : (i += 1) {
        const want_present = (i % 2 == 0);
        try std.testing.expectEqual(want_present, set.contains(fakeSlot(i)));
    }

    // Iteration still yields exactly the survivors, once each.
    var seen: usize = 0;
    var it = set.keyIterator();
    while (it.next()) |ptr| {
        try std.testing.expect(set.contains(ptr.*));
        seen += 1;
    }
    try std.testing.expectEqual(n / 2, seen);
}

test "lazily/context.SlotEdgeSet index: tombstones are reclaimed under churn" {
    const a = std.testing.allocator;
    const n = SlotEdgeSet.promote_threshold * 2;

    var set = SlotEdgeSet.init();
    defer set.deinit(a);

    var i: usize = 0;
    while (i < n) : (i += 1) try set.getOrPut(fakeSlot(i), a);

    // Remove-then-reinsert the whole set many times. Without tombstone
    // reclamation the table saturates and `indexFind` never terminates.
    var round: usize = 0;
    while (round < 50) : (round += 1) {
        i = 0;
        while (i < n) : (i += 1) try std.testing.expect(set.remove(fakeSlot(i)));
        try std.testing.expectEqual(@as(usize, 0), set.count());
        i = 0;
        while (i < n) : (i += 1) try set.getOrPut(fakeSlot(i), a);
        try std.testing.expectEqual(n, set.count());
    }
    i = 0;
    while (i < n) : (i += 1) try std.testing.expect(set.contains(fakeSlot(i)));
}

test "lazily/context.SlotEdgeSet index: clear drops the index (recycled owner)" {
    const a = std.testing.allocator;
    var set = SlotEdgeSet.init();
    defer set.deinit(a);

    var i: usize = 0;
    while (i < SlotEdgeSet.promote_threshold) : (i += 1) try set.getOrPut(fakeSlot(i), a);
    try std.testing.expect(set.indexed());

    set.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), set.count());
    try std.testing.expect(!set.indexed());
    // The allocation is retained, but the *contents* must not be trusted: a
    // recycled owner refilling with unrelated keys must not see the old ones.
    try std.testing.expect(set.index != null and set.index.?.entries.len > 0);

    try set.getOrPut(fakeSlot(9999), a);
    try std.testing.expectEqual(@as(usize, 1), set.count());
    try std.testing.expect(set.contains(fakeSlot(9999)));
    i = 0;
    while (i < SlotEdgeSet.promote_threshold) : (i += 1) {
        try std.testing.expect(!set.contains(fakeSlot(i)));
    }

    // Refilling past the threshold re-promotes without reallocating.
    i = 0;
    while (i < SlotEdgeSet.promote_threshold) : (i += 1) try set.getOrPut(fakeSlot(i), a);
    try std.testing.expect(set.indexed());
    i = 0;
    while (i < SlotEdgeSet.promote_threshold) : (i += 1) try std.testing.expect(set.contains(fakeSlot(i)));
}

test "lazily/context.SlotEdgeSet index: oscillating across the threshold is stable" {
    // A dependent list that gains and loses one edge per recompute sits exactly
    // on the promote boundary. With no demotion this must stay indexed and
    // must not rebuild; correctness is asserted either way.
    const a = std.testing.allocator;
    const t = SlotEdgeSet.promote_threshold;

    var set = SlotEdgeSet.init();
    defer set.deinit(a);

    var i: usize = 0;
    while (i < t) : (i += 1) try set.getOrPut(fakeSlot(i), a);
    try std.testing.expect(set.indexed());
    const cap_after_promote = set.index.?.entries.len;

    var round: usize = 0;
    while (round < 1000) : (round += 1) {
        try std.testing.expect(set.remove(fakeSlot(t - 1)));
        try std.testing.expectEqual(t - 1, set.count());
        try std.testing.expect(set.indexed()); // no demotion => no thrash
        try set.getOrPut(fakeSlot(t - 1), a);
        try std.testing.expectEqual(t, set.count());
    }
    // Table never had to grow: the oscillation is not leaking tombstones.
    try std.testing.expectEqual(cap_after_promote, set.index.?.entries.len);
    i = 0;
    while (i < t) : (i += 1) try std.testing.expect(set.contains(fakeSlot(i)));
}

test "lazily/context: SubscriberEdgeSet-shaped usize keys index correctly" {
    // `cell.zig` uses `EdgeSet(usize, 1)`. Integer keys take the same index
    // path as pointers; the inline_cap=1 small-vector path must be unaffected.
    const a = std.testing.allocator;
    const S = EdgeSet(usize, 1);
    var set = S.init();
    defer set.deinit(a);

    try set.getOrPut(7, a);
    try std.testing.expectEqual(@as(usize, 1), set.count());
    try std.testing.expect(set.spill.items.len == 0); // still inline
    try std.testing.expect(!set.indexed());

    var i: usize = 0;
    while (i < S.promote_threshold * 4) : (i += 1) try set.getOrPut(i * 3 + 100, a);
    try std.testing.expect(set.indexed());
    i = 0;
    while (i < S.promote_threshold * 4) : (i += 1) try std.testing.expect(set.contains(i * 3 + 100));
    try std.testing.expect(set.contains(7));
}
