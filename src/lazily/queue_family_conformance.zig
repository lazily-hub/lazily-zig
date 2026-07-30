//! The canonical `TopicCell` and `WorkQueueCell` corpora, replayed.
//!
//! Before this file, lazily-zig shipped both primitives with hand-transcribed
//! tests: `queue.zig` and `work_queue.zig` carry tests *named* after
//! `topiccell_*.json` / `workqueue_*.json` whose expected values were typed into
//! the source. The canonical fixtures were listed in
//! `scripts/check-conformance-coverage.sh` under `KNOWN_UNCOVERED` with the
//! reason "No runner at all in this binding" — accurate, and the reason the
//! spec's coverage rows for these two primitives could not honestly read green
//! here (#lzcoverageaudit). A transcription cannot catch the corpus changing
//! upstream; only a replay can.
//!
//! `queuecell_*.json` is NOT replayed here — `queue.zig` already replays all
//! five against the real cell, through the same manifest recorder. This file
//! closes the two gaps, so the whole queue family is now corpus-driven.
//!
//! # What is asserted per step
//!
//! Both replays assert the full expected state, the operation's return value,
//! and — the part that makes the suite able to fail for the right reason — the
//! `invalidates` matrix **per reader kind, in both directions**. A step
//! expecting `false` fails if the cell invalidated anyway, so over-invalidation
//! is as visible as under-invalidation. Asserting the post-state alone would
//! pass against a cell that dirties every reader on every op, which is exactly
//! the defect the reader-kind independence law exists to forbid.
//!
//! Invalidation is observed through each reader kind's version counter, the
//! observable this binding exposes (`ReaderKind.version`). `queue.zig` uses the
//! same probe for `queuecell_*`, and `work_queue.zig`'s `expectDelta` helper
//! established it for this primitive.
//!
//! # Two places the corpus is thinner than the code
//!
//! - `WorkQueueCell`'s `visibility_timeout` / `max_deliveries` are not in the
//!   fixture `initial`, so every binding supplies them out of band. The values
//!   here match lazily-go's runner exactly (10, and 2 for the dead-letter
//!   fixture) rather than being tuned until this binding passed.
//! - `restart` carries a `subscriber` the observable contract never uses: the
//!   one fixture step that issues it expects *nothing* to change. This binding's
//!   `TopicCell.restart` takes no subscriber for that reason, and the step still
//!   pins the no-op.

const std = @import("std");
const testing = std.testing;

const cj = @import("conformance_json.zig");
const Value = cj.Value;

const Context = @import("context.zig").Context;
const queue = @import("queue.zig");
const work_queue = @import("work_queue.zig");

const TopicDurability = queue.TopicDurability;
const Topic = queue.TopicCell([]const u8);
const TopicSnapshot = queue.TopicSnapshot([]const u8);
const TopicSubscriptionSnapshot = queue.TopicSubscriptionSnapshot;
const WorkQueue = work_queue.WorkQueueCell([]const u8);

const topic_fixtures = [_][]const u8{
    "collections/topiccell_broadcast_cursor_isolation.json",
    "collections/topiccell_durable_replay_gc.json",
    "collections/topiccell_ephemeral_lifecycle.json",
    "collections/topiccell_offline_tail_bounds.json",
};

const work_queue_fixtures = [_][]const u8{
    "collections/workqueue_competing_delivery.json",
    "collections/workqueue_lease_deadletter.json",
};

/// Total steps in each corpus. A replay that opens every fixture but silently
/// drives none of their steps reports the same "ok" as a real one, so each
/// entry point returns its step count and the corpus tests assert the total.
const topic_corpus_steps = 29;
const work_queue_corpus_steps = 18;

// ---------------------------------------------------------------------------
// TopicCell
// ---------------------------------------------------------------------------

fn parseDurability(raw: []const u8) !TopicDurability {
    if (std.mem.eql(u8, raw, "durable")) return .durable;
    if (std.mem.eql(u8, raw, "ephemeral")) return .ephemeral;
    return error.UnknownDurability;
}

/// Build a topic in the fixture's `initial` state.
///
/// Goes through `initFromSnapshot` rather than replaying `subscribe`/`publish`
/// to get there: the snapshot path is the only one that can seat a cursor at an
/// arbitrary offset, which `topiccell_durable_replay_gc` starts from.
fn buildTopic(ctx: *Context, initial: Value) !Topic {
    const allocator = testing.allocator;
    const elements_json = try cj.arrayOr(initial, "elements");
    const elements = try allocator.alloc([]const u8, elements_json.len);
    defer allocator.free(elements);
    for (elements_json, 0..) |element, index| elements[index] = try cj.asStr(element);

    const subs_json = cj.field(initial, "subscriptions");
    var subs: std.ArrayList(TopicSubscriptionSnapshot) = .empty;
    defer subs.deinit(allocator);
    if (subs_json) |node| {
        switch (node) {
            .object => |object| {
                var it = object.iterator();
                while (it.next()) |entry| {
                    try subs.append(allocator, .{
                        .subscriber_id = entry.key_ptr.*,
                        .cursor = try cj.asUsize(try cj.required(entry.value_ptr.*, "cursor")),
                        .durability = try parseDurability(
                            try cj.asStr(try cj.required(entry.value_ptr.*, "durability")),
                        ),
                        .connected = try cj.asBool(try cj.required(entry.value_ptr.*, "connected")),
                    });
                }
            },
            else => {},
        }
    }

    return Topic.initFromSnapshot(ctx, .{
        .allocator = allocator,
        .base_offset = try cj.asUsize(try cj.required(initial, "base_offset")),
        .elements = elements,
        .subscriptions = subs.items,
    });
}

/// Every subscriber id the fixture ever mentions, in first-seen order.
///
/// Reader versions have to be sampled before each step for ids that may not
/// exist yet (a `subscribe` step) or may stop existing (an ephemeral
/// `disconnect` removes the subscription outright), so the id set comes from the
/// fixture rather than from the live cell.
fn collectSubscriberIds(
    ids: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    fixture: Value,
) !void {
    const add = struct {
        fn call(list: *std.ArrayList([]const u8), alloc: std.mem.Allocator, id: []const u8) !void {
            for (list.items) |seen| if (std.mem.eql(u8, seen, id)) return;
            try list.append(alloc, id);
        }
    };
    if (cj.field(try cj.required(fixture, "initial"), "subscriptions")) |node| {
        switch (node) {
            .object => |object| {
                var it = object.iterator();
                while (it.next()) |entry| try add.call(ids, allocator, entry.key_ptr.*);
            },
            else => {},
        }
    }
    for (try cj.arrayOr(fixture, "steps")) |step| {
        if (cj.field(try cj.required(step, "op"), "subscriber")) |id| {
            try add.call(ids, allocator, try cj.asStr(id));
        }
        const expected = try cj.required(step, "expected");
        for ([_][]const u8{ "subscriptions", "reads", "invalidates" }) |key| {
            if (cj.field(expected, key)) |node| {
                switch (node) {
                    .object => |object| {
                        var it = object.iterator();
                        while (it.next()) |entry| try add.call(ids, allocator, entry.key_ptr.*);
                    },
                    else => {},
                }
            }
        }
    }
}

fn assertTopicState(topic: *const Topic, expected: Value, where: []const u8) !void {
    errdefer std.debug.print("topic state mismatch at {s}\n", .{where});

    try testing.expectEqual(
        try cj.asUsize(try cj.required(expected, "base_offset")),
        topic.baseOffset(),
    );

    const want_elements = try cj.arrayOr(expected, "elements");
    const got_elements = topic.items();
    try testing.expectEqual(want_elements.len, got_elements.len);
    for (want_elements, got_elements) |want, got| {
        try testing.expectEqualStrings(try cj.asStr(want), got);
    }

    // Subscriptions are asserted as a set, not just per named id: a step that
    // must REMOVE an ephemeral subscription is only observable if a surviving
    // extra entry fails, so the count is part of the claim.
    const want_subs = cj.field(expected, "subscriptions");
    var want_count: usize = 0;
    if (want_subs) |node| {
        switch (node) {
            .object => |object| {
                var it = object.iterator();
                while (it.next()) |entry| {
                    want_count += 1;
                    const got = topic.subscription(entry.key_ptr.*) orelse {
                        std.debug.print("{s}: subscription {s} is absent\n", .{ where, entry.key_ptr.* });
                        return error.MissingSubscription;
                    };
                    try testing.expectEqual(
                        try cj.asUsize(try cj.required(entry.value_ptr.*, "cursor")),
                        got.cursor,
                    );
                    try testing.expectEqual(
                        try parseDurability(try cj.asStr(try cj.required(entry.value_ptr.*, "durability"))),
                        got.durability,
                    );
                    try testing.expectEqual(
                        try cj.asBool(try cj.required(entry.value_ptr.*, "connected")),
                        got.connected,
                    );
                }
            },
            else => {},
        }
    }
    try testing.expectEqual(want_count, topic.subscriptions.count());

    // `reads` is the cursor's retained tail per subscriber. A subscriber absent
    // from `reads` but present in `subscriptions` is not asserted; a subscriber
    // in `reads` must exist and match exactly.
    if (cj.field(expected, "reads")) |node| {
        switch (node) {
            .object => |object| {
                var it = object.iterator();
                while (it.next()) |entry| {
                    const want_stream = try cj.asArray(entry.value_ptr.*);
                    const got_stream = try topic.readStream(entry.key_ptr.*);
                    try testing.expectEqual(want_stream.len, got_stream.len);
                    for (want_stream, got_stream) |want, got| {
                        try testing.expectEqualStrings(try cj.asStr(want), got);
                    }
                }
            },
            else => {},
        }
    }
}

/// Replay one `topiccell_*.json` fixture. Returns the step count.
fn replayTopic(rel_path: []const u8) !usize {
    const allocator = testing.allocator;
    var parsed = (try cj.load(rel_path)) orelse return error.SkipZigTest;
    defer parsed.deinit();
    const fixture = parsed.value;

    var ids: std.ArrayList([]const u8) = .empty;
    defer ids.deinit(allocator);
    try collectSubscriberIds(&ids, allocator, fixture);

    const ctx = try Context.init(allocator);
    defer ctx.deinit();
    var topic = try buildTopic(ctx, try cj.required(fixture, "initial"));
    defer topic.deinit();

    const before = try allocator.alloc(?u64, ids.items.len);
    defer allocator.free(before);

    const steps = try cj.arrayOr(fixture, "steps");
    for (steps, 0..) |step, index| {
        const op = try cj.required(step, "op");
        const op_type = try cj.asStr(try cj.required(op, "type"));
        const expected = try cj.required(step, "expected");
        const where = try std.fmt.allocPrint(
            allocator,
            "{s} step {d} ({s})",
            .{ rel_path, index, op_type },
        );
        defer allocator.free(where);

        for (ids.items, 0..) |id, slot| before[slot] = topic.readerVersion(id);

        var returned_string: ?[]const u8 = null;
        var returned_usize: ?usize = null;
        var returned_is_null = false;

        if (std.mem.eql(u8, op_type, "publish")) {
            _ = try topic.publish(try cj.asStr(try cj.required(op, "value")));
        } else if (std.mem.eql(u8, op_type, "subscribe")) {
            _ = try topic.subscribe(
                try cj.asStr(try cj.required(op, "subscriber")),
                try parseDurability(try cj.asStr(try cj.required(op, "durability"))),
            );
        } else if (std.mem.eql(u8, op_type, "reconnect")) {
            try topic.reconnect(try cj.asStr(try cj.required(op, "subscriber")));
        } else if (std.mem.eql(u8, op_type, "disconnect")) {
            try topic.disconnect(try cj.asStr(try cj.required(op, "subscriber")));
        } else if (std.mem.eql(u8, op_type, "restart")) {
            topic.restart();
        } else if (std.mem.eql(u8, op_type, "gc")) {
            returned_usize = topic.gc();
        } else if (std.mem.eql(u8, op_type, "advance")) {
            // The corpus spells `advance` as "consume one element and tell me
            // which"; this binding's `advance` moves the cursor by `count` and
            // returns the new cursor. Read the element AT the cursor first, then
            // move by one: a no-op advance (offline, or already at the tail)
            // must report `null` rather than the element it did not consume.
            const subscriber = try cj.asStr(try cj.required(op, "subscriber"));
            const stream = try topic.readStream(subscriber);
            const head: ?[]const u8 = if (stream.len == 0) null else stream[0];
            const cursor_before = (topic.subscription(subscriber) orelse
                return error.MissingSubscription).cursor;
            const cursor_after = try topic.advance(subscriber, 1);
            if (cursor_after == cursor_before) {
                returned_is_null = true;
            } else {
                returned_string = head;
            }
        } else {
            std.debug.print("unknown TopicCell op: {s}\n", .{op_type});
            return error.UnknownOpType;
        }

        try assertTopicState(&topic, expected, where);

        if (cj.field(step, "returns")) |want| {
            errdefer std.debug.print("returns mismatch at {s}\n", .{where});
            switch (want) {
                .null => try testing.expect(returned_is_null or returned_string == null),
                .string => |s| try testing.expectEqualStrings(s, returned_string orelse ""),
                else => try testing.expectEqual(try cj.asUsize(want), returned_usize orelse 0),
            }
        }

        // The reader-kind claim, both directions, per subscriber.
        if (cj.field(expected, "invalidates")) |node| {
            switch (node) {
                .object => |object| {
                    var it = object.iterator();
                    while (it.next()) |entry| {
                        const want_invalidated = try cj.asBool(entry.value_ptr.*);
                        const id = entry.key_ptr.*;
                        var slot: usize = 0;
                        while (slot < ids.items.len and
                            !std.mem.eql(u8, ids.items[slot], id)) : (slot += 1)
                        {}
                        const after = topic.readerVersion(id);
                        const changed = if (after) |now|
                            (before[slot] == null or before[slot].? != now)
                        else
                            // The subscription is gone. Its reader was disposed,
                            // so every reader of it is invalid — which is a
                            // stronger observation than a version bump, and the
                            // only one available for a removed ephemeral.
                            before[slot] != null;
                        errdefer std.debug.print(
                            "{s}: subscriber {s} invalidates want={} got={}\n",
                            .{ where, id, want_invalidated, changed },
                        );
                        try testing.expectEqual(want_invalidated, changed);
                    }
                },
                else => {},
            }
        }
    }

    return steps.len;
}

test "lazily/queue-family conformance: TopicCell replays the canonical corpus" {
    var total: usize = 0;
    for (topic_fixtures) |rel_path| {
        total += replayTopic(rel_path) catch |err| switch (err) {
            // No `lazily-spec` sibling checkout. CI asserts the corpus is
            // present, so this cannot report green there.
            error.SkipZigTest => return error.SkipZigTest,
            else => return err,
        };
    }
    // An absence guard proves the fixtures exist; only a positive step count
    // proves this binary drove them.
    try testing.expectEqual(@as(usize, topic_corpus_steps), total);
}

// ---------------------------------------------------------------------------
// WorkQueueCell
// ---------------------------------------------------------------------------

fn assertWorkQueueState(wq: *const WorkQueue, expected: Value, where: []const u8) !void {
    errdefer std.debug.print("work-queue state mismatch at {s}\n", .{where});

    const want_pending = try cj.arrayOr(expected, "pending");
    const got_pending = wq.pendingItems();
    try testing.expectEqual(want_pending.len, got_pending.len);
    for (want_pending, got_pending) |want, got| {
        try testing.expectEqual(try cj.asU64(try cj.required(want, "item_id")), got.item_id);
        try testing.expectEqualStrings(try cj.asStr(try cj.required(want, "value")), got.value);
        try testing.expectEqual(try cj.asU64(try cj.required(want, "attempts")), got.attempts);
    }

    // In-flight deliveries are keyed by delivery id in a hash map here, so the
    // fixture's array order is not this binding's order. Match by delivery id
    // and assert the count, which pins the same set without inventing an
    // ordering the primitive does not promise.
    const want_in_flight = try cj.arrayOr(expected, "in_flight");
    const got_in_flight = try wq.inFlightDeliveries(testing.allocator);
    defer testing.allocator.free(got_in_flight);
    try testing.expectEqual(want_in_flight.len, got_in_flight.len);
    for (want_in_flight) |want| {
        const delivery_id = try cj.asU64(try cj.required(want, "delivery_id"));
        const found = for (got_in_flight) |got| {
            if (got.delivery_id == delivery_id) break got;
        } else {
            std.debug.print("{s}: delivery {d} is not in flight\n", .{ where, delivery_id });
            return error.MissingDelivery;
        };
        try testing.expectEqual(try cj.asU64(try cj.required(want, "item_id")), found.item_id);
        try testing.expectEqualStrings(try cj.asStr(try cj.required(want, "value")), found.value);
        try testing.expectEqualStrings(try cj.asStr(try cj.required(want, "worker")), found.worker);
        try testing.expectEqual(try cj.asU64(try cj.required(want, "attempt")), found.attempt);
        try testing.expectEqual(try cj.asU64(try cj.required(want, "deadline")), found.deadline);
    }

    const want_dead = try cj.arrayOr(expected, "dead_letters");
    const got_dead = wq.deadLetterItems();
    try testing.expectEqual(want_dead.len, got_dead.len);
    for (want_dead, got_dead) |want, got| {
        try testing.expectEqual(try cj.asU64(try cj.required(want, "item_id")), got.item_id);
        try testing.expectEqualStrings(try cj.asStr(try cj.required(want, "value")), got.value);
        try testing.expectEqual(try cj.asU64(try cj.required(want, "attempts")), got.attempts);
        const want_reason = try cj.asStr(try cj.required(want, "reason"));
        const got_reason = switch (got.reason) {
            .nack => "nack",
            .expired => "expired",
        };
        try testing.expectEqualStrings(want_reason, got_reason);
    }

    // `reads` are the four reader kinds. Reading them here (not only their
    // version counters) is what makes the invalidation matrix a claim about an
    // observable value rather than about a counter that happens to move.
    if (cj.field(expected, "reads")) |reads| {
        try testing.expectEqual(
            try cj.asUsize(try cj.required(reads, "pending_len")),
            wq.pendingLen().get(),
        );
        try testing.expectEqual(
            try cj.asBool(try cj.required(reads, "is_empty")),
            wq.isEmpty().get(),
        );
        try testing.expectEqual(
            try cj.asUsize(try cj.required(reads, "in_flight_len")),
            wq.inFlightLen().get(),
        );
        try testing.expectEqual(
            try cj.asUsize(try cj.required(reads, "dead_letter_len")),
            wq.deadLetterLen().get(),
        );
    }
}

/// Replay one `workqueue_*.json` fixture. Returns the step count.
fn replayWorkQueue(rel_path: []const u8, max_deliveries: u64) !usize {
    const allocator = testing.allocator;
    var parsed = (try cj.load(rel_path)) orelse return error.SkipZigTest;
    defer parsed.deinit();
    const fixture = parsed.value;

    const ctx = try Context.init(allocator);
    defer ctx.deinit();
    var wq = try WorkQueue.init(ctx, 10, max_deliveries);
    defer wq.deinit();

    // Both canonical fixtures start empty; there is no snapshot constructor to
    // seat pending/in-flight state, and no fixture needs one. Fail loudly rather
    // than silently replaying from the wrong start if that ever changes.
    const initial = try cj.required(fixture, "initial");
    for ([_][]const u8{ "pending", "in_flight", "dead_letters" }) |key| {
        try testing.expectEqual(@as(usize, 0), (try cj.arrayOr(initial, key)).len);
    }

    const steps = try cj.arrayOr(fixture, "steps");
    for (steps, 0..) |step, index| {
        const op = try cj.required(step, "op");
        const op_type = try cj.asStr(try cj.required(op, "type"));
        const expected = try cj.required(step, "expected");
        const where = try std.fmt.allocPrint(
            allocator,
            "{s} step {d} ({s})",
            .{ rel_path, index, op_type },
        );
        defer allocator.free(where);

        const before = wq.versions();

        var returned_u64: ?u64 = null;
        var returned_bool: ?bool = null;
        var returned_delivery: ?WorkQueue.Delivery = null;
        var returned_is_null = false;

        if (std.mem.eql(u8, op_type, "push")) {
            returned_u64 = try wq.push(try cj.asStr(try cj.required(op, "value")));
        } else if (std.mem.eql(u8, op_type, "claim")) {
            const claimed = try wq.claim(
                try cj.asStr(try cj.required(op, "worker")),
                try cj.asU64(try cj.required(op, "now")),
            );
            if (claimed) |delivery| returned_delivery = delivery else returned_is_null = true;
        } else if (std.mem.eql(u8, op_type, "ack")) {
            returned_bool = wq.ack(
                try cj.asStr(try cj.required(op, "worker")),
                try cj.asU64(try cj.required(op, "delivery_id")),
            );
        } else if (std.mem.eql(u8, op_type, "nack")) {
            returned_bool = try wq.nack(
                try cj.asStr(try cj.required(op, "worker")),
                try cj.asU64(try cj.required(op, "delivery_id")),
            );
        } else if (std.mem.eql(u8, op_type, "reap_expired")) {
            returned_u64 = @intCast(try wq.reapExpired(try cj.asU64(try cj.required(op, "now"))));
        } else {
            std.debug.print("unknown WorkQueueCell op: {s}\n", .{op_type});
            return error.UnknownOpType;
        }

        try assertWorkQueueState(&wq, expected, where);

        if (cj.field(step, "returns")) |want| {
            errdefer std.debug.print("returns mismatch at {s}\n", .{where});
            switch (want) {
                .null => try testing.expect(returned_is_null),
                .bool => |b| try testing.expectEqual(b, returned_bool orelse !b),
                .integer, .number_string => try testing.expectEqual(
                    try cj.asU64(want),
                    returned_u64 orelse return error.ExpectedIntegerReturn,
                ),
                // A `claim` returns the whole delivery record; every field is
                // part of the contract, `attempt` and `deadline` especially —
                // they are what the redelivery and lease laws are stated over.
                .object => {
                    const delivery = returned_delivery orelse return error.ExpectedDelivery;
                    try testing.expectEqual(
                        try cj.asU64(try cj.required(want, "delivery_id")),
                        delivery.delivery_id,
                    );
                    try testing.expectEqual(
                        try cj.asU64(try cj.required(want, "item_id")),
                        delivery.item_id,
                    );
                    try testing.expectEqualStrings(
                        try cj.asStr(try cj.required(want, "value")),
                        delivery.value,
                    );
                    try testing.expectEqualStrings(
                        try cj.asStr(try cj.required(want, "worker")),
                        delivery.worker,
                    );
                    try testing.expectEqual(
                        try cj.asU64(try cj.required(want, "attempt")),
                        delivery.attempt,
                    );
                    try testing.expectEqual(
                        try cj.asU64(try cj.required(want, "deadline")),
                        delivery.deadline,
                    );
                },
                else => return error.UnsupportedReturnShape,
            }
        }

        const after = wq.versions();
        const invalidates = try cj.required(expected, "invalidates");
        const check = struct {
            fn call(
                name: []const u8,
                was: u64,
                now: u64,
                node: Value,
                site: []const u8,
            ) !void {
                const want_invalidated = try cj.asBool(try cj.required(node, name));
                const changed = was != now;
                errdefer std.debug.print(
                    "{s}: reader {s} invalidates want={} got={}\n",
                    .{ site, name, want_invalidated, changed },
                );
                try testing.expectEqual(want_invalidated, changed);
            }
        };
        try check.call("pending_len", before.pending_len, after.pending_len, invalidates, where);
        try check.call("is_empty", before.is_empty, after.is_empty, invalidates, where);
        try check.call("in_flight_len", before.in_flight_len, after.in_flight_len, invalidates, where);
        try check.call("dead_letter_len", before.dead_letter_len, after.dead_letter_len, invalidates, where);
    }

    return steps.len;
}

test "lazily/queue-family conformance: WorkQueueCell replays the canonical corpus" {
    var total: usize = 0;
    for (work_queue_fixtures) |rel_path| {
        // `max_deliveries` is not in the fixture; these are lazily-go's values.
        const max_deliveries: u64 =
            if (std.mem.endsWith(u8, rel_path, "workqueue_lease_deadletter.json")) 2 else 3;
        total += replayWorkQueue(rel_path, max_deliveries) catch |err| switch (err) {
            error.SkipZigTest => return error.SkipZigTest,
            else => return err,
        };
    }
    try testing.expectEqual(@as(usize, work_queue_corpus_steps), total);
}

test "lazily/queue-family conformance: the invalidation probe can fail" {
    // The corpus above depends on the version-counter probe being able to
    // report "not invalidated". If `ReaderKind.version` ever became monotonic
    // per read, or the readers were fused, every `invalidates: false` step would
    // pass for the wrong reason and the whole file would assert nothing.
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var wq = try WorkQueue.init(ctx, 10, 3);
    defer wq.deinit();

    const idle = wq.versions();
    try testing.expectEqual(idle.pending_len, wq.versions().pending_len);

    _ = try wq.push("a");
    const after_push = wq.versions();
    try testing.expect(after_push.pending_len != idle.pending_len);
    // A second push into a non-empty queue must NOT move `is_empty` — the
    // reader kinds are independent, and this is the discrimination the corpus
    // relies on.
    _ = try wq.push("b");
    const after_second = wq.versions();
    try testing.expect(after_second.pending_len != after_push.pending_len);
    try testing.expectEqual(after_push.is_empty, after_second.is_empty);
}
