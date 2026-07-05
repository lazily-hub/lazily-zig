const std = @import("std");

// Causal receipt projection — the Zig counterpart of `lazily-spec/protocol.md`
// § "Causal Receipts" and the Lean model in `lazily-formal/LazilyFormal/Receipt.lean`.
//
// Receipts record the outcome of a command or effect request keyed by a stable
// `causation_id`. This is deliberately NOT a transport ACK plane: `observed`
// and `accepted` are non-terminal progress observations; `applied` and
// `rejected` are terminal outcomes. Stale-generation receipts are ignored by
// the current projection, duplicate receipt ids are idempotent no-ops, and two
// distinct terminal outcomes for the same causation id + generation fail
// closed instead of selecting a winner — the exact rules `Receipt.lean` proves.

/// Generic receipt outcomes. `observed` / `accepted` are non-terminal; `applied`
/// / `rejected` are terminal.
pub const ReceiptOutcome = enum {
    observed,
    accepted,
    applied,
    rejected,

    /// Whether this outcome completes the causation. Mirrors
    /// `ReceiptOutcome.isTerminal` in `lazily-formal/LazilyFormal/Receipt.lean`.
    pub fn isTerminal(self: ReceiptOutcome) bool {
        return switch (self) {
            .observed, .accepted => false,
            .applied, .rejected => true,
        };
    }

    /// Wire string used by the canonical externally-tagged JSON form.
    pub fn wireName(self: ReceiptOutcome) []const u8 {
        return switch (self) {
            .observed => "observed",
            .accepted => "accepted",
            .applied => "applied",
            .rejected => "rejected",
        };
    }

    pub fn fromWireName(name: []const u8) error{UnknownReceiptOutcome}!ReceiptOutcome {
        if (std.mem.eql(u8, name, "observed")) return .observed;
        if (std.mem.eql(u8, name, "accepted")) return .accepted;
        if (std.mem.eql(u8, name, "applied")) return .applied;
        if (std.mem.eql(u8, name, "rejected")) return .rejected;
        return error.UnknownReceiptOutcome;
    }

    pub fn jsonStringify(self: ReceiptOutcome, jw: anytype) !void {
        try jw.write(self.wireName());
    }
};

/// One causal receipt event. Mirrors `CausalReceipt` in
/// `lazily-spec/schemas/receipts.json`.
pub const CausalReceipt = struct {
    /// Idempotency key for this receipt event. Duplicate `receipt_id`s are
    /// no-ops (theorem `duplicate_receipt_noop` in `Receipt.lean`).
    receipt_id: []const u8,
    /// Stable id of the command, event, or effect request this receipt
    /// observes.
    causation_id: []const u8,
    /// Peer, process, or subsystem that produced the receipt.
    observer: []const u8,
    /// Monotonic producer/editor generation. Consumers discard receipts whose
    /// generation does not match the current authority generation for the
    /// causation id (theorem `stale_generation_discarded`).
    generation: u64,
    /// Receipt outcome.
    outcome: ReceiptOutcome,
    /// Optional human/debug rejection reason; `null` when absent. Always
    /// emitted to match the JSON schema (it is a required field).
    reason: ?[]const u8 = null,
    /// Optional hash of the state/payload the receipt observed; `null` when
    /// absent. Always emitted to match the JSON schema.
    payload_hash: ?[]const u8 = null,

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !CausalReceipt {
        return .{
            .receipt_id = try asString(try field(value, "receipt_id")),
            .causation_id = try asString(try field(value, "causation_id")),
            .observer = try asString(try field(value, "observer")),
            .generation = try asU64(try field(value, "generation")),
            .outcome = try ReceiptOutcome.fromWireName(
                try asString(try field(value, "outcome")),
            ),
            .reason = try optionalString(allocator, objectGet(value, "reason")),
            .payload_hash = try optionalString(allocator, objectGet(value, "payload_hash")),
        };
    }

    pub fn jsonStringify(self: CausalReceipt, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("receipt_id");
        try jw.write(self.receipt_id);
        try jw.objectField("causation_id");
        try jw.write(self.causation_id);
        try jw.objectField("observer");
        try jw.write(self.observer);
        try jw.objectField("generation");
        try jw.write(self.generation);
        try jw.objectField("outcome");
        try jw.write(self.outcome);
        try jw.objectField("reason");
        if (self.reason) |r| {
            try jw.write(r);
        } else {
            try jw.write(null);
        }
        try jw.objectField("payload_hash");
        if (self.payload_hash) |p| {
            try jw.write(p);
        } else {
            try jw.write(null);
        }
        try jw.endObject();
    }
};

/// Wire body for the externally-tagged `CausalReceipts` envelope. Matches
/// `CausalReceipts` in `lazily-spec/schemas/receipts.json`.
pub const CausalReceipts = struct {
    receipts: []const CausalReceipt,

    pub fn init(receipts: []const CausalReceipt) CausalReceipts {
        return .{ .receipts = receipts };
    }

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !CausalReceipts {
        return .{ .receipts = try parseReceipts(allocator, try field(value, "receipts")) };
    }

    pub fn jsonStringify(self: CausalReceipts, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("receipts");
        try jw.write(self.receipts);
        try jw.endObject();
    }
};

/// Externally-tagged receipt wire message: `{"CausalReceipts": {...}}`.
/// Separate from `IpcMessage` — receipts are a projection plane, not a graph
/// state plane (mirrors lazily-rs `ReceiptMessage`).
pub const ReceiptMessage = union(enum) {
    CausalReceipts: CausalReceipts,

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !ReceiptMessage {
        const tagged = try singleField(value);
        if (std.mem.eql(u8, tagged.name, "CausalReceipts")) {
            return .{ .CausalReceipts = try CausalReceipts.fromJson(allocator, tagged.value) };
        }
        return error.UnknownReceiptMessage;
    }

    pub fn jsonStringify(self: ReceiptMessage, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .CausalReceipts => |body| {
                try jw.objectField("CausalReceipts");
                try jw.write(body);
            },
        }
        try jw.endObject();
    }
};

/// Result of applying one receipt to a projection. Mirrors `ApplyResult` in
/// `Receipt.lean`.
pub const ReceiptApplyStatus = union(enum) {
    /// Receipt was accepted into the authoritative projection.
    recorded,
    /// Same `receipt_id` was already seen (idempotent no-op).
    duplicate,
    /// Receipt belongs to a generation other than the current authority.
    stale_generation: struct {
        expected: u64,
        actual: u64,
    },
    /// A different terminal outcome already exists for this causation id +
    /// generation; the projection fails closed.
    terminal_conflict: struct {
        causation_id: []const u8,
        existing: ReceiptOutcome,
        incoming: ReceiptOutcome,
    },
};

/// Folded receipt projection. The pure kernel mirrors `Receipt.lean`'s `apply`;
/// this struct adds the storage a real consumer folds receipts into.
///
/// Memory ownership: each of the three receipt maps owns its OWN independent
/// copy of every stored receipt (strings and all). `stale_receipt_ids` owns
/// only its keys. `deinit` walks each map once and frees what it owns — no
/// aliasing between maps.
pub const ReceiptProjection = struct {
    allocator: std.mem.Allocator,
    receipts_by_id: std.StringHashMapUnmanaged(CausalReceipt) = .empty,
    latest_by_causation: std.StringHashMapUnmanaged(CausalReceipt) = .empty,
    terminal_by_causation: std.StringHashMapUnmanaged(CausalReceipt) = .empty,
    stale_receipt_ids: std.StringHashMapUnmanaged(void) = .empty,

    pub fn init(allocator: std.mem.Allocator) ReceiptProjection {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ReceiptProjection) void {
        // receipts_by_id: keys alias the stored value's receipt_id, so we only
        // free the value payloads here.
        var receipts_it = self.receipts_by_id.valueIterator();
        while (receipts_it.next()) |r| freeReceipt(self.allocator, r);
        self.receipts_by_id.deinit(self.allocator);

        // latest_by_causation: owns both key (causation_id) and value (a full
        // receipt copy). The value's causation_id aliases the map key — free
        // the value, then the key.
        var latest_it = self.latest_by_causation.iterator();
        while (latest_it.next()) |entry| {
            freeReceipt(self.allocator, entry.value_ptr);
        }
        self.latest_by_causation.deinit(self.allocator);

        // terminal_by_causation: same shape as latest_by_causation.
        var terminal_it = self.terminal_by_causation.iterator();
        while (terminal_it.next()) |entry| {
            freeReceipt(self.allocator, entry.value_ptr);
        }
        self.terminal_by_causation.deinit(self.allocator);

        // stale_receipt_ids: keys only.
        var stale_it = self.stale_receipt_ids.keyIterator();
        while (stale_it.next()) |k| self.allocator.free(k.*);
        self.stale_receipt_ids.deinit(self.allocator);

        self.* = undefined;
    }

    /// Apply one receipt against the projection. When `current_generation` is
    /// `null`, the generation guard is disabled (every receipt is treated as
    /// current — useful for tests that just replay a fixture). The reducer is
    /// the Zig mirror of `apply` in `Receipt.lean`.
    pub fn observe(
        self: *ReceiptProjection,
        current_generation: ?u64,
        incoming: CausalReceipt,
    ) error{OutOfMemory}!ReceiptApplyStatus {
        if (self.receipts_by_id.contains(incoming.receipt_id) or
            self.stale_receipt_ids.contains(incoming.receipt_id))
        {
            return .duplicate;
        }

        if (current_generation) |expected| {
            if (incoming.generation != expected) {
                const stale_key = try self.allocator.dupe(u8, incoming.receipt_id);
                errdefer self.allocator.free(stale_key);
                try self.stale_receipt_ids.put(self.allocator, stale_key, {});
                return .{ .stale_generation = .{ .expected = expected, .actual = incoming.generation } };
            }
        }

        if (incoming.outcome.isTerminal()) {
            if (self.terminal_by_causation.get(incoming.causation_id)) |existing| {
                if (existing.outcome != incoming.outcome) {
                    return .{
                        .terminal_conflict = .{
                            .causation_id = incoming.causation_id,
                            .existing = existing.outcome,
                            .incoming = incoming.outcome,
                        },
                    };
                }
            }
        }

        // receipts_by_id: owns one independent full copy. The map key aliases
        // that copy's receipt_id, so the value owns the key slice.
        const stored_for_id = try dupReceipt(self.allocator, incoming);
        try self.receipts_by_id.put(self.allocator, stored_for_id.receipt_id, stored_for_id);
        errdefer {
            if (self.receipts_by_id.fetchRemove(incoming.receipt_id)) |kv| {
                freeReceiptValue(self.allocator, kv.value);
            }
        }

        // terminal_by_causation: insert only on the first terminal observation
        // for this causation id. A second terminal with the same outcome is
        // recorded idempotently in receipts_by_id but does not replace the
        // authoritative terminal handle (keeps `terminal_for` stable, matching
        // the Lean model's "first terminal wins" rule). Same outcome ⇒ no
        // conflict; a different outcome returned `.terminal_conflict` above.
        if (incoming.outcome.isTerminal()) {
            const gop = try self.terminal_by_causation.getOrPut(self.allocator, incoming.causation_id);
            if (!gop.found_existing) {
                const stored_for_terminal = try dupReceipt(self.allocator, incoming);
                errdefer freeReceipt(self.allocator, &stored_for_terminal);
                // The map temporarily owns the lookup key aliasing
                // `incoming.causation_id` (borrowed). Replace it with an owned
                // copy via the stored receipt's slice so deinit can free it.
                gop.key_ptr.* = stored_for_terminal.causation_id;
                gop.value_ptr.* = stored_for_terminal;
            }
        }
        errdefer {
            if (incoming.outcome.isTerminal()) {
                if (self.terminal_by_causation.fetchRemove(incoming.causation_id)) |kv| {
                    freeReceiptValue(self.allocator, kv.value);
                }
            }
        }

        // latest_by_causation: replace any prior entry. It owns its own
        // independent copy + key, so we free the prior one in full.
        if (self.latest_by_causation.fetchRemove(incoming.causation_id)) |prior| {
            freeReceiptValue(self.allocator, prior.value);
        }
        const stored_for_latest = try dupReceipt(self.allocator, incoming);
        errdefer freeReceiptValue(self.allocator, stored_for_latest);
        try self.latest_by_causation.put(
            self.allocator,
            stored_for_latest.causation_id,
            stored_for_latest,
        );

        return .recorded;
    }

    /// Latest recorded receipt for a causation id, terminal or non-terminal.
    pub fn latestFor(self: *const ReceiptProjection, causation_id: []const u8) ?CausalReceipt {
        return self.latest_by_causation.get(causation_id);
    }

    /// Terminal receipt for a causation id, if any.
    pub fn terminalFor(self: *const ReceiptProjection, causation_id: []const u8) ?CausalReceipt {
        return self.terminal_by_causation.get(causation_id);
    }

    /// Whether a receipt id has already been seen (recorded or stale).
    pub fn containsReceipt(self: *const ReceiptProjection, receipt_id: []const u8) bool {
        return self.receipts_by_id.contains(receipt_id) or
            self.stale_receipt_ids.contains(receipt_id);
    }

    /// Number of currently-recorded (non-stale) receipts.
    pub fn recordedCount(self: *const ReceiptProjection) usize {
        return self.receipts_by_id.count();
    }

    /// Number of stale receipt ids retained for audit/debug.
    pub fn staleCount(self: *const ReceiptProjection) usize {
        return self.stale_receipt_ids.count();
    }
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn dupReceipt(allocator: std.mem.Allocator, r: CausalReceipt) !CausalReceipt {
    var out = r;
    out.receipt_id = try allocator.dupe(u8, r.receipt_id);
    errdefer allocator.free(out.receipt_id);
    out.causation_id = try allocator.dupe(u8, r.causation_id);
    errdefer allocator.free(out.causation_id);
    out.observer = try allocator.dupe(u8, r.observer);
    errdefer allocator.free(out.observer);
    out.reason = if (r.reason) |s| try allocator.dupe(u8, s) else null;
    errdefer if (out.reason) |s| allocator.free(s);
    out.payload_hash = if (r.payload_hash) |s| try allocator.dupe(u8, s) else null;
    return out;
}

fn freeReceipt(allocator: std.mem.Allocator, r: *CausalReceipt) void {
    allocator.free(r.receipt_id);
    allocator.free(r.causation_id);
    allocator.free(r.observer);
    if (r.reason) |s| allocator.free(s);
    if (r.payload_hash) |s| allocator.free(s);
    r.* = undefined;
}

/// Convenience overload for by-value receipts (e.g. the `KV` returned by
/// `fetchRemove`). Frees the owned slices without resetting a storage slot.
fn freeReceiptValue(allocator: std.mem.Allocator, r: CausalReceipt) void {
    allocator.free(r.receipt_id);
    allocator.free(r.causation_id);
    allocator.free(r.observer);
    if (r.reason) |s| allocator.free(s);
    if (r.payload_hash) |s| allocator.free(s);
}

fn parseReceipts(allocator: std.mem.Allocator, value: std.json.Value) ![]const CausalReceipt {
    switch (value) {
        .array => |array| {
            const out = try allocator.alloc(CausalReceipt, array.items.len);
            for (array.items, out) |item, *receipt| {
                receipt.* = try CausalReceipt.fromJson(allocator, item);
            }
            return out;
        },
        else => return error.ExpectedArray,
    }
}

const TaggedValue = struct {
    name: []const u8,
    value: std.json.Value,
};

fn singleField(value: std.json.Value) !TaggedValue {
    switch (value) {
        .object => |object| {
            if (object.count() != 1) return error.ExpectedSingleFieldObject;
            var iter = object.iterator();
            const entry = iter.next() orelse return error.ExpectedSingleFieldObject;
            return .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* };
        },
        else => return error.ExpectedObject,
    }
}

fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    switch (value) {
        .object => |object| return object.get(name) orelse error.MissingField,
        else => return error.ExpectedObject,
    }
}

fn objectGet(value: std.json.Value, name: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(name),
        else => null,
    };
}

fn asString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}

fn asU64(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |n| if (n >= 0) @as(u64, @intCast(n)) else error.ExpectedUnsignedInteger,
        .number_string => |s| try std.fmt.parseInt(u64, s, 10),
        else => error.ExpectedUnsignedInteger,
    };
}

/// Read an optional string field. Returns `null` for an explicit JSON `null`
/// or an absent field. The returned slice is borrowed from `value`'s arena —
/// callers (e.g. `dupReceipt`) copy it before escaping the parse lifetime.
fn optionalString(
    _: std.mem.Allocator,
    value: ?std.json.Value,
) !?[]const u8 {
    if (value) |v| {
        switch (v) {
            .null => return null,
            .string => |s| return s,
            else => return error.ExpectedStringOrNull,
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "lazily/receipt: ReceiptOutcome terminality matches the Lean model" {
    // Mirrors the `observed_nonterminal` / `accepted_nonterminal` /
    // `applied_terminal` / `rejected_terminal` theorems in `Receipt.lean`.
    try std.testing.expect(!ReceiptOutcome.observed.isTerminal());
    try std.testing.expect(!ReceiptOutcome.accepted.isTerminal());
    try std.testing.expect(ReceiptOutcome.applied.isTerminal());
    try std.testing.expect(ReceiptOutcome.rejected.isTerminal());
}

test "lazily/receipt: ReceiptOutcome round-trips its wire name" {
    const all = [_]ReceiptOutcome{ .observed, .accepted, .applied, .rejected };
    for (all) |o| {
        try std.testing.expectEqual(o, try ReceiptOutcome.fromWireName(o.wireName()));
    }
    try std.testing.expectError(
        error.UnknownReceiptOutcome,
        ReceiptOutcome.fromWireName("delivered"),
    );
}

test "lazily/receipt: causal_receipts conformance fixture round-trips" {
    // Cross-sibling byte contract: the canonical wire shape from
    // `lazily-spec/conformance/receipts/causal_receipts.json` must decode and
    // re-encode byte-identically.
    const allocator = std.testing.allocator;

    const fixture_path = try std.fmt.allocPrint(
        allocator,
        "../lazily-spec/conformance/receipts/causal_receipts.json",
        .{},
    );
    defer allocator.free(fixture_path);

    const fixture_raw = try readFixtureFile(fixture_path);
    defer allocator.free(fixture_raw);

    var parsed_fixture = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        fixture_raw,
        .{ .allocate = .alloc_always },
    );
    defer parsed_fixture.deinit();

    const wire_json = try std.json.Stringify.valueAlloc(
        allocator,
        try field(parsed_fixture.value, "wire"),
        .{},
    );
    defer allocator.free(wire_json);

    var parsed_message = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        wire_json,
        .{ .allocate = .alloc_always },
    );
    defer parsed_message.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const message = try ReceiptMessage.fromJson(arena.allocator(), parsed_message.value);

    const encoded = try std.json.Stringify.valueAlloc(allocator, message, .{});
    defer allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, wire_json, encoded);

    // Fixture assertions (mirrors the lazily-spec `assertions` block).
    const body = message.CausalReceipts;
    try std.testing.expectEqual(@as(usize, 4), body.receipts.len);

    try std.testing.expectEqualStrings(
        "receipt-stale",
        body.receipts[3].receipt_id,
    );
    try std.testing.expectEqual(@as(u64, 6), body.receipts[3].generation);
    try std.testing.expectEqual(ReceiptOutcome.rejected, body.receipts[3].outcome);
    try std.testing.expect(body.receipts[3].reason != null);
    try std.testing.expect(body.receipts[3].payload_hash == null);

    try std.testing.expectEqual(@as(u64, 7), body.receipts[0].generation);
    try std.testing.expectEqual(ReceiptOutcome.observed, body.receipts[0].outcome);
    try std.testing.expectEqual(ReceiptOutcome.accepted, body.receipts[1].outcome);
    try std.testing.expectEqual(ReceiptOutcome.applied, body.receipts[2].outcome);
    try std.testing.expectEqualStrings(
        "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        body.receipts[2].payload_hash.?,
    );
}

test "lazily/receipt: projection records non-terminal then terminal" {
    // Mirrors `nonterminal_records_without_terminal_conflict` +
    // `first_terminal_records` in `Receipt.lean`.
    const allocator = std.testing.allocator;
    var projection = ReceiptProjection.init(allocator);
    defer projection.deinit();

    const observed = CausalReceipt{
        .receipt_id = "receipt-observed",
        .causation_id = "patch-123",
        .observer = "editor",
        .generation = 7,
        .outcome = .observed,
    };
    try std.testing.expectEqual(
        ReceiptApplyStatus.recorded,
        try projection.observe(Some(7), observed),
    );

    const applied = CausalReceipt{
        .receipt_id = "receipt-applied",
        .causation_id = "patch-123",
        .observer = "editor",
        .generation = 7,
        .outcome = .applied,
        .payload_hash = "sha256:abc",
    };
    try std.testing.expectEqual(
        ReceiptApplyStatus.recorded,
        try projection.observe(Some(7), applied),
    );

    try std.testing.expectEqual(
        ReceiptOutcome.applied,
        projection.latestFor("patch-123").?.outcome,
    );
    try std.testing.expectEqual(
        ReceiptOutcome.applied,
        projection.terminalFor("patch-123").?.outcome,
    );
    try std.testing.expect(projection.containsReceipt("receipt-observed"));
    try std.testing.expect(projection.containsReceipt("receipt-applied"));
    try std.testing.expectEqual(@as(usize, 2), projection.recordedCount());
    try std.testing.expectEqual(@as(usize, 0), projection.staleCount());
}

test "lazily/receipt: stale generation is discarded but retained as audit id" {
    // Mirrors `stale_generation_discarded`.
    const allocator = std.testing.allocator;
    var projection = ReceiptProjection.init(allocator);
    defer projection.deinit();

    const stale = CausalReceipt{
        .receipt_id = "receipt-stale",
        .causation_id = "patch-123",
        .observer = "editor",
        .generation = 6,
        .outcome = .rejected,
        .reason = "stale generation",
    };
    try std.testing.expectEqual(
        ReceiptApplyStatus{ .stale_generation = .{ .expected = 7, .actual = 6 } },
        try projection.observe(Some(7), stale),
    );

    try std.testing.expect(projection.terminalFor("patch-123") == null);
    try std.testing.expect(projection.latestFor("patch-123") == null);
    try std.testing.expect(projection.containsReceipt("receipt-stale"));
    try std.testing.expectEqual(@as(usize, 1), projection.staleCount());
    try std.testing.expectEqual(@as(usize, 0), projection.recordedCount());
}

test "lazily/receipt: duplicate receipt id is a no-op" {
    // Mirrors `duplicate_receipt_noop`.
    const allocator = std.testing.allocator;
    var projection = ReceiptProjection.init(allocator);
    defer projection.deinit();

    const receipt = CausalReceipt{
        .receipt_id = "receipt-1",
        .causation_id = "patch-123",
        .observer = "editor",
        .generation = 7,
        .outcome = .accepted,
    };
    try std.testing.expectEqual(
        ReceiptApplyStatus.recorded,
        try projection.observe(Some(7), receipt),
    );
    try std.testing.expectEqual(
        ReceiptApplyStatus.duplicate,
        try projection.observe(Some(7), receipt),
    );
    try std.testing.expectEqual(@as(usize, 1), projection.recordedCount());
}

test "lazily/receipt: conflicting terminal receipts fail closed" {
    // Mirrors `distinct_terminal_conflicts`.
    const allocator = std.testing.allocator;
    var projection = ReceiptProjection.init(allocator);
    defer projection.deinit();

    const applied = CausalReceipt{
        .receipt_id = "receipt-applied",
        .causation_id = "patch-123",
        .observer = "editor",
        .generation = 7,
        .outcome = .applied,
    };
    try std.testing.expectEqual(
        ReceiptApplyStatus.recorded,
        try projection.observe(Some(7), applied),
    );

    const rejected = CausalReceipt{
        .receipt_id = "receipt-rejected",
        .causation_id = "patch-123",
        .observer = "editor",
        .generation = 7,
        .outcome = .rejected,
    };
    try std.testing.expectEqual(
        ReceiptApplyStatus{
            .terminal_conflict = .{
                .causation_id = "patch-123",
                .existing = .applied,
                .incoming = .rejected,
            },
        },
        try projection.observe(Some(7), rejected),
    );
    try std.testing.expect(!projection.containsReceipt("receipt-rejected"));
    try std.testing.expectEqual(@as(usize, 1), projection.recordedCount());
    try std.testing.expectEqual(
        ReceiptOutcome.applied,
        projection.terminalFor("patch-123").?.outcome,
    );
}

test "lazily/receipt: same-terminal re-observation is idempotent" {
    // Two receipts with the same terminal outcome but distinct receipt ids are
    // both recorded (no conflict). The terminal projection stays at that
    // outcome.
    const allocator = std.testing.allocator;
    var projection = ReceiptProjection.init(allocator);
    defer projection.deinit();

    const a = CausalReceipt{
        .receipt_id = "receipt-applied-a",
        .causation_id = "patch-123",
        .observer = "editor",
        .generation = 7,
        .outcome = .applied,
    };
    const b = CausalReceipt{
        .receipt_id = "receipt-applied-b",
        .causation_id = "patch-123",
        .observer = "editor",
        .generation = 7,
        .outcome = .applied,
    };
    try std.testing.expectEqual(
        ReceiptApplyStatus.recorded,
        try projection.observe(Some(7), a),
    );
    try std.testing.expectEqual(
        ReceiptApplyStatus.recorded,
        try projection.observe(Some(7), b),
    );
    try std.testing.expectEqual(@as(usize, 2), projection.recordedCount());
    try std.testing.expectEqual(
        ReceiptOutcome.applied,
        projection.terminalFor("patch-123").?.outcome,
    );
}

test "lazily/receipt: ReceiptMessage uses externally-tagged wire shape" {
    const allocator = std.testing.allocator;
    const message = ReceiptMessage{ .CausalReceipts = CausalReceipts.init(&.{
        CausalReceipt{
            .receipt_id = "receipt-applied",
            .causation_id = "patch-123",
            .observer = "editor",
            .generation = 7,
            .outcome = .applied,
        },
    }) };

    const encoded = try std.json.Stringify.valueAlloc(allocator, message, .{});
    defer allocator.free(encoded);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, encoded, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const decoded = try ReceiptMessage.fromJson(arena.allocator(), parsed.value);
    try std.testing.expect(decoded == .CausalReceipts);
    try std.testing.expectEqual(@as(usize, 1), decoded.CausalReceipts.receipts.len);

    const receipt_json = try std.json.Stringify.valueAlloc(
        allocator,
        parsed.value.object.get("CausalReceipts").?.object.get("receipts").?.array.items[0],
        .{},
    );
    defer allocator.free(receipt_json);
    try std.testing.expect(std.mem.indexOf(u8, receipt_json, "\"outcome\":\"applied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt_json, "\"reason\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt_json, "\"payload_hash\":null") != null);
}

test "lazily/receipt: replaying the conformance fixture into a projection yields the asserted outcome" {
    // End-to-end: decode the fixture's `wire` body into `CausalReceipts`,
    // fold each receipt into a `ReceiptProjection` seeded with the fixture's
    // current generation, and verify the projection agrees with the
    // fixture's `assertions` block.
    const allocator = std.testing.allocator;

    const fixture_path = try std.fmt.allocPrint(
        allocator,
        "../lazily-spec/conformance/receipts/causal_receipts.json",
        .{},
    );
    defer allocator.free(fixture_path);
    const fixture_raw = try readFixtureFile(fixture_path);
    defer allocator.free(fixture_raw);

    var parsed_fixture = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        fixture_raw,
        .{ .allocate = .alloc_always },
    );
    defer parsed_fixture.deinit();
    const root = parsed_fixture.value;

    const assertions = try field(root, "assertions");
    const current_generation = try asU64(try field(assertions, "current_generation"));
    const expected_count = try asU64(try field(assertions, "receipt_count"));

    const wire = try field(root, "wire");
    var wire_arena = std.heap.ArenaAllocator.init(allocator);
    defer wire_arena.deinit();
    const body = try CausalReceipts.fromJson(
        wire_arena.allocator(),
        try field(wire, "CausalReceipts"),
    );

    var projection = ReceiptProjection.init(allocator);
    defer projection.deinit();

    var applied_count: usize = 0;
    var stale_count: usize = 0;
    for (body.receipts) |r| {
        const status = try projection.observe(Some(current_generation), r);
        switch (status) {
            .recorded => applied_count += 1,
            .stale_generation => stale_count += 1,
            .duplicate, .terminal_conflict => {},
        }
    }

    try std.testing.expectEqual(@as(usize, expected_count), body.receipts.len);
    try std.testing.expectEqual(@as(usize, 3), applied_count); // observed + accepted + applied
    try std.testing.expectEqual(@as(usize, 1), stale_count); // receipt-stale

    const terminal = projection.terminalFor("patch-123").?;
    try std.testing.expectEqual(ReceiptOutcome.applied, terminal.outcome);
    try std.testing.expectEqualStrings(
        "sha256:2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        terminal.payload_hash.?,
    );

    const stale_ids = try asArray(try field(assertions, "stale_receipt_ids"));
    try std.testing.expectEqual(@as(usize, 1), stale_ids.len);
    try std.testing.expectEqualStrings("receipt-stale", try asString(stale_ids[0]));
    try std.testing.expect(projection.containsReceipt("receipt-stale"));
}

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

fn Some(g: u64) ?u64 {
    return g;
}

fn asArray(value: std.json.Value) ![]const std.json.Value {
    return switch (value) {
        .array => |a| a.items,
        else => error.ExpectedArray,
    };
}

fn readFixtureFile(path: []const u8) ![]u8 {
    const builtin = @import("builtin");
    if (comptime builtin.zig_version.minor >= 16) {
        return std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            path,
            std.testing.allocator,
            .limited(1024 * 1024),
        );
    }
    return std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024 * 1024);
}
