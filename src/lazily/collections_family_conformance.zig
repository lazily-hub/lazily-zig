//! The keyed-collection ordering contract replayed against **all three
//! execution models** — `SourceMap`, `ThreadSafeSourceMap`, `AsyncSourceMap`.
//!
//! `cellmap_atomic_move.json` and `cellmap_independence.json` are canonical
//! fixtures required of every binding, and until now this binding named them in
//! a doc comment and loaded neither. Only `materialization/*.json` was ever
//! replayed. So the ordering and reader-class-independence laws had no
//! executable gate here at all, while the coverage matrix scored them green.
//!
//! One replay engine runs over a `Model` — the same shape as
//! `reactive_graph_conformance.zig`'s `Engine(comptime Model)`, which proved
//! years ago that the three execution models fit one generic harness. Ordering
//! is neither thread- nor async-coloured (it touches no entry node and awaits
//! nothing), so unlike the reactive-graph corpus this one needs no `settle`
//! projection: all three models are driven identically.
//!
//! # What is asserted, and what this binding cannot yet assert
//!
//! Per step, from the fixture: the resulting `order` and `membership`, the
//! changed `values`, and `invalidates` — the reader-class independence contract.
//!
//! `invalidates` is checked against the three **version counters**, not against
//! live readers, because that is the observable this binding exposes: entries on
//! the single-threaded map are cached values rather than reactive nodes, so
//! there are no per-entry readers to invalidate. This catches every mutation
//! that matters — a reorder leaking into membership, a value write leaking into
//! order — but it is strictly weaker than the graph-edge assertion lazily-rs
//! makes, and it is why this binding is marked partial rather than green on the
//! spec's Core row. Making it green means making the map graph-backed.

const std = @import("std");
const cj = @import("conformance_json.zig");
const builtin = @import("builtin");
const json = std.json;
const testing = std.testing;

const Context = @import("context.zig").Context;
const ThreadSafeContext = @import("thread_safe_context.zig").ThreadSafeContext;
const AsyncContext = @import("async_context.zig").AsyncContext;
const reactive_map = @import("reactive_map.zig");
const thread_safe_reactive_map = @import("thread_safe_reactive_map.zig");
const async_reactive_map = @import("async_reactive_map.zig");

/// This area's subdirectory of the corpus. NOT a path: the root resolves at
/// RUNTIME through `specAreaPath`, so this replay moves under
/// `LAZILY_SPEC_CONFORMANCE_DIR` with every other one (`#lzzigingressspecdir`).
const SPEC_AREA = "collections";

/// Entry value type used across all collection fixtures (JSON integers).
const V = i64;

/// Reads through the runtime conformance manifest recorder
/// (#lazilyupgradeconformance): naming a fixture is not replaying it, so the
/// coverage guard is fed by observed reads rather than a source grep.
const readFixtureFile = @import("conformance_manifest.zig").specReadFile;
const specAreaPath = @import("conformance_manifest.zig").specAreaPath;

fn fixturesPresent() bool {
    const path = specAreaPath(testing.allocator, SPEC_AREA, "cellmap_atomic_move.json") catch return false;
    defer testing.allocator.free(path);
    const raw = readFixtureFile(path) catch return false;
    testing.allocator.free(raw);
    return true;
}

fn field(value: json.Value, name: []const u8) ?json.Value {
    return switch (value) {
        .object => |o| o.get(name),
        else => null,
    };
}

fn required(value: json.Value, name: []const u8) !json.Value {
    return field(value, name) orelse error.MissingField;
}

fn asStr(value: json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}

fn asI64(value: json.Value) !i64 {
    return switch (value) {
        .integer => |n| n,
        .number_string => |s| try std.fmt.parseInt(i64, s, 10),
        else => error.ExpectedInteger,
    };
}

fn asBool(value: json.Value) !bool {
    return switch (value) {
        .bool => |b| b,
        else => error.ExpectedBool,
    };
}

/// The three reader classes, sampled before and after an op.
const Versions = struct {
    membership: u64,
    order: u64,
    /// Per-entry value versions, parallel to the key list they were sampled from.
    values: std.StringHashMap(u64),

    fn deinit(self: *Versions) void {
        self.values.deinit();
    }
};

// ---------------------------------------------------------------------------
// The three models
// ---------------------------------------------------------------------------

/// Single-threaded. Cached collection storage is surfaced through real
/// per-entry, membership, and order graph nodes.
const SyncModel = struct {
    ctx: *Context,
    map: reactive_map.SourceMap([]const u8, V),

    const FLAVOR = "SourceMap";
    const Self = @This();

    fn init(allocator: std.mem.Allocator) !Self {
        const ctx = try Context.init(allocator);
        return .{ .ctx = ctx, .map = try reactive_map.SourceMap([]const u8, V).init(ctx) };
    }
    fn deinit(self: *Self) void {
        self.map.deinit();
        self.ctx.deinit();
    }
    fn setValue(self: *Self, key: []const u8, v: V) !void {
        try self.map.set(key, v);
    }
    fn remove(self: *Self, key: []const u8) void {
        _ = self.map.remove(key);
    }
    fn moveTo(self: *Self, key: []const u8, index: usize) void {
        _ = self.map.moveTo(key, index);
    }
    fn moveBefore(self: *Self, key: []const u8, anchor: []const u8) void {
        _ = self.map.moveBefore(key, anchor);
    }
    fn moveAfter(self: *Self, key: []const u8, anchor: []const u8) void {
        _ = self.map.moveAfter(key, anchor);
    }
    fn keys(self: *Self) []const []const u8 {
        return self.map.keys().get();
    }
    fn value(self: *Self, key: []const u8) ?V {
        return self.map.get(key);
    }
    fn contains(self: *Self, key: []const u8) bool {
        return self.map.contains(key).get();
    }
    fn valueVersion(self: *Self, key: []const u8) ?u64 {
        return self.map.valueVersion(key);
    }
    fn membershipVersion(self: *Self) u64 {
        return self.map.membershipVersion();
    }
    fn orderVersion(self: *Self) u64 {
        return self.map.orderVersion();
    }
    /// Entry identity across an op — the `handle_stable` probe.
    fn handleStamp(self: *Self, key: []const u8) ?u64 {
        const h = self.map.handle(key) orelse return null;
        return h.id;
    }
};

/// Thread-safe. Entries are real nodes in a `ThreadSafeContext`.
const ThreadSafeModel = struct {
    tsctx: ThreadSafeContext,
    map: thread_safe_reactive_map.ThreadSafeSourceMap([]const u8, V),

    const FLAVOR = "ThreadSafeSourceMap";
    const Self = @This();

    fn init(allocator: std.mem.Allocator) !Self {
        var self: Self = undefined;
        self.tsctx = ThreadSafeContext.init(allocator);
        return self;
    }
    /// Two-phase because the map borrows `&self.tsctx`, whose address must be
    /// stable — `init` returns by value, so the map is wired after the move.
    fn wire(self: *Self) void {
        self.map = thread_safe_reactive_map.ThreadSafeSourceMap([]const u8, V).init(&self.tsctx);
    }
    fn deinit(self: *Self) void {
        self.map.deinit();
        self.tsctx.deinit();
    }
    fn setValue(self: *Self, key: []const u8, v: V) !void {
        try self.map.set(key, v);
    }
    fn remove(self: *Self, key: []const u8) void {
        _ = self.map.remove(key);
    }
    fn moveTo(self: *Self, key: []const u8, index: usize) void {
        _ = self.map.moveTo(key, index);
    }
    fn moveBefore(self: *Self, key: []const u8, anchor: []const u8) void {
        _ = self.map.moveBefore(key, anchor);
    }
    fn moveAfter(self: *Self, key: []const u8, anchor: []const u8) void {
        _ = self.map.moveAfter(key, anchor);
    }
    fn keys(self: *Self) []const []const u8 {
        return self.map.core.keys();
    }
    fn value(self: *Self, key: []const u8) ?V {
        return self.map.observe(key);
    }
    fn contains(self: *Self, key: []const u8) bool {
        return self.map.containsKey(key);
    }
    /// This flavor's entries are real nodes, so a value write is observable
    /// through the node rather than through a stamp. The fixture's per-entry
    /// value axis is asserted via `value()` instead; see `assertInvalidation`.
    fn valueVersion(self: *Self, key: []const u8) ?u64 {
        _ = self;
        _ = key;
        return null;
    }
    fn membershipVersion(self: *Self) u64 {
        return self.map.membershipVersion();
    }
    fn orderVersion(self: *Self) u64 {
        return self.map.orderVersion();
    }
    fn handleStamp(self: *Self, key: []const u8) ?u64 {
        const h = self.map.handle(key) orelse return null;
        return h.id;
    }
};

/// Async. Entries are nodes in an `AsyncContext`; ordering awaits nothing.
const AsyncModel = struct {
    actx: AsyncContext(V),
    map: async_reactive_map.AsyncSourceMap([]const u8, V),

    const FLAVOR = "AsyncSourceMap";
    const Self = @This();

    fn init(allocator: std.mem.Allocator) !Self {
        var self: Self = undefined;
        self.actx = AsyncContext(V).init(allocator);
        return self;
    }
    /// Two-phase for the same reason as the thread-safe model: the map borrows
    /// `&self.actx`, whose address must outlive `init`'s by-value return.
    fn wire(self: *Self) !void {
        self.map = try async_reactive_map.AsyncSourceMap([]const u8, V).init(&self.actx);
    }
    fn deinit(self: *Self) void {
        self.map.deinit();
        self.actx.deinit();
    }
    fn setValue(self: *Self, key: []const u8, v: V) !void {
        try self.map.set(key, v);
    }
    fn remove(self: *Self, key: []const u8) void {
        _ = self.map.remove(key);
    }
    fn moveTo(self: *Self, key: []const u8, index: usize) void {
        _ = self.map.moveTo(key, index);
    }
    fn moveBefore(self: *Self, key: []const u8, anchor: []const u8) void {
        _ = self.map.moveBefore(key, anchor);
    }
    fn moveAfter(self: *Self, key: []const u8, anchor: []const u8) void {
        _ = self.map.moveAfter(key, anchor);
    }
    fn keys(self: *Self) []const []const u8 {
        return self.map.keys();
    }
    fn value(self: *Self, key: []const u8) ?V {
        return self.map.observe(key);
    }
    fn contains(self: *Self, key: []const u8) bool {
        return self.map.containsKey(key);
    }
    fn valueVersion(self: *Self, key: []const u8) ?u64 {
        _ = self;
        _ = key;
        return null;
    }
    fn membershipVersion(self: *Self) u64 {
        return self.map.membershipVersion();
    }
    fn orderVersion(self: *Self) u64 {
        return self.map.orderVersion();
    }
    fn handleStamp(self: *Self, key: []const u8) ?u64 {
        const handle = self.map.handle(key) orelse return null;
        return handle.id;
    }
};

// ---------------------------------------------------------------------------
// The replay engine — one body, three models
// ---------------------------------------------------------------------------

fn Engine(comptime Model: type) type {
    return struct {
        /// `assertKeyWith` context for one replay step. Every check here takes
        /// the fixture's own value as its second argument, which is what makes
        /// the key count as ASSERTED rather than merely read.
        const StepCtx = struct {
            model: *Model,
            step: usize,
            stamps_before: *std.StringHashMap(u64),
            mv_before: u64,
            ov_before: u64,
            vv_before: *std.StringHashMap(u64),
            values_before: *std.StringHashMap(V),

            fn checkInvalidates(self: StepCtx, inv: *cj.AssertionKeys) !void {
                try assertInvalidation(
                    Model,
                    self.model,
                    inv,
                    self.step,
                    self.mv_before,
                    self.ov_before,
                    self.vv_before,
                    self.values_before,
                );
            }

            fn checkHandleStable(self: StepCtx, hs: *cj.AssertionKeys) !void {
                const obj = switch (hs.object) {
                    .object => |o| o,
                    else => return error.ExpectedObject,
                };
                var it = obj.iterator();
                while (it.next()) |e| {
                    const key = e.key_ptr.*;
                    const after = self.model.handleStamp(key);
                    const before = self.stamps_before.get(key);
                    const stable = after != null and before != null and after.? == before.?;
                    try hs.assertKey(key, stable);
                }
            }

            fn checkOrder(self: StepCtx, ord: json.Value) !void {
                const want = switch (ord) {
                    .array => |a| a,
                    else => return error.ExpectedArray,
                };
                const got = self.model.keys();
                if (want.items.len != got.len) {
                    std.debug.print(
                        "{s} step {d}: order length {d} != {d}\n",
                        .{ Model.FLAVOR, self.step, got.len, want.items.len },
                    );
                    return error.OrderMismatch;
                }
                for (want.items, got) |w, g| {
                    try testing.expectEqualStrings(try asStr(w), g);
                }
            }

            fn checkMembership(self: StepCtx, mem: json.Value) !void {
                const want = switch (mem) {
                    .array => |a| a,
                    else => return error.ExpectedArray,
                };
                try testing.expectEqual(want.items.len, self.model.keys().len);
                for (want.items) |w| {
                    try testing.expect(self.model.contains(try asStr(w)));
                }
            }

            fn checkValues(self: StepCtx, vals: *cj.AssertionKeys) !void {
                const object = switch (vals.object) {
                    .object => |o| o,
                    else => return error.ExpectedObject,
                };
                var it = object.iterator();
                while (it.next()) |entry| {
                    const got = self.model.value(entry.key_ptr.*) orelse return error.MissingKey;
                    try vals.assertKey(entry.key_ptr.*, got);
                }
            }
        };

        fn run(fixture_name: []const u8) !void {
            if (!fixturesPresent()) {
                std.debug.print(
                    "skipping {s}: {s} absent - run with the lazily-spec sibling\n",
                    .{ Model.FLAVOR, SPEC_AREA },
                );
                return;
            }
            const alloc = testing.allocator;
            const path = try specAreaPath(alloc, SPEC_AREA, fixture_name);
            defer alloc.free(path);
            const raw = try readFixtureFile(path);
            defer alloc.free(raw);
            var parsed = try json.parseFromSlice(json.Value, alloc, raw, .{});
            defer parsed.deinit();
            const fixture = parsed.value;

            var model = try Model.init(alloc);
            if (comptime @hasDecl(Model, "wire")) {
                const W = @typeInfo(@TypeOf(Model.wire)).@"fn".return_type.?;
                if (comptime @typeInfo(W) == .error_union) try model.wire() else model.wire();
            }
            defer model.deinit();

            // -- initial state ------------------------------------------
            const initial = try required(fixture, "initial");
            const init_order = switch (try required(initial, "order")) {
                .array => |a| a,
                else => return error.ExpectedArray,
            };
            const init_values = try required(initial, "values");
            for (init_order.items) |k| {
                const key = try asStr(k);
                const v = try asI64(field(init_values, key) orelse return error.MissingValue);
                try model.setValue(key, v);
            }

            const steps = switch (try required(fixture, "steps")) {
                .array => |a| a,
                else => return error.ExpectedArray,
            };
            // A vacuous replay must not report green.
            try testing.expect(steps.items.len > 0);

            for (steps.items, 0..) |step, i| {
                const op = try required(step, "op");
                var expected = cj.AssertionKeys.init("collections-family expected", try required(step, "expected"));
                defer expected.finish() catch @panic("conformance assertion-key check failed");

                // Sample every reader class before the op.
                const mv_before = model.membershipVersion();
                const ov_before = model.orderVersion();
                var vv_before = std.StringHashMap(u64).init(alloc);
                defer vv_before.deinit();
                var stamps_before = std.StringHashMap(u64).init(alloc);
                defer stamps_before.deinit();
                for (model.keys()) |k| {
                    if (model.valueVersion(k)) |vv| try vv_before.put(k, vv);
                    if (model.handleStamp(k)) |h| try stamps_before.put(k, h);
                }
                // Values before, so an untouched entry can be proved untouched
                // on the flavors whose entries are nodes rather than stamps.
                var values_before = std.StringHashMap(V).init(alloc);
                defer values_before.deinit();
                for (model.keys()) |k| {
                    if (model.value(k)) |v| try values_before.put(k, v);
                }

                try applyOp(Model, &model, op);

                // Every arm below routes the fixture's own value into the
                // comparison, so the tracker can tell a checked key from a read
                // one (#lzconsumednotasserted).
                const step_ctx = StepCtx{
                    .model = &model,
                    .step = i,
                    .stamps_before = &stamps_before,
                    .mv_before = mv_before,
                    .ov_before = ov_before,
                    .vv_before = &vv_before,
                    .values_before = &values_before,
                };

                // -- invalidation (reader-class independence) ------------
                try expected.assertObjectWith("invalidates", step_ctx, StepCtx.checkInvalidates);

                // -- handle stability ------------------------------------
                _ = try expected.assertObjectWithOpt("handle_stable", step_ctx, StepCtx.checkHandleStable);

                // -- resulting state -------------------------------------
                _ = try expected.assertKeyWithOpt("order", step_ctx, StepCtx.checkOrder);
                _ = try expected.assertKeyWithOpt("membership", step_ctx, StepCtx.checkMembership);
                _ = try expected.assertObjectWithOpt("values", step_ctx, StepCtx.checkValues);
            }
        }
    };
}

fn applyOp(comptime Model: type, model: *Model, op: json.Value) !void {
    const ty = try asStr(try required(op, "type"));
    if (std.mem.eql(u8, ty, "set_value")) {
        try model.setValue(try asStr(try required(op, "key")), try asI64(try required(op, "value")));
    } else if (std.mem.eql(u8, ty, "insert")) {
        const key = try asStr(try required(op, "key"));
        try model.setValue(key, try asI64(try required(op, "value")));
        // `at` is optional: "end" (where a fresh key lands) or a 0-based index.
        if (field(op, "at")) |at| {
            switch (at) {
                .integer => |n| model.moveTo(key, @intCast(n)),
                // "end" is where a fresh key already lands, so it is a no-op —
                // but only "end". A bare `else => {}` swallowed every other
                // spelling, so an `at` the fixture meant as a real position was
                // silently not applied and the step still booked
                // (#lzscenariobodyskip).
                .string => |s| if (!std.mem.eql(u8, s, "end")) {
                    std.debug.print("unknown insert position `{s}`\n", .{s});
                    return error.UnknownInsertPosition;
                },
                else => return error.UnknownInsertPosition,
            }
        }
    } else if (std.mem.eql(u8, ty, "remove")) {
        model.remove(try asStr(try required(op, "key")));
    } else if (std.mem.eql(u8, ty, "move_to")) {
        model.moveTo(
            try asStr(try required(op, "key")),
            @intCast(try asI64(try required(op, "index"))),
        );
    } else if (std.mem.eql(u8, ty, "move_before")) {
        model.moveBefore(
            try asStr(try required(op, "key")),
            try asStr(try required(op, "before")),
        );
    } else if (std.mem.eql(u8, ty, "move_after")) {
        model.moveAfter(
            try asStr(try required(op, "key")),
            try asStr(try required(op, "after")),
        );
    } else {
        std.debug.print("unknown collection op type: {s}\n", .{ty});
        return error.UnknownOp;
    }
}

/// The reader-class independence contract, asserted in **both** directions: a
/// class the fixture says invalidates must have changed, and one it says does
/// not must be byte-identical. One-directional checking is how a map that bumps
/// everything on every write passes a contract about not doing that.
fn assertInvalidation(
    comptime Model: type,
    model: *Model,
    inv: *cj.AssertionKeys,
    step: usize,
    mv_before: u64,
    ov_before: u64,
    vv_before: *std.StringHashMap(u64),
    values_before: *std.StringHashMap(V),
) !void {
    const membership_changed = model.membershipVersion() != mv_before;
    const checked_membership = try inv.assertKeyOpt("membership", membership_changed);
    if (!checked_membership and membership_changed) {
        std.debug.print(
            "{s} step {d}: membership invalidated but the fixture omits it " ++
                "(a pure reorder must NOT touch set identity)\n",
            .{ Model.FLAVOR, step },
        );
        return error.MembershipInvalidationMismatch;
    }

    const order_changed = model.orderVersion() != ov_before;
    const checked_order = try inv.assertKeyOpt("order", order_changed);
    if (!checked_order and order_changed) {
        std.debug.print(
            "{s} step {d}: order invalidated but the fixture omits it\n",
            .{ Model.FLAVOR, step },
        );
        return error.OrderInvalidationMismatch;
    }

    // Per-entry value axis. Keys the fixture lists must have changed; surviving
    // keys it does not list must be untouched.
    // An absent `value` list means "no entry value may change".
    var listed_items: []const json.Value = &.{};
    _ = try inv.assertKeyWithOpt("value", &listed_items, struct {
        fn check(out: *[]const json.Value, node: json.Value) !void {
            out.* = switch (node) {
                .array => |a| a.items,
                else => return error.ExpectedArray,
            };
        }
    }.check);
    for (model.keys()) |k| {
        var is_listed = false;
        for (listed_items) |l| {
            if (std.mem.eql(u8, try asStr(l), k)) is_listed = true;
        }
        // A key the op just added had no reader before it, so there is nothing
        // for the op to have invalidated. Scoring it would make every insert
        // fail its own `invalidates: {value: []}` clause.
        if (!values_before.contains(k)) continue;
        const changed = blk: {
            if (model.valueVersion(k)) |now| {
                // Stamp-bearing flavor: the version is the observable.
                const before = vv_before.get(k) orelse break :blk true;
                break :blk now != before;
            }
            // Node-bearing flavor: compare the value itself.
            const before = values_before.get(k) orelse break :blk true;
            const now = model.value(k) orelse break :blk true;
            break :blk now != before;
        };
        if (changed != is_listed) {
            std.debug.print(
                "{s} step {d}: value invalidation for `{s}` was {} but fixture says {}\n",
                .{ Model.FLAVOR, step, k, changed, is_listed },
            );
            return error.ValueInvalidationMismatch;
        }
    }
}

// ---------------------------------------------------------------------------
// The 2 x 3 matrix
// ---------------------------------------------------------------------------

test "lazily/collections_family: atomic move - SourceMap" {
    try Engine(SyncModel).run("cellmap_atomic_move.json");
}

test "lazily/collections_family: atomic move - ThreadSafeSourceMap" {
    try Engine(ThreadSafeModel).run("cellmap_atomic_move.json");
}

test "lazily/collections_family: atomic move - AsyncSourceMap" {
    try Engine(AsyncModel).run("cellmap_atomic_move.json");
}

test "lazily/collections_family: independence - SourceMap" {
    try Engine(SyncModel).run("cellmap_independence.json");
}

test "lazily/collections_family: independence - ThreadSafeSourceMap" {
    try Engine(ThreadSafeModel).run("cellmap_independence.json");
}

test "lazily/collections_family: independence - AsyncSourceMap" {
    try Engine(AsyncModel).run("cellmap_independence.json");
}
