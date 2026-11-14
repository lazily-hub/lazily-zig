//! The canonical reactive-egress corpus (`#lzegress`), replayed against **every
//! flavor this binding ships**: `EgressCell` / `ThreadSafeEgressCell` /
//! `AsyncEgressCell`, matching the `reactive-egress`, `egress-thread-safe` and
//! `egress-async` coverage rows.
//!
//! The fixture owns the transition and invalidation expectations; the flavor
//! axis lives in the runner. One comptime-duck-typed model interface replays the
//! same JSON against each shell. The transport Effect has its own unit coverage
//! in each shell module: the corpus describes the delivery authority beneath any
//! concrete transport.
//!
//! What keeps this from reporting green while testing nothing:
//!
//! * Every fixture is REQUIRED. A missing file fails (`SpecFixtureMissing`); it
//!   is never a skip.
//! * Every step is EXECUTED and counted, and each flavor's executed count must
//!   equal the number of steps the corpus carries — the count comes from what
//!   the replay did, not from what was loaded. An unknown `op.type` fails rather
//!   than being skipped.
//! * Each step's `expected` and `returns` blocks are bound to an
//!   `AssertionKeys` tracker, so an unread or unasserted key fails, and every
//!   value is observed through the shell's PUBLIC API.
//! * `invalidates` is asserted in BOTH directions through a cache-validity
//!   probe per reader kind (a derived node that read the reader, for the
//!   single-threaded graph; the reader node itself, for the other two). A step
//!   expecting `false` fails if the shell invalidated anyway. The probe is
//!   pinned by a negative control per flavor that proves it can fail.

const std = @import("std");
const testing = std.testing;
const cj = @import("conformance_json.zig");
const Context = @import("context.zig").Context;
const Compute = @import("context.zig").Compute;
const cell = @import("cell.zig");
const ThreadSafeContext = @import("thread_safe_context.zig").ThreadSafeContext;
const core_mod = @import("egress_core.zig");
const egress = @import("egress.zig");
const thread_safe_egress = @import("thread_safe_egress.zig");
const async_egress = @import("async_egress.zig");

const EgressPolicy = core_mod.EgressPolicy;
const EgressRetry = core_mod.EgressRetry;
const EgressAck = core_mod.EgressAck;
const EgressFailure = core_mod.EgressFailure;
const EgressRetryAction = core_mod.EgressRetryAction;
const EgressReconnect = core_mod.EgressReconnect;
const Envelope = core_mod.EgressEnvelope(u64);
const Claim = core_mod.EgressClaim(u64);

const SPEC_AREA = "egress";

/// Every egress-transport fixture the corpus ships. Named, not globbed: a
/// fixture added upstream and not here is a missing replay, and the runtime
/// coverage guard is what reports it.
const FIXTURES = [_][]const u8{
    "egress_ordered_ack.json",
    "egress_inflight_window.json",
    "egress_retry_budget.json",
    "egress_generation_fence.json",
};

/// Reader kinds in the order the fixture's `invalidates` object lists them.
const KINDS = [_][]const u8{ "pending", "inflight", "acked_through", "retry" };

// ---------------------------------------------------------------------------
// Flavor 1 — single-threaded. Reader kinds are `Source(u64)` nodes, so the
// probe is a derived node per kind that READ the reader: its cache validity is
// the graph's own answer to "was this reader invalidated".
// ---------------------------------------------------------------------------

const SyncCell = egress.EgressCell(u64);

/// The model the comptime probe bodies read. One replay runs at a time.
var sync_bound: ?*SyncModel = null;

fn syncProbe(comptime kind: usize) type {
    return struct {
        fn compute(view: *Compute) anyerror!u64 {
            const m = sync_bound.?;
            return switch (kind) {
                0 => @intCast(view.get(m.cell.pendingReader()).len),
                1 => @intCast(view.get(m.cell.inflightReader()).len),
                2 => if (view.get(m.cell.ackedThroughReader())) |x| x +% 1 else 0,
                3 => if (view.get(m.cell.retryReader())) |r| @as(u64, r.attempt) +% 1 else 0,
                else => unreachable,
            };
        }
    };
}

const SyncModel = struct {
    allocator: std.mem.Allocator,
    ctx: *Context,
    cell: SyncCell,
    probes: [4]*cell.Computed(u64) = undefined,
    probe_keys: [4]usize = undefined,

    pub const label = "single-threaded";

    pub fn create(allocator: std.mem.Allocator, initial_generation: u64, policy: EgressPolicy) !*SyncModel {
        const ctx = try Context.init(allocator);
        errdefer ctx.deinit();
        const self = try allocator.create(SyncModel);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .ctx = ctx, .cell = try SyncCell.init(ctx, initial_generation, policy) };
        sync_bound = self;
        inline for (0..4) |kind| {
            const node = try cell.computed(u64, ctx, syncProbe(kind).compute, null);
            self.probes[kind] = node;
            self.probe_keys[kind] = node.slot.cache_key.?;
        }
        return self;
    }

    pub fn destroy(self: *SyncModel) void {
        for (self.probes) |node| self.allocator.destroy(node);
        self.cell.deinit();
        self.ctx.deinit();
        if (sync_bound == self) sync_bound = null;
        self.allocator.destroy(self);
    }

    pub fn materialize(self: *SyncModel) !void {
        for (self.probes) |node| _ = node.get();
    }

    pub fn validity(self: *SyncModel) ![4]bool {
        var out: [4]bool = undefined;
        for (self.probe_keys, 0..) |key, i| {
            const slot = self.ctx.cacheLookup(key) orelse {
                out[i] = false;
                continue;
            };
            out[i] = slot.storage != null and !slot.stale and !slot.disposed;
        }
        return out;
    }

    pub fn enqueue(self: *SyncModel, payload: u64) !u64 {
        return self.cell.enqueue(payload);
    }
    pub fn claim(self: *SyncModel, g: u64) !Claim {
        return self.cell.claim(g);
    }
    pub fn ack(self: *SyncModel, g: u64, through: u64) !EgressAck {
        return self.cell.ack(g, through);
    }
    pub fn fail(self: *SyncModel, g: u64, sequence: u64) !EgressFailure {
        return self.cell.fail(g, sequence);
    }
    pub fn retryNow(self: *SyncModel, g: u64, sequence: u64) !EgressRetryAction {
        return self.cell.retryNow(g, sequence);
    }
    pub fn reconnect(self: *SyncModel, g: u64) !EgressReconnect {
        return self.cell.reconnect(g);
    }
    pub fn generation(self: *SyncModel) u64 {
        return self.cell.generation();
    }
    pub fn nextSequence(self: *SyncModel) u64 {
        return self.cell.nextSequence();
    }
    pub fn pending(self: *SyncModel, allocator: std.mem.Allocator) ![]Envelope {
        return allocator.dupe(Envelope, self.cell.pendingReader().get());
    }
    pub fn inflight(self: *SyncModel, allocator: std.mem.Allocator) ![]Envelope {
        return allocator.dupe(Envelope, self.cell.inflightReader().get());
    }
    pub fn ackedThrough(self: *SyncModel) !?u64 {
        return self.cell.ackedThroughReader().get();
    }
    pub fn retry(self: *SyncModel) !?EgressRetry {
        return self.cell.retryReader().get();
    }
};

// ---------------------------------------------------------------------------
// Flavor 2 — thread-safe. The reader kinds ARE graph nodes; the probe is the
// context's own cache-validity introspection on them.
// ---------------------------------------------------------------------------

const TsCell = thread_safe_egress.ThreadSafeEgressCell(u64);

const ThreadSafeModel = struct {
    allocator: std.mem.Allocator,
    ctx: ThreadSafeContext,
    cell: TsCell,

    pub const label = "thread-safe";

    pub fn create(allocator: std.mem.Allocator, initial_generation: u64, policy: EgressPolicy) !*ThreadSafeModel {
        const self = try allocator.create(ThreadSafeModel);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .ctx = ThreadSafeContext.init(allocator), .cell = undefined };
        errdefer self.ctx.deinit();
        try self.cell.init(&self.ctx, initial_generation, policy);
        return self;
    }

    pub fn destroy(self: *ThreadSafeModel) void {
        self.cell.deinit();
        self.ctx.deinit();
        self.allocator.destroy(self);
    }

    pub fn materialize(self: *ThreadSafeModel) !void {
        _ = self.ctx.get(u64, self.cell.pendingHandle());
        _ = self.ctx.get(u64, self.cell.inflightHandle());
        _ = self.ctx.get(?u64, self.cell.ackedThroughHandle());
        _ = self.ctx.get(?EgressRetry, self.cell.retryHandle());
    }

    pub fn validity(self: *ThreadSafeModel) ![4]bool {
        return self.cell.validity();
    }

    pub fn enqueue(self: *ThreadSafeModel, payload: u64) !u64 {
        return self.cell.enqueue(payload);
    }
    pub fn claim(self: *ThreadSafeModel, g: u64) !Claim {
        return self.cell.claim(g);
    }
    pub fn ack(self: *ThreadSafeModel, g: u64, through: u64) !EgressAck {
        return self.cell.ack(g, through);
    }
    pub fn fail(self: *ThreadSafeModel, g: u64, sequence: u64) !EgressFailure {
        return self.cell.fail(g, sequence);
    }
    pub fn retryNow(self: *ThreadSafeModel, g: u64, sequence: u64) !EgressRetryAction {
        return self.cell.retryNow(g, sequence);
    }
    pub fn reconnect(self: *ThreadSafeModel, g: u64) !EgressReconnect {
        return self.cell.reconnect(g);
    }
    pub fn generation(self: *ThreadSafeModel) u64 {
        return self.cell.generation();
    }
    pub fn nextSequence(self: *ThreadSafeModel) u64 {
        return self.cell.nextSequence();
    }
    pub fn pending(self: *ThreadSafeModel, allocator: std.mem.Allocator) ![]Envelope {
        return self.cell.pending(allocator);
    }
    pub fn inflight(self: *ThreadSafeModel, allocator: std.mem.Allocator) ![]Envelope {
        return self.cell.inflight(allocator);
    }
    pub fn ackedThrough(self: *ThreadSafeModel) !?u64 {
        return self.cell.ackedThrough();
    }
    pub fn retry(self: *ThreadSafeModel) !?EgressRetry {
        return self.cell.retry();
    }
};

// ---------------------------------------------------------------------------
// Flavor 3 — async. No `settle` step in the model: delivery state is not
// async-coloured, so every read drives the queue itself.
// ---------------------------------------------------------------------------

const AsyncCell = async_egress.AsyncEgressCell(u64);

const AsyncModel = struct {
    allocator: std.mem.Allocator,
    ctx: AsyncCell.Ctx,
    cell: AsyncCell,

    pub const label = "async";

    pub fn create(allocator: std.mem.Allocator, initial_generation: u64, policy: EgressPolicy) !*AsyncModel {
        const self = try allocator.create(AsyncModel);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .ctx = AsyncCell.Ctx.init(allocator), .cell = undefined };
        errdefer self.ctx.deinit();
        try self.cell.init(&self.ctx, initial_generation, policy);
        return self;
    }

    pub fn destroy(self: *AsyncModel) void {
        self.cell.deinit();
        self.ctx.deinit();
        self.allocator.destroy(self);
    }

    pub fn materialize(self: *AsyncModel) !void {
        _ = try self.ctx.awaitComputed(self.cell.pendingHandle());
        _ = try self.ctx.awaitComputed(self.cell.inflightHandle());
        _ = try self.ctx.awaitComputed(self.cell.ackedThroughHandle());
        _ = try self.ctx.awaitComputed(self.cell.retryHandle());
    }

    pub fn validity(self: *AsyncModel) ![4]bool {
        return self.cell.validity();
    }

    pub fn enqueue(self: *AsyncModel, payload: u64) !u64 {
        return self.cell.enqueue(payload);
    }
    pub fn claim(self: *AsyncModel, g: u64) !Claim {
        return self.cell.claim(g);
    }
    pub fn ack(self: *AsyncModel, g: u64, through: u64) !EgressAck {
        return self.cell.ack(g, through);
    }
    pub fn fail(self: *AsyncModel, g: u64, sequence: u64) !EgressFailure {
        return self.cell.fail(g, sequence);
    }
    pub fn retryNow(self: *AsyncModel, g: u64, sequence: u64) !EgressRetryAction {
        return self.cell.retryNow(g, sequence);
    }
    pub fn reconnect(self: *AsyncModel, g: u64) !EgressReconnect {
        return self.cell.reconnect(g);
    }
    pub fn generation(self: *AsyncModel) u64 {
        return self.cell.generation();
    }
    pub fn nextSequence(self: *AsyncModel) u64 {
        return self.cell.nextSequence();
    }
    pub fn pending(self: *AsyncModel, allocator: std.mem.Allocator) ![]Envelope {
        return self.cell.pending(allocator);
    }
    pub fn inflight(self: *AsyncModel, allocator: std.mem.Allocator) ![]Envelope {
        return self.cell.inflight(allocator);
    }
    pub fn ackedThrough(self: *AsyncModel) !?u64 {
        return self.cell.ackedThrough();
    }
    pub fn retry(self: *AsyncModel) !?EgressRetry {
        return self.cell.retry();
    }
};

// ---------------------------------------------------------------------------
// Fixture decoding and comparison
// ---------------------------------------------------------------------------

fn policyOf(value: cj.Value) !EgressPolicy {
    return .{
        .inflight_limit = try cj.asUsize(try cj.required(value, "inflight_limit")),
        .retry_budget = @intCast(try cj.asU64(try cj.required(value, "retry_budget"))),
        .retry_base = try cj.asU64(try cj.required(value, "retry_base")),
        .retry_ceiling = try cj.asU64(try cj.required(value, "retry_ceiling")),
    };
}

fn objectLen(value: cj.Value) !usize {
    return switch (value) {
        .object => |o| o.count(),
        else => error.ExpectedObject,
    };
}

/// One envelope against its fixture object, key set included.
fn expectEnvelope(actual: Envelope, want: cj.Value) !void {
    try testing.expectEqual(@as(usize, 4), try objectLen(want));
    try testing.expectEqual(try cj.asU64(try cj.required(want, "generation")), actual.generation);
    try testing.expectEqual(try cj.asU64(try cj.required(want, "sequence")), actual.sequence);
    try testing.expectEqual(try cj.asU64(try cj.required(want, "attempt")), @as(u64, actual.attempt));
    try testing.expectEqual(try cj.asU64(try cj.required(want, "payload")), actual.payload);
}

fn expectEnvelopes(actual: []const Envelope, want: cj.Value) anyerror!void {
    const items = try cj.asArray(want);
    if (items.len != actual.len) {
        std.debug.print("envelope list length: want {d}, got {d}\n", .{ items.len, actual.len });
        return error.TestExpectedEqual;
    }
    for (items, actual) |w, a| try expectEnvelope(a, w);
}

/// A `retry` decision object, via a child tracker so its key set is owned.
fn expectRetryObject(keys: *cj.AssertionKeys, name: []const u8, actual: ?EgressRetry) !void {
    const want = try keys.required(name);
    if (want == .null) {
        if (actual != null) {
            std.debug.print("{s}: '{s}' want null, got a retry decision\n", .{ keys.where, name });
            return error.TestExpectedEqual;
        }
        return keys.assertKey(name, null);
    }
    const got = actual orelse {
        std.debug.print("{s}: '{s}' want a retry decision, got null\n", .{ keys.where, name });
        return error.TestExpectedEqual;
    };
    var sub = try keys.sub(name);
    try sub.assertKey("sequence", got.sequence);
    try sub.assertKey("attempt", got.attempt);
    try sub.assertKey("backoff", got.backoff);
    try sub.assertKey("exhausted", got.exhausted);
    try sub.finish();
}

fn expectReturns(where: []const u8, op_type: []const u8, model: anytype, op: cj.Value, want: cj.Value) !void {
    var keys = cj.AssertionKeys.init(where, want);
    if (std.mem.eql(u8, op_type, "enqueue")) {
        const sequence = try model.enqueue(try cj.asU64(try cj.required(op, "payload")));
        try keys.assertKey("sequence", sequence);
    } else if (std.mem.eql(u8, op_type, "claim")) {
        const claimed = try model.claim(try cj.asU64(try cj.required(op, "generation")));
        try keys.assertKey("claim", std.meta.activeTag(claimed));
        switch (claimed) {
            .claimed => |envelope| {
                var sub = try keys.sub("envelope");
                try sub.assertKey("generation", envelope.generation);
                try sub.assertKey("sequence", envelope.sequence);
                try sub.assertKey("attempt", envelope.attempt);
                try sub.assertKey("payload", envelope.payload);
                try sub.finish();
            },
            .stale_generation => |current| try keys.assertKey("current", current),
            .empty, .window_full => {},
        }
    } else if (std.mem.eql(u8, op_type, "ack")) {
        const result = try model.ack(
            try cj.asU64(try cj.required(op, "generation")),
            try cj.asU64(try cj.required(op, "through")),
        );
        try keys.assertKey("ack", std.meta.activeTag(result));
        switch (result) {
            .advanced => |through| try keys.assertKey("through", through),
            .unchanged => |through| try keys.assertKey("through", through),
            .stale_generation => |current| try keys.assertKey("current", current),
        }
    } else if (std.mem.eql(u8, op_type, "fail")) {
        const result = try model.fail(
            try cj.asU64(try cj.required(op, "generation")),
            try cj.asU64(try cj.required(op, "sequence")),
        );
        try keys.assertKey("failure", std.meta.activeTag(result));
        switch (result) {
            .retrying, .exhausted => |r| try expectRetryObject(&keys, "retry", r),
            .stale_generation => |current| try keys.assertKey("current", current),
            .unknown_sequence => {},
        }
    } else if (std.mem.eql(u8, op_type, "retry_now")) {
        const result = try model.retryNow(
            try cj.asU64(try cj.required(op, "generation")),
            try cj.asU64(try cj.required(op, "sequence")),
        );
        try keys.assertKey("retry_action", std.meta.activeTag(result));
        switch (result) {
            .scheduled => |sequence| try keys.assertKey("sequence", sequence),
            .stale_generation => |current| try keys.assertKey("current", current),
            .unknown_sequence => {},
        }
    } else if (std.mem.eql(u8, op_type, "reconnect")) {
        const result = try model.reconnect(try cj.asU64(try cj.required(op, "generation")));
        try keys.assertKey("reconnect", std.meta.activeTag(result));
        switch (result) {
            .advanced => |a| {
                try keys.assertKey("generation", a.generation);
                try keys.assertKey("replayed", a.replayed);
            },
            .unchanged => |g| try keys.assertKey("generation", g),
            .stale_generation => |current| try keys.assertKey("current", current),
        }
    } else {
        std.debug.print("{s}: unknown egress op `{s}`\n", .{ where, op_type });
        return error.UnknownOperation;
    }
    try keys.finish();
}

fn expectState(
    where: []const u8,
    model: anytype,
    expected: cj.Value,
    before: [4]bool,
    after: [4]bool,
) !void {
    const allocator = testing.allocator;
    var keys = cj.AssertionKeys.init(where, expected);
    try keys.assertKey("generation", model.generation());
    try keys.assertKey("next_sequence", model.nextSequence());
    const pending: []const Envelope = try model.pending(allocator);
    defer allocator.free(pending);
    try keys.assertKeyWith("pending", pending, expectEnvelopes);
    const inflight: []const Envelope = try model.inflight(allocator);
    defer allocator.free(inflight);
    try keys.assertKeyWith("inflight", inflight, expectEnvelopes);
    try keys.assertKey("acked_through", try model.ackedThrough());
    try expectRetryObject(&keys, "retry", try model.retry());

    var invalidates = try keys.sub("invalidates");
    inline for (KINDS, 0..) |kind, i| {
        // Invalidated = was a valid cache before the op AND is not one now.
        invalidates.assertKey(kind, before[i] and !after[i]) catch |err| {
            std.debug.print(
                "{s}: '{s}' invalidation (was valid={}, now valid={})\n",
                .{ where, kind, before[i], after[i] },
            );
            return err;
        };
    }
    try invalidates.finish();
    try keys.finish();
}

/// Replay one fixture against one flavor. Returns the number of steps EXECUTED.
fn replayFixture(comptime Model: type, name: []const u8, fixture: cj.Value) !usize {
    try testing.expectEqualStrings("Egress", try cj.asStr(try cj.required(fixture, "kind")));
    try testing.expectEqualStrings("EgressCore", try cj.asStr(try cj.required(fixture, "model")));
    const model = try Model.create(
        testing.allocator,
        try cj.asU64(try cj.required(fixture, "generation")),
        try policyOf(try cj.required(fixture, "policy")),
    );
    defer model.destroy();
    try model.materialize();

    var executed: usize = 0;
    for (try cj.asArray(try cj.required(fixture, "steps")), 0..) |step, index| {
        const op = try cj.required(step, "op");
        const op_type = try cj.asStr(try cj.required(op, "type"));
        var returns_where: [192]u8 = undefined;
        var expected_where: [192]u8 = undefined;
        const rw = std.fmt.bufPrint(&returns_where, "{s}/{s} [{s}] steps[{d}].returns ({s})", .{ SPEC_AREA, name, Model.label, index, op_type }) catch name;
        const ew = std.fmt.bufPrint(&expected_where, "{s}/{s} [{s}] steps[{d}].expected ({s})", .{ SPEC_AREA, name, Model.label, index, op_type }) catch name;

        const before = try model.validity();
        try expectReturns(rw, op_type, model, op, try cj.required(step, "returns"));
        const after = try model.validity();
        try expectState(ew, model, try cj.required(step, "expected"), before, after);
        // Warm every reader so the next step's probe measures that step alone.
        try model.materialize();
        executed += 1;
    }
    return executed;
}

const Corpus = struct {
    fixtures: [FIXTURES.len]cj.Fixture,

    fn load() !Corpus {
        var out: Corpus = undefined;
        var loaded: usize = 0;
        errdefer for (out.fixtures[0..loaded]) |*f| f.deinit();
        for (FIXTURES, 0..) |name, i| {
            var path_buf: [128]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ SPEC_AREA, name });
            out.fixtures[i] = (try cj.load(path)) orelse {
                std.debug.print("egress corpus fixture missing: {s} (a missing fixture is a FAILURE, never a skip)\n", .{path});
                return error.SpecFixtureMissing;
            };
            loaded += 1;
        }
        return out;
    }

    fn deinit(self: *Corpus) void {
        for (&self.fixtures) |*f| f.deinit();
    }

    /// Steps the corpus CARRIES — compared against steps a flavor EXECUTED.
    fn stepCount(self: *const Corpus) !usize {
        var total: usize = 0;
        for (self.fixtures) |f| {
            const steps = try cj.asArray(try cj.required(f.value, "steps"));
            if (steps.len == 0) return error.VacuousFixture;
            total += steps.len;
        }
        return total;
    }
};

fn replayCorpus(comptime Model: type, corpus: *const Corpus) !usize {
    var executed: usize = 0;
    for (corpus.fixtures, FIXTURES) |f, name| executed += try replayFixture(Model, name, f.value);
    return executed;
}

test "egress corpus: single-threaded EgressCell executes every step" {
    var corpus = try Corpus.load();
    defer corpus.deinit();
    const carried = try corpus.stepCount();
    try testing.expect(carried > 0);
    try testing.expectEqual(carried, try replayCorpus(SyncModel, &corpus));
}

test "egress corpus: ThreadSafeEgressCell executes every step" {
    var corpus = try Corpus.load();
    defer corpus.deinit();
    const carried = try corpus.stepCount();
    try testing.expect(carried > 0);
    try testing.expectEqual(carried, try replayCorpus(ThreadSafeModel, &corpus));
}

test "egress corpus: AsyncEgressCell executes every step" {
    var corpus = try Corpus.load();
    defer corpus.deinit();
    const carried = try corpus.stepCount();
    try testing.expect(carried > 0);
    try testing.expectEqual(carried, try replayCorpus(AsyncModel, &corpus));
}

/// Negative control: the probe must be ABLE to report an invalidation, and must
/// report exactly the kinds an enqueue dirties. A probe stuck at "valid" (or
/// stuck at "invalid") would satisfy half of every `invalidates` matrix.
fn probeDiscriminates(comptime Model: type) !void {
    const model = try Model.create(testing.allocator, 1, .{});
    defer model.destroy();
    try model.materialize();
    try testing.expectEqual([4]bool{ true, true, true, true }, try model.validity());
    _ = try model.enqueue(1);
    try testing.expectEqual([4]bool{ false, true, true, true }, try model.validity());
    try model.materialize();
    _ = try model.claim(1);
    try testing.expectEqual([4]bool{ false, false, true, true }, try model.validity());
    try model.materialize();
    _ = try model.ack(1, 0);
    try testing.expectEqual([4]bool{ true, false, false, true }, try model.validity());
}

test "egress corpus: the invalidation probe discriminates on every flavor" {
    try probeDiscriminates(SyncModel);
    try probeDiscriminates(ThreadSafeModel);
    try probeDiscriminates(AsyncModel);
}
