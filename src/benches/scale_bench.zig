//! #lzscalebench — large-graph scale benchmark for lazily-zig, replicating the
//! lazily-rs `scale` group (`benches/scale.rs`) and lazily-go
//! (`scale_bench_test.go`).
//!
//! Models a spreadsheet-shaped graph: `N` input cells plus `N` formula slots,
//! where `formula[i] = input[i] + input[i-1]` (local fan-in, like a column of
//! `=A_i + A_{i-1}`). With the default `N = 1_000_000` that is ~2M reactive
//! nodes once every formula has been pulled once. Four scenarios cover the
//! spreadsheet lifecycle:
//!
//!   - build                        — construct all N input nodes (formulas are
//!     materialized lazily on first read; see note below).
//!   - cold_full_recalc             — first read of every formula: materializes
//!     the N formula slots + edges and computes them.
//!   - viewport_recalc              — edit one input, read only a bounded
//!     viewport (the lazy-pull win: off-viewport formulas stay dirty / are
//!     never recomputed).
//!   - full_recalc_invalidate_all   — touch every input, then read every
//!     formula (worst-case full-sheet edit).
//!
//! Zig 0.17 removed `std.time.Timer` AND `std.time.nanoTimestamp`; this runner
//! reads a monotonic clock directly (`std.os.linux.clock_gettime(.MONOTONIC)`)
//! for wall-clock timing — the only portable monotonic source left in this
//! toolchain. Wired into `build.zig` as `zig build bench-scale` (kept out of the
//! default `zig build bench` so the fast micro-bench stays fast). Size and
//! viewport are env-configurable:
//!
//!   zig build bench-scale
//!   LAZILY_SCALE_N=1000000 zig build bench-scale
//!   LAZILY_SCALE_N=5000000 zig build bench-scale   # Google Sheets 10M-cell workbook
//!   LAZILY_SCALE_VIEWPORT=1000 zig build bench-scale
//!
//! ## Why the graph is built from raw `Slot`s (not `cell()`/`slot()`)
//!
//! lazily-zig's reactive graph is *comptime-function keyed*: `cell(T, ctx, fn)`
//! and `slot(T, ctx, fn)` derive a slot's cache key from the address of a
//! comptime `valueFn`, and a Zig `valueFn` cannot close over a runtime index.
//! A spreadsheet needs `N` *distinct* input cells and `N` *distinct* formula
//! slots that each read a specific pair of inputs — impossible with a single
//! shared comptime `valueFn`. So this bench uses the keyed escape hatch
//! (`Slot.initKeyed` / `slotKeyed` with a runtime cache key) plus a single
//! module-global `graph` the value functions consult for "which index am I".
//! The reactive shape is faithful: real dependency edges, real lazy
//! invalidation, real local fan-in. Only the closure-capture is simulated.
//!
//! Inputs are persistent `Slot`s holding a mutable `i64`; an edit writes the
//! new value in place and calls `Slot.emitChange` (invalidate dependents, keep
//! the input). Formulas are ordinary lazy slots: `emitChange` destroys them and
//! the next read re-materializes them — exactly the pull-based recompute the
//! lazily model specifies.

const std = @import("std");
const builtin = @import("builtin");
const lazily = @import("lazily");

const Context = lazily.Context;
const Slot = lazily.Slot;
const slotKeyed = lazily.slotKeyed;

const linux = std.os.linux;

fn nowNs() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

/// Module-global spreadsheet graph. The comptime value functions read
/// `graph.idx` to learn the index they are (re)computing, and `graph.values`
/// for the backing input storage. Single-threaded by construction.
const Graph = struct {
    ctx: *Context = undefined,
    n: usize = 0,
    values: []i64 = &.{},
    inputs: []*Slot = &.{},
    idx: usize = 0,
};

var graph: Graph = .{};

inline fn inputKey(i: usize) usize {
    return 2 * i;
}
inline fn formulaKey(i: usize) usize {
    return 2 * i + 1;
}

/// Input value function: returns the backing store for the index currently
/// being materialized. `graph.idx` is set immediately before any pull that can
/// create/recreate an input slot.
fn inputValueFn(_: *Context) anyerror!i64 {
    return graph.values[graph.idx];
}

/// Read (or lazily re-materialize) input `i`, registering a dependency edge
/// from the slot currently being computed (the formula) to input `i`.
fn readInput(ctx: *Context, i: usize) i64 {
    graph.idx = i;
    const p = slotKeyed(i64, ctx, inputKey(i), inputValueFn, null) catch unreachable;
    return p.*;
}

/// Formula value function: `formula[i] = input[i] + input[i-1]`. Captures its
/// own index from `graph.idx` before `readInput` mutates it.
fn formulaValueFn(ctx: *Context) anyerror!i64 {
    const i = graph.idx;
    const a = readInput(ctx, i);
    const prev = if (i == 0) 0 else i - 1;
    const b = readInput(ctx, prev);
    return a +% b;
}

/// Pull (or lazily re-materialize) formula `i`.
fn pullFormula(ctx: *Context, i: usize) i64 {
    graph.idx = i;
    const p = slotKeyed(i64, ctx, formulaKey(i), formulaValueFn, null) catch unreachable;
    return p.*;
}

/// Construct the N persistent input slots. Formula slots are NOT materialized
/// here (they are lazy in lazily-zig — there is no "register without compute").
fn buildInputs(ctx: *Context, a: std.mem.Allocator, n: usize) !void {
    graph.ctx = ctx;
    graph.n = n;
    graph.values = try a.alloc(i64, n);
    graph.inputs = try a.alloc(*Slot, n);
    for (0..n) |i| {
        graph.values[i] = @intCast(i);
        graph.idx = i;
        graph.inputs[i] = try Slot.initKeyed(i64, ctx, inputKey(i), inputValueFn, null);
    }
}

/// Read every formula once, folding into an accumulator (defeats DCE).
fn readAllFormulas(ctx: *Context, n: usize) i64 {
    var acc: i64 = 0;
    for (0..n) |i| acc +%= pullFormula(ctx, i);
    return acc;
}

/// Edit input `i` to `v`: write in place, then invalidate dependent formulas
/// (keep the input slot alive).
fn setInput(i: usize, v: i64) void {
    const s = graph.inputs[i];
    const p = s.getPtr(i64) catch unreachable;
    p.* = v;
    s.emitChange();
}

var sink: i64 = 0;

fn ms(ns: i128) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}

fn printRow(name: []const u8, total_ns: i128, per_cell_cells: usize) void {
    const total_ms = ms(total_ns);
    if (per_cell_cells > 0) {
        const per_cell_ns = @as(f64, @floatFromInt(total_ns)) /
            @as(f64, @floatFromInt(per_cell_cells));
        std.debug.print("{s:<32} {d:>10.2} ms   {d:>8.1} ns/cell\n", .{ name, total_ms, per_cell_ns });
    } else {
        std.debug.print("{s:<32} {d:>10.2} ms\n", .{ name, total_ms });
    }
}

/// Read an unsigned env var. Zig 0.17-dev's std reorganized env access behind
/// the new Io interface (no stable `std.posix.getenv`/`std.process.getenv`),
/// so we read `/proc/self/environ` via raw Linux syscalls — the one path that
/// stays stable across the toolchain churn and works without linking libc.
fn envUsize(name: []const u8, default: usize) usize {
    var buf: [65536]u8 = undefined;
    const fd: usize = linux.open("/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(fd)) < 0) return default;
    defer _ = linux.close(@intCast(fd));
    var total: usize = 0;
    while (total < buf.len) {
        const r = linux.read(@intCast(fd), buf[total..].ptr, buf.len - total);
        const ri: isize = @bitCast(r);
        if (ri <= 0) break;
        total += @intCast(r);
    }
    var it = std.mem.splitScalar(u8, buf[0..total], 0);
    while (it.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..eq], name)) {
            return std.fmt.parseInt(usize, entry[eq + 1 ..], 10) catch default;
        }
    }
    return default;
}

pub fn main() !void {
    const n = envUsize("LAZILY_SCALE_N", 1_000_000);
    var viewport = envUsize("LAZILY_SCALE_VIEWPORT", 1_000);
    if (viewport > n) viewport = n;

    // Heavy scenarios rebuild the whole sheet each rep; keep rep counts small
    // for large N so a run stays feasible in wall-clock time and memory.
    const heavy_reps: usize = if (n <= 1_000_000) 3 else 1;
    const viewport_reps: usize = 1_000;

    std.debug.print(
        \\lazily-zig scale benchmark (#lzscalebench)
        \\==========================================
        \\N (rows)        = {d}  ({d} cells = {d} inputs + {d} formulas)
        \\viewport        = {d}
        \\heavy reps      = {d}
        \\allocator       = ArenaAllocator over page_allocator (fresh per scenario)
        \\timing          = std.os.linux.clock_gettime(.MONOTONIC), wall-clock
        \\
        \\
    , .{ n, 2 * n, n, n, viewport, heavy_reps });

    const base = std.heap.page_allocator;
    const cells = 2 * n;

    // --- build: construct N input nodes (formulas lazy). ---
    {
        var best: i128 = std.math.maxInt(i128);
        var rep: usize = 0;
        while (rep < heavy_reps) : (rep += 1) {
            var arena = std.heap.ArenaAllocator.init(base);
            const a = arena.allocator();
            const ctx = try Context.init(a);
            const t0 = nowNs();
            try buildInputs(ctx, a, n);
            const t1 = nowNs();
            if (t1 - t0 < best) best = t1 - t0;
            arena.deinit();
        }
        printRow("build", best, cells);
    }

    // --- cold_full_recalc: first read of every formula. ---
    {
        var best: i128 = std.math.maxInt(i128);
        var rep: usize = 0;
        while (rep < heavy_reps) : (rep += 1) {
            var arena = std.heap.ArenaAllocator.init(base);
            const a = arena.allocator();
            const ctx = try Context.init(a);
            try buildInputs(ctx, a, n);
            const t0 = nowNs();
            sink = readAllFormulas(ctx, n);
            const t1 = nowNs();
            if (t1 - t0 < best) best = t1 - t0;
            arena.deinit();
        }
        printRow("cold_full_recalc", best, cells);
    }

    // --- viewport_recalc: edit one input, read a bounded viewport. ---
    {
        var arena = std.heap.ArenaAllocator.init(base);
        const a = arena.allocator();
        const ctx = try Context.init(a);
        try buildInputs(ctx, a, n);
        sink = readAllFormulas(ctx, n); // warm the whole sheet once

        const mid = n / 2;
        const lo = if (mid >= viewport / 2) mid - viewport / 2 else 0;
        const hi = @min(lo + viewport, n);

        var tick: i64 = 0;
        const t0 = nowNs();
        var rep: usize = 0;
        while (rep < viewport_reps) : (rep += 1) {
            tick += 1;
            setInput(mid, tick);
            var acc: i64 = 0;
            var i = lo;
            while (i < hi) : (i += 1) acc +%= pullFormula(ctx, i);
            sink = acc;
        }
        const t1 = nowNs();
        const per_iter = @divTrunc(t1 - t0, @as(i128, @intCast(viewport_reps)));
        const per_iter_us = @as(f64, @floatFromInt(per_iter)) / @as(f64, std.time.ns_per_us);
        std.debug.print("{s:<32} {d:>10.3} us   (edit 1 input, read {d}-cell viewport, avg of {d})\n", .{
            "viewport_recalc (per edit)", per_iter_us, hi - lo, viewport_reps,
        });
        arena.deinit();
    }

    // --- full_recalc_invalidate_all: touch every input, read every formula. ---
    {
        var best: i128 = std.math.maxInt(i128);
        var arena = std.heap.ArenaAllocator.init(base);
        const a = arena.allocator();
        const ctx = try Context.init(a);
        try buildInputs(ctx, a, n);
        sink = readAllFormulas(ctx, n); // warm once

        var tick: i64 = 0;
        var rep: usize = 0;
        while (rep < heavy_reps) : (rep += 1) {
            tick += 1;
            const t0 = nowNs();
            const base_v = tick;
            for (0..n) |j| setInput(j, base_v + @as(i64, @intCast(j)));
            sink = readAllFormulas(ctx, n);
            const t1 = nowNs();
            if (t1 - t0 < best) best = t1 - t0;
        }
        printRow("full_recalc_invalidate_all", best, cells);
        arena.deinit();
    }

    std.debug.print("\nsink={d}  (defeats dead-code elimination)\n", .{sink});
}
