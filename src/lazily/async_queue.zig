//! The async flavor of the queue family (`#lzqueuefamilyflavors`):
//! `AsyncQueueCell`, `AsyncTopicCell`, `AsyncWorkQueueCell`.
//!
//! Same [`queue_core.zig`](queue_core.zig) algebra as the other two shells, over
//! [`AsyncContext`](async_context.zig).
//!
//! # Nothing here is async-coloured
//!
//! Whether a push is admissible is a function of the bound and the closed flag;
//! which delivery a lease expiry redelivers is a function of the deadlines and
//! the attempt count; which cursors a publish moves is a function of the
//! connected set. None of that is state the graph owns and none of it has to be
//! awaited. So **every** mutator below is synchronous and returns a plain value:
//! there is no `settle` step in the op surface, and no operation is `?T` for want
//! of one. Awaiting belongs to the producer and the consumer, and both are
//! outside the primitive by construction.
//!
//! Zig's `AsyncContext` is a no-runtime pending-compute queue rather than a
//! futures executor, so a derived node resolves when the queue is drained. The
//! reads here drive that drain themselves (`awaitComputed`), which is what keeps
//! the flavor-neutral surface identical to the other two. [`settle`] is exposed
//! for callers that want to drive it explicitly.
//!
//! # One frontier walk, structurally
//!
//! `AsyncContext.setSource` marks a dependent for recompute by *enqueuing* it, and
//! the `queued` flag bounds the queue to one entry per node. A pop that dirties
//! `head` + `len` + `is_full` therefore enqueues each reached reader once and the
//! next drain runs it once — no `batch()` boundary is needed to get what the
//! thread-safe shell has to ask for. Invalidation still runs with the core lock
//! released, for the same lock-ordering reason: a reader's compute takes the core
//! lock from inside the drain.
//!
//! # One value type
//!
//! `AsyncContext` is monomorphic in its node value type, so each primitive's
//! reader kinds travel as variants of one union — [`AsyncQueueRead`],
//! [`AsyncTopicRead`], [`AsyncWorkQueueRead`]. That is a Zig-specific encoding of
//! the same reader set, not a different contract.

const std = @import("std");
const ParkingMutex = @import("parking_mutex.zig").ParkingMutex;
const ac = @import("async_context.zig");
const AsyncContext = ac.AsyncContext;
const AsyncSource = ac.AsyncSource;
const AsyncComputed = ac.AsyncComputed;
const core_mod = @import("queue_core.zig");
const queue = @import("queue.zig");

pub const QueueCore = core_mod.QueueCore;
pub const QueueInvalidates = core_mod.QueueInvalidates;
pub const QueuePushError = core_mod.QueuePushError;
pub const QueuePopError = core_mod.QueuePopError;
pub const QueueVersions = core_mod.QueueVersions;
pub const TopicCore = core_mod.TopicCore;
pub const TopicDurability = core_mod.TopicDurability;
pub const TopicSnapshot = core_mod.TopicSnapshot;
pub const TopicSubscribeOutcome = core_mod.TopicSubscribeOutcome;
pub const TopicSubscriptionSnapshot = core_mod.TopicSubscriptionSnapshot;
pub const TopicWake = core_mod.TopicWake;
pub const VecDequeStorage = queue.VecDequeStorage;
pub const WorkQueueCore = core_mod.WorkQueueCore;
pub const WorkQueueDeadLetterReason = core_mod.WorkQueueDeadLetterReason;
pub const WorkQueueError = core_mod.WorkQueueError;
pub const WorkQueueInvalidates = core_mod.WorkQueueInvalidates;
pub const WorkQueueVersions = core_mod.WorkQueueVersions;

// ===========================================================================
// AsyncQueueCell
// ===========================================================================

/// Every value a queue node carries on the async graph. One union rather than one
/// context per reader kind, because `AsyncContext` is monomorphic in its node
/// value type.
pub fn AsyncQueueRead(comptime T: type) type {
    return union(enum) {
        /// A reader-kind version input: the graph write that clears its readers.
        version: u64,
        head: ?T,
        len: usize,
        is_empty: bool,
        is_full: bool,
        closed: bool,
    };
}

/// A reactive FIFO queue — SPSC primitive with an MPSC usage rule — on an
/// [`AsyncContext`].
///
/// The cell's address must be stable once constructed: every reader closure
/// reaches the cell through a heap-boxed binding (Zig has no closures), which is
/// why [`init`] fills a `*Self` in place rather than returning one.
pub fn AsyncQueueCell(comptime T: type, comptime S: type) type {
    return struct {
        const Self = @This();

        pub const Core = core_mod.QueueCore(T, S);
        pub const Read = AsyncQueueRead(T);
        pub const Ctx = AsyncContext(Read);

        const Kind = enum(usize) { head = 0, len = 1, is_empty = 2, is_full = 3, closed = 4 };

        const Binding = struct {
            owner: *Self,
            version: AsyncSource(Read),
            counter: u64 = 0,
        };

        ctx: *Ctx,
        allocator: std.mem.Allocator,
        /// Serializes the queue algebra. Never held across a graph write.
        mutex: ParkingMutex,
        core: Core,
        head_reader: AsyncComputed(Read),
        len_reader: AsyncComputed(Read),
        is_empty_reader: AsyncComputed(Read),
        is_full_reader: AsyncComputed(Read),
        closed_reader: AsyncComputed(Read),
        bindings: [5]*Binding,

        // --- compute closures ------------------------------------------------

        fn computeHead(ptr: *anyopaque, cc: *Ctx.ComputeContext) anyerror!Read {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            try cc.readCell(b.version.id);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return .{ .head = b.owner.core.peek() };
        }

        fn computeLen(ptr: *anyopaque, cc: *Ctx.ComputeContext) anyerror!Read {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            try cc.readCell(b.version.id);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return .{ .len = b.owner.core.len() };
        }

        fn computeIsEmpty(ptr: *anyopaque, cc: *Ctx.ComputeContext) anyerror!Read {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            try cc.readCell(b.version.id);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return .{ .is_empty = b.owner.core.isEmpty() };
        }

        fn computeIsFull(ptr: *anyopaque, cc: *Ctx.ComputeContext) anyerror!Read {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            try cc.readCell(b.version.id);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return .{ .is_full = b.owner.core.isFull() };
        }

        fn computeIsClosed(ptr: *anyopaque, cc: *Ctx.ComputeContext) anyerror!Read {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            try cc.readCell(b.version.id);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return .{ .closed = b.owner.core.isClosed() };
        }

        // --- construction ----------------------------------------------------

        pub fn init(self: *Self, ctx: *Ctx, storage: S) !void {
            self.* = .{
                .ctx = ctx,
                .allocator = ctx.allocator,
                .mutex = ParkingMutex.init(),
                .core = Core.init(storage),
                .head_reader = undefined,
                .len_reader = undefined,
                .is_empty_reader = undefined,
                .is_full_reader = undefined,
                .closed_reader = undefined,
                .bindings = undefined,
            };
            for (0..5) |i| {
                const version = try ctx.source(.{ .version = 0 });
                self.bindings[i] = try self.allocator.create(Binding);
                self.bindings[i].* = .{ .owner = self, .version = version };
            }
            self.head_reader = try ctx.computedClosure(
                self.bindings[@intFromEnum(Kind.head)],
                computeHead,
            );
            self.len_reader = try ctx.computedClosure(
                self.bindings[@intFromEnum(Kind.len)],
                computeLen,
            );
            self.is_empty_reader = try ctx.computedClosure(
                self.bindings[@intFromEnum(Kind.is_empty)],
                computeIsEmpty,
            );
            self.is_full_reader = try ctx.computedClosure(
                self.bindings[@intFromEnum(Kind.is_full)],
                computeIsFull,
            );
            self.closed_reader = try ctx.computedClosure(
                self.bindings[@intFromEnum(Kind.closed)],
                computeIsClosed,
            );
        }

        pub fn deinit(self: *Self) void {
            for (self.bindings) |b| self.allocator.destroy(b);
            self.core.deinit();
        }

        // --- invalidation ------------------------------------------------------

        fn bump(self: *Self, binding: *Binding) !void {
            binding.counter += 1;
            try self.ctx.setSource(binding.version, .{ .version = binding.counter });
        }

        /// Publish the collected change set, with the core lock RELEASED. Each
        /// reached reader is enqueued at most once, so the next drain is one
        /// frontier walk.
        fn publish(self: *Self, changed: QueueInvalidates) !void {
            if (!changed.any()) return;
            if (changed.head) try self.bump(self.bindings[@intFromEnum(Kind.head)]);
            if (changed.len) try self.bump(self.bindings[@intFromEnum(Kind.len)]);
            if (changed.is_empty) try self.bump(self.bindings[@intFromEnum(Kind.is_empty)]);
            if (changed.is_full) try self.bump(self.bindings[@intFromEnum(Kind.is_full)]);
            if (changed.closed) try self.bump(self.bindings[@intFromEnum(Kind.closed)]);
        }

        // --- mutators -----------------------------------------------------------

        pub fn tryPush(self: *Self, value: T) !void {
            const changed = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.tryPush(value);
            };
            try self.publish(changed);
        }

        pub fn tryPop(self: *Self) !T {
            const popped = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.tryPop();
            };
            try self.publish(popped.invalidates);
            return popped.value;
        }

        pub fn close(self: *Self) !void {
            const changed = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk self.core.close();
            };
            try self.publish(changed);
        }

        // --- reactive reads ---------------------------------------------------

        /// Drive the pending-compute queue to quiescence. The reads below do this
        /// for themselves; this is the explicit handle.
        pub fn settle(self: *Self) !usize {
            return self.ctx.settle();
        }

        pub fn head(self: *Self) !?T {
            return (try self.ctx.awaitComputed(self.head_reader)).head;
        }

        pub fn len(self: *Self) !usize {
            return (try self.ctx.awaitComputed(self.len_reader)).len;
        }

        pub fn isEmpty(self: *Self) !bool {
            return (try self.ctx.awaitComputed(self.is_empty_reader)).is_empty;
        }

        pub fn isFull(self: *Self) !bool {
            return (try self.ctx.awaitComputed(self.is_full_reader)).is_full;
        }

        pub fn isClosed(self: *Self) !bool {
            return (try self.ctx.awaitComputed(self.closed_reader)).closed;
        }

        // --- cache-validity probes -------------------------------------------

        pub fn headIsValid(self: *Self) bool {
            return self.ctx.isCacheValid(self.head_reader.id);
        }
        pub fn lenIsValid(self: *Self) bool {
            return self.ctx.isCacheValid(self.len_reader.id);
        }
        pub fn isEmptyIsValid(self: *Self) bool {
            return self.ctx.isCacheValid(self.is_empty_reader.id);
        }
        pub fn isFullIsValid(self: *Self) bool {
            return self.ctx.isCacheValid(self.is_full_reader.id);
        }
        pub fn closedIsValid(self: *Self) bool {
            return self.ctx.isCacheValid(self.closed_reader.id);
        }

        pub fn versions(self: *const Self) QueueVersions {
            return .{
                .head = self.bindings[@intFromEnum(Kind.head)].counter,
                .len = self.bindings[@intFromEnum(Kind.len)].counter,
                .is_empty = self.bindings[@intFromEnum(Kind.is_empty)].counter,
                .is_full = self.bindings[@intFromEnum(Kind.is_full)].counter,
                .closed = self.bindings[@intFromEnum(Kind.closed)].counter,
            };
        }

        // --- non-reactive projections ----------------------------------------

        pub fn capacity(self: *Self) ?usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.core.capacity();
        }

        pub fn items(self: *Self) []const T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.core.items();
        }
    };
}

/// Build an unbounded `AsyncQueueCell` over the reference backend, in place.
pub fn initUnbounded(
    comptime T: type,
    cell: *AsyncQueueCell(T, VecDequeStorage(T)),
    ctx: *AsyncQueueCell(T, VecDequeStorage(T)).Ctx,
) !void {
    return cell.init(ctx, VecDequeStorage(T).initUnbounded(ctx.allocator));
}

/// Build a bounded `AsyncQueueCell` over the reference backend, in place.
pub fn initBounded(
    comptime T: type,
    cell: *AsyncQueueCell(T, VecDequeStorage(T)),
    ctx: *AsyncQueueCell(T, VecDequeStorage(T)).Ctx,
    capacity: usize,
) !void {
    return cell.init(ctx, VecDequeStorage(T).initBounded(ctx.allocator, capacity));
}

// ===========================================================================
// AsyncTopicCell
// ===========================================================================

/// Every value a topic node carries on the async graph.
pub fn AsyncTopicRead(comptime T: type) type {
    return union(enum) {
        version: u64,
        /// The head of this subscriber's unread suffix.
        element: ?T,
    };
}

/// Broadcast topic with independent absolute cursors on an [`AsyncContext`].
pub fn AsyncTopicCell(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Core = core_mod.TopicCore(T);
        pub const Read = AsyncTopicRead(T);
        pub const Ctx = AsyncContext(Read);

        const Binding = struct {
            owner: *Self,
            id: []const u8,
            version: AsyncSource(Read),
            counter: u64 = 0,
        };
        const Reader = struct {
            value: AsyncComputed(Read),
            binding: *Binding,
        };

        /// One transition's wake set, copied out under the core lock so the graph
        /// write can happen with it released.
        const Plan = struct {
            bindings: std.ArrayList(*Binding) = .empty,

            fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
                self.bindings.deinit(allocator);
            }
        };

        ctx: *Ctx,
        allocator: std.mem.Allocator,
        mutex: ParkingMutex,
        core: Core,
        readers: std.StringHashMap(Reader),

        // --- compute closure --------------------------------------------------

        fn computeRead(ptr: *anyopaque, cc: *Ctx.ComputeContext) anyerror!Read {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            try cc.readCell(b.version.id);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return .{ .element = b.owner.core.readValue(b.id) catch null };
        }

        // --- construction ----------------------------------------------------

        pub fn init(self: *Self, ctx: *Ctx) void {
            self.* = .{
                .ctx = ctx,
                .allocator = ctx.allocator,
                .mutex = ParkingMutex.init(),
                .core = Core.init(ctx.allocator),
                .readers = std.StringHashMap(Reader).init(ctx.allocator),
            };
        }

        pub fn initFromSnapshot(self: *Self, ctx: *Ctx, saved: TopicSnapshot(T)) !void {
            const core = try Core.initFromSnapshot(ctx.allocator, saved);
            self.* = .{
                .ctx = ctx,
                .allocator = ctx.allocator,
                .mutex = ParkingMutex.init(),
                .core = core,
                .readers = std.StringHashMap(Reader).init(ctx.allocator),
            };
            errdefer self.deinit();
            for (saved.subscriptions) |saved_sub| {
                _ = try self.mintReader(saved_sub.subscriber_id);
            }
        }

        pub fn deinit(self: *Self) void {
            var iterator = self.readers.iterator();
            while (iterator.next()) |entry| {
                self.allocator.destroy(entry.value_ptr.binding);
                self.allocator.free(entry.key_ptr.*);
            }
            self.readers.deinit();
            self.core.deinit();
        }

        /// MUST be called with the core lock RELEASED — the first compute of a new
        /// node takes the core lock from inside the drain.
        fn mintReader(self: *Self, subscriber_id: []const u8) !*Reader {
            if (self.readers.getPtr(subscriber_id)) |existing| return existing;
            const owned_id = try self.allocator.dupe(u8, subscriber_id);
            errdefer self.allocator.free(owned_id);
            const version = try self.ctx.source(.{ .version = 0 });
            const binding = try self.allocator.create(Binding);
            errdefer self.allocator.destroy(binding);
            binding.* = .{ .owner = self, .version = version, .id = owned_id };
            const value = try self.ctx.computedClosure(binding, computeRead);
            try self.readers.put(owned_id, .{ .value = value, .binding = binding });
            return self.readers.getPtr(owned_id).?;
        }

        fn dropReader(self: *Self, subscriber_id: []const u8) void {
            const removed = self.readers.fetchRemove(subscriber_id) orelse return;
            self.ctx.disposeNode(removed.value.value.id);
            self.ctx.disposeNode(removed.value.binding.version.id);
            self.allocator.destroy(removed.value.binding);
            self.allocator.free(removed.key);
        }

        // --- invalidation ------------------------------------------------------

        /// Resolve the core's wake set against this shell's reader table. Runs
        /// WITH the core lock held; touches no graph node.
        fn collect(self: *Self, plan: *Plan, wake: TopicWake) !void {
            if (wake == .none) return;
            var iterator = self.readers.iterator();
            while (iterator.next()) |entry| {
                if (self.core.wakes(wake, entry.key_ptr.*)) {
                    try plan.bindings.append(self.allocator, entry.value_ptr.binding);
                }
            }
        }

        fn publish(self: *Self, plan: *const Plan) !void {
            for (plan.bindings.items) |binding| {
                binding.counter += 1;
                try self.ctx.setSource(binding.version, .{ .version = binding.counter });
            }
        }

        // --- mutators -----------------------------------------------------------

        pub fn subscribe(
            self: *Self,
            subscriber_id: []const u8,
            durability: TopicDurability,
        ) !TopicSubscribeOutcome {
            const result = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.subscribe(subscriber_id, durability);
            };
            if (result.change.minted) _ = try self.mintReader(subscriber_id);

            var plan: Plan = .{};
            defer plan.deinit(self.allocator);
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.collect(&plan, result.change.wake);
            }
            try self.publish(&plan);
            return result.outcome;
        }

        pub fn reconnect(self: *Self, subscriber_id: []const u8) !void {
            var plan: Plan = .{};
            defer plan.deinit(self.allocator);
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                const change = try self.core.reconnect(subscriber_id);
                try self.collect(&plan, change.wake);
            }
            try self.publish(&plan);
        }

        pub fn disconnect(self: *Self, subscriber_id: []const u8) !void {
            var plan: Plan = .{};
            defer plan.deinit(self.allocator);
            const removed = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                const change = try self.core.disconnect(subscriber_id);
                try self.collect(&plan, change.wake);
                break :blk change.removed;
            };
            if (removed) {
                self.dropReader(subscriber_id);
                return;
            }
            try self.publish(&plan);
        }

        pub fn publishValue(self: *Self, value: T) !usize {
            var plan: Plan = .{};
            defer plan.deinit(self.allocator);
            const offset = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                const result = try self.core.publish(value);
                try self.collect(&plan, result.change.wake);
                break :blk result.offset;
            };
            try self.publish(&plan);
            return offset;
        }

        pub fn advance(self: *Self, subscriber_id: []const u8, count: usize) !usize {
            var plan: Plan = .{};
            defer plan.deinit(self.allocator);
            const cursor = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                const result = try self.core.advance(subscriber_id, count);
                try self.collect(&plan, result.change.wake);
                break :blk result.cursor;
            };
            try self.publish(&plan);
            return cursor;
        }

        pub fn gc(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.core.gc();
        }

        pub fn restart(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            _ = self.core.restart();
        }

        // --- reactive reads ---------------------------------------------------

        pub fn settle(self: *Self) !usize {
            return self.ctx.settle();
        }

        pub fn read(self: *Self, subscriber_id: []const u8) !?T {
            const reader = self.readers.getPtr(subscriber_id) orelse
                return error.SubscriptionNotFound;
            return (try self.ctx.awaitComputed(reader.value)).element;
        }

        pub fn readIsValid(self: *Self, subscriber_id: []const u8) bool {
            const reader = self.readers.getPtr(subscriber_id) orelse return false;
            return self.ctx.isCacheValid(reader.value.id);
        }

        pub fn readerVersion(self: *const Self, subscriber_id: []const u8) ?u64 {
            const reader = self.readers.get(subscriber_id) orelse return null;
            return reader.binding.counter;
        }

        // --- non-reactive projections ----------------------------------------

        pub fn readStream(self: *Self, subscriber_id: []const u8) ![]const T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.core.readStream(subscriber_id);
        }

        pub fn baseOffset(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.core.baseOffset();
        }

        pub fn tailOffset(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.core.tailOffset();
        }

        pub fn items(self: *Self) []const T {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.core.items();
        }

        pub fn subscriptionCount(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.core.subscriptionCount();
        }

        pub fn subscription(
            self: *Self,
            subscriber_id: []const u8,
        ) ?TopicSubscriptionSnapshot {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.core.subscription(subscriber_id);
        }

        pub fn snapshot(self: *Self, allocator: std.mem.Allocator) !TopicSnapshot(T) {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.core.snapshot(allocator);
        }
    };
}

// ===========================================================================
// AsyncWorkQueueCell
// ===========================================================================

/// Every value a work-queue node carries on the async graph.
pub const AsyncWorkQueueRead = union(enum) {
    version: u64,
    count: usize,
    is_empty: bool,
};

/// Competing-consumer queue with leased exclusive claims on an
/// [`AsyncContext`].
pub fn AsyncWorkQueueCell(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Core = core_mod.WorkQueueCore(T);
        pub const Item = Core.Item;
        pub const Delivery = Core.Delivery;
        pub const DeadLetter = Core.DeadLetter;
        pub const Read = AsyncWorkQueueRead;
        pub const Ctx = AsyncContext(Read);

        const Kind = enum(usize) {
            pending_len = 0,
            is_empty = 1,
            in_flight_len = 2,
            dead_letter_len = 3,
        };

        const Binding = struct {
            owner: *Self,
            version: AsyncSource(Read),
            counter: u64 = 0,
        };

        ctx: *Ctx,
        allocator: std.mem.Allocator,
        mutex: ParkingMutex,
        core: Core,
        pending_reader: AsyncComputed(Read),
        empty_reader: AsyncComputed(Read),
        in_flight_reader: AsyncComputed(Read),
        dead_letter_reader: AsyncComputed(Read),
        bindings: [4]*Binding,

        // --- compute closures ------------------------------------------------

        fn computePendingLen(ptr: *anyopaque, cc: *Ctx.ComputeContext) anyerror!Read {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            try cc.readCell(b.version.id);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return .{ .count = b.owner.core.pendingLen() };
        }

        fn computeIsEmpty(ptr: *anyopaque, cc: *Ctx.ComputeContext) anyerror!Read {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            try cc.readCell(b.version.id);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return .{ .is_empty = b.owner.core.isEmpty() };
        }

        fn computeInFlightLen(ptr: *anyopaque, cc: *Ctx.ComputeContext) anyerror!Read {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            try cc.readCell(b.version.id);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return .{ .count = b.owner.core.inFlightLen() };
        }

        fn computeDeadLetterLen(ptr: *anyopaque, cc: *Ctx.ComputeContext) anyerror!Read {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            try cc.readCell(b.version.id);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return .{ .count = b.owner.core.deadLetterLen() };
        }

        // --- construction ----------------------------------------------------

        pub fn init(
            self: *Self,
            ctx: *Ctx,
            visibility_timeout: u64,
            max_deliveries: u64,
        ) !void {
            var core = try Core.init(ctx.allocator, visibility_timeout, max_deliveries);
            errdefer core.deinit();
            self.* = .{
                .ctx = ctx,
                .allocator = ctx.allocator,
                .mutex = ParkingMutex.init(),
                .core = core,
                .pending_reader = undefined,
                .empty_reader = undefined,
                .in_flight_reader = undefined,
                .dead_letter_reader = undefined,
                .bindings = undefined,
            };
            for (0..4) |i| {
                const version = try ctx.source(.{ .version = 0 });
                self.bindings[i] = try self.allocator.create(Binding);
                self.bindings[i].* = .{ .owner = self, .version = version };
            }
            self.pending_reader = try ctx.computedClosure(
                self.bindings[@intFromEnum(Kind.pending_len)],
                computePendingLen,
            );
            self.empty_reader = try ctx.computedClosure(
                self.bindings[@intFromEnum(Kind.is_empty)],
                computeIsEmpty,
            );
            self.in_flight_reader = try ctx.computedClosure(
                self.bindings[@intFromEnum(Kind.in_flight_len)],
                computeInFlightLen,
            );
            self.dead_letter_reader = try ctx.computedClosure(
                self.bindings[@intFromEnum(Kind.dead_letter_len)],
                computeDeadLetterLen,
            );
        }

        pub fn deinit(self: *Self) void {
            for (self.bindings) |b| self.allocator.destroy(b);
            self.core.deinit();
        }

        // --- invalidation ------------------------------------------------------

        fn bump(self: *Self, binding: *Binding) !void {
            binding.counter += 1;
            try self.ctx.setSource(binding.version, .{ .version = binding.counter });
        }

        fn publish(self: *Self, changed: WorkQueueInvalidates) !void {
            if (!changed.any()) return;
            if (changed.pending_len) try self.bump(self.bindings[@intFromEnum(Kind.pending_len)]);
            if (changed.in_flight_len) {
                try self.bump(self.bindings[@intFromEnum(Kind.in_flight_len)]);
            }
            if (changed.dead_letter_len) {
                try self.bump(self.bindings[@intFromEnum(Kind.dead_letter_len)]);
            }
            if (changed.is_empty) try self.bump(self.bindings[@intFromEnum(Kind.is_empty)]);
        }

        // --- mutators -----------------------------------------------------------

        pub fn push(self: *Self, value: T) !u64 {
            const pushed = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.push(value);
            };
            try self.publish(pushed.invalidates);
            return pushed.item_id;
        }

        pub fn claim(self: *Self, worker: []const u8, now: u64) !?Delivery {
            const claimed = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.claim(worker, now);
            };
            try self.publish(claimed.invalidates);
            return claimed.delivery;
        }

        pub fn ack(self: *Self, worker: []const u8, delivery_id: u64) !bool {
            const settled = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk self.core.ack(worker, delivery_id);
            };
            try self.publish(settled.invalidates);
            return settled.ok;
        }

        pub fn nack(self: *Self, worker: []const u8, delivery_id: u64) !bool {
            const settled = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.nack(worker, delivery_id);
            };
            try self.publish(settled.invalidates);
            return settled.ok;
        }

        pub fn reapExpired(self: *Self, now: u64) !usize {
            const reaped = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.reapExpired(now);
            };
            try self.publish(reaped.invalidates);
            return reaped.count;
        }

        // --- reactive reads ---------------------------------------------------

        pub fn settle(self: *Self) !usize {
            return self.ctx.settle();
        }

        pub fn pendingLen(self: *Self) !usize {
            return (try self.ctx.awaitComputed(self.pending_reader)).count;
        }
        pub fn isEmpty(self: *Self) !bool {
            return (try self.ctx.awaitComputed(self.empty_reader)).is_empty;
        }
        pub fn inFlightLen(self: *Self) !usize {
            return (try self.ctx.awaitComputed(self.in_flight_reader)).count;
        }
        pub fn deadLetterLen(self: *Self) !usize {
            return (try self.ctx.awaitComputed(self.dead_letter_reader)).count;
        }

        // --- cache-validity probes -------------------------------------------

        pub fn pendingLenIsValid(self: *Self) bool {
            return self.ctx.isCacheValid(self.pending_reader.id);
        }
        pub fn isEmptyIsValid(self: *Self) bool {
            return self.ctx.isCacheValid(self.empty_reader.id);
        }
        pub fn inFlightLenIsValid(self: *Self) bool {
            return self.ctx.isCacheValid(self.in_flight_reader.id);
        }
        pub fn deadLetterLenIsValid(self: *Self) bool {
            return self.ctx.isCacheValid(self.dead_letter_reader.id);
        }

        pub fn versions(self: *const Self) WorkQueueVersions {
            return .{
                .pending_len = self.bindings[@intFromEnum(Kind.pending_len)].counter,
                .is_empty = self.bindings[@intFromEnum(Kind.is_empty)].counter,
                .in_flight_len = self.bindings[@intFromEnum(Kind.in_flight_len)].counter,
                .dead_letter_len = self.bindings[@intFromEnum(Kind.dead_letter_len)].counter,
            };
        }

        // --- non-reactive projections ----------------------------------------

        pub fn pendingItems(self: *Self) []const Item {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.core.pendingItems();
        }

        pub fn deadLetterItems(self: *Self) []const DeadLetter {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.core.deadLetterItems();
        }

        pub fn inFlightDeliveries(
            self: *Self,
            allocator: std.mem.Allocator,
        ) ![]Delivery {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.core.inFlightDeliveries(allocator);
        }
    };
}

// ===========================================================================
// Tests
// ===========================================================================

const testing = std.testing;

test "lazily/async_queue: reader kinds are independent across the drain" {
    const Cell = AsyncQueueCell(i32, VecDequeStorage(i32));
    var ctx = Cell.Ctx.init(testing.allocator);
    defer ctx.deinit();

    var q: Cell = undefined;
    try initBounded(i32, &q, &ctx, 2);
    defer q.deinit();

    try testing.expect(try q.isEmpty());
    try q.tryPush(1);
    try testing.expectEqual(@as(?i32, 1), try q.head());
    const after_first = q.versions();
    try q.tryPush(2);
    const after_second = q.versions();
    // A push into a non-empty queue must not move head or emptiness.
    try testing.expectEqual(after_first.head, after_second.head);
    try testing.expectEqual(after_first.is_empty, after_second.is_empty);
    try testing.expect(after_second.len != after_first.len);
    try testing.expect(after_second.is_full != after_first.is_full);
    try testing.expect(try q.isFull());

    try testing.expectError(error.Full, q.tryPush(3));
    try testing.expectEqual(after_second, q.versions());

    try testing.expectEqual(@as(i32, 1), try q.tryPop());
    try testing.expectEqual(@as(?i32, 2), try q.head());
    try testing.expect(!(try q.isFull()));

    try q.close();
    try testing.expect(try q.isClosed());
    try testing.expectError(error.Closed, q.tryPush(4));
}

test "lazily/async_queue: one op enqueues each reached reader once" {
    const Cell = AsyncQueueCell(i32, VecDequeStorage(i32));
    var ctx = Cell.Ctx.init(testing.allocator);
    defer ctx.deinit();

    var q: Cell = undefined;
    try initBounded(i32, &q, &ctx, 1);
    defer q.deinit();

    // Warm every reader, then a push that dirties len + is_empty + is_full. The
    // `queued` flag is what bounds the drain to one compute per reader, so three
    // dirtied kinds must cost exactly three computes, not more.
    _ = try q.len();
    _ = try q.isEmpty();
    _ = try q.isFull();
    _ = try q.head();
    _ = try q.settle();

    try q.tryPush(7);
    try testing.expectEqual(@as(usize, 4), try q.settle());
}

test "lazily/async_queue: a topic wakes only the connected cursors" {
    const Cell = AsyncTopicCell([]const u8);
    var ctx = Cell.Ctx.init(testing.allocator);
    defer ctx.deinit();

    var topic: Cell = undefined;
    topic.init(&ctx);
    defer topic.deinit();

    _ = try topic.subscribe("a", .durable);
    _ = try topic.subscribe("b", .durable);
    _ = try topic.read("a");
    _ = try topic.read("b");

    _ = try topic.publishValue("one");
    try testing.expectEqualStrings("one", (try topic.read("a")).?);
    try testing.expectEqualStrings("one", (try topic.read("b")).?);

    try topic.disconnect("b");
    const b_offline = topic.readerVersion("b").?;
    _ = try topic.publishValue("two");
    try testing.expectEqual(b_offline, topic.readerVersion("b").?);
    // An offline durable cursor reads nothing, and still holds GC at its cursor.
    try testing.expectEqual(@as(?[]const u8, null), try topic.read("b"));
    try testing.expectEqual(@as(usize, 0), topic.gc());
}

test "lazily/async_queue: work-queue leases redeliver and dead-letter" {
    const Cell = AsyncWorkQueueCell([]const u8);
    var ctx = Cell.Ctx.init(testing.allocator);
    defer ctx.deinit();

    var wq: Cell = undefined;
    try wq.init(&ctx, 10, 2);
    defer wq.deinit();

    _ = try wq.push("job");
    try testing.expectEqual(@as(usize, 1), try wq.pendingLen());
    try testing.expect(!(try wq.isEmpty()));

    const first = (try wq.claim("w1", 0)).?;
    try testing.expectEqual(@as(u64, 1), first.attempt);
    try testing.expect(try wq.isEmpty());

    // Strictly-after expiry.
    try testing.expectEqual(@as(usize, 0), try wq.reapExpired(10));
    try testing.expectEqual(@as(usize, 1), try wq.reapExpired(11));
    try testing.expectEqual(@as(usize, 1), try wq.pendingLen());

    const second = (try wq.claim("w2", 20)).?;
    try testing.expectEqual(@as(u64, 2), second.attempt);
    try testing.expect(try wq.nack("w2", second.delivery_id));
    try testing.expectEqual(@as(usize, 1), try wq.deadLetterLen());
    try testing.expectEqual(@as(usize, 0), try wq.pendingLen());
    // A stale ack for a delivery that already dead-lettered changes nothing.
    const before = wq.versions();
    try testing.expect(!(try wq.ack("w2", second.delivery_id)));
    try testing.expectEqual(before, wq.versions());
}
