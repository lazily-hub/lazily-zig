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

    std.debug.print("\n(instrumentation counter deltas; lower = less work per op)\n", .{});
}
