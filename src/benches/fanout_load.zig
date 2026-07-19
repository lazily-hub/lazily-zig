//! Fan-out width ladder load test (`#lzspecedgeindex`).
//!
//! Every existing lazily-zig bench scales *node count* and pins fan-out at 2,
//! which is exactly why the O(n^2) edge-registration defect hid: width was
//! never a variable. This walks width instead — one source slot with N
//! dependents — and asserts the shape of the curve rather than printing it.
//!
//! Three phases are timed separately so the two fixes stay distinguishable:
//!
//!   build   N x `getOrPut` into the source's `change_subscribers`
//!           (the registration defect: unconditional linear dedup scan).
//!   notify  one `emitChange` on the source, cascading to all N dependents
//!           (control: the edge-index change must not move this).
//!   destroy N x `Slot.destroy`, each doing
//!           `parent.change_subscribers.remove(self)`
//!           (the `EdgeSet.remove` defect, unique to this binding: a linear
//!           scan called per-edge during cascade).
//!
//! Method is climb / project / refuse: each rung measures bytes-per-subscriber
//! and projects the next rung from *that* measurement, refusing to start a rung
//! whose projection would not leave `LAZILY_FANOUT_FLOOR_MB` of MemAvailable
//! free. Mirrors lazily-rs `examples/pubsub_load.rs`.
//!
//! MANUAL / ON-DEMAND — not wired into `zig build test`:
//!
//!   zig build load-fanout                               # ladder to 1M
//!   LAZILY_FANOUT_MAX=10000000 zig build load-fanout    # ladder to 10M
//!
//! Zig 0.17-dev removed `std.time.Timer`, `std.time.nanoTimestamp` and stable
//! env access, so this reads the monotonic clock, `/proc/self/statm` and
//! `/proc/meminfo` through raw `std.os.linux` syscalls, like `scale_bench.zig`.

const std = @import("std");
const lazily = @import("lazily");
const Context = lazily.Context;
const Slot = lazily.Slot;
const slotKeyed = lazily.slotKeyed;

const linux = std.os.linux;

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

fn envUsize(name: []const u8, default: usize) usize {
    var buf: [65536]u8 = undefined;
    const data = readProcFile("/proc/self/environ", &buf) orelse return default;
    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..eq], name)) {
            return std.fmt.parseInt(usize, entry[eq + 1 ..], 10) catch default;
        }
    }
    return default;
}

/// Resident set size in bytes.
fn rssBytes() usize {
    var buf: [256]u8 = undefined;
    const data = readProcFile("/proc/self/statm", &buf) orelse return 0;
    var it = std.mem.tokenizeAny(u8, data, " \n");
    _ = it.next() orelse return 0; // total program size
    const rss_pages_str = it.next() orelse return 0;
    const pages = std.fmt.parseInt(usize, rss_pages_str, 10) catch return 0;
    return pages * 4096;
}

/// MemAvailable in bytes (0 if unreadable — the guard then refuses to climb).
fn memAvailableBytes() usize {
    var buf: [8192]u8 = undefined;
    const data = readProcFile("/proc/meminfo", &buf) orelse return 0;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "MemAvailable:")) continue;
        var it = std.mem.tokenizeAny(u8, line["MemAvailable:".len..], " \t");
        const kb_str = it.next() orelse return 0;
        const kb = std.fmt.parseInt(usize, kb_str, 10) catch return 0;
        return kb * 1024;
    }
    return 0;
}

// --- the graph -------------------------------------------------------------

const Graph = struct {
    source_value: i64 = 0,
    idx: usize = 0,
    /// Subscribers per source. `group == n` is the wide fan-out under test;
    /// a small `group` is the narrow control (see `control_group`).
    group: usize = 1,
};
var g: Graph = .{};

inline fn sourceKey(s: usize) usize {
    return 2 * s;
}
inline fn subKey(i: usize) usize {
    return 2 * i + 1;
}
inline fn sourceOf(i: usize) usize {
    return i / g.group;
}

fn sourceValueFn(_: *Context) anyerror!i64 {
    return g.source_value;
}

/// Read this subscriber's source, registering `current slot -> source`. This is
/// the call that drives `source.change_subscribers.getOrPut`.
fn readSource(ctx: *Context, s: usize) i64 {
    const p = slotKeyed(i64, ctx, sourceKey(s), sourceValueFn, null) catch unreachable;
    return p.*;
}

fn subValueFn(ctx: *Context) anyerror!i64 {
    const i = g.idx;
    return readSource(ctx, sourceOf(i)) +% @as(i64, @intCast(i));
}

fn pullSub(ctx: *Context, i: usize) i64 {
    g.idx = i;
    const p = slotKeyed(i64, ctx, subKey(i), subValueFn, null) catch unreachable;
    return p.*;
}

fn sourceSlot(ctx: *Context, s: usize) *Slot {
    return ctx.cacheLookup(sourceKey(s)).?;
}

/// Fan-out of the narrow control: comfortably below `promote_threshold`, so its
/// linear dedup scan is effectively O(1) and its cost is pure allocation +
/// cache-miss noise at the same node count.
const control_group: usize = 8;

/// Build N subscribers over ceil(N / group) sources and return ns/subscriber.
/// The control run isolates *width* from the memory-hierarchy slope that every
/// phase picks up as the working set outgrows cache: a 1M-node graph is slower
/// per node than a 1k-node graph no matter how narrow it is.
fn buildOnly(n: usize, group: usize) !f64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try Context.init(a);
    try ctx.initDense(2 * n + 2);
    g.group = group;
    g.source_value = 1;
    const t = nowNs();
    for (0..n) |i| sink +%= pullSub(ctx, i);
    const ns = nowNs() - t;
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n));
}

var sink: i64 = 0;

// --- ladder ----------------------------------------------------------------

const Rung = struct {
    n: usize,
    build_ns_per_sub: f64,
    control_ns_per_sub: f64,
    notify_ns_per_sub: f64,
    destroy_ns_per_sub: f64,
    bytes_per_sub: f64,
};

fn runRung(n: usize) !Rung {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try Context.init(a);
    try ctx.initDense(2 * n + 2);

    g.group = n; // single source, full width
    g.source_value = 1;
    _ = readSource(ctx, 0);

    const rss_before = rssBytes();

    // --- build: N registrations into one source ---------------------------
    var t = nowNs();
    for (0..n) |i| sink +%= pullSub(ctx, i);
    const build_ns = nowNs() - t;

    const rss_after = rssBytes();
    const bytes_per_sub = if (rss_after > rss_before)
        @as(f64, @floatFromInt(rss_after - rss_before)) / @as(f64, @floatFromInt(n))
    else
        0;

    if (sourceSlot(ctx, 0).change_subscribers.count() != n) return error.EdgeCountMismatch;

    // --- notify: one publish cascading to all N ---------------------------
    g.source_value = 2;
    const src = sourceSlot(ctx, 0);
    const src_ptr = src.getPtr(i64) catch unreachable;
    src_ptr.* = 2;
    t = nowNs();
    src.emitChange();
    const notify_ns = nowNs() - t;

    // --- correctness: every survivor observes the final publish -----------
    for (0..n) |i| {
        const got = pullSub(ctx, i);
        const want = 2 +% @as(i64, @intCast(i));
        if (got != want) {
            std.debug.print("FAIL n={d} sub[{d}] = {d}, want {d}\n", .{ n, i, got, want });
            return error.StalePublish;
        }
    }
    // Re-pulling rebuilt every edge, so the source is back at full width.
    if (sourceSlot(ctx, 0).change_subscribers.count() != n) return error.EdgeCountMismatch;

    // --- destroy: N x parent.change_subscribers.remove ---------------------
    // Collect handles first so the timed loop is pure teardown.
    const pa = std.heap.page_allocator;
    const subs = try pa.alloc(*Slot, n);
    defer pa.free(subs);
    for (0..n) |i| subs[i] = ctx.cacheLookup(subKey(i)).?;

    t = nowNs();
    for (subs) |s| s.destroy(true);
    const destroy_ns = nowNs() - t;

    if (sourceSlot(ctx, 0).change_subscribers.count() != 0) return error.EdgesLeaked;

    const fn_ = @as(f64, @floatFromInt(n));
    // Teardown this rung's arena before the control run so the two builds see
    // comparable memory pressure.
    arena.deinit();
    arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const control_ns_per_sub = try buildOnly(n, control_group);

    return .{
        .n = n,
        .control_ns_per_sub = control_ns_per_sub,
        .build_ns_per_sub = @as(f64, @floatFromInt(build_ns)) / fn_,
        .notify_ns_per_sub = @as(f64, @floatFromInt(notify_ns)) / fn_,
        .destroy_ns_per_sub = @as(f64, @floatFromInt(destroy_ns)) / fn_,
        .bytes_per_sub = bytes_per_sub,
    };
}

pub fn main() !void {
    const max_n = envUsize("LAZILY_FANOUT_MAX", 1_000_000);
    const floor_mb = envUsize("LAZILY_FANOUT_FLOOR_MB", 4096);
    const floor_bytes = floor_mb * 1024 * 1024;

    const ladder = [_]usize{
        // The cluster around the promote threshold (64) is deliberate: a naive
        // promote/demote pair thrashes at exactly threshold+1 and is invisible
        // at every other width.
        32,        63,        64,         65,        96,
        128,       129,       160,        256,       1_024,
        4_096,     65_536,    262_144,    1_000_000,
        4_000_000, 10_000_000,
        100_000_000,
    };

    std.debug.print(
        \\lazily-zig fan-out width ladder (#lzspecedgeindex)
        \\=================================================
        \\promote threshold = {d}
        \\max width         = {d}   (LAZILY_FANOUT_MAX)
        \\memory floor      = {d} MB (LAZILY_FANOUT_FLOOR_MB)
        \\MemAvailable      = {d:.2} GB
        \\
        \\
    , .{
        @TypeOf(@as(Slot, undefined).change_subscribers).promote_threshold,
        max_n,
        floor_mb,
        @as(f64, @floatFromInt(memAvailableBytes())) / (1024.0 * 1024.0 * 1024.0),
    });

    std.debug.print("{s:>10} {s:>11} {s:>11} {s:>7} {s:>11} {s:>12} {s:>10}\n", .{
        "width", "build ns/s", "ctrl ns/s", "b/ctrl", "notify ns/s", "destroy ns/s", "bytes/sub",
    });

    var rungs: [ladder.len]Rung = undefined;
    var count: usize = 0;
    var last_bytes_per_sub: f64 = 0;

    for (ladder) |n| {
        if (n > max_n) {
            std.debug.print("-- stop: width {d} exceeds LAZILY_FANOUT_MAX\n", .{n});
            break;
        }
        // Climb / project / refuse: project this rung's footprint from the
        // *measured* bytes/sub of the previous rung, and refuse if the
        // projection would eat into the floor.
        if (last_bytes_per_sub > 0) {
            const projected = last_bytes_per_sub * @as(f64, @floatFromInt(n));
            const avail = @as(f64, @floatFromInt(memAvailableBytes()));
            if (projected + @as(f64, @floatFromInt(floor_bytes)) > avail) {
                std.debug.print(
                    "-- refuse: width {d} projects {d:.2} GB from measured {d:.1} B/sub; " ++
                        "MemAvailable {d:.2} GB leaves less than the {d} MB floor\n",
                    .{
                        n,
                        projected / (1024.0 * 1024.0 * 1024.0),
                        last_bytes_per_sub,
                        avail / (1024.0 * 1024.0 * 1024.0),
                        floor_mb,
                    },
                );
                break;
            }
        }

        const r = try runRung(n);
        rungs[count] = r;
        count += 1;
        if (r.bytes_per_sub > 0) last_bytes_per_sub = r.bytes_per_sub;

        std.debug.print("{d:>10} {d:>11.1} {d:>11.1} {d:>7.2} {d:>11.1} {d:>12.1} {d:>10.1}\n", .{
            r.n,
            r.build_ns_per_sub,
            r.control_ns_per_sub,
            r.build_ns_per_sub / r.control_ns_per_sub,
            r.notify_ns_per_sub,
            r.destroy_ns_per_sub,
            r.bytes_per_sub,
        });
    }

    std.mem.doNotOptimizeAway(sink);
    try assertShape(rungs[0..count]);
    std.debug.print("\nall assertions passed ({d} rungs)\n", .{count});
}

fn find(rungs: []const Rung, n: usize) ?Rung {
    for (rungs) |r| if (r.n == n) return r;
    return null;
}

fn assertShape(rungs: []const Rung) !void {
    std.debug.print("\n-- assertions --\n", .{});

    // 1. Width must not cost more than the same node count at a narrow
    //    fan-out.
    //
    //    NOTE ON THE FORM OF THIS ASSERTION. The obvious version — "build
    //    ns/sub grows < 2x from 1k to 1M" — does not hold on the fixed engine
    //    and is not a test of the edge index. Measured here, build ns/sub goes
    //    84.4 (1k) -> 222.1 (1M) -> 396.0 (10M), a 4.7x absolute rise. But the
    //    narrow-fan-out control rises too, and so does `notify`, which does no
    //    dedup work at all: every phase picks up a memory-hierarchy slope once
    //    the working set outgrows cache. At width 10M the spill list is 80 MB
    //    and the index table 32 MB, so each registration is ~2 TLB misses no
    //    matter what the algorithm is. The absolute check measures DRAM, not
    //    the index.
    //
    //    What distinguishes O(1) from O(n) registration is that the cost stops
    //    tracking width: 1M -> 10M is 10x the width for 1.8x the cost. The
    //    narrow control at the same node count holds allocation and cache
    //    behaviour fixed and varies only width, so the ratio below is the
    //    width-attributable cost alone. On the unfixed engine that ratio is
    //    ~150x at width 65536 and would be ~4 orders of magnitude at 10M; on
    //    the fixed engine it saturates below 4x.
    var worst_ratio: f64 = 0;
    var worst_n: usize = 0;
    for (rungs) |r| {
        if (r.n < 1_024) continue;
        const ratio = r.build_ns_per_sub / r.control_ns_per_sub;
        if (ratio > worst_ratio) {
            worst_ratio = ratio;
            worst_n = r.n;
        }
    }
    if (worst_n != 0) {
        std.debug.print("worst wide/narrow build ratio: {d:.2}x at width {d} (limit 8.00x)\n", .{ worst_ratio, worst_n });
        if (worst_ratio >= 8.0) return error.BuildCostSuperlinear;
    }

    const small = find(rungs, 1_024) orelse {
        std.debug.print("SKIP growth checks: ladder did not reach 1k\n", .{});
        return;
    };
    const top = rungs[rungs.len - 1];

    // 2. destroy ns/sub — the `EdgeSet.remove` scan, the second O(n^2) source —
    //    must not grow faster than the notify cascade, which walks the same
    //    number of nodes with no dedup structure involved at all. Same
    //    reasoning as above: notify is the memory-hierarchy control.
    if (top.n > small.n) {
        const destroy_growth = top.destroy_ns_per_sub / small.destroy_ns_per_sub;
        const notify_growth = top.notify_ns_per_sub / small.notify_ns_per_sub;
        std.debug.print(
            "destroy ns/sub {d} -> {d}: {d:.2}x (notify control {d:.2}x, limit 2x the control)\n",
            .{ small.n, top.n, destroy_growth, notify_growth },
        );
        if (destroy_growth >= 2.0 * @max(notify_growth, 1.0)) return error.DestroyCostSuperlinear;
    }

    // 3. bytes/sub flat within 20% across the measurable part of the ladder.
    //    Small rungs are dominated by fixed context/arena overhead and page
    //    granularity, so flatness is asserted from 4k up.
    var min_b: f64 = std.math.floatMax(f64);
    var max_b: f64 = 0;
    var measured: usize = 0;
    for (rungs) |r| {
        if (r.n < 4_096 or r.bytes_per_sub <= 0) continue;
        measured += 1;
        min_b = @min(min_b, r.bytes_per_sub);
        max_b = @max(max_b, r.bytes_per_sub);
    }
    if (measured >= 2) {
        const spread = (max_b - min_b) / min_b;
        std.debug.print("bytes/sub spread over >=4k rungs: {d:.1}..{d:.1} = {d:.1}% (limit 20%)\n", .{ min_b, max_b, spread * 100 });
        if (spread > 0.20) return error.BytesPerSubNotFlat;
    } else {
        std.debug.print("SKIP bytes/sub flatness: fewer than 2 rungs >= 4k\n", .{});
    }

    // 4. notify: the cascade is O(width) by construction and the edge-index
    //    change must not add to it. Asserted against the narrow-fan-out build
    //    control at the same N, i.e. the same memory-hierarchy denominator the
    //    build assertion uses.
    for (rungs) |r| {
        if (r.n < 1_024) continue;
        if (r.notify_ns_per_sub >= 2.0 * r.control_ns_per_sub) {
            std.debug.print("notify ns/sub {d:.1} at width {d} exceeds 2x control {d:.1}\n", .{ r.notify_ns_per_sub, r.n, r.control_ns_per_sub });
            return error.NotifyCostRegressed;
        }
    }
    std.debug.print("notify ns/sub within 2x the narrow-fan-out control at every rung >= 1k\n", .{});

    // 5. Threshold-boundary stability: widths 63/64/65 and 128/129 must not
    //    show a step. A shared promote/demote boundary shows up here as a ~4x
    //    build cost at exactly threshold+1 and nowhere else.
    const boundary = [_][2]usize{ .{ 63, 65 }, .{ 128, 129 } };
    for (boundary) |pair| {
        const lo = find(rungs, pair[0]) orelse continue;
        const hi = find(rungs, pair[1]) orelse continue;
        const ratio = hi.build_ns_per_sub / lo.build_ns_per_sub;
        std.debug.print("build ns/sub {d} -> {d}: {d:.2}x (limit 2.00x, thrash guard)\n", .{ pair[0], pair[1], ratio });
        if (ratio >= 2.0) return error.ThresholdThrash;
    }
}
