//! Embedded-service plane (`#lzservice`) — the Zig port of lazily-rs
//! `src/service.rs` (see `lazily-spec/docs/service.md` and the formal model
//! `lazily-formal/LazilyFormal/Service.lean`).
//!
//! The story for "an instance is also a host of services": `HealthCell` /
//! `ReadinessCell` / `DiscoveryCell` / `ServiceRegistry`, each a pure compute
//! **core** (an aggregation / keyed map) split from a thin reactive **cell**
//! projecting the composed view.
//!
//! Reactive-cell model (matching `temporal.zig`): each shell owns a per-reader
//! logical version counter bumped **only when the projected reader value
//! provably changes** — the edge-only invalidation contract. Scalar readers
//! (`health`, `ready`) compare the projected value; collection readers
//! (`discovery`, `projection`) compare a canonical, key-sorted signature string.
//! A conformance test diffs the version snapshot across a step to assert the
//! fixture's `invalidates` matrix (the Zig analogue of the rs `Cell<T>`
//! `PartialEq` store-guard). Cells seed the stored reader value/signature to the
//! rs default (`Healthy` / `ready = true` / empty map) before replay so the
//! FIRST op only invalidates when it actually changes the projection.

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("context.zig").Context;

// ===========================================================================
// Health
// ===========================================================================

/// Composed health status (worst component dominates).
pub const Health = enum {
    healthy,
    degraded,
    unhealthy,

    /// Canonical fixture spelling.
    pub fn toString(self: Health) []const u8 {
        return switch (self) {
            .healthy => "Healthy",
            .degraded => "Degraded",
            .unhealthy => "Unhealthy",
        };
    }
};

/// One liveness probe's report.
const Probe = struct { up: bool, critical: bool };

/// Composed liveness-probe core. Each probe reports `up` and whether it is
/// `critical`. Keys are borrowed slices (they outlive the core).
pub const HealthCore = struct {
    probes: std.StringHashMap(Probe),

    pub fn init(allocator: std.mem.Allocator) HealthCore {
        return .{ .probes = std.StringHashMap(Probe).init(allocator) };
    }
    pub fn deinit(self: *HealthCore) void {
        self.probes.deinit();
    }
    /// Set/refresh a probe.
    pub fn set(self: *HealthCore, name: []const u8, up: bool, critical: bool) !void {
        try self.probes.put(name, .{ .up = up, .critical = critical });
    }
    /// The aggregate: Unhealthy if any critical probe is down, else Degraded if
    /// any is down, else Healthy.
    pub fn health(self: *const HealthCore) Health {
        var any_down = false;
        var it = self.probes.valueIterator();
        while (it.next()) |p| {
            if (p.critical and !p.up) return .unhealthy;
            if (!p.up) any_down = true;
        }
        return if (any_down) .degraded else .healthy;
    }
};

/// Reactive health: projects the aggregate for `/health`. `health` invalidates
/// only when the aggregate changes.
pub const HealthCell = struct {
    ctx: *Context,
    core: HealthCore,
    prev_health: Health = .healthy,
    health_version: u64 = 0,

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) HealthCell {
        return .{ .ctx = ctx, .core = HealthCore.init(allocator) };
    }
    pub fn deinit(self: *HealthCell) void {
        self.core.deinit();
    }
    pub fn set(self: *HealthCell, name: []const u8, up: bool, critical: bool) !void {
        try self.core.set(name, up, critical);
        const h = self.core.health();
        if (h != self.prev_health) {
            self.prev_health = h;
            self.health_version += 1;
        }
    }
    pub fn health(self: *const HealthCell) Health {
        return self.core.health();
    }
    pub fn healthVersion(self: *const HealthCell) u64 {
        return self.health_version;
    }
};

// ===========================================================================
// Readiness
// ===========================================================================

/// Composed readiness-probe core: ready iff every condition holds.
pub const ReadinessCore = struct {
    conditions: std.StringHashMap(bool),

    pub fn init(allocator: std.mem.Allocator) ReadinessCore {
        return .{ .conditions = std.StringHashMap(bool).init(allocator) };
    }
    pub fn deinit(self: *ReadinessCore) void {
        self.conditions.deinit();
    }
    pub fn set(self: *ReadinessCore, name: []const u8, ready_val: bool) !void {
        try self.conditions.put(name, ready_val);
    }
    /// Ready iff every condition is true (empty → true).
    pub fn ready(self: *const ReadinessCore) bool {
        var it = self.conditions.valueIterator();
        while (it.next()) |v| {
            if (!v.*) return false;
        }
        return true;
    }
};

/// Reactive readiness: projects `ready` for `/ready`. Invalidates only on a flip.
pub const ReadinessCell = struct {
    ctx: *Context,
    core: ReadinessCore,
    prev_ready: bool = true,
    ready_version: u64 = 0,

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) ReadinessCell {
        return .{ .ctx = ctx, .core = ReadinessCore.init(allocator) };
    }
    pub fn deinit(self: *ReadinessCell) void {
        self.core.deinit();
    }
    pub fn set(self: *ReadinessCell, name: []const u8, ready_val: bool) !void {
        try self.core.set(name, ready_val);
        const r = self.core.ready();
        if (r != self.prev_ready) {
            self.prev_ready = r;
            self.ready_version += 1;
        }
    }
    pub fn ready(self: *const ReadinessCell) bool {
        return self.core.ready();
    }
    pub fn readyVersion(self: *const ReadinessCell) u64 {
        return self.ready_version;
    }
};

// ===========================================================================
// Canonical collection signature
// ===========================================================================

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Build a canonical, key-sorted `k=v;k=v;` signature of a `service → endpoint`
/// map. Order-independent, so it flags content changes for a collection reader.
/// Caller owns the returned slice.
fn mapSignature(allocator: std.mem.Allocator, map: *const std.StringHashMap([]const u8)) ![]u8 {
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(allocator);
    var it = map.iterator();
    while (it.next()) |e| try keys.append(allocator, e.key_ptr.*);
    std.mem.sort([]const u8, keys.items, {}, strLess);

    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);
    for (keys.items) |k| {
        try buf.appendSlice(allocator, k);
        try buf.append(allocator, '=');
        try buf.appendSlice(allocator, map.get(k).?);
        try buf.append(allocator, ';');
    }
    return buf.toOwnedSlice(allocator);
}

// ===========================================================================
// Discovery
// ===========================================================================

/// One discovery entry: the live endpoint and its owning peer.
fn DiscoveryEntry(comptime P: type) type {
    return struct { endpoint: []const u8, owner: P };
}

/// Service-discovery core: `service → (endpoint, owner)`. A peer's departure
/// (`evict`) removes its endpoints. Keys/endpoints are borrowed slices.
pub fn DiscoveryCore(comptime P: type) type {
    return struct {
        entries: std.StringHashMap(DiscoveryEntry(P)),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .entries = std.StringHashMap(DiscoveryEntry(P)).init(allocator) };
        }
        pub fn deinit(self: *Self) void {
            self.entries.deinit();
        }
        pub fn register(self: *Self, service: []const u8, endpoint: []const u8, peer: P) !void {
            try self.entries.put(service, .{ .endpoint = endpoint, .owner = peer });
        }
        pub fn deregister(self: *Self, service: []const u8) void {
            _ = self.entries.remove(service);
        }
        /// Remove all endpoints owned by `peer` (membership loss).
        pub fn evict(self: *Self, peer: P) !void {
            var doomed = std.ArrayList([]const u8).empty;
            defer doomed.deinit(self.entries.allocator);
            var it = self.entries.iterator();
            while (it.next()) |e| {
                if (std.meta.eql(e.value_ptr.owner, peer)) {
                    try doomed.append(self.entries.allocator, e.key_ptr.*);
                }
            }
            for (doomed.items) |k| _ = self.entries.remove(k);
        }
        pub fn resolve(self: *const Self, service: []const u8) ?[]const u8 {
            return if (self.entries.get(service)) |e| e.endpoint else null;
        }
        /// The live `service → endpoint` map. Caller owns/deinits it.
        pub fn discovery(self: *const Self, allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
            var map = std.StringHashMap([]const u8).init(allocator);
            errdefer map.deinit();
            var it = self.entries.iterator();
            while (it.next()) |e| try map.put(e.key_ptr.*, e.value_ptr.endpoint);
            return map;
        }
    };
}

/// Reactive service discovery. `discovery` (a collection reader) invalidates
/// only when the live `service → endpoint` map changes content.
pub fn DiscoveryCell(comptime P: type) type {
    return struct {
        ctx: *Context,
        allocator: std.mem.Allocator,
        core: DiscoveryCore(P),
        prev_signature: []u8,
        discovery_version: u64 = 0,

        const Self = @This();

        pub fn init(ctx: *Context, allocator: std.mem.Allocator) !Self {
            return .{
                .ctx = ctx,
                .allocator = allocator,
                .core = DiscoveryCore(P).init(allocator),
                .prev_signature = try allocator.alloc(u8, 0), // empty-map signature
            };
        }
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.prev_signature);
            self.core.deinit();
        }
        fn refresh(self: *Self) !void {
            var proj = try self.core.discovery(self.allocator);
            defer proj.deinit();
            const sig = try mapSignature(self.allocator, &proj);
            if (!std.mem.eql(u8, sig, self.prev_signature)) {
                self.allocator.free(self.prev_signature);
                self.prev_signature = sig;
                self.discovery_version += 1;
            } else {
                self.allocator.free(sig);
            }
        }
        pub fn register(self: *Self, service: []const u8, endpoint: []const u8, peer: P) !void {
            try self.core.register(service, endpoint, peer);
            try self.refresh();
        }
        pub fn deregister(self: *Self, service: []const u8) !void {
            self.core.deregister(service);
            try self.refresh();
        }
        pub fn evict(self: *Self, peer: P) !void {
            try self.core.evict(peer);
            try self.refresh();
        }
        pub fn resolve(self: *const Self, service: []const u8) ?[]const u8 {
            return self.core.resolve(service);
        }
        /// The live `service → endpoint` map. Caller owns/deinits it.
        pub fn discovery(self: *const Self, allocator: std.mem.Allocator) !std.StringHashMap([]const u8) {
            return self.core.discovery(allocator);
        }
        pub fn discoveryVersion(self: *const Self) u64 {
            return self.discovery_version;
        }
    };
}

// ===========================================================================
// Service registry (durable)
// ===========================================================================

/// A durable registry op (the ordered log entry). Slices are borrowed.
pub const RegistryOp = union(enum) {
    register: struct { service: []const u8, endpoint: []const u8 },
    deregister: struct { service: []const u8 },
};

/// Durable service-registry core: an ordered log (the `DurableOutbox` pattern)
/// whose left-fold is the projection, so replay reconstructs it.
pub const ServiceRegistryCore = struct {
    allocator: std.mem.Allocator,
    log: std.ArrayList(RegistryOp),
    projection: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) ServiceRegistryCore {
        return .{
            .allocator = allocator,
            .log = std.ArrayList(RegistryOp).empty,
            .projection = std.StringHashMap([]const u8).init(allocator),
        };
    }
    pub fn deinit(self: *ServiceRegistryCore) void {
        // Ops hold borrowed slices — free only the list, not the entries.
        self.log.deinit(self.allocator);
        self.projection.deinit();
    }
    fn apply(projection: *std.StringHashMap([]const u8), op: RegistryOp) !void {
        switch (op) {
            .register => |r| try projection.put(r.service, r.endpoint),
            .deregister => |d| _ = projection.remove(d.service),
        }
    }
    pub fn register(self: *ServiceRegistryCore, service: []const u8, endpoint: []const u8) !void {
        const op = RegistryOp{ .register = .{ .service = service, .endpoint = endpoint } };
        try apply(&self.projection, op);
        try self.log.append(self.allocator, op);
    }
    pub fn deregister(self: *ServiceRegistryCore, service: []const u8) !void {
        const op = RegistryOp{ .deregister = .{ .service = service } };
        try apply(&self.projection, op);
        try self.log.append(self.allocator, op);
    }
    /// Rebuild the projection from the durable log (restart / crash-replay).
    pub fn replay(self: *ServiceRegistryCore) !void {
        self.projection.clearRetainingCapacity();
        for (self.log.items) |op| try apply(&self.projection, op);
    }
    pub fn projectionMap(self: *const ServiceRegistryCore) *const std.StringHashMap([]const u8) {
        return &self.projection;
    }
};

/// Reactive durable service registry. `projection` (a collection reader)
/// invalidates only when the projected map changes content.
pub const ServiceRegistry = struct {
    ctx: *Context,
    allocator: std.mem.Allocator,
    core: ServiceRegistryCore,
    prev_signature: []u8,
    projection_version: u64 = 0,

    pub fn init(ctx: *Context, allocator: std.mem.Allocator) !ServiceRegistry {
        return .{
            .ctx = ctx,
            .allocator = allocator,
            .core = ServiceRegistryCore.init(allocator),
            .prev_signature = try allocator.alloc(u8, 0), // empty-map signature
        };
    }
    pub fn deinit(self: *ServiceRegistry) void {
        self.allocator.free(self.prev_signature);
        self.core.deinit();
    }
    fn refresh(self: *ServiceRegistry) !void {
        const sig = try mapSignature(self.allocator, &self.core.projection);
        if (!std.mem.eql(u8, sig, self.prev_signature)) {
            self.allocator.free(self.prev_signature);
            self.prev_signature = sig;
            self.projection_version += 1;
        } else {
            self.allocator.free(sig);
        }
    }
    pub fn register(self: *ServiceRegistry, service: []const u8, endpoint: []const u8) !void {
        try self.core.register(service, endpoint);
        try self.refresh();
    }
    pub fn deregister(self: *ServiceRegistry, service: []const u8) !void {
        try self.core.deregister(service);
        try self.refresh();
    }
    pub fn replay(self: *ServiceRegistry) !void {
        try self.core.replay();
        try self.refresh();
    }
    pub fn projectionMap(self: *const ServiceRegistry) *const std.StringHashMap([]const u8) {
        return &self.core.projection;
    }
    pub fn projectionVersion(self: *const ServiceRegistry) u64 {
        return self.projection_version;
    }
};

// ===========================================================================
// Unit tests (pure cores)
// ===========================================================================

test "service: health worst-component dominates" {
    var h = HealthCore.init(std.testing.allocator);
    defer h.deinit();
    try h.set("cache", true, false);
    try std.testing.expectEqual(Health.healthy, h.health());
    try h.set("cache", false, false);
    try std.testing.expectEqual(Health.degraded, h.health());
    try h.set("db", false, true);
    try std.testing.expectEqual(Health.unhealthy, h.health());
}

test "service: readiness all-conditions" {
    var r = ReadinessCore.init(std.testing.allocator);
    defer r.deinit();
    try r.set("deps", false);
    try std.testing.expect(!r.ready());
    try r.set("deps", true);
    try std.testing.expect(r.ready());
}

test "service: discovery evict removes owner's endpoints" {
    var d = DiscoveryCore(u64).init(std.testing.allocator);
    defer d.deinit();
    try d.register("api", "e1", 1);
    try d.register("db", "e2", 2);
    try d.evict(2);
    var proj = try d.discovery(std.testing.allocator);
    defer proj.deinit();
    try std.testing.expectEqual(@as(usize, 1), proj.count());
    try std.testing.expectEqualStrings("e1", d.resolve("api").?);
    try std.testing.expect(d.resolve("db") == null);
}

test "service: registry replay reconstructs projection" {
    var reg = ServiceRegistryCore.init(std.testing.allocator);
    defer reg.deinit();
    try reg.register("api", "v1");
    try reg.register("api", "v2");
    try reg.deregister("db");
    try std.testing.expectEqualStrings("v2", reg.projection.get("api").?);
    const before = reg.projection.count();
    try reg.replay();
    try std.testing.expectEqual(before, reg.projection.count());
    try std.testing.expectEqualStrings("v2", reg.projection.get("api").?);
}

// ===========================================================================
// lazily-spec conformance fixture replay
// `../lazily-spec/conformance/service/*.json` (mirrors lazily-rs
// `tests/service_conformance.rs`).
// ===========================================================================

const json = std.json;
const SPEC_DIR = "../lazily-spec/conformance/service";

fn readFixtureFile(path: []const u8) ![]u8 {
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

fn specFixturesPresent() bool {
    const raw = readFixtureFile(SPEC_DIR ++ "/health.json") catch return false;
    std.testing.allocator.free(raw);
    return true;
}

fn jsonField(value: json.Value, name: []const u8) ?json.Value {
    return switch (value) {
        .object => |object| object.get(name),
        else => null,
    };
}
fn jsonFieldRequired(value: json.Value, name: []const u8) !json.Value {
    return jsonField(value, name) orelse error.MissingField;
}
fn jsonAsU64(value: json.Value) !u64 {
    return switch (value) {
        .integer => |n| if (n >= 0) @as(u64, @intCast(n)) else error.ExpectedUnsigned,
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
fn jsonAsString(value: json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}

fn loadFixture(name: []const u8) !json.Parsed(json.Value) {
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ SPEC_DIR, name });
    defer std.testing.allocator.free(path);
    const raw = try readFixtureFile(path);
    defer std.testing.allocator.free(raw);
    return json.parseFromSlice(json.Value, std.testing.allocator, raw, .{ .allocate = .alloc_always });
}

fn steps(fx: json.Value) ![]const json.Value {
    return switch (try jsonFieldRequired(fx, "steps")) {
        .array => |a| a.items,
        else => error.ExpectedArray,
    };
}

/// The fixture's `invalidates[reader]` flag for a step.
fn invalidates(step: json.Value, reader: []const u8) !bool {
    const exp = try jsonFieldRequired(step, "expected");
    const inv = try jsonFieldRequired(exp, "invalidates");
    return jsonAsBool(try jsonFieldRequired(inv, reader));
}

/// Assert a live `service → endpoint` map equals the fixture object as a set of
/// pairs (count + every key/value).
fn expectMapEquals(actual: *const std.StringHashMap([]const u8), expected: json.Value) !void {
    const obj = switch (expected) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };
    try std.testing.expectEqual(obj.count(), actual.count());
    var it = obj.iterator();
    while (it.next()) |e| {
        const got = actual.get(e.key_ptr.*) orelse return error.MissingKey;
        try std.testing.expectEqualStrings(try jsonAsString(e.value_ptr.*), got);
    }
}

test "service conformance: health" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var cell = HealthCell.init(ctx, std.testing.allocator);
    defer cell.deinit();
    var parsed = try loadFixture("health.json");
    defer parsed.deinit();

    for (try steps(parsed.value)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const name = try jsonAsString(try jsonFieldRequired(op, "name"));
        const up = try jsonAsBool(try jsonFieldRequired(op, "up"));
        const critical = try jsonAsBool(try jsonFieldRequired(op, "critical"));

        const pre = cell.healthVersion();
        try cell.set(name, up, critical);

        const exp = try jsonFieldRequired(step, "expected");
        try std.testing.expectEqualStrings(
            try jsonAsString(try jsonFieldRequired(exp, "health")),
            cell.health().toString(),
        );
        try std.testing.expectEqual(try invalidates(step, "health"), cell.healthVersion() != pre);
    }
}

test "service conformance: readiness" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var cell = ReadinessCell.init(ctx, std.testing.allocator);
    defer cell.deinit();
    var parsed = try loadFixture("readiness.json");
    defer parsed.deinit();

    for (try steps(parsed.value)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const name = try jsonAsString(try jsonFieldRequired(op, "name"));
        const ready_val = try jsonAsBool(try jsonFieldRequired(op, "ready"));

        const pre = cell.readyVersion();
        try cell.set(name, ready_val);

        const exp = try jsonFieldRequired(step, "expected");
        try std.testing.expectEqual(try jsonAsBool(try jsonFieldRequired(exp, "ready")), cell.ready());
        try std.testing.expectEqual(try invalidates(step, "ready"), cell.readyVersion() != pre);
    }
}

test "service conformance: discovery" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var cell = try DiscoveryCell(u64).init(ctx, std.testing.allocator);
    defer cell.deinit();
    var parsed = try loadFixture("discovery.json");
    defer parsed.deinit();

    for (try steps(parsed.value)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const op_type = try jsonAsString(try jsonFieldRequired(op, "type"));

        const pre = cell.discoveryVersion();
        if (std.mem.eql(u8, op_type, "register")) {
            try cell.register(
                try jsonAsString(try jsonFieldRequired(op, "service")),
                try jsonAsString(try jsonFieldRequired(op, "endpoint")),
                try jsonAsU64(try jsonFieldRequired(op, "peer")),
            );
        } else if (std.mem.eql(u8, op_type, "deregister")) {
            try cell.deregister(try jsonAsString(try jsonFieldRequired(op, "service")));
        } else if (std.mem.eql(u8, op_type, "evict")) {
            try cell.evict(try jsonAsU64(try jsonFieldRequired(op, "peer")));
        } else if (std.mem.eql(u8, op_type, "resolve")) {
            const got = cell.resolve(try jsonAsString(try jsonFieldRequired(op, "service")));
            try std.testing.expectEqualStrings(
                try jsonAsString(try jsonFieldRequired(step, "returns")),
                got.?,
            );
        } else return error.UnknownOp;

        const exp = try jsonFieldRequired(step, "expected");
        var proj = try cell.discovery(std.testing.allocator);
        defer proj.deinit();
        try expectMapEquals(&proj, try jsonFieldRequired(exp, "discovery"));
        try std.testing.expectEqual(try invalidates(step, "discovery"), cell.discoveryVersion() != pre);
    }
}

test "service conformance: service_registry" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var reg = try ServiceRegistry.init(ctx, std.testing.allocator);
    defer reg.deinit();
    var parsed = try loadFixture("service_registry.json");
    defer parsed.deinit();

    for (try steps(parsed.value)) |step| {
        const op = try jsonFieldRequired(step, "op");
        const op_type = try jsonAsString(try jsonFieldRequired(op, "type"));

        const pre = reg.projectionVersion();
        if (std.mem.eql(u8, op_type, "register")) {
            try reg.register(
                try jsonAsString(try jsonFieldRequired(op, "service")),
                try jsonAsString(try jsonFieldRequired(op, "endpoint")),
            );
        } else if (std.mem.eql(u8, op_type, "deregister")) {
            try reg.deregister(try jsonAsString(try jsonFieldRequired(op, "service")));
        } else if (std.mem.eql(u8, op_type, "replay")) {
            try reg.replay();
        } else return error.UnknownOp;

        const exp = try jsonFieldRequired(step, "expected");
        try expectMapEquals(reg.projectionMap(), try jsonFieldRequired(exp, "projection"));
        try std.testing.expectEqual(try invalidates(step, "projection"), reg.projectionVersion() != pre);
    }
}
