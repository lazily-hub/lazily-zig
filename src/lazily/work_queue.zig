const std = @import("std");

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

        allocator: std.mem.Allocator,
        visibility_timeout: u64,
        max_deliveries: u64,
        pending: std.ArrayList(Item) = .empty,
        in_flight: std.AutoHashMap(u64, Delivery),
        dead_letters: std.ArrayList(DeadLetter) = .empty,
        next_item_id: u64 = 0,
        next_delivery_id: u64 = 0,
        pending_version: u64 = 0,
        empty_version: u64 = 0,
        in_flight_version: u64 = 0,
        dead_letter_version: u64 = 0,

        const Self = @This();

        pub fn init(
            allocator: std.mem.Allocator,
            visibility_timeout: u64,
            max_deliveries: u64,
        ) WorkQueueError!Self {
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
            self.pending_version += 1;
            if (was_empty) self.empty_version += 1;
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
            self.pending_version += 1;
            if (self.pending.items.len == 0) self.empty_version += 1;
            self.in_flight_version += 1;
            return delivery;
        }

        pub fn ack(self: *Self, worker: []const u8, delivery_id: u64) bool {
            const delivery = self.in_flight.get(delivery_id) orelse return false;
            if (!std.mem.eql(u8, worker, delivery.worker)) return false;
            _ = self.in_flight.remove(delivery_id);
            self.in_flight_version += 1;
            return true;
        }

        fn fail(self: *Self, delivery: Delivery, reason: WorkQueueDeadLetterReason) !void {
            if (delivery.attempt >= self.max_deliveries) {
                try self.dead_letters.append(self.allocator, .{
                    .item_id = delivery.item_id,
                    .value = delivery.value,
                    .attempts = delivery.attempt,
                    .reason = reason,
                });
                self.dead_letter_version += 1;
            } else {
                const was_empty = self.pending.items.len == 0;
                try self.pending.append(self.allocator, .{
                    .item_id = delivery.item_id,
                    .value = delivery.value,
                    .attempts = delivery.attempt,
                });
                self.pending_version += 1;
                if (was_empty) self.empty_version += 1;
            }
        }

        pub fn nack(self: *Self, worker: []const u8, delivery_id: u64) !bool {
            const delivery = self.in_flight.get(delivery_id) orelse return false;
            if (!std.mem.eql(u8, worker, delivery.worker)) return false;
            try self.fail(delivery, .nack);
            _ = self.in_flight.remove(delivery_id);
            self.in_flight_version += 1;
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
            for (expired.items) |delivery_id| {
                const delivery = self.in_flight.get(delivery_id).?;
                try self.fail(delivery, .expired);
                _ = self.in_flight.remove(delivery_id);
                self.in_flight_version += 1;
            }
            return expired.items.len;
        }

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

        pub fn versions(self: *const Self) WorkQueueVersions {
            return .{
                .pending_len = self.pending_version,
                .is_empty = self.empty_version,
                .in_flight_len = self.in_flight_version,
                .dead_letter_len = self.dead_letter_version,
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
    var queue = try WorkQueueCell([]const u8).init(std.testing.allocator, 10, 3);
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
    var queue = try WorkQueueCell([]const u8).init(std.testing.allocator, 10, 2);
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
