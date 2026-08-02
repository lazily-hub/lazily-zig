//! Blob-backend discriminator strictness on decode (`#lzblobbackendstrict`).
//!
//! protocol.md § Zero-copy blob descriptor makes `backend` optional with a
//! default of `shm`. Nine bindings read that optionality two different ways and
//! five of them — this one included — extended it to cover a PRESENT token
//! outside the enum, normalizing `rdma` to `shm` and documenting the
//! normalization as forward compatibility. The clause now separates the two
//! facts: absence is the forward-compatible channel, presence-outside-the-enum
//! is a corrupt or non-conforming producer and MUST be refused, naming the
//! token.
//!
//! Why normalizing is not merely lenient. `docs/zero-copy-transport.md` proves
//! `resolve_wrong_backend` — a descriptor of one kind never resolves against a
//! different backend's table — and it proves it BECAUSE receivers route by
//! kind. Reading an unknown kind as `shm` is routing a non-shm descriptor into
//! the shm table; the generation/len/checksum/epoch verification then usually
//! rejects it. "Usually" is the defect: a structural guarantee becomes a 64-bit
//! checksum's word against a backend this build genuinely resolves, so a
//! collision returns bytes where a refusal would have been a visible protocol
//! error the peer recovers from by resync.
//!
//! The runner checks both halves of the clause, because the decode half alone
//! is satisfiable without implementing it. `backend_omitted` forces a real
//! decode; `backend_arrow` forces the field to actually be READ (a decoder that
//! hardcodes `shm` passes every other accept scenario); and
//! `reencoded_backend_field_present` forces the ENCODER half — false for `shm`,
//! true for `arrow` — so a binding cannot satisfy the clause by echoing back
//! whatever it received.
//!
//! The wire arrives as RAW text/hex rather than as a parsed object. That is not
//! a convenience: `schemas/defs.json` closes `backend` to an enum, so the two
//! reject frames are schema-INVALID by construction and a fixture embedding
//! them as structured JSON would fail the corpus's own schema gate.

const std = @import("std");
const cj = @import("conformance_json.zig");
const ipc = @import("ipc.zig");
const mp = @import("msgpack.zig");

const Value = std.json.Value;
const IpcMessage = ipc.IpcMessage;
const BlobBackendKind = ipc.BlobBackendKind;

const FIXTURE = "codec/blob_backend_discriminator.json";

fn hexToBytes(allocator: std.mem.Allocator, hex: []const u8) ![]u8 {
    if (hex.len % 2 != 0) return error.OddLengthHexString;
    const out = try allocator.alloc(u8, hex.len / 2);
    errdefer allocator.free(out);
    for (out, 0..) |*byte, i| {
        byte.* = try std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16);
    }
    return out;
}

/// Decode the scenario's wire form THROUGH the codec it names. Both codecs are
/// exercised because the msgpack decoder is derived from the json one but the
/// derivation is exactly what a defect would break.
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

/// Re-encode under the scenario's own codec and read the produced frame back
/// SCHEMA-LESSLY. `ShmBlobRef.backend` is a non-optional Zig field with a
/// default, so no assertion over the decoded value can tell "emitted `shm`"
/// from "omitted `shm`" — which is the whole encoder half of the clause.
fn reencodedFrame(
    allocator: std.mem.Allocator,
    scenario: Value,
    message: IpcMessage,
) !std.json.Parsed(Value) {
    const codec = try cj.asStr(try cj.required(scenario, "codec"));
    if (std.mem.eql(u8, codec, "msgpack")) {
        const frame = try mp.encodeAlloc(allocator, message);
        defer allocator.free(frame);
        return mp.toJsonValue(allocator, frame);
    }
    const encoded = try message.encodeJsonAlloc(allocator);
    defer allocator.free(encoded);
    return std.json.parseFromSlice(Value, allocator, encoded, .{});
}

/// The `SharedBlob` descriptor of the frame's first op, schema-lessly.
fn blobOf(scenario: Value, frame: Value) !Value {
    const variant = try cj.asStr(try cj.required(scenario, "variant"));
    if (!std.mem.eql(u8, variant, "Delta")) return error.UnexpectedVariant;
    const body = try cj.required(frame, "Delta");
    const op = (try cj.asArray(try cj.required(body, "ops")))[0];
    const slot = try cj.required(op, "SlotValue");
    return try cj.required(try cj.required(slot, "payload"), "SharedBlob");
}

fn checkStrList(context: []const []const u8, expected: Value) anyerror!void {
    const want = try cj.asArray(expected);
    try std.testing.expectEqual(want.len, context.len);
    for (want, context) |w, got| try std.testing.expectEqualStrings(try cj.asStr(w), got);
}

test "lazily/codec: an omitted blob backend is shm, a present unknown one is refused by name" {
    var fixture = (try cj.load(FIXTURE)) orelse return;
    defer fixture.deinit();
    const root = fixture.value;

    try std.testing.expectEqual(@as(u64, 1), try cj.asU64(try cj.required(root, "protocol_version")));
    try std.testing.expectEqualStrings(
        "BlobBackendDiscriminator",
        try cj.asStr(try cj.required(root, "kind")),
    );

    const scenarios_array = try cj.asArray(try cj.required(root, "scenarios"));

    var meta = cj.AssertionKeys.init(FIXTURE ++ " assertions", try cj.required(root, "assertions"));
    try meta.assertKey("required_of_binding", "MUST");
    try meta.assertKey("scenario_count", scenarios_array.len);
    try meta.assertKeyWith("codecs", @as([]const []const u8, &.{ "json", "msgpack" }), checkStrList);
    try meta.assertKeyWith(
        "backends",
        @as([]const []const u8, &.{ "shm", "arrow", "in_process" }),
        checkStrList,
    );
    try meta.assertKeyWith(
        "outcomes",
        @as([]const []const u8, &.{ "accept", "reject" }),
        checkStrList,
    );
    for ([_][]const u8{
        "clause",
        "wire_encoding",
        "reject_obligation",
        "anti_vacuity",
        "theorem",
        "generator",
    }) |prose| {
        try meta.excuseKey(
            prose,
            "prose: it states WHY the fixture is shaped this way; the behaviour it " ++
                "describes is asserted by the per-scenario decode, refusal and re-encode below",
        );
    }
    try meta.finish();

    // Anti-vacuity, three counters for three ways to pass without implementing
    // the clause. A runner that never decodes still reports `shm` everywhere
    // and satisfies the omitted and explicit-shm scenarios; `arrow` decodes are
    // what only a real read of the field can produce, and refusals are what
    // only the strict half can produce.
    var replayed: usize = 0;
    var accepted: usize = 0;
    var refused: usize = 0;
    var arrow_decoded: usize = 0;
    var backend_field_emitted: usize = 0;

    var scenarios = try cj.scenarios(FIXTURE, root);
    while (scenarios.next()) |sc| {
        // Rung 4 books on the PAYLOAD handoff (#lzscenariobodyskip), so a body
        // that stops short of replaying stops being booked.
        const scenario = try sc.replay();
        replayed += 1;

        const expect = try cj.required(scenario, "expect");
        const outcome = try cj.asStr(try cj.required(scenario, "outcome"));
        var keys = cj.AssertionKeys.init(FIXTURE, expect);

        // A token left over from an earlier scenario must never be able to
        // satisfy `error_names_token` for a later one.
        _ = BlobBackendKind.takeUnknownToken();

        if (std.mem.eql(u8, outcome, "reject")) {
            if (decodeScenario(std.testing.allocator, scenario)) |ok| {
                var accepted_frame = ok;
                accepted_frame.deinit();
                std.debug.print(
                    "{s}: scenario '{s}' decoded a frame the clause requires refusing\n",
                    .{ FIXTURE, try sc.id() },
                );
                return error.UnknownBackendWasAccepted;
            } else |err| {
                // Pinned to THIS error, not to "some error": a decode that
                // blew up on `checksum` would satisfy a bare is-error check.
                try keys.assertKey("rejected", err == error.UnknownBlobBackend);
            }
            refused += 1;

            // Refusal is only half the obligation. A decoder that refuses
            // because it mis-parsed `checksum` passes a bare is-error
            // assertion while implementing none of the clause, so the error has
            // to carry the token that caused it.
            const token = BlobBackendKind.takeUnknownToken() orelse {
                std.debug.print(
                    "{s}: scenario '{s}' refused the frame but named no token\n",
                    .{ FIXTURE, try sc.id() },
                );
                return error.RefusalNamedNoToken;
            };
            try keys.assertKey("error_names_token", token);
            try keys.finish();
            continue;
        }

        var parsed = try decodeScenario(std.testing.allocator, scenario);
        defer parsed.deinit();
        accepted += 1;
        // An accepted frame must leave no diagnostic behind, or the reject
        // assertions above could be satisfied by a decoder that parks a token
        // on every descriptor it sees.
        try std.testing.expect(BlobBackendKind.takeUnknownToken() == null);

        const variant = try cj.asStr(try cj.required(scenario, "variant"));
        if (!std.mem.eql(u8, variant, "Delta")) return error.UnexpectedVariant;
        const op = switch (parsed.message.Delta.ops[0]) {
            .SlotValue => |o| o,
            else => return error.ExpectedSlotValueOp,
        };
        const blob = switch (op.payload) {
            .SharedBlob => |b| b,
            else => return error.ExpectedSharedBlobPayload,
        };
        if (blob.backend == .arrow) arrow_decoded += 1;

        try keys.assertKey("decoded_backend", blob.backend);
        try keys.assertKey("node", op.node);
        try keys.assertKey("offset", blob.offset);
        try keys.assertKey("len", blob.len);
        try keys.assertKey("generation", blob.generation);
        try keys.assertKey("epoch", blob.epoch);
        try keys.assertKey("checksum", blob.checksum);

        // The encoder half, which no assertion over the decoded value reaches.
        var reencoded = try reencodedFrame(std.testing.allocator, scenario, parsed.message);
        defer reencoded.deinit();
        const wire_blob = try blobOf(scenario, reencoded.value);
        const present = cj.field(wire_blob, "backend") != null;
        if (present) backend_field_emitted += 1;
        try keys.assertKey("reencoded_backend_field_present", present);
        try keys.finish();
    }

    try std.testing.expectEqual(@as(usize, 8), replayed);
    try std.testing.expectEqual(@as(usize, 6), accepted);
    try std.testing.expectEqual(@as(usize, 2), refused);
    // Both `arrow` scenarios really read the field...
    try std.testing.expectEqual(@as(usize, 2), arrow_decoded);
    // ...and only those two emitted it again, so the four `shm` frames
    // round-tripped without growing a `backend` key.
    try std.testing.expectEqual(@as(usize, 2), backend_field_emitted);
}
