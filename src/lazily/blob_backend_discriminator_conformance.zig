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
//! The nine PARAGRAPHS in `assertions` are discharged, not excused
//! (`#lzprosekeyconvention`). This runner used to excuse each of them with an
//! individually-worded reason naming the assertion that carried it — the right
//! instinct, checked by nothing: the text could have named a key this run never
//! asserts, or one the corpus no longer carries, and `finish()` would still have
//! been satisfied. `proseKey` makes the same statement machine-checkable, and
//! `verifyProse` refuses the run when a named key never reached a comparison.
//!
//! `scenario_count`, `codecs` and `outcomes` were the keys that sweep left
//! behind, and they are fixed here (`#lznullformblind`). The count compared the
//! fixture's declaration to `root.scenarios.len`; the other two compared
//! `assertions.codecs` / `assertions.outcomes` to hand-written
//! `&.{"json","msgpack"}` / `&.{"accept","reject"}` literals. All three were
//! green over a runner that decoded nothing, so no discharge could honestly name
//! them. They now read the scenarios replayed to completion, the decoder
//! branches actually fed, and the accept/reject verdicts the decodes actually
//! reached — which is why `clause`, `wire_encoding`, `backend_form_vocabulary`
//! and `anti_vacuity` can cite them.
//!
//! The raw-wire `backend` classifier gets a SECOND WITNESS in the same pass. Its
//! json arm reads through `std.json`, which is the standard library and shares
//! nothing with this binding's codec, but its msgpack arm went through
//! `mp.toJsonValue` — this binding's own unpacker — so an unpacker defect would
//! have corrupted the control and the thing controlled together.
//! `msgpackBackendForm` reads the same slot out of the raw bytes
//! (`a7 62 61 63 6b 65 6e 64`, then nil / fixstr / anything else) and must
//! agree; `byte_witnessed` is counted so a witness that never runs cannot agree
//! with everything by silence.
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
///
/// `observed` is written INSIDE the matched branch, immediately before the wire
/// reaches that decoder (`#lznullformblind`), and on the REJECT path too — the
/// codec still consumed the frame. The `codecs` assertion after the loop is
/// therefore a record of which decoders were fed rather than a reading-back of
/// the scenario's `codec` label, and a runner that replays nothing banks an
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

/// The scenario's wire frame as a schema-less `Value`, WITHOUT the typed
/// decoder.
///
/// This is the control `wire_encoding` needs (`#lzprosekeyconvention`). The
/// paragraph's obligation is that an ABSENT map entry, an explicit null and a
/// present short string stay TELLABLE APART on their way into the runner — and
/// every one of them decodes to `backend == .shm`, so no assertion over a
/// decoded message can see the difference. Reading the raw slot before the
/// decoder runs is what makes the three forms distinguishable at all.
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

/// The `backend` slot's WIRE form, read off the raw frame. The vocabulary is the
/// fixture's own: `omitted` / `null` / `non_string` / the token itself.
fn wireBackendForm(scenario: Value, frame: Value) ![]const u8 {
    const blob = try blobOf(scenario, frame);
    const entry = cj.field(blob, "backend") orelse return "omitted";
    return switch (entry) {
        .null => "null",
        .string => |token| token,
        else => "non_string",
    };
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

/// A SECOND witness for the msgpack `backend` slot, read at the BYTE level.
///
/// `rawWire` is decoder-independent for json — `std.json.parseFromSlice` is the
/// standard library, not this binding's codec — but its msgpack arm goes through
/// `mp.toJsonValue`, this binding's own unpacker. A defect there would corrupt
/// the control and the thing controlled TOGETHER, which is the one way
/// `wireBackendForm` could agree with a wrong answer.
///
/// This reads the frame as bytes instead. `a7 62 61 63 6b 65 6e 64` is the
/// MessagePack fixstr for `"backend"`, and what follows is the slot's value:
/// `0xc0` is nil, `0xa0|len` a fixstr whose bytes are the token itself, and
/// anything else is the non-string form. No occurrence at all is the omitted
/// form. The marker must be UNIQUE in the frame or the read is ambiguous.
fn msgpackBackendForm(frame: []const u8) ![]const u8 {
    const marker = [_]u8{ 0xa7, 'b', 'a', 'c', 'k', 'e', 'n', 'd' };
    const at = std.mem.indexOf(u8, frame, &marker) orelse return "omitted";
    if (std.mem.indexOf(u8, frame[at + marker.len ..], &marker) != null) {
        return error.AmbiguousBackendMarkerInFrame;
    }
    const slot = at + marker.len;
    if (slot >= frame.len) return error.TruncatedBackendSlot;
    const value = frame[slot];
    if (value == 0xc0) return "null";
    if (value >= 0xa0 and value <= 0xbf) {
        const len: usize = value & 0x1f;
        if (slot + 1 + len > frame.len) return error.TruncatedBackendToken;
        // The TOKEN itself, lifted out of the bytes — `wireBackendForm`'s
        // vocabulary for a present string is the token, not the word "present".
        return frame[slot + 1 ..][0..len];
    }
    // str8/str16/str32 would still be a token, but no backend name in this
    // corpus is that long, so anything else here is the non-string form.
    if (value == 0xd9 or value == 0xda or value == 0xdb) return error.UnexpectedLongBackendToken;
    return "non_string";
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

/// A small deduplicating set of borrowed strings, for the declared-vs-OBSERVED
/// vocabulary checks below.
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

    // The fixture-scoped prose ledger (`#lzprosekeyconvention`). Every discharge
    // below names keys asserted in the per-scenario `expect` blocks, which are
    // reached long after this block is finished — `epoch_disambiguation` is the
    // canonical case — so verification cannot be block-scoped.
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
    // `scenario_count`, `codecs`, `outcomes`, `backends`, `backend_forms` and
    // `rejection_kinds` are all asserted AFTER the loop, against what this run
    // actually observed, so `meta` stays open until then. Declaring a vocabulary
    // and comparing it to a hardcoded copy of itself — which is what
    // `checkStrList` on `backends` did — proves the fixture agrees with the
    // runner's transcription of the fixture.
    //
    // `scenario_count`, `codecs` and `outcomes` were the three left behind by
    // that first sweep (`#lznullformblind`): the count read
    // `scenarios_array.len`, and the other two read hand-written
    // `&.{"json","msgpack"}` / `&.{"accept","reject"}` literals. All three were
    // green over a runner that decoded nothing — the vacuity `anti_vacuity`
    // names, sitting inside the guard meant to enforce it.

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
    // How many frames the decoder-INDEPENDENT byte scan classified. A witness
    // that never runs agrees with everything, so it is counted too.
    var byte_witnessed: usize = 0;

    // Declared-vs-OBSERVED vocabularies, checked after the loop.
    var decoded_backends: StrSet = .{};
    var observed_forms: StrSet = .{};
    var observed_rejection_kinds: StrSet = .{};
    // Banked inside `decodeScenario`, at the branch that feeds each decoder.
    var observed_codecs: StrSet = .{};
    // Banked from the VERDICT this run reached — a decode that errored, a decode
    // that produced a frame — never from the scenario's `outcome` label
    // (`#lznullformblind`).
    var observed_outcomes: StrSet = .{};

    var scenarios = try cj.scenarios(FIXTURE, root);
    while (scenarios.next()) |sc| {
        // Rung 4 books on the PAYLOAD handoff (#lzscenariobodyskip), so a body
        // that stops short of replaying stops being booked.
        const scenario = try sc.replay();

        const expect = try cj.required(scenario, "expect");
        const outcome = try cj.asStr(try cj.required(scenario, "outcome"));
        const form = try cj.asStr(try cj.required(scenario, "backend_form"));

        // The wire-form control. The scenario's `backend_form` is a LABEL; what
        // discharges `wire_encoding` is that the raw slot really has that shape,
        // because the three `shm` forms are indistinguishable everywhere else in
        // this fixture. Only a label the wire CONFIRMS is banked, so the
        // vocabulary assertion after the loop is an observation rather than a
        // reading-back of the fixture's own labelling.
        {
            var raw = try rawWire(std.testing.allocator, scenario);
            defer raw.deinit();
            const wire_form = try wireBackendForm(scenario, raw.value);
            if (!std.mem.eql(u8, wire_form, form)) {
                std.debug.print(
                    "{s}: scenario '{s}' is labelled backend_form '{s}' but its raw wire " ++
                        "carries '{s}'\n",
                    .{ FIXTURE, try sc.id(), form, wire_form },
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
            const byte_form = try msgpackBackendForm(frame);
            if (!std.mem.eql(u8, byte_form, form)) {
                std.debug.print(
                    "{s}: scenario '{s}' is labelled backend_form '{s}', the unpacker " ++
                        "reads it as such, and the RAW BYTES carry '{s}'\n",
                    .{ FIXTURE, try sc.id(), form, byte_form },
                );
                return error.WireFormContradictsBytes;
            }
            byte_witnessed += 1;
        }
        observed_forms.add(form);
        if (std.mem.eql(u8, form, "null")) null_form_replayed += 1;
        var keys = cj.AssertionKeys.init(FIXTURE, expect);
        // Into the SAME ledger as the `assertions` block: a discharge names keys
        // by name in any block of this fixture (`#lzprosekeyconvention`).
        try keys.trackProse(&prose);

        // A token left over from an earlier scenario must never be able to
        // satisfy `error_names_token` for a later one.
        _ = BlobBackendKind.takeUnknownToken();

        if (std.mem.eql(u8, outcome, "reject")) {
            // Widened to `anyerror` on purpose: the two codecs return different
            // inferred error sets, and the switch below has to be writable
            // against both without pinning either one's membership.
            const err: anyerror = blk: {
                if (decodeScenario(std.testing.allocator, scenario, &keys, &observed_codecs)) |ok| {
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
            // The OBSERVED verdict: this decode really returned an error. The
            // scenario's `outcome` label had no part in producing it.
            observed_outcomes.add("reject");
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
            // Booked only once the scenario's every assertion has landed, so
            // `scenario_count` below counts scenarios REPLAYED rather than
            // scenarios present in the file.
            replayed += 1;
            continue;
        }

        var parsed = try decodeScenario(std.testing.allocator, scenario, &keys, &observed_codecs);
        defer parsed.deinit();
        accepted += 1;
        // The OBSERVED verdict: this decode really produced a frame.
        observed_outcomes.add("accept");
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
        replayed += 1;
    }

    // The count and the vocabulary checks. Declared against what this run
    // OBSERVED, not against a copy of the declaration — see
    // `checkDeclaredWereObserved`.
    try meta.assertKey("scenario_count", replayed);
    try meta.assertKeyWith("codecs", &observed_codecs, checkDeclaredWereObserved);
    try meta.assertKeyWith("outcomes", &observed_outcomes, checkDeclaredWereObserved);
    try meta.assertKeyWith("backends", &decoded_backends, checkDeclaredWereObserved);
    try meta.assertKeyWith("backend_forms", &observed_forms, checkDeclaredWereObserved);
    try meta.assertKeyWith("rejection_kinds", &observed_rejection_kinds, checkDeclaredWereObserved);

    // The nine paragraphs, DISCHARGED (`#lzprosekeyconvention`). Each names the
    // executable keys this run actually asserted — which is why they are written
    // here, after the loop: every name below has by now reached a comparison, and
    // `verifyProse` fails the run if one has not. That is the difference between
    // this and the free-text excuses it replaces, which said the same things and
    // were checked by nothing.
    try meta.proseKey("clause", &.{
        // omitted / null / explicit-shm decode as `shm`, arrow and in_process as
        // themselves — the field is READ rather than defaulted...
        "decoded_backend",
        // ...and a present token outside the enum is refused, by name, rather
        // than normalized.
        "rejected",
        "rejection_kind",
        "error_names_token",
        // Both HALVES of the clause really occurred. `outcomes` is banked from
        // the verdict each decode reached, so a run that only ever accepted —
        // or only ever refused — no longer discharges this (`#lznullformblind`).
        "outcomes",
    });
    try meta.proseKey("wire_encoding", &.{
        // Executable proof that the exact raw text / decoded-hex byte buffer
        // reaches the library decoder rather than a reconstructed proxy.
        "wire_input_fnv1a64",
    });
    try meta.proseKey("backend_form_vocabulary", &.{
        // Its own words: "every backend in `assertions.backends` appears as the
        // `decoded_backend` of some accept scenario". `backends` is asserted
        // declared-against-OBSERVED over exactly that set.
        "backends",
        "decoded_backend",
        "backend_forms",
        // "The seven wire shapes ... each carried in BOTH CODECS" — the observed
        // codec set is what makes that half of the sentence checkable.
        "codecs",
    });
    try meta.proseKey("reject_obligation", &.{
        // "`error_names_token` is the assertion that separates them" — refused
        // for the stated reason, not merely refused.
        "error_names_token",
        "rejection_kind",
    });
    try meta.proseKey("null_form", &.{
        // An explicit null is the ABSENT form: decoded as `shm`...
        "decoded_backend",
        // ...re-encoded WITHOUT a `backend` entry, so the null does not survive...
        "reencoded_backend_field_present",
        // ...and the `null` form was really among the ones replayed.
        "backend_forms",
    });
    try meta.proseKey("non_string_form", &.{
        // Both halves: the refusal...
        "rejected",
        // ...and that it arrives through the documented decode-error family,
        // which is the half that makes it visible to a caller's handler.
        "rejection_is_decode_error",
        "rejection_kind",
    });
    // The spec's own worked example. Both are asserted in the per-scenario
    // `expect` blocks, fourteen scenarios after this one — the case that makes
    // the ledger fixture-scoped rather than block-scoped.
    try meta.proseKey("epoch_disambiguation", &.{ "frame_epoch", "blob_epoch" });
    try meta.proseKey("anti_vacuity", &.{
        // (4) vocabulary completeness...
        "backends",
        // (1) a real decode of every form...
        "backend_forms",
        // (2) the field really READ...
        "decoded_backend",
        // (3) the ENCODER half.
        "reencoded_backend_field_present",
        // "TWO CODECS ARE NOT TWO IMPLEMENTATIONS ... a binding whose two codecs
        // share a decode path should RECORD THAT IN ITS OWN LEDGER rather than
        // infer independence from the scenario count." `codecs` is that record —
        // banked at the branch each decoder is fed, so it says which paths ran
        // and claims nothing about their independence (`#lznullformblind`).
        "codecs",
    });
    // PROXY (`#lzprosekeyconvention`). `theorem` names `resolve_wrong_backend`, a
    // Lean theorem in lazily-formal; no run in this repo can prove it. What the
    // run can prove is its CONSEQUENCE — an unknown kind is refused rather than
    // routed into the shm table, which is the same fact as "never normalized".
    try meta.proseKey("theorem", &.{ "rejected", "decoded_backend" });
    try meta.finish();
    try cj.verifyProse(&prose);

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
    // Every msgpack frame went past the unpacker AND past the byte scan.
    try std.testing.expectEqual(@as(usize, 7), byte_witnessed);

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
