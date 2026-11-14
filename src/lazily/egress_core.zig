//! Transport-agnostic reactive egress core (`#lzegress`).
//!
//! The core owns delivery authority: sequence assignment, the unacknowledged
//! window, a monotone acknowledgement watermark, the retry budget, and the
//! producer-generation fence. It owns no graph handles and performs no I/O, so
//! the single-threaded, thread-safe, and async shells all wrap this one
//! algebra. Durability (an outbox) and conflation/backpressure (`RelayCell`)
//! stay separate layers around the envelope.
//!
//! Contract: lazily-spec `conformance/egress/egress_*.json`, mirroring the
//! lazily-rs reference `EgressCore`. Every mutator returns the reader kinds it
//! dirtied (`EgressChange`) beside its outcome; a shell clears exactly that set.

const std = @import("std");

/// Egress policy. `retry_budget` counts retries AFTER the first attempt.
pub const EgressPolicy = struct {
    inflight_limit: usize = 64,
    retry_budget: u32 = 3,
    retry_base: u64 = 10,
    retry_ceiling: u64 = 1_000,
};

pub const EgressConfigError = error{
    ZeroInflightLimit,
    ZeroRetryBase,
    RetryCeilingBelowBase,
};

/// One send attempt. `(generation, sequence)` is the transport idempotency
/// identity.
pub fn EgressEnvelope(comptime T: type) type {
    return struct {
        generation: u64,
        sequence: u64,
        attempt: u32,
        payload: T,
    };
}

pub const EgressRetry = struct {
    sequence: u64,
    attempt: u32,
    backoff: u64,
    exhausted: bool,
};

pub fn EgressClaim(comptime T: type) type {
    return union(enum) {
        claimed: EgressEnvelope(T),
        empty,
        window_full,
        stale_generation: u64,
    };
}

pub const EgressAck = union(enum) {
    advanced: u64,
    unchanged: ?u64,
    /// `through` names a sequence never assigned. Refused: accepting it would
    /// lift the watermark over the next enqueue and strand that record (its
    /// genuine ACK would then read `unchanged`). Carries `next_sequence`.
    beyond_sent: u64,
    stale_generation: u64,
};

pub const EgressFailure = union(enum) {
    retrying: EgressRetry,
    exhausted: EgressRetry,
    unknown_sequence,
    stale_generation: u64,
};

pub const EgressRetryAction = union(enum) {
    scheduled: u64,
    unknown_sequence,
    stale_generation: u64,
};

pub const EgressReconnect = union(enum) {
    advanced: struct { generation: u64, replayed: usize },
    unchanged: u64,
    stale_generation: u64,
};

/// Reader-kind invalidations emitted by one transition.
pub const EgressChange = struct {
    pending: bool = false,
    inflight: bool = false,
    acked_through: bool = false,
    retry: bool = false,

    pub fn isEmpty(self: EgressChange) bool {
        return !self.pending and !self.inflight and !self.acked_through and !self.retry;
    }
};

pub fn EgressTransition(comptime Outcome: type) type {
    return struct { change: EgressChange, outcome: Outcome };
}

/// Pure egress delivery authority. Payloads are stored by value; a slice
/// payload is borrowed and must outlive the core, matching the other Zig cores.
pub fn EgressCore(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Envelope = EgressEnvelope(T);
        pub const Claim = EgressClaim(T);

        allocator: std.mem.Allocator,
        policy: EgressPolicy,
        current_generation: u64,
        next_seq: u64 = 0,
        acked: ?u64 = null,
        /// Ordered by sequence: enqueue appends a fresh maximum, and every
        /// re-insertion goes through `insertOrdered`.
        pending_list: std.ArrayList(Envelope) = .empty,
        /// Ordered by sequence (the reference's `BTreeMap`).
        inflight_list: std.ArrayList(Envelope) = .empty,
        /// Parked failures awaiting `retry_now`, ordered by sequence.
        failed_list: std.ArrayList(Envelope) = .empty,
        last_retry: ?EgressRetry = null,

        pub fn init(
            allocator: std.mem.Allocator,
            initial_generation: u64,
            policy: EgressPolicy,
        ) EgressConfigError!Self {
            if (policy.inflight_limit == 0) return error.ZeroInflightLimit;
            if (policy.retry_base == 0) return error.ZeroRetryBase;
            if (policy.retry_ceiling < policy.retry_base) return error.RetryCeilingBelowBase;
            return .{
                .allocator = allocator,
                .policy = policy,
                .current_generation = initial_generation,
            };
        }

        pub fn deinit(self: *Self) void {
            self.pending_list.deinit(self.allocator);
            self.inflight_list.deinit(self.allocator);
            self.failed_list.deinit(self.allocator);
            self.* = undefined;
        }

        // --- projections -----------------------------------------------------

        pub fn generation(self: *const Self) u64 {
            return self.current_generation;
        }

        pub fn nextSequence(self: *const Self) u64 {
            return self.next_seq;
        }

        /// Borrowed view, valid until the next mutation.
        pub fn pending(self: *const Self) []const Envelope {
            return self.pending_list.items;
        }

        /// Borrowed view, valid until the next mutation.
        pub fn inflight(self: *const Self) []const Envelope {
            return self.inflight_list.items;
        }

        pub fn ackedThrough(self: *const Self) ?u64 {
            return self.acked;
        }

        pub fn retry(self: *const Self) ?EgressRetry {
            return self.last_retry;
        }

        // --- transitions -----------------------------------------------------

        /// Assign the next sequence and place the value in the pending projection.
        pub fn enqueue(self: *Self, payload: T) !EgressTransition(u64) {
            const sequence = self.next_seq;
            try self.pending_list.append(self.allocator, .{
                .generation = self.current_generation,
                .sequence = sequence,
                .attempt = 0,
                .payload = payload,
            });
            self.next_seq +|= 1;
            return .{ .change = .{ .pending = true }, .outcome = sequence };
        }

        /// Move one pending value into the unacknowledged window. The caller
        /// supplies the generation its transport attachment captured, so an
        /// attachment from a superseded incarnation can neither claim nor replay.
        pub fn claim(self: *Self, attachment_generation: u64) !EgressTransition(Claim) {
            if (attachment_generation != self.current_generation) {
                return .{ .change = .{}, .outcome = .{ .stale_generation = self.current_generation } };
            }
            if (self.inflight_list.items.len >= self.policy.inflight_limit) {
                return .{ .change = .{}, .outcome = .window_full };
            }
            if (self.pending_list.items.len == 0) {
                return .{ .change = .{}, .outcome = .empty };
            }
            try self.inflight_list.ensureUnusedCapacity(self.allocator, 1);
            var record = self.pending_list.orderedRemove(0);
            record.generation = self.current_generation;
            record.attempt +|= 1;
            insertOrderedAssumeCapacity(&self.inflight_list, record);
            const retry_changed = if (self.last_retry) |r| r.sequence == record.sequence else false;
            if (retry_changed) self.last_retry = null;
            return .{
                .change = .{ .pending = true, .inflight = true, .retry = retry_changed },
                .outcome = .{ .claimed = record },
            };
        }

        /// Advance the cumulative acknowledgement watermark and prune every
        /// acknowledged record.
        pub fn ack(self: *Self, attachment_generation: u64, through: u64) EgressTransition(EgressAck) {
            if (attachment_generation != self.current_generation) {
                return .{ .change = .{}, .outcome = .{ .stale_generation = self.current_generation } };
            }
            // After the fence, BEFORE the watermark: a refusal changes nothing
            // and invalidates nothing.
            if (through >= self.next_seq) {
                return .{ .change = .{}, .outcome = .{ .beyond_sent = self.next_seq } };
            }
            if (self.acked) |current| {
                if (through <= current) return .{ .change = .{}, .outcome = .{ .unchanged = current } };
            }
            const inflight_before = self.inflight_list.items.len;
            const pending_before = self.pending_list.items.len;
            self.acked = through;
            retainAbove(&self.inflight_list, through);
            retainAbove(&self.failed_list, through);
            retainAbove(&self.pending_list, through);
            const retry_changed = if (self.last_retry) |r| r.sequence <= through else false;
            if (retry_changed) self.last_retry = null;
            return .{
                .change = .{
                    .pending = self.pending_list.items.len != pending_before,
                    .inflight = self.inflight_list.items.len != inflight_before,
                    .acked_through = true,
                    .retry = retry_changed,
                },
                .outcome = .{ .advanced = through },
            };
        }

        /// Park a failed in-flight record while retry budget remains; a record
        /// past its budget is dropped and the failure is terminal.
        pub fn fail(self: *Self, attachment_generation: u64, sequence: u64) !EgressTransition(EgressFailure) {
            if (attachment_generation != self.current_generation) {
                return .{ .change = .{}, .outcome = .{ .stale_generation = self.current_generation } };
            }
            const index = indexOf(self.inflight_list.items, sequence) orelse
                return .{ .change = .{}, .outcome = .unknown_sequence };
            const record = self.inflight_list.items[index];
            const exhausted = record.attempt > self.policy.retry_budget;
            if (!exhausted) try self.failed_list.ensureUnusedCapacity(self.allocator, 1);
            _ = self.inflight_list.orderedRemove(index);
            const r = EgressRetry{
                .sequence = sequence,
                .attempt = record.attempt,
                .backoff = self.backoff(record.attempt),
                .exhausted = exhausted,
            };
            self.last_retry = r;
            if (!exhausted) insertOrderedAssumeCapacity(&self.failed_list, record);
            return .{
                .change = .{ .inflight = true, .retry = true },
                .outcome = if (exhausted) .{ .exhausted = r } else .{ .retrying = r },
            };
        }

        /// Make a parked failed record eligible again (the caller decides when
        /// its derived backoff has elapsed). Order is preserved by sequence.
        pub fn retryNow(self: *Self, attachment_generation: u64, sequence: u64) !EgressTransition(EgressRetryAction) {
            if (attachment_generation != self.current_generation) {
                return .{ .change = .{}, .outcome = .{ .stale_generation = self.current_generation } };
            }
            const index = indexOf(self.failed_list.items, sequence) orelse
                return .{ .change = .{}, .outcome = .unknown_sequence };
            try self.pending_list.ensureUnusedCapacity(self.allocator, 1);
            const record = self.failed_list.orderedRemove(index);
            insertOrderedAssumeCapacity(&self.pending_list, record);
            const retry_changed = if (self.last_retry) |r| r.sequence == sequence else false;
            if (retry_changed) self.last_retry = null;
            return .{
                .change = .{ .pending = true, .retry = retry_changed },
                .outcome = .{ .scheduled = sequence },
            };
        }

        /// Fence the previous attachment and replay every unacknowledged record
        /// (in flight or parked) through the new generation. The watermark and
        /// the sequence space survive; only the producer incarnation changes.
        pub fn reconnect(self: *Self, new_generation: u64) !EgressTransition(EgressReconnect) {
            if (new_generation < self.current_generation) {
                return .{ .change = .{}, .outcome = .{ .stale_generation = self.current_generation } };
            }
            if (new_generation == self.current_generation) {
                return .{ .change = .{}, .outcome = .{ .unchanged = self.current_generation } };
            }
            const replayed = self.inflight_list.items.len + self.failed_list.items.len;
            try self.pending_list.ensureUnusedCapacity(self.allocator, replayed);
            self.current_generation = new_generation;
            for (self.inflight_list.items) |record| insertOrderedAssumeCapacity(&self.pending_list, record);
            for (self.failed_list.items) |record| insertOrderedAssumeCapacity(&self.pending_list, record);
            self.inflight_list.clearRetainingCapacity();
            self.failed_list.clearRetainingCapacity();
            for (self.pending_list.items) |*record| record.generation = new_generation;
            const retry_changed = self.last_retry != null;
            self.last_retry = null;
            // Every retained envelope's generation was rewritten above, so a
            // cached `pending` is stale whenever ANY record is retained — not
            // only when something was replayed out of the window.
            const pending_changed = replayed > 0 or self.pending_list.items.len > 0;
            return .{
                .change = .{ .pending = pending_changed, .inflight = replayed > 0, .retry = retry_changed },
                .outcome = .{ .advanced = .{ .generation = new_generation, .replayed = replayed } },
            };
        }

        // --- helpers ---------------------------------------------------------

        fn backoff(self: *const Self, attempt: u32) u64 {
            const shift: u6 = @intCast(@min(attempt -| 1, 63));
            const scaled = std.math.mul(u64, self.policy.retry_base, @as(u64, 1) << shift) catch std.math.maxInt(u64);
            return @min(scaled, self.policy.retry_ceiling);
        }

        fn indexOf(items: []const Envelope, sequence: u64) ?usize {
            for (items, 0..) |record, index| {
                if (record.sequence == sequence) return index;
            }
            return null;
        }

        fn insertOrderedAssumeCapacity(list: *std.ArrayList(Envelope), record: Envelope) void {
            var position: usize = list.items.len;
            for (list.items, 0..) |existing, index| {
                if (existing.sequence > record.sequence) {
                    position = index;
                    break;
                }
            }
            list.insertAssumeCapacity(position, record);
        }

        fn retainAbove(list: *std.ArrayList(Envelope), through: u64) void {
            var write: usize = 0;
            for (list.items) |record| {
                if (record.sequence > through) {
                    list.items[write] = record;
                    write += 1;
                }
            }
            list.shrinkRetainingCapacity(write);
        }
    };
}

const testing = std.testing;

fn testPolicy() EgressPolicy {
    return .{ .inflight_limit = 2, .retry_budget = 1, .retry_base = 5, .retry_ceiling = 20 };
}

test "lazily/egress_core: ack is monotone and reconnect fences the old attachment" {
    var core = try EgressCore(u64).init(testing.allocator, 7, testPolicy());
    defer core.deinit();
    _ = try core.enqueue(1);
    _ = try core.enqueue(2);
    try testing.expect((try core.claim(7)).outcome == .claimed);
    try testing.expectEqual(EgressAck{ .advanced = 0 }, core.ack(7, 0).outcome);
    try testing.expectEqual(EgressAck{ .unchanged = 0 }, core.ack(7, 0).outcome);
    const reconnect = (try core.reconnect(8)).outcome;
    try testing.expectEqual(@as(u64, 8), reconnect.advanced.generation);
    try testing.expectEqual(@as(u64, 8), (try core.claim(7)).outcome.stale_generation);
    try testing.expectEqual(@as(?u64, 0), core.ackedThrough());
}

test "lazily/egress_core: retry budget is bounded and backoff doubles to the ceiling" {
    var core = try EgressCore(u64).init(testing.allocator, 1, testPolicy());
    defer core.deinit();
    _ = try core.enqueue(1);
    const first = (try core.claim(1)).outcome.claimed;
    const retrying = (try core.fail(1, first.sequence)).outcome;
    try testing.expectEqual(@as(u64, 5), retrying.retrying.backoff);
    try testing.expectEqual(@as(u64, first.sequence), (try core.retryNow(1, first.sequence)).outcome.scheduled);
    const second = (try core.claim(1)).outcome.claimed;
    try testing.expectEqual(@as(u32, 2), second.attempt);
    const exhausted = (try core.fail(1, second.sequence)).outcome;
    try testing.expectEqual(@as(u64, 10), exhausted.exhausted.backoff);
    try testing.expectEqual(@as(usize, 0), core.pending().len);
    try testing.expect((try core.retryNow(1, second.sequence)).outcome == .unknown_sequence);
}

test "lazily/egress_core: an ack past the last assigned sequence is refused and changes nothing" {
    var core = try EgressCore(u64).init(testing.allocator, 1, .{});
    defer core.deinit();
    // Nothing assigned yet: even `through = 0` is beyond what was sent.
    const empty = core.ack(1, 0);
    try testing.expectEqual(EgressAck{ .beyond_sent = 0 }, empty.outcome);
    try testing.expect(empty.change.isEmpty());
    _ = try core.enqueue(10);
    _ = try core.claim(1);
    const refused = core.ack(1, 1);
    try testing.expectEqual(EgressAck{ .beyond_sent = 1 }, refused.outcome);
    try testing.expect(refused.change.isEmpty());
    try testing.expectEqual(@as(?u64, null), core.ackedThrough());
    try testing.expectEqual(@as(usize, 1), core.inflight().len);
    // The fence still wins over the refusal.
    try testing.expectEqual(@as(u64, 1), core.ack(0, 5).outcome.stale_generation);
    // The next record is not stranded: its genuine ack still advances.
    _ = try core.enqueue(20);
    try testing.expectEqual(EgressAck{ .advanced = 1 }, core.ack(1, 1).outcome);
}

test "lazily/egress_core: a replay-free reconnect still invalidates a non-empty pending" {
    var core = try EgressCore(u64).init(testing.allocator, 3, .{});
    defer core.deinit();
    _ = try core.enqueue(10);
    const t = try core.reconnect(4);
    try testing.expectEqual(@as(usize, 0), t.outcome.advanced.replayed);
    try testing.expect(t.change.pending);
    try testing.expect(!t.change.inflight);
    try testing.expectEqual(@as(u64, 4), core.pending()[0].generation);
    // With nothing retained, a reconnect dirties no list reader.
    var idle = try EgressCore(u64).init(testing.allocator, 1, .{});
    defer idle.deinit();
    const quiet = try idle.reconnect(2);
    try testing.expect(!quiet.change.pending and !quiet.change.inflight);
}

test "lazily/egress_core: configuration is validated" {
    try testing.expectError(error.ZeroInflightLimit, EgressCore(u64).init(testing.allocator, 1, .{ .inflight_limit = 0 }));
    try testing.expectError(error.ZeroRetryBase, EgressCore(u64).init(testing.allocator, 1, .{ .retry_base = 0 }));
    try testing.expectError(error.RetryCeilingBelowBase, EgressCore(u64).init(testing.allocator, 1, .{ .retry_base = 10, .retry_ceiling = 5 }));
}

test "lazily/egress_core: a full window refuses a claim without dirtying any reader" {
    var core = try EgressCore(u64).init(testing.allocator, 1, .{ .inflight_limit = 1 });
    defer core.deinit();
    _ = try core.enqueue(1);
    _ = try core.enqueue(2);
    _ = try core.claim(1);
    const refused = try core.claim(1);
    try testing.expect(refused.outcome == .window_full);
    try testing.expect(refused.change.isEmpty());
}
