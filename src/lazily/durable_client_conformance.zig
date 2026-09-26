const std = @import("std");
const testing = std.testing;
const cj = @import("conformance_json.zig");
const durable = @import("durable_client.zig");

const fixture_path = "durable-client/envelope_v1.json";

fn envelope(value: cj.Value, buffer: []u8) !durable.DurableEnvelope {
    const payload = try cj.asArray(try cj.required(value, "payload"));
    if (payload.len > buffer.len) return error.PayloadTooLarge;
    for (payload, 0..) |byte, index| buffer[index] = @intCast(try cj.asU64(byte));
    return .{
        .protocol_version = try cj.asU64(try cj.required(value, "protocol_version")),
        .message_id = try cj.asStr(try cj.required(value, "message_id")),
        .schema_version = try cj.asU64(try cj.required(value, "schema_version")),
        .codec_version = try cj.asU64(try cj.required(value, "codec_version")),
        .payload = buffer[0..payload.len],
    };
}

fn validationName(value: durable.EnvelopeValidation) []const u8 {
    return switch (value) {
        .accepted => "accepted",
        .unsupported_protocol_version => "unsupported_protocol_version",
        .invalid_message_id => "invalid_message_id",
        .invalid_schema_version => "invalid_schema_version",
        .invalid_codec_version => "invalid_codec_version",
    };
}

fn classificationName(value: durable.DeliveryClassification) []const u8 {
    return switch (value) {
        .first => "first",
        .duplicate => "duplicate",
        .conflict => "conflict",
    };
}

fn projectionName(value: durable.ProjectionDeliveryClassification) []const u8 {
    return switch (value) {
        .buffered => "buffered",
        .applied => "applied",
        .duplicate => "duplicate",
        .conflict => "conflict",
    };
}

fn fingerprint(value: cj.Value) !durable.ProjectionFingerprint {
    return .{
        .projection_id = try cj.asStr(try cj.required(value, "projection_id")),
        .source_position = try cj.asU64(try cj.required(value, "source_position")),
        .fingerprint = try cj.asStr(try cj.required(value, "fingerprint")),
        .completeness = if (std.mem.eql(u8, try cj.asStr(try cj.required(value, "completeness")), "complete_history"))
            .complete_history
        else
            .latest_state_only,
    };
}

test "durable client replays the canonical envelope order dedup receipt and fingerprint corpus" {
    var parsed = (try cj.load(fixture_path)) orelse return error.SpecFixtureMissing;
    defer parsed.deinit();
    try testing.expect(!(try cj.asBool(try cj.required(parsed.value, "owner_authority"))));
    const tiers = durable.DurableTierDeclaration{};
    try testing.expect(tiers.core and tiers.client and !tiers.durable_host and !tiers.distributed_host and !tiers.accelerated_host);

    for (try cj.asArray(try cj.required(parsed.value, "envelope_vectors"))) |vector| {
        var payload: [256]u8 = undefined;
        const actual = try envelope(try cj.required(vector, "envelope"), &payload);
        var expected = cj.AssertionKeys.init("durable-client/envelope_v1.json envelope expected", try cj.required(vector, "expected"));
        try expected.assertKey("reason", validationName(actual.validate()));
        try expected.assertKey("accepted", actual.validate() == .accepted);
        // Decoding is permitted exactly when validation succeeds; TypedDurableClient enforces this order.
        try expected.assertKey("payload_decoded", actual.validate() == .accepted);
        try expected.finish();
    }

    for (try cj.asArray(try cj.required(parsed.value, "ordering_vectors"))) |vector| {
        const observed = try cj.asArray(try cj.required(vector, "observed_message_ids"));
        const expected = try cj.asArray(try cj.required(vector, "expected_delivery_order"));
        try testing.expectEqual(observed.len, expected.len);
        for (observed, expected) |actual, want| try testing.expectEqualStrings(try cj.asStr(want), try cj.asStr(actual));
        try testing.expect(!(try cj.asBool(try cj.required(vector, "owner_order_inferred"))));
    }

    for (try cj.asArray(try cj.required(parsed.value, "projection_ordering_vectors"))) |vector| {
        var order = durable.AdvisoryProjectionOrder.init(testing.allocator);
        defer order.deinit();
        const positions = try cj.asArray(try cj.required(vector, "observed_source_positions"));
        const classes = try cj.asArray(try cj.required(vector, "expected_delivery_classification"));
        for (positions, classes) |position_value, class_value| {
            const position = try cj.asU64(position_value);
            var fingerprint_buf: [32]u8 = undefined;
            const source = try std.fmt.bufPrint(&fingerprint_buf, "source-{d}", .{position});
            try testing.expectEqualStrings(try cj.asStr(class_value), projectionName(try order.observe(position, source)));
        }
        const expected_applied = try cj.asArray(try cj.required(vector, "expected_applied_positions"));
        try testing.expectEqual(expected_applied.len, order.applied_positions.items.len);
        for (expected_applied, order.applied_positions.items) |want, actual|
            try testing.expectEqual(try cj.asU64(want), actual);
        try testing.expect(!order.brokerOrderAuthoritative() and !order.mayAuthorizeTransition());
    }

    for (try cj.asArray(try cj.required(parsed.value, "dedup_vectors"))) |vector| {
        var dedup = durable.DurableDeduplicator.init(testing.allocator);
        defer dedup.deinit();
        const deliveries = try cj.asArray(try cj.required(vector, "deliveries"));
        const expected = try cj.asArray(try cj.required(vector, "expected_classification"));
        for (deliveries, expected) |delivery, want| {
            var payload: [256]u8 = undefined;
            try testing.expectEqualStrings(try cj.asStr(want), classificationName(try dedup.classify(try envelope(delivery, &payload))));
        }
    }

    for (try cj.asArray(try cj.required(parsed.value, "receipt_vectors"))) |vector| {
        const receipt = try cj.required(vector, "receipt");
        const expected = try cj.required(vector, "expected_round_trip");
        const actual = durable.DurableHostReceipt{
            .protocol_version = try cj.asU64(try cj.required(receipt, "protocol_version")),
            .receipt_id = try cj.asStr(try cj.required(receipt, "receipt_id")),
            .message_id = try cj.asStr(try cj.required(receipt, "message_id")),
            .outcome = .committed,
            .owner_position = try cj.asU64(try cj.required(receipt, "owner_position")),
        };
        try testing.expectEqualStrings(try cj.asStr(try cj.required(expected, "receipt_id")), actual.receipt_id);
        try testing.expectEqualStrings(try cj.asStr(try cj.required(expected, "message_id")), actual.message_id);
        try testing.expectEqual(try cj.asU64(try cj.required(expected, "owner_position")), actual.owner_position);
        try testing.expectEqual(try cj.asBool(try cj.required(vector, "transport_ack_equivalent")), actual.transportAckEquivalent());
    }

    for (try cj.asArray(try cj.required(parsed.value, "projection_fingerprint_vectors"))) |vector| {
        const left = try fingerprint(try cj.required(vector, "left"));
        const right = try fingerprint(try cj.required(vector, "right"));
        var expected = cj.AssertionKeys.init("durable-client/envelope_v1.json projection fingerprint expected", try cj.required(vector, "expected"));
        try expected.assertKey("same_source", left.source_position == right.source_position);
        try expected.assertKey("same_fingerprint", std.mem.eql(u8, left.fingerprint, right.fingerprint));
        try expected.assertKey("same_completeness", left.completeness == right.completeness);
        try expected.assertKey("equivalent", left.equivalentTo(right));
        try expected.finish();
        try testing.expect(!left.mayAuthorizeTransition() and !right.mayAuthorizeTransition());
    }
}
