//! The fortified `Compute` view is the sole tracking surface (`#lzcellkernel`).
//!
//! Zig mirror of lazily-rs `tests/compute_fortification.rs` (commits 6209f1d +
//! 47992d9). These tests pin the two halves of the fortification contract, plus
//! the generation stamp that Zig uses in place of Rust's lifetime/`!Send` brand:
//!
//! 1. A **tracked** read through the `*Compute` handed to a value-threaded
//!    compute/effect closure registers a dependency edge against the
//!    *recomputing node*, so a change to the dependency recomputes the
//!    dependent.
//! 2. The explicit **untracked** read (`Compute.getUntracked`, reached from the
//!    same view / `Compute.untracked()`) registers **no** edge, so the dependent
//!    neither gains a dependency nor recomputes.
//! 3. An effect tracks through its `Compute` view.
//! 4. **Generation stamp** — a `Compute` whose node has been disposed is no
//!    longer `alive()`, and a tracked read through it is a checked
//!    `error.StaleCompute` rather than an edge misattributed to a dead node.
//!
//! The recomputing node id is threaded as a *value* (`Compute.node`), not an
//! ambient thread-local, so the attribution is correct by construction. The
//! ambient frame is detached for the duration of the closure, so `Compute.get`
//! is the ONLY read that registers an edge.

const std = @import("std");
const Context = @import("context.zig").Context;
const Compute = @import("context.zig").Compute;
const cellMod = @import("cell.zig");
const effectMod = @import("effect.zig");
const source = cellMod.source;
const computedC = cellMod.computedC;
const Source = cellMod.Source;
const effectNoCleanupC = effectMod.effectNoCleanupC;

fn one(_ctx: *Context) anyerror!i32 {
    _ = _ctx;
    return 1;
}

test "lazily/compute: a tracked read registers an edge against the recomputing node" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const a = try source(i32, ctx, one, null);

    // Value-threaded compute closure: the tracked read attributes to `b`, the
    // node being recomputed — carried into the closure as the `Compute.node`
    // value, not resolved from any ambient frame.
    const S = struct {
        var src: *Source(i32) = undefined;
        var calls: usize = 0;
        fn compute(c: *Compute) anyerror!i32 {
            calls += 1;
            return c.get(src) * 10;
        }
    };
    S.src = a;
    S.calls = 0;

    const b = try computedC(i32, ctx, S.compute, null);
    defer ctx.allocator.destroy(b);

    // computedKeyed materializes once at construction.
    try std.testing.expectEqual(@as(i32, 10), b.get().*);
    try std.testing.expectEqual(@as(usize, 1), S.calls);

    // Structural: the edge exists in both directions.
    try std.testing.expectEqual(@as(usize, 1), ctx.dependentCount(a.handle()));
    try std.testing.expectEqual(@as(usize, 1), ctx.dependencyCount(b.handle()));

    // Behavioural: changing `a` recomputes `b`.
    a.set(5);
    try std.testing.expectEqual(@as(i32, 50), b.get().*);
    try std.testing.expectEqual(@as(usize, 2), S.calls);
}

test "lazily/compute: an untracked read registers no edge and does not recompute" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const a = try source(i32, ctx, one, null);

    const S = struct {
        var src: *Source(i32) = undefined;
        var calls: usize = 0;
        fn compute(c: *Compute) anyerror!i32 {
            calls += 1;
            // The explicit untracked read: forms no dependency edge. Equivalent
            // to reading through `c.untracked()`.
            return c.getUntracked(src) * 10;
        }
    };
    S.src = a;
    S.calls = 0;

    const d = try computedC(i32, ctx, S.compute, null);
    defer ctx.allocator.destroy(d);

    try std.testing.expectEqual(@as(i32, 10), d.get().*);
    try std.testing.expectEqual(@as(usize, 1), S.calls);

    // Structural: no edge was formed by the untracked read.
    try std.testing.expectEqual(@as(usize, 0), ctx.dependentCount(a.handle()));
    try std.testing.expectEqual(@as(usize, 0), ctx.dependencyCount(d.handle()));

    // Behavioural: changing `a` does NOT recompute `d` — its cached value stands.
    a.set(5);
    try std.testing.expectEqual(@as(i32, 10), d.get().*);
    try std.testing.expectEqual(@as(usize, 1), S.calls);
}

test "lazily/compute: an effect tracks through its Compute view" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const a = try source(i32, ctx, one, null);

    const S = struct {
        var src: *Source(i32) = undefined;
        var runs: usize = 0;
        fn body(c: *Compute) anyerror!void {
            runs += 1;
            _ = c.get(src);
        }
    };
    S.src = a;
    S.runs = 0;

    const watch = try effectNoCleanupC(ctx, S.body);
    defer ctx.allocator.destroy(watch);
    defer watch.dispose();

    try std.testing.expectEqual(@as(usize, 1), S.runs);
    try std.testing.expectEqual(@as(usize, 1), ctx.dependentCount(a.handle()));

    a.set(2);
    try std.testing.expectEqual(@as(usize, 2), S.runs);
}

test "lazily/compute: the generation stamp rejects a stale view" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const a = try source(i32, ctx, one, null);

    const S = struct {
        var src: *Source(i32) = undefined;
        fn compute(c: *Compute) anyerror!i32 {
            return c.get(src);
        }
    };
    S.src = a;

    const n = try computedC(i32, ctx, S.compute, null);
    defer ctx.allocator.destroy(n);
    _ = n.get();

    // Mint a view over `n` by hand, then tear `n` out of the graph. A view held
    // past the recompute (a non-escapability breach) must not misattribute an
    // edge: the stamp catches it.
    var view = Compute.init(ctx, n.slot);
    try std.testing.expect(view.alive());

    n.disposeNode();

    try std.testing.expect(!view.alive());
    try std.testing.expectError(error.StaleCompute, view.tryGet(a));
    // And the disposed node acquired no new dependency from the rejected read.
    try std.testing.expectEqual(@as(usize, 0), ctx.dependencyCount(n.handle()));
}
