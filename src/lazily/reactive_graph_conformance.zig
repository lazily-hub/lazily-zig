//! Cross-language conformance for the reactive-graph plane
//! (`#lzspecconf`, `#lzspecedgeindex`) — see
//! `../lazily-spec/conformance/reactive-graph/*.json`.
//!
//! Until recently `lazily-rs` was the only binding replaying this corpus, and
//! that gap is exactly how a transitive-cascade defect shipped undetected in
//! lazily-dart and lazily-go (`#lzdartobservercow`): both were correct
//! synchronously and broken asynchronously, and nothing replayed the fixture
//! that would have caught it against the async context.
//!
//! ## Replay against every context the binding ships
//!
//! `lazily-zig` ships three: `Context` (synchronous, pull-based),
//! `ThreadSafeContext` (runtime-keyed, lock-guarded, lazy-on-read) and
//! `AsyncContext` (queue-drained, revision-tracked). The corpus is
//! parameterised over all three rather than run against the default one,
//! because "correct in the default context" is precisely the property the
//! dart/go defect had.
//!
//! ## Positive assertion (`#lzspecconf`)
//!
//! An absence guard is not enough: a runner that skips everything must fail.
//! For each model this asserts (a) the fixture set on disk matches `FIXTURES`
//! exactly, (b) every fixture was either replayed or skipped with its
//! unsupported op named, (c) the skip ledger matches observation exactly, and
//! (d) a non-zero count of fixtures, ops and assertions actually executed.
//!
//! ## Divergence ledger
//!
//! `EXPECTED_DIVERGENCES` records fixture assertions a model does not satisfy.
//! Every entry would be a finding against `lazily-zig`, never a relaxation of a
//! fixture. The observed set is asserted to equal the ledger *exactly*, so a new
//! divergence fails the build and a fixed one fails it until its entry is
//! deleted. Both directions are load-bearing.
//!
//! ## Output (`#lzzigfailedcommand`)
//!
//! Routine progress — per-fixture counts, ledgered skips, ledgered divergences,
//! the summary line — is SILENT unless `LAZILY_CONFORMANCE_VERBOSE` is set.
//! Findings always print and always return an error. This is not cosmetic: Zig's
//! build runner prints `failed command: <argv>` for any step whose captured
//! stderr is non-empty, *including steps that succeeded*, so routine chatter on
//! a green run puts a failure line under a passing summary. See the `note`
//! helper for the two upstream mechanisms that combine to cause it.

const std = @import("std");
const builtin = @import("builtin");
const cj = @import("conformance_json.zig");
const json = std.json;

const ContextMod = @import("context.zig");
const Context = ContextMod.Context;
const Compute = ContextMod.Compute;
const CellMod = @import("cell.zig");
const EffectMod = @import("effect.zig");
const SignalMod = @import("signal.zig");
const slotKeyed = @import("slot.zig").slotKeyed;
const AsyncContext = @import("async_context.zig").AsyncContext;
const ThreadSafeContext = @import("thread_safe_context.zig").ThreadSafeContext;

const conformance_manifest = @import("conformance_manifest.zig");

/// Corpus area this file replays.
const AREA = "reactive-graph";

/// This used to be `const SPEC_DIR = "../lazily-spec/conformance/reactive-graph"`,
/// a COMPTIME constant — and this is the one runner in the binding that
/// ENUMERATES the corpus directory rather than only reading named files
/// (`#lzledgeragreementaudit`). So the drift guard below, the guard whose entire
/// job is to fire when somebody else grows the corpus, was reading a path that
/// `LAZILY_SPEC_CONFORMANCE_DIR` could not move.
///
/// That made it immune to the probe it most needs to survive. Point the suite at
/// a scratch corpus carrying an extra reactive-graph fixture and this runner
/// enumerated the DEFAULT corpus instead, found no drift, and reported green
/// having proved nothing about the corpus it was aimed at. Pointing it at a
/// corpus that does not exist AT ALL was green too, because
/// `panicIfExplicitCorpusMissing` only fires for paths under the override root
/// and these paths never were (`#lzzigspecdiroption`, `#lzoverrideallrunners`).
///
/// Resolved at runtime, so both the enumeration and every fixture read follow
/// the override, and an explicitly named corpus that is absent is fatal here for
/// the same reason it is everywhere else.
fn specPath(a: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ conformance_manifest.conformanceRoot(), AREA, name });
}

fn specDirPath(a: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ conformance_manifest.conformanceRoot(), AREA });
}

/// The value type every model carries. The corpus is integer-valued.
const V = i64;

/// Upper bound on distinct node ids in a single fixture. The widest is
/// `recycled_id_inherits_nothing.json`: a 64-wide fanout plus six named nodes.
///
/// The synchronous `Context` keys its slot cache by *function pointer*, so each
/// node index needs its own comptime-instantiated family of functions; this
/// bounds that expansion.
const MAX_NODES = 80;

/// Upper bound on live teardown scopes in a single fixture.
const MAX_SCOPES = 8;

/// Cache-key generations per node index. A disposed key is never reused: the
/// tombstone `slotKeyed` leaves behind is what makes a read of a disposed node
/// an error, so a replacement subscriber in a churn cycle has to be a genuinely
/// new node. `syncKey` folds the generation into the key.
const GEN_STRIDE = 1024;

/// The canonical fixture set, asserted against the directory listing so a
/// fixture added or renamed upstream fails loudly instead of going unrun.
const FIXTURES = [_][]const u8{
    "churn_returns_to_baseline.json",
    "cross_scope_teardown_hazard.json",
    "disarm_disposes_nothing.json",
    "disposal_does_not_run_surviving_effects.json",
    "dispose_detaches_edges_both_directions.json",
    "dispose_signal_reverts_to_lazy.json",
    "failed_compute_is_never_cached.json",
    "exact_fold_paths_stay_exact.json",
    "feedback_drain_bound_reports_exhaustion.json",
    "merge_cell_acquires_no_dependency_edge.json",
    "merge_feed_through_a_formula_coalesces.json",
    "merge_folds_synchronously_in_batch.json",
    "merge_per_settled_cone_not_per_write.json",
    "read_after_dispose_is_an_error.json",
    "recycled_id_inherits_nothing.json",
    "scope_teardown_equals_fold_of_disposals.json",
    "scoping_bounds_teardown_not_visibility.json",
    "signal_materializes_once_per_batch.json",
    "signal_materializes_without_a_read.json",
    "teardown_runs_members_in_reverse_creation_order.json",
    "transitive_invalidation_reaches_depth.json",
};

/// Ops this runner can drive against every model.
const SUPPORTED_OPS = [_][]const u8{
    "cell",                 "computed",    "effect",         "read",
    "set_cell",             "dispose",     "fanout",         "dispose_fanout",
    "churn",                "begin_scope", "end_scope",      "disarm",
    "dispose_stale_handle",
    // Signal eagerness (`#lzsignaleager`).
    "signal",      "dispose_signal", "batch",
    // Arms the next N computes of an existing node to fail, so a fixture can
    // assert on `computes_of` that a failed compute is never cached.
    "fail_next",
};

/// Assertion keys this runner can evaluate. An `expect` key outside this set
/// fails loudly — silently ignoring an assertion is the anti-pattern this
/// runner exists to kill.
const SUPPORTED_ASSERTIONS = [_][]const u8{
    "note",           "value",         "error",             "read",
    "readable",       "dependents_of", "dependencies_of",   "observed_by",
    "observed_count", "cleanup_order", "scope_owned_count",
    // Signal eagerness (`#lzsignaleager`). The *only* observable that
    // distinguishes an eager signal from the lazy memo it is built on, so it is
    // counted for real — one increment per actual invocation of the compute the
    // runner synthesizes — never derived from op shape.
    "computes_of",
};

/// Fixtures that cannot run against `lazily-zig` today, with the first
/// unsupported op or assertion each one needs. Asserted to match observation
/// exactly: a fixture that starts passing, or a newly blocked one, fails the
/// build. Every entry would be a **capability gap in the binding**, never a
/// relaxed assertion — an accounted-for skip, not a faked pass.
///
/// The six `#lzmergefeed` fixtures landed on spec main (Step 3) exercise a
/// merge-feed surface this runner does not model yet. Five construct a
/// `merge_cell` node, an op kind with no counterpart here (the runner has no
/// merge-feed node), and one asserts `drain_exhausted`, a feedback-drain
/// observable this runner does not track. They are recorded skips rather than
/// silent gaps, so a regression — a fixture that stops replaying, or one of
/// these becoming replayable without its entry removed — is a loud ledger diff.
/// Merge ops are deliberately not implemented here; that is tracked upstream.
const EXPECTED_SKIPS = [_]struct { fixture: []const u8, op: []const u8 }{
    .{ .fixture = "exact_fold_paths_stay_exact.json", .op = "merge_cell" },
    .{ .fixture = "feedback_drain_bound_reports_exhaustion.json", .op = "drain_exhausted" },
    .{ .fixture = "merge_cell_acquires_no_dependency_edge.json", .op = "merge_cell" },
    .{ .fixture = "merge_feed_through_a_formula_coalesces.json", .op = "merge_cell" },
    .{ .fixture = "merge_folds_synchronously_in_batch.json", .op = "merge_cell" },
    .{ .fixture = "merge_per_settled_cone_not_per_write.json", .op = "merge_cell" },
};

/// Fixtures one MODEL cannot replay, with the capability gap that blocks it.
///
/// Separate from `EXPECTED_SKIPS` because the gap is per-context, not per-
/// binding: `ThreadSafeContext.ComputeFn(T)` returns a plain `T` with no error
/// channel (a deliberate design choice — see `thread_safe_context.zig`, which
/// degrades a dropped edge into permanent re-computation rather than widening
/// the signature), so a compute that FAILS is inexpressible against that
/// context. `Context` and `AsyncContext` both take `anyerror!V` and replay the
/// fixture normally.
///
/// The alternative was to fake it: return a sentinel value and have the model's
/// `read` report an error. That would cache the sentinel, so the node would not
/// re-run on the next read, and the fixture would report a divergence that is an
/// artifact of the runner rather than a finding against the binding. A named
/// skip is honest; a synthesized failure is not.
const EXPECTED_MODEL_SKIPS = [_]struct {
    model: []const u8,
    fixture: []const u8,
    reason: []const u8,
}{
    .{
        .model = "ThreadSafeContext",
        .fixture = "failed_compute_is_never_cached.json",
        .reason = "ComputeFn(T) returns a plain T — a compute cannot fail on this context",
    },
    .{
        .model = "AsyncContext",
        .fixture = "failed_compute_is_never_cached.json",
        .reason = "no lazy mode for derived slots — setCell enqueues every dependent unconditionally, " ++
            "so the armed run is consumed by the write instead of the read the fixture arms it for",
    },
};

fn modelSkipReason(model: []const u8, fixture: []const u8) ?[]const u8 {
    for (EXPECTED_MODEL_SKIPS) |e| {
        if (std.mem.eql(u8, e.model, model) and std.mem.eql(u8, e.fixture, fixture)) {
            return e.reason;
        }
    }
    return null;
}

fn modelSkipCount(model: []const u8) usize {
    var n: usize = 0;
    for (EXPECTED_MODEL_SKIPS) |e| {
        if (std.mem.eql(u8, e.model, model)) n += 1;
    }
    return n;
}

/// Divergences this binding currently exhibits, keyed
/// `<model>/<fixture><label>#<step>:<key>`. See the module doc: findings, never
/// relaxations, and asserted in both directions.
const EXPECTED_DIVERGENCES = [_][]const u8{
    // `#lzsignaleager` clause 4, on `AsyncContext` only. Disposing a signal's
    // eager puller must revert the backing value to lazy: the write at step 3
    // carries no read, so a de-eagered node must not re-materialize
    // (`computes_of.sig` 1). `AsyncContext` recomputes 2.
    //
    // Mechanism, and why this is not a puller bug: `AsyncContext` has no lazy
    // mode for derived slots at all. `setCell` walks `reverse_edges` and calls
    // `invalidateSlot` on every dependent, which bumps the revision and
    // `enqueueCompute`s it unconditionally — there is no demand check, no
    // "is anything reading this", and `settle` then drains the whole queue.
    // Every derived slot in that context is eager whether or not a puller is
    // attached, so disposing the puller removes nothing observable and the
    // signal cannot revert to a memo. Clauses 1-3 pass here for the same
    // reason clause 4 fails.
    //
    // Not fixed rather than not fixable: making derived slots demand-driven
    // means `get`/`awaitResolved` must be able to pull a stale slot on read and
    // `invalidateSlot` must stop enqueueing unreached nodes. That is a rewrite
    // of the async scheduler, not a contained change, and every other plane
    // built on this context (reliable_sync, async_reactive_map) depends on the
    // current drain discipline. Clauses 1-3 hold on all three contexts and
    // clause 4 holds on `Context` and `ThreadSafeContext`.
    "AsyncContext/dispose_signal_reverts_to_lazy.json#3:computes_of.sig",
};

// ---------------------------------------------------------------------------
// Shared effect log
// ---------------------------------------------------------------------------

/// Effect run/cleanup order, recorded by node index. Global because the
/// synchronous model's effect bodies are comptime-instantiated functions and
/// have nowhere else to close over.
const EffectLog = struct {
    var runs: std.ArrayList(usize) = .empty;
    var cleanups: std.ArrayList(usize) = .empty;
    var allocator: std.mem.Allocator = undefined;
    /// Set when a log append failed. Surfaces as a hard test failure rather
    /// than as a silently short observation list.
    var dropped: bool = false;

    fn reset(a: std.mem.Allocator) void {
        allocator = a;
        runs.clearRetainingCapacity();
        cleanups.clearRetainingCapacity();
        dropped = false;
    }

    fn deinit() void {
        runs.deinit(allocator);
        cleanups.deinit(allocator);
        runs = .empty;
        cleanups = .empty;
    }

    fn recordRun(idx: usize) void {
        runs.append(allocator, idx) catch {
            dropped = true;
        };
    }

    fn recordCleanup(idx: usize) void {
        cleanups.append(allocator, idx) catch {
            dropped = true;
        };
    }
};

// ---------------------------------------------------------------------------
// Fixture loading (mirrors the `readFixtureFile` idiom already used by
// rateshape/membership/resilience in this repo).
// ---------------------------------------------------------------------------

/// Reads through the runtime conformance manifest recorder
/// (#lazilyupgradeconformance): naming a fixture is not replaying it, so the
/// coverage guard is fed by observed reads rather than a source grep.
const readFixtureFile = conformance_manifest.specReadFile;

fn specFixturesPresent() bool {
    const path = specPath(
        std.testing.allocator,
        "transitive_invalidation_reaches_depth.json",
    ) catch return false;
    defer std.testing.allocator.free(path);
    const raw = readFixtureFile(path) catch return false;
    std.testing.allocator.free(raw);
    return true;
}

fn loadFixture(name: []const u8) !json.Parsed(json.Value) {
    const path = try specPath(std.testing.allocator, name);
    defer std.testing.allocator.free(path);
    const raw = try readFixtureFile(path);
    defer std.testing.allocator.free(raw);
    return json.parseFromSlice(json.Value, std.testing.allocator, raw, .{ .allocate = .alloc_always });
}

fn field(value: json.Value, name: []const u8) ?json.Value {
    return switch (value) {
        .object => |o| o.get(name),
        else => null,
    };
}

fn asI64(value: json.Value) !V {
    return switch (value) {
        .integer => |n| @intCast(n),
        .number_string => |s| try std.fmt.parseInt(V, s, 10),
        else => error.ExpectedInteger,
    };
}

fn asUsize(value: json.Value) !usize {
    return @intCast(try asI64(value));
}

fn asString(value: json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}

fn asArray(value: json.Value) ![]const json.Value {
    return switch (value) {
        .array => |a| a.items,
        else => error.ExpectedArray,
    };
}

fn asObject(value: json.Value) !json.ObjectMap {
    return switch (value) {
        .object => |o| o,
        else => error.ExpectedObject,
    };
}

/// Visit every `op` and every `expect` key in the fixture, across both the
/// `steps` and `scenarios` shapes.
const OpOrExpect = enum { op, expect };
const VisitFn = *const fn (kind: OpOrExpect, name: []const u8) void;

fn forEachOpAndAssertion(fx: json.Value, visit: VisitFn) !void {
    const Local = struct {
        fn walkSteps(steps: []const json.Value, v: VisitFn) !void {
            for (steps) |st| {
                if (field(st, "op")) |op| {
                    v(.op, try asString(field(op, "type") orelse return error.MissingOpType));
                }
                if (field(st, "expect")) |expect| {
                    const obj = try asObject(expect);
                    var it = obj.iterator();
                    while (it.next()) |entry| v(.expect, entry.key_ptr.*);
                }
            }
        }
    };

    if (field(fx, "scenarios")) |scenarios| {
        for (try asArray(scenarios)) |sc| {
            try Local.walkSteps(try asArray(field(sc, "steps") orelse return error.MissingSteps), visit);
        }
    } else {
        try Local.walkSteps(try asArray(field(fx, "steps") orelse return error.MissingSteps), visit);
    }

    // The `scenarios` tail block is evaluated by `evaluateTail`; its keys are
    // fixed rather than free-form, so they need no support check here.
}

fn opSupported(name: []const u8) bool {
    for (SUPPORTED_OPS) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

fn assertionSupported(name: []const u8) bool {
    for (SUPPORTED_ASSERTIONS) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

/// The first unsupported op or assertion the fixture needs, or null when it is
/// fully replayable.
fn firstUnsupported(fx: json.Value) !?[]const u8 {
    const Found = struct {
        var hit: ?[]const u8 = null;
        fn visit(kind: OpOrExpect, name: []const u8) void {
            if (hit != null) return;
            const ok = switch (kind) {
                .op => opSupported(name),
                .expect => assertionSupported(name),
            };
            if (!ok) hit = name;
        }
    };
    Found.hit = null;
    try forEachOpAndAssertion(fx, &Found.visit);
    return Found.hit;
}

// ---------------------------------------------------------------------------
// Node / scope id tables — fixture strings to dense indices.
// ---------------------------------------------------------------------------

fn Table(comptime cap: usize, comptime overflow: anyerror) type {
    return struct {
        names: [cap][]const u8 = undefined,
        len: usize = 0,

        const Self = @This();

        fn indexOf(self: *const Self, name: []const u8) !usize {
            for (self.names[0..self.len], 0..) |n, i| {
                if (std.mem.eql(u8, n, name)) return i;
            }
            return error.UnknownId;
        }

        fn contains(self: *const Self, name: []const u8) bool {
            return if (self.indexOf(name)) |_| true else |_| false;
        }

        fn intern(self: *Self, name: []const u8) !usize {
            if (self.indexOf(name)) |i| return i else |_| {}
            if (self.len == cap) return overflow;
            self.names[self.len] = name;
            self.len += 1;
            return self.len - 1;
        }
    };
}

const NodeTable = Table(MAX_NODES, error.TooManyNodes);
const ScopeTable = Table(MAX_SCOPES, error.TooManyScopes);

/// What kind of node an index holds. Drives read dispatch and `readable`.
///
/// `.signal` is a `.computed` with an eager puller attached; it reads
/// identically, which is the whole reason `computes_of` exists.
const Kind = enum { unset, cell, computed, effect, signal };

/// Upper bound on `reads` per derived node. The corpus needs 2
/// (`signal_materializes_once_per_batch.json` sums two cells).
const MAX_DEPS = 4;

/// Cumulative compute invocations per node index, never reset per step
/// (`#lzsignaleager`). Incremented inside each model's synthesized compute, so
/// it counts what actually ran rather than what the op stream implies.
var compute_counts: [MAX_NODES]usize = @splat(0);

/// How many upcoming compute bodies must fail, per node index (`fail_next`).
/// Consumed from inside the compute body, AFTER `compute_counts` ticks, so an
/// armed run is counted exactly like a successful one — which is what lets a
/// fixture assert the retry on `computes_of` rather than on the error a caching
/// binding also raises.
var armed_failures: [MAX_NODES]usize = @splat(0);

fn takeArmed(idx: usize) bool {
    if (armed_failures[idx] == 0) return false;
    armed_failures[idx] -= 1;
    return true;
}

/// The per-index node definition, rewritten as a fixture replays. Shared by all
/// three models: the synchronous model's comptime functions read it, and the
/// other two use it only to know a node's kind and shape.
const Def = struct {
    kind: Kind = .unset,
    /// Every id this node reads, in fixture order. A `computed`/`effect` uses at
    /// most one; a `signal` may sum several.
    deps: [MAX_DEPS]usize = @splat(0),
    ndeps: usize = 0,
    offset: V = 0,
    initial: V = 0,

    /// The single dependency, for the ops that only ever have one.
    fn dep(self: Def) ?usize {
        return if (self.ndeps == 0) null else self.deps[0];
    }

    fn depSlice(self: *const Def) []const usize {
        return self.deps[0..self.ndeps];
    }

    fn withDeps(kind: Kind, deps: []const usize, offset: V) !Def {
        if (deps.len > MAX_DEPS) return error.TooManyReads;
        var d = Def{ .kind = kind, .ndeps = deps.len, .offset = offset };
        for (deps, 0..) |x, i| d.deps[i] = x;
        return d;
    }
};

var defs: [MAX_NODES]Def = @splat(.{});
var gens: [MAX_NODES]usize = @splat(0);

fn resetDefs() void {
    defs = @splat(.{});
    gens = @splat(0);
    compute_counts = @splat(0);
    armed_failures = @splat(0);
}

// ---------------------------------------------------------------------------
// Model 1 — `Context`, the synchronous pull-based graph.
//
// `Context` keys its slot cache by an integer, but its constructors take
// comptime value functions (Zig has no runtime closures), so a dynamically
// shaped fixture graph needs one comptime-instantiated family per node index.
// Each generated function reads its own entry of the module-level `defs` table.
// The *key* is runtime — `syncKey(i)` folds in a generation counter so a
// re-created node is a genuinely new node rather than a resurrection of a
// tombstone.
// ---------------------------------------------------------------------------

fn syncKey(idx: usize) usize {
    return (idx + 1) * GEN_STRIDE + gens[idx];
}

/// Cleanup payload for a synchronous effect. `Effect(Cleanup)` requires a
/// `destroy()`; this one records the teardown order the corpus pins.
const SyncCleanup = struct {
    idx: usize,
    pub fn destroy(self: *SyncCleanup) void {
        EffectLog.recordCleanup(self.idx);
    }
};

/// Untracked value read of node `idx` (external observation / materialization).
fn syncReadIndex(ctx: *Context, idx: usize) anyerror!V {
    return sync_read_fns[idx](ctx);
}

/// Tracked read of node `idx` from inside a compute/effect (`#lzcellkernel`):
/// reads the value untracked, then registers the edge `idx -> c.node` by value.
/// Replaces what the ambient tracking frame did automatically.
fn syncReadTracked(c: *Compute, idx: usize) anyerror!V {
    const v = try sync_read_fns[idx](c.untracked());
    if (c.untracked().cacheLookup(syncKey(idx))) |s| c.trackSlot(s);
    return v;
}

fn SyncNodeFns(comptime i: usize) type {
    return struct {
        fn cellInit(_: *Context) anyerror!V {
            return defs[i].initial;
        }

        fn compute(c: *Compute) anyerror!V {
            compute_counts[i] += 1;
            if (takeArmed(i)) return error.ComputeFailed;
            const d = defs[i];
            var acc: V = d.offset;
            for (d.depSlice()) |dep| acc += try syncReadTracked(c, dep);
            return acc;
        }

        fn effectBody(c: *Compute) anyerror!?SyncCleanup {
            EffectLog.recordRun(i);
            if (defs[i].dep()) |dep| {
                // A read that fails because a dependency is gone is the
                // contract, not a test failure: the effect simply observes it.
                _ = syncReadTracked(c, dep) catch {};
            }
            return SyncCleanup{ .idx = i };
        }

        fn setCell(ctx: *Context, value: V) anyerror!void {
            defs[i].initial = value;
            const c = try CellMod.cellKeyed(V, ctx, syncKey(i), cellInit, null);
            c.set(value);
        }

        fn read(ctx: *Context) anyerror!V {
            return switch (defs[i].kind) {
                .cell => (try CellMod.cellKeyed(V, ctx, syncKey(i), cellInit, null)).tryGet(),
                // A signal reads through its backing slot exactly like a memo —
                // that indistinguishability is the fixture's premise, so the
                // runner must not give the signal a privileged read path.
                .computed, .signal => (try slotKeyed(V, ctx, syncKey(i), compute, null)).*,
                .effect => error.EffectHasNoValue,
                .unset => error.UnsetNode,
            };
        }
    };
}

const sync_read_fns: [MAX_NODES]*const fn (*Context) anyerror!V = blk: {
    var a: [MAX_NODES]*const fn (*Context) anyerror!V = undefined;
    for (0..MAX_NODES) |i| a[i] = SyncNodeFns(i).read;
    break :blk a;
};

/// The synthesized compute per node index, as a runtime pointer — `signalKeyed`
/// takes its `valueFn` at runtime, unlike `signal`, which keys the slot cache by
/// the comptime function pointer and so can only ever back one node.
const sync_compute_fns: [MAX_NODES]*const fn (*Compute) anyerror!V = blk: {
    var a: [MAX_NODES]*const fn (*Compute) anyerror!V = undefined;
    for (0..MAX_NODES) |i| a[i] = SyncNodeFns(i).compute;
    break :blk a;
};

/// The writes a `batch` op carries, staged for `Context.batch`, whose `run` is
/// comptime — the same reason `defs` is module-level.
const BatchWrite = struct { idx: usize, value: V };
var staged_batch: [MAX_NODES]BatchWrite = undefined;
var staged_batch_len: usize = 0;
/// Set when a staged write failed inside the batch body. `Context.batch`'s `run`
/// cannot return an error, so the failure is latched and rethrown at the call
/// site rather than swallowed.
var staged_batch_failed: ?anyerror = null;

fn applyStagedBatch(ctx: *Context) void {
    for (staged_batch[0..staged_batch_len]) |w| {
        sync_set_cell_fns[w.idx](ctx, w.value) catch |e| {
            if (staged_batch_failed == null) staged_batch_failed = e;
        };
    }
}

const SyncModel = struct {
    pub const NAME = "Context";

    ctx: *Context,
    scopes: [MAX_SCOPES]?Context.TeardownScope = @splat(null),
    /// Effect handles, so `isActive` and the allocator-owned `Effect` struct
    /// can both be reached. Indexed by node index.
    effects: [MAX_NODES]?*EffectMod.Effect(SyncCleanup) = @splat(null),
    /// Eager-signal handles (`#lzsignaleager`), also allocator-owned.
    signals: [MAX_NODES]?*CellMod.Computed(V) = @splat(null),

    fn create(allocator: std.mem.Allocator) !SyncModel {
        return .{ .ctx = try Context.init(allocator) };
    }

    fn destroy(self: *SyncModel) void {
        for (&self.scopes) |*maybe| {
            if (maybe.*) |*s| s.deinit();
            maybe.* = null;
        }
        for (self.effects) |maybe| {
            if (maybe) |e| self.ctx.allocator.destroy(e);
        }
        for (self.signals) |maybe| {
            if (maybe) |s| self.ctx.allocator.destroy(s);
        }
        self.ctx.deinit();
    }

    fn handle(_: *SyncModel, idx: usize) Context.NodeHandle {
        return .{ .key = syncKey(idx) };
    }

    fn addCell(self: *SyncModel, idx: usize, value: V) !void {
        gens[idx] += 1;
        defs[idx] = .{ .kind = .cell, .initial = value };
        _ = try sync_read_fns[idx](self.ctx);
    }

    fn addComputed(self: *SyncModel, idx: usize, deps: []const usize, offset: V) !void {
        gens[idx] += 1;
        defs[idx] = try Def.withDeps(.computed, deps, offset);
        // Materialize eagerly so the node exists as a graph member. Its
        // dependency edge registers on the first *read*, which is why the
        // corpus reads before asserting a degree.
        _ = sync_read_fns[idx](self.ctx) catch {};
    }

    /// `Context`'s own eager construct. `signalKeyed` rather than `signal`
    /// because the latter keys the slot cache by the comptime `valueFn` pointer.
    fn addSignal(self: *SyncModel, idx: usize, deps: []const usize, offset: V) !void {
        gens[idx] += 1;
        defs[idx] = try Def.withDeps(.signal, deps, offset);
        // `signalKeyed` is now `computedKeyed(...).eager()`, and `.eager()`
        // reserves the eager-recompute queue entry itself (via
        // `installEagerHooks`), so `on_invalidate_hook`'s append can never fail
        // for want of capacity. The extra reserve here is redundant but cheap;
        // keep it so an OOM surfaces at construction rather than as silent
        // staleness.
        try self.ctx.reserveEagerRecomputeSlot();
        self.signals[idx] = try SignalMod.signalKeyed(V, self.ctx, syncKey(idx), sync_compute_fns[idx], null);
    }

    fn disposeSignal(self: *SyncModel, idx: usize) void {
        // Revert the eager `Computed` to lazy (remove the puller) without
        // tearing the node out — the `dispose_signal_reverts_to_lazy` contract.
        if (self.signals[idx]) |s| s.lazy();
    }

    fn batch(self: *SyncModel, writes: []const BatchWrite) !void {
        if (writes.len > staged_batch.len) return error.TooManyBatchWrites;
        staged_batch_len = writes.len;
        for (writes, 0..) |w, i| staged_batch[i] = w;
        staged_batch_failed = null;
        self.ctx.batch(applyStagedBatch);
        if (staged_batch_failed) |e| return e;
    }

    fn addEffect(self: *SyncModel, comptime_idx: usize, dep: ?usize) !void {
        gens[comptime_idx] += 1;
        defs[comptime_idx] = try Def.withDeps(.effect, if (dep) |d| &[_]usize{d} else &[_]usize{}, 0);
        if (self.effects[comptime_idx]) |old| {
            self.ctx.allocator.destroy(old);
            self.effects[comptime_idx] = null;
        }
        self.effects[comptime_idx] = try sync_effect_ctors[comptime_idx](self.ctx);
    }

    fn read(self: *SyncModel, idx: usize) !V {
        return sync_read_fns[idx](self.ctx);
    }

    fn setCell(self: *SyncModel, idx: usize, value: V) !void {
        try sync_set_cell_fns[idx](self.ctx, value);
    }

    fn dispose(self: *SyncModel, idx: usize) void {
        if (self.effects[idx]) |e| {
            e.disposeNode();
            return;
        }
        self.ctx.disposeNode(self.handle(idx));
    }

    fn dependentCount(self: *SyncModel, idx: usize) usize {
        return self.ctx.dependentCount(self.handle(idx));
    }

    fn dependencyCount(self: *SyncModel, idx: usize) usize {
        return self.ctx.dependencyCount(self.handle(idx));
    }

    fn readable(self: *SyncModel, idx: usize) bool {
        if (defs[idx].kind == .effect) {
            const e = self.effects[idx] orelse return false;
            return e.isActive();
        }
        _ = self.read(idx) catch return false;
        return true;
    }

    fn settle(_: *SyncModel) void {}

    fn beginScope(self: *SyncModel, si: usize) !void {
        self.scopes[si] = self.ctx.scope();
    }

    fn ownInScope(self: *SyncModel, si: usize, idx: usize) !void {
        try self.scopes[si].?.own(self.handle(idx));
    }

    fn scopeLen(self: *SyncModel, si: usize) usize {
        return self.scopes[si].?.len();
    }

    fn disarmScope(self: *SyncModel, si: usize) void {
        self.scopes[si].?.disarm();
    }

    fn endScope(self: *SyncModel, si: usize) void {
        self.scopes[si].?.deinit();
        self.scopes[si] = null;
    }
};

const SyncEffectCtor = *const fn (*Context) anyerror!*EffectMod.Effect(SyncCleanup);

const sync_effect_ctors: [MAX_NODES]SyncEffectCtor = blk: {
    var a: [MAX_NODES]SyncEffectCtor = undefined;
    for (0..MAX_NODES) |i| a[i] = struct {
        fn call(ctx: *Context) anyerror!*EffectMod.Effect(SyncCleanup) {
            return EffectMod.effectKeyed(SyncCleanup, ctx, syncKey(i), SyncNodeFns(i).effectBody);
        }
    }.call;
    break :blk a;
};

const sync_set_cell_fns: [MAX_NODES]*const fn (*Context, V) anyerror!void = blk: {
    var a: [MAX_NODES]*const fn (*Context, V) anyerror!void = undefined;
    for (0..MAX_NODES) |i| a[i] = SyncNodeFns(i).setCell;
    break :blk a;
};

// ---------------------------------------------------------------------------
// Model 2 — `ThreadSafeContext`. Runtime-keyed and closure-capable, so no
// comptime function expansion is needed; the per-node descriptor is passed as
// the compute's userdata pointer.
// ---------------------------------------------------------------------------

const TsDesc = struct {
    model: *TsModel = undefined,
    idx: usize = 0,
};

const TsModel = struct {
    pub const NAME = "ThreadSafeContext";

    ctx: ThreadSafeContext,
    ids: [MAX_NODES]u64 = @splat(0),
    /// The eager puller effect backing a `signal`, by the signal's node index.
    puller_ids: [MAX_NODES]?u64 = @splat(null),
    descs: [MAX_NODES]TsDesc = @splat(.{}),
    scopes: [MAX_SCOPES]?ThreadSafeContext.TeardownScope = @splat(null),

    fn compute(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) V {
        const d: *TsDesc = @ptrCast(@alignCast(ptr));
        compute_counts[d.idx] += 1;
        const def = defs[d.idx];
        var acc: V = def.offset;
        for (def.depSlice()) |dep| acc += cc.readNode(V, .{ .id = d.model.ids[dep] });
        return acc;
    }

    /// The eager puller for a signal: an ordinary Effect that reads the backing
    /// memo and nothing else. Deliberately not `effectCompute` — a puller is not
    /// an `observed_by` subscriber, so it must stay out of `EffectLog`.
    fn signalPuller(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) V {
        const d: *TsDesc = @ptrCast(@alignCast(ptr));
        return cc.readNode(V, .{ .id = d.model.ids[d.idx] });
    }

    fn effectCompute(ptr: *anyopaque, cc: *ThreadSafeContext.ComputeContext) V {
        const d: *TsDesc = @ptrCast(@alignCast(ptr));
        EffectLog.recordRun(d.idx);
        if (defs[d.idx].dep()) |dep| {
            _ = cc.readNode(V, .{ .id = d.model.ids[dep] });
        }
        return 0;
    }

    fn effectCleanup(ptr: *anyopaque) void {
        const d: *TsDesc = @ptrCast(@alignCast(ptr));
        EffectLog.recordCleanup(d.idx);
    }

    fn create(allocator: std.mem.Allocator) !TsModel {
        return .{ .ctx = ThreadSafeContext.init(allocator) };
    }

    fn destroy(self: *TsModel) void {
        for (&self.scopes) |*maybe| {
            if (maybe.*) |*s| s.deinit();
            maybe.* = null;
        }
        self.ctx.deinit();
    }

    fn bindDesc(self: *TsModel, idx: usize) *TsDesc {
        self.descs[idx] = .{ .model = self, .idx = idx };
        return &self.descs[idx];
    }

    fn addCell(self: *TsModel, idx: usize, value: V) !void {
        defs[idx] = .{ .kind = .cell, .initial = value };
        self.ids[idx] = (try self.ctx.cell(V, value)).id;
    }

    fn addComputed(self: *TsModel, idx: usize, deps: []const usize, offset: V) !void {
        defs[idx] = try Def.withDeps(.computed, deps, offset);
        const h = try self.ctx.computedClosure(V, @ptrCast(self.bindDesc(idx)), compute);
        self.ids[idx] = h.id;
    }

    /// `ThreadSafeContext` has no `Signal` type, so the signal is built the way
    /// the spec derives it: a memo plus an Effect that pulls it. Eagerness is
    /// then a property of effect scheduling rather than of a bespoke node kind —
    /// which is exactly what clause 3 measures.
    fn addSignal(self: *TsModel, idx: usize, deps: []const usize, offset: V) !void {
        try self.addComputed(idx, deps, offset);
        defs[idx].kind = .signal;
        const d = self.bindDesc(idx);
        const puller = try self.ctx.effectClosure(V, @ptrCast(d), signalPuller, null, null);
        self.puller_ids[idx] = puller.id;
    }

    fn disposeSignal(self: *TsModel, idx: usize) void {
        if (self.puller_ids[idx]) |pid| {
            self.ctx.disposeNode(pid);
            self.puller_ids[idx] = null;
        }
    }

    fn batch(self: *TsModel, writes: []const BatchWrite) !void {
        const Body = struct {
            model: *TsModel,
            writes: []const BatchWrite,
            /// `batch`'s body returns a plain value, so a failed write is
            /// latched and rethrown at the call site rather than swallowed.
            failed: ?anyerror = null,
            fn run(ptr: *anyopaque) void {
                const b: *@This() = @ptrCast(@alignCast(ptr));
                for (b.writes) |w| b.model.setCell(w.idx, w.value) catch |e| {
                    if (b.failed == null) b.failed = e;
                };
            }
        };
        var body = Body{ .model = self, .writes = writes };
        self.ctx.batch(void, @ptrCast(&body), Body.run);
        if (body.failed) |e| return e;
    }

    fn addEffect(self: *TsModel, idx: usize, dep: ?usize) !void {
        defs[idx] = try Def.withDeps(.effect, if (dep) |dd| &[_]usize{dd} else &[_]usize{}, 0);
        const d = self.bindDesc(idx);
        const h = try self.ctx.effectClosure(V, @ptrCast(d), effectCompute, @ptrCast(d), effectCleanup);
        self.ids[idx] = h.id;
    }

    fn read(self: *TsModel, idx: usize) !V {
        if (defs[idx].kind == .effect) return error.EffectHasNoValue;
        return self.ctx.tryGet(V, .{ .id = self.ids[idx] });
    }

    fn setCell(self: *TsModel, idx: usize, value: V) !void {
        defs[idx].initial = value;
        self.ctx.setCell(V, .{ .id = self.ids[idx] }, value);
    }

    fn dispose(self: *TsModel, idx: usize) void {
        self.ctx.disposeNode(self.ids[idx]);
    }

    fn dependentCount(self: *TsModel, idx: usize) usize {
        return self.ctx.dependentCount(self.ids[idx]);
    }

    fn dependencyCount(self: *TsModel, idx: usize) usize {
        return self.ctx.dependencyCount(self.ids[idx]);
    }

    fn readable(self: *TsModel, idx: usize) bool {
        if (defs[idx].kind == .effect) return !self.ctx.isDisposed(self.ids[idx]);
        _ = self.read(idx) catch return false;
        return true;
    }

    fn settle(_: *TsModel) void {}

    fn beginScope(self: *TsModel, si: usize) !void {
        self.scopes[si] = self.ctx.scope();
    }

    fn ownInScope(self: *TsModel, si: usize, idx: usize) !void {
        try self.scopes[si].?.own(self.ids[idx]);
    }

    fn scopeLen(self: *TsModel, si: usize) usize {
        return self.scopes[si].?.len();
    }

    fn disarmScope(self: *TsModel, si: usize) void {
        self.scopes[si].?.disarm();
    }

    fn endScope(self: *TsModel, si: usize) void {
        self.scopes[si].?.deinit();
        self.scopes[si] = null;
    }
};

// ---------------------------------------------------------------------------
// Model 3 — `AsyncContext`. The context the dart/go defect hid in: staleness is
// a revision counter and the cascade rides the settle queue rather than a
// recursive invalidate, so a chain that refreshes synchronously can silently
// stop refreshing here.
// ---------------------------------------------------------------------------

const ACtx = AsyncContext(V);

const AsyncDesc = struct {
    model: *AsyncModel = undefined,
    idx: usize = 0,
};

const AsyncModel = struct {
    pub const NAME = "AsyncContext";

    ctx: ACtx,
    ids: [MAX_NODES]u64 = @splat(0),
    puller_ids: [MAX_NODES]?u64 = @splat(null),
    descs: [MAX_NODES]AsyncDesc = @splat(.{}),
    scopes: [MAX_SCOPES]?ACtx.TeardownScope = @splat(null),

    /// Ids are uniform across cells and slots, so one edge registration covers
    /// both cases.
    fn readDep(cc: *ACtx.ComputeContext, dep_id: u64) !V {
        try cc.readCell(dep_id);
        return cc.async_ctx.getCell(dep_id) orelse
            cc.async_ctx.get(dep_id) orelse
            error.AsyncDependencyUnresolved;
    }

    fn compute(ptr: *anyopaque, cc: *ACtx.ComputeContext) anyerror!V {
        const d: *AsyncDesc = @ptrCast(@alignCast(ptr));
        compute_counts[d.idx] += 1;
        if (takeArmed(d.idx)) return error.ComputeFailed;
        const def = defs[d.idx];
        var acc: V = def.offset;
        for (def.depSlice()) |dep| acc += try readDep(cc, d.model.ids[dep]);
        return acc;
    }

    /// See `TsModel.signalPuller`: the eager puller is an ordinary Effect that
    /// reads the backing memo, and it stays out of `EffectLog`.
    fn signalPuller(ptr: *anyopaque, cc: *ACtx.ComputeContext) anyerror!V {
        const d: *AsyncDesc = @ptrCast(@alignCast(ptr));
        return readDep(cc, d.model.ids[d.idx]);
    }

    fn effectCompute(ptr: *anyopaque, cc: *ACtx.ComputeContext) anyerror!V {
        const d: *AsyncDesc = @ptrCast(@alignCast(ptr));
        EffectLog.recordRun(d.idx);
        if (defs[d.idx].dep()) |dep| {
            _ = readDep(cc, d.model.ids[dep]) catch {};
        }
        return 0;
    }

    fn effectCleanup(ptr: *anyopaque) void {
        const d: *AsyncDesc = @ptrCast(@alignCast(ptr));
        EffectLog.recordCleanup(d.idx);
    }

    fn create(allocator: std.mem.Allocator) !AsyncModel {
        return .{ .ctx = ACtx.init(allocator) };
    }

    fn destroy(self: *AsyncModel) void {
        for (&self.scopes) |*maybe| {
            if (maybe.*) |*s| s.deinit();
            maybe.* = null;
        }
        self.ctx.deinit();
    }

    fn bindDesc(self: *AsyncModel, idx: usize) *AsyncDesc {
        self.descs[idx] = .{ .model = self, .idx = idx };
        return &self.descs[idx];
    }

    fn addCell(self: *AsyncModel, idx: usize, value: V) !void {
        defs[idx] = .{ .kind = .cell, .initial = value };
        self.ids[idx] = try self.ctx.cell(value);
    }

    fn addComputed(self: *AsyncModel, idx: usize, deps: []const usize, offset: V) !void {
        defs[idx] = try Def.withDeps(.computed, deps, offset);
        self.ids[idx] = try self.ctx.computedAsyncClosure(@ptrCast(self.bindDesc(idx)), compute);
        // Drain so the dependency edge this slot registers exists before the
        // next level is declared against it.
        _ = try self.ctx.settle();
    }

    /// Same composed construction as `TsModel.addSignal`: memo plus a pulling
    /// Effect.
    fn addSignal(self: *AsyncModel, idx: usize, deps: []const usize, offset: V) !void {
        try self.addComputed(idx, deps, offset);
        defs[idx].kind = .signal;
        const d = self.bindDesc(idx);
        self.puller_ids[idx] = try self.ctx.effectAsyncClosure(@ptrCast(d), signalPuller, null, null);
        _ = try self.ctx.settle();
    }

    fn disposeSignal(self: *AsyncModel, idx: usize) void {
        if (self.puller_ids[idx]) |pid| {
            self.ctx.disposeNode(pid);
            self.puller_ids[idx] = null;
        }
    }

    /// `AsyncContext` has no batch boundary of its own: it is queue-drained, so
    /// its flush point *is* `settle`. Writing every value before a single settle
    /// is therefore the batch — the invalidations coalesce in `pending` under
    /// the `queued` flag exactly as a batch requires.
    fn batch(self: *AsyncModel, writes: []const BatchWrite) !void {
        for (writes) |w| {
            defs[w.idx].initial = w.value;
            try self.ctx.setCell(self.ids[w.idx], w.value);
        }
        _ = try self.ctx.settle();
    }

    fn addEffect(self: *AsyncModel, idx: usize, dep: ?usize) !void {
        defs[idx] = try Def.withDeps(.effect, if (dep) |dd| &[_]usize{dd} else &[_]usize{}, 0);
        const d = self.bindDesc(idx);
        self.ids[idx] = try self.ctx.effectAsyncClosure(@ptrCast(d), effectCompute, @ptrCast(d), effectCleanup);
        _ = try self.ctx.settle();
    }

    fn read(self: *AsyncModel, idx: usize) !V {
        if (defs[idx].kind == .effect) return error.EffectHasNoValue;
        if (defs[idx].kind == .cell) return self.ctx.tryGetCell(self.ids[idx]);
        _ = try self.ctx.settle();
        return self.ctx.awaitResolved(self.ids[idx]);
    }

    fn setCell(self: *AsyncModel, idx: usize, value: V) !void {
        defs[idx].initial = value;
        try self.ctx.setCell(self.ids[idx], value);
        _ = try self.ctx.settle();
    }

    fn dispose(self: *AsyncModel, idx: usize) void {
        self.ctx.disposeNode(self.ids[idx]);
    }

    fn dependentCount(self: *AsyncModel, idx: usize) usize {
        return self.ctx.dependentCount(self.ids[idx]);
    }

    fn dependencyCount(self: *AsyncModel, idx: usize) usize {
        return self.ctx.dependencyCount(self.ids[idx]);
    }

    fn readable(self: *AsyncModel, idx: usize) bool {
        if (defs[idx].kind == .effect) return !self.ctx.isDisposed(self.ids[idx]);
        _ = self.read(idx) catch return false;
        return true;
    }

    fn settle(self: *AsyncModel) void {
        _ = self.ctx.settle() catch {};
    }

    fn beginScope(self: *AsyncModel, si: usize) !void {
        self.scopes[si] = self.ctx.scope();
    }

    fn ownInScope(self: *AsyncModel, si: usize, idx: usize) !void {
        try self.scopes[si].?.own(self.ids[idx]);
    }

    fn scopeLen(self: *AsyncModel, si: usize) usize {
        return self.scopes[si].?.len();
    }

    fn disarmScope(self: *AsyncModel, si: usize) void {
        self.scopes[si].?.disarm();
    }

    fn endScope(self: *AsyncModel, si: usize) void {
        self.scopes[si].?.deinit();
        self.scopes[si] = null;
    }
};

// ---------------------------------------------------------------------------
// Observation — what `observationally_equal` compares
// ---------------------------------------------------------------------------

/// Everything a scenario leaves behind that the equality relation compares.
/// Rendered to a canonical string so two scenarios are compared as wholes
/// rather than field-by-field.
const Observation = struct {
    buf: std.ArrayList(u8) = .empty,

    fn deinit(self: *Observation, a: std.mem.Allocator) void {
        self.buf.deinit(a);
    }

    fn add(self: *Observation, a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
        var scratch: [256]u8 = undefined;
        const rendered = std.fmt.bufPrint(&scratch, fmt, args) catch return;
        self.buf.appendSlice(a, rendered) catch {};
    }
};

const Report = struct {
    ops: usize = 0,
    checks: usize = 0,
    divergences: usize = 0,
    obs: Observation = .{},
};

// ---------------------------------------------------------------------------
// Routine-output gate (`#lzzigfailedcommand`)
// ---------------------------------------------------------------------------
//
// Zig's build runner replays a step's captured stderr and then prints
// `failed command: <argv>` whenever that capture is non-empty — on SUCCESS as
// well as on failure. Two upstream facts combine to produce that:
//
//   * `build_runner.zig` enters the error printer under the comment "No matter
//     the result, we want to display error/warning messages", guarded only by
//     `result_stderr.len > 0` (plus the error bundles) — not by step status.
//   * `Step.Run` populates `result_failed_command` for EVERY run, up front, as
//     a record in case the step later fails. The error printer prints it
//     unconditionally, so a passing step reaches it with the field set.
//
// So any routine chatter on a green run makes `zig build test` print a failure
// line underneath `24/24 steps succeeded`. That trains a reader to skim past
// the next such line, which will be real.
//
// Routine progress therefore goes through `note`, silent unless
// LAZILY_CONFORMANCE_VERBOSE is set. Everything that reports an actual finding
// keeps using `std.debug.print` and is always paired with a returned error, so
// captured stderr is non-empty exactly when the step genuinely fails — and the
// `failed command:` line then means what it says.

var verbose_cache: ?bool = null;

fn verbose() bool {
    if (verbose_cache) |v| return v;
    const v = @import("conformance_manifest.zig").envFlagSet("LAZILY_CONFORMANCE_VERBOSE");
    verbose_cache = v;
    return v;
}

/// Routine progress output. Silent unless LAZILY_CONFORMANCE_VERBOSE is set.
/// Never use this for a finding — findings must always print and always error.
fn note(comptime fmt: []const u8, args: anytype) void {
    if (verbose()) std.debug.print(fmt, args);
}

// ---------------------------------------------------------------------------
// Divergence ledger accounting
// ---------------------------------------------------------------------------

var observed_divergences: std.ArrayList([]const u8) = .empty;
/// Parallel to `observed_divergences`: the full "got X, want Y" text for each
/// entry. The ledger compares ids, but an UNDOCUMENTED divergence is a real
/// finding and must print its detail even though the routine `DIVERGENCE` line
/// is gated behind `note`.
var observed_divergence_details: std.ArrayList([]const u8) = .empty;

fn recordDivergence(a: std.mem.Allocator, entry: []const u8, detail: []const u8) void {
    for (observed_divergences.items) |e| {
        if (std.mem.eql(u8, e, entry)) return;
    }
    const owned = a.dupe(u8, entry) catch return;
    observed_divergences.append(a, owned) catch {
        a.free(owned);
        return;
    };
    const owned_detail = a.dupe(u8, detail) catch "";
    observed_divergence_details.append(a, owned_detail) catch {
        if (owned_detail.len > 0) a.free(owned_detail);
    };
}

/// Detail text recorded alongside `entry`, or an empty slice when none was kept.
fn divergenceDetail(entry: []const u8) []const u8 {
    for (observed_divergences.items, 0..) |e, i| {
        if (!std.mem.eql(u8, e, entry)) continue;
        if (i < observed_divergence_details.items.len) return observed_divergence_details.items[i];
        return "";
    }
    return "";
}

fn clearDivergences(a: std.mem.Allocator) void {
    for (observed_divergences.items) |e| a.free(e);
    observed_divergences.deinit(a);
    observed_divergences = .empty;
    for (observed_divergence_details.items) |d| {
        if (d.len > 0) a.free(d);
    }
    observed_divergence_details.deinit(a);
    observed_divergence_details = .empty;
}

// ---------------------------------------------------------------------------
// Replay engine
// ---------------------------------------------------------------------------

fn Engine(comptime Model: type) type {
    return struct {
        model: *Model,
        nodes: NodeTable = .{},
        scopes: ScopeTable = .{},
        fixture: []const u8,
        label: []const u8,
        step: usize = 0,
        rep: Report = .{},
        allocator: std.mem.Allocator,

        const Self = @This();

        fn node(self: *Self, id: []const u8) !usize {
            return self.nodes.indexOf(id) catch {
                std.debug.print(
                    "  {s}/{s}{s}: op names unknown node `{s}`\n",
                    .{ Model.NAME, self.fixture, self.label, id },
                );
                return error.UnknownNodeId;
            };
        }

        fn scope(self: *Self, name: []const u8) !usize {
            return self.scopes.indexOf(name) catch {
                std.debug.print(
                    "  {s}/{s}{s}: op names unknown scope `{s}`\n",
                    .{ Model.NAME, self.fixture, self.label, name },
                );
                return error.UnknownScopeId;
            };
        }

        /// Record one assertion outcome. A mismatch is a *divergence*, recorded
        /// against the ledger rather than failing immediately, so one run
        /// reports every disagreement instead of only the first.
        fn check(self: *Self, key: []const u8, got: anytype, want: @TypeOf(got)) void {
            self.rep.checks += 1;
            const equal = switch (@typeInfo(@TypeOf(got))) {
                .pointer => std.mem.eql(u8, got, want),
                else => got == want,
            };
            if (equal) return;
            self.rep.divergences += 1;
            var entry_buf: [256]u8 = undefined;
            const entry = std.fmt.bufPrint(&entry_buf, "{s}/{s}{s}#{d}:{s}", .{
                Model.NAME, self.fixture, self.label, self.step, key,
            }) catch "<entry too long>";
            var detail_buf: [512]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buf, "got {any}, want {any}", .{ got, want }) catch "<detail too long>";
            note("  DIVERGENCE {s} — {s}\n", .{ entry, detail });
            recordDivergence(self.allocator, entry, detail);
        }

        /// Create a node, dispatching into a scope when the op names one.
        fn create(self: *Self, op: json.Value, op_type: []const u8, id: []const u8) !void {
            const idx = try self.nodes.intern(id);
            const reads = if (field(op, "reads")) |r| try asArray(r) else &[_]json.Value{};
            if (reads.len > MAX_DEPS) return error.TooManyReads;
            var dep_buf: [MAX_DEPS]usize = undefined;
            for (reads, 0..) |r, i| dep_buf[i] = try self.node(try asString(r));
            const deps = dep_buf[0..reads.len];
            const offset: V = if (field(op, "offset")) |o| try asI64(o) else 0;

            if (std.mem.eql(u8, op_type, "cell")) {
                try self.model.addCell(idx, try asI64(field(op, "value") orelse return error.MissingValue));
            } else if (std.mem.eql(u8, op_type, "computed")) {
                try self.model.addComputed(idx, deps, offset);
            } else if (std.mem.eql(u8, op_type, "signal")) {
                try self.model.addSignal(idx, deps, offset);
            } else if (std.mem.eql(u8, op_type, "effect")) {
                // Effects read at most one node in this corpus.
                if (deps.len > 1) return error.MultiParentNodeUnsupported;
                try self.model.addEffect(idx, if (deps.len == 1) deps[0] else null);
            } else {
                // `effect` used to be the bare `else` (#lzscenariobodyskip). The
                // caller's four-way test and `SUPPORTED_OPS` both gate this
                // today, so it is a latent fail-open rather than a live one —
                // but the moment a fifth creation op joins that gate without an
                // arm here, it would silently be replayed as an effect and the
                // scenario would still be booked.
                std.debug.print("  unknown creation op `{s}`\n", .{op_type});
                return error.UnknownCreateOpType;
            }

            if (field(op, "scope")) |s| {
                try self.model.ownInScope(try self.scope(try asString(s)), idx);
            }
        }

        /// Returns the value a `read` op produced, and whether it errored.
        fn runOp(self: *Self, op: json.Value) !struct { value: ?V, errored: bool } {
            const op_type = try asString(field(op, "type") orelse return error.MissingOpType);

            if (std.mem.eql(u8, op_type, "cell") or
                std.mem.eql(u8, op_type, "computed") or
                std.mem.eql(u8, op_type, "signal") or
                std.mem.eql(u8, op_type, "effect"))
            {
                try self.create(op, op_type, try asString(field(op, "id") orelse return error.MissingOpId));
            } else if (std.mem.eql(u8, op_type, "read")) {
                const idx = try self.node(try asString(field(op, "id") orelse return error.MissingOpId));
                const v = self.model.read(idx) catch return .{ .value = null, .errored = true };
                return .{ .value = v, .errored = false };
            } else if (std.mem.eql(u8, op_type, "fail_next")) {
                // Arms the next N computes of an existing node to fail. It
                // creates nothing and touches no dependency set.
                const idx = try self.node(try asString(field(op, "id") orelse return error.MissingOpId));
                const n: usize = if (field(op, "count")) |c|
                    @intCast(try asI64(c))
                else
                    1;
                armed_failures[idx] += if (n > 0) n else 1;
            } else if (std.mem.eql(u8, op_type, "set_cell")) {
                const idx = try self.node(try asString(field(op, "id") orelse return error.MissingOpId));
                try self.model.setCell(idx, try asI64(field(op, "value") orelse return error.MissingValue));
            } else if (std.mem.eql(u8, op_type, "dispose_signal")) {
                // Disposes the eager puller and nothing else — not a node
                // teardown. The backing value stays live and lazy (clause 4).
                self.model.disposeSignal(try self.node(try asString(field(op, "id") orelse return error.MissingOpId)));
            } else if (std.mem.eql(u8, op_type, "batch")) {
                const writes = try asArray(field(op, "writes") orelse return error.MissingWrites);
                var buf: [MAX_NODES]BatchWrite = undefined;
                if (writes.len > buf.len) return error.TooManyBatchWrites;
                for (writes, 0..) |w, i| {
                    buf[i] = .{
                        .idx = try self.node(try asString(field(w, "id") orelse return error.MissingOpId)),
                        .value = try asI64(field(w, "value") orelse return error.MissingValue),
                    };
                }
                try self.model.batch(buf[0..writes.len]);
            } else if (std.mem.eql(u8, op_type, "dispose")) {
                self.model.dispose(try self.node(try asString(field(op, "id") orelse return error.MissingOpId)));
            } else if (std.mem.eql(u8, op_type, "fanout")) {
                try self.runFanout(op);
            } else if (std.mem.eql(u8, op_type, "dispose_fanout")) {
                const prefix = try asString(field(op, "id_prefix") orelse return error.MissingPrefix);
                const count = try asUsize(field(op, "count") orelse return error.MissingCount);
                for (0..count) |i| {
                    var name_buf: [64]u8 = undefined;
                    const name = try std.fmt.bufPrint(&name_buf, "{s}_{d}", .{ prefix, i });
                    if (self.nodes.indexOf(name)) |idx| self.model.dispose(idx) else |_| {}
                }
            } else if (std.mem.eql(u8, op_type, "churn")) {
                try self.runChurn(op);
            } else if (std.mem.eql(u8, op_type, "begin_scope")) {
                const si = try self.scopes.intern(try asString(field(op, "scope") orelse return error.MissingScope));
                try self.model.beginScope(si);
            } else if (std.mem.eql(u8, op_type, "end_scope")) {
                self.model.endScope(try self.scope(try asString(field(op, "scope") orelse return error.MissingScope)));
            } else if (std.mem.eql(u8, op_type, "disarm")) {
                // A disarmed scope owns nothing; it stays in the table so a
                // later `scope_owned_count` and `end_scope` are no-ops rather
                // than errors.
                self.model.disarmScope(try self.scope(try asString(field(op, "scope") orelse return error.MissingScope)));
            } else if (std.mem.eql(u8, op_type, "dispose_stale_handle")) {
                // In this binding a handle is a cache key (sync) or a monotonic
                // id (async / thread-safe), and neither is ever recycled — a
                // disposed key keeps its tombstone for the life of the context.
                // So a stale handle can only ever name the node it was minted
                // for, and the "must not tear down whatever now owns that id"
                // hazard is unreachable by construction rather than guarded
                // against. What remains testable is the idempotence case, which
                // is what this drives.
                const target = try asString(field(op, "handle_of") orelse return error.MissingHandleOf);
                self.model.dispose(try self.node(target));
            } else {
                // Unreachable: `firstUnsupported` gates the whole fixture.
                std.debug.print("  unsupported op `{s}`\n", .{op_type});
                return error.UnsupportedOp;
            }
            return .{ .value = null, .errored = false };
        }

        fn runFanout(self: *Self, op: json.Value) !void {
            // Subscribers are effects, not derived slots: the corpus asserts
            // `observed_count` on a publish, and in a lazy binding only an eager
            // reader observes a publish without being pulled.
            const prefix = try asString(field(op, "id_prefix") orelse return error.MissingPrefix);
            const count = try asUsize(field(op, "count") orelse return error.MissingCount);
            const reads = try asArray(field(op, "reads") orelse return error.MissingReads);
            if (reads.len != 1) return error.MultiParentNodeUnsupported;
            const dep = try self.node(try asString(reads[0]));
            for (0..count) |i| {
                var name_buf: [64]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buf, "{s}_{d}", .{ prefix, i });
                // `intern` borrows the name, so it must outlive the table.
                const owned = try self.internOwned(name);
                try self.addEffectAt(owned, dep);
            }
        }

        /// Fixture ids are slices into the parsed JSON, which outlives the
        /// engine; generated ids are not, so they are duped into an arena that
        /// the engine frees.
        var generated_names: std.ArrayList([]const u8) = .empty;

        fn internOwned(self: *Self, name: []const u8) !usize {
            if (self.nodes.indexOf(name)) |i| return i else |_| {}
            const owned = try self.allocator.dupe(u8, name);
            try generated_names.append(self.allocator, owned);
            return self.nodes.intern(owned);
        }

        fn addEffectAt(self: *Self, idx: usize, dep: usize) !void {
            try self.model.addEffect(idx, dep);
        }

        fn runChurn(self: *Self, op: json.Value) !void {
            const source = try self.node(try asString(field(op, "source") orelse return error.MissingSource));
            const prefix = try asString(field(op, "id_prefix") orelse return error.MissingPrefix);
            const live_width = try asUsize(field(op, "live_width") orelse return error.MissingLiveWidth);
            const cycles = try asUsize(field(op, "cycles") orelse return error.MissingCycles);
            const mode = try asString(field(op, "mode") orelse return error.MissingMode);

            if (std.mem.eql(u8, mode, "dispose_then_create")) {
                // Hold `live_width` subscribers; each cycle disposes one and
                // creates its replacement, so the live count is invariant.
                for (0..cycles) |c| {
                    var name_buf: [64]u8 = undefined;
                    const name = try std.fmt.bufPrint(&name_buf, "{s}_{d}", .{ prefix, c % live_width });
                    const idx = try self.internOwned(name);
                    if (defs[idx].kind != .unset) self.model.dispose(idx);
                    try self.addEffectAt(idx, source);
                    self.model.settle();
                }
            } else if (std.mem.eql(u8, mode, "scope_per_cycle")) {
                // One teardown scope per cycle; its subscriber is gone by the
                // end of its own cycle, so it contributes nothing to the
                // steady-state count.
                var name_buf: [64]u8 = undefined;
                const name = try std.fmt.bufPrint(&name_buf, "{s}_scoped", .{prefix});
                const idx = try self.internOwned(name);
                const si = try self.scopes.intern("__churn__");
                for (0..cycles) |_| {
                    try self.model.beginScope(si);
                    try self.addEffectAt(idx, source);
                    try self.model.ownInScope(si, idx);
                    self.model.settle();
                    self.model.endScope(si);
                }
            } else {
                std.debug.print("  unknown churn mode `{s}`\n", .{mode});
                return error.UnknownChurnMode;
            }
        }

        fn readable(self: *Self, id: []const u8) bool {
            const idx = self.nodes.indexOf(id) catch return false;
            return self.model.readable(idx);
        }

        /// Compare an effect-id list against the log slice, by node index.
        fn checkIdList(self: *Self, key: []const u8, log: []const usize, want: []const json.Value, effects_only: bool) !void {
            // Only effects run a body or a cleanup, so an expected list is
            // projected onto its effect entries before comparison.
            var want_buf: [MAX_NODES]usize = undefined;
            var want_len: usize = 0;
            for (want) |w| {
                const name = try asString(w);
                const idx = self.nodes.indexOf(name) catch continue;
                if (effects_only and defs[idx].kind != .effect) continue;
                want_buf[want_len] = idx;
                want_len += 1;
            }
            self.check(key, log.len, want_len);
            if (log.len != want_len) return;
            for (log, want_buf[0..want_len], 0..) |g, w, i| {
                var k: [96]u8 = undefined;
                const sub = std.fmt.bufPrint(&k, "{s}[{d}]", .{ key, i }) catch key;
                self.check(sub, g, w);
            }
        }

        fn evaluateExpect(
            self: *Self,
            expect: json.Value,
            op_id: ?[]const u8,
            op_value: ?V,
            op_errored: bool,
            runs_before: usize,
        ) !void {
            const obj = try asObject(expect);

            // Keys are evaluated in sorted order, matching lazily-rs's BTreeMap
            // iteration, so every binding agrees on when a degree is sampled
            // relative to a read that re-registers the edge it counts.
            var keys: [16][]const u8 = undefined;
            var nkeys: usize = 0;
            var kit = obj.iterator();
            while (kit.next()) |entry| : (nkeys += 1) {
                if (nkeys == keys.len) return error.TooManyAssertionKeys;
                keys[nkeys] = entry.key_ptr.*;
            }
            std.mem.sort([]const u8, keys[0..nkeys], {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lt);

            const has_error_key = obj.get("error") != null;

            for (keys[0..nkeys]) |key| {
                const raw = obj.get(key).?;
                if (std.mem.eql(u8, key, "note")) continue;

                if (std.mem.eql(u8, key, "value")) {
                    // Reading `value` and skipping past it is exactly the
                    // read-then-discard shape this guard exists to refuse. No
                    // fixture in the corpus pairs `value` with `error` today; if
                    // one ever does, it has to grow a real comparison here
                    // rather than a `continue` (#lzconsumednotasserted).
                    if (has_error_key) {
                        std.debug.print(
                            "  step assertion carries both `value` and `error`; `value` " ++
                                "would be read and discarded\n",
                            .{},
                        );
                        return error.ValueAndErrorAssertedTogether;
                    }
                    const want = try asI64(raw);
                    const got = op_value orelse blk: {
                        // `value` attaches to the step's own op; if that op was
                        // not a read, re-read the node it names.
                        const idx = try self.node(op_id orelse return error.MissingOpId);
                        break :blk self.model.read(idx) catch {
                            self.check("value", @as(V, -1), want);
                            continue;
                        };
                    };
                    self.check("value", got, want);
                } else if (std.mem.eql(u8, key, "error")) {
                    // Any non-null error code means "this op must fail"; null
                    // means "must not". The runner does not model error
                    // identity — the fixtures carry the code so the contract is
                    // legible, and this binding's own tests pin which error it
                    // raises.
                    const want_error = switch (raw) {
                        .null => false,
                        .string => true,
                        else => return error.MalformedErrorAssertion,
                    };
                    self.check("error", op_errored, want_error);
                } else if (std.mem.eql(u8, key, "read")) {
                    const map = try asObject(raw);
                    for (try sortedKeys(map)) |id| {
                        const want = try asI64(map.get(id).?);
                        var k: [96]u8 = undefined;
                        const sub = std.fmt.bufPrint(&k, "read.{s}", .{id}) catch "read";
                        const idx = try self.node(id);
                        const got = self.model.read(idx) catch {
                            self.check(sub, @as(V, -1), want);
                            continue;
                        };
                        self.check(sub, got, want);
                    }
                } else if (std.mem.eql(u8, key, "readable")) {
                    const map = try asObject(raw);
                    for (try sortedKeys(map)) |id| {
                        const want = switch (map.get(id).?) {
                            .bool => |b| b,
                            else => return error.MalformedReadableAssertion,
                        };
                        var k: [96]u8 = undefined;
                        const sub = std.fmt.bufPrint(&k, "readable.{s}", .{id}) catch "readable";
                        self.check(sub, self.readable(id), want);
                    }
                } else if (std.mem.eql(u8, key, "dependents_of") or
                    std.mem.eql(u8, key, "dependencies_of"))
                {
                    const dependents = std.mem.eql(u8, key, "dependents_of");
                    const map = try asObject(raw);
                    for (try sortedKeys(map)) |id| {
                        const want = try asUsize(map.get(id).?);
                        var k: [96]u8 = undefined;
                        const sub = std.fmt.bufPrint(&k, "{s}.{s}", .{ key, id }) catch key;
                        const idx = try self.node(id);
                        const got = if (dependents)
                            self.model.dependentCount(idx)
                        else
                            self.model.dependencyCount(idx);
                        self.check(sub, got, want);
                    }
                } else if (std.mem.eql(u8, key, "computes_of")) {
                    // Cumulative from the start of the scenario, including the
                    // invocation at creation, and never reset per step. Read
                    // straight off the counter the synthesized compute bumps —
                    // deriving it from the op stream would defeat the fixtures.
                    const map = try asObject(raw);
                    for (try sortedKeys(map)) |id| {
                        const want = try asUsize(map.get(id).?);
                        var k: [96]u8 = undefined;
                        const sub = std.fmt.bufPrint(&k, "computes_of.{s}", .{id}) catch "computes_of";
                        self.check(sub, compute_counts[try self.node(id)], want);
                    }
                } else if (std.mem.eql(u8, key, "observed_by")) {
                    try self.checkIdList("observed_by", EffectLog.runs.items[runs_before..], try asArray(raw), false);
                } else if (std.mem.eql(u8, key, "observed_count")) {
                    self.check("observed_count", EffectLog.runs.items.len - runs_before, try asUsize(raw));
                } else if (std.mem.eql(u8, key, "cleanup_order")) {
                    // Cumulative, not per-step: the individual-disposal
                    // scenario spreads three disposals over three steps and pins
                    // the whole order on the last one.
                    try self.checkIdList("cleanup_order", EffectLog.cleanups.items, try asArray(raw), true);
                } else if (std.mem.eql(u8, key, "scope_owned_count")) {
                    const map = try asObject(raw);
                    for (try sortedKeys(map)) |name| {
                        const want = try asUsize(map.get(name).?);
                        var k: [96]u8 = undefined;
                        const sub = std.fmt.bufPrint(&k, "scope_owned_count.{s}", .{name}) catch "scope_owned_count";
                        self.check(sub, self.model.scopeLen(try self.scope(name)), want);
                    }
                } else {
                    std.debug.print("  UNKNOWN assertion key `{s}`\n", .{key});
                    return error.UnknownAssertionKey;
                }
            }
        }

        fn replay(self: *Self, steps: []const json.Value) !void {
            for (steps, 0..) |step, si| {
                self.step = si;
                const runs_before = EffectLog.runs.items.len;

                const op = field(step, "op") orelse return error.MissingOp;
                const outcome = try self.runOp(op);
                self.rep.ops += 1;
                self.model.settle();

                const expect = field(step, "expect") orelse continue;
                const op_id: ?[]const u8 = if (field(op, "id")) |v| try asString(v) else null;
                try self.evaluateExpect(expect, op_id, outcome.value, outcome.errored, runs_before);
            }
        }

        /// Check the `scenarios` shape's `expected` block against the final
        /// world state, and record the observation the equality relation
        /// compares.
        ///
        /// The key order here is fixed rather than sorted, and deliberately so:
        /// the after-publish `read` must run before its `dependents_of`, because
        /// this binding's publish cascade *consumes* the reverse edge and the
        /// read is what re-registers it. Sampling the degree first would measure
        /// the middle of a cascade.
        fn evaluateTail(self: *Self, fx: json.Value) !void {
            self.step = 9999; // "expected", not a step index
            const expected_block = field(fx, "expected") orelse return;
            const a = self.allocator;

            // The step-level `expect` refuses an unrecognised key; this tail did
            // not, at any nesting level. The module comment used to argue its
            // keys "are fixed rather than free-form, so they need no support
            // check here" -- an assumption only the corpus gets to make
            // (#lzassertunknownkeys).
            var expected = cj.AssertionKeys.init("reactive-graph expected tail", expected_block);
            // Asserted by `runCorpus`, which needs every scenario's report
            // before it can compare two worlds — the relation is between two op
            // streams, which this single-scenario tail cannot express.
            try expected.excuseKey(
                "observationally_equal",
                "a relation between two scenarios' observations, asserted in runCorpus " ++
                    "after every scenario has been replayed",
            );

            _ = try expected.assertObjectWithOpt("final_state", self, Self.checkFinalState);
            _ = try expected.assertObjectWithOpt("after_publish", self, Self.checkAfterPublish);

            try expected.finish();
            for (EffectLog.cleanups.items) |c| self.rep.obs.add(a, "cleanup[{d}];", .{c});
        }

        fn checkFinalState(self: *Self, fin: *cj.AssertionKeys) !void {
            _ = try fin.assertObjectWithOpt("dependents_of", self, struct {
                fn check(engine: *Self, members: *cj.AssertionKeys) !void {
                    const map = try asObject(members.object);
                    for (try sortedKeys(map)) |id| {
                        const idx = try engine.node(id);
                        const got = engine.model.dependentCount(idx);
                        var k: [96]u8 = undefined;
                        engine.check(
                            std.fmt.bufPrint(&k, "final.dependents_of.{s}", .{id}) catch "final.dependents_of",
                            got,
                            try asUsize(map.get(id).?),
                        );
                        try members.assertKey(id, got);
                        engine.rep.obs.add(engine.allocator, "dep[{s}]={d};", .{ id, got });
                    }
                }
            }.check);
            _ = try fin.assertObjectWithOpt("readable", self, struct {
                fn check(engine: *Self, members: *cj.AssertionKeys) !void {
                    const map = try asObject(members.object);
                    for (try sortedKeys(map)) |id| {
                        const got = engine.readable(id);
                        var k: [96]u8 = undefined;
                        engine.check(
                            std.fmt.bufPrint(&k, "final.readable.{s}", .{id}) catch "final.readable",
                            got,
                            switch (map.get(id).?) {
                                .bool => |b| b,
                                else => return error.MalformedReadableAssertion,
                            },
                        );
                        try members.assertKey(id, got);
                        engine.rep.obs.add(engine.allocator, "readable[{s}]={};", .{ id, got });
                    }
                }
            }.check);
            _ = try fin.assertObjectWithOpt("read", self, struct {
                fn check(engine: *Self, members: *cj.AssertionKeys) !void {
                    const map = try asObject(members.object);
                    for (try sortedKeys(map)) |id| {
                        const idx = try engine.node(id);
                        const want = try asI64(map.get(id).?);
                        var k: [96]u8 = undefined;
                        const key = std.fmt.bufPrint(&k, "final.read.{s}", .{id}) catch "final.read";
                        if (engine.model.read(idx)) |got| {
                            engine.check(key, got, want);
                            try members.assertKey(id, got);
                            engine.rep.obs.add(engine.allocator, "read[{s}]={d};", .{ id, got });
                        } else |_| {
                            engine.check(key, @as(V, -1), want);
                            try members.assertKey(id, @as(V, -1));
                            engine.rep.obs.add(engine.allocator, "read[{s}]=err;", .{id});
                        }
                    }
                }
            }.check);
        }

        fn checkAfterPublish(self: *Self, pub_keys: *cj.AssertionKeys) !void {
            const a = self.allocator;
            // `op` is the publish to PERFORM, not a fact to compare — it drives
            // the cascade every other key here observes.
            try pub_keys.excuseKey(
                "op",
                "block input: the cell write whose cascade the other keys observe",
            );
            const op = pub_keys.field("op") orelse return error.MissingOp;
            const idx = try self.node(try asString(field(op, "id") orelse return error.MissingOpId));
            const runs_before = EffectLog.runs.items.len;
            try self.model.setCell(idx, try asI64(field(op, "value") orelse return error.MissingValue));
            self.model.settle();

            const ran = EffectLog.runs.items[runs_before..];
            _ = try pub_keys.assertKeyWithOpt("observed_by", RanCtx{ .engine = self, .ran = ran }, RanCtx.check);
            for (ran) |r| self.rep.obs.add(a, "ran[{d}];", .{r});

            _ = try pub_keys.assertObjectWithOpt("read", self, struct {
                fn check(engine: *Self, members: *cj.AssertionKeys) !void {
                    const map = try asObject(members.object);
                    for (try sortedKeys(map)) |id| {
                        const nidx = try engine.node(id);
                        const want = try asI64(map.get(id).?);
                        var k: [96]u8 = undefined;
                        const key = std.fmt.bufPrint(&k, "after_publish.read.{s}", .{id}) catch "after_publish.read";
                        if (engine.model.read(nidx)) |got| {
                            engine.check(key, got, want);
                            try members.assertKey(id, got);
                            engine.rep.obs.add(engine.allocator, "pubread[{s}]={d};", .{ id, got });
                        } else |_| {
                            engine.check(key, @as(V, -1), want);
                            try members.assertKey(id, @as(V, -1));
                            engine.rep.obs.add(engine.allocator, "pubread[{s}]=err;", .{id});
                        }
                    }
                }
            }.check);
            _ = try pub_keys.assertObjectWithOpt("dependents_of", self, struct {
                fn check(engine: *Self, members: *cj.AssertionKeys) !void {
                    const map = try asObject(members.object);
                    for (try sortedKeys(map)) |id| {
                        const nidx = try engine.node(id);
                        const got = engine.model.dependentCount(nidx);
                        var k: [96]u8 = undefined;
                        engine.check(
                            std.fmt.bufPrint(&k, "after_publish.dependents_of.{s}", .{id}) catch "after_publish.dependents_of",
                            got,
                            try asUsize(map.get(id).?),
                        );
                        try members.assertKey(id, got);
                        engine.rep.obs.add(engine.allocator, "pubdep[{s}]={d};", .{ id, got });
                    }
                }
            }.check);
        }

        /// `assertKeyWith` context for `after_publish.observed_by` — the check
        /// needs both the engine and the effect runs the publish produced.
        const RanCtx = struct {
            engine: *Self,
            ran: []const usize,

            fn check(self: RanCtx, ob: json.Value) !void {
                try self.engine.checkIdList(
                    "after_publish.observed_by",
                    self.ran,
                    try asArray(ob),
                    false,
                );
            }
        };
    };
}

/// Object keys in sorted order. Bounded, because every map in the corpus is a
/// handful of node ids.
var sorted_key_buf: [MAX_NODES][]const u8 = undefined;

fn sortedKeys(map: json.ObjectMap) ![]const []const u8 {
    var n: usize = 0;
    var it = map.iterator();
    while (it.next()) |entry| : (n += 1) {
        if (n == sorted_key_buf.len) return error.TooManyKeys;
        sorted_key_buf[n] = entry.key_ptr.*;
    }
    std.mem.sort([]const u8, sorted_key_buf[0..n], {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return sorted_key_buf[0..n];
}

// ---------------------------------------------------------------------------
// Corpus driver
// ---------------------------------------------------------------------------

fn replayFixture(comptime Model: type, fixture_name: []const u8, fx: json.Value, total: *Report) !void {
    const a = std.testing.allocator;
    // A bare `error.MissingShape` / `error.UnknownFixtureShape` names neither
    // the fixture nor what was read, and this is the failure a GROWN corpus
    // produces (`#lzledgeragreementaudit`). Findings print, then return the
    // error — see the file header.
    const shape_value = field(fx, "shape") orelse {
        std.debug.print(
            "  reactive-graph {s}: fixture carries no `shape` — this runner dispatches on it " ++
                "and cannot guess. Fix the fixture upstream or add the shape here\n",
            .{fixture_name},
        );
        return error.MissingShape;
    };
    const shape = try asString(shape_value);

    if (std.mem.eql(u8, shape, "steps")) {
        resetDefs();
        EffectLog.reset(a);
        var model = try Model.create(a);
        defer model.destroy();
        var engine = Engine(Model){ .model = &model, .fixture = fixture_name, .label = "", .allocator = a };
        defer freeGeneratedNames(Model, a);
        try engine.replay(try asArray(field(fx, "steps").?));
        total.ops += engine.rep.ops;
        total.checks += engine.rep.checks;
        total.divergences += engine.rep.divergences;
        return;
    }

    if (!std.mem.eql(u8, shape, "scenarios")) {
        std.debug.print(
            "  reactive-graph {s}: unknown fixture shape `{s}` — this runner knows only " ++
                "`steps` and `scenarios`. A fixture carrying a new shape needs a replay arm " ++
                "here before it can be replayed; never widen this to a skip (#lzspecconf)\n",
            .{ fixture_name, shape },
        );
        return error.UnknownFixtureShape;
    }

    // `observationally_equal` is a relation between two op streams, which a
    // single `steps` array cannot express. Each scenario is replayed in its own
    // context and the resulting observations are compared as wholes. Asserting
    // only that each scenario independently satisfies `expected` would not test
    // the relation the fixture exists to state.
    // Per-scenario replay accounting (#lzscenariocoverage). `FIXTURES` names
    // are bare filenames; the ledger keys by corpus-relative id.
    var ledger_id_buf: [256]u8 = undefined;
    const ledger_fixture = try std.fmt.bufPrint(&ledger_id_buf, "reactive-graph/{s}", .{fixture_name});
    var ledger = try cj.scenarios(ledger_fixture, fx);

    var obs_bufs: [8]Observation = @splat(.{});
    var obs_names: [8][]const u8 = undefined;
    var obs_len: usize = 0;
    defer for (obs_bufs[0..obs_len]) |*o| {
        var m = o.*;
        m.deinit(a);
    };

    while (ledger.next()) |handle| {
        if (obs_len == obs_bufs.len) return error.TooManyScenarios;
        // `name` is a LABEL read, taken off peek() so it books nothing
        // (#lzscenariobodyskip); the early return above must not credit a
        // replay that never happened.
        const name = try asString(field(handle.peek(), "name") orelse return error.MissingScenarioName);
        const sc = try handle.replay();
        var label_buf: [96]u8 = undefined;
        const label = try std.fmt.bufPrint(&label_buf, "[{s}]", .{name});

        resetDefs();
        EffectLog.reset(a);
        var model = try Model.create(a);
        var engine = Engine(Model){ .model = &model, .fixture = fixture_name, .label = label, .allocator = a };
        try engine.replay(try asArray(field(sc, "steps").?));
        try engine.evaluateTail(fx);
        model.destroy();
        freeGeneratedNames(Model, a);

        total.ops += engine.rep.ops;
        total.checks += engine.rep.checks;
        total.divergences += engine.rep.divergences;
        obs_bufs[obs_len] = engine.rep.obs;
        obs_names[obs_len] = name;
        obs_len += 1;
    }

    const expected = field(fx, "expected") orelse return;
    const pairs = field(expected, "observationally_equal") orelse return;
    const want_names = try asArray(pairs);
    if (want_names.len < 2) return;

    var first: ?usize = null;
    for (want_names) |wn| {
        const name = try asString(wn);
        var found: ?usize = null;
        for (obs_names[0..obs_len], 0..) |on, i| {
            if (std.mem.eql(u8, on, name)) found = i;
        }
        const idx = found orelse {
            std.debug.print("  `observationally_equal` names unknown scenario `{s}`\n", .{name});
            return error.UnknownScenario;
        };
        if (first == null) {
            first = idx;
            continue;
        }
        total.checks += 1;
        const lhs = obs_bufs[first.?].buf.items;
        const rhs = obs_bufs[idx].buf.items;
        if (!std.mem.eql(u8, lhs, rhs)) {
            total.divergences += 1;
            var entry_buf: [256]u8 = undefined;
            const entry = std.fmt.bufPrint(&entry_buf, "{s}/{s}#expected:observationally_equal", .{
                Model.NAME, fixture_name,
            }) catch "<entry too long>";
            var detail_buf: [512]u8 = undefined;
            const detail = std.fmt.bufPrint(&detail_buf, "scenarios `{s}` and `{s}` differ", .{
                obs_names[first.?], obs_names[idx],
            }) catch "<detail too long>";
            note(
                "  DIVERGENCE {s} — {s}\n    {s}\n    {s}\n",
                .{ entry, detail, lhs, rhs },
            );
            recordDivergence(a, entry, detail);
        }
    }
}

fn freeGeneratedNames(comptime Model: type, a: std.mem.Allocator) void {
    const E = Engine(Model);
    for (E.generated_names.items) |n| a.free(n);
    E.generated_names.deinit(a);
    E.generated_names = .empty;
}

/// Replay the whole corpus against one execution model.
fn runCorpus(comptime Model: type) !void {
    const name = Model.NAME;
    const a = std.testing.allocator;

    if (!specFixturesPresent()) {
        std.debug.print(
            "SKIP reactive_graph_conformance[{s}]: {s}/{s} not found — clone lazily-spec as a " ++
                "sibling to run the reactive-graph fixtures (#lzspecconf)\n",
            .{ name, conformance_manifest.conformanceRoot(), AREA },
        );
        return error.SkipZigTest;
    }

    defer clearDivergences(a);
    defer EffectLog.deinit();

    var replayed: usize = 0;
    var skipped: usize = 0;
    var total = Report{};

    for (FIXTURES) |fixture_name| {
        const parsed = try loadFixture(fixture_name);
        defer parsed.deinit();
        const fx = parsed.value;

        if (modelSkipReason(name, fixture_name)) |reason| {
            // Named, per-model skip. Silent skipping is the anti-pattern, but
            // these are ledgered, so they are routine — see the note() header.
            note(
                "SKIP reactive-graph[{s}] {s}: {s}\n",
                .{ name, fixture_name, reason },
            );
            skipped += 1;
            continue;
        }

        if (try firstUnsupported(fx)) |blocking| {
            // Named skip. Routine while it stays in EXPECTED_SKIPS; the
            // undocumented case below is the finding and prints unconditionally.
            note(
                "SKIP reactive-graph[{s}] {s}: unsupported `{s}`\n",
                .{ name, fixture_name, blocking },
            );
            var documented = false;
            for (EXPECTED_SKIPS) |e| {
                if (std.mem.eql(u8, e.fixture, fixture_name)) {
                    try std.testing.expectEqualStrings(e.op, blocking);
                    documented = true;
                }
            }
            if (!documented) {
                std.debug.print(
                    "  reactive-graph[{s}] {s} is not in EXPECTED_SKIPS — a fixture stopped " ++
                        "being replayable (unsupported `{s}`)\n",
                    .{ name, fixture_name, blocking },
                );
                return error.UndocumentedSkip;
            }
            skipped += 1;
            continue;
        }

        // A replayable fixture must not be sitting in the skip ledger.
        for (EXPECTED_SKIPS) |e| {
            if (std.mem.eql(u8, e.fixture, fixture_name)) {
                std.debug.print(
                    "  {s} is replayable now — remove it from EXPECTED_SKIPS\n",
                    .{fixture_name},
                );
                return error.StaleSkipLedger;
            }
        }

        var per_fixture = Report{};
        try replayFixture(Model, fixture_name, fx, &per_fixture);

        // Per-fixture positive assertion.
        if (per_fixture.ops == 0) return error.ReplayedZeroOps;
        if (per_fixture.checks == 0) return error.ReplayedZeroAssertions;
        if (EffectLog.dropped) return error.EffectLogDropped;

        note(
            "reactive-graph[{s}] {s}: {d} ops, {d} assertions\n",
            .{ name, fixture_name, per_fixture.ops, per_fixture.checks },
        );
        total.ops += per_fixture.ops;
        total.checks += per_fixture.checks;
        total.divergences += per_fixture.divergences;
        replayed += 1;
    }

    note(
        "reactive-graph[{s}]: {d} fixtures replayed, {d} skipped, {d} ops, {d} assertions\n",
        .{ name, replayed, skipped, total.ops, total.checks },
    );

    // ---- Positive assertion (`#lzspecconf`) ----
    // The runner must have actually executed the corpus. A runner that can
    // report green while executing nothing is the exact anti-pattern this
    // exists to kill, so a zero count in any of these fails loudly.
    try std.testing.expect(replayed > 0);
    try std.testing.expect(total.ops > 0);
    try std.testing.expect(total.checks > 0);
    try std.testing.expectEqual(EXPECTED_SKIPS.len + modelSkipCount(name), skipped);
    try std.testing.expectEqual(FIXTURES.len, replayed + skipped);

    // ---- Divergence ledger, asserted in both directions ----
    for (observed_divergences.items) |d| {
        var documented = false;
        for (EXPECTED_DIVERGENCES) |e| {
            if (std.mem.eql(u8, e, d)) documented = true;
        }
        if (!documented) {
            std.debug.print(
                "  undocumented divergence {s} — {s}\n" ++
                    "  this is a finding against lazily-zig; fix it or record it in " ++
                    "EXPECTED_DIVERGENCES (never edit the fixture)\n",
                .{ d, divergenceDetail(d) },
            );
            return error.UndocumentedDivergence;
        }
    }
    for (EXPECTED_DIVERGENCES) |e| {
        if (!std.mem.startsWith(u8, e, name)) continue;
        var still = false;
        for (observed_divergences.items) |d| {
            if (std.mem.eql(u8, e, d)) still = true;
        }
        if (!still) {
            std.debug.print(
                "  documented divergence {s} no longer reproduces — delete the stale entry\n",
                .{e},
            );
            return error.StaleDivergenceLedger;
        }
    }
}

/// 1 if `name` is a known fixture, 0 if it is not a `.json` file at all, and an
/// error if it is a `.json` this runner does not know about.
fn countFixture(name: []const u8) !usize {
    if (!std.mem.endsWith(u8, name, ".json")) return 0;
    for (FIXTURES) |f| {
        if (std.mem.eql(u8, f, name)) return 1;
    }
    std.debug.print("  unknown fixture on disk: {s}\n", .{name});
    return error.FixtureSetDrifted;
}

test "reactive-graph conformance: fixture set on disk matches FIXTURES" {
    // An upstream addition or rename must fail here rather than go unrun.
    if (!specFixturesPresent()) return error.SkipZigTest;

    const dir_path = try specDirPath(std.testing.allocator);
    defer std.testing.allocator.free(dir_path);

    var seen: usize = 0;
    if (comptime builtin.zig_version.minor >= 16) {
        const io = std.testing.io;
        var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            seen += try countFixture(entry.name);
        }
    } else {
        var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            seen += try countFixture(entry.name);
        }
    }
    try std.testing.expectEqual(FIXTURES.len, seen);
}

test "reactive-graph conformance: Context (synchronous)" {
    try runCorpus(SyncModel);
}

test "reactive-graph conformance: ThreadSafeContext" {
    try runCorpus(TsModel);
}

test "reactive-graph conformance: AsyncContext" {
    // The context the dart/go transitive-cascade defect hid in. Replaying the
    // corpus here rather than only against `Context` is the whole point.
    try runCorpus(AsyncModel);
}
