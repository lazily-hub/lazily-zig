//! Replay the canonical replay-equivalence corpus against `replay.zig`
//! (`#lzreplayzig`).
//!
//! Three fixtures, one obligation each (`../lazily-spec/docs/replay-equivalence.md`):
//! the fingerprint is bound to its log and that binding is revalidated before
//! any value compare; a divergence is reported at the first checkpoint where the
//! values parted; the observation encoding agrees with the family on which
//! differences are differences.
//!
//! The corpus declares its subjects in prose because a JSON fixture cannot carry
//! a reactive graph. This binding's copy of that declaration is
//! `replay.Accumulator`, which the in-source obligation tests use too — one
//! subject, so the canonical replay and the bare-clone tests cannot drift into
//! describing two different things.
//!
//! Paths are resolved at RUNTIME through `conformance_json.load`, never spelled
//! as a comptime constant, so `LAZILY_SPEC_CONFORMANCE_DIR` really moves these
//! replays and a perturbation probe can falsify them.

const std = @import("std");
const testing = std.testing;

const cj = @import("conformance_json.zig");
const replay = @import("replay.zig");

const Value = cj.Value;
const Accumulator = replay.Accumulator;
const Harness = replay.AccumulatorHarness;

const MAX_LOGS = 8;
const MAX_FINGERPRINTS = 8;

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---------------------------------------------------------------------------
// Obligations 1 and 2 — the ReplayHarness fixtures
// ---------------------------------------------------------------------------

const NamedLog = struct {
    name: []const u8,
    events: []replay.ReplayEvent,
    log: replay.ReplayLog,
};

const NamedFingerprint = struct {
    name: []const u8,
    fingerprint: replay.ReplayFingerprint,
};

fn optionalI64(object: Value, name: []const u8) !?i64 {
    const found = cj.field(object, name) orelse return null;
    if (found == .null) return null;
    return try cj.asI64(found);
}

fn buildEvents(allocator: std.mem.Allocator, raw: Value) ![]replay.ReplayEvent {
    const entries = try cj.asArray(raw);
    const events = try allocator.alloc(replay.ReplayEvent, entries.len);
    errdefer allocator.free(events);
    for (entries, 0..) |entry, index| {
        events[index] = .{
            .seq = try cj.asI64(try cj.required(entry, "seq")),
            .name = try cj.asStr(try cj.required(entry, "name")),
            // Every canonical log carries an integer payload; a fixture that
            // grew another shape should fail here rather than be coerced.
            .payload = .{ .int = try cj.asI64(try cj.required(entry, "payload")) },
        };
    }
    return events;
}

/// The subject's OBSERVED final sum, driven independently of the harness.
///
/// Read back through `observe()` rather than off the field, because `observe` is
/// what the fingerprint digests: this is the one place the recorded digest and
/// the corpus's declared final state are made to meet.
fn observedFinalSum(
    allocator: std.mem.Allocator,
    spec: Accumulator.Spec,
    log: replay.ReplayLog,
) !i64 {
    const subject = try Accumulator.create(spec, allocator);
    defer subject.destroy(allocator);
    for (log.events) |event| try subject.apply(event);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (try subject.observe(arena.allocator())) |observation| {
        if (eql(observation.label, "sum")) return observation.value.int;
    }
    return error.SubjectObservesNoSum;
}

const CheckpointSeqs = struct {
    actual: []const replay.ReplayCheckpoint,
};

fn assertCheckpointSeqs(context: CheckpointSeqs, expected: Value) anyerror!void {
    const want = try cj.asArray(expected);
    try testing.expectEqual(want.len, context.actual.len);
    for (want, context.actual) |declared, checkpoint| {
        try testing.expectEqual(try cj.asI64(declared), checkpoint.seq);
    }
}

/// The outcome vocabulary the corpus speaks, derived from the harness's error
/// VALUES rather than from a message — which is the point of keeping them
/// distinct in the first place.
fn outcomeOf(err: anyerror) ![]const u8 {
    return switch (err) {
        error.ReplayLogMismatch => "log_mismatch",
        error.ReplayStrideMismatch => "stride_mismatch",
        error.ReplayDivergence => "divergent",
        else => err,
    };
}

fn driveHarnessFixture(rel: []const u8, minimum_steps: usize) !void {
    var fixture = (try cj.load(rel)) orelse return;
    defer fixture.deinit();
    const allocator = testing.allocator;

    try testing.expectEqualStrings("Replay", try cj.asStr(try cj.required(fixture.value, "kind")));
    try testing.expectEqualStrings(
        "ReplayHarness",
        try cj.asStr(try cj.required(fixture.value, "model")),
    );

    const config = try cj.required(fixture.value, "config");
    const subject = try cj.asStr(try cj.required(config, "subject"));
    const drifting = eql(subject, "drifting_accumulator");
    if (!drifting and !eql(subject, "accumulator")) return error.UnknownCanonicalReplaySubject;
    const config_stride: usize = blk: {
        const declared = try optionalI64(config, "stride") orelse break :blk 1;
        break :blk @intCast(declared);
    };
    const config_drift_at: ?i64 = if (drifting)
        try cj.asI64(try cj.required(config, "drift_at"))
    else
        null;

    var logs: [MAX_LOGS]NamedLog = undefined;
    var log_count: usize = 0;
    defer {
        for (logs[0..log_count]) |entry| allocator.free(entry.events);
    }
    const declared_logs = try cj.required(config, "logs");
    var log_iterator = (switch (declared_logs) {
        .object => |object| object,
        else => return error.ExpectedLogsObject,
    }).iterator();
    while (log_iterator.next()) |entry| {
        if (log_count == MAX_LOGS) return error.TooManyCanonicalLogs;
        const events = try buildEvents(allocator, entry.value_ptr.*);
        errdefer allocator.free(events);
        logs[log_count] = .{
            .name = entry.key_ptr.*,
            .events = events,
            .log = try replay.ReplayLog.init(allocator, events),
        };
        log_count += 1;
    }
    try testing.expect(log_count > 0);

    var fingerprints: [MAX_FINGERPRINTS]NamedFingerprint = undefined;
    var fingerprint_count: usize = 0;
    defer {
        for (fingerprints[0..fingerprint_count]) |*entry| entry.fingerprint.deinit();
    }

    const Lookup = struct {
        fn log(all: []const NamedLog, name: []const u8) !replay.ReplayLog {
            for (all) |entry| {
                if (eql(entry.name, name)) return entry.log;
            }
            return error.UnknownCanonicalLogName;
        }
        fn fingerprint(
            all: []const NamedFingerprint,
            name: []const u8,
        ) !replay.ReplayFingerprint {
            for (all) |entry| {
                if (eql(entry.name, name)) return entry.fingerprint;
            }
            return error.UnknownCanonicalFingerprintName;
        }
    };

    const steps = try cj.asArray(try cj.required(fixture.value, "steps"));
    try testing.expect(steps.len >= minimum_steps);
    var executed: usize = 0;

    for (steps) |step| {
        const op = try cj.required(step, "op");
        const op_type = try cj.asStr(try cj.required(op, "type"));
        var expected = cj.AssertionKeys.init(rel, try cj.required(step, "expected"));

        if (eql(op_type, "log_digest_equal")) {
            const left = try Lookup.log(logs[0..log_count], try cj.asStr(try cj.required(op, "left")));
            const right = try Lookup.log(logs[0..log_count], try cj.asStr(try cj.required(op, "right")));
            const same = std.mem.eql(u8, &left.digest, &right.digest);
            try testing.expectEqual(
                try cj.asBool(try cj.required(step, "returns")),
                same,
            );
            try expected.finish();
            executed += 1;
            continue;
        }

        // Per-op overrides: `drift` and `stride` select the subject and the
        // sampling this step replays with, falling back to the fixture config.
        const spec = Accumulator.Spec{
            .drift_at = config_drift_at,
            .drift = try optionalI64(op, "drift") orelse 0,
        };
        const stride: usize = blk: {
            const declared = try optionalI64(op, "stride") orelse break :blk config_stride;
            break :blk @intCast(declared);
        };
        const harness = try Harness.init(allocator, Accumulator.create, spec, stride);
        const log = try Lookup.log(logs[0..log_count], try cj.asStr(try cj.required(op, "log")));

        if (eql(op_type, "record")) {
            if (fingerprint_count == MAX_FINGERPRINTS) return error.TooManyCanonicalFingerprints;
            var fingerprint = try harness.record(log);
            errdefer fingerprint.deinit();
            try expected.assertKey("outcome", "recorded");
            try expected.assertKeyWith(
                "checkpoint_seqs",
                CheckpointSeqs{ .actual = fingerprint.checkpoints },
                assertCheckpointSeqs,
            );
            try expected.assertKey("stride", fingerprint.stride);
            const final_sum = try observedFinalSum(allocator, spec, log);
            try expected.assertKey("final_sum", final_sum);
            // The fingerprint must have observed the value the subject ends on,
            // not merely SOME value — otherwise this fixture would accept a
            // harness that watched something else entirely.
            const declared_digest = try replay.canonicalDigest(allocator, .{ .int = final_sum });
            try testing.expectEqual(declared_digest, fingerprint.final().digestFor("sum").?);
            try expected.finish();
            fingerprints[fingerprint_count] = .{
                .name = try cj.asStr(try cj.required(op, "into")),
                .fingerprint = fingerprint,
            };
            fingerprint_count += 1;
            executed += 1;
            continue;
        }

        if (eql(op_type, "prove")) {
            const replays: usize = @intCast(try cj.asI64(try cj.required(op, "replays")));
            var proven = try harness.prove(log, replays);
            proven.deinit();
            try expected.assertKey("outcome", "ok");
            try expected.assertKey("divergences", @as(usize, 0));
            try expected.finish();
            executed += 1;
            continue;
        }

        const fingerprint = try Lookup.fingerprint(
            fingerprints[0..fingerprint_count],
            try cj.asStr(try cj.required(op, "fingerprint")),
        );

        if (eql(op_type, "verify")) {
            var report: replay.DivergenceReport = undefined;
            var first: ?replay.ReplayDivergence = null;
            var outcome: []const u8 = "ok";
            if (harness.verify(log, fingerprint, &report)) |_| {} else |err| {
                outcome = try outcomeOf(err);
                if (err == error.ReplayDivergence) first = report.first();
            }
            defer if (first != null) report.deinit();

            try expected.assertKey("outcome", outcome);
            if (first) |divergence| {
                try expected.assertKey("first_divergent_seq", divergence.seq);
                try expected.assertKey("first_divergent_label", divergence.label);
                try expected.assertKey("first_divergent_kind", divergence.kind);
            } else {
                try expected.assertKey("divergences", @as(usize, 0));
            }
            try expected.finish();
            executed += 1;
            continue;
        }

        if (eql(op_type, "check")) {
            // The reporting form collects value divergences instead of failing —
            // and still REFUSES a stale fingerprint, because an unanswerable
            // question is not a report.
            if (harness.check(log, fingerprint)) |collected| {
                var report = collected;
                defer report.deinit();
                try expected.assertKey("outcome", "ok");
                try expected.assertKey("divergences", report.len());
            } else |err| {
                try expected.assertKey("outcome", try outcomeOf(err));
                try expected.assertKey("divergences", @as(usize, 0));
            }
            try expected.finish();
            executed += 1;
            continue;
        }

        return error.UnknownCanonicalReplayOperation;
    }

    // Every step really ran: a loop that silently matched nothing would satisfy
    // each assertion above over an empty population.
    try testing.expectEqual(steps.len, executed);
}

test "canonical replay: a fingerprint is bound to the log that produced it" {
    try driveHarnessFixture("replay/fingerprint_log_binding.json", 8);
}

test "canonical replay: divergence is localized to its first checkpoint" {
    try driveHarnessFixture("replay/divergence_localization.json", 7);
}

// ---------------------------------------------------------------------------
// Obligation 3 — the canonical encoding's equality classes
// ---------------------------------------------------------------------------

/// Values are type-tagged in the fixture because JSON cannot distinguish int `1`
/// from float `1.0`, and integers carry decimal STRINGS so a value beyond 2^53
/// stays exact.
fn parseTagged(arena: std.mem.Allocator, tagged: Value) anyerror!replay.Value {
    const tag = try cj.asStr(try cj.required(tagged, "t"));
    if (eql(tag, "opaque")) return .opaque_value;

    if (eql(tag, "int")) {
        return .{ .int = try std.fmt.parseInt(i64, try cj.asStr(try cj.required(tagged, "v")), 10) };
    }
    if (eql(tag, "str")) return .{ .str = try cj.asStr(try cj.required(tagged, "v")) };
    if (eql(tag, "float")) {
        return .{ .float = try std.fmt.parseFloat(f64, try cj.asStr(try cj.required(tagged, "v"))) };
    }
    if (eql(tag, "bool")) return .{ .bool = try cj.asBool(try cj.required(tagged, "v")) };
    if (eql(tag, "bytes")) {
        const hex = try cj.asStr(try cj.required(tagged, "v"));
        const raw = try arena.alloc(u8, hex.len / 2);
        return .{ .bytes = try std.fmt.hexToBytes(raw, hex) };
    }
    if (eql(tag, "seq") or eql(tag, "set")) {
        const declared = try cj.asArray(try cj.required(tagged, "v"));
        const members = try arena.alloc(replay.Value, declared.len);
        for (declared, 0..) |member, index| members[index] = try parseTagged(arena, member);
        return if (eql(tag, "seq")) .{ .seq = members } else .{ .set = members };
    }
    if (eql(tag, "map")) {
        const declared = try cj.asArray(try cj.required(tagged, "v"));
        const entries = try arena.alloc(replay.MapEntry, declared.len);
        for (declared, 0..) |pair, index| {
            const parts = try cj.asArray(pair);
            if (parts.len != 2) return error.MalformedCanonicalMapEntry;
            entries[index] = .{
                .key = .{ .str = try cj.asStr(parts[0]) },
                .value = try parseTagged(arena, parts[1]),
            };
        }
        return .{ .map = entries };
    }
    return error.UnknownCanonicalValueTag;
}

fn namedValue(values: Value, name: []const u8) !Value {
    return cj.required(values, name);
}

test "canonical replay: the observation encoding's equality classes" {
    const rel = "replay/canonical_encoding_equality.json";
    var fixture = (try cj.load(rel)) orelse return;
    defer fixture.deinit();

    try testing.expectEqualStrings("Replay", try cj.asStr(try cj.required(fixture.value, "kind")));
    try testing.expectEqualStrings(
        "CanonicalEncoding",
        try cj.asStr(try cj.required(fixture.value, "model")),
    );

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const values = try cj.required(try cj.required(fixture.value, "config"), "values");
    const steps = try cj.asArray(try cj.required(fixture.value, "steps"));
    try testing.expect(steps.len >= 11);

    var saw_equal = false;
    var saw_different = false;
    var executed: usize = 0;

    for (steps) |step| {
        const op = try cj.required(step, "op");
        const op_type = try cj.asStr(try cj.required(op, "type"));
        const returns = try cj.asBool(try cj.required(step, "returns"));
        var expected = cj.AssertionKeys.init(rel, try cj.required(step, "expected"));

        if (eql(op_type, "digest_equal")) {
            const left = try parseTagged(
                arena.allocator(),
                try namedValue(values, try cj.asStr(try cj.required(op, "left"))),
            );
            const right = try parseTagged(
                arena.allocator(),
                try namedValue(values, try cj.asStr(try cj.required(op, "right"))),
            );
            const left_digest = try replay.canonicalDigest(testing.allocator, left);
            const right_digest = try replay.canonicalDigest(testing.allocator, right);
            const same = std.mem.eql(u8, &left_digest, &right_digest);
            try testing.expectEqual(returns, same);
            if (same) saw_equal = true else saw_different = true;
            try expected.finish();
            executed += 1;
            continue;
        }

        if (eql(op_type, "digest_defined")) {
            const value = try parseTagged(
                arena.allocator(),
                try namedValue(values, try cj.asStr(try cj.required(op, "value"))),
            );
            var defined = true;
            _ = replay.canonicalDigest(testing.allocator, value) catch |err| {
                if (err != error.ReplayEncoding) return err;
                defined = false;
            };
            try testing.expectEqual(returns, defined);
            try expected.assertKey("outcome", "encoding_error");
            try expected.finish();
            executed += 1;
            continue;
        }

        return error.UnknownCanonicalEncodingOperation;
    }

    try testing.expectEqual(steps.len, executed);
    // Both outcomes really occurred: a runner that only ever saw `false` would
    // pass every inequality claim with a completely broken encoding.
    try testing.expect(saw_equal);
    try testing.expect(saw_different);
}
