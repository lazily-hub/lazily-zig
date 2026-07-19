//! Observer-semantics conformance runner (`#lzdartobservercow`, `#lzspecconf`).
//!
//! Replays the canonical cross-language fixtures in
//! `../lazily-spec/conformance/reactive-graph/observer_*.json` against
//! `lazily/cell.Cell`'s observer list. The normative prose these pin lives in
//! `lazily-spec/docs/reactive-graph.md` § observer semantics; sibling runners
//! are `lazily-rs/tests/*_conformance.rs` (the `SPEC_DIR` + skip-if-absent
//! shape mirrored here) and `lazily-go/familysync_conformance_test.go`.
//!
//! This is a REAL fixture runner, not a transcription: it parses the JSON and
//! interprets the op vocabulary, so a fixture added or amended in lazily-spec
//! takes effect here without editing this file. Bundled copies drift — see
//! lazily-kt's `src/test/resources/conformance/`, which already has.
//!
//! Op vocabulary implemented (the union across the five `observer_*` fixtures):
//!
//!   cell        { id, value }                       — fresh Cell(i32)
//!   set_cell    { id, value }                       — store (== guard applies)
//!   subscribe   { id, cell, callback?,
//!                 on_notify?, on_notify_once? }     — register an observer
//!   subscribe   { id_prefix, cell, ... }            — nested form; auto-numbered
//!   unsubscribe { id, times? }                      — dispose a registration
//!   dispose     { id }                              — tear the cell down
//!
//!   expect { observed_order, observed_count, observed_counts,
//!            error, readable, note }
//!
//! `subscribe`/`unsubscribe` nested under `on_notify` run from inside the
//! callback, which is how the reentrancy clauses are exercised.
//!
//! Two fixture concepts need a word on how they map onto Zig:
//!
//!   * `callback` labels two registrations as sharing one callable. Zig
//!     callbacks are bare `*const fn` pointers, so the runner hands both
//!     registrations the SAME pointer out of a comptime-generated pool. That
//!     is load-bearing: give each registration its own pointer and a binding
//!     that dedups by callback address passes the duplicate-registration
//!     fixture vacuously.
//!   * Because a shared pointer cannot report *which* registration fired, the
//!     runner logs callback labels and resolves them back to fixture observer
//!     ids afterwards, consuming the registrations live at the start of the
//!     pass in registration order. That is exact: the only fixtures with a
//!     shared label never unsubscribe mid-notification.
//!
//! Directory-driven, so the eight disposal/teardown fixtures alongside these
//! can be enabled later by widening `fixture_prefix`.

const std = @import("std");
const linux = std.os.linux;

const Context = @import("context.zig").Context;
const cell_mod = @import("cell.zig");
const Cell = cell_mod.Cell;
const ChangeCallback = cell_mod.ChangeCallback;
const Subscription = cell_mod.Subscription;

/// Sibling-relative, exactly as `lazily-rs`'s conformance tests spell it
/// (`#lzspecconf`). `zig build test` runs the test binary with the repo root as
/// its cwd, the same assumption `cargo test` makes there.
const spec_dir = "../lazily-spec/conformance/reactive-graph";

/// Only the observer semantics fixtures are green today; the disposal fixtures
/// in the same directory are a separate migration.
const fixture_prefix = "observer_";

// --- fixed-capacity runner state ---------------------------------------------
//
// Deliberately array-backed rather than `std.ArrayList`: this file has to
// compile on 0.15.2, 0.16.0 and master, whose ArrayList APIs differ, and every
// fixture is small enough that the bounds below are slack by an order of
// magnitude.
const max_cells = 8;
const max_regs = 32;
const max_labels = 32;
const max_fires = 64;
const max_name = 96;

// --- callback pool ------------------------------------------------------------

var g_runner: ?*Runner = null;

fn PoolCb(comptime i: usize) type {
    return struct {
        fn f(c: *Cell(i32)) void {
            if (g_runner) |r| r.fire(i, c);
        }
    };
}

const callback_pool: [max_labels]ChangeCallback(i32) = blk: {
    @setEvalBranchQuota(10_000);
    var a: [max_labels]ChangeCallback(i32) = undefined;
    for (0..max_labels) |i| a[i] = PoolCb(i).f;
    break :blk a;
};

/// The cell's initial value, threaded through a global because `Cell.init`
/// takes a comptime `ValueFn`.
var pending_initial: i32 = 0;

fn initialValue(ctx: *Context) !i32 {
    _ = ctx;
    return pending_initial;
}

// --- raw-syscall file access ---------------------------------------------------
//
// zig master removed `std.fs.cwd()`; the repo already reaches for
// `std.os.linux` directly elsewhere (`transport.zig`, `benches/fanout_load.zig`)
// for the same reason.

fn pathExists(path: [*:0]const u8) bool {
    return @as(isize, @bitCast(linux.access(path, 0))) == 0;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(rc)) < 0) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    var buf = try allocator.alloc(u8, 1 << 16);
    errdefer allocator.free(buf);
    var total: usize = 0;
    while (true) {
        if (total == buf.len) buf = try allocator.realloc(buf, buf.len * 2);
        const r = linux.read(fd, buf[total..].ptr, buf.len - total);
        const ri: isize = @bitCast(r);
        if (ri < 0) return error.ReadFailed;
        if (ri == 0) break;
        total += @intCast(r);
    }
    // The caller frees exactly what was allocated, so shrink rather than slice.
    return try allocator.realloc(buf, total);
}

const FixtureNames = struct {
    buf: [64][max_name]u8 = undefined,
    len: [64]usize = undefined,
    count: usize = 0,

    fn at(self: *const FixtureNames, i: usize) []const u8 {
        return self.buf[i][0..self.len[i]];
    }
};

fn listFixtures(out: *FixtureNames) !void {
    const rc = linux.open(spec_dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (@as(isize, @bitCast(rc)) < 0) return error.OpenDirFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    var dbuf: [16384]u8 align(8) = undefined;
    while (true) {
        const n = linux.getdents64(fd, &dbuf, dbuf.len);
        const ni: isize = @bitCast(n);
        if (ni < 0) return error.GetdentsFailed;
        if (ni == 0) break;
        var off: usize = 0;
        while (off < @as(usize, @intCast(ni))) {
            const d: *const linux.dirent64 = @ptrCast(@alignCast(&dbuf[off]));
            const name_ptr: [*:0]const u8 = @ptrCast(&dbuf[off + @offsetOf(linux.dirent64, "name")]);
            const name = std.mem.span(name_ptr);
            off += d.reclen;
            if (!std.mem.startsWith(u8, name, fixture_prefix)) continue;
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            if (name.len > max_name) return error.NameTooLong;
            if (out.count == out.buf.len) return error.TooManyFixtures;
            @memcpy(out.buf[out.count][0..name.len], name);
            out.len[out.count] = name.len;
            out.count += 1;
        }
    }
    // Deterministic replay order.
    var i: usize = 1;
    while (i < out.count) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.lessThan(u8, out.at(j), out.at(j - 1))) : (j -= 1) {
            std.mem.swap([max_name]u8, &out.buf[j], &out.buf[j - 1]);
            std.mem.swap(usize, &out.len[j], &out.len[j - 1]);
        }
    }
}

// --- the interpreter -----------------------------------------------------------

const CellEnt = struct {
    name_buf: [max_name]u8 = undefined,
    name_len: usize = 0,
    ctx: *Context = undefined,
    cell: *Cell(i32) = undefined,
    alive: bool = false,

    fn name(self: *const CellEnt) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

const RegEnt = struct {
    id_buf: [max_name]u8 = undefined,
    id_len: usize = 0,
    label: usize = 0,
    cell: usize = 0,
    token: Subscription = undefined,
    live: bool = false,
    on_notify: ?std.json.Value = null,
    once: bool = false,
    fired: bool = false,

    fn id(self: *const RegEnt) []const u8 {
        return self.id_buf[0..self.id_len];
    }
};

const Runner = struct {
    allocator: std.mem.Allocator,
    fixture: []const u8,

    cells: [max_cells]CellEnt = @splat(.{}),
    cell_count: usize = 0,

    regs: [max_regs]RegEnt = @splat(.{}),
    reg_count: usize = 0,

    label_buf: [max_labels][max_name]u8 = undefined,
    label_len: [max_labels]usize = undefined,
    label_count: usize = 0,

    fire_log: [max_fires]usize = undefined,
    fire_count: usize = 0,

    /// Set when an op the fixture expects to be silent (`"error": null`)
    /// reports a failure.
    err: bool = false,

    fn deinit(self: *Runner) void {
        var i: usize = 0;
        while (i < self.cell_count) : (i += 1) {
            if (self.cells[i].alive) {
                self.cells[i].ctx.deinit();
                self.cells[i].alive = false;
            }
        }
    }

    fn labelIndex(self: *Runner, name: []const u8) !usize {
        var i: usize = 0;
        while (i < self.label_count) : (i += 1) {
            if (std.mem.eql(u8, self.label_buf[i][0..self.label_len[i]], name)) return i;
        }
        if (self.label_count == max_labels) return error.TooManyLabels;
        if (name.len > max_name) return error.NameTooLong;
        @memcpy(self.label_buf[self.label_count][0..name.len], name);
        self.label_len[self.label_count] = name.len;
        self.label_count += 1;
        return self.label_count - 1;
    }

    fn cellIndex(self: *Runner, name: []const u8) !usize {
        var i: usize = 0;
        while (i < self.cell_count) : (i += 1) {
            if (std.mem.eql(u8, self.cells[i].name(), name)) return i;
        }
        return error.UnknownCell;
    }

    fn regIndex(self: *Runner, id: []const u8) ?usize {
        var i: usize = 0;
        while (i < self.reg_count) : (i += 1) {
            if (std.mem.eql(u8, self.regs[i].id(), id)) return i;
        }
        return null;
    }

    // --- ops ---------------------------------------------------------------

    fn opCell(self: *Runner, name: []const u8, value: i32) !void {
        if (self.cell_count == max_cells) return error.TooManyCells;
        if (name.len > max_name) return error.NameTooLong;
        const e = &self.cells[self.cell_count];
        @memcpy(e.name_buf[0..name.len], name);
        e.name_len = name.len;
        // One Context per cell: `Cell.init` caches by `valueFnCacheKey`, which
        // is per-Context, so distinct cells sharing `initialValue` need
        // distinct Contexts.
        pending_initial = value;
        e.ctx = try Context.init(self.allocator);
        e.cell = try Cell(i32).init(e.ctx, initialValue, null);
        e.alive = true;
        self.cell_count += 1;
    }

    fn opSubscribe(
        self: *Runner,
        id: []const u8,
        cell_idx: usize,
        label_name: []const u8,
        on_notify: ?std.json.Value,
        once: bool,
    ) !void {
        if (self.reg_count == max_regs) return error.TooManyRegistrations;
        if (id.len > max_name) return error.NameTooLong;
        const label = try self.labelIndex(label_name);
        const r = &self.regs[self.reg_count];
        r.* = .{};
        @memcpy(r.id_buf[0..id.len], id);
        r.id_len = id.len;
        r.label = label;
        r.cell = cell_idx;
        r.on_notify = on_notify;
        r.once = once;
        r.fired = false;
        r.live = true;
        r.token = try self.cells[cell_idx].cell.subscribe(callback_pool[label]);
        self.reg_count += 1;
    }

    fn opUnsubscribe(self: *Runner, id: []const u8) void {
        const idx = self.regIndex(id) orelse {
            // A disposer for an id the fixture never registered would be a
            // runner bug, not an implementation one.
            self.err = true;
            return;
        };
        const r = &self.regs[idx];
        if (!self.cells[r.cell].alive) {
            // "a disposer called after its cell is gone is a no-op, not an
            // error". In a manually-managed binding the disposer cannot reach
            // into freed memory to find that out, so the caller — here, the
            // runner — holds the token alongside the cell and drops it. The
            // observable contract (no error, nothing fires) is what is
            // asserted; the representation is explicitly not.
            return;
        }
        if (!r.live) return; // latched: every call after the first is a no-op
        _ = self.cells[r.cell].cell.unsubscribe(r.token);
        r.live = false;
    }

    fn opDispose(self: *Runner, name: []const u8) !void {
        const idx = try self.cellIndex(name);
        const e = &self.cells[idx];
        if (!e.alive) return;
        var i: usize = 0;
        while (i < self.reg_count) : (i += 1) {
            if (self.regs[i].cell == idx) self.regs[i].live = false;
        }
        e.ctx.deinit();
        e.alive = false;
    }

    // --- notify-time reentrancy -------------------------------------------

    fn fire(self: *Runner, label: usize, c: *Cell(i32)) void {
        _ = c; // the firing cell is reachable from the fixture ops by name
        if (self.fire_count < max_fires) {
            self.fire_log[self.fire_count] = label;
            self.fire_count += 1;
        } else {
            self.err = true;
        }
        var i: usize = 0;
        while (i < self.reg_count) : (i += 1) {
            const r = &self.regs[i];
            if (!r.live or r.label != label) continue;
            const ops = r.on_notify orelse continue;
            if (r.once and r.fired) return;
            r.fired = true;
            self.runNotifyOps(ops) catch {
                self.err = true;
            };
            return;
        }
    }

    fn runNotifyOps(self: *Runner, ops: std.json.Value) !void {
        for (ops.array.items) |op| try self.applyOp(op);
    }

    /// Next free `<prefix>_<n>` for the nested `id_prefix` form.
    fn generatedId(self: *Runner, prefix: []const u8, out: *[max_name]u8) ![]const u8 {
        var n: usize = 0;
        while (n < 1000) : (n += 1) {
            const s = try std.fmt.bufPrint(out, "{s}_{d}", .{ prefix, n });
            if (self.regIndex(s) == null) return s;
        }
        return error.IdExhausted;
    }

    // --- op dispatch --------------------------------------------------------

    fn applyOp(self: *Runner, op: std.json.Value) !void {
        const ty = op.object.get("type").?.string;
        if (std.mem.eql(u8, ty, "cell")) {
            try self.opCell(op.object.get("id").?.string, @intCast(op.object.get("value").?.integer));
        } else if (std.mem.eql(u8, ty, "set_cell")) {
            const idx = try self.cellIndex(op.object.get("id").?.string);
            const v: i32 = @intCast(op.object.get("value").?.integer);
            self.cells[idx].cell.set(v);
        } else if (std.mem.eql(u8, ty, "subscribe")) {
            const cell_idx = try self.cellIndex(op.object.get("cell").?.string);
            var gen: [max_name]u8 = undefined;
            const id = if (op.object.get("id")) |v|
                v.string
            else
                try self.generatedId(op.object.get("id_prefix").?.string, &gen);
            const label_name = if (op.object.get("callback")) |v| v.string else id;
            const once = if (op.object.get("on_notify_once")) |v| v.bool else false;
            try self.opSubscribe(id, cell_idx, label_name, op.object.get("on_notify"), once);
        } else if (std.mem.eql(u8, ty, "unsubscribe")) {
            const id = op.object.get("id").?.string;
            const times: usize = if (op.object.get("times")) |v| @intCast(v.integer) else 1;
            var k: usize = 0;
            while (k < times) : (k += 1) self.opUnsubscribe(id);
        } else if (std.mem.eql(u8, ty, "dispose")) {
            try self.opDispose(op.object.get("id").?.string);
        } else {
            std.debug.print("{s}: unimplemented op '{s}'\n", .{ self.fixture, ty });
            return error.UnimplementedOp;
        }
    }

    // --- expectations -------------------------------------------------------

    /// Resolve the logged callback labels back to fixture observer ids, using
    /// the registrations that were live on `cell_idx` when the pass began.
    fn observedIds(
        self: *Runner,
        pre_live: []const usize,
        out: *[max_fires][]const u8,
    ) ![]const []const u8 {
        var consumed: [max_regs]bool = @splat(false);
        var n: usize = 0;
        while (n < self.fire_count) : (n += 1) {
            const label = self.fire_log[n];
            var hit: ?usize = null;
            for (pre_live) |ri| {
                if (consumed[ri]) continue;
                if (self.regs[ri].label != label) continue;
                hit = ri;
                break;
            }
            const ri = hit orelse {
                std.debug.print(
                    "{s}: callback '{s}' fired more times than it had live registrations\n",
                    .{ self.fixture, self.label_buf[label][0..self.label_len[label]] },
                );
                return error.UnmatchedInvocation;
            };
            consumed[ri] = true;
            out[n] = self.regs[ri].id();
        }
        return out[0..self.fire_count];
    }

    fn checkExpect(
        self: *Runner,
        expect: std.json.Value,
        pre_live: []const usize,
        step_idx: usize,
    ) !void {
        var ids_buf: [max_fires][]const u8 = undefined;
        const observed = try self.observedIds(pre_live, &ids_buf);

        if (expect.object.get("error")) |e| {
            if (e == .null and self.err) {
                std.debug.print("{s} step {d}: expected no error, runner recorded one\n", .{ self.fixture, step_idx });
                return error.UnexpectedError;
            }
        }

        if (expect.object.get("observed_order")) |want| {
            const w = want.array.items;
            var ok = w.len == observed.len;
            if (ok) for (w, observed) |a, b| {
                if (!std.mem.eql(u8, a.string, b)) {
                    ok = false;
                    break;
                }
            };
            if (!ok) {
                std.debug.print("{s} step {d}: observed_order mismatch\n  want: ", .{ self.fixture, step_idx });
                for (w) |a| std.debug.print("{s} ", .{a.string});
                std.debug.print("\n  got:  ", .{});
                for (observed) |b| std.debug.print("{s} ", .{b});
                std.debug.print("\n", .{});
                return error.ObservedOrderMismatch;
            }
        }

        if (expect.object.get("observed_count")) |want| {
            const w: usize = @intCast(want.integer);
            if (w != observed.len) {
                std.debug.print("{s} step {d}: observed_count want {d} got {d}\n", .{ self.fixture, step_idx, w, observed.len });
                return error.ObservedCountMismatch;
            }
        }

        if (expect.object.get("observed_counts")) |want| {
            var it = want.object.iterator();
            while (it.next()) |kv| {
                const w: usize = @intCast(kv.value_ptr.integer);
                var got: usize = 0;
                for (observed) |b| {
                    if (std.mem.eql(u8, b, kv.key_ptr.*)) got += 1;
                }
                if (w != got) {
                    std.debug.print("{s} step {d}: observed_counts[{s}] want {d} got {d}\n", .{ self.fixture, step_idx, kv.key_ptr.*, w, got });
                    return error.ObservedCountsMismatch;
                }
            }
        }

        if (expect.object.get("readable")) |want| {
            var it = want.object.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.* != .bool) continue;
                const idx = try self.cellIndex(kv.key_ptr.*);
                if (self.cells[idx].alive != kv.value_ptr.bool) {
                    std.debug.print("{s} step {d}: readable[{s}] want {} got {}\n", .{ self.fixture, step_idx, kv.key_ptr.*, kv.value_ptr.bool, self.cells[idx].alive });
                    return error.ReadableMismatch;
                }
            }
        }
    }

    fn runFixture(self: *Runner, root: std.json.Value) !void {
        for (root.object.get("steps").?.array.items, 0..) |step, step_idx| {
            const op = step.object.get("op").?;

            // Snapshot the live registrations of the cell this op targets,
            // in registration order, before the op can change them.
            var pre_buf: [max_regs]usize = undefined;
            var pre_n: usize = 0;
            if (op.object.get("id")) |idv| {
                if (std.mem.eql(u8, op.object.get("type").?.string, "set_cell")) {
                    const ci = try self.cellIndex(idv.string);
                    var i: usize = 0;
                    while (i < self.reg_count) : (i += 1) {
                        if (self.regs[i].live and self.regs[i].cell == ci) {
                            pre_buf[pre_n] = i;
                            pre_n += 1;
                        }
                    }
                }
            }

            self.fire_count = 0;
            self.err = false;
            try self.applyOp(op);

            if (step.object.get("expect")) |expect| {
                try self.checkExpect(expect, pre_buf[0..pre_n], step_idx);
            }
        }
    }
};

test "lazily/cell.Cell: observer semantics conformance (lazily-spec reactive-graph)" {
    if (!pathExists(spec_dir)) {
        std.debug.print(
            "skipping: {s} absent - run with the lazily-spec sibling checked out\n",
            .{spec_dir},
        );
        return error.SkipZigTest;
    }

    var names: FixtureNames = .{};
    try listFixtures(&names);
    if (names.count == 0) {
        std.debug.print("skipping: no {s}*.json under {s}\n", .{ fixture_prefix, spec_dir });
        return error.SkipZigTest;
    }

    const allocator = std.testing.allocator;
    var failures: usize = 0;
    var i: usize = 0;
    while (i < names.count) : (i += 1) {
        const name = names.at(i);
        // `std.fmt.bufPrintZ` is gone on master; build the sentinel path by hand.
        var path_buf: [max_name + spec_dir.len + 8]u8 = undefined;
        @memcpy(path_buf[0..spec_dir.len], spec_dir);
        path_buf[spec_dir.len] = '/';
        @memcpy(path_buf[spec_dir.len + 1 ..][0..name.len], name);
        path_buf[spec_dir.len + 1 + name.len] = 0;
        const path: [*:0]const u8 = @ptrCast(&path_buf);

        const raw = try readFileAlloc(allocator, path);
        defer allocator.free(raw);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
        defer parsed.deinit();

        var runner = Runner{ .allocator = allocator, .fixture = name };
        g_runner = &runner;
        defer g_runner = null;
        defer runner.deinit();

        // Report every non-conforming fixture in one run rather than stopping
        // at the first: which fixtures are red is the migration's status board.
        runner.runFixture(parsed.value) catch |e| {
            std.debug.print("FAILED fixture {s}: {s}\n", .{ name, @errorName(e) });
            failures += 1;
        };
    }

    if (failures > 0) {
        std.debug.print("{d} of {d} observer fixtures failed\n", .{ failures, names.count });
        return error.ObserverConformanceFailed;
    }
}
