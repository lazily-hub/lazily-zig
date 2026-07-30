//! `IngressCore` — the graph-agnostic admission algebra behind every ingress
//! flavor (`#designimplementtransport`).
//!
//! Same split `keyed_order.zig` makes for the map family and `work_queue.zig`'s
//! lease algebra makes for the queue family, and for the same reason: deciding
//! whether an inbound envelope is *admissible* touches no reactive node and
//! awaits nothing, so the single-threaded, thread-safe, and async shells share
//! this verbatim — while **reactivity deliberately stays out**. Invalidation is a
//! graph write, so each flavor mints its own per-scope reader kinds on its own
//! graph and clears exactly the set this core reports.
//!
//! Every mutator therefore returns a [`Change`] — *which* reader kinds the
//! transition dirtied — rather than performing the invalidation itself. That
//! return value is the whole contract between the core and a shell, and it is a
//! pure function of the transition.
//!
//! # Transport-agnostic by construction
//!
//! The core never touches a transport. An envelope is a value
//! ([`IngressEnvelope`]) carrying its own provenance — `generation`, `sequence`,
//! `stamped_at` — so a WebSocket frame, an RPC response, and a polled page are
//! the *same* input once decoded. [`IngressTransportKind`] exists only to derive
//! an [`IngressSchedule`]: event delivery needs no polling, and a bounded poll
//! interval is offered only where an event channel is unavailable.
//!
//! # What is a derive and what is a call
//!
//! Readiness, authority, and retry are **not** imperative refresh calls. They are
//! pure functions of scope state ([`ScopeView.readiness`], [`ScopeView.authority`],
//! [`ScopeView.retry`]) that each shell exposes as a reactive reader. Freshness is
//! time-dependent, so it enters through an explicit [`tick`] rather than a hidden
//! clock read — the same discipline `temporal.zig` uses, and the reason staleness
//! transitions are deterministic and fixture-replayable.
//!
//! # Ownership
//!
//! Like [`KeyedOrder`](keyed_order.zig), the core stores `K` by value and does
//! **not** own slice keys: a `[]const u8` key must outlive the core.
//!
//! Spec: `../lazily-spec/docs/transport-ingress.md`. Reference implementation:
//! `../lazily-rs/src/ingress_core.rs`.

const std = @import("std");
const relay = @import("relay.zig");
const merge = @import("merge.zig");

/// The overflow algebra is the relay family's, reused verbatim: backpressure at
/// `high_water` is the same decision a `RelayCell` makes about its hot head.
pub const Overflow = relay.Overflow;
pub const MergePolicy = merge.MergePolicy;

/// Choose the hash-map implementation for key type `K`, mirroring
/// `reactive_map.zig`: `[]const u8` hashes content, everything else is auto.
pub fn HashMapFor(comptime K: type, comptime V: type) type {
    if (K == []const u8) return std.StringHashMap(V);
    return std.AutoHashMap(K, V);
}

/// How envelopes reach a scope. Event delivery is the default and needs no
/// schedule; the other two exist so a deployment without an event channel still
/// has a *bounded* fallback rather than an unbounded refresh loop.
pub const IngressTransportKind = enum {
    /// Server-initiated delivery (WebSocket, SSE, in-proc channel). Preferred.
    event_channel,
    /// Client-initiated, but triggered by an out-of-band event rather than a
    /// timer — an RPC issued *because* something happened.
    rpc_triggered,
    /// Client-initiated on a bounded interval. The fallback of last resort.
    bounded_polling,
};

/// When, if ever, a scope should ask the transport for more data.
///
/// `poll_interval` is non-null only for [`IngressTransportKind.bounded_polling`],
/// which makes "we polled a transport that pushes" unrepresentable rather than
/// merely discouraged.
pub const IngressSchedule = struct {
    kind: IngressTransportKind,
    poll_interval: ?u64,

    /// Derive the schedule for `kind`. A poll interval is offered only where
    /// event delivery is unavailable, and never zero.
    pub fn forKind(kind: IngressTransportKind, poll_interval: u64) IngressSchedule {
        return .{
            .kind = kind,
            .poll_interval = switch (kind) {
                .bounded_polling => @max(@as(u64, 1), poll_interval),
                .event_channel, .rpc_triggered => null,
            },
        };
    }
};

/// Why an envelope was refused. Every variant is a *decision*, not a failure —
/// dropping a superseded envelope is correct behaviour and is receipted as such.
pub const IngressDropReason = enum {
    /// `generation` is below the scope's fence: a zombie producer.
    stale_generation,
    /// `sequence` was already delivered in this generation.
    duplicate_sequence,
    /// `sequence` is already sitting in the reorder buffer.
    duplicate_buffered,
    /// The reorder buffer is at `reorder_window` and this envelope does not fill
    /// the gap.
    reorder_window_overflow,
    /// `now - stamped_at` exceeds the freshness horizon.
    expired,
    /// The hot window is at `high_water` under a bounding overflow policy.
    backpressure,
    /// The scope is closed; it admits nothing until reopened.
    scope_closed,
};

/// A transport- or decode-level failure attributed to a scope. Distinct from a
/// drop: an error means we could not *decide*, so it drives retry.
pub const IngressError = enum {
    /// The transport closed or reset under us.
    transport_closed,
    /// The frame could not be decoded into an envelope.
    decode_failed,
    /// The producer reported that our generation is no longer authoritative.
    authority_lost,
};

/// Where a scope is in its lifecycle. Scopes are keyed and independent: closing
/// one never touches another.
pub const IngressLifecycle = enum {
    /// Opened, nothing delivered yet.
    opening,
    /// Delivering.
    live,
    /// Disconnected but retained: state and cursors survive for replay.
    suspended,
    /// Terminal until reopened. Admits nothing.
    closed,
};

/// The derived answer to "can a consumer trust this scope right now?".
pub const IngressReadiness = enum {
    /// No such scope.
    unknown,
    /// Open, nothing delivered yet.
    warming,
    /// Delivered and inside the freshness horizon.
    ready,
    /// Delivered, but the newest accepted stamp is older than the horizon.
    stale,
    /// Disconnected; retained state may be replayed.
    suspended,
    /// Terminal.
    closed,
};

/// What the scope currently claims authority over — the fence plus the in-order
/// watermark a replay request must resume from.
pub const IngressAuthority = struct {
    generation: u64,
    /// Highest in-order sequence delivered, or `null` before first delivery.
    delivered_through: ?u64,
    /// Producer stamp of the newest delivered envelope.
    stamped_at: u64,
};

/// The derived retry decision for a scope that has errored.
pub const IngressRetry = struct {
    /// Consecutive errors since the last delivery.
    attempt: u32,
    /// Exponential backoff, clamped to the policy ceiling.
    backoff: u64,
    /// Sequence a replay should resume from.
    resume_from: u64,
};

/// What a reconnect needs from the transport to close its gap.
pub const ReplayRequest = struct {
    generation: u64,
    from_sequence: u64,
};

/// Bounds and taxes, all flavor-neutral.
pub const IngressPolicy = struct {
    /// How many out-of-order envelopes may be held per scope. `0` disables
    /// reordering: a gap drops immediately.
    reorder_window: usize = 8,
    /// `now - stamped_at` above this marks a scope [`IngressReadiness.stale`]; an
    /// *arriving* envelope that old drops as [`IngressDropReason.expired`].
    freshness_horizon: u64 = 1_000,
    /// Merged-op count at which `overflow` engages.
    high_water: u64 = 64,
    /// What to do at `high_water`.
    overflow: Overflow = .Conflate,
    /// Retained receipts, oldest evicted first.
    receipt_capacity: usize = 256,
    /// First retry backoff; doubles per consecutive error.
    retry_base: u64 = 10,
    /// Backoff clamp.
    retry_ceiling: u64 = 10_000,
};

/// Why a policy was refused at construction time.
pub const IngressConfigError = error{
    /// [`Overflow.Conflate`] chosen for a non-conflating merge policy: the
    /// coalescence cannot be the bound when `⊕` does not conflate. Validated
    /// exactly as `RelayCell.init` does.
    ConflateNotBounding,
    /// A zero receipt capacity would discard every receipt it just minted.
    ZeroReceiptCapacity,
};

/// Which receipt channel a receipt belongs to. The three are separate reader
/// kinds because they have separate consumers: a projection wants accepts, a
/// dashboard wants drops, a supervisor wants errors.
pub const IngressReceiptChannel = enum { accepted, dropped, err };

/// The decision a receipt records.
pub const IngressReceiptOutcome = union(enum) {
    accepted: struct {
        /// Highest in-order sequence delivered after this envelope.
        delivered_through: u64,
        /// Whether the payload coalesced into a non-empty window.
        conflated: bool,
    },
    dropped: IngressDropReason,
    err: IngressError,
};

/// One decoded inbound message, with the provenance admission needs.
pub fn IngressEnvelope(comptime K: type, comptime T: type) type {
    return struct {
        key: K,
        /// Producer incarnation. Monotone per key; a higher value fences lower.
        generation: u64,
        /// Position within `generation`, starting at 0.
        sequence: u64,
        /// Producer's logical timestamp, compared against the freshness horizon.
        stamped_at: u64,
        payload: T,

        pub fn init(key: K, generation: u64, sequence: u64, stamped_at: u64, payload: T) @This() {
            return .{
                .key = key,
                .generation = generation,
                .sequence = sequence,
                .stamped_at = stamped_at,
                .payload = payload,
            };
        }
    };
}

/// One durable record of an admission decision.
pub fn IngressReceipt(comptime K: type) type {
    return struct {
        /// Monotone receipt offset, stable across eviction — so a consumer can
        /// tell "I have seen everything" from "the log wrapped".
        offset: u64,
        key: K,
        generation: u64,
        sequence: ?u64,
        outcome: IngressReceiptOutcome,

        pub fn channel(self: @This()) IngressReceiptChannel {
            return switch (self.outcome) {
                .accepted => .accepted,
                .dropped => .dropped,
                .err => .err,
            };
        }
    };
}

/// A producer-incarnation handover: the fence we held, and the one we now hold.
pub const IngressHandoff = struct { from: u64, to: u64 };

/// The outcome of admitting one envelope.
pub const IngressAdmission = union(enum) {
    /// Delivered in order into an empty window.
    accepted: struct { delivered_through: u64 },
    /// Delivered in order and coalesced with at least one other op — either a
    /// prior undrained op, or a buffered successor this delivery flushed.
    conflated: struct { delivered_through: u64 },
    /// Held pending an earlier sequence. Nothing is visible yet.
    buffered: struct { gap_from: u64 },
    /// A newer producer incarnation took over: sequence expectations reset and
    /// the envelope was delivered.
    generation_handoff: IngressHandoff,
    /// Refused, with the reason receipted.
    dropped: IngressDropReason,
    /// Refused by [`Overflow.Block`]; the producer must retry after a drain.
    blocked,

    /// Whether the envelope became visible to readers.
    pub fn isDelivered(self: IngressAdmission) bool {
        return switch (self) {
            .accepted, .conflated, .generation_handoff => true,
            else => false,
        };
    }
};

/// Which of a scope's four reader kinds a transition dirtied.
///
/// Four kinds exist because they have four different invalidation boundaries: a
/// buffered envelope moves nothing but its own gap, a `tick` across the horizon
/// moves only readiness, and an error moves only retry.
pub const IngressScopeChange = struct {
    value: bool = false,
    readiness: bool = false,
    authority: bool = false,
    retry: bool = false,

    /// Nothing changed — the shell must not clear a slot.
    pub fn isEmpty(self: IngressScopeChange) bool {
        return !(self.value or self.readiness or self.authority or self.retry);
    }

    pub fn all() IngressScopeChange {
        return .{ .value = true, .readiness = true, .authority = true, .retry = true };
    }

    pub fn readinessOnly() IngressScopeChange {
        return .{ .readiness = true };
    }

    pub fn valueOnly() IngressScopeChange {
        return .{ .value = true };
    }

    pub fn retryOnly() IngressScopeChange {
        return .{ .retry = true };
    }

    /// What materializing a previously-unknown scope changes: an unknown scope
    /// reads `unknown`/`null`, so its first appearance moves readiness and
    /// authority — and nothing else. A reader that observed a key before it
    /// opened must learn that it did.
    pub fn creation() IngressScopeChange {
        return .{ .readiness = true, .authority = true };
    }

    pub fn unionWith(self: IngressScopeChange, other: IngressScopeChange) IngressScopeChange {
        return .{
            .value = self.value or other.value,
            .readiness = self.readiness or other.readiness,
            .authority = self.authority or other.authority,
            .retry = self.retry or other.retry,
        };
    }
};

/// Read-only projection of one scope, from which every derive is computed.
///
/// A shell's reader closures call these and nothing else, which is why the three
/// flavors cannot disagree about readiness, authority, or retry.
pub const ScopeView = struct {
    lifecycle: IngressLifecycle,
    generation: u64,
    delivered_through: ?u64,
    stamped_at: u64,
    /// Buffered out-of-order envelopes.
    buffered: usize,
    /// Merged ops in the hot window.
    window_depth: u64,
    consecutive_errors: u32,
    /// Logical now, as of the last [`IngressCore.tick`].
    observed_now: u64,
    policy: IngressPolicy,

    /// Whether the newest delivered stamp is inside the freshness horizon.
    pub fn isFresh(self: ScopeView) bool {
        return self.observed_now -| self.stamped_at <= self.policy.freshness_horizon;
    }

    /// Derived readiness. A scope that has never delivered is `warming`, not
    /// `stale`, because there is no stamp to be old.
    pub fn readiness(self: ScopeView) IngressReadiness {
        return switch (self.lifecycle) {
            .closed => .closed,
            .suspended => .suspended,
            .opening => .warming,
            .live => if (self.delivered_through == null)
                .warming
            else if (self.isFresh()) .ready else .stale,
        };
    }

    /// Derived authority. A closed scope claims none.
    pub fn authority(self: ScopeView) ?IngressAuthority {
        if (self.lifecycle == .closed) return null;
        return .{
            .generation = self.generation,
            .delivered_through = self.delivered_through,
            .stamped_at = self.stamped_at,
        };
    }

    /// The first sequence not yet delivered in order.
    pub fn resumeFrom(self: ScopeView) u64 {
        return if (self.delivered_through) |seq| seq + 1 else 0;
    }

    /// Whether the scope is holding a gap open — an out-of-order buffer that a
    /// replay, not a retry, is the fix for.
    pub fn hasGap(self: ScopeView) bool {
        return self.buffered > 0;
    }

    /// Derived retry. `null` while no error is outstanding — a healthy scope has
    /// no backoff, rather than a zero one.
    pub fn retry(self: ScopeView) ?IngressRetry {
        if (self.consecutive_errors == 0) return null;
        const shift: u6 = @intCast(@min(@as(u32, 31), self.consecutive_errors -| 1));
        const doubled = std.math.mul(u64, self.policy.retry_base, @as(u64, 1) << shift) catch
            std.math.maxInt(u64);
        return .{
            .attempt = self.consecutive_errors,
            .backoff = @min(doubled, self.policy.retry_ceiling),
            .resume_from = self.resumeFrom(),
        };
    }
};

/// Keyed lifecycle scopes, an admission algebra, and a bounded receipt log. No
/// reactive context, no handles, no interior mutability — each flavor wraps this
/// in its own lock.
pub fn IngressCore(comptime K: type, comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Envelope = IngressEnvelope(K, T);
        pub const Receipt = IngressReceipt(K);

        /// One `(key, dirtied reader kinds)` pair.
        pub const ScopeDelta = struct { key: K, change: IngressScopeChange };

        /// The pure invalidation set of one transition: the whole contract
        /// between the core and a flavor shell.
        ///
        /// `scopes` aliases the core's reusable scratch buffer and is valid only
        /// until the next mutator call — the shell consumes it immediately, which
        /// is what keeps the algebra allocation-quiet on the hot path.
        pub const Change = struct {
            scopes: []const ScopeDelta = &.{},
            /// The accepted-receipt reader grew.
            accepted_receipts: bool = false,
            /// The dropped-receipt reader grew.
            dropped_receipts: bool = false,
            /// The error-receipt reader grew.
            error_receipts: bool = false,

            pub fn isEmpty(self: Change) bool {
                return self.scopes.len == 0 and
                    !self.accepted_receipts and
                    !self.dropped_receipts and
                    !self.error_receipts;
            }
        };

        pub const SuspendResult = struct { change: Change, replay: ?ReplayRequest };
        pub const ReconnectResult = struct { change: Change, replay: ReplayRequest };
        pub const DrainResult = struct { change: Change, value: ?T };
        pub const AdmitResult = struct { change: Change, admission: IngressAdmission };

        const Pending = struct { sequence: u64, payload: T, stamped_at: u64 };

        /// Everything a reader can observe *about shape rather than payload*. The
        /// buffered path diffs these to derive its invalidation set, so "a
        /// buffered envelope invalidates nothing" is a computed fact rather than a
        /// claim — and the handoff-that-buffers case (which clears the window)
        /// cannot slip through.
        const Stamp = struct {
            lifecycle: IngressLifecycle,
            generation: u64,
            delivered_through: ?u64,
            has_window: bool,
        };

        const Scope = struct {
            lifecycle: IngressLifecycle = .opening,
            generation: u64,
            delivered_through: ?u64 = null,
            stamped_at: u64 = 0,
            /// Out-of-order envelopes, kept sorted by `sequence`. Bounded by
            /// `policy.reorder_window`, so a linear ordered insert is cheaper
            /// than a tree.
            pending: std.ArrayList(Pending) = .empty,
            window: ?T = null,
            window_depth: u64 = 0,
            consecutive_errors: u32 = 0,

            fn init(generation: u64) Scope {
                return .{ .generation = generation };
            }

            fn deinit(self: *Scope, allocator: std.mem.Allocator) void {
                self.pending.deinit(allocator);
            }

            fn view(self: *const Scope, observed_now: u64, policy: IngressPolicy) ScopeView {
                return .{
                    .lifecycle = self.lifecycle,
                    .generation = self.generation,
                    .delivered_through = self.delivered_through,
                    .stamped_at = self.stamped_at,
                    .buffered = self.pending.items.len,
                    .window_depth = self.window_depth,
                    .consecutive_errors = self.consecutive_errors,
                    .observed_now = observed_now,
                    .policy = policy,
                };
            }

            fn nextExpected(self: *const Scope) u64 {
                return if (self.delivered_through) |seq| seq + 1 else 0;
            }

            fn stamp(self: *const Scope) Stamp {
                return .{
                    .lifecycle = self.lifecycle,
                    .generation = self.generation,
                    .delivered_through = self.delivered_through,
                    .has_window = self.window != null,
                };
            }

            fn liveOrOpening(self: *const Scope) IngressLifecycle {
                return if (self.delivered_through != null) .live else .opening;
            }

            fn buffered(self: *const Scope, sequence: u64) bool {
                for (self.pending.items) |p| {
                    if (p.sequence == sequence) return true;
                }
                return false;
            }

            fn takeBuffered(self: *Scope, sequence: u64) ?Pending {
                for (self.pending.items, 0..) |p, i| {
                    if (p.sequence == sequence) return self.pending.orderedRemove(i);
                }
                return null;
            }

            fn insertBuffered(self: *Scope, allocator: std.mem.Allocator, item: Pending) !void {
                var at: usize = self.pending.items.len;
                for (self.pending.items, 0..) |p, i| {
                    if (p.sequence > item.sequence) {
                        at = i;
                        break;
                    }
                }
                try self.pending.insert(allocator, at, item);
            }

            /// Discard the superseded incarnation's buffered successors AND its
            /// undrained window. A handoff is a baseline reset, not a
            /// continuation.
            fn resetBaseline(self: *Scope, generation: u64) void {
                self.generation = generation;
                self.delivered_through = null;
                self.pending.clearRetainingCapacity();
                self.window = null;
                self.window_depth = 0;
            }
        };

        /// What the admission algebra decided, before any receipt is minted.
        const Decision = union(enum) {
            refuse: IngressDropReason,
            block,
            buffered: struct { gap_from: u64 },
            delivered: struct {
                delivered_through: u64,
                conflated: bool,
                handoff: ?IngressHandoff,
            },
        };

        allocator: std.mem.Allocator,
        policy: IngressPolicy,
        merge_policy: MergePolicy(T),
        scopes: HashMapFor(K, Scope),
        receipts: std.ArrayList(Receipt) = .empty,
        next_receipt_offset: u64 = 0,
        observed_now: u64 = 0,
        /// Reusable buffer the returned `Change.scopes` slices point into.
        delta_scratch: std.ArrayList(ScopeDelta) = .empty,

        /// Build a core over `policy`, validating the overflow choice against the
        /// merge algebra the way `RelayCell.init` does: `Conflate` bounds nothing
        /// for a non-conflating `⊕`.
        pub fn init(
            allocator: std.mem.Allocator,
            policy: IngressPolicy,
            merge_policy: MergePolicy(T),
        ) IngressConfigError!Self {
            if (policy.overflow == .Conflate and !merge_policy.conflates) {
                return IngressConfigError.ConflateNotBounding;
            }
            if (policy.receipt_capacity == 0) return IngressConfigError.ZeroReceiptCapacity;
            return .{
                .allocator = allocator,
                .policy = policy,
                .merge_policy = merge_policy,
                .scopes = HashMapFor(K, Scope).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.scopes.valueIterator();
            while (it.next()) |scope| scope.deinit(self.allocator);
            self.scopes.deinit();
            self.receipts.deinit(self.allocator);
            self.delta_scratch.deinit(self.allocator);
        }

        // --- reads -----------------------------------------------------------

        /// Read-only projection of one scope, or `null` when unknown.
        pub fn view(self: *const Self, key: K) ?ScopeView {
            const scope = self.scopes.getPtr(key) orelse return null;
            return scope.view(self.observed_now, self.policy);
        }

        /// Readiness of a scope. Unknown scopes read `unknown` rather than an
        /// error: a reader may legitimately observe a key before it opens.
        pub fn readiness(self: *const Self, key: K) IngressReadiness {
            const v = self.view(key) orelse return .unknown;
            return v.readiness();
        }

        pub fn authority(self: *const Self, key: K) ?IngressAuthority {
            const v = self.view(key) orelse return null;
            return v.authority();
        }

        pub fn retry(self: *const Self, key: K) ?IngressRetry {
            const v = self.view(key) orelse return null;
            return v.retry();
        }

        /// The coalesced window awaiting drain.
        pub fn peek(self: *const Self, key: K) ?T {
            const scope = self.scopes.getPtr(key) orelse return null;
            return scope.window;
        }

        /// Retained receipts on one channel, oldest first. Counting is the shape
        /// every reader needs; the slice form stays available for consumers that
        /// want the payloads.
        pub fn receiptCount(self: *const Self, channel: IngressReceiptChannel) usize {
            var n: usize = 0;
            for (self.receipts.items) |receipt| {
                if (receipt.channel() == channel) n += 1;
            }
            return n;
        }

        /// Every retained receipt, oldest first, across all three channels.
        pub fn receiptLog(self: *const Self) []const Receipt {
            return self.receipts.items;
        }

        pub fn scopeCount(self: *const Self) usize {
            return self.scopes.count();
        }

        pub fn observedNow(self: *const Self) u64 {
            return self.observed_now;
        }

        // --- change bookkeeping ---------------------------------------------

        fn beginChange(self: *Self) void {
            self.delta_scratch.clearRetainingCapacity();
        }

        fn mark(self: *Self, key: K, change: IngressScopeChange) !void {
            if (change.isEmpty()) return;
            try self.delta_scratch.append(self.allocator, .{ .key = key, .change = change });
        }

        fn deltas(self: *const Self) []const ScopeDelta {
            return self.delta_scratch.items;
        }

        // --- lifecycle -------------------------------------------------------

        /// Open (or reopen) a scope at `generation`.
        ///
        /// Reopening a suspended scope preserves its watermark so a replay can
        /// resume from the gap; reopening a *closed* scope resets it, because a
        /// closed scope's producer is gone and its sequence space is not
        /// resumable.
        pub fn open(self: *Self, key: K, generation: u64) !Change {
            self.beginChange();
            const entry = try self.scopes.getOrPut(key);
            if (!entry.found_existing) {
                entry.value_ptr.* = Scope.init(generation);
                try self.mark(key, IngressScopeChange.creation());
                return .{ .scopes = self.deltas() };
            }
            const scope = entry.value_ptr;
            const before = scope.stamp();
            if (scope.lifecycle == .closed) {
                // A closed scope's producer is gone and its sequence space is not
                // resumable, so reopening resets the baseline. The `pending`
                // buffer's capacity is retained rather than reassigned — a struct
                // literal here would leak it.
                scope.pending.clearRetainingCapacity();
                scope.lifecycle = .opening;
                scope.generation = generation;
                scope.delivered_through = null;
                scope.stamped_at = 0;
                scope.window = null;
                scope.window_depth = 0;
                scope.consecutive_errors = 0;
            } else {
                scope.lifecycle = scope.liveOrOpening();
                if (generation > scope.generation) {
                    scope.generation = generation;
                    scope.delivered_through = null;
                    scope.pending.clearRetainingCapacity();
                }
            }
            const after = scope.stamp();
            if (!std.meta.eql(before, after)) {
                try self.mark(key, .{
                    .value = before.has_window != after.has_window,
                    .readiness = before.lifecycle != after.lifecycle,
                    .authority = true,
                });
            }
            return .{ .scopes = self.deltas() };
        }

        /// Suspend a scope: retain state and cursors, stop delivering. Returns
        /// the replay request a reconnect will need, or `null` when there was
        /// nothing to suspend.
        pub fn suspendScope(self: *Self, key: K) !SuspendResult {
            self.beginChange();
            const scope = self.scopes.getPtr(key) orelse
                return .{ .change = .{}, .replay = null };
            if (scope.lifecycle == .suspended or scope.lifecycle == .closed) {
                return .{ .change = .{}, .replay = null };
            }
            scope.lifecycle = .suspended;
            const request: ReplayRequest = .{
                .generation = scope.generation,
                .from_sequence = scope.nextExpected(),
            };
            try self.mark(key, IngressScopeChange.readinessOnly());
            return .{ .change = .{ .scopes = self.deltas() }, .replay = request };
        }

        /// Reconnect a scope at `generation`, clearing the error streak.
        ///
        /// A higher generation is a producer handoff: the sequence space
        /// restarts, so the buffered reorder window and the coalesced value are
        /// discarded rather than replayed against a fence they no longer belong
        /// to. One rule, two entry points — `admit` applies the same reset.
        pub fn reconnect(self: *Self, key: K, generation: u64) !ReconnectResult {
            self.beginChange();
            const entry = try self.scopes.getOrPut(key);
            const created = !entry.found_existing;
            if (created) entry.value_ptr.* = Scope.init(generation);
            const scope = entry.value_ptr;

            const handoff = generation > scope.generation;
            const had_window = scope.window != null;
            if (handoff) scope.resetBaseline(generation);
            const before_lifecycle = scope.lifecycle;
            scope.lifecycle = scope.liveOrOpening();
            const had_errors = scope.consecutive_errors > 0;
            scope.consecutive_errors = 0;
            const request: ReplayRequest = .{
                .generation = scope.generation,
                .from_sequence = scope.nextExpected(),
            };
            var change: IngressScopeChange = .{
                .value = handoff and had_window,
                .readiness = before_lifecycle != scope.lifecycle,
                .authority = handoff,
                .retry = had_errors,
            };
            if (created) change = change.unionWith(IngressScopeChange.creation());
            try self.mark(key, change);
            return .{ .change = .{ .scopes = self.deltas() }, .replay = request };
        }

        /// Close a scope. It admits nothing and claims no authority until
        /// reopened.
        pub fn close(self: *Self, key: K) !Change {
            self.beginChange();
            const scope = self.scopes.getPtr(key) orelse return .{};
            if (scope.lifecycle == .closed) return .{};
            const had_window = scope.window != null;
            const had_errors = scope.consecutive_errors > 0;
            scope.lifecycle = .closed;
            scope.pending.clearRetainingCapacity();
            scope.window = null;
            scope.window_depth = 0;
            scope.consecutive_errors = 0;
            try self.mark(key, .{
                .value = had_window,
                .readiness = true,
                .authority = true,
                .retry = had_errors,
            });
            return .{ .scopes = self.deltas() };
        }

        /// Advance logical time. Only scopes that *crossed* the freshness horizon
        /// are dirtied — a tick inside the horizon invalidates nothing, which is
        /// what keeps a polling shell from re-rendering on every tick.
        pub fn tick(self: *Self, now: u64) !Change {
            self.beginChange();
            if (now == self.observed_now) return .{};
            const before = self.observed_now;
            self.observed_now = now;
            const policy = self.policy;
            var it = self.scopes.iterator();
            while (it.next()) |entry| {
                const scope = entry.value_ptr;
                if (scope.view(before, policy).readiness() != scope.view(now, policy).readiness()) {
                    try self.mark(keyOf(entry), IngressScopeChange.readinessOnly());
                }
            }
            return .{ .scopes = self.deltas() };
        }

        /// Record a transport/decode failure against a scope, deepening its
        /// backoff.
        pub fn fail(self: *Self, key: K, err: IngressError) !Change {
            self.beginChange();
            const entry = try self.scopes.getOrPut(key);
            const created = !entry.found_existing;
            if (created) entry.value_ptr.* = Scope.init(0);
            const scope = entry.value_ptr;
            scope.consecutive_errors +|= 1;
            const generation = scope.generation;
            var change = IngressScopeChange.retryOnly();
            if (created) change = change.unionWith(IngressScopeChange.creation());
            try self.mark(key, change);
            const channel = try self.pushReceipt(.{
                .offset = 0,
                .key = key,
                .generation = generation,
                .sequence = null,
                .outcome = .{ .err = err },
            });
            var out: Change = .{ .scopes = self.deltas() };
            markChannel(&out, channel);
            return out;
        }

        /// Drain a scope's coalesced window, resetting its depth. Returns `null`
        /// for an empty window and dirties nothing.
        ///
        /// A drain is an *egress*, not an ack: it never moves the watermark, so a
        /// replay after a drain still resumes from the same sequence.
        pub fn drain(self: *Self, key: K) !DrainResult {
            self.beginChange();
            const scope = self.scopes.getPtr(key) orelse
                return .{ .change = .{}, .value = null };
            const value = scope.window;
            if (value == null) return .{ .change = .{}, .value = null };
            scope.window = null;
            scope.window_depth = 0;
            try self.mark(key, IngressScopeChange.valueOnly());
            return .{ .change = .{ .scopes = self.deltas() }, .value = value };
        }

        // --- admission -------------------------------------------------------

        /// Admit one envelope, applying — in this order — scope lifecycle, the
        /// generation fence, freshness, generation handoff, dedupe, ordering,
        /// backpressure, and merge.
        ///
        /// The order is the contract: a zombie generation is rejected before its
        /// stale sequence is consulted, and an expired envelope is rejected
        /// before it can occupy a reorder slot.
        pub fn admit(self: *Self, envelope: Envelope) !AdmitResult {
            self.beginChange();
            const key = envelope.key;

            const before: ?Stamp = if (self.scopes.getPtr(key)) |s| s.stamp() else null;
            const created = before == null;

            const entry = try self.scopes.getOrPut(key);
            if (!entry.found_existing) entry.value_ptr.* = Scope.init(envelope.generation);
            const decision = try self.decide(entry.value_ptr, envelope);

            // A refused envelope must not leave a scope behind: an expired or
            // blocked message for a key we do not track is not an admission
            // plane, and materializing one would report a readiness change that
            // never happened.
            const admitted = switch (decision) {
                .buffered, .delivered => true,
                else => false,
            };
            if (created and !admitted) {
                if (self.scopes.getPtr(key)) |s| s.deinit(self.allocator);
                _ = self.scopes.remove(key);
            }

            const fence = if (self.scopes.getPtr(key)) |s| s.generation else envelope.generation;

            switch (decision) {
                .refuse => |reason| {
                    const channel = try self.pushReceipt(.{
                        .offset = 0,
                        .key = key,
                        .generation = fence,
                        .sequence = envelope.sequence,
                        .outcome = .{ .dropped = reason },
                    });
                    var out: Change = .{};
                    markChannel(&out, channel);
                    return .{ .change = out, .admission = .{ .dropped = reason } };
                },
                .block => {
                    const channel = try self.pushReceipt(.{
                        .offset = 0,
                        .key = key,
                        .generation = fence,
                        .sequence = envelope.sequence,
                        .outcome = .{ .dropped = .backpressure },
                    });
                    var out: Change = .{};
                    markChannel(&out, channel);
                    return .{ .change = out, .admission = .blocked };
                },
                .buffered => |b| {
                    // A buffered envelope mints no receipt, and for an
                    // already-current scope it dirties no reader, because nothing
                    // a reader can observe moved. Two cases are NOT invisible and
                    // are DERIVED rather than assumed: the scope's own first
                    // appearance (it moves off `unknown`), and a generation
                    // handoff that buffers — which resets the fence, the
                    // watermark, and the window before parking the envelope.
                    var change: IngressScopeChange = if (created)
                        IngressScopeChange.creation()
                    else
                        .{};
                    if (before) |b0| {
                        if (self.scopes.getPtr(key)) |s| {
                            const a0 = s.stamp();
                            change = change.unionWith(.{
                                .value = b0.has_window != a0.has_window,
                                .readiness = b0.lifecycle != a0.lifecycle or
                                    (b0.delivered_through == null) != (a0.delivered_through == null),
                                .authority = b0.generation != a0.generation or
                                    !std.meta.eql(b0.delivered_through, a0.delivered_through),
                            });
                        }
                    }
                    try self.mark(key, change);
                    return .{
                        .change = .{ .scopes = self.deltas() },
                        .admission = .{ .buffered = .{ .gap_from = b.gap_from } },
                    };
                },
                .delivered => |d| {
                    try self.mark(key, IngressScopeChange.all());
                    const channel = try self.pushReceipt(.{
                        .offset = 0,
                        .key = key,
                        .generation = fence,
                        .sequence = envelope.sequence,
                        .outcome = .{ .accepted = .{
                            .delivered_through = d.delivered_through,
                            .conflated = d.conflated,
                        } },
                    });
                    var out: Change = .{ .scopes = self.deltas() };
                    markChannel(&out, channel);
                    const admission: IngressAdmission = if (d.handoff) |h|
                        .{ .generation_handoff = .{ .from = h.from, .to = h.to } }
                    else if (d.conflated)
                        .{ .conflated = .{ .delivered_through = d.delivered_through } }
                    else
                        .{ .accepted = .{ .delivered_through = d.delivered_through } };
                    return .{ .change = out, .admission = admission };
                },
            }
        }

        /// The admission algebra proper: pure over one scope, mutating only that
        /// scope, minting nothing.
        fn decide(self: *Self, scope: *Scope, envelope: Envelope) !Decision {
            const policy = self.policy;

            // 1. lifecycle.
            if (scope.lifecycle == .closed) return .{ .refuse = .scope_closed };

            // 2. generation fence. BEFORE dedupe: a zombie producer replaying old
            //    sequences under an old generation must be distinguishable from a
            //    legitimate retry. Testing the sequence first would report
            //    `duplicate_sequence` and hide the zombie.
            if (envelope.generation < scope.generation) return .{ .refuse = .stale_generation };

            // 3. freshness. BEFORE ordering: an expired envelope must never
            //    occupy a reorder slot, or a slow zombie can exhaust the buffer
            //    and starve live data.
            if (self.observed_now -| envelope.stamped_at > policy.freshness_horizon) {
                return .{ .refuse = .expired };
            }

            // 4. generation handoff — a baseline reset, not a continuation.
            var handoff: ?IngressHandoff = null;
            if (envelope.generation > scope.generation) {
                handoff = .{ .from = scope.generation, .to = envelope.generation };
                scope.resetBaseline(envelope.generation);
            }

            const expected = scope.nextExpected();

            // 5. dedupe.
            if (envelope.sequence < expected) return .{ .refuse = .duplicate_sequence };

            // 6. ordering.
            if (envelope.sequence > expected) {
                if (scope.buffered(envelope.sequence)) return .{ .refuse = .duplicate_buffered };
                if (scope.pending.items.len >= policy.reorder_window) {
                    return .{ .refuse = .reorder_window_overflow };
                }
                try scope.insertBuffered(self.allocator, .{
                    .sequence = envelope.sequence,
                    .payload = envelope.payload,
                    .stamped_at = envelope.stamped_at,
                });
                return .{ .buffered = .{ .gap_from = expected } };
            }

            // 7. backpressure. Checked here and not earlier: refusing an in-order
            //    envelope leaves a gap the reorder buffer cannot close, so `Block`
            //    must be observable by the producer as its own outcome.
            if (scope.window_depth >= policy.high_water) {
                switch (policy.overflow) {
                    // Refuse WITHOUT advancing the watermark, which is what makes
                    // the producer's retry in-order rather than a duplicate.
                    .Block => return .block,
                    .DropNewest => return .{ .refuse = .backpressure },
                    .DropOldest => {
                        scope.window = null;
                        scope.window_depth = 0;
                    },
                    // `Conflate` *is* the bound; `Spill` degrades to it until a
                    // durable tail is wired, exactly as `RelayCell` does.
                    .Conflate, .Spill => {},
                }
            }

            // 8. merge.
            var conflated = self.mergeInto(scope, envelope.payload, envelope.stamped_at);
            scope.delivered_through = envelope.sequence;
            scope.lifecycle = .live;
            scope.consecutive_errors = 0;
            var delivered_through = envelope.sequence;

            // Flush every buffered successor this delivery unblocked. One
            // invalidation covers the whole flush: readers observe the coalesced
            // window, never a partial replay. The buffer replays in SEQUENCE
            // order, which is why a merely associative `⊕` converges to the
            // in-order fold (`reorder_needs_no_commutativity`).
            while (true) {
                const next = scope.nextExpected();
                const item = scope.takeBuffered(next) orelse break;
                conflated = self.mergeInto(scope, item.payload, item.stamped_at) or conflated;
                scope.delivered_through = next;
                delivered_through = next;
            }

            return .{ .delivered = .{
                .delivered_through = delivered_through,
                .conflated = conflated,
                .handoff = handoff,
            } };
        }

        /// Merge one payload into a scope's hot head. Returns whether it
        /// coalesced with an existing window.
        fn mergeInto(self: *Self, scope: *Scope, payload: T, stamped_at: u64) bool {
            const conflated = if (scope.window) |current| blk: {
                scope.window = self.merge_policy.merge(current, payload);
                break :blk true;
            } else blk: {
                scope.window = payload;
                break :blk false;
            };
            scope.window_depth += 1;
            scope.stamped_at = @max(scope.stamped_at, stamped_at);
            return conflated;
        }

        fn pushReceipt(self: *Self, receipt_in: Receipt) !IngressReceiptChannel {
            var receipt = receipt_in;
            receipt.offset = self.next_receipt_offset;
            self.next_receipt_offset += 1;
            const channel = receipt.channel();
            try self.receipts.append(self.allocator, receipt);
            while (self.receipts.items.len > self.policy.receipt_capacity) {
                _ = self.receipts.orderedRemove(0);
            }
            return channel;
        }

        fn markChannel(change: *Change, channel: IngressReceiptChannel) void {
            switch (channel) {
                .accepted => change.accepted_receipts = true,
                .dropped => change.dropped_receipts = true,
                .err => change.error_receipts = true,
            }
        }

        /// `StringHashMap` and `AutoHashMap` expose the same iterator shape, so
        /// one accessor covers both instantiations.
        fn keyOf(entry: anytype) K {
            return entry.key_ptr.*;
        }
    };
}

// ---------------------------------------------------------------------------
// Unit tests — one per named invariant, mirroring the `#[cfg(test)]` tail of
// lazily-rs `src/ingress_core.rs`.
// ---------------------------------------------------------------------------

const testing = std.testing;

const Core = IngressCore([]const u8, u64);

fn sumCore(policy: IngressPolicy) !Core {
    return Core.init(testing.allocator, policy, merge.sum(u64));
}

fn env(
    key: []const u8,
    generation: u64,
    sequence: u64,
    stamped_at: u64,
    payload: u64,
) Core.Envelope {
    return Core.Envelope.init(key, generation, sequence, stamped_at, payload);
}

test "lazily/ingress_core: Conflate is rejected for a non-conflating algebra" {
    // A non-conflating `⊕` over `u64`, matching relay.zig's `rawFifoLike` spike.
    const raw: MergePolicy(u64) = .{
        .name = "RawFifo",
        .merge = struct {
            fn f(_: u64, op: u64) u64 {
                return op;
            }
        }.f,
        .commutative = false,
        .idempotent = false,
        .conflates = false,
    };
    try testing.expectError(
        IngressConfigError.ConflateNotBounding,
        Core.init(testing.allocator, .{ .overflow = .Conflate }, raw),
    );
}

test "lazily/ingress_core: a zero receipt capacity is rejected" {
    try testing.expectError(
        IngressConfigError.ZeroReceiptCapacity,
        Core.init(testing.allocator, .{ .receipt_capacity = 0 }, merge.sum(u64)),
    );
}

test "lazily/ingress_core: in-order delivery conflates and receipts" {
    var core = try sumCore(.{});
    defer core.deinit();

    const first = try core.admit(env("a", 1, 0, 0, 5));
    try testing.expectEqual(@as(u64, 0), first.admission.accepted.delivered_through);
    try testing.expect(first.change.accepted_receipts);
    try testing.expectEqual(@as(usize, 1), first.change.scopes.len);
    try testing.expectEqual(IngressScopeChange.all(), first.change.scopes[0].change);

    const second = try core.admit(env("a", 1, 1, 0, 7));
    try testing.expectEqual(@as(u64, 1), second.admission.conflated.delivered_through);
    try testing.expectEqual(@as(?u64, 12), core.peek("a"));
    try testing.expectEqual(@as(usize, 2), core.receiptCount(.accepted));
    try testing.expectEqual(@as(usize, 0), core.receiptCount(.dropped));
}

test "lazily/ingress_core: reorder buffers then flushes in one invalidation" {
    var core = try sumCore(.{});
    defer core.deinit();

    const parked = try core.admit(env("a", 1, 2, 0, 4));
    try testing.expectEqual(@as(u64, 0), parked.admission.buffered.gap_from);
    // A buffered envelope mints no receipt and moves no value. The scope's first
    // appearance DOES move it off `unknown`, and saying so is the difference
    // between a sound invalidation set and a reader stuck on `unknown` forever.
    try testing.expect(!parked.change.accepted_receipts and !parked.change.dropped_receipts);
    try testing.expectEqual(@as(usize, 1), parked.change.scopes.len);
    try testing.expectEqual(IngressScopeChange.creation(), parked.change.scopes[0].change);
    try testing.expectEqual(@as(?u64, null), core.peek("a"));

    // Now the scope exists, so a second buffered envelope really is invisible.
    const again = try core.admit(env("a", 1, 1, 0, 2));
    try testing.expect(again.change.isEmpty());

    const flush = try core.admit(env("a", 1, 0, 0, 1));
    // Three ops coalesced, so the delivery reports `conflated` even though the
    // window it started from was empty.
    try testing.expectEqual(@as(u64, 2), flush.admission.conflated.delivered_through);
    // 1 ⊕ 2 ⊕ 4 — the whole flush lands as one window.
    try testing.expectEqual(@as(?u64, 7), core.peek("a"));
    try testing.expectEqual(@as(usize, 0), core.view("a").?.buffered);
    try testing.expectEqual(@as(usize, 1), core.receiptCount(.accepted));
}

test "lazily/ingress_core: duplicates drop after delivery and while buffered" {
    var core = try sumCore(.{});
    defer core.deinit();
    _ = try core.admit(env("a", 1, 0, 0, 1));
    const dup = try core.admit(env("a", 1, 0, 0, 1));
    try testing.expectEqual(IngressDropReason.duplicate_sequence, dup.admission.dropped);
    _ = try core.admit(env("a", 1, 5, 0, 1));
    const dup_buffered = try core.admit(env("a", 1, 5, 0, 1));
    try testing.expectEqual(IngressDropReason.duplicate_buffered, dup_buffered.admission.dropped);
    try testing.expectEqual(@as(?u64, 1), core.peek("a"));
}

test "lazily/ingress_core: reorder-window overflow drops rather than growing" {
    var core = try sumCore(.{ .reorder_window = 2 });
    defer core.deinit();
    _ = try core.admit(env("a", 1, 1, 0, 1));
    _ = try core.admit(env("a", 1, 2, 0, 1));
    const over = try core.admit(env("a", 1, 3, 0, 1));
    try testing.expectEqual(IngressDropReason.reorder_window_overflow, over.admission.dropped);
    try testing.expectEqual(@as(usize, 2), core.view("a").?.buffered);
}

test "lazily/ingress_core: a zero reorder window drops every gap immediately" {
    var core = try sumCore(.{ .reorder_window = 0 });
    defer core.deinit();
    const gap = try core.admit(env("a", 1, 1, 0, 1));
    try testing.expectEqual(IngressDropReason.reorder_window_overflow, gap.admission.dropped);
}

test "lazily/ingress_core: a stale generation is fenced before its sequence is consulted" {
    var core = try sumCore(.{});
    defer core.deinit();
    _ = try core.admit(env("a", 2, 0, 0, 1));
    // Sequence 0 would be a duplicate; generation 1 is stale. The fence wins,
    // which is what makes a zombie producer distinguishable from a retry.
    const zombie = try core.admit(env("a", 1, 0, 0, 9));
    try testing.expectEqual(IngressDropReason.stale_generation, zombie.admission.dropped);
    try testing.expectEqual(@as(?u64, 1), core.peek("a"));
}

test "lazily/ingress_core: a newer generation hands off and resets the sequence space" {
    var core = try sumCore(.{});
    defer core.deinit();
    _ = try core.admit(env("a", 1, 0, 0, 1));
    _ = try core.admit(env("a", 1, 7, 0, 1));
    const handoff = try core.admit(env("a", 2, 0, 0, 4));
    try testing.expectEqual(@as(u64, 1), handoff.admission.generation_handoff.from);
    try testing.expectEqual(@as(u64, 2), handoff.admission.generation_handoff.to);
    const v = core.view("a").?;
    try testing.expectEqual(@as(u64, 2), v.generation);
    try testing.expectEqual(@as(?u64, 0), v.delivered_through);
    // The old generation's buffered successor is not replayed under the new
    // fence — its sequence numbers mean something else now.
    try testing.expectEqual(@as(usize, 0), v.buffered);
    // Nor is its undrained window folded into the new baseline.
    try testing.expectEqual(@as(?u64, 4), core.peek("a"));
}

test "lazily/ingress_core: a handoff that buffers still reports the baseline reset" {
    // Reporting this as "buffered, nothing changed" would leave every reader
    // showing the superseded generation's value forever.
    var core = try sumCore(.{});
    defer core.deinit();
    _ = try core.admit(env("a", 1, 0, 0, 5));
    const parked = try core.admit(env("a", 2, 3, 0, 9));
    try testing.expectEqual(@as(u64, 0), parked.admission.buffered.gap_from);
    try testing.expectEqual(@as(usize, 1), parked.change.scopes.len);
    try testing.expectEqual(
        IngressScopeChange{ .value = true, .readiness = true, .authority = true, .retry = false },
        parked.change.scopes[0].change,
    );
    try testing.expectEqual(@as(?u64, null), core.peek("a"));
    const v = core.view("a").?;
    try testing.expectEqual(@as(u64, 2), v.generation);
    try testing.expectEqual(@as(?u64, null), v.delivered_through);
    try testing.expectEqual(@as(usize, 1), v.buffered);
    // A buffered envelope under the SAME generation is still invisible.
    const same = try core.admit(env("a", 2, 4, 0, 1));
    try testing.expect(same.change.isEmpty());
}

test "lazily/ingress_core: an expired envelope never occupies a reorder slot" {
    var core = try sumCore(.{ .freshness_horizon = 10, .reorder_window = 1 });
    defer core.deinit();
    _ = try core.tick(100);
    const expired = try core.admit(env("a", 1, 3, 50, 1));
    try testing.expectEqual(IngressDropReason.expired, expired.admission.dropped);
    // A refused envelope leaves no scope behind.
    try testing.expectEqual(@as(?ScopeView, null), core.view("a"));
    // The slot is still free for a fresh out-of-order envelope.
    const fresh = try core.admit(env("a", 1, 3, 95, 1));
    try testing.expectEqual(@as(u64, 0), fresh.admission.buffered.gap_from);
}

test "lazily/ingress_core: Block refuses without losing the window or moving the watermark" {
    var core = try Core.init(
        testing.allocator,
        .{ .high_water = 1, .overflow = .Block },
        merge.keepLatest(u64),
    );
    defer core.deinit();
    _ = try core.admit(env("a", 1, 0, 0, 5));
    const blocked = try core.admit(env("a", 1, 1, 0, 9));
    try testing.expectEqual(IngressAdmission.blocked, blocked.admission);
    try testing.expect(blocked.change.dropped_receipts);
    try testing.expectEqual(@as(?u64, 5), core.peek("a"));
    // The blocked envelope did not advance the watermark, so a producer retry
    // after a drain is still in order rather than a duplicate.
    try testing.expectEqual(@as(?u64, 0), core.view("a").?.delivered_through);
    _ = try core.drain("a");
    const retried = try core.admit(env("a", 1, 1, 0, 9));
    try testing.expectEqual(@as(u64, 1), retried.admission.accepted.delivered_through);
}

test "lazily/ingress_core: DropOldest restarts the window at the incoming op" {
    var core = try Core.init(
        testing.allocator,
        .{ .high_water = 2, .overflow = .DropOldest },
        merge.sum(u64),
    );
    defer core.deinit();
    _ = try core.admit(env("a", 1, 0, 0, 1));
    _ = try core.admit(env("a", 1, 1, 0, 2));
    const restart = try core.admit(env("a", 1, 2, 0, 30));
    try testing.expectEqual(@as(u64, 2), restart.admission.accepted.delivered_through);
    try testing.expectEqual(@as(?u64, 30), core.peek("a"));
}

test "lazily/ingress_core: DropNewest keeps the window and receipts the drop" {
    var core = try Core.init(
        testing.allocator,
        .{ .high_water = 1, .overflow = .DropNewest },
        merge.sum(u64),
    );
    defer core.deinit();
    _ = try core.admit(env("a", 1, 0, 0, 5));
    const dropped = try core.admit(env("a", 1, 1, 0, 9));
    try testing.expectEqual(IngressDropReason.backpressure, dropped.admission.dropped);
    try testing.expect(dropped.change.dropped_receipts);
    try testing.expectEqual(@as(?u64, 5), core.peek("a"));
}

test "lazily/ingress_core: readiness derives from lifecycle and freshness" {
    var core = try sumCore(.{ .freshness_horizon = 10 });
    defer core.deinit();
    try testing.expectEqual(IngressReadiness.unknown, core.readiness("a"));
    _ = try core.open("a", 1);
    try testing.expectEqual(IngressReadiness.warming, core.readiness("a"));
    _ = try core.admit(env("a", 1, 0, 0, 1));
    try testing.expectEqual(IngressReadiness.ready, core.readiness("a"));

    // Crossing the horizon is a readiness-only transition.
    const crossed = try core.tick(50);
    try testing.expectEqual(@as(usize, 1), crossed.scopes.len);
    try testing.expectEqual(IngressScopeChange.readinessOnly(), crossed.scopes[0].change);
    try testing.expectEqual(IngressReadiness.stale, core.readiness("a"));
    // A further tick inside the same readiness dirties nothing.
    try testing.expect((try core.tick(60)).isEmpty());
}

test "lazily/ingress_core: suspend retains the watermark and reconnect replays the gap" {
    var core = try sumCore(.{});
    defer core.deinit();
    _ = try core.admit(env("a", 1, 0, 0, 1));
    _ = try core.admit(env("a", 1, 1, 0, 1));
    const suspended = try core.suspendScope("a");
    try testing.expectEqual(
        ReplayRequest{ .generation = 1, .from_sequence = 2 },
        suspended.replay.?,
    );
    try testing.expectEqual(IngressReadiness.suspended, core.readiness("a"));
    // The coalesced window survives a disconnect; only readiness changed.
    try testing.expectEqual(@as(?u64, 2), core.peek("a"));
    try testing.expectEqual(@as(usize, 1), suspended.change.scopes.len);
    try testing.expectEqual(
        IngressScopeChange.readinessOnly(),
        suspended.change.scopes[0].change,
    );
    // Suspending twice is idempotent and dirties nothing.
    const twice = try core.suspendScope("a");
    try testing.expect(twice.change.isEmpty());
    try testing.expectEqual(@as(?ReplayRequest, null), twice.replay);

    const back = try core.reconnect("a", 1);
    try testing.expectEqual(ReplayRequest{ .generation = 1, .from_sequence = 2 }, back.replay);
    try testing.expectEqual(IngressReadiness.ready, core.readiness("a"));
}

test "lazily/ingress_core: reconnect at a higher generation discards the stale window" {
    var core = try sumCore(.{});
    defer core.deinit();
    _ = try core.admit(env("a", 1, 0, 0, 5));
    _ = try core.suspendScope("a");
    const back = try core.reconnect("a", 3);
    try testing.expectEqual(ReplayRequest{ .generation = 3, .from_sequence = 0 }, back.replay);
    try testing.expect(back.change.scopes[0].change.value and
        back.change.scopes[0].change.authority);
    try testing.expectEqual(@as(?u64, null), core.peek("a"));
}

test "lazily/ingress_core: errors deepen backoff and a delivery clears it" {
    var core = try sumCore(.{ .retry_base = 10, .retry_ceiling = 25 });
    defer core.deinit();
    _ = try core.open("a", 1);
    try testing.expectEqual(@as(?IngressRetry, null), core.retry("a"));

    _ = try core.fail("a", .transport_closed);
    try testing.expectEqual(
        IngressRetry{ .attempt = 1, .backoff = 10, .resume_from = 0 },
        core.retry("a").?,
    );
    _ = try core.fail("a", .transport_closed);
    try testing.expectEqual(@as(u64, 20), core.retry("a").?.backoff);
    // Clamped, not doubled past the ceiling.
    _ = try core.fail("a", .transport_closed);
    try testing.expectEqual(@as(u64, 25), core.retry("a").?.backoff);
    try testing.expectEqual(@as(usize, 3), core.receiptCount(.err));

    _ = try core.admit(env("a", 1, 0, 0, 1));
    try testing.expectEqual(@as(?IngressRetry, null), core.retry("a"));
}

test "lazily/ingress_core: a reconnect clears the error streak without a delivery" {
    var core = try sumCore(.{});
    defer core.deinit();
    _ = try core.open("a", 1);
    _ = try core.fail("a", .authority_lost);
    const back = try core.reconnect("a", 1);
    try testing.expect(back.change.scopes[0].change.retry);
    try testing.expectEqual(@as(?IngressRetry, null), core.retry("a"));
}

test "lazily/ingress_core: closed scopes admit nothing and claim no authority" {
    var core = try sumCore(.{});
    defer core.deinit();
    _ = try core.admit(env("a", 1, 0, 0, 1));
    _ = try core.close("a");
    try testing.expectEqual(@as(?IngressAuthority, null), core.authority("a"));
    const refused = try core.admit(env("a", 1, 1, 0, 1));
    try testing.expectEqual(IngressDropReason.scope_closed, refused.admission.dropped);
    // Reopening a closed scope restarts its sequence space.
    _ = try core.open("a", 1);
    const reopened = try core.admit(env("a", 1, 0, 0, 4));
    try testing.expectEqual(@as(u64, 0), reopened.admission.accepted.delivered_through);
}

test "lazily/ingress_core: scopes are independent" {
    var core = try sumCore(.{});
    defer core.deinit();
    _ = try core.admit(env("a", 1, 0, 0, 1));
    const beta = try core.admit(env("b", 1, 0, 0, 2));
    try testing.expectEqual(@as(usize, 1), beta.change.scopes.len);
    try testing.expectEqualStrings("b", beta.change.scopes[0].key);
    _ = try core.close("b");
    try testing.expectEqual(IngressReadiness.ready, core.readiness("a"));
    try testing.expectEqual(@as(?u64, 1), core.peek("a"));
}

test "lazily/ingress_core: receipts are bounded and offsets stay monotone" {
    var core = try sumCore(.{ .receipt_capacity = 2 });
    defer core.deinit();
    for (0..4) |seq| _ = try core.admit(env("a", 1, @intCast(seq), 0, 1));
    var offsets: [2]u64 = undefined;
    var n: usize = 0;
    for (core.receiptLog()) |receipt| {
        if (receipt.channel() != .accepted) continue;
        offsets[n] = receipt.offset;
        n += 1;
    }
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualSlices(u64, &.{ 2, 3 }, &offsets);
}

test "lazily/ingress_core: a schedule offers a poll interval only without event delivery" {
    try testing.expectEqual(
        @as(?u64, null),
        IngressSchedule.forKind(.event_channel, 50).poll_interval,
    );
    try testing.expectEqual(
        @as(?u64, null),
        IngressSchedule.forKind(.rpc_triggered, 50).poll_interval,
    );
    try testing.expectEqual(
        @as(?u64, 50),
        IngressSchedule.forKind(.bounded_polling, 50).poll_interval,
    );
    // A zero interval would be an unbounded refresh loop.
    try testing.expectEqual(
        @as(?u64, 1),
        IngressSchedule.forKind(.bounded_polling, 0).poll_interval,
    );
}

test "lazily/ingress_core: drain is value-only and an empty drain dirties nothing" {
    var core = try sumCore(.{});
    defer core.deinit();
    _ = try core.admit(env("a", 1, 0, 0, 3));
    const drained = try core.drain("a");
    try testing.expectEqual(@as(?u64, 3), drained.value);
    try testing.expectEqual(@as(usize, 1), drained.change.scopes.len);
    try testing.expectEqual(IngressScopeChange.valueOnly(), drained.change.scopes[0].change);
    const empty = try core.drain("a");
    try testing.expectEqual(@as(?u64, null), empty.value);
    try testing.expect(empty.change.isEmpty());
    // Draining does not move the watermark: a drain is an egress, not an ack.
    try testing.expectEqual(@as(?u64, 0), core.view("a").?.delivered_through);
}

test "lazily/ingress_core: out-of-order arrival converges to the in-order fold" {
    // The reordering tax is paid by the buffer, not by the algebra: for any
    // arrival permutation of a contiguous run, the drained window equals the
    // in-order fold (`reorder_needs_no_commutativity`).
    const permutations = [_][4]u64{
        .{ 0, 1, 2, 3 },
        .{ 3, 2, 1, 0 },
        .{ 1, 0, 3, 2 },
        .{ 2, 0, 1, 3 },
        .{ 0, 3, 1, 2 },
    };
    for (permutations) |order| {
        var core = try sumCore(.{});
        defer core.deinit();
        for (order) |seq| {
            _ = try core.admit(env("a", 1, seq, 0, @as(u64, 1) << @intCast(seq)));
        }
        try testing.expectEqual(@as(?u64, 1 + 2 + 4 + 8), core.peek("a"));
        try testing.expectEqual(@as(?u64, 3), core.view("a").?.delivered_through);
    }
}
