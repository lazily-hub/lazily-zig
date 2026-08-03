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
//!
//! The four PARAGRAPHS in `assertions` are discharged, not excused
//! (`#lzprosekeyconvention`): each names the executable keys this run asserts,
//! and `verifyProse` refuses the run when a named key never reached a
//! comparison. `fields` and `key_forms` moved with them, from a comparison
//! against a hardcoded copy of the declaration to declared-against-OBSERVED —
//! a discharge naming a key that only proves the fixture agrees with its own
//! transcription would be true and worthless.
//!
//! `scenario_count` and `codecs` were left behind by that sweep and are fixed
//! here (`#lznullformblind`): the first compared the fixture's declared count to
//! `root.scenarios.len`, the second compared `assertions.codecs` to a
//! hand-written `&.{"json","msgpack"}`. Both stayed green over a runner that
//! decoded nothing. They now read the scenarios this run replayed to completion
//! and the decoder branches this run actually fed, which is why `wire_encoding`
//! and `anti_vacuity` can cite `codecs` at all.
//!
//! The raw-wire `key` classifier gets a SECOND WITNESS in the same pass. Its
//! json arm reads through `std.json`, which is the standard library and shares
//! nothing with this binding's codec, but its msgpack arm went through
//! `mp.toJsonValue` — this binding's own unpacker — so an unpacker defect would
//! have corrupted the control and the thing controlled together. `msgpackKeyForm`
//! reads the same slot out of the raw bytes (`a3 6b 65 79`, then `0xc0` for nil)
//! and must agree; `byte_witnessed` is counted so a witness that never runs
//! cannot agree with everything by silence.

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

/// Decode the scenario's wire form THROUGH the codec it names, banking the
/// codec path that actually ran.
///
/// `observed` is written INSIDE the matched branch, immediately before the wire
/// reaches that decoder (`#lznullformblind`), so the `codecs` assertion after
/// the loop records which decoders were fed rather than reading the scenario's
/// own `codec` label back to the fixture. A runner that replays nothing banks an
/// empty set and reddens.
fn decodeScenario(
    allocator: std.mem.Allocator,
    scenario: Value,
    keys: *cj.AssertionKeys,
    observed: *StrSet,
) !ipc.ParsedMessage {
    const codec = try cj.asStr(try cj.required(scenario, "codec"));
    if (std.mem.eql(u8, codec, "json")) {
        const wire = try cj.asStr(try cj.required(scenario, "wire_json"));
        var digest: [16]u8 = undefined;
        try keys.assertKey("wire_input_fnv1a64", cj.wireInputFnv1a64Hex(wire, &digest));
        observed.add("json");
        return IpcMessage.decodeJson(allocator, wire);
    }
    if (std.mem.eql(u8, codec, "msgpack")) {
        const frame = try hexToBytes(allocator, try cj.asStr(try cj.required(scenario, "wire_msgpack_hex")));
        defer allocator.free(frame);
        var digest: [16]u8 = undefined;
        try keys.assertKey("wire_input_fnv1a64", cj.wireInputFnv1a64Hex(frame, &digest));
        observed.add("msgpack");
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

/// The scenario's wire frame as a schema-less `Value`, WITHOUT the typed
/// decoder.
///
/// This is the control `wire_encoding` needs, and without it that paragraph is
/// dischargeable by NOTHING in this fixture (`#lzprosekeyconvention`). Its
/// obligation is that the ABSENT and explicit-`null` wire forms stay tellable
/// apart on their way into the runner — and the decoder collapses them by
/// design, which is the clause. Every key in the `expect` blocks is therefore
/// identical for the `omitted` and `null` families: same `decoded_key` (null),
/// same `reencoded_key_field_present` (false), same node, tag, payload, epoch.
/// The four `null` scenarios would be the four `omitted` ones wearing a
/// different id. Reading the raw slot before the decoder runs is the only place
/// the difference exists.
fn rawWire(allocator: std.mem.Allocator, scenario: Value) !std.json.Parsed(Value) {
    const codec = try cj.asStr(try cj.required(scenario, "codec"));
    if (std.mem.eql(u8, codec, "msgpack")) {
        const frame = try hexToBytes(allocator, try cj.asStr(try cj.required(scenario, "wire_msgpack_hex")));
        defer allocator.free(frame);
        return mp.toJsonValue(allocator, frame);
    }
    return std.json.parseFromSlice(
        Value,
        allocator,
        try cj.asStr(try cj.required(scenario, "wire_json")),
        .{ .allocate = .alloc_always },
    );
}

/// The `key` slot's WIRE form, read off the raw frame. The fixture's own
/// vocabulary: `omitted` (no map entry) / `null` (explicit nil) / `present`.
fn wireKeyForm(scenario: Value, frame: Value) ![]const u8 {
    const node = try nodeOf(scenario, frame);
    const entry = cj.field(node, "key") orelse return "omitted";
    return switch (entry) {
        .null => "null",
        else => "present",
    };
}

/// A SECOND witness for the msgpack `key` slot, read at the BYTE level.
///
/// `rawWire` is decoder-independent for json — `std.json.parseFromSlice` is the
/// standard library, not this binding's codec — but its msgpack arm goes through
/// `mp.toJsonValue`, this binding's own unpacker. A defect there would corrupt
/// the control and the thing controlled TOGETHER, which is the one way
/// `wireKeyForm` could agree with a wrong answer.
///
/// This reads the frame as bytes instead. `a3 6b 65 79` is the MessagePack
/// fixstr for `"key"`, and the byte immediately after it is the slot's value:
/// `0xc0` is nil, `0xa0..0xbf` a fixstr. No occurrence at all is the omitted
/// form. The marker must be UNIQUE in the frame or the read is ambiguous, so a
/// second occurrence is an error rather than a first-match guess.
fn msgpackKeyForm(frame: []const u8) ![]const u8 {
    const marker = [_]u8{ 0xa3, 'k', 'e', 'y' };
    const at = std.mem.indexOf(u8, frame, &marker) orelse return "omitted";
    if (std.mem.indexOf(u8, frame[at + marker.len ..], &marker) != null) {
        return error.AmbiguousKeyMarkerInFrame;
    }
    if (at + marker.len >= frame.len) return error.TruncatedKeySlot;
    const value = frame[at + marker.len];
    if (value == 0xc0) return "null";
    if (value >= 0xa0 and value <= 0xbf) return "present";
    // str8/str16/str32 would still be a present key, but nothing in this corpus
    // carries one — say so loudly rather than widen the classifier on a guess.
    return error.UnclassifiableKeySlotByte;
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

/// A small deduplicating set of borrowed strings, for the declared-vs-OBSERVED
/// vocabulary checks.
const StrSet = struct {
    items: [8][]const u8 = undefined,
    len: usize = 0,

    fn add(self: *StrSet, s: []const u8) void {
        if (self.has(s)) return;
        if (self.len == self.items.len) @panic("StrSet capacity exceeded");
        self.items[self.len] = s;
        self.len += 1;
    }

    fn has(self: *const StrSet, s: []const u8) bool {
        for (self.items[0..self.len]) |item| {
            if (std.mem.eql(u8, item, s)) return true;
        }
        return false;
    }
};

/// Every value the fixture DECLARES was actually OBSERVED by this run, and
/// nothing else was.
///
/// The shape a hardcoded transcription cannot substitute for: comparing
/// `key_forms` against a literal `&.{"omitted","null","present"}` proves the
/// fixture agrees with this runner's copy of the fixture. It says nothing about
/// which forms a scenario actually pushed through the decoder — which is exactly
/// what `clause` and `anti_vacuity` are discharged by below. `codecs` joined
/// them under `#lznullformblind` for the same reason.
fn checkDeclaredWereObserved(observed: *const StrSet, expected: Value) anyerror!void {
    const want = try cj.asArray(expected);
    for (want) |w| {
        const name = try cj.asStr(w);
        if (!observed.has(name)) {
            std.debug.print(
                "{s}: '{s}' is declared but no scenario in this run observed it\n",
                .{ FIXTURE, name },
            );
            return error.DeclaredValueNeverObserved;
        }
    }
    if (want.len != observed.len) {
        std.debug.print(
            "{s}: this run observed {d} distinct values against {d} declared\n",
            .{ FIXTURE, observed.len, want.len },
        );
        return error.ObservedValueNotDeclared;
    }
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

    // The fixture-scoped prose ledger (`#lzprosekeyconvention`). The paragraphs
    // are discharged after the loop, because every key they name is asserted in a
    // per-scenario `expect` block.
    var prose = cj.ProseLedger.init(FIXTURE);
    defer prose.deinit();
    errdefer prose.disarm();

    var meta = cj.AssertionKeys.init(FIXTURE ++ " assertions", try cj.required(root, "assertions"));
    try meta.trackProse(&prose);
    try meta.assertKey("required_of_binding", "MUST");
    try meta.excuseKey(
        "generator",
        "names the lazily-spec script that emits this fixture. It is a fact about the " ++
            "CORPUS's build, not about this binding, so there is nothing here to compare " ++
            "it against — lazily-spec's own regeneration check owns it",
    );
    // `scenario_count`, `codecs`, `fields` and `key_forms` are all asserted
    // AFTER the loop, against what this run actually observed, so `meta` stays
    // open until then. `scenario_count` used to read `scenarios_array.len` and
    // `codecs` a hand-written `&.{"json","msgpack"}` — the fixture compared to a
    // copy of itself, green over a runner that decodes nothing
    // (`#lznullformblind`).

    // Anti-vacuity in both directions. A runner that never decodes reports
    // "absent" for everything and satisfies all eight omitted/null scenarios;
    // the `present` count is what only a real decode can produce.
    var replayed: usize = 0;
    var keys_decoded: usize = 0;
    // How many frames the decoder-INDEPENDENT byte scan classified. A witness
    // that never runs agrees with everything, so it is counted too.
    var byte_witnessed: usize = 0;

    // Declared-vs-OBSERVED vocabularies, checked after the loop.
    var observed_fields: StrSet = .{};
    var observed_key_forms: StrSet = .{};
    // Banked inside `decodeScenario`, at the branch that feeds each decoder.
    var observed_codecs: StrSet = .{};

    var scenarios = try cj.scenarios(FIXTURE, root);
    while (scenarios.next()) |sc| {
        // Rung 4 books on the PAYLOAD handoff (#lzscenariobodyskip), so a
        // body that stops short of replaying stops being booked.
        const scenario = try sc.replay();

        const expect = try cj.required(scenario, "expect");
        const field = try cj.asStr(try cj.required(scenario, "field"));
        observed_fields.add(field);

        // The wire-form control. `key_form` is a LABEL; what makes the omitted
        // and null families different runs at all is that the RAW slot really
        // has that shape. Only a label the wire confirms is banked, so the
        // vocabulary assertion after the loop is an observation of the frames
        // rather than a reading-back of the fixture's own labelling.
        const key_form = try cj.asStr(try cj.required(scenario, "key_form"));
        {
            var raw = try rawWire(std.testing.allocator, scenario);
            defer raw.deinit();
            const wire_form = try wireKeyForm(scenario, raw.value);
            if (!std.mem.eql(u8, wire_form, key_form)) {
                std.debug.print(
                    "{s}: scenario '{s}' is labelled key_form '{s}' but its raw wire " ++
                        "carries '{s}'\n",
                    .{ FIXTURE, try sc.id(), key_form, wire_form },
                );
                return error.WireFormContradictsLabel;
            }
        }
        // The SECOND witness, for msgpack only: `rawWire`'s msgpack arm is this
        // binding's own unpacker, so on its own it cannot rule out a defect that
        // corrupts the control and the thing controlled together. The byte scan
        // shares no code with it (`#lznullformblind`).
        if (std.mem.eql(u8, try cj.asStr(try cj.required(scenario, "codec")), "msgpack")) {
            const frame = try hexToBytes(
                std.testing.allocator,
                try cj.asStr(try cj.required(scenario, "wire_msgpack_hex")),
            );
            defer std.testing.allocator.free(frame);
            const byte_form = try msgpackKeyForm(frame);
            if (!std.mem.eql(u8, byte_form, key_form)) {
                std.debug.print(
                    "{s}: scenario '{s}' is labelled key_form '{s}', the unpacker reads " ++
                        "it as such, and the RAW BYTES carry '{s}'\n",
                    .{ FIXTURE, try sc.id(), key_form, byte_form },
                );
                return error.WireFormContradictsBytes;
            }
            byte_witnessed += 1;
        }
        observed_key_forms.add(key_form);

        var keys = cj.AssertionKeys.init(FIXTURE, expect);
        // Into the SAME ledger as the `assertions` block: a discharge names keys
        // by name in any block of this fixture (`#lzprosekeyconvention`).
        try keys.trackProse(&prose);

        var parsed = try decodeScenario(std.testing.allocator, scenario, &keys, &observed_codecs);
        defer parsed.deinit();

        const key: ?[]const u8 = if (std.mem.eql(u8, field, "snapshot"))
            parsed.message.Snapshot.nodes[0].key
        else switch (parsed.message.Delta.ops[0]) {
            .NodeAdd => |op| op.key,
            else => return error.ExpectedNodeAddOp,
        };
        if (key != null) keys_decoded += 1;

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
        // Booked only once the scenario's every assertion has landed, so
        // `scenario_count` below counts scenarios REPLAYED rather than
        // scenarios present in the file.
        replayed += 1;
    }

    // The count and the vocabularies. Declared against what this run OBSERVED,
    // not against a copy of the declaration — see `checkDeclaredWereObserved`.
    try meta.assertKey("scenario_count", replayed);
    try meta.assertKeyWith("codecs", &observed_codecs, checkDeclaredWereObserved);
    try meta.assertKeyWith("fields", &observed_fields, checkDeclaredWereObserved);
    try meta.assertKeyWith("key_forms", &observed_key_forms, checkDeclaredWereObserved);

    // The four paragraphs, DISCHARGED (`#lzprosekeyconvention`).
    try meta.proseKey("clause", &.{
        // "a decoder MUST accept both an omitted `key` and an explicit `key:
        // null` and read both as absent, refusing neither and constructing a key
        // from neither" — the decoded value, over every form the run replayed.
        "decoded_key",
        "key_forms",
    });
    try meta.proseKey("wire_encoding", &.{
        // Executable proof that the exact raw text / decoded-hex byte buffer
        // reaches the library decoder rather than a reconstructed proxy.
        "wire_input_fnv1a64",
    });
    // "A runner MUST re-encode the decoded message and inspect the resulting
    // frame for the presence of the field" — this is that inspection.
    try meta.proseKey("reencode_obligation", &.{"reencoded_key_field_present"});
    try meta.proseKey("anti_vacuity", &.{
        // "the `omitted` and `present` scenarios are the controls" — both are in
        // the observed form set, and `present` is the one only a real decode can
        // turn into a non-null `decoded_key`.
        "key_forms",
        "decoded_key",
        // The `snapshot`/`node_add` split is the second axis: a runner that only
        // ever reads `NodeSnapshot.key` satisfies half the file.
        "fields",
        // "one that never decodes at all satisfies all of them" — the observed
        // codec set is EMPTY for exactly that runner, which is what turns
        // `codecs` from a restatement into a discharge (`#lznullformblind`).
        "codecs",
    });
    try meta.finish();
    try cj.verifyProse(&prose);

    try std.testing.expectEqual(@as(usize, 12), replayed);
    try std.testing.expectEqual(@as(usize, 4), keys_decoded);
    // Every msgpack frame went past the unpacker AND past the byte scan.
    try std.testing.expectEqual(@as(usize, 6), byte_witnessed);
}
