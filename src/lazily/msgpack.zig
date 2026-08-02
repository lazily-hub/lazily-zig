//! lazily IPC wire codec — `msgpack`, the CROSS-LANGUAGE BINARY DEFAULT
//! (`#lzmsgpackseven`, protocol.md § Frame codecs).
//!
//! `msgpack` is MUST-level for every binding, and protocol.md spells out that
//! shipping *a* MessagePack codec is not implementing it: the codec token names
//! ONE wire — the externally tagged frame (`{"Snapshot": …}`) over named-field
//! maps whose keys are the `json` field names, with the same omit-when-absent
//! rule for optional fields. A codec that packs the same data as an internally
//! tagged envelope (`{"type": 0, "value": …}`), gives `NodeState`/`IpcValue`
//! integer `kind` discriminators instead of the `Payload`/`Inline` external
//! tags, or uses positional arrays, is a private codec that happens to use
//! MessagePack framing — a peer that negotiated `msgpack` with it could not
//! decode its frames.
//!
//! This module is built ON the `json` codec in `ipc.zig` rather than beside it,
//! and that is the point: the two codecs differ only in how a value tree is
//! serialized, never in the SHAPE of that tree. Deriving the msgpack frame from
//! the json encoder's own output makes the external tags, the field names, and
//! both `NodeKey` rules (`NodeSnapshot`/`NodeAdd` omit an absent key, `CrdtOp`
//! always writes it, `null` when unset) identical BY CONSTRUCTION. A second
//! hand-written transcription of the same shape is exactly the drift that puts
//! a binding outside the wire it claims to speak. Zig's json encoder is a
//! streaming stringifier with no DOM sink, so the bridge runs through the
//! reference text form; that costs a parse per frame and buys a codec that
//! cannot silently diverge from the reference one.
//!
//! Byte payloads are ARRAYS OF INTEGERS, not MessagePack `bin`. That is what
//! the reference encoder produces (`rmp_serde` serializes `Vec<u8>` through
//! serde's default seq impl) and what its decoder accepts, so emitting or
//! accepting `bin` would put lazily-zig outside the wire it claims. `bin` is
//! therefore recognized on read only in order to be REJECTED.
//!
//! NOT byte-canonical (§ Frame codecs): a MessagePack map's key order is
//! encoder-defined, so conformance is `decode(encode(m)) == m` plus a decode of
//! a peer's frame, never a golden byte string. This encoder happens to be
//! deterministic — allowed, but not a property any peer may rely on.
//!
//! Zero dependencies: the packer/unpacker below implements the subset lazily
//! needs (nil, bool, int, str, array, map; `bin` read-to-reject) directly
//! against the MessagePack spec.
//! Reference: https://github.com/msgpack/msgpack/blob/master/spec.md

const std = @import("std");
const ipc = @import("ipc.zig");

const Value = std.json.Value;

pub const Error = error{
    /// The buffer ran out mid-value.
    TruncatedFrame,
    /// A well-formed value was followed by bytes that are not part of the frame.
    TrailingBytesAfterFrame,
    /// `0xc1` — the one byte MessagePack never assigns.
    NeverUsedFormat,
    /// A `bin` payload turned up where this wire carries an array of integers.
    UnexpectedBinaryPayload,
    /// `float`/`ext` — no `IpcMessage` field is floating point or extension typed.
    UnsupportedValueInFrame,
    /// A map key that is not a string. Named-field maps require string keys.
    NonStringMapKey,
    /// An integer outside the range MessagePack can express.
    IntegerOutOfRange,
    /// A `str`/`array`/`map` header longer than `usize` can address.
    LengthOutOfRange,
};

// ---------------------------------------------------------------------------
// Packer — writes the smallest valid encoding of each value.
// ---------------------------------------------------------------------------

pub const Packer = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) Packer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Packer) void {
        self.buf.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn bytes(self: *const Packer) []const u8 {
        return self.buf.items;
    }

    /// Hand the accumulated frame to the caller. The packer is empty afterwards.
    pub fn toOwnedSlice(self: *Packer) ![]u8 {
        return self.buf.toOwnedSlice(self.allocator);
    }

    fn byte(self: *Packer, b: u8) !void {
        try self.buf.append(self.allocator, b);
    }

    fn beU(self: *Packer, comptime T: type, value: T) !void {
        var raw: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &raw, value, .big);
        try self.buf.appendSlice(self.allocator, &raw);
    }

    pub fn nil(self: *Packer) !void {
        try self.byte(0xc0);
    }

    pub fn boolean(self: *Packer, value: bool) !void {
        try self.byte(if (value) 0xc3 else 0xc2);
    }

    pub fn int(self: *Packer, value: i128) !void {
        if (value >= 0) {
            const u: u128 = @intCast(value);
            if (u <= 0x7f) return self.byte(@intCast(u));
            if (u <= std.math.maxInt(u8)) {
                try self.byte(0xcc);
                return self.beU(u8, @intCast(u));
            }
            if (u <= std.math.maxInt(u16)) {
                try self.byte(0xcd);
                return self.beU(u16, @intCast(u));
            }
            if (u <= std.math.maxInt(u32)) {
                try self.byte(0xce);
                return self.beU(u32, @intCast(u));
            }
            if (u <= std.math.maxInt(u64)) {
                try self.byte(0xcf);
                return self.beU(u64, @intCast(u));
            }
            return Error.IntegerOutOfRange;
        }
        if (value >= -32) return self.byte(@bitCast(@as(i8, @intCast(value))));
        if (value >= std.math.minInt(i8)) {
            try self.byte(0xd0);
            return self.beU(u8, @bitCast(@as(i8, @intCast(value))));
        }
        if (value >= std.math.minInt(i16)) {
            try self.byte(0xd1);
            return self.beU(u16, @bitCast(@as(i16, @intCast(value))));
        }
        if (value >= std.math.minInt(i32)) {
            try self.byte(0xd2);
            return self.beU(u32, @bitCast(@as(i32, @intCast(value))));
        }
        if (value >= std.math.minInt(i64)) {
            try self.byte(0xd3);
            return self.beU(u64, @bitCast(@as(i64, @intCast(value))));
        }
        return Error.IntegerOutOfRange;
    }

    pub fn str(self: *Packer, text: []const u8) !void {
        if (text.len <= 31) {
            try self.byte(0xa0 | @as(u8, @intCast(text.len)));
        } else if (text.len <= std.math.maxInt(u8)) {
            try self.byte(0xd9);
            try self.beU(u8, @intCast(text.len));
        } else if (text.len <= std.math.maxInt(u16)) {
            try self.byte(0xda);
            try self.beU(u16, @intCast(text.len));
        } else if (text.len <= std.math.maxInt(u32)) {
            try self.byte(0xdb);
            try self.beU(u32, @intCast(text.len));
        } else return Error.LengthOutOfRange;
        try self.buf.appendSlice(self.allocator, text);
    }

    pub fn arrayHeader(self: *Packer, count: usize) !void {
        if (count <= 15) return self.byte(0x90 | @as(u8, @intCast(count)));
        if (count <= std.math.maxInt(u16)) {
            try self.byte(0xdc);
            return self.beU(u16, @intCast(count));
        }
        if (count <= std.math.maxInt(u32)) {
            try self.byte(0xdd);
            return self.beU(u32, @intCast(count));
        }
        return Error.LengthOutOfRange;
    }

    pub fn mapHeader(self: *Packer, count: usize) !void {
        if (count <= 15) return self.byte(0x80 | @as(u8, @intCast(count)));
        if (count <= std.math.maxInt(u16)) {
            try self.byte(0xde);
            return self.beU(u16, @intCast(count));
        }
        if (count <= std.math.maxInt(u32)) {
            try self.byte(0xdf);
            return self.beU(u32, @intCast(count));
        }
        return Error.LengthOutOfRange;
    }
};

// ---------------------------------------------------------------------------
// Unpacker
// ---------------------------------------------------------------------------

pub const Unpacker = struct {
    data: []const u8,
    pos: usize = 0,

    pub const Kind = enum { nil, boolean, int, str, bin, array, map, float, ext, never_used };

    pub fn init(data: []const u8) Unpacker {
        return .{ .data = data };
    }

    pub fn eof(self: *const Unpacker) bool {
        return self.pos >= self.data.len;
    }

    fn peekByte(self: *const Unpacker) !u8 {
        if (self.pos >= self.data.len) return Error.TruncatedFrame;
        return self.data[self.pos];
    }

    fn takeByte(self: *Unpacker) !u8 {
        const b = try self.peekByte();
        self.pos += 1;
        return b;
    }

    fn takeBeU(self: *Unpacker, comptime T: type) !T {
        const width = @divExact(@typeInfo(T).int.bits, 8);
        if (self.pos + width > self.data.len) return Error.TruncatedFrame;
        const raw = self.data[self.pos..][0..width];
        self.pos += width;
        return std.mem.readInt(T, raw, .big);
    }

    fn takeSlice(self: *Unpacker, len: usize) ![]const u8 {
        if (self.pos + len > self.data.len) return Error.TruncatedFrame;
        const out = self.data[self.pos..][0..len];
        self.pos += len;
        return out;
    }

    pub fn peekKind(self: *const Unpacker) !Kind {
        const b = try self.peekByte();
        return switch (b) {
            0x00...0x7f, 0xe0...0xff => .int,
            0x80...0x8f, 0xde, 0xdf => .map,
            0x90...0x9f, 0xdc, 0xdd => .array,
            0xa0...0xbf, 0xd9...0xdb => .str,
            0xc0 => .nil,
            0xc1 => .never_used,
            0xc2, 0xc3 => .boolean,
            0xc4...0xc6 => .bin,
            0xc7...0xc9, 0xd4...0xd8 => .ext,
            0xca, 0xcb => .float,
            0xcc...0xcf, 0xd0...0xd3 => .int,
        };
    }

    pub fn readNil(self: *Unpacker) !void {
        if (try self.takeByte() != 0xc0) return Error.UnsupportedValueInFrame;
    }

    pub fn readBool(self: *Unpacker) !bool {
        return switch (try self.takeByte()) {
            0xc2 => false,
            0xc3 => true,
            else => Error.UnsupportedValueInFrame,
        };
    }

    /// `i128` is the narrowest type that holds every MessagePack integer, since
    /// the format carries both `uint64` and `int64`.
    pub fn readInt(self: *Unpacker) !i128 {
        const b = try self.takeByte();
        return switch (b) {
            0x00...0x7f => @as(i128, b),
            0xe0...0xff => @as(i128, @as(i8, @bitCast(b))),
            0xcc => @as(i128, try self.takeBeU(u8)),
            0xcd => @as(i128, try self.takeBeU(u16)),
            0xce => @as(i128, try self.takeBeU(u32)),
            0xcf => @as(i128, try self.takeBeU(u64)),
            0xd0 => @as(i128, @as(i8, @bitCast(try self.takeBeU(u8)))),
            0xd1 => @as(i128, @as(i16, @bitCast(try self.takeBeU(u16)))),
            0xd2 => @as(i128, @as(i32, @bitCast(try self.takeBeU(u32)))),
            0xd3 => @as(i128, @as(i64, @bitCast(try self.takeBeU(u64)))),
            else => Error.UnsupportedValueInFrame,
        };
    }

    /// Borrows from the frame buffer; copy it if it must outlive the bytes.
    pub fn readStr(self: *Unpacker) ![]const u8 {
        const b = try self.takeByte();
        const len: usize = switch (b) {
            0xa0...0xbf => b & 0x1f,
            0xd9 => try self.takeBeU(u8),
            0xda => try self.takeBeU(u16),
            0xdb => try self.takeBeU(u32),
            else => return Error.UnsupportedValueInFrame,
        };
        return self.takeSlice(len);
    }

    pub fn readArrayHeader(self: *Unpacker) !usize {
        const b = try self.takeByte();
        return switch (b) {
            0x90...0x9f => b & 0x0f,
            0xdc => try self.takeBeU(u16),
            0xdd => try self.takeBeU(u32),
            else => Error.UnsupportedValueInFrame,
        };
    }

    pub fn readMapHeader(self: *Unpacker) !usize {
        const b = try self.takeByte();
        return switch (b) {
            0x80...0x8f => b & 0x0f,
            0xde => try self.takeBeU(u16),
            0xdf => try self.takeBeU(u32),
            else => Error.UnsupportedValueInFrame,
        };
    }
};

// ---------------------------------------------------------------------------
// Generic DOM <-> MessagePack bridge
// ---------------------------------------------------------------------------

/// `std.json.ObjectMap` is an allocator-carrying `StringArrayHashMap` through
/// Zig 0.15 and the allocator-free one from 0.16 on, and this repo gates on
/// three toolchains spanning that change. Probing for the `allocator` field
/// keeps the bridge working on all three without a version number to keep in
/// sync with the pins.
const object_map_is_managed = @hasField(std.json.ObjectMap, "allocator");

fn objectMapEmpty(allocator: std.mem.Allocator) std.json.ObjectMap {
    return if (comptime object_map_is_managed) std.json.ObjectMap.init(allocator) else .empty;
}

fn objectMapPut(
    map: *std.json.ObjectMap,
    allocator: std.mem.Allocator,
    key: []const u8,
    value: Value,
) !void {
    if (comptime object_map_is_managed) return map.put(key, value);
    return map.put(allocator, key, value);
}

/// Pack a `std.json.Value` tree. Object member order is preserved
/// (`std.json.ObjectMap` is a `StringArrayHashMap`), which is why this encoder
/// is deterministic — allowed, never guaranteed to a peer.
pub fn packValue(packer: *Packer, value: Value) !void {
    switch (value) {
        .null => try packer.nil(),
        .bool => |b| try packer.boolean(b),
        .integer => |n| try packer.int(n),
        .number_string => |s| try packer.int(try std.fmt.parseInt(i128, s, 10)),
        // No `IpcMessage` field is floating point (§ IpcMessage: every field is
        // an integer, string, or byte sequence). Refusing here keeps a future
        // double-valued field from silently acquiring a wire form nothing
        // agreed on.
        .float => return Error.UnsupportedValueInFrame,
        .string => |s| try packer.str(s),
        .array => |a| {
            try packer.arrayHeader(a.items.len);
            for (a.items) |item| try packValue(packer, item);
        },
        .object => |o| {
            try packer.mapHeader(o.count());
            var iter = o.iterator();
            while (iter.next()) |entry| {
                try packer.str(entry.key_ptr.*);
                try packValue(packer, entry.value_ptr.*);
            }
        },
    }
}

/// Unpack into a `std.json.Value` tree allocated from `arena`. Strings and
/// object keys are COPIED, so the tree outlives the frame buffer.
pub fn unpackValue(arena: std.mem.Allocator, up: *Unpacker) anyerror!Value {
    switch (try up.peekKind()) {
        .nil => {
            try up.readNil();
            return .null;
        },
        .boolean => return .{ .bool = try up.readBool() },
        .int => {
            const n = try up.readInt();
            if (n >= std.math.minInt(i64) and n <= std.math.maxInt(i64)) {
                return .{ .integer = @intCast(n) };
            }
            // `std.json` spells an integer wider than `i64` as `number_string`;
            // matching that keeps the two codecs' value trees comparable.
            return .{ .number_string = try std.fmt.allocPrint(arena, "{d}", .{n}) };
        },
        .str => return .{ .string = try arena.dupe(u8, try up.readStr()) },
        // A byte payload arrives as an ARRAY OF INTEGERS on this wire. The
        // reference decoder rejects `bin` in the same position, so accepting it
        // here would make lazily-zig read frames no conforming peer produces
        // and write none it can read — a private extension wearing the
        // `msgpack` token.
        .bin => return Error.UnexpectedBinaryPayload,
        .array => {
            const count = try up.readArrayHeader();
            var out = std.json.Array.init(arena);
            try out.ensureTotalCapacity(count);
            var i: usize = 0;
            while (i < count) : (i += 1) out.appendAssumeCapacity(try unpackValue(arena, up));
            return .{ .array = out };
        },
        .map => {
            const count = try up.readMapHeader();
            var out = objectMapEmpty(arena);
            var i: usize = 0;
            while (i < count) : (i += 1) {
                if (try up.peekKind() != .str) return Error.NonStringMapKey;
                const key = try arena.dupe(u8, try up.readStr());
                try objectMapPut(&out, arena, key, try unpackValue(arena, up));
            }
            return .{ .object = out };
        },
        .float, .ext => return Error.UnsupportedValueInFrame,
        .never_used => return Error.NeverUsedFormat,
    }
}

/// Schema-less view of a frame's bytes.
///
/// The named-field rule is a property of the ENCODING, so it is invisible to
/// any assertion over a decoded `IpcMessage`: a positional encoder round-trips
/// every value correctly and is still non-conforming. Conformance runners
/// introspect through this.
pub fn toJsonValue(allocator: std.mem.Allocator, frame: []const u8) !std.json.Parsed(Value) {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    var up = Unpacker.init(frame);
    const value = try unpackValue(arena.allocator(), &up);
    if (!up.eof()) return Error.TrailingBytesAfterFrame;
    return .{ .arena = arena, .value = value };
}

// ---------------------------------------------------------------------------
// The frame codec
// ---------------------------------------------------------------------------

/// Encode `message` as a `msgpack` frame. Caller owns the returned bytes.
pub fn encodeAlloc(allocator: std.mem.Allocator, message: ipc.IpcMessage) ![]u8 {
    // Derived from the REFERENCE codec's own output rather than transcribed a
    // second time — see the module header. The two codecs cannot disagree about
    // tags, field names, or the omit-when-absent rule, because only one of them
    // decides those.
    const text = try message.encodeJsonAlloc(allocator);
    defer allocator.free(text);

    var tree = try std.json.parseFromSlice(Value, allocator, text, .{ .allocate = .alloc_always });
    defer tree.deinit();

    var packer = Packer.init(allocator);
    errdefer packer.deinit();
    try packValue(&packer, tree.value);
    return packer.toOwnedSlice();
}

/// Decode a `msgpack` frame. The returned `ParsedMessage` owns the arena the
/// message's slices point into; `deinit()` it.
pub fn decode(allocator: std.mem.Allocator, frame: []const u8) !ipc.ParsedMessage {
    var parsed = try toJsonValue(allocator, frame);
    errdefer parsed.deinit();
    const message = try ipc.IpcMessage.fromJson(parsed.arena.allocator(), parsed.value);
    return .{ .parsed = parsed, .message = message };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Round-trip `message` through the codec and hand the decoded frame plus its
/// schema-less view to `check`. Both are freed afterwards.
fn expectRoundTrip(
    message: ipc.IpcMessage,
    context: anytype,
    comptime check: fn (@TypeOf(context), ipc.IpcMessage, Value) anyerror!void,
) !void {
    const frame = try encodeAlloc(testing.allocator, message);
    defer testing.allocator.free(frame);

    var round = try decode(testing.allocator, frame);
    defer round.deinit();

    var view = try toJsonValue(testing.allocator, frame);
    defer view.deinit();

    // `decode(encode(m)) == m` is spelled through the reference codec because
    // the decoded frames hold slices: `std.meta.eql` would compare pointers.
    const source_json = try message.encodeJsonAlloc(testing.allocator);
    defer testing.allocator.free(source_json);
    const round_json = try round.message.encodeJsonAlloc(testing.allocator);
    defer testing.allocator.free(round_json);
    try testing.expectEqualStrings(source_json, round_json);

    try check(context, round.message, view.value);
}

fn envelopeKey(view: Value) ![]const u8 {
    const object = switch (view) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };
    try testing.expectEqual(@as(usize, 1), object.count());
    return object.keys()[0];
}

fn envelopeBody(view: Value) !Value {
    const object = switch (view) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };
    try testing.expectEqual(@as(usize, 1), object.count());
    return object.values()[0];
}

test "lazily/msgpack: control frames round-trip" {
    const Check = struct {
        fn resync(_: void, message: ipc.IpcMessage, view: Value) !void {
            try testing.expectEqual(@as(u64, 12), message.ResyncRequest.from_epoch);
            try testing.expectEqualStrings("ResyncRequest", try envelopeKey(view));
        }
        fn ack(_: void, message: ipc.IpcMessage, view: Value) !void {
            try testing.expectEqual(@as(u64, 41), message.OutboxAck.through_epoch);
            try testing.expectEqualStrings("OutboxAck", try envelopeKey(view));
        }
    };
    try expectRoundTrip(ipc.IpcMessage.resyncRequest(12), {}, Check.resync);
    try expectRoundTrip(ipc.IpcMessage.outboxAck(41), {}, Check.ack);
}

test "lazily/msgpack: the NodeKey rules survive the binary codec" {
    const keyed = ipc.NodeSnapshot{
        .node = 9,
        .type_tag = "u64",
        .state = ipc.NodeState.fromPayload(&.{ 7, 8 }),
        .key = "scores/alice",
    };
    const keyless = ipc.NodeSnapshot.fromOpaque(10, "opaque-type");
    const nodes = [_]ipc.NodeSnapshot{ keyed, keyless };
    const message = ipc.IpcMessage{ .Snapshot = ipc.Snapshot.init(3, &nodes, &.{}, &.{9}) };

    const Check = struct {
        fn run(_: void, message_: ipc.IpcMessage, view: Value) !void {
            try testing.expectEqualStrings("scores/alice", message_.Snapshot.nodes[0].key.?);
            try testing.expect(message_.Snapshot.nodes[1].key == null);

            const body = try envelopeBody(view);
            const encoded_nodes = (try requiredField(body, "nodes")).array.items;
            // A self-describing codec OMITS an absent optional (protocol.md
            // § NodeKey) — that is the rule that lets a pre-`key` decoder read
            // a post-`key` frame, and it has to hold under msgpack exactly as
            // under json.
            try testing.expect(hasField(encoded_nodes[0], "key"));
            try testing.expect(!hasField(encoded_nodes[1], "key"));
            // The unit variant is a BARE STRING, never `{"Opaque": null}`.
            try testing.expectEqualStrings(
                "Opaque",
                (try requiredField(encoded_nodes[1], "state")).string,
            );
        }
    };
    try expectRoundTrip(message, {}, Check.run);
}

test "lazily/msgpack: a CrdtOp always writes key, null when unset" {
    const ops = [_]ipc.CrdtOp{.{
        .node = 1,
        .key = null,
        .stamp = .{ .wall_time = 5, .logical = 0, .peer = 1 },
        .state = ipc.IpcValue.fromInline(&.{1}),
    }};
    const frontier = [_]ipc.FrontierEntry{.{
        .peer = 1,
        .stamp = .{ .wall_time = 5, .logical = 0, .peer = 1 },
    }};
    const message = ipc.IpcMessage{ .CrdtSync = ipc.CrdtSync.init(&frontier, &ops) };

    const Check = struct {
        fn run(_: void, message_: ipc.IpcMessage, view: Value) !void {
            try testing.expect(message_.CrdtSync.ops[0].key == null);
            const body = try envelopeBody(view);
            const encoded_ops = (try requiredField(body, "ops")).array.items;
            // Unlike `NodeSnapshot`, a `CrdtOp` ALWAYS carries `key` — an
            // anti-entropy op's addressing is part of its merge identity — and
            // the decoder reads the explicit null back as absent.
            try testing.expect((try requiredField(encoded_ops[0], "key")) == .null);
            // The frontier entry is a 2-element TUPLE, not a map.
            const encoded_frontier = (try requiredField(body, "frontier")).array.items;
            try testing.expectEqual(@as(usize, 2), encoded_frontier[0].array.items.len);
        }
    };
    try expectRoundTrip(message, {}, Check.run);
}

fn requiredField(value: Value, name: []const u8) !Value {
    return switch (value) {
        .object => |o| o.get(name) orelse error.MissingField,
        else => error.ExpectedObject,
    };
}

fn hasField(value: Value, name: []const u8) bool {
    return switch (value) {
        .object => |o| o.contains(name),
        else => false,
    };
}

test "lazily/msgpack: a bin byte payload is rejected" {
    // `{"OutboxAck": {"through_epoch": <bin8 of 1 byte>}}` — well-formed
    // MessagePack, outside this wire. Accepting it would make the binding read
    // frames no conforming peer produces.
    var packer = Packer.init(testing.allocator);
    defer packer.deinit();
    try packer.mapHeader(1);
    try packer.str("OutboxAck");
    try packer.mapHeader(1);
    try packer.str("through_epoch");
    try packer.buf.appendSlice(testing.allocator, &.{ 0xc4, 0x01, 0x2a });

    try testing.expectError(Error.UnexpectedBinaryPayload, decode(testing.allocator, packer.bytes()));
}

test "lazily/msgpack: a positional frame is rejected" {
    // The shape protocol.md excludes outright: the same values as a positional
    // array. It is well-formed MessagePack and carries every field, and it is
    // not this wire.
    var packer = Packer.init(testing.allocator);
    defer packer.deinit();
    try packer.arrayHeader(2);
    try packer.str("OutboxAck");
    try packer.arrayHeader(1);
    try packer.int(41);

    try testing.expectError(error.ExpectedObject, decode(testing.allocator, packer.bytes()));
}

test "lazily/msgpack: an internally tagged frame is rejected" {
    // `{"type": 0, "value": {...}}` — the private framing protocol.md names as
    // the thing that is NOT `msgpack`. Two envelope entries, so the
    // single-field envelope check refuses it.
    var packer = Packer.init(testing.allocator);
    defer packer.deinit();
    try packer.mapHeader(2);
    try packer.str("type");
    try packer.int(4);
    try packer.str("value");
    try packer.mapHeader(1);
    try packer.str("through_epoch");
    try packer.int(41);

    try testing.expectError(error.ExpectedSingleFieldObject, decode(testing.allocator, packer.bytes()));
}

test "lazily/msgpack: truncated and trailing bytes are rejected" {
    const frame = try encodeAlloc(testing.allocator, ipc.IpcMessage.outboxAck(41));
    defer testing.allocator.free(frame);

    try testing.expectError(
        Error.TruncatedFrame,
        decode(testing.allocator, frame[0 .. frame.len - 1]),
    );

    const trailing = try std.mem.concat(testing.allocator, u8, &.{ frame, &[_]u8{0xc0} });
    defer testing.allocator.free(trailing);
    try testing.expectError(Error.TrailingBytesAfterFrame, decode(testing.allocator, trailing));
}

test "lazily/msgpack: a non-string map key is rejected" {
    var packer = Packer.init(testing.allocator);
    defer packer.deinit();
    try packer.mapHeader(1);
    try packer.int(0);
    try packer.int(1);

    try testing.expectError(Error.NonStringMapKey, decode(testing.allocator, packer.bytes()));
}

test "lazily/msgpack: every integer width survives a round trip" {
    const cases = [_]i128{
        0,                    1,                    127,
        128,                  255,                  256,
        65535,                65536,                4294967295,
        4294967296,           std.math.maxInt(i64), std.math.maxInt(u64),
        -1,                   -32,                  -33,
        -128,                 -129,                 -32768,
        -32769,               -2147483648,          -2147483649,
        std.math.minInt(i64),
    };
    for (cases) |case| {
        var packer = Packer.init(testing.allocator);
        defer packer.deinit();
        try packer.int(case);
        var up = Unpacker.init(packer.bytes());
        try testing.expectEqual(case, try up.readInt());
        try testing.expect(up.eof());
    }
}

/// A run of `n` `x` bytes. Spelled as a loop rather than with the repeat
/// operator: the three pinned toolchains disagree about the whitespace that
/// operator tolerates, and a codec test has no business being the thing that
/// breaks on it.
fn filledX(comptime n: usize) [n]u8 {
    var buf: [n]u8 = undefined;
    @memset(&buf, 'x');
    return buf;
}

test "lazily/msgpack: str widths survive a round trip" {
    const w31 = filledX(31);
    const w32 = filledX(32);
    const w255 = filledX(255);
    const w300 = filledX(300);
    const cases = [_][]const u8{ "", "k", &w31, &w32, &w255, &w300 };
    for (cases) |case| {
        var packer = Packer.init(testing.allocator);
        defer packer.deinit();
        try packer.str(case);
        var up = Unpacker.init(packer.bytes());
        try testing.expectEqualStrings(case, try up.readStr());
        try testing.expect(up.eof());
    }
}

test "lazily/msgpack: array and map headers survive their width boundaries" {
    const counts = [_]usize{ 0, 15, 16, 65535, 65536 };
    for (counts) |count| {
        var packer = Packer.init(testing.allocator);
        defer packer.deinit();
        try packer.arrayHeader(count);
        try packer.mapHeader(count);
        var up = Unpacker.init(packer.bytes());
        try testing.expectEqual(count, try up.readArrayHeader());
        try testing.expectEqual(count, try up.readMapHeader());
        try testing.expect(up.eof());
    }
}
