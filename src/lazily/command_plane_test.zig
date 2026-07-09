const std = @import("std");
const cp = @import("command_plane.zig");
const receipt_mod = @import("receipt.zig");
const ipc = @import("ipc.zig");
const CommandProjection = cp.CommandProjection;
const CommandSubmit = cp.CommandSubmit;
const CommandCancel = cp.CommandCancel;
const CommandEvent = cp.CommandEvent;
const CommandEvents = cp.CommandEvents;
const CommandRpcClient = cp.CommandRpcClient;
const CausalReceipt = receipt_mod.CausalReceipt;
const ReceiptOutcome = receipt_mod.ReceiptOutcome;

const allocator = std.testing.allocator;

// A canonical submit frame (matches the conformance fixtures' envelope).
fn sampleSubmit(command_id: []const u8, gen: u64) CommandSubmit {
    return .{
        .command_id = command_id,
        .causation_id = command_id,
        .source = "vscode-plugin",
        .target = "project-controller",
        .namespace = "agent-doc",
        .name = "editor_route",
        .authority_generation = gen,
        .idempotency_key = "project-root:plan.md:run",
        .deadline_ms = 120000,
        .policy = .{
            .dedupe = .same_idempotency_key,
            .supersede = false,
            .cancel_on_preempt = true,
        },
        .payload_type = "agent-doc.editor_route.v1",
        .payload_hash = "sha256:abc",
        .payload = ipc.IpcValue.fromInline(&.{ 1, 2, 3 }),
        .required_features = &.{ "causal-receipts", "command-events" },
    };
}

fn receipt(command_id: []const u8, receipt_id: []const u8, gen: u64, outcome: ReceiptOutcome) CausalReceipt {
    return .{
        .receipt_id = receipt_id,
        .causation_id = command_id,
        .observer = "project-controller",
        .generation = gen,
        .outcome = outcome,
    };
}

// ---------------------------------------------------------------------------
// accepted_then_applied_receipt fixture
// ---------------------------------------------------------------------------

test "lazily/command_plane: observed/accepted are progress; applied receipt is terminal" {
    var p = CommandProjection.init(allocator);
    defer p.deinit();

    try std.testing.expectEqual(cp.CommandApplyStatus.recorded, try p.applyMessage(.{ .CommandSubmit = sampleSubmit("cmd-1", 42) }));

    // observed + accepted events do NOT make it terminal.
    _ = try p.applyMessage(.{ .CommandEvents = .{ .events = &.{
        .{ .event_id = "ev-o", .command_id = "cmd-1", .kind = .observed, .generation = 42, .detail = null },
        .{ .event_id = "ev-a", .command_id = "cmd-1", .kind = .accepted, .generation = 42, .detail = "queued" },
    } } });
    const e1 = p.entry("cmd-1").?;
    try std.testing.expectEqual(cp.CommandStatus.accepted, e1.status);
    try std.testing.expect(!e1.terminal);

    // An applied receipt flips it to terminal.
    try std.testing.expectEqual(cp.CommandApplyStatus.recorded, try p.observeReceipt(receipt("cmd-1", "rcpt-1", 42, .applied)));
    const e2 = p.entry("cmd-1").?;
    try std.testing.expectEqual(cp.CommandStatus.applied, e2.status);
    try std.testing.expect(e2.terminal);
    try std.testing.expectEqualStrings("rcpt-1", e2.terminal_receipt_id.?);
}

// ---------------------------------------------------------------------------
// rpc_call_waits_for_terminal fixture
// ---------------------------------------------------------------------------

const SentFrame = struct {
    msg: cp.CommandMessage,
};

const TransportState = struct {
    alloc: std.mem.Allocator,
    sent: std.ArrayListUnmanaged(SentFrame) = .empty,

    fn send(ctx: *anyopaque, msg: cp.CommandMessage) void {
        const self: *TransportState = @ptrCast(@alignCast(ctx));
        self.sent.append(self.alloc, .{ .msg = msg }) catch {};
    }
};

test "lazily/command_plane: RPC call resolves only on terminal receipt" {
    var ts = TransportState{ .alloc = allocator };
    defer ts.sent.deinit(allocator);
    const transport = cp.CommandTransport{ .ctx = @ptrCast(&ts), .send_fn = TransportState.send };

    var client = CommandRpcClient.init(transport, allocator);
    defer client.deinit();

    _ = try client.submit(sampleSubmit("cmd-run-1", 42));

    // After submit + progress events, pollCall is still pending.
    try std.testing.expectEqual(client.pollCall("cmd-run-1").kind, .pending);

    // Submit goes out on the transport.
    try std.testing.expectEqual(@as(usize, 1), ts.sent.items.len);
    try std.testing.expect(ts.sent.items[0].msg == .CommandSubmit);

    _ = try client.ingestCommand(.{ .CommandEvents = .{ .events = &.{
        .{ .event_id = "ev-1", .command_id = "cmd-run-1", .kind = .observed, .generation = 42, .detail = null },
        .{ .event_id = "ev-2", .command_id = "cmd-run-1", .kind = .accepted, .generation = 42, .detail = "queued" },
        .{ .event_id = "ev-3", .command_id = "cmd-run-1", .kind = .started, .generation = 42, .detail = null },
    } } });
    try std.testing.expectEqual(client.pollCall("cmd-run-1").kind, .pending);

    // Only the terminal receipt resolves it.
    _ = try client.ingestReceipt(receipt("cmd-run-1", "rcpt-1", 42, .applied));
    const call = client.pollCall("cmd-run-1");
    try std.testing.expectEqual(.resolved, call.kind);
    try std.testing.expectEqual(cp.CommandStatus.applied, call.entry.?.status);
    try std.testing.expectEqualStrings("ev-3", call.entry.?.last_event_id.?);
}

// ---------------------------------------------------------------------------
// stale_generation_ignored fixture
// ---------------------------------------------------------------------------

test "lazily/command_plane: stale-generation events/receipts are ignored" {
    var p = CommandProjection.init(allocator);
    defer p.deinit();
    _ = try p.applyMessage(.{ .CommandSubmit = sampleSubmit("cmd-2", 7) });

    const stale_event = CommandEvent{ .event_id = "ev-s", .command_id = "cmd-2", .kind = .started, .generation = 6, .detail = null };
    const r = try p.event(stale_event);
    try std.testing.expect(r == .stale_generation);
    if (r == .stale_generation) {
        try std.testing.expectEqual(@as(u64, 7), r.stale_generation.expected);
        try std.testing.expectEqual(@as(u64, 6), r.stale_generation.actual);
    }

    // Status unchanged.
    try std.testing.expectEqual(cp.CommandStatus.submitted, p.entry("cmd-2").?.status);

    // Stale receipt is also ignored, command stays non-terminal.
    const rr = try p.observeReceipt(receipt("cmd-2", "rcpt-s", 6, .applied));
    try std.testing.expect(rr == .stale_generation);
    try std.testing.expect(!p.entry("cmd-2").?.terminal);
}

// ---------------------------------------------------------------------------
// cancel_preempts_nonterminal fixture
// ---------------------------------------------------------------------------

test "lazily/command_plane: cancel before terminal only; cancel after applied ignored" {
    var p = CommandProjection.init(allocator);
    defer p.deinit();
    _ = try p.applyMessage(.{ .CommandSubmit = sampleSubmit("cmd-3", 1) });

    // A cancel is recorded (non-terminal) against a running command.
    _ = try p.applyMessage(.{ .CommandEvents = .{ .events = &.{
        .{ .event_id = "ev-s", .command_id = "cmd-3", .kind = .started, .generation = 1, .detail = null },
    } } });
    try std.testing.expectEqual(cp.CommandApplyStatus.recorded, try p.applyMessage(.{ .CommandCancel = .{
        .command_id = "cmd-3",
        .causation_id = "cancel-1",
        .source = "vscode-plugin",
        .authority_generation = 1,
        .reason = "user aborted",
    } }));
    try std.testing.expect(!p.entry("cmd-3").?.terminal);

    // A duplicate cancel causation_id is a no-op.
    try std.testing.expectEqual(cp.CommandApplyStatus.duplicate, try p.applyMessage(.{ .CommandCancel = .{
        .command_id = "cmd-3",
        .causation_id = "cancel-1",
        .source = "vscode-plugin",
        .authority_generation = 1,
        .reason = null,
    } }));

    // An applied receipt wins: the command is terminal/applied. A later cancel
    // receipt (rejected/cancelled) at the same generation conflicts fail-closed.
    _ = try p.observeReceipt(receipt("cmd-3", "rcpt-applied", 1, .applied));
    try std.testing.expect(p.entry("cmd-3").?.terminal);
    const conflict = try p.observeReceipt(.{
        .receipt_id = "rcpt-cancel",
        .causation_id = "cmd-3",
        .observer = "project-controller",
        .generation = 1,
        .outcome = .rejected,
        .reason = "cancelled",
    });
    try std.testing.expect(conflict == .terminal_conflict);
    try std.testing.expect(p.hasConflict("cmd-3"));
}

// ---------------------------------------------------------------------------
// terminal_conflict_fail_closed fixture
// ---------------------------------------------------------------------------

test "lazily/command_plane: distinct terminal outcomes fail closed" {
    var p = CommandProjection.init(allocator);
    defer p.deinit();
    _ = try p.applyMessage(.{ .CommandSubmit = sampleSubmit("cmd-4", 3) });

    _ = try p.observeReceipt(receipt("cmd-4", "rcpt-a", 3, .applied));
    const conflict = try p.observeReceipt(receipt("cmd-4", "rcpt-b", 3, .rejected));
    try std.testing.expect(conflict == .terminal_conflict);
    if (conflict == .terminal_conflict) {
        try std.testing.expectEqual(cp.CommandStatus.applied, conflict.terminal_conflict.existing);
        try std.testing.expectEqual(cp.CommandStatus.rejected, conflict.terminal_conflict.incoming);
    }
    // First terminal wins; the conflicting receipt was not recorded.
    try std.testing.expectEqualStrings("rcpt-a", p.terminalFor("cmd-4").?.terminal_receipt_id.?);
}

// ---------------------------------------------------------------------------
// reconnect_command_projection fixture (reconnect equivalence)
// ---------------------------------------------------------------------------

test "lazily/command_plane: folding a projection image equals folding its frames" {
    // Build a live projection by folding frames.
    var live = CommandProjection.init(allocator);
    defer live.deinit();
    _ = try live.applyMessage(.{ .CommandSubmit = sampleSubmit("cmd-5", 9) });
    _ = try live.applyMessage(.{ .CommandEvents = .{ .events = &.{
        .{ .event_id = "ev-5", .command_id = "cmd-5", .kind = .started, .generation = 9, .detail = null },
    } } });
    _ = try live.observeReceipt(receipt("cmd-5", "rcpt-5", 9, .applied));

    // Snapshot to an image.
    const img = try live.toImage();
    defer live.freeImage(img);
    try std.testing.expectEqual(@as(u64, 9), img.generation);
    try std.testing.expectEqual(@as(usize, 1), img.commands.len);
    try std.testing.expectEqual(cp.CommandStatus.applied, img.commands[0].status);

    // Fold the image into a fresh projection — reconnect resync.
    var resync = CommandProjection.init(allocator);
    defer resync.deinit();
    _ = try resync.applyMessage(.{ .CommandProjection = img });
    try std.testing.expectEqual(cp.CommandStatus.applied, resync.entry("cmd-5").?.status);
    try std.testing.expect(resync.entry("cmd-5").?.terminal);
    try std.testing.expectEqualStrings("rcpt-5", resync.entry("cmd-5").?.terminal_receipt_id.?);

    // Idempotency: replaying the original receipt must be a no-op (its id was
    // folded in via the image).
    try std.testing.expectEqual(cp.CommandApplyStatus.duplicate, try resync.observeReceipt(receipt("cmd-5", "rcpt-5", 9, .applied)));
}

// ---------------------------------------------------------------------------
// duplicate submit is idempotent
// ---------------------------------------------------------------------------

test "lazily/command_plane: duplicate command_id submit is a no-op" {
    var p = CommandProjection.init(allocator);
    defer p.deinit();
    try std.testing.expectEqual(cp.CommandApplyStatus.recorded, try p.applyMessage(.{ .CommandSubmit = sampleSubmit("dup", 1) }));
    try std.testing.expectEqual(cp.CommandApplyStatus.duplicate, try p.applyMessage(.{ .CommandSubmit = sampleSubmit("dup", 1) }));
    try std.testing.expectEqual(@as(usize, 1), p.entries.count());
}

// ---------------------------------------------------------------------------
// Wire round-trip (message-passing.json conformance)
// ---------------------------------------------------------------------------

test "lazily/command_plane: CommandMessage wire round-trip is byte-stable" {
    const frames = [_]cp.CommandMessage{
        .{ .CommandSubmit = sampleSubmit("cmd-w", 5) },
        .{ .CommandCancel = .{
            .command_id = "cmd-w",
            .causation_id = "cancel-w",
            .source = "vscode-plugin",
            .authority_generation = 5,
            .reason = "aborted",
        } },
        .{ .CommandEvents = .{ .events = &.{
            .{ .event_id = "ev-w", .command_id = "cmd-w", .kind = .progress, .generation = 5, .detail = "halfway" },
        } } },
        .{ .CommandProjection = .{
            .generation = 5,
            .commands = &.{
                .{
                    .command_id = "cmd-w",
                    .status = .running,
                    .terminal = false,
                    .generation = 5,
                    .reason = null,
                    .terminal_receipt_id = null,
                    .last_event_id = "ev-w",
                },
            },
        } },
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    for (frames) |msg| {
        const encoded1 = try cp.commandMessageToJson(allocator, msg);
        defer allocator.free(encoded1);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded1, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        const decoded = try cp.commandMessageFromJson(a, parsed.value);

        const encoded2 = try cp.commandMessageToJson(allocator, decoded);
        defer allocator.free(encoded2);

        try std.testing.expectEqualSlices(u8, encoded1, encoded2);
    }
}

test "lazily/command_plane: enums round-trip wire names" {
    const dcs = [_]cp.DedupePolicy{ .none, .same_idempotency_key, .same_command_id };
    for (dcs) |d| {
        try std.testing.expectEqual(d, try cp.DedupePolicy.fromWireName(d.wireName()));
    }
    const kinds = [_]cp.CommandEventKind{ .observed, .accepted, .started, .progress, .cancelled, .superseded, .timed_out };
    for (kinds) |k| {
        try std.testing.expectEqual(k, try cp.CommandEventKind.fromWireName(k.wireName()));
    }
    const statuses = [_]cp.CommandStatus{ .submitted, .accepted, .running, .applied, .rejected, .cancelled, .superseded, .timed_out };
    for (statuses) |s| {
        try std.testing.expectEqual(s, try cp.CommandStatus.fromWireName(s.wireName()));
        try std.testing.expectEqual(s.isTerminal(), switch (s) {
            .applied, .rejected, .cancelled, .superseded, .timed_out => true,
            else => false,
        });
    }
}
