//! Replay-equivalence proof for a rebuilt graph (`#lzreplayzig`).
//!
//! `../lazily-spec/docs/replay-equivalence.md` states the contract:
//!
//!     Given the same event log, a REBUILT graph observes the same values at
//!     every checkpoint. Any deviation is a defect in the graph, not a
//!     tolerance.
//!
//! and three obligations follow from it. This module is how this binding
//! *proves* that statement instead of asserting it.
//!
//! 1. **The fingerprint is bound to the log that produced it.** The discipline
//!    is taken from `tsift`, whose cached excerpts are trustworthy because every
//!    one records a body hash and revalidates it against the source bytes before
//!    the excerpt is returned. Here the event log is the source bytes:
//!    `ReplayFingerprint` carries `log_digest`, and every compare revalidates it
//!    FIRST — `error.ReplayLogMismatch`, and no value is looked at. Both halves
//!    matter: `[+1,+2,+3]` and `[+3,+2,+1]` settle to the same sum, so a
//!    value-only comparison would pass and certify nothing about the log in
//!    front of it, while a harness that compared anyway and reported the
//!    difference as a divergence would blame the graph for a stale artifact.
//!
//! 2. **Divergence is localized to the first diverging checkpoint.** A
//!    fingerprint covering only the final state says the graph is wrong but not
//!    where. Every event is checkpointed by default (`stride = 1`) and the first
//!    checkpoint whose values parted is reported, naming the cell label. The
//!    `stride` is part of the fingerprint, because equal log digest PLUS equal
//!    stride is what makes two checkpoint sequences comparable at all — a
//!    mismatch is `error.ReplayStrideMismatch`, kept distinct from
//!    `error.ReplayLogMismatch` so a driver routes on the error rather than on a
//!    message string.
//!
//! 3. **The observation encoding is canonical, or it fails.** `canonicalBytes`
//!    is type-tagged and length-framed, orders mapping and set members by their
//!    own encoded bytes, and preserves sequence order. A value with no defined
//!    encoding (`Value.opaque_value`) fails with `error.ReplayEncoding` rather
//!    than falling back on a host default rendering — such a fallback embeds an
//!    address and reports a *false* divergence on every run, which is the exact
//!    failure a replay proof exists to make impossible.
//!
//! **Hashing.** BLAKE2b-256 from `std.crypto.hash.blake2`, which ships with the
//! toolchain, so the proof costs this binding no dependency. Fingerprints are
//! pinned next to a test in one language and are never exchanged between
//! bindings, so the spec leaves the hash and the byte layout free; what it pins
//! is the equality CLASSES, and those are what `canonicalBytes` implements.
//!
//! **What it covers, and what it cannot.** Checkpoint *values* only. Per
//! `replay-safety.md` clause 3 sibling effect order is deliberately free across
//! the family, so the sequence of effects a replay fires is not a stable thing
//! to fingerprint and this harness does not pretend otherwise.
//!
//! The canonical corpus replay lives in `replay_conformance.zig`; the tests at
//! the bottom of this file prove the same three obligations in-source, so they
//! hold in a bare clone with no `lazily-spec` sibling checkout.

const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;
const List = std.array_list.Managed(u8);

/// BLAKE2b-256. Collision resistance over canonical bytes is the only property
/// relied on; these digests are not wire-compatible with anything and are not
/// meant to be.
const Hasher = std.crypto.hash.blake2.Blake2b256;

pub const DIGEST_LENGTH = Hasher.digest_length;

/// A raw BLAKE2b-256 digest. Compared by bytes; `formatDigest` renders one for
/// diagnostics only — nothing in the proof parses a hex string.
pub const Digest = [DIGEST_LENGTH]u8;

/// The checkpoint sequence number for the state before any event was applied.
/// Negative on purpose: event seqs are non-negative, so the initial checkpoint
/// can never collide with one.
pub const INITIAL_SEQ: i64 = -1;

/// Every way a replay proof can fail to be completed as stated.
///
/// These are SEPARATE values, not one error carrying a message, so a driver
/// routes on the error: a stale fingerprint (`ReplayLogMismatch` /
/// `ReplayStrideMismatch`) is an unanswerable question and means "re-record",
/// while `ReplayDivergence` is a defect in the graph. Collapsing them would
/// force a caller to match on prose to tell the two apart.
pub const ProofError = error{
    /// A value has no canonical byte encoding, so it cannot be fingerprinted.
    ReplayEncoding,
    /// The fingerprint was recorded against a different event log. Refused
    /// BEFORE any observed value is compared, and never compared afterwards.
    ReplayLogMismatch,
    /// The fingerprint was recorded at a different checkpoint stride. The log
    /// is the right one; the two checkpoint sequences were never comparable.
    ReplayStrideMismatch,
    /// A replayed graph observed a different value than the fingerprint.
    ReplayDivergence,
    /// Same log digest and stride, yet a different number of checkpoints — so
    /// this cannot come from sampling. `apply` or `observe` changed shape.
    ReplayCheckpointCount,
    /// Event sequence numbers must strictly increase (they MAY be
    /// non-contiguous: an ack-truncated durable outbox replays real epochs).
    ReplayLogNotIncreasing,
    /// An event carries a negative seq, an empty name, or a payload the subject
    /// cannot apply.
    ReplayMalformedEvent,
    /// `stride` must be >= 1; `prove` needs at least 2 replays to compare.
    ReplayBadArgument,
    /// `observe` returned the same label twice, so "the same labels carry the
    /// same values" has no single answer for that label.
    ReplayDuplicateLabel,
};

pub const EncodeError = Allocator.Error || error{ReplayEncoding};

// ---------------------------------------------------------------------------
// The observed value
// ---------------------------------------------------------------------------

/// One entry of a `Value.map`.
pub const MapEntry = struct {
    key: Value,
    value: Value,
};

/// What a graph may observe at a checkpoint.
///
/// A closed union rather than `anytype` because the third obligation is about
/// which differences ARE differences: every arm below carries its own type tag
/// into the encoding, so `1`, `"1"`, `1.0`, `true` and the byte string `1` are
/// five different values by construction.
///
/// `opaque_value` is this binding's spelling of "a value the encoding does not
/// define". A dynamically typed binding gets that case for free by being handed
/// an arbitrary object; in Zig it has to be representable to be testable, and
/// the corpus's `opaque` tag maps onto it.
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    str: []const u8,
    bytes: []const u8,
    /// Order IS part of the value.
    seq: []const Value,
    /// Order is NOT part of the value; members are ordered by their encoding.
    set: []const Value,
    /// Order is NOT part of the value; entries are ordered by their encoding.
    map: []const MapEntry,
    /// No canonical encoding — encoding one fails with `error.ReplayEncoding`
    /// instead of degrading to a host default rendering.
    opaque_value,
};

/// `<tag><decimal length>:<body>` — the framing every composite relies on.
///
/// The length prefix is the row of the spec's equality table that is easiest to
/// get wrong: concatenating member encodings without a length or delimiter makes
/// `["a","bc"]` and `["ab","c"]` identical, and a harness that cannot tell them
/// apart certifies a graph that reshaped its own output.
fn frame(out: *List, tag: u8, body: []const u8) Allocator.Error!void {
    var buf: [24]u8 = undefined;
    const len_text = std.fmt.bufPrint(&buf, "{d}", .{body.len}) catch unreachable;
    try out.append(tag);
    try out.appendSlice(len_text);
    try out.append(':');
    try out.appendSlice(body);
}

fn lessThanEncoded(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Encode every member into its own buffer, order the buffers by their BYTES,
/// then concatenate. Sorting the encodings rather than the values is what makes
/// the order-insensitivity total: members of mixed types are not mutually
/// comparable as values, but their encodings always are.
fn frameUnordered(
    allocator: Allocator,
    out: *List,
    tag: u8,
    count: usize,
    context: anytype,
    comptime encodeMember: fn (@TypeOf(context), Allocator, *List, usize) EncodeError!void,
) EncodeError!void {
    const parts = try allocator.alloc([]u8, count);
    var built: usize = 0;
    defer {
        for (parts[0..built]) |part| allocator.free(part);
        allocator.free(parts);
    }
    while (built < count) : (built += 1) {
        var member = List.init(allocator);
        errdefer member.deinit();
        try encodeMember(context, allocator, &member, built);
        parts[built] = try member.toOwnedSlice();
    }
    std.mem.sort([]u8, parts, {}, lessThanEncoded);
    var body = List.init(allocator);
    defer body.deinit();
    for (parts) |part| try body.appendSlice(part);
    try frame(out, tag, body.items);
}

fn encodeSetMember(
    members: []const Value,
    allocator: Allocator,
    into: *List,
    index: usize,
) EncodeError!void {
    try encodeValue(allocator, into, members[index]);
}

fn encodeMapEntry(
    entries: []const MapEntry,
    allocator: Allocator,
    into: *List,
    index: usize,
) EncodeError!void {
    try encodeValue(allocator, into, entries[index].key);
    try encodeValue(allocator, into, entries[index].value);
}

/// Append the canonical encoding of `value` to `out`.
///
/// The error set is written out because this function is recursive; an inferred
/// one cannot be resolved.
pub fn encodeValue(allocator: Allocator, out: *List, value: Value) EncodeError!void {
    switch (value) {
        .null => try out.appendSlice("n0:"),
        // Spelled out rather than framed so a boolean can never share bytes with
        // the integer or the text that renders the same way.
        .bool => |flag| try out.appendSlice(if (flag) "b1:1" else "b1:0"),
        .int => |number| {
            var buf: [24]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}", .{number}) catch unreachable;
            try frame(out, 'i', text);
        },
        .float => |number| {
            // The exact bits, not a formatted form: a shortest-round-trip
            // rendering folds distinct NaN payloads together, and a decimal one
            // drifts between toolchains.
            const bits: u64 = @bitCast(number);
            var buf: [16]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{x:0>16}", .{bits}) catch unreachable;
            try frame(out, 'f', text);
        },
        .str => |text| try frame(out, 's', text),
        .bytes => |raw| try frame(out, 'y', raw),
        .seq => |items| {
            var body = List.init(allocator);
            defer body.deinit();
            for (items) |item| try encodeValue(allocator, &body, item);
            try frame(out, 'l', body.items);
        },
        .set => |items| try frameUnordered(allocator, out, 't', items.len, items, encodeSetMember),
        .map => |entries| try frameUnordered(
            allocator,
            out,
            'm',
            entries.len,
            entries,
            encodeMapEntry,
        ),
        // Loudly, and on purpose. See the module header, obligation 3.
        .opaque_value => return error.ReplayEncoding,
    }
}

/// The canonical bytes of `value`. Caller owns the returned slice.
pub fn canonicalBytes(allocator: Allocator, value: Value) EncodeError![]u8 {
    var out = List.init(allocator);
    errdefer out.deinit();
    try encodeValue(allocator, &out, value);
    return out.toOwnedSlice();
}

/// BLAKE2b-256 over `canonicalBytes(value)`.
pub fn canonicalDigest(allocator: Allocator, value: Value) EncodeError!Digest {
    const bytes = try canonicalBytes(allocator, value);
    defer allocator.free(bytes);
    return digestOfBytes(bytes);
}

fn digestOfBytes(bytes: []const u8) Digest {
    var out: Digest = undefined;
    Hasher.hash(bytes, &out, .{});
    return out;
}

/// Lowercase hex of `digest`, for diagnostics only.
pub fn formatDigest(digest: Digest, out: *[DIGEST_LENGTH * 2]u8) []const u8 {
    const alphabet = "0123456789abcdef";
    for (digest, 0..) |byte, index| {
        out[index * 2] = alphabet[byte >> 4];
        out[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out[0..];
}

// ---------------------------------------------------------------------------
// The log
// ---------------------------------------------------------------------------

/// One entry of an ordered event log.
pub const ReplayEvent = struct {
    seq: i64,
    name: []const u8,
    payload: Value = .null,
};

/// An ordered event log with a digest over its canonical bytes.
///
/// Sequence numbers must strictly increase; they do NOT have to be contiguous,
/// because an ack-truncated durable outbox replays real epochs and renumbering
/// them would hide a truncated prefix that the log digest otherwise catches.
///
/// Borrows `events`: the caller keeps ownership and must outlive the log.
pub const ReplayLog = struct {
    events: []const ReplayEvent,
    digest: Digest,

    pub fn init(allocator: Allocator, events: []const ReplayEvent) !ReplayLog {
        var previous: ?i64 = null;
        for (events) |event| {
            if (event.seq < 0 or event.name.len == 0) return error.ReplayMalformedEvent;
            if (previous) |seen| {
                if (event.seq <= seen) return error.ReplayLogNotIncreasing;
            }
            previous = event.seq;
        }

        var body = List.init(allocator);
        defer body.deinit();
        for (events) |event| {
            var entry = List.init(allocator);
            defer entry.deinit();
            try encodeValue(allocator, &entry, .{ .int = event.seq });
            try encodeValue(allocator, &entry, .{ .str = event.name });
            try encodeValue(allocator, &entry, event.payload);
            // A framed SEQUENCE, so event order is part of the digest — which is
            // the whole reason `[+1,+2,+3]` and `[+3,+2,+1]` are different logs.
            try frame(&body, 'l', entry.items);
        }
        var out = List.init(allocator);
        defer out.deinit();
        try frame(&out, 'l', body.items);

        return .{ .events = events, .digest = digestOfBytes(out.items) };
    }

    pub fn len(self: ReplayLog) usize {
        return self.events.len;
    }
};

// ---------------------------------------------------------------------------
// The fingerprint
// ---------------------------------------------------------------------------

/// One observed cell at one checkpoint.
pub const CellDigest = struct {
    label: []const u8,
    digest: Digest,
};

/// Per-cell digests observed after applying events through `seq`, sorted by
/// label. `seq` is `INITIAL_SEQ` for the state before any event was applied.
pub const ReplayCheckpoint = struct {
    seq: i64,
    cells: []const CellDigest,

    pub fn digestFor(self: ReplayCheckpoint, label: []const u8) ?Digest {
        for (self.cells) |cell| {
            if (std.mem.eql(u8, cell.label, label)) return cell.digest;
        }
        return null;
    }
};

/// A recorded, log-bound observation of a replayed graph.
///
/// Owns an arena holding every checkpoint, cell and label, so a fingerprint
/// outlives the observations it was taken from and one `deinit` releases all of
/// it.
pub const ReplayFingerprint = struct {
    arena: *std.heap.ArenaAllocator,
    log_digest: Digest,
    stride: usize,
    checkpoints: []const ReplayCheckpoint,

    pub fn deinit(self: *ReplayFingerprint) void {
        const parent = self.arena.child_allocator;
        self.arena.deinit();
        parent.destroy(self.arena);
        self.* = undefined;
    }

    /// The last checkpoint — the end state of the replay.
    pub fn final(self: ReplayFingerprint) ReplayCheckpoint {
        return self.checkpoints[self.checkpoints.len - 1];
    }
};

pub const DivergenceKind = enum {
    /// Both sides observed the label and the digests differ.
    value,
    /// The fingerprint has the label; the replay did not observe it.
    missing,
    /// The replay observed a label the fingerprint does not carry.
    unexpected,
};

/// One cell that did not replay to its recorded digest.
pub const ReplayDivergence = struct {
    seq: i64,
    label: []const u8,
    kind: DivergenceKind,
    expected: ?Digest,
    actual: ?Digest,
};

/// The divergences of one comparison, owning its own copy of every label.
///
/// Copied rather than borrowed because the replayed fingerprint a report is
/// derived from is released inside `verify`: a report holding slices into it
/// would name freed memory on exactly the failure path that has to be readable.
pub const DivergenceReport = struct {
    arena: *std.heap.ArenaAllocator,
    items: []const ReplayDivergence,

    pub fn deinit(self: *DivergenceReport) void {
        const parent = self.arena.child_allocator;
        self.arena.deinit();
        parent.destroy(self.arena);
        self.* = undefined;
    }

    /// The earliest divergence, which is the one worth reading.
    pub fn first(self: DivergenceReport) ?ReplayDivergence {
        if (self.items.len == 0) return null;
        return self.items[0];
    }

    pub fn len(self: DivergenceReport) usize {
        return self.items.len;
    }
};

fn newArena(allocator: Allocator) !*std.heap.ArenaAllocator {
    const arena = try allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    return arena;
}

fn destroyArena(arena: *std.heap.ArenaAllocator) void {
    const parent = arena.child_allocator;
    arena.deinit();
    parent.destroy(arena);
}

fn lessThanCell(_: void, a: CellDigest, b: CellDigest) bool {
    return std.mem.order(u8, a.label, b.label) == .lt;
}

// ---------------------------------------------------------------------------
// The harness
// ---------------------------------------------------------------------------

/// What a graph observes at a checkpoint, keyed by a stable label.
pub const Observation = struct {
    label: []const u8,
    value: Value,
};

/// Rebuild a graph from an event log and prove it replays identically.
///
/// `Graph` must provide:
///
///   * `pub fn apply(self: *Graph, event: ReplayEvent) !void` — advance by
///     exactly one event;
///   * `pub fn observe(self: *Graph, allocator: Allocator) ![]const Observation`
///     — the cell values the fingerprint covers. `allocator` belongs to a
///     per-checkpoint arena the harness resets, so an observation may allocate
///     freely and never frees;
///   * `pub fn destroy(self: *Graph, allocator: Allocator) void` — release the
///     graph and whatever it owns.
///
/// `Ctx` is whatever the build function needs to construct one (a config
/// struct, a context pointer, `void`).
///
/// `build` is called once per replay and MUST return a FRESH graph: a harness
/// that reuses one instance proves nothing, because the state it would compare
/// against is the state it already has.
///
/// `stride` checkpoints every `stride`-th event; the initial state (before any
/// event) and the final state are always checkpointed. It is recorded in the
/// fingerprint, so a fingerprint can never be compared against a replay that
/// sampled differently.
pub fn ReplayHarness(comptime Graph: type, comptime Ctx: type) type {
    return struct {
        const Self = @This();

        pub const BuildFn = *const fn (ctx: Ctx, allocator: Allocator) anyerror!*Graph;

        allocator: Allocator,
        build: BuildFn,
        ctx: Ctx,
        stride: usize,

        pub fn init(allocator: Allocator, build: BuildFn, ctx: Ctx, stride: usize) !Self {
            if (stride < 1) return error.ReplayBadArgument;
            return .{ .allocator = allocator, .build = build, .ctx = ctx, .stride = stride };
        }

        /// Replay `log` once and record what the graph observed. Caller owns the
        /// fingerprint and must `deinit` it.
        pub fn record(self: Self, log: ReplayLog) !ReplayFingerprint {
            return self.replay(log);
        }

        /// Replay `log` and REPORT the divergences from `fingerprint`.
        ///
        /// Non-raising for value divergence, so a caller can collect all of
        /// them. A fingerprint recorded against a different log or at a
        /// different stride is still REFUSED here: a stale fingerprint is an
        /// unanswerable question, not a report. Caller owns the report.
        pub fn check(self: Self, log: ReplayLog, fingerprint: ReplayFingerprint) !DivergenceReport {
            var replayed = try self.replay(log);
            defer replayed.deinit();
            try revalidate(fingerprint, replayed);
            return self.compare(fingerprint, replayed);
        }

        /// Replay `log` and fail unless it matches `fingerprint` exactly.
        ///
        /// On `error.ReplayDivergence`, when `out_report` is non-null it is
        /// filled with the divergences and the caller owns it. Zig errors carry
        /// no payload, so the detail travels through the out-parameter rather
        /// than through a message a caller would have to parse.
        pub fn verify(
            self: Self,
            log: ReplayLog,
            fingerprint: ReplayFingerprint,
            out_report: ?*DivergenceReport,
        ) !void {
            var report = try self.check(log, fingerprint);
            if (report.items.len == 0) {
                report.deinit();
                return;
            }
            if (out_report) |slot| {
                slot.* = report;
            } else {
                report.deinit();
            }
            return error.ReplayDivergence;
        }

        /// Record `log` and re-replay it, failing on any divergence.
        ///
        /// The self-check: no external fingerprint is needed to catch a graph
        /// that is not a pure function of its log, because two replays of the
        /// same log in the same process already disagree. Caller owns the
        /// returned fingerprint.
        pub fn prove(self: Self, log: ReplayLog, replays: usize) !ReplayFingerprint {
            if (replays < 2) return error.ReplayBadArgument;
            var fingerprint = try self.record(log);
            errdefer fingerprint.deinit();
            var remaining = replays - 1;
            while (remaining > 0) : (remaining -= 1) {
                try self.verify(log, fingerprint, null);
            }
            return fingerprint;
        }

        // -- internals --------------------------------------------------------

        /// Bind the fingerprint to these exact log bytes BEFORE comparing any
        /// value, then to the stride. The order is the obligation, not an
        /// optimisation: a value compare against a stale fingerprint answers a
        /// question nobody asked.
        fn revalidate(fingerprint: ReplayFingerprint, replayed: ReplayFingerprint) !void {
            if (!std.mem.eql(u8, &fingerprint.log_digest, &replayed.log_digest)) {
                return error.ReplayLogMismatch;
            }
            if (fingerprint.stride != replayed.stride) return error.ReplayStrideMismatch;
        }

        fn sampleHere(self: Self, index: usize, total: usize) bool {
            return (index + 1) % self.stride == 0 or index + 1 == total;
        }

        fn sampleCount(self: Self, total: usize) usize {
            var count: usize = 1; // the initial state is always checkpointed
            var index: usize = 0;
            while (index < total) : (index += 1) {
                if (self.sampleHere(index, total)) count += 1;
            }
            return count;
        }

        fn replay(self: Self, log: ReplayLog) !ReplayFingerprint {
            const arena = try newArena(self.allocator);
            errdefer destroyArena(arena);
            const out = arena.allocator();

            // Observations live only long enough to be digested, so a separate
            // arena is reset per checkpoint and a long log does not accumulate
            // every intermediate rendering.
            var scratch = std.heap.ArenaAllocator.init(self.allocator);
            defer scratch.deinit();

            const total = log.events.len;
            const checkpoints = try out.alloc(ReplayCheckpoint, self.sampleCount(total));

            const graph = try self.build(self.ctx, self.allocator);
            defer graph.destroy(self.allocator);

            var taken: usize = 0;
            checkpoints[taken] = try sample(out, &scratch, graph, INITIAL_SEQ);
            taken += 1;
            for (log.events, 0..) |event, index| {
                try graph.apply(event);
                if (!self.sampleHere(index, total)) continue;
                checkpoints[taken] = try sample(out, &scratch, graph, event.seq);
                taken += 1;
            }

            return .{
                .arena = arena,
                .log_digest = log.digest,
                .stride = self.stride,
                .checkpoints = checkpoints,
            };
        }

        fn sample(
            out: Allocator,
            scratch: *std.heap.ArenaAllocator,
            graph: *Graph,
            seq: i64,
        ) !ReplayCheckpoint {
            _ = scratch.reset(.retain_capacity);
            const observed = try graph.observe(scratch.allocator());
            const cells = try out.alloc(CellDigest, observed.len);
            for (observed, 0..) |observation, index| {
                cells[index] = .{
                    .label = try out.dupe(u8, observation.label),
                    .digest = try canonicalDigest(scratch.allocator(), observation.value),
                };
            }
            std.mem.sort(CellDigest, cells, {}, lessThanCell);
            var index: usize = 1;
            while (index < cells.len) : (index += 1) {
                if (std.mem.eql(u8, cells[index - 1].label, cells[index].label)) {
                    return error.ReplayDuplicateLabel;
                }
            }
            return .{ .seq = seq, .cells = cells };
        }

        /// Walk the two checkpoint sequences in step and stop at the FIRST one
        /// that parted. Later checkpoints are almost always the same defect
        /// carried forward, and the spec lets them be omitted.
        fn compare(
            self: Self,
            expected: ReplayFingerprint,
            actual: ReplayFingerprint,
        ) !DivergenceReport {
            const arena = try newArena(self.allocator);
            errdefer destroyArena(arena);
            const out = arena.allocator();

            var found = std.array_list.Managed(ReplayDivergence).init(out);
            const pairs = @min(expected.checkpoints.len, actual.checkpoints.len);
            var index: usize = 0;
            while (index < pairs) : (index += 1) {
                try diffCheckpoint(
                    out,
                    expected.checkpoints[index],
                    actual.checkpoints[index],
                    &found,
                );
                if (found.items.len > 0) break;
            }
            if (found.items.len == 0 and expected.checkpoints.len != actual.checkpoints.len) {
                // Same log digest and stride, so this cannot come from sampling.
                destroyArena(arena);
                return error.ReplayCheckpointCount;
            }
            return .{ .arena = arena, .items = found.items };
        }

        /// Both cell arrays are sorted by label, so their union is a merge walk.
        fn diffCheckpoint(
            out: Allocator,
            want: ReplayCheckpoint,
            got: ReplayCheckpoint,
            found: *std.array_list.Managed(ReplayDivergence),
        ) !void {
            var left: usize = 0;
            var right: usize = 0;
            while (left < want.cells.len or right < got.cells.len) {
                const order: std.math.Order = if (left == want.cells.len)
                    .gt
                else if (right == got.cells.len)
                    .lt
                else
                    std.mem.order(u8, want.cells[left].label, got.cells[right].label);
                switch (order) {
                    .lt => {
                        try found.append(.{
                            .seq = want.seq,
                            .label = try out.dupe(u8, want.cells[left].label),
                            .kind = .missing,
                            .expected = want.cells[left].digest,
                            .actual = null,
                        });
                        left += 1;
                    },
                    .gt => {
                        try found.append(.{
                            .seq = want.seq,
                            .label = try out.dupe(u8, got.cells[right].label),
                            .kind = .unexpected,
                            .expected = null,
                            .actual = got.cells[right].digest,
                        });
                        right += 1;
                    },
                    .eq => {
                        if (!std.mem.eql(
                            u8,
                            &want.cells[left].digest,
                            &got.cells[right].digest,
                        )) {
                            try found.append(.{
                                .seq = want.seq,
                                .label = try out.dupe(u8, want.cells[left].label),
                                .kind = .value,
                                .expected = want.cells[left].digest,
                                .actual = got.cells[right].digest,
                            });
                        }
                        left += 1;
                        right += 1;
                    },
                }
            }
        }
    };
}

// ---------------------------------------------------------------------------
// The corpus's canonical subject
// ---------------------------------------------------------------------------

/// `accumulator`, and `drifting_accumulator` when a drift is configured.
///
/// A fixture cannot carry a reactive graph, so the corpus declares its subjects
/// in prose and every binding implements them the same way. This is this
/// binding's copy of that declaration, kept to the letter — including that
/// `observe` exposes `sum` and `names` under exactly those labels. It lives here
/// rather than in the conformance runner so the canonical replay and the
/// in-source tests below cannot describe two different subjects.
pub const Accumulator = struct {
    pub const Spec = struct {
        drift_at: ?i64 = null,
        drift: i64 = 0,
    };

    sum: i64 = 0,
    names: std.array_list.Managed([]const u8),
    spec: Spec,

    pub fn create(spec: Spec, allocator: Allocator) anyerror!*Accumulator {
        const self = try allocator.create(Accumulator);
        self.* = .{
            .names = std.array_list.Managed([]const u8).init(allocator),
            .spec = spec,
        };
        return self;
    }

    pub fn apply(self: *Accumulator, event: ReplayEvent) !void {
        self.sum += switch (event.payload) {
            .int => |value| value,
            else => return error.ReplayMalformedEvent,
        };
        try self.names.append(event.name);
        // `drifting_accumulator`: a value taken from OUTSIDE the log, which is
        // the one thing a replay proof is looking for.
        if (self.spec.drift_at) |at| {
            if (event.seq == at) self.sum += self.spec.drift;
        }
    }

    pub fn observe(self: *Accumulator, allocator: Allocator) ![]const Observation {
        const names = try allocator.alloc(Value, self.names.items.len);
        for (self.names.items, 0..) |name, index| names[index] = .{ .str = name };
        const observed = try allocator.alloc(Observation, 2);
        observed[0] = .{ .label = "sum", .value = .{ .int = self.sum } };
        observed[1] = .{ .label = "names", .value = .{ .seq = names } };
        return observed;
    }

    pub fn destroy(self: *Accumulator, allocator: Allocator) void {
        self.names.deinit();
        allocator.destroy(self);
    }
};

pub const AccumulatorHarness = ReplayHarness(Accumulator, Accumulator.Spec);

// ---------------------------------------------------------------------------
// In-source proof of the three obligations. These hold in a bare clone with no
// `lazily-spec` sibling checkout; the canonical corpus replay is separate.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testEvents(payloads: []const i64, out: []ReplayEvent) []ReplayEvent {
    for (payloads, 0..) |payload, index| {
        out[index] = .{
            .seq = @intCast(index),
            .name = "add",
            .payload = .{ .int = payload },
        };
    }
    return out[0..payloads.len];
}

test "obligation 1: two logs with the same final sum have different digests" {
    var buf_a: [3]ReplayEvent = undefined;
    var buf_b: [3]ReplayEvent = undefined;
    const log_a = try ReplayLog.init(testing.allocator, testEvents(&.{ 1, 2, 3 }, &buf_a));
    const log_b = try ReplayLog.init(testing.allocator, testEvents(&.{ 3, 2, 1 }, &buf_b));
    try testing.expect(!std.mem.eql(u8, &log_a.digest, &log_b.digest));

    const harness = try AccumulatorHarness.init(testing.allocator, Accumulator.create, .{}, 1);
    var fingerprint = try harness.record(log_a);
    defer fingerprint.deinit();

    // Same final sum, different log: refused as a distinct outcome and never
    // compared — by `verify` AND by the reporting form.
    try testing.expectError(error.ReplayLogMismatch, harness.verify(log_b, fingerprint, null));
    try testing.expectError(error.ReplayLogMismatch, harness.check(log_b, fingerprint));
    try harness.verify(log_a, fingerprint, null);
}

test "obligation 2: divergence is localized to its first checkpoint" {
    var buf: [4]ReplayEvent = undefined;
    const log = try ReplayLog.init(testing.allocator, testEvents(&.{ 1, 2, 3, 4 }, &buf));

    const clean = try AccumulatorHarness.init(
        testing.allocator,
        Accumulator.create,
        .{ .drift_at = 1, .drift = 0 },
        1,
    );
    var fingerprint = try clean.record(log);
    defer fingerprint.deinit();

    const drifting = try AccumulatorHarness.init(
        testing.allocator,
        Accumulator.create,
        .{ .drift_at = 1, .drift = 100 },
        1,
    );
    var report: DivergenceReport = undefined;
    try testing.expectError(
        error.ReplayDivergence,
        drifting.verify(log, fingerprint, &report),
    );
    defer report.deinit();
    const first = report.first().?;
    // seq 0 still matches; the report names the first checkpoint that parted.
    try testing.expectEqual(@as(i64, 1), first.seq);
    try testing.expectEqualStrings("sum", first.label);
    try testing.expectEqual(DivergenceKind.value, first.kind);
}

test "obligation 2: a fingerprint is bound to the stride it was sampled at" {
    var buf: [4]ReplayEvent = undefined;
    const log = try ReplayLog.init(testing.allocator, testEvents(&.{ 1, 2, 3, 4 }, &buf));

    const sparse = try AccumulatorHarness.init(testing.allocator, Accumulator.create, .{}, 2);
    var fingerprint = try sparse.record(log);
    defer fingerprint.deinit();
    try testing.expectEqual(@as(usize, 3), fingerprint.checkpoints.len);
    try testing.expectEqual(INITIAL_SEQ, fingerprint.checkpoints[0].seq);
    try testing.expectEqual(@as(i64, 1), fingerprint.checkpoints[1].seq);
    try testing.expectEqual(@as(i64, 3), fingerprint.checkpoints[2].seq);

    const dense = try AccumulatorHarness.init(testing.allocator, Accumulator.create, .{}, 1);
    try testing.expectError(
        error.ReplayStrideMismatch,
        dense.verify(log, fingerprint, null),
    );
    try testing.expectError(error.ReplayStrideMismatch, dense.check(log, fingerprint));
    try sparse.verify(log, fingerprint, null);
}

fn digestsEqual(allocator: Allocator, left: Value, right: Value) !bool {
    const a = try canonicalDigest(allocator, left);
    const b = try canonicalDigest(allocator, right);
    return std.mem.eql(u8, &a, &b);
}

test "obligation 3: the encoding's equality classes" {
    const allocator = testing.allocator;
    const one: Value = .{ .int = 1 };
    const two: Value = .{ .int = 2 };
    const three: Value = .{ .int = 3 };

    const map_ab: Value = .{ .map = &.{
        .{ .key = .{ .str = "a" }, .value = one },
        .{ .key = .{ .str = "b" }, .value = two },
    } };
    const map_ba: Value = .{ .map = &.{
        .{ .key = .{ .str = "b" }, .value = two },
        .{ .key = .{ .str = "a" }, .value = one },
    } };
    try testing.expect(try digestsEqual(allocator, map_ab, map_ba));

    const set_123: Value = .{ .set = &.{ one, two, three } };
    const set_312: Value = .{ .set = &.{ three, one, two } };
    try testing.expect(try digestsEqual(allocator, set_123, set_312));

    const seq_12: Value = .{ .seq = &.{ one, two } };
    const seq_21: Value = .{ .seq = &.{ two, one } };
    try testing.expect(!try digestsEqual(allocator, seq_12, seq_21));

    // Five different values, not one.
    const tagged = [_]Value{
        one,
        .{ .str = "1" },
        .{ .float = 1.0 },
        .{ .bool = true },
        .{ .bytes = "1" },
    };
    for (tagged, 0..) |left, index| {
        for (tagged[index + 1 ..]) |right| {
            try testing.expect(!try digestsEqual(allocator, left, right));
        }
    }

    // Member framing: a concatenation must not be ambiguous.
    const a_bc: Value = .{ .seq = &.{ .{ .str = "a" }, .{ .str = "bc" } } };
    const ab_c: Value = .{ .seq = &.{ .{ .str = "ab" }, .{ .str = "c" } } };
    try testing.expect(!try digestsEqual(allocator, a_bc, ab_c));

    // Beyond 2^53, and still exact.
    const big: Value = .{ .int = 9007199254740993 };
    const big_plus_one: Value = .{ .int = 9007199254740994 };
    try testing.expect(try digestsEqual(allocator, big, big));
    try testing.expect(!try digestsEqual(allocator, big, big_plus_one));

    // Loudly, rather than on a host default rendering — nested as well as bare.
    try testing.expectError(
        error.ReplayEncoding,
        canonicalDigest(allocator, .opaque_value),
    );
    try testing.expectError(
        error.ReplayEncoding,
        canonicalDigest(allocator, .{ .seq = &.{ one, .opaque_value } }),
    );
}

test "a log must strictly increase and may be non-contiguous" {
    const gapped = [_]ReplayEvent{
        .{ .seq = 7, .name = "add", .payload = .{ .int = 1 } },
        .{ .seq = 19, .name = "add", .payload = .{ .int = 2 } },
    };
    _ = try ReplayLog.init(testing.allocator, &gapped);

    const repeated = [_]ReplayEvent{
        .{ .seq = 1, .name = "add", .payload = .{ .int = 1 } },
        .{ .seq = 1, .name = "add", .payload = .{ .int = 2 } },
    };
    try testing.expectError(
        error.ReplayLogNotIncreasing,
        ReplayLog.init(testing.allocator, &repeated),
    );

    const unnamed = [_]ReplayEvent{.{ .seq = 0, .name = "", .payload = .{ .int = 1 } }};
    try testing.expectError(
        error.ReplayMalformedEvent,
        ReplayLog.init(testing.allocator, &unnamed),
    );
}

test "prove catches a graph that is not a pure function of its log" {
    var buf: [3]ReplayEvent = undefined;
    const log = try ReplayLog.init(testing.allocator, testEvents(&.{ 1, 2, 3 }, &buf));

    const honest = try AccumulatorHarness.init(testing.allocator, Accumulator.create, .{}, 1);
    var fingerprint = try honest.prove(log, 2);
    defer fingerprint.deinit();
    // The recorded digest IS the digest of the state the subject ends on, not
    // merely some value the harness happened to observe.
    try testing.expectEqual(
        try canonicalDigest(testing.allocator, .{ .int = 6 }),
        fingerprint.final().digestFor("sum").?,
    );

    // A graph whose state escapes the log: the SECOND replay in the same
    // process already disagrees with the first, with no external fingerprint.
    const Leaky = struct {
        var carried: i64 = 0;

        const Self = @This();
        sum: i64,

        fn create(_: void, allocator: Allocator) anyerror!*Self {
            const self = try allocator.create(Self);
            self.* = .{ .sum = carried };
            return self;
        }
        fn apply(self: *Self, event: ReplayEvent) !void {
            self.sum += event.payload.int;
            carried = self.sum;
        }
        fn observe(self: *Self, allocator: Allocator) ![]const Observation {
            const observed = try allocator.alloc(Observation, 1);
            observed[0] = .{ .label = "sum", .value = .{ .int = self.sum } };
            return observed;
        }
        fn destroy(self: *Self, allocator: Allocator) void {
            allocator.destroy(self);
        }
    };
    Leaky.carried = 0;
    const leaky = try ReplayHarness(Leaky, void).init(
        testing.allocator,
        Leaky.create,
        {},
        1,
    );
    try testing.expectError(error.ReplayDivergence, leaky.prove(log, 2));
}

test "a label the replay stops observing is reported as missing" {
    var buf: [2]ReplayEvent = undefined;
    const log = try ReplayLog.init(testing.allocator, testEvents(&.{ 1, 2 }, &buf));

    const Narrow = struct {
        const Self = @This();
        sum: i64 = 0,

        fn create(_: void, allocator: Allocator) anyerror!*Self {
            const self = try allocator.create(Self);
            self.* = .{};
            return self;
        }
        fn apply(self: *Self, event: ReplayEvent) !void {
            self.sum += event.payload.int;
        }
        fn observe(self: *Self, allocator: Allocator) ![]const Observation {
            const observed = try allocator.alloc(Observation, 1);
            observed[0] = .{ .label = "sum", .value = .{ .int = self.sum } };
            return observed;
        }
        fn destroy(self: *Self, allocator: Allocator) void {
            allocator.destroy(self);
        }
    };

    const wide = try AccumulatorHarness.init(testing.allocator, Accumulator.create, .{}, 1);
    var fingerprint = try wide.record(log);
    defer fingerprint.deinit();

    const narrow = try ReplayHarness(Narrow, void).init(
        testing.allocator,
        Narrow.create,
        {},
        1,
    );
    var report = try narrow.check(log, fingerprint);
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.len());
    try testing.expectEqual(DivergenceKind.missing, report.first().?.kind);
    try testing.expectEqualStrings("names", report.first().?.label);
    try testing.expectEqual(INITIAL_SEQ, report.first().?.seq);
}

test "stride and replay-count arguments are validated" {
    try testing.expectError(
        error.ReplayBadArgument,
        AccumulatorHarness.init(testing.allocator, Accumulator.create, .{}, 0),
    );
    var buf: [1]ReplayEvent = undefined;
    const log = try ReplayLog.init(testing.allocator, testEvents(&.{7}, &buf));
    const harness = try AccumulatorHarness.init(testing.allocator, Accumulator.create, .{}, 1);
    try testing.expectError(error.ReplayBadArgument, harness.prove(log, 1));
}

test "formatDigest renders the whole digest" {
    var buf: [DIGEST_LENGTH * 2]u8 = undefined;
    const digest = try canonicalDigest(testing.allocator, .{ .int = 6 });
    const hex = formatDigest(digest, &buf);
    try testing.expectEqual(@as(usize, DIGEST_LENGTH * 2), hex.len);
    for (hex) |char| try testing.expect(std.ascii.isHex(char));
}

comptime {
    // Everything this module touches (`std.crypto.hash.blake2`,
    // `std.heap.ArenaAllocator`, `std.mem.sort`) is stable across the three
    // pinned Zig versions, so no version shim belongs here and none should be
    // added without a reason.
    std.debug.assert(builtin.zig_version.major == 0);
}
