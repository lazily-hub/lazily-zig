//! `AsyncEgressCell` — the `AsyncContext` flavor of the reactive egress family
//! (`#lzegress`).
//!
//! Delivery authority is synchronous: every mutator and every delivery-state
//! read returns a plain value, because sequence assignment, the window, the
//! watermark, and the fence are state nothing has to await. The four readers
//! are ordinary computed nodes over the shared core. Only the transport
//! attachment ([`attachTransport`]) is async-coloured: it is an async Effect
//! the context's pending-compute queue drives (`settle`), which is where this
//! binding's `AsyncContext` puts work that runs off the caller's stack.
//!
//! `AsyncContext` is monomorphic in its node value type, so the reader values
//! and the version inputs travel as [`AsyncEgressRead`] variants — a
//! Zig-specific encoding of the same reader set, not a different contract.

const std = @import("std");
const ParkingMutex = @import("parking_mutex.zig").ParkingMutex;
const ac = @import("async_context.zig");
const AsyncContext = ac.AsyncContext;
const AsyncSource = ac.AsyncSource;
const AsyncComputed = ac.AsyncComputed;
const core_mod = @import("egress_core.zig");

pub const EgressCore = core_mod.EgressCore;
pub const EgressPolicy = core_mod.EgressPolicy;
pub const EgressRetry = core_mod.EgressRetry;
pub const EgressAck = core_mod.EgressAck;
pub const EgressFailure = core_mod.EgressFailure;
pub const EgressRetryAction = core_mod.EgressRetryAction;
pub const EgressReconnect = core_mod.EgressReconnect;
pub const EgressChange = core_mod.EgressChange;

/// Every value an egress node carries on the async graph.
pub const AsyncEgressRead = union(enum) {
    /// A reader-kind version input, and the value of the two list readers
    /// (whose lists are copied out under the core lock).
    version: u64,
    acked_through: ?u64,
    retry: ?EgressRetry,
    /// The value an attachment Effect resolves to.
    none,
};

pub fn AsyncEgressCell(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Core = EgressCore(T);
        pub const Envelope = Core.Envelope;
        pub const Claim = Core.Claim;
        pub const Read = AsyncEgressRead;
        pub const Ctx = AsyncContext(Read);

        const Binding = struct {
            owner: *Self,
            version: AsyncSource(Read),
            counter: u64 = 0,
        };

        ctx: *Ctx,
        allocator: std.mem.Allocator,
        /// Serializes the delivery algebra. Never held across a graph write.
        mutex: ParkingMutex,
        core: Core,
        /// Index order: pending, inflight, acked_through, retry.
        bindings: [4]*Binding,
        readers: [4]AsyncComputed(Read),

        // --- compute closures ------------------------------------------------

        fn computeRevision(ptr: *anyopaque, cc: *Ctx.ComputeContext) anyerror!Read {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            try cc.readCell(b.version.id);
            return .{ .version = b.counter };
        }

        fn computeAcked(ptr: *anyopaque, cc: *Ctx.ComputeContext) anyerror!Read {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            try cc.readCell(b.version.id);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return .{ .acked_through = b.owner.core.ackedThrough() };
        }

        fn computeRetry(ptr: *anyopaque, cc: *Ctx.ComputeContext) anyerror!Read {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            try cc.readCell(b.version.id);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return .{ .retry = b.owner.core.retry() };
        }

        // --- construction ----------------------------------------------------

        /// Build the cell in place: the reader bindings capture its address.
        pub fn init(self: *Self, ctx: *Ctx, initial_generation: u64, policy: EgressPolicy) !void {
            var core = try Core.init(ctx.allocator, initial_generation, policy);
            errdefer core.deinit();
            self.* = .{
                .ctx = ctx,
                .allocator = ctx.allocator,
                .mutex = ParkingMutex.init(),
                .core = core,
                .bindings = undefined,
                .readers = undefined,
            };
            var made: usize = 0;
            errdefer for (self.bindings[0..made]) |b| self.allocator.destroy(b);
            for (0..4) |i| {
                const version = try ctx.source(.{ .version = 0 });
                const b = try self.allocator.create(Binding);
                b.* = .{ .owner = self, .version = version };
                self.bindings[i] = b;
                made += 1;
            }
            self.readers[0] = try ctx.computedClosure(self.bindings[0], computeRevision);
            self.readers[1] = try ctx.computedClosure(self.bindings[1], computeRevision);
            self.readers[2] = try ctx.computedClosure(self.bindings[2], computeAcked);
            self.readers[3] = try ctx.computedClosure(self.bindings[3], computeRetry);
        }

        pub fn deinit(self: *Self) void {
            for (self.bindings) |b| self.allocator.destroy(b);
            self.core.deinit();
        }

        // --- reads -----------------------------------------------------------

        /// Drive the pending-compute queue (including attachment Effects) to
        /// quiescence. The reads below do this for themselves.
        pub fn settle(self: *Self) !usize {
            return self.ctx.settle();
        }

        pub fn generation(self: *Self) u64 {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.core.generation();
        }

        pub fn nextSequence(self: *Self) u64 {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.core.nextSequence();
        }

        pub fn pending(self: *Self, allocator: std.mem.Allocator) ![]Envelope {
            _ = try self.ctx.awaitComputed(self.readers[0]);
            self.mutex.lock();
            defer self.mutex.unlock();
            return allocator.dupe(Envelope, self.core.pending());
        }

        pub fn inflight(self: *Self, allocator: std.mem.Allocator) ![]Envelope {
            _ = try self.ctx.awaitComputed(self.readers[1]);
            self.mutex.lock();
            defer self.mutex.unlock();
            return allocator.dupe(Envelope, self.core.inflight());
        }

        pub fn ackedThrough(self: *Self) !?u64 {
            return (try self.ctx.awaitComputed(self.readers[2])).acked_through;
        }

        pub fn retry(self: *Self) !?EgressRetry {
            return (try self.ctx.awaitComputed(self.readers[3])).retry;
        }

        pub fn pendingHandle(self: *const Self) AsyncComputed(Read) {
            return self.readers[0];
        }

        pub fn inflightHandle(self: *const Self) AsyncComputed(Read) {
            return self.readers[1];
        }

        pub fn ackedThroughHandle(self: *const Self) AsyncComputed(Read) {
            return self.readers[2];
        }

        pub fn retryHandle(self: *const Self) AsyncComputed(Read) {
            return self.readers[3];
        }

        /// Cache validity of the four reader nodes, in reader order. Never
        /// settles.
        pub fn validity(self: *Self) [4]bool {
            var out: [4]bool = undefined;
            for (self.readers, 0..) |r, i| out[i] = self.ctx.isCacheValid(r.id);
            return out;
        }

        // --- invalidation ------------------------------------------------------

        fn bump(self: *Self, binding: *Binding) !void {
            binding.counter += 1;
            try self.ctx.setSource(binding.version, .{ .version = binding.counter });
        }

        /// Publish with the core lock RELEASED. `setSource` enqueues each reached
        /// node once (its `queued` flag bounds the queue), so a multi-kind
        /// transition still resolves every dependent in one drain.
        fn publish(self: *Self, change: EgressChange) !void {
            if (change.pending) try self.bump(self.bindings[0]);
            if (change.inflight) try self.bump(self.bindings[1]);
            if (change.acked_through) try self.bump(self.bindings[2]);
            if (change.retry) try self.bump(self.bindings[3]);
        }

        // --- mutators ----------------------------------------------------------

        pub fn enqueue(self: *Self, payload: T) !u64 {
            const t = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.enqueue(payload);
            };
            try self.publish(t.change);
            return t.outcome;
        }

        pub fn claim(self: *Self, attachment_generation: u64) !Claim {
            const t = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.claim(attachment_generation);
            };
            try self.publish(t.change);
            return t.outcome;
        }

        pub fn ack(self: *Self, attachment_generation: u64, through: u64) !EgressAck {
            const t = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk self.core.ack(attachment_generation, through);
            };
            try self.publish(t.change);
            return t.outcome;
        }

        pub fn fail(self: *Self, attachment_generation: u64, sequence: u64) !EgressFailure {
            const t = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.fail(attachment_generation, sequence);
            };
            try self.publish(t.change);
            return t.outcome;
        }

        pub fn retryNow(self: *Self, attachment_generation: u64, sequence: u64) !EgressRetryAction {
            const t = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.retryNow(attachment_generation, sequence);
            };
            try self.publish(t.change);
            return t.outcome;
        }

        pub fn reconnect(self: *Self, new_generation: u64) !EgressReconnect {
            const t = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.reconnect(new_generation);
            };
            try self.publish(t.change);
            return t.outcome;
        }

        // --- transport attachment ----------------------------------------------

        /// The async-coloured half: one transport Effect per incarnation, run by
        /// the context's pending-compute queue. `Tr` is any type with
        /// `fn send(self: *Tr, envelope: Envelope) bool`.
        pub fn Attachment(comptime Tr: type) type {
            return struct {
                const Att = @This();

                const State = struct {
                    cell: *Self,
                    transport: *Tr,
                    generation: u64,
                };

                allocator: std.mem.Allocator,
                state: *State,
                effect_id: u64,

                fn body(ptr: *anyopaque, cc: *Ctx.ComputeContext) anyerror!Read {
                    const s: *State = @ptrCast(@alignCast(ptr));
                    const cell = s.cell;
                    // Edges on the pending and inflight reader-kind inputs: an
                    // acknowledgement reopens the window and re-queues this Effect.
                    try cc.readCell(cell.bindings[1].version.id);
                    try cc.readCell(cell.bindings[0].version.id);
                    while (true) {
                        switch (try cell.claim(s.generation)) {
                            .claimed => |envelope| {
                                if (!s.transport.send(envelope)) {
                                    _ = try cell.fail(s.generation, envelope.sequence);
                                    break;
                                }
                            },
                            else => break,
                        }
                    }
                    return .none;
                }

                pub fn detach(self: *Att) void {
                    self.state.cell.ctx.disposeNode(self.effect_id);
                    self.allocator.destroy(self.state);
                    self.* = undefined;
                }
            };
        }

        pub fn attachTransport(self: *Self, comptime Tr: type, transport: *Tr) !Attachment(Tr) {
            const Att = Attachment(Tr);
            const state = try self.allocator.create(Att.State);
            errdefer self.allocator.destroy(state);
            state.* = .{ .cell = self, .transport = transport, .generation = self.generation() };
            const id = try self.ctx.effectAsyncClosure(state, Att.body, null, null);
            return .{ .allocator = self.allocator, .state = state, .effect_id = id };
        }
    };
}

// ---------------------------------------------------------------------------
// Tests. The corpus replay lives in `egress_family_conformance.zig`.
// ---------------------------------------------------------------------------

const testing = std.testing;
const Cell = AsyncEgressCell(u64);

const TestTransport = struct {
    sent: std.ArrayList(u64) = .empty,

    fn deinit(self: *TestTransport) void {
        self.sent.deinit(testing.allocator);
    }

    pub fn send(self: *TestTransport, envelope: Cell.Envelope) bool {
        self.sent.append(testing.allocator, envelope.sequence) catch return false;
        return true;
    }
};

test "lazily/async_egress: the async attachment sends only when the queue is driven" {
    var ctx = Cell.Ctx.init(testing.allocator);
    defer ctx.deinit();
    var egress: Cell = undefined;
    try egress.init(&ctx, 1, .{ .inflight_limit = 1 });
    defer egress.deinit();
    var transport: TestTransport = .{};
    defer transport.deinit();
    var attachment = try egress.attachTransport(TestTransport, &transport);
    defer attachment.detach();

    _ = try egress.enqueue(10);
    _ = try egress.enqueue(20);
    // Delivery state is synchronous; the transport is not run on the caller's
    // stack.
    try testing.expectEqual(@as(usize, 0), transport.sent.items.len);
    _ = try egress.settle();
    try testing.expectEqualSlices(u64, &.{0}, transport.sent.items);

    try testing.expectEqual(EgressAck{ .advanced = 0 }, try egress.ack(1, 0));
    _ = try egress.settle();
    try testing.expectEqualSlices(u64, &.{ 0, 1 }, transport.sent.items);
    const pending = try egress.pending(testing.allocator);
    defer testing.allocator.free(pending);
    try testing.expectEqual(@as(usize, 0), pending.len);
}

test "lazily/async_egress: reconnect makes the old attachment inert" {
    var ctx = Cell.Ctx.init(testing.allocator);
    defer ctx.deinit();
    var egress: Cell = undefined;
    try egress.init(&ctx, 3, .{});
    defer egress.deinit();
    var old: TestTransport = .{};
    defer old.deinit();
    var old_attachment = try egress.attachTransport(TestTransport, &old);
    defer old_attachment.detach();

    _ = try egress.enqueue(10);
    _ = try egress.settle();
    _ = try egress.reconnect(4);
    _ = try egress.enqueue(20);
    _ = try egress.settle();
    try testing.expectEqualSlices(u64, &.{0}, old.sent.items);

    var fresh: TestTransport = .{};
    defer fresh.deinit();
    var fresh_attachment = try egress.attachTransport(TestTransport, &fresh);
    defer fresh_attachment.detach();
    _ = try egress.settle();
    try testing.expectEqualSlices(u64, &.{ 0, 1 }, fresh.sent.items);
}
