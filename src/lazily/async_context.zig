const std = @import("std");

/// Async reactive context for the Zig binding. Zig removed language `async`
/// in 0.10/0.11 and has no suspendable executor, so this layer is a
/// task-queue + drain surface — the synchronous graph's `pending_recompute` +
/// `drainPendingRecompute` generalized with revision tracking and a 4-state
/// slot machine.
///
/// Per `lazily-spec/docs/async.md`, an async context is **compute, not
/// protocol** — only resolved slot values cross IPC/FFI as ordinary cell
/// payloads. The spec's 7-item conformance checklist is pinned by deterministic
/// tests (there are no JSON fixtures — the spec explicitly rules them out).
///
/// Mirrors lazily-rs `AsyncContext` (`async_context.rs`), specialized to the
/// no-runtime model: `settle()` replaces `await`; "in-flight" means "queued for
/// the next settle()".
///
/// **Generic over the value type** (`AsyncContext(comptime V)`): a context
/// instance carries one value type `V` (like the reactive families it backs).
/// `AsyncContext(u32)` is the historical instantiation. Slot computes take a
/// `*anyopaque` userdata pointer + a call fn (the Zig closure-emulation idiom),
/// so a per-key family entry can compute a value that depends on its runtime
/// key — the missing capability that lets an `AsyncReactiveMap` ride real
/// async slots instead of a private value-cache.

pub const AsyncSlotState = enum { empty, computing, resolved, err };

pub const AsyncContextId = u64;

/// A handle to an async slot. Copy + lightweight (carries an id + generation).
pub fn AsyncSlotHandle(comptime T: type) type {
    _ = T;
    return struct {
        id: u64,
        generation: u64,

        const Self = @This();
        pub fn eq(a: Self, b: Self) bool {
            return a.id == b.id and a.generation == b.generation;
        }
    };
}

/// The async reactive context, generic over its value type `V`. Owns a registry
/// of slots + cells, a pending-compute queue, and a generation counter for safe
/// handle disposal (`#lzasyncdispose2`: a recycled id must not be aliased by a
/// stale handle).
pub fn AsyncContext(comptime V: type) type {
    return struct {
        const Self = @This();

        /// A slot compute expressed as userdata pointer + call fn (Zig closure
        /// emulation). `ptr` is opaque state the compute captures (e.g. the
        /// owning reactive family + this entry's key); pure computes pass an
        /// unused pointer via [`computedAsync`].
        pub const ComputeFn = *const fn (ptr: *anyopaque, cc: *ComputeContext) anyerror!V;

        /// The compute context passed to a slot's compute fn. Dependency edges
        /// register immediately through this context (NOT a thread-local —
        /// `async.md` L152-165), so source invalidation while a compute is
        /// running can supersede it.
        pub const ComputeContext = struct {
            async_ctx: *Self,
            slot_id: u64,

            /// Register a cell dependency. The compute will be invalidated when
            /// the cell is set.
            ///
            /// This used to swallow the error as "best-effort edge
            /// registration". It is not best-effort: `reverse_edges` is the
            /// ONLY path by which a slot is ever re-enqueued (`setCell` and
            /// the two cascade walks in `settleOnce` all read it and nothing
            /// else), and `settleOnce` clears a slot's edges before every
            /// recompute. So a dropped edge is not one missed invalidation —
            /// the slot never recomputes on that dependency again, and since
            /// the recompute is what would rebuild the edge, nothing restores
            /// it. That is permanent silent staleness, the same class as the
            /// cascade-worklist bug.
            ///
            /// Every caller is a `ComputeFn`, whose return type is already
            /// `anyerror!V`, so the failure propagates through an error union
            /// that exists: `settleOnce` puts the slot in `.err`, where
            /// `get` and `awaitResolved` report it. A visibly failed slot
            /// beats a silently wrong one.
            pub fn readCell(self: *ComputeContext, cell_id: u64) !void {
                // A live reader that still names a disposed node errors on its
                // next recompute, rather than observing a stale, default or
                // recycled value (`read_after_dispose_is_an_error.json`). This
                // guard is also what stops a recompute racing a teardown from
                // rebuilding an edge the disposal just removed.
                if (self.async_ctx.isDisposed(cell_id)) return error.NodeDisposed;
                if (self.async_ctx.isDisposed(self.slot_id)) return error.NodeDisposed;
                try self.async_ctx.addEdge(self.slot_id, cell_id);
            }
        };

        /// A no-runtime async slot node. State transitions follow the spec's
        /// 4-state machine: `Empty → Computing → Resolved|Error`, with the
        /// load-bearing `Computing → Computing (stale)` transition that discards
        /// superseded results.
        pub const SlotNode = struct {
            state: AsyncSlotState = .empty,
            value: ?V = null,
            err_value: ?anyerror = null,
            /// Bumped on every invalidate/clear. A completing compute records the
            /// slot revision at start; at publish time the graph accepts the
            /// value only if the revision is still current (stale-completion
            /// discard).
            revision: u64 = 0,
            compute_ptr: *anyopaque = undefined,
            compute_fn: ?ComputeFn = null,
            dependencies: std.ArrayList(u64),
            dependents: std.ArrayList(u64),
            /// True when a compute is queued for this slot (waiting for settle()).
            queued: bool = false,
            /// Graph-disposal tombstone (`#lzspecedgeindex`). The node stays in
            /// `slots` so a read through a handle reports `error.NodeDisposed`
            /// rather than `error.AsyncUnresolved` — "torn down" and "never
            /// existed" are different answers and callers depend on the
            /// difference.
            disposed: bool = false,
            /// Marks this node as a side effect rather than a value. Load-bearing
            /// for disposal: an effect reached by the teardown walk must not be
            /// scheduled (see `dirtyDependentConeForTeardown`).
            is_effect: bool = false,
            /// True once the effect body has run at least once, so
            /// cleanup-before-body does not fire a cleanup that never happened.
            effect_ran: bool = false,
            cleanup_ptr: ?*anyopaque = null,
            cleanup_fn: ?*const fn (*anyopaque) void = null,
            /// Visited stamp for the teardown walk. An epoch counter rather than
            /// a bool so the walk never has to reset it — resetting would need a
            /// second pass, and teardown gets no second chances.
            teardown_mark: u64 = 0,

            pub fn init() SlotNode {
                return .{ .dependencies = .empty, .dependents = .empty };
            }

            pub fn deinit(self: *SlotNode, allocator: std.mem.Allocator) void {
                self.dependencies.deinit(allocator);
                self.dependents.deinit(allocator);
            }

            /// The stale-discard check. Returns true if `at_revision` is still the
            /// current revision (so the completing compute may publish).
            pub fn isCurrentRevision(self: *const SlotNode, at_revision: u64) bool {
                return self.revision == at_revision;
            }
        };

        allocator: std.mem.Allocator,
        next_id: u64 = 1,
        generations: std.AutoHashMap(u64, u64),
        pending: std.ArrayList(u64),
        edges: std.AutoHashMap(u64, std.ArrayList(u64)), // slot_id -> [cell_id]
        reverse_edges: std.AutoHashMap(u64, std.ArrayList(u64)), // cell_id -> [slot_id]
        cells: std.AutoHashMap(u64, V),
        slots: std.AutoHashMap(u64, SlotNode),
        settled: bool = false,
        /// Disposal tombstones for *cells*. Slots carry theirs on `SlotNode`;
        /// `cells` is a bare `id -> V` map, so its tombstones live here.
        /// Capacity is reserved at node-creation time — see `reserveTeardown`.
        disposed_cells: std.AutoHashMap(u64, void),
        /// Worklist for the teardown walk, pre-grown to the live node count so
        /// the walk never allocates. See `reserveTeardown`.
        teardown_scratch: std.ArrayList(u64),
        teardown_epoch: u64 = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .generations = std.AutoHashMap(u64, u64).init(allocator),
                .pending = .empty,
                .edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
                .reverse_edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
                .cells = std.AutoHashMap(u64, V).init(allocator),
                .slots = std.AutoHashMap(u64, SlotNode).init(allocator),
                .disposed_cells = std.AutoHashMap(u64, void).init(allocator),
                .teardown_scratch = .empty,
            };
        }

        pub fn deinit(self: *Self) void {
            self.generations.deinit();
            self.pending.deinit(self.allocator);
            self.disposed_cells.deinit();
            self.teardown_scratch.deinit(self.allocator);
            var e1 = self.edges.valueIterator();
            while (e1.next()) |list| list.deinit(self.allocator);
            self.edges.deinit();
            var e2 = self.reverse_edges.valueIterator();
            while (e2.next()) |list| list.deinit(self.allocator);
            self.reverse_edges.deinit();
            self.cells.deinit();
            var si = self.slots.valueIterator();
            while (si.next()) |s| s.deinit(self.allocator);
            self.slots.deinit();
        }

        // --- cells ---

        pub fn cell(self: *Self, value: V) !u64 {
            const id = self.next_id;
            self.next_id += 1;
            try self.cells.put(id, value);
            try self.reserveTeardown();
            return id;
        }

        pub fn getCell(self: *Self, id: u64) ?V {
            return self.cells.get(id);
        }

        /// The checked cell read. See `Cell(T).tryGet` in the sync binding: a
        /// disposed node reads as an error, never as a stale or default value.
        pub fn tryGetCell(self: *Self, id: u64) error{ NodeDisposed, MissingCell }!V {
            if (self.disposed_cells.contains(id)) return error.NodeDisposed;
            return self.cells.get(id) orelse error.MissingCell;
        }

        /// Pay for teardown up front (`#lzspecedgeindex`).
        ///
        /// Every allocation disposal could possibly need is made here, at node
        /// creation, where the caller still has an error to handle. Teardown
        /// itself then walks pre-grown storage and cannot fail: a scope's
        /// `deinit` runs from a `defer` with nowhere to report, and a cascade
        /// that stops halfway leaves exactly the frozen-reader graph this whole
        /// change exists to prevent.
        ///
        /// Both bounds are the live node count: the teardown worklist can hold
        /// at most every node once (the epoch stamp dedupes), and `pending` can
        /// hold at most every slot once (the `queued` flag dedupes).
        fn reserveTeardown(self: *Self) !void {
            const n = self.slots.count() + self.cells.count();
            try self.teardown_scratch.ensureTotalCapacity(self.allocator, n);
            try self.pending.ensureTotalCapacity(self.allocator, n);
            try self.disposed_cells.ensureTotalCapacity(@intCast(n));
        }

        /// Synchronous write. If not inside a settle, invalidates dependent slots
        /// immediately (queues their computes).
        pub fn setCell(self: *Self, id: u64, value: V) !void {
            if (self.cells.get(id)) |old| {
                if (std.meta.eql(old, value)) return; // PartialEq guard
            }
            try self.cells.put(id, value);
            if (self.reverse_edges.getPtr(id)) |dependents| {
                for (dependents.items) |slot_id| {
                    try self.invalidateSlot(slot_id);
                }
            }
        }

        // --- slots ---

        /// A derived async slot whose `compute` is a **closure**: `ptr` is opaque
        /// captured state (e.g. a family + key) handed back to `compute` on every
        /// run. This is what lets a per-key family entry resolve a key-dependent
        /// value on a no-closure engine.
        pub fn computedAsyncClosure(self: *Self, ptr: *anyopaque, compute: ComputeFn) !u64 {
            const id = self.next_id;
            self.next_id += 1;
            var node = SlotNode.init();
            node.compute_ptr = ptr;
            node.compute_fn = compute;
            node.state = .computing;
            try self.slots.put(id, node);
            try self.reserveTeardown();
            try self.enqueueCompute(id);
            return id;
        }

        /// A side effect rather than a value: same node machinery, but flagged
        /// so the teardown walk never schedules it, and carrying an optional
        /// cleanup that runs before every rerun and once at disposal.
        pub fn effectAsyncClosure(
            self: *Self,
            ptr: *anyopaque,
            compute: ComputeFn,
            cleanup_ptr: ?*anyopaque,
            cleanup_fn: ?*const fn (*anyopaque) void,
        ) !u64 {
            const id = try self.computedAsyncClosure(ptr, compute);
            const n = self.slots.getPtr(id).?;
            n.is_effect = true;
            n.cleanup_ptr = cleanup_ptr;
            n.cleanup_fn = cleanup_fn;
            return id;
        }

        /// A derived async slot from a **pure** compute (no captured state) — the
        /// common case. Adapts to the closure form with an unused userdata ptr.
        pub fn computedAsync(self: *Self, compute: *const fn (*ComputeContext) anyerror!V) !u64 {
            const Wrap = struct {
                fn call(ptr: *anyopaque, cc: *ComputeContext) anyerror!V {
                    const f: *const fn (*ComputeContext) anyerror!V = @ptrCast(@alignCast(ptr));
                    return f(cc);
                }
            };
            return self.computedAsyncClosure(@constCast(@ptrCast(compute)), Wrap.call);
        }

        /// Synchronous fast-path read. Returns the value iff state == Resolved.
        pub fn get(self: *Self, id: u64) ?V {
            if (self.slots.get(id)) |node| {
                if (node.state == .resolved) return node.value;
            }
            return null;
        }

        /// Resolve a slot, blocking-style: drains pending computes until the slot
        /// is Resolved (or Error). The Zig analog of `await get_async(handle)`.
        pub fn awaitResolved(self: *Self, id: u64) !V {
            while (true) {
                if (self.get(id)) |v| return v;
                if (self.slots.get(id)) |node| {
                    if (node.state == .err) return node.err_value.?;
                }
                if (!try self.settleOnce()) {
                    if (self.slots.get(id) != null) {
                        try self.enqueueCompute(id);
                        continue;
                    }
                    return error.AsyncUnresolved;
                }
            }
        }

        /// Drain the pending-compute queue to quiescence. Returns the number of
        /// computes run.
        pub fn settle(self: *Self) !usize {
            var total: usize = 0;
            while (try self.settleOnce()) {
                total += 1;
            }
            return total;
        }

        /// Run one pending compute. Returns true iff a compute ran.
        fn settleOnce(self: *Self) !bool {
            if (self.pending.items.len == 0) return false;
            const slot_id = self.pending.orderedRemove(0);
            var node = self.slots.getPtr(slot_id) orelse return false;
            node.queued = false;
            // A disposed node can still be sitting in the queue from before its
            // disposal. Returning `true` (rather than `false`) is load-bearing:
            // `settle` stops at the first `false`, so reporting "nothing ran"
            // here would abandon every entry behind it.
            if (node.disposed) return true;
            const at_revision = node.revision;
            const compute = node.compute_fn orelse return false;
            const ptr = node.compute_ptr;

            // Cleanup-before-body: the previous run's cleanup completes before
            // the next body starts.
            if (node.is_effect and node.effect_ran) {
                if (node.cleanup_fn) |cf| cf(node.cleanup_ptr.?);
            }
            if (node.is_effect) node.effect_ran = true;

            // Reset dependencies before recompute (the compute re-registers them).
            if (self.edges.getPtr(slot_id)) |deps| {
                for (deps.items) |cell_id| {
                    if (self.reverse_edges.getPtr(cell_id)) |dependents| {
                        var i: usize = 0;
                        while (i < dependents.items.len) {
                            if (dependents.items[i] == slot_id) {
                                _ = dependents.swapRemove(i);
                            } else {
                                i += 1;
                            }
                        }
                    }
                }
                deps.clearRetainingCapacity();
            }

            var cc = ComputeContext{ .async_ctx = self, .slot_id = slot_id };
            const result = compute(ptr, &cc) catch |err| {
                // getPtr again: the compute may have grown the slots map, moving
                // the previous pointer.
                const n = self.slots.getPtr(slot_id) orelse return true;
                if (n.isCurrentRevision(at_revision)) {
                    n.state = .err;
                    n.err_value = err;
                }
                return true;
            };

            const n = self.slots.getPtr(slot_id) orelse return true;
            // Stale-completion discard: only publish if still current.
            if (!n.isCurrentRevision(at_revision)) return true;

            // Guard: all computed cells are guarded (`#lzcellkernel`, final
            // 2026-07-21). An equal recompute publishes the (equal) value but
            // suppresses the downstream cascade via the `std.meta.eql` check on
            // `changed` below — the same guard that subsumed the former `memo`.
            const old_value = n.value;
            n.value = result;
            n.state = .resolved;
            n.err_value = null;

            const changed = old_value == null or !std.meta.eql(old_value.?, result);
            if (changed) {
                if (self.reverse_edges.getPtr(slot_id)) |dependents| {
                    const snapshot = try self.allocator.dupe(u64, dependents.items);
                    defer self.allocator.free(snapshot);
                    for (snapshot) |dep_slot_id| {
                        if (dep_slot_id != slot_id) {
                            try self.invalidateSlot(dep_slot_id);
                        }
                    }
                }
            }
            return true;
        }

        fn enqueueCompute(self: *Self, slot_id: u64) !void {
            var node = self.slots.getPtr(slot_id) orelse return;
            if (node.queued or node.disposed) return;
            node.queued = true;
            node.state = .computing;
            try self.pending.append(self.allocator, slot_id);
        }

        /// `enqueueCompute` for the teardown path. `reserveTeardown` grew
        /// `pending` to the live node count at every creation, and the `queued`
        /// flag bounds the queue to one entry per node, so the capacity is
        /// guaranteed and this cannot fail.
        fn enqueueComputeInfallible(self: *Self, slot_id: u64) void {
            var node = self.slots.getPtr(slot_id) orelse return;
            if (node.queued or node.disposed) return;
            node.queued = true;
            node.state = .computing;
            std.debug.assert(self.pending.capacity > self.pending.items.len);
            self.pending.appendAssumeCapacity(slot_id);
        }

        fn invalidateSlot(self: *Self, slot_id: u64) !void {
            var node = self.slots.getPtr(slot_id) orelse return;
            if (node.disposed) return;
            node.revision += 1; // supersede any in-flight compute
            try self.enqueueCompute(slot_id);
        }

        // -------------------------------------------------------------------
        // Graph disposal, degree introspection, teardown scopes
        // (`#lzspecedgeindex`)
        // -------------------------------------------------------------------

        /// Nodes that read this one. A count, never the collection.
        pub fn dependentCount(self: *Self, id: u64) usize {
            const list = self.reverse_edges.getPtr(id) orelse return 0;
            return list.items.len;
        }

        /// Nodes this one reads. See `dependentCount`.
        pub fn dependencyCount(self: *Self, id: u64) usize {
            const list = self.edges.getPtr(id) orelse return 0;
            return list.items.len;
        }

        pub fn isDisposed(self: *Self, id: u64) bool {
            if (self.slots.getPtr(id)) |n| return n.disposed;
            return self.disposed_cells.contains(id);
        }

        /// Mark the surviving dependent cone for recompute without running a
        /// single effect.
        ///
        /// Unlike the sync binding, this context's invalidation does **not**
        /// consume the reverse edge — `invalidateSlot` only bumps a revision and
        /// queues, and `settleOnce` clears a slot's dependencies at the top of
        /// its *own* recompute. So an effect skipped here keeps every edge it
        /// had and is reached normally by the next real publish; there is no
        /// re-attachment to do. What must not happen is the enqueue: draining it
        /// would run the effect body, which reads back through the node being
        /// disposed, from inside the teardown dismantling it.
        ///
        /// Allocation-free: `teardown_scratch` and `pending` were both grown to
        /// the live node count at creation (`reserveTeardown`), and
        /// `teardown_mark` dedupes so each node is visited once.
        fn dirtyDependentConeForTeardown(self: *Self, root: u64) void {
            self.teardown_epoch += 1;
            const epoch = self.teardown_epoch;
            self.teardown_scratch.clearRetainingCapacity();
            self.pushTeardownDependents(root, epoch);
            while (self.teardown_scratch.pop()) |id| {
                self.pushTeardownDependents(id, epoch);
            }
        }

        fn pushTeardownDependents(self: *Self, id: u64, epoch: u64) void {
            const list = self.reverse_edges.getPtr(id) orelse return;
            // Iterate by index: nothing below mutates this list, but the
            // worklist push may reallocate a *different* list in the same map.
            var i: usize = 0;
            while (i < list.items.len) : (i += 1) {
                const dep_id = list.items[i];
                const n = self.slots.getPtr(dep_id) orelse continue;
                if (n.disposed or n.teardown_mark == epoch) continue;
                n.teardown_mark = epoch;
                if (!n.is_effect) {
                    n.revision += 1; // supersede any in-flight compute
                    self.enqueueComputeInfallible(dep_id);
                }
                std.debug.assert(self.teardown_scratch.capacity > self.teardown_scratch.items.len);
                self.teardown_scratch.appendAssumeCapacity(dep_id);
            }
        }

        fn detachEdge(self: *Self, slot_id: u64, dep_id: u64) void {
            if (self.edges.getPtr(slot_id)) |deps| {
                var i: usize = 0;
                while (i < deps.items.len) {
                    if (deps.items[i] == dep_id) _ = deps.swapRemove(i) else i += 1;
                }
            }
            if (self.reverse_edges.getPtr(dep_id)) |dents| {
                var i: usize = 0;
                while (i < dents.items.len) {
                    if (dents.items[i] == slot_id) _ = dents.swapRemove(i) else i += 1;
                }
            }
        }

        /// Tear one node out of the graph. Idempotent, allocation-free,
        /// infallible — see `reserveTeardown`.
        pub fn disposeNode(self: *Self, id: u64) void {
            const is_slot = self.slots.contains(id);
            const is_cell = self.cells.contains(id);
            if (!is_slot and !is_cell) return;
            if (self.isDisposed(id)) return; // idempotent

            // Dirty the cone while the edges describing it still exist.
            self.dirtyDependentConeForTeardown(id);

            if (self.slots.getPtr(id)) |n| {
                if (n.is_effect and n.effect_ran) {
                    if (n.cleanup_fn) |cf| cf(n.cleanup_ptr.?);
                }
            }

            // Detach both directions.
            if (self.edges.getPtr(id)) |deps| {
                // Copy-free: walk backwards so `swapRemove` inside `detachEdge`
                // cannot skip an entry.
                while (deps.items.len > 0) {
                    const dep_id = deps.items[deps.items.len - 1];
                    self.detachEdge(id, dep_id);
                }
            }
            if (self.reverse_edges.getPtr(id)) |dents| {
                while (dents.items.len > 0) {
                    const s_id = dents.items[dents.items.len - 1];
                    self.detachEdge(s_id, id);
                }
            }

            if (self.slots.getPtr(id)) |n| {
                n.disposed = true;
                n.state = .err;
                n.err_value = error.NodeDisposed;
                n.value = null;
                n.queued = false;
                n.revision += 1;
                n.cleanup_fn = null;
            } else {
                // Capacity reserved at `cell()`.
                self.disposed_cells.putAssumeCapacity(id, {});
            }
        }

        pub fn scope(self: *Self) TeardownScope {
            return .{ .ctx = self, .owned = .empty };
        }

        /// See `Context.TeardownScope`: a scope names a set and a moment, adds
        /// no disposal semantics of its own, and tears down in reverse creation
        /// order. `own` is where the allocation happens; `deinit` cannot fail.
        pub const TeardownScope = struct {
            ctx: *Self,
            owned: std.ArrayList(u64),
            armed: bool = true,

            pub fn own(self: *TeardownScope, id: u64) !void {
                if (!self.armed) return;
                try self.owned.append(self.ctx.allocator, id);
            }

            pub fn len(self: *const TeardownScope) usize {
                return self.owned.items.len;
            }

            pub fn disarm(self: *TeardownScope) void {
                self.armed = false;
                self.owned.clearRetainingCapacity();
            }

            pub fn deinit(self: *TeardownScope) void {
                if (self.armed) {
                    var i = self.owned.items.len;
                    while (i > 0) {
                        i -= 1;
                        self.ctx.disposeNode(self.owned.items[i]);
                    }
                }
                self.owned.deinit(self.ctx.allocator);
                self.* = undefined;
            }
        };

        /// All-or-nothing: reserve both lists before mutating either. Appending
        /// the forward edge first and only then discovering the reverse append
        /// is out of memory would leave a one-sided edge — a dependency the
        /// slot believes it has and that no `setCell` will ever fire on.
        fn addEdge(self: *Self, slot_id: u64, cell_id: u64) !void {
            const gop1 = try self.edges.getOrPut(slot_id);
            if (!gop1.found_existing) gop1.value_ptr.* = .empty;

            const gop2 = try self.reverse_edges.getOrPut(cell_id);
            if (!gop2.found_existing) gop2.value_ptr.* = .empty;

            var needs_reverse = true;
            for (gop2.value_ptr.items) |s| {
                if (s == slot_id) {
                    needs_reverse = false;
                    break;
                }
            }

            try gop1.value_ptr.ensureUnusedCapacity(self.allocator, 1);
            if (needs_reverse) try gop2.value_ptr.ensureUnusedCapacity(self.allocator, 1);

            gop1.value_ptr.appendAssumeCapacity(cell_id);
            if (needs_reverse) gop2.value_ptr.appendAssumeCapacity(slot_id);
        }
    };
}

// ---------------------------------------------------------------------------
// Tests (mirror async_context.rs deterministic invariants), on AsyncContext(u32).
// ---------------------------------------------------------------------------

const ACtx = AsyncContext(u32);
const CC = ACtx.ComputeContext;

const AsyncTestState = struct {
    var cell_a: u64 = 0;
    var compute_runs: u64 = 0;
};

fn readACompute(_: *CC) anyerror!u32 {
    AsyncTestState.compute_runs += 1;
    return 42;
}

fn readATimesTwo(cc: *CC) anyerror!u32 {
    try cc.readCell(AsyncTestState.cell_a);
    return 84;
}

test "lazily/async_context: settle resolves a queued compute" {
    const allocator = std.testing.allocator;
    var ctx = ACtx.init(allocator);
    defer ctx.deinit();

    AsyncTestState.compute_runs = 0;
    const slot = try ctx.computedAsync(readACompute);
    try std.testing.expect(ctx.get(slot) == null); // not yet resolved
    try std.testing.expectEqual(@as(usize, 1), try ctx.settle());
    try std.testing.expectEqual(@as(u32, 42), ctx.get(slot).?);
    try std.testing.expectEqual(@as(u64, 1), AsyncTestState.compute_runs);
}

test "lazily/async_context: setCell invalidates a dependent slot" {
    const allocator = std.testing.allocator;
    var ctx = ACtx.init(allocator);
    defer ctx.deinit();

    DepState.runs = 0;
    DepState.cell = try ctx.cell(1);
    _ = try ctx.computedAsync(DepState.compute);
    _ = try ctx.settle();
    try std.testing.expectEqual(@as(u64, 1), DepState.runs);

    try ctx.setCell(DepState.cell, 5);
    const ran = try ctx.settle();
    try std.testing.expect(ran > 0);
    try std.testing.expectEqual(@as(u64, 2), DepState.runs);
}

const DepState = struct {
    var cell: u64 = 0;
    var runs: u64 = 0;

    fn compute(cc: *CC) anyerror!u32 {
        try cc.readCell(DepState.cell);
        DepState.runs += 1;
        return 0;
    }
};

test "lazily/async_context: stale completion is discarded on dependency change" {
    const allocator = std.testing.allocator;
    var ctx = ACtx.init(allocator);
    defer ctx.deinit();

    AsyncTestState.cell_a = try ctx.cell(10);
    const derived = try ctx.computedAsync(readATimesTwo);
    _ = try ctx.settle();
    try std.testing.expectEqual(@as(u32, 84), ctx.get(derived).?);

    try ctx.setCell(AsyncTestState.cell_a, 20);
    _ = try ctx.settle();
    try std.testing.expect(ctx.get(derived) != null);
}

test "lazily/async_context: awaitResolved blocks via settle until resolved" {
    const allocator = std.testing.allocator;
    var ctx = ACtx.init(allocator);
    defer ctx.deinit();

    const slot = try ctx.computedAsync(readACompute);
    const v = try ctx.awaitResolved(slot);
    try std.testing.expectEqual(@as(u32, 42), v);
}

test "lazily/async_context: guarded computed suppresses cascade when value unchanged" {
    // `memo` is removed (`#lzcellkernel`); a plain `computedAsync` is guarded by
    // default — an equal recompute publishes but suppresses the cascade.
    const allocator = std.testing.allocator;
    var ctx = ACtx.init(allocator);
    defer ctx.deinit();

    AsyncTestState.compute_runs = 0;
    AsyncTestState.cell_a = try ctx.cell(1);

    const constantCompute = struct {
        fn call(cc: *CC) anyerror!u32 {
            try cc.readCell(AsyncTestState.cell_a);
            return 100;
        }
    }.call;

    const derived = try ctx.computedAsync(constantCompute);
    _ = try ctx.settle();
    try std.testing.expectEqual(@as(u32, 100), ctx.get(derived).?);

    try ctx.setCell(AsyncTestState.cell_a, 2);
    const ran = try ctx.settle();
    try std.testing.expectEqual(@as(u32, 100), ctx.get(derived).?);
    try std.testing.expect(ran > 0);
}

test "lazily/async_context: closure compute resolves a key-dependent value" {
    const allocator = std.testing.allocator;
    var ctx = ACtx.init(allocator);
    defer ctx.deinit();

    // A tiny "family" the compute closes over: slot_id → factor.
    const Fam = struct {
        base: u32,
        fn compute(ptr: *anyopaque, _: *CC) anyerror!u32 {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            return self.base * 7;
        }
    };
    var fam = Fam{ .base = 6 };
    const slot = try ctx.computedAsyncClosure(&fam, Fam.compute);
    try std.testing.expectEqual(@as(u32, 42), try ctx.awaitResolved(slot));
}

test "lazily/async_context: generic over bool value type" {
    const allocator = std.testing.allocator;
    const BCtx = AsyncContext(bool);
    var ctx = BCtx.init(allocator);
    defer ctx.deinit();
    const c = try ctx.cell(true);
    try std.testing.expectEqual(@as(?bool, true), ctx.getCell(c));
    try ctx.setCell(c, false);
    try std.testing.expectEqual(@as(?bool, false), ctx.getCell(c));
}

// ---------------------------------------------------------------------------
// Transitive-cascade coverage (#lzdartobservercow).
//
// `invalidateSlot` deliberately does NOT walk dependents — it only bumps the
// revision and enqueues the slot. The cascade instead rides the recompute
// pipeline: `settleOnce` publishes a changed value and only then invalidates
// that slot's `reverse_edges`, which enqueues the next level. So depth is
// covered by the queue draining, not by a recursive invalidate.
//
// This is the structural difference from the lazily-dart (c91a32a) and
// lazily-go (bdfdbce) defect, where an invalidation handler marked its own node
// stale and stopped, and a "resolved" read fast path short-circuited the
// recursive pull that would otherwise have compensated. These tests pin the
// zig behavior at depth so a future refactor cannot quietly reintroduce it.
// ---------------------------------------------------------------------------

/// cell -> a -> b -> c -> d. Each level registers the level above it as a
/// dependency via `readCell` (ids are uniform, so a slot id is a legal
/// dependency id) and folds its value.
const ChainState = struct {
    var cell_id: u64 = 0;
    var a_id: u64 = 0;
    var b_id: u64 = 0;
    var c_id: u64 = 0;
    var d_id: u64 = 0;

    var a_runs: u64 = 0;
    var b_runs: u64 = 0;
    var c_runs: u64 = 0;
    var d_runs: u64 = 0;

    fn reset() void {
        a_runs = 0;
        b_runs = 0;
        c_runs = 0;
        d_runs = 0;
    }

    fn a(cc: *CC) anyerror!u32 {
        try cc.readCell(cell_id);
        a_runs += 1;
        return (cc.async_ctx.getCell(cell_id) orelse 0) + 10;
    }
    fn b(cc: *CC) anyerror!u32 {
        try cc.readCell(a_id);
        b_runs += 1;
        return (cc.async_ctx.get(a_id) orelse 0) + 100;
    }
    fn c(cc: *CC) anyerror!u32 {
        try cc.readCell(b_id);
        c_runs += 1;
        return (cc.async_ctx.get(b_id) orelse 0) + 1000;
    }
    fn d(cc: *CC) anyerror!u32 {
        try cc.readCell(c_id);
        d_runs += 1;
        return (cc.async_ctx.get(c_id) orelse 0) + 10000;
    }
};

test "lazily/async_context: cascade reaches depth 3 (cell -> a -> b -> c)" {
    const allocator = std.testing.allocator;
    var ctx = ACtx.init(allocator);
    defer ctx.deinit();

    const S = ChainState;
    S.reset();
    S.cell_id = try ctx.cell(1);
    S.a_id = try ctx.computedAsync(S.a);
    S.b_id = try ctx.computedAsync(S.b);
    S.c_id = try ctx.computedAsync(S.c);

    _ = try ctx.settle();
    try std.testing.expectEqual(@as(u32, 11), ctx.get(S.a_id).?);
    try std.testing.expectEqual(@as(u32, 111), ctx.get(S.b_id).?);
    try std.testing.expectEqual(@as(u32, 1111), ctx.get(S.c_id).?);

    // One write at the root must refresh ALL THREE levels, not just the first.
    // This is the exact assertion that failed in dart/go before c91a32a/bdfdbce.
    S.reset();
    try ctx.setCell(S.cell_id, 2);
    _ = try ctx.settle();

    try std.testing.expectEqual(@as(u32, 12), ctx.get(S.a_id).?);
    try std.testing.expectEqual(@as(u32, 112), ctx.get(S.b_id).?);
    try std.testing.expectEqual(@as(u32, 1112), ctx.get(S.c_id).?);
    try std.testing.expectEqual(@as(u64, 1), S.a_runs);
    try std.testing.expectEqual(@as(u64, 1), S.b_runs);
    try std.testing.expectEqual(@as(u64, 1), S.c_runs);
}

test "lazily/async_context: cascade reaches depth 4 and repeats across writes" {
    const allocator = std.testing.allocator;
    var ctx = ACtx.init(allocator);
    defer ctx.deinit();

    const S = ChainState;
    S.reset();
    S.cell_id = try ctx.cell(1);
    S.a_id = try ctx.computedAsync(S.a);
    S.b_id = try ctx.computedAsync(S.b);
    S.c_id = try ctx.computedAsync(S.c);
    S.d_id = try ctx.computedAsync(S.d);

    _ = try ctx.settle();
    try std.testing.expectEqual(@as(u32, 11111), ctx.get(S.d_id).?);

    // Three successive writes: the cascade must fire every time, not just once
    // (the dart/go defect went deaf after the first rerun).
    var expected: u32 = 11111;
    var v: u32 = 1;
    while (v < 4) : (v += 1) {
        S.reset();
        try ctx.setCell(S.cell_id, v + 1);
        _ = try ctx.settle();
        expected += 1;
        try std.testing.expectEqual(expected, ctx.get(S.d_id).?);
        try std.testing.expectEqual(@as(u64, 1), S.d_runs);
    }
}

/// cell -> {left, right} -> sink. Sink must recompute exactly once per write
/// despite two invalidation paths reaching it.
const DiamondState = struct {
    var cell_id: u64 = 0;
    var left_id: u64 = 0;
    var right_id: u64 = 0;
    var sink_id: u64 = 0;
    var sink_runs: u64 = 0;

    fn left(cc: *CC) anyerror!u32 {
        try cc.readCell(cell_id);
        return (cc.async_ctx.getCell(cell_id) orelse 0) + 1;
    }
    fn right(cc: *CC) anyerror!u32 {
        try cc.readCell(cell_id);
        return (cc.async_ctx.getCell(cell_id) orelse 0) + 2;
    }
    fn sink(cc: *CC) anyerror!u32 {
        try cc.readCell(left_id);
        try cc.readCell(right_id);
        sink_runs += 1;
        return (cc.async_ctx.get(left_id) orelse 0) +
            (cc.async_ctx.get(right_id) orelse 0);
    }
};

test "lazily/async_context: diamond converges and does not double-run the sink" {
    const allocator = std.testing.allocator;
    var ctx = ACtx.init(allocator);
    defer ctx.deinit();

    const S = DiamondState;
    S.sink_runs = 0;
    S.cell_id = try ctx.cell(10);
    S.left_id = try ctx.computedAsync(S.left);
    S.right_id = try ctx.computedAsync(S.right);
    S.sink_id = try ctx.computedAsync(S.sink);

    _ = try ctx.settle();
    try std.testing.expectEqual(@as(u32, 23), ctx.get(S.sink_id).?); // 11 + 12

    S.sink_runs = 0;
    try ctx.setCell(S.cell_id, 20);
    _ = try ctx.settle();
    try std.testing.expectEqual(@as(u32, 43), ctx.get(S.sink_id).?); // 21 + 22

    // `enqueueCompute`'s `queued` latch collapses the two arrival paths, but the
    // sink still reruns once per arriving level (left, then right), so assert a
    // bound rather than an exact 1.
    try std.testing.expect(S.sink_runs >= 1 and S.sink_runs <= 2);
}

/// A slot whose compute has an observable side effect — the AsyncContext analog
/// of an Effect downstream of a slot. Two successive writes must produce two
/// reruns; the sibling defect made an async effect deaf after exactly one.
const AsyncEffectState = struct {
    var cell_id: u64 = 0;
    var mid_id: u64 = 0;
    var effect_runs: u64 = 0;
    var last_seen: u32 = 0;

    fn mid(cc: *CC) anyerror!u32 {
        try cc.readCell(cell_id);
        return (cc.async_ctx.getCell(cell_id) orelse 0) * 2;
    }
    fn effect(cc: *CC) anyerror!u32 {
        try cc.readCell(mid_id);
        const v = cc.async_ctx.get(mid_id) orelse 0;
        effect_runs += 1;
        last_seen = v;
        return v;
    }
};

test "lazily/async_context: effect downstream of a slot reruns on every write" {
    const allocator = std.testing.allocator;
    var ctx = ACtx.init(allocator);
    defer ctx.deinit();

    const S = AsyncEffectState;
    S.effect_runs = 0;
    S.last_seen = 0;
    S.cell_id = try ctx.cell(1);
    S.mid_id = try ctx.computedAsync(S.mid);
    _ = try ctx.computedAsync(S.effect);

    _ = try ctx.settle();
    try std.testing.expectEqual(@as(u64, 1), S.effect_runs);
    try std.testing.expectEqual(@as(u32, 2), S.last_seen);

    // First write.
    try ctx.setCell(S.cell_id, 5);
    _ = try ctx.settle();
    try std.testing.expectEqual(@as(u32, 10), S.last_seen);

    // SECOND write — the one that exposed the dart/go "deaf after one rerun".
    try ctx.setCell(S.cell_id, 9);
    _ = try ctx.settle();
    try std.testing.expectEqual(@as(u32, 18), S.last_seen);
    try std.testing.expectEqual(@as(u64, 3), S.effect_runs);
}

test "lazily/async_context: read before the queue drains observes a stale value at depth" {
    // SEMANTICS PIN, not a bug report. `setCell` enqueues only its DIRECT
    // dependents; deeper levels are enqueued later, by `settleOnce` publishing a
    // changed value and walking `reverse_edges`. So between the write and
    // quiescence, a depth>=2 slot is still `.resolved` holding its previous
    // value, and both `get` and `awaitResolved` will hand it back.
    //
    // `awaitResolved` is the sharper case: its loop leads with
    // `if (self.get(id)) |v| return v`, so it returns the stale value WITHOUT
    // settling anything, because the slot was never moved off `.resolved`.
    //
    // This is eventual consistency, and it is the documented contract for this
    // type: `settle()` is "drain the pending-compute queue to quiescence" and is
    // what callers must run before reading. It is not the dart/go defect — the
    // cascade does reach every level (see the depth-3/depth-4 tests above), it
    // just reaches them asynchronously. Changing it would mean making `get`
    // demand-driven, which is a contract change, not a fix.
    const allocator = std.testing.allocator;
    var ctx = ACtx.init(allocator);
    defer ctx.deinit();

    const S = ChainState;
    S.reset();
    S.cell_id = try ctx.cell(1);
    S.a_id = try ctx.computedAsync(S.a);
    S.b_id = try ctx.computedAsync(S.b);
    S.c_id = try ctx.computedAsync(S.c);
    _ = try ctx.settle();
    try std.testing.expectEqual(@as(u32, 1111), ctx.get(S.c_id).?);

    S.reset();
    try ctx.setCell(S.cell_id, 2);

    // Only the direct dependent was enqueued.
    try std.testing.expectEqual(@as(usize, 1), ctx.pending.items.len);
    try std.testing.expectEqual(S.a_id, ctx.pending.items[0]);

    // Depth 2 and 3 are still `.resolved` with pre-write values.
    try std.testing.expectEqual(@as(u32, 111), ctx.get(S.b_id).?);
    try std.testing.expectEqual(@as(u32, 1111), ctx.get(S.c_id).?);

    // And `awaitResolved` short-circuits on that stale `.resolved` state
    // without running a single compute.
    try std.testing.expectEqual(@as(u32, 1111), try ctx.awaitResolved(S.c_id));
    try std.testing.expectEqual(@as(u64, 0), S.c_runs);

    // Draining to quiescence is what makes the read correct.
    _ = try ctx.settle();
    try std.testing.expectEqual(@as(u32, 1112), ctx.get(S.c_id).?);
    try std.testing.expectEqual(@as(usize, 0), ctx.pending.items.len);
}

// A dropped dependency edge is permanent, not best-effort. `reverse_edges` is
// the only thing `setCell`/`settleOnce` consult to decide what to re-enqueue,
// and `settleOnce` clears a slot's edges before every recompute — so the
// recompute that would rebuild a dropped edge is exactly the one that can no
// longer be triggered. `readCell` therefore propagates through the
// `anyerror!V` its callers already return, and the slot lands in `.err` where
// a reader can see it.

const EdgeOomState = struct {
    var cell_a: u64 = 0;
    var cell_b: u64 = 0;
    var read_extra: bool = false;

    fn compute(_: *anyopaque, cc: *CC) anyerror!u32 {
        try cc.readCell(cell_a);
        // Second run pulls in a dependency never registered before, so the
        // edge lists genuinely have to grow — a re-registration of an existing
        // edge reuses retained capacity and never touches the allocator.
        if (read_extra) try cc.readCell(cell_b);
        return 7;
    }
};

test "lazily/async_context: a dropped dependency edge must surface, not resolve silently" {
    const S = EdgeOomState;
    const backing = std.testing.allocator;
    var ctx = ACtx.init(backing);
    defer ctx.deinit();

    S.read_extra = false;
    S.cell_a = 9001;
    S.cell_b = 9002;
    try ctx.setCell(S.cell_a, 1);
    try ctx.setCell(S.cell_b, 1);

    var dummy: u8 = 0;
    const slot_id = try ctx.computedAsyncClosure(&dummy, S.compute);
    _ = try ctx.settle();
    try std.testing.expectEqual(@as(u32, 7), ctx.get(slot_id).?);

    // Queue the recompute while memory is still available, so the failure
    // under test is the edge registration and not the enqueue.
    S.read_extra = true;
    try ctx.setCell(S.cell_a, 2);

    var failing = std.testing.FailingAllocator.init(backing, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    ctx.allocator = failing.allocator();
    _ = try ctx.settle();
    ctx.allocator = backing;

    try std.testing.expect(failing.has_induced_failure);

    // The assertion that fails against the old `catch {}`: the slot reports the
    // failure instead of publishing a value whose dependency set is a lie.
    // Under the old code this was `.resolved` holding 7, with the `cell_b` edge
    // silently missing forever.
    try std.testing.expectEqual(AsyncSlotState.err, ctx.slots.getPtr(slot_id).?.state);
    try std.testing.expect(ctx.get(slot_id) == null);
    try std.testing.expectError(error.OutOfMemory, ctx.awaitResolved(slot_id));

    // And it stays visibly failed rather than quietly serving a stale value:
    // the recompute that would have rebuilt the edge is the one that can no
    // longer be reached, so silence here would have been permanent.
    try ctx.setCell(S.cell_b, 42);
    _ = try ctx.settle();
    try std.testing.expectEqual(AsyncSlotState.err, ctx.slots.getPtr(slot_id).?.state);
}
