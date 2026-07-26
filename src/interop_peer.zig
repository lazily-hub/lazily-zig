const std = @import("std");
const lazily = @import("lazily");

const PROTOCOL_VERSION: u64 = 1;

const SnapshotCell = struct {
    node: lazily.NodeId,
    key: ?lazily.NodeKey,
    state: lazily.IpcValue,
};

const EmptyObject = struct {};

const Peer = struct {
    arena: std.heap.ArenaAllocator,
    peer_id: ?lazily.PeerId = null,
    runtime: ?lazily.CrdtPlaneRuntime = null,

    fn init(backing: std.mem.Allocator) Peer {
        return .{ .arena = std.heap.ArenaAllocator.init(backing) };
    }

    fn deinit(self: *Peer) void {
        if (self.runtime) |*runtime| runtime.deinit();
        self.arena.deinit();
    }

    fn requestAlloc(self: *Peer, line: []const u8) ![]u8 {
        const allocator = self.arena.allocator();
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{
            .allocate = .alloc_always,
        });
        const request = parsed.value;
        const command = try stringField(request, "cmd");
        if (std.mem.eql(u8, command, "hello")) return self.helloAlloc(request);
        if (std.mem.eql(u8, command, "local_set")) return self.localSetAlloc(request);
        if (std.mem.eql(u8, command, "deliver")) return self.deliverAlloc(request);
        if (std.mem.eql(u8, command, "snapshot")) return self.snapshotAlloc();
        if (std.mem.eql(u8, command, "bye")) {
            return stringifyAlloc(allocator, .{ .ok = true });
        }
        if (std.mem.startsWith(u8, command, "link_")) {
            return stringifyAlloc(allocator, .{
                .ok = false,
                .@"error" = "unsupported channel",
                .unsupported = true,
            });
        }
        return self.errorAlloc("unknown command");
    }

    fn helloAlloc(self: *Peer, request: std.json.Value) ![]u8 {
        const version = try u64Field(request, "protocol_version");
        if (version != PROTOCOL_VERSION) return self.errorAlloc("unsupported protocol_version");
        const peer = try u64Field(request, "peer");
        if (self.runtime) |*runtime| runtime.deinit();
        self.peer_id = peer;
        self.runtime = lazily.CrdtPlaneRuntime.init(self.arena.allocator(), peer);
        return stringifyAlloc(self.arena.allocator(), .{
            .ok = true,
            .binding = "lazily-zig",
            .version = "0.31.1",
            .protocol_version = PROTOCOL_VERSION,
            .features = [_][]const u8{"distributed_crdt"},
            .codecs = [_][]const u8{ "json", "msgpack" },
            .channels = [_][]const u8{},
            .channel_variants = EmptyObject{},
            .platform_profile = "portable",
            .carve_outs = [_][]const u8{"transport_links"},
        });
    }

    fn localSetAlloc(self: *Peer, request: std.json.Value) ![]u8 {
        const runtime = &(self.runtime orelse return self.errorAlloc("hello must run first"));
        const node = try u64Field(request, "node");
        const at = try u64Field(request, "at");
        const key_value = try objectField(request, "key");
        const key: ?[]const u8 = switch (key_value) {
            .null => null,
            .string => |value| value,
            else => return self.errorAlloc("local_set requires nullable key"),
        };
        const state = try lazily.IpcValue.fromJson(
            self.arena.allocator(),
            try objectField(request, "state"),
        );
        try runtime.registerKey(node, key);
        const op = (try runtime.localUpdate(node, state, at)) orelse
            return self.errorAlloc("production runtime rejected fresh local op");
        const frontier = try runtime.wireFrontier(self.arena.allocator());
        const ops = try self.arena.allocator().alloc(lazily.CrdtOp, 1);
        ops[0] = op;
        const frame = lazily.IpcMessage{
            .CrdtSync = lazily.CrdtSync.init(frontier, ops),
        };
        return stringifyAlloc(self.arena.allocator(), .{ .ok = true, .frame = frame });
    }

    fn deliverAlloc(self: *Peer, request: std.json.Value) ![]u8 {
        const runtime = &(self.runtime orelse return self.errorAlloc("hello must run first"));
        const message = try lazily.IpcMessage.fromJson(
            self.arena.allocator(),
            try objectField(request, "frame"),
        );
        const sync = switch (message) {
            .CrdtSync => |sync| sync,
            else => return self.errorAlloc("deliver requires CrdtSync"),
        };
        const applied = try runtime.ingest(sync, try u64Field(request, "at"));
        return stringifyAlloc(self.arena.allocator(), .{ .ok = true, .applied = applied });
    }

    fn snapshotAlloc(self: *Peer) ![]u8 {
        const runtime = &(self.runtime orelse return self.errorAlloc("hello must run first"));
        const entries = try runtime.converged(self.arena.allocator());
        const cells = try self.arena.allocator().alloc(SnapshotCell, entries.len);
        for (entries, cells) |entry, *cell| {
            cell.* = .{ .node = entry.node, .key = entry.key, .state = entry.state };
        }
        return stringifyAlloc(self.arena.allocator(), .{ .ok = true, .cells = cells });
    }

    fn errorAlloc(self: *Peer, message: []const u8) ![]u8 {
        return stringifyAlloc(self.arena.allocator(), .{
            .ok = false,
            .@"error" = message,
        });
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var peer = Peer.init(init.gpa);
    defer peer.deinit();
    if (args.len > 1 and std.mem.eql(u8, args[1], "--self-check")) {
        try selfCheck(&peer);
        std.debug.print("lazily-zig interop peer self-check: ok\n", .{});
        return;
    }

    var stdin_buffer: [1024 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const input = &stdin_reader.interface;
    const output = &stdout_writer.interface;

    while (try input.takeDelimiter('\n')) |line| {
        const bye = std.mem.indexOf(u8, line, "\"cmd\":\"bye\"") != null or
            std.mem.indexOf(u8, line, "\"cmd\": \"bye\"") != null;
        const response = peer.requestAlloc(line) catch |err|
            try peer.errorAlloc(@errorName(err));
        try output.writeAll(response);
        try output.writeByte('\n');
        try output.flush();
        if (bye) return;
    }
}

fn selfCheck(peer: *Peer) !void {
    const hello = try peer.requestAlloc(
        \\{"cmd":"hello","peer":1,"protocol_version":1}
    );
    if (std.mem.indexOf(u8, hello, "\"ok\":true") == null) return error.SelfCheckHello;
    const local = try peer.requestAlloc(
        \\{"cmd":"local_set","node":7,"key":null,"state":{"Inline":[65]},"at":10}
    );
    if (std.mem.indexOf(u8, local, "\"key\":null") == null) return error.SelfCheckKey;
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        peer.arena.allocator(),
        local,
        .{ .allocate = .alloc_always },
    );
    const frame = try objectField(parsed.value, "frame");
    const delivery = try stringifyAlloc(peer.arena.allocator(), .{
        .cmd = "deliver",
        .frame = frame,
        .at = 11,
    });
    const duplicate = try peer.requestAlloc(delivery);
    if (std.mem.indexOf(u8, duplicate, "\"applied\":0") == null)
        return error.SelfCheckIdempotence;
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

fn objectField(value: std.json.Value, name: []const u8) !std.json.Value {
    return switch (value) {
        .object => |object| object.get(name) orelse error.MissingField,
        else => error.ExpectedObject,
    };
}

fn stringField(value: std.json.Value, name: []const u8) ![]const u8 {
    return switch (try objectField(value, name)) {
        .string => |string| string,
        else => error.ExpectedString,
    };
}

fn u64Field(value: std.json.Value, name: []const u8) !u64 {
    return switch (try objectField(value, name)) {
        .integer => |integer| std.math.cast(u64, integer) orelse error.ExpectedU64,
        else => error.ExpectedU64,
    };
}
