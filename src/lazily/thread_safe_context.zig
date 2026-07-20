//! `ThreadSafeContext` — a lock-backed, `Send`-shareable reactive context.
//!
//! The Zig `Context` (`context.zig`) bakes thread-safety into a build-wide
//! comptime flag (`build_options.thread_safe`), so a single build cannot hold
//! *both* a fast single-threaded graph and a shared one. `ThreadSafeContext` is
//! the distinct type that closes that gap — the analog of lazily-rs
//! `ThreadSafeContext`: a reactive graph whose every operation is serialized by
//! one [`ParkingMutex`](parking_mutex.zig), so it can be shared across threads
//! (behind a pointer) regardless of the build flag.
//!
//! It is a **standalone registry graph** (like [`AsyncContext`](async_context.zig)),
//! not a wrapper over `Context`: `Context` keys its reactive nodes by a comptime
//! function pointer, so it cannot mint an independent node per *runtime* key —
//! exactly what a keyed reactive family needs. `ThreadSafeContext` instead keys
//! nodes by a runtime `u64` id, with **type-erased storage** (a boxed value plus
//! a monomorphic-per-`T` recompute/free thunk generated at the typed call site,
//! the same "typed free function stored in an erased slot" idiom the sync engine
//! uses). This is what lets `ThreadSafeReactiveMap` allocate a real reactive
//! cell per key.
//!
//! Reactivity is **lazy** (like `Context`): a `setCell` marks transitive
//! dependents dirty; a dirty computed slot recomputes on `get`. Reads return
//! values **by copy** (never a pointer into the graph) so a value can safely
//! cross the lock boundary to another thread. Cell writes are PartialEq-guarded
//! (`std.meta.eql`). `batch` coalesces writes (no intermediate recompute of the
//! eager surface — here a no-op beyond nesting, since recompute is lazy).

const std = @import("std");
const ParkingMutex = @import("parking_mutex.zig").ParkingMutex;

/// A handle to a `ThreadSafeContext` node (cell or slot). Copy + lightweight.
pub fn TsHandle(comptime T: type) type {
    _ = T; // phantom: tags handles by value type at the API surface.
    return struct {
        id: u64,
        const Self = @This();
        pub fn eq(a: Self, b: Self) bool {
            return a.id == b.id;
        }
    };
}

pub const ThreadSafeContext = struct {
    const Self = @This();

    /// A slot compute expressed as userdata pointer + call fn (Zig closure
    /// emulation): `ptr` is captured state (e.g. a family + key). Typed by the
    /// value `T` produced; stored type-erased and cast back by the per-`T`
    /// recompute thunk.
    pub fn ComputeFn(comptime T: type) type {
        return *const fn (ptr: *anyopaque, cc: *ComputeContext) T;
    }

    /// Passed to a slot's compute; `readNode` registers a dependency edge so the
    /// slot is invalidated when that node changes.
    pub const ComputeContext = struct {
        ctx: *Self,
        slot_id: u64,
        pub fn readNode(self: *ComputeContext, comptime T: type, handle: TsHandle(T)) T {
            self.ctx.addEdgeUnlocked(self.slot_id, handle.id) catch {
                // Poison, do not swallow. `dependents` is the only list
                // `invalidateDependentsUnlocked` walks, and `dirty` is the only
                // flag `getUnlocked` consults — so a dropped edge means this
                // slot is never marked dirty for `handle` again. And
                // `Recompute.run` clears deps before every compute, so the
                // recompute that would rebuild the edge is exactly the one
                // that can no longer be triggered. Permanent silent staleness.
                //
                // `ComputeFn(T)` returns plain `T`, so unlike `AsyncContext`'s
                // `anyerror!V` there is no error union to propagate through and
                // no signature is changed here. Instead the slot's edge set is
                // marked incomplete: `Recompute.run` then refuses to clear
                // `dirty`, so `getUnlocked` recomputes on EVERY read. That is
                // conservative over-recomputation in place of silent
                // staleness, and it is self-healing — each read retries the
                // registration, and the first one that succeeds lets `dirty`
                // clear again.
                if (self.ctx.nodes.getPtr(self.slot_id)) |n| n.edges_incomplete = true;
                self.ctx.edge_drop_degradations += 1;
            };
            return self.ctx.getUnlocked(T, handle.id);
        }
    };

    const Node = struct {
        /// Heap-boxed value (`*T`). Read/written only through the per-`T` thunks.
        box: *anyopaque,
        free_fn: *const fn (std.mem.Allocator, *anyopaque) void,
        // Slot-only (null for input cells):
        compute_ptr: ?*anyopaque = null,
        /// Type-erased typed compute fn; cast back by `recompute_fn`.
        compute_erased: ?*anyopaque = null,
        /// Monomorphic-over-`T` recompute: re-run compute, rebox, cascade. Null
        /// for cells.
        recompute_fn: ?*const fn (*Self, u64) void = null,
        dirty: bool = false,
        /// Set when a dependency edge could not be registered during the last
        /// compute. While true, `Recompute.run` leaves `dirty` set so the slot
        /// recomputes on every read rather than trusting an edge set that is
        /// known to be missing entries. Cleared at the start of each compute.
        edges_incomplete: bool = false,
        deps: std.ArrayList(u64), // nodes this reads
        dependents: std.ArrayList(u64), // nodes that read this
    };

    allocator: std.mem.Allocator,
    mutex: ParkingMutex,
    next_id: u64,
    nodes: std.AutoHashMap(u64, Node),
    batch_depth: usize,
    /// Count of dependency-edge registrations dropped for lack of memory. Each
    /// one left its slot in the always-recompute degraded mode above. Non-zero
    /// means the graph traded work for correctness at least once.
    edge_drop_degradations: u64 = 0,
    /// Count of invalidation cascades that could not snapshot a dependents list
    /// and fell back to marking every computed node dirty. Non-zero means the
    /// graph was conservatively over-invalidated. Mirrors `Context.cascade_oom_fallbacks`.
    invalidate_oom_fallbacks: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .mutex = ParkingMutex.init(),
            .next_id = 1,
            .nodes = std.AutoHashMap(u64, Node).init(allocator),
            .batch_depth = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |node| {
            node.free_fn(self.allocator, node.box);
            node.deps.deinit(self.allocator);
            node.dependents.deinit(self.allocator);
        }
        self.nodes.deinit();
    }

    // --- type-erased box helpers (monomorphic per T) ---

    fn boxValue(self: *Self, comptime T: type, value: T) !*anyopaque {
        const p = try self.allocator.create(T);
        p.* = value;
        return @ptrCast(p);
    }

    fn Free(comptime T: type) type {
        return struct {
            fn run(allocator: std.mem.Allocator, box: *anyopaque) void {
                const p: *T = @ptrCast(@alignCast(box));
                allocator.destroy(p);
            }
        };
    }

    fn readBox(comptime T: type, box: *anyopaque) T {
        const p: *T = @ptrCast(@alignCast(box));
        return p.*;
    }

    // --- cells ---

    /// Allocate an input cell holding `value`, returning its handle. Independent
    /// per call (runtime-keyed), unlike the fn-pointer-keyed `Context.cell`.
    pub fn cell(self: *Self, comptime T: type, value: T) !TsHandle(T) {
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = self.next_id;
        self.next_id += 1;
        try self.nodes.put(id, .{
            .box = try self.boxValue(T, value),
            .free_fn = Free(T).run,
            .deps = .empty,
            .dependents = .empty,
        });
        return .{ .id = id };
    }

    /// Read a cell or (recomputing if dirty) a slot — by copy.
    pub fn getCell(self: *Self, comptime T: type, handle: TsHandle(T)) T {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.getUnlocked(T, handle.id);
    }

    /// Read any node by handle — by copy. Alias of [`getCell`] for slot reads.
    pub fn get(self: *Self, comptime T: type, handle: TsHandle(T)) T {
        return self.getCell(T, handle);
    }

    fn getUnlocked(self: *Self, comptime T: type, id: u64) T {
        const node = self.nodes.getPtr(id).?;
        if (node.dirty) {
            if (node.recompute_fn) |rf| rf(self, id);
        }
        return readBox(T, self.nodes.getPtr(id).?.box);
    }

    /// Overwrite an input cell (PartialEq-guarded). Marks transitive dependents
    /// dirty; they recompute lazily on read.
    pub fn setCell(self: *Self, comptime T: type, handle: TsHandle(T), value: T) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const node = self.nodes.getPtr(handle.id).?;
        if (std.meta.eql(readBox(T, node.box), value)) return; // PartialEq guard
        const p: *T = @ptrCast(@alignCast(node.box));
        p.* = value;
        self.invalidateDependentsUnlocked(handle.id);
    }

    // --- computed slots ---

    /// A derived slot whose `compute` is a **closure** (`ptr` = captured state).
    /// Computed eagerly now; reads register dependencies so a later `setCell`
    /// invalidates it. This is what backs a per-key reactive family slot.
    pub fn computedClosure(
        self: *Self,
        comptime T: type,
        ptr: *anyopaque,
        compute: ComputeFn(T),
    ) !TsHandle(T) {
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = self.next_id;
        self.next_id += 1;
        // Seed with a first compute so the box holds a real value.
        try self.nodes.put(id, .{
            .box = try self.boxValue(T, undefined),
            .free_fn = Free(T).run,
            .compute_ptr = ptr,
            .compute_erased = @constCast(@ptrCast(compute)),
            .recompute_fn = Recompute(T).run,
            .dirty = true,
            .deps = .empty,
            .dependents = .empty,
        });
        Recompute(T).run(self, id);
        return .{ .id = id };
    }

    /// A derived slot from a **pure** compute (no captured state).
    pub fn computed(self: *Self, comptime T: type, compute: *const fn (*ComputeContext) T) !TsHandle(T) {
        const Wrap = struct {
            fn call(ptr: *anyopaque, cc: *ComputeContext) T {
                const f: *const fn (*ComputeContext) T = @ptrCast(@alignCast(ptr));
                return f(cc);
            }
        };
        return self.computedClosure(T, @constCast(@ptrCast(compute)), Wrap.call);
    }

    /// The per-`T` recompute thunk: re-run the slot's compute, rebox the result,
    /// clear dirty, and cascade to dependents only if the value changed.
    fn Recompute(comptime T: type) type {
        return struct {
            fn run(self: *Self, id: u64) void {
                var node = self.nodes.getPtr(id).?;
                // Clear old dependency edges (re-discovered each compute).
                self.clearDepsUnlocked(id);
                // Reset the poison before re-registering: a compute that gets
                // all of its edges back is healed and may clear `dirty` again.
                self.nodes.getPtr(id).?.edges_incomplete = false;
                const compute: ComputeFn(T) = @ptrCast(@alignCast(node.compute_erased.?));
                var cc = ComputeContext{ .ctx = self, .slot_id = id };
                const result = compute(node.compute_ptr.?, &cc);
                node = self.nodes.getPtr(id).?; // compute may have grown the map
                const old = readBox(T, node.box);
                const p: *T = @ptrCast(@alignCast(node.box));
                p.* = result;
                // Only clear `dirty` if every edge this compute asked for was
                // actually registered. Otherwise the slot stays dirty and
                // recomputes on every read — see `ComputeContext.readNode`.
                node.dirty = node.edges_incomplete;
                if (!std.meta.eql(old, result)) {
                    self.invalidateDependentsUnlocked(id);
                }
            }
        };
    }

    // --- dependency graph plumbing (all unlocked; callers hold the mutex) ---

    /// All-or-nothing. The old body appended the forward edge and only then
    /// looked the dependency up, so both an absent `dep_id` and an OOM on the
    /// reverse append left a one-sided edge: a dependency the slot believes it
    /// has, that no `setCell` will ever fire on. Reserve both lists before
    /// touching either.
    fn addEdgeUnlocked(self: *Self, slot_id: u64, dep_id: u64) !void {
        if (slot_id == dep_id) return; // a self-read is not an edge
        const slot = self.nodes.getPtr(slot_id) orelse return;
        for (slot.deps.items) |d| {
            if (d == dep_id) return;
        }
        const dep = self.nodes.getPtr(dep_id) orelse return;
        try slot.deps.ensureUnusedCapacity(self.allocator, 1);
        try dep.dependents.ensureUnusedCapacity(self.allocator, 1);
        slot.deps.appendAssumeCapacity(dep_id);
        dep.dependents.appendAssumeCapacity(slot_id);
    }

    fn clearDepsUnlocked(self: *Self, slot_id: u64) void {
        const slot = self.nodes.getPtr(slot_id) orelse return;
        for (slot.deps.items) |dep_id| {
            if (self.nodes.getPtr(dep_id)) |dep| {
                var i: usize = 0;
                while (i < dep.dependents.items.len) {
                    if (dep.dependents.items[i] == slot_id) {
                        _ = dep.dependents.swapRemove(i);
                    } else i += 1;
                }
            }
        }
        slot.deps.clearRetainingCapacity();
    }

    fn invalidateDependentsUnlocked(self: *Self, id: u64) void {
        const node = self.nodes.getPtr(id) orelse return;
        // Snapshot: recursion may mutate the list.
        const snapshot = self.allocator.dupe(u64, node.dependents.items) catch {
            // The old `catch return` abandoned the entire cascade: every
            // transitive dependent stayed `dirty == false`, and `getUnlocked`
            // only recomputes when `dirty`, so they served stale boxes forever
            // with nothing left to rebuild the state. Degrade conservatively
            // instead — mark every computed node dirty. Over-invalidating and
            // correct beats precise and silently wrong, matching
            // `Context.cascadeFallbackMarkAllStaleUnlocked`.
            self.invalidate_oom_fallbacks += 1;
            var it = self.nodes.valueIterator();
            while (it.next()) |n| {
                if (n.recompute_fn != null) n.dirty = true;
            }
            return;
        };
        defer self.allocator.free(snapshot);
        for (snapshot) |dep_slot| {
            const dep = self.nodes.getPtr(dep_slot) orelse continue;
            if (!dep.dirty) {
                dep.dirty = true;
                self.invalidateDependentsUnlocked(dep_slot);
            }
        }
    }

    // --- batch ---

    /// Run `f(userdata)` inside a batch boundary. Recompute here is lazy (on
    /// read), so batching only nests a depth counter — writes never trigger an
    /// intermediate recompute regardless. Kept for API parity with `Context`.
    pub fn batch(self: *Self, comptime R: type, userdata: *anyopaque, f: *const fn (*anyopaque) R) R {
        self.mutex.lock();
        self.batch_depth += 1;
        self.mutex.unlock();
        const r = f(userdata);
        self.mutex.lock();
        self.batch_depth -= 1;
        self.mutex.unlock();
        return r;
    }
};

// ---------------------------------------------------------------------------
// Tests — a lock-backed reactive graph: per-key cells, computed invalidation,
// PartialEq guard, and cross-thread sharing.
// ---------------------------------------------------------------------------

const testing = std.testing;
const builtin = @import("builtin");

test "lazily/thread_safe_context: independent per-key cells" {
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();
    const a = try ctx.cell(u32, 1);
    const b = try ctx.cell(u32, 2);
    try testing.expectEqual(@as(u32, 1), ctx.getCell(u32, a));
    try testing.expectEqual(@as(u32, 2), ctx.getCell(u32, b));
    ctx.setCell(u32, a, 10);
    try testing.expectEqual(@as(u32, 10), ctx.getCell(u32, a));
    try testing.expectEqual(@as(u32, 2), ctx.getCell(u32, b)); // independent
}

var g_dep_cell: TsHandle(u32) = undefined;

fn doubleDep(cc: *ThreadSafeContext.ComputeContext) u32 {
    return cc.readNode(u32, g_dep_cell) * 2;
}

test "lazily/thread_safe_context: computed slot reacts to cell write" {
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();
    g_dep_cell = try ctx.cell(u32, 5);
    const derived = try ctx.computed(u32, doubleDep);
    try testing.expectEqual(@as(u32, 10), ctx.get(u32, derived));
    ctx.setCell(u32, g_dep_cell, 8);
    try testing.expectEqual(@as(u32, 16), ctx.get(u32, derived)); // recomputed lazily
}

test "lazily/thread_safe_context: PartialEq guard suppresses no-op write" {
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();
    const c = try ctx.cell(i64, 42);
    ctx.setCell(i64, c, 42); // no change
    try testing.expectEqual(@as(i64, 42), ctx.getCell(i64, c));
}

const Shared = struct {
    ctx: *ThreadSafeContext,
    handle: TsHandle(u32),
    fn bump(self: Shared) void {
        var i: u32 = 0;
        while (i < 100) : (i += 1) {
            const v = self.ctx.getCell(u32, self.handle);
            self.ctx.setCell(u32, self.handle, v + 1);
        }
    }
};

test "lazily/thread_safe_context: shared across threads under the lock" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();
    // N distinct cells, each bumped 100× from its own thread — the graph is
    // serialized so every cell lands at its final value with no torn state.
    const N = 4;
    var handles: [N]TsHandle(u32) = undefined;
    for (0..N) |i| handles[i] = try ctx.cell(u32, 0);
    var threads: [N]std.Thread = undefined;
    for (0..N) |i| {
        threads[i] = try std.Thread.spawn(.{}, Shared.bump, .{Shared{ .ctx = &ctx, .handle = handles[i] }});
    }
    for (threads) |t| t.join();
    for (0..N) |i| try testing.expectEqual(@as(u32, 100), ctx.getCell(u32, handles[i]));
}

// A dropped dependency edge on the thread-safe path is permanent, exactly as it
// is on the async path, but for different machinery: invalidation here is a
// lazy `dirty` pull, not a queue. `setCell` -> `invalidateDependentsUnlocked`
// walks `dependents` and nothing else; `getUnlocked` recomputes iff `dirty`.
// So a slot missing from a cell's `dependents` is never marked dirty, never
// recomputes, and — since `Recompute.run` clears deps before every compute —
// never gets the chance to re-register the edge. `ComputeFn(T)` returns plain
// `T`, so there is no error union to ride; the slot is poisoned into
// always-recompute instead.

const TsEdgeOomState = struct {
    var cell_a: TsHandle(u32) = .{ .id = 0 };
    var cell_b: TsHandle(u32) = .{ .id = 0 };
    var read_extra: bool = false;

    fn compute(_: *anyopaque, cc: *ThreadSafeContext.ComputeContext) u32 {
        var acc = cc.readNode(u32, cell_a);
        // Pulled in only on the second run, so the edge lists genuinely have to
        // grow: re-registering an existing edge reuses retained capacity and
        // never reaches the allocator.
        if (read_extra) acc += cc.readNode(u32, cell_b);
        return acc;
    }
};

test "lazily/thread_safe_context: a dropped edge must not leave the slot silently detached" {
    const S = TsEdgeOomState;
    const backing = testing.allocator;
    var ctx = ThreadSafeContext.init(backing);
    defer ctx.deinit();

    S.read_extra = false;
    S.cell_a = try ctx.cell(u32, 1);
    S.cell_b = try ctx.cell(u32, 100);

    var dummy: u8 = 0;
    const slot = try ctx.computedClosure(u32, &dummy, S.compute);
    try testing.expectEqual(@as(u32, 1), ctx.get(u32, slot));

    // Dirty the slot while memory is available, so the failure under test is
    // the edge registration and not the invalidation snapshot.
    S.read_extra = true;
    ctx.setCell(u32, S.cell_a, 2);

    // `resize_fail_index` matters: an ArrayList grows by trying an in-place
    // remap first, and a FailingAllocator that only fails fresh allocations
    // lets that remap through, leaving the test vacuously green.
    var failing = std.testing.FailingAllocator.init(backing, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    ctx.allocator = failing.allocator();
    _ = ctx.get(u32, slot);
    ctx.allocator = backing;
    try testing.expect(failing.has_induced_failure);

    // THE load-bearing assertion, and deliberately first: a write to the cell
    // whose edge was dropped must still reach the slot. Under the old
    // `catch {}` the slot was absent from `cell_b.dependents`, so it was never
    // marked dirty, `getUnlocked` returned the stale box, and this read
    // yielded 102 (the pre-write value) forever.
    ctx.setCell(u32, S.cell_b, 500);
    try testing.expectEqual(@as(u32, 502), ctx.get(u32, slot));

    // The degradation is self-healing: with memory back, the recompute above
    // re-registered both edges, so the slot has left always-recompute mode and
    // tracks normally again.
    try testing.expect(!ctx.nodes.getPtr(slot.id).?.edges_incomplete);
    ctx.setCell(u32, S.cell_a, 3);
    try testing.expectEqual(@as(u32, 503), ctx.get(u32, slot));

    // Checked last: the counter cannot fail against the old code for a
    // behavioural reason, since the field did not exist.
    try testing.expectEqual(@as(u64, 1), ctx.edge_drop_degradations);
}

test "lazily/thread_safe_context: an unsnapshotable cascade over-invalidates rather than going silent" {
    const backing = testing.allocator;
    var ctx = ThreadSafeContext.init(backing);
    defer ctx.deinit();

    const src = try ctx.cell(u32, 1);
    const Compute = struct {
        var cell_id: TsHandle(u32) = .{ .id = 0 };
        fn run(_: *anyopaque, cc: *ThreadSafeContext.ComputeContext) u32 {
            return cc.readNode(u32, cell_id) * 10;
        }
    };
    Compute.cell_id = src;
    var dummy: u8 = 0;
    const derived = try ctx.computedClosure(u32, &dummy, Compute.run);
    try testing.expectEqual(@as(u32, 10), ctx.get(u32, derived));

    // Starve the `dupe` that snapshots `src.dependents`.
    var failing = std.testing.FailingAllocator.init(backing, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    ctx.allocator = failing.allocator();
    ctx.setCell(u32, src, 9);
    ctx.allocator = backing;
    try testing.expect(failing.has_induced_failure);

    // The assertion that fails against the old `catch return`: the write is
    // still observable. The old code abandoned the cascade, leaving `derived`
    // with `dirty == false` and `getUnlocked` serving the stale 10.
    try testing.expectEqual(@as(u32, 90), ctx.get(u32, derived));

    try testing.expectEqual(@as(u64, 1), ctx.invalidate_oom_fallbacks);
}
