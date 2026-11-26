//! Graph IR interpreter. Documents parse into sources, computeds, and effects.
//! Canonical source is emitted from the document, not from live values.

const std = @import("std");

pub const graph_drain_budget: i32 = 100_000;
pub const GraphFault = error{GraphFault};

const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const Edge = struct {
    from: []const u8,
    kind: []const u8,
    to: []const u8,
};

pub const GraphEffectRun = struct {
    id: []const u8,
    result: Value,
};

const Cx = struct {
    parent: Allocator,
    arena: Allocator,
    fault: *[]u8,

    fn fail(self: Cx, comptime fmt: []const u8, args: anytype) anyerror {
        if (self.fault.len != 0) self.parent.free(self.fault.*);
        self.fault.* = try std.fmt.allocPrint(self.parent, fmt, args);
        return error.GraphFault;
    }
};

fn aaOf(arena: *std.heap.ArenaAllocator) Allocator {
    return arena.allocator();
}

fn jsonEq(left: Value, right: Value) bool {
    if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
    return switch (left) {
        .null => true,
        .bool => |bit| bit == right.bool,
        .integer => |int| int == right.integer,
        .float => |real| real == right.float,
        .number_string => |text| std.mem.eql(u8, text, right.number_string),
        .string => |text| std.mem.eql(u8, text, right.string),
        .array => |list| blk: {
            if (list.items.len != right.array.items.len) break :blk false;
            for (list.items, right.array.items) |a, b| if (!jsonEq(a, b)) break :blk false;
            break :blk true;
        },
        .object => |obj| blk: {
            if (obj.count() != right.object.count()) break :blk false;
            var it = obj.iterator();
            while (it.next()) |entry| {
                const other = right.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!jsonEq(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

fn appendSlice(buf: *std.ArrayList(u8), a: Allocator, text: []const u8) !void {
    try buf.appendSlice(a, text);
}

fn writeString(buf: *std.ArrayList(u8), a: Allocator, text: []const u8) !void {
    try buf.append(a, '"');
    for (text) |c| switch (c) {
        '"' => try appendSlice(buf, a, "\\\""),
        '\\' => try appendSlice(buf, a, "\\\\"),
        '\n' => try appendSlice(buf, a, "\\n"),
        '\r' => try appendSlice(buf, a, "\\r"),
        '\t' => try appendSlice(buf, a, "\\t"),
        else => if (c < 0x20) {
            var hex: [6]u8 = undefined;
            _ = try std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{c});
            try appendSlice(buf, a, &hex);
        } else try buf.append(a, c),
    };
    try buf.append(a, '"');
}

fn writeCanon(buf: *std.ArrayList(u8), a: Allocator, value: Value) !void {
    switch (value) {
        .null => try appendSlice(buf, a, "null"),
        .bool => |bit| try appendSlice(buf, a, if (bit) "true" else "false"),
        .integer => |int| try buf.print(a, "{d}", .{int}),
        .float => |real| try buf.print(a, "{d}", .{real}),
        .number_string => |text| try appendSlice(buf, a, text),
        .string => |text| try writeString(buf, a, text),
        .array => |list| {
            try buf.append(a, '[');
            for (list.items, 0..) |item, i| {
                if (i != 0) try buf.append(a, ',');
                try writeCanon(buf, a, item);
            }
            try buf.append(a, ']');
        },
        .object => |obj| {
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(a);
            var it = obj.iterator();
            while (it.next()) |entry| try keys.append(a, entry.key_ptr.*);
            std.mem.sort([]const u8, keys.items, {}, struct {
                fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
                    return std.mem.order(u8, lhs, rhs) == .lt;
                }
            }.less);
            try buf.append(a, '{');
            for (keys.items, 0..) |key, i| {
                if (i != 0) try buf.append(a, ',');
                try writeString(buf, a, key);
                try buf.append(a, ':');
                try writeCanon(buf, a, obj.get(key).?);
            }
            try buf.append(a, '}');
        },
    }
}

fn canonical(a: Allocator, value: Value) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try writeCanon(&buf, a, value);
    return buf.toOwnedSlice(a);
}

fn validId(text: []const u8) bool {
    if (text.len == 0 or text.len > 128) return false;
    const head = text[0];
    if (!((head >= 'A' and head <= 'Z') or (head >= 'a' and head <= 'z') or head == '_')) return false;
    for (text) |c| {
        if (!((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_')) return false;
    }
    return true;
}

fn field(value: Value, name: []const u8) ?Value {
    return switch (value) {
        .object => |obj| obj.get(name),
        else => null,
    };
}

fn allow(cx: Cx, value: Value, what: []const u8, keys: []const []const u8) anyerror!void {
    const obj = switch (value) {
        .object => |obj| obj,
        else => return,
    };
    var it = obj.iterator();
    while (it.next()) |entry| {
        var ok = false;
        for (keys) |key| if (std.mem.eql(u8, entry.key_ptr.*, key)) {
            ok = true;
        };
        if (!ok) return cx.fail("{s}: unknown field `{s}`", .{ what, entry.key_ptr.* });
    }
}

fn require(cx: Cx, value: Value, name: []const u8, what: []const u8) anyerror!Value {
    return field(value, name) orelse cx.fail("{s} requires `{s}`", .{ what, name });
}

fn asString(cx: Cx, value: Value, what: []const u8) anyerror![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => cx.fail("{s} must be a string, got {s}", .{ what, try canonical(cx.arena, value) }),
    };
}

fn expectObject(cx: Cx, value: Value, what: []const u8) anyerror!void {
    if (value != .object) return cx.fail("{s} must be an object", .{what});
}

fn expectBool(cx: Cx, value: Value) anyerror!bool {
    return switch (value) {
        .bool => |bit| bit,
        else => cx.fail("expected a boolean, got {s}", .{try canonical(cx.arena, value)}),
    };
}

const Num = struct { integer: bool, as_int: i64, as_real: f64 };

fn asNum(cx: Cx, value: Value) anyerror!Num {
    return switch (value) {
        .integer => |int| .{ .integer = true, .as_int = int, .as_real = 0 },
        .float => |real| if (std.math.isFinite(real)) .{ .integer = false, .as_int = 0, .as_real = real } else cx.fail("non-finite number", .{}),
        else => cx.fail("expected a number, got {s}", .{try canonical(cx.arena, value)}),
    };
}

fn canonicalF64(cx: Cx, number: f64) anyerror!Value {
    if (!std.math.isFinite(number)) return cx.fail("non-finite number", .{});
    const min_int: f64 = @floatFromInt(std.math.minInt(i64));
    if (number == @trunc(number) and number >= min_int and number < 9223372036854775808.0) {
        const integer: i64 = @intFromFloat(number);
        if (@as(f64, @floatFromInt(integer)) == number) return .{ .integer = integer };
    }
    return .{ .float = number };
}

fn addInt(cx: Cx, a: i64, b: i64) anyerror!i64 {
    return std.math.add(i64, a, b) catch cx.fail("integer overflow", .{});
}
fn subInt(cx: Cx, a: i64, b: i64) anyerror!i64 {
    return std.math.sub(i64, a, b) catch cx.fail("integer overflow", .{});
}
fn mulInt(cx: Cx, a: i64, b: i64) anyerror!i64 {
    return std.math.mul(i64, a, b) catch cx.fail("integer overflow", .{});
}

fn ordering(cx: Cx, left: Value, right: Value) anyerror!i32 {
    const a = try asNum(cx, left);
    const b = try asNum(cx, right);
    if (a.integer and b.integer) return @as(i32, @intFromBool(a.as_int > b.as_int)) - @as(i32, @intFromBool(a.as_int < b.as_int));
    const lf: f64 = if (a.integer) @floatFromInt(a.as_int) else a.as_real;
    const rf: f64 = if (b.integer) @floatFromInt(b.as_int) else b.as_real;
    return @as(i32, @intFromBool(lf > rf)) - @as(i32, @intFromBool(lf < rf));
}

fn numBin(cx: Cx, op: []const u8, left: Value, right: Value) anyerror!Value {
    const a = try asNum(cx, left);
    const b = try asNum(cx, right);
    if (!std.mem.eql(u8, op, "div") and a.integer and b.integer) {
        if (std.mem.eql(u8, op, "add")) return .{ .integer = try addInt(cx, a.as_int, b.as_int) };
        if (std.mem.eql(u8, op, "sub")) return .{ .integer = try subInt(cx, a.as_int, b.as_int) };
        if (std.mem.eql(u8, op, "mul")) return .{ .integer = try mulInt(cx, a.as_int, b.as_int) };
        return cx.fail("op `{s}` is not an integer operator", .{op});
    }
    const lf: f64 = if (a.integer) @floatFromInt(a.as_int) else a.as_real;
    const rf: f64 = if (b.integer) @floatFromInt(b.as_int) else b.as_real;
    if (std.mem.eql(u8, op, "div") and rf == 0) return cx.fail("division by zero", .{});
    const value: f64 = if (std.mem.eql(u8, op, "add")) lf + rf else if (std.mem.eql(u8, op, "sub")) lf - rf else if (std.mem.eql(u8, op, "mul")) lf * rf else if (std.mem.eql(u8, op, "div")) lf / rf else return cx.fail("op `{s}` is not a numeric operator", .{op});
    return canonicalF64(cx, value);
}

fn checkPolicy(cx: Cx, policy: []const u8, init: Value) anyerror!void {
    if (std.mem.eql(u8, policy, "sum") or std.mem.eql(u8, policy, "max") or std.mem.eql(u8, policy, "min")) _ = try asNum(cx, init) else if (std.mem.eql(u8, policy, "and") or std.mem.eql(u8, policy, "or")) _ = try expectBool(cx, init);
}

fn parseId(cx: Cx, text: []const u8, what: []const u8) anyerror![]const u8 {
    if (!validId(text)) return cx.fail("{s} `{s}` is not a graph IR id", .{ what, text });
    return text;
}

fn isUnary(op: []const u8) bool {
    return std.mem.eql(u8, op, "neg") or std.mem.eql(u8, op, "not") or std.mem.eql(u8, op, "len");
}
fn isBinary(op: []const u8) bool {
    const names = [_][]const u8{ "add", "sub", "mul", "div", "mod", "min", "max", "eq", "ne", "lt", "le", "gt", "ge", "concat", "get", "and", "or" };
    for (names) |name| if (std.mem.eql(u8, op, name)) return true;
    return false;
}

fn parseExpr(cx: Cx, value: Value) anyerror!void {
    try expectObject(cx, value, "expression");
    try allow(cx, value, "expression", &.{ "lit", "ref", "op", "args", "object" });
    var forms: usize = 0;
    for ([_][]const u8{ "lit", "ref", "op", "object" }) |key| if (field(value, key) != null) {
        forms += 1;
    };
    if (forms != 1) return cx.fail("expression must be exactly one of lit, ref, op, or object", .{});
    if (field(value, "args") != null and field(value, "op") == null) return cx.fail("args is only valid on an op expression", .{});
    if (field(value, "lit") != null) return;
    if (field(value, "ref")) |ref| {
        _ = try parseId(cx, try asString(cx, ref, "expression `ref`"), "ref");
        return;
    }
    if (field(value, "object")) |object| {
        if (object != .array) return cx.fail("object expression must be an array", .{});
        var seen = std.StringHashMap(void).init(cx.parent);
        defer seen.deinit();
        for (object.array.items) |item| {
            try expectObject(cx, item, "object field");
            try allow(cx, item, "object field", &.{ "key", "value" });
            const key = try asString(cx, try require(cx, item, "key", "object field"), "object field `key`");
            if (seen.get(key) != null) return cx.fail("duplicate object key `{s}`", .{key});
            try seen.put(key, {});
            try parseExpr(cx, try require(cx, item, "value", "object field"));
        }
        return;
    }
    const op = try asString(cx, try require(cx, value, "op", "expression"), "expression `op`");
    if (!isUnary(op) and !isBinary(op) and !std.mem.eql(u8, op, "if") and !std.mem.eql(u8, op, "array"))
        return cx.fail("unknown op `{s}`", .{op});
    const args = try require(cx, value, "args", "op expression");
    if (args != .array) return cx.fail("op args must be an array", .{});
    const ok = if (isUnary(op)) args.array.items.len == 1 else if (std.mem.eql(u8, op, "if")) args.array.items.len == 3 else if (std.mem.eql(u8, op, "array")) true else args.array.items.len == 2;
    if (!ok) return cx.fail("op `{s}` has the wrong number of arguments", .{op});
    for (args.array.items) |arg| try parseExpr(cx, arg);
}

fn parseStmt(cx: Cx, value: Value) anyerror!void {
    try expectObject(cx, value, "statement");
    const verb = try asString(cx, try require(cx, value, "do", "statement"), "statement `do`");
    if (std.mem.eql(u8, verb, "eval")) {
        try allow(cx, value, "eval", &.{ "do", "expr" });
        try parseExpr(cx, try require(cx, value, "expr", "eval"));
    } else if (std.mem.eql(u8, verb, "set") or std.mem.eql(u8, verb, "merge")) {
        try allow(cx, value, verb, &.{ "do", "target", "expr" });
        _ = try parseId(cx, try asString(cx, try require(cx, value, "target", verb), verb), "write target");
        try parseExpr(cx, try require(cx, value, "expr", verb));
    } else if (std.mem.eql(u8, verb, "seq")) {
        try allow(cx, value, "seq", &.{ "do", "steps" });
        const steps = try require(cx, value, "steps", "seq");
        if (steps != .array) return cx.fail("seq steps must be an array", .{});
        if (steps.array.items.len == 0) return cx.fail("seq steps must not be empty", .{});
        for (steps.array.items) |step| try parseStmt(cx, step);
    } else if (std.mem.eql(u8, verb, "when")) {
        try allow(cx, value, "when", &.{ "do", "cond", "then", "else" });
        try parseExpr(cx, try require(cx, value, "cond", "when"));
        try parseStmt(cx, try require(cx, value, "then", "when"));
        if (field(value, "else")) |otherwise| try parseStmt(cx, otherwise);
    } else return cx.fail("unknown statement `{s}`", .{verb});
}

fn parsePolicy(cx: Cx, object: Value, id: []const u8) anyerror![]const u8 {
    const policy = field(object, "policy") orelse return "keep-latest";
    if (policy != .string) return cx.fail("source `{s}` policy must be a string", .{id});
    const value = policy.string;
    if (!(std.mem.eql(u8, value, "keep-latest") or std.mem.eql(u8, value, "sum") or std.mem.eql(u8, value, "max") or std.mem.eql(u8, value, "min") or std.mem.eql(u8, value, "and") or std.mem.eql(u8, value, "or")))
        return cx.fail("unknown source policy `{s}`", .{value});
    return value;
}

fn parseNode(cx: Cx, value: Value) anyerror!void {
    try expectObject(cx, value, "node");
    const kind = try asString(cx, try require(cx, value, "kind", "node"), "node `kind`");
    const id = try parseId(cx, try asString(cx, try require(cx, value, "id", "node"), "node `id`"), "node id");
    if (std.mem.eql(u8, kind, "source")) {
        try allow(cx, value, "source", &.{ "id", "kind", "init", "policy" });
        const init = try require(cx, value, "init", "source");
        try checkPolicy(cx, try parsePolicy(cx, value, id), init);
    } else if (std.mem.eql(u8, kind, "computed")) {
        try allow(cx, value, "computed", &.{ "id", "kind", "expr", "eager" });
        if (field(value, "eager")) |eager| if (eager != .bool) return cx.fail("computed `{s}` eager must be a boolean", .{id});
        try parseExpr(cx, try require(cx, value, "expr", "computed"));
    } else if (std.mem.eql(u8, kind, "effect")) {
        try allow(cx, value, "effect", &.{ "id", "kind", "body" });
        try parseStmt(cx, try require(cx, value, "body", "effect"));
    } else return cx.fail("unknown node kind `{s}`", .{kind});
}

fn collectExpr(expr: Value, reads: *std.StringHashMap(void)) !void {
    if (field(expr, "ref")) |ref| if (ref == .string) try reads.put(ref.string, {});
    if (field(expr, "args")) |args| if (args == .array) for (args.array.items) |arg| try collectExpr(arg, reads);
    if (field(expr, "object")) |object| if (object == .array) for (object.array.items) |item| if (field(item, "value")) |child| try collectExpr(child, reads);
}

fn collectStmt(stmt: Value, reads: *std.StringHashMap(void), writes: *std.StringHashMap(void)) !void {
    const verb = field(stmt, "do").?.string;
    if (std.mem.eql(u8, verb, "eval")) try collectExpr(field(stmt, "expr").?, reads) else if (std.mem.eql(u8, verb, "set") or std.mem.eql(u8, verb, "merge")) {
        try writes.put(field(stmt, "target").?.string, {});
        try collectExpr(field(stmt, "expr").?, reads);
    } else if (std.mem.eql(u8, verb, "seq")) {
        for (field(stmt, "steps").?.array.items) |step| try collectStmt(step, reads, writes);
    } else if (std.mem.eql(u8, verb, "when")) {
        try collectExpr(field(stmt, "cond").?, reads);
        try collectStmt(field(stmt, "then").?, reads, writes);
        if (field(stmt, "else")) |otherwise| try collectStmt(otherwise, reads, writes);
    }
}

fn sortedKeys(a: Allocator, map: *std.StringHashMap(void)) ![][]const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    errdefer keys.deinit(a);
    var it = map.iterator();
    while (it.next()) |entry| try keys.append(a, entry.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, struct {
        fn less(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }
    }.less);
    return keys.toOwnedSlice(a);
}

fn edgeSets(a: Allocator, node: Value) !struct { reads: [][]const u8, writes: [][]const u8 } {
    var reads = std.StringHashMap(void).init(a);
    defer reads.deinit();
    var writes = std.StringHashMap(void).init(a);
    defer writes.deinit();
    const kind = field(node, "kind").?.string;
    if (std.mem.eql(u8, kind, "computed")) try collectExpr(field(node, "expr").?, &reads);
    if (std.mem.eql(u8, kind, "effect")) try collectStmt(field(node, "body").?, &reads, &writes);
    return .{ .reads = try sortedKeys(a, &reads), .writes = try sortedKeys(a, &writes) };
}

fn emitExpr(buf: *std.ArrayList(u8), a: Allocator, expr: Value) anyerror!void {
    if (field(expr, "lit")) |lit| {
        try appendSlice(buf, a, "lit(");
        try writeCanon(buf, a, lit);
        try buf.append(a, ')');
        return;
    }
    if (field(expr, "ref")) |ref| {
        try buf.print(a, "ref({s})", .{ref.string});
        return;
    }
    if (field(expr, "object")) |object| {
        try appendSlice(buf, a, "object(");
        for (object.array.items, 0..) |item, i| {
            if (i != 0) try appendSlice(buf, a, ", ");
            try writeCanon(buf, a, field(item, "key").?);
            try appendSlice(buf, a, ": ");
            try emitExpr(buf, a, field(item, "value").?);
        }
        try buf.append(a, ')');
        return;
    }
    try buf.print(a, "{s}(", .{field(expr, "op").?.string});
    for (field(expr, "args").?.array.items, 0..) |arg, i| {
        if (i != 0) try appendSlice(buf, a, ", ");
        try emitExpr(buf, a, arg);
    }
    try buf.append(a, ')');
}

fn emitStmt(buf: *std.ArrayList(u8), a: Allocator, stmt: Value) anyerror!void {
    const verb = field(stmt, "do").?.string;
    if (std.mem.eql(u8, verb, "eval")) {
        try appendSlice(buf, a, "eval(");
        try emitExpr(buf, a, field(stmt, "expr").?);
        try buf.append(a, ')');
    } else if (std.mem.eql(u8, verb, "set") or std.mem.eql(u8, verb, "merge")) {
        try buf.print(a, "{s}({s}, ", .{ verb, field(stmt, "target").?.string });
        try emitExpr(buf, a, field(stmt, "expr").?);
        try buf.append(a, ')');
    } else if (std.mem.eql(u8, verb, "seq")) {
        try appendSlice(buf, a, "seq(");
        for (field(stmt, "steps").?.array.items, 0..) |step, i| {
            if (i != 0) try appendSlice(buf, a, ", ");
            try emitStmt(buf, a, step);
        }
        try buf.append(a, ')');
    } else {
        try appendSlice(buf, a, "when(");
        try emitExpr(buf, a, field(stmt, "cond").?);
        try appendSlice(buf, a, ", ");
        try emitStmt(buf, a, field(stmt, "then").?);
        if (field(stmt, "else")) |otherwise| {
            try appendSlice(buf, a, ", ");
            try emitStmt(buf, a, otherwise);
        }
        try buf.append(a, ')');
    }
}

fn emitNode(buf: *std.ArrayList(u8), a: Allocator, node: Value) anyerror!void {
    const kind = field(node, "kind").?.string;
    const id = field(node, "id").?.string;
    if (std.mem.eql(u8, kind, "source")) {
        try buf.print(a, "source {s} = ", .{id});
        try writeCanon(buf, a, field(node, "init").?);
        if (field(node, "policy")) |policy| if (!std.mem.eql(u8, policy.string, "keep-latest")) try buf.print(a, " policy {s}", .{policy.string});
    } else if (std.mem.eql(u8, kind, "computed")) {
        try buf.print(a, "computed {s}", .{id});
        if (field(node, "eager")) |eager| if (eager.bool) try appendSlice(buf, a, " eager");
        try appendSlice(buf, a, " = ");
        try emitExpr(buf, a, field(node, "expr").?);
    } else {
        try buf.print(a, "effect {s} = ", .{id});
        try emitStmt(buf, a, field(node, "body").?);
    }
}

fn runeCount(text: []const u8) !usize {
    return std.unicode.utf8CountCodepoints(text);
}

pub const GraphIr = struct {
    parent: Allocator,
    arena: *std.heap.ArenaAllocator,
    id: ?[]const u8 = null,
    nodes: std.ArrayList(Value) = .empty,
    index: std.StringHashMap(usize),
    fault: []u8 = &.{},

    fn cx(self: *GraphIr) Cx {
        return .{ .parent = self.parent, .arena = aaOf(self.arena), .fault = &self.fault };
    }

    pub fn init(parent: Allocator) !GraphIr {
        const arena = try parent.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(parent);
        return .{ .parent = parent, .arena = arena, .index = std.StringHashMap(usize).init(parent) };
    }

    pub fn deinit(self: *GraphIr) void {
        self.index.deinit();
        if (self.fault.len != 0) self.parent.free(self.fault);
        self.arena.deinit();
        self.parent.destroy(self.arena);
    }

    pub fn fromJsonStr(parent: Allocator, text: []const u8) !GraphIr {
        var ir = try GraphIr.init(parent);
        ir.load(text) catch |err| switch (err) {
            error.GraphFault => return ir,
            else => {
                ir.deinit();
                return err;
            },
        };
        return ir;
    }

    fn load(self: *GraphIr, text: []const u8) anyerror!void {
        const root = std.json.parseFromSliceLeaky(Value, aaOf(self.arena), text, .{ .allocate = .alloc_always }) catch |err| {
            return self.cx().fail("graph document is not JSON: {s}", .{@errorName(err)});
        };
        try self.ingest(root);
    }

    fn ingest(self: *GraphIr, value: Value) anyerror!void {
        const context = self.cx();
        try expectObject(context, value, "graph document");
        try allow(context, value, "graph document", &.{ "kind", "ir", "id", "nodes" });
        const kind = try asString(context, try require(context, value, "kind", "graph document"), "graph document `kind`");
        if (!std.mem.eql(u8, kind, "graph")) return context.fail("graph document kind must be \"graph\", got `{s}`", .{kind});
        const version = try asString(context, try require(context, value, "ir", "graph document"), "graph document `ir`");
        if (!std.mem.eql(u8, version, "1")) return context.fail("unsupported graph IR version `{s}`", .{version});
        if (field(value, "id")) |id| self.id = try parseId(context, try asString(context, id, "graph id"), "graph id");
        const nodes = try require(context, value, "nodes", "graph document");
        if (nodes != .array) return context.fail("graph nodes must be an array", .{});
        var seen = std.StringHashMap(void).init(self.parent);
        defer seen.deinit();
        for (nodes.array.items) |item| {
            try parseNode(context, item);
            const id = field(item, "id").?.string;
            if (seen.get(id) != null) return context.fail("duplicate node id `{s}`", .{id});
            try seen.put(id, {});
            try self.nodes.append(aaOf(self.arena), item);
        }
        try self.reindex();
        try self.check();
    }

    pub fn node(self: *const GraphIr, id: []const u8) ?Value {
        const slot = self.index.get(id) orelse return null;
        return self.nodes.items[slot];
    }

    pub fn nodeEager(self: *const GraphIr, id: []const u8) bool {
        const found = self.node(id) orelse return false;
        if (!std.mem.eql(u8, field(found, "kind").?.string, "computed")) return false;
        const eager = field(found, "eager") orelse return false;
        return eager == .bool and eager.bool;
    }

    pub fn nodeExprOp(self: *const GraphIr, id: []const u8) []const u8 {
        const found = self.node(id) orelse return "";
        const expr = field(found, "expr") orelse return "";
        const op = field(expr, "op") orelse return "";
        return if (op == .string) op.string else "";
    }

    pub fn staticEdges(self: *const GraphIr) ![]Edge {
        var edges: std.ArrayList(Edge) = .empty;
        errdefer edges.deinit(self.parent);
        for (self.nodes.items) |item| {
            const sets = try edgeSets(self.parent, item);
            defer self.parent.free(sets.reads);
            defer self.parent.free(sets.writes);
            for (sets.reads) |to| try edges.append(self.parent, .{ .from = field(item, "id").?.string, .kind = "read", .to = to });
            for (sets.writes) |to| try edges.append(self.parent, .{ .from = field(item, "id").?.string, .kind = "write", .to = to });
        }
        std.mem.sort(Edge, edges.items, {}, struct {
            fn less(_: void, lhs: Edge, rhs: Edge) bool {
                const from = std.mem.order(u8, lhs.from, rhs.from);
                if (from != .eq) return from == .lt;
                const kind = std.mem.order(u8, lhs.kind, rhs.kind);
                if (kind != .eq) return kind == .lt;
                return std.mem.order(u8, lhs.to, rhs.to) == .lt;
            }
        }.less);
        return edges.toOwnedSlice(self.parent);
    }

    pub fn emitSource(self: *const GraphIr) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.parent);
        if (self.id) |id| try buf.print(self.parent, "graph {s} ir 1\n", .{id}) else try appendSlice(&buf, self.parent, "graph ir 1\n");
        for (self.nodes.items) |item| {
            try emitNode(&buf, self.parent, item);
            try buf.append(self.parent, '\n');
        }
        return buf.toOwnedSlice(self.parent);
    }

    pub fn toJsonText(self: *const GraphIr) ![]u8 {
        var object = Value{ .object = .empty };
        try object.object.put(aaOf(self.arena), "kind", .{ .string = "graph" });
        try object.object.put(aaOf(self.arena), "ir", .{ .string = "1" });
        if (self.id) |id| try object.object.put(aaOf(self.arena), "id", .{ .string = id });
        var list = std.json.Array.init(aaOf(self.arena));
        for (self.nodes.items) |item| try list.append(item);
        try object.object.put(aaOf(self.arena), "nodes", .{ .array = list });
        return canonical(self.parent, object);
    }

    fn reindex(self: *GraphIr) !void {
        self.index.clearRetainingCapacity();
        for (self.nodes.items, 0..) |item, slot| {
            const id = field(item, "id").?.string;
            if (self.index.get(id) != null) return self.cx().fail("duplicate node id `{s}`", .{id});
            try self.index.put(id, slot);
        }
    }

    fn check(self: *GraphIr) anyerror!void {
        const context = self.cx();
        for (self.nodes.items) |item| {
            const sets = try edgeSets(self.parent, item);
            defer self.parent.free(sets.reads);
            defer self.parent.free(sets.writes);
            const id = field(item, "id").?.string;
            for (sets.reads) |to| {
                const target = self.node(to) orelse return context.fail("node `{s}` reads unknown node `{s}`", .{ id, to });
                if (std.mem.eql(u8, field(target, "kind").?.string, "effect")) return context.fail("node `{s}` reads effect `{s}`, which has no value", .{ id, to });
            }
            for (sets.writes) |to| {
                const target = self.node(to) orelse return context.fail("node `{s}` writes unknown node `{s}`", .{ id, to });
                if (!std.mem.eql(u8, field(target, "kind").?.string, "source")) return context.fail("node `{s}` writes non-source `{s}`", .{ id, to });
            }
        }
        var color = std.StringHashMap(u2).init(self.parent);
        defer color.deinit();
        var stack: std.ArrayList([]const u8) = .empty;
        defer stack.deinit(self.parent);
        const visit = struct {
            fn go(doc: *GraphIr, colors: *std.StringHashMap(u2), path: *std.ArrayList([]const u8), id: []const u8) anyerror!void {
                if (colors.get(id)) |state| {
                    if (state == 1) {
                        var text: std.ArrayList(u8) = .empty;
                        defer text.deinit(doc.parent);
                        var started = false;
                        for (path.items) |item| {
                            if (!started and !std.mem.eql(u8, item, id)) continue;
                            started = true;
                            if (text.items.len != 0) try appendSlice(&text, doc.parent, " -> ");
                            try appendSlice(&text, doc.parent, item);
                        }
                        if (text.items.len != 0) try appendSlice(&text, doc.parent, " -> ");
                        try appendSlice(&text, doc.parent, id);
                        return doc.cx().fail("cycle in read edges: {s}", .{text.items});
                    }
                    if (state == 2) return;
                }
                try colors.put(id, 1);
                try path.append(doc.parent, id);
                if (doc.node(id)) |target| {
                    const sets = try edgeSets(doc.parent, target);
                    defer doc.parent.free(sets.reads);
                    defer doc.parent.free(sets.writes);
                    for (sets.reads) |dep| if (doc.node(dep) != null) try go(doc, colors, path, dep);
                }
                _ = path.pop();
                try colors.put(id, 2);
            }
        }.go;
        for (self.nodes.items) |item| try visit(self, &color, &stack, field(item, "id").?.string);
    }

    fn applyOp(self: *GraphIr, op: Value) anyerror!void {
        const name = field(op, "op").?.string;
        if (std.mem.eql(u8, name, "add") or std.mem.eql(u8, name, "replace")) {
            const item = field(op, "node").?;
            const id = field(item, "id").?.string;
            if (std.mem.eql(u8, name, "add")) {
                if (self.index.get(id) != null) return self.cx().fail("add requires a new id, `{s}` already exists", .{id});
                try self.nodes.append(aaOf(self.arena), item);
            } else {
                const slot = self.index.get(id) orelse return self.cx().fail("replace requires an existing node `{s}`", .{id});
                self.nodes.items[slot] = item;
            }
        } else {
            const id = field(op, "id").?.string;
            const slot = self.index.get(id) orelse return self.cx().fail("remove requires an existing node `{s}`", .{id});
            _ = self.nodes.orderedRemove(slot);
        }
        try self.reindex();
        try self.check();
    }
};

pub const GraphEdit = struct {
    parent: Allocator,
    arena: *std.heap.ArenaAllocator,
    ops: std.ArrayList(Value) = .empty,
    fault: []u8 = &.{},

    fn cx(self: *GraphEdit) Cx {
        return .{ .parent = self.parent, .arena = aaOf(self.arena), .fault = &self.fault };
    }

    pub fn deinit(self: *GraphEdit) void {
        if (self.fault.len != 0) self.parent.free(self.fault);
        self.arena.deinit();
        self.parent.destroy(self.arena);
    }

    pub fn fromJsonStr(parent: Allocator, text: []const u8) !GraphEdit {
        const arena = try parent.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(parent);
        var edit = GraphEdit{ .parent = parent, .arena = arena };
        edit.load(text) catch |err| switch (err) {
            error.GraphFault => return edit,
            else => {
                edit.deinit();
                return err;
            },
        };
        return edit;
    }

    fn load(self: *GraphEdit, text: []const u8) anyerror!void {
        const context = self.cx();
        const root = std.json.parseFromSliceLeaky(Value, aaOf(self.arena), text, .{ .allocate = .alloc_always }) catch |err| {
            return context.fail("graph edit is not JSON: {s}", .{@errorName(err)});
        };
        try expectObject(context, root, "graph edit");
        try allow(context, root, "graph edit", &.{ "kind", "ir", "ops" });
        const kind = try asString(context, try require(context, root, "kind", "graph edit"), "graph edit `kind`");
        if (!std.mem.eql(u8, kind, "edit")) return context.fail("graph edit kind must be \"edit\", got `{s}`", .{kind});
        const version = try asString(context, try require(context, root, "ir", "graph edit"), "graph edit `ir`");
        if (!std.mem.eql(u8, version, "1")) return context.fail("unsupported graph IR version `{s}`", .{version});
        const ops = try require(context, root, "ops", "graph edit");
        if (ops != .array) return context.fail("graph edit ops must be an array", .{});
        if (ops.array.items.len == 0) return context.fail("graph edit ops must not be empty", .{});
        for (ops.array.items) |item| {
            try expectObject(context, item, "edit op");
            const name = try asString(context, try require(context, item, "op", "edit op"), "edit op `op`");
            if (std.mem.eql(u8, name, "add") or std.mem.eql(u8, name, "replace")) {
                try allow(context, item, name, &.{ "op", "node" });
                try parseNode(context, try require(context, item, "node", name));
            } else if (std.mem.eql(u8, name, "remove")) {
                try allow(context, item, "remove", &.{ "op", "id" });
                _ = try parseId(context, try asString(context, try require(context, item, "id", "remove"), "remove `id`"), "remove id");
            } else return context.fail("unknown edit op `{s}`", .{name});
            try self.ops.append(aaOf(self.arena), item);
        }
    }
};

const SourceState = struct { value: Value, policy: []const u8 };
const ComputedState = struct { expr: Value, eager: bool, cache: Value = .null, has_value: bool = false, dirty: bool = true };
const EffectState = struct { body: Value };
const Snap = struct { kind: []const u8, source: SourceState = undefined, computed: ComputedState = undefined, effect: EffectState = undefined, deps: std.StringHashMap(void), present: bool = false };

pub const GraphRuntime = struct {
    parent: Allocator,
    arena: *std.heap.ArenaAllocator,
    doc: GraphIr,
    drain_budget: i32,
    last_drain_exhaustion: ?i32 = null,
    sources: std.StringHashMap(SourceState),
    computeds: std.StringHashMap(ComputedState),
    effects: std.StringHashMap(EffectState),
    deps: std.StringHashMap(std.StringHashMap(void)),
    subs: std.StringHashMap(std.StringHashMap(void)),
    observed: std.StringHashMap(std.StringHashMap(void)),
    trace: std.ArrayList(GraphEffectRun) = .empty,
    frames: std.ArrayList(std.StringHashMap(void)) = .empty,
    stack: std.ArrayList(?[]const u8) = .empty,
    computing: std.StringHashMap(void),
    scheduled: std.ArrayList([]const u8) = .empty,
    scheduled_set: std.StringHashMap(void),
    current: ?[]const u8 = null,
    draining: bool = false,
    fault: []u8 = &.{},

    fn cx(self: *GraphRuntime) Cx {
        return .{ .parent = self.parent, .arena = aaOf(self.arena), .fault = &self.fault };
    }

    pub fn deinit(self: *GraphRuntime) void {
        self.sources.deinit();
        self.computeds.deinit();
        self.effects.deinit();
        var deps_it = self.deps.iterator();
        while (deps_it.next()) |entry| entry.value_ptr.deinit();
        self.deps.deinit();
        var subs_it = self.subs.iterator();
        while (subs_it.next()) |entry| entry.value_ptr.deinit();
        self.subs.deinit();
        var observed_it = self.observed.iterator();
        while (observed_it.next()) |entry| entry.value_ptr.deinit();
        self.observed.deinit();
        self.trace.deinit(self.parent);
        for (self.frames.items) |*frame| frame.deinit();
        self.frames.deinit(self.parent);
        self.stack.deinit(self.parent);
        self.computing.deinit();
        self.scheduled.deinit(self.parent);
        self.scheduled_set.deinit();
        if (self.fault.len != 0) self.parent.free(self.fault);
        self.doc.deinit();
        self.arena.deinit();
        self.parent.destroy(self.arena);
    }

    pub fn loadJson(parent: Allocator, text: []const u8, budget: i32) !GraphRuntime {
        var doc = try GraphIr.fromJsonStr(parent, text);
        if (doc.fault.len != 0) {
            var rt = try GraphRuntime.init(parent, budget);
            rt.fault = doc.fault;
            doc.fault = &.{};
            doc.deinit();
            return rt;
        }
        return lowerOwned(doc, budget);
    }

    pub fn lower(doc: *const GraphIr, budget: i32) !GraphRuntime {
        var copy = try GraphIr.init(doc.parent);
        copy.id = if (doc.id) |id| try aaOf(copy.arena).dupe(u8, id) else null;
        for (doc.nodes.items) |item| try copy.nodes.append(aaOf(copy.arena), try cloneValue(aaOf(copy.arena), item));
        try copy.reindex();
        if (doc.fault.len != 0) copy.fault = try doc.parent.dupe(u8, doc.fault);
        return lowerOwned(copy, budget);
    }

    fn lowerOwned(doc: GraphIr, budget: i32) !GraphRuntime {
        var rt = try GraphRuntime.init(doc.parent, budget);
        rt.doc.deinit();
        rt.doc = doc;
        if (rt.doc.fault.len != 0) return rt;
        rt.installDocument() catch |err| switch (err) {
            error.GraphFault => return rt,
            else => {
                rt.deinit();
                return err;
            },
        };
        return rt;
    }

    fn init(parent: Allocator, budget: i32) !GraphRuntime {
        const arena = try parent.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(parent);
        return .{
            .parent = parent,
            .arena = arena,
            .doc = try GraphIr.init(parent),
            .drain_budget = if (budget > 0) budget else graph_drain_budget,
            .sources = std.StringHashMap(SourceState).init(parent),
            .computeds = std.StringHashMap(ComputedState).init(parent),
            .effects = std.StringHashMap(EffectState).init(parent),
            .deps = std.StringHashMap(std.StringHashMap(void)).init(parent),
            .subs = std.StringHashMap(std.StringHashMap(void)).init(parent),
            .observed = std.StringHashMap(std.StringHashMap(void)).init(parent),
            .computing = std.StringHashMap(void).init(parent),
            .scheduled_set = std.StringHashMap(void).init(parent),
        };
    }

    pub fn contains(self: *const GraphRuntime, id: []const u8) bool {
        return self.doc.node(id) != null;
    }
    pub fn isEager(self: *GraphRuntime, id: []const u8) !bool {
        const found = self.doc.node(id) orelse return self.cx().fail("unknown node `{s}`", .{id});
        if (!std.mem.eql(u8, field(found, "kind").?.string, "computed")) return self.cx().fail("`{s}` is not a computed", .{id});
        const eager = field(found, "eager") orelse return false;
        return eager == .bool and eager.bool;
    }
    pub fn sourcePolicy(self: *GraphRuntime, id: []const u8) ![]const u8 {
        const found = self.doc.node(id) orelse return self.cx().fail("unknown node `{s}`", .{id});
        if (!std.mem.eql(u8, field(found, "kind").?.string, "source")) return self.cx().fail("`{s}` is not a source", .{id});
        return parsePolicy(self.cx(), found, id);
    }
    pub fn staticEdges(self: *const GraphRuntime) ![]Edge {
        return self.doc.staticEdges();
    }
    pub fn emitSource(self: *const GraphRuntime) ![]u8 {
        return self.doc.emitSource();
    }
    pub fn observedReads(self: *GraphRuntime, id: []const u8) ![][]const u8 {
        const found = self.observed.getPtr(id) orelse return self.parent.alloc([]const u8, 0);
        return sortedKeys(self.parent, found);
    }
    pub fn effectTrace(self: *const GraphRuntime) []const GraphEffectRun {
        return self.trace.items;
    }

    pub fn get(self: *GraphRuntime, id: []const u8) anyerror!Value {
        if (self.effects.get(id) != null and self.sources.get(id) == null and self.computeds.get(id) == null)
            return self.cx().fail("`{s}` is an effect and has no value", .{id});
        if (self.sources.get(id)) |src| return src.value;
        if (self.computeds.get(id) == null) return self.cx().fail("unknown node `{s}`", .{id});
        const state = self.computeds.getPtr(id).?;
        if (state.dirty or !state.has_value) try self.recompute(id);
        return self.computeds.get(id).?.cache;
    }

    pub fn writeSource(self: *GraphRuntime, id: []const u8, value: Value) anyerror!void {
        _ = try self.setSource(id, value);
        try self.drain();
        try self.raiseFault();
    }

    pub fn apply(self: *GraphRuntime, edit: *const GraphEdit) anyerror!void {
        if (edit.fault.len != 0) return self.cx().fail("{s}", .{edit.fault});
        for (edit.ops.items, 0..) |op, index| {
            var next = try self.cloneDoc();
            next.applyOp(op) catch |err| {
                if (err == error.GraphFault) {
                    const wrapped = try std.fmt.allocPrint(self.parent, "edit op {d}: {s}", .{ index, next.fault });
                    next.deinit();
                    if (self.fault.len != 0) self.parent.free(self.fault);
                    self.fault = wrapped;
                    return error.GraphFault;
                }
                next.deinit();
                return err;
            };
            self.installOp(op) catch |err| {
                if (err == error.GraphFault) {
                    const wrapped = try std.fmt.allocPrint(self.parent, "edit op {d}: {s}", .{ index, self.fault });
                    next.deinit();
                    self.parent.free(self.fault);
                    self.fault = wrapped;
                    return error.GraphFault;
                }
                next.deinit();
                return err;
            };
            self.doc.deinit();
            self.doc = next;
        }
    }

    fn cloneDoc(self: *GraphRuntime) !GraphIr {
        var copy = try GraphIr.init(self.parent);
        copy.id = if (self.doc.id) |id| try aaOf(copy.arena).dupe(u8, id) else null;
        for (self.doc.nodes.items) |item| try copy.nodes.append(aaOf(copy.arena), try cloneValue(aaOf(copy.arena), item));
        try copy.reindex();
        return copy;
    }

    fn installDocument(self: *GraphRuntime) anyerror!void {
        for (self.doc.nodes.items) |item| if (std.mem.eql(u8, field(item, "kind").?.string, "source")) try self.insertSource(item);
        for (self.doc.nodes.items) |item| if (std.mem.eql(u8, field(item, "kind").?.string, "computed")) try self.insertComputed(item);
        for (self.doc.nodes.items) |item| if (std.mem.eql(u8, field(item, "kind").?.string, "computed")) if (field(item, "eager")) |eager| if (eager == .bool and eager.bool) try self.recompute(field(item, "id").?.string);
        for (self.doc.nodes.items) |item| if (std.mem.eql(u8, field(item, "kind").?.string, "effect")) try self.insertEffect(item);
        try self.raiseFault();
    }

    fn installOp(self: *GraphRuntime, op: Value) anyerror!void {
        const name = field(op, "op").?.string;
        if (std.mem.eql(u8, name, "add")) try self.addNode(field(op, "node").?) else if (std.mem.eql(u8, name, "replace")) try self.replaceNode(field(op, "node").?) else try self.removeNode(field(op, "id").?.string);
        try self.drain();
        try self.raiseFault();
    }

    fn addNode(self: *GraphRuntime, node: Value) anyerror!void {
        const kind = field(node, "kind").?.string;
        const id = field(node, "id").?.string;
        if (std.mem.eql(u8, kind, "source")) try self.insertSource(node) else if (std.mem.eql(u8, kind, "computed")) {
            try self.insertComputed(node);
            if (field(node, "eager")) |eager| if (eager == .bool and eager.bool) self.recompute(id) catch |err| {
                self.dropBinding(id);
                return err;
            };
        } else try self.insertEffect(node);
    }

    fn replaceNode(self: *GraphRuntime, node: Value) anyerror!void {
        const id = field(node, "id").?.string;
        var snap = try self.snapshot(id);
        self.dropBinding(id);
        self.addNode(node) catch |err| {
            self.dropBinding(id);
            try self.restore(id, snap);
            return err;
        };
        self.notify(id) catch |err| {
            self.dropBinding(id);
            try self.restore(id, snap);
            return err;
        };
        snap.deps.deinit();
    }

    fn removeNode(self: *GraphRuntime, id: []const u8) anyerror!void {
        if (self.sources.get(id) == null and self.computeds.get(id) == null and self.effects.get(id) == null)
            return self.cx().fail("unknown node `{s}`", .{id});
        self.dropBinding(id);
        if (self.subs.fetchRemove(id)) |entry| {
            var set = entry.value;
            set.deinit();
        }
    }

    fn insertSource(self: *GraphRuntime, node: Value) anyerror!void {
        const id = field(node, "id").?.string;
        const policy = try parsePolicy(self.cx(), node, id);
        try checkPolicy(self.cx(), policy, field(node, "init").?);
        try self.sources.put(id, .{ .value = field(node, "init").?, .policy = policy });
    }
    fn insertComputed(self: *GraphRuntime, node: Value) anyerror!void {
        const id = field(node, "id").?.string;
        const eager = if (field(node, "eager")) |bit| bit == .bool and bit.bool else false;
        try self.computeds.put(id, .{ .expr = field(node, "expr").?, .eager = eager });
        try self.deps.put(id, std.StringHashMap(void).init(self.parent));
    }
    fn insertEffect(self: *GraphRuntime, node: Value) anyerror!void {
        const id = field(node, "id").?.string;
        try self.effects.put(id, .{ .body = field(node, "body").? });
        try self.deps.put(id, std.StringHashMap(void).init(self.parent));
        self.runEffect(id) catch |err| {
            self.dropBinding(id);
            return err;
        };
    }

    fn snapshot(self: *GraphRuntime, id: []const u8) !Snap {
        if (self.sources.get(id)) |src| return .{ .kind = "source", .source = src, .deps = std.StringHashMap(void).init(self.parent), .present = true };
        if (self.computeds.get(id)) |comp| {
            var deps = std.StringHashMap(void).init(self.parent);
            if (self.deps.get(id)) |set| {
                var it = set.iterator();
                while (it.next()) |entry| try deps.put(entry.key_ptr.*, {});
            }
            return .{ .kind = "computed", .computed = comp, .deps = deps, .present = true };
        }
        if (self.effects.get(id)) |effect| {
            var deps = std.StringHashMap(void).init(self.parent);
            if (self.deps.get(id)) |set| {
                var it = set.iterator();
                while (it.next()) |entry| try deps.put(entry.key_ptr.*, {});
            }
            return .{ .kind = "effect", .effect = effect, .deps = deps, .present = true };
        }
        return .{ .kind = "", .deps = std.StringHashMap(void).init(self.parent) };
    }

    fn restore(self: *GraphRuntime, id: []const u8, snap: Snap) !void {
        if (!snap.present) {
            var doomed = snap.deps;
            doomed.deinit();
            return;
        }
        if (std.mem.eql(u8, snap.kind, "source")) try self.sources.put(id, snap.source) else if (std.mem.eql(u8, snap.kind, "computed")) {
            try self.computeds.put(id, snap.computed);
            try self.deps.put(id, std.StringHashMap(void).init(self.parent));
            var it = snap.deps.iterator();
            while (it.next()) |entry| {
                try self.subAdd(entry.key_ptr.*, id);
                try self.deps.getPtr(id).?.put(entry.key_ptr.*, {});
            }
        } else if (std.mem.eql(u8, snap.kind, "effect")) {
            try self.effects.put(id, snap.effect);
            try self.deps.put(id, std.StringHashMap(void).init(self.parent));
            var it = snap.deps.iterator();
            while (it.next()) |entry| {
                try self.subAdd(entry.key_ptr.*, id);
                try self.deps.getPtr(id).?.put(entry.key_ptr.*, {});
            }
        }
        var doomed = snap.deps;
        doomed.deinit();
    }

    fn dropBinding(self: *GraphRuntime, id: []const u8) void {
        _ = self.sources.remove(id);
        _ = self.computeds.remove(id);
        _ = self.effects.remove(id);
        if (self.deps.fetchRemove(id)) |entry| {
            var set = entry.value;
            var it = set.iterator();
            while (it.next()) |dep| {
                if (self.subs.getPtr(dep.key_ptr.*)) |readers| _ = readers.remove(id);
            }
            set.deinit();
        }
        if (self.observed.fetchRemove(id)) |entry| {
            var set = entry.value;
            set.deinit();
        }
        _ = self.scheduled_set.remove(id);
    }

    fn setSource(self: *GraphRuntime, id: []const u8, value: Value) anyerror!Value {
        const src = self.sources.getPtr(id) orelse {
            if (self.computeds.get(id) != null or self.effects.get(id) != null) return self.cx().fail("`{s}` is not a source", .{id});
            return self.cx().fail("unknown node `{s}`", .{id});
        };
        const changed = !jsonEq(src.value, value);
        src.value = value;
        if (changed) try self.notify(id);
        return src.value;
    }

    fn mergeSource(self: *GraphRuntime, id: []const u8, value: Value) anyerror!Value {
        const src = self.sources.get(id) orelse {
            if (self.computeds.get(id) != null or self.effects.get(id) != null) return self.cx().fail("`{s}` is not a source", .{id});
            return self.cx().fail("unknown node `{s}`", .{id});
        };
        return self.setSource(id, try foldPolicy(self.cx(), src.policy, src.value, value));
    }

    fn notify(self: *GraphRuntime, id: []const u8) anyerror!void {
        const readers = self.subs.getPtr(id) orelse return;
        const names = try sortedKeys(self.parent, readers);
        defer self.parent.free(names);
        for (names) |dep| {
            if (self.computeds.getPtr(dep)) |comp| {
                const down = self.subs.getPtr(dep);
                if (comp.eager or (down != null and down.?.count() > 0)) {
                    if (self.computing.get(dep) != null) {
                        comp.dirty = true;
                        continue;
                    }
                    try self.recompute(dep);
                } else comp.dirty = true;
            } else if (self.effects.get(dep) != null) try self.schedule(dep);
        }
    }

    fn schedule(self: *GraphRuntime, id: []const u8) !void {
        if (self.effects.get(id) != null and self.scheduled_set.get(id) == null) {
            try self.scheduled_set.put(id, {});
            try self.scheduled.append(self.parent, id);
        }
    }

    fn drain(self: *GraphRuntime) anyerror!void {
        if (self.draining) return;
        self.draining = true;
        defer self.draining = false;
        var iterations: i32 = 0;
        while (self.scheduled.items.len > 0) {
            const id = self.scheduled.orderedRemove(0);
            _ = self.scheduled_set.remove(id);
            iterations += 1;
            if (iterations >= self.drain_budget) {
                self.last_drain_exhaustion = iterations;
                return;
            }
            if (self.effects.get(id) == null) continue;
            self.runEffect(id) catch |err| {
                if (err == error.GraphFault) return;
                return err;
            };
        }
    }

    fn raiseFault(self: *GraphRuntime) anyerror!void {
        if (self.fault.len != 0) return error.GraphFault;
    }

    fn runEffect(self: *GraphRuntime, id: []const u8) anyerror!void {
        const body = self.effects.get(id).?.body;
        try self.begin(id);
        const result = self.evalStmt(body) catch |err| {
            self.end(id);
            return err;
        };
        self.end(id);
        try self.trace.append(self.parent, .{ .id = id, .result = result });
        try self.drain();
    }

    fn recompute(self: *GraphRuntime, id: []const u8) anyerror!void {
        if (self.computing.get(id) != null) return self.cx().fail("cycle in read edges: {s}", .{id});
        try self.computing.put(id, {});
        defer _ = self.computing.remove(id);
        const expr = self.computeds.get(id).?.expr;
        try self.begin(id);
        const value = self.evalExpr(expr) catch |err| {
            self.end(id);
            if (self.computeds.getPtr(id)) |state| {
                state.dirty = true;
                state.has_value = false;
                state.cache = .null;
            }
            return err;
        };
        self.end(id);
        const state = self.computeds.getPtr(id).?;
        const changed = !state.has_value or !jsonEq(state.cache, value);
        state.cache = value;
        state.has_value = true;
        state.dirty = false;
        if (changed) try self.notify(id);
    }

    fn begin(self: *GraphRuntime, id: []const u8) !void {
        if (self.deps.getPtr(id)) |previous| {
            var it = previous.iterator();
            while (it.next()) |dep| {
                if (self.subs.getPtr(dep.key_ptr.*)) |readers| _ = readers.remove(id);
            }
            previous.clearRetainingCapacity();
        } else try self.deps.put(id, std.StringHashMap(void).init(self.parent));
        try self.frames.append(self.parent, std.StringHashMap(void).init(self.parent));
        try self.stack.append(self.parent, self.current);
        self.current = id;
    }

    fn end(self: *GraphRuntime, id: []const u8) void {
        const frame = self.frames.pop() orelse return;
        if (self.observed.fetchRemove(id)) |old| {
            var set = old.value;
            set.deinit();
        }
        self.observed.put(id, frame) catch {};
        self.current = self.stack.pop().?;
    }

    fn note(self: *GraphRuntime, id: []const u8) !void {
        if (self.frames.items.len == 0 or self.current == null) return self.cx().fail("read outside a node evaluation", .{});
        try self.frames.items[self.frames.items.len - 1].put(id, {});
        try self.subAdd(id, self.current.?);
        try self.deps.getPtr(self.current.?).?.put(id, {});
    }

    fn subAdd(self: *GraphRuntime, src: []const u8, reader: []const u8) !void {
        if (self.subs.getPtr(src) == null) try self.subs.put(src, std.StringHashMap(void).init(self.parent));
        try self.subs.getPtr(src).?.put(reader, {});
    }

    fn readRef(self: *GraphRuntime, id: []const u8) anyerror!Value {
        try self.note(id);
        if (self.sources.get(id)) |src| return src.value;
        if (self.computeds.getPtr(id)) |comp| {
            if (comp.dirty or !comp.has_value) {
                try self.recompute(id);
                return self.computeds.get(id).?.cache;
            }
            return comp.cache;
        }
        if (self.effects.get(id) != null) return self.cx().fail("`{s}` is an effect and has no value", .{id});
        return self.cx().fail("unknown node `{s}`", .{id});
    }

    fn evalExpr(self: *GraphRuntime, expr: Value) anyerror!Value {
        if (field(expr, "lit")) |lit| return lit;
        if (field(expr, "ref")) |ref| return self.readRef(ref.string);
        if (field(expr, "object")) |object| {
            var result = Value{ .object = .empty };
            var seen = std.StringHashMap(void).init(self.parent);
            defer seen.deinit();
            for (object.array.items) |item| {
                const key = field(item, "key").?.string;
                if (seen.get(key) != null) return self.cx().fail("duplicate object key `{s}`", .{key});
                try seen.put(key, {});
                try result.object.put(aaOf(self.arena), key, try self.evalExpr(field(item, "value").?));
            }
            return result;
        }
        const op = field(expr, "op").?.string;
        const args = field(expr, "args").?.array.items;
        if (std.mem.eql(u8, op, "and")) {
            if (!try expectBool(self.cx(), try self.evalExpr(args[0]))) return .{ .bool = false };
            return .{ .bool = try expectBool(self.cx(), try self.evalExpr(args[1])) };
        }
        if (std.mem.eql(u8, op, "or")) {
            if (try expectBool(self.cx(), try self.evalExpr(args[0]))) return .{ .bool = true };
            return .{ .bool = try expectBool(self.cx(), try self.evalExpr(args[1])) };
        }
        if (std.mem.eql(u8, op, "if")) return self.evalExpr(if (try expectBool(self.cx(), try self.evalExpr(args[0]))) args[1] else args[2]);
        if (std.mem.eql(u8, op, "array")) {
            var list = std.json.Array.init(aaOf(self.arena));
            for (args) |arg| try list.append(try self.evalExpr(arg));
            return .{ .array = list };
        }
        var values: std.ArrayList(Value) = .empty;
        defer values.deinit(self.parent);
        for (args) |arg| try values.append(self.parent, try self.evalExpr(arg));
        return self.evalValues(op, values.items);
    }

    fn evalValues(self: *GraphRuntime, op: []const u8, values: []const Value) anyerror!Value {
        const context = self.cx();
        if (std.mem.eql(u8, op, "neg")) {
            const num = try asNum(context, values[0]);
            if (num.integer) {
                if (num.as_int == std.math.minInt(i64)) return context.fail("integer overflow", .{});
                return .{ .integer = -num.as_int };
            }
            return canonicalF64(context, -num.as_real);
        }
        if (std.mem.eql(u8, op, "not")) return .{ .bool = !try expectBool(context, values[0]) };
        if (std.mem.eql(u8, op, "len")) return .{ .integer = @intCast(try lenValue(context, values[0])) };
        if (std.mem.eql(u8, op, "add") or std.mem.eql(u8, op, "sub") or std.mem.eql(u8, op, "mul") or std.mem.eql(u8, op, "div"))
            return numBin(context, op, values[0], values[1]);
        if (std.mem.eql(u8, op, "mod")) {
            const a = try asNum(context, values[0]);
            const b = try asNum(context, values[1]);
            if (!a.integer or !b.integer) return context.fail("mod requires integers", .{});
            if (b.as_int == 0) return context.fail("division by zero", .{});
            return .{ .integer = @rem(a.as_int, b.as_int) };
        }
        if (std.mem.eql(u8, op, "min") or std.mem.eql(u8, op, "max")) {
            const order = try ordering(context, values[0], values[1]);
            if (std.mem.eql(u8, op, "max")) return if (order >= 0) values[0] else values[1];
            return if (order <= 0) values[0] else values[1];
        }
        if (std.mem.eql(u8, op, "eq") or std.mem.eql(u8, op, "ne")) {
            const equal = jsonEq(values[0], values[1]);
            return .{ .bool = if (std.mem.eql(u8, op, "ne")) !equal else equal };
        }
        if (std.mem.eql(u8, op, "lt") or std.mem.eql(u8, op, "le") or std.mem.eql(u8, op, "gt") or std.mem.eql(u8, op, "ge")) {
            const order = try ordering(context, values[0], values[1]);
            const bit = if (std.mem.eql(u8, op, "lt")) order < 0 else if (std.mem.eql(u8, op, "le")) order <= 0 else if (std.mem.eql(u8, op, "gt")) order > 0 else order >= 0;
            return .{ .bool = bit };
        }
        if (std.mem.eql(u8, op, "concat")) {
            if (values[0] != .string or values[1] != .string) return context.fail("concat requires strings, got {s} and {s}", .{ try canonical(self.parent, values[0]), try canonical(self.parent, values[1]) });
            const text = try std.fmt.allocPrint(aaOf(self.arena), "{s}{s}", .{ values[0].string, values[1].string });
            return .{ .string = text };
        }
        if (std.mem.eql(u8, op, "get")) return evalGet(context, values[0], values[1]);
        return context.fail("op `{s}` is not an eager operator", .{op});
    }

    fn lenValue(context: Cx, value: Value) anyerror!usize {
        return switch (value) {
            .string => |text| try runeCount(text),
            .array => |list| list.items.len,
            .object => |obj| obj.count(),
            else => context.fail("len requires a string, array, or object, got {s}", .{try canonical(context.arena, value)}),
        };
    }

    fn evalGet(context: Cx, target: Value, key: Value) anyerror!Value {
        if (target == .array) {
            const index = try asNum(context, key);
            if (!index.integer) return context.fail("array index must be an integer", .{});
            if (index.as_int < 0) return context.fail("array index must be >= 0", .{});
            if (@as(u64, @intCast(index.as_int)) >= target.array.items.len) return context.fail("index {d} out of range", .{index.as_int});
            return target.array.items[@intCast(index.as_int)];
        }
        if (target == .object) {
            if (key != .string) return context.fail("object key must be a string, got {s}", .{try canonical(context.arena, key)});
            return target.object.get(key.string) orelse context.fail("missing key `{s}`", .{key.string});
        }
        return context.fail("get requires an array or object, got {s}", .{try canonical(context.arena, target)});
    }

    fn foldPolicy(context: Cx, policy: []const u8, old: Value, op: Value) anyerror!Value {
        if (std.mem.eql(u8, policy, "keep-latest")) return op;
        if (std.mem.eql(u8, policy, "sum")) return numBin(context, "add", old, op);
        if (std.mem.eql(u8, policy, "max")) return if (try ordering(context, old, op) >= 0) old else op;
        if (std.mem.eql(u8, policy, "min")) return if (try ordering(context, old, op) <= 0) old else op;
        if (std.mem.eql(u8, policy, "and")) return .{ .bool = try expectBool(context, old) and try expectBool(context, op) };
        if (std.mem.eql(u8, policy, "or")) return .{ .bool = try expectBool(context, old) or try expectBool(context, op) };
        return context.fail("unknown source policy `{s}`", .{policy});
    }

    fn evalStmt(self: *GraphRuntime, stmt: Value) anyerror!Value {
        const verb = field(stmt, "do").?.string;
        if (std.mem.eql(u8, verb, "eval")) return self.evalExpr(field(stmt, "expr").?);
        if (std.mem.eql(u8, verb, "set")) return self.setSource(field(stmt, "target").?.string, try self.evalExpr(field(stmt, "expr").?));
        if (std.mem.eql(u8, verb, "merge")) return self.mergeSource(field(stmt, "target").?.string, try self.evalExpr(field(stmt, "expr").?));
        if (std.mem.eql(u8, verb, "seq")) {
            var list = std.json.Array.init(aaOf(self.arena));
            for (field(stmt, "steps").?.array.items) |step| try list.append(try self.evalStmt(step));
            return .{ .array = list };
        }
        if (std.mem.eql(u8, verb, "when")) {
            if (!try expectBool(self.cx(), try self.evalExpr(field(stmt, "cond").?))) {
                if (field(stmt, "else")) |otherwise| return self.evalStmt(otherwise);
                return .null;
            }
            return self.evalStmt(field(stmt, "then").?);
        }
        return self.cx().fail("unknown statement `{s}`", .{verb});
    }
};

fn cloneValue(a: Allocator, value: Value) !Value {
    return switch (value) {
        .null => .null,
        .bool => |bit| .{ .bool = bit },
        .integer => |int| .{ .integer = int },
        .float => |real| .{ .float = real },
        .number_string => |text| .{ .number_string = try a.dupe(u8, text) },
        .string => |text| .{ .string = try a.dupe(u8, text) },
        .array => |list| blk: {
            var copy = std.json.Array.init(a);
            for (list.items) |item| try copy.append(try cloneValue(a, item));
            break :blk .{ .array = copy };
        },
        .object => |obj| blk: {
            var copy = Value{ .object = .empty };
            var it = obj.iterator();
            while (it.next()) |entry| try copy.object.put(a, try a.dupe(u8, entry.key_ptr.*), try cloneValue(a, entry.value_ptr.*));
            break :blk copy;
        },
    };
}

const testing = std.testing;

fn expectFault(fault: []const u8, fragment: []const u8) !void {
    try testing.expect(std.mem.indexOf(u8, fault, fragment) != null);
}

test "counter lowers then an edit replaces the graph" {
    const a = testing.allocator;
    var doc = try GraphIr.fromJsonStr(a, counter);
    defer doc.deinit();
    try testing.expectEqualStrings("", doc.fault);
    try testing.expectEqualStrings("counter", doc.id.?);
    try testing.expect(doc.nodeEager("doubled"));
    try testing.expectEqualStrings("mul", doc.nodeExprOp("doubled"));
    const edges = try doc.staticEdges();
    defer a.free(edges);
    try testing.expectEqual(@as(usize, 2), edges.len);
    try testing.expectEqualStrings("doubled", edges[0].from);
    try testing.expectEqualStrings("count", edges[0].to);
    try testing.expectEqualStrings("log", edges[1].from);
    const source = try doc.emitSource();
    defer a.free(source);
    try testing.expectEqualStrings(counter_source, source);
    const json = try doc.toJsonText();
    defer a.free(json);
    var again = try GraphIr.fromJsonStr(a, json);
    defer again.deinit();
    const again_source = try again.emitSource();
    defer a.free(again_source);
    try testing.expectEqualStrings(counter_source, again_source);

    var rt = try GraphRuntime.lower(&doc, 0);
    defer rt.deinit();
    try testing.expectEqual(@as(i64, 2), (try rt.get("doubled")).integer);
    try testing.expectEqual(@as(usize, 1), rt.effectTrace().len);
    try testing.expectEqualStrings("log", rt.effectTrace()[0].id);
    try testing.expectEqual(@as(i64, 2), rt.effectTrace()[0].result.integer);
    const doubled_reads = try rt.observedReads("doubled");
    defer a.free(doubled_reads);
    try testing.expectEqual(@as(usize, 1), doubled_reads.len);
    try testing.expectEqualStrings("count", doubled_reads[0]);
    try testing.expect(try rt.isEager("doubled"));
    try testing.expectEqualStrings("keep-latest", try rt.sourcePolicy("count"));
    const before = try rt.emitSource();
    defer a.free(before);
    try rt.writeSource("count", .{ .integer = 4 });
    try testing.expectEqual(@as(i64, 8), (try rt.get("doubled")).integer);
    try testing.expectEqual(@as(usize, 2), rt.effectTrace().len);
    try testing.expectEqual(@as(i64, 8), rt.effectTrace()[1].result.integer);
    const after = try rt.emitSource();
    defer a.free(after);
    try testing.expectEqualStrings(before, after);
    var edit = try GraphEdit.fromJsonStr(a, counter_edit);
    defer edit.deinit();
    try rt.apply(&edit);
    try testing.expectEqual(@as(i64, 14), (try rt.get("doubled")).integer);
    try testing.expectEqualStrings("n:", (try rt.get("shown")).string);
    try testing.expect(!rt.contains("log"));
    try testing.expect(!try rt.isEager("doubled"));
    const trace_len = rt.effectTrace().len;
    try rt.writeSource("count", .{ .integer = 5 });
    try testing.expectEqual(@as(i64, 15), (try rt.get("doubled")).integer);
    try testing.expectEqual(trace_len, rt.effectTrace().len);
    const emitted = try rt.emitSource();
    defer a.free(emitted);
    try testing.expectEqualStrings(
        "graph counter ir 1\nsource count = 1\ncomputed doubled = add(ref(count), lit(10))\nsource label = \"n\"\ncomputed shown = concat(ref(label), lit(\":\"))\n",
        emitted,
    );
}

test "dynamic if observes only the taken branch" {
    const a = testing.allocator;
    var rt = try GraphRuntime.loadJson(a,
        \\{"kind":"graph","ir":"1","nodes":[
        \\{"id":"flag","kind":"source","init":false},
        \\{"id":"left","kind":"source","init":"L"},
        \\{"id":"right","kind":"source","init":"R"},
        \\{"id":"picked","kind":"computed","expr":{"op":"if","args":[{"ref":"flag"},{"ref":"left"},{"ref":"right"}]}}
        \\]}
    , 0);
    defer rt.deinit();
    const edges = try rt.staticEdges();
    defer a.free(edges);
    try testing.expectEqual(@as(usize, 3), edges.len);
    try testing.expectEqualStrings("R", (try rt.get("picked")).string);
    const right = try rt.observedReads("picked");
    defer a.free(right);
    try testing.expectEqual(@as(usize, 2), right.len);
    try testing.expectEqualStrings("flag", right[0]);
    try testing.expectEqualStrings("right", right[1]);
    try rt.writeSource("flag", .{ .bool = true });
    try testing.expectEqualStrings("L", (try rt.get("picked")).string);
    const left = try rt.observedReads("picked");
    defer a.free(left);
    try testing.expectEqualStrings("flag", left[0]);
    try testing.expectEqualStrings("left", left[1]);
}

test "sum policy folds and skips an equal write" {
    const a = testing.allocator;
    var rt = try GraphRuntime.loadJson(a,
        \\{"kind":"graph","ir":"1","nodes":[
        \\{"id":"tick","kind":"source","init":0},
        \\{"id":"total","kind":"source","init":0,"policy":"sum"},
        \\{"id":"bump","kind":"effect","body":{"do":"seq","steps":[
        \\{"do":"eval","expr":{"ref":"tick"}},
        \\{"do":"merge","target":"total","expr":{"lit":1}}
        \\]}}]}
    , 0);
    defer rt.deinit();
    const source = try rt.emitSource();
    defer a.free(source);
    try testing.expect(std.mem.indexOf(u8, source, "policy sum") != null);
    try testing.expect(std.mem.indexOf(u8, source, "merge(total, lit(1))") != null);
    try testing.expectEqual(@as(i64, 1), (try rt.get("total")).integer);
    try testing.expectEqual(@as(i64, 0), rt.effectTrace()[0].result.array.items[0].integer);
    try testing.expectEqual(@as(i64, 1), rt.effectTrace()[0].result.array.items[1].integer);
    try rt.writeSource("tick", .{ .integer = 1 });
    try testing.expectEqual(@as(i64, 2), (try rt.get("total")).integer);
    try testing.expectEqual(@as(usize, 2), rt.effectTrace().len);
    try rt.writeSource("tick", .{ .integer = 1 });
    try testing.expectEqual(@as(usize, 2), rt.effectTrace().len);
}

test "structures" {
    const a = testing.allocator;
    var rt = try GraphRuntime.loadJson(a,
        \\{"kind":"graph","ir":"1","nodes":[
        \\{"id":"row","kind":"source","init":{"name":"ada","n":2}},
        \\{"id":"name","kind":"computed","expr":{"op":"get","args":[{"ref":"row"},{"lit":"name"}]}},
        \\{"id":"n","kind":"computed","expr":{"op":"get","args":[{"ref":"row"},{"lit":"n"}]}},
        \\{"id":"tag","kind":"computed","expr":{"op":"concat","args":[{"ref":"name"},{"lit":"#"}]}},
        \\{"id":"width","kind":"computed","expr":{"op":"len","args":[{"ref":"name"}]}},
        \\{"id":"pair","kind":"computed","expr":{"op":"array","args":[{"ref":"name"},{"ref":"n"}]}},
        \\{"id":"wrapped","kind":"computed","expr":{"object":[{"key":"name","value":{"ref":"name"}}]}}
        \\]}
    , 0);
    defer rt.deinit();
    try testing.expectEqualStrings("ada", (try rt.get("name")).string);
    try testing.expectEqual(@as(i64, 2), (try rt.get("n")).integer);
    try testing.expectEqualStrings("ada#", (try rt.get("tag")).string);
    try testing.expectEqual(@as(i64, 3), (try rt.get("width")).integer);
    const pair = try rt.get("pair");
    try testing.expectEqualStrings("ada", pair.array.items[0].string);
    try testing.expectEqual(@as(i64, 2), pair.array.items[1].integer);
    const wrapped = try rt.get("wrapped");
    try testing.expectEqual(@as(usize, 1), wrapped.object.count());
    try testing.expectEqualStrings("ada", wrapped.object.get("name").?.string);
}

test "cycle and snapshot are rejected" {
    const a = testing.allocator;
    var cycle = try GraphIr.fromJsonStr(a,
        \\{"kind":"graph","ir":"1","nodes":[{"id":"a","kind":"computed","expr":{"ref":"b"}},{"id":"b","kind":"computed","expr":{"ref":"a"}}]}
    );
    defer cycle.deinit();
    try expectFault(cycle.fault, "cycle in read edges");
    var snap = try GraphIr.fromJsonStr(a,
        \\{"Snapshot":{"epoch":0,"nodes":[],"edges":[],"roots":[]}}
    );
    defer snap.deinit();
    try expectFault(snap.fault, "graph");
}

test "policies and null init" {
    const a = testing.allocator;
    var rt = try GraphRuntime.loadJson(a,
        \\{"kind":"graph","ir":"1","nodes":[
        \\{"id":"empty","kind":"source","init":null},
        \\{"id":"hi","kind":"source","init":3,"policy":"max"},
        \\{"id":"lo","kind":"source","init":3,"policy":"min"},
        \\{"id":"both","kind":"source","init":true,"policy":"and"},
        \\{"id":"either","kind":"source","init":false,"policy":"or"},
        \\{"id":"fold","kind":"effect","body":{"do":"seq","steps":[
        \\{"do":"merge","target":"hi","expr":{"lit":1}},
        \\{"do":"merge","target":"hi","expr":{"lit":5}},
        \\{"do":"merge","target":"hi","expr":{"lit":5}},
        \\{"do":"merge","target":"lo","expr":{"lit":1}},
        \\{"do":"merge","target":"both","expr":{"lit":false}},
        \\{"do":"merge","target":"either","expr":{"lit":true}}
        \\]}}]}
    , 0);
    defer rt.deinit();
    try testing.expect((try rt.get("empty")) == .null);
    try testing.expectEqual(@as(i64, 5), (try rt.get("hi")).integer);
    try testing.expectEqual(@as(i64, 1), (try rt.get("lo")).integer);
    try testing.expect(!(try rt.get("both")).bool);
    try testing.expect((try rt.get("either")).bool);
}

test "and short-circuits and div by zero faults" {
    const a = testing.allocator;
    var rt = try GraphRuntime.loadJson(a,
        \\{"kind":"graph","ir":"1","nodes":[
        \\{"id":"flag","kind":"source","init":false},
        \\{"id":"n","kind":"source","init":1},
        \\{"id":"bad","kind":"computed","expr":{"op":"div","args":[{"ref":"n"},{"lit":0}]}},
        \\{"id":"gate","kind":"computed","expr":{"op":"and","args":[{"ref":"flag"},{"ref":"bad"}]}}
        \\]}
    , 0);
    defer rt.deinit();
    try testing.expect(!(try rt.get("gate")).bool);
    const reads = try rt.observedReads("gate");
    defer a.free(reads);
    try testing.expectEqual(@as(usize, 1), reads.len);
    try testing.expectError(error.GraphFault, rt.get("bad"));
    try expectFault(rt.fault, "division by zero");
}

test "failed edits leave the previous graph" {
    const a = testing.allocator;
    var rt = try GraphRuntime.loadJson(a,
        \\{"kind":"graph","ir":"1","nodes":[{"id":"a","kind":"source","init":1},{"id":"b","kind":"computed","expr":{"ref":"a"}}]}
    , 0);
    defer rt.deinit();
    var edit = try GraphEdit.fromJsonStr(a,
        \\{"kind":"edit","ir":"1","ops":[{"op":"remove","id":"a"}]}
    );
    defer edit.deinit();
    try testing.expectError(error.GraphFault, rt.apply(&edit));
    try expectFault(rt.fault, "edit op 0");
    try testing.expect(rt.contains("a") and rt.contains("b"));
    try testing.expectEqual(@as(i64, 1), (try rt.get("b")).integer);
    var empty = try GraphRuntime.loadJson(a, "{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[]}", 0);
    defer empty.deinit();
    var forward = try GraphEdit.fromJsonStr(a,
        \\{"kind":"edit","ir":"1","ops":[{"op":"add","node":{"id":"a","kind":"computed","expr":{"ref":"b"}}},{"op":"add","node":{"id":"b","kind":"source","init":1}}]}
    );
    defer forward.deinit();
    try testing.expectError(error.GraphFault, empty.apply(&forward));
    try testing.expect(!empty.contains("a") and !empty.contains("b"));
    const source = try empty.emitSource();
    defer a.free(source);
    try testing.expectEqualStrings("graph ir 1\n", source);
}

test "replace source resets and when records null" {
    const a = testing.allocator;
    var rt = try GraphRuntime.loadJson(a,
        \\{"kind":"graph","ir":"1","id":"g","nodes":[{"id":"count","kind":"source","init":1}]}
    , 0);
    defer rt.deinit();
    try rt.writeSource("count", .{ .integer = 9 });
    try testing.expectEqual(@as(i64, 9), (try rt.get("count")).integer);
    const before = try rt.emitSource();
    defer a.free(before);
    try testing.expectEqualStrings("graph g ir 1\nsource count = 1\n", before);
    var edit = try GraphEdit.fromJsonStr(a,
        \\{"kind":"edit","ir":"1","ops":[{"op":"replace","node":{"id":"count","kind":"source","init":0}}]}
    );
    defer edit.deinit();
    try rt.apply(&edit);
    try testing.expectEqual(@as(i64, 0), (try rt.get("count")).integer);
    var on = try GraphRuntime.loadJson(a,
        \\{"kind":"graph","ir":"1","nodes":[{"id":"on","kind":"source","init":true},{"id":"value","kind":"source","init":0},{"id":"apply","kind":"effect","body":{"do":"when","cond":{"ref":"on"},"then":{"do":"set","target":"value","expr":{"lit":7}}}}]}
    , 0);
    defer on.deinit();
    try testing.expectEqual(@as(i64, 7), (try on.get("value")).integer);
    var off = try GraphRuntime.loadJson(a,
        \\{"kind":"graph","ir":"1","nodes":[{"id":"on","kind":"source","init":false},{"id":"value","kind":"source","init":0},{"id":"apply","kind":"effect","body":{"do":"when","cond":{"ref":"on"},"then":{"do":"set","target":"value","expr":{"lit":7}}}}]}
    , 0);
    defer off.deinit();
    try testing.expectEqual(@as(i64, 0), (try off.get("value")).integer);
    try testing.expect(off.effectTrace()[0].result == .null);
}

test "empty graph accepts add and rejections fail closed" {
    const a = testing.allocator;
    var rt = try GraphRuntime.loadJson(a, "{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[]}", 0);
    defer rt.deinit();
    var edit = try GraphEdit.fromJsonStr(a,
        \\{"kind":"edit","ir":"1","ops":[{"op":"add","node":{"id":"x","kind":"source","init":1}}]}
    );
    defer edit.deinit();
    try rt.apply(&edit);
    try testing.expectEqual(@as(i64, 1), (try rt.get("x")).integer);
    const texts = [_][]const u8{
        "{\"kind\":\"graph\",\"ir\":\"2\",\"nodes\":[]}",
        "{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[{\"id\":\"1count\",\"kind\":\"source\",\"init\":0}]}",
        "{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[{\"id\":\"c\",\"kind\":\"computed\",\"expr\":{\"op\":\"pow\",\"args\":[{\"lit\":2},{\"lit\":3}]}}]}",
        "{\"kind\":\"graph\",\"ir\":\"1\",\"nodes\":[{\"id\":\"e\",\"kind\":\"effect\",\"body\":\"log\"}]}",
    };
    for (texts) |text| {
        var bad = try GraphIr.fromJsonStr(a, text);
        defer bad.deinit();
        try testing.expect(bad.fault.len != 0);
    }
    var empty = try GraphEdit.fromJsonStr(a, "{\"kind\":\"edit\",\"ir\":\"1\",\"ops\":[]}");
    defer empty.deinit();
    try testing.expect(empty.fault.len != 0);
}

test "feedback stops at the drain budget" {
    const a = testing.allocator;
    var doc = try GraphIr.fromJsonStr(a,
        \\{"kind":"graph","ir":"1","nodes":[{"id":"n","kind":"source","init":0},{"id":"loop","kind":"effect","body":{"do":"set","target":"n","expr":{"op":"add","args":[{"ref":"n"},{"lit":1}]}}}]}
    );
    defer doc.deinit();
    var rt = try GraphRuntime.lower(&doc, 4);
    defer rt.deinit();
    try testing.expectEqual(@as(i32, 4), rt.last_drain_exhaustion.?);
    try testing.expectEqual(@as(i64, 4), (try rt.get("n")).integer);
}

const counter =
    \\{
    \\  "kind": "graph", "ir": "1", "id": "counter",
    \\  "nodes": [
    \\    {"id": "count", "kind": "source", "init": 1},
    \\    {"id": "doubled", "kind": "computed", "eager": true,
    \\      "expr": {"op": "mul", "args": [{"ref": "count"}, {"lit": 2}]}},
    \\    {"id": "log", "kind": "effect", "body": {"do": "eval", "expr": {"ref": "doubled"}}}
    \\  ]
    \\}
;

const counter_edit =
    \\{
    \\  "kind": "edit", "ir": "1",
    \\  "ops": [
    \\    {"op": "replace", "node": {"id": "doubled", "kind": "computed",
    \\      "expr": {"op": "add", "args": [{"ref": "count"}, {"lit": 10}]}}},
    \\    {"op": "add", "node": {"id": "label", "kind": "source", "init": "n"}},
    \\    {"op": "add", "node": {"id": "shown", "kind": "computed",
    \\      "expr": {"op": "concat", "args": [{"ref": "label"}, {"lit": ":"}]}}},
    \\    {"op": "remove", "id": "log"}
    \\  ]
    \\}
;

const counter_source =
    "graph counter ir 1\n" ++
    "source count = 1\n" ++
    "computed doubled eager = mul(ref(count), lit(2))\n" ++
    "effect log = eval(ref(doubled))\n";
