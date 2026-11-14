//! `ThreadSafeEgressCell` — the `ThreadSafeContext` flavor of the reactive
//! egress family (`#lzegress`).
//!
//! Delivery authority stays in the one shared [`EgressCore`](egress_core.zig),
//! serialized by a [`ParkingMutex`]; the graph only carries invalidation. Two
//! rules make the flavor sound:
//!
//! 1. **The core lock is never held across a graph write.** A reader's compute
//!    takes the core lock, so publishing with it held would invert the lock
//!    order against a concurrent read. Every mutator copies the transition's
//!    `EgressChange` out under the lock and publishes after releasing it.
//! 2. **The whole change set publishes inside one `batch()`.** A transition that
//!    dirties several reader kinds reruns a dependent Effect once, not once per
//!    kind, so no reader observes `new inflight, old pending`.
//!
//! One attached transport Effect per producer incarnation
//! ([`attachTransport`]): the attachment captures the generation current at
//! attach time and is inert at the core fence after a `reconnect`.
//!
//! The two list-valued readers (`pending`, `inflight`) carry their reader-kind
//! revision as the node value and hand the list out by copy under the core
//! lock: a borrowed slice into the core would be a data race the moment another
//! thread mutates it. `acked_through` and `retry` are plain values and are the
//! node values themselves.

const std = @import("std");
const ParkingMutex = @import("parking_mutex.zig").ParkingMutex;
const tsc = @import("thread_safe_context.zig");
const ThreadSafeContext = tsc.ThreadSafeContext;
const TsHandle = tsc.TsHandle;
const core_mod = @import("egress_core.zig");

pub const EgressCore = core_mod.EgressCore;
pub const EgressPolicy = core_mod.EgressPolicy;
pub const EgressRetry = core_mod.EgressRetry;
pub const EgressAck = core_mod.EgressAck;
pub const EgressFailure = core_mod.EgressFailure;
pub const EgressRetryAction = core_mod.EgressRetryAction;
pub const EgressReconnect = core_mod.EgressReconnect;
pub const EgressChange = core_mod.EgressChange;

pub fn ThreadSafeEgressCell(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Core = EgressCore(T);
        pub const Envelope = Core.Envelope;
        pub const Claim = Core.Claim;

        /// Closure emulation: what a reader's compute needs. Heap-boxed so its
        /// address is stable.
        const Binding = struct {
            owner: *Self,
            version: TsHandle(u64),
            counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        };

        const PublishOp = struct { cell: *Self, change: EgressChange };

        ctx: *ThreadSafeContext,
        allocator: std.mem.Allocator,
        /// Serializes the delivery algebra. Never held across a graph write.
        mutex: ParkingMutex,
        core: Core,
        /// Index order: pending, inflight, acked_through, retry.
        bindings: [4]*Binding,
        pending_reader: TsHandle(u64),
        inflight_reader: TsHandle(u64),
        acked_reader: TsHandle(?u64),
        retry_reader: TsHandle(?EgressRetry),
        /// Attached transports, woken after every publish. Guarded by its own
        /// lock, never held while a pump runs.
        attach_mutex: ParkingMutex = ParkingMutex.init(),
        wakers: [max_attachments]Waker = undefined,
        waker_count: usize = 0,

        /// Attachments per cell: one live incarnation plus fenced ones the caller
        /// has not detached yet.
        pub const max_attachments = 8;

        // --- compute closures ------------------------------------------------

        fn computeRevision(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) u64 {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            return cc.readNode(u64, b.version);
        }

        fn computeAcked(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) ?u64 {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            _ = cc.readNode(u64, b.version);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return b.owner.core.ackedThrough();
        }

        fn computeRetry(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) ?EgressRetry {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            _ = cc.readNode(u64, b.version);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return b.owner.core.retry();
        }

        // --- construction ----------------------------------------------------

        /// Build the cell in place: the reader bindings capture its address.
        pub fn init(
            self: *Self,
            ctx: *ThreadSafeContext,
            initial_generation: u64,
            policy: EgressPolicy,
        ) !void {
            var core = try Core.init(ctx.allocator, initial_generation, policy);
            errdefer core.deinit();
            self.* = .{
                .ctx = ctx,
                .allocator = ctx.allocator,
                .mutex = ParkingMutex.init(),
                .core = core,
                .bindings = undefined,
                .pending_reader = undefined,
                .inflight_reader = undefined,
                .acked_reader = undefined,
                .retry_reader = undefined,
            };
            var made: usize = 0;
            errdefer for (self.bindings[0..made]) |b| self.allocator.destroy(b);
            for (0..4) |i| {
                const version = try ctx.cell(u64, 0);
                const b = try self.allocator.create(Binding);
                b.* = .{ .owner = self, .version = version };
                self.bindings[i] = b;
                made += 1;
            }
            self.pending_reader = try ctx.computedClosure(u64, self.bindings[0], computeRevision);
            self.inflight_reader = try ctx.computedClosure(u64, self.bindings[1], computeRevision);
            self.acked_reader = try ctx.computedClosure(?u64, self.bindings[2], computeAcked);
            self.retry_reader = try ctx.computedClosure(?EgressRetry, self.bindings[3], computeRetry);
        }

        pub fn deinit(self: *Self) void {
            for (self.bindings) |b| self.allocator.destroy(b);
            self.core.deinit();
        }

        // --- reads -----------------------------------------------------------

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

        /// The pending records, copied out. Reading registers through the
        /// `pending` reader node, so its cache is current afterwards.
        pub fn pending(self: *Self, allocator: std.mem.Allocator) ![]Envelope {
            _ = self.ctx.get(u64, self.pending_reader);
            self.mutex.lock();
            defer self.mutex.unlock();
            return allocator.dupe(Envelope, self.core.pending());
        }

        /// The unacknowledged window, copied out.
        pub fn inflight(self: *Self, allocator: std.mem.Allocator) ![]Envelope {
            _ = self.ctx.get(u64, self.inflight_reader);
            self.mutex.lock();
            defer self.mutex.unlock();
            return allocator.dupe(Envelope, self.core.inflight());
        }

        pub fn ackedThrough(self: *Self) ?u64 {
            return self.ctx.get(?u64, self.acked_reader);
        }

        pub fn retry(self: *Self) ?EgressRetry {
            return self.ctx.get(?EgressRetry, self.retry_reader);
        }

        pub fn pendingHandle(self: *const Self) TsHandle(u64) {
            return self.pending_reader;
        }

        pub fn inflightHandle(self: *const Self) TsHandle(u64) {
            return self.inflight_reader;
        }

        pub fn ackedThroughHandle(self: *const Self) TsHandle(?u64) {
            return self.acked_reader;
        }

        pub fn retryHandle(self: *const Self) TsHandle(?EgressRetry) {
            return self.retry_reader;
        }

        /// Cache validity of the four reader nodes, in reader order. Introspection,
        /// never a read.
        pub fn validity(self: *Self) [4]bool {
            return .{
                self.ctx.isCacheValid(self.pending_reader.id),
                self.ctx.isCacheValid(self.inflight_reader.id),
                self.ctx.isCacheValid(self.acked_reader.id),
                self.ctx.isCacheValid(self.retry_reader.id),
            };
        }

        // --- invalidation ------------------------------------------------------

        fn bump(self: *Self, binding: *Binding) void {
            const next = binding.counter.fetchAdd(1, .monotonic) + 1;
            self.ctx.setCell(u64, binding.version, next);
        }

        fn batchBody(ptr: *anyopaque) void {
            const op: *PublishOp = @ptrCast(@alignCast(ptr));
            const self = op.cell;
            if (op.change.pending) self.bump(self.bindings[0]);
            if (op.change.inflight) self.bump(self.bindings[1]);
            if (op.change.acked_through) self.bump(self.bindings[2]);
            if (op.change.retry) self.bump(self.bindings[3]);
        }

        /// Publish with the core lock RELEASED, as one `batch()`.
        fn publish(self: *Self, change: EgressChange) void {
            if (change.isEmpty()) return;
            var op = PublishOp{ .cell = self, .change = change };
            self.ctx.batch(void, @ptrCast(&op), batchBody);
            // Every lock is released here: run whatever attachments the batch's
            // effect flush armed.
            self.wakeAll();
        }

        // --- mutators ----------------------------------------------------------

        pub fn enqueue(self: *Self, payload: T) !u64 {
            const t = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.enqueue(payload);
            };
            self.publish(t.change);
            return t.outcome;
        }

        pub fn claim(self: *Self, attachment_generation: u64) !Claim {
            const t = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.claim(attachment_generation);
            };
            self.publish(t.change);
            return t.outcome;
        }

        pub fn ack(self: *Self, attachment_generation: u64, through: u64) EgressAck {
            const t = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk self.core.ack(attachment_generation, through);
            };
            self.publish(t.change);
            return t.outcome;
        }

        pub fn fail(self: *Self, attachment_generation: u64, sequence: u64) !EgressFailure {
            const t = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.fail(attachment_generation, sequence);
            };
            self.publish(t.change);
            return t.outcome;
        }

        pub fn retryNow(self: *Self, attachment_generation: u64, sequence: u64) !EgressRetryAction {
            const t = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.retryNow(attachment_generation, sequence);
            };
            self.publish(t.change);
            return t.outcome;
        }

        pub fn reconnect(self: *Self, new_generation: u64) !EgressReconnect {
            const t = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.reconnect(new_generation);
            };
            self.publish(t.change);
            return t.outcome;
        }

        // --- transport attachment ----------------------------------------------

        /// Type-erased handle on one attachment, so `publish` can wake every
        /// attachment without knowing its transport type.
        const Waker = struct {
            ptr: *anyopaque,
            pump: *const fn (*anyopaque) void,
        };

        /// One transport Effect per incarnation. `Tr` is any type with
        /// `fn send(self: *Tr, envelope: Envelope) bool`; the caller keeps
        /// `transport` alive until `detach`.
        ///
        /// The Effect is the reactive trigger, not the sender. A
        /// `ThreadSafeContext` runs effect bodies under its graph lock, which is
        /// not reentrant, so a body that claimed (a graph write) would deadlock
        /// on itself. The body therefore only forms the edges (`pending`,
        /// `inflight`) and ARMS the attachment; the send loop runs right after
        /// the publishing graph write returns, on the publishing thread, with no
        /// lock held — the same "never hold a lock across a graph write" rule
        /// the mutators follow. `pumping` makes the loop single-flight per
        /// attachment, and the re-check after clearing it closes the lost-wake
        /// window against a concurrent publisher.
        pub fn Attachment(comptime Tr: type) type {
            return struct {
                const Att = @This();

                const State = struct {
                    cell: *Self,
                    transport: *Tr,
                    generation: u64,
                    armed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
                    pumping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
                };

                allocator: std.mem.Allocator,
                state: *State,
                effect: TsHandle(void),

                fn body(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) void {
                    const s: *State = @ptrCast(@alignCast(ptr));
                    // The window re-opening on an ack must re-run this Effect.
                    _ = cc.readNode(u64, s.cell.inflight_reader);
                    _ = cc.readNode(u64, s.cell.pending_reader);
                    s.armed.store(true, .release);
                }

                fn drain(s: *State) void {
                    while (true) {
                        const claimed = s.cell.claim(s.generation) catch return;
                        switch (claimed) {
                            .claimed => |envelope| {
                                if (!s.transport.send(envelope)) {
                                    _ = s.cell.fail(s.generation, envelope.sequence) catch {};
                                    return;
                                }
                            },
                            else => return,
                        }
                    }
                }

                fn pump(ptr: *anyopaque) void {
                    const s: *State = @ptrCast(@alignCast(ptr));
                    while (true) {
                        if (s.pumping.swap(true, .acq_rel)) return;
                        while (s.armed.swap(false, .acq_rel)) drain(s);
                        s.pumping.store(false, .release);
                        if (!s.armed.load(.acquire)) return;
                    }
                }

                pub fn detach(self: *Att) void {
                    const cell = self.state.cell;
                    cell.removeWaker(self.state);
                    cell.ctx.disposeNode(self.effect.id);
                    self.allocator.destroy(self.state);
                    self.* = undefined;
                }
            };
        }

        fn wakeAll(self: *Self) void {
            var local: [max_attachments]Waker = undefined;
            const n = blk: {
                self.attach_mutex.lock();
                defer self.attach_mutex.unlock();
                @memcpy(local[0..self.waker_count], self.wakers[0..self.waker_count]);
                break :blk self.waker_count;
            };
            for (local[0..n]) |w| w.pump(w.ptr);
        }

        fn removeWaker(self: *Self, ptr: *anyopaque) void {
            self.attach_mutex.lock();
            defer self.attach_mutex.unlock();
            for (self.wakers[0..self.waker_count], 0..) |w, i| {
                if (w.ptr == ptr) {
                    self.wakers[i] = self.wakers[self.waker_count - 1];
                    self.waker_count -= 1;
                    return;
                }
            }
        }

        pub fn attachTransport(self: *Self, comptime Tr: type, transport: *Tr) !Attachment(Tr) {
            const Att = Attachment(Tr);
            const state = try self.allocator.create(Att.State);
            errdefer self.allocator.destroy(state);
            state.* = .{ .cell = self, .transport = transport, .generation = self.generation() };
            {
                self.attach_mutex.lock();
                defer self.attach_mutex.unlock();
                if (self.waker_count == max_attachments) return error.TooManyAttachments;
                self.wakers[self.waker_count] = .{ .ptr = state, .pump = Att.pump };
                self.waker_count += 1;
            }
            errdefer self.removeWaker(state);
            const handle = try self.ctx.effectClosure(void, state, Att.body, null, null);
            // The Effect's first run armed it; send whatever is already pending.
            Att.pump(state);
            return .{ .allocator = self.allocator, .state = state, .effect = handle };
        }
    };
}

// ---------------------------------------------------------------------------
// Tests. The corpus replay lives in `egress_family_conformance.zig`; here is the
// transport attachment and cross-thread sharing of the one core.
// ---------------------------------------------------------------------------

const testing = std.testing;
const Cell = ThreadSafeEgressCell(u64);

const TestTransport = struct {
    mutex: ParkingMutex = ParkingMutex.init(),
    sent: std.ArrayList(u64) = .empty,

    fn deinit(self: *TestTransport) void {
        self.sent.deinit(testing.allocator);
    }

    pub fn send(self: *TestTransport, envelope: Cell.Envelope) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.sent.append(testing.allocator, envelope.sequence) catch return false;
        return true;
    }
};

test "lazily/thread_safe_egress: the attachment drives the shared projection" {
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();
    var egress: Cell = undefined;
    try egress.init(&ctx, 1, .{});
    defer egress.deinit();
    var transport: TestTransport = .{};
    defer transport.deinit();
    var attachment = try egress.attachTransport(TestTransport, &transport);
    defer attachment.detach();

    _ = try egress.enqueue(7);
    _ = try egress.enqueue(8);
    try testing.expectEqualSlices(u64, &.{ 0, 1 }, transport.sent.items);
    const window = try egress.inflight(testing.allocator);
    defer testing.allocator.free(window);
    try testing.expectEqual(@as(usize, 2), window.len);
}

test "lazily/thread_safe_egress: an ack reopens the window and reconnect fences the old attachment" {
    var ctx = ThreadSafeContext.init(testing.allocator);
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
    try testing.expectEqualSlices(u64, &.{0}, transport.sent.items);
    _ = egress.ack(1, 0);
    try testing.expectEqualSlices(u64, &.{ 0, 1 }, transport.sent.items);

    _ = try egress.reconnect(2);
    _ = try egress.enqueue(30);
    // Generation 1's attachment is fenced: nothing new reaches its transport.
    try testing.expectEqualSlices(u64, &.{ 0, 1 }, transport.sent.items);
}

test "lazily/thread_safe_egress: concurrent producers share one sequence space" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();
    var egress: Cell = undefined;
    try egress.init(&ctx, 1, .{});
    defer egress.deinit();

    const per_thread = 50;
    const Worker = struct {
        fn run(cell: *Cell) void {
            for (0..per_thread) |i| _ = cell.enqueue(i) catch unreachable;
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&egress});
    for (threads) |t| t.join();

    try testing.expectEqual(@as(u64, 4 * per_thread), egress.nextSequence());
    const pending = try egress.pending(testing.allocator);
    defer testing.allocator.free(pending);
    try testing.expectEqual(@as(usize, 4 * per_thread), pending.len);
    for (pending, 0..) |record, index| try testing.expectEqual(@as(u64, index), record.sequence);
}
