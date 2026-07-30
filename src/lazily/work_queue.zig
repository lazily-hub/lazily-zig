//! `WorkQueueCell` — the single-threaded flavor of the competing-consumer queue.
//!
//! The lease/redelivery/dead-letter algebra lives in
//! [`WorkQueueCore`](queue_core.zig) and is shared verbatim with
//! `ThreadSafeWorkQueueCell` and `AsyncWorkQueueCell`; this shell owns four graph
//! identities and the publish path, nothing else.

const std = @import("std");
const Context = @import("context.zig").Context;
const Compute = @import("context.zig").Compute;
const Slot = @import("context.zig").Slot;
const ReaderKind = @import("reader_kind.zig").ReaderKind;
const cell = @import("cell.zig");
const core_mod = @import("queue_core.zig");

pub const WorkQueueCore = core_mod.WorkQueueCore;
pub const WorkQueueDeadLetterReason = core_mod.WorkQueueDeadLetterReason;
pub const WorkQueueError = core_mod.WorkQueueError;
pub const WorkQueueInvalidates = core_mod.WorkQueueInvalidates;

pub const WorkQueueVersions = core_mod.WorkQueueVersions;

/// Process-local competing-consumer queue with leased exclusive claims.
///
/// Item ids remain stable across retries and every claim gets a fresh delivery
/// id. Failed deliveries requeue at the tail until `max_deliveries` is reached,
/// then move to the dead-letter list. Leases expire strictly after deadline.
/// Distributed/HA use requires a consensus-backed leader or adapter.
pub fn WorkQueueCell(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Core = core_mod.WorkQueueCore(T);
        pub const Item = Core.Item;
        pub const Delivery = Core.Delivery;
        pub const DeadLetter = Core.DeadLetter;

        ctx: *Context,
        allocator: std.mem.Allocator,
        core: Core,
        pending_reader: ReaderKind,
        empty_reader: ReaderKind,
        in_flight_reader: ReaderKind,
        dead_letter_reader: ReaderKind,

        pub fn init(
            ctx: *Context,
            visibility_timeout: u64,
            max_deliveries: u64,
        ) !Self {
            var core = try Core.init(ctx.allocator, visibility_timeout, max_deliveries);
            errdefer core.deinit();
            const pending_reader = try ReaderKind.init(ctx);
            errdefer pending_reader.dispose();
            const empty_reader = try ReaderKind.init(ctx);
            errdefer empty_reader.dispose();
            const in_flight_reader = try ReaderKind.init(ctx);
            errdefer in_flight_reader.dispose();
            const dead_letter_reader = try ReaderKind.init(ctx);
            return .{
                .ctx = ctx,
                .allocator = ctx.allocator,
                .core = core,
                .pending_reader = pending_reader,
                .empty_reader = empty_reader,
                .in_flight_reader = in_flight_reader,
                .dead_letter_reader = dead_letter_reader,
            };
        }

        pub fn deinit(self: *Self) void {
            self.pending_reader.dispose();
            self.empty_reader.dispose();
            self.in_flight_reader.dispose();
            self.dead_letter_reader.dispose();
            self.core.deinit();
        }

        /// Publish exactly the reader kinds the core reported, in one frontier
        /// walk: a consumer must never see `pending_len` decremented while
        /// `is_empty` still reads stale.
        fn publish(self: *Self, changed: WorkQueueInvalidates) void {
            var readers: [4]ReaderKind = undefined;
            var count: usize = 0;
            if (changed.pending_len) {
                readers[count] = self.pending_reader;
                count += 1;
            }
            if (changed.in_flight_len) {
                readers[count] = self.in_flight_reader;
                count += 1;
            }
            if (changed.dead_letter_len) {
                readers[count] = self.dead_letter_reader;
                count += 1;
            }
            if (changed.is_empty) {
                readers[count] = self.empty_reader;
                count += 1;
            }
            if (count == 0) return;
            ReaderKind.bumpMany(self.ctx, readers[0..count]);
        }

        pub fn push(self: *Self, value: T) !u64 {
            const pushed = try self.core.push(value);
            self.publish(pushed.invalidates);
            return pushed.item_id;
        }

        pub fn claim(self: *Self, worker: []const u8, now: u64) !?Delivery {
            const claimed = try self.core.claim(worker, now);
            self.publish(claimed.invalidates);
            return claimed.delivery;
        }

        pub fn ack(self: *Self, worker: []const u8, delivery_id: u64) bool {
            const settled = self.core.ack(worker, delivery_id);
            self.publish(settled.invalidates);
            return settled.ok;
        }

        pub fn nack(self: *Self, worker: []const u8, delivery_id: u64) !bool {
            const settled = try self.core.nack(worker, delivery_id);
            self.publish(settled.invalidates);
            return settled.ok;
        }

        pub fn reapExpired(self: *Self, now: u64) !usize {
            const reaped = try self.core.reapExpired(now);
            self.publish(reaped.invalidates);
            return reaped.count;
        }

        pub const PendingLenReader = struct {
            owner: *const Self,
            slot: *Slot,

            pub fn get(reader: @This()) usize {
                return reader.owner.core.pendingLen();
            }
        };

        pub const EmptyReader = struct {
            owner: *const Self,
            slot: *Slot,

            pub fn get(reader: @This()) bool {
                return reader.owner.core.isEmpty();
            }
        };

        pub const InFlightLenReader = struct {
            owner: *const Self,
            slot: *Slot,

            pub fn get(reader: @This()) usize {
                return reader.owner.core.inFlightLen();
            }
        };

        pub const DeadLetterLenReader = struct {
            owner: *const Self,
            slot: *Slot,

            pub fn get(reader: @This()) usize {
                return reader.owner.core.deadLetterLen();
            }
        };

        pub fn pendingLen(self: *const Self) PendingLenReader {
            return .{ .owner = self, .slot = self.pending_reader.slot() };
        }

        pub fn isEmpty(self: *const Self) EmptyReader {
            return .{ .owner = self, .slot = self.empty_reader.slot() };
        }

        pub fn inFlightLen(self: *const Self) InFlightLenReader {
            return .{ .owner = self, .slot = self.in_flight_reader.slot() };
        }

        pub fn deadLetterLen(self: *const Self) DeadLetterLenReader {
            return .{ .owner = self, .slot = self.dead_letter_reader.slot() };
        }

        pub fn versions(self: *const Self) WorkQueueVersions {
            return .{
                .pending_len = self.pending_reader.version(),
                .is_empty = self.empty_reader.version(),
                .in_flight_len = self.in_flight_reader.version(),
                .dead_letter_len = self.dead_letter_reader.version(),
            };
        }

        pub fn pendingItems(self: *const Self) []const Item {
            return self.core.pendingItems();
        }

        pub fn deadLetterItems(self: *const Self) []const DeadLetter {
            return self.core.deadLetterItems();
        }

        pub fn inFlightDeliveries(
            self: *const Self,
            allocator: std.mem.Allocator,
        ) ![]Delivery {
            return self.core.inFlightDeliveries(allocator);
        }
    };
}

fn expectDelta(
    before: WorkQueueVersions,
    after: WorkQueueVersions,
    pending: bool,
    empty: bool,
    in_flight: bool,
    dead: bool,
) !void {
    try std.testing.expectEqual(before.pending_len + @intFromBool(pending), after.pending_len);
    try std.testing.expectEqual(before.is_empty + @intFromBool(empty), after.is_empty);
    try std.testing.expectEqual(before.in_flight_len + @intFromBool(in_flight), after.in_flight_len);
    try std.testing.expectEqual(before.dead_letter_len + @intFromBool(dead), after.dead_letter_len);
}

test "WorkQueueCell competing delivery fixture" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var queue = try WorkQueueCell([]const u8).init(ctx, 10, 3);
    defer queue.deinit();
    var before = queue.versions();
    try std.testing.expectEqual(@as(u64, 0), try queue.push("a"));
    try expectDelta(before, queue.versions(), true, true, false, false);
    before = queue.versions();
    try std.testing.expectEqual(@as(u64, 1), try queue.push("b"));
    try expectDelta(before, queue.versions(), true, false, false, false);
    before = queue.versions();
    const first = (try queue.claim("alpha", 100)).?;
    try std.testing.expectEqual(@as(u64, 0), first.delivery_id);
    try std.testing.expectEqual(@as(u64, 110), first.deadline);
    try expectDelta(before, queue.versions(), true, false, true, false);
    before = queue.versions();
    const second = (try queue.claim("beta", 100)).?;
    try std.testing.expectEqual(@as(u64, 1), second.delivery_id);
    try expectDelta(before, queue.versions(), true, true, true, false);
    before = queue.versions();
    try std.testing.expect((try queue.claim("gamma", 100)) == null);
    try expectDelta(before, queue.versions(), false, false, false, false);
    try std.testing.expect(!queue.ack("alpha", second.delivery_id));
    try expectDelta(before, queue.versions(), false, false, false, false);
    before = queue.versions();
    try std.testing.expect(queue.ack("beta", second.delivery_id));
    try expectDelta(before, queue.versions(), false, false, true, false);
    before = queue.versions();
    try std.testing.expect(try queue.nack("alpha", first.delivery_id));
    try expectDelta(before, queue.versions(), true, true, true, false);
    before = queue.versions();
    const retry = (try queue.claim("gamma", 105)).?;
    try std.testing.expectEqual(@as(u64, 2), retry.delivery_id);
    try std.testing.expectEqual(@as(u64, 2), retry.attempt);
    try std.testing.expectEqual(@as(u64, 115), retry.deadline);
    try expectDelta(before, queue.versions(), true, true, true, false);
}

test "WorkQueueCell strict expiry and dead letter fixture" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var queue = try WorkQueueCell([]const u8).init(ctx, 10, 2);
    defer queue.deinit();
    _ = try queue.push("poison");
    _ = try queue.claim("worker-1", 0);
    var before = queue.versions();
    try std.testing.expectEqual(@as(usize, 0), try queue.reapExpired(10));
    try expectDelta(before, queue.versions(), false, false, false, false);
    before = queue.versions();
    try std.testing.expectEqual(@as(usize, 1), try queue.reapExpired(11));
    try expectDelta(before, queue.versions(), true, true, true, false);
    const second = (try queue.claim("worker-2", 11)).?;
    try std.testing.expectEqual(@as(u64, 2), second.attempt);
    try std.testing.expectEqual(@as(u64, 21), second.deadline);
    before = queue.versions();
    try std.testing.expectEqual(@as(usize, 0), try queue.reapExpired(21));
    try expectDelta(before, queue.versions(), false, false, false, false);
    before = queue.versions();
    try std.testing.expectEqual(@as(usize, 1), try queue.reapExpired(22));
    try expectDelta(before, queue.versions(), false, false, true, true);
    const dead = queue.deadLetterItems();
    try std.testing.expectEqual(@as(usize, 1), dead.len);
    try std.testing.expectEqual(@as(u64, 2), dead[0].attempts);
    try std.testing.expectEqual(WorkQueueDeadLetterReason.expired, dead[0].reason);
}

test "WorkQueueCell reader kinds form real graph edges" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var queue = try WorkQueueCell([]const u8).init(ctx, 10, 2);
    defer queue.deinit();

    const Derived = struct {
        var owner: *WorkQueueCell([]const u8) = undefined;
        var runs: usize = 0;

        fn pendingLen(view: *Compute) !usize {
            runs += 1;
            return view.get(owner.pendingLen());
        }
    };
    Derived.owner = &queue;
    Derived.runs = 0;

    const pending_len = try cell.computed(usize, ctx, Derived.pendingLen, null);
    defer ctx.allocator.destroy(pending_len);
    try std.testing.expectEqual(@as(usize, 0), pending_len.get().*);

    const before_push = Derived.runs;
    _ = try queue.push("job");
    try std.testing.expectEqual(@as(usize, 1), pending_len.get().*);
    try std.testing.expectEqual(before_push + 1, Derived.runs);

    const before_claim = Derived.runs;
    _ = try queue.claim("worker", 0);
    try std.testing.expectEqual(@as(usize, 0), pending_len.get().*);
    try std.testing.expectEqual(before_claim + 1, Derived.runs);
}
