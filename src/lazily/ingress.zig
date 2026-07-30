//! `IngressCell` — the single-threaded shell of the transport-agnostic reactive
//! ingress family (`#designimplementtransport`).
//!
//! The shell owns the graph; [`IngressCore`](ingress_core.zig) owns the algebra.
//! Every core mutator reports *which* reader kinds the transition dirtied, and
//! this shell clears exactly that set — no more (over-invalidation re-renders a
//! value that did not change) and no less (under-invalidation freezes a reader).
//!
//! # Four reader kinds per scope, three receipt channels
//!
//! | Reader | Reads | Dirtied by |
//! |---|---|---|
//! | `value` | the coalesced window | delivery, drain, handoff, close |
//! | `readiness` | [`IngressReadiness`] | lifecycle change, first delivery, a freshness-horizon *crossing* |
//! | `authority` | [`IngressAuthority`] | delivery, handoff, open, close |
//! | `retry` | [`IngressRetry`] | error, delivery, reconnect, close |
//!
//! plus `accepted` / `dropped` / `error` receipt readers. They are separate
//! reader kinds because they have separate consumers: collapsing them would make
//! an error deepen a backoff *and* re-render a value that did not change, and
//! would let a dropped envelope invalidate a projection that only reads accepts.
//!
//! The negative cases are the contract: a buffered out-of-order envelope
//! invalidates nothing and mints no receipt; a `tick` inside the freshness
//! horizon invalidates nothing; an empty drain invalidates nothing; a suspend
//! invalidates readiness only.
//!
//! # No observers — only graph edges
//!
//! Each reader kind is a real `Source(u64)` node (the shared
//! [`ReaderKind`](reader_kind.zig) identity the queue and map families already
//! use), and a reader derives its value from core storage on demand. There is no
//! observer registry, listener list, or subscription set: anything that survived
//! an invalidation would not be a graph edge.
//!
//! A transition that dirties several kinds publishes them through
//! [`bumpSources`](cell.zig), so the whole set lands in **one** frontier walk and
//! no reader observes `new value, old authority` — the partial fan-out a
//! generation handoff must never expose.

const std = @import("std");
const Context = @import("context.zig").Context;
const Compute = @import("context.zig").Compute;
const Slot = @import("context.zig").Slot;
const cell = @import("cell.zig");
const effect = @import("effect.zig");
const merge = @import("merge.zig");
const ReaderKind = @import("reader_kind.zig").ReaderKind;
const core_mod = @import("ingress_core.zig");

pub const IngressCore = core_mod.IngressCore;
pub const IngressAdmission = core_mod.IngressAdmission;
pub const IngressAuthority = core_mod.IngressAuthority;
pub const IngressConfigError = core_mod.IngressConfigError;
pub const IngressDropReason = core_mod.IngressDropReason;
pub const IngressError = core_mod.IngressError;
pub const IngressLifecycle = core_mod.IngressLifecycle;
pub const IngressPolicy = core_mod.IngressPolicy;
pub const IngressReadiness = core_mod.IngressReadiness;
pub const IngressReceiptChannel = core_mod.IngressReceiptChannel;
pub const IngressRetry = core_mod.IngressRetry;
pub const IngressSchedule = core_mod.IngressSchedule;
pub const IngressTransportKind = core_mod.IngressTransportKind;
pub const ReplayRequest = core_mod.ReplayRequest;
pub const ScopeView = core_mod.ScopeView;

/// Per-reader-kind version counters. A version that did not move is the
/// operational reading of "this reader was not invalidated"; the conformance
/// runner additionally probes real derived-node cache validity, which is the
/// stronger claim.
pub const IngressScopeVersions = struct {
    value: u64,
    readiness: u64,
    authority: u64,
    retry: u64,
    accepted: u64,
    dropped: u64,
    err: u64,
};

/// Keyed lifecycle-scoped admission with reactive derives, on a single-threaded
/// [`Context`]. `T` is the payload type; the merge algebra arrives as a runtime
/// [`MergePolicy`](merge.zig) value, matching `RelayCell`'s shape.
///
/// The cell's address must be stable once any reader has been handed out: reader
/// handles carry `*const Self`. Keep it in a `var` (or heap-allocate it) and pass
/// `&cell`, exactly as `WorkQueueCell` is used.
pub fn IngressCell(comptime K: type, comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Core = IngressCore(K, T);
        pub const Envelope = Core.Envelope;
        pub const Receipt = Core.Receipt;

        /// Four graph nodes per scope, because the four derives have four
        /// different invalidation boundaries.
        pub const ScopeReaders = struct {
            value: ReaderKind,
            readiness: ReaderKind,
            authority: ReaderKind,
            retry: ReaderKind,
        };

        /// The coalesced window awaiting drain. `null` for an unknown scope or a
        /// drained one — a reader cannot tell those apart, and does not need to.
        pub const ValueReader = struct {
            owner: *const Self,
            key: K,
            slot: *Slot,

            pub fn get(self: @This()) ?T {
                return self.owner.core.peek(self.key);
            }
        };

        pub const ReadinessReader = struct {
            owner: *const Self,
            key: K,
            slot: *Slot,

            pub fn get(self: @This()) IngressReadiness {
                return self.owner.core.readiness(self.key);
            }
        };

        pub const AuthorityReader = struct {
            owner: *const Self,
            key: K,
            slot: *Slot,

            pub fn get(self: @This()) ?IngressAuthority {
                return self.owner.core.authority(self.key);
            }
        };

        pub const RetryReader = struct {
            owner: *const Self,
            key: K,
            slot: *Slot,

            pub fn get(self: @This()) ?IngressRetry {
                return self.owner.core.retry(self.key);
            }
        };

        /// One receipt channel's depth. Counted rather than collected so a reader
        /// never has to own a slice; `receiptLog` stays available for consumers
        /// that want the payloads.
        pub const ReceiptCountReader = struct {
            owner: *const Self,
            channel: IngressReceiptChannel,
            slot: *Slot,

            pub fn get(self: @This()) usize {
                return self.owner.core.receiptCount(self.channel);
            }
        };

        ctx: *Context,
        allocator: std.mem.Allocator,
        core: Core,
        readers: core_mod.HashMapFor(K, ScopeReaders),
        accepted_reader: ReaderKind,
        dropped_reader: ReaderKind,
        error_reader: ReaderKind,
        schedule_value: IngressSchedule,
        /// Reusable publish buffer, so a multi-kind transition needs no
        /// allocation on the hot path and still lands as one frontier walk.
        bump_scratch: std.ArrayList(*cell.Source(u64)) = .empty,

        pub fn init(
            ctx: *Context,
            policy: IngressPolicy,
            merge_policy: merge.MergePolicy(T),
            transport: IngressTransportKind,
            poll_interval: u64,
        ) !Self {
            var core = try Core.init(ctx.allocator, policy, merge_policy);
            errdefer core.deinit();
            const accepted_reader = try ReaderKind.init(ctx);
            errdefer accepted_reader.dispose();
            const dropped_reader = try ReaderKind.init(ctx);
            errdefer dropped_reader.dispose();
            const error_reader = try ReaderKind.init(ctx);
            return .{
                .ctx = ctx,
                .allocator = ctx.allocator,
                .core = core,
                .readers = core_mod.HashMapFor(K, ScopeReaders).init(ctx.allocator),
                .accepted_reader = accepted_reader,
                .dropped_reader = dropped_reader,
                .error_reader = error_reader,
                .schedule_value = IngressSchedule.forKind(transport, poll_interval),
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.readers.valueIterator();
            while (it.next()) |r| {
                r.value.dispose();
                r.readiness.dispose();
                r.authority.dispose();
                r.retry.dispose();
            }
            self.readers.deinit();
            self.accepted_reader.dispose();
            self.dropped_reader.dispose();
            self.error_reader.dispose();
            self.bump_scratch.deinit(self.allocator);
            self.core.deinit();
        }

        // --- reader identities ----------------------------------------------

        /// Mint (or fetch) the four reader-kind nodes for `key`. Minting a reader
        /// does **not** open a scope: a consumer may legitimately observe a key
        /// before it exists, and reads `unknown`/`null` until it does.
        pub fn scopeReaders(self: *Self, key: K) !*ScopeReaders {
            const entry = try self.readers.getOrPut(key);
            if (!entry.found_existing) {
                const value_reader = try ReaderKind.init(self.ctx);
                errdefer value_reader.dispose();
                const readiness_reader = try ReaderKind.init(self.ctx);
                errdefer readiness_reader.dispose();
                const authority_reader = try ReaderKind.init(self.ctx);
                errdefer authority_reader.dispose();
                const retry_reader = try ReaderKind.init(self.ctx);
                entry.value_ptr.* = .{
                    .value = value_reader,
                    .readiness = readiness_reader,
                    .authority = authority_reader,
                    .retry = retry_reader,
                };
            }
            return entry.value_ptr;
        }

        pub fn value(self: *Self, key: K) !ValueReader {
            const r = try self.scopeReaders(key);
            return .{ .owner = self, .key = key, .slot = r.value.slot() };
        }

        pub fn readiness(self: *Self, key: K) !ReadinessReader {
            const r = try self.scopeReaders(key);
            return .{ .owner = self, .key = key, .slot = r.readiness.slot() };
        }

        pub fn authority(self: *Self, key: K) !AuthorityReader {
            const r = try self.scopeReaders(key);
            return .{ .owner = self, .key = key, .slot = r.authority.slot() };
        }

        pub fn retry(self: *Self, key: K) !RetryReader {
            const r = try self.scopeReaders(key);
            return .{ .owner = self, .key = key, .slot = r.retry.slot() };
        }

        pub fn accepted(self: *const Self) ReceiptCountReader {
            return .{ .owner = self, .channel = .accepted, .slot = self.accepted_reader.slot() };
        }

        pub fn dropped(self: *const Self) ReceiptCountReader {
            return .{ .owner = self, .channel = .dropped, .slot = self.dropped_reader.slot() };
        }

        pub fn errors(self: *const Self) ReceiptCountReader {
            return .{ .owner = self, .channel = .err, .slot = self.error_reader.slot() };
        }

        /// The derived schedule. A poll interval exists only where event delivery
        /// is unavailable, so this is a pure function of the transport and never
        /// invalidates.
        pub fn schedule(self: *const Self) IngressSchedule {
            return self.schedule_value;
        }

        pub fn view(self: *const Self, key: K) ?ScopeView {
            return self.core.view(key);
        }

        pub fn receiptLog(self: *const Self) []const Receipt {
            return self.core.receiptLog();
        }

        pub fn versions(self: *Self, key: K) !IngressScopeVersions {
            const r = try self.scopeReaders(key);
            return .{
                .value = r.value.version(),
                .readiness = r.readiness.version(),
                .authority = r.authority.version(),
                .retry = r.retry.version(),
                .accepted = self.accepted_reader.version(),
                .dropped = self.dropped_reader.version(),
                .err = self.error_reader.version(),
            };
        }

        // --- invalidation ----------------------------------------------------

        /// Clear exactly the reader kinds the core reported, as one graph write.
        fn apply(self: *Self, change: Core.Change) !void {
            self.bump_scratch.clearRetainingCapacity();
            for (change.scopes) |delta| {
                const r = try self.scopeReaders(delta.key);
                if (delta.change.value) {
                    try self.bump_scratch.append(self.allocator, r.value.source);
                }
                if (delta.change.readiness) {
                    try self.bump_scratch.append(self.allocator, r.readiness.source);
                }
                if (delta.change.authority) {
                    try self.bump_scratch.append(self.allocator, r.authority.source);
                }
                if (delta.change.retry) {
                    try self.bump_scratch.append(self.allocator, r.retry.source);
                }
            }
            if (change.accepted_receipts) {
                try self.bump_scratch.append(self.allocator, self.accepted_reader.source);
            }
            if (change.dropped_receipts) {
                try self.bump_scratch.append(self.allocator, self.dropped_reader.source);
            }
            if (change.error_receipts) {
                try self.bump_scratch.append(self.allocator, self.error_reader.source);
            }
            // One publish for the whole set: `bumpSources` holds the graph lock
            // until every source value and invalidation frontier is visible, then
            // drains the eager queue once.
            cell.bumpSources(self.ctx, self.bump_scratch.items);
        }

        // --- mutators ---------------------------------------------------------

        pub fn open(self: *Self, key: K, generation: u64) !void {
            try self.apply(try self.core.open(key, generation));
        }

        pub fn admit(self: *Self, envelope: Envelope) !IngressAdmission {
            const result = try self.core.admit(envelope);
            try self.apply(result.change);
            return result.admission;
        }

        pub fn suspendScope(self: *Self, key: K) !?ReplayRequest {
            const result = try self.core.suspendScope(key);
            try self.apply(result.change);
            return result.replay;
        }

        pub fn reconnect(self: *Self, key: K, generation: u64) !ReplayRequest {
            const result = try self.core.reconnect(key, generation);
            try self.apply(result.change);
            return result.replay;
        }

        pub fn close(self: *Self, key: K) !void {
            try self.apply(try self.core.close(key));
        }

        pub fn fail(self: *Self, key: K, err: IngressError) !void {
            try self.apply(try self.core.fail(key, err));
        }

        pub fn tick(self: *Self, now: u64) !void {
            try self.apply(try self.core.tick(now));
        }

        pub fn drain(self: *Self, key: K) !?T {
            const result = try self.core.drain(key);
            try self.apply(result.change);
            return result.value;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests. The canonical corpus is replayed against all three flavors in
// `ingress_family_conformance.zig`; what lives here is the graph-edge contract
// the corpus cannot state — that the reader kinds are real edges, and that a
// multi-kind transition is ONE frontier walk.
//
// Zig has no closures, so a derived node reaches its owner through a
// module-scope `var` set before construction — the same idiom `work_queue.zig`'s
// edge test uses. Reader handles are minted BEFORE the derived node so no
// compute body ever allocates a graph node mid-recompute.
// ---------------------------------------------------------------------------

const testing = std.testing;

const Cell = IngressCell([]const u8, u64);

/// Handles the test compute bodies read, bound before each derived node is
/// built.
const Bound = struct {
    var value: Cell.ValueReader = undefined;
    var readiness: Cell.ReadinessReader = undefined;
    var authority: Cell.AuthorityReader = undefined;
    var retry: Cell.RetryReader = undefined;
    var accepted: Cell.ReceiptCountReader = undefined;
    var dropped: Cell.ReceiptCountReader = undefined;
    var errors: Cell.ReceiptCountReader = undefined;

    fn bind(ing: *Cell, key: []const u8) !void {
        value = try ing.value(key);
        readiness = try ing.readiness(key);
        authority = try ing.authority(key);
        retry = try ing.retry(key);
        accepted = ing.accepted();
        dropped = ing.dropped();
        errors = ing.errors();
    }
};

test "lazily/ingress: reader kinds form real graph edges, per kind" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var ing = try Cell.init(ctx, .{}, merge.sum(u64), .event_channel, 25);
    defer ing.deinit();
    try Bound.bind(&ing, "alpha");

    const Derived = struct {
        var window_runs: usize = 0;
        var retry_runs: usize = 0;

        fn window(view: *Compute) !u64 {
            window_runs += 1;
            return view.get(Bound.value) orelse 0;
        }

        fn retryAttempt(view: *Compute) !u64 {
            retry_runs += 1;
            const r = view.get(Bound.retry);
            return if (r) |x| @as(u64, x.attempt) else 0;
        }
    };
    Derived.window_runs = 0;
    Derived.retry_runs = 0;

    const window = try cell.computed(u64, ctx, Derived.window, null);
    defer ctx.allocator.destroy(window);
    const attempt = try cell.computed(u64, ctx, Derived.retryAttempt, null);
    defer ctx.allocator.destroy(attempt);
    try testing.expectEqual(@as(u64, 0), window.get().*);
    try testing.expectEqual(@as(u64, 0), attempt.get().*);

    // A delivery dirties all four kinds, so both readers recompute.
    var before_window = Derived.window_runs;
    var before_retry = Derived.retry_runs;
    _ = try ing.admit(Cell.Envelope.init("alpha", 1, 0, 0, 5));
    try testing.expectEqual(@as(u64, 5), window.get().*);
    try testing.expectEqual(@as(u64, 0), attempt.get().*);
    try testing.expectEqual(before_window + 1, Derived.window_runs);
    try testing.expectEqual(before_retry + 1, Derived.retry_runs);

    // An error dirties retry ONLY. A window reader that recomputed here would be
    // the over-invalidation the fixtures assert against.
    before_window = Derived.window_runs;
    before_retry = Derived.retry_runs;
    try ing.fail("alpha", .transport_closed);
    try testing.expectEqual(@as(u64, 5), window.get().*);
    try testing.expectEqual(@as(u64, 1), attempt.get().*);
    try testing.expectEqual(before_window, Derived.window_runs);
    try testing.expectEqual(before_retry + 1, Derived.retry_runs);

    // A buffered envelope dirties nothing at all once the scope exists.
    before_window = Derived.window_runs;
    before_retry = Derived.retry_runs;
    _ = try ing.admit(Cell.Envelope.init("alpha", 1, 5, 0, 1));
    try testing.expectEqual(@as(u64, 5), window.get().*);
    try testing.expectEqual(@as(u64, 1), attempt.get().*);
    try testing.expectEqual(before_window, Derived.window_runs);
    try testing.expectEqual(before_retry, Derived.retry_runs);
}

test "lazily/ingress: one admission is one frontier walk" {
    // The gate the thread-safe flavor's `batch()` exists for, asserted on the
    // single-threaded graph too: an Effect reading several reader kinds of the
    // same scope must run ONCE for an admission that dirties all four, not once
    // per kind. Two runs would mean a reader could observe
    // `new value, old authority`.
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var ing = try Cell.init(ctx, .{}, merge.sum(u64), .event_channel, 25);
    defer ing.deinit();
    try Bound.bind(&ing, "alpha");

    const Watcher = struct {
        var runs: usize = 0;
        var last_window: ?u64 = null;
        var last_generation: ?u64 = null;

        fn body(view: *Compute) !void {
            runs += 1;
            last_window = view.get(Bound.value);
            const auth = view.get(Bound.authority);
            last_generation = if (auth) |a| a.generation else null;
            _ = view.get(Bound.readiness);
            _ = view.get(Bound.retry);
        }
    };
    Watcher.runs = 0;
    Watcher.last_window = null;
    Watcher.last_generation = null;

    const watcher = try effect.effectNoCleanup(ctx, Watcher.body);
    defer ctx.allocator.destroy(watcher);
    try testing.expectEqual(@as(usize, 1), Watcher.runs);

    _ = try ing.admit(Cell.Envelope.init("alpha", 3, 0, 0, 5));
    try testing.expectEqual(@as(usize, 2), Watcher.runs);
    // The effect saw the whole transition, not a prefix of it.
    try testing.expectEqual(@as(?u64, 5), Watcher.last_window);
    try testing.expectEqual(@as(?u64, 3), Watcher.last_generation);

    // A handoff dirties all four kinds again — still one run.
    _ = try ing.admit(Cell.Envelope.init("alpha", 4, 0, 0, 9));
    try testing.expectEqual(@as(usize, 3), Watcher.runs);
    try testing.expectEqual(@as(?u64, 9), Watcher.last_window);
    try testing.expectEqual(@as(?u64, 4), Watcher.last_generation);
}

test "lazily/ingress: receipt channels invalidate independently" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var ing = try Cell.init(ctx, .{}, merge.sum(u64), .event_channel, 25);
    defer ing.deinit();
    try Bound.bind(&ing, "alpha");

    const Channels = struct {
        var accepted_runs: usize = 0;
        var dropped_runs: usize = 0;
        var error_runs: usize = 0;

        fn acceptedLen(view: *Compute) !u64 {
            accepted_runs += 1;
            return @intCast(view.get(Bound.accepted));
        }
        fn droppedLen(view: *Compute) !u64 {
            dropped_runs += 1;
            return @intCast(view.get(Bound.dropped));
        }
        fn errorLen(view: *Compute) !u64 {
            error_runs += 1;
            return @intCast(view.get(Bound.errors));
        }
    };
    Channels.accepted_runs = 0;
    Channels.dropped_runs = 0;
    Channels.error_runs = 0;

    const accepted = try cell.computed(u64, ctx, Channels.acceptedLen, null);
    defer ctx.allocator.destroy(accepted);
    const dropped = try cell.computed(u64, ctx, Channels.droppedLen, null);
    defer ctx.allocator.destroy(dropped);
    const errors = try cell.computed(u64, ctx, Channels.errorLen, null);
    defer ctx.allocator.destroy(errors);
    _ = accepted.get();
    _ = dropped.get();
    _ = errors.get();

    // An accept must not invalidate a dashboard that only reads drops.
    var a0 = Channels.accepted_runs;
    var d0 = Channels.dropped_runs;
    var e0 = Channels.error_runs;
    _ = try ing.admit(Cell.Envelope.init("alpha", 1, 0, 0, 5));
    try testing.expectEqual(@as(u64, 1), accepted.get().*);
    try testing.expectEqual(@as(u64, 0), dropped.get().*);
    try testing.expectEqual(@as(u64, 0), errors.get().*);
    try testing.expectEqual(a0 + 1, Channels.accepted_runs);
    try testing.expectEqual(d0, Channels.dropped_runs);
    try testing.expectEqual(e0, Channels.error_runs);

    // A duplicate is a drop: the dropped channel only.
    a0 = Channels.accepted_runs;
    d0 = Channels.dropped_runs;
    e0 = Channels.error_runs;
    _ = try ing.admit(Cell.Envelope.init("alpha", 1, 0, 0, 5));
    try testing.expectEqual(@as(u64, 1), dropped.get().*);
    try testing.expectEqual(a0, Channels.accepted_runs);
    try testing.expectEqual(d0 + 1, Channels.dropped_runs);
    try testing.expectEqual(e0, Channels.error_runs);

    // An error moves the error channel only. This is why `invalidates` is
    // asserted per channel and never by receipt COUNT: a stale cache recomputes
    // to the right count, so a count-only gate reports green.
    a0 = Channels.accepted_runs;
    d0 = Channels.dropped_runs;
    e0 = Channels.error_runs;
    try ing.fail("alpha", .decode_failed);
    try testing.expectEqual(@as(u64, 1), errors.get().*);
    try testing.expectEqual(a0, Channels.accepted_runs);
    try testing.expectEqual(d0, Channels.dropped_runs);
    try testing.expectEqual(e0 + 1, Channels.error_runs);
}

test "lazily/ingress: construction validates overflow against the merge algebra" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    const raw: merge.MergePolicy(u64) = .{
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
        Cell.init(ctx, .{ .overflow = .Conflate }, raw, .event_channel, 25),
    );
}

test "lazily/ingress: an empty drain and an in-horizon tick move no version" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var ing = try Cell.init(ctx, .{ .freshness_horizon = 30 }, merge.sum(u64), .bounded_polling, 0);
    defer ing.deinit();

    // A bounded-polling transport gets a bounded interval, never zero.
    try testing.expectEqual(@as(?u64, 1), ing.schedule().poll_interval);

    _ = try ing.admit(Cell.Envelope.init("alpha", 1, 0, 0, 5));
    try testing.expectEqual(@as(?u64, 5), try ing.drain("alpha"));

    const before = try ing.versions("alpha");
    try testing.expectEqual(@as(?u64, null), try ing.drain("alpha"));
    try ing.tick(10);
    try testing.expectEqual(before, try ing.versions("alpha"));

    // Crossing the horizon is readiness-only.
    try ing.tick(100);
    const after = try ing.versions("alpha");
    try testing.expectEqual(before.value, after.value);
    try testing.expectEqual(before.readiness + 1, after.readiness);
    try testing.expectEqual(before.authority, after.authority);
    try testing.expectEqual(before.retry, after.retry);
}

test "lazily/ingress: scopes are independent" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var ing = try Cell.init(ctx, .{}, merge.sum(u64), .event_channel, 25);
    defer ing.deinit();

    _ = try ing.admit(Cell.Envelope.init("alpha", 1, 0, 0, 1));
    const before_alpha = try ing.versions("alpha");
    _ = try ing.admit(Cell.Envelope.init("beta", 1, 0, 0, 2));
    const after_alpha = try ing.versions("alpha");
    try testing.expectEqual(before_alpha.value, after_alpha.value);
    try testing.expectEqual(before_alpha.readiness, after_alpha.readiness);
    try testing.expectEqual(before_alpha.authority, after_alpha.authority);
    try testing.expectEqual(before_alpha.retry, after_alpha.retry);
    // The shared accepted channel DID move — it is one log, keyed by nothing.
    try testing.expectEqual(before_alpha.accepted + 1, after_alpha.accepted);
    // Closing one scope never touches another.
    try ing.close("beta");
    try testing.expectEqual(IngressReadiness.ready, ing.core.readiness("alpha"));
    try testing.expectEqual(@as(?u64, 1), ing.core.peek("alpha"));
    try testing.expectEqual(@as(?u64, 0), ing.view("alpha").?.delivered_through);
}
