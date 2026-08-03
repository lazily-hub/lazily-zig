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
//!
//! FIXTURE v2 carries four shapes v1 declared or implied without carrying, and
//! this binding was not equally ready for them:
//!
//!   - `in_process` — ALREADY conformed. `BlobBackendKind` has carried three
//!     values since the zero-copy transport landed, and `fromString` has
//!     accepted all three; v1 simply never asked. Nothing was fixed here, and
//!     the new VOCABULARY-COMPLETENESS check below is what turns that from a
//!     claim into an assertion. A scenario count cannot reach it: a binding
//!     knowing only {shm, arrow} refuses `in_process` while NAMING the token,
//!     which is conforming by the letter of the reject clause, so it passes
//!     every is-error assertion in the file.
//!   - an explicit `null` — was REFUSED (`error.ExpectedString`), and is now
//!     the absent form. See `ipc.parseShmBlobRef`.
//!   - a NON-STRING `backend` — was already refused, and through
//!     `error.ExpectedString`, which is a member of the documented family
//!     (`ipc.BlobDescriptorDecodeError`). The family is what was missing: it
//!     was an inferred error set nobody had written down, so "the refusal
//!     arrives where callers catch" was unassertable.
//!   - `frame_epoch` vs `blob_epoch` — v1 carried 9 in both, so a runner
//!     reading either satisfied one `expect.epoch`. This one read the BLOB's.
//!     Both are now read, from their own sources.
//!
//! ONE VERDICT, NOT TWO. `msgpack.decode` unpacks to the same `std.json.Value`
//! DOM the json decoder consumes and hands it to `ipc.IpcMessage.fromJson`, so
//! the msgpack half of every scenario pair re-proves the UNPACKER and the
//! encoder bridge, not a second discriminator implementation. A fully green run
//! here is one implementation checked over two framings — recorded per the
//! fixture's own `anti_vacuity` note rather than inferred from the pair count.

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

/// A small deduplicating set of borrowed strings, for the three
/// declared-vs-OBSERVED vocabulary checks below.
const StrSet = struct {
    items: [16][]const u8 = undefined,
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

/// Every value the fixture DECLARES was actually OBSERVED at runtime, and
/// nothing else was.
///
/// This is the assertion shape a scenario count cannot substitute for. v1
/// declared three backends in `assertions.backends` and carried scenarios for
/// two; a binding knowing only {shm, arrow} refused `in_process` while naming
/// the token — conforming by the letter of the reject clause — and passed all
/// eight scenarios while implementing a smaller enum than the clause declares.
/// Counting scenarios says the file was fully replayed. It cannot say the
/// vocabulary was fully exercised.
///
/// Checked in BOTH directions: the size equality closes the reverse case, where
/// the run observes a value the fixture never declared (a stale runner mapping
/// its own spelling onto the corpus's).
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
    try meta.excuseKey(
        "backend_form_vocabulary",
        "prose: it states the completeness obligation rather than a value to compare. " ++
            "The obligation itself is asserted — `backend_forms` and `backends` are both " ++
            "checked declared-against-OBSERVED after the loop, which is the check it names",
    );
    try meta.excuseKey(
        "null_form",
        "prose: the two null scenarios assert the behaviour it describes — decoded as " ++
            "`shm`, and re-encoded WITHOUT a `backend` entry, so the null does not survive",
    );
    try meta.excuseKey(
        "non_string_form",
        "prose: the two non_string scenarios assert both halves it describes — the " ++
            "refusal, and that the refusal is a member of `ipc.BlobDescriptorDecodeError`",
    );
    try meta.excuseKey(
        "epoch_disambiguation",
        "prose: the accept scenarios assert `frame_epoch` against the Delta frame and " ++
            "`blob_epoch` against the ShmBlobRef descriptor, from their own sources",
    );
    // `backends`, `backend_forms` and `rejection_kinds` are asserted AFTER the
    // loop, against what this run actually observed, so `meta` stays open until
    // then. Declaring a vocabulary and comparing it to a hardcoded copy of
    // itself — which is what `checkStrList` on `backends` did — proves the
    // fixture agrees with the runner's transcription of the fixture.

    // Anti-vacuity counters, one per way to pass without implementing the
    // clause. A runner that never decodes still reports `shm` everywhere and
    // satisfies the omitted, explicit-shm and null scenarios; `arrow` and
    // `in_process` decodes are what only a real read of the field can produce,
    // and refusals are what only the strict half can produce.
    var replayed: usize = 0;
    var accepted: usize = 0;
    var refused: usize = 0;
    var arrow_decoded: usize = 0;
    var in_process_decoded: usize = 0;
    var null_form_replayed: usize = 0;
    var non_string_refused: usize = 0;
    var backend_field_emitted: usize = 0;

    // Declared-vs-OBSERVED vocabularies, checked after the loop.
    var decoded_backends: StrSet = .{};
    var observed_forms: StrSet = .{};
    var observed_rejection_kinds: StrSet = .{};

    var scenarios = try cj.scenarios(FIXTURE, root);
    while (scenarios.next()) |sc| {
        // Rung 4 books on the PAYLOAD handoff (#lzscenariobodyskip), so a body
        // that stops short of replaying stops being booked.
        const scenario = try sc.replay();
        replayed += 1;

        const expect = try cj.required(scenario, "expect");
        const outcome = try cj.asStr(try cj.required(scenario, "outcome"));
        const form = try cj.asStr(try cj.required(scenario, "backend_form"));
        observed_forms.add(form);
        if (std.mem.eql(u8, form, "null")) null_form_replayed += 1;
        var keys = cj.AssertionKeys.init(FIXTURE, expect);

        // A token left over from an earlier scenario must never be able to
        // satisfy `error_names_token` for a later one.
        _ = BlobBackendKind.takeUnknownToken();

        if (std.mem.eql(u8, outcome, "reject")) {
            // Widened to `anyerror` on purpose: the two codecs return different
            // inferred error sets, and the switch below has to be writable
            // against both without pinning either one's membership.
            const err: anyerror = blk: {
                if (decodeScenario(std.testing.allocator, scenario)) |ok| {
                    var accepted_frame = ok;
                    accepted_frame.deinit();
                    std.debug.print(
                        "{s}: scenario '{s}' decoded a frame the clause requires refusing\n",
                        .{ FIXTURE, try sc.id() },
                    );
                    return error.UnknownBackendWasAccepted;
                } else |e| break :blk e;
            };
            refused += 1;
            try keys.assertKey("rejected", true);

            // The refusal has to arrive where callers already catch. A frame
            // refused through an error outside the family every decode is
            // guarded with fails PAST the handler: still rejected, still
            // invisible. See `ipc.BlobDescriptorDecodeError`.
            if (!ipc.isBlobDescriptorDecodeError(err)) {
                std.debug.print(
                    "{s}: scenario '{s}' refused through {s}, which is not a member of " ++
                        "ipc.BlobDescriptorDecodeError\n",
                    .{ FIXTURE, try sc.id(), @errorName(err) },
                );
                return error.RefusalOutsideDecodeErrorFamily;
            }
            try keys.assertKey("rejection_is_decode_error", true);

            // Which refusal this is, derived from the error the decode actually
            // produced rather than copied out of the fixture. Pinned to THESE
            // errors, not to "some error": a decode that blew up on `checksum`
            // would satisfy a bare is-error check, and would land here as
            // ExpectedUnsignedInteger — a family member, and still not the
            // clause.
            const observed_kind: []const u8 = switch (err) {
                error.UnknownBlobBackend => "unknown_token",
                error.ExpectedString => "non_string",
                else => {
                    std.debug.print(
                        "{s}: scenario '{s}' refused through {s}, which is a decode error " ++
                            "but not one the clause's two refusals produce\n",
                        .{ FIXTURE, try sc.id(), @errorName(err) },
                    );
                    return error.RefusalKindNotAttributable;
                },
            };
            observed_rejection_kinds.add(observed_kind);
            try keys.assertKey("rejection_kind", observed_kind);

            // Naming the token is the other half of the UNKNOWN-TOKEN refusal.
            // A decoder that refuses because it mis-parsed `checksum` passes a
            // bare is-error assertion while implementing none of the clause.
            // The non-string form asserts the MIRROR of it: there is no token,
            // so nothing may be parked — a decoder that parked the empty string
            // here would hand it to the next scenario's `error_names_token`.
            const token = BlobBackendKind.takeUnknownToken();
            if (std.mem.eql(u8, observed_kind, "unknown_token")) {
                const named = token orelse {
                    std.debug.print(
                        "{s}: scenario '{s}' refused the frame but named no token\n",
                        .{ FIXTURE, try sc.id() },
                    );
                    return error.RefusalNamedNoToken;
                };
                try keys.assertKey("error_names_token", named);
            } else {
                non_string_refused += 1;
                if (token != null) {
                    std.debug.print(
                        "{s}: scenario '{s}' has no token, but the decoder parked one\n",
                        .{ FIXTURE, try sc.id() },
                    );
                    return error.RefusalNamedAPhantomToken;
                }
                // `error_names_token` is genuinely absent here — the fixture
                // does not carry it, so there is nothing to consume.
                try std.testing.expect(!keys.has("error_names_token"));
            }
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
        const delta = parsed.message.Delta;
        const op = switch (delta.ops[0]) {
            .SlotValue => |o| o,
            else => return error.ExpectedSlotValueOp,
        };
        const blob = switch (op.payload) {
            .SharedBlob => |b| b,
            else => return error.ExpectedSharedBlobPayload,
        };
        if (blob.backend == .arrow) arrow_decoded += 1;
        if (blob.backend == .in_process) in_process_decoded += 1;
        decoded_backends.add(blob.backend.toString());

        try keys.assertKey("decoded_backend", blob.backend);
        try keys.assertKey("node", op.node);
        try keys.assertKey("offset", blob.offset);
        try keys.assertKey("len", blob.len);
        try keys.assertKey("generation", blob.generation);
        // Two DIFFERENT epochs from two DIFFERENT sources. v1 carried 9 in both
        // the frame and the descriptor, so a runner reading either one
        // satisfied a single `expect.epoch` and the fixture could not tell them
        // apart. The frame epoch orders deltas; the descriptor epoch is the
        // arena incarnation the blob was written into. Reading `delta.epoch`
        // for both — or `blob.epoch` for both — now fails.
        try keys.assertKey("frame_epoch", delta.epoch);
        try keys.assertKey("blob_epoch", blob.epoch);
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

    // The vocabulary checks. Declared against what this run OBSERVED, not
    // against a copy of the declaration — see `checkDeclaredWereObserved`.
    try meta.assertKeyWith("backends", &decoded_backends, checkDeclaredWereObserved);
    try meta.assertKeyWith("backend_forms", &observed_forms, checkDeclaredWereObserved);
    try meta.assertKeyWith("rejection_kinds", &observed_rejection_kinds, checkDeclaredWereObserved);
    try meta.finish();

    try std.testing.expectEqual(@as(usize, 14), replayed);
    try std.testing.expectEqual(@as(usize, 10), accepted);
    try std.testing.expectEqual(@as(usize, 4), refused);
    // Both `arrow` scenarios really read the field...
    try std.testing.expectEqual(@as(usize, 2), arrow_decoded);
    // ...and so did both `in_process` ones, which is the vocabulary v1 declared
    // and never asked for.
    try std.testing.expectEqual(@as(usize, 2), in_process_decoded);
    // Both null frames reached a decode rather than being skipped past.
    try std.testing.expectEqual(@as(usize, 2), null_form_replayed);
    // Both non-string frames were refused, and through the documented family.
    try std.testing.expectEqual(@as(usize, 2), non_string_refused);
    // Only `arrow` and `in_process` emitted the field again, so the six `shm`
    // frames (two omitted, two explicit, two null) round-tripped without
    // growing a `backend` key.
    try std.testing.expectEqual(@as(usize, 4), backend_field_emitted);

    // A pass count is not proof that a test ran the scenarios it names — a
    // filtered `zig build test --test-filter ...` can report "N/N passed"
    // having selected this test NOT AT ALL. So the run says what it replayed,
    // out loud, and the same fourteen ids go into the runtime scenario ledger
    // that `scripts/check-conformance-coverage.sh` reads back.
    if (@import("conformance_manifest.zig").envFlagSet("LAZILY_CONFORMANCE_MANIFEST")) {
        std.debug.print(
            "{s}: replayed {d} scenarios ({d} accept / {d} reject); " ++
                "backends decoded: {d} arrow, {d} in_process; " ++
                "null forms: {d}; non-string refusals: {d}\n",
            .{
                FIXTURE,
                replayed,
                accepted,
                refused,
                arrow_decoded,
                in_process_decoded,
                null_form_replayed,
                non_string_refused,
            },
        );
    }
}
