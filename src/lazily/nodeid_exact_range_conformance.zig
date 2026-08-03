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
//!
//! The three PARAGRAPHS in `assertions` are discharged, not excused
//! (`#lzprosekeyconvention`). `outcomes` left that list with them and became a
//! real assertion: it is a gloss MAP, not a paragraph, so the assertion is over
//! its key set — checked against the outcomes this run actually replayed, which
//! is also what discharges `anti_vacuity`.
//!
//! `scenario_count` and `codecs` followed them (`#lznullformblind`).
//! `scenario_count` read `root.scenarios.len` — the fixture against its own
//! structure — and `codecs` a hand-written `&.{"json","msgpack"}`. Both were
//! green over a runner that decoded nothing, which is the vacuity
//! `anti_vacuity` names, and neither could honestly be cited by any discharge.
//! They are now the scenarios this run replayed to completion and the decoder
//! branches this run actually fed, so `wire_encoding` and `anti_vacuity` cite
//! `codecs` for the half of their claim that is about the codecs running at all.

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

/// Decode a scenario's wire frame with the codec it names, banking the codec
/// path that actually ran.
///
/// lazily-zig never refuses anything in this corpus, so a decode error here is
/// a real failure rather than the `exact_or_reject` branch.
///
/// `observed` is written INSIDE the matched branch, immediately before the wire
/// is handed to that decoder (`#lznullformblind`). The `codecs` assertion after
/// the loop is therefore a record of which decoders were fed, not a re-reading
/// of the scenario's own `codec` label — a runner that replays nothing banks an
/// empty set and reddens.
fn decodeScenario(allocator: std.mem.Allocator, scenario: Value, observed: *StrSet) !ipc.ParsedMessage {
    const codec = try cj.asStr(try cj.required(scenario, "codec"));
    if (std.mem.eql(u8, codec, "json")) {
        // The raw TEXT through the codec's own entry point, so the parse that
        // would round on a narrower runtime is inside the code under test.
        const wire = try cj.asStr(try cj.required(scenario, "wire_json"));
        observed.add("json");
        return IpcMessage.decodeJson(allocator, wire);
    }
    if (std.mem.eql(u8, codec, "msgpack")) {
        const frame = try hexToBytes(allocator, try cj.asStr(try cj.required(scenario, "wire_msgpack_hex")));
        defer allocator.free(frame);
        observed.add("msgpack");
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

/// A small deduplicating set of borrowed strings, for the declared-vs-OBSERVED
/// outcome-vocabulary check.
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

/// What this run actually did with one scenario's frame.
const Verdict = struct {
    observed: *StrSet,
    /// The decode returned a message rather than an error.
    accepted: bool,
    /// The decoded identifier equals `expect.node_id_decimal` exactly.
    exact: bool,
};

/// `outcome` against what the run actually DID, not against a hand-written copy
/// of the vocabulary.
///
/// The membership check this replaces was satisfied by any two-element
/// vocabulary and by a runner that decoded nothing — the shape
/// `anti_vacuity` exists to name, and a discharge naming it would have
/// discharged nothing (`#lzprosekeyconvention`). Both branches are now claims
/// about the observed decode: `exact` obliges an exact accept, and
/// `exact_or_reject` forbids the third outcome — an accept yielding a
/// NEIGHBOURING identifier, which is precisely what a rounding decoder produces.
fn checkOutcome(v: Verdict, expected: Value) anyerror!void {
    const outcome = try cj.asStr(expected);
    if (std.mem.eql(u8, outcome, "exact")) {
        if (!v.accepted) return error.ExactScenarioWasRejected;
        if (!v.exact) return error.ExactScenarioDecodedInexactly;
    } else if (std.mem.eql(u8, outcome, "exact_or_reject")) {
        if (v.accepted and !v.exact) return error.BoundaryValueDecodedInexactly;
    } else {
        return error.UnknownOutcome;
    }
    // Banked for the `outcomes` gloss-map key-set assertion after the loop.
    v.observed.add(outcome);
}

/// The `outcomes` gloss map's KEY SET against the outcomes this run replayed.
fn checkOutcomeVocabulary(observed: *const StrSet, expected: Value) anyerror!void {
    const object = switch (expected) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };
    for (object.keys()) |name| {
        if (!observed.has(name)) {
            std.debug.print(
                "{s}: outcome '{s}' is declared but no scenario in this run replayed it\n",
                .{ FIXTURE, name },
            );
            return error.DeclaredOutcomeNeverObserved;
        }
    }
    if (object.count() != observed.len) {
        std.debug.print(
            "{s}: this run replayed {d} distinct outcomes against {d} declared\n",
            .{ FIXTURE, observed.len, object.count() },
        );
        return error.ObservedOutcomeNotDeclared;
    }
}

/// Every value the fixture DECLARES was actually OBSERVED by this run, and
/// nothing else was.
///
/// This replaces a hand-written `&.{"json","msgpack"}` comparison, which proved
/// that this runner's transcription of the fixture matched the fixture and was
/// green over a runner that decoded neither codec (`#lznullformblind`). Checked
/// in both directions: the size equality closes the reverse case, where the run
/// pushes frames through a codec the fixture never declared.
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

test "lazily/codec: NodeId exact-representation bound is enforced by refusal, never rounding" {
    var fixture = (try cj.load(FIXTURE)) orelse return;
    defer fixture.deinit();
    const root = fixture.value;

    try std.testing.expectEqual(@as(u64, 1), try cj.asU64(try cj.required(root, "protocol_version")));
    try std.testing.expectEqualStrings("NodeIdExactRange", try cj.asStr(try cj.required(root, "kind")));

    // The fixture-scoped prose ledger (`#lzprosekeyconvention`). The three
    // paragraphs are discharged after the loop, because every key they name is
    // asserted in a per-scenario `expect` block.
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
    // `scenario_count`, `codecs` and `outcomes` are all asserted AFTER the loop,
    // against what this run actually replayed, so `meta` stays open until then.
    // `scenario_count` used to read `root.scenarios.len` and `codecs` a
    // hand-written `&.{"json","msgpack"}`; both compared the fixture to a copy
    // of itself and stayed green over a runner that decoded nothing — the shape
    // `anti_vacuity` names, sitting inside the guard meant to enforce it
    // (`#lznullformblind`).

    // Anti-vacuity. `exact_or_reject` is satisfied by a runner that decodes
    // nothing, so the count of scenarios this run actually ACCEPTED is the
    // assertion that the decoder ran at all. lazily-zig covers the whole
    // corpus, so the expected value is every scenario — anything less is a
    // narrowing of the binding, not of the test.
    var accepted: usize = 0;
    var replayed: usize = 0;
    var observed_outcomes: StrSet = .{};
    // Banked inside `decodeScenario`, at the branch that feeds each decoder.
    var observed_codecs: StrSet = .{};

    var scenarios = try cj.scenarios(FIXTURE, root);
    while (scenarios.next()) |sc| {
        // Rung 4 books on the PAYLOAD handoff (#lzscenariobodyskip), so a
        // body that stops short of replaying stops being booked.
        const scenario = try sc.replay();

        const expect = try cj.required(scenario, "expect");
        const decimal = try cj.asStr(try cj.required(expect, "node_id_decimal"));
        const expected = try std.fmt.parseInt(u64, decimal, 10);

        var parsed = try decodeScenario(std.testing.allocator, scenario, &observed_codecs);
        defer parsed.deinit();
        accepted += 1;

        const snapshot = switch (parsed.message) {
            .Snapshot => |s| s,
            else => return error.ExpectedSnapshotVariant,
        };
        try std.testing.expectEqualStrings("Snapshot", try cj.asStr(try cj.required(scenario, "variant")));

        var keys = cj.AssertionKeys.init(FIXTURE, expect);
        // Into the SAME ledger as the `assertions` block: a discharge names keys
        // by name in any block of this fixture (`#lzprosekeyconvention`).
        try keys.trackProse(&prose);
        try keys.assertKey("epoch", snapshot.epoch);
        try keys.assertKey("node_count", snapshot.nodes.len);

        const node = snapshot.nodes[0];
        // The discriminating assertion. A rounding or wrapping decoder yields a
        // NEIGHBOURING identifier that still decodes cleanly and addresses a
        // different node, so the exact comparison is the only check that sees
        // the substitution.
        try std.testing.expectEqual(expected, node.node);

        // Asserted HERE, not before the decode: `outcome` is checked against the
        // verdict this run reached, so it cannot be satisfied by a runner that
        // decodes nothing.
        try keys.assertKeyWith(
            "outcome",
            Verdict{ .observed = &observed_outcomes, .accepted = true, .exact = node.node == expected },
            checkOutcome,
        );

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
        // Booked only once the scenario's every assertion has landed, so
        // `scenario_count` below counts scenarios REPLAYED rather than
        // scenarios present in the file.
        replayed += 1;
    }

    // The count and the two vocabularies, against what this run actually did.
    try meta.assertKey("scenario_count", replayed);
    try meta.assertKeyWith("codecs", &observed_codecs, checkDeclaredWereObserved);
    // The gloss map's key set, against the outcomes this run replayed.
    try meta.assertKeyWith("outcomes", &observed_outcomes, checkOutcomeVocabulary);

    // The three paragraphs, DISCHARGED (`#lzprosekeyconvention`).
    try meta.proseKey("clause", &.{
        // "a decoder that cannot represent a received NodeId/PeerId exactly MUST
        // reject the frame; it MUST NOT round, truncate, saturate, or wrap" —
        // the decimal comparison is the only check that sees a substitution, and
        // it is made on both identifier fields the frame carries.
        "node_id_decimal",
        "root_id_decimal",
        "outcome",
    });
    // PROXY (`#lzprosekeyconvention`). Half of `wire_encoding` is a claim about
    // how the CORPUS carries its bytes, which no run can observe. The half a run
    // CAN carry is its consequence: "a runner MUST parse `wire_json` with the
    // codec under test, not re-serialize a pre-parsed object, and MUST compare
    // the decoded identifier by its decimal RENDERING".
    try meta.proseKey("wire_encoding", &.{
        // "parse ... with the codec under test" — `codecs` is now the record of
        // which decoders were actually fed, one branch per wire carriage (raw
        // text for json, raw hex for msgpack), so it discharges the first half
        // instead of being a copy of the fixture's own list (`#lznullformblind`).
        "codecs",
        // ...and the decimal comparison, made against a string, so a
        // double-backed runtime cannot round the expectation before the test
        // reads it.
        "node_id_decimal",
        "root_id_decimal",
    });
    try meta.proseKey("anti_vacuity", &.{
        // "the two `exact` scenarios are the control" — the declared outcome
        // vocabulary checked against what this run actually replayed is what
        // proves the control branch ran, and the decimal is what it produced.
        "outcomes",
        "outcome",
        "node_id_decimal",
        // "`exact_or_reject` alone is satisfied by a runner that never decodes
        // anything" — the observed codec set is EMPTY for exactly that runner,
        // which is what makes it a discharge rather than a restatement
        // (`#lznullformblind`).
        "codecs",
    });
    try meta.finish();
    try cj.verifyProse(&prose);

    try std.testing.expectEqual(@as(usize, 6), accepted);
}
