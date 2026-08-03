//! The canonical `QueueCell`, `TopicCell` and `WorkQueueCell` corpora, replayed
//! against **every flavor this binding ships** — with a ledger that is *enforced*
//! rather than advisory (`#lzqueuefamilyflavors`).
//!
//! lazily-zig now ships all nine cells: `QueueCell` / `ThreadSafeQueueCell` /
//! `AsyncQueueCell`, `TopicCell` / `ThreadSafeTopicCell` / `AsyncTopicCell`, and
//! `WorkQueueCell` / `ThreadSafeWorkQueueCell` / `AsyncWorkQueueCell` — matching
//! the nine `coverage.json` queue-family rows.
//!
//! The flavor axis lives in the **runner**, not the corpus: each fixture carries a
//! `model` field naming the primitive and no execution-model field, and one
//! comptime-duck-typed model interface per primitive replays the same JSON against
//! each of its three shells. Nothing in those interfaces is thread- or
//! async-coloured, which is the finding rather than an oversight — whether a push
//! is admissible is a function of the bound and the closed flag, and which cursors
//! a publish moves is a function of the connected set, so there is nothing to await
//! and no `settle` step anywhere below.
//!
//! # What keeps this suite from reporting green while testing nothing
//!
//! Each of these is a failure mode this family of suites has actually shipped:
//!
//! * **Exact step counts, not floors.** Every replay returns its step count and
//!   every test asserts the corpus total — 31 for the five `queuecell_*`
//!   fixtures, 29 for the four `topiccell_*`, 18 for the two `workqueue_*`. A
//!   runner that opens every fixture and drives none of their steps reports the
//!   same "ok" as a real one, so an absence guard is not enough: only a positive,
//!   *equal* count proves this binary drove them.
//! * **`invalidates` asserted in BOTH directions, per reader kind.** A step whose
//!   fixture says `invalidates.head: false` FAILS if the flavor invalidated
//!   anyway, so over-invalidation is as visible as under-invalidation. Asserting
//!   the post-state alone would pass against a cell that dirties every reader on
//!   every op, which is exactly the defect reader-kind independence exists to
//!   forbid. Every flavor observes it through its own per-reader version counter:
//!   `ReaderKind.version` for the single-threaded shells, the atomic bump counter
//!   for the thread-safe ones, the plain bump counter for the async ones.
//! * **A version counter is not the only evidence.** The counters could in
//!   principle move without any dependent rerunning, so the tail of this file
//!   builds a real derived node per flavor over a real reader and proves it reruns
//!   exactly when the reader was invalidated — and stays warm when it was not.
//! * **The probe itself must be able to fail.** A probe stuck on "always
//!   invalidated" would pass every `true` for free. `the invalidation probe
//!   discriminates` pins that a push onto a non-empty queue does NOT move `head`
//!   while a pop does, on all three flavors.
//! * **A 3×3 ledger**, checked against the family's SOURCE TEXT in both
//!   directions and against the models the replay actually drives. A row claiming
//!   a flavor whose type is not defined fails; a defined type whose row says
//!   unshipped fails and names the runner to extend; and a shipped row whose
//!   `flavor` does not match the model in the replay list fails, so a row cannot
//!   claim a flavor the runner never touched.
//!
//! # One place the corpus used to be thinner than the code
//!
//! `WorkQueueCell`'s `visibility_timeout` / `max_deliveries` now come from the
//! fixture's top-level `config` block. They used to be supplied out of band —
//! `replayWorkQueue` took `max_deliveries` as a parameter and the timeout was the
//! literal `10` — which is drift by construction: the corpus could retune a lease
//! and this binding would keep replaying the old one and stay green.
//!
//! `restart` still carries a `subscriber` the observable contract never uses: the
//! one fixture step that issues it expects *nothing* to change. This family's
//! `restart` takes no subscriber for that reason, and the step still pins the
//! no-op.

const std = @import("std");
const testing = std.testing;

const cj = @import("conformance_json.zig");
const Value = cj.Value;

const Context = @import("context.zig").Context;
const Compute = @import("context.zig").Compute;
const cell = @import("cell.zig");
const ThreadSafeContext = @import("thread_safe_context.zig").ThreadSafeContext;
const core_mod = @import("queue_core.zig");
const queue = @import("queue.zig");
const work_queue = @import("work_queue.zig");
const thread_safe_queue = @import("thread_safe_queue.zig");
const async_queue = @import("async_queue.zig");

const QueueVersions = core_mod.QueueVersions;
const WorkQueueVersions = core_mod.WorkQueueVersions;
const TopicDurability = core_mod.TopicDurability;
const TopicSnapshot = core_mod.TopicSnapshot;
const TopicSubscriptionSnapshot = core_mod.TopicSubscriptionSnapshot;

const Str = []const u8;
const VecDeque = queue.VecDequeStorage(Str);

// ---------------------------------------------------------------------------
// The corpus
// ---------------------------------------------------------------------------

/// Named explicitly rather than globbed: a fixture added to the corpus and not to
/// one of these lists is a *missing replay*, and the runtime coverage guard is
/// what should notice, not a silently shorter run.
const queue_fixtures = [_]Str{
    "collections/queuecell_spsc_push_pop.json",
    "collections/queuecell_popped_head_observation.json",
    "collections/queuecell_mpsc_multi_writer.json",
    "collections/queuecell_bounded_backpressure.json",
    "collections/queuecell_closure_lifecycle.json",
};

const topic_fixtures = [_]Str{
    "collections/topiccell_broadcast_cursor_isolation.json",
    "collections/topiccell_durable_replay_gc.json",
    "collections/topiccell_ephemeral_lifecycle.json",
    "collections/topiccell_offline_tail_bounds.json",
};

const work_queue_fixtures = [_]Str{
    "collections/workqueue_competing_delivery.json",
    "collections/workqueue_lease_deadletter.json",
};

/// Total steps in each corpus.
const queue_corpus_steps = 31;
const topic_corpus_steps = 29;
const work_queue_corpus_steps = 18;

/// Steps and asserted `invalidates` flags. A step count alone cannot tell a
/// replay that asserted the matrix from one that skipped it.
const ReplayCount = struct {
    steps: usize = 0,
    flags: usize = 0,

    fn add(self: *ReplayCount, other: ReplayCount) void {
        self.steps += other.steps;
        self.flags += other.flags;
    }
};

fn corpusPresent() bool {
    const loaded = cj.load(queue_fixtures[0]) catch return false;
    if (loaded) |parsed| {
        var owned = parsed;
        owned.deinit();
        return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Op outcomes — flavor-neutral spellings of what a queue op reported
// ---------------------------------------------------------------------------

const PushOutcome = enum { ok, full, closed };
const PopOutcome = union(enum) { value: Str, empty, closed };

// ===========================================================================
// QueueCell — three flavors
// ===========================================================================

const SyncQueue = queue.QueueCell(Str, VecDeque);

/// Module-scope binding for the batch body: Zig has no closures and
/// `Context.batch` takes a bare fn. One replay runs at a time, the same idiom
/// `queue.zig`'s own MPSC test uses.
var sync_batch_model: ?*SyncQueueModel = null;
var sync_batch_values: []const Value = &.{};

fn syncBatchBody(_: *Context) void {
    const model = sync_batch_model orelse return;
    for (sync_batch_values) |op| {
        const value_node = cj.required(op, "value") catch return;
        const value = cj.asStr(value_node) catch return;
        model.cell.tryPush(value) catch {};
    }
}

const SyncQueueModel = struct {
    allocator: std.mem.Allocator,
    ctx: *Context,
    cell: SyncQueue,

    pub const label = "single-threaded";

    pub fn create(allocator: std.mem.Allocator, capacity: ?usize) !*SyncQueueModel {
        const ctx = try Context.init(allocator);
        errdefer ctx.deinit();
        const self = try allocator.create(SyncQueueModel);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .ctx = ctx,
            .cell = if (capacity) |c|
                try queue.newBounded(Str, ctx, c)
            else
                try queue.newUnbounded(Str, ctx),
        };
        return self;
    }

    pub fn destroy(self: *SyncQueueModel) void {
        self.cell.deinit();
        self.ctx.deinit();
        if (sync_batch_model == self) sync_batch_model = null;
        self.allocator.destroy(self);
    }

    pub fn push(self: *SyncQueueModel, value: Str) !PushOutcome {
        self.cell.tryPush(value) catch |err| return switch (err) {
            error.Full => PushOutcome.full,
            error.Closed => PushOutcome.closed,
        };
        return .ok;
    }

    pub fn pop(self: *SyncQueueModel) !PopOutcome {
        const value = self.cell.tryPop() catch |err| return switch (err) {
            error.Empty => PopOutcome.empty,
            error.Closed => PopOutcome.closed,
        };
        return .{ .value = value };
    }

    pub fn close(self: *SyncQueueModel) !void {
        self.cell.close();
    }

    /// MPSC: per-producer pushes inside one `batch()` boundary.
    pub fn batchPush(self: *SyncQueueModel, ops: []const Value) !void {
        sync_batch_model = self;
        sync_batch_values = ops;
        self.ctx.batch(syncBatchBody);
    }

    pub fn head(self: *SyncQueueModel) !?Str {
        return self.cell.head().get();
    }
    pub fn len(self: *SyncQueueModel) !usize {
        return self.cell.len().get();
    }
    pub fn isEmpty(self: *SyncQueueModel) !bool {
        return self.cell.isEmpty().get();
    }
    pub fn isFull(self: *SyncQueueModel) !bool {
        return self.cell.isFull().get();
    }
    pub fn isClosed(self: *SyncQueueModel) !bool {
        return self.cell.isClosed().get();
    }
    pub fn elements(self: *SyncQueueModel) []const Str {
        return self.cell.items();
    }
    pub fn versions(self: *SyncQueueModel) QueueVersions {
        return self.cell.versions();
    }
};

const TsQueue = thread_safe_queue.ThreadSafeQueueCell(Str, VecDeque);

const TsQueueModel = struct {
    allocator: std.mem.Allocator,
    ctx: ThreadSafeContext,
    cell: TsQueue,

    pub const label = "thread-safe";

    const BatchOp = struct { model: *TsQueueModel, ops: []const Value };

    pub fn create(allocator: std.mem.Allocator, capacity: ?usize) !*TsQueueModel {
        const self = try allocator.create(TsQueueModel);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .ctx = ThreadSafeContext.init(allocator),
            .cell = undefined,
        };
        if (capacity) |c| {
            try thread_safe_queue.initBounded(Str, &self.cell, &self.ctx, c);
        } else {
            try thread_safe_queue.initUnbounded(Str, &self.cell, &self.ctx);
        }
        return self;
    }

    pub fn destroy(self: *TsQueueModel) void {
        self.cell.deinit();
        self.ctx.deinit();
        self.allocator.destroy(self);
    }

    pub fn push(self: *TsQueueModel, value: Str) !PushOutcome {
        self.cell.tryPush(value) catch |err| return switch (err) {
            error.Full => PushOutcome.full,
            error.Closed => PushOutcome.closed,
        };
        return .ok;
    }

    pub fn pop(self: *TsQueueModel) !PopOutcome {
        const value = self.cell.tryPop() catch |err| return switch (err) {
            error.Empty => PopOutcome.empty,
            error.Closed => PopOutcome.closed,
        };
        return .{ .value = value };
    }

    pub fn close(self: *TsQueueModel) !void {
        self.cell.close();
    }

    fn batchBody(ptr: *anyopaque) void {
        const op: *BatchOp = @ptrCast(@alignCast(ptr));
        for (op.ops) |inner| {
            const value_node = cj.required(inner, "value") catch return;
            const value = cj.asStr(value_node) catch return;
            op.model.cell.tryPush(value) catch {};
        }
    }

    pub fn batchPush(self: *TsQueueModel, ops: []const Value) !void {
        var op = BatchOp{ .model = self, .ops = ops };
        self.ctx.batch(void, @ptrCast(&op), batchBody);
    }

    pub fn head(self: *TsQueueModel) !?Str {
        return self.cell.head();
    }
    pub fn len(self: *TsQueueModel) !usize {
        return self.cell.len();
    }
    pub fn isEmpty(self: *TsQueueModel) !bool {
        return self.cell.isEmpty();
    }
    pub fn isFull(self: *TsQueueModel) !bool {
        return self.cell.isFull();
    }
    pub fn isClosed(self: *TsQueueModel) !bool {
        return self.cell.isClosed();
    }
    pub fn elements(self: *TsQueueModel) []const Str {
        return self.cell.items();
    }
    pub fn versions(self: *TsQueueModel) QueueVersions {
        return self.cell.versions();
    }
};

const AsyncQueue = async_queue.AsyncQueueCell(Str, VecDeque);

const AsyncQueueModel = struct {
    allocator: std.mem.Allocator,
    ctx: AsyncQueue.Ctx,
    cell: AsyncQueue,

    pub const label = "async";

    pub fn create(allocator: std.mem.Allocator, capacity: ?usize) !*AsyncQueueModel {
        const self = try allocator.create(AsyncQueueModel);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .ctx = AsyncQueue.Ctx.init(allocator),
            .cell = undefined,
        };
        if (capacity) |c| {
            try async_queue.initBounded(Str, &self.cell, &self.ctx, c);
        } else {
            try async_queue.initUnbounded(Str, &self.cell, &self.ctx);
        }
        return self;
    }

    pub fn destroy(self: *AsyncQueueModel) void {
        self.cell.deinit();
        self.ctx.deinit();
        self.allocator.destroy(self);
    }

    pub fn push(self: *AsyncQueueModel, value: Str) !PushOutcome {
        self.cell.tryPush(value) catch |err| switch (err) {
            error.Full => return PushOutcome.full,
            error.Closed => return PushOutcome.closed,
            else => return err,
        };
        return .ok;
    }

    pub fn pop(self: *AsyncQueueModel) !PopOutcome {
        const value = self.cell.tryPop() catch |err| switch (err) {
            error.Empty => return PopOutcome.empty,
            error.Closed => return PopOutcome.closed,
            else => return err,
        };
        return .{ .value = value };
    }

    pub fn close(self: *AsyncQueueModel) !void {
        return self.cell.close();
    }

    /// No `batch()` here on purpose: `AsyncContext.setSource` enqueues a dependent
    /// and the `queued` flag bounds the queue to one entry per node, so N pushes
    /// already coalesce into one recompute per reached reader. The fixture asserts
    /// changed-or-not, not how many times.
    pub fn batchPush(self: *AsyncQueueModel, ops: []const Value) !void {
        for (ops) |inner| {
            _ = try self.push(try cj.asStr(try cj.required(inner, "value")));
        }
    }

    pub fn head(self: *AsyncQueueModel) !?Str {
        return self.cell.head();
    }
    pub fn len(self: *AsyncQueueModel) !usize {
        return self.cell.len();
    }
    pub fn isEmpty(self: *AsyncQueueModel) !bool {
        return self.cell.isEmpty();
    }
    pub fn isFull(self: *AsyncQueueModel) !bool {
        return self.cell.isFull();
    }
    pub fn isClosed(self: *AsyncQueueModel) !bool {
        return self.cell.isClosed();
    }
    pub fn elements(self: *AsyncQueueModel) []const Str {
        return self.cell.items();
    }
    pub fn versions(self: *AsyncQueueModel) QueueVersions {
        return self.cell.versions();
    }
};

// --- the queue replay ------------------------------------------------------

fn expectEqualOptStr(where: Str, want: ?Str, got: ?Str) !void {
    if (want == null and got == null) return;
    if (want == null or got == null) {
        std.debug.print("{s}: want {?s} got {?s}\n", .{ where, want, got });
        return error.TestExpectedEqual;
    }
    errdefer std.debug.print("{s}: string mismatch\n", .{where});
    try testing.expectEqualStrings(want.?, got.?);
}

/// `assertKeyWith` contexts for the QueueCell state block. Generic over the
/// flavor's model type, which is comptime here.
fn QueueStateCtx(comptime M: type) type {
    return struct {
        model: M,
        where: Str,

        const Self = @This();

        fn elements(self: Self, node: Value) !void {
            const want = try cj.asArray(node);
            const got = self.model.elements();
            try testing.expectEqual(want.len, got.len);
            for (want, got) |w, g| try testing.expectEqualStrings(try cj.asStr(w), g);
        }

        fn head(self: Self, node: Value) !void {
            const want: ?Str = switch (node) {
                .null => null,
                else => try cj.asStr(node),
            };
            try expectEqualOptStr(self.where, want, try self.model.head());
        }
    };
}

fn assertQueueState(model: anytype, expected: *cj.AssertionKeys, where: Str) !void {
    errdefer std.debug.print("queue state mismatch at {s}\n", .{where});

    const C = QueueStateCtx(@TypeOf(model));
    const ctx = C{ .model = model, .where = where };
    _ = try expected.assertKeyWithOpt("elements", ctx, C.elements);
    _ = try expected.assertKeyWithOpt("head", ctx, C.head);
    _ = try expected.assertKeyOpt("len", try model.len());
    _ = try expected.assertKeyOpt("is_empty", try model.isEmpty());
    _ = try expected.assertKeyOpt("is_full", try model.isFull());
    _ = try expected.assertKeyOpt("closed", try model.isClosed());
}

/// Assert the per-reader-kind matrix in BOTH directions. Only kinds the fixture
/// declares are asserted (an absent kind means "don't check"); the return value is
/// the number of flags asserted, so a caller can prove the matrix was not silently
/// absent.
/// `assertKeyWith` context for the QueueCell invalidation matrix. The flag count
/// comes back through `asserted`, since the check itself returns void.
const QueueInvalidationCtx = struct {
    before: QueueVersions,
    after: QueueVersions,
    where: Str,
    asserted: *usize,

    fn check(self: QueueInvalidationCtx, node: *cj.AssertionKeys) !void {
        self.asserted.* = try assertQueueInvalidation(self.before, self.after, node, self.where);
    }
};

fn assertQueueInvalidation(
    before: QueueVersions,
    after: QueueVersions,
    node: *cj.AssertionKeys,
    where: Str,
) !usize {
    _ = where;
    var asserted: usize = 0;
    inline for (.{ "head", "len", "is_empty", "is_full", "closed" }) |name| {
        const changed = @field(before, name) != @field(after, name);
        if (try node.assertKeyOpt(name, changed)) asserted += 1;
    }
    return asserted;
}

fn replayQueue(comptime Model: type, rel_path: Str) !ReplayCount {
    const allocator = testing.allocator;
    var parsed = (try cj.load(rel_path)) orelse return error.SkipZigTest;
    defer parsed.deinit();
    const fixture = parsed.value;
    // The fixture names the PRIMITIVE, not the execution model: the flavor axis
    // lives here in the runner.
    try testing.expectEqualStrings(
        "QueueCell",
        try cj.asStr(try cj.required(fixture, "model")),
    );

    const initial = try cj.required(fixture, "initial");
    const capacity: ?usize = if (cj.field(initial, "capacity")) |node| switch (node) {
        .null => null,
        else => try cj.asUsize(node),
    } else null;

    const model = try Model.create(allocator, capacity);
    defer model.destroy();

    for (try cj.arrayOr(initial, "elements")) |element| {
        try testing.expectEqual(PushOutcome.ok, try model.push(try cj.asStr(element)));
    }
    // `closed` in `initial` is rare but supported, and must be applied AFTER the
    // elements: a closed queue rejects every push.
    if (cj.field(initial, "closed")) |node| {
        if (try cj.asBool(node)) try model.close();
    }

    var counts: ReplayCount = .{};
    const steps = try cj.arrayOr(fixture, "steps");
    for (steps, 0..) |step, index| {
        const op = try cj.required(step, "op");
        const op_type = try cj.asStr(try cj.required(op, "type"));
        var expected = cj.AssertionKeys.init(
            "queue-family QueueCell expected",
            cj.field(step, "expected") orelse Value.null,
        );
        defer expected.finish() catch @panic("conformance assertion-key check failed");

        var where_buf: [192]u8 = undefined;
        const where = try std.fmt.bufPrint(&where_buf, "{s}/{s} step {d} ({s})", .{
            Model.label,
            rel_path,
            index,
            op_type,
        });

        const before = model.versions();
        var returned: ?Str = null;

        if (std.mem.eql(u8, op_type, "push") or std.mem.eql(u8, op_type, "try_push")) {
            const outcome = try model.push(try cj.asStr(try cj.required(op, "value")));
            returned = switch (outcome) {
                .ok => null,
                .full => "Full",
                .closed => "Closed",
            };
        } else if (std.mem.eql(u8, op_type, "pop") or std.mem.eql(u8, op_type, "try_pop")) {
            returned = switch (try model.pop()) {
                .value => |v| v,
                .empty => "Empty",
                .closed => "Closed",
            };
        } else if (std.mem.eql(u8, op_type, "close")) {
            try model.close();
        } else if (std.mem.eql(u8, op_type, "batch")) {
            try model.batchPush(try cj.arrayOr(op, "ops"));
        } else {
            std.debug.print("{s}: unknown QueueCell op `{s}`\n", .{ where, op_type });
            return error.UnknownOpType;
        }

        try assertQueueState(model, &expected, where);

        if (cj.field(step, "returns")) |want| {
            errdefer std.debug.print("returns mismatch at {s}\n", .{where});
            switch (want) {
                .null => try testing.expect(returned == null),
                else => try expectEqualOptStr(where, try cj.asStr(want), returned),
            }
        }

        const after = model.versions();
        var flags: usize = 0;
        _ = try expected.assertObjectWithOpt("invalidates", QueueInvalidationCtx{
            .before = before,
            .after = after,
            .where = where,
            .asserted = &flags,
        }, QueueInvalidationCtx.check);
        counts.flags += flags;
        counts.steps += 1;
    }
    return counts;
}

fn replayQueueCorpus(comptime Model: type) !ReplayCount {
    var totals: ReplayCount = .{};
    for (queue_fixtures) |rel_path| {
        totals.add(try replayQueue(Model, rel_path));
    }
    return totals;
}

// ===========================================================================
// TopicCell — three flavors
// ===========================================================================

fn parseDurability(raw: Str) !TopicDurability {
    if (std.mem.eql(u8, raw, "durable")) return .durable;
    if (std.mem.eql(u8, raw, "ephemeral")) return .ephemeral;
    return error.UnknownDurability;
}

const SyncTopic = queue.TopicCell(Str);

const SyncTopicModel = struct {
    allocator: std.mem.Allocator,
    ctx: *Context,
    cell: SyncTopic,

    pub const label = "single-threaded";

    /// Built through `initFromSnapshot` rather than by replaying
    /// `subscribe`/`publish`: the snapshot path is the only one that can seat a
    /// cursor at an arbitrary offset, which `topiccell_durable_replay_gc` starts
    /// from.
    pub fn create(allocator: std.mem.Allocator, saved: TopicSnapshot(Str)) !*SyncTopicModel {
        const ctx = try Context.init(allocator);
        errdefer ctx.deinit();
        const self = try allocator.create(SyncTopicModel);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .ctx = ctx,
            .cell = try SyncTopic.initFromSnapshot(ctx, saved),
        };
        return self;
    }

    pub fn destroy(self: *SyncTopicModel) void {
        self.cell.deinit();
        self.ctx.deinit();
        self.allocator.destroy(self);
    }

    pub fn publish(self: *SyncTopicModel, value: Str) !usize {
        return self.cell.publish(value);
    }
    pub fn subscribe(self: *SyncTopicModel, id: Str, durability: TopicDurability) !void {
        _ = try self.cell.subscribe(id, durability);
    }
    pub fn reconnect(self: *SyncTopicModel, id: Str) !void {
        return self.cell.reconnect(id);
    }
    pub fn disconnect(self: *SyncTopicModel, id: Str) !void {
        return self.cell.disconnect(id);
    }
    pub fn restart(self: *SyncTopicModel) !void {
        self.cell.restart();
    }
    pub fn gc(self: *SyncTopicModel) !usize {
        return self.cell.gc();
    }
    pub fn advance(self: *SyncTopicModel, id: Str, count: usize) !usize {
        return self.cell.advance(id, count);
    }
    pub fn readStream(self: *SyncTopicModel, id: Str) ![]const Str {
        return self.cell.readStream(id);
    }
    /// The REACTIVE read, so the matrix is a claim about an observable value and
    /// not only about a counter that happens to move.
    pub fn read(self: *SyncTopicModel, id: Str) !?Str {
        return (try self.cell.read(id)).get();
    }
    pub fn subscription(self: *SyncTopicModel, id: Str) ?TopicSubscriptionSnapshot {
        return self.cell.subscription(id);
    }
    pub fn subscriptionCount(self: *SyncTopicModel) usize {
        return self.cell.subscriptionCount();
    }
    pub fn baseOffset(self: *SyncTopicModel) usize {
        return self.cell.baseOffset();
    }
    pub fn items(self: *SyncTopicModel) []const Str {
        return self.cell.items();
    }
    pub fn readerVersion(self: *SyncTopicModel, id: Str) ?u64 {
        return self.cell.readerVersion(id);
    }
};

const TsTopic = thread_safe_queue.ThreadSafeTopicCell(Str);

const TsTopicModel = struct {
    allocator: std.mem.Allocator,
    ctx: ThreadSafeContext,
    cell: TsTopic,

    pub const label = "thread-safe";

    pub fn create(allocator: std.mem.Allocator, saved: TopicSnapshot(Str)) !*TsTopicModel {
        const self = try allocator.create(TsTopicModel);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .ctx = ThreadSafeContext.init(allocator),
            .cell = undefined,
        };
        try self.cell.initFromSnapshot(&self.ctx, saved);
        return self;
    }

    pub fn destroy(self: *TsTopicModel) void {
        self.cell.deinit();
        self.ctx.deinit();
        self.allocator.destroy(self);
    }

    pub fn publish(self: *TsTopicModel, value: Str) !usize {
        return self.cell.publishValue(value);
    }
    pub fn subscribe(self: *TsTopicModel, id: Str, durability: TopicDurability) !void {
        _ = try self.cell.subscribe(id, durability);
    }
    pub fn reconnect(self: *TsTopicModel, id: Str) !void {
        return self.cell.reconnect(id);
    }
    pub fn disconnect(self: *TsTopicModel, id: Str) !void {
        return self.cell.disconnect(id);
    }
    pub fn restart(self: *TsTopicModel) !void {
        self.cell.restart();
    }
    pub fn gc(self: *TsTopicModel) !usize {
        return self.cell.gc();
    }
    pub fn advance(self: *TsTopicModel, id: Str, count: usize) !usize {
        return self.cell.advance(id, count);
    }
    pub fn readStream(self: *TsTopicModel, id: Str) ![]const Str {
        return self.cell.readStream(id);
    }
    pub fn read(self: *TsTopicModel, id: Str) !?Str {
        return self.cell.read(id);
    }
    pub fn subscription(self: *TsTopicModel, id: Str) ?TopicSubscriptionSnapshot {
        return self.cell.subscription(id);
    }
    pub fn subscriptionCount(self: *TsTopicModel) usize {
        return self.cell.subscriptionCount();
    }
    pub fn baseOffset(self: *TsTopicModel) usize {
        return self.cell.baseOffset();
    }
    pub fn items(self: *TsTopicModel) []const Str {
        return self.cell.items();
    }
    pub fn readerVersion(self: *TsTopicModel, id: Str) ?u64 {
        return self.cell.readerVersion(id);
    }
};

const AsyncTopic = async_queue.AsyncTopicCell(Str);

const AsyncTopicModel = struct {
    allocator: std.mem.Allocator,
    ctx: AsyncTopic.Ctx,
    cell: AsyncTopic,

    pub const label = "async";

    pub fn create(allocator: std.mem.Allocator, saved: TopicSnapshot(Str)) !*AsyncTopicModel {
        const self = try allocator.create(AsyncTopicModel);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .ctx = AsyncTopic.Ctx.init(allocator),
            .cell = undefined,
        };
        try self.cell.initFromSnapshot(&self.ctx, saved);
        return self;
    }

    pub fn destroy(self: *AsyncTopicModel) void {
        self.cell.deinit();
        self.ctx.deinit();
        self.allocator.destroy(self);
    }

    pub fn publish(self: *AsyncTopicModel, value: Str) !usize {
        return self.cell.publishValue(value);
    }
    pub fn subscribe(self: *AsyncTopicModel, id: Str, durability: TopicDurability) !void {
        _ = try self.cell.subscribe(id, durability);
    }
    pub fn reconnect(self: *AsyncTopicModel, id: Str) !void {
        return self.cell.reconnect(id);
    }
    pub fn disconnect(self: *AsyncTopicModel, id: Str) !void {
        return self.cell.disconnect(id);
    }
    pub fn restart(self: *AsyncTopicModel) !void {
        self.cell.restart();
    }
    pub fn gc(self: *AsyncTopicModel) !usize {
        return self.cell.gc();
    }
    pub fn advance(self: *AsyncTopicModel, id: Str, count: usize) !usize {
        return self.cell.advance(id, count);
    }
    pub fn readStream(self: *AsyncTopicModel, id: Str) ![]const Str {
        return self.cell.readStream(id);
    }
    pub fn read(self: *AsyncTopicModel, id: Str) !?Str {
        return self.cell.read(id);
    }
    pub fn subscription(self: *AsyncTopicModel, id: Str) ?TopicSubscriptionSnapshot {
        return self.cell.subscription(id);
    }
    pub fn subscriptionCount(self: *AsyncTopicModel) usize {
        return self.cell.subscriptionCount();
    }
    pub fn baseOffset(self: *AsyncTopicModel) usize {
        return self.cell.baseOffset();
    }
    pub fn items(self: *AsyncTopicModel) []const Str {
        return self.cell.items();
    }
    pub fn readerVersion(self: *AsyncTopicModel, id: Str) ?u64 {
        return self.cell.readerVersion(id);
    }
};

// --- the topic replay ------------------------------------------------------

/// Every subscriber id the fixture ever mentions, in first-seen order.
///
/// Reader versions have to be sampled before each step for ids that may not exist
/// yet (a `subscribe` step) or may stop existing (an ephemeral `disconnect`
/// removes the subscription outright), so the id set comes from the fixture rather
/// than from the live cell.
fn collectSubscriberIds(
    ids: *std.ArrayList(Str),
    allocator: std.mem.Allocator,
    fixture: Value,
) !void {
    const add = struct {
        fn call(list: *std.ArrayList(Str), alloc: std.mem.Allocator, id: Str) !void {
            for (list.items) |seen| if (std.mem.eql(u8, seen, id)) return;
            try list.append(alloc, id);
        }
    };
    if (cj.field(try cj.required(fixture, "initial"), "subscriptions")) |node| {
        switch (node) {
            .object => |object| {
                var it = object.iterator();
                while (it.next()) |entry| try add.call(ids, allocator, entry.key_ptr.*);
            },
            else => {},
        }
    }
    for (try cj.arrayOr(fixture, "steps")) |step| {
        if (cj.field(try cj.required(step, "op"), "subscriber")) |id| {
            try add.call(ids, allocator, try cj.asStr(id));
        }
    }
}

/// `assertKeyWith` contexts for the TopicCell state block.
fn TopicStateCtx(comptime M: type) type {
    return struct {
        model: M,
        where: Str,

        const Self = @This();

        fn elements(self: Self, node: Value) !void {
            const want = try cj.asArray(node);
            const got = self.model.items();
            try testing.expectEqual(want.len, got.len);
            for (want, got) |w, g| try testing.expectEqualStrings(try cj.asStr(w), g);
        }

        /// Subscriptions are asserted as a SET, not just per named id: a step
        /// that must REMOVE an ephemeral subscription is only observable if a
        /// surviving extra entry fails, so the count is part of the claim.
        fn subscriptions(self: Self, node: *cj.AssertionKeys) !void {
            const object = switch (node.object) {
                .object => |o| o,
                else => return error.ExpectedObject,
            };
            var want_count: usize = 0;
            var it = object.iterator();
            while (it.next()) |entry| {
                want_count += 1;
                const got = self.model.subscription(entry.key_ptr.*) orelse {
                    std.debug.print(
                        "{s}: subscription {s} is absent\n",
                        .{ self.where, entry.key_ptr.* },
                    );
                    return error.MissingSubscription;
                };
                var subscription = try node.sub(entry.key_ptr.*);
                try subscription.assertKey("cursor", got.cursor);
                try subscription.assertKey("durability", got.durability);
                try subscription.assertKey("connected", got.connected);
                try subscription.finish();
            }
            try testing.expectEqual(want_count, self.model.subscriptionCount());
        }

        /// `reads` is the cursor's retained tail per subscriber. Asserted twice:
        /// the whole suffix non-reactively, and its head THROUGH THE REACTIVE
        /// READER — a shell that under-invalidated fails on the second even when
        /// the first agrees.
        fn reads(self: Self, node: *cj.AssertionKeys) !void {
            const object = switch (node.object) {
                .object => |o| o,
                else => return error.ExpectedObject,
            };
            var it = object.iterator();
            while (it.next()) |entry| {
                const want_stream = try cj.asArray(entry.value_ptr.*);
                const got_stream = try self.model.readStream(entry.key_ptr.*);
                try node.assertKeyWith(entry.key_ptr.*, got_stream, struct {
                    fn check(actual: []const Str, expected: Value) !void {
                        const want = try cj.asArray(expected);
                        try testing.expectEqual(want.len, actual.len);
                        for (want, actual) |w, got| {
                            try testing.expectEqualStrings(try cj.asStr(w), got);
                        }
                    }
                }.check);
                const want_head: ?Str = if (want_stream.len == 0)
                    null
                else
                    try cj.asStr(want_stream[0]);
                try expectEqualOptStr(self.where, want_head, try self.model.read(entry.key_ptr.*));
            }
        }
    };
}

fn assertTopicState(model: anytype, expected: *cj.AssertionKeys, where: Str) !void {
    errdefer std.debug.print("topic state mismatch at {s}\n", .{where});

    const C = TopicStateCtx(@TypeOf(model));
    const ctx = C{ .model = model, .where = where };

    try expected.assertKey("base_offset", model.baseOffset());
    if (!try expected.assertKeyWithOpt("elements", ctx, C.elements)) {
        try testing.expectEqual(@as(usize, 0), model.items().len);
    }
    if (!try expected.assertObjectWithOpt("subscriptions", ctx, C.subscriptions)) {
        try testing.expectEqual(@as(usize, 0), model.subscriptionCount());
    }
    _ = try expected.assertObjectWithOpt("reads", ctx, C.reads);
}

fn replayTopic(comptime Model: type, rel_path: Str) !ReplayCount {
    const allocator = testing.allocator;
    var parsed = (try cj.load(rel_path)) orelse return error.SkipZigTest;
    defer parsed.deinit();
    const fixture = parsed.value;
    try testing.expectEqualStrings(
        "TopicCell",
        try cj.asStr(try cj.required(fixture, "model")),
    );

    var ids: std.ArrayList(Str) = .empty;
    defer ids.deinit(allocator);
    try collectSubscriberIds(&ids, allocator, fixture);

    // Build the fixture's `initial` state as a snapshot.
    const initial = try cj.required(fixture, "initial");
    const elements_json = try cj.arrayOr(initial, "elements");
    const elements = try allocator.alloc(Str, elements_json.len);
    defer allocator.free(elements);
    for (elements_json, 0..) |element, index| elements[index] = try cj.asStr(element);

    var subs: std.ArrayList(TopicSubscriptionSnapshot) = .empty;
    defer subs.deinit(allocator);
    if (cj.field(initial, "subscriptions")) |node| {
        switch (node) {
            .object => |object| {
                var it = object.iterator();
                while (it.next()) |entry| {
                    try subs.append(allocator, .{
                        .subscriber_id = entry.key_ptr.*,
                        .cursor = try cj.asUsize(try cj.required(entry.value_ptr.*, "cursor")),
                        .durability = try parseDurability(
                            try cj.asStr(try cj.required(entry.value_ptr.*, "durability")),
                        ),
                        .connected = try cj.asBool(
                            try cj.required(entry.value_ptr.*, "connected"),
                        ),
                    });
                }
            },
            else => {},
        }
    }

    const model = try Model.create(allocator, .{
        .allocator = allocator,
        .base_offset = try cj.asUsize(try cj.required(initial, "base_offset")),
        .elements = elements,
        .subscriptions = subs.items,
    });
    defer model.destroy();

    const before = try allocator.alloc(?u64, ids.items.len);
    defer allocator.free(before);

    var counts: ReplayCount = .{};
    const steps = try cj.arrayOr(fixture, "steps");
    for (steps, 0..) |step, index| {
        const op = try cj.required(step, "op");
        const op_type = try cj.asStr(try cj.required(op, "type"));
        var expected = cj.AssertionKeys.init("queue-family expected", try cj.required(step, "expected"));
        defer expected.finish() catch @panic("conformance assertion-key check failed");

        var where_buf: [192]u8 = undefined;
        const where = try std.fmt.bufPrint(&where_buf, "{s}/{s} step {d} ({s})", .{
            Model.label,
            rel_path,
            index,
            op_type,
        });

        for (ids.items, 0..) |id, slot| before[slot] = model.readerVersion(id);

        var returned_string: ?Str = null;
        var returned_usize: ?usize = null;
        var returned_is_null = false;

        if (std.mem.eql(u8, op_type, "publish")) {
            _ = try model.publish(try cj.asStr(try cj.required(op, "value")));
        } else if (std.mem.eql(u8, op_type, "subscribe")) {
            try model.subscribe(
                try cj.asStr(try cj.required(op, "subscriber")),
                try parseDurability(try cj.asStr(try cj.required(op, "durability"))),
            );
        } else if (std.mem.eql(u8, op_type, "reconnect")) {
            try model.reconnect(try cj.asStr(try cj.required(op, "subscriber")));
        } else if (std.mem.eql(u8, op_type, "disconnect")) {
            try model.disconnect(try cj.asStr(try cj.required(op, "subscriber")));
        } else if (std.mem.eql(u8, op_type, "restart")) {
            try model.restart();
        } else if (std.mem.eql(u8, op_type, "gc")) {
            returned_usize = try model.gc();
        } else if (std.mem.eql(u8, op_type, "advance")) {
            // The corpus spells `advance` as "consume one element and tell me
            // which"; this family's `advance` moves the cursor by `count` and
            // returns the new cursor. Read the element AT the cursor first, then
            // move by one: a no-op advance (offline, or already at the tail) must
            // report `null` rather than the element it did not consume.
            const subscriber = try cj.asStr(try cj.required(op, "subscriber"));
            const stream = try model.readStream(subscriber);
            const head: ?Str = if (stream.len == 0) null else stream[0];
            const cursor_before = (model.subscription(subscriber) orelse
                return error.MissingSubscription).cursor;
            const cursor_after = try model.advance(subscriber, 1);
            if (cursor_after == cursor_before) {
                returned_is_null = true;
            } else {
                returned_string = head;
            }
        } else {
            std.debug.print("{s}: unknown TopicCell op `{s}`\n", .{ where, op_type });
            return error.UnknownOpType;
        }

        try assertTopicState(model, &expected, where);

        if (cj.field(step, "returns")) |want| {
            errdefer std.debug.print("returns mismatch at {s}\n", .{where});
            switch (want) {
                .null => try testing.expect(returned_is_null or returned_string == null),
                .string => |s| try testing.expectEqualStrings(s, returned_string orelse ""),
                else => try testing.expectEqual(try cj.asUsize(want), returned_usize orelse 0),
            }
        }

        // The reader-kind claim, both directions, per subscriber.
        const TopicInvCtx = struct {
            model: @TypeOf(model),
            ids: []const Str,
            before: []const ?u64,
            where: Str,
            flags: *usize,

            fn check(self: @This(), node: *cj.AssertionKeys) !void {
                const object = switch (node.object) {
                    .object => |o| o,
                    else => return error.ExpectedObject,
                };
                var it = object.iterator();
                while (it.next()) |entry| {
                    const id = entry.key_ptr.*;
                    var slot: usize = 0;
                    while (slot < self.ids.len and
                        !std.mem.eql(u8, self.ids[slot], id)) : (slot += 1)
                    {}
                    if (slot == self.ids.len) return error.UnknownFixtureSubscriber;
                    const after = self.model.readerVersion(id);
                    const changed = if (after) |now|
                        (self.before[slot] == null or self.before[slot].? != now)
                    else
                        // The subscription is gone. Its reader was disposed, so
                        // every reader of it is invalid — a stronger observation
                        // than a version bump, and the only one available for a
                        // removed ephemeral.
                        self.before[slot] != null;
                    try node.assertKey(id, changed);
                    self.flags.* += 1;
                }
            }
        };
        _ = try expected.assertObjectWithOpt("invalidates", TopicInvCtx{
            .model = model,
            .ids = ids.items,
            .before = before,
            .where = where,
            .flags = &counts.flags,
        }, TopicInvCtx.check);
        counts.steps += 1;
    }
    return counts;
}

fn replayTopicCorpus(comptime Model: type) !ReplayCount {
    var totals: ReplayCount = .{};
    for (topic_fixtures) |rel_path| {
        totals.add(try replayTopic(Model, rel_path));
    }
    return totals;
}

// ===========================================================================
// WorkQueueCell — three flavors
// ===========================================================================

const SyncWorkQueue = work_queue.WorkQueueCell(Str);
const Delivery = SyncWorkQueue.Delivery;

const SyncWorkQueueModel = struct {
    allocator: std.mem.Allocator,
    ctx: *Context,
    cell: SyncWorkQueue,

    pub const label = "single-threaded";

    pub fn create(
        allocator: std.mem.Allocator,
        visibility_timeout: u64,
        max_deliveries: u64,
    ) !*SyncWorkQueueModel {
        const ctx = try Context.init(allocator);
        errdefer ctx.deinit();
        const self = try allocator.create(SyncWorkQueueModel);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .ctx = ctx,
            .cell = try SyncWorkQueue.init(ctx, visibility_timeout, max_deliveries),
        };
        return self;
    }

    pub fn destroy(self: *SyncWorkQueueModel) void {
        self.cell.deinit();
        self.ctx.deinit();
        self.allocator.destroy(self);
    }

    pub fn push(self: *SyncWorkQueueModel, value: Str) !u64 {
        return self.cell.push(value);
    }
    pub fn claim(self: *SyncWorkQueueModel, worker: Str, now: u64) !?Delivery {
        return self.cell.claim(worker, now);
    }
    pub fn ack(self: *SyncWorkQueueModel, worker: Str, delivery_id: u64) !bool {
        return self.cell.ack(worker, delivery_id);
    }
    pub fn nack(self: *SyncWorkQueueModel, worker: Str, delivery_id: u64) !bool {
        return self.cell.nack(worker, delivery_id);
    }
    pub fn reapExpired(self: *SyncWorkQueueModel, now: u64) !usize {
        return self.cell.reapExpired(now);
    }
    pub fn pendingLen(self: *SyncWorkQueueModel) !usize {
        return self.cell.pendingLen().get();
    }
    pub fn isEmpty(self: *SyncWorkQueueModel) !bool {
        return self.cell.isEmpty().get();
    }
    pub fn inFlightLen(self: *SyncWorkQueueModel) !usize {
        return self.cell.inFlightLen().get();
    }
    pub fn deadLetterLen(self: *SyncWorkQueueModel) !usize {
        return self.cell.deadLetterLen().get();
    }
    pub fn pendingItems(self: *SyncWorkQueueModel) []const SyncWorkQueue.Item {
        return self.cell.pendingItems();
    }
    pub fn deadLetterItems(self: *SyncWorkQueueModel) []const SyncWorkQueue.DeadLetter {
        return self.cell.deadLetterItems();
    }
    pub fn inFlightDeliveries(
        self: *SyncWorkQueueModel,
        allocator: std.mem.Allocator,
    ) ![]Delivery {
        return self.cell.inFlightDeliveries(allocator);
    }
    pub fn versions(self: *SyncWorkQueueModel) WorkQueueVersions {
        return self.cell.versions();
    }
};

const TsWorkQueue = thread_safe_queue.ThreadSafeWorkQueueCell(Str);

const TsWorkQueueModel = struct {
    allocator: std.mem.Allocator,
    ctx: ThreadSafeContext,
    cell: TsWorkQueue,

    pub const label = "thread-safe";

    pub fn create(
        allocator: std.mem.Allocator,
        visibility_timeout: u64,
        max_deliveries: u64,
    ) !*TsWorkQueueModel {
        const self = try allocator.create(TsWorkQueueModel);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .ctx = ThreadSafeContext.init(allocator),
            .cell = undefined,
        };
        try self.cell.init(&self.ctx, visibility_timeout, max_deliveries);
        return self;
    }

    pub fn destroy(self: *TsWorkQueueModel) void {
        self.cell.deinit();
        self.ctx.deinit();
        self.allocator.destroy(self);
    }

    pub fn push(self: *TsWorkQueueModel, value: Str) !u64 {
        return self.cell.push(value);
    }
    pub fn claim(self: *TsWorkQueueModel, worker: Str, now: u64) !?Delivery {
        return self.cell.claim(worker, now);
    }
    pub fn ack(self: *TsWorkQueueModel, worker: Str, delivery_id: u64) !bool {
        return self.cell.ack(worker, delivery_id);
    }
    pub fn nack(self: *TsWorkQueueModel, worker: Str, delivery_id: u64) !bool {
        return self.cell.nack(worker, delivery_id);
    }
    pub fn reapExpired(self: *TsWorkQueueModel, now: u64) !usize {
        return self.cell.reapExpired(now);
    }
    pub fn pendingLen(self: *TsWorkQueueModel) !usize {
        return self.cell.pendingLen();
    }
    pub fn isEmpty(self: *TsWorkQueueModel) !bool {
        return self.cell.isEmpty();
    }
    pub fn inFlightLen(self: *TsWorkQueueModel) !usize {
        return self.cell.inFlightLen();
    }
    pub fn deadLetterLen(self: *TsWorkQueueModel) !usize {
        return self.cell.deadLetterLen();
    }
    pub fn pendingItems(self: *TsWorkQueueModel) []const TsWorkQueue.Item {
        return self.cell.pendingItems();
    }
    pub fn deadLetterItems(self: *TsWorkQueueModel) []const TsWorkQueue.DeadLetter {
        return self.cell.deadLetterItems();
    }
    pub fn inFlightDeliveries(
        self: *TsWorkQueueModel,
        allocator: std.mem.Allocator,
    ) ![]Delivery {
        return self.cell.inFlightDeliveries(allocator);
    }
    pub fn versions(self: *TsWorkQueueModel) WorkQueueVersions {
        return self.cell.versions();
    }
};

const AsyncWorkQueue = async_queue.AsyncWorkQueueCell(Str);

const AsyncWorkQueueModel = struct {
    allocator: std.mem.Allocator,
    ctx: AsyncWorkQueue.Ctx,
    cell: AsyncWorkQueue,

    pub const label = "async";

    pub fn create(
        allocator: std.mem.Allocator,
        visibility_timeout: u64,
        max_deliveries: u64,
    ) !*AsyncWorkQueueModel {
        const self = try allocator.create(AsyncWorkQueueModel);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .ctx = AsyncWorkQueue.Ctx.init(allocator),
            .cell = undefined,
        };
        try self.cell.init(&self.ctx, visibility_timeout, max_deliveries);
        return self;
    }

    pub fn destroy(self: *AsyncWorkQueueModel) void {
        self.cell.deinit();
        self.ctx.deinit();
        self.allocator.destroy(self);
    }

    pub fn push(self: *AsyncWorkQueueModel, value: Str) !u64 {
        return self.cell.push(value);
    }
    pub fn claim(self: *AsyncWorkQueueModel, worker: Str, now: u64) !?Delivery {
        return self.cell.claim(worker, now);
    }
    pub fn ack(self: *AsyncWorkQueueModel, worker: Str, delivery_id: u64) !bool {
        return self.cell.ack(worker, delivery_id);
    }
    pub fn nack(self: *AsyncWorkQueueModel, worker: Str, delivery_id: u64) !bool {
        return self.cell.nack(worker, delivery_id);
    }
    pub fn reapExpired(self: *AsyncWorkQueueModel, now: u64) !usize {
        return self.cell.reapExpired(now);
    }
    pub fn pendingLen(self: *AsyncWorkQueueModel) !usize {
        return self.cell.pendingLen();
    }
    pub fn isEmpty(self: *AsyncWorkQueueModel) !bool {
        return self.cell.isEmpty();
    }
    pub fn inFlightLen(self: *AsyncWorkQueueModel) !usize {
        return self.cell.inFlightLen();
    }
    pub fn deadLetterLen(self: *AsyncWorkQueueModel) !usize {
        return self.cell.deadLetterLen();
    }
    pub fn pendingItems(self: *AsyncWorkQueueModel) []const AsyncWorkQueue.Item {
        return self.cell.pendingItems();
    }
    pub fn deadLetterItems(self: *AsyncWorkQueueModel) []const AsyncWorkQueue.DeadLetter {
        return self.cell.deadLetterItems();
    }
    pub fn inFlightDeliveries(
        self: *AsyncWorkQueueModel,
        allocator: std.mem.Allocator,
    ) ![]Delivery {
        return self.cell.inFlightDeliveries(allocator);
    }
    pub fn versions(self: *AsyncWorkQueueModel) WorkQueueVersions {
        return self.cell.versions();
    }
};

// --- the work-queue replay -------------------------------------------------

/// `assertKeyWith` contexts for the WorkQueueCell state block.
fn WorkQueueStateCtx(comptime M: type) type {
    return struct {
        model: M,
        where: Str,

        const Self = @This();

        fn pending(self: Self, node: Value) !void {
            const want_pending = try cj.asArray(node);
            const got_pending = self.model.pendingItems();
            try testing.expectEqual(want_pending.len, got_pending.len);
            for (want_pending, got_pending) |want, got| {
                try testing.expectEqual(try cj.asU64(try cj.required(want, "item_id")), got.item_id);
                try testing.expectEqualStrings(try cj.asStr(try cj.required(want, "value")), got.value);
                try testing.expectEqual(try cj.asU64(try cj.required(want, "attempts")), got.attempts);
            }
        }

        /// In-flight deliveries are keyed by delivery id in a hash map here, so
        /// the fixture's array order is not this binding's order. Match by
        /// delivery id and assert the count, which pins the same set without
        /// inventing an ordering the primitive does not promise.
        fn inFlight(self: Self, node: Value) !void {
            const want_in_flight = try cj.asArray(node);
            const got_in_flight = try self.model.inFlightDeliveries(testing.allocator);
            defer testing.allocator.free(got_in_flight);
            try testing.expectEqual(want_in_flight.len, got_in_flight.len);
            for (want_in_flight) |want| {
                const delivery_id = try cj.asU64(try cj.required(want, "delivery_id"));
                const found = for (got_in_flight) |got| {
                    if (got.delivery_id == delivery_id) break got;
                } else {
                    std.debug.print(
                        "{s}: delivery {d} is not in flight\n",
                        .{ self.where, delivery_id },
                    );
                    return error.MissingDelivery;
                };
                try testing.expectEqual(try cj.asU64(try cj.required(want, "item_id")), found.item_id);
                try testing.expectEqualStrings(try cj.asStr(try cj.required(want, "value")), found.value);
                try testing.expectEqualStrings(
                    try cj.asStr(try cj.required(want, "worker")),
                    found.worker,
                );
                try testing.expectEqual(try cj.asU64(try cj.required(want, "attempt")), found.attempt);
                try testing.expectEqual(try cj.asU64(try cj.required(want, "deadline")), found.deadline);
            }
        }

        fn deadLetters(self: Self, node: Value) !void {
            const want_dead = try cj.asArray(node);
            const got_dead = self.model.deadLetterItems();
            try testing.expectEqual(want_dead.len, got_dead.len);
            for (want_dead, got_dead) |want, got| {
                try testing.expectEqual(try cj.asU64(try cj.required(want, "item_id")), got.item_id);
                try testing.expectEqualStrings(try cj.asStr(try cj.required(want, "value")), got.value);
                try testing.expectEqual(try cj.asU64(try cj.required(want, "attempts")), got.attempts);
                const want_reason = try cj.asStr(try cj.required(want, "reason"));
                const got_reason = switch (got.reason) {
                    .nack => "nack",
                    .expired => "expired",
                };
                try testing.expectEqualStrings(want_reason, got_reason);
            }
        }

        /// `reads` are the four reader kinds. Reading them here (not only their
        /// version counters) is what makes the invalidation matrix a claim about
        /// an observable value rather than about a counter that happens to move.
        fn reads(self: Self, node: *cj.AssertionKeys) !void {
            try node.assertKey("pending_len", try self.model.pendingLen());
            try node.assertKey("is_empty", try self.model.isEmpty());
            try node.assertKey("in_flight_len", try self.model.inFlightLen());
            try node.assertKey("dead_letter_len", try self.model.deadLetterLen());
        }
    };
}

fn assertWorkQueueState(model: anytype, expected: *cj.AssertionKeys, where: Str) !void {
    errdefer std.debug.print("work-queue state mismatch at {s}\n", .{where});

    const C = WorkQueueStateCtx(@TypeOf(model));
    const ctx = C{ .model = model, .where = where };

    if (!try expected.assertKeyWithOpt("pending", ctx, C.pending)) {
        try testing.expectEqual(@as(usize, 0), model.pendingItems().len);
    }
    if (!try expected.assertKeyWithOpt("in_flight", ctx, C.inFlight)) {
        const got = try model.inFlightDeliveries(testing.allocator);
        defer testing.allocator.free(got);
        try testing.expectEqual(@as(usize, 0), got.len);
    }
    if (!try expected.assertKeyWithOpt("dead_letters", ctx, C.deadLetters)) {
        try testing.expectEqual(@as(usize, 0), model.deadLetterItems().len);
    }
    _ = try expected.assertObjectWithOpt("reads", ctx, C.reads);
}

/// `assertKeyWith` context for the WorkQueueCell invalidation matrix. The flag
/// count comes back through `asserted`, since the check itself returns void.
const WorkQueueInvalidationCtx = struct {
    before: WorkQueueVersions,
    after: WorkQueueVersions,
    where: Str,
    asserted: *usize,

    fn check(self: WorkQueueInvalidationCtx, node: *cj.AssertionKeys) !void {
        self.asserted.* = try assertWorkQueueInvalidation(
            self.before,
            self.after,
            node,
            self.where,
        );
    }
};

fn assertWorkQueueInvalidation(
    before: WorkQueueVersions,
    after: WorkQueueVersions,
    invalidates: *cj.AssertionKeys,
    where: Str,
) !usize {
    _ = where;
    var asserted: usize = 0;
    inline for (.{ "pending_len", "is_empty", "in_flight_len", "dead_letter_len" }) |name| {
        const changed = @field(before, name) != @field(after, name);
        try invalidates.assertKey(name, changed);
        asserted += 1;
    }
    return asserted;
}

fn replayWorkQueue(comptime Model: type, rel_path: Str) !ReplayCount {
    const allocator = testing.allocator;
    var parsed = (try cj.load(rel_path)) orelse return error.SkipZigTest;
    defer parsed.deinit();
    const fixture = parsed.value;
    try testing.expectEqualStrings(
        "WorkQueueCell",
        try cj.asStr(try cj.required(fixture, "model")),
    );

    // The lease configuration comes from the fixture, not from this file. It used
    // to be a runner parameter, which is drift by construction: the corpus could
    // retune a lease and this binding would keep replaying the old one and stay
    // green.
    const config = try cj.required(fixture, "config");
    const model = try Model.create(
        allocator,
        try cj.asU64(try cj.required(config, "visibility_timeout")),
        try cj.asU64(try cj.required(config, "max_deliveries")),
    );
    defer model.destroy();

    // Both canonical fixtures start empty; there is no snapshot constructor to seat
    // pending/in-flight state, and no fixture needs one. Fail loudly rather than
    // silently replaying from the wrong start if that ever changes.
    const initial = try cj.required(fixture, "initial");
    for ([_]Str{ "pending", "in_flight", "dead_letters" }) |key| {
        try testing.expectEqual(@as(usize, 0), (try cj.arrayOr(initial, key)).len);
    }

    var counts: ReplayCount = .{};
    const steps = try cj.arrayOr(fixture, "steps");
    for (steps, 0..) |step, index| {
        const op = try cj.required(step, "op");
        const op_type = try cj.asStr(try cj.required(op, "type"));
        var expected = cj.AssertionKeys.init("queue-family expected", try cj.required(step, "expected"));
        defer expected.finish() catch @panic("conformance assertion-key check failed");

        var where_buf: [192]u8 = undefined;
        const where = try std.fmt.bufPrint(&where_buf, "{s}/{s} step {d} ({s})", .{
            Model.label,
            rel_path,
            index,
            op_type,
        });

        const before = model.versions();

        var returned_u64: ?u64 = null;
        var returned_bool: ?bool = null;
        var returned_delivery: ?Delivery = null;
        var returned_is_null = false;

        if (std.mem.eql(u8, op_type, "push")) {
            returned_u64 = try model.push(try cj.asStr(try cj.required(op, "value")));
        } else if (std.mem.eql(u8, op_type, "claim")) {
            const claimed = try model.claim(
                try cj.asStr(try cj.required(op, "worker")),
                try cj.asU64(try cj.required(op, "now")),
            );
            if (claimed) |delivery| returned_delivery = delivery else returned_is_null = true;
        } else if (std.mem.eql(u8, op_type, "ack")) {
            returned_bool = try model.ack(
                try cj.asStr(try cj.required(op, "worker")),
                try cj.asU64(try cj.required(op, "delivery_id")),
            );
        } else if (std.mem.eql(u8, op_type, "nack")) {
            returned_bool = try model.nack(
                try cj.asStr(try cj.required(op, "worker")),
                try cj.asU64(try cj.required(op, "delivery_id")),
            );
        } else if (std.mem.eql(u8, op_type, "reap_expired")) {
            returned_u64 = @intCast(try model.reapExpired(
                try cj.asU64(try cj.required(op, "now")),
            ));
        } else {
            std.debug.print("{s}: unknown WorkQueueCell op `{s}`\n", .{ where, op_type });
            return error.UnknownOpType;
        }

        try assertWorkQueueState(model, &expected, where);

        if (cj.field(step, "returns")) |want| {
            errdefer std.debug.print("returns mismatch at {s}\n", .{where});
            switch (want) {
                .null => try testing.expect(returned_is_null),
                .bool => |b| try testing.expectEqual(b, returned_bool orelse !b),
                .integer, .number_string => try testing.expectEqual(
                    try cj.asU64(want),
                    returned_u64 orelse return error.ExpectedIntegerReturn,
                ),
                // A `claim` returns the whole delivery record; every field is part
                // of the contract, `attempt` and `deadline` especially — they are
                // what the redelivery and lease laws are stated over.
                .object => {
                    const delivery = returned_delivery orelse return error.ExpectedDelivery;
                    try testing.expectEqual(
                        try cj.asU64(try cj.required(want, "delivery_id")),
                        delivery.delivery_id,
                    );
                    try testing.expectEqual(
                        try cj.asU64(try cj.required(want, "item_id")),
                        delivery.item_id,
                    );
                    try testing.expectEqualStrings(
                        try cj.asStr(try cj.required(want, "value")),
                        delivery.value,
                    );
                    try testing.expectEqualStrings(
                        try cj.asStr(try cj.required(want, "worker")),
                        delivery.worker,
                    );
                    try testing.expectEqual(
                        try cj.asU64(try cj.required(want, "attempt")),
                        delivery.attempt,
                    );
                    try testing.expectEqual(
                        try cj.asU64(try cj.required(want, "deadline")),
                        delivery.deadline,
                    );
                },
                else => return error.UnsupportedReturnShape,
            }
        }

        const after = model.versions();
        var flags: usize = 0;
        try expected.assertObjectWith("invalidates", WorkQueueInvalidationCtx{
            .before = before,
            .after = after,
            .where = where,
            .asserted = &flags,
        }, WorkQueueInvalidationCtx.check);
        counts.flags += flags;
        counts.steps += 1;
    }
    return counts;
}

fn replayWorkQueueCorpus(comptime Model: type) !ReplayCount {
    var totals: ReplayCount = .{};
    for (work_queue_fixtures) |rel_path| {
        totals.add(try replayWorkQueue(Model, rel_path));
    }
    return totals;
}

// ===========================================================================
// The gates — nine replays, exact counts
// ===========================================================================

/// Every `queuecell_*` step declares at least `head` and `len`; most declare all
/// five. Every `workqueue_*` step declares all four. The floor exists only to
/// catch a matrix that went silently absent — the equality assertions on step
/// counts are the real gate.
const queue_flags_floor = 2;
const work_queue_flags_per_step = 4;

fn expectQueueCorpus(comptime Model: type) !void {
    const counts = try replayQueueCorpus(Model);
    // A positive count is the only thing that proves this binary drove the
    // fixtures; their presence on disk proves only that they exist.
    try testing.expect(counts.steps > 0);
    try testing.expectEqual(@as(usize, queue_corpus_steps), counts.steps);
    try testing.expect(counts.flags >= counts.steps * queue_flags_floor);
}

test "lazily/queue-family conformance: QueueCell replays the corpus (single-threaded)" {
    if (!corpusPresent()) return error.SkipZigTest;
    try expectQueueCorpus(SyncQueueModel);
}

test "lazily/queue-family conformance: QueueCell replays the corpus (thread-safe)" {
    if (!corpusPresent()) return error.SkipZigTest;
    try expectQueueCorpus(TsQueueModel);
}

test "lazily/queue-family conformance: QueueCell replays the corpus (async)" {
    if (!corpusPresent()) return error.SkipZigTest;
    try expectQueueCorpus(AsyncQueueModel);
}

fn expectTopicCorpus(comptime Model: type) !void {
    const counts = try replayTopicCorpus(Model);
    try testing.expect(counts.steps > 0);
    try testing.expectEqual(@as(usize, topic_corpus_steps), counts.steps);
    try testing.expect(counts.flags > 0);
}

test "lazily/queue-family conformance: TopicCell replays the corpus (single-threaded)" {
    if (!corpusPresent()) return error.SkipZigTest;
    try expectTopicCorpus(SyncTopicModel);
}

test "lazily/queue-family conformance: TopicCell replays the corpus (thread-safe)" {
    if (!corpusPresent()) return error.SkipZigTest;
    try expectTopicCorpus(TsTopicModel);
}

test "lazily/queue-family conformance: TopicCell replays the corpus (async)" {
    if (!corpusPresent()) return error.SkipZigTest;
    try expectTopicCorpus(AsyncTopicModel);
}

fn expectWorkQueueCorpus(comptime Model: type) !void {
    const counts = try replayWorkQueueCorpus(Model);
    try testing.expect(counts.steps > 0);
    try testing.expectEqual(@as(usize, work_queue_corpus_steps), counts.steps);
    try testing.expectEqual(counts.steps * work_queue_flags_per_step, counts.flags);
}

test "lazily/queue-family conformance: WorkQueueCell replays the corpus (single-threaded)" {
    if (!corpusPresent()) return error.SkipZigTest;
    try expectWorkQueueCorpus(SyncWorkQueueModel);
}

test "lazily/queue-family conformance: WorkQueueCell replays the corpus (thread-safe)" {
    if (!corpusPresent()) return error.SkipZigTest;
    try expectWorkQueueCorpus(TsWorkQueueModel);
}

test "lazily/queue-family conformance: WorkQueueCell replays the corpus (async)" {
    if (!corpusPresent()) return error.SkipZigTest;
    try expectWorkQueueCorpus(AsyncWorkQueueModel);
}

test "lazily/queue-family conformance: the corpus totals are what this file claims" {
    if (!corpusPresent()) return error.SkipZigTest;
    // The nine tests above assert against the constants; this asserts the
    // constants against the corpus, so a fixture gaining or losing a step is a
    // failure here rather than nine silent drifts.
    const totals = struct {
        fn call(fixtures: []const Str) !usize {
            var total: usize = 0;
            for (fixtures) |rel_path| {
                var parsed = (try cj.load(rel_path)) orelse return error.FixtureMissing;
                defer parsed.deinit();
                total += (try cj.arrayOr(parsed.value, "steps")).len;
            }
            return total;
        }
    };
    try testing.expectEqual(@as(usize, queue_corpus_steps), try totals.call(&queue_fixtures));
    try testing.expectEqual(@as(usize, topic_corpus_steps), try totals.call(&topic_fixtures));
    try testing.expectEqual(
        @as(usize, work_queue_corpus_steps),
        try totals.call(&work_queue_fixtures),
    );
}

// ===========================================================================
// The 3×3 ledger — enforced against the source, in both directions
// ===========================================================================

const Primitive = enum { queue, topic, work_queue };

const FlavorRow = struct {
    primitive: Primitive,
    /// Must equal the replayed model's `label`.
    flavor: Str,
    /// The type whose definition in the family's source proves the claim.
    type_name: Str,
    shipped: bool,
    /// Which module is supposed to define it.
    module: Str,
};

const flavor_ledger = [_]FlavorRow{
    .{
        .primitive = .queue,
        .flavor = "single-threaded",
        .type_name = "QueueCell",
        .shipped = true,
        .module = "queue.zig",
    },
    .{
        .primitive = .queue,
        .flavor = "thread-safe",
        .type_name = "ThreadSafeQueueCell",
        .shipped = true,
        .module = "thread_safe_queue.zig",
    },
    .{
        .primitive = .queue,
        .flavor = "async",
        .type_name = "AsyncQueueCell",
        .shipped = true,
        .module = "async_queue.zig",
    },
    .{
        .primitive = .topic,
        .flavor = "single-threaded",
        .type_name = "TopicCell",
        .shipped = true,
        .module = "queue.zig",
    },
    .{
        .primitive = .topic,
        .flavor = "thread-safe",
        .type_name = "ThreadSafeTopicCell",
        .shipped = true,
        .module = "thread_safe_queue.zig",
    },
    .{
        .primitive = .topic,
        .flavor = "async",
        .type_name = "AsyncTopicCell",
        .shipped = true,
        .module = "async_queue.zig",
    },
    .{
        .primitive = .work_queue,
        .flavor = "single-threaded",
        .type_name = "WorkQueueCell",
        .shipped = true,
        .module = "work_queue.zig",
    },
    .{
        .primitive = .work_queue,
        .flavor = "thread-safe",
        .type_name = "ThreadSafeWorkQueueCell",
        .shipped = true,
        .module = "thread_safe_queue.zig",
    },
    .{
        .primitive = .work_queue,
        .flavor = "async",
        .type_name = "AsyncWorkQueueCell",
        .shipped = true,
        .module = "async_queue.zig",
    },
};

/// The family's source text, reached from the filesystem at compile time.
///
/// `@embedFile` rather than a `readDir` walk for two reasons. First, cwd: a test
/// binary may run from somewhere other than the repo root, and a ledger that
/// silently skips itself is not a ledger. Second, self-reference: this file lives
/// in the same package as the shells, so a directory grep would find the ledger's
/// own `type_name` string literals and report every flavor present — the exact
/// false positive that made `queue.zig`'s first ledger fail against correct code.
/// This file is deliberately NOT part of the searched text.
///
/// A deleted or renamed shell module fails the *build*, which is louder still.
const family_source = @embedFile("queue_core.zig") ++
    @embedFile("queue.zig") ++
    @embedFile("work_queue.zig") ++
    @embedFile("thread_safe_queue.zig") ++
    @embedFile("async_queue.zig");

test "lazily/queue-family ledger: unshipped flavors are really absent" {
    // The evidence channel guards itself: empty source text would report every
    // flavor absent and pass every `shipped = false` row for free.
    try testing.expect(family_source.len > 1000);

    for (flavor_ledger) |row| {
        // `pub fn X(comptime` — the definition, not a doc-comment mention.
        var needle_buf: [128]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "pub fn {s}(comptime", .{row.type_name});
        const defined = std.mem.indexOf(u8, family_source, needle) != null;
        if (row.shipped and !defined) {
            std.debug.print(
                "ledger row `{s}/{s}` claims shipped, but `pub fn {s}(` is not defined in " ++
                    "the queue-family source (expected in {s}); fix the ledger or ship it\n",
                .{ @tagName(row.primitive), row.flavor, row.type_name, row.module },
            );
            return error.TestExpectedEqual;
        }
        if (!row.shipped and defined) {
            std.debug.print(
                "`{s}` now EXISTS but the queue-family ledger still records the {s}/{s} " ++
                    "flavor as unshipped, so the canonical corpus is not replayed against " ++
                    "it. Fix: flip .shipped AND extend the replay to drive it. Do NOT flip " ++
                    "the flag alone — that restores the false green this check prevents.\n",
                .{ row.type_name, @tagName(row.primitive), row.flavor },
            );
            return error.TestExpectedEqual;
        }
    }
}

test "lazily/queue-family ledger: every row names a flavor the replay really drives" {
    // In a summary line, "skipped" and "passed" are indistinguishable, and a row
    // can claim a flavor no replay touches. The ledger order IS the replay order,
    // and every label below is read off the model the tests above drive.
    try testing.expectEqual(@as(usize, 9), flavor_ledger.len);
    var shipped: usize = 0;
    for (flavor_ledger) |row| {
        if (row.shipped) shipped += 1;
    }
    try testing.expectEqual(@as(usize, 9), shipped);

    const replayed = [_]Str{
        SyncQueueModel.label,
        TsQueueModel.label,
        AsyncQueueModel.label,
        SyncTopicModel.label,
        TsTopicModel.label,
        AsyncTopicModel.label,
        SyncWorkQueueModel.label,
        TsWorkQueueModel.label,
        AsyncWorkQueueModel.label,
    };
    for (flavor_ledger, replayed) |row, model_label| {
        try testing.expectEqualStrings(row.flavor, model_label);
    }

    // Three primitives, three flavors each — not nine rows of the same primitive.
    for ([_]Primitive{ .queue, .topic, .work_queue }) |primitive| {
        var seen: usize = 0;
        for (flavor_ledger) |row| {
            if (row.primitive == primitive) seen += 1;
        }
        try testing.expectEqual(@as(usize, 3), seen);
    }
}

test "lazily/queue-family ledger: every fixture the replay lists really exists" {
    if (!corpusPresent()) return error.SkipZigTest;
    // The runtime coverage guard (`scripts/check-conformance-coverage.sh`) fails on
    // a canonical fixture nothing opened. This is the near end of the same check:
    // every name in the lists must resolve to real bytes, so a typo cannot shorten
    // the run silently.
    for (queue_fixtures ++ topic_fixtures ++ work_queue_fixtures) |rel_path| {
        var parsed = (try cj.load(rel_path)) orelse {
            std.debug.print("fixture {s} named by a replay list does not exist\n", .{rel_path});
            return error.FixtureMissing;
        };
        parsed.deinit();
    }
    try testing.expectEqual(@as(usize, 5), queue_fixtures.len);
    try testing.expectEqual(@as(usize, 4), topic_fixtures.len);
    try testing.expectEqual(@as(usize, 2), work_queue_fixtures.len);
}

// ===========================================================================
// The probe itself must be able to fail
// ===========================================================================

test "lazily/queue-family conformance: the invalidation probe discriminates" {
    // The corpus asserts NEGATIVE invalidation, so a probe stuck on "always
    // invalidated" or "never invalidated" would pass half the matrix for free.
    // This pins it on all three flavors: a push onto a NON-EMPTY queue must not
    // move `head`, and a pop must.
    inline for (.{ SyncQueueModel, TsQueueModel, AsyncQueueModel }) |Model| {
        const model = try Model.create(testing.allocator, null);
        defer model.destroy();

        const idle = model.versions();
        try testing.expectEqual(idle, model.versions());

        _ = try model.push("a");
        const after_first = model.versions();
        try testing.expect(after_first.head != idle.head);
        try testing.expect(after_first.is_empty != idle.is_empty);

        _ = try model.push("b");
        const after_second = model.versions();
        try testing.expect(after_second.len != after_first.len);
        // The discrimination the whole corpus rests on.
        try testing.expectEqual(after_first.head, after_second.head);
        try testing.expectEqual(after_first.is_empty, after_second.is_empty);

        _ = try model.pop();
        const after_pop = model.versions();
        try testing.expect(after_pop.head != after_second.head);
        try testing.expectEqual(after_second.is_empty, after_pop.is_empty);
    }
}

test "lazily/queue-family conformance: a work-queue probe discriminates too" {
    inline for (.{ SyncWorkQueueModel, TsWorkQueueModel, AsyncWorkQueueModel }) |Model| {
        const model = try Model.create(testing.allocator, 10, 3);
        defer model.destroy();

        const idle = model.versions();
        _ = try model.push("a");
        const after_push = model.versions();
        try testing.expect(after_push.pending_len != idle.pending_len);
        try testing.expect(after_push.is_empty != idle.is_empty);
        // A second push into a non-empty queue must NOT move `is_empty`.
        _ = try model.push("b");
        const after_second = model.versions();
        try testing.expect(after_second.pending_len != after_push.pending_len);
        try testing.expectEqual(after_push.is_empty, after_second.is_empty);
        try testing.expectEqual(after_push.dead_letter_len, after_second.dead_letter_len);
    }
}

// ===========================================================================
// A version counter is not the only evidence: real derived nodes must rerun
// ===========================================================================

/// The single-threaded probe needs a module-scope binding, because Zig has no
/// closures and `cell.computed` takes a bare fn.
const SyncDerived = struct {
    var owner: *SyncQueue = undefined;
    var head_runs: usize = 0;
    var len_runs: usize = 0;

    fn head(view: *Compute) !?Str {
        head_runs += 1;
        return view.get(owner.head());
    }
    fn len(view: *Compute) !usize {
        len_runs += 1;
        return view.get(owner.len());
    }
};

test "lazily/queue-family: a derived node over a reader reruns exactly on invalidation (single-threaded)" {
    const allocator = testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();
    var q = try queue.newUnbounded(Str, ctx);
    defer q.deinit();

    SyncDerived.owner = &q;
    SyncDerived.head_runs = 0;
    SyncDerived.len_runs = 0;
    const derived_head = try cell.computed(?Str, ctx, SyncDerived.head, null);
    defer allocator.destroy(derived_head);
    const derived_len = try cell.computed(usize, ctx, SyncDerived.len, null);
    defer allocator.destroy(derived_len);
    _ = derived_head.get();
    _ = derived_len.get();

    var head_runs = SyncDerived.head_runs;
    var len_runs = SyncDerived.len_runs;
    try q.tryPush("a");
    _ = derived_head.get();
    _ = derived_len.get();
    try testing.expectEqual(head_runs + 1, SyncDerived.head_runs);
    try testing.expectEqual(len_runs + 1, SyncDerived.len_runs);

    // A push onto a non-empty queue moves `len` and NOT `head`, so the head derive
    // must stay warm. This is the claim a version counter alone cannot make.
    head_runs = SyncDerived.head_runs;
    len_runs = SyncDerived.len_runs;
    try q.tryPush("b");
    _ = derived_head.get();
    _ = derived_len.get();
    try testing.expectEqual(head_runs, SyncDerived.head_runs);
    try testing.expectEqual(len_runs + 1, SyncDerived.len_runs);
}

test "lazily/queue-family: a derived node over a reader reruns exactly on invalidation (thread-safe)" {
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();
    var q: TsQueue = undefined;
    try thread_safe_queue.initUnbounded(Str, &q, &ctx);
    defer q.deinit();

    const Derived = struct {
        var cell_ptr: *TsQueue = undefined;
        var head_runs: usize = 0;
        var len_runs: usize = 0;

        fn head(_: *anyopaque, cc: *ThreadSafeContext.ComputeContext) usize {
            head_runs += 1;
            const value = cc.readNode(?Str, cell_ptr.head_reader);
            return if (value) |v| v.len else 0;
        }
        fn len(_: *anyopaque, cc: *ThreadSafeContext.ComputeContext) usize {
            len_runs += 1;
            return cc.readNode(usize, cell_ptr.len_reader);
        }
    };
    Derived.cell_ptr = &q;
    Derived.head_runs = 0;
    Derived.len_runs = 0;

    var anchor: u8 = 0;
    const derived_head = try ctx.computedClosure(usize, @ptrCast(&anchor), Derived.head);
    const derived_len = try ctx.computedClosure(usize, @ptrCast(&anchor), Derived.len);

    var head_runs = Derived.head_runs;
    var len_runs = Derived.len_runs;
    try q.tryPush("a");
    _ = ctx.get(usize, derived_head);
    _ = ctx.get(usize, derived_len);
    try testing.expectEqual(head_runs + 1, Derived.head_runs);
    try testing.expectEqual(len_runs + 1, Derived.len_runs);

    head_runs = Derived.head_runs;
    len_runs = Derived.len_runs;
    try q.tryPush("b");
    _ = ctx.get(usize, derived_head);
    _ = ctx.get(usize, derived_len);
    try testing.expectEqual(head_runs, Derived.head_runs);
    try testing.expectEqual(len_runs + 1, Derived.len_runs);
}

test "lazily/queue-family: a derived node over a reader reruns exactly on invalidation (async)" {
    var ctx = AsyncQueue.Ctx.init(testing.allocator);
    defer ctx.deinit();
    var q: AsyncQueue = undefined;
    try async_queue.initUnbounded(Str, &q, &ctx);
    defer q.deinit();

    const Derived = struct {
        var cell_ptr: *AsyncQueue = undefined;
        var head_runs: usize = 0;
        var len_runs: usize = 0;

        fn head(_: *anyopaque, cc: *AsyncQueue.Ctx.ComputeContext) anyerror!AsyncQueue.Read {
            head_runs += 1;
            try cc.readCell(cell_ptr.head_reader.id);
            const upstream = cc.async_ctx.get(cell_ptr.head_reader.id);
            const value: ?Str = if (upstream) |u| u.head else null;
            return .{ .len = if (value) |v| v.len else 0 };
        }
        fn len(_: *anyopaque, cc: *AsyncQueue.Ctx.ComputeContext) anyerror!AsyncQueue.Read {
            len_runs += 1;
            try cc.readCell(cell_ptr.len_reader.id);
            const upstream = cc.async_ctx.get(cell_ptr.len_reader.id);
            return .{ .len = if (upstream) |u| u.len else 0 };
        }
    };
    Derived.cell_ptr = &q;
    Derived.head_runs = 0;
    Derived.len_runs = 0;

    var anchor: u8 = 0;
    const derived_head = try ctx.computedClosure(@ptrCast(&anchor), Derived.head);
    const derived_len = try ctx.computedClosure(@ptrCast(&anchor), Derived.len);
    // These derives sit at depth 2 (version source -> reader -> derive), and this
    // graph is a pending-compute QUEUE: the cascade only reaches depth 2 once the
    // reader itself has recomputed, so the drain has to be driven to quiescence
    // before a read. `awaitComputed` alone stops as soon as ITS node resolves,
    // which for an untouched derive is immediately.
    _ = try ctx.settle();

    var head_runs = Derived.head_runs;
    var len_runs = Derived.len_runs;
    try q.tryPush("a");
    _ = try ctx.settle();
    _ = try ctx.awaitComputed(derived_head);
    _ = try ctx.awaitComputed(derived_len);
    try testing.expect(Derived.head_runs > head_runs);
    try testing.expect(Derived.len_runs > len_runs);

    head_runs = Derived.head_runs;
    len_runs = Derived.len_runs;
    try q.tryPush("b");
    _ = try ctx.settle();
    _ = try ctx.awaitComputed(derived_head);
    _ = try ctx.awaitComputed(derived_len);
    // `head` did not move, so nothing downstream of it may rerun.
    try testing.expectEqual(head_runs, Derived.head_runs);
    try testing.expect(Derived.len_runs > len_runs);
}

test "lazily/queue-family: a topic derive reruns only for the woken cursor" {
    // The per-subscriber half of the same claim, on all three flavors: a publish
    // wakes every connected cursor, an advance wakes exactly one, and a
    // disconnected durable cursor is woken by neither.
    inline for (.{ SyncTopicModel, TsTopicModel, AsyncTopicModel }) |Model| {
        var subs = [_]TopicSubscriptionSnapshot{
            .{ .subscriber_id = "a", .cursor = 0, .durability = .durable, .connected = true },
            .{ .subscriber_id = "b", .cursor = 0, .durability = .durable, .connected = true },
        };
        const model = try Model.create(testing.allocator, .{
            .allocator = testing.allocator,
            .base_offset = 0,
            .elements = @constCast(&[_]Str{}),
            .subscriptions = subs[0..],
        });
        defer model.destroy();

        _ = try model.read("a");
        _ = try model.read("b");
        const a0 = model.readerVersion("a").?;
        const b0 = model.readerVersion("b").?;

        _ = try model.publish("one");
        try testing.expect(model.readerVersion("a").? > a0);
        try testing.expect(model.readerVersion("b").? > b0);
        try testing.expectEqualStrings("one", (try model.read("a")).?);

        const a1 = model.readerVersion("a").?;
        const b1 = model.readerVersion("b").?;
        _ = try model.advance("a", 1);
        try testing.expect(model.readerVersion("a").? > a1);
        try testing.expectEqual(b1, model.readerVersion("b").?);
        try testing.expectEqual(@as(?Str, null), try model.read("a"));

        try model.disconnect("b");
        const b2 = model.readerVersion("b").?;
        _ = try model.publish("two");
        try testing.expectEqual(b2, model.readerVersion("b").?);
    }
}

// ---------------------------------------------------------------------------
// Mutation-check record (`#lzqueuefamilyflavors`). Each deliberate defect was
// introduced, `make check` run, its EXIT CODE checked, and the defect reverted with
// an mtime bump — a restore that preserves mtime lets the build system reuse the
// MUTATED artifact and report a false green. The commit message carries the full
// table; the shape of it is:
//
// * a shared-core defect (drop `QueueCore`'s empty→head transition, publish to
//   disconnected cursors in `TopicCore`, drop the emptiness flip in
//   `WorkQueueCore.claim`) turns ALL THREE flavors red together — the proof the
//   three shells really share one algebra rather than three copies of it;
// * a per-shell under-invalidation (a reader kind that stops being bumped) fails
//   the `invalidates: true` half in exactly one flavor;
// * a per-shell over-invalidation (bump every kind / wake every subscriber) fails
//   the `invalidates: false` half in exactly one flavor, which is the direction a
//   post-state-only suite cannot see at all.
// ---------------------------------------------------------------------------
