//! View compute document. Signals are sources, standing expressions are guarded
//! computeds, and the optional chart is one statechart cell. Semantic trace
//! only: no pixels, focus, or host widgets.
const std = @import("std");
const builtin = @import("builtin");
const Context = @import("context.zig").Context;
const Compute = @import("context.zig").Compute;
const Source = @import("cell.zig").Source;
const Computed = @import("cell.zig").Computed;
const computedKeyed = @import("cell.zig").computedKeyed;
const effectKeyed = @import("effect.zig").effectKeyed;
const Effect = @import("effect.zig").Effect;
const ChartDef = @import("statechart.zig").ChartDef;
const StateChart = @import("statechart.zig").StateChart;
const conformance = @import("conformance_manifest.zig");

var diag_buf: [240]u8 = undefined;
var diag: []const u8 = "";

fn fail(comptime fmt: []const u8, args: anytype) error{Rejected} {
    diag = std.fmt.bufPrint(&diag_buf, fmt, args) catch fmt;
    return error.Rejected;
}

fn listEmpty(comptime T: type) std.ArrayList(T) {
    return if (builtin.zig_version.minor < 16) .{} else .empty;
}

const Kind = enum { nul, boolean, int, str };

const ViewValue = struct {
    k: Kind = .nul,
    b: bool = false,
    n: i64 = 0,
    s: []const u8 = "",

    fn json(self: ViewValue) std.json.Value {
        return switch (self.k) {
            .nul => .null,
            .boolean => .{ .bool = self.b },
            .int => .{ .integer = self.n },
            .str => .{ .string = self.s },
        };
    }

    fn eql(self: ViewValue, other: ViewValue) bool {
        if (self.k != other.k) return false;
        return switch (self.k) {
            .nul => true,
            .boolean => self.b == other.b,
            .int => self.n == other.n,
            .str => std.mem.eql(u8, self.s, other.s),
        };
    }
};

const Node = struct {
    role: []const u8,
    children: []const []const u8,
    flow: ?[]const u8,
};

const ExprDoc = struct {
    key: []const u8,
    expr: std.json.Value,
};

const SigBox = struct { initial: ViewValue };
const ExprBox = struct { view: *View, expr: std.json.Value };

fn sourceValue(c: *Compute) anyerror!ViewValue {
    const key = c.node.cache_key orelse return error.Rejected;
    const box: *const SigBox = @ptrFromInt(key);
    return box.initial;
}

fn exprValue(c: *Compute) anyerror!ViewValue {
    const key = c.node.cache_key orelse return error.Rejected;
    const box: *const ExprBox = @ptrFromInt(key);
    return box.view.evalExpr(box.expr, c, false);
}

fn hostBody(c: *Compute) anyerror!?void {
    const key = c.node.cache_key orelse return error.Rejected;
    const view: *View = @ptrFromInt(key);
    if (view.exprs.count() > 0) {
        var it = view.exprs.valueIterator();
        while (it.next()) |slot| _ = c.get(slot.*);
    } else {
        var it = view.signals.valueIterator();
        while (it.next()) |slot| _ = c.get(slot.*);
    }
    return null;
}

pub const View = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    ctx: *Context,
    root: []const u8,
    nodes: std.StringHashMap(Node),
    signals: std.StringHashMap(*Source(ViewValue)),
    exprs: std.StringHashMap(*Computed(ViewValue)),
    effects: std.StringHashMap(std.json.Value),
    chart_def: ?*ChartDef = null,
    chart: ?*StateChart = null,
    host: ?*Effect(void) = null,
    payload: ViewValue = .{},
    in_effect: bool = false,

    pub fn install(ctx: *Context, doc: std.json.Value) !*View {
        const view = try ctx.allocator.create(View);
        errdefer ctx.allocator.destroy(view);
        view.* = .{
            .allocator = ctx.allocator,
            .arena = std.heap.ArenaAllocator.init(ctx.allocator),
            .ctx = ctx,
            .root = "",
            .nodes = undefined,
            .signals = undefined,
            .exprs = undefined,
            .effects = undefined,
        };
        const alloc = view.arena.allocator();
        view.nodes = std.StringHashMap(Node).init(alloc);
        view.signals = std.StringHashMap(*Source(ViewValue)).init(alloc);
        view.exprs = std.StringHashMap(*Computed(ViewValue)).init(alloc);
        view.effects = std.StringHashMap(std.json.Value).init(alloc);
        errdefer view.arena.deinit();
        try view.populate(doc);
        return view;
    }

    pub fn deinit(self: *View) void {
        var cells = self.exprs.valueIterator();
        while (cells.next()) |cell| self.allocator.destroy(cell.*);
        if (self.host) |effect| {
            effect.dispose();
            self.allocator.destroy(effect);
        }
        if (self.chart) |chart| chart.deinit();
        if (self.chart_def) |def| {
            def.deinit();
            self.allocator.destroy(def);
        }
        self.arena.deinit();
        self.allocator.destroy(self);
    }

    fn a(self: *View) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn dupe(self: *View, s: []const u8) ![]u8 {
        return self.a().dupe(u8, s);
    }

    fn populate(self: *View, doc: std.json.Value) !void {
        const root_obj = try asObj(doc);
        try allow(root_obj, &.{ "id", "root", "signals", "nodes", "chart" });
        const id = try asStr(root_obj.get("id") orelse return fail("missing id", .{}));
        if (id.len == 0) return fail("empty id", .{});
        const root = try asStr(root_obj.get("root") orelse return fail("missing root", .{}));
        if (root.len == 0) return fail("empty root", .{});
        self.root = try self.dupe(root);
        const signals_obj = try asObj(root_obj.get("signals") orelse return fail("missing signals", .{}));
        const nodes_obj = try asObj(root_obj.get("nodes") orelse return fail("missing nodes", .{}));
        if (nodes_obj.count() == 0) return fail("empty nodes", .{});
        const has_chart = root_obj.get("chart") != null;
        if (has_chart) {
            _ = try asObj(root_obj.get("chart").?);
        }

        var initials = std.StringHashMap(ViewValue).init(self.a());
        var sig_it = signals_obj.iterator();
        while (sig_it.next()) |entry| {
            if (entry.key_ptr.*.len == 0) return fail("empty signal id", .{});
            const sig = try asObj(entry.value_ptr.*);
            try allow(sig, &.{"initial"});
            const initial = try literal(sig.get("initial") orelse return fail("missing initial", .{}));
            const stored = try self.own(initial);
            try initials.put(try self.dupe(entry.key_ptr.*), stored);
        }

        var exprs = listEmpty(ExprDoc);
        var node_it = nodes_obj.iterator();
        while (node_it.next()) |entry| {
            if (entry.key_ptr.*.len == 0) return fail("empty node id", .{});
            const node = try asObj(entry.value_ptr.*);
            try allow(node, &.{ "role", "children", "layout", "text", "bind", "hidden", "disabled", "effects" });
            const role = try asStr(node.get("role") orelse return fail("missing role", .{}));
            if (!oneOf(role, &.{ "text", "button", "field", "list", "region" })) return fail("unknown role {s}", .{role});
            const children = if (node.get("children")) |raw| try self.childrenOf(entry.key_ptr.*, raw) else &.{};
            const flow = if (node.get("layout")) |raw| try self.layoutOf(entry.key_ptr.*, raw) else null;
            if (node.get("bind")) |raw| {
                const bind = try asStr(raw);
                if (bind.len == 0 or !initials.contains(bind)) return fail("bad bind {s}", .{bind});
            }
            const nid = try self.dupe(entry.key_ptr.*);
            if (node.get("text")) |raw| try self.standing("text", nid, raw, &exprs, &initials);
            if (node.get("hidden")) |raw| try self.standing("hidden", nid, raw, &exprs, &initials);
            if (node.get("disabled")) |raw| try self.standing("disabled", nid, raw, &exprs, &initials);
            if (node.get("effects")) |raw| {
                const effect_obj = try asObj(raw);
                try allow(effect_obj, &.{ "activate", "change", "submit" });
                var eit = effect_obj.iterator();
                while (eit.next()) |ev| {
                    try validateEffect(ev.value_ptr.*, &initials, has_chart);
                }
                if (effect_obj.count() > 0) try self.effects.put(nid, .{ .object = effect_obj });
            }
            try self.nodes.put(nid, .{ .role = try self.dupe(role), .children = children, .flow = flow });
        }
        if (!self.nodes.contains(self.root)) return fail("root missing", .{});
        try checkTree(&self.nodes, self.root, self.a());

        var init_it = initials.iterator();
        while (init_it.next()) |entry| {
            const box = try self.a().create(SigBox);
            box.* = .{ .initial = entry.value_ptr.* };
            const src = try Source(ViewValue).initKeyed(self.ctx, @intFromPtr(box), sourceValue, null);
            try self.signals.put(entry.key_ptr.*, src);
        }
        for (exprs.items) |item| {
            _ = try self.evalExpr(item.expr, null, false);
        }
        for (exprs.items) |item| {
            const box = try self.a().create(ExprBox);
            box.* = .{ .view = self, .expr = item.expr };
            const cell = try computedKeyed(ViewValue, self.ctx, @intFromPtr(box), exprValue, null);
            try self.exprs.put(item.key, cell);
        }
        if (has_chart) {
            const def = try self.allocator.create(ChartDef);
            errdefer self.allocator.destroy(def);
            def.* = ChartDef.parse(self.allocator, root_obj.get("chart").?) catch return fail("chart rejected", .{});
            self.chart_def = def;
            self.chart = StateChart.init(self.ctx, def) catch return fail("chart init", .{});
        }
        self.host = try effectKeyed(void, self.ctx, @intFromPtr(self), hostBody);
    }

    fn standing(
        self: *View,
        field: []const u8,
        nid: []const u8,
        raw: std.json.Value,
        exprs: *std.ArrayList(ExprDoc),
        signals: *const std.StringHashMap(ViewValue),
    ) !void {
        const expr = switch (raw) {
            .string => |s| try litExpr(self.a(), s),
            .bool => |b| try litBool(self.a(), b),
            .object => blk: {
                try validateExpr(raw, signals, false);
                break :blk raw;
            },
            else => return fail("{s} must be a literal or expression", .{field}),
        };
        if (!std.mem.eql(u8, field, "text")) {
            if (raw == .string) return fail("{s} must be a boolean or expression", .{field});
        } else if (raw == .bool) return fail("text must be a string or expression", .{});
        const key = try std.fmt.allocPrint(self.a(), "{s}.{s}", .{ nid, field });
        try exprs.append(self.a(), .{ .key = key, .expr = expr });
    }

    fn childrenOf(self: *View, nid: []const u8, raw: std.json.Value) ![]const []const u8 {
        const items = switch (raw) {
            .array => |arr| arr.items,
            else => return fail("children of {s} must be an array", .{nid}),
        };
        const out = try self.a().alloc([]const u8, items.len);
        for (items, 0..) |item, i| {
            const text = try asStr(item);
            if (text.len == 0) return fail("empty child", .{});
            for (out[0..i]) |prev| {
                if (std.mem.eql(u8, prev, text)) return fail("duplicate child {s}", .{text});
            }
            out[i] = try self.dupe(text);
        }
        return out;
    }

    fn layoutOf(self: *View, nid: []const u8, raw: std.json.Value) !?[]const u8 {
        const layout = try asObj(raw);
        try allow(layout, &.{ "flow", "align", "grow" });
        var flow: ?[]const u8 = null;
        if (layout.get("flow")) |value| {
            const text = try asStr(value);
            if (!oneOf(text, &.{ "row", "column", "stack" })) return fail("unknown flow {s}", .{text});
            flow = try self.dupe(text);
        }
        if (layout.get("align")) |value| {
            const text = try asStr(value);
            if (!oneOf(text, &.{ "start", "center", "end", "stretch" })) return fail("unknown align {s}", .{text});
        }
        if (layout.get("grow")) |value| {
            const grow = try literal(value);
            if (grow.k != .int or grow.n < 0) return fail("grow on {s}", .{nid});
        }
        return flow;
    }

    fn own(self: *View, value: ViewValue) !ViewValue {
        if (value.k == .str) {
            var copy = value;
            copy.s = try self.dupe(value.s);
            return copy;
        }
        return value;
    }

    fn read(self: *View, sid: []const u8, cx: ?*Compute) !ViewValue {
        const src = self.signals.get(sid) orelse return fail("unknown signal {s}", .{sid});
        if (cx) |c| return c.get(src);
        return src.get();
    }

    fn evalExpr(self: *View, expr: std.json.Value, cx: ?*Compute, in_effect: bool) anyerror!ViewValue {
        const obj = try asObj(expr);
        try allow(obj, &.{ "op", "args" });
        const op = try asStr(obj.get("op") orelse return fail("missing op", .{}));
        const args = try asArr(obj.get("args") orelse return fail("missing args", .{}));
        if (std.mem.eql(u8, op, "lit")) {
            if (args.len != 1) return fail("lit arity", .{});
            return self.own(try literal(args[0]));
        }
        if (std.mem.eql(u8, op, "ref")) {
            if (args.len != 1) return fail("ref arity", .{});
            return self.read(try asStr(args[0]), cx);
        }
        if (std.mem.eql(u8, op, "call")) return self.evalCall(args, cx, in_effect);
        if (std.mem.eql(u8, op, "if")) {
            if (args.len != 3) return fail("if arity", .{});
            const cond = try self.evalArg(args[0], cx, in_effect);
            if (cond.k != .boolean) return fail("if cond", .{});
            return self.evalArg(if (cond.b) args[1] else args[2], cx, in_effect);
        }
        if (std.mem.eql(u8, op, "eq")) {
            if (args.len != 2) return fail("eq arity", .{});
            const left = try self.evalArg(args[0], cx, in_effect);
            const right = try self.evalArg(args[1], cx, in_effect);
            return .{ .k = .boolean, .b = left.eql(right) };
        }
        if (std.mem.eql(u8, op, "concat")) {
            var buf = listEmpty(u8);
            for (args) |arg| {
                const value = try self.evalArg(arg, cx, in_effect);
                try buf.appendSlice(self.a(), stringify(value));
            }
            return .{ .k = .str, .s = buf.items };
        }
        if (std.mem.eql(u8, op, "trim")) {
            if (args.len != 1) return fail("trim arity", .{});
            const value = try self.evalArg(args[0], cx, in_effect);
            return .{ .k = .str, .s = trimSpace(stringify(value)) };
        }
        return fail("unknown expr op {s}", .{op});
    }

    fn evalCall(self: *View, args: []const std.json.Value, cx: ?*Compute, in_effect: bool) anyerror!ViewValue {
        if (args.len == 0) return fail("call name", .{});
        const name = try asStr(args[0]);
        const rest = args[1..];
        if (std.mem.eql(u8, name, "event")) {
            if (rest.len != 0) return fail("event arity", .{});
            if (!in_effect) return fail("event outside effect", .{});
            return self.payload;
        }
        if (std.mem.eql(u8, name, "not")) {
            if (rest.len != 1) return fail("not arity", .{});
            const value = try self.evalArg(rest[0], cx, in_effect);
            if (value.k != .boolean) return fail("not type", .{});
            return .{ .k = .boolean, .b = !value.b };
        }
        if (std.mem.eql(u8, name, "add")) {
            if (rest.len < 2) return fail("add arity", .{});
            var sum: i64 = 0;
            for (rest) |arg| {
                const value = try self.evalArg(arg, cx, in_effect);
                if (value.k != .int) return fail("add type", .{});
                if ((value.n > 0 and sum > std.math.maxInt(i64) - value.n) or
                    (value.n < 0 and sum < std.math.minInt(i64) - value.n))
                    return fail("add overflow", .{});
                sum += value.n;
            }
            return .{ .k = .int, .n = sum };
        }
        if (std.mem.eql(u8, name, "len")) {
            if (rest.len != 1) return fail("len arity", .{});
            const value = try self.evalArg(rest[0], cx, in_effect);
            if (value.k != .str) return fail("len type", .{});
            const n = std.unicode.utf8CountCodepoints(value.s) catch return fail("len utf8", .{});
            return .{ .k = .int, .n = @intCast(n) };
        }
        return fail("unknown call {s}", .{name});
    }

    fn evalArg(self: *View, value: std.json.Value, cx: ?*Compute, in_effect: bool) anyerror!ViewValue {
        if (value == .object) return self.evalExpr(value, cx, in_effect);
        return self.own(try literal(value));
    }

    pub fn signalsJson(self: *View, alloc: std.mem.Allocator) !std.json.Value {
        var map = objectMapEmpty(alloc);
        var it = self.signals.iterator();
        while (it.next()) |entry| {
            try objectMapPut(&map, alloc, entry.key_ptr.*, entry.value_ptr.*.get().json());
        }
        return .{ .object = map };
    }

    pub fn expressionsJson(self: *View, alloc: std.mem.Allocator) !std.json.Value {
        var map = objectMapEmpty(alloc);
        var it = self.exprs.iterator();
        while (it.next()) |entry| {
            const got = entry.value_ptr.*.get();
            try objectMapPut(&map, alloc, entry.key_ptr.*, got.*.json());
        }
        return .{ .object = map };
    }

    pub fn layoutJson(self: *View, alloc: std.mem.Allocator) !std.json.Value {
        var out = arrayEmpty(alloc);
        try self.walkLayout(alloc, &out, self.root);
        return .{ .array = out };
    }

    fn walkLayout(self: *View, alloc: std.mem.Allocator, out: *std.json.Array, id: []const u8) !void {
        const node = self.nodes.get(id) orelse return fail("missing node {s}", .{id});
        var kids = arrayEmpty(alloc);
        for (node.children) |child| try arrayAppend(&kids, alloc, .{ .string = child });
        var obj = objectMapEmpty(alloc);
        try objectMapPut(&obj, alloc, "id", .{ .string = id });
        try objectMapPut(&obj, alloc, "role", .{ .string = node.role });
        try objectMapPut(&obj, alloc, "children", .{ .array = kids });
        try objectMapPut(&obj, alloc, "flow", if (node.flow) |flow| .{ .string = flow } else .null);
        try arrayAppend(out, alloc, .{ .object = obj });
        for (node.children) |child| try self.walkLayout(alloc, out, child);
    }

    pub fn chartJson(self: *View, alloc: std.mem.Allocator) !std.json.Value {
        const chart = self.chart orelse return .null;
        const leaves = try chart.activeLeaves(alloc);
        var out = arrayEmpty(alloc);
        for (leaves) |leaf| try arrayAppend(&out, alloc, .{ .string = leaf });
        return .{ .array = out };
    }

    pub fn dispatch(self: *View, alloc: std.mem.Allocator, node: []const u8, event: []const u8, value: std.json.Value) !std.json.Value {
        if (!oneOf(event, &.{ "activate", "change", "submit" })) return fail("unknown event {s}", .{event});
        if (!self.nodes.contains(node)) return fail("unknown node {s}", .{node});
        var trace = arrayEmpty(alloc);
        const effects = self.effects.get(node) orelse return .{ .array = trace };
        const effect_obj = try asObj(effects);
        const effect = effect_obj.get(event) orelse return .{ .array = trace };
        self.payload = try self.own(try literal(value));
        self.in_effect = true;
        defer self.in_effect = false;
        try self.exec(alloc, effect, &trace);
        return .{ .array = trace };
    }

    fn exec(self: *View, alloc: std.mem.Allocator, effect: std.json.Value, trace: *std.json.Array) !void {
        const obj = try asObj(effect);
        const op = try asStr(obj.get("op") orelse return fail("effect op", .{}));
        const args = try asArr(obj.get("args") orelse return fail("effect args", .{}));
        if (std.mem.eql(u8, op, "set")) {
            if (args.len != 2) return fail("set arity", .{});
            const sid = try asStr(args[0]);
            const src = self.signals.get(sid) orelse return fail("unknown signal {s}", .{sid});
            const value = try self.evalArg(args[1], null, true);
            src.set(value);
            var rec = objectMapEmpty(alloc);
            try objectMapPut(&rec, alloc, "op", .{ .string = "set" });
            try objectMapPut(&rec, alloc, "signal", .{ .string = sid });
            try objectMapPut(&rec, alloc, "value", value.json());
            try arrayAppend(trace, alloc, .{ .object = rec });
            return;
        }
        if (std.mem.eql(u8, op, "send")) {
            const chart = self.chart orelse return fail("send without chart", .{});
            if (args.len != 1 and args.len != 2) return fail("send arity", .{});
            const name = try asStr(args[0]);
            var rec = objectMapEmpty(alloc);
            try objectMapPut(&rec, alloc, "op", .{ .string = "send" });
            try objectMapPut(&rec, alloc, "event", .{ .string = name });
            if (args.len == 2) {
                const payload = try self.evalArg(args[1], null, true);
                try objectMapPut(&rec, alloc, "payload", payload.json());
            }
            var guards = std.StringHashMap(bool).init(alloc);
            _ = chart.send(name, &guards);
            try arrayAppend(trace, alloc, .{ .object = rec });
            return;
        }
        if (std.mem.eql(u8, op, "batch")) {
            if (args.len == 0) return fail("empty batch", .{});
            for (args) |nested| try self.exec(alloc, nested, trace);
            return;
        }
        return fail("unknown effect op {s}", .{op});
    }
};

fn checkTree(nodes: *const std.StringHashMap(Node), root: []const u8, allocator: std.mem.Allocator) !void {
    var stack = std.StringHashMap(void).init(allocator);
    var done = std.StringHashMap(void).init(allocator);
    const Walker = struct {
        fn walk(
            map: *const std.StringHashMap(Node),
            stack_map: *std.StringHashMap(void),
            done_map: *std.StringHashMap(void),
            id: []const u8,
        ) !void {
            if (stack_map.contains(id)) return fail("cycle {s}", .{id});
            if (done_map.contains(id)) return fail("diamond {s}", .{id});
            try stack_map.put(id, {});
            const node = map.getPtr(id) orelse return fail("dangling {s}", .{id});
            for (node.children) |child| {
                if (!map.contains(child)) return fail("dangling {s}", .{child});
                try walk(map, stack_map, done_map, child);
            }
            _ = stack_map.remove(id);
            try done_map.put(id, {});
        }
    };
    try Walker.walk(nodes, &stack, &done, root);
    if (done.count() != nodes.count()) return fail("orphan", .{});
}

fn validateEffect(effect: std.json.Value, signals: *const std.StringHashMap(ViewValue), has_chart: bool) error{Rejected}!void {
    const obj = try asObj(effect);
    try allow(obj, &.{ "op", "args" });
    const op = try asStr(obj.get("op") orelse return fail("effect op", .{}));
    if (!oneOf(op, &.{ "set", "batch", "send" })) return fail("unknown effect op {s}", .{op});
    const args = try asArr(obj.get("args") orelse return fail("effect args", .{}));
    if (std.mem.eql(u8, op, "set")) {
        if (args.len != 2) return fail("set arity", .{});
        const sid = try asStr(args[0]);
        if (!signals.contains(sid)) return fail("unknown signal {s}", .{sid});
        return validateArg(args[1], signals, true);
    }
    if (std.mem.eql(u8, op, "send")) {
        if (!has_chart) return fail("send without chart", .{});
        if (args.len != 1 and args.len != 2) return fail("send arity", .{});
        _ = try asStr(args[0]);
        if (args.len == 2) return validateArg(args[1], signals, true);
        return;
    }
    if (args.len == 0) return fail("empty batch", .{});
    for (args) |nested| try validateEffect(nested, signals, has_chart);
}

fn validateArg(value: std.json.Value, signals: *const std.StringHashMap(ViewValue), in_effect: bool) error{Rejected}!void {
    if (value == .object) return validateExpr(value, signals, in_effect);
    _ = try literal(value);
}

fn validateExpr(expr: std.json.Value, signals: *const std.StringHashMap(ViewValue), in_effect: bool) error{Rejected}!void {
    const obj = try asObj(expr);
    try allow(obj, &.{ "op", "args" });
    const op = try asStr(obj.get("op") orelse return fail("expr op", .{}));
    if (!oneOf(op, &.{ "lit", "ref", "call", "if", "eq", "concat", "trim" })) return fail("unknown expr op {s}", .{op});
    const args = try asArr(obj.get("args") orelse return fail("expr args", .{}));
    if (std.mem.eql(u8, op, "lit")) {
        if (args.len != 1) return fail("lit arity", .{});
        _ = try literal(args[0]);
        return;
    }
    if (std.mem.eql(u8, op, "ref")) {
        if (args.len != 1) return fail("ref arity", .{});
        const sid = try asStr(args[0]);
        if (!signals.contains(sid)) return fail("unknown signal {s}", .{sid});
        return;
    }
    if (std.mem.eql(u8, op, "call")) return validateCall(args, signals, in_effect);
    if (std.mem.eql(u8, op, "if") and args.len != 3) return fail("if arity", .{});
    if (std.mem.eql(u8, op, "eq") and args.len != 2) return fail("eq arity", .{});
    if (std.mem.eql(u8, op, "trim") and args.len != 1) return fail("trim arity", .{});
    for (args) |arg| try validateArg(arg, signals, in_effect);
}

fn validateCall(args: []const std.json.Value, signals: *const std.StringHashMap(ViewValue), in_effect: bool) error{Rejected}!void {
    if (args.len == 0) return fail("call name", .{});
    const name = try asStr(args[0]);
    if (!oneOf(name, &.{ "event", "not", "add", "len" })) return fail("unknown call {s}", .{name});
    const rest = args[1..];
    if (std.mem.eql(u8, name, "event")) {
        if (rest.len != 0 or !in_effect) return fail("event", .{});
        return;
    }
    if (std.mem.eql(u8, name, "not") and rest.len != 1) return fail("not arity", .{});
    if (std.mem.eql(u8, name, "add") and rest.len < 2) return fail("add arity", .{});
    if (std.mem.eql(u8, name, "len") and rest.len != 1) return fail("len arity", .{});
    for (rest) |arg| try validateArg(arg, signals, in_effect);
}

fn literal(value: std.json.Value) !ViewValue {
    return switch (value) {
        .null => .{},
        .bool => |b| .{ .k = .boolean, .b = b },
        .integer => |n| .{ .k = .int, .n = n },
        .string => |s| .{ .k = .str, .s = s },
        .float => |n| blk: {
            if (n != @trunc(n) or n > @as(f64, @floatFromInt(std.math.maxInt(i64))) or n < @as(f64, @floatFromInt(std.math.minInt(i64))))
                return fail("non-integer", .{});
            break :blk .{ .k = .int, .n = @intFromFloat(n) };
        },
        .number_string => |s| blk: {
            const n = std.fmt.parseInt(i64, s, 10) catch return fail("non-integer", .{});
            break :blk .{ .k = .int, .n = n };
        },
        else => fail("bad literal", .{}),
    };
}

fn stringify(value: ViewValue) []const u8 {
    return switch (value.k) {
        .nul => "",
        .boolean => if (value.b) "true" else "false",
        .int => std.fmt.bufPrint(&int_buf, "{d}", .{value.n}) catch "",
        .str => value.s,
    };
}

var int_buf: [32]u8 = undefined;

fn isSpace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

fn trimSpace(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len) {
        const len = std.unicode.utf8ByteSequenceLength(s[start]) catch break;
        if (start + len > s.len) break;
        const cp = std.unicode.utf8Decode(s[start..][0..len]) catch break;
        if (!isSpace(cp)) break;
        start += len;
    }
    var end = s.len;
    while (end > start) {
        var i = end - 1;
        while (i > start and s[i] & 0xC0 == 0x80) i -= 1;
        const cp = std.unicode.utf8Decode(s[i..end]) catch break;
        if (!isSpace(cp)) break;
        end = i;
    }
    return s[start..end];
}

fn asObj(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |o| o,
        else => fail("expected object", .{}),
    };
}

fn asStr(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => fail("expected string", .{}),
    };
}

fn asArr(value: std.json.Value) ![]const std.json.Value {
    return switch (value) {
        .array => |a| a.items,
        else => fail("expected array", .{}),
    };
}

fn allow(obj: std.json.ObjectMap, keys: []const []const u8) !void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (!oneOf(entry.key_ptr.*, keys)) return fail("unknown field {s}", .{entry.key_ptr.*});
    }
}

fn oneOf(text: []const u8, keys: []const []const u8) bool {
    for (keys) |key| if (std.mem.eql(u8, text, key)) return true;
    return false;
}

fn litExpr(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var args = arrayEmpty(allocator);
    try arrayAppend(&args, allocator, .{ .string = text });
    var obj = objectMapEmpty(allocator);
    try objectMapPut(&obj, allocator, "op", .{ .string = "lit" });
    try objectMapPut(&obj, allocator, "args", .{ .array = args });
    return .{ .object = obj };
}

fn litBool(allocator: std.mem.Allocator, value: bool) !std.json.Value {
    var args = arrayEmpty(allocator);
    try arrayAppend(&args, allocator, .{ .bool = value });
    var obj = objectMapEmpty(allocator);
    try objectMapPut(&obj, allocator, "op", .{ .string = "lit" });
    try objectMapPut(&obj, allocator, "args", .{ .array = args });
    return .{ .object = obj };
}

const object_map_is_managed = @hasField(std.json.ObjectMap, "allocator");
const array_is_managed = @hasField(std.json.Array, "allocator");

fn objectMapEmpty(allocator: std.mem.Allocator) std.json.ObjectMap {
    return if (comptime object_map_is_managed) std.json.ObjectMap.init(allocator) else .empty;
}

fn objectMapPut(map: *std.json.ObjectMap, allocator: std.mem.Allocator, key: []const u8, value: std.json.Value) !void {
    if (comptime object_map_is_managed) return map.put(key, value);
    return map.put(allocator, key, value);
}

fn arrayEmpty(allocator: std.mem.Allocator) std.json.Array {
    return if (comptime array_is_managed) std.json.Array.init(allocator) else .empty;
}

fn arrayAppend(array: *std.json.Array, allocator: std.mem.Allocator, value: std.json.Value) !void {
    if (comptime array_is_managed) return array.append(value);
    return array.append(allocator, value);
}

const expected_files = [_][]const u8{
    "batch_send.json",
    "counter.json",
    "field_change.json",
    "malformed_rejected.json",
};

fn sameJson(a: std.json.Value, b: std.json.Value) bool {
    if (a == .integer and b == .float) return @as(f64, @floatFromInt(a.integer)) == b.float;
    if (a == .float and b == .integer) return a.float == @as(f64, @floatFromInt(b.integer));
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |v| v == b.bool,
        .integer => |v| v == b.integer,
        .float => |v| v == b.float,
        .number_string => |v| std.mem.eql(u8, v, b.number_string),
        .string => |v| std.mem.eql(u8, v, b.string),
        .array => |xs| blk: {
            if (xs.items.len != b.array.items.len) break :blk false;
            for (xs.items, b.array.items) |x, y| if (!sameJson(x, y)) break :blk false;
            break :blk true;
        },
        .object => |xs| blk: {
            if (xs.count() != b.object.count()) break :blk false;
            var it = xs.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!sameJson(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn expectSame(label: []const u8, got: std.json.Value, want: std.json.Value) !void {
    if (sameJson(got, want)) return;
    std.debug.print("{s} mismatch\n got  {any}\n want {any}\n", .{ label, got, want });
    return error.Mismatch;
}

fn replayBytes(bytes: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    const fixture = parsed.value;
    const kind = try asStr((try asObj(fixture)).get("kind") orelse return error.Rejected);
    if (!std.mem.eql(u8, kind, "View")) return error.Rejected;
    var ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    const view = View.install(ctx, (try asObj(fixture)).get("view").?) catch |err| {
        std.debug.print("install {s}: {s}\n", .{ @errorName(err), diag });
        return err;
    };
    defer view.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ta = arena.allocator();
    const obj = try asObj(fixture);
    try expectSame("signals", try view.signalsJson(ta), obj.get("signals").?);
    try expectSame("expressions", try view.expressionsJson(ta), obj.get("expressions").?);
    try expectSame("layout", try view.layoutJson(ta), obj.get("layout").?);
    try expectSame("trace", .{ .array = arrayEmpty(ta) }, obj.get("trace").?);
    try expectSame("chart", try view.chartJson(ta), obj.get("chart").?);
    const steps = try asArr(obj.get("steps").?);
    for (steps, 0..) |step, i| {
        const step_obj = try asObj(step);
        const trace = try view.dispatch(
            ta,
            try asStr(step_obj.get("node").?),
            try asStr(step_obj.get("event").?),
            step_obj.get("value") orelse .null,
        );
        const label = try std.fmt.allocPrint(ta, "step {d}", .{i});
        try expectSame(label, try view.signalsJson(ta), step_obj.get("signals").?);
        try expectSame(label, try view.expressionsJson(ta), step_obj.get("expressions").?);
        try expectSame(label, trace, step_obj.get("trace").?);
        try expectSame(label, try view.chartJson(ta), step_obj.get("chart").?);
    }
}

fn rejectBytes(bytes: []const u8) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    const cases = try asArr((try asObj(parsed.value)).get("cases") orelse return error.Rejected);
    if (cases.len == 0) return error.Rejected;
    for (cases) |case| {
        const obj = try asObj(case);
        var ctx = try Context.init(std.testing.allocator);
        defer ctx.deinit();
        if (View.install(ctx, obj.get("view").?)) |_| return error.Accepted else |_| {}
    }
}

fn readFixture(name: []const u8) ![]u8 {
    const path = try conformance.specAreaPath(std.testing.allocator, "view", name);
    defer std.testing.allocator.free(path);
    return conformance.specReadFile(path) catch |err| {
        if (conformance.conformanceAbsenceIsFatal()) std.debug.panic("view fixture missing: {s}", .{name});
        return err;
    };
}

test "view conformance" {
    const dir_path = conformance.specAreaDir(std.testing.allocator, "view") catch return error.SkipZigTest;
    defer std.testing.allocator.free(dir_path);
    var found = listEmpty([]const u8);
    defer {
        for (found.items) |name| std.testing.allocator.free(name);
        if (builtin.zig_version.minor < 16) found.deinit() else found.deinit(std.testing.allocator);
    }
    if (comptime builtin.zig_version.minor >= 16) {
        const io = std.testing.io;
        var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch {
            if (conformance.conformanceAbsenceIsFatal()) std.debug.panic("view corpus missing", .{});
            return error.SkipZigTest;
        };
        defer dir.close(io);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            try found.append(std.testing.allocator, try std.testing.allocator.dupe(u8, entry.name));
        }
    } else {
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch {
            if (conformance.conformanceAbsenceIsFatal()) std.debug.panic("view corpus missing", .{});
            return error.SkipZigTest;
        };
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            try found.append(std.testing.allocator, try std.testing.allocator.dupe(u8, entry.name));
        }
    }
    std.mem.sort([]const u8, found.items, {}, struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.less);
    if (found.items.len != expected_files.len) return error.FixtureSetDrifted;
    for (found.items, expected_files) |got, want| {
        if (!std.mem.eql(u8, got, want)) return error.FixtureSetDrifted;
    }
    for (expected_files[0..3]) |name| {
        const bytes = readFixture(name) catch return error.SkipZigTest;
        defer std.testing.allocator.free(bytes);
        try replayBytes(bytes);
    }
    const malformed = readFixture("malformed_rejected.json") catch return error.SkipZigTest;
    defer std.testing.allocator.free(malformed);
    try rejectBytes(malformed);
}
