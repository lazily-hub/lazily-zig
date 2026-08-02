//! `NodeKey` null-leniency on decode (`#lzkeynullstrict`).
//!
//! protocol.md § NodeKey said a self-describing codec OMITS an absent `key`,
//! and that a decoder seeing no `key` field treats it as absent. That settled
//! the omitted form and left an explicit `key: null` undefined — and three
//! bindings diverged there. The clause is now explicit: omit-when-absent binds
//! the ENCODER, and a decoder MUST accept both forms as absent, refusing
//! neither and constructing a key from neither.
//!
//! lazily-zig was one of the three that REFUSED. `NodeSnapshot.fromJson` read
//! `if (objectGet(value, "key")) |k| try asString(k) else null`, which sees the
//! JSON null as a present-but-non-string field and returns
//! `error.ExpectedString` — making this binding stricter than the reference
//! implementation on a frame the reference implementation produces. Note where
//! it was already right: `CrdtOp.fromJson`, in the same file, switched on
//! `.null` explicitly, because a `CrdtOp` ALWAYS writes `key: null` when unset.
//! All three sites now share `keyFieldOrNull`.
//!
//! The runner checks both halves. Reading the null form as absent is only half
//! the rule — a binding that writes it straight back out has a correct decoded
//! value and a non-conforming encoder — so each scenario re-encodes under its
//! own codec and inspects the produced frame's field set.

const std = @import("std");
const cj = @import("conformance_json.zig");
const ipc = @import("ipc.zig");
const mp = @import("msgpack.zig");

const Value = std.json.Value;
const IpcMessage = ipc.IpcMessage;

const FIXTURE = "codec/nodekey_null_leniency.json";

fn hexToBytes(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.OddLengthHexString;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    for (out, 0..) |*byte, i| {
        byte.* = try std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16);
    }
    return out;
}

fn decodeScenario(allocator: std.mem.Allocator, scenario: Value) !ipc.ParsedMessage {
    const codec = try cj.asStr(try cj.required(scenario, "codec"));
    if (std.mem.eql(u8, codec, "json")) {
        return IpcMessage.decodeJson(allocator, try cj.asStr(try cj.required(scenario, "wire_json")));
    }
    if (std.mem.eql(u8, codec, "msgpack")) {
        const frame = try hexToBytes(allocator, try cj.asStr(try cj.required(scenario, "wire_msgpack_hex")));
        defer allocator.free(frame);
        return mp.decode(allocator, frame);
    }
    return error.UnknownCodec;
}

/// Re-encode under the scenario's own codec and read the field set back
/// SCHEMA-LESSLY. The typed `?[]const u8` cannot tell "field absent" from
/// "field present and null", which is the whole distinction under test.
fn reencodedNode(
    allocator: std.mem.Allocator,
    scenario: Value,
    message: IpcMessage,
) !std.json.Parsed(Value) {
    const codec = try cj.asStr(try cj.required(scenario, "codec"));
    if (std.mem.eql(u8, codec, "msgpack")) {
        // Through the msgpack encoder specifically: the `#lzmsgpackparity`
        // defect was a msgpack encoder writing `key: null` while json omitted
        // it, so asserting the json output for both would miss that class.
        const frame = try mp.encodeAlloc(allocator, message);
        defer allocator.free(frame);
        return mp.toJsonValue(allocator, frame);
    }
    const encoded = try message.encodeJsonAlloc(allocator);
    defer allocator.free(encoded);
    return std.json.parseFromSlice(Value, allocator, encoded, .{});
}

fn nodeOf(scenario: Value, frame: Value) !Value {
    const field = try cj.asStr(try cj.required(scenario, "field"));
    if (std.mem.eql(u8, field, "snapshot")) {
        const body = try cj.required(frame, "Snapshot");
        return (try cj.asArray(try cj.required(body, "nodes")))[0];
    }
    const body = try cj.required(frame, "Delta");
    const op = (try cj.asArray(try cj.required(body, "ops")))[0];
    return try cj.required(op, "NodeAdd");
}

const Bytes = struct { items: []const u8 };

fn checkPayload(context: Bytes, expected: Value) anyerror!void {
    const want = try cj.asArray(expected);
    try std.testing.expectEqual(want.len, context.items.len);
    for (want, context.items) |w, got| try std.testing.expectEqual(try cj.asU64(w), @as(u64, got));
}

const OptStr = struct { value: ?[]const u8 };

fn checkDecodedKey(context: OptStr, expected: Value) anyerror!void {
    switch (expected) {
        .null => try std.testing.expect(context.value == null),
        else => {
            try std.testing.expect(context.value != null);
            try std.testing.expectEqualStrings(try cj.asStr(expected), context.value.?);
        },
    }
}

fn checkStrList(context: []const []const u8, expected: Value) anyerror!void {
    const want = try cj.asArray(expected);
    try std.testing.expectEqual(want.len, context.len);
    for (want, context) |w, got| try std.testing.expectEqualStrings(try cj.asStr(w), got);
}

test "lazily/codec: NodeKey null-leniency — both wire forms decode as absent, the encoder still omits" {
    var fixture = (try cj.load(FIXTURE)) orelse return;
    defer fixture.deinit();
    const root = fixture.value;

    try std.testing.expectEqual(@as(u64, 1), try cj.asU64(try cj.required(root, "protocol_version")));
    try std.testing.expectEqualStrings(
        "NodeKeyNullLeniency",
        try cj.asStr(try cj.required(root, "kind")),
    );

    const scenarios_array = try cj.asArray(try cj.required(root, "scenarios"));

    var meta = cj.AssertionKeys.init(FIXTURE ++ " assertions", try cj.required(root, "assertions"));
    try meta.assertKey("required_of_binding", "MUST");
    try meta.assertKey("scenario_count", scenarios_array.len);
    try meta.assertKeyWith("codecs", @as([]const []const u8, &.{ "json", "msgpack" }), checkStrList);
    try meta.assertKeyWith("fields", @as([]const []const u8, &.{ "snapshot", "node_add" }), checkStrList);
    try meta.assertKeyWith(
        "key_forms",
        @as([]const []const u8, &.{ "omitted", "null", "present" }),
        checkStrList,
    );
    for ([_][]const u8{ "clause", "wire_encoding", "reencode_obligation", "anti_vacuity", "generator" }) |prose| {
        try meta.excuseKey(
            prose,
            "prose: it states WHY the fixture is shaped this way; the behaviour it " ++
                "describes is asserted by the per-scenario decode and re-encode below",
        );
    }
    try meta.finish();

    // Anti-vacuity in both directions. A runner that never decodes reports
    // "absent" for everything and satisfies all eight omitted/null scenarios;
    // the `present` count is what only a real decode can produce.
    var replayed: usize = 0;
    var keys_decoded: usize = 0;

    var scenarios = try cj.scenarios(FIXTURE, root);
    while (scenarios.next()) |scenario| {
        _ = try scenarios.replaying();
        replayed += 1;

        const expect = try cj.required(scenario, "expect");
        const field = try cj.asStr(try cj.required(scenario, "field"));

        var parsed = try decodeScenario(std.testing.allocator, scenario);
        defer parsed.deinit();

        const key: ?[]const u8 = if (std.mem.eql(u8, field, "snapshot"))
            parsed.message.Snapshot.nodes[0].key
        else switch (parsed.message.Delta.ops[0]) {
            .NodeAdd => |op| op.key,
            else => return error.ExpectedNodeAddOp,
        };
        if (key != null) keys_decoded += 1;

        var keys = cj.AssertionKeys.init(FIXTURE, expect);
        // The decode half: omitted and explicit-null must both arrive absent.
        try keys.assertKeyWith("decoded_key", OptStr{ .value = key }, checkDecodedKey);

        var reencoded = try reencodedNode(std.testing.allocator, scenario, parsed.message);
        defer reencoded.deinit();
        const node = try nodeOf(scenario, reencoded.value);

        // The encode half, which no assertion over the decoded value reaches.
        const encoded_key = node.object.get("key");
        const present = encoded_key != null and encoded_key.? != .null;
        try keys.assertKey("reencoded_key_field_present", present);

        try keys.assertKey("node", try cj.asU64(try cj.required(node, "node")));
        try keys.assertKey("type_tag", try cj.asStr(try cj.required(node, "type_tag")));
        const payload = try cj.asArray(try cj.required(try cj.required(node, "state"), "Payload"));
        var payload_bytes: [8]u8 = undefined;
        for (payload, 0..) |item, i| payload_bytes[i] = @intCast(try cj.asU64(item));
        try keys.assertKeyWith("payload", Bytes{ .items = payload_bytes[0..payload.len] }, checkPayload);
        try keys.assertKey("epoch", switch (parsed.message) {
            .Snapshot => |s| s.epoch,
            .Delta => |d| d.epoch,
            else => return error.UnexpectedVariant,
        });
        try keys.finish();
    }

    try std.testing.expectEqual(@as(usize, 12), replayed);
    try std.testing.expectEqual(@as(usize, 4), keys_decoded);
}
