const std = @import("std");
const Context = @import("context.zig").Context;
const Compute = @import("context.zig").Compute;
const Slot = @import("context.zig").Slot;
const ReaderKind = @import("reader_kind.zig").ReaderKind;
const cell = @import("cell.zig");

pub const WorkQueueDeadLetterReason = enum { nack, expired };

pub const WorkQueueVersions = struct {
    pending_len: u64,
    is_empty: u64,
    in_flight_len: u64,
    dead_letter_len: u64,
};

pub const WorkQueueError = error{
    InvalidConfiguration,
    ItemIdExhausted,
    DeliveryIdExhausted,
    DeadlineOverflow,
};

/// Process-local competing-consumer queue with leased exclusive claims.
///
/// Item ids remain stable across retries and every claim gets a fresh delivery
/// id. Failed deliveries requeue at the tail until `max_deliveries` is reached,
/// then move to the dead-letter list. Leases expire strictly after deadline.
/// Distributed/HA use requires a consensus-backed leader or adapter.
pub fn WorkQueueCell(comptime T: type) type {
    return struct {
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

        ctx: *Context,
        allocator: std.mem.Allocator,
        visibility_timeout: u64,
        max_deliveries: u64,
        pending: std.ArrayList(Item) = .empty,
        in_flight: std.AutoHashMap(u64, Delivery),
        dead_letters: std.ArrayList(DeadLetter) = .empty,
        next_item_id: u64 = 0,
        next_delivery_id: u64 = 0,
        pending_reader: ReaderKind,
        empty_reader: ReaderKind,
        in_flight_reader: ReaderKind,
        dead_letter_reader: ReaderKind,

        const Self = @This();

        pub fn init(
            ctx: *Context,
            visibility_timeout: u64,
            max_deliveries: u64,
        ) !Self {
            if (visibility_timeout == 0 or max_deliveries == 0) {
                return error.InvalidConfiguration;
            }
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
                .visibility_timeout = visibility_timeout,
                .max_deliveries = max_deliveries,
                .in_flight = std.AutoHashMap(u64, Delivery).init(ctx.allocator),
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
            self.pending.deinit(self.allocator);
            self.in_flight.deinit();
            self.dead_letters.deinit(self.allocator);
        }

        pub fn push(self: *Self, value: T) !u64 {
            if (self.next_item_id == std.math.maxInt(u64)) {
                return error.ItemIdExhausted;
            }
            const was_empty = self.pending.items.len == 0;
            const item_id = self.next_item_id;
            try self.pending.append(self.allocator, .{
                .item_id = item_id,
                .value = value,
                .attempts = 0,
            });
            self.next_item_id += 1;
            var changed = [_]ReaderKind{ self.pending_reader, self.empty_reader };
            ReaderKind.bumpMany(self.ctx, changed[0..if (was_empty) 2 else 1]);
            return item_id;
        }

        pub fn claim(self: *Self, worker: []const u8, now: u64) !?Delivery {
            if (self.pending.items.len == 0) return null;
            if (self.next_delivery_id == std.math.maxInt(u64)) {
                return error.DeliveryIdExhausted;
            }
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
            var changed = [_]ReaderKind{
                self.pending_reader,
                self.in_flight_reader,
                self.empty_reader,
            };
            ReaderKind.bumpMany(self.ctx, changed[0..if (self.pending.items.len == 0) 3 else 2]);
            return delivery;
        }

        pub fn ack(self: *Self, worker: []const u8, delivery_id: u64) bool {
            const delivery = self.in_flight.get(delivery_id) orelse return false;
            if (!std.mem.eql(u8, worker, delivery.worker)) return false;
            _ = self.in_flight.remove(delivery_id);
            self.in_flight_reader.bump();
            return true;
        }

        const FailureTransition = struct {
            requeued: bool,
            became_non_empty: bool,
        };

        fn fail(self: *Self, delivery: Delivery, reason: WorkQueueDeadLetterReason) !FailureTransition {
            if (delivery.attempt >= self.max_deliveries) {
                try self.dead_letters.append(self.allocator, .{
                    .item_id = delivery.item_id,
                    .value = delivery.value,
                    .attempts = delivery.attempt,
                    .reason = reason,
                });
                return .{ .requeued = false, .became_non_empty = false };
            } else {
                const was_empty = self.pending.items.len == 0;
                try self.pending.append(self.allocator, .{
                    .item_id = delivery.item_id,
                    .value = delivery.value,
                    .attempts = delivery.attempt,
                });
                return .{ .requeued = true, .became_non_empty = was_empty };
            }
        }

        pub fn nack(self: *Self, worker: []const u8, delivery_id: u64) !bool {
            const delivery = self.in_flight.get(delivery_id) orelse return false;
            if (!std.mem.eql(u8, worker, delivery.worker)) return false;
            const transition = try self.fail(delivery, .nack);
            _ = self.in_flight.remove(delivery_id);
            var changed: [3]ReaderKind = undefined;
            changed[0] = self.in_flight_reader;
            changed[1] = if (transition.requeued) self.pending_reader else self.dead_letter_reader;
            const count: usize = if (transition.became_non_empty) blk: {
                changed[2] = self.empty_reader;
                break :blk 3;
            } else 2;
            ReaderKind.bumpMany(self.ctx, changed[0..count]);
            return true;
        }

        pub fn reapExpired(self: *Self, now: u64) !usize {
            var expired: std.ArrayList(u64) = .empty;
            defer expired.deinit(self.allocator);
            var iterator = self.in_flight.iterator();
            while (iterator.next()) |entry| {
                if (entry.value_ptr.deadline < now) {
                    try expired.append(self.allocator, entry.key_ptr.*);
                }
            }
            if (expired.items.len == 0) return 0;
            std.mem.sort(u64, expired.items, {}, std.sort.asc(u64));
            var requeued = false;
            var dead_lettered = false;
            var became_non_empty = false;
            for (expired.items) |delivery_id| {
                const delivery = self.in_flight.get(delivery_id).?;
                const transition = try self.fail(delivery, .expired);
                requeued = requeued or transition.requeued;
                dead_lettered = dead_lettered or !transition.requeued;
                became_non_empty = became_non_empty or transition.became_non_empty;
                _ = self.in_flight.remove(delivery_id);
            }
            var changed: [4]ReaderKind = undefined;
            var count: usize = 0;
            changed[count] = self.in_flight_reader;
            count += 1;
            if (requeued) {
                changed[count] = self.pending_reader;
                count += 1;
            }
            if (dead_lettered) {
                changed[count] = self.dead_letter_reader;
                count += 1;
            }
            if (became_non_empty) {
                changed[count] = self.empty_reader;
                count += 1;
            }
            ReaderKind.bumpMany(self.ctx, changed[0..count]);
            return expired.items.len;
        }

        pub const PendingLenReader = struct {
            owner: *const Self,
            slot: *Slot,

            pub fn get(reader: @This()) usize {
                return reader.owner.pending.items.len;
            }
        };

        pub const EmptyReader = struct {
            owner: *const Self,
            slot: *Slot,

            pub fn get(reader: @This()) bool {
                return reader.owner.pending.items.len == 0;
            }
        };

        pub const InFlightLenReader = struct {
            owner: *const Self,
            slot: *Slot,

            pub fn get(reader: @This()) usize {
                return reader.owner.in_flight.count();
            }
        };

        pub const DeadLetterLenReader = struct {
            owner: *const Self,
            slot: *Slot,

            pub fn get(reader: @This()) usize {
                return reader.owner.dead_letters.items.len;
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
            return self.pending.items;
        }

        pub fn deadLetterItems(self: *const Self) []const DeadLetter {
            return self.dead_letters.items;
        }

        pub fn inFlightDeliveries(
            self: *const Self,
            allocator: std.mem.Allocator,
        ) ![]Delivery {
            var result = try allocator.alloc(Delivery, self.in_flight.count());
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
