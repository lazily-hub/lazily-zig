//! `ThreadSafeIngressCell` — the `Send + Sync` flavor of the transport-agnostic
//! reactive ingress family (`#designimplementtransport`).
//!
//! Same [`IngressCore`](ingress_core.zig) algebra as [`IngressCell`](ingress.zig);
//! what differs is only where the graph lives and how invalidation is published.
//! Three rules are load-bearing here and nowhere else:
//!
//! 1. **Invalidation runs OUTSIDE the core lock.** A reader's compute takes the
//!    context lock and then the core lock (it must read scope state to derive its
//!    value). An op that invalidated while still holding the core lock would take
//!    those in the opposite order and deadlock. So every mutator copies the core's
//!    reported change into a call-local plan under the core lock, releases it, and
//!    only then touches the graph — the same discipline
//!    `thread_safe_reactive_map.zig` uses for `remove`.
//!
//! 2. **The whole change set publishes inside one `batch()`.** `ThreadSafeContext`
//!    marks cones dirty inline but defers the *effect flush* to the outermost batch
//!    exit, so a transition that dirties four reader kinds reruns each reached
//!    effect once rather than four times. Without the batch, one admission is
//!    several frontier walks and an effect can observe `new value, old authority`
//!    — exactly the partial fan-out a generation handoff must never expose.
//!
//! 3. **The plan is call-local.** A shared scratch buffer would let one thread
//!    publish another's change set; the plan therefore lives on the caller's
//!    stack, and the per-reader version counters are atomic so two concurrent
//!    bumps cannot collapse into one write.
//!
//! **Admission is not thread-coloured, either.** Whether an envelope is admissible
//! is a function of the fence, the watermark, the reorder buffer, and the observed
//! clock. The mutex serializes access to that state; it does not change a single
//! decision.
//!
//! Minting a scope's readers ([`scopeReaders`]) mutates a plain hash map and is
//! **not** itself a synchronized surface — mint every key a concurrent workload
//! will touch before spawning. Publishing never mints: a key nothing has read has
//! no observer to invalidate.

const std = @import("std");
const ParkingMutex = @import("parking_mutex.zig").ParkingMutex;
const tsc = @import("thread_safe_context.zig");
const ThreadSafeContext = tsc.ThreadSafeContext;
const TsHandle = tsc.TsHandle;
const merge = @import("merge.zig");
const core_mod = @import("ingress_core.zig");

pub const IngressCore = core_mod.IngressCore;
pub const IngressAdmission = core_mod.IngressAdmission;
pub const IngressAuthority = core_mod.IngressAuthority;
pub const IngressConfigError = core_mod.IngressConfigError;
pub const IngressError = core_mod.IngressError;
pub const IngressPolicy = core_mod.IngressPolicy;
pub const IngressReadiness = core_mod.IngressReadiness;
pub const IngressReceiptChannel = core_mod.IngressReceiptChannel;
pub const IngressRetry = core_mod.IngressRetry;
pub const IngressSchedule = core_mod.IngressSchedule;
pub const IngressTransportKind = core_mod.IngressTransportKind;
pub const ReplayRequest = core_mod.ReplayRequest;
pub const ScopeView = core_mod.ScopeView;

/// Keyed lifecycle-scoped admission with reactive derives on a
/// [`ThreadSafeContext`], so an ingress plane can live in an owner shared across
/// threads.
///
/// The cell's address must be stable once constructed: every reader closure
/// reaches the cell through a heap-boxed binding (Zig has no closures), which is
/// why [`init`] fills a `*Self` in place rather than returning one.
pub fn ThreadSafeIngressCell(comptime K: type, comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Core = IngressCore(K, T);
        pub const Envelope = Core.Envelope;
        pub const Receipt = Core.Receipt;

        /// Closure emulation: what a per-scope reader's compute needs to derive
        /// its value and to register its one dependency edge. Heap-boxed, so the
        /// address stays stable across a rehash of `readers`.
        ///
        /// `counter` makes each bump a distinct value, so `setCell`'s equality
        /// guard can never swallow one of two concurrent bumps.
        const ScopeBinding = struct {
            owner: *Self,
            key: K,
            version: TsHandle(u64),
            counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        };

        /// Closure emulation for a receipt-channel reader.
        const ChannelBinding = struct {
            owner: *Self,
            channel: IngressReceiptChannel,
            version: TsHandle(u64),
            counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        };

        /// Four version inputs and four derived readers per scope, because the
        /// four derives have four different invalidation boundaries.
        pub const ScopeReaders = struct {
            value: TsHandle(?T),
            readiness: TsHandle(IngressReadiness),
            authority: TsHandle(?IngressAuthority),
            retry: TsHandle(?IngressRetry),
            /// Index order: value, readiness, authority, retry.
            bindings: [4]*ScopeBinding,
        };

        const Channel = struct {
            reader: TsHandle(usize),
            binding: *ChannelBinding,
        };

        /// One transition's invalidation set, copied out of the core's scratch
        /// buffer so the graph write can happen with the core lock released. Lives
        /// on the caller's stack: a shared buffer would let one thread publish
        /// another thread's change set.
        const Plan = struct {
            deltas: std.ArrayList(Core.ScopeDelta) = .empty,
            accepted: bool = false,
            dropped: bool = false,
            err: bool = false,

            fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
                self.deltas.deinit(allocator);
            }

            fn isEmpty(self: *const Plan) bool {
                return self.deltas.items.len == 0 and !self.accepted and
                    !self.dropped and !self.err;
            }
        };

        const PublishOp = struct { cell: *Self, plan: *const Plan };

        ctx: *ThreadSafeContext,
        allocator: std.mem.Allocator,
        /// Serializes the admission algebra. Never held across a graph write.
        mutex: ParkingMutex,
        core: Core,
        readers: core_mod.HashMapFor(K, ScopeReaders),
        accepted: Channel,
        dropped: Channel,
        errors: Channel,
        schedule_value: IngressSchedule,

        // --- compute closures ------------------------------------------------

        fn computeValue(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) ?T {
            const b: *ScopeBinding = @ptrCast(@alignCast(ptr));
            _ = cc.readNode(u64, b.version);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return b.owner.core.peek(b.key);
        }

        fn computeReadiness(
            ptr: *anyopaque,
            cc: *ThreadSafeContext.ComputeContext,
        ) IngressReadiness {
            const b: *ScopeBinding = @ptrCast(@alignCast(ptr));
            _ = cc.readNode(u64, b.version);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return b.owner.core.readiness(b.key);
        }

        fn computeAuthority(
            ptr: *anyopaque,
            cc: *ThreadSafeContext.ComputeContext,
        ) ?IngressAuthority {
            const b: *ScopeBinding = @ptrCast(@alignCast(ptr));
            _ = cc.readNode(u64, b.version);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return b.owner.core.authority(b.key);
        }

        fn computeRetry(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) ?IngressRetry {
            const b: *ScopeBinding = @ptrCast(@alignCast(ptr));
            _ = cc.readNode(u64, b.version);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return b.owner.core.retry(b.key);
        }

        fn computeChannel(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) usize {
            const b: *ChannelBinding = @ptrCast(@alignCast(ptr));
            _ = cc.readNode(u64, b.version);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return b.owner.core.receiptCount(b.channel);
        }

        // --- construction ----------------------------------------------------

        /// Build the cell in place. Takes `*Self` rather than returning one
        /// because the reader bindings capture the cell's address, so it must be
        /// at its final location before any node is minted.
        pub fn init(
            self: *Self,
            ctx: *ThreadSafeContext,
            policy: IngressPolicy,
            merge_policy: merge.MergePolicy(T),
            transport: IngressTransportKind,
            poll_interval: u64,
        ) !void {
            var core = try Core.init(ctx.allocator, policy, merge_policy);
            errdefer core.deinit();
            self.* = .{
                .ctx = ctx,
                .allocator = ctx.allocator,
                .mutex = ParkingMutex.init(),
                .core = core,
                .readers = core_mod.HashMapFor(K, ScopeReaders).init(ctx.allocator),
                .accepted = undefined,
                .dropped = undefined,
                .errors = undefined,
                .schedule_value = IngressSchedule.forKind(transport, poll_interval),
            };
            self.accepted = try self.initChannel(.accepted);
            self.dropped = try self.initChannel(.dropped);
            self.errors = try self.initChannel(.err);
        }

        fn initChannel(self: *Self, channel: IngressReceiptChannel) !Channel {
            const version = try self.ctx.cell(u64, 0);
            const binding = try self.allocator.create(ChannelBinding);
            errdefer self.allocator.destroy(binding);
            binding.* = .{ .owner = self, .channel = channel, .version = version };
            const reader = try self.ctx.computedClosure(usize, binding, computeChannel);
            return .{ .reader = reader, .binding = binding };
        }

        pub fn deinit(self: *Self) void {
            var it = self.readers.valueIterator();
            while (it.next()) |r| {
                for (r.bindings) |b| self.allocator.destroy(b);
            }
            self.readers.deinit();
            self.allocator.destroy(self.accepted.binding);
            self.allocator.destroy(self.dropped.binding);
            self.allocator.destroy(self.errors.binding);
            self.core.deinit();
        }

        // --- reader identities ------------------------------------------------

        /// Mint (or fetch) the four version inputs and four derived readers for
        /// `key`. Minting a reader does **not** open a scope: a consumer may
        /// legitimately observe a key before it exists, and reads
        /// `unknown`/`null` until it does.
        ///
        /// MUST be called with the core lock released — minting a derived node
        /// runs its first compute, which takes the core lock. Not synchronized:
        /// see the module header.
        pub fn scopeReaders(self: *Self, key: K) !*ScopeReaders {
            const entry = try self.readers.getOrPut(key);
            if (entry.found_existing) return entry.value_ptr;

            var bindings: [4]*ScopeBinding = undefined;
            for (0..4) |i| {
                const version = try self.ctx.cell(u64, 0);
                bindings[i] = try self.allocator.create(ScopeBinding);
                bindings[i].* = .{ .owner = self, .key = key, .version = version };
            }
            entry.value_ptr.* = .{
                .value = try self.ctx.computedClosure(?T, bindings[0], computeValue),
                .readiness = try self.ctx.computedClosure(
                    IngressReadiness,
                    bindings[1],
                    computeReadiness,
                ),
                .authority = try self.ctx.computedClosure(
                    ?IngressAuthority,
                    bindings[2],
                    computeAuthority,
                ),
                .retry = try self.ctx.computedClosure(?IngressRetry, bindings[3], computeRetry),
                .bindings = bindings,
            };
            return entry.value_ptr;
        }

        // --- reactive reads ---------------------------------------------------

        pub fn value(self: *Self, key: K) !?T {
            const r = try self.scopeReaders(key);
            return self.ctx.get(?T, r.value);
        }

        pub fn readiness(self: *Self, key: K) !IngressReadiness {
            const r = try self.scopeReaders(key);
            return self.ctx.get(IngressReadiness, r.readiness);
        }

        pub fn authority(self: *Self, key: K) !?IngressAuthority {
            const r = try self.scopeReaders(key);
            return self.ctx.get(?IngressAuthority, r.authority);
        }

        pub fn retry(self: *Self, key: K) !?IngressRetry {
            const r = try self.scopeReaders(key);
            return self.ctx.get(?IngressRetry, r.retry);
        }

        pub fn acceptedLen(self: *Self) usize {
            return self.ctx.get(usize, self.accepted.reader);
        }

        pub fn droppedLen(self: *Self) usize {
            return self.ctx.get(usize, self.dropped.reader);
        }

        pub fn errorsLen(self: *Self) usize {
            return self.ctx.get(usize, self.errors.reader);
        }

        /// The derived schedule — a pure function of the transport, so it never
        /// invalidates.
        pub fn schedule(self: *const Self) IngressSchedule {
            return self.schedule_value;
        }

        // --- cache-validity probes -------------------------------------------

        pub fn valueIsValid(self: *Self, key: K) !bool {
            const r = try self.scopeReaders(key);
            return self.ctx.isCacheValid(r.value.id);
        }

        pub fn readinessIsValid(self: *Self, key: K) !bool {
            const r = try self.scopeReaders(key);
            return self.ctx.isCacheValid(r.readiness.id);
        }

        pub fn authorityIsValid(self: *Self, key: K) !bool {
            const r = try self.scopeReaders(key);
            return self.ctx.isCacheValid(r.authority.id);
        }

        pub fn retryIsValid(self: *Self, key: K) !bool {
            const r = try self.scopeReaders(key);
            return self.ctx.isCacheValid(r.retry.id);
        }

        pub fn acceptedIsValid(self: *Self) bool {
            return self.ctx.isCacheValid(self.accepted.reader.id);
        }

        pub fn droppedIsValid(self: *Self) bool {
            return self.ctx.isCacheValid(self.dropped.reader.id);
        }

        pub fn errorsIsValid(self: *Self) bool {
            return self.ctx.isCacheValid(self.errors.reader.id);
        }

        // --- non-reactive projections ----------------------------------------

        pub fn view(self: *Self, key: K) ?ScopeView {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.core.view(key);
        }

        // --- invalidation ------------------------------------------------------

        /// Copy the core's reported change into the caller's plan. Runs WITH the
        /// core lock held; touches no graph node.
        fn collect(self: *Self, plan: *Plan, change: Core.Change) !void {
            try plan.deltas.appendSlice(self.allocator, change.scopes);
            plan.accepted = change.accepted_receipts;
            plan.dropped = change.dropped_receipts;
            plan.err = change.error_receipts;
        }

        fn bumpScope(self: *Self, binding: *ScopeBinding) void {
            const next = binding.counter.fetchAdd(1, .monotonic) + 1;
            self.ctx.setCell(u64, binding.version, next);
        }

        fn bumpChannel(self: *Self, binding: *ChannelBinding) void {
            const next = binding.counter.fetchAdd(1, .monotonic) + 1;
            self.ctx.setCell(u64, binding.version, next);
        }

        fn batchBody(ptr: *anyopaque) void {
            const op: *PublishOp = @ptrCast(@alignCast(ptr));
            const self = op.cell;
            for (op.plan.deltas.items) |delta| {
                // Non-minting on purpose: a key nothing has read has no observer
                // to invalidate, and minting here would need the graph AND the
                // reader map at once.
                const r = self.readers.getPtr(delta.key) orelse continue;
                if (delta.change.value) self.bumpScope(r.bindings[0]);
                if (delta.change.readiness) self.bumpScope(r.bindings[1]);
                if (delta.change.authority) self.bumpScope(r.bindings[2]);
                if (delta.change.retry) self.bumpScope(r.bindings[3]);
            }
            if (op.plan.accepted) self.bumpChannel(self.accepted.binding);
            if (op.plan.dropped) self.bumpChannel(self.dropped.binding);
            if (op.plan.err) self.bumpChannel(self.errors.binding);
        }

        /// Publish the collected change set. Called with the core lock RELEASED,
        /// and wrapped in one `batch()` so the whole set is one frontier walk.
        fn publish(self: *Self, plan: *const Plan) void {
            if (plan.isEmpty()) return;
            var op = PublishOp{ .cell = self, .plan = plan };
            self.ctx.batch(void, @ptrCast(&op), batchBody);
        }

        // --- mutators -----------------------------------------------------------

        pub fn open(self: *Self, key: K, generation: u64) !void {
            var plan: Plan = .{};
            defer plan.deinit(self.allocator);
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.collect(&plan, try self.core.open(key, generation));
            }
            self.publish(&plan);
        }

        pub fn admit(self: *Self, envelope: Envelope) !IngressAdmission {
            var plan: Plan = .{};
            defer plan.deinit(self.allocator);
            const admission = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                const result = try self.core.admit(envelope);
                try self.collect(&plan, result.change);
                break :blk result.admission;
            };
            self.publish(&plan);
            return admission;
        }

        pub fn suspendScope(self: *Self, key: K) !?ReplayRequest {
            var plan: Plan = .{};
            defer plan.deinit(self.allocator);
            const replay = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                const result = try self.core.suspendScope(key);
                try self.collect(&plan, result.change);
                break :blk result.replay;
            };
            self.publish(&plan);
            return replay;
        }

        pub fn reconnect(self: *Self, key: K, generation: u64) !ReplayRequest {
            var plan: Plan = .{};
            defer plan.deinit(self.allocator);
            const replay = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                const result = try self.core.reconnect(key, generation);
                try self.collect(&plan, result.change);
                break :blk result.replay;
            };
            self.publish(&plan);
            return replay;
        }

        pub fn close(self: *Self, key: K) !void {
            var plan: Plan = .{};
            defer plan.deinit(self.allocator);
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.collect(&plan, try self.core.close(key));
            }
            self.publish(&plan);
        }

        pub fn fail(self: *Self, key: K, err: IngressError) !void {
            var plan: Plan = .{};
            defer plan.deinit(self.allocator);
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.collect(&plan, try self.core.fail(key, err));
            }
            self.publish(&plan);
        }

        pub fn tick(self: *Self, now: u64) !void {
            var plan: Plan = .{};
            defer plan.deinit(self.allocator);
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.collect(&plan, try self.core.tick(now));
            }
            self.publish(&plan);
        }

        pub fn drain(self: *Self, key: K) !?T {
            var plan: Plan = .{};
            defer plan.deinit(self.allocator);
            const drained = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                const result = try self.core.drain(key);
                try self.collect(&plan, result.change);
                break :blk result.value;
            };
            self.publish(&plan);
            return drained;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests. The canonical corpus is replayed against this flavor in
// `ingress_family_conformance.zig`; what lives here is what only this flavor can
// break — the frontier-walk gate and cross-thread sharing.
// ---------------------------------------------------------------------------

const testing = std.testing;
const builtin = @import("builtin");

const Cell = ThreadSafeIngressCell([]const u8, u64);

test "lazily/thread_safe_ingress: one admission is one frontier walk" {
    // The mutation this kills: publishing the change set OUTSIDE `batch()`. Each
    // `setCell` then flushes on its own, so an effect reading four reader kinds
    // runs four times for one admission — and between runs it observes
    // `new value, old authority`.
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();
    var ing: Cell = undefined;
    try ing.init(&ctx, .{}, merge.sum(u64), .event_channel, 25);
    defer ing.deinit();

    const readers = try ing.scopeReaders("alpha");

    const Watcher = struct {
        var handles: *Cell.ScopeReaders = undefined;
        var runs: usize = 0;
        var last_window: ?u64 = null;
        var last_generation: ?u64 = null;

        fn body(_: *anyopaque, cc: *ThreadSafeContext.ComputeContext) usize {
            runs += 1;
            last_window = cc.readNode(?u64, handles.value);
            const auth = cc.readNode(?IngressAuthority, handles.authority);
            last_generation = if (auth) |a| a.generation else null;
            _ = cc.readNode(IngressReadiness, handles.readiness);
            _ = cc.readNode(?IngressRetry, handles.retry);
            return runs;
        }
    };
    Watcher.handles = readers;
    Watcher.runs = 0;
    Watcher.last_window = null;
    Watcher.last_generation = null;

    var unused: usize = 0;
    _ = try ctx.effectClosure(usize, @ptrCast(&unused), Watcher.body, null, null);
    try testing.expectEqual(@as(usize, 1), Watcher.runs);

    // A delivery dirties all four kinds. Exactly one rerun.
    _ = try ing.admit(Cell.Envelope.init("alpha", 3, 0, 0, 5));
    try testing.expectEqual(@as(usize, 2), Watcher.runs);
    try testing.expectEqual(@as(?u64, 5), Watcher.last_window);
    try testing.expectEqual(@as(?u64, 3), Watcher.last_generation);

    // A handoff dirties all four again — still one rerun, and the effect sees
    // the whole transition rather than a prefix of it.
    _ = try ing.admit(Cell.Envelope.init("alpha", 4, 0, 0, 9));
    try testing.expectEqual(@as(usize, 3), Watcher.runs);
    try testing.expectEqual(@as(?u64, 9), Watcher.last_window);
    try testing.expectEqual(@as(?u64, 4), Watcher.last_generation);

    // A buffered envelope dirties nothing, so the effect does not rerun at all.
    _ = try ing.admit(Cell.Envelope.init("alpha", 4, 7, 0, 1));
    try testing.expectEqual(@as(usize, 3), Watcher.runs);
}

test "lazily/thread_safe_ingress: reader kinds invalidate independently" {
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();
    var ing: Cell = undefined;
    try ing.init(&ctx, .{ .freshness_horizon = 30 }, merge.sum(u64), .event_channel, 25);
    defer ing.deinit();

    const Warm = struct {
        fn all(cell: *Cell) !void {
            _ = try cell.value("alpha");
            _ = try cell.readiness("alpha");
            _ = try cell.authority("alpha");
            _ = try cell.retry("alpha");
            _ = cell.acceptedLen();
            _ = cell.droppedLen();
            _ = cell.errorsLen();
        }

        /// The four scope kinds plus the three channels, in fixture order.
        fn probe(cell: *Cell) ![7]bool {
            return .{
                try cell.valueIsValid("alpha"),
                try cell.readinessIsValid("alpha"),
                try cell.authorityIsValid("alpha"),
                try cell.retryIsValid("alpha"),
                cell.acceptedIsValid(),
                cell.droppedIsValid(),
                cell.errorsIsValid(),
            };
        }
    };

    // Reading warms every reader, which is what makes each probe below measure
    // that step's invalidation and nothing else.
    try Warm.all(&ing);
    try testing.expectEqual([7]bool{ true, true, true, true, true, true, true }, try Warm.probe(&ing));

    // A delivery dirties all four scope kinds and the accepted channel only.
    _ = try ing.admit(Cell.Envelope.init("alpha", 1, 0, 0, 5));
    try testing.expectEqual(
        [7]bool{ false, false, false, false, false, true, true },
        try Warm.probe(&ing),
    );

    // An error on an EXISTING scope is retry + error-channel only. (On an unknown
    // key it would also move readiness and authority, because the scope's first
    // appearance moves it off `unknown` — see `IngressScopeChange.creation`.)
    try Warm.all(&ing);
    try ing.fail("alpha", .transport_closed);
    try testing.expectEqual(
        [7]bool{ true, true, true, false, true, true, false },
        try Warm.probe(&ing),
    );

    // A duplicate is a drop: the dropped channel only, and no scope reader.
    try Warm.all(&ing);
    _ = try ing.admit(Cell.Envelope.init("alpha", 1, 0, 0, 5));
    try testing.expectEqual(
        [7]bool{ true, true, true, true, true, false, true },
        try Warm.probe(&ing),
    );

    // A tick inside the freshness horizon invalidates nothing at all — this is
    // what keeps a polling shell from re-rendering on every tick.
    try Warm.all(&ing);
    try ing.tick(10);
    try testing.expectEqual([7]bool{ true, true, true, true, true, true, true }, try Warm.probe(&ing));

    // Crossing it is readiness-only.
    try ing.tick(100);
    try testing.expectEqual(
        [7]bool{ true, false, true, true, true, true, true },
        try Warm.probe(&ing),
    );

    try testing.expectEqual(@as(?u64, 5), try ing.value("alpha"));
    try testing.expectEqual(IngressReadiness.stale, try ing.readiness("alpha"));
    try testing.expectEqual(@as(usize, 1), ing.acceptedLen());
    try testing.expectEqual(@as(usize, 1), ing.droppedLen());
    try testing.expectEqual(@as(usize, 1), ing.errorsLen());
}

/// Independent scopes hammered from N threads. A mutex admits a concurrent
/// workload as *some* sequential order of the per-scope admissions, and scopes
/// are independent, so every scope's watermark must be the full run.
const Soak = struct {
    cell: *Cell,
    key: []const u8,
    count: u64,

    fn run(self: Soak) void {
        var seq: u64 = 0;
        while (seq < self.count) : (seq += 1) {
            _ = self.cell.admit(Cell.Envelope.init(self.key, 1, seq, 0, 1)) catch unreachable;
        }
    }
};

test "lazily/thread_safe_ingress: concurrent per-scope admission is serializable" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();
    var ing: Cell = undefined;
    try ing.init(&ctx, .{}, merge.sum(u64), .event_channel, 25);
    defer ing.deinit();

    const keys = [_][]const u8{ "alpha", "beta", "gamma", "delta" };
    // Mint every reader up front — `scopeReaders` is not a synchronized surface.
    for (keys) |key| _ = try ing.scopeReaders(key);

    const per_scope: u64 = 40;
    var threads: [keys.len]std.Thread = undefined;
    for (keys, 0..) |key, i| {
        threads[i] = try std.Thread.spawn(
            .{},
            Soak.run,
            .{Soak{ .cell = &ing, .key = key, .count = per_scope }},
        );
    }
    for (threads) |t| t.join();

    for (keys) |key| {
        try testing.expectEqual(@as(?u64, per_scope - 1), ing.view(key).?.delivered_through);
        try testing.expectEqual(@as(?u64, per_scope), try ing.value(key));
    }
    try testing.expectEqual(@as(usize, keys.len * per_scope), ing.acceptedLen());
}

test "lazily/thread_safe_ingress: construction validates overflow against the merge algebra" {
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();
    const raw: merge.MergePolicy(u64) = .{
        .name = "RawFifo",
        .merge = struct {
            fn f(_: u64, op: u64) u64 {
                return op;
            }
        }.f,
        .commutative = false,
        .idempotent = false,
        .conflates = false,
    };
    var ing: Cell = undefined;
    try testing.expectError(
        IngressConfigError.ConflateNotBounding,
        ing.init(&ctx, .{ .overflow = .Conflate }, raw, .event_channel, 25),
    );
}
