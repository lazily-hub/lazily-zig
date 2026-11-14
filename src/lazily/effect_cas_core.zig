//! Generic keyed compare-and-swap effect authority (`#lzeffectcas`).
//!
//! The pure core owns effect identity, keyed single-flight, latest-wins
//! coalescing, logical-clock retry timing, reconnect fencing, exact receipt
//! matching, and the cursor of an ordered effect plan. Backends stay
//! application-owned: they observe an opaque authority token `A` and execute
//! one atomic compare-and-apply per attempt the core hands out.
//!
//! Contract: lazily-spec `conformance/egress/effect_cas.json`, mirroring the
//! lazily-rs reference `EffectCasCore`.
//!
//! Ownership: keys, identities, plans, payloads, receipts and errors are
//! BORROWED — the caller keeps them alive for the core's lifetime, matching the
//! other Zig cores. The core owns only its receipt lists. A `Claim.claimed`
//! attempt's `prior_receipts` is a borrowed view valid until the next mutation.
//!
//! Not ported: the reference's `durable_state()` / `hydrate()` crash-recovery
//! image. The corpus does not exercise it, and this binding ships no serde
//! layer to round-trip it through.

const std = @import("std");

pub fn HashMapFor(comptime K: type, comptime V: type) type {
    if (K == []const u8) return std.StringHashMap(V);
    return std.AutoHashMap(K, V);
}

/// Equality for the generic payload slots: byte slices by content, everything
/// else structurally.
fn eqlValue(comptime T: type, a: T, b: T) bool {
    if (T == []const u8) return std.mem.eql(u8, a, b);
    return std.meta.eql(a, b);
}

pub const EffectCasPlanError = error{EmptyPlan};
pub const EffectCasIdentityError = error{EmptyIdentity};

/// Exact identity of one adapter call.
pub const EffectAttemptIdentity = struct {
    effect: []const u8,
    generation: u64,
    epoch: u64,
    step: usize,
    attempt: u32,

    pub fn eql(a: EffectAttemptIdentity, b: EffectAttemptIdentity) bool {
        return std.mem.eql(u8, a.effect, b.effect) and a.generation == b.generation and
            a.epoch == b.epoch and a.step == b.step and a.attempt == b.attempt;
    }
};

pub const EffectTerminalKind = enum { applied, superseded, rejected };

pub const EffectCasChange = struct { state: bool = false };

pub fn EffectCasTransition(comptime Outcome: type) type {
    return struct { change: EffectCasChange, outcome: Outcome };
}

pub const EffectCasUpsert = union(enum) {
    accepted,
    unchanged,
    already_applied: u64,
    stale_epoch: u64,
    epoch_conflict,
};

pub const EffectCasApplied = union(enum) {
    step_applied: usize,
    completed: u64,
    superseded,
    duplicate,
    unknown_attempt,
    stale_generation: u64,
};

pub const EffectCasFailure = union(enum) {
    superseded,
    retrying: u64,
    rejected,
    unknown_attempt,
    stale_generation: u64,
};

pub const EffectCasReconnect = union(enum) {
    advanced: struct { generation: u64, requeued: usize, superseded: usize },
    unchanged: u64,
    stale_generation: u64,
};

/// Pure keyed effect-CAS orchestration authority over key `K`, opaque
/// authority `A`, plan payload `P`, receipt `R`, and adapter error `E`.
pub fn EffectCasCore(comptime K: type, comptime A: type, comptime P: type, comptime R: type, comptime E: type) type {
    return struct {
        const Self = @This();

        /// Immutable desired effect. One epoch names exactly one identity and
        /// plan. The plan is an ordered, non-empty list of idempotent payloads.
        pub const Intent = struct {
            identity: []const u8,
            epoch: u64,
            key: K,
            expected: A,
            plan: []const P,

            fn eql(a: Intent, b: Intent) bool {
                if (!std.mem.eql(u8, a.identity, b.identity) or a.epoch != b.epoch) return false;
                if (!eqlValue(K, a.key, b.key) or !eqlValue(A, a.expected, b.expected)) return false;
                if (a.plan.len != b.plan.len) return false;
                for (a.plan, b.plan) |x, y| if (!eqlValue(P, x, y)) return false;
                return true;
            }
        };

        /// A successful step receipt, retained as lineage for later plan steps.
        pub const Receipt = struct {
            attempt: EffectAttemptIdentity,
            receipt: R,
            authority: A,
        };

        /// The exact compare-and-apply call handed to an application adapter.
        pub const Attempt = struct {
            identity: EffectAttemptIdentity,
            key: K,
            expected: A,
            payload: P,
            prior_receipts: []const Receipt,
        };

        pub const Pending = struct {
            intent: Intent,
            next_step: usize,
            expected: A,
            receipts: std.ArrayList(Receipt),
            next_attempt: u32,
            ready_at: ?u64,
        };

        pub const Retry = struct {
            attempt: EffectAttemptIdentity,
            err: E,
            retry_at: u64,
        };

        pub const Terminal = struct {
            kind: EffectTerminalKind,
            identity: []const u8,
            epoch: u64,
            /// Superseded only: the authority the backend reported, when known.
            observed: ?A = null,
            /// Rejected only.
            err: ?E = null,
            receipts: std.ArrayList(Receipt),
        };

        const Inflight = struct {
            retained: Pending,
            attempt: Attempt,
        };

        const Entry = struct {
            pending: ?Pending = null,
            inflight: ?Inflight = null,
            retry: ?Retry = null,
            applied_through: ?u64 = null,
            terminal: ?Terminal = null,
            terminal_intent: ?Intent = null,
        };

        /// Borrowed reader projection of one key, valid until the next mutation.
        pub const KeyState = struct {
            pending: ?*const Pending,
            inflight: ?*const Attempt,
            retry: ?Retry,
            applied_through: ?u64,
            terminal: ?*const Terminal,
        };

        pub const Claim = union(enum) {
            claimed: Attempt,
            empty,
            busy,
            waiting: u64,
            stale_generation: u64,
        };

        allocator: std.mem.Allocator,
        current_generation: u64,
        keys: HashMapFor(K, Entry),

        pub fn init(allocator: std.mem.Allocator, initial_generation: u64) Self {
            return .{
                .allocator = allocator,
                .current_generation = initial_generation,
                .keys = HashMapFor(K, Entry).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            var it = self.keys.valueIterator();
            while (it.next()) |entry| {
                if (entry.pending) |*p| p.receipts.deinit(self.allocator);
                if (entry.inflight) |*f| f.retained.receipts.deinit(self.allocator);
                if (entry.terminal) |*t| t.receipts.deinit(self.allocator);
            }
            self.keys.deinit();
            self.* = undefined;
        }

        /// Validate and build an intent. Identity and plan must be non-empty.
        pub fn intent(identity: []const u8, epoch: u64, key: K, expected: A, plan: []const P) (EffectCasPlanError || EffectCasIdentityError)!Intent {
            if (identity.len == 0) return error.EmptyIdentity;
            if (plan.len == 0) return error.EmptyPlan;
            return .{ .identity = identity, .epoch = epoch, .key = key, .expected = expected, .plan = plan };
        }

        // --- projections -----------------------------------------------------

        pub fn generation(self: *const Self) u64 {
            return self.current_generation;
        }

        pub fn keyCount(self: *const Self) usize {
            return self.keys.count();
        }

        pub fn state(self: *const Self, key: K) ?KeyState {
            const entry = self.keys.getPtr(key) orelse return null;
            return .{
                .pending = if (entry.pending) |*p| p else null,
                .inflight = if (entry.inflight) |*f| &f.attempt else null,
                .retry = entry.retry,
                .applied_through = entry.applied_through,
                .terminal = if (entry.terminal) |*t| t else null,
            };
        }

        /// Keys with ready work at logical time `now` (no attempt in flight and
        /// no retry delay pending). Caller owns the returned slice.
        pub fn pendingKeys(self: *const Self, allocator: std.mem.Allocator, now: u64) ![]K {
            var out: std.ArrayList(K) = .empty;
            errdefer out.deinit(allocator);
            var it = self.keys.iterator();
            while (it.next()) |kv| {
                const entry = kv.value_ptr;
                if (entry.inflight != null) continue;
                const p = entry.pending orelse continue;
                if (p.ready_at) |at| if (at > now) continue;
                try out.append(allocator, kv.key_ptr.*);
            }
            return out.toOwnedSlice(allocator);
        }

        // --- helpers ---------------------------------------------------------

        fn setTerminal(self: *Self, entry: *Entry, terminal: Terminal, terminal_intent: Intent) void {
            if (entry.terminal) |*old| old.receipts.deinit(self.allocator);
            entry.terminal = terminal;
            entry.terminal_intent = terminal_intent;
        }

        fn newerPending(entry: *const Entry, epoch: u64) bool {
            return if (entry.pending) |p| p.intent.epoch > epoch else false;
        }

        // --- transitions -----------------------------------------------------

        pub fn upsertDesired(self: *Self, desired: Intent) !EffectCasTransition(EffectCasUpsert) {
            const gop = try self.keys.getOrPut(desired.key);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            const entry = gop.value_ptr;
            if (entry.applied_through) |applied| {
                if (desired.epoch <= applied) return .{ .change = .{}, .outcome = .{ .already_applied = applied } };
            }

            var current: ?u64 = null;
            if (entry.pending) |p| current = @max(current orelse 0, p.intent.epoch);
            if (entry.inflight) |f| current = @max(current orelse 0, f.retained.intent.epoch);
            if (entry.terminal_intent) |t| current = @max(current orelse 0, t.epoch);
            if (current) |epoch| {
                if (desired.epoch < epoch) return .{ .change = .{}, .outcome = .{ .stale_epoch = epoch } };
                if (desired.epoch == epoch) {
                    // Against the ORIGINAL submitted intent (identity, epoch,
                    // key, initial `expected`, plan). A partially applied plan
                    // advances `Pending.expected`, never `intent.expected`, so a
                    // re-send of the same desire stays `unchanged`.
                    const same = (if (entry.pending) |p| p.intent.eql(desired) else false) or
                        (if (entry.inflight) |f| f.retained.intent.eql(desired) else false) or
                        (if (entry.terminal_intent) |t| t.eql(desired) else false);
                    return .{ .change = .{}, .outcome = if (same) .unchanged else .epoch_conflict };
                }
            }

            if (entry.pending) |superseded| {
                self.setTerminal(entry, .{
                    .kind = .superseded,
                    .identity = superseded.intent.identity,
                    .epoch = superseded.intent.epoch,
                    .receipts = superseded.receipts,
                }, superseded.intent);
            }
            entry.pending = .{
                .intent = desired,
                .next_step = 0,
                .expected = desired.expected,
                .receipts = .empty,
                .next_attempt = 1,
                .ready_at = null,
            };
            entry.retry = null;
            return .{ .change = .{ .state = true }, .outcome = .accepted };
        }

        pub fn claim(self: *Self, key: K, attachment_generation: u64, now: u64) EffectCasTransition(Claim) {
            if (attachment_generation != self.current_generation) {
                return .{ .change = .{}, .outcome = .{ .stale_generation = self.current_generation } };
            }
            const entry = self.keys.getPtr(key) orelse return .{ .change = .{}, .outcome = .empty };
            if (entry.inflight != null) return .{ .change = .{}, .outcome = .busy };
            const p = entry.pending orelse return .{ .change = .{}, .outcome = .empty };
            if (p.ready_at) |retry_at| {
                if (now < retry_at) return .{ .change = .{}, .outcome = .{ .waiting = retry_at } };
            }
            entry.pending = null;
            entry.inflight = .{ .retained = p, .attempt = undefined };
            const retained = &entry.inflight.?.retained;
            entry.inflight.?.attempt = .{
                .identity = .{
                    .effect = retained.intent.identity,
                    .generation = attachment_generation,
                    .epoch = retained.intent.epoch,
                    .step = retained.next_step,
                    .attempt = retained.next_attempt,
                },
                .key = retained.intent.key,
                .expected = retained.expected,
                .payload = retained.intent.plan[retained.next_step],
                .prior_receipts = retained.receipts.items,
            };
            return .{ .change = .{ .state = true }, .outcome = .{ .claimed = entry.inflight.?.attempt } };
        }

        pub fn recordApplied(
            self: *Self,
            key: K,
            attempt: EffectAttemptIdentity,
            receipt: R,
            authority: A,
        ) !EffectCasTransition(EffectCasApplied) {
            if (attempt.generation != self.current_generation) {
                return .{ .change = .{}, .outcome = .{ .stale_generation = self.current_generation } };
            }
            const entry = self.keys.getPtr(key) orelse return .{ .change = .{}, .outcome = .unknown_attempt };
            if (entry.terminal) |t| {
                for (t.receipts.items) |known| {
                    if (known.attempt.eql(attempt) and eqlValue(R, known.receipt, receipt)) {
                        return .{ .change = .{}, .outcome = .duplicate };
                    }
                }
            }
            const live = entry.inflight orelse return .{ .change = .{}, .outcome = .unknown_attempt };
            if (!live.attempt.identity.eql(attempt)) return .{ .change = .{}, .outcome = .unknown_attempt };

            var retained = live.retained;
            try retained.receipts.append(self.allocator, .{ .attempt = attempt, .receipt = receipt, .authority = authority });
            entry.inflight = null;
            entry.retry = null;

            if (newerPending(entry, retained.intent.epoch)) {
                self.setTerminal(entry, .{
                    .kind = .superseded,
                    .identity = retained.intent.identity,
                    .epoch = retained.intent.epoch,
                    .observed = authority,
                    .receipts = retained.receipts,
                }, retained.intent);
                return .{ .change = .{ .state = true }, .outcome = .superseded };
            }

            const next_step = retained.next_step + 1;
            if (next_step < retained.intent.plan.len) {
                retained.next_step = next_step;
                retained.expected = authority;
                retained.ready_at = null;
                retained.next_attempt = 1;
                entry.pending = retained;
                return .{ .change = .{ .state = true }, .outcome = .{ .step_applied = next_step } };
            }

            const epoch = retained.intent.epoch;
            const frontier = if (entry.applied_through) |old| @max(old, epoch) else epoch;
            entry.applied_through = frontier;
            self.setTerminal(entry, .{
                .kind = .applied,
                .identity = retained.intent.identity,
                .epoch = epoch,
                .receipts = retained.receipts,
            }, retained.intent);
            return .{ .change = .{ .state = true }, .outcome = .{ .completed = frontier } };
        }

        const FailureKind = union(enum) {
            superseded: A,
            retryable: struct { err: E, retry_at: u64 },
            rejected: E,
        };

        pub fn recordSuperseded(self: *Self, key: K, attempt: EffectAttemptIdentity, observed: A) EffectCasTransition(EffectCasFailure) {
            return self.finishFailed(key, attempt, .{ .superseded = observed });
        }

        pub fn recordRetryable(self: *Self, key: K, attempt: EffectAttemptIdentity, err: E, retry_at: u64) EffectCasTransition(EffectCasFailure) {
            return self.finishFailed(key, attempt, .{ .retryable = .{ .err = err, .retry_at = retry_at } });
        }

        pub fn recordRejected(self: *Self, key: K, attempt: EffectAttemptIdentity, err: E) EffectCasTransition(EffectCasFailure) {
            return self.finishFailed(key, attempt, .{ .rejected = err });
        }

        fn finishFailed(self: *Self, key: K, attempt: EffectAttemptIdentity, kind: FailureKind) EffectCasTransition(EffectCasFailure) {
            if (attempt.generation != self.current_generation) {
                return .{ .change = .{}, .outcome = .{ .stale_generation = self.current_generation } };
            }
            const entry = self.keys.getPtr(key) orelse return .{ .change = .{}, .outcome = .unknown_attempt };
            const live = entry.inflight orelse return .{ .change = .{}, .outcome = .unknown_attempt };
            if (!live.attempt.identity.eql(attempt)) return .{ .change = .{}, .outcome = .unknown_attempt };

            var retained = live.retained;
            entry.inflight = null;
            const newer = newerPending(entry, retained.intent.epoch);
            switch (kind) {
                .superseded => |observed| {
                    entry.retry = null;
                    self.setTerminal(entry, .{
                        .kind = .superseded,
                        .identity = retained.intent.identity,
                        .epoch = retained.intent.epoch,
                        .observed = observed,
                        .receipts = retained.receipts,
                    }, retained.intent);
                    return .{ .change = .{ .state = true }, .outcome = .superseded };
                },
                .retryable => |r| {
                    if (newer) {
                        entry.retry = null;
                        self.setTerminal(entry, .{
                            .kind = .superseded,
                            .identity = retained.intent.identity,
                            .epoch = retained.intent.epoch,
                            .receipts = retained.receipts,
                        }, retained.intent);
                        return .{ .change = .{ .state = true }, .outcome = .superseded };
                    }
                    entry.retry = .{ .attempt = attempt, .err = r.err, .retry_at = r.retry_at };
                    retained.next_attempt +|= 1;
                    retained.ready_at = r.retry_at;
                    entry.pending = retained;
                    return .{ .change = .{ .state = true }, .outcome = .{ .retrying = r.retry_at } };
                },
                .rejected => |err| {
                    entry.retry = null;
                    self.setTerminal(entry, .{
                        .kind = .rejected,
                        .identity = retained.intent.identity,
                        .epoch = retained.intent.epoch,
                        .err = err,
                        .receipts = retained.receipts,
                    }, retained.intent);
                    return .{ .change = .{ .state = true }, .outcome = .rejected };
                },
            }
        }

        /// Fence the previous actor generation: every in-flight attempt is
        /// requeued under the SAME effect identity with its attempt counter
        /// advanced, unless a newer desired effect already supersedes it.
        pub fn reconnect(self: *Self, new_generation: u64) EffectCasTransition(EffectCasReconnect) {
            if (new_generation < self.current_generation) {
                return .{ .change = .{}, .outcome = .{ .stale_generation = self.current_generation } };
            }
            if (new_generation == self.current_generation) {
                return .{ .change = .{}, .outcome = .{ .unchanged = self.current_generation } };
            }
            self.current_generation = new_generation;
            var requeued: usize = 0;
            var superseded: usize = 0;
            var it = self.keys.valueIterator();
            while (it.next()) |entry| {
                const live = entry.inflight orelse continue;
                var retained = live.retained;
                entry.inflight = null;
                if (newerPending(entry, retained.intent.epoch)) {
                    self.setTerminal(entry, .{
                        .kind = .superseded,
                        .identity = retained.intent.identity,
                        .epoch = retained.intent.epoch,
                        .receipts = retained.receipts,
                    }, retained.intent);
                    superseded += 1;
                } else {
                    retained.next_attempt +|= 1;
                    retained.ready_at = null;
                    entry.pending = retained;
                    requeued += 1;
                }
            }
            return .{
                .change = .{ .state = true },
                .outcome = .{ .advanced = .{ .generation = new_generation, .requeued = requeued, .superseded = superseded } },
            };
        }
    };
}

const testing = std.testing;
const Core = EffectCasCore([]const u8, u64, []const u8, []const u8, []const u8);

fn claimed(core: *Core, key: []const u8, gen: u64, now: u64) !Core.Attempt {
    return switch (core.claim(key, gen, now).outcome) {
        .claimed => |attempt| attempt,
        else => error.ExpectedClaim,
    };
}

test "lazily/effect_cas_core: an ordered plan advances from receipt authority and dedupes the terminal receipt" {
    var core = Core.init(testing.allocator, 7);
    defer core.deinit();
    _ = try core.upsertDesired(try Core.intent("effect-1", 1, "doc", 10, &.{ "canonical", "snapshot" }));
    const first = try claimed(&core, "doc", 7, 0);
    try testing.expectEqual(@as(u64, 10), first.expected);
    try testing.expectEqual(EffectCasApplied{ .step_applied = 1 }, (try core.recordApplied("doc", first.identity, "r1", 11)).outcome);
    const second = try claimed(&core, "doc", 7, 0);
    try testing.expectEqual(@as(u64, 11), second.expected);
    try testing.expectEqualStrings("snapshot", second.payload);
    try testing.expectEqual(@as(usize, 1), second.prior_receipts.len);
    try testing.expectEqual(EffectCasApplied{ .completed = 1 }, (try core.recordApplied("doc", second.identity, "r2", 12)).outcome);
    try testing.expectEqual(EffectCasApplied.duplicate, (try core.recordApplied("doc", second.identity, "r2", 12)).outcome);
}

test "lazily/effect_cas_core: retry uses the logical clock and a newer desire wins" {
    var core = Core.init(testing.allocator, 1);
    defer core.deinit();
    _ = try core.upsertDesired(try Core.intent("old", 1, "doc", 1, &.{"write"}));
    const old = try claimed(&core, "doc", 1, 0);
    try testing.expectEqual(EffectCasFailure{ .retrying = 9 }, core.recordRetryable("doc", old.identity, "busy", 9).outcome);
    try testing.expectEqual(@as(u64, 9), core.claim("doc", 1, 8).outcome.waiting);
    _ = try core.upsertDesired(try Core.intent("new", 2, "doc", 2, &.{"write"}));
    try testing.expectEqualStrings("new", (try claimed(&core, "doc", 1, 8)).identity.effect);
}

test "lazily/effect_cas_core: stale attempts and an authority mismatch never advance the frontier" {
    var core = Core.init(testing.allocator, 2);
    defer core.deinit();
    _ = try core.upsertDesired(try Core.intent("effect", 4, "doc", 8, &.{"write"}));
    const attempt = try claimed(&core, "doc", 2, 0);
    try testing.expectEqual(EffectCasFailure.superseded, core.recordSuperseded("doc", attempt.identity, 9).outcome);
    try testing.expectEqual(@as(?u64, null), core.state("doc").?.applied_through);
    try testing.expectEqual(EffectCasApplied.unknown_attempt, (try core.recordApplied("doc", attempt.identity, "late", 10)).outcome);
    try testing.expectEqual(@as(?u64, null), core.state("doc").?.applied_through);
}

test "lazily/effect_cas_core: same-epoch upserts are idempotent or conflict, never silently replace" {
    var core = Core.init(testing.allocator, 1);
    defer core.deinit();
    _ = try core.upsertDesired(try Core.intent("a", 3, "doc", 0, &.{"write"}));
    try testing.expectEqual(EffectCasUpsert.unchanged, (try core.upsertDesired(try Core.intent("a", 3, "doc", 0, &.{"write"}))).outcome);
    try testing.expectEqual(EffectCasUpsert.epoch_conflict, (try core.upsertDesired(try Core.intent("b", 3, "doc", 0, &.{"write"}))).outcome);
    try testing.expectEqual(@as(u64, 3), (try core.upsertDesired(try Core.intent("c", 2, "doc", 0, &.{"write"}))).outcome.stale_epoch);
    try testing.expectError(error.EmptyPlan, Core.intent("d", 4, "doc", 0, &.{}));
    try testing.expectError(error.EmptyIdentity, Core.intent("", 4, "doc", 0, &.{"write"}));
}
