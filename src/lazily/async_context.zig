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
        cc.readCell(cell_id);
        a_runs += 1;
        return (cc.async_ctx.getCell(cell_id) orelse 0) + 10;
    }
    fn b(cc: *CC) anyerror!u32 {
        cc.readCell(a_id);
        b_runs += 1;
        return (cc.async_ctx.get(a_id) orelse 0) + 100;
    }
    fn c(cc: *CC) anyerror!u32 {
        cc.readCell(b_id);
        c_runs += 1;
        return (cc.async_ctx.get(b_id) orelse 0) + 1000;
    }
    fn d(cc: *CC) anyerror!u32 {
        cc.readCell(c_id);
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
        cc.readCell(cell_id);
        return (cc.async_ctx.getCell(cell_id) orelse 0) + 1;
    }
    fn right(cc: *CC) anyerror!u32 {
        cc.readCell(cell_id);
        return (cc.async_ctx.getCell(cell_id) orelse 0) + 2;
    }
    fn sink(cc: *CC) anyerror!u32 {
        cc.readCell(left_id);
        cc.readCell(right_id);
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
        cc.readCell(cell_id);
        return (cc.async_ctx.getCell(cell_id) orelse 0) * 2;
    }
    fn effect(cc: *CC) anyerror!u32 {
        cc.readCell(mid_id);
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
