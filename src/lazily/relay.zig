//! RelayCell backpressure plan (#relaycell), Phases 2–6 — the Zig port.
//!
//! See `lazily-spec/docs/relaycell.md` and
//! `relaycell-backpressure-analysis.md`. A `RelayCell` is an *algebra-typed
//! conflating relay*: it accumulates a fast ingress into a **hot head** (a
//! [`MergePolicy`] fold), bounds it with a [`BackpressurePolicy`], and lets a
//! slow egress **drain** the coalesced window. The converged egress state is
//! independent of the drain schedule whenever the merge ⊕ is associative (the
//! `relay_converges` invariant, pinned in `LazilyFormal.Relay`).
//!
//! Phase 2 RelayCell + BackpressurePolicy · Phase 3 SpillStore · Phase 4
//! Transport · Phase 5 Outbox/Inbox roles · Phase 6
//! Rate/Window/Expiry/Priority/Keyed policies. Time is a logical clock (a
//! monotone tick) so behaviour is deterministic and portable.
//!
//! ## Zig idiom
//!
//! Mirrors the `MergeCell(T)` comptime-value-policy idiom (`merge.zig`): a
//! relay is `RelayCell(comptime T)` parameterized over the element type; the
//! `MergePolicy(T)` (the associative fold + its algebra flags) is a runtime
//! value passed at `init`, exactly as `MergeCell(T).init` takes it. The hot
//! head is a plain `?T` optional (empty window = `null`) and `depth`/`is_full`/
//! `is_empty` are **demand-driven reader methods** computed from the current
//! fields on each read — an unobserved relay costs `N·⊕` and no more (the merge
//! cost law), the same demand-driven model `queue.zig` uses for its reader
//! kinds. `Conflate` on a non-conflating policy (`RawFifo`) is rejected at
//! `init` with `error.ConflateNotBounding` (the runtime-error form of the flag
//! guard, since the overflow is a runtime value).

const std = @import("std");
const Context = @import("context.zig").Context;
const MergePolicy = @import("merge.zig").MergePolicy;

// ---------------------------------------------------------------------------
// Phase 2: RelayCell + BackpressurePolicy
// ---------------------------------------------------------------------------

/// What a bound measures (analysis §4.4). The Phase-2 core meters `Count`; the
/// other dimensions are wired as the metering closure evolves.
pub const BoundDim = enum { Count, Bytes, Keys, Age };

/// The action taken when the hot head crosses `high_water` (analysis §4.4).
pub const Overflow = enum {
    /// Refuse ingress; the producer backpressures (observes `is_full`). Lossless.
    Block,
    /// Discard the incoming op. Lossy.
    DropNewest,
    /// Reset the window to the incoming op, discarding what accumulated. Lossy.
    DropOldest,
    /// Keep merging — the coalescence *is* the bound. Lossless for converged
    /// state; requires `policy.conflates`.
    Conflate,
    /// Page the accumulated window to a durable tail (Phase 3 `SpillStore`).
    Spill,
};

/// The outcome of a single `ingress` op.
pub const IngressOutcome = enum {
    /// Merged into an empty window (window depth was 0).
    Accepted,
    /// Merged into a non-empty window (coalesced with prior ops).
    Conflated,
    /// Dropped by `DropNewest`/`DropOldest` overflow.
    Dropped,
    /// Refused by `Block` overflow; the producer must retry after a drain.
    Blocked,
};

/// Why a construction/merge-swap was rejected (analysis §4.3 flag validation).
/// `Conflate` chosen for a non-conflating policy (`RawFifo`).
pub const RelayConfigError = error{ConflateNotBounding};

/// Reactive backpressure limits (analysis §4.4). In the Rust/JS bindings every
/// field is a reactive cell so an operator retunes it live; the Zig port keeps
/// the config as mutable fields (a retune is a direct field write, and the
/// reader methods recompute on demand). Hysteresis (`high_water` ≠ `low_water`)
/// prevents flapping.
pub const BackpressurePolicy = struct {
    dimension: BoundDim,
    high_water: u64,
    low_water: u64,
    overflow: Overflow,

    /// `ctx` is accepted for API parity with the reactive bindings (where the
    /// fields are cells minted on `ctx`); the Zig port stores plain values.
    pub fn init(
        ctx: *Context,
        dimension: BoundDim,
        high_water: u64,
        low_water: u64,
        overflow: Overflow,
    ) BackpressurePolicy {
        _ = ctx;
        return .{
            .dimension = dimension,
            .high_water = high_water,
            .low_water = low_water,
            .overflow = overflow,
        };
    }
};

/// The algebra-typed conflating relay (Phase 2, in-proc core).
///
/// `T` is the element type. The `MergePolicy(T)` fold is a runtime value passed
/// at `init` (the `MergeCell` idiom). The hot head is a `?T` (empty = `null`);
/// `pending` is the `Count` bound. `depth`/`isFull`/`isEmpty` are demand-driven
/// reader methods.
pub fn RelayCell(comptime T: type) type {
    return struct {
        policy: BackpressurePolicy,
        merge_policy: MergePolicy(T),
        /// Hot head: current window's coalesced value (`null` = empty window).
        head: ?T = null,
        /// Ops merged into the current window since the last drain (`Count`).
        pending: u64 = 0,

        const Self = @This();

        /// Build a relay over `merge_policy`, validating the initial overflow
        /// against the policy's algebra flags (analysis §4.3): `Conflate`
        /// requires `merge_policy.conflates`. `ctx` is accepted for API parity.
        pub fn init(
            ctx: *Context,
            policy: BackpressurePolicy,
            merge_policy: MergePolicy(T),
        ) RelayConfigError!Self {
            _ = ctx;
            if (policy.overflow == .Conflate and !merge_policy.conflates) {
                return RelayConfigError.ConflateNotBounding;
            }
            return .{ .policy = policy, .merge_policy = merge_policy };
        }

        /// Whether the current overflow choice is legal for the policy — a
        /// runtime guard mirroring `init`'s construction-time check.
        pub fn overflowIsLegal(self: *const Self) bool {
            return self.policy.overflow != .Conflate or self.merge_policy.conflates;
        }

        /// Demand-driven reader: current window depth (`Count`).
        pub fn depth(self: *const Self) u64 {
            return self.pending;
        }
        /// Demand-driven reader: window is at/over `high_water`.
        pub fn isFull(self: *const Self) bool {
            return self.pending >= self.policy.high_water;
        }
        /// Demand-driven reader: window is empty (nothing to drain).
        pub fn isEmpty(self: *const Self) bool {
            return self.head == null;
        }

        fn mergeIntoHead(self: *Self, op: T) void {
            self.head = if (self.head) |cur| self.merge_policy.merge(cur, op) else op;
        }

        /// Ingest one op. Applies the overflow policy when the window is at
        /// `high_water`; otherwise merges the op into the hot head under the
        /// merge policy.
        pub fn ingress(self: *Self, op: T) IngressOutcome {
            const was_empty = self.pending == 0;

            if (self.pending >= self.policy.high_water) {
                switch (self.policy.overflow) {
                    .Block => return .Blocked,
                    .DropNewest => return .Dropped,
                    .DropOldest => {
                        // Discard the accumulated window, restart from this op.
                        self.head = op;
                        self.pending = 1;
                        return .Dropped;
                    },
                    // Conflate keeps merging (the coalescence is the bound);
                    // Spill is Phase 3 and, until wired, degrades to Conflate
                    // for a bounding policy. Both fall through to the merge.
                    .Conflate, .Spill => {},
                }
            }

            self.mergeIntoHead(op);
            self.pending += 1;
            return if (was_empty) .Accepted else .Conflated;
        }

        /// Drain the coalesced window: take the hot head's value and reset the
        /// window. Returns `null` for an empty window. `relay_converges`
        /// guarantees the egress fold equals the flat fold of every ingested
        /// op, for any drain schedule.
        pub fn drain(self: *Self) ?T {
            const cur = self.head;
            if (cur != null) {
                self.head = null;
                self.pending = 0;
            }
            return cur;
        }

        /// Peek the current coalesced window without draining.
        pub fn peek(self: *const Self) ?T {
            return self.head;
        }
    };
}

// ---------------------------------------------------------------------------
// Phase 3: SpillStore
// ---------------------------------------------------------------------------

/// How spilled windows are laid out on the durable tail (analysis §6).
pub const SpillMode = enum {
    /// Merge each spilled window into the open page until it fills — minimizes
    /// disk (keep-latest / semilattice). One page holds a coalesced run.
    CompactOnWrite,
    /// Append each spilled window as its own page — preserves increments for an
    /// accumulating (non-idempotent) policy that must not double-count.
    AppendCompact,
};

/// One immutable cold page: a coalesced window summary plus its manifest entry.
pub fn SpillPage(comptime T: type) type {
    return struct { id: u64, summary: T, bytes: u64 };
}

/// A paged durable tail for a `RelayCell` (Phase 3, in-memory reference
/// backend). Holds immutable cold pages plus a bounded manifest, an egress
/// cursor, and ack-before-reclaim. Memory is `O(hot) + O(manifest)`.
pub fn SpillStore(comptime T: type) type {
    return struct {
        pages: std.ArrayList(SpillPage(T)),
        mode: SpillMode,
        page_size: u64,
        merge_policy: MergePolicy(T),
        /// Ops merged into the open (last) page under `CompactOnWrite`.
        open_fill: u64 = 0,
        next_id: u64 = 0,
        /// Pages acked from the front (reclaimable). The egress cursor.
        acked: usize = 0,
        allocator: std.mem.Allocator,

        const Self = @This();
        const Page = SpillPage(T);

        pub fn init(
            allocator: std.mem.Allocator,
            mode: SpillMode,
            page_size: u64,
            merge_policy: MergePolicy(T),
        ) Self {
            return .{
                .pages = .empty,
                .mode = mode,
                .page_size = @max(page_size, 1),
                .merge_policy = merge_policy,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.pages.deinit(self.allocator);
        }

        fn pushPage(self: *Self, summary: T, bytes: u64) !void {
            try self.pages.append(self.allocator, .{ .id = self.next_id, .summary = summary, .bytes = bytes });
            self.next_id += 1;
        }

        /// Spill one coalesced window summary to the durable tail.
        /// `AppendCompact` always opens a new page; `CompactOnWrite` merges into
        /// the open page until it reaches `page_size`, then seals it.
        pub fn spill(self: *Self, window: T, bytes: u64) !void {
            switch (self.mode) {
                .AppendCompact => try self.pushPage(window, bytes),
                .CompactOnWrite => {
                    if (self.open_fill >= self.page_size or self.pages.items.len == 0) {
                        try self.pushPage(window, bytes);
                        self.open_fill = 1;
                    } else {
                        const last = &self.pages.items[self.pages.items.len - 1];
                        last.summary = self.merge_policy.merge(last.summary, window);
                        last.bytes += bytes;
                        self.open_fill += 1;
                    }
                },
            }
        }

        /// Pages the egress has not yet acked (at/after the ack cursor).
        pub fn pendingPages(self: *const Self) []const Page {
            return self.pages.items[self.acked..];
        }

        pub fn pageCount(self: *const Self) usize {
            return self.pages.items.len;
        }

        /// Ack every page through `id` (inclusive), advancing the reclaim cursor.
        pub fn ackThrough(self: *Self, id: u64) void {
            while (self.acked < self.pages.items.len and self.pages.items[self.acked].id <= id) {
                self.acked += 1;
            }
        }

        /// Drop acked pages (durable reclaim). Manifest/cursor stay consistent.
        pub fn reclaim(self: *Self) void {
            var n = self.acked;
            while (n > 0) : (n -= 1) {
                _ = self.pages.orderedRemove(0);
            }
            self.acked = 0;
        }

        /// Fold every live cold page (oldest first) into `s0`.
        pub fn foldPages(self: *const Self, s0: T) T {
            var acc = s0;
            for (self.pages.items) |p| acc = self.merge_policy.merge(acc, p.summary);
            return acc;
        }

        /// **Reconstruction (spill_lossless).** Fold the cold tail then the hot
        /// head — reproduces the flat fold of every op the relay ingested.
        pub fn reconstruct(self: *const Self, s0: T, hot: ?T) T {
            const cold = self.foldPages(s0);
            return if (hot) |h| self.merge_policy.merge(cold, h) else cold;
        }

        /// **Crash replay.** Re-deliver every unacked page from the ack cursor
        /// into `downstream`. For an idempotent policy re-applying an
        /// already-delivered page is a no-op (`spill_replay_idempotent`), so
        /// at-least-once replay converges.
        pub fn replayUnacked(self: *const Self, downstream: T) T {
            var acc = downstream;
            for (self.pendingPages()) |p| acc = self.merge_policy.merge(acc, p.summary);
            return acc;
        }
    };
}

// ---------------------------------------------------------------------------
// Phase 4: Transport
// ---------------------------------------------------------------------------
//
// Transport abstracts ingress/egress delivery so the mechanism is pluggable. A
// RelayCell is written once against the Transport shape; the merge algebra —
// not the transport — guarantees converged state (transport_independent), so
// transports may differ across bindings and still converge. Zig expresses the
// abstraction as a comptime duck-typed shape (deliver/poll/hasPending); both
// concrete transports below satisfy it, so a generic egress loop works over
// either (see the transport test).

/// `InProc` — direct delivery: every buffered op is handed over in one frame.
pub fn InProcTransport(comptime T: type) type {
    return struct {
        buf: std.ArrayList(T),
        frame: std.ArrayList(T),
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .buf = .empty, .frame = .empty, .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.buf.deinit(self.allocator);
            self.frame.deinit(self.allocator);
        }

        pub fn deliver(self: *Self, op: T) !void {
            try self.buf.append(self.allocator, op);
        }

        /// Pull the next ready frame (all buffered ops). The returned slice is
        /// owned by the transport and valid until the next `poll`/`deliver`.
        pub fn poll(self: *Self) ![]const T {
            self.frame.clearRetainingCapacity();
            try self.frame.appendSlice(self.allocator, self.buf.items);
            self.buf.clearRetainingCapacity();
            return self.frame.items;
        }

        pub fn hasPending(self: *const Self) bool {
            return self.buf.items.len > 0;
        }
    };
}

/// A *framed* transport — models `CrossThread`/`Ipc`/`Ws`: ops are delivered in
/// bounded frames of at most `frame_size` (an MTU / batch boundary). Different
/// `frame_size`s are different framings of the same op stream.
pub fn FramedTransport(comptime T: type) type {
    return struct {
        buf: std.ArrayList(T),
        frame: std.ArrayList(T),
        frame_size: usize,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, frame_size: usize) Self {
            return .{
                .buf = .empty,
                .frame = .empty,
                .frame_size = @max(frame_size, 1),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.buf.deinit(self.allocator);
            self.frame.deinit(self.allocator);
        }

        pub fn deliver(self: *Self, op: T) !void {
            try self.buf.append(self.allocator, op);
        }

        pub fn poll(self: *Self) ![]const T {
            const n = @min(self.frame_size, self.buf.items.len);
            self.frame.clearRetainingCapacity();
            try self.frame.appendSlice(self.allocator, self.buf.items[0..n]);
            // Drain the front n from buf.
            var i: usize = 0;
            while (i < n) : (i += 1) _ = self.buf.orderedRemove(0);
            return self.frame.items;
        }

        pub fn hasPending(self: *const Self) bool {
            return self.buf.items.len > 0;
        }
    };
}

// ---------------------------------------------------------------------------
// Phase 5: Outbox / Inbox roles
// ---------------------------------------------------------------------------
//
// RelayCell is direction-neutral; Outbox and Inbox are role facades (typed
// constructors with direction-appropriate defaults), not reimplementations.
// They differ in the backpressure-propagation contract. A network link is
// Outbox → Transport → Inbox.

/// The app → transport send side (analysis §4.7). Backpressures the local
/// producer directly via `is_full`. Default overflow `Conflate` (state
/// broadcast).
pub fn Outbox(comptime T: type) type {
    return struct {
        relay: RelayCell(T),

        const Self = @This();

        /// Build an outbox bounded by `high_water` with the role default
        /// overflow (`Conflate`).
        pub fn init(ctx: *Context, high_water: u64, merge_policy: MergePolicy(T)) RelayConfigError!Self {
            return Self.withOverflow(ctx, .Count, high_water, .Conflate, merge_policy);
        }

        /// Build an outbox with an explicit dimension/overflow (e.g. `Spill`
        /// for a lossless event channel).
        pub fn withOverflow(
            ctx: *Context,
            dimension: BoundDim,
            high_water: u64,
            overflow: Overflow,
            merge_policy: MergePolicy(T),
        ) RelayConfigError!Self {
            const policy = BackpressurePolicy.init(ctx, dimension, high_water, high_water / 2, overflow);
            return .{ .relay = try RelayCell(T).init(ctx, policy, merge_policy) };
        }

        /// The local producer sends an op. A `Blocked` outcome is the producer's
        /// backpressure signal — it should await a drain before retrying.
        pub fn send(self: *Self, op: T) IngressOutcome {
            return self.relay.ingress(op);
        }

        /// The transport drains the coalesced window for egress.
        pub fn drain(self: *Self) ?T {
            return self.relay.drain();
        }

        /// The producer-facing backpressure signal (window at/over the watermark).
        pub fn isFull(self: *const Self) bool {
            return self.relay.isFull();
        }
    };
}

/// The transport → app receive side (analysis §4.7). Cannot block the remote
/// directly; backpressure is a **credit meter** the app replenishes.
pub fn Inbox(comptime T: type) type {
    return struct {
        relay: RelayCell(T),
        credits: u64,
        max_credits: u64,

        const Self = @This();

        /// Build an inbox bounded by `high_water` with the role default overflow
        /// (`Conflate`) and a credit budget of `max_credits`.
        pub fn init(
            ctx: *Context,
            high_water: u64,
            max_credits: u64,
            merge_policy: MergePolicy(T),
        ) RelayConfigError!Self {
            return Self.withOverflow(ctx, high_water, .Conflate, max_credits, merge_policy);
        }

        pub fn withOverflow(
            ctx: *Context,
            high_water: u64,
            overflow: Overflow,
            max_credits: u64,
            merge_policy: MergePolicy(T),
        ) RelayConfigError!Self {
            const policy = BackpressurePolicy.init(ctx, .Count, high_water, high_water / 2, overflow);
            return .{
                .relay = try RelayCell(T).init(ctx, policy, merge_policy),
                .credits = max_credits,
                .max_credits = max_credits,
            };
        }

        /// Whether the transport may deliver another message (a credit is
        /// available). When `false`, the transport must stop reading → the
        /// remote throttles.
        pub fn ready(self: *const Self) bool {
            return self.credits > 0;
        }

        /// Credits currently available to the remote.
        pub fn creditsAvailable(self: *const Self) u64 {
            return self.credits;
        }

        /// The transport delivers a received op. Consumes a credit; the caller
        /// MUST have checked `ready` (a delivery without credit still applies
        /// but drives `credits` to zero, signalling the remote to stop).
        pub fn receive(self: *Self, op: T) IngressOutcome {
            self.credits -|= 1;
            return self.relay.ingress(op);
        }

        /// The app consumes the coalesced window and replenishes `replenish`
        /// credits (up to the budget), re-opening the remote's flow.
        pub fn consume(self: *Self, replenish: u64) ?T {
            const out = self.relay.drain();
            self.credits = @min(self.credits + replenish, self.max_credits);
            return out;
        }
    };
}

// ---------------------------------------------------------------------------
// Phase 6: extra reactive policies
// ---------------------------------------------------------------------------
//
// Each policy is an optional reactive stage composed onto a relay egress; they
// only change where/when a relay flushes or which ops survive. Time is a
// logical clock (a monotone tick) — a binding drives tick/advance from its own
// runtime timer.

/// Case 9 — **rate-limited egress (token bucket).** A drain is permitted only
/// when a token is available. Refilled `refill_per_tick` tokens per logical
/// tick, capped at `capacity`.
pub const RatePolicy = struct {
    capacity: u64,
    tokens: u64,
    refill_per_tick: u64,

    pub fn init(capacity: u64, refill_per_tick: u64) RatePolicy {
        return .{ .capacity = capacity, .tokens = capacity, .refill_per_tick = refill_per_tick };
    }

    pub fn tokensAvailable(self: *const RatePolicy) u64 {
        return self.tokens;
    }

    /// Try to consume one token for an egress; returns `true` if paced through.
    pub fn tryEgress(self: *RatePolicy) bool {
        if (self.tokens > 0) {
            self.tokens -= 1;
            return true;
        }
        return false;
    }

    /// Advance the logical clock, refilling the bucket (saturating at capacity).
    pub fn tick(self: *RatePolicy) void {
        self.tokens = @min(self.tokens + self.refill_per_tick, self.capacity);
    }
};

/// Case 8 — **time-windowed coalescence (debounce/throttle).** Flushes when it
/// reaches `window_ops` ops **or** on an explicit `tick`. Because a window is
/// just a flush group, associativity keeps the converged state unchanged
/// (`flushGroupingIrrelevant`).
pub const WindowPolicy = struct {
    window_ops: u64,
    pending: u64 = 0,

    pub fn init(window_ops: u64) WindowPolicy {
        return .{ .window_ops = @max(window_ops, 1) };
    }

    /// Record one ingress; returns `true` when the window is full and flushes.
    pub fn onIngress(self: *WindowPolicy) bool {
        self.pending += 1;
        if (self.pending >= self.window_ops) {
            self.pending = 0;
            return true;
        }
        return false;
    }

    /// The debounce/throttle interval elapsed: flush whatever is pending.
    pub fn tick(self: *WindowPolicy) bool {
        if (self.pending > 0) {
            self.pending = 0;
            return true;
        }
        return false;
    }
};

/// Case 10 — **TTL / deadline expiry.** Drops elements whose age exceeds `ttl`
/// against a logical clock. Lossy-by-age (explicit); used to shed cold data.
pub const ExpiryPolicy = struct {
    ttl: u64,
    now: u64 = 0,

    pub fn init(ttl: u64) ExpiryPolicy {
        return .{ .ttl = ttl };
    }

    pub fn advance(self: *ExpiryPolicy, by: u64) void {
        self.now += by;
    }

    pub fn nowClock(self: *const ExpiryPolicy) u64 {
        return self.now;
    }

    /// Whether an element stamped at `stamped_at` is still live (not expired).
    pub fn isLive(self: *const ExpiryPolicy, stamped_at: u64) bool {
        return self.now -| stamped_at <= self.ttl;
    }

    /// A `(timestamp, value)` element for `retainLive`.
    pub fn Stamped(comptime V: type) type {
        return struct { ts: u64, value: V };
    }

    /// Retain only the live elements of a timestamped batch (drop the aged
    /// tail). Returns a caller-owned slice allocated with `allocator`.
    pub fn retainLive(
        self: *const ExpiryPolicy,
        comptime V: type,
        allocator: std.mem.Allocator,
        batch: []const Stamped(V),
    ) ![]V {
        var out: std.ArrayList(V) = .empty;
        errdefer out.deinit(allocator);
        for (batch) |e| {
            if (self.isLive(e.ts)) try out.append(allocator, e.value);
        }
        return out.toOwnedSlice(allocator);
    }
};

/// Case 11 — **priority egress.** Ingress carries a priority; egress pops the
/// highest priority first (**not** FIFO), FIFO within equal priority.
/// Reordering, so sound for a commutative merge downstream (`reorder_adjacent`).
pub fn PriorityStorage(comptime T: type) type {
    return struct {
        const Item = struct { priority: u64, seq: u64, value: T };

        items: std.ArrayList(Item),
        seq: u64 = 0,
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .items = .empty, .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.items.deinit(self.allocator);
        }

        pub fn push(self: *Self, priority: u64, value: T) !void {
            try self.items.append(self.allocator, .{ .priority = priority, .seq = self.seq, .value = value });
            self.seq += 1;
        }

        /// Pop the highest-priority element (FIFO within equal priority).
        pub fn pop(self: *Self) ?T {
            if (self.items.items.len == 0) return null;
            var best: usize = 0;
            for (self.items.items, 0..) |a, i| {
                const b = self.items.items[best];
                if (a.priority > b.priority or (a.priority == b.priority and a.seq < b.seq)) {
                    best = i;
                }
            }
            const out = self.items.orderedRemove(best);
            return out.value;
        }

        pub fn len(self: *const Self) usize {
            return self.items.items.len;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.items.items.len == 0;
        }
    };
}

/// Case 18 — **keyed sharding.** N independent relays keyed by `K`; an op routes
/// to its key's shard. Merging *across* shards requires a **commutative** merge.
/// The converged per-key state equals a single relay per key.
///
/// `K` may be `[]const u8` (string keys, backed by `StringHashMap`) or any
/// `AutoHashMap`-compatible key type.
pub fn KeyedRelay(comptime K: type, comptime T: type) type {
    const MapType = if (K == []const u8)
        std.StringHashMap(RelayCell(T))
    else
        std.AutoHashMap(K, RelayCell(T));

    return struct {
        shards: MapType,
        high_water: u64,
        overflow: Overflow,
        merge_policy: MergePolicy(T),

        const Self = @This();

        pub fn init(
            allocator: std.mem.Allocator,
            high_water: u64,
            overflow: Overflow,
            merge_policy: MergePolicy(T),
        ) Self {
            return .{
                .shards = MapType.init(allocator),
                .high_water = high_water,
                .overflow = overflow,
                .merge_policy = merge_policy,
            };
        }

        pub fn deinit(self: *Self) void {
            self.shards.deinit();
        }

        /// Route `op` to `key`'s shard, creating the shard on first use.
        pub fn ingress(self: *Self, ctx: *Context, key: K, op: T) !IngressOutcome {
            const gop = try self.shards.getOrPut(key);
            if (!gop.found_existing) {
                const policy = BackpressurePolicy.init(ctx, .Count, self.high_water, self.high_water / 2, self.overflow);
                gop.value_ptr.* = try RelayCell(T).init(ctx, policy, self.merge_policy);
            }
            return gop.value_ptr.ingress(op);
        }

        /// Drain a key's coalesced window.
        pub fn drain(self: *Self, key: K) ?T {
            if (self.shards.getPtr(key)) |relay| return relay.drain();
            return null;
        }

        pub fn keyIterator(self: *Self) MapType.KeyIterator {
            return self.shards.keyIterator();
        }

        pub fn shardCount(self: *const Self) usize {
            return self.shards.count();
        }
    };
}

// ===========================================================================
// Tests — mirror the kt/js coverage list (#relaycell Phases 2–6).
// ===========================================================================

const merge = @import("merge.zig");

/// A non-conflating stand-in policy (`RawFifo` analog) for the Conflate
/// rejection test: the zig value-typed merge core has no collection policies,
/// so this exposes `conflates = false` over `i64` — enough to exercise the
/// construction-time flag guard.
fn rawFifo(comptime T: type) MergePolicy(T) {
    return .{
        .name = "RawFifo",
        .merge = struct {
            fn f(_: T, op: T) T {
                return op;
            }
        }.f,
        .commutative = false,
        .idempotent = false,
        .conflates = false,
    };
}

fn makeRelay(
    ctx: *Context,
    policy: MergePolicy(i64),
    high_water: u64,
    overflow: Overflow,
) !RelayCell(i64) {
    const bp = BackpressurePolicy.init(ctx, .Count, high_water, high_water / 2, overflow);
    return RelayCell(i64).init(ctx, bp, policy);
}

// -- Phase 2 -----------------------------------------------------------------

test "relay: converged egress independent of drain schedule (Sum/Max)" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const policies = [_]MergePolicy(i64){ merge.sum(i64), merge.max(i64) };
    inline for (policies) |policy| {
        const ops = [_]i64{ 3, 1, 4, 1, 5, 9, 2, 6 };
        var flat: i64 = ops[0];
        for (ops[1..]) |op| flat = policy.merge(flat, op);

        // drain-every schedule.
        var r_every = try makeRelay(ctx, policy, 1_000_000, .Conflate);
        var acc: ?i64 = null;
        for (ops) |op| {
            _ = r_every.ingress(op);
            if (r_every.drain()) |d| {
                acc = if (acc) |a| policy.merge(a, d) else d;
            }
        }
        try std.testing.expectEqual(flat, acc.?);

        // drain-once schedule.
        var r_once = try makeRelay(ctx, policy, 1_000_000, .Conflate);
        for (ops) |op| _ = r_once.ingress(op);
        try std.testing.expectEqual(flat, r_once.drain().?);
    }
}

test "relay: reactive depth / isFull / isEmpty (demand-driven)" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var r = try makeRelay(ctx, merge.sum(i64), 3, .Conflate);
    try std.testing.expect(r.isEmpty());
    try std.testing.expectEqual(@as(u64, 0), r.depth());
    try std.testing.expect(!r.isFull());

    _ = r.ingress(1);
    _ = r.ingress(1);
    try std.testing.expect(!r.isEmpty());
    try std.testing.expectEqual(@as(u64, 2), r.depth());
    try std.testing.expect(!r.isFull());

    _ = r.ingress(1);
    try std.testing.expectEqual(@as(u64, 3), r.depth());
    try std.testing.expect(r.isFull());

    _ = r.drain();
    try std.testing.expect(r.isEmpty());
    try std.testing.expectEqual(@as(u64, 0), r.depth());
}

test "relay: Block overflow refuses ingress" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var r = try makeRelay(ctx, merge.sum(i64), 2, .Block);
    try std.testing.expectEqual(IngressOutcome.Accepted, r.ingress(1));
    try std.testing.expectEqual(IngressOutcome.Conflated, r.ingress(1));
    try std.testing.expectEqual(IngressOutcome.Blocked, r.ingress(1));
    try std.testing.expectEqual(@as(i64, 2), r.drain().?);
}

test "relay: DropNewest and DropOldest" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var rn = try makeRelay(ctx, merge.sum(i64), 2, .DropNewest);
    _ = rn.ingress(1);
    _ = rn.ingress(1);
    try std.testing.expectEqual(IngressOutcome.Dropped, rn.ingress(9));
    try std.testing.expectEqual(@as(i64, 2), rn.drain().?);

    var ro = try makeRelay(ctx, merge.sum(i64), 2, .DropOldest);
    _ = ro.ingress(1);
    _ = ro.ingress(1);
    try std.testing.expectEqual(IngressOutcome.Dropped, ro.ingress(9));
    try std.testing.expectEqual(@as(i64, 9), ro.drain().?);
}

test "relay: construction rejects Conflate for RawFifo" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const bp = BackpressurePolicy.init(ctx, .Count, 4, 2, .Conflate);
    try std.testing.expectError(
        RelayConfigError.ConflateNotBounding,
        RelayCell(i64).init(ctx, bp, rawFifo(i64)),
    );

    // A non-Conflate overflow is legal for RawFifo.
    const bp_block = BackpressurePolicy.init(ctx, .Count, 4, 2, .Block);
    var r = try RelayCell(i64).init(ctx, bp_block, rawFifo(i64));
    try std.testing.expect(r.overflowIsLegal());
    _ = r.ingress(7);
    try std.testing.expectEqual(@as(i64, 7), r.drain().?);
}

// -- Phase 3 -----------------------------------------------------------------

test "relay/spill: spill_lossless both modes" {
    const allocator = std.testing.allocator;
    const modes = [_]SpillMode{ .CompactOnWrite, .AppendCompact };
    for (modes) |mode| {
        var store = SpillStore(i64).init(allocator, mode, 2, merge.sum(i64));
        defer store.deinit();

        const windows = [_]i64{ 1, 2, 3, 4, 5 };
        for (windows) |w| try store.spill(w, 1);
        const hot: i64 = 10;
        var flat: i64 = 0;
        for (windows) |w| flat += w;
        flat += hot;
        try std.testing.expectEqual(flat, store.reconstruct(0, hot));
    }
}

test "relay/spill: spill_replay_idempotent for idempotent policy (Max)" {
    const allocator = std.testing.allocator;
    var store = SpillStore(i64).init(allocator, .AppendCompact, 1, merge.max(i64));
    defer store.deinit();

    for ([_]i64{ 3, 7, 5 }) |w| try store.spill(w, 1);
    const once = store.replayUnacked(0);
    const twice = store.replayUnacked(once);
    try std.testing.expectEqual(once, twice);
    try std.testing.expectEqual(@as(i64, 7), once);
}

test "relay/spill: CompactOnWrite bounds pages and ack reclaims" {
    const allocator = std.testing.allocator;
    var store = SpillStore(i64).init(allocator, .CompactOnWrite, 2, merge.sum(i64));
    defer store.deinit();

    var i: usize = 0;
    while (i < 5) : (i += 1) try store.spill(1, 1); // page size 2 → 3 pages
    try std.testing.expectEqual(@as(usize, 3), store.pageCount());

    const first_id = store.pendingPages()[0].id;
    store.ackThrough(first_id);
    try std.testing.expectEqual(@as(usize, 2), store.pendingPages().len);
    store.reclaim();
    try std.testing.expectEqual(@as(usize, 2), store.pageCount());
}

// -- Phase 4 -----------------------------------------------------------------

test "relay/transport: transport_independent across framing" {
    const allocator = std.testing.allocator;
    const policies = [_]MergePolicy(i64){ merge.sum(i64), merge.max(i64), merge.keepLatest(i64) };
    inline for (policies) |policy| {
        const ops = [_]i64{ 3, 1, 4, 1, 5, 9 };
        var flat: i64 = ops[0];
        for (ops[1..]) |op| flat = policy.merge(flat, op);

        // Run the same op stream through three framings; all converge to flat.
        // InProc (one frame).
        {
            const ctx = try Context.init(allocator);
            defer ctx.deinit();
            var tp = InProcTransport(i64).init(allocator);
            defer tp.deinit();
            for (ops) |op| try tp.deliver(op);
            var r = try makeRelay(ctx, policy, 1_000_000, .Conflate);
            while (tp.hasPending()) {
                const frame = try tp.poll();
                for (frame) |op| _ = r.ingress(op);
            }
            try std.testing.expectEqual(flat, r.drain().?);
        }
        // Framed at MTUs 2 and 3.
        for ([_]usize{ 2, 3 }) |mtu| {
            const ctx = try Context.init(allocator);
            defer ctx.deinit();
            var tp = FramedTransport(i64).init(allocator, mtu);
            defer tp.deinit();
            for (ops) |op| try tp.deliver(op);
            var r = try makeRelay(ctx, policy, 1_000_000, .Conflate);
            while (tp.hasPending()) {
                const frame = try tp.poll();
                for (frame) |op| _ = r.ingress(op);
            }
            try std.testing.expectEqual(flat, r.drain().?);
        }
    }
}

// -- Phase 5 -----------------------------------------------------------------

test "relay/roles: Outbox conflates state broadcast" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var out = try Outbox(i64).init(ctx, 8, merge.keepLatest(i64));
    _ = out.send(1);
    _ = out.send(2);
    _ = out.send(3);
    try std.testing.expectEqual(@as(i64, 3), out.drain().?);
}

test "relay/roles: Inbox credit meters remote" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var inbox = try Inbox(i64).init(ctx, 100, 2, merge.sum(i64));
    try std.testing.expect(inbox.ready());
    _ = inbox.receive(5);
    _ = inbox.receive(5);
    try std.testing.expect(!inbox.ready());
    try std.testing.expectEqual(@as(i64, 10), inbox.consume(2).?);
    try std.testing.expect(inbox.ready());
}

test "relay/roles: Outbox → Inbox link converges" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var out = try Outbox(i64).init(ctx, 64, merge.sum(i64));
    var inbox = try Inbox(i64).init(ctx, 64, 64, merge.sum(i64));
    var tp = InProcTransport(i64).init(allocator);
    defer tp.deinit();

    const ops = [_]i64{ 1, 2, 3, 4 };
    for (ops) |op| _ = out.send(op);
    try tp.deliver(out.drain().?);
    while (tp.hasPending()) {
        const frame = try tp.poll();
        for (frame) |m| _ = inbox.receive(m);
    }
    var expected: i64 = 0;
    for (ops) |op| expected += op;
    try std.testing.expectEqual(expected, inbox.consume(64).?);
}

// -- Phase 6 -----------------------------------------------------------------

test "relay/policy: RatePolicy token bucket" {
    var rate = RatePolicy.init(2, 1);
    try std.testing.expect(rate.tryEgress());
    try std.testing.expect(rate.tryEgress());
    try std.testing.expect(!rate.tryEgress());
    rate.tick();
    try std.testing.expect(rate.tryEgress());
}

test "relay/policy: WindowPolicy flush on fill and tick" {
    var window = WindowPolicy.init(3);
    try std.testing.expect(!window.onIngress());
    try std.testing.expect(!window.onIngress());
    try std.testing.expect(window.onIngress());
    try std.testing.expect(!window.onIngress());
    try std.testing.expect(window.tick());
    try std.testing.expect(!window.tick());
}

test "relay/policy: ExpiryPolicy drops aged" {
    const allocator = std.testing.allocator;
    var expiry = ExpiryPolicy.init(5);
    expiry.advance(10);
    const S = ExpiryPolicy.Stamped([]const u8);
    const batch = [_]S{
        .{ .ts = 3, .value = "old" },
        .{ .ts = 7, .value = "fresh" },
        .{ .ts = 10, .value = "now" },
    };
    const live = try expiry.retainLive([]const u8, allocator, &batch);
    defer allocator.free(live);
    try std.testing.expectEqual(@as(usize, 2), live.len);
    try std.testing.expectEqualStrings("fresh", live[0]);
    try std.testing.expectEqualStrings("now", live[1]);
}

test "relay/policy: PriorityStorage pops highest first, FIFO within" {
    const allocator = std.testing.allocator;
    var pq = PriorityStorage([]const u8).init(allocator);
    defer pq.deinit();

    try pq.push(1, "low");
    try pq.push(3, "highA");
    try pq.push(2, "mid");
    try pq.push(3, "highB");
    try std.testing.expectEqualStrings("highA", pq.pop().?);
    try std.testing.expectEqualStrings("highB", pq.pop().?);
    try std.testing.expectEqualStrings("mid", pq.pop().?);
    try std.testing.expectEqualStrings("low", pq.pop().?);
    try std.testing.expectEqual(@as(?[]const u8, null), pq.pop());
}

test "relay/policy: KeyedRelay shards per key" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var keyed = KeyedRelay([]const u8, i64).init(allocator, 64, .Conflate, merge.sum(i64));
    defer keyed.deinit();

    _ = try keyed.ingress(ctx, "a", 1);
    _ = try keyed.ingress(ctx, "b", 10);
    _ = try keyed.ingress(ctx, "a", 2);
    try std.testing.expectEqual(@as(i64, 3), keyed.drain("a").?);
    try std.testing.expectEqual(@as(i64, 10), keyed.drain("b").?);

    // Both keys are present (order across keys is not defined).
    try std.testing.expectEqual(@as(usize, 2), keyed.shardCount());
    var have_a = false;
    var have_b = false;
    var it = keyed.keyIterator();
    while (it.next()) |k| {
        if (std.mem.eql(u8, k.*, "a")) have_a = true;
        if (std.mem.eql(u8, k.*, "b")) have_b = true;
    }
    try std.testing.expect(have_a and have_b);
}
