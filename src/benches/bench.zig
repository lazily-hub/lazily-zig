//! lazily-zig benchmarks. Mirrors the lazily-rs `benches/` surface
//! (`context.rs`: cached_reads, cold_first_get, dependency_fan_out,
//! set_cell_invalidation, memo_equality_suppression).
//!
//! Zig 0.17 removed `std.time.Timer`; this runner reports iteration counts +
//! `Context.instrumentationSnapshot()` deltas (deterministic counter-based
//! measurement, more stable than wall clock for reactive-graph microbenches).
//!
//! Run: `zig build bench`

const std = @import("std");
const lazily = @import("lazily");

const Context = lazily.Context;
const cell = lazily.cell;
const slot = lazily.slot;
const signal = lazily.signal;
const Slot = lazily.Slot;
const slotKeyed = lazily.slotKeyed;
const MvRegister = lazily.MvRegister;

const Inst = Context.Instrumentation;

fn printHeader(name: []const u8, iters: u64) void {
    std.debug.print("{s:<40} {d:>12} iters\n", .{ name, iters });
}

fn printDelta(d: Inst) void {
    std.debug.print("  node_allocations={d} edges_added={d} recomputes={d} queue_pushes={d} max_depth={d}\n", .{
        d.node_allocations,
        d.dependency_edges_added,
        d.slot_recomputes,
        d.effect_queue_pushes,
        d.max_effect_queue_depth,
    });
}

fn getSource(_: *Context) anyerror!u32 {
    return 42;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    std.debug.print("lazily-zig benchmarks\n======================\n\n", .{});

    // cached_reads: warm-cache slot re-reads (no recompute).
    {
        const ctx = try Context.init(allocator);
        defer ctx.deinit();
        _ = try slot(u32, ctx, struct {
            fn call(_: *Context) anyerror!u32 {
                return 42;
            }
        }.call, null);
        const before = ctx.instrumentationSnapshot();
        const iters: u64 = 100_000;
        var i: u64 = 0;
        while (i < iters) : (i += 1) {
            _ = slot(u32, ctx, struct {
                fn call(_: *Context) anyerror!u32 {
                    return 42;
                }
            }.call, null) catch {};
        }
        printHeader("cached_reads", iters);
        printDelta(.{
            .node_allocations = ctx.instrumentationSnapshot().node_allocations - before.node_allocations,
            .slot_recomputes = ctx.instrumentationSnapshot().slot_recomputes - before.slot_recomputes,
            .dependency_edges_added = ctx.instrumentationSnapshot().dependency_edges_added - before.dependency_edges_added,
            .dependency_edges_removed = ctx.instrumentationSnapshot().dependency_edges_removed - before.dependency_edges_removed,
            .effect_queue_pushes = ctx.instrumentationSnapshot().effect_queue_pushes - before.effect_queue_pushes,
            .max_effect_queue_depth = ctx.instrumentationSnapshot().max_effect_queue_depth,
        });
    }

    // cold_first_get: fresh context + slot per iteration.
    {
        const iters: u64 = 1000;
        var total_nodes: u64 = 0;
        var i: u64 = 0;
        while (i < iters) : (i += 1) {
            const ctx = try Context.init(allocator);
            _ = try slot(u32, ctx, struct {
                fn call(_: *Context) anyerror!u32 {
                    return 42;
                }
            }.call, null);
            total_nodes += ctx.instrumentationSnapshot().node_allocations;
            ctx.deinit();
        }
        std.debug.print("{s:<40} {d:>12} iters  nodes={d}\n", .{ "cold_first_get", iters, total_nodes });
    }

    // dependency_fan_out: invalidate a cell with N derived readers.
    {
        const ctx = try Context.init(allocator);
        defer ctx.deinit();
        const N: u64 = 256;
        const src = try cell(u32, ctx, getSource, null);
        var i: u64 = 0;
        while (i < N) : (i += 1) {
            _ = try slot(u32, ctx, struct {
                fn call(c: *Context) anyerror!u32 {
                    const s = try cell(u32, c, getSource, null);
                    return s.get() + 1;
                }
            }.call, null);
        }
        const before = ctx.instrumentationSnapshot();
        const iters: u64 = 1000;
        i = 0;
        while (i < iters) : (i += 1) src.set(@intCast(i));
        const after = ctx.instrumentationSnapshot();
        printHeader("set_cell_invalidation_fan_out_256", iters);
        printDelta(.{
            .node_allocations = after.node_allocations - before.node_allocations,
            .slot_recomputes = after.slot_recomputes - before.slot_recomputes,
            .dependency_edges_added = after.dependency_edges_added - before.dependency_edges_added,
            .dependency_edges_removed = after.dependency_edges_removed - before.dependency_edges_removed,
            .effect_queue_pushes = after.effect_queue_pushes - before.effect_queue_pushes,
            .max_effect_queue_depth = after.max_effect_queue_depth,
        });
    }

    // memo_equality_suppression: signal whose recomputed value is unchanged.
    {
        const ctx = try Context.init(allocator);
        defer ctx.deinit();
        const src = try cell(u32, ctx, getSource, null);
        const sig = try signal(u32, ctx, struct {
            fn call(c: *Context) anyerror!u32 {
                _ = try cell(u32, c, getSource, null);
                return 99; // unchanged regardless of source
            }
        }.call, null);
        defer ctx.allocator.destroy(sig);
        const before = ctx.instrumentationSnapshot();
        const iters: u64 = 1000;
        var i: u64 = 0;
        while (i < iters) : (i += 1) src.set(@intCast(i));
        const after = ctx.instrumentationSnapshot();
        printHeader("memo_equality_suppression", iters);
        printDelta(.{
            .node_allocations = after.node_allocations - before.node_allocations,
            .slot_recomputes = after.slot_recomputes - before.slot_recomputes,
            .dependency_edges_added = after.dependency_edges_added - before.dependency_edges_added,
            .dependency_edges_removed = after.dependency_edges_removed - before.dependency_edges_removed,
            .effect_queue_pushes = after.effect_queue_pushes - before.effect_queue_pushes,
            .max_effect_queue_depth = after.max_effect_queue_depth,
        });
    }

    // cached_reads_with_dependency: warm-cache slot re-reads while a tracking
    // frame is active. Exercises the `#lzzigslotconstptr` *const-Slot cached
    // `get` AND `#lzzigcontainsfast` — every cached re-read of the inner slot
    // by the outer valueFn walks the cached-read path with the outer slot's
    // tracking frame pushed. Pre-fix this hit `getOrPut` on every cached read;
    // the `contains` fast path makes the steady state `edges_added == 1` (one
    // first-time subscribe, then 99,999 fast-path skips).
    {
        const ctx = try Context.init(allocator);
        defer ctx.deinit();
        const inner_fn = struct {
            fn call(_: *Context) anyerror!u32 {
                return 42;
            }
        }.call;
        // Prime the cache: first pull materializes the inner slot.
        _ = try slot(u32, ctx, inner_fn, null);
        ctx.resetInstrumentation();
        const before = ctx.instrumentationSnapshot();
        // Materializing `outer` runs its valueFn, which performs 100,000
        // cached reads of the inner slot — each walks the cached-read branch
        // with `outer`'s tracking frame pushed.
        const outer = try slot(u32, ctx, struct {
            fn call(c: *Context) anyerror!u32 {
                const inner_inner_fn = struct {
                    fn call(_: *Context) anyerror!u32 {
                        return 42;
                    }
                }.call;
                var i: u64 = 0;
                const n: u64 = 100_000;
                while (i < n) : (i += 1) {
                    _ = slot(u32, c, inner_inner_fn, null) catch return error.OutOfMemory;
                }
                return 0;
            }
        }.call, null);
        _ = outer;
        printHeader("cached_reads_with_dependency", 100_000);
        printDelta(.{
            .node_allocations = ctx.instrumentationSnapshot().node_allocations - before.node_allocations,
            .slot_recomputes = ctx.instrumentationSnapshot().slot_recomputes - before.slot_recomputes,
            .dependency_edges_added = ctx.instrumentationSnapshot().dependency_edges_added - before.dependency_edges_added,
            .dependency_edges_removed = ctx.instrumentationSnapshot().dependency_edges_removed - before.dependency_edges_removed,
            .effect_queue_pushes = ctx.instrumentationSnapshot().effect_queue_pushes - before.effect_queue_pushes,
            .max_effect_queue_depth = ctx.instrumentationSnapshot().max_effect_queue_depth,
        });
    }

    // arena_churn: cache-race-loser burst — every iter allocates a fresh slot
    // and immediately frees it because the cache already holds the key. This is
    // the production workload the `#lzzigfreestack` inline free-stack absorbs:
    // alloc() and free() ping-pong with no `free_list.append` allocator calls
    // for bursts ≤ 16 deep. `node_allocations` increments per fresh slot.
    {
        const ctx = try Context.init(allocator);
        defer ctx.deinit();
        const key: usize = 0x4242_4242;
        // Prime the cache so every subsequent initKeyed at `key` is the loser.
        const primed = try Slot.initKeyed(u32, ctx, key, struct {
            fn call(_: *Context) anyerror!u32 {
                return 42;
            }
        }.call, null);
        _ = primed;
        ctx.resetInstrumentation();
        const before = ctx.instrumentationSnapshot();
        const iters: u64 = 100_000;
        var i: u64 = 0;
        while (i < iters) : (i += 1) {
            _ = Slot.initKeyed(u32, ctx, key, struct {
                fn call(_: *Context) anyerror!u32 {
                    return 42;
                }
            }.call, null) catch {};
        }
        printHeader("arena_churn_cache_race_loser", iters);
        printDelta(.{
            .node_allocations = ctx.instrumentationSnapshot().node_allocations - before.node_allocations,
            .slot_recomputes = ctx.instrumentationSnapshot().slot_recomputes - before.slot_recomputes,
            .dependency_edges_added = ctx.instrumentationSnapshot().dependency_edges_added - before.dependency_edges_added,
            .dependency_edges_removed = ctx.instrumentationSnapshot().dependency_edges_removed - before.dependency_edges_removed,
            .effect_queue_pushes = ctx.instrumentationSnapshot().effect_queue_pushes - before.effect_queue_pushes,
            .max_effect_queue_depth = ctx.instrumentationSnapshot().max_effect_queue_depth,
        });
    }

    // crdt_merge: MvRegister.mergeFrom churn. `#lzzigcrdtstack` removed the
    // `std.heap.page_allocator.alloc` per merge (128-entry stack buffer covers
    // the realistic entry count). The bench reports iteration count and the
    // resulting `entries` length; counter-based since the win is in
    // allocator-syscall avoidance, not graph work.
    {
        const iters: u64 = 100_000;
        var i: u64 = 0;
        while (i < iters) : (i += 1) {
            var a = MvRegister(u32).init(allocator);
            defer a.deinit();
            var b = MvRegister(u32).init(allocator);
            defer b.deinit();
            try a.set(1, 1);
            try b.set(2, 2);
            _ = try a.mergeFrom(&b);
        }
        std.debug.print(
            "{s:<40} {d:>12} iters  merges={d}\n",
            .{ "crdt_mv_register_merge", iters, iters },
        );
    }

    std.debug.print("\n(instrumentation counter deltas; lower = less work per op)\n", .{});
}
