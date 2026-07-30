//! The queue family's transition algebra, with **no graph writes at all**
//! (`#lzqueuefamilyflavors`).
//!
//! `QueueCell` / `TopicCell` / `WorkQueueCell` each ship in three flavors —
//! single-threaded, thread-safe, async — and the three differ only in *where the
//! reader lives and how invalidation is published*. Nothing about a push, a
//! publish, or a lease expiry is thread- or async-coloured, so duplicating the
//! state machine per flavor would be three chances to disagree about the same
//! law. This module is the one copy: every core here owns the state, performs
//! the transition, and **returns which reader kinds it dirtied**. It imports no
//! context, holds no node, and bumps no version.
//!
//! Same split the ingress family already uses in this package
//! ([`ingress_core.zig`](ingress_core.zig) + three shells), and the split
//! lazily-js (`src/queue-core.js`) and lazily-cs (`src/Lazily/QueueCore.cs`)
//! landed for this same backlog item.
//!
//! # The change sets
//!
//! - [`QueueInvalidates`] — `head` / `len` / `is_empty` / `is_full` / `closed`.
//! - [`WorkQueueInvalidates`] — `pending_len` / `is_empty` / `in_flight_len` /
//!   `dead_letter_len`.
//! - [`TopicWake`] — which *subscribers'* unread suffix moved. A topic's reader
//!   set is unbounded and per-subscriber, so returning a list would mean
//!   allocating inside the core (and, for the thread-safe shell, allocating
//!   while holding the core lock). Instead the core returns a small tagged
//!   union — `.none`, `.{ .one = id }`, `.{ .connected_at_or_before = offset }` —
//!   and each shell resolves it against its OWN reader table via
//!   [`TopicCore.wakes`]. The core never learns that readers exist.
//!
//! # Reader-kind exactness
//!
//! Every `invalidates` flag below is decided by the *transition*, never by
//! comparing derived values: a push knows it moved `head` only when it came from
//! empty, and `is_full` only when it crossed the bound. That is what makes
//! reader-kind independence checkable in both directions — a core that returned
//! "everything changed" would pass every `invalidates: true` in the canonical
//! corpus and fail every `false`.

const std = @import("std");

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Failure modes for `QueueStorage.tryPush` / `QueueCell.tryPush`.
///
/// `Full` and `Closed` are the two observable rejection reasons distinguished by
/// the shell's contract (`lazily-spec/cell-model.md` § "Storage backend
/// contract"). Neither changes queue state, so neither invalidates any reader.
pub const QueuePushError = error{
    /// The backend is bounded and at capacity. The overflow policy (block /
    /// drop-oldest / drop-newest / reject) is a backend property. Distinct from
    /// `Closed`.
    Full,
    /// The queue is closed; push is rejected regardless of capacity. Terminal —
    /// once closed, a queue cannot be reopened.
    Closed,
};

/// Failure modes for `QueueStorage.tryPop` / `QueueCell.tryPop`.
///
/// `Empty` and `Closed` are distinct observable signals: `Empty` means "try
/// again later," `Closed` means "the producer is done and the queue is drained."
pub const QueuePopError = error{
    /// The queue is open but contains no elements.
    Empty,
    /// The queue is closed and empty — the producer is done and all buffered
    /// elements have been consumed. Pop on a closed *non-empty* queue still
    /// drains (returns the next element); only closed+empty yields `Closed`.
    Closed,
};

// ---------------------------------------------------------------------------
// QueueCore
// ---------------------------------------------------------------------------

/// A snapshot of all five reader-kind version counters. Two snapshots diffed
/// across an op yield exactly which reader kinds the op invalidated — the
/// `invalidates` matrix asserted by
/// `lazily-spec/conformance/collections/queuecell_*.json`. Every flavor exposes
/// it: the counters are the shell's own, but the shape is the family's.
pub const QueueVersions = struct {
    head: u64,
    len: u64,
    is_empty: u64,
    is_full: u64,
    closed: u64,
};

/// The five reader kinds a queue transition can dirty. A field left `false` is
/// a positive claim that the kind's projected value did not change — the shells
/// publish exactly these and the canonical corpus asserts both directions.
pub const QueueInvalidates = struct {
    head: bool = false,
    len: bool = false,
    is_empty: bool = false,
    is_full: bool = false,
    closed: bool = false,

    pub fn any(self: QueueInvalidates) bool {
        return self.head or self.len or self.is_empty or self.is_full or self.closed;
    }

    /// Deliberately NOT used by any shell: the `count` a `.{}`-returning op
    /// reports is the point. Present so tests can state "nothing moved".
    pub const none: QueueInvalidates = .{};
};

/// FIFO state plus the push/pop/close transition algebra, over a pluggable
/// `QueueStorage` backend (the comptime contract documented on
/// [`queue.VecDequeStorage`](queue.zig)).
///
/// `peek` and `capacity` are OPTIONAL backend capabilities, detected with
/// `@hasDecl`: a raw-channel backend implements neither, has no `head` reader
/// (trivially null) and is never full.
pub fn QueueCore(comptime T: type, comptime S: type) type {
    return struct {
        const Self = @This();

        pub const Element = T;
        pub const Storage = S;
        pub const Popped = struct { value: T, invalidates: QueueInvalidates };

        const has_peek = @hasDecl(S, "peek");
        const has_capacity = @hasDecl(S, "capacity");
        const has_items = @hasDecl(S, "items");

        storage: S,
        /// Cached bound: capacity is a fixed backend property, so reading it per
        /// transition would be a hot-path call that can never change its answer.
        cap: ?usize,

        pub fn init(storage: S) Self {
            return .{
                .storage = storage,
                .cap = if (has_capacity) storage.capacity() else null,
            };
        }

        pub fn deinit(self: *Self) void {
            if (@hasDecl(S, "deinit")) self.storage.deinit();
        }

        /// Which reader kinds provably changed when the queue went from
        /// `len_before` to `len_after`. No reader value is derived here — the
        /// transition alone decides (exact for any FIFO), so no `peek` is needed.
        /// `head_changed` is the caller's, because head depends on op direction
        /// rather than on length: a pop always moves head, a push moves it only
        /// out of empty. `closed` is never set here; only [`close`] sets it.
        fn transition(
            self: *const Self,
            len_before: usize,
            len_after: usize,
            head_changed: bool,
        ) QueueInvalidates {
            var out: QueueInvalidates = .{ .len = true, .head = head_changed };
            if ((len_before == 0) != (len_after == 0)) out.is_empty = true;
            if (self.cap) |c| {
                if ((len_before >= c) != (len_after >= c)) out.is_full = true;
            }
            return out;
        }

        // -- mutating ops --

        /// Append to the tail. On error the state is unchanged and the returned
        /// error carries no invalidation, because nothing moved.
        pub fn tryPush(self: *Self, value: T) QueuePushError!QueueInvalidates {
            const len_before = self.storage.len();
            try self.storage.tryPush(value);
            return self.transition(len_before, len_before + 1, len_before == 0);
        }

        /// Remove and return the head element.
        pub fn tryPop(self: *Self) QueuePopError!Popped {
            const len_before = self.storage.len();
            const value = try self.storage.tryPop();
            return .{
                .value = value,
                .invalidates = self.transition(len_before, len_before - 1, true),
            };
        }

        /// Idempotent and terminal. Only the false → true edge invalidates.
        pub fn close(self: *Self) QueueInvalidates {
            if (self.storage.isClosed()) return .{};
            self.storage.close();
            return .{ .closed = true };
        }

        // -- derived reads (demand-materialized from storage) --

        pub fn peek(self: *const Self) ?T {
            if (has_peek) return self.storage.peek();
            return null;
        }

        pub fn len(self: *const Self) usize {
            return self.storage.len();
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.storage.len() == 0;
        }

        pub fn isFull(self: *const Self) bool {
            if (self.cap) |c| return self.storage.len() >= c;
            return false;
        }

        pub fn isClosed(self: *const Self) bool {
            return self.storage.isClosed();
        }

        pub fn capacity(self: *const Self) ?usize {
            return self.cap;
        }

        /// FIFO-ordered view, when the backend offers one. Non-reactive.
        pub fn items(self: *const Self) []const T {
            if (has_items) return self.storage.items();
            return &[_]T{};
        }
    };
}

// ---------------------------------------------------------------------------
// TopicCore
// ---------------------------------------------------------------------------

pub const TopicDurability = enum { durable, ephemeral };

pub const TopicSubscribeOutcome = enum { subscribed, reconnected, already_subscribed };

pub const TopicSubscriptionSnapshot = struct {
    subscriber_id: []const u8,
    cursor: usize,
    durability: TopicDurability,
    connected: bool,
};

pub fn TopicSnapshot(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        base_offset: usize,
        elements: []T,
        subscriptions: []TopicSubscriptionSnapshot,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            for (self.subscriptions) |subscription| {
                self.allocator.free(subscription.subscriber_id);
            }
            self.allocator.free(self.subscriptions);
            self.allocator.free(self.elements);
        }
    };
}

/// Which subscribers' unread suffix moved, without naming any of them by
/// allocation.
///
/// A topic's reader set is per-subscriber and unbounded, so a change set spelled
/// as a list would allocate inside the core — and the thread-safe shell would be
/// allocating while holding the core lock. This union is the whole change set for
/// every topic op, and [`TopicCore.wakes`] is its resolver: a shell walks its own
/// reader table and asks, once per reader.
pub const TopicWake = union(enum) {
    /// Nothing observable moved (an idempotent reconnect, a `gc`, a `restart`).
    none,
    /// Exactly this subscriber (subscribe / reconnect / disconnect / advance).
    one: []const u8,
    /// Every CONNECTED subscriber whose cursor is at or before this offset —
    /// i.e. the log grew past them. `publish` returns the pre-append tail here,
    /// which is every connected cursor, but stating the bound rather than "all"
    /// keeps the resolver a pure predicate on core state.
    connected_at_or_before: usize,
};

/// What a topic mutator did, beyond the wake set: the shell also has to MINT a
/// reader for a brand-new subscription and DROP one for a removed ephemeral,
/// and neither is derivable from the wake set alone.
pub const TopicChange = struct {
    wake: TopicWake = .none,
    /// A subscription that did not exist now does.
    minted: bool = false,
    /// An ephemeral subscription was removed outright by `disconnect`.
    removed: bool = false,
};

pub const TopicSubscribeResult = struct {
    outcome: TopicSubscribeOutcome,
    change: TopicChange,
};

pub const TopicPublishResult = struct {
    offset: usize,
    change: TopicChange,
};

pub const TopicAdvanceResult = struct {
    cursor: usize,
    change: TopicChange,
};

pub const TopicError = error{
    SubscriptionNotFound,
    EphemeralCannotReconnect,
    AdvancePastTail,
    CursorOutsideRetainedLog,
    DisconnectedEphemeralSubscription,
};

/// Broadcast log with independent absolute cursors, minus the graph.
///
/// Durable offline subscriptions retain data; ephemeral subscriptions disappear
/// on disconnect. `gc` drops only the prefix below the slowest durable cursor,
/// so it moves nobody's unread suffix and returns `.none`.
pub fn TopicCore(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Subscription = struct {
            cursor: usize,
            durability: TopicDurability,
            connected: bool,
        };

        allocator: std.mem.Allocator,
        base_offset: usize = 0,
        elements: std.ArrayList(T) = .empty,
        subscriptions: std.StringHashMap(Subscription),

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .subscriptions = std.StringHashMap(Subscription).init(allocator),
            };
        }

        /// Rebuild from a saved snapshot. Validates before storing anything, so a
        /// rejected snapshot leaves a core the caller can still `deinit`.
        pub fn initFromSnapshot(
            allocator: std.mem.Allocator,
            saved: TopicSnapshot(T),
        ) !Self {
            var self = Self.init(allocator);
            errdefer self.deinit();
            self.base_offset = saved.base_offset;
            try self.elements.appendSlice(allocator, saved.elements);
            const tail = self.tailOffset();
            for (saved.subscriptions) |saved_sub| {
                if (saved_sub.cursor < self.base_offset or saved_sub.cursor > tail) {
                    return error.CursorOutsideRetainedLog;
                }
                if (saved_sub.durability == .ephemeral and !saved_sub.connected) {
                    return error.DisconnectedEphemeralSubscription;
                }
                const owned_id = try allocator.dupe(u8, saved_sub.subscriber_id);
                errdefer allocator.free(owned_id);
                try self.subscriptions.put(owned_id, .{
                    .cursor = saved_sub.cursor,
                    .durability = saved_sub.durability,
                    .connected = saved_sub.connected,
                });
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            var iterator = self.subscriptions.keyIterator();
            while (iterator.next()) |key| self.allocator.free(key.*);
            self.subscriptions.deinit();
            self.elements.deinit(self.allocator);
        }

        /// Does `wake` name `id`? The resolution half of [`TopicWake`]: each
        /// shell walks its own reader table and asks this once per reader, so the
        /// core stays free of reader identity and allocates nothing to report a
        /// broadcast.
        pub fn wakes(self: *const Self, wake: TopicWake, id: []const u8) bool {
            return switch (wake) {
                .none => false,
                .one => |only| std.mem.eql(u8, only, id),
                .connected_at_or_before => |offset| blk: {
                    const sub = self.subscriptions.get(id) orelse break :blk false;
                    break :blk sub.connected and sub.cursor <= offset;
                },
            };
        }

        // -- mutating ops --

        /// Start a cursor at the tail, or resume an offline durable subscriber.
        pub fn subscribe(
            self: *Self,
            subscriber_id: []const u8,
            durability: TopicDurability,
        ) !TopicSubscribeResult {
            if (self.subscriptions.getPtr(subscriber_id)) |sub| {
                if (sub.connected) return .{ .outcome = .already_subscribed, .change = .{} };
                if (sub.durability != .durable) return error.EphemeralCannotReconnect;
                sub.connected = true;
                return .{
                    .outcome = .reconnected,
                    // Borrow the map's key, not the caller's slice: the shell may
                    // resolve the wake after the caller's argument has died.
                    .change = .{ .wake = .{ .one = self.keyOf(subscriber_id).? } },
                };
            }
            const owned_id = try self.allocator.dupe(u8, subscriber_id);
            errdefer self.allocator.free(owned_id);
            try self.subscriptions.put(owned_id, .{
                .cursor = self.tailOffset(),
                .durability = durability,
                .connected = true,
            });
            return .{
                .outcome = .subscribed,
                .change = .{ .wake = .{ .one = owned_id }, .minted = true },
            };
        }

        pub fn reconnect(self: *Self, subscriber_id: []const u8) !TopicChange {
            const sub = self.subscriptions.getPtr(subscriber_id) orelse
                return error.SubscriptionNotFound;
            if (sub.durability != .durable) return error.EphemeralCannotReconnect;
            if (sub.connected) return .{};
            sub.connected = true;
            return .{ .wake = .{ .one = self.keyOf(subscriber_id).? } };
        }

        pub fn disconnect(self: *Self, subscriber_id: []const u8) !TopicChange {
            const sub = self.subscriptions.getPtr(subscriber_id) orelse
                return error.SubscriptionNotFound;
            if (!sub.connected) return .{};
            if (sub.durability == .ephemeral) {
                const removed = self.subscriptions.fetchRemove(subscriber_id).?;
                self.allocator.free(removed.key);
                // No wake: the subscription is gone, and the shell disposing its
                // reader is a strictly stronger observation than a version bump.
                return .{ .removed = true };
            }
            sub.connected = false;
            return .{ .wake = .{ .one = self.keyOf(subscriber_id).? } };
        }

        /// Append a value. Every connected cursor's unread suffix grows by one.
        pub fn publish(self: *Self, value: T) !TopicPublishResult {
            const offset = self.tailOffset();
            try self.elements.append(self.allocator, value);
            return .{
                .offset = offset,
                .change = .{ .wake = .{ .connected_at_or_before = offset } },
            };
        }

        /// Advance only the named subscriber. A no-op advance (offline, already
        /// at the tail, or `count == 0`) wakes nobody.
        pub fn advance(
            self: *Self,
            subscriber_id: []const u8,
            count: usize,
        ) !TopicAdvanceResult {
            const sub = self.subscriptions.getPtr(subscriber_id) orelse
                return error.SubscriptionNotFound;
            if (!sub.connected or sub.cursor == self.tailOffset()) {
                return .{ .cursor = sub.cursor, .change = .{} };
            }
            if (count > self.tailOffset() - sub.cursor) return error.AdvancePastTail;
            if (count == 0) return .{ .cursor = sub.cursor, .change = .{} };
            sub.cursor += count;
            return .{
                .cursor = sub.cursor,
                .change = .{ .wake = .{ .one = self.keyOf(subscriber_id).? } },
            };
        }

        /// Drop the safe prefix. Cursor offsets stay absolute, so no subscriber's
        /// unread suffix moves and nothing is woken.
        pub fn gc(self: *Self) usize {
            var frontier = self.tailOffset();
            var iterator = self.subscriptions.valueIterator();
            while (iterator.next()) |sub| {
                if (sub.durability == .durable and sub.cursor < frontier) {
                    frontier = sub.cursor;
                }
            }
            const removed = frontier - self.base_offset;
            var index: usize = 0;
            while (index < removed) : (index += 1) _ = self.elements.orderedRemove(0);
            self.base_offset = frontier;
            return removed;
        }

        /// The corpus issues `restart` with a `subscriber` the observable contract
        /// never uses, and the one step that issues it expects nothing to change.
        pub fn restart(self: *Self) TopicChange {
            _ = self;
            return .{};
        }

        // -- projections --

        fn keyOf(self: *const Self, subscriber_id: []const u8) ?[]const u8 {
            const entry = self.subscriptions.getEntry(subscriber_id) orelse return null;
            return entry.key_ptr.*;
        }

        /// The retained suffix from this subscriber's cursor. An offline
        /// subscriber reads nothing.
        pub fn readStream(self: *const Self, subscriber_id: []const u8) ![]const T {
            const sub = self.subscriptions.get(subscriber_id) orelse
                return error.SubscriptionNotFound;
            if (!sub.connected) return self.elements.items[0..0];
            return self.elements.items[sub.cursor - self.base_offset ..];
        }

        pub fn readValue(self: *const Self, subscriber_id: []const u8) !?T {
            const stream = try self.readStream(subscriber_id);
            return if (stream.len == 0) null else stream[0];
        }

        pub fn baseOffset(self: *const Self) usize {
            return self.base_offset;
        }

        pub fn tailOffset(self: *const Self) usize {
            return self.base_offset + self.elements.items.len;
        }

        pub fn items(self: *const Self) []const T {
            return self.elements.items;
        }

        pub fn subscriptionCount(self: *const Self) usize {
            return self.subscriptions.count();
        }

        pub fn subscription(
            self: *const Self,
            subscriber_id: []const u8,
        ) ?TopicSubscriptionSnapshot {
            const found = self.subscriptions.get(subscriber_id) orelse return null;
            return .{
                .subscriber_id = subscriber_id,
                .cursor = found.cursor,
                .durability = found.durability,
                .connected = found.connected,
            };
        }

        pub fn snapshot(
            self: *const Self,
            allocator: std.mem.Allocator,
        ) !TopicSnapshot(T) {
            const elements = try allocator.dupe(T, self.elements.items);
            errdefer allocator.free(elements);
            const subscriptions = try allocator.alloc(
                TopicSubscriptionSnapshot,
                self.subscriptions.count(),
            );
            errdefer allocator.free(subscriptions);
            var initialized: usize = 0;
            errdefer for (subscriptions[0..initialized]) |saved_sub| {
                allocator.free(saved_sub.subscriber_id);
            };

            var iterator = self.subscriptions.iterator();
            while (iterator.next()) |entry| {
                const subscriber_id = try allocator.dupe(u8, entry.key_ptr.*);
                subscriptions[initialized] = .{
                    .subscriber_id = subscriber_id,
                    .cursor = entry.value_ptr.cursor,
                    .durability = entry.value_ptr.durability,
                    .connected = entry.value_ptr.connected,
                };
                initialized += 1;
            }
            return .{
                .allocator = allocator,
                .base_offset = self.base_offset,
                .elements = elements,
                .subscriptions = subscriptions,
            };
        }
    };
}

// ---------------------------------------------------------------------------
// WorkQueueCore
// ---------------------------------------------------------------------------

pub const WorkQueueDeadLetterReason = enum { nack, expired };

pub const WorkQueueError = error{
    InvalidConfiguration,
    ItemIdExhausted,
    DeliveryIdExhausted,
    DeadlineOverflow,
};

/// A snapshot of all four work-queue reader-kind version counters.
pub const WorkQueueVersions = struct {
    pending_len: u64,
    is_empty: u64,
    in_flight_len: u64,
    dead_letter_len: u64,
};

/// The four reader kinds a work-queue transition can dirty.
pub const WorkQueueInvalidates = struct {
    pending_len: bool = false,
    is_empty: bool = false,
    in_flight_len: bool = false,
    dead_letter_len: bool = false,

    pub fn any(self: WorkQueueInvalidates) bool {
        return self.pending_len or self.is_empty or
            self.in_flight_len or self.dead_letter_len;
    }
};

/// Competing-consumer queue with leased exclusive claims, minus the graph.
///
/// Item ids stay stable across retries and every claim gets a fresh delivery id.
/// Failed deliveries requeue at the tail until `max_deliveries` is reached, then
/// move to the dead-letter list. Leases expire strictly after their deadline.
pub fn WorkQueueCore(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Item = struct {
            item_id: u64,
            value: T,
            attempts: u64,
        };

        pub const Delivery = struct {
            delivery_id: u64,
            item_id: u64,
            value: T,
            worker: []const u8,
            attempt: u64,
            deadline: u64,
        };

        pub const DeadLetter = struct {
            item_id: u64,
            value: T,
            attempts: u64,
            reason: WorkQueueDeadLetterReason,
        };

        pub const Pushed = struct { item_id: u64, invalidates: WorkQueueInvalidates };
        pub const Claimed = struct { delivery: ?Delivery, invalidates: WorkQueueInvalidates };
        pub const Settled = struct { ok: bool, invalidates: WorkQueueInvalidates };
        pub const Reaped = struct { count: usize, invalidates: WorkQueueInvalidates };

        allocator: std.mem.Allocator,
        visibility_timeout: u64,
        max_deliveries: u64,
        pending: std.ArrayList(Item) = .empty,
        in_flight: std.AutoHashMap(u64, Delivery),
        dead_letters: std.ArrayList(DeadLetter) = .empty,
        next_item_id: u64 = 0,
        next_delivery_id: u64 = 0,

        pub fn init(
            allocator: std.mem.Allocator,
            visibility_timeout: u64,
            max_deliveries: u64,
        ) !Self {
            if (visibility_timeout == 0 or max_deliveries == 0) {
                return error.InvalidConfiguration;
            }
            return .{
                .allocator = allocator,
                .visibility_timeout = visibility_timeout,
                .max_deliveries = max_deliveries,
                .in_flight = std.AutoHashMap(u64, Delivery).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.pending.deinit(self.allocator);
            self.in_flight.deinit();
            self.dead_letters.deinit(self.allocator);
        }

        // -- mutating ops --

        pub fn push(self: *Self, value: T) !Pushed {
            if (self.next_item_id == std.math.maxInt(u64)) return error.ItemIdExhausted;
            const was_empty = self.pending.items.len == 0;
            const item_id = self.next_item_id;
            try self.pending.append(self.allocator, .{
                .item_id = item_id,
                .value = value,
                .attempts = 0,
            });
            self.next_item_id += 1;
            return .{
                .item_id = item_id,
                .invalidates = .{ .pending_len = true, .is_empty = was_empty },
            };
        }

        pub fn claim(self: *Self, worker: []const u8, now: u64) !Claimed {
            if (self.pending.items.len == 0) return .{ .delivery = null, .invalidates = .{} };
            if (self.next_delivery_id == std.math.maxInt(u64)) return error.DeliveryIdExhausted;
            const deadline = std.math.add(u64, now, self.visibility_timeout) catch {
                return error.DeadlineOverflow;
            };
            const item = self.pending.items[0];
            const delivery: Delivery = .{
                .delivery_id = self.next_delivery_id,
                .item_id = item.item_id,
                .value = item.value,
                .worker = worker,
                .attempt = item.attempts + 1,
                .deadline = deadline,
            };
            try self.in_flight.put(delivery.delivery_id, delivery);
            _ = self.pending.orderedRemove(0);
            self.next_delivery_id += 1;
            return .{
                .delivery = delivery,
                .invalidates = .{
                    .pending_len = true,
                    .in_flight_len = true,
                    .is_empty = self.pending.items.len == 0,
                },
            };
        }

        pub fn ack(self: *Self, worker: []const u8, delivery_id: u64) Settled {
            const delivery = self.in_flight.get(delivery_id) orelse
                return .{ .ok = false, .invalidates = .{} };
            if (!std.mem.eql(u8, worker, delivery.worker)) {
                return .{ .ok = false, .invalidates = .{} };
            }
            _ = self.in_flight.remove(delivery_id);
            return .{ .ok = true, .invalidates = .{ .in_flight_len = true } };
        }

        const FailureTransition = struct {
            requeued: bool,
            became_non_empty: bool,
        };

        fn fail(
            self: *Self,
            delivery: Delivery,
            reason: WorkQueueDeadLetterReason,
        ) !FailureTransition {
            if (delivery.attempt >= self.max_deliveries) {
                try self.dead_letters.append(self.allocator, .{
                    .item_id = delivery.item_id,
                    .value = delivery.value,
                    .attempts = delivery.attempt,
                    .reason = reason,
                });
                return .{ .requeued = false, .became_non_empty = false };
            }
            const was_empty = self.pending.items.len == 0;
            try self.pending.append(self.allocator, .{
                .item_id = delivery.item_id,
                .value = delivery.value,
                .attempts = delivery.attempt,
            });
            return .{ .requeued = true, .became_non_empty = was_empty };
        }

        pub fn nack(self: *Self, worker: []const u8, delivery_id: u64) !Settled {
            const delivery = self.in_flight.get(delivery_id) orelse
                return .{ .ok = false, .invalidates = .{} };
            if (!std.mem.eql(u8, worker, delivery.worker)) {
                return .{ .ok = false, .invalidates = .{} };
            }
            const transition = try self.fail(delivery, .nack);
            _ = self.in_flight.remove(delivery_id);
            return .{
                .ok = true,
                .invalidates = .{
                    .in_flight_len = true,
                    .pending_len = transition.requeued,
                    .dead_letter_len = !transition.requeued,
                    .is_empty = transition.became_non_empty,
                },
            };
        }

        pub fn reapExpired(self: *Self, now: u64) !Reaped {
            var expired: std.ArrayList(u64) = .empty;
            defer expired.deinit(self.allocator);
            var iterator = self.in_flight.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.deadline < now) {
                    try expired.append(self.allocator, entry.key_ptr.*);
                }
            }
            if (expired.items.len == 0) return .{ .count = 0, .invalidates = .{} };
            // Hash-map iteration order is not delivery order; the redelivery law
            // is stated over delivery id, so reap in that order.
            std.mem.sort(u64, expired.items, {}, std.sort.asc(u64));
            var out: WorkQueueInvalidates = .{ .in_flight_len = true };
            for (expired.items) |delivery_id| {
                const delivery = self.in_flight.get(delivery_id).?;
                const transition = try self.fail(delivery, .expired);
                if (transition.requeued) out.pending_len = true else out.dead_letter_len = true;
                if (transition.became_non_empty) out.is_empty = true;
                _ = self.in_flight.remove(delivery_id);
            }
            return .{ .count = expired.items.len, .invalidates = out };
        }

        // -- derived reads --

        pub fn pendingLen(self: *const Self) usize {
            return self.pending.items.len;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.pending.items.len == 0;
        }

        pub fn inFlightLen(self: *const Self) usize {
            return self.in_flight.count();
        }

        pub fn deadLetterLen(self: *const Self) usize {
            return self.dead_letters.items.len;
        }

        pub fn pendingItems(self: *const Self) []const Item {
            return self.pending.items;
        }

        pub fn deadLetterItems(self: *const Self) []const DeadLetter {
            return self.dead_letters.items;
        }

        /// In-flight deliveries in delivery-id order. The backing store is a hash
        /// map, so a caller that needs a stable order has to ask for one.
        pub fn inFlightDeliveries(
            self: *const Self,
            allocator: std.mem.Allocator,
        ) ![]Delivery {
            const result = try allocator.alloc(Delivery, self.in_flight.count());
            var index: usize = 0;
            var iterator = self.in_flight.iterator();
            while (iterator.next()) |entry| : (index += 1) {
                result[index] = entry.value_ptr.*;
            }
            std.mem.sort(Delivery, result, {}, struct {
                fn lessThan(_: void, left: Delivery, right: Delivery) bool {
                    return left.delivery_id < right.delivery_id;
                }
            }.lessThan);
            return result;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests — the algebra alone, with no graph anywhere near it.
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestStorage = struct {
    buf: std.ArrayList(i32) = .empty,
    cap: ?usize = null,
    closed: bool = false,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TestStorage) void {
        self.buf.deinit(self.allocator);
    }
    pub fn tryPush(self: *TestStorage, value: i32) QueuePushError!void {
        if (self.closed) return error.Closed;
        if (self.cap) |c| {
            if (self.buf.items.len >= c) return error.Full;
        }
        self.buf.append(self.allocator, value) catch return;
    }
    pub fn tryPop(self: *TestStorage) QueuePopError!i32 {
        if (self.buf.items.len == 0) return if (self.closed) error.Closed else error.Empty;
        return self.buf.orderedRemove(0);
    }
    pub fn peek(self: *const TestStorage) ?i32 {
        return if (self.buf.items.len == 0) null else self.buf.items[0];
    }
    pub fn len(self: *const TestStorage) usize {
        return self.buf.items.len;
    }
    pub fn capacity(self: *const TestStorage) ?usize {
        return self.cap;
    }
    pub fn isClosed(self: *const TestStorage) bool {
        return self.closed;
    }
    pub fn close(self: *TestStorage) void {
        self.closed = true;
    }
    pub fn items(self: *const TestStorage) []const i32 {
        return self.buf.items;
    }
};

test "lazily/queue_core: the push/pop transition is exact per reader kind" {
    var core = QueueCore(i32, TestStorage).init(
        .{ .allocator = testing.allocator, .cap = 2 },
    );
    defer core.deinit();

    // Empty → 1: head moves (there was none), len moves, emptiness flips, not full.
    try testing.expectEqual(
        QueueInvalidates{ .head = true, .len = true, .is_empty = true },
        try core.tryPush(1),
    );
    // 1 → 2 at capacity: head stays, fullness flips.
    try testing.expectEqual(
        QueueInvalidates{ .len = true, .is_full = true },
        try core.tryPush(2),
    );
    // Rejected push moves nothing at all.
    try testing.expectError(error.Full, core.tryPush(3));
    // Pop off capacity: head always moves, fullness flips back, still non-empty.
    const popped = try core.tryPop();
    try testing.expectEqual(@as(i32, 1), popped.value);
    try testing.expectEqual(
        QueueInvalidates{ .head = true, .len = true, .is_full = true },
        popped.invalidates,
    );
    // Close is terminal and idempotent.
    try testing.expectEqual(QueueInvalidates{ .closed = true }, core.close());
    try testing.expectEqual(QueueInvalidates{}, core.close());
}

test "lazily/queue_core: a topic wake resolves without the core knowing any reader" {
    var core = TopicCore([]const u8).init(testing.allocator);
    defer core.deinit();

    _ = try core.subscribe("a", .durable);
    _ = try core.subscribe("b", .durable);
    const published = try core.publish("one");
    try testing.expect(core.wakes(published.change.wake, "a"));
    try testing.expect(core.wakes(published.change.wake, "b"));
    // An id nothing subscribed under is never woken, so a shell holding a stale
    // reader cannot be spuriously invalidated.
    try testing.expect(!core.wakes(published.change.wake, "c"));

    // A disconnected durable cursor is NOT woken by a later publish.
    _ = try core.disconnect("b");
    const second = try core.publish("two");
    try testing.expect(core.wakes(second.change.wake, "a"));
    try testing.expect(!core.wakes(second.change.wake, "b"));

    // Advance wakes exactly one.
    const advanced = try core.advance("a", 1);
    try testing.expectEqual(@as(usize, 1), advanced.cursor);
    try testing.expect(core.wakes(advanced.change.wake, "a"));
    try testing.expect(!core.wakes(advanced.change.wake, "b"));
}

test "lazily/queue_core: work-queue emptiness flips only on the boundary" {
    var core = try WorkQueueCore([]const u8).init(testing.allocator, 10, 2);
    defer core.deinit();

    try testing.expectEqual(
        WorkQueueInvalidates{ .pending_len = true, .is_empty = true },
        (try core.push("a")).invalidates,
    );
    // Second push into a non-empty queue must NOT move `is_empty`.
    try testing.expectEqual(
        WorkQueueInvalidates{ .pending_len = true },
        (try core.push("b")).invalidates,
    );
    try testing.expectEqual(
        WorkQueueInvalidates{ .pending_len = true, .in_flight_len = true },
        (try core.claim("w", 0)).invalidates,
    );
    // The claim that empties the pending list flips emptiness.
    try testing.expectEqual(
        WorkQueueInvalidates{ .pending_len = true, .in_flight_len = true, .is_empty = true },
        (try core.claim("w", 0)).invalidates,
    );
}
