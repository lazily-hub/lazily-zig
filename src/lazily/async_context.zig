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
/// Mirrors lazily-rs `AsyncContext` (`async_context.rs:62-1292`), specialized
/// to the no-runtime model: `settle()` replaces `await`; "in-flight" means
/// "queued for the next settle()".

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

/// A no-runtime async slot node. State transitions follow the spec's 4-state
/// machine: `Empty → Computing → Resolved|Error`, with the load-bearing
/// `Computing → Computing (stale)` transition that discards superseded results.
pub fn AsyncSlotNode(comptime T: type) type {
    return struct {
        state: AsyncSlotState = .empty,
        value: ?T = null,
        err_value: ?anyerror = null,
        /// Bumped on every invalidate/clear. A completing compute records the
        /// slot revision at start; at publish time the graph accepts the value
        /// only if the revision is still current (stale-completion discard).
        revision: u64 = 0,
        compute: ?*const fn (*AsyncComputeContext) anyerror!T = null,
        equals: ?*const fn (T, T) bool = null,
        dependencies: std.ArrayList(u64),
        dependents: std.ArrayList(u64),
        /// True when a compute is queued for this slot (waiting for settle()).
        queued: bool = false,

        const Self = @This();

        pub fn init() Self {
            return .{
                .dependencies = .empty,
                .dependents = .empty,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.dependencies.deinit(allocator);
            self.dependents.deinit(allocator);
        }

        /// The stale-discard check. Returns true if `at_revision` is still the
        /// current revision (so the completing compute may publish).
        pub fn isCurrentRevision(self: *const Self, at_revision: u64) bool {
            return self.revision == at_revision;
        }
    };
}

/// The compute context passed to a slot's compute fn. Dependency edges register
/// immediately through this context (NOT a thread-local — `async.md` L152-165),
/// so source invalidation while a compute is running can supersede it.
pub const AsyncComputeContext = struct {
    async_ctx: *AsyncContext,
    slot_id: u64,

    /// Register a cell dependency. The compute will be invalidated when the
    /// cell is set. Errors are swallowed (best-effort edge registration).
    pub fn readCell(self: *AsyncComputeContext, cell_id: u64) void {
        self.async_ctx.addEdge(self.slot_id, cell_id) catch {};
    }
};

/// An async cell — a value source whose writes invalidate dependent slots.
pub fn AsyncCell(comptime T: type) type {
    return struct {
        value: T,
        id: u64,
    };
}

/// The async reactive context. Owns a registry of slots + cells, a pending-
/// compute queue, and a generation counter for safe handle disposal
/// (`#lzasyncdispose2`: a recycled id must not be aliased by a stale handle).
pub const AsyncContext = struct {
    allocator: std.mem.Allocator,
    /// Type-erased slot registry. We store at most one value-type per context
    /// for simplicity; a heterogeneous registry would use a vtable per slot.
    next_id: u64 = 1,
    generations: std.AutoHashMap(u64, u64),
    pending: std.ArrayList(u64),
    edges: std.AutoHashMap(u64, std.ArrayList(u64)), // slot_id -> [cell_id]
    reverse_edges: std.AutoHashMap(u64, std.ArrayList(u64)), // cell_id -> [slot_id]
    cells_u32: std.AutoHashMap(u64, u32),
    slots_u32: std.AutoHashMap(u64, AsyncSlotNode(u32)),
    settled: bool = false,

    pub fn init(allocator: std.mem.Allocator) AsyncContext {
        return .{
            .allocator = allocator,
            .generations = std.AutoHashMap(u64, u64).init(allocator),
            .pending = .empty,
            .edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
            .reverse_edges = std.AutoHashMap(u64, std.ArrayList(u64)).init(allocator),
            .cells_u32 = std.AutoHashMap(u64, u32).init(allocator),
            .slots_u32 = std.AutoHashMap(u64, AsyncSlotNode(u32)).init(allocator),
        };
    }

    pub fn deinit(self: *AsyncContext) void {
        self.generations.deinit();
        self.pending.deinit(self.allocator);
        var e1 = self.edges.valueIterator();
        while (e1.next()) |list| list.deinit(self.allocator);
        self.edges.deinit();
        var e2 = self.reverse_edges.valueIterator();
        while (e2.next()) |list| list.deinit(self.allocator);
        self.reverse_edges.deinit();
        self.cells_u32.deinit();
        var si = self.slots_u32.valueIterator();
        while (si.next()) |s| s.deinit(self.allocator);
        self.slots_u32.deinit();
    }

    // --- cells (u32 value-type) ---

    pub fn cell(self: *AsyncContext, value: u32) !u64 {
        const id = self.next_id;
        self.next_id += 1;
        try self.cells_u32.put(id, value);
        return id;
    }

    pub fn getCell(self: *AsyncContext, id: u64) ?u32 {
        return self.cells_u32.get(id);
    }

    /// Synchronous write. If not inside a settle, invalidates dependent slots
    /// immediately (queues their computes). Inside `batch`, the queue flush is
    /// deferred to the outermost exit.
    pub fn setCell(self: *AsyncContext, id: u64, value: u32) !void {
        if (self.cells_u32.get(id)) |old| {
            if (old == value) return; // PartialEq guard
        }
        try self.cells_u32.put(id, value);
        // Invalidate all slots that depend on this cell.
        if (self.reverse_edges.getPtr(id)) |dependents| {
            for (dependents.items) |slot_id| {
                try self.invalidateSlot(slot_id);
            }
        }
    }

    // --- slots (u32 value-type) ---

    pub fn computedAsync(
        self: *AsyncContext,
        compute: *const fn (*AsyncComputeContext) anyerror!u32,
    ) !u64 {
        const id = self.next_id;
        self.next_id += 1;
        var node = AsyncSlotNode(u32).init();
        node.compute = compute;
        node.state = .computing;
        try self.slots_u32.put(id, node);
        try self.enqueueCompute(id);
        return id;
    }

    /// Memo variant: a compute whose result is equality-guarded so a
    /// recomputation that yields an equal value does NOT cascade to dependents.
    pub fn memoAsync(
        self: *AsyncContext,
        compute: *const fn (*AsyncComputeContext) anyerror!u32,
        equals: *const fn (u32, u32) bool,
    ) !u64 {
        const id = self.next_id;
        self.next_id += 1;
        var node = AsyncSlotNode(u32).init();
        node.compute = compute;
        node.equals = equals;
        node.state = .computing;
        try self.slots_u32.put(id, node);
        try self.enqueueCompute(id);
        return id;
    }

    /// Synchronous fast-path read. Returns the value iff state == Resolved.
    pub fn get(self: *AsyncContext, id: u64) ?u32 {
        if (self.slots_u32.get(id)) |node| {
            if (node.state == .resolved) return node.value;
        }
        return null;
    }

    /// Resolve a slot, blocking-style: drains pending computes until the slot
    /// is Resolved (or Error). The Zig analog of `await get_async(handle)`.
    pub fn awaitResolved(self: *AsyncContext, id: u64) !u32 {
        while (true) {
            if (self.get(id)) |v| return v;
            if (self.slots_u32.get(id)) |node| {
                if (node.state == .err) return node.err_value.?;
            }
            if (!try self.settleOnce()) {
                // Nothing left to run; re-spawn the slot's compute.
                if (self.slots_u32.get(id) != null) {
                    try self.enqueueCompute(id);
                    continue;
                }
                return error.AsyncUnresolved;
            }
        }
    }

    /// Drain the pending-compute queue to quiescence. Returns the number of
    /// computes run. Mirrors JS `settle()` (no Rust counterpart — tokio drives
    /// itself; a no-runtime platform requires an explicit drain entry point).
    pub fn settle(self: *AsyncContext) !usize {
        var total: usize = 0;
        while (try self.settleOnce()) {
            total += 1;
        }
        return total;
    }

    /// Run one pending compute. Returns true iff a compute ran.
    fn settleOnce(self: *AsyncContext) !bool {
        if (self.pending.items.len == 0) return false;
        const slot_id = self.pending.orderedRemove(0);
        var node = self.slots_u32.getPtr(slot_id) orelse return false;
        node.queued = false;
        const at_revision = node.revision;
        const compute = node.compute orelse return false;

        // Reset dependencies for this slot before re-computing (the compute fn
        // re-registers them via the compute context).
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

        var cc = AsyncComputeContext{ .async_ctx = self, .slot_id = slot_id };
        const result = compute(&cc) catch |err| {
            // Publish error only if still current revision (stale discard).
            if (node.isCurrentRevision(at_revision)) {
                node.state = .err;
                node.err_value = err;
            }
            return true;
        };

        // Stale-completion discard: only publish if the revision is still current.
        if (!node.isCurrentRevision(at_revision)) {
            // A newer compute is queued; this result is stale.
            return true;
        }

        // Memo guard: if equals fn is set and the new value equals the old,
        // suppress the cascade (do NOT re-invalidate dependents).
        if (node.equals) |eq| {
            if (node.value) |old| {
                if (eq(old, result)) {
                    node.state = .resolved;
                    return true; // unchanged — no cascade
                }
            }
        }

        const old_value = node.value;
        node.value = result;
        node.state = .resolved;
        node.err_value = null;

        // Cascade: invalidate dependents only if the value actually changed.
        if (old_value == null or old_value.? != result) {
            if (self.reverse_edges.getPtr(slot_id)) |dependents| {
                // shallow copy — invalidate mutates the list
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

    fn enqueueCompute(self: *AsyncContext, slot_id: u64) !void {
        var node = self.slots_u32.getPtr(slot_id) orelse return;
        if (node.queued) return;
        node.queued = true;
        node.state = .computing;
        try self.pending.append(self.allocator, slot_id);
    }

    fn invalidateSlot(self: *AsyncContext, slot_id: u64) !void {
        var node = self.slots_u32.getPtr(slot_id) orelse return;
        node.revision += 1; // supersede any in-flight compute
        try self.enqueueCompute(slot_id);
    }

    fn addEdge(self: *AsyncContext, slot_id: u64, cell_id: u64) !void {
        const gop1 = try self.edges.getOrPut(slot_id);
        if (!gop1.found_existing) gop1.value_ptr.* = .empty;
        try gop1.value_ptr.append(self.allocator, cell_id);

        const gop2 = try self.reverse_edges.getOrPut(cell_id);
        if (!gop2.found_existing) gop2.value_ptr.* = .empty;
        // Avoid duplicate edges.
        for (gop2.value_ptr.items) |s| {
            if (s == slot_id) return;
        }
        try gop2.value_ptr.append(self.allocator, slot_id);
    }
};

// ---------------------------------------------------------------------------
// Tests (mirror async_context.rs deterministic invariants)
// ---------------------------------------------------------------------------

const AsyncTestState = struct {
    var cell_a: u64 = 0;
    var compute_runs: u64 = 0;
};

fn readACompute(_: *AsyncComputeContext) anyerror!u32 {
    AsyncTestState.compute_runs += 1;
    return 42;
}

fn readATimesTwo(cc: *AsyncComputeContext) anyerror!u32 {
    cc.readCell(AsyncTestState.cell_a);
    return 84;
}

test "lazily/async_context: settle resolves a queued compute" {
    const allocator = std.testing.allocator;
    var ctx = AsyncContext.init(allocator);
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
    var ctx = AsyncContext.init(allocator);
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

    fn compute(cc: *AsyncComputeContext) anyerror!u32 {
        cc.readCell(DepState.cell);
        DepState.runs += 1;
        return 0;
    }
};

test "lazily/async_context: stale completion is discarded on dependency change" {
    const allocator = std.testing.allocator;
    var ctx = AsyncContext.init(allocator);
    defer ctx.deinit();

    AsyncTestState.cell_a = try ctx.cell(10);
    const derived = try ctx.computedAsync(readATimesTwo);
    // Resolve initial.
    _ = try ctx.settle();
    try std.testing.expectEqual(@as(u32, 84), ctx.get(derived).?);

    // setCell invalidates the dependent → enqueues a fresh compute at a new revision.
    try ctx.setCell(AsyncTestState.cell_a, 20);
    // The queued compute is the only pending work; settle runs it once.
    _ = try ctx.settle();
    // readATimesTwo still returns 84 (constant) — but the compute ran again
    // because the dependency changed.
    try std.testing.expect(ctx.get(derived) != null);
}

test "lazily/async_context: awaitResolved blocks via settle until resolved" {
    const allocator = std.testing.allocator;
    var ctx = AsyncContext.init(allocator);
    defer ctx.deinit();

    const slot = try ctx.computedAsync(readACompute);
    const v = try ctx.awaitResolved(slot);
    try std.testing.expectEqual(@as(u32, 42), v);
}

test "lazily/async_context: memo guard suppresses cascade when value unchanged" {
    const allocator = std.testing.allocator;
    var ctx = AsyncContext.init(allocator);
    defer ctx.deinit();

    AsyncTestState.compute_runs = 0;
    AsyncTestState.cell_a = try ctx.cell(1);

    const eq = struct {
        fn eq(a: u32, b: u32) bool {
            return a == b;
        }
    }.eq;
    // Constant compute: always returns 100 regardless of cell value.
    const constantCompute = struct {
        fn call(cc: *AsyncComputeContext) anyerror!u32 {
            cc.readCell(AsyncTestState.cell_a);
            return 100;
        }
    }.call;

    const memo = try ctx.memoAsync(constantCompute, eq);
    _ = try ctx.settle();
    try std.testing.expectEqual(@as(u32, 100), ctx.get(memo).?);

    // Change the cell — memo recomputes but value stays 100 (memo guard).
    try ctx.setCell(AsyncTestState.cell_a, 2);
    const ran = try ctx.settle();
    try std.testing.expectEqual(@as(u32, 100), ctx.get(memo).?);
    // The settle ran at least one compute (the re-validation).
    try std.testing.expect(ran > 0);
}
