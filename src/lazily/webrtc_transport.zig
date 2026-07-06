const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("ipc.zig");
const permission = @import("permission.zig");

/// Version-agnostic Mutex shim (matches `context.zig`'s `GraphMutex` pattern):
/// Zig < 0.16 uses `std.Thread.Mutex`; Zig >= 0.16 uses a spinlock over
/// `std.atomic.Mutex` (std.Thread.Mutex was removed).
const ChannelMutex = if (builtin.zig_version.minor < 16)
    std.Thread.Mutex
else
    struct {
        inner: std.atomic.Mutex = .unlocked,
        pub fn lock(self: *@This()) void {
            while (!self.inner.tryLock()) {}
        }
        pub fn unlock(self: *@This()) void {
            self.inner.unlock();
        }
    };

/// The DataChannel seam — the portable transport abstraction behind which a
/// concrete WebRTC backend (str0m in Rust, the browser `RTCPeerConnection` in
/// JS, a consumer-provided adapter in Kotlin/Zig) is optional. Carries
/// serialized `IpcMessage` frames as bytes; reliable ordered delivery is the
/// contract. Mirrors lazily-rs `DataChannel` (`webrtc_transport.rs:34-52`).
pub const DataChannel = struct {
    ctx: *anyopaque,
    vtable: *const Vtable,

    pub const Vtable = struct {
        send_frame: *const fn (ctx: *anyopaque, frame: []const u8) Error!void,
        try_recv_frame: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) Error!?[]u8,
        is_open: *const fn (ctx: *anyopaque) bool,
    };

    pub const Error = error{
        Channel,
        Closed,
        Encode,
        Decode,
        OutOfMemory,
    };

    pub fn sendFrame(self: DataChannel, frame: []const u8) Error!void {
        return self.vtable.send_frame(self.ctx, frame);
    }

    pub fn tryRecvFrame(self: DataChannel, allocator: std.mem.Allocator) Error!?[]u8 {
        return self.vtable.try_recv_frame(self.ctx, allocator);
    }

    pub fn isOpen(self: DataChannel) bool {
        return self.vtable.is_open(self.ctx);
    }
};

/// A permission-filtering IPC sink. Outbound `Snapshot`/`Delta`/`CrdtSync`
/// messages are filtered to the recipient peer's read allowlist (omission, not
/// redaction) before encoding and sending. Inbound permission enforcement is
/// the graph-apply layer's responsibility — the transport carries frames
/// verbatim. Mirrors lazily-rs `WebRtcSink` (`webrtc_transport.rs:86-130`).
pub const WebRtcSink = struct {
    channel: DataChannel,
    permissions: *const permission.PeerPermissions,
    peer: ipc.PeerId,

    pub fn init(
        channel: DataChannel,
        permissions: *const permission.PeerPermissions,
        peer: ipc.PeerId,
    ) WebRtcSink {
        return .{ .channel = channel, .permissions = permissions, .peer = peer };
    }

    /// Filter, encode, and send a message. Returns Channel.Closed when the
    /// underlying channel is not open.
    pub fn send(self: *WebRtcSink, allocator: std.mem.Allocator, message: ipc.IpcMessage) DataChannel.Error!void {
        if (!self.channel.isOpen()) return error.Closed;

        const filtered = try self.filterMessage(allocator, message);
        defer freeMessage(allocator, filtered);

        const frame = try filtered.encodeJsonAlloc(allocator);
        defer allocator.free(frame);

        try self.channel.sendFrame(frame);
    }

    fn filterMessage(self: *WebRtcSink, allocator: std.mem.Allocator, message: ipc.IpcMessage) DataChannel.Error!ipc.IpcMessage {
        switch (message) {
            .Snapshot => |s| {
                // Filter nodes to readable; keep edges/roots that reference
                // surviving nodes. (Edges to filtered nodes are dropped.)
                var nodes = std.ArrayList(ipc.NodeSnapshot).empty;
                defer nodes.deinit(allocator);
                var readable = std.AutoHashMap(ipc.NodeId, void).init(allocator);
                defer readable.deinit();
                for (s.nodes) |ns| {
                    if (self.permissions.canRead(self.peer, ns.node)) {
                        try nodes.append(allocator, ns);
                        try readable.put(ns.node, {});
                    }
                }
                var edges = std.ArrayList(ipc.EdgeSnapshot).empty;
                defer edges.deinit(allocator);
                for (s.edges) |es| {
                    if (readable.contains(es.dependent) and readable.contains(es.dependency)) {
                        try edges.append(allocator, es);
                    }
                }
                var roots = std.ArrayList(ipc.NodeId).empty;
                defer roots.deinit(allocator);
                for (s.roots) |r| {
                    if (readable.contains(r)) try roots.append(allocator, r);
                }
                return .{ .Snapshot = ipc.Snapshot.init(
                    s.epoch,
                    try nodes.toOwnedSlice(allocator),
                    try edges.toOwnedSlice(allocator),
                    try roots.toOwnedSlice(allocator),
                ) };
            },
            .Delta => |d| {
                var ops = std.ArrayList(ipc.DeltaOp).empty;
                defer ops.deinit(allocator);
                for (d.ops) |op| {
                    if (opNode(op)) |n| {
                        if (!self.permissions.canRead(self.peer, n)) continue;
                    }
                    try ops.append(allocator, op);
                }
                return .{ .Delta = ipc.Delta.init(d.base_epoch, d.epoch, try ops.toOwnedSlice(allocator)) };
            },
            .CrdtSync => |c| {
                var readable = std.AutoHashMap(ipc.NodeId, void).init(allocator);
                defer readable.deinit();
                for (c.ops) |op| {
                    if (self.permissions.canRead(self.peer, op.node)) {
                        try readable.put(op.node, {});
                    }
                }
                const filtered = try c.filterReadable(allocator, readable);
                return .{ .CrdtSync = filtered };
            },
        }
    }
};

/// A verbatim IPC source. Decodes inbound frames; the apply layer (BridgeHub)
/// enforces inbound write permissions. Mirrors lazily-rs `WebRtcSource`.
pub const WebRtcSource = struct {
    channel: DataChannel,

    pub fn init(channel: DataChannel) WebRtcSource {
        return .{ .channel = channel };
    }

    /// Decode the next pending frame into an `IpcMessage`. Returns null when
    /// no frame is pending.
    pub fn recv(self: *WebRtcSource, allocator: std.mem.Allocator) DataChannel.Error!?ipc.ParsedMessage {
        const frame = (try self.channel.tryRecvFrame(allocator)) orelse return null;
        defer allocator.free(frame);
        const parsed = ipc.IpcMessage.decodeJson(allocator, frame) catch return error.Decode;
        return parsed;
    }
};

/// Extract the target node id from a DeltaOp (for permission filtering).
fn opNode(op: ipc.DeltaOp) ?ipc.NodeId {
    return switch (op) {
        .CellSet => |e| e.node,
        .SlotValue => |e| e.node,
        .Invalidate => |e| e.node,
        .NodeAdd => |e| e.node,
        .NodeRemove => |e| e.node,
        .EdgeAdd, .EdgeRemove => null,
    };
}

fn freeMessage(allocator: std.mem.Allocator, message: ipc.IpcMessage) void {
    switch (message) {
        .Snapshot => |s| {
            allocator.free(s.nodes);
            allocator.free(s.edges);
            allocator.free(s.roots);
        },
        .Delta => |d| allocator.free(d.ops),
        .CrdtSync => |c| {
            allocator.free(c.ops);
            allocator.free(c.frontier);
        },
    }
}

/// An in-memory loopback DataChannel pair: two endpoints with cross-wired
/// queues and a shared open flag. Used for conformance tests and in-process
/// multi-peer simulations. Mirrors lazily-rs `InMemoryDataChannel`
/// (`webrtc_transport.rs:209-262`).
pub const InMemoryDataChannel = struct {
    tx: *TxQueue,
    rx: *TxQueue,
    open_flag: *std.atomic.Value(bool),
    allocator: std.mem.Allocator,

    pub const Frame = []u8;

    /// One direction of the loopback pair.
    pub const TxQueue = struct {
        frames: std.ArrayList(Frame) = .empty,
        mutex: ChannelMutex = .{},

        pub fn deinit(self: *TxQueue, allocator: std.mem.Allocator) void {
            self.mutex.lock();
            for (self.frames.items) |f| allocator.free(f);
            self.frames.deinit(allocator);
            self.mutex.unlock();
        }
    };

    /// Create a cross-wired pair of channels sharing one open flag. Each side
    /// owns its `rx` queue; the pair shares two `TxQueue`s and one
    /// `open_flag`. Clean up with `deinitPair`.
    pub fn pair(allocator: std.mem.Allocator) !struct { a: InMemoryDataChannel, b: InMemoryDataChannel } {
        const q_a = try allocator.create(TxQueue);
        const q_b = try allocator.create(TxQueue);
        q_a.* = .{};
        q_b.* = .{};
        const open = try allocator.create(std.atomic.Value(bool));
        open.* = std.atomic.Value(bool).init(true);
        return .{
            .a = .{ .tx = q_a, .rx = q_b, .open_flag = open, .allocator = allocator },
            .b = .{ .tx = q_b, .rx = q_a, .open_flag = open, .allocator = allocator },
        };
    }

    /// Free the shared queues + open flag. Call once per pair.
    pub fn deinitPair(self: *InMemoryDataChannel) void {
        self.tx.deinit(self.allocator);
        self.rx.deinit(self.allocator);
        self.allocator.destroy(self.tx);
        self.allocator.destroy(self.rx);
        self.allocator.destroy(self.open_flag);
    }

    pub fn close(self: *InMemoryDataChannel) void {
        self.open_flag.store(false, .seq_cst);
    }

    pub fn channel(self: *InMemoryDataChannel) DataChannel {
        return .{
            .ctx = self,
            .vtable = &.{
                .send_frame = sendFrameImpl,
                .try_recv_frame = tryRecvFrameImpl,
                .is_open = isOpenImpl,
            },
        };
    }

    fn sendFrameImpl(ctx: *anyopaque, frame: []const u8) DataChannel.Error!void {
        const self: *InMemoryDataChannel = @ptrCast(@alignCast(ctx));
        if (!self.open_flag.load(.seq_cst)) return error.Closed;
        const dup = try self.allocator.dupe(u8, frame);
        {
            self.tx.mutex.lock();
            defer self.tx.mutex.unlock();
            self.tx.frames.append(self.allocator, dup) catch {
                self.allocator.free(dup);
                return error.OutOfMemory;
            };
        }
    }

    fn tryRecvFrameImpl(ctx: *anyopaque, allocator: std.mem.Allocator) DataChannel.Error!?[]u8 {
        const self: *InMemoryDataChannel = @ptrCast(@alignCast(ctx));
        const frame: ?Frame = blk: {
            self.rx.mutex.lock();
            defer self.rx.mutex.unlock();
            if (self.rx.frames.items.len == 0) break :blk null;
            break :blk self.rx.frames.orderedRemove(0);
        };
        const f = frame orelse return null;
        // Transfer ownership to the caller's allocator.
        if (allocator.ptr == self.allocator.ptr and allocator.vtable == self.allocator.vtable) {
            return f;
        }
        const dup = try allocator.dupe(u8, f);
        self.allocator.free(f);
        return dup;
    }

    fn isOpenImpl(ctx: *anyopaque) bool {
        const self: *InMemoryDataChannel = @ptrCast(@alignCast(ctx));
        return self.open_flag.load(.seq_cst);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "lazily/webrtc_transport: InMemoryDataChannel round-trip + close" {
    const allocator = std.testing.allocator;
    var p = try InMemoryDataChannel.pair(allocator);
    defer p.a.deinitPair();

    const ca = p.a.channel();
    const cb = p.b.channel();

    try std.testing.expect(ca.isOpen());
    try ca.sendFrame("hello");
    const frame = (try cb.tryRecvFrame(allocator)).?;
    defer allocator.free(frame);
    try std.testing.expectEqualStrings("hello", frame);

    p.a.close();
    try std.testing.expect(!ca.isOpen());
    try std.testing.expectError(error.Closed, ca.sendFrame("after-close"));
}

test "lazily/webrtc_transport: WebRtcSink filters CrdtSync by read permission" {
    const allocator = std.testing.allocator;
    var perms = permission.PeerPermissions.init(allocator);
    defer perms.deinit();
    try perms.grant(2, 10, .read); // peer 2 can read node 10 only

    var p = try InMemoryDataChannel.pair(allocator);
    defer p.a.deinitPair();
    var sink = WebRtcSink.init(p.a.channel(), &perms, 2);

    const msg = ipc.IpcMessage{ .CrdtSync = ipc.CrdtSync.init(
        &.{},
        &.{
            .{ .node = 10, .stamp = .{ .wall_time = 1, .logical = 0, .peer = 1 }, .state = ipc.IpcValue.fromInline(&.{ 1 }) },
            .{ .node = 20, .stamp = .{ .wall_time = 1, .logical = 0, .peer = 1 }, .state = ipc.IpcValue.fromInline(&.{ 2 }) },
        },
    ) };
    try sink.send(allocator, msg);

    // The recipient (b) should receive only the node-10 op.
    var src = WebRtcSource.init(p.b.channel());
    var parsed = (try src.recv(allocator)).?;
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.message.CrdtSync.ops.len);
    try std.testing.expectEqual(@as(ipc.NodeId, 10), parsed.message.CrdtSync.ops[0].node);
}

test "lazily/webrtc_transport: WebRtcSource recv returns null when idle" {
    const allocator = std.testing.allocator;
    var p = try InMemoryDataChannel.pair(allocator);
    defer p.a.deinitPair();
    var src = WebRtcSource.init(p.b.channel());
    try std.testing.expect((try src.recv(allocator)) == null);
}
