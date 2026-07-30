//! The transport-agnostic ingress contract (`#designimplementtransport`),
//! replayed against **every flavor this binding ships** — with a ledger that is
//! *enforced* rather than advisory.
//!
//! lazily-zig ships all three: `IngressCell` / `ThreadSafeIngressCell` /
//! `AsyncIngressCell`, matching the three `coverage.json` ingress rows and the
//! contract `../lazily-spec/docs/transport-ingress.md` declares REQUIRED of every
//! binding × every flavor.
//!
//! The flavor axis lives in the **runner**, not the corpus: the fixtures carry a
//! `model` field naming the primitive and no execution-model field, and one
//! comptime-duck-typed model interface replays the same JSON against each shell.
//! Nothing in that interface is async-coloured, which is the finding rather than
//! an oversight — an admission decision is a function of the fence, the
//! watermark, the reorder buffer, and the observed clock, so there is nothing to
//! await and no `settle` step anywhere below.
//!
//! The merge axis needs no type parameter here: this binding models a merge policy
//! as a runtime value (`merge.MergePolicy(T)`, the shape `relay.zig` already
//! uses), so `"merge": "sum"` and `"merge": "keep_latest"` select a value rather
//! than instantiating a second model.
//!
//! Three things keep this suite from reporting green while testing nothing — each
//! one a failure mode this family of suites has actually shipped:
//!
//! * the ledger test checks each row against the **source text** of the family's
//!   four modules, in BOTH directions. A row marked shipped whose type is not
//!   defined fails; a type that exists while its row says unshipped fails and
//!   names the runner to extend. The source is reached with `@embedFile`, not a
//!   directory walk: this file is inside the same package as the shells, so a
//!   `readDir` grep would find the ledger's own string literals and report every
//!   flavor present — the self-reference that made `queue.zig`'s first ledger fail
//!   against correct code.
//! * Every replay returns its step count, and every flavor asserts that count is
//!   non-zero and equal to the corpus total. An absence guard proves the fixtures
//!   exist on disk; only a positive count proves this binary opened them.
//! * `invalidates` is asserted in **both** directions through a cache-validity
//!   probe per reader kind. A step expecting `false` fails if the shell
//!   invalidated anyway, so over-invalidation is as visible as under-. The probe
//!   is itself pinned by a test that proves it can fail, on all three flavors.
//!
//! `invalidates` is asserted **per channel**, never by receipt *count*: a stale
//! cache recomputes to the right count, so a count-only gate reports green.
//!
//! Every gate below was mutation-checked; the module tail lists the seven probes
//! and what each one turned red.

const std = @import("std");
const cj = @import("conformance_json.zig");
const json = std.json;
const Context = @import("context.zig").Context;
const Compute = @import("context.zig").Compute;
const cell = @import("cell.zig");
const merge = @import("merge.zig");
const core_mod = @import("ingress_core.zig");
const ingress = @import("ingress.zig");
const thread_safe_ingress = @import("thread_safe_ingress.zig");
const async_ingress = @import("async_ingress.zig");
const ThreadSafeContext = @import("thread_safe_context.zig").ThreadSafeContext;

/// Reads through the runtime conformance manifest recorder
/// (`#lazilyupgradeconformance`): naming a fixture is not replaying it, so the
/// coverage guard is fed by observed reads rather than a source grep.
const readFixtureFile = @import("conformance_manifest.zig").specReadFile;

const IngressAdmission = core_mod.IngressAdmission;
const IngressAuthority = core_mod.IngressAuthority;
const IngressDropReason = core_mod.IngressDropReason;
const IngressError = core_mod.IngressError;
const IngressLifecycle = core_mod.IngressLifecycle;
const IngressPolicy = core_mod.IngressPolicy;
const IngressReadiness = core_mod.IngressReadiness;
const IngressRetry = core_mod.IngressRetry;
const IngressSchedule = core_mod.IngressSchedule;
const IngressTransportKind = core_mod.IngressTransportKind;
const Overflow = core_mod.Overflow;
const ReplayRequest = core_mod.ReplayRequest;
const ScopeView = core_mod.ScopeView;

const testing = std.testing;

const SPEC_DIR = "../lazily-spec/conformance/ingress/";

/// Every fixture the ingress corpus ships. Named explicitly rather than globbed:
/// a fixture added to the corpus and not to this list is a *missing replay*, and
/// the runtime coverage guard is what should notice, not a silently shorter run.
const FIXTURES = [_][]const u8{
    "ingress_ordered_delivery.json",
    "ingress_reorder_and_duplication.json",
    "ingress_reorder_window_overflow.json",
    "ingress_disconnect_replay.json",
    "ingress_backpressure.json",
    "ingress_generation_handoff.json",
    "ingress_freshness_and_retry.json",
};

/// The corpus never names more than a couple of scopes per fixture; the bound
/// exists so the probe matrix can be a fixed array (and so a fixture that grows
/// past it fails loudly rather than silently probing a prefix).
const max_keys = 4;

/// The four scope reader kinds, in the order the fixture's `invalidates.scopes`
/// object lists them. The field names ARE the fixture's keys.
const Kind = enum(usize) { value = 0, readiness = 1, authority = 2, retry = 3 };

/// The three receipt channels, in the order `invalidates.receipts` lists them.
const ChannelIndex = enum(usize) { accepted = 0, dropped = 1, err = 2 };

/// The enum FIELD NAMES are the fixture's JSON keys, and the enum values are the
/// probe-matrix slots. Deriving both from reflection — rather than from a
/// hand-written list — is what keeps the corpus keys and the probe slots from
/// drifting apart, and the comptime block below pins the one assumption that makes
/// the slot index sound.
/// Reflected through `std.enums.values` + `@tagName` rather than through
/// `@typeInfo(E).@"enum"`: that struct's shape moved between the toolchains this
/// repo's CI matrix pins — 0.16.0 exposes `fields`, master exposes `field_names` /
/// `field_values`, and neither exposes the other. `values`/`@tagName` are stable
/// across all three, so the corpus keys stay reflection-derived without pinning
/// the suite to one compiler.
fn tagNames(comptime E: type) [std.enums.values(E).len][:0]const u8 {
    comptime {
        const vals = std.enums.values(E);
        var out: [vals.len][:0]const u8 = undefined;
        for (vals, 0..) |e, i| out[i] = @tagName(e);
        return out;
    }
}

const kind_names = tagNames(Kind);
const channel_names = tagNames(ChannelIndex);

comptime {
    for (std.enums.values(Kind), 0..) |e, i| {
        if (@intFromEnum(e) != i) @compileError("Kind values must equal their declaration index");
    }
    for (std.enums.values(ChannelIndex), 0..) |e, i| {
        if (@intFromEnum(e) != i) @compileError("ChannelIndex values must equal their declaration index");
    }
}

/// Cache-validity snapshot of every reader kind the fixture can speak about.
const Snapshot = struct {
    scopes: [max_keys][4]bool = @splat(@splat(false)),
    receipts: [3]bool = @splat(false),
};

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

fn jsonField(value: json.Value, name: []const u8) ?json.Value {
    return switch (value) {
        .object => |object| object.get(name),
        else => null,
    };
}

fn jsonFieldRequired(value: json.Value, name: []const u8) !json.Value {
    return jsonField(value, name) orelse error.MissingField;
}

fn jsonAsString(value: json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}

fn jsonAsU64(value: json.Value) !u64 {
    return switch (value) {
        .integer => |n| if (n >= 0) @as(u64, @intCast(n)) else error.ExpectedUnsignedInteger,
        .number_string => |s| try std.fmt.parseInt(u64, s, 10),
        else => error.ExpectedUnsignedInteger,
    };
}

fn jsonAsBool(value: json.Value) !bool {
    return switch (value) {
        .bool => |b| b,
        else => error.ExpectedBool,
    };
}

/// A `u64|null` field, spelled as an optional.
fn jsonAsOptU64(value: json.Value) !?u64 {
    return switch (value) {
        .null => null,
        else => try jsonAsU64(value),
    };
}

fn requiredU64(value: json.Value, name: []const u8) !u64 {
    return jsonAsU64(try jsonFieldRequired(value, name));
}

fn requiredString(value: json.Value, name: []const u8) ![]const u8 {
    return jsonAsString(try jsonFieldRequired(value, name));
}

fn requiredEnum(comptime E: type, value: json.Value, name: []const u8) !E {
    const text = try requiredString(value, name);
    return std.meta.stringToEnum(E, text) orelse {
        std.debug.print("unknown {s} `{s}`\n", .{ @typeName(E), text });
        return error.UnknownEnumValue;
    };
}

/// `Overflow` belongs to the relay family and predates the corpus spelling, so it
/// is the one mapping that cannot come from `stringToEnum`.
fn overflowOf(text: []const u8) !Overflow {
    if (std.mem.eql(u8, text, "block")) return .Block;
    if (std.mem.eql(u8, text, "drop_newest")) return .DropNewest;
    if (std.mem.eql(u8, text, "drop_oldest")) return .DropOldest;
    if (std.mem.eql(u8, text, "conflate")) return .Conflate;
    if (std.mem.eql(u8, text, "spill")) return .Spill;
    std.debug.print("unknown overflow `{s}`\n", .{text});
    return error.UnknownOverflow;
}

fn mergeOf(text: []const u8) !merge.MergePolicy(u64) {
    if (std.mem.eql(u8, text, "sum")) return merge.sum(u64);
    if (std.mem.eql(u8, text, "keep_latest")) return merge.keepLatest(u64);
    if (std.mem.eql(u8, text, "max")) return merge.max(u64);
    std.debug.print("unknown merge `{s}`\n", .{text});
    return error.UnknownMerge;
}

fn policyOf(value: json.Value) !IngressPolicy {
    return .{
        .reorder_window = @intCast(try requiredU64(value, "reorder_window")),
        .freshness_horizon = try requiredU64(value, "freshness_horizon"),
        .high_water = try requiredU64(value, "high_water"),
        .overflow = try overflowOf(try requiredString(value, "overflow")),
        .receipt_capacity = @intCast(try requiredU64(value, "receipt_capacity")),
        .retry_base = try requiredU64(value, "retry_base"),
        .retry_ceiling = try requiredU64(value, "retry_ceiling"),
    };
}

fn expectedReplay(value: json.Value) !?ReplayRequest {
    return switch (value) {
        .null => null,
        else => ReplayRequest{
            .generation = try requiredU64(value, "generation"),
            .from_sequence = try requiredU64(value, "from_sequence"),
        },
    };
}

fn expectTag(where: []const u8, ok: bool) !void {
    if (!ok) {
        std.debug.print("{s}: admission variant mismatch\n", .{where});
        return error.TestExpectedEqual;
    }
}

fn expectEqU64(where: []const u8, want: u64, got: u64) !void {
    if (want != got) {
        std.debug.print("{s}: want {d} got {d}\n", .{ where, want, got });
        return error.TestExpectedEqual;
    }
}

fn expectEqOptU64(where: []const u8, want: ?u64, got: ?u64) !void {
    if (!std.meta.eql(want, got)) {
        std.debug.print("{s}: want {?d} got {?d}\n", .{ where, want, got });
        return error.TestExpectedEqual;
    }
}

/// Assert an admission against the fixture's `returns` object, field by field so
/// a variant mismatch names the case.
fn expectAdmission(want: json.Value, got: IngressAdmission, where: []const u8) !void {
    const kind = try requiredString(want, "admission");
    if (std.mem.eql(u8, kind, "accepted")) {
        try expectTag(where, got == .accepted);
        try expectEqU64(
            where,
            try requiredU64(want, "delivered_through"),
            got.accepted.delivered_through,
        );
    } else if (std.mem.eql(u8, kind, "conflated")) {
        try expectTag(where, got == .conflated);
        try expectEqU64(
            where,
            try requiredU64(want, "delivered_through"),
            got.conflated.delivered_through,
        );
    } else if (std.mem.eql(u8, kind, "buffered")) {
        try expectTag(where, got == .buffered);
        try expectEqU64(where, try requiredU64(want, "gap_from"), got.buffered.gap_from);
    } else if (std.mem.eql(u8, kind, "generation_handoff")) {
        try expectTag(where, got == .generation_handoff);
        try expectEqU64(where, try requiredU64(want, "from"), got.generation_handoff.from);
        try expectEqU64(where, try requiredU64(want, "to"), got.generation_handoff.to);
    } else if (std.mem.eql(u8, kind, "dropped")) {
        try expectTag(where, got == .dropped);
        const reason = try requiredEnum(IngressDropReason, want, "reason");
        if (got.dropped != reason) {
            std.debug.print("{s}: drop reason want {s} got {s}\n", .{
                where,
                @tagName(reason),
                @tagName(got.dropped),
            });
            return error.TestExpectedEqual;
        }
    } else if (std.mem.eql(u8, kind, "blocked")) {
        try expectTag(where, got == .blocked);
    } else {
        std.debug.print("{s}: unknown admission `{s}`\n", .{ where, kind });
        return error.UnknownAdmission;
    }
}

// ---------------------------------------------------------------------------
// Flavor 1 — single-threaded
//
// The only flavor whose reader kinds are not themselves graph nodes: a reader is a
// handle over core storage plus the shared `ReaderKind` edge, the shape `queue.zig`
// and `work_queue.zig` already use. So the cache-validity probe needs a real
// derived node per (scope, kind), and Zig has no closures — hence the
// comptime-indexed probe bodies below, each reading one pre-bound reader handle
// out of the model.
// ---------------------------------------------------------------------------

const SyncCell = ingress.IngressCell([]const u8, u64);

/// The model the comptime probe bodies read. One replay runs at a time, so a
/// module-scope binding is the same idiom `work_queue.zig`'s edge test uses.
var sync_bound: ?*SyncModel = null;

fn syncScopeProbe(comptime i: usize, comptime kind: Kind) type {
    return struct {
        fn compute(view: *Compute) anyerror!u64 {
            const m = sync_bound.?;
            return switch (kind) {
                .value => blk: {
                    const v = view.get(m.values[i]);
                    break :blk if (v) |x| x +% 1 else 0;
                },
                .readiness => @intFromEnum(view.get(m.readinesses[i])),
                .authority => blk: {
                    const a = view.get(m.authorities[i]);
                    break :blk if (a) |x| x.generation +% 1 else 0;
                },
                .retry => blk: {
                    const r = view.get(m.retries[i]);
                    break :blk if (r) |x| @as(u64, x.attempt) +% 1 else 0;
                },
            };
        }
    };
}

fn syncChannelProbe(comptime c: ChannelIndex) type {
    return struct {
        fn compute(view: *Compute) anyerror!u64 {
            const m = sync_bound.?;
            return @intCast(view.get(m.channels[@intFromEnum(c)]));
        }
    };
}

const SyncModel = struct {
    allocator: std.mem.Allocator,
    ctx: *Context,
    cell: SyncCell,
    keys: [][]const u8,
    key_count: usize = 0,
    values: [max_keys]SyncCell.ValueReader = undefined,
    readinesses: [max_keys]SyncCell.ReadinessReader = undefined,
    authorities: [max_keys]SyncCell.AuthorityReader = undefined,
    retries: [max_keys]SyncCell.RetryReader = undefined,
    channels: [3]SyncCell.ReceiptCountReader = undefined,
    probes: [max_keys][4]?*cell.Computed(u64) = @splat(@splat(null)),
    probe_keys: [max_keys][4]usize = @splat(@splat(0)),
    channel_probes: [3]?*cell.Computed(u64) = @splat(null),
    channel_probe_keys: [3]usize = @splat(0),

    pub const label = "single-threaded";

    pub fn create(
        allocator: std.mem.Allocator,
        keys: [][]const u8,
        policy: IngressPolicy,
        merge_policy: merge.MergePolicy(u64),
        transport: IngressTransportKind,
        poll_interval: u64,
    ) !*SyncModel {
        const ctx = try Context.init(allocator);
        errdefer ctx.deinit();
        const self = try allocator.create(SyncModel);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .ctx = ctx,
            .cell = try SyncCell.init(ctx, policy, merge_policy, transport, poll_interval),
            .keys = keys,
            .key_count = keys.len,
        };
        // Bind the reader handles BEFORE any probe node exists, so no compute body
        // ever mints a graph node mid-recompute.
        for (keys, 0..) |key, i| {
            self.values[i] = try self.cell.value(key);
            self.readinesses[i] = try self.cell.readiness(key);
            self.authorities[i] = try self.cell.authority(key);
            self.retries[i] = try self.cell.retry(key);
        }
        self.channels = .{ self.cell.accepted(), self.cell.dropped(), self.cell.errors() };

        sync_bound = self;
        inline for (0..max_keys) |i| {
            inline for (kind_names, 0..) |_, slot| {
                const kind: Kind = @enumFromInt(slot);
                if (i < keys.len) {
                    const node = try cell.computed(u64, ctx, syncScopeProbe(i, kind).compute, null);
                    self.probes[i][slot] = node;
                    self.probe_keys[i][slot] = node.slot.cache_key.?;
                }
            }
        }
        inline for (channel_names, 0..) |_, slot| {
            const c: ChannelIndex = @enumFromInt(slot);
            const node = try cell.computed(u64, ctx, syncChannelProbe(c).compute, null);
            self.channel_probes[slot] = node;
            self.channel_probe_keys[slot] = node.slot.cache_key.?;
        }
        return self;
    }

    pub fn destroy(self: *SyncModel) void {
        for (self.probes) |row| {
            for (row) |maybe| {
                if (maybe) |node| self.allocator.destroy(node);
            }
        }
        for (self.channel_probes) |maybe| {
            if (maybe) |node| self.allocator.destroy(node);
        }
        self.cell.deinit();
        self.ctx.deinit();
        if (sync_bound == self) sync_bound = null;
        self.allocator.destroy(self);
    }

    /// Read every reader kind, so the caches are warm and the next step's probe
    /// measures *that step's* invalidation and nothing else.
    pub fn materialize(self: *SyncModel) !void {
        for (self.probes[0..self.key_count]) |row| {
            for (row) |maybe| {
                if (maybe) |node| _ = node.get();
            }
        }
        for (self.channel_probes) |maybe| {
            if (maybe) |node| _ = node.get();
        }
        _ = self.cell.schedule();
    }

    /// `true` while the derived node still holds a valid cache. This graph
    /// invalidates in place — the slot stays in the cache marked `stale` until the
    /// next read orphans it — so the probe reads through the cache rather than the
    /// handle's (possibly orphaned) pointer.
    fn cacheValid(self: *SyncModel, key: usize) bool {
        const slot = self.ctx.cacheLookup(key) orelse return false;
        return slot.storage != null and !slot.stale and !slot.disposed;
    }

    pub fn snapshot(self: *SyncModel) !Snapshot {
        var out: Snapshot = .{};
        for (0..self.key_count) |i| {
            for (0..4) |k| out.scopes[i][k] = self.cacheValid(self.probe_keys[i][k]);
        }
        for (0..3) |c| out.receipts[c] = self.cacheValid(self.channel_probe_keys[c]);
        return out;
    }

    // --- ops --------------------------------------------------------------

    pub fn open(self: *SyncModel, key: []const u8, generation: u64) !void {
        return self.cell.open(key, generation);
    }
    pub fn admit(
        self: *SyncModel,
        key: []const u8,
        generation: u64,
        sequence: u64,
        stamped_at: u64,
        payload: u64,
    ) !IngressAdmission {
        return self.cell.admit(
            SyncCell.Envelope.init(key, generation, sequence, stamped_at, payload),
        );
    }
    pub fn suspendScope(self: *SyncModel, key: []const u8) !?ReplayRequest {
        return self.cell.suspendScope(key);
    }
    pub fn reconnect(self: *SyncModel, key: []const u8, generation: u64) !ReplayRequest {
        return self.cell.reconnect(key, generation);
    }
    pub fn close(self: *SyncModel, key: []const u8) !void {
        return self.cell.close(key);
    }
    pub fn fail(self: *SyncModel, key: []const u8, err: IngressError) !void {
        return self.cell.fail(key, err);
    }
    pub fn tick(self: *SyncModel, now: u64) !void {
        return self.cell.tick(now);
    }
    pub fn drain(self: *SyncModel, key: []const u8) !?u64 {
        return self.cell.drain(key);
    }

    // --- reads ------------------------------------------------------------

    pub fn value(self: *SyncModel, key: []const u8) !?u64 {
        return (try self.cell.value(key)).get();
    }
    pub fn readiness(self: *SyncModel, key: []const u8) !IngressReadiness {
        return (try self.cell.readiness(key)).get();
    }
    pub fn authority(self: *SyncModel, key: []const u8) !?IngressAuthority {
        return (try self.cell.authority(key)).get();
    }
    pub fn retry(self: *SyncModel, key: []const u8) !?IngressRetry {
        return (try self.cell.retry(key)).get();
    }
    pub fn acceptedLen(self: *SyncModel) !usize {
        return self.cell.accepted().get();
    }
    pub fn droppedLen(self: *SyncModel) !usize {
        return self.cell.dropped().get();
    }
    pub fn errorsLen(self: *SyncModel) !usize {
        return self.cell.errors().get();
    }
    pub fn view(self: *SyncModel, key: []const u8) ?ScopeView {
        return self.cell.view(key);
    }
    pub fn schedule(self: *SyncModel) IngressSchedule {
        return self.cell.schedule();
    }
};

// ---------------------------------------------------------------------------
// Flavor 2 — thread-safe. Its reader kinds ARE graph nodes, so the probe is the
// context's own cache-validity introspection.
// ---------------------------------------------------------------------------

const TsCell = thread_safe_ingress.ThreadSafeIngressCell([]const u8, u64);

const ThreadSafeModel = struct {
    allocator: std.mem.Allocator,
    ctx: ThreadSafeContext,
    cell: TsCell,
    keys: [][]const u8,
    key_count: usize,

    pub const label = "thread-safe";

    pub fn create(
        allocator: std.mem.Allocator,
        keys: [][]const u8,
        policy: IngressPolicy,
        merge_policy: merge.MergePolicy(u64),
        transport: IngressTransportKind,
        poll_interval: u64,
    ) !*ThreadSafeModel {
        const self = try allocator.create(ThreadSafeModel);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .ctx = ThreadSafeContext.init(allocator),
            .cell = undefined,
            .keys = keys,
            .key_count = keys.len,
        };
        try self.cell.init(&self.ctx, policy, merge_policy, transport, poll_interval);
        // Mint every scope's readers up front: a reader that does not exist would
        // silently pass a `false` invalidation expectation.
        for (keys) |key| _ = try self.cell.scopeReaders(key);
        return self;
    }

    pub fn destroy(self: *ThreadSafeModel) void {
        self.cell.deinit();
        self.ctx.deinit();
        self.allocator.destroy(self);
    }

    pub fn materialize(self: *ThreadSafeModel) !void {
        for (self.keys) |key| {
            _ = try self.cell.value(key);
            _ = try self.cell.readiness(key);
            _ = try self.cell.authority(key);
            _ = try self.cell.retry(key);
        }
        _ = self.cell.acceptedLen();
        _ = self.cell.droppedLen();
        _ = self.cell.errorsLen();
        _ = self.cell.schedule();
    }

    pub fn snapshot(self: *ThreadSafeModel) !Snapshot {
        var out: Snapshot = .{};
        for (self.keys, 0..) |key, i| {
            out.scopes[i] = .{
                try self.cell.valueIsValid(key),
                try self.cell.readinessIsValid(key),
                try self.cell.authorityIsValid(key),
                try self.cell.retryIsValid(key),
            };
        }
        out.receipts = .{
            self.cell.acceptedIsValid(),
            self.cell.droppedIsValid(),
            self.cell.errorsIsValid(),
        };
        return out;
    }

    pub fn open(self: *ThreadSafeModel, key: []const u8, generation: u64) !void {
        return self.cell.open(key, generation);
    }
    pub fn admit(
        self: *ThreadSafeModel,
        key: []const u8,
        generation: u64,
        sequence: u64,
        stamped_at: u64,
        payload: u64,
    ) !IngressAdmission {
        return self.cell.admit(
            TsCell.Envelope.init(key, generation, sequence, stamped_at, payload),
        );
    }
    pub fn suspendScope(self: *ThreadSafeModel, key: []const u8) !?ReplayRequest {
        return self.cell.suspendScope(key);
    }
    pub fn reconnect(self: *ThreadSafeModel, key: []const u8, generation: u64) !ReplayRequest {
        return self.cell.reconnect(key, generation);
    }
    pub fn close(self: *ThreadSafeModel, key: []const u8) !void {
        return self.cell.close(key);
    }
    pub fn fail(self: *ThreadSafeModel, key: []const u8, err: IngressError) !void {
        return self.cell.fail(key, err);
    }
    pub fn tick(self: *ThreadSafeModel, now: u64) !void {
        return self.cell.tick(now);
    }
    pub fn drain(self: *ThreadSafeModel, key: []const u8) !?u64 {
        return self.cell.drain(key);
    }

    pub fn value(self: *ThreadSafeModel, key: []const u8) !?u64 {
        return self.cell.value(key);
    }
    pub fn readiness(self: *ThreadSafeModel, key: []const u8) !IngressReadiness {
        return self.cell.readiness(key);
    }
    pub fn authority(self: *ThreadSafeModel, key: []const u8) !?IngressAuthority {
        return self.cell.authority(key);
    }
    pub fn retry(self: *ThreadSafeModel, key: []const u8) !?IngressRetry {
        return self.cell.retry(key);
    }
    pub fn acceptedLen(self: *ThreadSafeModel) !usize {
        return self.cell.acceptedLen();
    }
    pub fn droppedLen(self: *ThreadSafeModel) !usize {
        return self.cell.droppedLen();
    }
    pub fn errorsLen(self: *ThreadSafeModel) !usize {
        return self.cell.errorsLen();
    }
    pub fn view(self: *ThreadSafeModel, key: []const u8) ?ScopeView {
        return self.cell.view(key);
    }
    pub fn schedule(self: *ThreadSafeModel) IngressSchedule {
        return self.cell.schedule();
    }
};

// ---------------------------------------------------------------------------
// Flavor 3 — async. Note there is no `settle` step in the model: every read
// drives the pending queue itself and hands back a plain value, because admission
// is not async-coloured.
// ---------------------------------------------------------------------------

const AsyncCell = async_ingress.AsyncIngressCell([]const u8, u64);

const AsyncModel = struct {
    allocator: std.mem.Allocator,
    ctx: AsyncCell.Ctx,
    cell: AsyncCell,
    keys: [][]const u8,
    key_count: usize,

    pub const label = "async";

    pub fn create(
        allocator: std.mem.Allocator,
        keys: [][]const u8,
        policy: IngressPolicy,
        merge_policy: merge.MergePolicy(u64),
        transport: IngressTransportKind,
        poll_interval: u64,
    ) !*AsyncModel {
        const self = try allocator.create(AsyncModel);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .ctx = AsyncCell.Ctx.init(allocator),
            .cell = undefined,
            .keys = keys,
            .key_count = keys.len,
        };
        try self.cell.init(&self.ctx, policy, merge_policy, transport, poll_interval);
        for (keys) |key| _ = try self.cell.scopeReaders(key);
        return self;
    }

    pub fn destroy(self: *AsyncModel) void {
        self.cell.deinit();
        self.ctx.deinit();
        self.allocator.destroy(self);
    }

    pub fn materialize(self: *AsyncModel) !void {
        for (self.keys) |key| {
            _ = try self.cell.value(key);
            _ = try self.cell.readiness(key);
            _ = try self.cell.authority(key);
            _ = try self.cell.retry(key);
        }
        _ = try self.cell.acceptedLen();
        _ = try self.cell.droppedLen();
        _ = try self.cell.errorsLen();
        _ = self.cell.schedule();
    }

    pub fn snapshot(self: *AsyncModel) !Snapshot {
        var out: Snapshot = .{};
        for (self.keys, 0..) |key, i| {
            out.scopes[i] = .{
                try self.cell.valueIsValid(key),
                try self.cell.readinessIsValid(key),
                try self.cell.authorityIsValid(key),
                try self.cell.retryIsValid(key),
            };
        }
        out.receipts = .{
            self.cell.acceptedIsValid(),
            self.cell.droppedIsValid(),
            self.cell.errorsIsValid(),
        };
        return out;
    }

    pub fn open(self: *AsyncModel, key: []const u8, generation: u64) !void {
        return self.cell.open(key, generation);
    }
    pub fn admit(
        self: *AsyncModel,
        key: []const u8,
        generation: u64,
        sequence: u64,
        stamped_at: u64,
        payload: u64,
    ) !IngressAdmission {
        return self.cell.admit(
            AsyncCell.Envelope.init(key, generation, sequence, stamped_at, payload),
        );
    }
    pub fn suspendScope(self: *AsyncModel, key: []const u8) !?ReplayRequest {
        return self.cell.suspendScope(key);
    }
    pub fn reconnect(self: *AsyncModel, key: []const u8, generation: u64) !ReplayRequest {
        return self.cell.reconnect(key, generation);
    }
    pub fn close(self: *AsyncModel, key: []const u8) !void {
        return self.cell.close(key);
    }
    pub fn fail(self: *AsyncModel, key: []const u8, err: IngressError) !void {
        return self.cell.fail(key, err);
    }
    pub fn tick(self: *AsyncModel, now: u64) !void {
        return self.cell.tick(now);
    }
    pub fn drain(self: *AsyncModel, key: []const u8) !?u64 {
        return self.cell.drain(key);
    }

    pub fn value(self: *AsyncModel, key: []const u8) !?u64 {
        return self.cell.value(key);
    }
    pub fn readiness(self: *AsyncModel, key: []const u8) !IngressReadiness {
        return self.cell.readiness(key);
    }
    pub fn authority(self: *AsyncModel, key: []const u8) !?IngressAuthority {
        return self.cell.authority(key);
    }
    pub fn retry(self: *AsyncModel, key: []const u8) !?IngressRetry {
        return self.cell.retry(key);
    }
    pub fn acceptedLen(self: *AsyncModel) !usize {
        return self.cell.acceptedLen();
    }
    pub fn droppedLen(self: *AsyncModel) !usize {
        return self.cell.droppedLen();
    }
    pub fn errorsLen(self: *AsyncModel) !usize {
        return self.cell.errorsLen();
    }
    pub fn view(self: *AsyncModel, key: []const u8) ?ScopeView {
        return self.cell.view(key);
    }
    pub fn schedule(self: *AsyncModel) IngressSchedule {
        return self.cell.schedule();
    }
};

// ---------------------------------------------------------------------------
// The replay
// ---------------------------------------------------------------------------

fn keyIndex(keys: [][]const u8, key: []const u8) !usize {
    for (keys, 0..) |k, i| {
        if (std.mem.eql(u8, k, key)) return i;
    }
    return error.UnknownFixtureKey;
}

fn addKey(
    allocator: std.mem.Allocator,
    keys: *std.ArrayList([]const u8),
    key: []const u8,
) !void {
    for (keys.items) |k| {
        if (std.mem.eql(u8, k, key)) return;
    }
    try keys.append(allocator, key);
}

/// Every key the fixture ever mentions, so a reader exists (and is probed) from
/// the first step — an absent reader would silently pass a `false` invalidation
/// expectation.
fn collectKeys(allocator: std.mem.Allocator, fixture: json.Value) ![][]const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    errdefer keys.deinit(allocator);
    const steps = (try jsonFieldRequired(fixture, "steps")).array;
    for (steps.items) |step| {
        const op = try jsonFieldRequired(step, "op");
        if (jsonField(op, "key")) |k| try addKey(allocator, &keys, try jsonAsString(k));
        const expected = jsonField(step, "expected") orelse continue;
        const scopes = jsonField(expected, "scopes") orelse continue;
        switch (scopes) {
            .object => |map| {
                var it = map.iterator();
                while (it.next()) |entry| try addKey(allocator, &keys, entry.key_ptr.*);
            },
            else => {},
        }
    }
    if (keys.items.len > max_keys) return error.TooManyFixtureKeys;
    return keys.toOwnedSlice(allocator);
}

/// Assert the fixture's expected state after one step. Reads through the reactive
/// readers, so a shell that under-invalidated fails HERE as well as in the
/// invalidation matrix.
/// `assertKeyWith` context for `expected.scopes`. Generic over the flavor's
/// model type, which is comptime here.
fn StateCtx(comptime M: type) type {
    return struct {
        model: M,
        where: []const u8,

        fn check(self: @This(), scopes: json.Value) !void {
            try assertState(self.model, scopes, self.where);
        }

        fn checkReceipts(self: @This(), receipts: json.Value) !void {
            try assertReceipts(self.model, receipts, self.where);
        }
    };
}

fn assertState(model: anytype, scopes: json.Value, where: []const u8) !void {
    switch (scopes) {
        .object => |map| {
            var it = map.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const want = entry.value_ptr.*;
                const got = model.view(key) orelse {
                    std.debug.print("{s}: scope {s} absent\n", .{ where, key });
                    return error.TestExpectedEqual;
                };
                try testing.expectEqual(
                    try requiredEnum(IngressLifecycle, want, "lifecycle"),
                    got.lifecycle,
                );
                try expectEqU64(where, try requiredU64(want, "generation"), got.generation);
                try expectEqOptU64(
                    where,
                    try jsonAsOptU64(try jsonFieldRequired(want, "delivered_through")),
                    got.delivered_through,
                );
                try expectEqU64(where, try requiredU64(want, "buffered"), got.buffered);
                try expectEqU64(
                    where,
                    try requiredU64(want, "consecutive_errors"),
                    got.consecutive_errors,
                );
                try expectEqOptU64(
                    where,
                    try jsonAsOptU64(try jsonFieldRequired(want, "window")),
                    try model.value(key),
                );
                try testing.expectEqual(
                    try requiredEnum(IngressReadiness, want, "readiness"),
                    try model.readiness(key),
                );

                const got_authority = try model.authority(key);
                switch (try jsonFieldRequired(want, "authority")) {
                    .null => try testing.expectEqual(
                        @as(?IngressAuthority, null),
                        got_authority,
                    ),
                    else => |want_authority| try testing.expectEqual(
                        IngressAuthority{
                            .generation = try requiredU64(want_authority, "generation"),
                            .delivered_through = try jsonAsOptU64(
                                try jsonFieldRequired(want_authority, "delivered_through"),
                            ),
                            .stamped_at = try requiredU64(want_authority, "stamped_at"),
                        },
                        got_authority.?,
                    ),
                }

                const got_retry = try model.retry(key);
                switch (try jsonFieldRequired(want, "retry")) {
                    .null => try testing.expectEqual(@as(?IngressRetry, null), got_retry),
                    else => |want_retry| try testing.expectEqual(
                        IngressRetry{
                            .attempt = @intCast(try requiredU64(want_retry, "attempt")),
                            .backoff = try requiredU64(want_retry, "backoff"),
                            .resume_from = try requiredU64(want_retry, "resume_from"),
                        },
                        got_retry.?,
                    ),
                }
            }
        },
        else => return error.ExpectedObject,
    }

}

fn assertReceipts(model: anytype, receipts: json.Value, where: []const u8) !void {
    try expectEqU64(where, try requiredU64(receipts, "accepted"), try model.acceptedLen());
    try expectEqU64(where, try requiredU64(receipts, "dropped"), try model.droppedLen());
    try expectEqU64(where, try requiredU64(receipts, "error"), try model.errorsLen());
}

/// Assert `invalidates` in BOTH directions. `true` means the reader's cache went
/// from valid to invalid across the op; `false` means it stayed valid — so a shell
/// that invalidated anyway fails here, and over-invalidation is as visible as
/// under-. Returns the number of flags asserted, so the caller can prove the
/// matrix was not silently absent.
/// `assertKeyWith` context for `expected.invalidates`. The flag count comes back
/// through `asserted`, since the check itself returns void.
const InvalidationCtx = struct {
    keys: [][]const u8,
    before: Snapshot,
    after: Snapshot,
    where: []const u8,
    asserted: *usize,

    fn check(self: InvalidationCtx, want: json.Value) !void {
        self.asserted.* = try assertInvalidation(
            self.keys,
            want,
            self.before,
            self.after,
            self.where,
        );
    }
};

/// The matrix nests under `expected`, NOT on the step. lazily-rs's MAP runner
/// read it off the step, so it was always absent and the assertion never ran
/// once. Pin the nesting so that cannot recur here.
fn assertInvalidation(
    keys: [][]const u8,
    want: json.Value,
    before: Snapshot,
    after: Snapshot,
    where: []const u8,
) !usize {
    var asserted: usize = 0;

    const want_scopes = try jsonFieldRequired(want, "scopes");
    switch (want_scopes) {
        .object => |map| {
            var it = map.iterator();
            while (it.next()) |entry| {
                const i = try keyIndex(keys, entry.key_ptr.*);
                inline for (kind_names, 0..) |kind_name, slot| {
                    const flag = try jsonAsBool(
                        try jsonFieldRequired(entry.value_ptr.*, kind_name),
                    );
                    const was_valid = before.scopes[i][slot];
                    const now_valid = after.scopes[i][slot];
                    const invalidated = was_valid and !now_valid;
                    if (invalidated != flag) {
                        std.debug.print(
                            "{s}: {s}.{s} invalidation want {} got {} " ++
                                "(was valid={}, now valid={})\n",
                            .{
                                where,
                                entry.key_ptr.*,
                                kind_name,
                                flag,
                                invalidated,
                                was_valid,
                                now_valid,
                            },
                        );
                        return error.TestExpectedEqual;
                    }
                    asserted += 1;
                }
            }
        },
        else => return error.ExpectedObject,
    }

    const want_receipts = try jsonFieldRequired(want, "receipts");
    inline for (.{ "accepted", "dropped", "error" }, 0..) |name, c| {
        const flag = try jsonAsBool(try jsonFieldRequired(want_receipts, name));
        const invalidated = before.receipts[c] and !after.receipts[c];
        if (invalidated != flag) {
            std.debug.print("{s}: receipts.{s} invalidation want {} got {}\n", .{
                where,
                name,
                flag,
                invalidated,
            });
            return error.TestExpectedEqual;
        }
        asserted += 1;
    }
    return asserted;
}

const ReplayCount = struct { steps: usize, flags: usize };

/// Replay one fixture against one flavor. Returns the step count, so a caller can
/// prove this binary actually opened the corpus rather than merely naming it.
fn replay(
    comptime Model: type,
    allocator: std.mem.Allocator,
    fixture: json.Value,
    name: []const u8,
) !ReplayCount {
    const policy = try policyOf(try jsonFieldRequired(fixture, "policy"));
    const merge_policy = try mergeOf(try requiredString(fixture, "merge"));
    const transport = try requiredEnum(IngressTransportKind, fixture, "transport");
    const poll_interval = try requiredU64(fixture, "poll_interval");

    const keys = try collectKeys(allocator, fixture);
    defer allocator.free(keys);

    const model = try Model.create(
        allocator,
        keys,
        policy,
        merge_policy,
        transport,
        poll_interval,
    );
    defer model.destroy();

    // The schedule is a derive of the transport and nothing else.
    try testing.expectEqual(
        IngressSchedule.forKind(transport, poll_interval),
        model.schedule(),
    );

    try model.materialize();

    var counts: ReplayCount = .{ .steps = 0, .flags = 0 };
    const steps = (try jsonFieldRequired(fixture, "steps")).array;
    for (steps.items, 0..) |step, index| {
        const op = try jsonFieldRequired(step, "op");
        const op_type = try requiredString(op, "type");

        var where_buf: [192]u8 = undefined;
        const where = try std.fmt.bufPrint(&where_buf, "{s}/{s} step {d} ({s})", .{
            Model.label,
            name,
            index,
            op_type,
        });

        const before = try model.snapshot();
        const returns = jsonField(step, "returns");

        if (std.mem.eql(u8, op_type, "admit")) {
            const admission = try model.admit(
                try requiredString(op, "key"),
                try requiredU64(op, "generation"),
                try requiredU64(op, "sequence"),
                try requiredU64(op, "stamped_at"),
                try requiredU64(op, "payload"),
            );
            if (returns) |want| try expectAdmission(want, admission, where);
        } else if (std.mem.eql(u8, op_type, "open")) {
            try model.open(try requiredString(op, "key"), try requiredU64(op, "generation"));
        } else if (std.mem.eql(u8, op_type, "drain")) {
            const drained = try model.drain(try requiredString(op, "key"));
            if (returns) |want| {
                try expectEqOptU64(
                    where,
                    try jsonAsOptU64(try jsonFieldRequired(want, "drained")),
                    drained,
                );
            }
        } else if (std.mem.eql(u8, op_type, "suspend")) {
            const request = try model.suspendScope(try requiredString(op, "key"));
            if (returns) |want| {
                try testing.expectEqual(
                    try expectedReplay(try jsonFieldRequired(want, "replay")),
                    request,
                );
            }
        } else if (std.mem.eql(u8, op_type, "reconnect")) {
            const request = try model.reconnect(
                try requiredString(op, "key"),
                try requiredU64(op, "generation"),
            );
            if (returns) |want| {
                try testing.expectEqual(
                    try expectedReplay(try jsonFieldRequired(want, "replay")),
                    @as(?ReplayRequest, request),
                );
            }
        } else if (std.mem.eql(u8, op_type, "close")) {
            try model.close(try requiredString(op, "key"));
        } else if (std.mem.eql(u8, op_type, "fail")) {
            try model.fail(
                try requiredString(op, "key"),
                try requiredEnum(IngressError, op, "error"),
            );
        } else if (std.mem.eql(u8, op_type, "tick")) {
            try model.tick(try requiredU64(op, "now"));
        } else {
            std.debug.print("{s}: unknown op `{s}`\n", .{ where, op_type });
            return error.UnknownOpType;
        }

        // Snapshot BEFORE asserting state: `assertState` reads through the
        // readers, which re-warms every cache it touches.
        const after = try model.snapshot();
        // One guard over the step's whole `expected` block, shared by both
        // helpers: every key it carries has to be claimed by one of them
        // (#lzassertunknownkeys).
        // The matrix nests under `expected`, NOT on the step. lazily-rs's MAP
        // runner read it off the step, so it was always absent and the
        // assertion never ran once. Pin the nesting so that cannot recur here.
        if (jsonField(step, "invalidates") != null) return error.InvalidatesMustNestUnderExpected;
        var expected = cj.AssertionKeys.init(
            "ingress-family expected", try jsonFieldRequired(step, "expected"));
        const StateCheck = StateCtx(@TypeOf(model));
        try expected.assertKeyWith(
            "scopes",
            StateCheck{ .model = model, .where = where },
            StateCheck.check,
        );
        try expected.assertKeyWith(
            "receipts",
            StateCheck{ .model = model, .where = where },
            StateCheck.checkReceipts,
        );
        var flags: usize = 0;
        try expected.assertKeyWith("invalidates", InvalidationCtx{
            .keys = keys,
            .before = before,
            .after = after,
            .where = where,
            .asserted = &flags,
        }, InvalidationCtx.check);
        counts.flags += flags;
        try expected.finish();
        try model.materialize();
        counts.steps += 1;
    }
    return counts;
}

fn loadFixture(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    const path = try std.fmt.allocPrint(allocator, SPEC_DIR ++ "{s}", .{name});
    defer allocator.free(path);
    return readFixtureFile(path) catch null;
}

fn corpusPresent() bool {
    const raw = loadFixture(testing.allocator, FIXTURES[0]) catch return false;
    if (raw) |bytes| {
        testing.allocator.free(bytes);
        return true;
    }
    return false;
}

/// Replay the whole corpus against one flavor. Returns the total step count and
/// the total number of invalidation flags asserted.
fn replayCorpus(comptime Model: type) !ReplayCount {
    const allocator = testing.allocator;
    var totals: ReplayCount = .{ .steps = 0, .flags = 0 };
    for (FIXTURES) |name| {
        const raw = (try loadFixture(allocator, name)) orelse return error.FixtureMissing;
        defer allocator.free(raw);
        var parsed = try json.parseFromSlice(json.Value, allocator, raw, .{
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        // The fixture names the PRIMITIVE, not the execution model: the flavor
        // axis lives here in the runner.
        try testing.expectEqualStrings("IngressCell", try requiredString(parsed.value, "model"));
        const counts = try replay(Model, allocator, parsed.value, name);
        totals.steps += counts.steps;
        totals.flags += counts.flags;
    }
    return totals;
}

fn expectedStepTotal() !usize {
    const allocator = testing.allocator;
    var total: usize = 0;
    for (FIXTURES) |name| {
        const raw = (try loadFixture(allocator, name)) orelse return error.FixtureMissing;
        defer allocator.free(raw);
        var parsed = try json.parseFromSlice(json.Value, allocator, raw, .{});
        defer parsed.deinit();
        total += (try jsonFieldRequired(parsed.value, "steps")).array.items.len;
    }
    return total;
}

/// Every replay asserts at least this many invalidation flags per step: the four
/// reader kinds of the one scope the step names, plus the three receipt channels.
/// Steps naming two scopes assert eleven.
const flags_per_step_floor = 7;

// ---------------------------------------------------------------------------
// The gates
// ---------------------------------------------------------------------------

test "lazily/ingress conformance: the corpus is present and non-trivial" {
    if (!corpusPresent()) return error.SkipZigTest;
    const total = try expectedStepTotal();
    if (total < 30) {
        std.debug.print(
            "the ingress corpus replays only {d} steps; that is not the named schedule set\n",
            .{total},
        );
        return error.TestExpectedEqual;
    }
}

test "lazily/ingress conformance: the single-threaded flavor replays the corpus" {
    if (!corpusPresent()) return error.SkipZigTest;
    const counts = try replayCorpus(SyncModel);
    // A positive count is the only thing that proves this binary opened the
    // fixtures; the absence guard above proves only that they exist on disk.
    try testing.expect(counts.steps > 0);
    try testing.expectEqual(try expectedStepTotal(), counts.steps);
    try testing.expect(counts.flags >= counts.steps * flags_per_step_floor);
}

test "lazily/ingress conformance: the thread-safe flavor replays the corpus" {
    if (!corpusPresent()) return error.SkipZigTest;
    const counts = try replayCorpus(ThreadSafeModel);
    try testing.expect(counts.steps > 0);
    try testing.expectEqual(try expectedStepTotal(), counts.steps);
    try testing.expect(counts.flags >= counts.steps * flags_per_step_floor);
}

test "lazily/ingress conformance: the async flavor replays the corpus" {
    if (!corpusPresent()) return error.SkipZigTest;
    const counts = try replayCorpus(AsyncModel);
    try testing.expect(counts.steps > 0);
    try testing.expectEqual(try expectedStepTotal(), counts.steps);
    try testing.expect(counts.flags >= counts.steps * flags_per_step_floor);
}

// ---------------------------------------------------------------------------
// The ledger — enforced against the source, in both directions.
// ---------------------------------------------------------------------------

const IngressFlavor = struct {
    label: []const u8,
    /// The type whose definition in the family's source proves the claim.
    type_name: []const u8,
    shipped: bool,
    /// Which module is supposed to define it.
    module: []const u8,
};

const ingress_flavor_ledger = [_]IngressFlavor{
    .{
        .label = "single-threaded",
        .type_name = "IngressCell",
        .shipped = true,
        .module = "ingress.zig",
    },
    .{
        .label = "thread-safe",
        .type_name = "ThreadSafeIngressCell",
        .shipped = true,
        .module = "thread_safe_ingress.zig",
    },
    .{
        .label = "async",
        .type_name = "AsyncIngressCell",
        .shipped = true,
        .module = "async_ingress.zig",
    },
};

/// The family's source text, reached from the filesystem at compile time.
///
/// `@embedFile` rather than a `readDir` walk for two reasons. First, cwd: a test
/// binary may run from somewhere other than the repo root, and a ledger that
/// silently skips itself is not a ledger. Second, self-reference: this file lives
/// in the same package as the shells, so a directory grep would find the ledger's
/// own `type_name` string literals and report every flavor present — the exact
/// false positive that made `queue.zig`'s first ledger fail against correct code.
/// This file is deliberately NOT part of the searched text.
///
/// A deleted or renamed shell module fails the *build*, which is louder still.
const family_source = @embedFile("ingress_core.zig") ++
    @embedFile("ingress.zig") ++
    @embedFile("thread_safe_ingress.zig") ++
    @embedFile("async_ingress.zig");

test "lazily/ingress ledger: unshipped flavors are really absent" {
    // The evidence channel guards itself: empty source text would report every
    // flavor absent and pass every `shipped = false` row for free.
    try testing.expect(family_source.len > 1000);

    for (ingress_flavor_ledger) |flavor| {
        // `pub fn X(comptime` — the definition, not a doc-comment mention.
        var needle_buf: [128]u8 = undefined;
        const needle = try std.fmt.bufPrint(
            &needle_buf,
            "pub fn {s}(comptime",
            .{flavor.type_name},
        );
        const defined = std.mem.indexOf(u8, family_source, needle) != null;
        if (flavor.shipped and !defined) {
            std.debug.print(
                "ledger row `{s}` claims shipped, but `pub fn {s}(` is not defined in the " ++
                    "ingress family source (expected in {s}); fix the ledger or ship it\n",
                .{ flavor.label, flavor.type_name, flavor.module },
            );
            return error.TestExpectedEqual;
        }
        if (!flavor.shipped and defined) {
            std.debug.print(
                "`{s}` now EXISTS but the ingress ledger still records the {s} flavor as " ++
                    "unshipped, so the canonical corpus is not replayed against it. Fix: flip " ++
                    ".shipped AND extend `replayCorpus` to drive it. Do NOT flip the flag " ++
                    "alone — that restores the false green this check prevents.\n",
                .{ flavor.type_name, flavor.label },
            );
            return error.TestExpectedEqual;
        }
    }
}

test "lazily/ingress ledger: is not all skips" {
    // In a summary line, "skipped" and "passed" are indistinguishable.
    var shipped: usize = 0;
    for (ingress_flavor_ledger) |flavor| {
        if (flavor.shipped) shipped += 1;
    }
    try testing.expect(shipped > 0);
    try testing.expectEqual(@as(usize, 3), ingress_flavor_ledger.len);
    // One replay test per row, and the row order is the replay order above.
    try testing.expectEqualStrings(ingress_flavor_ledger[0].label, SyncModel.label);
    try testing.expectEqualStrings(ingress_flavor_ledger[1].label, ThreadSafeModel.label);
    try testing.expectEqualStrings(ingress_flavor_ledger[2].label, AsyncModel.label);
}

test "lazily/ingress ledger: every fixture the replay list names really exists" {
    if (!corpusPresent()) return error.SkipZigTest;
    // The runtime coverage guard (`scripts/check-conformance-coverage.sh`) fails on
    // a canonical fixture nothing opened. This is the near end of the same check:
    // every name in the list must resolve to real bytes, so a typo cannot shorten
    // the run silently.
    for (FIXTURES) |name| {
        const raw = (try loadFixture(testing.allocator, name)) orelse {
            std.debug.print("fixture {s} named by the replay list does not exist\n", .{name});
            return error.FixtureMissing;
        };
        testing.allocator.free(raw);
    }
    try testing.expectEqual(@as(usize, 7), FIXTURES.len);
}

// ---------------------------------------------------------------------------
// The probe itself must be able to fail.
// ---------------------------------------------------------------------------

test "lazily/ingress conformance: the invalidation probe discriminates" {
    // The corpus asserts NEGATIVE invalidation, so a probe stuck on "always
    // invalidated" or "never invalidated" would pass half the matrix for free.
    // This pins it on every flavor: reading warms the cache, an op that dirties
    // the reader clears it, and one that does not leaves it warm.
    const allocator = testing.allocator;
    var keys = [_][]const u8{"alpha"};
    const value_slot = @intFromEnum(Kind.value);

    inline for (.{ SyncModel, ThreadSafeModel, AsyncModel }) |Model| {
        const model = try Model.create(
            allocator,
            keys[0..],
            .{},
            merge.sum(u64),
            .event_channel,
            25,
        );
        defer model.destroy();

        try model.materialize();
        try testing.expect((try model.snapshot()).scopes[0][value_slot]);

        _ = try model.admit("alpha", 1, 0, 0, 1);
        try testing.expect(!(try model.snapshot()).scopes[0][value_slot]);

        try model.materialize();
        _ = try model.admit("alpha", 1, 5, 0, 1);
        // A buffered envelope must NOT invalidate the value reader.
        try testing.expect((try model.snapshot()).scopes[0][value_slot]);
    }
}

// Mutation-check record (`#designimplementtransport`). Each deliberate defect was
// introduced, `mise run test` run, and the defect reverted with an mtime bump — a
// restore that preserves mtime lets the build system reuse the MUTATED artifact
// and report a false green. All seven were killed:
//
// * fence checked after dedupe → `ingress_generation_handoff` step 2 fails,
//   reporting `duplicate_sequence` where the corpus expects `stale_generation`.
// * handoff keeps the superseded window → `ingress_generation_handoff` step 4
//   fails on the window value.
// * `buffered` marks every reader dirty → every `invalidates: false` step fails,
//   in all three flavors.
// * `tick` marks readiness unconditionally → `ingress_freshness_and_retry` step 1
//   (the in-horizon tick) fails on `alpha.readiness`.
// * `Block` advances the watermark → `ingress_backpressure`'s final step reports
//   `duplicate_sequence` instead of an accept.
// * thread-safe `publish` runs outside `batch()` → the frontier-walk gate in
//   `thread_safe_ingress.zig` fails (four effect runs for one admission).
// * the error-receipt channel is never cleared → the replay fails on
//   `invalidates.receipts.error`. This one is the reason `invalidates` is asserted
//   per channel rather than by receipt COUNT: a stale cache recomputes to the
//   right count, so a count-only gate would have called it green.
