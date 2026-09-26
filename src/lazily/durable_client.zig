const std = @import("std");

pub const durable_protocol_version: u64 = 1;

pub const DurableCapabilityTier = enum { core, client, durable_host, distributed_host, accelerated_host };
pub const DurableTierDeclaration = struct {
    core: bool = true,
    client: bool = true,
    durable_host: bool = false,
    distributed_host: bool = false,
    accelerated_host: bool = false,
};

/// Exact durable-envelope-v1 shape. It carries neither owner authority nor broker metadata.
pub const DurableEnvelope = struct {
    protocol_version: u64 = durable_protocol_version,
    message_id: []const u8,
    schema_version: u64,
    codec_version: u64,
    payload: []const u8,

    pub fn validate(self: DurableEnvelope) EnvelopeValidation {
        if (self.protocol_version != durable_protocol_version) return .unsupported_protocol_version;
        if (self.message_id.len == 0) return .invalid_message_id;
        if (self.schema_version == 0 or self.schema_version > std.math.maxInt(u32)) return .invalid_schema_version;
        if (self.codec_version == 0 or self.codec_version > std.math.maxInt(u32)) return .invalid_codec_version;
        return .accepted;
    }

    pub fn sameContent(self: DurableEnvelope, other: DurableEnvelope) bool {
        return self.protocol_version == other.protocol_version and
            self.schema_version == other.schema_version and
            self.codec_version == other.codec_version and
            std.mem.eql(u8, self.payload, other.payload);
    }
};

pub const EnvelopeValidation = enum {
    accepted,
    unsupported_protocol_version,
    invalid_message_id,
    invalid_schema_version,
    invalid_codec_version,
};

pub const DeliveryClassification = enum { first, duplicate, conflict };

const OwnedEnvelope = struct {
    protocol_version: u64,
    message_id: []u8,
    schema_version: u64,
    codec_version: u64,
    payload: []u8,

    fn view(self: OwnedEnvelope) DurableEnvelope {
        return .{ .protocol_version = self.protocol_version, .message_id = self.message_id, .schema_version = self.schema_version, .codec_version = self.codec_version, .payload = self.payload };
    }
};

pub const DurableDeduplicator = struct {
    allocator: std.mem.Allocator,
    seen: std.StringHashMap(OwnedEnvelope),

    pub fn init(allocator: std.mem.Allocator) DurableDeduplicator {
        return .{ .allocator = allocator, .seen = std.StringHashMap(OwnedEnvelope).init(allocator) };
    }

    pub fn deinit(self: *DurableDeduplicator) void {
        var iterator = self.seen.valueIterator();
        while (iterator.next()) |envelope| {
            self.allocator.free(envelope.message_id);
            self.allocator.free(envelope.payload);
        }
        self.seen.deinit();
    }

    pub fn classify(self: *DurableDeduplicator, envelope: DurableEnvelope) !DeliveryClassification {
        if (self.seen.get(envelope.message_id)) |prior| {
            return if (prior.view().sameContent(envelope)) .duplicate else .conflict;
        }
        const id = try self.allocator.dupe(u8, envelope.message_id);
        errdefer self.allocator.free(id);
        const payload = try self.allocator.dupe(u8, envelope.payload);
        errdefer self.allocator.free(payload);
        try self.seen.put(id, .{ .protocol_version = envelope.protocol_version, .message_id = id, .schema_version = envelope.schema_version, .codec_version = envelope.codec_version, .payload = payload });
        return .first;
    }
};

pub const BrokerPubAck = struct { stream: []const u8, sequence: u64, duplicate: bool = false };
pub const DurableReceiptOutcome = enum { committed, duplicate, conflict, rejected };
pub const DurableHostReceipt = struct {
    protocol_version: u64 = durable_protocol_version,
    receipt_id: []const u8,
    message_id: []const u8,
    outcome: DurableReceiptOutcome,
    owner_position: u64,
    pub fn transportAckEquivalent(_: DurableHostReceipt) bool {
        return false;
    }
};

pub const ProjectionCompleteness = enum { complete_history, latest_state_only };
pub const ProjectionFingerprint = struct {
    projection_id: []const u8,
    source_position: u64,
    fingerprint: []const u8,
    completeness: ProjectionCompleteness = .complete_history,
    pub fn equivalentTo(self: ProjectionFingerprint, other: ProjectionFingerprint) bool {
        return std.mem.eql(u8, self.projection_id, other.projection_id) and
            self.source_position == other.source_position and
            std.mem.eql(u8, self.fingerprint, other.fingerprint) and
            self.completeness == other.completeness;
    }
    pub fn mayAuthorizeTransition(_: ProjectionFingerprint) bool {
        return false;
    }
};

pub const ProjectionDeliveryClassification = enum { buffered, applied, duplicate, conflict };

pub const AdvisoryProjectionOrder = struct {
    allocator: std.mem.Allocator,
    applied_through: u64 = 0,
    pending: std.AutoHashMap(u64, []u8),
    applied: std.AutoHashMap(u64, []u8),
    applied_positions: std.ArrayList(u64) = .empty,

    pub fn init(allocator: std.mem.Allocator) AdvisoryProjectionOrder {
        return .{ .allocator = allocator, .pending = std.AutoHashMap(u64, []u8).init(allocator), .applied = std.AutoHashMap(u64, []u8).init(allocator) };
    }

    pub fn deinit(self: *AdvisoryProjectionOrder) void {
        var pending_values = self.pending.valueIterator();
        while (pending_values.next()) |value| self.allocator.free(value.*);
        var applied_values = self.applied.valueIterator();
        while (applied_values.next()) |value| self.allocator.free(value.*);
        self.pending.deinit();
        self.applied.deinit();
        self.applied_positions.deinit(self.allocator);
    }

    pub fn observe(self: *AdvisoryProjectionOrder, position: u64, fingerprint: []const u8) !ProjectionDeliveryClassification {
        if (self.applied.get(position)) |prior|
            return if (std.mem.eql(u8, prior, fingerprint)) .duplicate else .conflict;
        if (self.pending.get(position)) |prior|
            return if (std.mem.eql(u8, prior, fingerprint)) .duplicate else .conflict;
        if (position > self.applied_through + 1) {
            try self.pending.put(position, try self.allocator.dupe(u8, fingerprint));
            return .buffered;
        }
        if (position <= self.applied_through) return .conflict;
        try self.applyOne(position, try self.allocator.dupe(u8, fingerprint));
        while (self.pending.fetchRemove(self.applied_through + 1)) |entry|
            try self.applyOne(entry.key, entry.value);
        return .applied;
    }

    fn applyOne(self: *AdvisoryProjectionOrder, position: u64, fingerprint: []u8) !void {
        self.applied_through = position;
        try self.applied.put(position, fingerprint);
        try self.applied_positions.append(self.allocator, position);
    }

    pub fn brokerOrderAuthoritative(_: AdvisoryProjectionOrder) bool {
        return false;
    }
    pub fn mayAuthorizeTransition(_: AdvisoryProjectionOrder) bool {
        return false;
    }
};

/// An injected NATS-compatible raw transport. PubAck remains outside the envelope.
pub const NatsDurableClientTransport = struct {
    context: *anyopaque,
    publishFn: *const fn (*anyopaque, []const u8, DurableEnvelope) anyerror!BrokerPubAck,
    subscribeFn: *const fn (*anyopaque, []const u8, *const fn (DurableEnvelope) void) anyerror!void,
    pub fn publish(self: NatsDurableClientTransport, subject: []const u8, envelope: DurableEnvelope) !BrokerPubAck {
        return self.publishFn(self.context, subject, envelope);
    }
};

pub fn TypedDurableClient(comptime Ingress: type, comptime Projection: type) type {
    return struct {
        const Self = @This();
        transport: NatsDurableClientTransport,
        deduplicator: *DurableDeduplicator,
        encode: *const fn (Ingress, []u8) anyerror![]const u8,
        decode: *const fn ([]const u8) anyerror!Projection,

        pub fn publish(self: Self, subject: []const u8, message_id: []const u8, schema_version: u64, codec_version: u64, value: Ingress, buffer: []u8) !BrokerPubAck {
            const envelope = DurableEnvelope{ .message_id = message_id, .schema_version = schema_version, .codec_version = codec_version, .payload = try self.encode(value, buffer) };
            if (envelope.validate() != .accepted) return error.InvalidDurableEnvelope;
            return self.transport.publish(subject, envelope);
        }

        /// Validation precedes the typed decoder, so unknown protocols never touch payload bytes.
        pub fn decodeEnvelope(self: Self, envelope: DurableEnvelope) !struct {
            validation: EnvelopeValidation,
            classification: ?DeliveryClassification,
            value: ?Projection,
        } {
            const validation = envelope.validate();
            if (validation != .accepted)
                return .{ .validation = validation, .classification = null, .value = null };
            const classification = try self.deduplicator.classify(envelope);
            if (classification != .first)
                return .{ .validation = .accepted, .classification = classification, .value = null };
            return .{ .validation = .accepted, .classification = .first, .value = try self.decode(envelope.payload) };
        }

        pub fn mayAuthorizeTransition(_: Self) bool {
            return false;
        }
    };
}

test "durable client envelope dedup receipt fingerprint and tiers" {
    const testing = std.testing;
    const tiers = DurableTierDeclaration{};
    try testing.expect(tiers.core and tiers.client);
    try testing.expect(!tiers.durable_host and !tiers.distributed_host and !tiers.accelerated_host);
    const first = DurableEnvelope{ .message_id = "sample-owner/message-4", .schema_version = 7, .codec_version = 11, .payload = &.{65} };
    try testing.expectEqual(EnvelopeValidation.accepted, first.validate());
    var unknown = first;
    unknown.protocol_version = 2;
    try testing.expectEqual(EnvelopeValidation.unsupported_protocol_version, unknown.validate());
    var dedup = DurableDeduplicator.init(testing.allocator);
    defer dedup.deinit();
    try testing.expectEqual(DeliveryClassification.first, try dedup.classify(first));
    try testing.expectEqual(DeliveryClassification.duplicate, try dedup.classify(first));
    var changed = first;
    changed.payload = &.{66};
    try testing.expectEqual(DeliveryClassification.conflict, try dedup.classify(changed));
    const receipt = DurableHostReceipt{ .receipt_id = "receipt-1", .message_id = first.message_id, .outcome = .committed, .owner_position = 42 };
    try testing.expect(!receipt.transportAckEquivalent());
    const left = ProjectionFingerprint{ .projection_id = "orders", .source_position = 42, .fingerprint = "aabbccdd" };
    try testing.expect(left.equivalentTo(left));
    var latest = left;
    latest.completeness = .latest_state_only;
    try testing.expect(!left.equivalentTo(latest));
    try testing.expect(!left.mayAuthorizeTransition());
    var order = AdvisoryProjectionOrder.init(testing.allocator);
    defer order.deinit();
    try testing.expectEqual(ProjectionDeliveryClassification.buffered, try order.observe(2, "two"));
    try testing.expectEqual(ProjectionDeliveryClassification.applied, try order.observe(1, "one"));
    try testing.expectEqual(ProjectionDeliveryClassification.duplicate, try order.observe(2, "two"));
    try testing.expectEqualSlices(u64, &.{ 1, 2 }, order.applied_positions.items);
    try testing.expect(!order.brokerOrderAuthoritative() and !order.mayAuthorizeTransition());
}
