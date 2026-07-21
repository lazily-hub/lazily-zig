//! Phase 1 of the RelayCell backpressure plan (#relaycell) — the merge algebra.
//!
//! See lazily-spec/docs/reactive-graph.md § "MergeCell and the merge algebra"
//! and relaycell-backpressure-analysis.md §4.0/§4.3. A merge policy is an
//! associative fold ⊕: T×T→T; the properties it satisfies (associativity always;
//! commutativity = reordering tax; idempotency = durability tax) select which
//! overflow behaviour is sound. `MergeCell` generalizes a plain `Cell` —
//! Cell ≡ MergeCell(KeepLatest) — a source whose write is a merge. Backed by an
//! ordinary cell, so it inherits the Phase-0 ==-guard (`std.meta.eql`) +
//! store-without-cascade.
//!
//! Zig note: the numeric/keep-latest policies (KeepLatest / Sum / Max) are the
//! value-typed core proven here. Allocator-backed collection policies
//! (SetUnion / RawFifo) compose at the RelayCell layer over their own storage.

const std = @import("std");
const Context = @import("context.zig").Context;
const SourceCell = @import("cell.zig").SourceCell;
const ValueFn = @import("context.zig").ValueFn;

/// An associative merge ⊕ with its transport-selected property flags.
/// Associativity ((a⊕b)⊕c == a⊕(b⊕c)) is a law, verified by the law-tests, not a
/// flag. `commutative` is the reordering tax; `idempotent` the durability tax;
/// `conflates` gates the Conflate overflow (Phase 2).
pub fn MergePolicy(comptime T: type) type {
    return struct {
        name: []const u8,
        merge: *const fn (old: T, op: T) T,
        commutative: bool,
        idempotent: bool,
        conflates: bool,
    };
}

/// Keep-latest band (old ⊕ op = op) — the policy behind a plain Cell.
pub fn keepLatest(comptime T: type) MergePolicy(T) {
    return .{
        .name = "KeepLatest",
        .merge = struct {
            fn f(_: T, op: T) T {
                return op;
            }
        }.f,
        .commutative = false,
        .idempotent = true,
        .conflates = true,
    };
}

/// Additive commutative monoid (old + op). Not idempotent.
pub fn sum(comptime T: type) MergePolicy(T) {
    return .{
        .name = "Sum",
        .merge = struct {
            fn f(a: T, b: T) T {
                return a + b;
            }
        }.f,
        .commutative = true,
        .idempotent = false,
        .conflates = true,
    };
}

/// Max semilattice (max(old, op)). Associative, commutative, idempotent.
pub fn max(comptime T: type) MergePolicy(T) {
    return .{
        .name = "Max",
        .merge = struct {
            fn f(a: T, b: T) T {
                return if (b > a) b else a;
            }
        }.f,
        .commutative = true,
        .idempotent = true,
        .conflates = true,
    };
}

/// A cell whose write is a merge under `policy` rather than a replace.
/// Cell ≡ MergeCell(KeepLatest). `merge` routes through the cell's ==-guarded
/// `set`, so an idempotent policy's no-op merge fires no cascade (free dedup).
pub fn MergeCell(comptime T: type) type {
    return struct {
        cell: *SourceCell(T),
        policy: MergePolicy(T),

        /// Init a MergeCell whose initial value is produced by `valueFn` (the
        /// same comptime-value idiom as `SourceCell.init`).
        pub fn init(
            ctx: *Context,
            comptime valueFn: *const ValueFn(T),
            policy: MergePolicy(T),
        ) !@This() {
            return .{ .cell = try SourceCell(T).init(ctx, valueFn, null), .policy = policy };
        }

        /// The underlying reactive cell (for wiring derived readers).
        pub fn underlying(self: *const @This()) *SourceCell(T) {
            return self.cell;
        }

        /// Read the current converged value.
        pub fn get(self: *const @This()) T {
            return self.cell.get();
        }

        /// Replace the value outright (the keep-latest write), bypassing the policy.
        pub fn set(self: *@This(), value: T) void {
            self.cell.set(value);
        }

        /// Fold `op` into the current value under the policy.
        pub fn merge(self: *@This(), op: T) void {
            self.cell.set(self.policy.merge(self.cell.get(), op));
        }
    };
}

// ---------------------------------------------------------------------------
// Law-tests (#relaycell Phase 1). Associativity for every policy; commutativity
// and idempotency asserted per flag.
// ---------------------------------------------------------------------------

test "merge algebra: associativity for every policy" {
    const policies = .{ keepLatest(i64), sum(i64), max(i64) };
    inline for (policies) |p| {
        const a: i64 = 5;
        const b: i64 = -3;
        const c: i64 = 8;
        try std.testing.expectEqual(
            p.merge(p.merge(a, b), c),
            p.merge(a, p.merge(b, c)),
        );
    }
}

test "merge algebra: commutativity matches the flag" {
    const s = sum(i64);
    const m = max(i64);
    try std.testing.expect(s.commutative and m.commutative);
    try std.testing.expectEqual(s.merge(s.merge(1, 2), 3), s.merge(s.merge(1, 3), 2));
    try std.testing.expectEqual(m.merge(m.merge(1, 2), 3), m.merge(m.merge(1, 3), 2));
    // KeepLatest is NOT commutative.
    const kl = keepLatest(i64);
    try std.testing.expect(!kl.commutative);
    try std.testing.expect(kl.merge(kl.merge(0, 1), 2) != kl.merge(kl.merge(0, 2), 1));
}

test "merge algebra: idempotency matches the flag" {
    const m = max(i64);
    try std.testing.expect(m.idempotent);
    try std.testing.expectEqual(m.merge(m.merge(3, 9), 9), m.merge(3, 9));
    // Sum is NOT idempotent.
    const s = sum(i64);
    try std.testing.expect(!s.idempotent);
    try std.testing.expect(s.merge(s.merge(0, 5), 5) != s.merge(0, 5));
}

test "MergeCell: Cell ≡ MergeCell(KeepLatest), Sum accumulates" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var mc = try MergeCell(i64).init(ctx, struct {
        fn f(_: *Context) !i64 {
            return 0;
        }
    }.f, sum(i64));
    for ([_]i64{ 1, 2, 3, 4 }) |d| mc.merge(d);
    try std.testing.expectEqual(@as(i64, 10), mc.get());
}

test "MergeCell: converged determinism mirrors mergecell_algebra.json" {
    // Inline mirror of lazily-spec/conformance/collections/mergecell_algebra.json
    // (zig has no collections-JSON harness): same op streams → same converged
    // values as lazily-rs / lazily-js / lazily-py / lazily-go.
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    // Sum, initial 0: 5,-3,8,2,0 → 12
    var s = try MergeCell(i64).init(ctx, struct {
        fn f(_: *Context) !i64 {
            return 0;
        }
    }.f, sum(i64));
    for ([_]i64{ 5, -3, 8, 2, 0 }) |op| s.merge(op);
    try std.testing.expectEqual(@as(i64, 12), s.get());

    // Max, initial 10: 5,10,42,0,42 → 42
    var m = try MergeCell(i64).init(ctx, struct {
        fn f(_: *Context) !i64 {
            return 10;
        }
    }.f, max(i64));
    for ([_]i64{ 5, 10, 42, 0, 42 }) |op| m.merge(op);
    try std.testing.expectEqual(@as(i64, 42), m.get());
}
