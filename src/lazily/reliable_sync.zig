//! Reliable sync protocol (`#lzsync`).
//!
//! Delivery-reliability over the `Snapshot`/`Delta`/`CrdtSync` planes
//! (`lazily-spec` § Reliable Sync): gap recovery, at-least-once outbox, and
//! OR-set / LWW liveness cells. The correctness backstop is `lazily-formal`
//! `ReliableSync.lean`; the cross-language pins are
//! `lazily-spec/conformance/reliable-sync/` (mirrored locally under
//! `test/reliable-sync/` so CI needs no `lazily-spec` sibling checkout).
//!
//! Three pure-protocol pieces (identical logic in every binding, no I/O / clock /
//! storage engine baked in):
//!
//! - `ResyncCoordinator` — receiver-side decision function over the inbound frame
//!   stream (`apply` / `request_snapshot` / `ignore`), multi-epoch-span aware.
//! - `DurableOutbox` — sender-side at-least-once contract (append-before-send,
//!   ack-through, replay-from-cursor). Ships `InMemoryOutbox` as the default; a
//!   host plugs a durable store (agent-doc: SQLite) behind the same duck-typed
//!   shape, and the crash-replay conformance replays a reference impl.
//! - `OrSet` / `WireLwwRegister` — the liveness cells that ride the CrdtSync plane.
//!
//! The reverse-channel control frames are `IpcMessage.ResyncRequest` and
//! `IpcMessage.OutboxAck` — variants on the same framed, codec-negotiated,
//! bidirectional message plane as `Snapshot`/`Delta`/`CrdtSync`, so they share
//! one encode/decode path, one demux point, one FFI kind, and one in-band order.
//! They match the `conformance/reliable-sync/` fixtures and round-trip through
//! json like the state frames.

const std = @import("std");
const ipc = @import("ipc.zig");

const Delta = ipc.Delta;
const IpcMessage = ipc.IpcMessage;
const WireStamp = ipc.WireStamp;

// ─────────────────────────────────────────────────────────────────────────────
// ResyncCoordinator — receiver-side decision function.
// ─────────────────────────────────────────────────────────────────────────────

/// Receiver decision for an inbound frame (spec § ResyncCoordinator).
pub const ResyncAction = union(enum) {
    /// Apply the frame and advance the receiver epoch.
    apply,
    /// A gap was detected; request a fresh `Snapshot` covering `from_epoch`
    /// (the payload is the receiver's current `last_epoch`).
    request_snapshot: u64,
    /// Drop the frame (already-applied re-delivery, malformed, a duplicate
    /// request suppressed while resyncing, or a reverse-channel control frame
    /// arriving at a data receiver).
    ignore,

    pub fn isApply(self: ResyncAction) bool {
        return self == .apply;
    }

    pub fn isRequestSnapshot(self: ResyncAction) bool {
        return self == .request_snapshot;
    }

    pub fn isIgnore(self: ResyncAction) bool {
        return self == .ignore;
    }

    /// The requested `from_epoch` when this is a `request_snapshot`, else null.
    pub fn fromEpoch(self: ResyncAction) ?u64 {
        return switch (self) {
            .request_snapshot => |from| from,
            else => null,
        };
    }
};

/// Receiver-side reliable-sync coordinator.
///
/// Holds `last_epoch` (the highest epoch fully applied) and a `resyncing` flag
/// (a `request_snapshot` is outstanding until a covering `Snapshot` lands, so
/// further ahead-of-cursor deltas are ignored instead of re-requesting).
///
/// `ingest` advances `last_epoch` on `apply` — the caller MUST fold the frame's
/// ops into its projection on `apply`. This mirrors the `ReliableSync.step` Lean
/// model.
pub const ResyncCoordinator = struct {
    last_epoch: u64 = 0,
    resyncing: bool = false,

    /// A coordinator at epoch 0 (fresh; a `Snapshot` seeds the first real epoch).
    pub fn init() ResyncCoordinator {
        return .{};
    }

    /// A coordinator that has already applied through `last_epoch`.
    pub fn withEpoch(last_epoch: u64) ResyncCoordinator {
        return .{ .last_epoch = last_epoch, .resyncing = false };
    }

    /// The highest epoch fully applied.
    pub fn lastEpoch(self: ResyncCoordinator) u64 {
        return self.last_epoch;
    }

    /// Whether a resync request is outstanding (awaiting a covering snapshot).
    pub fn isResyncing(self: ResyncCoordinator) bool {
        return self.resyncing;
    }

    /// Classify + fold an inbound `Delta`. On `apply` this advances `last_epoch`
    /// to `delta.epoch` (multi-epoch-span aware) and clears `resyncing`.
    pub fn ingestDelta(self: *ResyncCoordinator, delta: Delta) ResyncAction {
        if (delta.base_epoch == self.last_epoch) {
            // Contiguous. Accept any span >= 1; reject an empty/backward epoch.
            if (delta.epoch >= delta.base_epoch +| 1) {
                self.last_epoch = delta.epoch;
                self.resyncing = false;
                return .apply;
            }
            return .ignore;
        } else if (delta.base_epoch < self.last_epoch) {
            // Already applied — a re-delivery (outbox replay / retry). Idempotent.
            return .ignore;
        } else {
            // Gap: base_epoch > last_epoch. Request a covering snapshot once.
            if (self.resyncing) return .ignore;
            self.resyncing = true;
            return .{ .request_snapshot = self.last_epoch };
        }
    }

    /// Adopt a `Snapshot` at `snapshot_epoch` — a full-state frame always applies,
    /// setting `last_epoch` and clearing `resyncing`.
    pub fn ingestSnapshot(self: *ResyncCoordinator, snapshot_epoch: u64) ResyncAction {
        self.last_epoch = snapshot_epoch;
        self.resyncing = false;
        return .apply;
    }

    /// Classify an inbound `IpcMessage`. `CrdtSync` is handled by the CRDT plane,
    /// and the reverse-channel control frames (`ResyncRequest` / `OutboxAck`) are
    /// for the *sender*'s driver, not this data receiver, so both are `ignore`d.
    pub fn ingest(self: *ResyncCoordinator, msg: IpcMessage) ResyncAction {
        return switch (msg) {
            .Snapshot => |s| self.ingestSnapshot(s.epoch),
            .Delta => |d| self.ingestDelta(d),
            .CrdtSync, .ResyncRequest, .OutboxAck => .ignore,
        };
    }

    /// The `IpcMessage.OutboxAck` control frame advertising this receiver's
    /// resume cursor on reconnect (and for periodic retention advance).
    pub fn ack(self: ResyncCoordinator) IpcMessage {
        return IpcMessage.outboxAck(self.last_epoch);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// DurableOutbox — sender-side at-least-once contract + in-memory default.
// ─────────────────────────────────────────────────────────────────────────────

/// One retained outbox frame — `(epoch, message)`.
pub const OutboxEntry = struct {
    epoch: u64,
    message: IpcMessage,
};

/// Sender-side at-least-once outbox contract (spec § DurableOutbox).
///
/// Every frame is durably `append`ed **before** it is sent, retained until the
/// peer proves receipt (`ackThrough`), and `replayFrom` a reconnect cursor
/// re-sends everything the peer has not yet acked. Combined with the receiver's
/// idempotent `ignore` of already-applied deltas, this is at-least-once delivery
/// with exactly-once effect.
///
/// This is a duck-typed contract, not a Zig `interface` type: a durable store
/// (agent-doc: SQLite) satisfies it by exposing the same method set —
///
///   - `append(epoch: u64, msg: IpcMessage) !void` — persist before send.
///   - `ackThrough(epoch: u64) void` — advance retention cursor + prune `<= epoch`.
///   - `replayFrom(allocator, cursor: u64) ![]OutboxEntry` — retained `epoch > cursor`,
///     ascending (caller frees the slice).
///   - `retainedEpochs(allocator) ![]u64` — retained epochs, ascending (diagnostics).
///   - `retainedLen() usize` — retained frame count.
///
/// `InMemoryOutbox` is the default, correct within a process lifetime.
pub const InMemoryOutbox = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(OutboxEntry) = .empty,
    acked_through: u64 = 0,

    /// An empty outbox.
    pub fn init(allocator: std.mem.Allocator) InMemoryOutbox {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *InMemoryOutbox) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// The highest acked epoch (retention cursor).
    pub fn ackedThrough(self: InMemoryOutbox) u64 {
        return self.acked_through;
    }

    /// Persist `msg` at `epoch` before it is handed to the transport.
    pub fn append(self: *InMemoryOutbox, epoch: u64, msg: IpcMessage) !void {
        try self.entries.append(self.allocator, .{ .epoch = epoch, .message = msg });
    }

    /// The peer proved receipt through `epoch`; retained frames `<= epoch` pruned.
    pub fn ackThrough(self: *InMemoryOutbox, epoch: u64) void {
        if (epoch > self.acked_through) self.acked_through = epoch;
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (self.entries.items[i].epoch <= self.acked_through) {
                _ = self.entries.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Retained frames with `epoch > cursor`, in ascending epoch order. The
    /// returned slice is owned by `allocator`.
    pub fn replayFrom(self: InMemoryOutbox, allocator: std.mem.Allocator, cursor: u64) ![]OutboxEntry {
        var out: std.ArrayList(OutboxEntry) = .empty;
        errdefer out.deinit(allocator);
        for (self.entries.items) |entry| {
            if (entry.epoch > cursor) try out.append(allocator, entry);
        }
        std.mem.sort(OutboxEntry, out.items, {}, struct {
            fn lessThan(_: void, a: OutboxEntry, b: OutboxEntry) bool {
                return a.epoch < b.epoch;
            }
        }.lessThan);
        return out.toOwnedSlice(allocator);
    }

    /// Epochs still retained (not yet acked), ascending — the returned slice is
    /// owned by `allocator`.
    pub fn retainedEpochs(self: InMemoryOutbox, allocator: std.mem.Allocator) ![]u64 {
        const out = try allocator.alloc(u64, self.entries.items.len);
        for (self.entries.items, out) |entry, *e| e.* = entry.epoch;
        std.mem.sort(u64, out, {}, std.sort.asc(u64));
        return out;
    }

    /// The number of retained (unacked) frames.
    pub fn retainedLen(self: InMemoryOutbox) usize {
        return self.entries.items.len;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Liveness cells — OR-set + LWW register (ride the CrdtSync plane).
// ─────────────────────────────────────────────────────────────────────────────

/// An observed-remove set (OR-set) liveness cell.
///
/// Models one entry's presence via add/remove tags: a `(doc, pid)` is *present*
/// iff some add-tag is not shadowed by a remove that observed it. This gives the
/// add-wins-over-stale-remove bias liveness needs (a re-open concurrent with a
/// lagging close keeps the doc open). The join is the union of both tag sets, so
/// it is a semilattice — out-of-order and duplicate delivery converge
/// (`ReliableSync.joinOR_*`, `orset_add_wins_over_stale_remove`).
pub const OrSet = struct {
    allocator: std.mem.Allocator,
    adds: std.StringHashMapUnmanaged(void) = .empty,
    removes: std.StringHashMapUnmanaged(void) = .empty,

    /// An empty OR-set.
    pub fn init(allocator: std.mem.Allocator) OrSet {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OrSet) void {
        freeKeys(self.allocator, &self.adds);
        freeKeys(self.allocator, &self.removes);
        self.* = undefined;
    }

    /// Add a presence tag (an editor open / attach event mints a fresh tag).
    pub fn add(self: *OrSet, tag: []const u8) !void {
        try insertOwned(self.allocator, &self.adds, tag);
    }

    /// Remove, observing `tags` — only the add-tags this remove saw are shadowed.
    pub fn removeObserved(self: *OrSet, tags: []const []const u8) !void {
        for (tags) |t| try insertOwned(self.allocator, &self.removes, t);
    }

    /// Whether the entry is currently present (some add-tag not shadowed).
    pub fn present(self: OrSet) bool {
        var it = self.adds.keyIterator();
        while (it.next()) |k| {
            if (!self.removes.contains(k.*)) return true;
        }
        return false;
    }

    /// Join another replica's OR-set (union of adds and of removes).
    pub fn join(self: *OrSet, other: OrSet) !void {
        var ai = other.adds.keyIterator();
        while (ai.next()) |k| try insertOwned(self.allocator, &self.adds, k.*);
        var ri = other.removes.keyIterator();
        while (ri.next()) |k| try insertOwned(self.allocator, &self.removes, k.*);
    }

    fn insertOwned(
        allocator: std.mem.Allocator,
        set: *std.StringHashMapUnmanaged(void),
        key: []const u8,
    ) !void {
        if (set.contains(key)) return;
        const owned = try allocator.dupe(u8, key);
        errdefer allocator.free(owned);
        try set.put(allocator, owned, {});
    }

    fn freeKeys(allocator: std.mem.Allocator, set: *std.StringHashMapUnmanaged(void)) void {
        var it = set.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        set.deinit(allocator);
    }
};

/// A last-writer-wins register liveness cell (per-pid `alive`, owner lease).
///
/// Keyed by `WireStamp` (`(wall_time, logical, peer)` total order): the highest
/// stamp wins, so an OS process-exit write (`alive = false` at a fresh stamp)
/// dominates a stale re-assert. Join is the stamp-max, a semilattice
/// (`ReliableSync.joinReg_*`).
pub fn WireLwwRegister(comptime V: type) type {
    return struct {
        const Self = @This();

        reg_stamp: WireStamp,
        reg_value: V,

        /// A register holding `value` written at `stamp`.
        pub fn init(stamp_in: WireStamp, value_in: V) Self {
            return .{ .reg_stamp = stamp_in, .reg_value = value_in };
        }

        /// The current value.
        pub fn value(self: Self) V {
            return self.reg_value;
        }

        /// The current decisive stamp.
        pub fn stamp(self: Self) WireStamp {
            return self.reg_stamp;
        }

        /// Write `value` at `stamp` iff it dominates the current stamp.
        pub fn set(self: *Self, new_stamp: WireStamp, new_value: V) void {
            if (new_stamp.compare(self.reg_stamp) == .gt) {
                self.reg_stamp = new_stamp;
                self.reg_value = new_value;
            }
        }

        /// Join another replica's register (keep the higher stamp).
        pub fn join(self: *Self, other: Self) void {
            self.set(other.reg_stamp, other.reg_value);
        }
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// SyncDriver — full-duplex reliable-sync loop over injected seams.
// ─────────────────────────────────────────────────────────────────────────────

/// What one `SyncDriver.tick` accomplished (spec § SyncDriver).
///
/// `applied` are the inbound `Snapshot`/`Delta`/`CrdtSync` frames the host MUST
/// fold into its projection this tick — the driver has already advanced the
/// receiver cursor for them, so folding is the caller's remaining obligation.
/// `applied` is owned by `allocator`; call `deinit`.
pub const Progress = struct {
    /// Data frames pushed to the sink this tick (fresh enqueues + reconnect replays).
    sent: usize = 0,
    /// Inbound frames the host must fold into its projection (`apply`ed).
    applied: []IpcMessage = &.{},
    /// A gap was detected inbound and a `ResyncRequest` was emitted to the peer.
    resync_requested: bool = false,
    /// Inbound `ResyncRequest`s answered with a provider snapshot this tick.
    snapshots_served: usize = 0,
    /// The peer's ack cursor after this tick (our outbox retention / resume point).
    peer_acked_through: u64 = 0,
    /// Outbox frames still unacked (retained for reconnect replay).
    retained: usize = 0,
    allocator: ?std.mem.Allocator = null,

    pub fn deinit(self: *Progress) void {
        if (self.allocator) |a| a.free(self.applied);
        self.applied = &.{};
        self.allocator = null;
    }
};

/// Full-duplex reliable-sync loop driver (spec § SyncDriver).
///
/// One driver drives one peer connection over caller-supplied seams. It composes
/// the pure-protocol pieces into the loop shape the spec pins:
///
/// 1. **resync-on-reconnect** — `onReconnect` replays the unacked outbox suffix
///    from the peer's ack cursor and re-advertises our own receiver cursor.
/// 2. **drain** — pop host-enqueued outbound data frames, `append` each to the
///    outbox *before* sending (at-least-once durability), send via the sink.
/// 3. **retain-on-fail** — a send error leaves the frame in the outbox (unacked)
///    and stops the drain; it is re-sent on the next reconnect.
/// 4. **receive** — read inbound frames, route control frames (`OutboxAck` →
///    advance retention; `ResyncRequest` → answer with a provider snapshot) and
///    feed data frames through the `ResyncCoordinator`.
///
/// The seams are duck-typed comptime parameters (the Zig equivalent of the Rust
/// generics `S, R, O, C, P`):
///
///   - `Sink.send(*Sink, IpcMessage) bool` — true on success (a false is a stall,
///     NOT an error: the frame is retained and replayed on reconnect).
///   - `Source.recv(*Source) !?IpcMessage` — next inbound frame, null when drained.
///     A recv *error* propagates from `tick` (the `DriverError::Source` shape),
///     signalling the host to re-establish the transport and call `onReconnect`.
///   - `Clock.nowMillis(*const Clock) u64` — monotonic millis (stall timestamp).
///   - `Provider.snapshot(*const Provider, u64) IpcMessage` — a covering snapshot.
///   - `Outbox` — the `DurableOutbox` duck-typed contract (see `InMemoryOutbox`).
///
/// The driver owns no threads, no clock source, and no storage engine — the host
/// injects all seams and decides the tick cadence.
pub fn SyncDriver(
    comptime Sink: type,
    comptime Source: type,
    comptime Outbox: type,
    comptime Clock: type,
    comptime Provider: type,
) type {
    return struct {
        const Self = @This();

        const PendingEntry = struct {
            epoch: u64,
            message: IpcMessage,
        };

        allocator: std.mem.Allocator,
        sink: Sink,
        source: Source,
        outbox: Outbox,
        clock: Clock,
        provider: Provider,
        coordinator: ResyncCoordinator,
        /// Host-enqueued outbound data frames staged before append-then-send.
        pending: std.ArrayList(PendingEntry) = .empty,
        /// Highest epoch the peer acked — outbox retention + reconnect resume cursor.
        peer_acked_through: u64 = 0,
        /// We applied an inbound frame and owe the peer an `OutboxAck`.
        ack_owed: bool = false,
        /// A reconnect happened; the next tick replays the unacked outbox suffix.
        replay_pending: bool = false,
        /// `millis` since the last sink send failure; `null` when the sink is healthy.
        stalled_since: ?u64 = null,

        /// A fresh driver at receiver epoch 0 (a `Snapshot` seeds the first epoch).
        pub fn init(
            allocator: std.mem.Allocator,
            sink: Sink,
            source: Source,
            outbox: Outbox,
            clock: Clock,
            provider: Provider,
        ) Self {
            return Self.withEpoch(allocator, sink, source, outbox, clock, provider, 0);
        }

        /// A driver whose receiver already applied through `last_epoch` (resume).
        pub fn withEpoch(
            allocator: std.mem.Allocator,
            sink: Sink,
            source: Source,
            outbox: Outbox,
            clock: Clock,
            provider: Provider,
            last_epoch: u64,
        ) Self {
            return .{
                .allocator = allocator,
                .sink = sink,
                .source = source,
                .outbox = outbox,
                .clock = clock,
                .provider = provider,
                .coordinator = ResyncCoordinator.withEpoch(last_epoch),
            };
        }

        pub fn deinit(self: *Self) void {
            self.pending.deinit(self.allocator);
            self.* = undefined;
        }

        /// Stage an outbound data frame at `epoch` for the next tick's drain.
        pub fn enqueue(self: *Self, epoch: u64, msg: IpcMessage) !void {
            try self.pending.append(self.allocator, .{ .epoch = epoch, .message = msg });
        }

        /// Signal that the transport was re-established; the next `tick` replays
        /// the unacked outbox suffix and re-advertises our receiver cursor.
        pub fn onReconnect(self: *Self) void {
            self.replay_pending = true;
            self.ack_owed = true;
            self.stalled_since = null;
        }

        /// The receiver's current applied epoch.
        pub fn lastEpoch(self: Self) u64 {
            return self.coordinator.lastEpoch();
        }

        /// Whether the sink is currently stalled (last send failed).
        pub fn isStalled(self: Self) bool {
            return self.stalled_since != null;
        }

        /// Millis the sink has been stalled as of `now`, or `0` when healthy — a
        /// backoff signal for the host scheduler.
        pub fn stalledFor(self: Self, now: u64) u64 {
            return if (self.stalled_since) |since| now -| since else 0;
        }

        /// Borrow the underlying outbox (diagnostics / durable-store flush).
        pub fn outboxPtr(self: *Self) *Outbox {
            return &self.outbox;
        }

        /// Run one loop pass. See the type docs for the resync → drain → receive
        /// shape. Sink failures retain-and-stall (not an error); only an inbound
        /// source read failure propagates as the `DriverError::Source` shape.
        pub fn tick(self: *Self) !Progress {
            const now = self.clock.nowMillis();
            var progress: Progress = .{};

            // 1. resync-on-reconnect: replay the unacked outbox suffix, oldest first.
            if (self.replay_pending) {
                self.replay_pending = false;
                const frames = try self.outbox.replayFrom(self.allocator, self.peer_acked_through);
                defer self.allocator.free(frames);
                for (frames) |frame| {
                    if (self.sink.send(frame.message)) {
                        progress.sent += 1;
                    } else {
                        self.stalled_since = now;
                        self.replay_pending = true; // finish after the next reconnect
                        break;
                    }
                }
            }

            // 2. drain fresh enqueues: append-before-send, retain-and-stop on failure.
            //    A pre-existing stall skips the drain entirely.
            while (self.stalled_since == null and self.pending.items.len > 0) {
                const entry = self.pending.items[0];
                try self.outbox.append(entry.epoch, entry.message);
                _ = self.pending.orderedRemove(0);
                if (self.sink.send(entry.message)) {
                    progress.sent += 1;
                    self.stalled_since = null;
                } else {
                    // Retained in the outbox (unacked) → replayed on reconnect.
                    self.stalled_since = now;
                    break;
                }
            }

            // 3. receive: route control frames + feed data frames through the coordinator.
            var applied: std.ArrayList(IpcMessage) = .empty;
            errdefer applied.deinit(self.allocator);
            while (true) {
                const msg = (try self.source.recv()) orelse break;
                switch (msg) {
                    .OutboxAck => |a| {
                        if (a.through_epoch > self.peer_acked_through) {
                            self.peer_acked_through = a.through_epoch;
                        }
                        self.outbox.ackThrough(a.through_epoch);
                    },
                    .ResyncRequest => |req| {
                        const snap = self.provider.snapshot(req.from_epoch);
                        if (self.sink.send(snap)) {
                            progress.snapshots_served += 1;
                        } else {
                            self.stalled_since = now;
                        }
                    },
                    .CrdtSync => {
                        // Idempotent anti-entropy plane — the host folds it directly.
                        try applied.append(self.allocator, msg);
                    },
                    .Snapshot, .Delta => {
                        switch (self.coordinator.ingest(msg)) {
                            .apply => {
                                self.ack_owed = true;
                                try applied.append(self.allocator, msg);
                            },
                            .request_snapshot => |from_epoch| {
                                const req = IpcMessage.resyncRequest(from_epoch);
                                if (self.sink.send(req)) {
                                    progress.resync_requested = true;
                                } else {
                                    self.stalled_since = now;
                                }
                            },
                            .ignore => {},
                        }
                    },
                }
            }

            // 4. advertise our receiver cursor if we applied anything (retry until sent).
            if (self.ack_owed and self.sink.send(self.coordinator.ack())) {
                self.ack_owed = false;
            }

            progress.applied = try applied.toOwnedSlice(self.allocator);
            progress.allocator = self.allocator;
            progress.peer_acked_through = self.peer_acked_through;
            progress.retained = self.outbox.retainedLen();
            return progress;
        }
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests — conformance fixture replay + SyncDriver loop-shape + wire round-trip.
//
// The reliable-sync conformance fixtures live in `test/reliable-sync/` (copied
// from `lazily-spec/conformance/reliable-sync/` so CI needs no sibling). The
// scenarios are transcribed by hand — the same fixture-mirroring pattern the
// other conformance tests use (see lazily-cpp `tests/test_reliable_sync.cpp`) —
// and each embedded fixture is additionally parsed to prove it round-trips
// through the codec.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const NodeId = ipc.NodeId;
const DeltaOp = ipc.DeltaOp;
const Snapshot = ipc.Snapshot;
const NodeSnapshot = ipc.NodeSnapshot;
const IpcValue = ipc.IpcValue;

fn cellset(node: NodeId, bytes: []const u8) DeltaOp {
    return DeltaOp.cellSet(node, IpcValue.fromInline(bytes));
}
fn slotvalue(node: NodeId, bytes: []const u8) DeltaOp {
    return DeltaOp.slotValue(node, IpcValue.fromInline(bytes));
}
fn mkDelta(base: u64, epoch: u64, ops: []const DeltaOp) Delta {
    return Delta.init(base, epoch, ops);
}
fn nodeSnap(node: NodeId, bytes: []const u8) NodeSnapshot {
    return NodeSnapshot.fromPayload(node, "u64", bytes);
}
fn ws(wall: u64, logical: u64, peer: u64) WireStamp {
    return .{ .wall_time = wall, .logical = logical, .peer = peer };
}

/// Tiny graph-state model: fold Delta/Snapshot into node -> owned bytes.
const GraphModel = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMapUnmanaged(NodeId, []u8) = .empty,

    fn init(allocator: std.mem.Allocator) GraphModel {
        return .{ .allocator = allocator };
    }
    fn deinit(self: *GraphModel) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }
    fn setNode(self: *GraphModel, node: NodeId, bytes: []const u8) !void {
        const owned = try self.allocator.dupe(u8, bytes);
        const gop = try self.nodes.getOrPut(self.allocator, node);
        if (gop.found_existing) self.allocator.free(gop.value_ptr.*);
        gop.value_ptr.* = owned;
    }
    fn applyDelta(self: *GraphModel, d: Delta) !void {
        for (d.ops) |op| switch (op) {
            .CellSet => |o| try self.setNode(o.node, o.payload.Inline),
            .SlotValue => |o| try self.setNode(o.node, o.payload.Inline),
            else => {},
        };
    }
    fn applySnapshot(self: *GraphModel, s: Snapshot) !void {
        var it = self.nodes.valueIterator();
        while (it.next()) |v| self.allocator.free(v.*);
        self.nodes.clearRetainingCapacity();
        for (s.nodes) |n| try self.setNode(n.node, n.state.Payload);
    }
    fn eql(self: GraphModel, other: GraphModel) bool {
        if (self.nodes.count() != other.nodes.count()) return false;
        var it = self.nodes.iterator();
        while (it.next()) |e| {
            const ov = other.nodes.get(e.key_ptr.*) orelse return false;
            if (!std.mem.eql(u8, e.value_ptr.*, ov)) return false;
        }
        return true;
    }
};

// ── resync_gap_converge.json ─────────────────────────────────────────────────

// drop_suffix_then_resync_converges: receiver misses delta 2->3, detects the gap
// on 3->4, emits RequestSnapshot{from:2}, applies the covering Snapshot{epoch:4},
// and reaches the SAME graph as a receiver that saw every delta.
test "reliable_sync conformance: resync drop-suffix converges" {
    const a = testing.allocator;
    var coord = ResyncCoordinator.withEpoch(1);
    var ga = GraphModel.init(a);
    defer ga.deinit();

    const d12 = mkDelta(1, 2, &.{cellset(1, &.{10})});
    try testing.expect(coord.ingestDelta(d12).isApply());
    try ga.applyDelta(d12);
    try testing.expectEqual(@as(u64, 2), coord.lastEpoch());

    // delta 2->3 dropped (never arrives at A)

    var resync_requests: usize = 0;
    const d34 = mkDelta(3, 4, &.{cellset(3, &.{30})});
    const act = coord.ingestDelta(d34);
    try testing.expect(act.isRequestSnapshot());
    try testing.expectEqual(@as(?u64, 2), act.fromEpoch());
    resync_requests += 1;
    try testing.expectEqual(@as(u64, 2), coord.lastEpoch()); // unchanged

    const snap = Snapshot.init(4, &.{ nodeSnap(1, &.{10}), nodeSnap(2, &.{20}), nodeSnap(3, &.{30}) }, &.{}, &.{ 1, 2, 3 });
    try testing.expect(coord.ingestSnapshot(snap.epoch).isApply());
    try ga.applySnapshot(snap);
    try testing.expectEqual(@as(u64, 4), coord.lastEpoch());

    // Receiver B saw every delta 1->2->3->4.
    var gb = GraphModel.init(a);
    defer gb.deinit();
    try gb.applyDelta(mkDelta(1, 2, &.{cellset(1, &.{10})}));
    try gb.applyDelta(mkDelta(2, 3, &.{cellset(2, &.{20})}));
    try gb.applyDelta(mkDelta(3, 4, &.{cellset(3, &.{30})}));

    try testing.expectEqual(@as(usize, 1), resync_requests);
    try testing.expect(ga.eql(gb)); // equals_no_drop_receiver
    try testing.expectEqual(@as(usize, 3), ga.nodes.count());
}

// single_request_per_gap: while resyncing, further ahead-of-cursor deltas are
// Ignored and do NOT emit duplicate ResyncRequests.
test "reliable_sync conformance: single request per gap" {
    var coord = ResyncCoordinator.withEpoch(2);
    var resync_requests: usize = 0;

    var act = coord.ingestDelta(mkDelta(3, 4, &.{}));
    try testing.expect(act.isRequestSnapshot() and act.fromEpoch().? == 2);
    resync_requests += 1;

    act = coord.ingestDelta(mkDelta(4, 5, &.{}));
    try testing.expect(act.isIgnore()); // resyncing — suppress duplicate request
    try testing.expectEqual(@as(u64, 2), coord.lastEpoch());

    act = coord.ingestDelta(mkDelta(5, 6, &.{}));
    try testing.expect(act.isIgnore());
    try testing.expectEqual(@as(u64, 2), coord.lastEpoch());

    try testing.expect(coord.ingestSnapshot(6).isApply());
    try testing.expectEqual(@as(u64, 6), coord.lastEpoch());
    try testing.expectEqual(@as(usize, 1), resync_requests);
}

// ── idempotent_redelivery.json ───────────────────────────────────────────────

// replayed_delta_is_ignored: a re-delivered delta 40->41 (base_epoch 40 < 42) is
// Ignored; net state and last_epoch unchanged. OutboxAck advertises through=42.
test "reliable_sync conformance: idempotent replayed delta ignored" {
    var coord = ResyncCoordinator.withEpoch(42);
    const redeliver = mkDelta(40, 41, &.{cellset(1, &.{99})});
    try testing.expect(coord.ingestDelta(redeliver).isIgnore());
    try testing.expectEqual(@as(u64, 42), coord.lastEpoch());

    const ack = coord.ack();
    try testing.expectEqual(@as(u64, 42), ack.OutboxAck.through_epoch);
}

// duplicate_current_head_is_ignored: an exact re-delivery of the last-applied
// delta is also Ignored — a duplicate never double-applies.
test "reliable_sync conformance: idempotent duplicate head ignored" {
    var coord = ResyncCoordinator.withEpoch(41);
    try testing.expect(coord.ingestDelta(mkDelta(40, 41, &.{cellset(1, &.{10})})).isIgnore());
    try testing.expectEqual(@as(u64, 41), coord.lastEpoch());
}

// ── multi_epoch_delta.json ───────────────────────────────────────────────────

// span_3_applies_equal_to_unit_fold: one span-3 delta reaches the same graph and
// last_epoch as three unit deltas carrying the same ops in order.
test "reliable_sync conformance: multi-epoch apply equals fold" {
    const a = testing.allocator;
    const span3 = mkDelta(40, 43, &.{ cellset(1, &.{10}), cellset(2, &.{20}), slotvalue(3, &.{30}) });

    // assertions block
    try testing.expectEqual(@as(u64, 40), span3.base_epoch);
    try testing.expectEqual(@as(u64, 43), span3.epoch);
    try testing.expectEqual(@as(u64, 3), span3.epoch - span3.base_epoch); // span
    try testing.expect(span3.epoch > span3.base_epoch + 1); // is_multi_epoch
    try testing.expectEqual(@as(usize, 3), span3.ops.len); // op_count

    var coord = ResyncCoordinator.withEpoch(40);
    var batch = GraphModel.init(a);
    defer batch.deinit();
    try testing.expect(coord.ingestDelta(span3).isApply());
    try batch.applyDelta(span3);
    try testing.expectEqual(@as(u64, 43), coord.lastEpoch()); // atomic advance

    // Equivalent unit fold.
    var unit_coord = ResyncCoordinator.withEpoch(40);
    var unit = GraphModel.init(a);
    defer unit.deinit();
    const units = [_]Delta{
        mkDelta(40, 41, &.{cellset(1, &.{10})}),
        mkDelta(41, 42, &.{cellset(2, &.{20})}),
        mkDelta(42, 43, &.{slotvalue(3, &.{30})}),
    };
    for (units) |d| {
        try testing.expect(unit_coord.ingestDelta(d).isApply());
        try unit.applyDelta(d);
    }
    try testing.expectEqual(@as(u64, 43), unit_coord.lastEpoch());
    try testing.expect(batch.eql(unit)); // fold_equivalent
}

// gap_rule_unchanged_under_span: a span-3 delta whose base_epoch != last_epoch is
// still a gap; the span does not relax gap detection.
test "reliable_sync conformance: multi-epoch gap rule unchanged" {
    var coord = ResyncCoordinator.withEpoch(39);
    const act = coord.ingestDelta(mkDelta(40, 43, &.{}));
    try testing.expect(act.isRequestSnapshot());
    try testing.expectEqual(@as(?u64, 39), act.fromEpoch());
    try testing.expectEqual(@as(u64, 39), coord.lastEpoch()); // unchanged
}

// ── outbox_replay_after_crash.json ───────────────────────────────────────────

// crash_between_append_and_ack_replays_on_reconnect: appended 41,42,43; peer acks
// through 41; on reconnect replay_from(41) re-sends 42,43 in order; receiver
// applies both -> last_epoch 43. Exactly-once effect: none lost, none doubled.
test "reliable_sync conformance: outbox replay after crash" {
    const a = testing.allocator;
    var outbox = InMemoryOutbox.init(a);
    defer outbox.deinit();
    try outbox.append(41, .{ .Delta = mkDelta(40, 41, &.{cellset(1, &.{10})}) });
    try outbox.append(42, .{ .Delta = mkDelta(41, 42, &.{cellset(2, &.{20})}) });
    try outbox.append(43, .{ .Delta = mkDelta(42, 43, &.{cellset(3, &.{30})}) });

    outbox.ackThrough(41);
    const retained = try outbox.retainedEpochs(a);
    defer a.free(retained);
    try testing.expectEqualSlices(u64, &.{ 42, 43 }, retained); // retained_after_ack

    const replay = try outbox.replayFrom(a, 41); // reconnect cursor = 41
    defer a.free(replay);
    try testing.expectEqual(@as(usize, 2), replay.len);
    try testing.expectEqual(@as(u64, 42), replay[0].epoch);
    try testing.expectEqual(@as(u64, 43), replay[1].epoch); // replay_order

    var coord = ResyncCoordinator.withEpoch(41);
    var g = GraphModel.init(a);
    defer g.deinit();
    var applied: [2]u64 = undefined;
    var n: usize = 0;
    for (replay) |e| {
        try testing.expect(coord.ingest(e.message).isApply());
        try g.applyDelta(e.message.Delta);
        applied[n] = e.epoch;
        n += 1;
    }
    try testing.expectEqualSlices(u64, &.{ 42, 43 }, applied[0..n]); // receiver_applies
    try testing.expectEqual(@as(u64, 43), coord.lastEpoch());
}

// send_failure_retains_frame_for_next_tick: a send error does not lose the frame
// (append succeeded, send failed) — it stays in the outbox and is retried on a
// later tick. Driven through the SyncDriver loop.
test "reliable_sync conformance: outbox send-failure retains" {
    const a = testing.allocator;

    var d = try Harness.at(a, 0);
    defer d.deinit();
    d.wire.up = false; // sink down before the first send

    try d.driver.enqueue(44, .{ .Delta = mkDelta(43, 44, &.{cellset(4, &.{40})}) });
    var p1 = try d.driver.tick();
    defer p1.deinit();
    try testing.expectEqual(@as(usize, 0), p1.sent);
    try testing.expect(d.driver.isStalled());
    const r1 = try d.driver.outboxPtr().retainedEpochs(a);
    defer a.free(r1);
    try testing.expectEqualSlices(u64, &.{44}, r1); // frame_retained_after_failed_send

    d.wire.up = true;
    d.driver.onReconnect();
    var p2 = try d.driver.tick();
    defer p2.deinit();
    try testing.expectEqual(@as(usize, 1), p2.sent); // resent_on_next_tick: [44]
    const r2 = try d.driver.outboxPtr().retainedEpochs(a);
    defer a.free(r2);
    try testing.expectEqualSlices(u64, &.{44}, r2); // still unacked (no permanent gap)
}

// ── liveness_orset_lww.json ──────────────────────────────────────────────────

// open_set_add_wins_over_stale_remove: a re-open (add t3) concurrent with a
// lagging close (remove observing only t1) keeps the doc open; order-independent.
test "reliable_sync conformance: liveness OR-set add wins" {
    const a = testing.allocator;
    var s = OrSet.init(a);
    defer s.deinit();
    try s.add("t1");
    try s.removeObserved(&.{"t1"});
    try s.add("t3");
    try testing.expect(s.present()); // add_tag_t3_not_observed_by_remove

    // order_independent: apply in reverse order, same result.
    var r = OrSet.init(a);
    defer r.deinit();
    try r.add("t3");
    try r.add("t1");
    try r.removeObserved(&.{"t1"});
    try testing.expect(r.present());

    // redeliver_applied_count 0: joining an identical replica changes nothing.
    const before = s.present();
    try s.join(r);
    try testing.expectEqual(before, s.present());
}

// lww_alive_highest_stamp_wins: the OS process-exit write (alive=false at higher
// stamp) wins; a stale re-assert (alive=true at lower stamp) is dominated.
test "reliable_sync conformance: liveness LWW highest stamp wins" {
    const Reg = WireLwwRegister(bool);
    var alive = Reg.init(ws(20, 0, 1), true);
    alive.set(ws(25, 0, 1), false);
    alive.set(ws(22, 0, 1), true); // stale — dominated
    try testing.expectEqual(false, alive.value()); // max_stamp resolution

    // order_independent: apply in a different order.
    var alive2 = Reg.init(ws(22, 0, 1), true);
    alive2.set(ws(20, 0, 1), true);
    alive2.set(ws(25, 0, 1), false);
    try testing.expectEqual(false, alive2.value());
}

// Derived per-doc live aggregate: a doc is live iff some present (doc,pid) has
// alive[pid] == true.
const LiveEntry = struct { key: []const u8, doc: []const u8, pid: []const u8, set: OrSet };

fn liveDocs(
    allocator: std.mem.Allocator,
    entries: []const LiveEntry,
    alive: std.StringHashMapUnmanaged(WireLwwRegister(bool)),
) !std.StringHashMapUnmanaged(void) {
    var docs: std.StringHashMapUnmanaged(void) = .empty;
    errdefer docs.deinit(allocator);
    for (entries) |e| {
        if (!e.set.present()) continue;
        const reg = alive.get(e.pid) orelse continue;
        if (reg.value()) try docs.put(allocator, e.doc, {});
    }
    return docs;
}

// whole_editor_death_cascades: one alive[pid100]=false recomputes the derived
// live aggregate for BOTH docs pid100 held; docC (pid200) unaffected.
test "reliable_sync conformance: liveness whole-editor death cascades" {
    const a = testing.allocator;
    const Reg = WireLwwRegister(bool);

    var entries: [3]LiveEntry = .{
        .{ .key = "docA/pid100", .doc = "docA", .pid = "100", .set = OrSet.init(a) },
        .{ .key = "docB/pid100", .doc = "docB", .pid = "100", .set = OrSet.init(a) },
        .{ .key = "docC/pid200", .doc = "docC", .pid = "200", .set = OrSet.init(a) },
    };
    defer for (&entries) |*e| e.set.deinit();
    for (&entries) |*e| try e.set.add(e.key); // one add tag = present

    var alive: std.StringHashMapUnmanaged(Reg) = .empty;
    defer alive.deinit(a);
    try alive.put(a, "100", Reg.init(ws(1, 0, 1), true));
    try alive.put(a, "200", Reg.init(ws(1, 0, 1), true));

    var before = try liveDocs(a, &entries, alive);
    defer before.deinit(a);
    try testing.expectEqual(@as(usize, 3), before.count()); // docA, docB, docC

    // pid100 dies (higher stamp).
    alive.getPtr("100").?.set(ws(30, 0, 1), false);
    var after = try liveDocs(a, &entries, alive);
    defer after.deinit(a);
    try testing.expectEqual(@as(usize, 1), after.count()); // cascade -> only docC
    try testing.expect(after.contains("docC"));
    try testing.expect(!after.contains("docA"));
    try testing.expect(!after.contains("docB"));
}

// derived_live_doc_aggregate_converges_under_retry: two replicas exchange the same
// liveness ops in different orders; the derived per-doc live aggregate converges
// identically (semilattice join).
test "reliable_sync conformance: liveness converges under retry" {
    const a = testing.allocator;
    const Reg = WireLwwRegister(bool);

    const build = struct {
        fn go(alloc: std.mem.Allocator, reverse: bool, out: *[2]LiveEntry) !std.StringHashMapUnmanaged(void) {
            if (!reverse) {
                out[0] = .{ .key = "docA/pid100", .doc = "docA", .pid = "100", .set = OrSet.init(alloc) };
                out[1] = .{ .key = "docB/pid100", .doc = "docB", .pid = "100", .set = OrSet.init(alloc) };
                try out[0].set.add("a1");
                try out[1].set.add("b1");
            } else {
                out[0] = .{ .key = "docB/pid100", .doc = "docB", .pid = "100", .set = OrSet.init(alloc) };
                out[1] = .{ .key = "docA/pid100", .doc = "docA", .pid = "100", .set = OrSet.init(alloc) };
                try out[0].set.add("b1");
                try out[1].set.add("a1");
            }
            var alive: std.StringHashMapUnmanaged(Reg) = .empty;
            defer alive.deinit(alloc);
            try alive.put(alloc, "100", Reg.init(ws(41, 0, 1), true));
            return liveDocs(alloc, out, alive);
        }
    }.go;

    var e1: [2]LiveEntry = undefined;
    var r1 = try build(a, false, &e1);
    defer r1.deinit(a);
    defer for (&e1) |*e| e.set.deinit();

    var e2: [2]LiveEntry = undefined;
    var r2 = try build(a, true, &e2);
    defer r2.deinit(a);
    defer for (&e2) |*e| e.set.deinit();

    try testing.expectEqual(r1.count(), r2.count()); // order_independent
    try testing.expectEqual(@as(usize, 2), r1.count()); // converged_live_docs
    try testing.expect(r1.contains("docA") and r1.contains("docB"));
}

// ── wire round-trip: the new control frames survive the codec ────────────────

fn roundTrip(a: std.mem.Allocator, msg: IpcMessage) !ipc.ParsedMessage {
    const bytes = try msg.encodeJsonAlloc(a);
    defer a.free(bytes);
    return IpcMessage.decodeJson(a, bytes);
}

test "reliable_sync: control-frame wire round-trip" {
    const a = testing.allocator;

    var rq = try roundTrip(a, IpcMessage.resyncRequest(2));
    defer rq.deinit();
    try testing.expectEqual(@as(u64, 2), rq.message.ResyncRequest.from_epoch);

    var ak = try roundTrip(a, IpcMessage.outboxAck(42));
    defer ak.deinit();
    try testing.expectEqual(@as(u64, 42), ak.message.OutboxAck.through_epoch);

    try testing.expect(IpcMessage.resyncRequest(2).isControl());
    try testing.expect(IpcMessage.outboxAck(42).isControl());
    try testing.expect(!(IpcMessage{ .Delta = mkDelta(0, 1, &.{}) }).isControl());
}

// ── embedded fixtures parse through the codec (CI needs no lazily-spec sibling) ──

const fixture_resync = @embedFile("test/reliable-sync/resync_gap_converge.json");
const fixture_idempotent = @embedFile("test/reliable-sync/idempotent_redelivery.json");
const fixture_multi_epoch = @embedFile("test/reliable-sync/multi_epoch_delta.json");
const fixture_outbox = @embedFile("test/reliable-sync/outbox_replay_after_crash.json");
const fixture_liveness = @embedFile("test/reliable-sync/liveness_orset_lww.json");

/// Decode the top-level `wire` frame of an embedded fixture through the codec.
fn decodeFixtureWire(a: std.mem.Allocator, fixture: []const u8) !ipc.ParsedMessage {
    var root = try std.json.parseFromSlice(std.json.Value, a, fixture, .{ .allocate = .alloc_always });
    defer root.deinit();
    const wire = root.value.object.get("wire") orelse return error.MissingWire;
    const wire_json = try std.json.Stringify.valueAlloc(a, wire, .{});
    defer a.free(wire_json);
    return IpcMessage.decodeJson(a, wire_json);
}

test "reliable_sync: embedded fixtures decode through codec" {
    const a = testing.allocator;

    // resync_gap_converge → ResyncRequest { from_epoch: 2 }
    var f1 = try decodeFixtureWire(a, fixture_resync);
    defer f1.deinit();
    try testing.expectEqual(@as(u64, 2), f1.message.ResyncRequest.from_epoch);

    // idempotent_redelivery → OutboxAck { through_epoch: 42 }
    var f2 = try decodeFixtureWire(a, fixture_idempotent);
    defer f2.deinit();
    try testing.expectEqual(@as(u64, 42), f2.message.OutboxAck.through_epoch);

    // multi_epoch_delta → Delta { base_epoch: 40, epoch: 43, ops: 3 }
    var f3 = try decodeFixtureWire(a, fixture_multi_epoch);
    defer f3.deinit();
    try testing.expectEqual(@as(u64, 40), f3.message.Delta.base_epoch);
    try testing.expectEqual(@as(u64, 43), f3.message.Delta.epoch);
    try testing.expectEqual(@as(usize, 3), f3.message.Delta.ops.len);

    // outbox_replay_after_crash → OutboxAck { through_epoch: 41 }
    var f4 = try decodeFixtureWire(a, fixture_outbox);
    defer f4.deinit();
    try testing.expectEqual(@as(u64, 41), f4.message.OutboxAck.through_epoch);

    // liveness_orset_lww has no top-level `wire`; assert it parses + has scenarios.
    var f5 = try std.json.parseFromSlice(std.json.Value, a, fixture_liveness, .{ .allocate = .alloc_always });
    defer f5.deinit();
    try testing.expect(f5.value.object.get("scenarios").?.array.items.len == 4);
}

// ── SyncDriver: the loop-shape mechanism over a scripted transport ────────────
//
// A SimWorld-style deterministic pair: the sink records what the driver sends
// (and can be toggled "down" to model a disconnect); the source replays a
// scripted inbound frame stream (and can inject one read error). No threads, no
// real socket — every tick is a pure step over injected state.

const Wire = struct {
    sent: std.ArrayList(IpcMessage) = .empty,
    inbound: std.ArrayList(IpcMessage) = .empty,
    rx: usize = 0,
    up: bool = true,
    err: bool = false,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) Wire {
        return .{ .allocator = allocator };
    }
    fn deinit(self: *Wire) void {
        self.sent.deinit(self.allocator);
        self.inbound.deinit(self.allocator);
    }
    fn pushInbound(self: *Wire, msg: IpcMessage) !void {
        try self.inbound.append(self.allocator, msg);
    }
    fn sawResyncRequest(self: Wire, from_epoch: u64) bool {
        for (self.sent.items) |m| {
            if (m == .ResyncRequest and m.ResyncRequest.from_epoch == from_epoch) return true;
        }
        return false;
    }
    fn sawOutboxAck(self: Wire, through_epoch: u64) bool {
        for (self.sent.items) |m| {
            if (m == .OutboxAck and m.OutboxAck.through_epoch == through_epoch) return true;
        }
        return false;
    }
    fn sawSnapshot(self: Wire, epoch: u64) bool {
        for (self.sent.items) |m| {
            if (m == .Snapshot and m.Snapshot.epoch == epoch) return true;
        }
        return false;
    }
    fn sawDelta(self: Wire, epoch: u64) bool {
        for (self.sent.items) |m| {
            if (m == .Delta and m.Delta.epoch == epoch) return true;
        }
        return false;
    }
};

const TestSink = struct {
    wire: *Wire,
    fn send(self: *TestSink, msg: IpcMessage) bool {
        if (!self.wire.up) return false;
        self.wire.sent.append(self.wire.allocator, msg) catch return false;
        return true;
    }
};

const TestSource = struct {
    wire: *Wire,
    fn recv(self: *TestSource) !?IpcMessage {
        if (self.wire.err) {
            self.wire.err = false;
            return error.SourceDown;
        }
        if (self.wire.rx < self.wire.inbound.items.len) {
            const m = self.wire.inbound.items[self.wire.rx];
            self.wire.rx += 1;
            return m;
        }
        return null;
    }
};

const ZeroClock = struct {
    fn nowMillis(_: *const ZeroClock) u64 {
        return 0;
    }
};

/// Provider that answers a `ResyncRequest{from}` with a snapshot at `from + 5`.
const SnapAhead = struct {
    fn snapshot(_: *const SnapAhead, from_epoch: u64) IpcMessage {
        return .{ .Snapshot = Snapshot.init(from_epoch + 5, &.{}, &.{}, &.{}) };
    }
};

const TestDriver = SyncDriver(TestSink, TestSource, InMemoryOutbox, ZeroClock, SnapAhead);

/// Owns the wire + driver so a test can drive scripted ticks and inspect the sink.
const Harness = struct {
    wire: *Wire,
    driver: TestDriver,
    allocator: std.mem.Allocator,

    fn at(allocator: std.mem.Allocator, last_epoch: u64) !Harness {
        const wire = try allocator.create(Wire);
        wire.* = Wire.init(allocator);
        const driver = TestDriver.withEpoch(
            allocator,
            .{ .wire = wire },
            .{ .wire = wire },
            InMemoryOutbox.init(allocator),
            .{},
            .{},
            last_epoch,
        );
        return .{ .wire = wire, .driver = driver, .allocator = allocator };
    }

    fn deinit(self: *Harness) void {
        self.driver.outboxPtr().deinit();
        self.driver.deinit();
        self.wire.deinit();
        self.allocator.destroy(self.wire);
    }

    fn delta(base: u64, epoch: u64) IpcMessage {
        return .{ .Delta = mkDelta(base, epoch, &.{}) };
    }
};

test "sync_driver: drains append-before-send and retains until acked" {
    const a = testing.allocator;
    var h = try Harness.at(a, 0);
    defer h.deinit();

    try h.driver.enqueue(1, Harness.delta(0, 1));
    try h.driver.enqueue(2, Harness.delta(1, 2));
    var p = try h.driver.tick();
    defer p.deinit();
    try testing.expectEqual(@as(usize, 2), p.sent); // both fresh frames pushed
    try testing.expectEqual(@as(usize, 2), h.wire.sent.items.len);
    try testing.expectEqual(@as(usize, 2), p.retained); // appended-before-send, retained
    try testing.expect(!h.driver.isStalled());

    // Peer proves receipt → the outbox prunes and the resume cursor advances.
    try h.wire.pushInbound(IpcMessage.outboxAck(2));
    var p2 = try h.driver.tick();
    defer p2.deinit();
    try testing.expectEqual(@as(u64, 2), p2.peer_acked_through);
    try testing.expectEqual(@as(usize, 0), p2.retained); // acked frames pruned
}

test "sync_driver: retains on send failure and replays on reconnect" {
    const a = testing.allocator;
    var h = try Harness.at(a, 0);
    defer h.deinit();

    h.wire.up = false; // sink down before the first send
    try h.driver.enqueue(1, Harness.delta(0, 1));
    var p = try h.driver.tick();
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.sent);
    try testing.expect(h.driver.isStalled()); // a failed send stalls the driver
    try testing.expectEqual(@as(usize, 1), p.retained); // frame retained despite failure
    try testing.expectEqual(@as(usize, 0), h.wire.sent.items.len);
    try testing.expectEqual(@as(u64, 250), h.driver.stalledFor(250)); // host backoff signal

    // Transport recovers → the unacked suffix replays from the ack cursor.
    h.wire.up = true;
    h.driver.onReconnect();
    var p2 = try h.driver.tick();
    defer p2.deinit();
    try testing.expect(!h.driver.isStalled());
    try testing.expectEqual(@as(usize, 1), p2.sent); // the retained frame is replayed
    try testing.expect(h.wire.sawDelta(1)); // the replayed delta reached the sink
}

test "sync_driver: applies delta and advertises receiver cursor" {
    const a = testing.allocator;
    var h = try Harness.at(a, 0);
    defer h.deinit();

    try h.wire.pushInbound(Harness.delta(0, 1));
    var p = try h.driver.tick();
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.applied.len); // handed to the host
    try testing.expectEqual(@as(u64, 1), h.driver.lastEpoch());
    try testing.expect(h.wire.sawOutboxAck(1)); // advertised the new cursor
}

test "sync_driver: redelivery is idempotent no-op" {
    const a = testing.allocator;
    var h = try Harness.at(a, 0);
    defer h.deinit();

    try h.wire.pushInbound(Harness.delta(0, 1));
    var p = try h.driver.tick();
    p.deinit();
    try testing.expectEqual(@as(u64, 1), h.driver.lastEpoch());

    // Re-deliver the exact same frame (an outbox replay from the peer).
    try h.wire.pushInbound(Harness.delta(0, 1));
    var p2 = try h.driver.tick();
    defer p2.deinit();
    try testing.expectEqual(@as(usize, 0), p2.applied.len); // already-applied re-delivery ignored
    try testing.expectEqual(@as(u64, 1), h.driver.lastEpoch()); // no double-advance
}

test "sync_driver: requests snapshot on inbound gap" {
    const a = testing.allocator;
    var h = try Harness.at(a, 2);
    defer h.deinit();

    try h.wire.pushInbound(Harness.delta(3, 4)); // base 3 > last 2 → gap
    var p = try h.driver.tick();
    defer p.deinit();
    try testing.expect(p.resync_requested);
    try testing.expectEqual(@as(usize, 0), p.applied.len); // gapped delta not applied
    try testing.expect(h.wire.sawResyncRequest(2)); // ResyncRequest at the current cursor
}

test "sync_driver: answers resync request with provider snapshot" {
    const a = testing.allocator;
    var h = try Harness.at(a, 0);
    defer h.deinit();

    try h.wire.pushInbound(IpcMessage.resyncRequest(2));
    var p = try h.driver.tick();
    defer p.deinit();
    try testing.expectEqual(@as(usize, 1), p.snapshots_served);
    try testing.expect(h.wire.sawSnapshot(7)); // covering snapshot (from_epoch + 5)
}

test "sync_driver: surfaces source read error" {
    const a = testing.allocator;
    var h = try Harness.at(a, 0);
    defer h.deinit();

    h.wire.err = true;
    try testing.expectError(error.SourceDown, h.driver.tick());
}

test "sync_driver: full-duplex gap then snapshot converges" {
    const a = testing.allocator;
    var h = try Harness.at(a, 1);
    defer h.deinit();
    var g = GraphModel.init(a);
    defer g.deinit();

    // Feed: apply 1->2, then a gap 3->4 (emits ResyncRequest), then Snapshot{4}.
    try h.wire.pushInbound(.{ .Delta = mkDelta(1, 2, &.{cellset(1, &.{10})}) });
    try h.wire.pushInbound(.{ .Delta = mkDelta(3, 4, &.{cellset(3, &.{30})}) });
    try h.wire.pushInbound(.{ .Snapshot = Snapshot.init(4, &.{ nodeSnap(1, &.{10}), nodeSnap(2, &.{20}), nodeSnap(3, &.{30}) }, &.{}, &.{ 1, 2, 3 }) });

    var p = try h.driver.tick();
    defer p.deinit();
    for (p.applied) |m| switch (m) {
        .Delta => |dd| try g.applyDelta(dd),
        .Snapshot => |ss| try g.applySnapshot(ss),
        else => {},
    };

    try testing.expect(p.resync_requested); // gap detected on 3->4
    try testing.expectEqual(@as(u64, 4), h.driver.lastEpoch()); // snapshot adopted
    try testing.expectEqual(@as(usize, 3), g.nodes.count());

    // A ResyncRequest{from:2} and an OutboxAck{through:4} crossed the wire.
    try testing.expect(h.wire.sawResyncRequest(2));
    try testing.expect(h.wire.sawOutboxAck(4));
}
