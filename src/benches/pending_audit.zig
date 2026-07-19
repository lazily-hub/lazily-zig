//! Pending/scheduled-effect queue audit (`#lzspecedgeindex`).
//!
//! `src/benches/fanout_load.zig` walks fan-out width, but every node in it is a
//! lazy pull-based `slotKeyed`. Nothing in it ever enters `pending_recompute`,
//! so it is structurally blind to the defect this harness exists to rule out:
//! a linear scan of the pending/scheduled effect collection, which lazily-rs
//! and lazily-cpp shipped in `run_effect` (publish path) and lazily-kt shipped
//! in `disposeEffect` (teardown path). rs measured 222x at width 65,536; kt
//! measured 10,677x on teardown.
//!
//! Shape, copied from rs `examples/edge_audit.rs`: **total work is held fixed**
//! at `total_nodes` eager Signals and only the fan-out width varies, so every
//! rung recomputes the same number of nodes, publishes the same number of
//! values, and disposes the same number of handles. Anything that grows with
//! width is width-attributable. The assertion is against a narrow-fan-out
//! control at equal node count, never against absolute growth.
//!
//! Two arms:
//!   `zig build audit-pending`        — shipped engine
//!   `zig build audit-pending-naive`  — `-Dnaive_pending_scan=true`, which puts
//!                                      the scan back (see signal.zig
//!                                      `naiveEnqueueScan` / `naiveDisposeScan`)
//! A flat column from the shipped arm alone is equally consistent with "no
//! defect" and "blind harness". The naive arm's ratio is the detection margin
//! that tells the two apart.

const std = @import("std");
const lazily = @import("lazily");

const Context = lazily.Context;
const Slot = lazily.Slot;
const slotKeyed = lazily.slotKeyed;
const signalKeyed = lazily.signalKeyed;
const Signal = lazily.Signal;

const linux = std.os.linux;

// Zig master gutted std.posix/std.fs and std.process env access; read the clock
// and the environment through raw std.os.linux syscalls, like fanout_load.zig.
fn nowNs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn readProcFile(path: [*:0]const u8, buf: []u8) ?[]u8 {
    const fd: usize = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(fd)) < 0) return null;
    defer _ = linux.close(@intCast(fd));
    var total: usize = 0;
    while (total < buf.len) {
        const r = linux.read(@intCast(fd), buf[total..].ptr, buf.len - total);
        const ri: isize = @bitCast(r);
        if (ri <= 0) break;
        total += @intCast(r);
    }
    return buf[0..total];
}

// --- the graph -------------------------------------------------------------

const Graph = struct {
    source_value: i64 = 0,
    /// Source the currently-building / currently-publishing signals read.
    current_source: usize = 0,
};
var g: Graph = .{};

inline fn sourceKey(s: usize) usize {
    return 2 * s;
}
inline fn sigKey(i: usize) usize {
    return 2 * i + 1;
}

fn sourceValueFn(_: *Context) anyerror!i64 {
    return g.source_value;
}

/// Reading the source inside a tracking frame is what registers
/// `signal -> source` and puts the signal on the invalidation path.
fn sigValueFn(ctx: *Context) anyerror!i64 {
    const p = slotKeyed(i64, ctx, sourceKey(g.current_source), sourceValueFn, null) catch unreachable;
    return p.* *% 1000;
}

var sink: i64 = 0;

const Rung = struct {
    width: usize,
    sources: usize,
    publish_ns_per_node: f64,
    dispose_ns_per_node: f64,
};

/// State of the pending queue while the dispose loop runs.
///
/// `drained` is the natural teardown position and the one kt was in when its
/// `disposeEffect` scan cost 10,677x — "the collection is empty, so the scan is
/// free" was false there. `saturated` disposes each cohort while its siblings
/// are still queued behind them, so the scan has something to walk no matter
/// how the runtime treats an emptied collection.
///
/// Both arms are required. A drained-only harness that reports a small margin
/// under forced-naive has not shown absence — lazily-dart's first teardown arm
/// wrapped the work in `batch()`, which defers the cascade, so its pending list
/// was empty throughout and forced-naive came back at 1.2x. That reads exactly
/// like a clean negative and was measuring nothing. A low forced-naive margin
/// means suspect the harness first.
const DisposeMode = enum { drained, saturated };

/// Build `total / width` sources each fanning out to `width` eager Signals,
/// publish once per source (so every rung recomputes exactly `total` nodes),
/// then dispose every handle.
fn runRung(total: usize, width: usize, dispose_mode: DisposeMode) !Rung {
    const sources = total / width;

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try Context.init(a);
    try ctx.initDense(2 * total + 2 * sources + 4);

    const pa = std.heap.page_allocator;
    const sigs = try pa.alloc(*Signal(i64), total);
    defer pa.free(sigs);

    g.source_value = 1;
    for (0..sources) |s| {
        g.current_source = s;
        _ = try slotKeyed(i64, ctx, sourceKey(s), sourceValueFn, null);
    }

    // --- build (untimed; buildOnly-equivalent cost is not the axis) --------
    for (0..total) |i| {
        g.current_source = i / width;
        sigs[i] = try signalKeyed(i64, ctx, sigKey(i), sigValueFn, null);
    }

    for (0..sources) |s| {
        const src = ctx.cacheLookup(sourceKey(s)).?;
        if (src.change_subscribers.count() != width) return error.EdgeCountMismatch;
    }

    // --- publish: one publish per source, `width` enqueues + drains each ---
    // Total enqueues across the rung is `total` at every width. Only the queue
    // depth at enqueue time varies, which is exactly what a dedup scan would
    // charge for.
    g.source_value = 2;
    var publish_ns: u64 = 0;
    var dispose_ns: u64 = 0;

    switch (dispose_mode) {
        .drained => {
            var t = nowNs();
            for (0..sources) |s| {
                g.current_source = s;
                const src = ctx.cacheLookup(sourceKey(s)).?;
                const src_ptr = src.getPtr(i64) catch unreachable;
                src_ptr.* = 2;
                src.emitChange();
                ctx.drainPendingRecompute();
            }
            publish_ns = nowNs() - t;

            // Correctness: every signal observed the publish. Only meaningful
            // in this mode; `saturated` disposes before the drain by design.
            for (0..total) |i| sink +%= sigs[i].get().*;
            if (ctx.pending_recompute.items.len != 0) return error.QueueNotDrained;

            t = nowNs();
            for (sigs) |sig| sig.dispose();
            dispose_ns = nowNs() - t;
        },
        .saturated => {
            for (0..sources) |s| {
                g.current_source = s;
                const src = ctx.cacheLookup(sourceKey(s)).?;
                const src_ptr = src.getPtr(i64) catch unreachable;
                src_ptr.* = 2;

                // `emitChange` drains the queue itself, which would leave
                // nothing to dispose against — exactly the class of mistake
                // that made dart's first teardown arm inert. Enqueue without
                // draining, then drain explicitly after the dispose loop.
                var t = nowNs();
                ctx.mutex.lock();
                src.emitChangeUnlocked();
                ctx.mutex.unlock();
                publish_ns += nowNs() - t;

                // The cohort is queued and undrained right now. Verify that
                // before timing, so a harness that silently stopped saturating
                // (dart's `batch()` trap) fails loudly instead of reporting a
                // flat column.
                if (ctx.pending_recompute.items.len != width) return error.QueueNotSaturated;

                t = nowNs();
                for (sigs[s * width ..][0..width]) |sig| sig.dispose();
                dispose_ns += nowNs() - t;

                t = nowNs();
                ctx.drainPendingRecompute();
                publish_ns += nowNs() - t;
            }
        },
    }

    const ftotal = @as(f64, @floatFromInt(total));
    return .{
        .width = width,
        .sources = sources,
        .publish_ns_per_node = @as(f64, @floatFromInt(publish_ns)) / ftotal,
        .dispose_ns_per_node = @as(f64, @floatFromInt(dispose_ns)) / ftotal,
    };
}

fn envUsize(name: []const u8, dflt: usize) usize {
    var buf: [65536]u8 = undefined;
    const data = readProcFile("/proc/self/environ", &buf) orelse return dflt;
    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..eq], name)) {
            return std.fmt.parseInt(usize, entry[eq + 1 ..], 10) catch dflt;
        }
    }
    return dflt;
}

/// Narrow-fan-out control at equal node count. Below any plausible promotion
/// threshold, so its own per-publish queue depth is O(1); it carries the same
/// memory-hierarchy slope as the wide rungs and none of the width.
const control_width: usize = 8;

/// True when neither naive arm is compiled in — the only configuration that
/// asserts.
const shipped = !lazily.build_options.naive_pending_scan and
    std.mem.eql(u8, lazily.build_options.naive_dispose_scan, "none");

pub fn main() !void {
    const total = envUsize("LAZILY_AUDIT_TOTAL", 65536);
    const reps = envUsize("LAZILY_AUDIT_REPS", 3);

    std.debug.print(
        \\
        \\lazily-zig pending/scheduled-effect queue audit (#lzspecedgeindex)
        \\  naive_pending_scan (publish path)  = {}
        \\  naive_dispose_scan (teardown path) = {s}
        \\  total eager Signals per rung = {d} (FIXED — only width varies)
        \\  narrow-fan-out control width = {d}
        \\  reps = {d} (best-of, ratios only; absolute ns are not trustworthy
        \\  under concurrent load)
        \\
        \\
    , .{
        lazily.build_options.naive_pending_scan,
        lazily.build_options.naive_dispose_scan,
        total,
        control_width,
        reps,
    });

    const widths = [_]usize{ control_width, 64, 256, 1024, 4096, 16384, 65536 };

    std.debug.print("{s:>8} {s:>9} {s:>16} {s:>18} {s:>18}\n", .{
        "width", "sources", "publish ns/node", "dispose ns/node", "dispose ns/node",
    });
    std.debug.print("{s:>8} {s:>9} {s:>16} {s:>18} {s:>18}\n", .{
        "", "", "", "(drained queue)", "(saturated queue)",
    });

    var control_publish: f64 = 0;
    var control_drained: f64 = 0;
    var control_saturated: f64 = 0;
    var worst = [_]f64{ 0, 0, 0 };
    var worst_w = [_]usize{ 0, 0, 0 };

    for (widths) |w| {
        if (w > total) continue;

        var drained = try runRung(total, w, .drained);
        var saturated = try runRung(total, w, .saturated);
        // Best-of per column, independently. The drained dispose column lands
        // near 1 ns/node on the shipped engine, close enough to timer and
        // scheduler noise that a single sample's ratio is meaningless; the min
        // over reps is the least noise-contaminated estimate of each column.
        for (1..reps) |_| {
            const d = try runRung(total, w, .drained);
            const t = try runRung(total, w, .saturated);
            drained.publish_ns_per_node = @min(drained.publish_ns_per_node, d.publish_ns_per_node);
            drained.dispose_ns_per_node = @min(drained.dispose_ns_per_node, d.dispose_ns_per_node);
            saturated.dispose_ns_per_node = @min(saturated.dispose_ns_per_node, t.dispose_ns_per_node);
        }

        std.debug.print("{d:>8} {d:>9} {d:>16.1} {d:>18.1} {d:>18.1}\n", .{
            w, drained.sources, drained.publish_ns_per_node,
            drained.dispose_ns_per_node, saturated.dispose_ns_per_node,
        });

        if (w == control_width) {
            control_publish = drained.publish_ns_per_node;
            control_drained = drained.dispose_ns_per_node;
            control_saturated = saturated.dispose_ns_per_node;
            continue;
        }

        const ratios = [_]f64{
            drained.publish_ns_per_node / @max(control_publish, 0.0001),
            drained.dispose_ns_per_node / @max(control_drained, 0.0001),
            saturated.dispose_ns_per_node / @max(control_saturated, 0.0001),
        };
        for (ratios, 0..) |r, k| {
            if (r > worst[k]) {
                worst[k] = r;
                worst_w[k] = w;
            }
        }
    }

    std.debug.print(
        \\
        \\worst wide/narrow ratio vs the width-{d} control at equal node count:
        \\  publish            {d:>10.2}x at width {d}
        \\  dispose  drained   {d:>10.2}x at width {d}
        \\  dispose  saturated {d:>10.2}x at width {d}
        \\
    , .{
        control_width,
        worst[0], worst_w[0],
        worst[1], worst_w[1],
        worst[2], worst_w[2],
    });

    // Only the shipped arm asserts. The naive arms are expected to blow through
    // these and exist to report their detection margin. A naive margin in the
    // low single digits is a broken arm, not a fast path.
    if (comptime shipped) {
        if (worst[0] >= 4.0) {
            std.debug.print("publish cost scales with fan-out width at fixed node count\n", .{});
            return error.PublishCostWidthDependent;
        }
        // Wider gate on the dispose columns: they sit near 1 ns/node, where
        // clock granularity alone moves the ratio by 2-3x run to run. The naive
        // arms clear this by two to three orders of magnitude, so the looser
        // bound costs no detection power.
        if (worst[1] >= 8.0 or worst[2] >= 8.0) {
            std.debug.print("dispose cost scales with fan-out width at fixed node count\n", .{});
            return error.DisposeCostWidthDependent;
        }
        std.debug.print("publish + dispose (drained AND saturated) within bound at every width\n", .{});
    }

    std.debug.print("sink = {d}\n", .{sink});
}
