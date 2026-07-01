//! Full Harel/SCXML state charts — native Zig, conforming to
//! `lazily-spec/docs/state-charts.md` and the Lean model in
//! `lazily-formal/LazilyFormal/StateChart.lean`.
//!
//! A chart is **compute, not protocol**: it is never serialized as a distinct
//! wire kind. In this reactive binding the active configuration lives in a
//! [`Cell(Config)`], so any slot/signal/effect reading the configuration is
//! invalidated on a real transition; a no-op self-transition is suppressed by
//! the cell's `std.meta.eql` guard (see the spec's "Self-transitions" section).
//!
//! Implemented subset (per the spec's implementation-status note): compound
//! states, orthogonal (parallel) regions, shallow + deep history, entry/exit/
//! transition actions, named guards, external + internal transitions. Extended
//! state `{"expr": …}` guards and `run` actions are rejected explicitly; `final`
//! states are accepted as leaves without raising completion (`done`) events.
//!
//! Mirrors `lazily-rs/src/statechart.rs`. One `StateChart` per `Context` (the
//! configuration cell is keyed by a comptime value function, matching the same
//! constraint as `StateMachine(S, E)`).

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("context.zig").Context;
const cell = @import("cell.zig").cell;
const Cell = @import("cell.zig").Cell;

/// Cross-version empty initializer for `ArrayListUnmanaged`. Zig <0.16
/// initializes with `.{}`; >=0.16 uses the declared `.empty` constant.
inline fn emptyUnmanaged(comptime T: type) std.ArrayListUnmanaged(T) {
    return if (builtin.zig_version.minor < 16)
        .{}
    else
        .empty;
}

/// State index into `ChartDef.states`. State ids are interned to indices during
/// parse so the active configuration is a small sorted `[]const Index` — a
/// value-semantic, trivially-copyable cell payload with correct `eql`.
const Index = u16;

/// Active configuration cell payload: state indices sorted ascending, deduped.
pub const Config = struct {
    items: []const Index,
};

const Kind = enum {
    atomic,
    compound,
    parallel,
    history_shallow,
    history_deep,
    final,
};

const Transition = struct {
    target: Index,
    guard: ?[]const u8,
    action: [][]const u8,
    internal: bool,
};

const StateDef = struct {
    parent: ?Index,
    kind: Kind,
    initial: ?Index,
    default: ?Index,
    transitions: std.StringHashMapUnmanaged(Transition),
    entry: [][]const u8,
    exit: [][]const u8,
};

/// A parsed, immutable chart definition. Owns an arena with all strings and
/// arrays; call `deinit` to release.
pub const ChartDef = struct {
    arena: std.heap.ArenaAllocator,
    states: []StateDef,
    names: []const []const u8,
    index_of: std.StringHashMapUnmanaged(Index),
    children: []const []const Index,
    order: []const u32,
    depth: []const u32,
    root: Index,

    pub fn deinit(self: *ChartDef) void {
        self.arena.deinit();
    }

    /// Parse a chart definition from the declarative JSON `chart` object.
    /// Returns an error for malformed charts or unsupported features
    /// (`run` actions, `{"expr": …}` guards).
    pub fn parse(allocator: std.mem.Allocator, chart_json: std.json.Value) !ChartDef {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();

        const obj = switch (chart_json) {
            .object => |o| o,
            else => return error.ChartMustBeObject,
        };
        // Validates `chart.initial` is present; descent uses each compound's
        // own `initial` from the root, so the value itself is not stored.
        const top_initial = obj.get("initial") orelse return error.MissingChartInitial;
        if (top_initial != .string) return error.ChartInitialMustBeString;

        const states_obj = switch (obj.get("states") orelse return error.MissingChartStates) {
            .object => |o| o,
            else => return error.StatesMustBeObject,
        };
        const n = states_obj.count();
        if (n == 0) return error.StatesEmpty;
        if (n > 65535) return error.TooManyStates;
        const count: u16 = @intCast(n);

        // First pass: assign indices in document order. ObjectMap preserves
        // insertion order, so iteration yields document order.
        const names = try a.alloc([]const u8, count);
        var index_of = std.StringHashMapUnmanaged(Index){};
        const order = try a.alloc(u32, count);
        {
            var it = states_obj.iterator();
            var i: Index = 0;
            while (it.next()) |entry| {
                if (i >= count) break;
                names[i] = try a.dupe(u8, entry.key_ptr.*);
                try index_of.put(a, names[i], i);
                order[i] = i;
                i += 1;
            }
        }

        // Second pass: parse each state, resolving name references to indices.
        const states = try a.alloc(StateDef, count);
        {
            var it = states_obj.iterator();
            while (it.next()) |entry| {
                const id = index_of.get(entry.key_ptr.*) orelse continue;
                states[id] = try parseState(a, &index_of, entry.value_ptr.*);
            }
        }

        // Derived structure: children (sorted by document order) and root.
        const kids_lists = try a.alloc(std.ArrayListUnmanaged(Index), count);
        for (kids_lists) |*k| k.* = emptyUnmanaged(Index);
        var root: ?Index = null;
        {
            var it = states_obj.iterator();
            while (it.next()) |entry| {
                const id = index_of.get(entry.key_ptr.*) orelse continue;
                if (states[id].parent) |p| {
                    kids_lists[p].append(a, id) catch return error.OutOfMemory;
                } else {
                    if (root != null) return error.ChartHasMultipleRoots;
                    root = id;
                }
            }
        }
        const root_idx = root orelse return error.ChartHasNoRoot;
        for (kids_lists) |*k| std.mem.sort(Index, k.items, order, kidsOrderLess);

        const children = try a.alloc([]const Index, count);
        for (kids_lists, 0..) |*k, i| children[i] = try a.dupe(Index, k.items);

        const depth = try a.alloc(u32, count);
        @memset(depth, 0);
        computeDepth(kids_lists, root_idx, 0, depth);

        return ChartDef{
            .arena = arena,
            .states = states,
            .names = names,
            .index_of = index_of,
            .children = children,
            .order = order,
            .depth = depth,
            .root = root_idx,
        };
    }
};

/// A history recording for a region exited at least once.
const Recording = union(enum) {
    /// Direct child of the region that was active.
    shallow: Index,
    /// Full active sub-configuration below the region (leaves + ancestors).
    deep: []const Index,
};

/// A reactive full-Harel state chart backed by a configuration cell.
pub const StateChart = struct {
    def: *ChartDef,
    config: *Cell(Config),
    history: std.AutoHashMapUnmanaged(Index, Recording),
    last_actions: std.ArrayListUnmanaged([]const u8),
    arena: std.heap.ArenaAllocator,
    alloc: std.mem.Allocator,

    pub fn init(ctx: *Context, def: *ChartDef) !*StateChart {
        const self = try ctx.allocator.create(StateChart);
        self.* = .{
            .def = def,
            .config = undefined,
            .history = .{},
            .last_actions = emptyUnmanaged([]const u8),
            .arena = std.heap.ArenaAllocator.init(ctx.allocator),
            .alloc = ctx.allocator,
        };
        const pa = self.arena.allocator();

        var enter = emptyUnmanaged(Index);
        var entry_acts = emptyUnmanaged([]const u8);
        enterSubtree(def, pa, def.root, &enter, &entry_acts) catch return error.OutOfMemory;
        const items = sortedDedup(pa, enter.items) catch return error.OutOfMemory;
        self.last_actions.appendSlice(pa, entry_acts.items) catch return error.OutOfMemory;

        _initial_config = .{ .items = items };
        defer _initial_config = null;
        self.config = try cell(Config, ctx, initialConfigFn, null);
        return self;
    }

    pub fn deinit(self: *StateChart) void {
        // All history / last_actions / config storage lives in the arena.
        self.arena.deinit();
        self.alloc.destroy(self);
    }

    /// Ordered action names fired by the initial entry or the most recent
    /// `send` (exit → transition → entry). Borrowed view; valid until the next
    /// `send` or `deinit`.
    pub fn lastActions(self: *const StateChart) []const []const u8 {
        return self.last_actions.items;
    }

    /// The full active configuration (active leaves plus all active ancestors).
    pub fn configuration(self: *const StateChart) Config {
        return self.config.get();
    }

    /// Active atomic leaves, sorted by state id (one per parallel region; one
    /// for single-region charts). The returned array is allocated in `allocator`
    /// and owned by the caller; the id strings are borrowed from the chart def.
    pub fn activeLeaves(self: *const StateChart, allocator: std.mem.Allocator) ![][]const u8 {
        const config = self.config.get();
        var leaves = emptyUnmanaged([]const u8);
        for (config.items) |s| {
            switch (self.def.states[s].kind) {
                .atomic, .final => leaves.append(allocator, self.def.names[s]) catch return error.OutOfMemory,
                else => {},
            }
        }
        std.mem.sort([]const u8, leaves.items, {}, strLess);
        return leaves.toOwnedSlice(allocator) catch return error.OutOfMemory;
    }

    /// Hierarchical "state-in" predicate: `true` iff `id` is in the active
    /// configuration. Unknown ids return `false`.
    pub fn matches(self: *const StateChart, id: []const u8) bool {
        const idx = self.def.index_of.get(id) orelse return false;
        return configContains(self.config.get(), idx);
    }

    /// Send an event. Returns `true` if any transition was taken, `false` if
    /// rejected (configuration unchanged, no actions fired). `guards` resolves
    /// named guards for this send (absent/unknown name → fail-closed `false`).
    pub fn send(self: *StateChart, event: []const u8, guards: *const std.StringHashMap(bool)) bool {
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        const a = scratch.allocator();
        const def = self.def;
        const pa = self.arena.allocator();
        const config = self.config.get();

        // 1. Enabled transitions: per active leaf, innermost passing match.
        var candidates = emptyUnmanaged(Candidate);
        for (config.items) |leaf| {
            switch (def.states[leaf].kind) {
                .atomic, .final => {},
                else => continue,
            }
            var chain: [64]Index = undefined;
            const n = fillAncestors(def, leaf, &chain);
            for (chain[0..n]) |anc| {
                if (def.states[anc].transitions.get(event)) |t| {
                    if (guardPasses(t, guards)) {
                        candidates.append(a, .{ .source = anc, .transition = t, .leaf = leaf }) catch return false;
                        break; // innermost wins for this leaf's chain
                    }
                }
            }
        }

        if (candidates.items.len == 0) {
            self.last_actions.clearRetainingCapacity();
            return false;
        }

        // 2. Conflict resolution: order by source depth desc, then document
        //    order; take greedily, skipping any whose exit set intersects the
        //    taken union.
        std.mem.sort(Candidate, candidates.items, def, candLess);

        var exit_union = emptyUnmanaged(Index);
        var enter_union = emptyUnmanaged(Index);
        var taken = emptyUnmanaged(Transition);
        for (candidates.items) |cand| {
            var exit_set = emptyUnmanaged(Index);
            var enter_set = emptyUnmanaged(Index);
            computeExitEnter(def, a, &self.history, cand.source, cand.transition, cand.leaf, config, &exit_set, &enter_set) catch return false;
            if (anyCommon(exit_set.items, exit_union.items)) continue; // conflicts
            for (exit_set.items) |s| addIfAbsent(&exit_union, a, s) catch return false;
            for (enter_set.items) |s| addIfAbsent(&enter_union, a, s) catch return false;
            taken.append(a, cand.transition) catch return false;
        }

        if (taken.items.len == 0) {
            self.last_actions.clearRetainingCapacity();
            return false;
        }

        // 3. Record history for regions being exited that own a history child.
        for (exit_union.items) |s| {
            if (historyChildOf(def, s)) |h| {
                recordRegion(def, pa, s, h, config, &self.history) catch return false;
            }
        }

        // 4. Action trace: exit (innermost-first) → transition → entry (outermost-first).
        self.last_actions.clearRetainingCapacity();
        {
            const arr = a.dupe(Index, exit_union.items) catch return false;
            std.mem.sort(Index, arr, def, depthDesc);
            for (arr) |s| {
                for (def.states[s].exit) |act| self.last_actions.append(pa, act) catch return false;
            }
        }
        for (taken.items) |t| {
            for (t.action) |act| self.last_actions.append(pa, act) catch return false;
        }
        {
            const arr = a.dupe(Index, enter_union.items) catch return false;
            std.mem.sort(Index, arr, def, depthAsc);
            for (arr) |s| {
                for (def.states[s].entry) |act| self.last_actions.append(pa, act) catch return false;
            }
        }

        // 5. Apply new configuration.
        var tmp = emptyUnmanaged(Index);
        for (config.items) |s| {
            if (!contains(exit_union.items, s)) tmp.append(a, s) catch return false;
        }
        for (enter_union.items) |s| addIfAbsent(&tmp, a, s) catch return false;
        const new_items = sortedDedup(pa, tmp.items) catch return false;

        // Cell.set suppresses the no-op self-transition via std.meta.eql.
        self.config.set(.{ .items = new_items });
        return true;
    }
};

// --- configuration cell plumbing (comptime value-fn + threadlocal initial) ---

threadlocal var _initial_config: ?Config = null;

fn initialConfigFn(_: *Context) anyerror!Config {
    return _initial_config orelse return error.NoInitialConfig;
}

// --- parse helpers ---

fn parseState(a: std.mem.Allocator, index_of: *const std.StringHashMapUnmanaged(Index), raw: std.json.Value) !StateDef {
    const o = switch (raw) {
        .object => |oo| oo,
        else => return error.StateMustBeObject,
    };

    if (o.get("run") != null) return error.UnsupportedRunAction;

    const parent: ?Index = if (o.get("parent")) |v| try resolveName(index_of, try stringValue(v)) else null;
    const initial: ?Index = if (o.get("initial")) |v| try resolveName(index_of, try stringValue(v)) else null;
    const default: ?Index = if (o.get("default")) |v| try resolveName(index_of, try stringValue(v)) else null;

    const kind: Kind = blk: {
        if (o.get("history")) |hv| {
            const hs = switch (hv) {
                .string => |s| s,
                else => return error.UnknownHistoryKind,
            };
            if (std.mem.eql(u8, hs, "shallow")) break :blk .history_shallow;
            if (std.mem.eql(u8, hs, "deep")) break :blk .history_deep;
            return error.UnknownHistoryKind;
        }
        if (o.get("parallel")) |pv| if (pv == .bool and pv.bool) break :blk .parallel;
        if (o.get("kind")) |kv| if (kv == .string and std.mem.eql(u8, kv.string, "final")) break :blk .final;
        if (initial != null) break :blk .compound;
        break :blk .atomic;
    };

    var transitions = std.StringHashMapUnmanaged(Transition){};
    if (o.get("on")) |onv| {
        switch (onv) {
            .object => |onobj| {
                var it = onobj.iterator();
                while (it.next()) |e| {
                    const t = try parseTransition(a, index_of, e.value_ptr.*);
                    const key = try a.dupe(u8, e.key_ptr.*);
                    try transitions.put(a, key, t);
                }
            },
            else => return error.TransitionsMustBeObject,
        }
    }

    return StateDef{
        .parent = parent,
        .kind = kind,
        .initial = initial,
        .default = default,
        .transitions = transitions,
        .entry = try parseActionList(a, o.get("entry")),
        .exit = try parseActionList(a, o.get("exit")),
    };
}

fn parseTransition(a: std.mem.Allocator, index_of: *const std.StringHashMapUnmanaged(Index), raw: std.json.Value) !Transition {
    switch (raw) {
        .string => |s| return Transition{
            .target = try resolveName(index_of, s),
            .guard = null,
            .action = &.{},
            .internal = false,
        },
        .object => |o| {
            const target_v = o.get("target") orelse return error.TransitionRequiresTarget;
            const target_s = switch (target_v) {
                .string => |s| s,
                else => return error.TransitionRequiresTarget,
            };
            const guard: ?[]const u8 = if (o.get("guard")) |gv| switch (gv) {
                .string => |s| try a.dupe(u8, s),
                .object => return error.UnsupportedExprGuard,
                else => return error.GuardMustBeString,
            } else null;
            const internal = if (o.get("internal")) |iv| (iv == .bool and iv.bool) else false;
            return Transition{
                .target = try resolveName(index_of, target_s),
                .guard = guard,
                .action = try parseActionList(a, o.get("action")),
                .internal = internal,
            };
        },
        else => return error.TransitionMustBeStringOrObject,
    }
}

fn parseActionList(a: std.mem.Allocator, raw: ?std.json.Value) ![][]const u8 {
    const v = raw orelse return &.{};
    switch (v) {
        .array => |arr| {
            const out = try a.alloc([]const u8, arr.items.len);
            for (arr.items, 0..) |item, i| {
                out[i] = switch (item) {
                    .string => |s| try a.dupe(u8, s),
                    else => return error.ActionMustBeString,
                };
            }
            return out;
        },
        else => return error.EntryExitMustBeArray,
    }
}

fn stringValue(v: std.json.Value) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => error.UnknownStateReference,
    };
}

fn resolveName(index_of: *const std.StringHashMapUnmanaged(Index), name: []const u8) !Index {
    return index_of.get(name) orelse error.UnknownStateReference;
}

fn kidsOrderLess(order: []const u32, a: Index, b: Index) bool {
    return order[a] < order[b];
}

fn computeDepth(kids: []const std.ArrayListUnmanaged(Index), id: Index, d: u32, depth: []u32) void {
    depth[id] = d;
    for (kids[id].items) |c| computeDepth(kids, c, d + 1, depth);
}

// --- algorithm helpers ---

fn fillAncestors(def: *const ChartDef, id: Index, buf: []Index) usize {
    var n: usize = 0;
    var cur: Index = id;
    while (true) {
        if (n >= buf.len) break;
        buf[n] = cur;
        n += 1;
        cur = def.states[cur].parent orelse break;
    }
    return n;
}

fn contains(set: []const Index, x: Index) bool {
    for (set) |s| {
        if (s == x) return true;
    }
    return false;
}

fn configContains(c: Config, idx: Index) bool {
    return contains(c.items, idx);
}

fn addIfAbsent(list: *std.ArrayListUnmanaged(Index), a: std.mem.Allocator, x: Index) !void {
    if (!contains(list.items, x)) try list.append(a, x);
}

fn anyCommon(x: []const Index, y: []const Index) bool {
    for (x) |v| {
        if (contains(y, v)) return true;
    }
    return false;
}

fn sortedDedup(allocator: std.mem.Allocator, src: []const Index) ![]const Index {
    const out = try allocator.dupe(Index, src);
    std.mem.sort(Index, out, {}, indexAsc);
    var w: usize = 0;
    for (out) |v| {
        if (w == 0 or out[w - 1] != v) {
            out[w] = v;
            w += 1;
        }
    }
    return out[0..w];
}

fn indexAsc(_: void, a: Index, b: Index) bool {
    return a < b;
}

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn lca(def: *const ChartDef, a: Index, b: Index) Index {
    var aa: [64]Index = undefined;
    const na = fillAncestors(def, a, &aa);
    var ab: [64]Index = undefined;
    const nb = fillAncestors(def, b, &ab);
    for (ab[0..nb]) |c| {
        if (contains(aa[0..na], c)) return c;
    }
    return def.root;
}

fn isProperDescendant(def: *const ChartDef, desc: Index, anc: Index) bool {
    if (desc == anc) return false;
    var chain: [64]Index = undefined;
    const n = fillAncestors(def, desc, &chain);
    // chain[0] == desc; proper ancestors are chain[1..n].
    for (chain[1..n]) |c| {
        if (c == anc) return true;
    }
    return false;
}

fn guardPasses(t: Transition, guards: *const std.StringHashMap(bool)) bool {
    const name = t.guard orelse return true;
    return guards.get(name) orelse false; // fail-closed
}

fn historyChildOf(def: *const ChartDef, region: Index) ?Index {
    for (def.children[region]) |c| {
        switch (def.states[c].kind) {
            .history_shallow, .history_deep => return c,
            else => {},
        }
    }
    return null;
}

/// Enter `state` and its default descendants, recording entry ids + actions
/// top-down.
fn enterSubtree(
    def: *const ChartDef,
    a: std.mem.Allocator,
    state: Index,
    enter: *std.ArrayListUnmanaged(Index),
    actions: *std.ArrayListUnmanaged([]const u8),
) !void {
    try addIfAbsent(enter, a, state);
    for (def.states[state].entry) |act| try actions.append(a, act);
    switch (def.states[state].kind) {
        .atomic, .final, .history_shallow, .history_deep => {},
        .compound => {
            if (def.states[state].initial) |init| try enterSubtree(def, a, init, enter, actions);
        },
        .parallel => {
            for (def.children[state]) |c| try enterSubtree(def, a, c, enter, actions);
        },
    }
}

/// Path from just-below `lca` down to `target` (exclusive lca, inclusive target).
fn pathBelow(def: *const ChartDef, a: std.mem.Allocator, top: Index, target: Index) ![]Index {
    var chain = emptyUnmanaged(Index);
    var cur: Index = target;
    while (true) {
        try chain.append(a, cur);
        if (cur == top) break;
        const p = def.states[cur].parent orelse break;
        cur = p;
    }
    // chain == [target, ..., top-or-root]; drop top and above.
    var idx: usize = chain.items.len;
    for (chain.items, 0..) |c, i| {
        if (c == top) {
            idx = i;
            break;
        }
    }
    const out = try a.alloc(Index, idx);
    for (chain.items[0..idx], 0..) |c, i| out[idx - 1 - i] = c;
    return out; // [child-of-top, ..., target]
}

fn restoreViaHistory(
    def: *const ChartDef,
    a: std.mem.Allocator,
    history: *const std.AutoHashMapUnmanaged(Index, Recording),
    hist: Index,
    region: Index,
    enter: *std.ArrayListUnmanaged(Index),
) !void {
    if (history.get(hist)) |rec| {
        switch (rec) {
            .shallow => |child| {
                try addIfAbsent(enter, a, child);
                var ignored = emptyUnmanaged([]const u8);
                try enterSubtree(def, a, child, enter, &ignored);
            },
            .deep => |set| {
                for (set) |s| try addIfAbsent(enter, a, s);
            },
        }
        return;
    }
    // First entry: descend via `default`, else the region's `initial`.
    var start: ?Index = def.states[hist].default;
    if (start == null) start = def.states[region].initial;
    if (start) |s| {
        const path = try pathBelow(def, a, region, s);
        for (path) |p| try addIfAbsent(enter, a, p);
        var ignored = emptyUnmanaged([]const u8);
        try enterSubtree(def, a, s, enter, &ignored);
    }
}

fn computeExitEnter(
    def: *const ChartDef,
    a: std.mem.Allocator,
    history: *const std.AutoHashMapUnmanaged(Index, Recording),
    source: Index,
    t: Transition,
    leaf: Index,
    config: Config,
    exit_set: *std.ArrayListUnmanaged(Index),
    enter_set: *std.ArrayListUnmanaged(Index),
) !void {
    const target = t.target;
    const internal = t.internal and (target == source or isProperDescendant(def, target, source));
    const top = if (internal) source else lca(def, leaf, target);

    // Exit set: active proper-descendants of the lca.
    for (config.items) |s| {
        if (isProperDescendant(def, s, top)) try addIfAbsent(exit_set, a, s);
    }

    // Enter set.
    switch (def.states[target].kind) {
        .history_shallow, .history_deep => {
            const region = def.states[target].parent orelse def.root;
            const path = try pathBelow(def, a, top, region);
            for (path) |p| try addIfAbsent(enter_set, a, p);
            try restoreViaHistory(def, a, history, target, region, enter_set);
        },
        else => {
            const path = try pathBelow(def, a, top, target);
            for (path) |p| try addIfAbsent(enter_set, a, p);
            var ignored = emptyUnmanaged([]const u8);
            try enterSubtree(def, a, target, enter_set, &ignored);
        },
    }
}

fn recordRegion(
    def: *const ChartDef,
    a: std.mem.Allocator,
    region: Index,
    hist_child: Index,
    config: Config,
    history: *std.AutoHashMapUnmanaged(Index, Recording),
) !void {
    switch (def.states[hist_child].kind) {
        .history_shallow => {
            for (def.children[region]) |c| {
                switch (def.states[c].kind) {
                    .history_shallow, .history_deep => continue,
                    else => {},
                }
                if (configContains(config, c)) {
                    try history.put(a, hist_child, .{ .shallow = c });
                    return;
                }
            }
        },
        .history_deep => {
            var set = emptyUnmanaged(Index);
            for (config.items) |s| {
                if (isProperDescendant(def, s, region)) try set.append(a, s);
            }
            const owned = try sortedDedup(a, set.items);
            try history.put(a, hist_child, .{ .deep = owned });
        },
        else => {},
    }
}

const Candidate = struct { source: Index, transition: Transition, leaf: Index };

fn candLess(def: *ChartDef, a: Candidate, b: Candidate) bool {
    const da = def.depth[a.source];
    const db = def.depth[b.source];
    if (da != db) return da > db; // source depth desc (innermost wins)
    return def.order[a.source] < def.order[b.source]; // document order
}

fn depthAsc(def: *ChartDef, a: Index, b: Index) bool {
    return def.depth[a] < def.depth[b];
}

fn depthDesc(def: *ChartDef, a: Index, b: Index) bool {
    return def.depth[a] > def.depth[b];
}

// ----------------------------------------------------------------------
// Conformance against the canonical lazily-spec fixtures (mirrored under
// test/statechart/). Each fixture is embedded at compile time; replay mirrors
// lazily-rs/tests/statechart_conformance.rs.
// ----------------------------------------------------------------------

fn assertActive(allocator: std.mem.Allocator, sc: *const StateChart, expected: std.json.Value) !void {
    const leaves = try sc.activeLeaves(allocator);
    var want = emptyUnmanaged([]const u8);
    switch (expected) {
        .string => |s| try want.append(allocator, s),
        .array => |arr| {
            for (arr.items) |v| try want.append(allocator, v.string);
        },
        else => return error.ActiveMustBeStringOrArray,
    }
    std.mem.sort([]const u8, want.items, {}, strLess);
    try std.testing.expectEqual(want.items.len, leaves.len);
    for (leaves, 0..) |l, i| try std.testing.expectEqualStrings(want.items[i], l);
}

fn assertActions(sc: *const StateChart, expected: std.json.Value) !void {
    const arr = switch (expected) {
        .array => |x| x,
        else => return error.ActionsMustBeArray,
    };
    const got = sc.lastActions();
    try std.testing.expectEqual(arr.items.len, got.len);
    for (got, 0..) |g, i| try std.testing.expectEqualStrings(arr.items[i].string, g);
}

fn runFixture(bytes: []const u8) !void {
    var tarena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tarena.deinit();
    const ta = tarena.allocator();

    const parsed = try std.json.parseFromSlice(std.json.Value, ta, bytes, .{});
    const fixture = parsed.value;
    const chart_obj = switch (fixture.object.get("chart") orelse return error.FixtureMissingChart) {
        .object => |o| o,
        else => return error.FixtureChartMustBeObject,
    };

    var def = try ChartDef.parse(std.testing.allocator, .{ .object = chart_obj });
    defer def.deinit();
    var ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var sc = try StateChart.init(ctx, &def);
    defer sc.deinit();

    try assertActive(ta, sc, fixture.object.get("initial_active") orelse return error.FixtureMissingInitialActive);
    if (fixture.object.get("initial_actions")) |ia| try assertActions(sc, ia);

    const steps = switch (fixture.object.get("steps") orelse return error.FixtureMissingSteps) {
        .array => |x| x,
        else => return error.FixtureStepsMustBeArray,
    };

    for (steps.items) |step| {
        const event = step.object.get("event").?.string;
        var guards = std.StringHashMap(bool).init(ta);
        if (step.object.get("guards")) |gv| {
            var it = gv.object.iterator();
            while (it.next()) |e| try guards.put(e.key_ptr.*, e.value_ptr.bool);
        }

        const accepted = sc.send(event, &guards);
        try std.testing.expectEqual(step.object.get("accepted").?.bool, accepted);

        try assertActive(ta, sc, step.object.get("active") orelse return error.FixtureStepMissingActive);

        if (step.object.get("matches")) |mv| {
            var mit = mv.object.iterator();
            while (mit.next()) |e| {
                try std.testing.expectEqual(e.value_ptr.bool, sc.matches(e.key_ptr.*));
            }
        }
        if (step.object.get("actions")) |av| try assertActions(sc, av);
    }
}

test "lazily/statechart conformance: flat_cycle" {
    try runFixture(@embedFile("test/statechart/flat_cycle.json"));
}

test "lazily/statechart conformance: hierarchical_player" {
    try runFixture(@embedFile("test/statechart/hierarchical_player.json"));
}

test "lazily/statechart conformance: guarded_door" {
    try runFixture(@embedFile("test/statechart/guarded_door.json"));
}

test "lazily/statechart conformance: parallel_regions" {
    try runFixture(@embedFile("test/statechart/parallel_regions.json"));
}

test "lazily/statechart conformance: history_shallow" {
    try runFixture(@embedFile("test/statechart/history_shallow.json"));
}

test "lazily/statechart conformance: history_deep" {
    try runFixture(@embedFile("test/statechart/history_deep.json"));
}

test "lazily/statechart conformance: entry_exit_actions" {
    try runFixture(@embedFile("test/statechart/entry_exit_actions.json"));
}

test "lazily/statechart: rejects unsupported features explicitly" {
    const run_json =
        \\{"initial":"a","states":{"root":{"initial":"a"},"a":{"parent":"root","run":["x"]}}}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), run_json, .{});
    try std.testing.expectError(error.UnsupportedRunAction, ChartDef.parse(std.testing.allocator, parsed.value));

    const expr_json =
        \\{"initial":"a","states":{"root":{"initial":"a"},"a":{"parent":"root","on":{"GO":{"target":"a","guard":{"expr":"x"}}}}}}
    ;
    const parsed2 = try std.json.parseFromSlice(std.json.Value, arena.allocator(), expr_json, .{});
    try std.testing.expectError(error.UnsupportedExprGuard, ChartDef.parse(std.testing.allocator, parsed2.value));
}
