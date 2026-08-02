//! `NodeId` exact-representation bound (`#lzspecdecoderbound`).
//!
//! protocol.md § NodeId / PeerId stated the 2^53 bound as a PRODUCER obligation
//! and said nothing about what a decoder does when it receives a violation.
//! That left the receiving half undefined, which is exactly where the bindings
//! diverged. The clause is now normative: a decoder that cannot represent a
//! received identifier exactly MUST reject the frame rather than round it.
//!
//! lazily-zig is one of the three bindings that never has to refuse: `NodeId`
//! is a `u64`, and `std.json` hands an integer that overflows `i64` back as
//! `.number_string` rather than as a rounded float, so `asU64` re-parses the
//! literal text and the full u64 range — `u64::MAX` included — decodes exactly.
//! This runner therefore asserts the `exact` branch for all six scenarios,
//! which makes it a *floor*: a scenario that turns out to be rejectable here
//! means the fixture is wrong about the wire rather than about any decoder.
//!
//! The fixture carries its wire frames as raw text (json) and hex (msgpack),
//! and its expected identifier as a decimal STRING. Zig would not round a bare
//! 9007199254740993 while loading the file, but the contract is uniform across
//! the nine bindings on purpose: the double-backed ones would, and a fixture
//! that reads differently per runtime is not one fixture.

const std = @import("std");
const cj = @import("conformance_json.zig");
const ipc = @import("ipc.zig");
const mp = @import("msgpack.zig");

const Value = std.json.Value;
const IpcMessage = ipc.IpcMessage;

const FIXTURE = "codec/nodeid_exact_range.json";

fn hexToBytes(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.OddLengthHexString;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    for (out, 0..) |*byte, i| {
        byte.* = try std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16);
    }
    return out;
}

/// Decode a scenario's wire frame with the codec it names.
///
/// lazily-zig never refuses anything in this corpus, so a decode error here is
/// a real failure rather than the `exact_or_reject` branch.
fn decodeScenario(allocator: std.mem.Allocator, scenario: Value) !ipc.ParsedMessage {
    const codec = try cj.asStr(try cj.required(scenario, "codec"));
    if (std.mem.eql(u8, codec, "json")) {
        // The raw TEXT through the codec's own entry point, so the parse that
        // would round on a narrower runtime is inside the code under test.
        return IpcMessage.decodeJson(allocator, try cj.asStr(try cj.required(scenario, "wire_json")));
    }
    if (std.mem.eql(u8, codec, "msgpack")) {
        const frame = try hexToBytes(allocator, try cj.asStr(try cj.required(scenario, "wire_msgpack_hex")));
        defer allocator.free(frame);
        return mp.decode(allocator, frame);
    }
    return error.UnknownCodec;
}

const U8List = struct { items: []const u8 };

fn checkU8List(context: U8List, expected: Value) anyerror!void {
    const want = try cj.asArray(expected);
    try std.testing.expectEqual(want.len, context.items.len);
    for (want, context.items) |w, got| try std.testing.expectEqual(try cj.asU64(w), @as(u64, got));
}

/// `outcome` is the corpus-wide statement of what a decoder may do. lazily-zig
/// reads it as a constraint on the FIXTURE: both branches oblige it to decode,
/// because a u64 covers the whole wire range.
fn checkOutcome(_: void, expected: Value) anyerror!void {
    const outcome = try cj.asStr(expected);
    if (!std.mem.eql(u8, outcome, "exact") and !std.mem.eql(u8, outcome, "exact_or_reject")) {
        return error.UnknownOutcome;
    }
}

fn checkCodecs(_: void, expected: Value) anyerror!void {
    const want = try cj.asArray(expected);
    try std.testing.expectEqual(@as(usize, 2), want.len);
    try std.testing.expectEqualStrings("json", try cj.asStr(want[0]));
    try std.testing.expectEqualStrings("msgpack", try cj.asStr(want[1]));
}

test "lazily/codec: NodeId exact-representation bound is enforced by refusal, never rounding" {
    var fixture = (try cj.load(FIXTURE)) orelse return;
    defer fixture.deinit();
    const root = fixture.value;

    try std.testing.expectEqual(@as(u64, 1), try cj.asU64(try cj.required(root, "protocol_version")));
    try std.testing.expectEqualStrings("NodeIdExactRange", try cj.asStr(try cj.required(root, "kind")));

    var meta = cj.AssertionKeys.init(FIXTURE ++ " assertions", try cj.required(root, "assertions"));
    try meta.assertKey("required_of_binding", "MUST");
    try meta.assertKey("scenario_count", (try cj.asArray(try cj.required(root, "scenarios"))).len);
    try meta.assertKeyWith("codecs", {}, checkCodecs);
    for ([_][]const u8{ "clause", "wire_encoding", "outcomes", "anti_vacuity", "generator" }) |prose| {
        try meta.excuseKey(
            prose,
            "prose: it states WHY the fixture is shaped this way; the behaviour it " ++
                "describes is asserted by the per-scenario decode below",
        );
    }
    try meta.finish();

    // Anti-vacuity. `exact_or_reject` is satisfied by a runner that decodes
    // nothing, so the count of scenarios this run actually ACCEPTED is the
    // assertion that the decoder ran at all. lazily-zig covers the whole
    // corpus, so the expected value is every scenario — anything less is a
    // narrowing of the binding, not of the test.
    var accepted: usize = 0;

    var scenarios = try cj.scenarios(FIXTURE, root);
    while (scenarios.next()) |scenario| {
        // Record at the point of replay (`#lzscenariocoverage`): a scenario
        // this loop stops reaching stops being recorded.
        _ = try scenarios.replaying();

        const expect = try cj.required(scenario, "expect");
        const decimal = try cj.asStr(try cj.required(expect, "node_id_decimal"));
        const expected = try std.fmt.parseInt(u64, decimal, 10);

        var parsed = try decodeScenario(std.testing.allocator, scenario);
        defer parsed.deinit();
        accepted += 1;

        const snapshot = switch (parsed.message) {
            .Snapshot => |s| s,
            else => return error.ExpectedSnapshotVariant,
        };
        try std.testing.expectEqualStrings("Snapshot", try cj.asStr(try cj.required(scenario, "variant")));

        var keys = cj.AssertionKeys.init(FIXTURE, expect);
        try keys.assertKeyWith("outcome", {}, checkOutcome);
        try keys.assertKey("epoch", snapshot.epoch);
        try keys.assertKey("node_count", snapshot.nodes.len);

        const node = snapshot.nodes[0];
        // The discriminating assertion. A rounding or wrapping decoder yields a
        // NEIGHBOURING identifier that still decodes cleanly and addresses a
        // different node, so the exact comparison is the only check that sees
        // the substitution.
        try std.testing.expectEqual(expected, node.node);

        var node_decimal_buf: [24]u8 = undefined;
        const node_decimal = try std.fmt.bufPrint(&node_decimal_buf, "{d}", .{node.node});
        try keys.assertKey("node_id_decimal", node_decimal);
        try keys.assertKey("type_tag", node.type_tag);
        const payload = switch (node.state) {
            .Payload => |bytes| bytes,
            else => return error.ExpectedPayloadNodeState,
        };
        try keys.assertKeyWith("payload", U8List{ .items = payload }, checkU8List);
        try std.testing.expectEqual(@as(usize, 1), snapshot.roots.len);
        var root_decimal_buf: [24]u8 = undefined;
        const root_decimal = try std.fmt.bufPrint(&root_decimal_buf, "{d}", .{snapshot.roots[0]});
        try keys.assertKey("root_id_decimal", root_decimal);
        try keys.finish();
    }

    try std.testing.expectEqual(@as(usize, 6), accepted);
}
