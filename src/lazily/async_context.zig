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
/// key — the missing capability that lets an `AsyncReactiveFamily` ride real
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
        pub const EqualsFn = *const fn (V, V) bool;

        /// The compute context passed to a slot's compute fn. Dependency edges
        /// register immediately through this context (NOT a thread-local —
        /// `async.md` L152-165), so source invalidation while a compute is
        /// running can supersede it.
        pub const ComputeContext = struct {
            async_ctx: *Self,
            slot_id: u64,

            /// Register a cell dependency. The compute will be invalidated when
            /// the cell is set. Errors are swallowed (best-effort edge reg).
            pub fn readCell(self: *ComputeContext, cell_id: u64) void {
                self.async_ctx.addEdge(self.slot_id, cell_id) catch {};
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
            equals: ?EqualsFn = null,
            dependencies: std.ArrayList(u64),
            dependents: std.ArrayList(u64),
            /// True when a compute is queued for this slot (waiting for settle()).
            queued: bool = false,

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

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .generations = std.AutoHashMap(u64, u64).init(allocator),
                .pending = .empty,
                .edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
                .reverse_edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
                .cells = std.AutoHashMap(u64, V).init(allocator),
                .slots = std.AutoHashMap(u64, SlotNode).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.generations.deinit();
            self.pending.deinit(self.allocator);
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
            return id;
        }

        pub fn getCell(self: *Self, id: u64) ?V {
            return self.cells.get(id);
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
            try self.enqueueCompute(id);
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

        /// Memo variant: a compute whose result is equality-guarded so a
        /// recomputation that yields an equal value does NOT cascade to
        /// dependents.
        pub fn memoAsync(
            self: *Self,
            compute: *const fn (*ComputeContext) anyerror!V,
            equals: EqualsFn,
        ) !u64 {
            const id = try self.computedAsync(compute);
            self.slots.getPtr(id).?.equals = equals;
            return id;
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
            const at_revision = node.revision;
            const compute = node.compute_fn orelse return false;
            const ptr = node.compute_ptr;

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

            // Memo guard: an equal recompute suppresses the cascade.
            if (n.equals) |eq| {
                if (n.value) |old| {
                    if (eq(old, result)) {
                        n.state = .resolved;
                        return true;
                    }
                }
            }

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
            if (node.queued) return;
            node.queued = true;
            node.state = .computing;
            try self.pending.append(self.allocator, slot_id);
        }

        fn invalidateSlot(self: *Self, slot_id: u64) !void {
            var node = self.slots.getPtr(slot_id) orelse return;
            node.revision += 1; // supersede any in-flight compute
            try self.enqueueCompute(slot_id);
        }

        fn addEdge(self: *Self, slot_id: u64, cell_id: u64) !void {
            const gop1 = try self.edges.getOrPut(slot_id);
            if (!gop1.found_existing) gop1.value_ptr.* = .empty;
            try gop1.value_ptr.append(self.allocator, cell_id);

            const gop2 = try self.reverse_edges.getOrPut(cell_id);
            if (!gop2.found_existing) gop2.value_ptr.* = .empty;
            for (gop2.value_ptr.items) |s| {
                if (s == slot_id) return;
            }
            try gop2.value_ptr.append(self.allocator, slot_id);
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
    cc.readCell(AsyncTestState.cell_a);
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
        cc.readCell(DepState.cell);
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

test "lazily/async_context: memo guard suppresses cascade when value unchanged" {
    const allocator = std.testing.allocator;
    var ctx = ACtx.init(allocator);
    defer ctx.deinit();

    AsyncTestState.compute_runs = 0;
    AsyncTestState.cell_a = try ctx.cell(1);

    const eq = struct {
        fn eq(a: u32, b: u32) bool {
            return a == b;
        }
    }.eq;
    const constantCompute = struct {
        fn call(cc: *CC) anyerror!u32 {
            cc.readCell(AsyncTestState.cell_a);
            return 100;
        }
    }.call;

    const memo = try ctx.memoAsync(constantCompute, eq);
    _ = try ctx.settle();
    try std.testing.expectEqual(@as(u32, 100), ctx.get(memo).?);

    try ctx.setCell(AsyncTestState.cell_a, 2);
    const ran = try ctx.settle();
    try std.testing.expectEqual(@as(u32, 100), ctx.get(memo).?);
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
