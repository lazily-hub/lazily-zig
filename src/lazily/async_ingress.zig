//! `AsyncIngressCell` — the async flavor of the transport-agnostic reactive
//! ingress family (`#designimplementtransport`).
//!
//! Same [`IngressCore`](ingress_core.zig) algebra as the other two shells, over
//! [`AsyncContext`](async_context.zig).
//!
//! # Admission is not async-coloured
//!
//! Whether an envelope is admissible is a function of the fence, the watermark,
//! the reorder buffer, and the observed clock — state the graph does not own and
//! nothing has to await. So **every** mutator and every read below returns a plain
//! value: there is no `settle` step in the surface, and no operation is
//! `anyerror!?T` for want of one. Awaiting belongs to the transport, and the
//! transport is outside the primitive by construction.
//!
//! Zig's `AsyncContext` is a no-runtime pending-compute queue rather than a
//! futures executor, so a derived node resolves when the queue is drained. The
//! reads here drive that drain themselves (`awaitComputed`), which is what keeps
//! the flavor-neutral surface identical to the other two. [`settle`] is exposed for
//! callers that want to drive it explicitly.
//!
//! # One frontier walk, structurally
//!
//! `AsyncContext.setSource` marks a dependent for recompute by *enqueuing* it, and
//! the `queued` flag bounds the queue to one entry per node. A transition that
//! dirties four reader kinds therefore enqueues each reached reader once and the
//! next drain runs it once — no `batch()` boundary is needed to get what the
//! thread-safe shell has to ask for. Invalidation still runs with the core lock
//! released, for the same lock-ordering reason: a reader's compute takes the core
//! lock from inside the drain.
//!
//! # One value type
//!
//! `AsyncContext` is generic over a single node value type, so the four scope
//! derives, the three receipt counts, and the version inputs all travel as
//! [`AsyncIngressRead`] variants. That is a Zig-specific encoding of the same
//! reader set, not a different contract.

const std = @import("std");
const ParkingMutex = @import("parking_mutex.zig").ParkingMutex;
const ac = @import("async_context.zig");
const AsyncContext = ac.AsyncContext;
const AsyncSource = ac.AsyncSource;
const AsyncComputed = ac.AsyncComputed;
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

/// Every value an ingress node carries on the async graph. `AsyncContext` is
/// monomorphic in its node value type, so the reader kinds share one union rather
/// than each getting its own context.
pub fn AsyncIngressRead(comptime T: type) type {
    return union(enum) {
        /// A reader-kind version input: the graph write that clears its readers.
        version: u64,
        /// The coalesced window awaiting drain.
        window: ?T,
        readiness: IngressReadiness,
        authority: ?IngressAuthority,
        retry: ?IngressRetry,
        /// One receipt channel's depth.
        count: usize,
    };
}

/// Keyed lifecycle-scoped admission with reactive derives on an
/// [`AsyncContext`].
///
/// The cell's address must be stable once constructed: every reader closure
/// reaches the cell through a heap-boxed binding (Zig has no closures), which is
/// why [`init`] fills a `*Self` in place rather than returning one.
pub fn AsyncIngressCell(comptime K: type, comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Core = IngressCore(K, T);
        pub const Envelope = Core.Envelope;
        pub const Receipt = Core.Receipt;
        pub const Read = AsyncIngressRead(T);
        pub const Ctx = AsyncContext(Read);

        const ScopeBinding = struct {
            owner: *Self,
            key: K,
            version: AsyncSource(Read),
            counter: u64 = 0,
        };

        const ChannelBinding = struct {
            owner: *Self,
            channel: IngressReceiptChannel,
            version: AsyncSource(Read),
            counter: u64 = 0,
        };

        /// Four derived readers per scope, because the four derives have four
        /// different invalidation boundaries.
        pub const ScopeReaders = struct {
            value: AsyncComputed(Read),
            readiness: AsyncComputed(Read),
            authority: AsyncComputed(Read),
            retry: AsyncComputed(Read),
            /// Index order: value, readiness, authority, retry.
            bindings: [4]*ScopeBinding,
        };

        const Channel = struct {
            reader: AsyncComputed(Read),
            binding: *ChannelBinding,
        };

        /// One transition's invalidation set, copied out of the core's scratch
        /// buffer so the graph write can happen with the core lock released.
        const Plan = struct {
            deltas: std.ArrayList(Core.ScopeDelta) = .empty,
            accepted: bool = false,
            dropped: bool = false,
            err: bool = false,

            fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
                self.deltas.deinit(allocator);
            }
        };

        ctx: *Ctx,
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

        fn computeValue(ptr: *anyopaque, cc: *Ctx.ComputeContext) anyerror!Read {
            const b: *ScopeBinding = @ptrCast(@alignCast(ptr));
            try cc.readCell(b.version.id);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return .{ .window = b.owner.core.peek(b.key) };
        }

        fn computeReadiness(ptr: *anyopaque, cc: *Ctx.ComputeContext) anyerror!Read {
            const b: *ScopeBinding = @ptrCast(@alignCast(ptr));
            try cc.readCell(b.version.id);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return .{ .readiness = b.owner.core.readiness(b.key) };
        }

        fn computeAuthority(ptr: *anyopaque, cc: *Ctx.ComputeContext) anyerror!Read {
            const b: *ScopeBinding = @ptrCast(@alignCast(ptr));
            try cc.readCell(b.version.id);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return .{ .authority = b.owner.core.authority(b.key) };
        }

        fn computeRetry(ptr: *anyopaque, cc: *Ctx.ComputeContext) anyerror!Read {
            const b: *ScopeBinding = @ptrCast(@alignCast(ptr));
            try cc.readCell(b.version.id);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return .{ .retry = b.owner.core.retry(b.key) };
        }

        fn computeChannel(ptr: *anyopaque, cc: *Ctx.ComputeContext) anyerror!Read {
            const b: *ChannelBinding = @ptrCast(@alignCast(ptr));
            try cc.readCell(b.version.id);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return .{ .count = b.owner.core.receiptCount(b.channel) };
        }

        // --- construction ----------------------------------------------------

        pub fn init(
            self: *Self,
            ctx: *Ctx,
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
            const version = try self.ctx.source(.{ .version = 0 });
            const binding = try self.allocator.create(ChannelBinding);
            errdefer self.allocator.destroy(binding);
            binding.* = .{ .owner = self, .channel = channel, .version = version };
            const reader = try self.ctx.computedClosure(binding, computeChannel);
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
        /// `key`. Minting a reader does **not** open a scope.
        pub fn scopeReaders(self: *Self, key: K) !*ScopeReaders {
            const entry = try self.readers.getOrPut(key);
            if (entry.found_existing) return entry.value_ptr;

            var bindings: [4]*ScopeBinding = undefined;
            for (0..4) |i| {
                const version = try self.ctx.source(.{ .version = 0 });
                bindings[i] = try self.allocator.create(ScopeBinding);
                bindings[i].* = .{ .owner = self, .key = key, .version = version };
            }
            entry.value_ptr.* = .{
                .value = try self.ctx.computedClosure(bindings[0], computeValue),
                .readiness = try self.ctx.computedClosure(bindings[1], computeReadiness),
                .authority = try self.ctx.computedClosure(bindings[2], computeAuthority),
                .retry = try self.ctx.computedClosure(bindings[3], computeRetry),
                .bindings = bindings,
            };
            return entry.value_ptr;
        }

        // --- reactive reads ---------------------------------------------------

        /// Drive the pending-compute queue to quiescence. The reads below do this
        /// for themselves; this is the explicit handle.
        pub fn settle(self: *Self) !usize {
            return self.ctx.settle();
        }

        pub fn value(self: *Self, key: K) !?T {
            const r = try self.scopeReaders(key);
            return (try self.ctx.awaitComputed(r.value)).window;
        }

        pub fn readiness(self: *Self, key: K) !IngressReadiness {
            const r = try self.scopeReaders(key);
            return (try self.ctx.awaitComputed(r.readiness)).readiness;
        }

        pub fn authority(self: *Self, key: K) !?IngressAuthority {
            const r = try self.scopeReaders(key);
            return (try self.ctx.awaitComputed(r.authority)).authority;
        }

        pub fn retry(self: *Self, key: K) !?IngressRetry {
            const r = try self.scopeReaders(key);
            return (try self.ctx.awaitComputed(r.retry)).retry;
        }

        pub fn acceptedLen(self: *Self) !usize {
            return (try self.ctx.awaitComputed(self.accepted.reader)).count;
        }

        pub fn droppedLen(self: *Self) !usize {
            return (try self.ctx.awaitComputed(self.dropped.reader)).count;
        }

        pub fn errorsLen(self: *Self) !usize {
            return (try self.ctx.awaitComputed(self.errors.reader)).count;
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

        fn bumpScope(self: *Self, binding: *ScopeBinding) !void {
            binding.counter += 1;
            try self.ctx.setSource(binding.version, .{ .version = binding.counter });
        }

        fn bumpChannel(self: *Self, binding: *ChannelBinding) !void {
            binding.counter += 1;
            try self.ctx.setSource(binding.version, .{ .version = binding.counter });
        }

        /// Publish the collected change set, with the core lock RELEASED. Each
        /// reached reader is enqueued at most once, so the next drain is one
        /// frontier walk.
        fn publish(self: *Self, plan: *const Plan) !void {
            for (plan.deltas.items) |delta| {
                // Non-minting on purpose: a key nothing has read has no observer
                // to invalidate.
                const r = self.readers.getPtr(delta.key) orelse continue;
                if (delta.change.value) try self.bumpScope(r.bindings[0]);
                if (delta.change.readiness) try self.bumpScope(r.bindings[1]);
                if (delta.change.authority) try self.bumpScope(r.bindings[2]);
                if (delta.change.retry) try self.bumpScope(r.bindings[3]);
            }
            if (plan.accepted) try self.bumpChannel(self.accepted.binding);
            if (plan.dropped) try self.bumpChannel(self.dropped.binding);
            if (plan.err) try self.bumpChannel(self.errors.binding);
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
            try self.publish(&plan);
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
            try self.publish(&plan);
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
            try self.publish(&plan);
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
            try self.publish(&plan);
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
            try self.publish(&plan);
        }

        pub fn fail(self: *Self, key: K, err: IngressError) !void {
            var plan: Plan = .{};
            defer plan.deinit(self.allocator);
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.collect(&plan, try self.core.fail(key, err));
            }
            try self.publish(&plan);
        }

        pub fn tick(self: *Self, now: u64) !void {
            var plan: Plan = .{};
            defer plan.deinit(self.allocator);
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.collect(&plan, try self.core.tick(now));
            }
            try self.publish(&plan);
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
            try self.publish(&plan);
            return drained;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests. The canonical corpus is replayed against this flavor in
// `ingress_family_conformance.zig`; what lives here is what only this flavor can
// break — that the surface stays uncoloured, and that its enqueue-based
// invalidation is still exact per reader kind.
// ---------------------------------------------------------------------------

const testing = std.testing;

const Cell = AsyncIngressCell([]const u8, u64);

test "lazily/async_ingress: reader kinds invalidate independently" {
    var ctx = Cell.Ctx.init(testing.allocator);
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
            _ = try cell.acceptedLen();
            _ = try cell.droppedLen();
            _ = try cell.errorsLen();
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

    try Warm.all(&ing);
    try testing.expectEqual([7]bool{ true, true, true, true, true, true, true }, try Warm.probe(&ing));

    // A delivery dirties all four scope kinds and the accepted channel only.
    _ = try ing.admit(Cell.Envelope.init("alpha", 1, 0, 0, 5));
    try testing.expectEqual(
        [7]bool{ false, false, false, false, false, true, true },
        try Warm.probe(&ing),
    );

    // An error on an existing scope is retry + error-channel only.
    try Warm.all(&ing);
    try ing.fail("alpha", .transport_closed);
    try testing.expectEqual(
        [7]bool{ true, true, true, false, true, true, false },
        try Warm.probe(&ing),
    );

    // A buffered envelope invalidates nothing and mints no receipt.
    try Warm.all(&ing);
    const parked = try ing.admit(Cell.Envelope.init("alpha", 1, 3, 0, 1));
    try testing.expectEqual(@as(u64, 1), parked.buffered.gap_from);
    try testing.expectEqual([7]bool{ true, true, true, true, true, true, true }, try Warm.probe(&ing));

    // A tick inside the horizon invalidates nothing; crossing it is
    // readiness-only.
    try ing.tick(10);
    try testing.expectEqual([7]bool{ true, true, true, true, true, true, true }, try Warm.probe(&ing));
    try ing.tick(100);
    try testing.expectEqual(
        [7]bool{ true, false, true, true, true, true, true },
        try Warm.probe(&ing),
    );

    try testing.expectEqual(@as(?u64, 5), try ing.value("alpha"));
    try testing.expectEqual(IngressReadiness.stale, try ing.readiness("alpha"));
    try testing.expectEqual(@as(usize, 1), try ing.acceptedLen());
    try testing.expectEqual(@as(usize, 1), try ing.errorsLen());
}

test "lazily/async_ingress: nothing in the surface is async-coloured" {
    // Every read returns a plain value, and a mutator's result is available
    // immediately — no settle step, no `?T` standing in for "not resolved yet".
    var ctx = Cell.Ctx.init(testing.allocator);
    defer ctx.deinit();
    var ing: Cell = undefined;
    try ing.init(&ctx, .{}, merge.sum(u64), .event_channel, 25);
    defer ing.deinit();

    const first = try ing.admit(Cell.Envelope.init("alpha", 4, 0, 10, 1));
    try testing.expectEqual(@as(u64, 0), first.accepted.delivered_through);
    try testing.expectEqual(@as(?u64, 1), try ing.value("alpha"));

    const second = try ing.admit(Cell.Envelope.init("alpha", 4, 1, 12, 1));
    try testing.expectEqual(@as(u64, 1), second.conflated.delivered_through);
    try testing.expectEqual(@as(?u64, 2), try ing.value("alpha"));

    // suspend/reconnect hand back the replay request synchronously.
    const suspended = try ing.suspendScope("alpha");
    try testing.expectEqual(ReplayRequest{ .generation = 4, .from_sequence = 2 }, suspended.?);
    try testing.expectEqual(IngressReadiness.suspended, try ing.readiness("alpha"));
    // A disconnect retains the window and the watermark: replay, not resync.
    try testing.expectEqual(@as(?u64, 2), try ing.value("alpha"));

    const back = try ing.reconnect("alpha", 4);
    try testing.expectEqual(ReplayRequest{ .generation = 4, .from_sequence = 2 }, back);
    try testing.expectEqual(IngressReadiness.ready, try ing.readiness("alpha"));

    // A drain is an egress, not an ack.
    try testing.expectEqual(@as(?u64, 2), try ing.drain("alpha"));
    try testing.expectEqual(@as(?u64, 1), ing.view("alpha").?.delivered_through);
}

test "lazily/async_ingress: one admission is one enqueue per reader" {
    // The async graph's analogue of the frontier-walk gate: `setSource` enqueues,
    // and the `queued` flag bounds the queue to one entry per node, so a
    // transition that dirties four reader kinds costs one recompute per reader
    // rather than one per dirtied kind.
    var ctx = Cell.Ctx.init(testing.allocator);
    defer ctx.deinit();
    var ing: Cell = undefined;
    try ing.init(&ctx, .{}, merge.sum(u64), .event_channel, 25);
    defer ing.deinit();

    _ = try ing.value("alpha");
    _ = try ing.readiness("alpha");
    _ = try ing.authority("alpha");
    _ = try ing.retry("alpha");
    _ = try ing.acceptedLen();
    _ = try ing.droppedLen();
    _ = try ing.errorsLen();
    try testing.expectEqual(@as(usize, 0), try ing.settle());

    // Four scope kinds + the accepted channel = five dirtied readers, so five
    // computes. A sixth would mean a reader was enqueued twice.
    _ = try ing.admit(Cell.Envelope.init("alpha", 1, 0, 0, 5));
    try testing.expectEqual(@as(usize, 5), try ing.settle());

    // A buffered envelope enqueues nothing at all.
    _ = try ing.admit(Cell.Envelope.init("alpha", 1, 4, 0, 1));
    try testing.expectEqual(@as(usize, 0), try ing.settle());
}

test "lazily/async_ingress: construction validates overflow against the merge algebra" {
    var ctx = Cell.Ctx.init(testing.allocator);
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
