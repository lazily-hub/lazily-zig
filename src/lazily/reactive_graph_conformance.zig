//! Cross-language conformance for the reactive-graph plane
//! (`#lzspecconf`) — see `../lazily-spec/conformance/reactive-graph/*.json`.
//!
//! Until now `lazily-rs` was the only binding replaying this corpus, and that
//! gap is exactly how a transitive-cascade defect shipped undetected in
//! lazily-dart and lazily-go (`#lzdartobservercow`): both were correct
//! synchronously and broken asynchronously, and nothing replayed the fixture
//! that would have caught it against the async context.
//!
//! ## Replay against every context the binding ships
//!
//! `lazily-zig` ships three: `Context` (synchronous, pull-based),
//! `ThreadSafeContext` (runtime-keyed, lock-guarded, lazy-on-read) and
//! `AsyncContext` (queue-drained, revision-tracked). The corpus is
//! parameterised over all three rather than run against the default one,
//! because "correct in the default context" is precisely the property the
//! dart/go defect had. The zig async path tracks staleness by revision counter
//! and in-flight state — the exact hazard
//! `transitive_invalidation_reaches_depth` names.
//!
//! ## Positive assertion (`#lzspecconf`)
//!
//! An absence guard is not enough: a runner that skips everything must fail.
//! For each model this asserts (a) the fixture set on disk matches `FIXTURES`
//! exactly, (b) every fixture was either replayed or skipped with its
//! unsupported op named, (c) the skip ledger matches observation exactly, and
//! (d) a non-zero count of fixtures, ops and assertions actually executed.
//!
//! ## Op coverage
//!
//! Only `cell`, `computed`, `read` and `set_cell` are implementable against the
//! API zig exposes today. The remaining fixtures drive `begin_scope`/
//! `end_scope`/`disarm` (`TeardownScope`), `dispose`/`dispose_fanout`/
//! `dispose_stale_handle` (handle-level disposal) and assert `dependents_of`/
//! `dependencies_of` degree introspection — none of which `lazily-zig` has.
//! Those fixtures are skipped LOUDLY, naming the op that blocks them, and the
//! skip ledger below is asserted so implementing one of those surfaces fails
//! this test until its fixture is moved out of the ledger.

const std = @import("std");
const builtin = @import("builtin");
const json = std.json;

const Context = @import("context.zig").Context;
const CellMod = @import("cell.zig");
const initCellFn = CellMod.initCellFn;
const initSlotFn = @import("slot.zig").initSlotFn;
const AsyncContext = @import("async_context.zig").AsyncContext;
const ThreadSafeContext = @import("thread_safe_context.zig").ThreadSafeContext;

const SPEC_DIR = "../lazily-spec/conformance/reactive-graph";

/// The value type every model carries. The corpus is integer-valued.
const V = i64;

/// Upper bound on distinct node ids in a single fixture. The synchronous
/// `Context` keys its cache by *function pointer*, so each node index needs its
/// own comptime-instantiated pair of functions; this bounds that expansion.
const MAX_NODES = 8;

/// The canonical fixture set, asserted against the directory listing so a
/// fixture added or renamed upstream fails loudly instead of going unrun.
const FIXTURES = [_][]const u8{
    "churn_returns_to_baseline.json",
    "cross_scope_teardown_hazard.json",
    "disarm_disposes_nothing.json",
    "dispose_detaches_edges_both_directions.json",
    "read_after_dispose_is_an_error.json",
    "recycled_id_inherits_nothing.json",
    "scope_teardown_equals_fold_of_disposals.json",
    "scoping_bounds_teardown_not_visibility.json",
    "transitive_invalidation_reaches_depth.json",
};

/// Ops this runner can drive against every model.
const SUPPORTED_OPS = [_][]const u8{ "cell", "computed", "read", "set_cell" };

/// Fixtures that cannot run against `lazily-zig` today, with the first
/// unsupported op each one needs. Asserted to match observation exactly: a
/// fixture that starts passing, or a newly blocked one, fails the build.
///
/// Every entry is a **capability gap in the binding**, never a relaxed
/// assertion. `begin_scope`/`end_scope`/`disarm` need `TeardownScope`;
/// `dispose`/`dispose_fanout`/`dispose_stale_handle` need handle-level
/// disposal; `fanout`/`churn` need bulk node construction.
const EXPECTED_SKIPS = [_]struct { fixture: []const u8, op: []const u8 }{
    .{ .fixture = "churn_returns_to_baseline.json", .op = "fanout" },
    .{ .fixture = "cross_scope_teardown_hazard.json", .op = "begin_scope" },
    .{ .fixture = "disarm_disposes_nothing.json", .op = "begin_scope" },
    .{ .fixture = "dispose_detaches_edges_both_directions.json", .op = "effect" },
    .{ .fixture = "read_after_dispose_is_an_error.json", .op = "dispose" },
    .{ .fixture = "recycled_id_inherits_nothing.json", .op = "fanout" },
    .{ .fixture = "scope_teardown_equals_fold_of_disposals.json", .op = "begin_scope" },
    .{ .fixture = "scoping_bounds_teardown_not_visibility.json", .op = "begin_scope" },
};

// ---------------------------------------------------------------------------
// Fixture loading (mirrors the `readFixtureFile` idiom already used by
// rateshape/membership/resilience in this repo).
// ---------------------------------------------------------------------------

fn readFixtureFile(path: []const u8) ![]u8 {
    if (comptime builtin.zig_version.minor >= 16) {
        return std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            path,
            std.testing.allocator,
            .limited(1024 * 1024),
        );
    }
    return std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024 * 1024);
}

fn specFixturesPresent() bool {
    const raw = readFixtureFile(
        SPEC_DIR ++ "/transitive_invalidation_reaches_depth.json",
    ) catch return false;
    std.testing.allocator.free(raw);
    return true;
}

fn loadFixture(name: []const u8) !json.Parsed(json.Value) {
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ SPEC_DIR, name });
    defer std.testing.allocator.free(path);
    const raw = try readFixtureFile(path);
    defer std.testing.allocator.free(raw);
    return json.parseFromSlice(json.Value, std.testing.allocator, raw, .{ .allocate = .alloc_always });
}

fn field(value: json.Value, name: []const u8) ?json.Value {
    return switch (value) {
        .object => |o| o.get(name),
        else => null,
    };
}

fn asI64(value: json.Value) !V {
    return switch (value) {
        .integer => |n| @intCast(n),
        .number_string => |s| try std.fmt.parseInt(V, s, 10),
        else => error.ExpectedInteger,
    };
}

fn asString(value: json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}

fn asArray(value: json.Value) ![]const json.Value {
    return switch (value) {
        .array => |a| a.items,
        else => error.ExpectedArray,
    };
}

/// Every `op` in the fixture, across both `steps` and `scenarios` shapes.
fn forEachOpType(fx: json.Value, ctxbuf: anytype, comptime visit: fn (@TypeOf(ctxbuf), []const u8) void) !void {
    if (field(fx, "scenarios")) |scenarios| {
        for (try asArray(scenarios)) |sc| {
            const sc_steps = field(sc, "steps") orelse return error.MissingSteps;
            for (try asArray(sc_steps)) |st| {
                const op = field(st, "op") orelse continue;
                visit(ctxbuf, try asString(field(op, "type") orelse return error.MissingOpType));
            }
        }
        return;
    }
    const st_arr = field(fx, "steps") orelse return error.MissingSteps;
    for (try asArray(st_arr)) |st| {
        const op = field(st, "op") orelse continue;
        visit(ctxbuf, try asString(field(op, "type") orelse return error.MissingOpType));
    }
}

fn opSupported(name: []const u8) bool {
    for (SUPPORTED_OPS) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

/// The first unsupported op the fixture needs, or null when it is replayable.
fn firstUnsupportedOp(fx: json.Value) !?[]const u8 {
    const Found = struct {
        var hit: ?[]const u8 = null;
    };
    Found.hit = null;
    const Visitor = struct {
        fn visit(_: *u8, name: []const u8) void {
            if (Found.hit != null) return;
            if (!opSupported(name)) Found.hit = name;
        }
    };
    var dummy: u8 = 0;
    try forEachOpType(fx, &dummy, Visitor.visit);
    return Found.hit;
}

// ---------------------------------------------------------------------------
// Node id table — fixture string ids to dense indices.
// ---------------------------------------------------------------------------

const NodeTable = struct {
    names: [MAX_NODES][]const u8 = undefined,
    len: usize = 0,

    fn indexOf(self: *const NodeTable, name: []const u8) !usize {
        for (self.names[0..self.len], 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return i;
        }
        return error.UnknownNodeId;
    }

    fn intern(self: *NodeTable, name: []const u8) !usize {
        if (self.indexOf(name)) |i| return i else |_| {}
        if (self.len == MAX_NODES) return error.TooManyNodes;
        self.names[self.len] = name;
        self.len += 1;
        return self.len - 1;
    }
};

// ---------------------------------------------------------------------------
// Model 1 — `Context`, the synchronous pull-based graph.
//
// `Context` keys its slot cache by the *address of the value function*, so a
// dynamically-shaped fixture graph needs one comptime-instantiated function per
// node index. Each generated function reads its own slot of a module-level
// definition table, which the model rewrites per fixture.
// ---------------------------------------------------------------------------

const SyncKind = enum { unset, cell, computed };

const SyncDef = struct {
    kind: SyncKind = .unset,
    dep: usize = 0,
    offset: V = 0,
    initial: V = 0,
};

var sync_defs: [MAX_NODES]SyncDef = @splat(.{});

fn syncReadIndex(ctx: *Context, idx: usize) anyerror!V {
    return switch (sync_defs[idx].kind) {
        .cell => (try sync_cell_fns[idx](ctx)).get(),
        .computed => (try sync_slot_fns[idx](ctx)).*,
        .unset => error.UnsetNode,
    };
}

fn SyncNodeFns(comptime i: usize) type {
    return struct {
        fn cellInit(_: *Context) anyerror!V {
            return sync_defs[i].initial;
        }
        fn compute(ctx: *Context) anyerror!V {
            const d = sync_defs[i];
            return (try syncReadIndex(ctx, d.dep)) + d.offset;
        }
    };
}

const SyncCellFn = @TypeOf(initCellFn(V, SyncNodeFns(0).cellInit, null));
const SyncSlotFn = @TypeOf(initSlotFn(V, SyncNodeFns(0).compute, null));

const sync_cell_fns: [MAX_NODES]SyncCellFn = blk: {
    var a: [MAX_NODES]SyncCellFn = undefined;
    for (0..MAX_NODES) |i| a[i] = initCellFn(V, SyncNodeFns(i).cellInit, null);
    break :blk a;
};

const sync_slot_fns: [MAX_NODES]SyncSlotFn = blk: {
    var a: [MAX_NODES]SyncSlotFn = undefined;
    for (0..MAX_NODES) |i| a[i] = initSlotFn(V, SyncNodeFns(i).compute, null);
    break :blk a;
};

const SyncModel = struct {
    pub const NAME = "Context";

    ctx: *Context,

    fn create(allocator: std.mem.Allocator) !SyncModel {
        sync_defs = @splat(.{});
        return .{ .ctx = try Context.init(allocator) };
    }

    fn destroy(self: *SyncModel) void {
        self.ctx.deinit();
    }

    fn addCell(self: *SyncModel, idx: usize, value: V) !void {
        sync_defs[idx] = .{ .kind = .cell, .initial = value };
        _ = try sync_cell_fns[idx](self.ctx);
    }

    fn addComputed(self: *SyncModel, idx: usize, dep: usize, offset: V) !void {
        sync_defs[idx] = .{ .kind = .computed, .dep = dep, .offset = offset };
        _ = try sync_slot_fns[idx](self.ctx);
    }

    fn read(self: *SyncModel, idx: usize) !V {
        return syncReadIndex(self.ctx, idx);
    }

    fn setCell(self: *SyncModel, idx: usize, value: V) !void {
        sync_defs[idx].initial = value;
        (try sync_cell_fns[idx](self.ctx)).set(value);
    }
};

// ---------------------------------------------------------------------------
// Model 2 — `ThreadSafeContext`. Runtime-keyed and closure-capable, so no
// comptime function expansion is needed; the per-node descriptor is passed as
// the compute's userdata pointer.
// ---------------------------------------------------------------------------

const TsDesc = struct {
    dep_id: u64 = 0,
    offset: V = 0,
};

const TsModel = struct {
    pub const NAME = "ThreadSafeContext";

    ctx: ThreadSafeContext,
    ids: [MAX_NODES]u64 = @splat(0),
    descs: [MAX_NODES]TsDesc = @splat(.{}),

    fn compute(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) V {
        const d: *TsDesc = @ptrCast(@alignCast(ptr));
        return cc.readNode(V, .{ .id = d.dep_id }) + d.offset;
    }

    fn create(allocator: std.mem.Allocator) !TsModel {
        return .{ .ctx = ThreadSafeContext.init(allocator) };
    }

    fn destroy(self: *TsModel) void {
        self.ctx.deinit();
    }

    fn addCell(self: *TsModel, idx: usize, value: V) !void {
        self.ids[idx] = (try self.ctx.cell(V, value)).id;
    }

    fn addComputed(self: *TsModel, idx: usize, dep: usize, offset: V) !void {
        self.descs[idx] = .{ .dep_id = self.ids[dep], .offset = offset };
        const handle = try self.ctx.computedClosure(V, @ptrCast(&self.descs[idx]), compute);
        self.ids[idx] = handle.id;
    }

    fn read(self: *TsModel, idx: usize) !V {
        return self.ctx.get(V, .{ .id = self.ids[idx] });
    }

    fn setCell(self: *TsModel, idx: usize, value: V) !void {
        self.ctx.setCell(V, .{ .id = self.ids[idx] }, value);
    }
};

// ---------------------------------------------------------------------------
// Model 3 — `AsyncContext`. The context the dart/go defect hid in: staleness is
// a revision counter and the cascade rides the settle queue rather than a
// recursive invalidate, so a chain that refreshes synchronously can silently
// stop refreshing here.
// ---------------------------------------------------------------------------

const ACtx = AsyncContext(V);

const AsyncDesc = struct {
    dep_id: u64 = 0,
    offset: V = 0,
};

const AsyncModel = struct {
    pub const NAME = "AsyncContext";

    ctx: ACtx,
    ids: [MAX_NODES]u64 = @splat(0),
    is_cell: [MAX_NODES]bool = @splat(false),
    descs: [MAX_NODES]AsyncDesc = @splat(.{}),

    fn compute(ptr: *anyopaque, cc: *ACtx.ComputeContext) anyerror!V {
        const d: *AsyncDesc = @ptrCast(@alignCast(ptr));
        // Ids are uniform across cells and slots, so one edge registration
        // covers both cases.
        cc.readCell(d.dep_id);
        const base = cc.async_ctx.getCell(d.dep_id) orelse
            cc.async_ctx.get(d.dep_id) orelse
            return error.AsyncDependencyUnresolved;
        return base + d.offset;
    }

    fn create(allocator: std.mem.Allocator) !AsyncModel {
        return .{ .ctx = ACtx.init(allocator) };
    }

    fn destroy(self: *AsyncModel) void {
        self.ctx.deinit();
    }

    fn addCell(self: *AsyncModel, idx: usize, value: V) !void {
        self.ids[idx] = try self.ctx.cell(value);
        self.is_cell[idx] = true;
    }

    fn addComputed(self: *AsyncModel, idx: usize, dep: usize, offset: V) !void {
        self.descs[idx] = .{ .dep_id = self.ids[dep], .offset = offset };
        self.ids[idx] = try self.ctx.computedAsyncClosure(@ptrCast(&self.descs[idx]), compute);
        self.is_cell[idx] = false;
        // Drain so the dependency edge this slot registers exists before the
        // next level is declared against it.
        _ = try self.ctx.settle();
    }

    fn read(self: *AsyncModel, idx: usize) !V {
        if (self.is_cell[idx]) return self.ctx.getCell(self.ids[idx]) orelse error.MissingCell;
        _ = try self.ctx.settle();
        return self.ctx.awaitResolved(self.ids[idx]);
    }

    fn setCell(self: *AsyncModel, idx: usize, value: V) !void {
        try self.ctx.setCell(self.ids[idx], value);
        _ = try self.ctx.settle();
    }
};

// ---------------------------------------------------------------------------
// Replay
// ---------------------------------------------------------------------------

const Report = struct {
    ops: usize = 0,
    checks: usize = 0,
};

fn replaySteps(comptime Model: type, model: *Model, table: *NodeTable, step_list: []const json.Value) !Report {
    var report = Report{};

    for (step_list, 0..) |step, si| {
        const op = field(step, "op") orelse return error.MissingOp;
        const op_type = try asString(field(op, "type") orelse return error.MissingOpType);
        const id = try asString(field(op, "id") orelse return error.MissingOpId);

        if (std.mem.eql(u8, op_type, "cell")) {
            const idx = try table.intern(id);
            try model.addCell(idx, try asI64(field(op, "value") orelse return error.MissingValue));
        } else if (std.mem.eql(u8, op_type, "computed")) {
            const idx = try table.intern(id);
            const reads = try asArray(field(op, "reads") orelse return error.MissingReads);
            // Every `computed` in the replayable corpus is a single-parent
            // fold. A multi-parent one would need a different node shape, so
            // fail loudly rather than silently reading only the first parent.
            if (reads.len != 1) return error.MultiParentComputedUnsupported;
            const dep = try table.indexOf(try asString(reads[0]));
            try model.addComputed(idx, dep, try asI64(field(op, "offset") orelse return error.MissingOffset));
        } else if (std.mem.eql(u8, op_type, "read")) {
            _ = try model.read(try table.indexOf(id));
        } else if (std.mem.eql(u8, op_type, "set_cell")) {
            try model.setCell(
                try table.indexOf(id),
                try asI64(field(op, "value") orelse return error.MissingValue),
            );
        } else {
            // Unreachable: `firstUnsupportedOp` gates the whole fixture.
            return error.UnsupportedOp;
        }
        report.ops += 1;

        const expect = field(step, "expect") orelse continue;
        const expect_obj = switch (expect) {
            .object => |o| o,
            else => return error.ExpectedObject,
        };

        var it = expect_obj.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.eql(u8, key, "note")) continue;

            if (std.mem.eql(u8, key, "value")) {
                // `value` attaches to a `read` op: the value that read returned.
                const want = try asI64(entry.value_ptr.*);
                const got = try model.read(try table.indexOf(id));
                if (want != got) {
                    std.debug.print(
                        "  DIVERGENCE {s} step {d} `value` for `{s}`: want {d}, got {d}\n",
                        .{ Model.NAME, si, id, want, got },
                    );
                    return error.ConformanceDivergence;
                }
                report.checks += 1;
            } else if (std.mem.eql(u8, key, "read")) {
                // `read` is a map of node id to the value a read must observe.
                const reads_obj = switch (entry.value_ptr.*) {
                    .object => |o| o,
                    else => return error.ExpectedObject,
                };
                var rit = reads_obj.iterator();
                while (rit.next()) |r| {
                    const want = try asI64(r.value_ptr.*);
                    const got = try model.read(try table.indexOf(r.key_ptr.*));
                    if (want != got) {
                        std.debug.print(
                            "  DIVERGENCE {s} step {d} `read.{s}`: want {d}, got {d}\n",
                            .{ Model.NAME, si, r.key_ptr.*, want, got },
                        );
                        return error.ConformanceDivergence;
                    }
                    report.checks += 1;
                }
            } else {
                // An unrecognised assertion key must fail rather than be
                // skipped — silent skipping is the anti-pattern this runner
                // exists to kill.
                std.debug.print("  UNKNOWN assertion key `{s}` in {s}\n", .{ key, Model.NAME });
                return error.UnknownAssertionKey;
            }
        }
    }

    return report;
}

/// Replay the whole corpus against one execution model.
fn runCorpus(comptime Model: type) !void {
    const name = Model.NAME;

    if (!specFixturesPresent()) {
        std.debug.print(
            "SKIP reactive_graph_conformance[{s}]: {s} not found — clone lazily-spec as a " ++
                "sibling to run the reactive-graph fixtures (#lzspecconf)\n",
            .{ name, SPEC_DIR },
        );
        return error.SkipZigTest;
    }

    var replayed: usize = 0;
    var skipped: usize = 0;
    var total_ops: usize = 0;
    var total_checks: usize = 0;

    for (FIXTURES) |fixture_name| {
        const parsed = try loadFixture(fixture_name);
        defer parsed.deinit();
        const fx = parsed.value;

        if (try firstUnsupportedOp(fx)) |blocking_op| {
            // Loud, named skip. Silent skipping is the anti-pattern.
            std.debug.print(
                "SKIP reactive-graph[{s}] {s}: unsupported op `{s}`\n",
                .{ name, fixture_name, blocking_op },
            );
            // The ledger must already know about it, and must agree on which
            // op blocks it.
            var documented = false;
            for (EXPECTED_SKIPS) |e| {
                if (std.mem.eql(u8, e.fixture, fixture_name)) {
                    try std.testing.expectEqualStrings(e.op, blocking_op);
                    documented = true;
                }
            }
            if (!documented) {
                std.debug.print(
                    "  {s} is not in EXPECTED_SKIPS — a fixture stopped being replayable\n",
                    .{fixture_name},
                );
                return error.UndocumentedSkip;
            }
            skipped += 1;
            continue;
        }

        // A replayable fixture must not be sitting in the skip ledger.
        for (EXPECTED_SKIPS) |e| {
            if (std.mem.eql(u8, e.fixture, fixture_name)) {
                std.debug.print(
                    "  {s} is replayable now — remove it from EXPECTED_SKIPS\n",
                    .{fixture_name},
                );
                return error.StaleSkipLedger;
            }
        }

        // Dispatch on the declared `shape`, not the filename.
        const shape = try asString(field(fx, "shape") orelse return error.MissingShape);
        var report = Report{};
        if (std.mem.eql(u8, shape, "steps")) {
            var model = try Model.create(std.testing.allocator);
            defer model.destroy();
            var table = NodeTable{};
            report = try replaySteps(Model, &model, &table, try asArray(field(fx, "steps").?));
        } else if (std.mem.eql(u8, shape, "scenarios")) {
            for (try asArray(field(fx, "scenarios") orelse return error.MissingScenarios)) |sc| {
                var model = try Model.create(std.testing.allocator);
                defer model.destroy();
                var table = NodeTable{};
                const r = try replaySteps(Model, &model, &table, try asArray(field(sc, "steps").?));
                report.ops += r.ops;
                report.checks += r.checks;
            }
        } else {
            return error.UnknownFixtureShape;
        }

        // Per-fixture positive assertion.
        if (report.ops == 0) return error.ReplayedZeroOps;
        if (report.checks == 0) return error.ReplayedZeroAssertions;

        std.debug.print(
            "reactive-graph[{s}] {s}: {d} ops, {d} assertions\n",
            .{ name, fixture_name, report.ops, report.checks },
        );
        total_ops += report.ops;
        total_checks += report.checks;
        replayed += 1;
    }

    std.debug.print(
        "reactive-graph[{s}]: {d} fixtures replayed, {d} skipped, {d} ops, {d} assertions\n",
        .{ name, replayed, skipped, total_ops, total_checks },
    );

    // ---- Positive assertion (`#lzspecconf`) ----
    // The runner must have actually executed the corpus. A runner that can
    // report green while executing nothing is the exact anti-pattern this
    // exists to kill, so a zero count in any of these fails loudly.
    try std.testing.expect(replayed > 0);
    try std.testing.expect(total_ops > 0);
    try std.testing.expect(total_checks > 0);
    try std.testing.expectEqual(EXPECTED_SKIPS.len, skipped);
    try std.testing.expectEqual(FIXTURES.len, replayed + skipped);
}

/// 1 if `name` is a known fixture, 0 if it is not a `.json` file at all, and an
/// error if it is a `.json` this runner does not know about.
fn countFixture(name: []const u8) !usize {
    if (!std.mem.endsWith(u8, name, ".json")) return 0;
    for (FIXTURES) |f| {
        if (std.mem.eql(u8, f, name)) return 1;
    }
    std.debug.print("  unknown fixture on disk: {s}\n", .{name});
    return error.FixtureSetDrifted;
}

test "reactive-graph conformance: fixture set on disk matches FIXTURES" {
    // An upstream addition or rename must fail here rather than go unrun.
    if (!specFixturesPresent()) return error.SkipZigTest;

    var seen: usize = 0;
    if (comptime builtin.zig_version.minor >= 16) {
        const io = std.testing.io;
        var dir = try std.Io.Dir.cwd().openDir(io, SPEC_DIR, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            seen += try countFixture(entry.name);
        }
    } else {
        var dir = try std.fs.cwd().openDir(SPEC_DIR, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            seen += try countFixture(entry.name);
        }
    }
    try std.testing.expectEqual(FIXTURES.len, seen);
}

test "reactive-graph conformance: Context (synchronous)" {
    try runCorpus(SyncModel);
}

test "reactive-graph conformance: ThreadSafeContext" {
    try runCorpus(TsModel);
}

test "reactive-graph conformance: AsyncContext" {
    // The context the dart/go transitive-cascade defect hid in. Replaying the
    // corpus here rather than only against `Context` is the whole point.
    try runCorpus(AsyncModel);
}
