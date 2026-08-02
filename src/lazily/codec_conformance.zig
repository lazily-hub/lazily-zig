//! Frame-codec round-trip conformance (`#lzmsgpackparity`).
//!
//! protocol.md § Frame codecs makes `json` (the reference codec) and `msgpack`
//! (the cross-language binary default) MUST-level for every binding, and
//! requires every frame to round-trip through both for all three `IpcMessage`
//! variants. That requirement lived only in prose. The four conformance rungs —
//! was the fixture OPENED, were its keys CONSUMED, were they ASSERTED, was
//! every SCENARIO replayed — all reason about fixture *content*, and content
//! replay never exercises a codec, so a binding could carve out a MUST-level
//! codec and stay green on every rung.
//!
//! lazily-zig implements BOTH halves (`#lzmsgpackseven`). `msgpack` was a
//! carve-out here and in `interop_peer.zig`; before that it was ADVERTISED in
//! the capability handshake with no encoder behind it, which is the fail-open
//! form of the same gap.
//!
//! The runner decodes `wire`, RE-ENCODES the decoded message, decodes again,
//! and checks every `expect` key against that second decode. Asserting against
//! the fixture literal would prove nothing: the literal never passed through an
//! encoder.
//!
//! The msgpack half additionally introspects the ENCODED BYTES through
//! `msgpack.toJsonValue`. The named-field rule is a property of the ENCODING,
//! so it is invisible to every assertion over a decoded `IpcMessage`: a
//! positional encoder round-trips each value correctly and is still speaking a
//! wire no `msgpack` peer can read. `encoded_envelope_key` /
//! `encoded_body_field_names` / `first_node_encoded_field_names` /
//! `first_op_encoded_field_names` are the executable form of that rule.

const std = @import("std");
const cj = @import("conformance_json.zig");
const ipc = @import("ipc.zig");
const mp = @import("msgpack.zig");

const Value = std.json.Value;
const IpcMessage = ipc.IpcMessage;

const JSON_FIXTURE = "codec/frame_roundtrip_json.json";
const MSGPACK_FIXTURE = "codec/frame_roundtrip_msgpack.json";

fn variantOf(message: IpcMessage) []const u8 {
    return @tagName(std.meta.activeTag(message));
}

/// A `u64` list assertion. `AssertionKeys.compare` handles scalars and strings;
/// an array needs the escape hatch, and the fixture's own array must still
/// reach the comparison.
fn expectU64List(actual: []const u64, expected: Value) !void {
    const want = try cj.asArray(expected);
    try std.testing.expectEqual(want.len, actual.len);
    for (want, actual) |w, got| try std.testing.expectEqual(try cj.asU64(w), got);
}

fn expectStrList(actual: []const []const u8, expected: Value) !void {
    const want = try cj.asArray(expected);
    try std.testing.expectEqual(want.len, actual.len);
    for (want, actual) |w, got| try std.testing.expectEqualStrings(try cj.asStr(w), got);
}

const U64List = struct {
    items: []const u64,
    fn check(self: U64List, expected: Value) anyerror!void {
        return expectU64List(self.items, expected);
    }
};

const StrList = struct {
    items: []const []const u8,
    fn check(self: StrList, expected: Value) anyerror!void {
        return expectStrList(self.items, expected);
    }
};

fn assertSnapshot(keys: *cj.AssertionKeys, snap: ipc.Snapshot) !void {
    try keys.assertKey("epoch", snap.epoch);
    try keys.assertKey("node_count", snap.nodes.len);
    try keys.assertKey("edge_count", snap.edges.len);
    try keys.assertKey("root_count", snap.roots.len);
    try keys.assertKey("first_node_type_tag", snap.nodes[0].type_tag);

    const payload = snap.nodes[0].state.Payload;
    var bytes_buf: [64]u64 = undefined;
    for (payload, 0..) |b, i| bytes_buf[i] = b;
    try keys.assertKeyWith(
        "first_node_payload",
        U64List{ .items = bytes_buf[0..payload.len] },
        U64List.check,
    );

    var opaque_id: u64 = 0;
    var found = false;
    for (snap.nodes) |node| {
        if (node.state == .Opaque) {
            opaque_id = node.node;
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
    try keys.assertKey("opaque_node_id", opaque_id);
    // The externally-tagged UNIT variant is the shape most likely to decay into
    // `{"Opaque": null}` under a re-encode, so name it rather than infer it.
    try keys.assertKey("opaque_node_state_tag", "Opaque");

    const edge = [_]u64{ snap.edges[0].dependent, snap.edges[0].dependency };
    try keys.assertKeyWith("first_edge", U64List{ .items = &edge }, U64List.check);
    try keys.assertKeyWith("roots", U64List{ .items = snap.roots }, U64List.check);
}

fn assertDelta(keys: *cj.AssertionKeys, delta: ipc.Delta) !void {
    try keys.assertKey("base_epoch", delta.base_epoch);
    try keys.assertKey("epoch", delta.epoch);
    try keys.assertKey("op_count", delta.ops.len);

    var variants: [16][]const u8 = undefined;
    for (delta.ops, 0..) |op, i| variants[i] = @tagName(std.meta.activeTag(op));
    try keys.assertKeyWith(
        "op_variants",
        StrList{ .items = variants[0..delta.ops.len] },
        StrList.check,
    );

    const inline_bytes = delta.ops[0].CellSet.payload.Inline;
    var payload_buf: [64]u64 = undefined;
    for (inline_bytes, 0..) |b, i| payload_buf[i] = b;
    try keys.assertKeyWith(
        "first_op_payload",
        U64List{ .items = payload_buf[0..inline_bytes.len] },
        U64List.check,
    );

    var type_tag: []const u8 = "";
    for (delta.ops) |op| {
        if (op == .NodeAdd) {
            type_tag = op.NodeAdd.type_tag;
            break;
        }
    }
    try std.testing.expect(type_tag.len > 0);
    try keys.assertKey("node_add_type_tag", type_tag);
}

fn assertCrdtSync(keys: *cj.AssertionKeys, sync: ipc.CrdtSync) !void {
    try keys.assertKey("frontier_len", sync.frontier.len);
    try keys.assertKey("frontier_first_peer", sync.frontier[0].peer);
    try keys.assertKey("frontier_first_stamp_wall_time", sync.frontier[0].stamp.wall_time);
    try keys.assertKey("op_count", sync.ops.len);
    try keys.assertKey("first_op_node", sync.ops[0].node);
    // Decoded-value assertion, not an encoding one: both self-describing codecs
    // WRITE `key` for a CrdtOp (null when unset — an anti-entropy op's
    // addressing is part of its merge identity, and `schemas/distributed.json`
    // lists it in `required`). What must survive the round trip is that the
    // decoder reads that null back as absent.
    try keys.assertKey("first_op_key_absent", sync.ops[0].key == null);
    try keys.assertKey("second_op_node", sync.ops[1].node);
    try keys.assertKey("second_op_key", sync.ops[1].key.?);
    try keys.assertKey("second_op_stamp_peer", sync.ops[1].stamp.peer);
}

fn assertValues(keys: *cj.AssertionKeys, message: IpcMessage) !void {
    return switch (message) {
        .Snapshot => |snap| assertSnapshot(keys, snap),
        .Delta => |delta| assertDelta(keys, delta),
        .CrdtSync => |sync| assertCrdtSync(keys, sync),
        else => error.UnsupportedCodecFixtureVariant,
    };
}

test "lazily/codec: json frames round-trip through the reference codec" {
    var fixture = (try cj.load(JSON_FIXTURE)) orelse return;
    defer fixture.deinit();
    const root = fixture.value;

    try std.testing.expectEqual(@as(u64, 1), try cj.asU64(try cj.required(root, "protocol_version")));
    try std.testing.expectEqualStrings("FrameCodecRoundTrip", try cj.asStr(try cj.required(root, "kind")));
    try std.testing.expectEqualStrings("json", try cj.asStr(try cj.required(root, "codec")));

    // The fixture-level block pins the codec's identity and the two distinct
    // senses of "canonical" protocol.md keeps apart (`role` = the required
    // interop floor, `byte_canonical` = one deterministic byte form per
    // message).
    var meta = cj.AssertionKeys.init(JSON_FIXTURE ++ " assertions", try cj.required(root, "assertions"));
    try meta.assertKey("codec", "json");
    try meta.assertKey("self_describing", true);
    try meta.assertKey("byte_canonical", true);
    try meta.assertKey("required_of_binding", "MUST");
    try meta.assertKey("role", "reference");
    try meta.assertKey("scenario_count", (try cj.asArray(try cj.required(root, "scenarios"))).len);
    try meta.finish();

    var scenarios = try cj.scenarios(JSON_FIXTURE, root);
    var replayed: usize = 0;
    while (scenarios.next()) |scenario| {
        // Record at the point of replay (`#lzscenariocoverage`): a scenario this
        // loop stops reaching stops being recorded.
        _ = try scenarios.replaying();
        const wire_json = try std.json.Stringify.valueAlloc(
            std.testing.allocator,
            try cj.required(scenario, "wire"),
            .{},
        );
        defer std.testing.allocator.free(wire_json);

        var source = try IpcMessage.decodeJson(std.testing.allocator, wire_json);
        defer source.deinit();
        try std.testing.expectEqualStrings(
            try cj.asStr(try cj.required(scenario, "variant")),
            variantOf(source.message),
        );

        // Encode the DECODED message and decode the result. The fixture literal
        // is never re-asserted, so a codec that silently drops a field cannot
        // be masked by reading the input back.
        const encoded = try source.message.encodeJsonAlloc(std.testing.allocator);
        defer std.testing.allocator.free(encoded);
        var round = try IpcMessage.decodeJson(std.testing.allocator, encoded);
        defer round.deinit();

        const reencoded = try round.message.encodeJsonAlloc(std.testing.allocator);
        defer std.testing.allocator.free(reencoded);

        var keys = cj.AssertionKeys.init(JSON_FIXTURE, try cj.required(scenario, "expect"));
        // Structural equality via the canonical re-serialization: zig's decoded
        // frames hold slices, so `std.meta.eql` compares pointers rather than
        // contents. Both strings come from the SAME encoder, so this is a
        // round-trip claim, not a byte-canonicality claim about the codec.
        try keys.assertKey("round_trip_equals_source", std.mem.eql(u8, encoded, reencoded));
        try assertValues(&keys, round.message);
        try keys.finish();
        replayed += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), replayed);
}

// ---------------------------------------------------------------------------
// msgpack — the cross-language binary default
// ---------------------------------------------------------------------------

/// No frame body, node, or op in the corpus carries more fields than this.
const MAX_ENCODED_FIELDS = 32;

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The field names of an encoded map, SORTED. A MessagePack map's key order is
/// encoder-defined (§ Frame codecs, "not byte-canonical"), so the fixture's
/// lists are sorted and a runner MUST sort before comparing. Comparing in
/// encounter order would pin this encoder's emission order as if it were the
/// wire, which is exactly the property the spec says peers may not rely on.
fn sortedFieldNames(value: Value, buf: [][]const u8) ![][]const u8 {
    const object = switch (value) {
        .object => |o| o,
        else => return error.ExpectedNamedFieldMap,
    };
    if (object.count() > buf.len) return error.TooManyEncodedFields;
    const out = buf[0..object.count()];
    for (object.keys(), out) |name, *slot| slot.* = name;
    std.mem.sort([]const u8, out, {}, lessThanName);
    return out;
}

const Envelope = struct { key: []const u8, body: Value };

/// The externally tagged envelope: exactly ONE entry, keyed by the variant
/// NAME. An internally tagged `{"type": 0, "value": …}` frame has two entries
/// and dies here.
fn envelopeOf(view: Value) !Envelope {
    const object = switch (view) {
        .object => |o| o,
        else => return error.ExpectedExternallyTaggedEnvelope,
    };
    if (object.count() != 1) return error.ExpectedExternallyTaggedEnvelope;
    return .{ .key = object.keys()[0], .body = object.values()[0] };
}

fn encodedField(value: Value, name: []const u8) !Value {
    return switch (value) {
        .object => |o| o.get(name) orelse error.MissingEncodedField,
        else => error.ExpectedNamedFieldMap,
    };
}

fn encodedElements(value: Value, name: []const u8) ![]const Value {
    return switch (try encodedField(value, name)) {
        .array => |a| a.items,
        else => error.ExpectedArray,
    };
}

test "lazily/codec: msgpack frames round-trip through the cross-language binary default" {
    var fixture = (try cj.load(MSGPACK_FIXTURE)) orelse return;
    defer fixture.deinit();
    const root = fixture.value;

    try std.testing.expectEqual(@as(u64, 1), try cj.asU64(try cj.required(root, "protocol_version")));
    try std.testing.expectEqualStrings("FrameCodecRoundTrip", try cj.asStr(try cj.required(root, "kind")));
    try std.testing.expectEqualStrings("msgpack", try cj.asStr(try cj.required(root, "codec")));

    // `byte_canonical: false` is why this fixture pins decoded values and
    // sorted field-name lists instead of golden bytes, and `role` is the other
    // sense of "canonical" protocol.md keeps apart: msgpack is the required
    // efficient transport, never the reference codec.
    var meta = cj.AssertionKeys.init(MSGPACK_FIXTURE ++ " assertions", try cj.required(root, "assertions"));
    try meta.assertKey("codec", "msgpack");
    try meta.assertKey("self_describing", true);
    try meta.assertKey("byte_canonical", false);
    try meta.assertKey("required_of_binding", "MUST");
    try meta.assertKey("role", "cross_language_binary_default");
    try meta.assertKey("scenario_count", (try cj.asArray(try cj.required(root, "scenarios"))).len);
    try meta.finish();

    var scenarios = try cj.scenarios(MSGPACK_FIXTURE, root);
    var replayed: usize = 0;
    while (scenarios.next()) |scenario| {
        _ = try scenarios.replaying();

        // `wire` is the REFERENCE json form — the fixture's two halves carry
        // byte-identical `wire` blocks on purpose, so the msgpack half starts
        // from the same value and differs only in the serialization under test.
        const wire_json = try std.json.Stringify.valueAlloc(
            std.testing.allocator,
            try cj.required(scenario, "wire"),
            .{},
        );
        defer std.testing.allocator.free(wire_json);

        var source = try IpcMessage.decodeJson(std.testing.allocator, wire_json);
        defer source.deinit();
        try std.testing.expectEqualStrings(
            try cj.asStr(try cj.required(scenario, "variant")),
            variantOf(source.message),
        );

        // ENCODE the decoded message to msgpack, DECODE those bytes back, and
        // assert against THAT. The fixture literal never passed through this
        // codec, so asserting on it would prove nothing about the codec.
        const frame = try mp.encodeAlloc(std.testing.allocator, source.message);
        defer std.testing.allocator.free(frame);
        var round = try mp.decode(std.testing.allocator, frame);
        defer round.deinit();

        const reframe = try mp.encodeAlloc(std.testing.allocator, round.message);
        defer std.testing.allocator.free(reframe);

        // Schema-less view of the ENCODED BYTES. Everything below it is
        // invisible to an assertion over the decoded message.
        var view = try mp.toJsonValue(std.testing.allocator, frame);
        defer view.deinit();
        const envelope = try envelopeOf(view.value);

        var body_names: [MAX_ENCODED_FIELDS][]const u8 = undefined;
        var first_names: [MAX_ENCODED_FIELDS][]const u8 = undefined;
        var second_names: [MAX_ENCODED_FIELDS][]const u8 = undefined;

        var keys = cj.AssertionKeys.init(MSGPACK_FIXTURE, try cj.required(scenario, "expect"));
        // Both frames come from the SAME encoder, so this is a round-trip
        // claim, not a byte-canonicality claim about the codec — protocol.md
        // permits two conforming bindings to emit byte-different msgpack for
        // one `IpcMessage`.
        try keys.assertKey("round_trip_equals_source", std.mem.eql(u8, frame, reframe));
        try keys.assertKey("encoded_envelope_key", envelope.key);
        try keys.assertKeyWith(
            "encoded_body_field_names",
            StrList{ .items = try sortedFieldNames(envelope.body, &body_names) },
            StrList.check,
        );

        switch (round.message) {
            .Snapshot => {
                const nodes = try encodedElements(envelope.body, "nodes");
                // Carries NO `key`: `NodeSnapshot.key` is absent here and a
                // self-describing codec OMITS an absent optional
                // (protocol.md § NodeKey). That is the rule that lets a
                // pre-`key` decoder read a post-`key` frame, and named-field
                // encoding is what keeps it identical to the json half.
                try keys.assertKeyWith(
                    "first_node_encoded_field_names",
                    StrList{ .items = try sortedFieldNames(nodes[0], &first_names) },
                    StrList.check,
                );
            },
            .CrdtSync => {
                const ops = try encodedElements(envelope.body, "ops");
                // Both lists DO carry `key`: a `CrdtOp` always writes it, null
                // when unset, because an anti-entropy op's addressing is part
                // of its merge identity. The keyless op's absence is asserted
                // on the DECODED value instead (`first_op_key_absent`).
                try keys.assertKeyWith(
                    "first_op_encoded_field_names",
                    StrList{ .items = try sortedFieldNames(ops[0], &first_names) },
                    StrList.check,
                );
                try keys.assertKeyWith(
                    "second_op_encoded_field_names",
                    StrList{ .items = try sortedFieldNames(ops[1], &second_names) },
                    StrList.check,
                );
            },
            else => {},
        }

        try assertValues(&keys, round.message);
        try keys.finish();
        replayed += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), replayed);
}
