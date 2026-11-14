//! `EgressCell` — the single-threaded shell of the transport-agnostic reactive
//! egress family (`#lzegress`).
//!
//! The shell owns the graph; [`EgressCore`](egress_core.zig) owns delivery
//! authority. Every core mutator reports which reader kinds the transition
//! dirtied, and this shell bumps exactly that set — no more (over-invalidation
//! re-runs a transport that has nothing new to send) and no less
//! (under-invalidation freezes the window after an acknowledgement).
//!
//! | Reader | Reads | Dirtied by |
//! |---|---|---|
//! | `pending` | records awaiting a send attempt | enqueue, claim, retry_now, a pruning ack, reconnect replay |
//! | `inflight` | the unacknowledged window | claim, fail, a pruning ack, reconnect replay |
//! | `acked_through` | the cumulative watermark | an advancing ack |
//! | `retry` | the last failure's retry decision | fail, and whatever clears it |
//!
//! # No observers — only graph edges
//!
//! Each reader kind is a real `Source(u64)` node (the shared
//! [`ReaderKind`](reader_kind.zig) identity the queue/map/ingress families use);
//! a reader derives its value from core storage on demand. A transition that
//! dirties several kinds lands as ONE `bumpSources` frontier walk.
//!
//! # Transport
//!
//! Transport I/O lives in exactly one Effect per attachment
//! ([`attachTransport`]). The attachment captures the producer generation at
//! attach time, so after a `reconnect` the old attachment is inert at the core's
//! generation fence and the caller attaches one replacement for the new
//! incarnation. A transport is any type with
//! `fn send(self: *Tr, envelope: Envelope) bool` — `true` means the transport
//! accepted the attempt; domain delivery is proven later by `ack`.

const std = @import("std");
const Context = @import("context.zig").Context;
const Compute = @import("context.zig").Compute;
const Slot = @import("context.zig").Slot;
const cell = @import("cell.zig");
const effect_mod = @import("effect.zig");
const ReaderKind = @import("reader_kind.zig").ReaderKind;
const core_mod = @import("egress_core.zig");

pub const EgressCore = core_mod.EgressCore;
pub const EgressPolicy = core_mod.EgressPolicy;
pub const EgressConfigError = core_mod.EgressConfigError;
pub const EgressEnvelope = core_mod.EgressEnvelope;
pub const EgressRetry = core_mod.EgressRetry;
pub const EgressClaim = core_mod.EgressClaim;
pub const EgressAck = core_mod.EgressAck;
pub const EgressFailure = core_mod.EgressFailure;
pub const EgressRetryAction = core_mod.EgressRetryAction;
pub const EgressReconnect = core_mod.EgressReconnect;
pub const EgressChange = core_mod.EgressChange;

/// Per-reader-kind version counters. A version that did not move is the
/// operational reading of "this reader was not invalidated"; the conformance
/// runner additionally probes real derived-node cache validity.
pub const EgressVersions = struct {
    pending: u64,
    inflight: u64,
    acked_through: u64,
    retry: u64,
};

/// Reactive egress on a single-threaded [`Context`]. The cell's address must be
/// stable once a reader or attachment has been handed out (they carry `*Self`):
/// keep it in a `var` or on the heap and pass `&cell`.
pub fn EgressCell(comptime T: type) type {
    return struct {
        const Self = @This();

        pub const Core = EgressCore(T);
        pub const Envelope = Core.Envelope;
        pub const Claim = Core.Claim;

        pub const PendingReader = struct {
            owner: *const Self,
            slot: *Slot,

            pub fn get(self: @This()) []const Envelope {
                return self.owner.core.pending();
            }
        };

        pub const InflightReader = struct {
            owner: *const Self,
            slot: *Slot,

            pub fn get(self: @This()) []const Envelope {
                return self.owner.core.inflight();
            }
        };

        pub const AckedThroughReader = struct {
            owner: *const Self,
            slot: *Slot,

            pub fn get(self: @This()) ?u64 {
                return self.owner.core.ackedThrough();
            }
        };

        pub const RetryReader = struct {
            owner: *const Self,
            slot: *Slot,

            pub fn get(self: @This()) ?EgressRetry {
                return self.owner.core.retry();
            }
        };

        ctx: *Context,
        core: Core,
        pending_kind: ReaderKind,
        inflight_kind: ReaderKind,
        acked_kind: ReaderKind,
        retry_kind: ReaderKind,

        pub fn init(ctx: *Context, initial_generation: u64, policy: EgressPolicy) !Self {
            var core = try Core.init(ctx.allocator, initial_generation, policy);
            errdefer core.deinit();
            const pending_kind = try ReaderKind.init(ctx);
            errdefer pending_kind.dispose();
            const inflight_kind = try ReaderKind.init(ctx);
            errdefer inflight_kind.dispose();
            const acked_kind = try ReaderKind.init(ctx);
            errdefer acked_kind.dispose();
            const retry_kind = try ReaderKind.init(ctx);
            return .{
                .ctx = ctx,
                .core = core,
                .pending_kind = pending_kind,
                .inflight_kind = inflight_kind,
                .acked_kind = acked_kind,
                .retry_kind = retry_kind,
            };
        }

        pub fn deinit(self: *Self) void {
            self.pending_kind.dispose();
            self.inflight_kind.dispose();
            self.acked_kind.dispose();
            self.retry_kind.dispose();
            self.core.deinit();
        }

        // --- reader handles --------------------------------------------------

        pub fn pendingReader(self: *const Self) PendingReader {
            return .{ .owner = self, .slot = self.pending_kind.slot() };
        }

        pub fn inflightReader(self: *const Self) InflightReader {
            return .{ .owner = self, .slot = self.inflight_kind.slot() };
        }

        pub fn ackedThroughReader(self: *const Self) AckedThroughReader {
            return .{ .owner = self, .slot = self.acked_kind.slot() };
        }

        pub fn retryReader(self: *const Self) RetryReader {
            return .{ .owner = self, .slot = self.retry_kind.slot() };
        }

        // --- reads -----------------------------------------------------------

        pub fn generation(self: *const Self) u64 {
            return self.core.generation();
        }

        pub fn nextSequence(self: *const Self) u64 {
            return self.core.nextSequence();
        }

        /// Borrowed, valid until the next mutation.
        pub fn pending(self: *const Self) []const Envelope {
            return self.core.pending();
        }

        /// Borrowed, valid until the next mutation.
        pub fn inflight(self: *const Self) []const Envelope {
            return self.core.inflight();
        }

        pub fn ackedThrough(self: *const Self) ?u64 {
            return self.core.ackedThrough();
        }

        pub fn retry(self: *const Self) ?EgressRetry {
            return self.core.retry();
        }

        pub fn versions(self: *const Self) EgressVersions {
            return .{
                .pending = self.pending_kind.version(),
                .inflight = self.inflight_kind.version(),
                .acked_through = self.acked_kind.version(),
                .retry = self.retry_kind.version(),
            };
        }

        // --- invalidation ------------------------------------------------------

        /// Bump exactly the reader kinds the core reported, as one graph write.
        fn apply(self: *Self, change: EgressChange) void {
            if (change.isEmpty()) return;
            var sources: [4]*cell.Source(u64) = undefined;
            var n: usize = 0;
            if (change.pending) {
                sources[n] = self.pending_kind.source;
                n += 1;
            }
            if (change.inflight) {
                sources[n] = self.inflight_kind.source;
                n += 1;
            }
            if (change.acked_through) {
                sources[n] = self.acked_kind.source;
                n += 1;
            }
            if (change.retry) {
                sources[n] = self.retry_kind.source;
                n += 1;
            }
            cell.bumpSources(self.ctx, sources[0..n]);
        }

        // --- mutators ----------------------------------------------------------

        pub fn enqueue(self: *Self, payload: T) !u64 {
            const t = try self.core.enqueue(payload);
            self.apply(t.change);
            return t.outcome;
        }

        pub fn claim(self: *Self, attachment_generation: u64) !Claim {
            const t = try self.core.claim(attachment_generation);
            self.apply(t.change);
            return t.outcome;
        }

        pub fn ack(self: *Self, attachment_generation: u64, through: u64) EgressAck {
            const t = self.core.ack(attachment_generation, through);
            self.apply(t.change);
            return t.outcome;
        }

        pub fn fail(self: *Self, attachment_generation: u64, sequence: u64) !EgressFailure {
            const t = try self.core.fail(attachment_generation, sequence);
            self.apply(t.change);
            return t.outcome;
        }

        pub fn retryNow(self: *Self, attachment_generation: u64, sequence: u64) !EgressRetryAction {
            const t = try self.core.retryNow(attachment_generation, sequence);
            self.apply(t.change);
            return t.outcome;
        }

        pub fn reconnect(self: *Self, new_generation: u64) !EgressReconnect {
            const t = try self.core.reconnect(new_generation);
            self.apply(t.change);
            return t.outcome;
        }

        // --- transport attachment ----------------------------------------------

        /// One transport Effect, bound to the generation current at attach time.
        pub fn Attachment(comptime Tr: type) type {
            return struct {
                const Att = @This();

                const Binding = struct {
                    cell: *Self,
                    transport: *Tr,
                    generation: u64,
                };

                /// Zig has no closures and a single-threaded `Context` effect body
                /// is comptime, so the body finds its binding by the effect's own
                /// cache key. The key is reserved BEFORE the effect is built, so
                /// even the first run sees its binding.
                var registry: std.AutoHashMapUnmanaged(usize, *Binding) = .empty;

                allocator: std.mem.Allocator,
                key: usize,
                binding: *Binding,
                effect: *effect_mod.Effect(void),

                fn body(view: *Compute) anyerror!?void {
                    const b = registry.get(view.node.cache_key.?) orelse return null;
                    // `inflight` is a dependency even though the core is the
                    // authority: an acknowledgement reopens the window and must
                    // re-run this same attachment.
                    _ = view.get(b.cell.inflightReader());
                    if (view.get(b.cell.pendingReader()).len == 0) return null;
                    while (true) {
                        switch (try b.cell.claim(b.generation)) {
                            .claimed => |envelope| {
                                if (!b.transport.send(envelope)) {
                                    _ = try b.cell.fail(b.generation, envelope.sequence);
                                    break;
                                }
                            },
                            else => break,
                        }
                    }
                    return null;
                }

                /// Remove the Effect from the graph and free the binding.
                pub fn detach(self: *Att) void {
                    self.effect.disposeNode();
                    self.allocator.destroy(self.effect);
                    _ = registry.remove(self.key);
                    if (registry.count() == 0) {
                        // Free the table with the last attachment, so a registry
                        // never outlives every cell that used it.
                        registry.deinit(self.allocator);
                        registry = .empty;
                    }
                    self.allocator.destroy(self.binding);
                    self.* = undefined;
                }
            };
        }

        pub fn attachTransport(self: *Self, comptime Tr: type, transport: *Tr) !Attachment(Tr) {
            const Att = Attachment(Tr);
            const allocator = self.ctx.allocator;
            const key = try self.ctx.reserveDynamicCacheKey();
            const binding = try allocator.create(Att.Binding);
            errdefer allocator.destroy(binding);
            binding.* = .{ .cell = self, .transport = transport, .generation = self.generation() };
            try Att.registry.put(allocator, key, binding);
            errdefer _ = Att.registry.remove(key);
            const handle = try effect_mod.effectKeyed(void, self.ctx, key, Att.body);
            return .{ .allocator = allocator, .key = key, .binding = binding, .effect = handle };
        }
    };
}

// ---------------------------------------------------------------------------
// Tests. The canonical corpus is replayed against all three flavors in
// `egress_family_conformance.zig`; what lives here is the transport Effect the
// corpus does not describe, and the per-kind graph-edge contract.
// ---------------------------------------------------------------------------

const testing = std.testing;
const Cell = EgressCell(u64);

const TestTransport = struct {
    sent: std.ArrayList(u64) = .empty,
    fail_next: bool = false,

    fn deinit(self: *TestTransport) void {
        self.sent.deinit(testing.allocator);
    }

    pub fn send(self: *TestTransport, envelope: Cell.Envelope) bool {
        if (self.fail_next) {
            self.fail_next = false;
            return false;
        }
        self.sent.append(testing.allocator, envelope.sequence) catch return false;
        return true;
    }
};

test "lazily/egress: one Effect projects pending to the transport and the window" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var egress = try Cell.init(ctx, 1, .{});
    defer egress.deinit();
    var transport: TestTransport = .{};
    defer transport.deinit();
    var attachment = try egress.attachTransport(TestTransport, &transport);
    defer attachment.detach();

    _ = try egress.enqueue(10);
    _ = try egress.enqueue(20);
    try testing.expectEqualSlices(u64, &.{ 0, 1 }, transport.sent.items);
    try testing.expectEqual(@as(usize, 0), egress.pending().len);
    try testing.expectEqual(@as(usize, 2), egress.inflight().len);
}

test "lazily/egress: reconnect makes the old attachment inert" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var egress = try Cell.init(ctx, 3, .{});
    defer egress.deinit();
    var old: TestTransport = .{};
    defer old.deinit();
    var old_attachment = try egress.attachTransport(TestTransport, &old);
    defer old_attachment.detach();

    _ = try egress.enqueue(10);
    _ = try egress.reconnect(4);
    _ = try egress.enqueue(20);
    try testing.expectEqualSlices(u64, &.{0}, old.sent.items);

    var fresh: TestTransport = .{};
    defer fresh.deinit();
    var fresh_attachment = try egress.attachTransport(TestTransport, &fresh);
    defer fresh_attachment.detach();
    try testing.expectEqualSlices(u64, &.{ 0, 1 }, fresh.sent.items);
}

test "lazily/egress: an ack reopens the window without a request/ack handshake" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var egress = try Cell.init(ctx, 1, .{ .inflight_limit = 1 });
    defer egress.deinit();
    var transport: TestTransport = .{};
    defer transport.deinit();
    var attachment = try egress.attachTransport(TestTransport, &transport);
    defer attachment.detach();

    _ = try egress.enqueue(10);
    _ = try egress.enqueue(20);
    try testing.expectEqualSlices(u64, &.{0}, transport.sent.items);
    try testing.expectEqual(@as(usize, 1), egress.pending().len);

    try testing.expectEqual(EgressAck{ .advanced = 0 }, egress.ack(1, 0));
    try testing.expectEqualSlices(u64, &.{ 0, 1 }, transport.sent.items);
    try testing.expectEqual(@as(usize, 0), egress.pending().len);
}

test "lazily/egress: a refused send parks the record and stops the pump" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var egress = try Cell.init(ctx, 1, .{});
    defer egress.deinit();
    var transport: TestTransport = .{ .fail_next = true };
    defer transport.deinit();
    var attachment = try egress.attachTransport(TestTransport, &transport);
    defer attachment.detach();

    _ = try egress.enqueue(10);
    try testing.expectEqual(@as(usize, 0), transport.sent.items.len);
    try testing.expectEqual(@as(u32, 1), egress.retry().?.attempt);
    try testing.expectEqual(@as(usize, 0), egress.inflight().len);
    // An explicit retry re-enters pending and the same attachment sends it.
    _ = try egress.retryNow(1, 0);
    try testing.expectEqualSlices(u64, &.{0}, transport.sent.items);
    try testing.expectEqual(@as(u32, 2), egress.inflight()[0].attempt);
}

test "lazily/egress: reader kinds invalidate independently" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var egress = try Cell.init(ctx, 1, .{});
    defer egress.deinit();

    const before = egress.versions();
    _ = try egress.enqueue(1);
    const after = egress.versions();
    try testing.expectEqual(before.pending + 1, after.pending);
    try testing.expectEqual(before.inflight, after.inflight);
    try testing.expectEqual(before.acked_through, after.acked_through);
    try testing.expectEqual(before.retry, after.retry);
}
