//! The `Send + Sync` flavor of the queue family (`#lzqueuefamilyflavors`):
//! `ThreadSafeQueueCell`, `ThreadSafeTopicCell`, `ThreadSafeWorkQueueCell`.
//!
//! Same [`queue_core.zig`](queue_core.zig) algebra as the single-threaded shells
//! in `queue.zig` / `work_queue.zig`; what differs is only where the graph lives
//! and how invalidation is published. Three rules are load-bearing here and
//! nowhere else — the same three `thread_safe_ingress.zig` states, for the same
//! reasons:
//!
//! 1. **Invalidation runs OUTSIDE the core lock.** A reader's compute takes the
//!    context lock and then the core lock (it must read queue state to derive its
//!    value). An op that invalidated while still holding the core lock would take
//!    those in the opposite order and deadlock. So every mutator takes the core
//!    lock, computes the transition, copies the reported change set into a
//!    call-local plan, RELEASES the lock, and only then touches the graph.
//!
//! 2. **The whole change set publishes inside one `batch()`.** `ThreadSafeContext`
//!    marks cones dirty inline but defers the *effect flush* to the outermost
//!    batch exit, so a pop that dirties `head` + `len` + `is_full` reruns each
//!    reached effect once rather than three times. Without the batch, one pop is
//!    three frontier walks and a consumer can observe `len` already decremented
//!    while `is_full` still reads `true` — a partial fan-out that makes the
//!    backpressure signal a lie.
//!
//! 3. **The plan is call-local.** A shared scratch buffer would let one thread
//!    publish another's change set, so the plan lives on the caller's stack (a
//!    `QueueInvalidates` value, or a per-call `ArrayList` of bindings for the
//!    topic's per-subscriber fan-out). Each per-reader version counter is atomic
//!    so two concurrent bumps cannot collapse into one write — `setCell`'s
//!    equality guard would swallow the second otherwise.
//!
//! **Admission and ordering are not thread-coloured.** Whether a push is
//! admissible is a function of the bound and the closed flag; which delivery a
//! lease expiry redelivers is a function of the deadlines and the attempt count.
//! The mutex serializes access to that state; it does not change a single
//! decision. So every mutator below is synchronous and returns a plain value,
//! there is no `settle` step in the surface, and the flavor axis stays out of the
//! conformance corpus entirely.
//!
//! Minting a topic subscriber's reader ([`ThreadSafeTopicCell.subscribe`]) mutates
//! a plain hash map and is **not** itself a synchronized surface — subscribe every
//! id a concurrent workload will touch before spawning. Publishing never mints: an
//! id nothing has read has no observer to invalidate.

const std = @import("std");
const ParkingMutex = @import("parking_mutex.zig").ParkingMutex;
const tsc = @import("thread_safe_context.zig");
const ThreadSafeContext = tsc.ThreadSafeContext;
const TsHandle = tsc.TsHandle;
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

/// Closure emulation (Zig has none): what a reader's compute needs to reach its
/// cell and register its one dependency edge.
///
/// `counter` makes each bump a distinct value, so `setCell`'s equality guard can
/// never swallow one of two concurrent bumps.
fn VersionBinding(comptime Owner: type) type {
    return struct {
        owner: *Owner,
        version: TsHandle(u64),
        counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
        /// Only the topic needs this; the fixed-reader cells leave it empty.
        id: []const u8 = &[_]u8{},
    };
}

// ===========================================================================
// ThreadSafeQueueCell
// ===========================================================================

/// A reactive FIFO queue — SPSC primitive with an MPSC usage rule — on a
/// [`ThreadSafeContext`], so a queue can live in an owner shared across threads.
///
/// The cell's address must be stable once constructed: every reader closure
/// reaches the cell through a heap-boxed binding, which is why [`init`] fills a
/// `*Self` in place rather than returning one.
pub fn ThreadSafeQueueCell(comptime T: type, comptime S: type) type {
    return struct {
        const Self = @This();

        pub const Core = core_mod.QueueCore(T, S);
        const Binding = VersionBinding(Self);

        /// Index order of `bindings`, and of the flags in `QueueInvalidates`.
        const Kind = enum(usize) { head = 0, len = 1, is_empty = 2, is_full = 3, closed = 4 };

        const PublishOp = struct { cell: *Self, changed: QueueInvalidates };

        ctx: *ThreadSafeContext,
        allocator: std.mem.Allocator,
        /// Serializes the queue algebra. Never held across a graph write.
        mutex: ParkingMutex,
        core: Core,
        head_reader: TsHandle(?T),
        len_reader: TsHandle(usize),
        is_empty_reader: TsHandle(bool),
        is_full_reader: TsHandle(bool),
        closed_reader: TsHandle(bool),
        bindings: [5]*Binding,

        // --- compute closures ------------------------------------------------

        fn computeHead(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) ?T {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            _ = cc.readNode(u64, b.version);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return b.owner.core.peek();
        }

        fn computeLen(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) usize {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            _ = cc.readNode(u64, b.version);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return b.owner.core.len();
        }

        fn computeIsEmpty(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) bool {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            _ = cc.readNode(u64, b.version);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return b.owner.core.isEmpty();
        }

        fn computeIsFull(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) bool {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            _ = cc.readNode(u64, b.version);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return b.owner.core.isFull();
        }

        fn computeIsClosed(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) bool {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            _ = cc.readNode(u64, b.version);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return b.owner.core.isClosed();
        }

        // --- construction ----------------------------------------------------

        /// Build the cell in place. Takes `*Self` rather than returning one
        /// because the reader bindings capture the cell's address, so it must be
        /// at its final location before any node is minted.
        pub fn init(self: *Self, ctx: *ThreadSafeContext, storage: S) !void {
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
                const version = try ctx.cell(u64, 0);
                self.bindings[i] = try self.allocator.create(Binding);
                self.bindings[i].* = .{ .owner = self, .version = version };
            }
            self.head_reader = try ctx.computedClosure(
                ?T,
                self.bindings[@intFromEnum(Kind.head)],
                computeHead,
            );
            self.len_reader = try ctx.computedClosure(
                usize,
                self.bindings[@intFromEnum(Kind.len)],
                computeLen,
            );
            self.is_empty_reader = try ctx.computedClosure(
                bool,
                self.bindings[@intFromEnum(Kind.is_empty)],
                computeIsEmpty,
            );
            self.is_full_reader = try ctx.computedClosure(
                bool,
                self.bindings[@intFromEnum(Kind.is_full)],
                computeIsFull,
            );
            self.closed_reader = try ctx.computedClosure(
                bool,
                self.bindings[@intFromEnum(Kind.closed)],
                computeIsClosed,
            );
        }

        pub fn deinit(self: *Self) void {
            for (self.bindings) |b| self.allocator.destroy(b);
            self.core.deinit();
        }

        // --- invalidation ------------------------------------------------------

        fn bump(self: *Self, binding: *Binding) void {
            const next = binding.counter.fetchAdd(1, .monotonic) + 1;
            self.ctx.setCell(u64, binding.version, next);
        }

        fn batchBody(ptr: *anyopaque) void {
            const op: *PublishOp = @ptrCast(@alignCast(ptr));
            const self = op.cell;
            if (op.changed.head) self.bump(self.bindings[@intFromEnum(Kind.head)]);
            if (op.changed.len) self.bump(self.bindings[@intFromEnum(Kind.len)]);
            if (op.changed.is_empty) self.bump(self.bindings[@intFromEnum(Kind.is_empty)]);
            if (op.changed.is_full) self.bump(self.bindings[@intFromEnum(Kind.is_full)]);
            if (op.changed.closed) self.bump(self.bindings[@intFromEnum(Kind.closed)]);
        }

        /// Publish the collected change set. Called with the core lock RELEASED,
        /// wrapped in one `batch()` so the whole set is one frontier walk.
        fn publish(self: *Self, changed: QueueInvalidates) void {
            if (!changed.any()) return;
            var op = PublishOp{ .cell = self, .changed = changed };
            self.ctx.batch(void, @ptrCast(&op), batchBody);
        }

        // --- mutators -----------------------------------------------------------

        pub fn tryPush(self: *Self, value: T) QueuePushError!void {
            const changed = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.tryPush(value);
            };
            self.publish(changed);
        }

        pub fn tryPop(self: *Self) QueuePopError!T {
            const popped = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.tryPop();
            };
            self.publish(popped.invalidates);
            return popped.value;
        }

        pub fn close(self: *Self) void {
            const changed = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk self.core.close();
            };
            self.publish(changed);
        }

        // --- reactive reads ---------------------------------------------------

        pub fn head(self: *Self) ?T {
            return self.ctx.get(?T, self.head_reader);
        }

        pub fn len(self: *Self) usize {
            return self.ctx.get(usize, self.len_reader);
        }

        pub fn isEmpty(self: *Self) bool {
            return self.ctx.get(bool, self.is_empty_reader);
        }

        pub fn isFull(self: *Self) bool {
            return self.ctx.get(bool, self.is_full_reader);
        }

        pub fn isClosed(self: *Self) bool {
            return self.ctx.get(bool, self.closed_reader);
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

        /// The per-reader-kind bump counters, in the same shape the
        /// single-threaded shell reports. Diff two snapshots across an op to
        /// observe exactly which reader kinds it invalidated.
        pub fn versions(self: *const Self) QueueVersions {
            return .{
                .head = self.bindings[@intFromEnum(Kind.head)].counter.load(.monotonic),
                .len = self.bindings[@intFromEnum(Kind.len)].counter.load(.monotonic),
                .is_empty = self.bindings[@intFromEnum(Kind.is_empty)].counter.load(.monotonic),
                .is_full = self.bindings[@intFromEnum(Kind.is_full)].counter.load(.monotonic),
                .closed = self.bindings[@intFromEnum(Kind.closed)].counter.load(.monotonic),
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

/// Build an unbounded `ThreadSafeQueueCell` over the reference backend, in place.
pub fn initUnbounded(
    comptime T: type,
    cell: *ThreadSafeQueueCell(T, VecDequeStorage(T)),
    ctx: *ThreadSafeContext,
) !void {
    return cell.init(ctx, VecDequeStorage(T).initUnbounded(ctx.allocator));
}

/// Build a bounded `ThreadSafeQueueCell` over the reference backend, in place.
pub fn initBounded(
    comptime T: type,
    cell: *ThreadSafeQueueCell(T, VecDequeStorage(T)),
    ctx: *ThreadSafeContext,
    capacity: usize,
) !void {
    return cell.init(ctx, VecDequeStorage(T).initBounded(ctx.allocator, capacity));
}

// ===========================================================================
// ThreadSafeTopicCell
// ===========================================================================

/// Broadcast topic with independent absolute cursors on a
/// [`ThreadSafeContext`].
///
/// Unlike the queue and work-queue shells, this cell's reader set grows at
/// runtime, one node per subscriber. The publish plan is therefore a per-call
/// `ArrayList` of bindings rather than a fixed struct of flags — resolved against
/// this shell's own reader table by [`TopicCore.wakes`], under the core lock, and
/// bumped after it is released.
pub fn ThreadSafeTopicCell(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Core = core_mod.TopicCore(T);
        const Binding = VersionBinding(Self);
        const Reader = struct {
            value: TsHandle(?T),
            binding: *Binding,
        };

        /// One transition's wake set, copied out under the core lock so the graph
        /// write can happen with it released. Lives on the caller's stack: a
        /// shared buffer would let one thread publish another's change set.
        const Plan = struct {
            bindings: std.ArrayList(*Binding) = .empty,

            fn deinit(self: *Plan, allocator: std.mem.Allocator) void {
                self.bindings.deinit(allocator);
            }
        };

        const PublishOp = struct { cell: *Self, plan: *const Plan };

        ctx: *ThreadSafeContext,
        allocator: std.mem.Allocator,
        /// Serializes the log and the cursors. Never held across a graph write.
        mutex: ParkingMutex,
        core: Core,
        /// Reader identity per subscriber, keyed by this map's OWN duped id.
        readers: std.StringHashMap(Reader),

        // --- compute closure --------------------------------------------------

        fn computeRead(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) ?T {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            _ = cc.readNode(u64, b.version);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            // A subscription the core has dropped reads `null` rather than
            // failing: the shell disposes the node right after, and disposal is
            // the observation callers act on.
            return b.owner.core.readValue(b.id) catch null;
        }

        // --- construction ----------------------------------------------------

        pub fn init(self: *Self, ctx: *ThreadSafeContext) void {
            self.* = .{
                .ctx = ctx,
                .allocator = ctx.allocator,
                .mutex = ParkingMutex.init(),
                .core = Core.init(ctx.allocator),
                .readers = std.StringHashMap(Reader).init(ctx.allocator),
            };
        }

        pub fn initFromSnapshot(
            self: *Self,
            ctx: *ThreadSafeContext,
            saved: TopicSnapshot(T),
        ) !void {
            // The core validates before storing anything, so a rejected snapshot
            // mints no reader.
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

        /// MUST be called with the core lock RELEASED — minting a derived node
        /// runs its first compute, which takes the core lock. Not synchronized:
        /// see the module header.
        fn mintReader(self: *Self, subscriber_id: []const u8) !*Reader {
            if (self.readers.getPtr(subscriber_id)) |existing| return existing;
            const owned_id = try self.allocator.dupe(u8, subscriber_id);
            errdefer self.allocator.free(owned_id);
            const version = try self.ctx.cell(u64, 0);
            const binding = try self.allocator.create(Binding);
            errdefer self.allocator.destroy(binding);
            // The binding holds the map's own id, so the reader outlives the
            // caller's slice.
            binding.* = .{ .owner = self, .version = version, .id = owned_id };
            const value = try self.ctx.computedClosure(?T, binding, computeRead);
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

        fn bump(self: *Self, binding: *Binding) void {
            const next = binding.counter.fetchAdd(1, .monotonic) + 1;
            self.ctx.setCell(u64, binding.version, next);
        }

        fn batchBody(ptr: *anyopaque) void {
            const op: *PublishOp = @ptrCast(@alignCast(ptr));
            for (op.plan.bindings.items) |binding| op.cell.bump(binding);
        }

        fn publish(self: *Self, plan: *const Plan) void {
            if (plan.bindings.items.len == 0) return;
            var op = PublishOp{ .cell = self, .plan = plan };
            self.ctx.batch(void, @ptrCast(&op), batchBody);
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
            // Mint with the lock released: the first compute takes it.
            if (result.change.minted) _ = try self.mintReader(subscriber_id);

            var plan: Plan = .{};
            defer plan.deinit(self.allocator);
            {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.collect(&plan, result.change.wake);
            }
            self.publish(&plan);
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
            self.publish(&plan);
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
                // Disposal is strictly stronger than a bump: every reader of a
                // removed ephemeral becomes invalid, not merely stale.
                self.dropReader(subscriber_id);
                return;
            }
            self.publish(&plan);
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
            self.publish(&plan);
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
            self.publish(&plan);
            return cursor;
        }

        /// Drops the safe prefix. No cursor moves, so nothing is invalidated.
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

        pub fn read(self: *Self, subscriber_id: []const u8) !?T {
            const reader = self.readers.getPtr(subscriber_id) orelse
                return error.SubscriptionNotFound;
            return self.ctx.get(?T, reader.value);
        }

        pub fn readIsValid(self: *Self, subscriber_id: []const u8) bool {
            const reader = self.readers.getPtr(subscriber_id) orelse return false;
            return self.ctx.isCacheValid(reader.value.id);
        }

        pub fn readerVersion(self: *const Self, subscriber_id: []const u8) ?u64 {
            const reader = self.readers.get(subscriber_id) orelse return null;
            return reader.binding.counter.load(.monotonic);
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
// ThreadSafeWorkQueueCell
// ===========================================================================

/// Competing-consumer queue with leased exclusive claims on a
/// [`ThreadSafeContext`] — the flavor a real worker pool needs, since its
/// consumers are threads by construction.
pub fn ThreadSafeWorkQueueCell(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Core = core_mod.WorkQueueCore(T);
        pub const Item = Core.Item;
        pub const Delivery = Core.Delivery;
        pub const DeadLetter = Core.DeadLetter;

        const Binding = VersionBinding(Self);
        const Kind = enum(usize) {
            pending_len = 0,
            is_empty = 1,
            in_flight_len = 2,
            dead_letter_len = 3,
        };
        const PublishOp = struct { cell: *Self, changed: WorkQueueInvalidates };

        ctx: *ThreadSafeContext,
        allocator: std.mem.Allocator,
        /// Serializes the lease algebra. Never held across a graph write.
        mutex: ParkingMutex,
        core: Core,
        pending_reader: TsHandle(usize),
        empty_reader: TsHandle(bool),
        in_flight_reader: TsHandle(usize),
        dead_letter_reader: TsHandle(usize),
        bindings: [4]*Binding,

        // --- compute closures ------------------------------------------------

        fn computePendingLen(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) usize {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            _ = cc.readNode(u64, b.version);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return b.owner.core.pendingLen();
        }

        fn computeIsEmpty(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) bool {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            _ = cc.readNode(u64, b.version);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return b.owner.core.isEmpty();
        }

        fn computeInFlightLen(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) usize {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            _ = cc.readNode(u64, b.version);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return b.owner.core.inFlightLen();
        }

        fn computeDeadLetterLen(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) usize {
            const b: *Binding = @ptrCast(@alignCast(ptr));
            _ = cc.readNode(u64, b.version);
            b.owner.mutex.lock();
            defer b.owner.mutex.unlock();
            return b.owner.core.deadLetterLen();
        }

        // --- construction ----------------------------------------------------

        pub fn init(
            self: *Self,
            ctx: *ThreadSafeContext,
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
                const version = try ctx.cell(u64, 0);
                self.bindings[i] = try self.allocator.create(Binding);
                self.bindings[i].* = .{ .owner = self, .version = version };
            }
            self.pending_reader = try ctx.computedClosure(
                usize,
                self.bindings[@intFromEnum(Kind.pending_len)],
                computePendingLen,
            );
            self.empty_reader = try ctx.computedClosure(
                bool,
                self.bindings[@intFromEnum(Kind.is_empty)],
                computeIsEmpty,
            );
            self.in_flight_reader = try ctx.computedClosure(
                usize,
                self.bindings[@intFromEnum(Kind.in_flight_len)],
                computeInFlightLen,
            );
            self.dead_letter_reader = try ctx.computedClosure(
                usize,
                self.bindings[@intFromEnum(Kind.dead_letter_len)],
                computeDeadLetterLen,
            );
        }

        pub fn deinit(self: *Self) void {
            for (self.bindings) |b| self.allocator.destroy(b);
            self.core.deinit();
        }

        // --- invalidation ------------------------------------------------------

        fn bump(self: *Self, binding: *Binding) void {
            const next = binding.counter.fetchAdd(1, .monotonic) + 1;
            self.ctx.setCell(u64, binding.version, next);
        }

        fn batchBody(ptr: *anyopaque) void {
            const op: *PublishOp = @ptrCast(@alignCast(ptr));
            const self = op.cell;
            if (op.changed.pending_len) self.bump(self.bindings[@intFromEnum(Kind.pending_len)]);
            if (op.changed.in_flight_len) self.bump(self.bindings[@intFromEnum(Kind.in_flight_len)]);
            if (op.changed.dead_letter_len) {
                self.bump(self.bindings[@intFromEnum(Kind.dead_letter_len)]);
            }
            if (op.changed.is_empty) self.bump(self.bindings[@intFromEnum(Kind.is_empty)]);
        }

        fn publish(self: *Self, changed: WorkQueueInvalidates) void {
            if (!changed.any()) return;
            var op = PublishOp{ .cell = self, .changed = changed };
            self.ctx.batch(void, @ptrCast(&op), batchBody);
        }

        // --- mutators -----------------------------------------------------------

        pub fn push(self: *Self, value: T) !u64 {
            const pushed = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.push(value);
            };
            self.publish(pushed.invalidates);
            return pushed.item_id;
        }

        pub fn claim(self: *Self, worker: []const u8, now: u64) !?Delivery {
            const claimed = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.claim(worker, now);
            };
            self.publish(claimed.invalidates);
            return claimed.delivery;
        }

        pub fn ack(self: *Self, worker: []const u8, delivery_id: u64) bool {
            const settled = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk self.core.ack(worker, delivery_id);
            };
            self.publish(settled.invalidates);
            return settled.ok;
        }

        pub fn nack(self: *Self, worker: []const u8, delivery_id: u64) !bool {
            const settled = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.nack(worker, delivery_id);
            };
            self.publish(settled.invalidates);
            return settled.ok;
        }

        pub fn reapExpired(self: *Self, now: u64) !usize {
            const reaped = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.reapExpired(now);
            };
            self.publish(reaped.invalidates);
            return reaped.count;
        }

        // --- reactive reads ---------------------------------------------------

        pub fn pendingLen(self: *Self) usize {
            return self.ctx.get(usize, self.pending_reader);
        }
        pub fn isEmpty(self: *Self) bool {
            return self.ctx.get(bool, self.empty_reader);
        }
        pub fn inFlightLen(self: *Self) usize {
            return self.ctx.get(usize, self.in_flight_reader);
        }
        pub fn deadLetterLen(self: *Self) usize {
            return self.ctx.get(usize, self.dead_letter_reader);
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
                .pending_len = self.bindings[@intFromEnum(Kind.pending_len)]
                    .counter.load(.monotonic),
                .is_empty = self.bindings[@intFromEnum(Kind.is_empty)]
                    .counter.load(.monotonic),
                .in_flight_len = self.bindings[@intFromEnum(Kind.in_flight_len)]
                    .counter.load(.monotonic),
                .dead_letter_len = self.bindings[@intFromEnum(Kind.dead_letter_len)]
                    .counter.load(.monotonic),
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

test "lazily/thread_safe_queue: reader kinds are independent and derived nodes rerun" {
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();

    var q: ThreadSafeQueueCell(i32, VecDequeStorage(i32)) = undefined;
    try initBounded(i32, &q, &ctx, 2);
    defer q.deinit();

    try testing.expect(q.isEmpty());
    try q.tryPush(1);
    // A push out of empty moves head; a push into a non-empty queue does not.
    try testing.expectEqual(@as(?i32, 1), q.head());
    const after_first = q.versions();
    try q.tryPush(2);
    const after_second = q.versions();
    try testing.expectEqual(after_first.head, after_second.head);
    try testing.expect(after_second.len != after_first.len);
    // Crossing the bound is the backpressure signal.
    try testing.expect(after_second.is_full != after_first.is_full);
    try testing.expect(q.isFull());

    try testing.expectError(error.Full, q.tryPush(3));
    try testing.expectEqual(after_second, q.versions());

    try testing.expectEqual(@as(i32, 1), try q.tryPop());
    try testing.expectEqual(@as(?i32, 2), q.head());
    try testing.expect(!q.isFull());

    q.close();
    try testing.expect(q.isClosed());
    try testing.expectError(error.Closed, q.tryPush(4));
}

test "lazily/thread_safe_queue: one op is one batch, so an effect sees the whole set" {
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();

    var q: ThreadSafeQueueCell(i32, VecDequeStorage(i32)) = undefined;
    try initBounded(i32, &q, &ctx, 1);
    defer q.deinit();

    // An effect over three reader kinds must run ONCE per op, not once per
    // dirtied kind — and must never observe `len` moved while `is_full` is stale.
    const Watcher = struct {
        var cell: *ThreadSafeQueueCell(i32, VecDequeStorage(i32)) = undefined;
        var runs: usize = 0;
        var torn: usize = 0;
        fn body(_: *anyopaque, cc: *ThreadSafeContext.ComputeContext) usize {
            const l = cc.readNode(usize, cell.len_reader);
            const full = cc.readNode(bool, cell.is_full_reader);
            const empty = cc.readNode(bool, cell.is_empty_reader);
            runs += 1;
            if ((l == 0) != empty) torn += 1;
            if ((l >= 1) != full) torn += 1;
            return l;
        }
    };
    Watcher.cell = &q;
    Watcher.runs = 0;
    Watcher.torn = 0;
    var anchor: u8 = 0;
    _ = try ctx.effectClosure(usize, @ptrCast(&anchor), Watcher.body, null, null);
    const baseline = Watcher.runs;

    // This push dirties len, is_empty AND is_full at once.
    try q.tryPush(7);
    try testing.expectEqual(baseline + 1, Watcher.runs);
    _ = try q.tryPop();
    try testing.expectEqual(baseline + 2, Watcher.runs);
    try testing.expectEqual(@as(usize, 0), Watcher.torn);
}

test "lazily/thread_safe_queue: a topic wakes only the connected cursors" {
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();

    var topic: ThreadSafeTopicCell([]const u8) = undefined;
    topic.init(&ctx);
    defer topic.deinit();

    _ = try topic.subscribe("a", .durable);
    _ = try topic.subscribe("b", .durable);
    _ = try topic.read("a");
    _ = try topic.read("b");

    const before = .{ topic.readerVersion("a").?, topic.readerVersion("b").? };
    _ = try topic.publishValue("one");
    try testing.expect(topic.readerVersion("a").? > before[0]);
    try testing.expect(topic.readerVersion("b").? > before[1]);
    try testing.expectEqualStrings("one", (try topic.read("a")).?);

    // A disconnected durable cursor is not woken, and does not hold GC.
    try topic.disconnect("b");
    const b_offline = topic.readerVersion("b").?;
    _ = try topic.publishValue("two");
    try testing.expectEqual(b_offline, topic.readerVersion("b").?);

    // Advancing one subscriber never touches the other.
    const a_before = topic.readerVersion("a").?;
    _ = try topic.advance("a", 1);
    try testing.expect(topic.readerVersion("a").? > a_before);
    try testing.expectEqual(b_offline, topic.readerVersion("b").?);
}

test "lazily/thread_safe_queue: work-queue leases redeliver and dead-letter" {
    var ctx = ThreadSafeContext.init(testing.allocator);
    defer ctx.deinit();

    var wq: ThreadSafeWorkQueueCell([]const u8) = undefined;
    try wq.init(&ctx, 10, 2);
    defer wq.deinit();

    _ = try wq.push("job");
    try testing.expectEqual(@as(usize, 1), wq.pendingLen());
    try testing.expect(!wq.isEmpty());

    const first = (try wq.claim("w1", 0)).?;
    try testing.expectEqual(@as(u64, 1), first.attempt);
    try testing.expectEqual(@as(u64, 10), first.deadline);
    try testing.expect(wq.isEmpty());
    try testing.expectEqual(@as(usize, 1), wq.inFlightLen());

    // Strictly-after expiry: at the deadline nothing has expired yet.
    try testing.expectEqual(@as(usize, 0), try wq.reapExpired(10));
    try testing.expectEqual(@as(usize, 1), try wq.reapExpired(11));
    try testing.expectEqual(@as(usize, 1), wq.pendingLen());

    const second = (try wq.claim("w2", 20)).?;
    try testing.expectEqual(@as(u64, 2), second.attempt);
    // The attempt limit is 2, so this failure dead-letters instead of requeueing.
    try testing.expect(try wq.nack("w2", second.delivery_id));
    try testing.expectEqual(@as(usize, 1), wq.deadLetterLen());
    try testing.expectEqual(@as(usize, 0), wq.pendingLen());
}
