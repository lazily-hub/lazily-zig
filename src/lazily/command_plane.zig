const std = @import("std");
const receipt_mod = @import("receipt.zig");
const ipc = @import("ipc.zig");
const CausalReceipt = receipt_mod.CausalReceipt;
const ReceiptOutcome = receipt_mod.ReceiptOutcome;
const IpcValue = ipc.IpcValue;

// Command / RPC message plane (command-plane-v1).
//
// Editor and runtime integrations issue commands — Run Agent Doc, sync, focus,
// save, session operations — and need one reusable admission, dedupe,
// cancellation, generation-guard, progress, and reconnect story instead of a
// per-caller ad hoc request/response contract. This is that plane: an evented
// command message family that is an **additive sibling** to Snapshot / Delta /
// CrdtSync; it does not add new state-plane variants.
//
// The plane is feature-gated. Peers advertise `command-plane-v1` in the
// Capability Negotiation `features` array. A peer that lacks `command-plane-v1`
// fails closed before accepting command traffic; a command that requires the
// plane is not silently downgraded.
//
// Four externally-tagged frames make up the family:
//   - CommandSubmit    — admit a command (envelope + domain payload).
//   - CommandCancel    — preempt a still-non-terminal command.
//   - CommandEvents    — batch progress/detail events (UX/diagnostics only).
//   - CommandProjection — the folded, queryable image; also the reconnect
//     resync frame.
//
// Terminal authority is the causal receipt, not the event or the transport: a
// command becomes terminal only when a terminal CausalReceipt for its
// command_id folds in. A network ACK, controller admission, or accepted/queued
// event never resolves a unary call.
//
// Zig port of lazily-go `command_plane.go` and lazily-js
// `src/index.js` (CommandProjection / CommandRpcClient), conformant with
// lazily-spec `schemas/message-passing.json` and the shared
// `conformance/message-passing/` fixtures.
//
// Wire conventions (NORMATIVE, from message-passing.json):
//   - snake_case field names throughout.
//   - CommandMessage is externally tagged: `{"CommandSubmit": {...}}` etc.
//   - CommandProjectionEntry always emits all seven fields; nullable ones
//     (reason, terminal_receipt_id, last_event_id) emit JSON null.

// ---------------------------------------------------------------------------
// DedupePolicy / CommandPolicy
// ---------------------------------------------------------------------------

/// How the admitter collapses concurrent/duplicate submits.
pub const DedupePolicy = enum {
    none,
    same_idempotency_key,
    same_command_id,

    pub fn wireName(self: DedupePolicy) []const u8 {
        return switch (self) {
            .none => "none",
            .same_idempotency_key => "same_idempotency_key",
            .same_command_id => "same_command_id",
        };
    }

    pub fn fromWireName(name: []const u8) error{UnknownDedupePolicy}!DedupePolicy {
        if (std.mem.eql(u8, name, "none")) return .none;
        if (std.mem.eql(u8, name, "same_idempotency_key")) return .same_idempotency_key;
        if (std.mem.eql(u8, name, "same_command_id")) return .same_command_id;
        return error.UnknownDedupePolicy;
    }
};

/// Per-submit admission policy.
pub const CommandPolicy = struct {
    dedupe: DedupePolicy,
    supersede: bool,
    cancel_on_preempt: bool,
};

// ---------------------------------------------------------------------------
// CommandSubmit
// ---------------------------------------------------------------------------

/// Admits a command. Lazily owns the envelope (command_id, correlation,
/// idempotency, generation, policy, payload framing); the namespace owns the
/// payload body, which lazily never interprets. Wire fields borrow caller-owned
/// slices in the message struct; the projection dups what it keeps.
pub const CommandSubmit = struct {
    command_id: []const u8,
    causation_id: []const u8,
    source: []const u8,
    target: []const u8,
    namespace: []const u8,
    name: []const u8,
    authority_generation: u64,
    idempotency_key: []const u8,
    deadline_ms: u64,
    policy: CommandPolicy,
    payload_type: []const u8,
    payload_hash: []const u8,
    payload: IpcValue,
    required_features: []const []const u8,
};

// ---------------------------------------------------------------------------
// CommandCancel
// ---------------------------------------------------------------------------

/// Preempts a still-non-terminal command by `command_id` at a given
/// `authority_generation`, with an optional reason. A stale-generation cancel
/// is ignored. A cancel after a terminal outcome never rewrites it.
pub const CommandCancel = struct {
    command_id: []const u8,
    causation_id: []const u8,
    source: []const u8,
    authority_generation: u64,
    reason: ?[]const u8,
};

// ---------------------------------------------------------------------------
// CommandEvent / CommandEvents
// ---------------------------------------------------------------------------

/// Progress/detail event kind. These are UX/diagnostics only and are NEVER
/// terminal proof; terminal proof folds through CausalReceipt.
/// cancelled/superseded/timed_out are surfaced here for UX but their terminal
/// authority is a matching rejected receipt.
pub const CommandEventKind = enum {
    observed,
    accepted,
    started,
    progress,
    cancelled,
    superseded,
    timed_out,

    pub fn wireName(self: CommandEventKind) []const u8 {
        return @tagName(self);
    }

    pub fn fromWireName(name: []const u8) error{UnknownCommandEventKind}!CommandEventKind {
        return std.meta.stringToEnum(CommandEventKind, name) orelse error.UnknownCommandEventKind;
    }
};

/// One progress/detail event keyed by `command_id`.
pub const CommandEvent = struct {
    event_id: []const u8,
    command_id: []const u8,
    kind: CommandEventKind,
    generation: u64,
    detail: ?[]const u8,
};

/// A batch of progress/detail events.
pub const CommandEvents = struct {
    events: []const CommandEvent,
};

// ---------------------------------------------------------------------------
// CommandStatus / CommandProjectionEntry / CommandProjectionImage
// ---------------------------------------------------------------------------

/// Folded projection status. submitted/accepted/running are non-terminal;
/// applied/rejected/cancelled/superseded/timed_out are terminal and backed by a
/// terminal CausalReceipt.
pub const CommandStatus = enum {
    submitted,
    accepted,
    running,
    applied,
    rejected,
    cancelled,
    superseded,
    timed_out,

    pub fn wireName(self: CommandStatus) []const u8 {
        return @tagName(self);
    }

    pub fn fromWireName(name: []const u8) error{UnknownCommandStatus}!CommandStatus {
        return std.meta.stringToEnum(CommandStatus, name) orelse error.UnknownCommandStatus;
    }

    pub fn isTerminal(self: CommandStatus) bool {
        return switch (self) {
            .applied, .rejected, .cancelled, .superseded, .timed_out => true,
            else => false,
        };
    }
};

/// Monotonic forward-progress rank for non-terminal status. An event updates
/// status only when the next rank is >= the current.
fn phaseRank(status: CommandStatus) u8 {
    return switch (status) {
        .submitted => 0,
        .accepted => 1,
        .running => 2,
        else => 3,
    };
}

/// Maps an event kind to the non-terminal status it advances to, or `null`
/// when the event carries no status change (cancelled/superseded/timed_out are
/// event-only signals; the receipt carries terminal authority).
fn progressStatusOf(kind: CommandEventKind) ?CommandStatus {
    return switch (kind) {
        .observed, .accepted => .accepted,
        .started, .progress => .running,
        else => null,
    };
}

/// Maps a terminal receipt outcome (+ reason) to the folded command status. A
/// rejected receipt whose reason is "cancelled"/"superseded"/"timed_out" folds
/// to the matching terminal status.
fn terminalStatusOf(outcome: ReceiptOutcome, reason: ?[]const u8) CommandStatus {
    if (outcome == .applied) return .applied;
    if (outcome == .rejected) {
        if (reason) |r| {
            if (std.mem.eql(u8, r, "cancelled")) return .cancelled;
            if (std.mem.eql(u8, r, "superseded")) return .superseded;
            if (std.mem.eql(u8, r, "timed_out")) return .timed_out;
        }
        return .rejected;
    }
    return .accepted;
}

/// The folded, queryable image of one command's state. `reason`,
/// `terminal_receipt_id`, and `last_event_id` are nullable wire fields
/// (emitted as JSON null when absent). The projection owns all slices.
pub const CommandProjectionEntry = struct {
    command_id: []const u8,
    status: CommandStatus,
    terminal: bool,
    generation: u64,
    reason: ?[]const u8 = null,
    terminal_receipt_id: ?[]const u8 = null,
    last_event_id: ?[]const u8 = null,
};

/// The resync snapshot: an authority generation plus the per-command folded
/// entries.
pub const CommandProjectionImage = struct {
    generation: u64,
    commands: []const CommandProjectionEntry,
};

// ---------------------------------------------------------------------------
// CommandMessage (externally-tagged frame)
// ---------------------------------------------------------------------------

pub const CommandMessageTag = enum {
    CommandSubmit,
    CommandCancel,
    CommandEvents,
    CommandProjection,

    pub fn wireName(self: CommandMessageTag) []const u8 {
        return @tagName(self);
    }
};

/// One externally-tagged frame of the command plane.
pub const CommandMessage = union(CommandMessageTag) {
    CommandSubmit: CommandSubmit,
    CommandCancel: CommandCancel,
    CommandEvents: CommandEvents,
    CommandProjection: CommandProjectionImage,

    pub fn submit(s: CommandSubmit) CommandMessage {
        return .{ .CommandSubmit = s };
    }

    pub fn cancel(c: CommandCancel) CommandMessage {
        return .{ .CommandCancel = c };
    }

    pub fn events(e: CommandEvents) CommandMessage {
        return .{ .CommandEvents = e };
    }

    pub fn projection(p: CommandProjectionImage) CommandMessage {
        return .{ .CommandProjection = p };
    }

    /// Externally-tagged wire form `{"<Tag>": {...}}`.
    pub fn jsonStringify(self: CommandMessage, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .CommandSubmit => |s| {
                try jw.objectField("CommandSubmit");
                try writeSubmit(jw, s);
            },
            .CommandCancel => |c| {
                try jw.objectField("CommandCancel");
                try writeCancel(jw, c);
            },
            .CommandEvents => |ev| {
                try jw.objectField("CommandEvents");
                try writeEvents(jw, ev);
            },
            .CommandProjection => |img| {
                try jw.objectField("CommandProjection");
                try writeImage(jw, img);
            },
        }
        try jw.endObject();
    }
};

// ---------------------------------------------------------------------------
// CommandApplyStatus (sealed result hierarchy)
// ---------------------------------------------------------------------------

/// The result of folding a frame into a `CommandProjection`.
pub const CommandApplyStatus = union(enum) {
    /// The frame updated the projection.
    recorded,
    /// The frame was an idempotent no-op (duplicate command_id / event_id /
    /// receipt_id / cancel causation_id).
    duplicate,
    /// The command_id was not in the projection.
    unknown,
    /// The frame's generation did not match the command's current authority
    /// generation; the frame was ignored.
    stale_generation: struct {
        expected: u64,
        actual: u64,
    },
    /// A different terminal outcome already exists for this command_id
    /// (fail-closed).
    terminal_conflict: struct {
        command_id: []const u8,
        existing: CommandStatus,
        incoming: CommandStatus,
    },
};

// ---------------------------------------------------------------------------
// CommandProjection (the reducer)
// ---------------------------------------------------------------------------

/// The folded, queryable image of known command state. It is the reducer over
/// `CommandMessage` frames and `CausalReceipt` events.
///
/// Projection rules (lazily-spec § Command / RPC Message Plane):
///   - Terminal authority is the causal receipt, not the event or transport.
///   - Generation guards: events/receipts outside the command's current
///     authority generation are ignored.
///   - Idempotency: a replayed submit/event/receipt (same id) is a no-op.
///   - Cancel before terminal only: a cancel terminally rejects a non-terminal
///     command; a cancel after applied is ignored.
///   - Terminal conflict fails closed: two terminal receipts at the same
///     generation with different outcomes is a conflict.
///   - Reconnect equivalence: folding a CommandProjection image is equivalent
///     to folding the events and receipts it summarizes.
///
/// Memory: each entry owns its `command_id` (map key aliases it) and its
/// optional slices. The three "seen" sets own their keys. `deinit` walks each
/// container once and frees what it owns.
///
/// Not safe for concurrent use.
pub const CommandProjection = struct {
    allocator: std.mem.Allocator,
    generation: u64 = 0,
    entries: std.StringHashMapUnmanaged(CommandProjectionEntry) = .empty,
    seen_event_ids: std.StringHashMapUnmanaged(void) = .empty,
    seen_receipt_ids: std.StringHashMapUnmanaged(void) = .empty,
    seen_cancel_ids: std.StringHashMapUnmanaged(void) = .empty,
    conflicts: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: std.mem.Allocator) CommandProjection {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CommandProjection) void {
        var ei = self.entries.iterator();
        while (ei.next()) |kv| freeEntry(self.allocator, kv.value_ptr.*);
        self.entries.deinit(self.allocator);

        var sei = self.seen_event_ids.keyIterator();
        while (sei.next()) |k| self.allocator.free(k.*);
        self.seen_event_ids.deinit(self.allocator);

        var sri = self.seen_receipt_ids.keyIterator();
        while (sri.next()) |k| self.allocator.free(k.*);
        self.seen_receipt_ids.deinit(self.allocator);

        var sci = self.seen_cancel_ids.keyIterator();
        while (sci.next()) |k| self.allocator.free(k.*);
        self.seen_cancel_ids.deinit(self.allocator);

        var ci = self.conflicts.keyIterator();
        while (ci.next()) |k| self.allocator.free(k.*);
        self.conflicts.deinit(self.allocator);

        self.* = undefined;
    }

    /// Highest authority generation observed so far.
    pub fn currentGeneration(self: *const CommandProjection) u64 {
        return self.generation;
    }

    /// Dispatch a `CommandMessage` frame to the matching fold method.
    pub fn applyMessage(self: *CommandProjection, message: CommandMessage) !CommandApplyStatus {
        return switch (message) {
            .CommandSubmit => |s| try self.submit(s),
            .CommandCancel => |c| try self.cancel(c),
            .CommandEvents => |ev| blk: {
                var last: CommandApplyStatus = .unknown;
                for (ev.events) |e| last = try self.event(e);
                break :blk last;
            },
            .CommandProjection => |img| try self.applyProjection(img),
        };
    }

    /// Admit a command. A duplicate command_id is an idempotent no-op.
    pub fn submit(self: *CommandProjection, s: CommandSubmit) !CommandApplyStatus {
        if (self.entries.contains(s.command_id)) return .duplicate;
        if (s.authority_generation > self.generation) self.generation = s.authority_generation;
        const id_owned = try self.allocator.dupe(u8, s.command_id);
        try self.entries.put(self.allocator, id_owned, .{
            .command_id = id_owned,
            .status = .submitted,
            .terminal = false,
            .generation = s.authority_generation,
        });
        return .recorded;
    }

    /// Fold one progress/detail event. Stale-generation and duplicate event_ids
    /// are no-ops. Status advances monotonically (never backward, never on a
    /// terminal command).
    pub fn event(self: *CommandProjection, e: CommandEvent) !CommandApplyStatus {
        if (self.seen_event_ids.contains(e.event_id)) return .duplicate;
        const entry_ptr = self.entries.getPtr(e.command_id) orelse return .unknown;
        if (e.generation != entry_ptr.generation) {
            return .{ .stale_generation = .{ .expected = entry_ptr.generation, .actual = e.generation } };
        }
        const seen_key = try self.allocator.dupe(u8, e.event_id);
        try self.seen_event_ids.put(self.allocator, seen_key, {});
        // last_event_id: free prior, store owned.
        if (entry_ptr.last_event_id) |old| self.allocator.free(old);
        entry_ptr.last_event_id = try self.allocator.dupe(u8, e.event_id);
        if (progressStatusOf(e.kind)) |next| {
            if (!entry_ptr.terminal and phaseRank(next) >= phaseRank(entry_ptr.status)) {
                entry_ptr.status = next;
            }
        }
        return .recorded;
    }

    /// Record a cancel request. A cancel is non-terminal by itself; the
    /// rejected receipt makes it terminal. Stale-generation and duplicate cancel
    /// causation_ids are no-ops.
    pub fn cancel(self: *CommandProjection, c: CommandCancel) !CommandApplyStatus {
        if (self.seen_cancel_ids.contains(c.causation_id)) return .duplicate;
        const entry_ptr = self.entries.getPtr(c.command_id) orelse return .unknown;
        if (c.authority_generation != entry_ptr.generation) {
            return .{ .stale_generation = .{ .expected = entry_ptr.generation, .actual = c.authority_generation } };
        }
        const seen_key = try self.allocator.dupe(u8, c.causation_id);
        try self.seen_cancel_ids.put(self.allocator, seen_key, {});
        return .recorded;
    }

    /// Fold a causal receipt. This is the sole terminal authority: a terminal
    /// receipt (applied/rejected) flips the command to terminal. A differing
    /// terminal outcome at the same generation is a conflict (fail-closed).
    pub fn observeReceipt(self: *CommandProjection, r: CausalReceipt) !CommandApplyStatus {
        if (self.seen_receipt_ids.contains(r.receipt_id)) return .duplicate;
        const entry_ptr = self.entries.getPtr(r.causation_id) orelse return .unknown;
        if (r.generation != entry_ptr.generation) {
            return .{ .stale_generation = .{ .expected = entry_ptr.generation, .actual = r.generation } };
        }
        if (!r.outcome.isTerminal()) {
            const seen_key = try self.allocator.dupe(u8, r.receipt_id);
            try self.seen_receipt_ids.put(self.allocator, seen_key, {});
            if (!entry_ptr.terminal and phaseRank(.accepted) >= phaseRank(entry_ptr.status)) {
                entry_ptr.status = .accepted;
            }
            return .recorded;
        }
        const incoming = terminalStatusOf(r.outcome, r.reason);
        if (entry_ptr.terminal) {
            if (entry_ptr.status == incoming) {
                const seen_key = try self.allocator.dupe(u8, r.receipt_id);
                try self.seen_receipt_ids.put(self.allocator, seen_key, {});
                return .recorded;
            }
            const conflict_key = try self.allocator.dupe(u8, r.causation_id);
            try self.conflicts.put(self.allocator, conflict_key, {});
            return .{ .terminal_conflict = .{
                .command_id = r.causation_id,
                .existing = entry_ptr.status,
                .incoming = incoming,
            } };
        }
        const seen_key = try self.allocator.dupe(u8, r.receipt_id);
        try self.seen_receipt_ids.put(self.allocator, seen_key, {});
        entry_ptr.terminal = true;
        entry_ptr.status = incoming;
        if (r.reason) |reason| {
            if (entry_ptr.reason) |old| self.allocator.free(old);
            entry_ptr.reason = try self.allocator.dupe(u8, reason);
        }
        if (entry_ptr.terminal_receipt_id) |old| self.allocator.free(old);
        entry_ptr.terminal_receipt_id = try self.allocator.dupe(u8, r.receipt_id);
        return .recorded;
    }

    /// Fold a reconnect resync image. Equivalent to folding the events and
    /// receipts it summarizes.
    pub fn applyProjection(self: *CommandProjection, img: CommandProjectionImage) !CommandApplyStatus {
        if (img.generation > self.generation) self.generation = img.generation;
        for (img.commands) |c| {
            if (self.entries.fetchRemove(c.command_id)) |kv| freeEntry(self.allocator, kv.value);
            const stored = try dupEntry(self.allocator, c);
            try self.entries.put(self.allocator, stored.command_id, stored);
            if (stored.last_event_id) |id| {
                const k = try self.allocator.dupe(u8, id);
                try self.seen_event_ids.put(self.allocator, k, {});
            }
            if (stored.terminal_receipt_id) |id| {
                const k = try self.allocator.dupe(u8, id);
                try self.seen_receipt_ids.put(self.allocator, k, {});
            }
        }
        return .recorded;
    }

    /// The folded entry for `command_id`, or null if unknown.
    pub fn entry(self: *const CommandProjection, command_id: []const u8) ?CommandProjectionEntry {
        return self.entries.get(command_id);
    }

    /// The terminal entry for `command_id`, or null if unknown/not yet terminal.
    pub fn terminalFor(self: *const CommandProjection, command_id: []const u8) ?CommandProjectionEntry {
        if (self.entries.get(command_id)) |e| {
            if (e.terminal) return e;
        }
        return null;
    }

    /// Whether `command_id` has a terminal conflict.
    pub fn hasConflict(self: *const CommandProjection, command_id: []const u8) bool {
        return self.conflicts.contains(command_id);
    }

    /// A snapshot of the projection sorted by command_id. Caller owns the
    /// returned `commands` slice; the entries themselves are NOT independent
    /// copies (they borrow the projection's storage) — use only while the
    /// projection is alive, or pass through `dupEntry`.
    pub fn toImage(self: *const CommandProjection) !CommandProjectionImage {
        const list = try self.allocator.alloc(CommandProjectionEntry, self.entries.count());
        var it = self.entries.valueIterator();
        var i: usize = 0;
        while (it.next()) |e| : (i += 1) list[i] = e.*;
        std.mem.sort(CommandProjectionEntry, list, {}, struct {
            fn lt(_: void, a: CommandProjectionEntry, b: CommandProjectionEntry) bool {
                return std.mem.lessThan(u8, a.command_id, b.command_id);
            }
        }.lt);
        return .{ .generation = self.generation, .commands = list };
    }

    pub fn freeImage(self: *const CommandProjection, img: CommandProjectionImage) void {
        self.allocator.free(img.commands);
    }
};

fn freeEntry(allocator: std.mem.Allocator, e: CommandProjectionEntry) void {
    allocator.free(e.command_id);
    if (e.reason) |s| allocator.free(s);
    if (e.terminal_receipt_id) |s| allocator.free(s);
    if (e.last_event_id) |s| allocator.free(s);
}

fn dupEntry(allocator: std.mem.Allocator, e: CommandProjectionEntry) !CommandProjectionEntry {
    return .{
        .command_id = try allocator.dupe(u8, e.command_id),
        .status = e.status,
        .terminal = e.terminal,
        .generation = e.generation,
        .reason = if (e.reason) |s| try allocator.dupe(u8, s) else null,
        .terminal_receipt_id = if (e.terminal_receipt_id) |s| try allocator.dupe(u8, s) else null,
        .last_event_id = if (e.last_event_id) |s| try allocator.dupe(u8, s) else null,
    };
}

// ---------------------------------------------------------------------------
// RPC facade (CommandRpcClient)
// ---------------------------------------------------------------------------

/// Outbound sink for command frames. A vtable over a context pointer so any
/// transport (channel, IPC, loopback for tests) can drive the RPC client.
pub const CommandTransport = struct {
    ctx: *anyopaque,
    send_fn: *const fn (ctx: *anyopaque, message: CommandMessage) void,

    pub fn send(self: CommandTransport, message: CommandMessage) void {
        self.send_fn(self.ctx, message);
    }
};

pub const CallStateKind = enum { pending, resolved, conflict };

/// The unary-RPC resolution state. A call resolves only when the command
/// projection reaches a terminal causal receipt.
pub const CallState = struct {
    kind: CallStateKind,
    entry: ?CommandProjectionEntry = null,
};

/// RPC facade over the command plane. Builds and sends `CommandSubmit` /
/// `CommandCancel` frames, folds replies into its projection, and exposes a
/// polled unary-call resolution that completes only on a terminal causal
/// receipt.
pub const CommandRpcClient = struct {
    transport: CommandTransport,
    projection: CommandProjection,

    /// Construct over a transport; the projection uses `allocator` for its
    /// owned strings (the transport context need not be an allocator).
    pub fn init(transport: CommandTransport, allocator: std.mem.Allocator) CommandRpcClient {
        return .{ .transport = transport, .projection = CommandProjection.init(allocator) };
    }

    pub fn deinit(self: *CommandRpcClient) void {
        self.projection.deinit();
    }

    /// Build and send a `CommandSubmit`, fold it into the projection, and
    /// return the command id.
    pub fn submit(self: *CommandRpcClient, s: CommandSubmit) ![]const u8 {
        const msg = CommandMessage.submit(s);
        self.transport.send(msg);
        _ = try self.projection.applyMessage(msg);
        return s.command_id;
    }

    /// Build and send a `CommandCancel` and fold it into the projection.
    pub fn cancel(self: *CommandRpcClient, c: CommandCancel) !void {
        const msg = CommandMessage.cancel(c);
        self.transport.send(msg);
        _ = try self.projection.applyMessage(msg);
    }

    /// Fold an inbound `CommandMessage` into the projection.
    pub fn ingestCommand(self: *CommandRpcClient, message: CommandMessage) !CommandApplyStatus {
        return try self.projection.applyMessage(message);
    }

    /// Fold an inbound causal receipt into the projection.
    pub fn ingestReceipt(self: *CommandRpcClient, r: CausalReceipt) !CommandApplyStatus {
        return try self.projection.observeReceipt(r);
    }

    /// Current resolution state of a unary call. Resolves only when the command
    /// projection reaches a terminal causal receipt — a transport ACK,
    /// controller admission, or accepted/queued event never resolves it.
    pub fn pollCall(self: *const CommandRpcClient, command_id: []const u8) CallState {
        if (self.projection.hasConflict(command_id)) return .{ .kind = .conflict };
        if (self.projection.terminalFor(command_id)) |e| return .{ .kind = .resolved, .entry = e };
        return .{ .kind = .pending };
    }
};

// ---------------------------------------------------------------------------
// Wire JSON (message-passing.json). Normative form: externally-tagged frames,
// snake_case fields, nullable fields emitted as JSON null.
// ---------------------------------------------------------------------------

const TaggedValue = struct {
    name: []const u8,
    value: std.json.Value,
};

fn singleTagged(value: std.json.Value) !TaggedValue {
    switch (value) {
        .object => |object| {
            if (object.count() != 1) return error.ExpectedSingleFieldObject;
            var it = object.iterator();
            const entry = it.next() orelse return error.ExpectedSingleFieldObject;
            return .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* };
        },
        else => return error.ExpectedObject,
    }
}

fn jfield(value: std.json.Value, name: []const u8) !std.json.Value {
    return switch (value) {
        .object => |o| o.get(name) orelse error.MissingField,
        else => error.ExpectedObject,
    };
}

fn jstr(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}

fn ju64(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |n| if (n >= 0) @as(u64, @intCast(n)) else error.ExpectedUnsignedInteger,
        .number_string => |s| try std.fmt.parseInt(u64, s, 10),
        else => error.ExpectedUnsignedInteger,
    };
}

fn joptStr(allocator: std.mem.Allocator, value: std.json.Value) !?[]const u8 {
    switch (value) {
        .null => return null,
        .string => |s| return try allocator.dupe(u8, s),
        else => return error.ExpectedStringOrNull,
    }
}

fn jarray(value: std.json.Value) ![]const std.json.Value {
    return switch (value) {
        .array => |a| a.items,
        else => return error.ExpectedArray,
    };
}

fn parsePolicy(value: std.json.Value) !CommandPolicy {
    return .{
        .dedupe = try DedupePolicy.fromWireName(try jstr(try jfield(value, "dedupe"))),
        .supersede = jbool(try jfield(value, "supersede")),
        .cancel_on_preempt = jbool(try jfield(value, "cancel_on_preempt")),
    };
}

fn jbool(value: std.json.Value) bool {
    return switch (value) {
        .bool => |b| b,
        else => false,
    };
}

fn parseSubmit(allocator: std.mem.Allocator, value: std.json.Value) !CommandSubmit {
    const payload_value = try jfield(value, "payload");
    const features_arr = try jarray(try jfield(value, "required_features"));
    const features = try allocator.alloc([]const u8, features_arr.len);
    for (features_arr, features) |fv, *out| out.* = try allocator.dupe(u8, try jstr(fv));
    return .{
        .command_id = try allocator.dupe(u8, try jstr(try jfield(value, "command_id"))),
        .causation_id = try allocator.dupe(u8, try jstr(try jfield(value, "causation_id"))),
        .source = try allocator.dupe(u8, try jstr(try jfield(value, "source"))),
        .target = try allocator.dupe(u8, try jstr(try jfield(value, "target"))),
        .namespace = try allocator.dupe(u8, try jstr(try jfield(value, "namespace"))),
        .name = try allocator.dupe(u8, try jstr(try jfield(value, "name"))),
        .authority_generation = try ju64(try jfield(value, "authority_generation")),
        .idempotency_key = try allocator.dupe(u8, try jstr(try jfield(value, "idempotency_key"))),
        .deadline_ms = try ju64(try jfield(value, "deadline_ms")),
        .policy = try parsePolicy(try jfield(value, "policy")),
        .payload_type = try allocator.dupe(u8, try jstr(try jfield(value, "payload_type"))),
        .payload_hash = try allocator.dupe(u8, try jstr(try jfield(value, "payload_hash"))),
        .payload = try IpcValue.fromJson(allocator, payload_value),
        .required_features = features,
    };
}

fn parseCancel(allocator: std.mem.Allocator, value: std.json.Value) !CommandCancel {
    return .{
        .command_id = try allocator.dupe(u8, try jstr(try jfield(value, "command_id"))),
        .causation_id = try allocator.dupe(u8, try jstr(try jfield(value, "causation_id"))),
        .source = try allocator.dupe(u8, try jstr(try jfield(value, "source"))),
        .authority_generation = try ju64(try jfield(value, "authority_generation")),
        .reason = try joptStr(allocator, try jfield(value, "reason")),
    };
}

fn parseEvent(allocator: std.mem.Allocator, value: std.json.Value) !CommandEvent {
    return .{
        .event_id = try allocator.dupe(u8, try jstr(try jfield(value, "event_id"))),
        .command_id = try allocator.dupe(u8, try jstr(try jfield(value, "command_id"))),
        .kind = try CommandEventKind.fromWireName(try jstr(try jfield(value, "kind"))),
        .generation = try ju64(try jfield(value, "generation")),
        .detail = try joptStr(allocator, try jfield(value, "detail")),
    };
}

fn parseEvents(allocator: std.mem.Allocator, value: std.json.Value) !CommandEvents {
    const arr = try jarray(try jfield(value, "events"));
    const out = try allocator.alloc(CommandEvent, arr.len);
    for (arr, out) |ev, *o| o.* = try parseEvent(allocator, ev);
    return .{ .events = out };
}

fn parseEntry(allocator: std.mem.Allocator, value: std.json.Value) !CommandProjectionEntry {
    return .{
        .command_id = try allocator.dupe(u8, try jstr(try jfield(value, "command_id"))),
        .status = try CommandStatus.fromWireName(try jstr(try jfield(value, "status"))),
        .terminal = jbool(try jfield(value, "terminal")),
        .generation = try ju64(try jfield(value, "generation")),
        .reason = try joptStr(allocator, try jfield(value, "reason")),
        .terminal_receipt_id = try joptStr(allocator, try jfield(value, "terminal_receipt_id")),
        .last_event_id = try joptStr(allocator, try jfield(value, "last_event_id")),
    };
}

fn parseImage(allocator: std.mem.Allocator, value: std.json.Value) !CommandProjectionImage {
    const arr = try jarray(try jfield(value, "commands"));
    const out = try allocator.alloc(CommandProjectionEntry, arr.len);
    for (arr, out) |ev, *o| o.* = try parseEntry(allocator, ev);
    return .{
        .generation = try ju64(try jfield(value, "generation")),
        .commands = out,
    };
}

/// Decode a `CommandMessage` from its externally-tagged canonical JSON. All
/// slices are owned by `allocator`.
pub fn commandMessageFromJson(allocator: std.mem.Allocator, value: std.json.Value) !CommandMessage {
    const tagged = try singleTagged(value);
    if (std.mem.eql(u8, tagged.name, "CommandSubmit")) return .{ .CommandSubmit = try parseSubmit(allocator, tagged.value) };
    if (std.mem.eql(u8, tagged.name, "CommandCancel")) return .{ .CommandCancel = try parseCancel(allocator, tagged.value) };
    if (std.mem.eql(u8, tagged.name, "CommandEvents")) return .{ .CommandEvents = try parseEvents(allocator, tagged.value) };
    if (std.mem.eql(u8, tagged.name, "CommandProjection")) return .{ .CommandProjection = try parseImage(allocator, tagged.value) };
    return error.UnknownCommandMessage;
}

fn writeOptStr(jw: anytype, s: ?[]const u8) !void {
    if (s) |v| {
        try jw.write(v);
    } else {
        try jw.write(null);
    }
}

fn writePolicy(jw: anytype, p: CommandPolicy) !void {
    try jw.beginObject();
    try jw.objectField("dedupe");
    try jw.write(p.dedupe.wireName());
    try jw.objectField("supersede");
    try jw.write(p.supersede);
    try jw.objectField("cancel_on_preempt");
    try jw.write(p.cancel_on_preempt);
    try jw.endObject();
}

fn writeEntry(jw: anytype, e: CommandProjectionEntry) !void {
    try jw.beginObject();
    try jw.objectField("command_id");
    try jw.write(e.command_id);
    try jw.objectField("status");
    try jw.write(e.status.wireName());
    try jw.objectField("terminal");
    try jw.write(e.terminal);
    try jw.objectField("generation");
    try jw.write(e.generation);
    try jw.objectField("reason");
    try writeOptStr(jw, e.reason);
    try jw.objectField("terminal_receipt_id");
    try writeOptStr(jw, e.terminal_receipt_id);
    try jw.objectField("last_event_id");
    try writeOptStr(jw, e.last_event_id);
    try jw.endObject();
}

/// Encode a `CommandMessage` to its canonical JSON (owned by `allocator`).
pub fn commandMessageToJson(allocator: std.mem.Allocator, message: CommandMessage) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, message, .{});
}

// jsonStringify implementations drive the externally-tagged wire form.

fn writeSubmit(jw: anytype, self: CommandSubmit) !void {
    try jw.beginObject();
    try jw.objectField("command_id");
    try jw.write(self.command_id);
    try jw.objectField("causation_id");
    try jw.write(self.causation_id);
    try jw.objectField("source");
    try jw.write(self.source);
    try jw.objectField("target");
    try jw.write(self.target);
    try jw.objectField("namespace");
    try jw.write(self.namespace);
    try jw.objectField("name");
    try jw.write(self.name);
    try jw.objectField("authority_generation");
    try jw.write(self.authority_generation);
    try jw.objectField("idempotency_key");
    try jw.write(self.idempotency_key);
    try jw.objectField("deadline_ms");
    try jw.write(self.deadline_ms);
    try jw.objectField("policy");
    try writePolicy(jw, self.policy);
    try jw.objectField("payload_type");
    try jw.write(self.payload_type);
    try jw.objectField("payload_hash");
    try jw.write(self.payload_hash);
    try jw.objectField("payload");
    try jw.write(self.payload);
    try jw.objectField("required_features");
    try jw.write(self.required_features);
    try jw.endObject();
}

fn writeCancel(jw: anytype, self: CommandCancel) !void {
    try jw.beginObject();
    try jw.objectField("command_id");
    try jw.write(self.command_id);
    try jw.objectField("causation_id");
    try jw.write(self.causation_id);
    try jw.objectField("source");
    try jw.write(self.source);
    try jw.objectField("authority_generation");
    try jw.write(self.authority_generation);
    try jw.objectField("reason");
    try writeOptStr(jw, self.reason);
    try jw.endObject();
}

fn writeEvents(jw: anytype, self: CommandEvents) !void {
    try jw.beginObject();
    try jw.objectField("events");
    try jw.beginArray();
    for (self.events) |e| {
        try jw.beginObject();
        try jw.objectField("event_id");
        try jw.write(e.event_id);
        try jw.objectField("command_id");
        try jw.write(e.command_id);
        try jw.objectField("kind");
        try jw.write(e.kind.wireName());
        try jw.objectField("generation");
        try jw.write(e.generation);
        try jw.objectField("detail");
        try writeOptStr(jw, e.detail);
        try jw.endObject();
    }
    try jw.endArray();
    try jw.endObject();
}

fn writeImage(jw: anytype, self: CommandProjectionImage) !void {
    try jw.beginObject();
    try jw.objectField("generation");
    try jw.write(self.generation);
    try jw.objectField("commands");
    try jw.beginArray();
    for (self.commands) |c| try writeEntry(jw, c);
    try jw.endArray();
    try jw.endObject();
}
