//! The unified keyed reactive family (`ReactiveFamily`) and its materialization
//! mode (`#lzmatmode`).
//!
//! `lazily-spec/cell-model.md` § "The `ReactiveFamily` vehicle" fixes a **keyed
//! reactive family** that maps keys `K` to per-entry reactive nodes and abstracts
//! over the entry's **handle kind** (`ReactiveFamily<K, V, H>` in Rust). Zig has
//! no runtime closures and keys its reactive slots by comptime function pointer,
//! so this port fixes the handle-kind axis with a comptime `EntryKind` parameter
//! and models the materialization axis — *when* a derived node is allocated —
//! with its own present-set + value cache, exactly the `Mat` state of
//! `lazily-formal`'s `Materialization` module:
//!
//! - **Cell entries** ([`EntryKind.cell`]) are **input** nodes. An input has no
//!   derivation to defer, so it is **always materialized** regardless of mode.
//!   The keyed cell collection ([`CellFamily`](collection.zig)) is this
//!   input-cell specialization; cell entries are writable inputs (see `set`).
//! - **Slot entries** ([`EntryKind.slot`]) are **derived** nodes. These are what
//!   materialization mode governs.
//!
//! # Materialization mode
//!
//! Materialization mode is **orthogonal** to entry kind: it fixes *when a derived
//! cell's backing node is allocated*, never what it computes or how it converges,
//! and it MUST NOT be observable through any cell's value.
//!
//! - [`MaterializationMode.eager`] (**default**) — every derived node is
//!   allocated when the family is built. A read is a direct node access.
//! - [`MaterializationMode.lazy`] (opt-in) — a derived node is allocated on its
//!   **first read** ("materialize on pull"), addressed by key. A never-read
//!   derived cell is never allocated. Lazy is a keyed overlay on the eager core,
//!   not a second engine: the first read of key `k` builds the *same* node the
//!   eager build would have, then caches it.
//!
//! Entry kind is orthogonal to mode (proved in `lazily-formal`'s `Materialization`
//! module as `cell_entries_materialized_in_every_mode` /
//! `slot_entries_deferred_under_lazy`): choosing lazy defers only slot entries,
//! never cell entries. Observational transparency
//! (`observe (build eager s) id = observe (build lazy s) id = s.val id`) holds:
//! mode changes allocation timing and memory, never observed values.

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("context.zig").Context;

/// When a [`ReactiveFamily`]'s derived (slot) entries are allocated. Orthogonal
/// to [`EntryKind`]; never observable on the value axis.
///
/// Mirrors `Mode` in `lazily-formal`'s `Materialization` module. The default is
/// [`eager`](MaterializationMode.eager) (`Mode.default = Mode.eager`).
pub const MaterializationMode = enum {
    /// Allocate every derived node up front at build time. The shared
    /// high-performance core and the required default.
    eager,
    /// Allocate a derived node on its first read, keyed rather than
    /// handle-addressed. An opt-in overlay on the eager core.
    lazy,

    /// The default materialization mode. Implementations MUST default to eager.
    pub fn default() MaterializationMode {
        return .eager;
    }
};

/// Which kind of reactive node a [`ReactiveFamily`] entry is — the handle-kind
/// axis the family fixes at comptime, kept orthogonal to [`MaterializationMode`].
///
/// Mirrors `EntryKind` in `lazily-formal`'s `Materialization` module.
pub const EntryKind = enum {
    /// An **input** cell — always materialized, any mode; writable via `set`.
    cell,
    /// A **derived** slot — materialized eagerly, or lazily on first read.
    slot,
};

/// Choose the right hash map implementation for key type K.
/// `[]const u8` uses `StringHashMap` (hashes content); everything else uses
/// `AutoHashMap`. Mirrors `collection.zig`.
fn HashMapFor(comptime K: type, comptime V: type) type {
    if (K == []const u8) return std.StringHashMap(V);
    return std.AutoHashMap(K, V);
}

/// The canonical per-key value producer — a derived slot's recompute, or an
/// input cell's initial value (`s.val` in the formal model). Zig has no
/// closures, so a captured factory is expressed as a userdata pointer plus a
/// call function (the standard Zig closure-emulation idiom). Use [`pure`] for a
/// factory with no captured state.
pub fn Factory(comptime K: type, comptime V: type) type {
    return struct {
        ptr: *anyopaque,
        call_fn: *const fn (ptr: *anyopaque, key: K) V,

        const Self = @This();

        /// Produce `key`'s canonical value.
        pub fn call(self: Self, key: K) V {
            return self.call_fn(self.ptr, key);
        }

        /// Build a factory from a pure `key -> value` function (no captured
        /// state). The userdata pointer is unused.
        pub fn pure(comptime f: fn (K) V) Self {
            const Wrap = struct {
                fn call(_: *anyopaque, key: K) V {
                    return f(key);
                }
            };
            return .{ .ptr = undefined, .call_fn = Wrap.call };
        }
    };
}

/// The unified keyed reactive family (`#lzmatmode`): keys `K` map to per-entry
/// reactive nodes of the comptime-fixed [`EntryKind`], allocated per its
/// [`MaterializationMode`].
///
/// See the module docs for the eager/lazy contract and the
/// [`CellFamily`](collection.zig) input-cell specialization.
pub fn ReactiveFamily(comptime K: type, comptime V: type, comptime entry_kind: EntryKind) type {
    return struct {
        ctx: *Context,
        /// This family's materialization mode (read directly).
        mode: MaterializationMode,
        /// Canonical per-key value producer.
        factory: Factory(K, V),
        /// Currently-allocated entries (the "present" set) and their cached
        /// value. Grows on materialize, never shrinks silently — deferral, not
        /// de-allocation.
        materialized: HashMapFor(K, V),
        /// First-materialization order of the present set (stable snapshot for
        /// `presentKeys`).
        order: std.ArrayList(K),
        allocator: std.mem.Allocator,

        const Self = @This();

        /// This family's entry kind (comptime).
        pub const kind: EntryKind = entry_kind;

        fn build(
            ctx: *Context,
            mode: MaterializationMode,
            keys: []const K,
            factory: Factory(K, V),
        ) !Self {
            var self = Self{
                .ctx = ctx,
                .mode = mode,
                .factory = factory,
                .materialized = HashMapFor(K, V).init(ctx.allocator),
                .order = .empty,
                .allocator = ctx.allocator,
            };
            for (keys) |key| {
                // buildEager materializes every node; buildLazy materializes only
                // input cells (`present := isInput`). A cell entry is always
                // materialized regardless of mode; a slot entry only under eager.
                if (entry_kind == .cell or mode == .eager) {
                    try self.materializeKey(key);
                }
            }
            return self;
        }

        /// Build an **eager** family: every declared key's node is allocated now.
        /// This is the default mode ([`MaterializationMode.eager`]).
        pub fn eager(ctx: *Context, keys: []const K, factory: Factory(K, V)) !Self {
            return build(ctx, .eager, keys, factory);
        }

        /// Build a **lazy** family: derived (slot) entries are deferred to first
        /// read; input (cell) entries in `keys` are still materialized at build
        /// (cells are always materialized). Pass an empty `keys` for a purely
        /// on-demand slot family.
        pub fn lazy(ctx: *Context, keys: []const K, factory: Factory(K, V)) !Self {
            return build(ctx, .lazy, keys, factory);
        }

        /// Build a family in the **default** mode (eager). Alias for [`eager`].
        pub fn new(ctx: *Context, keys: []const K, factory: Factory(K, V)) !Self {
            return eager(ctx, keys, factory);
        }

        pub fn deinit(self: *Self) void {
            self.order.deinit(self.allocator);
            self.materialized.deinit();
        }

        /// Materialize `key` if absent (the lazy pull), caching its canonical
        /// value and recording first-materialization order. A warm key is a
        /// no-op — the present set only grows (`materialize_present_monotone`).
        fn materializeKey(self: *Self, key: K) !void {
            if (self.materialized.contains(key)) return; // warm: already allocated.
            const value = self.factory.call(key);
            try self.materialized.put(key, value);
            try self.order.append(self.allocator, key);
        }

        /// Get `key`'s value, materializing it on first access (the lazy pull)
        /// and caching it. Under eager an entry is already present.
        pub fn get(self: *Self, key: K) !V {
            try self.materializeKey(key);
            return self.materialized.get(key).?;
        }

        /// Observe `key`'s value — the headline transparency law: the returned
        /// value is identical under either mode. Materializes the entry if
        /// absent.
        pub fn observe(self: *Self, key: K) !V {
            return self.get(key);
        }

        /// Overwrite an input **cell** entry's value (cells are writable inputs,
        /// materialized-by-set). Materializes the entry if absent, then caches
        /// the new value without re-ordering. Compile error on a slot family:
        /// derived slots have no writable input.
        pub fn set(self: *Self, key: K, value: V) !void {
            if (entry_kind != .cell) @compileError("ReactiveFamily.set is only valid on cell (input) families");
            try self.materializeKey(key);
            try self.materialized.put(key, value);
        }

        /// Whether `key` is currently materialized (present in the allocated
        /// set). Non-reactive.
        pub fn isPresent(self: *const Self, key: K) bool {
            return self.materialized.contains(key);
        }

        /// The currently-materialized keys, in first-materialization order. The
        /// present set only grows (deferral, not de-allocation).
        pub fn presentKeys(self: *const Self) []const K {
            return self.order.items;
        }

        /// Number of currently-materialized entries.
        pub fn presentCount(self: *const Self) usize {
            return self.order.items.len;
        }

        /// This family's entry kind ([`EntryKind.cell`] for a cell family,
        /// [`EntryKind.slot`] for a slot family).
        pub fn entryKind(self: *const Self) EntryKind {
            _ = self;
            return entry_kind;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests — mirror lazily-rs `src/reactive_family.rs` unit tests, which name the
// `lazily-formal` Materialization theorems each asserts.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn timesThree(k: u32) u32 {
    return k * 3;
}

fn timesTwo(k: u32) u32 {
    return k * 2;
}

fn zeroFor(_: []const u8) u32 {
    return 0;
}

fn identity(k: u32) u32 {
    return k;
}

// `default_mode_eager`: the default materialization mode is eager.
test "lazily/reactive_family: default mode is eager" {
    try testing.expectEqual(MaterializationMode.eager, MaterializationMode.default());
}

// `eager_materializes_all`: eager allocates every declared node up front.
test "lazily/reactive_family: eager materializes all up front" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var fam = try ReactiveFamily(u32, u32, .slot).eager(
        ctx,
        &.{ 0, 1, 2, 5, 9 },
        Factory(u32, u32).pure(timesThree),
    );
    defer fam.deinit();

    try testing.expectEqual(@as(usize, 5), fam.presentCount());
    for ([_]u32{ 0, 1, 2, 5, 9 }) |k| {
        try testing.expect(fam.isPresent(k));
    }
}

// `lazy_defers_slots`: lazy leaves an unread derived slot unallocated.
test "lazily/reactive_family: lazy defers slots until read" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var fam = try ReactiveFamily(u32, u32, .slot).lazy(
        ctx,
        &.{ 0, 1, 2, 5, 9 },
        Factory(u32, u32).pure(timesThree),
    );
    defer fam.deinit();

    try testing.expectEqual(@as(usize, 0), fam.presentCount());
    try testing.expect(!fam.isPresent(5));

    // First read materializes just that key ("materialize on pull").
    try testing.expectEqual(@as(u32, 15), try fam.observe(5));
    try testing.expect(fam.isPresent(5));
    try testing.expectEqual(@as(usize, 1), fam.presentCount());
    try testing.expectEqual(@as(u32, 5), fam.presentKeys()[0]);
}

// `eager_lazy_observationally_equivalent` / `observe_canonical`: identical
// values under either mode.
test "lazily/reactive_family: eager and lazy observe identically" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var eager_fam = try ReactiveFamily(u32, u32, .slot).eager(
        ctx,
        &.{ 0, 1, 2, 5, 9 },
        Factory(u32, u32).pure(timesThree),
    );
    defer eager_fam.deinit();
    var lazy_fam = try ReactiveFamily(u32, u32, .slot).lazy(
        ctx,
        &.{ 0, 1, 2, 5, 9 },
        Factory(u32, u32).pure(timesThree),
    );
    defer lazy_fam.deinit();

    for ([_]u32{ 0, 1, 2, 5, 9 }) |k| {
        try testing.expectEqual(try eager_fam.observe(k), try lazy_fam.observe(k));
    }
}

// `materialize_present_monotone`: re-reading a key does not change the present
// set; the set only grows.
test "lazily/reactive_family: present set is monotone across reads" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var fam = try ReactiveFamily(u32, u32, .slot).lazy(
        ctx,
        &.{ 1, 2, 3, 4, 5 },
        Factory(u32, u32).pure(timesTwo),
    );
    defer fam.deinit();

    var sizes: [4]usize = undefined;
    const reads = [_]u32{ 2, 4, 2, 5 };
    for (reads, 0..) |k, i| {
        _ = try fam.observe(k);
        sizes[i] = fam.presentCount();
    }
    // Re-reading 2 does not re-materialize; sizes are non-decreasing.
    try testing.expectEqualSlices(usize, &.{ 1, 2, 2, 3 }, &sizes);
    try testing.expectEqualSlices(u32, &.{ 2, 4, 5 }, fam.presentKeys());
}

// `cell_entries_materialized_in_every_mode`: an input-cell family is fully
// materialized at build under **either** mode.
test "lazily/reactive_family: cell family materialized in every mode" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    const keys = [_][]const u8{ "a", "b", "c" };
    inline for ([_]MaterializationMode{ .eager, .lazy }) |mode| {
        var fam = try ReactiveFamily([]const u8, u32, .cell).build(
            ctx,
            mode,
            &keys,
            Factory([]const u8, u32).pure(zeroFor),
        );
        defer fam.deinit();
        try testing.expectEqual(EntryKind.cell, fam.entryKind());
        // Cells are always present at build, even under lazy.
        try testing.expectEqual(@as(usize, 3), fam.presentCount());
    }
}

// Cell entries are writable inputs (materialized-by-set), distinct from derived
// slots.
test "lazily/reactive_family: cell family entries are writable inputs" {
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    var fam = try ReactiveFamily(u32, u32, .cell).eager(
        ctx,
        &.{7},
        Factory(u32, u32).pure(identity),
    );
    defer fam.deinit();

    try testing.expectEqual(@as(u32, 7), try fam.get(7));
    try fam.set(7, 100);
    try testing.expectEqual(@as(u32, 100), try fam.observe(7));
}

// ---------------------------------------------------------------------------
// lazily-spec conformance fixture replay
// `../lazily-spec/conformance/materialization/*.json` — the executable form of
// the `lazily-formal` Materialization theorems (mirrors lazily-rs
// `tests/materialization_conformance.rs`).
// ---------------------------------------------------------------------------

const json = std.json;
const SPEC_DIR = "../lazily-spec/conformance/materialization";
const FV = i64;

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
    const raw = readFixtureFile(SPEC_DIR ++ "/observational_transparency.json") catch return false;
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

fn jsonAsI64(value: json.Value) !FV {
    return switch (value) {
        .integer => |n| @intCast(n),
        .number_string => |s| try std.fmt.parseInt(FV, s, 10),
        else => error.ExpectedInteger,
    };
}

fn jsonAsString(value: json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}

/// A runtime `key -> value` lookup over a fixture's `spec.val` / `spec.entries`
/// map, exposed to a family as a captured [`Factory`] (userdata pointer).
const Lookup = struct {
    map: std.StringHashMap(FV),

    fn init() Lookup {
        return .{ .map = std.StringHashMap(FV).init(std.testing.allocator) };
    }

    fn deinit(self: *Lookup) void {
        self.map.deinit();
    }

    fn call(ptr: *anyopaque, key: []const u8) FV {
        const self: *Lookup = @ptrCast(@alignCast(ptr));
        return self.map.get(key) orelse std.debug.panic("no spec val for key {s}", .{key});
    }

    fn factory(self: *Lookup) Factory([]const u8, FV) {
        return .{ .ptr = self, .call_fn = Lookup.call };
    }
};

/// Assert `expected` and `got` are the same *set* of keys (order-independent).
fn expectSameKeySet(expected: []const json.Value, got: []const []const u8) !void {
    try testing.expectEqual(expected.len, got.len);
    for (expected) |want_v| {
        const want = try jsonAsString(want_v);
        var found = false;
        for (got) |g| {
            if (std.mem.eql(u8, g, want)) {
                found = true;
                break;
            }
        }
        if (!found) {
            std.debug.print("missing expected present key: {s}\n", .{want});
            return error.KeySetMismatch;
        }
    }
}

fn arrayItems(value: json.Value) ![]const json.Value {
    return switch (value) {
        .array => |a| a.items,
        else => error.ExpectedArray,
    };
}

const Family = ReactiveFamily([]const u8, FV, .slot);
const CellFam = ReactiveFamily([]const u8, FV, .cell);

/// Shared checks for the two `spec.val` fixtures (all-slot families): default
/// mode eager, eager materializes all, observational transparency eager==lazy.
fn checkValFixture(ctx: *Context, name: []const u8) !void {
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ SPEC_DIR, name });
    defer testing.allocator.free(path);
    const raw = try readFixtureFile(path);
    defer testing.allocator.free(raw);
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const fixture = parsed.value;
    const expected = try jsonFieldRequired(fixture, "expected");

    // default_mode_eager
    try testing.expectEqualStrings("eager", try jsonAsString(try jsonFieldRequired(expected, "default_mode")));

    // Build the runtime lookup + declared key order from `spec.val`.
    const val_obj = switch (try jsonFieldRequired(try jsonFieldRequired(fixture, "spec"), "val")) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };
    var lookup = Lookup.init();
    defer lookup.deinit();
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(testing.allocator);
    var it = val_obj.iterator();
    while (it.next()) |entry| {
        try lookup.map.put(entry.key_ptr.*, try jsonAsI64(entry.value_ptr.*));
        try keys.append(testing.allocator, entry.key_ptr.*);
    }

    var eager_fam = try Family.eager(ctx, keys.items, lookup.factory());
    defer eager_fam.deinit();
    var lazy_fam = try Family.lazy(ctx, keys.items, lookup.factory());
    defer lazy_fam.deinit();

    // eager_materializes_all / lazy_defers_slots
    try testing.expectEqual(keys.items.len, eager_fam.presentCount());
    try expectSameKeySet(try arrayItems(try jsonFieldRequired(expected, "eager_present")), eager_fam.presentKeys());
    try testing.expectEqual(@as(usize, 0), lazy_fam.presentCount());

    // observe_canonical / eager_lazy_observationally_equivalent
    const observe_obj = switch (try jsonFieldRequired(expected, "observe")) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };
    var oit = observe_obj.iterator();
    while (oit.next()) |entry| {
        const want = try jsonAsI64(entry.value_ptr.*);
        try testing.expectEqual(want, try eager_fam.observe(entry.key_ptr.*));
        try testing.expectEqual(want, try lazy_fam.observe(entry.key_ptr.*));
    }
}

test "lazily/reactive_family conformance: observational_transparency" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    try checkValFixture(ctx, "observational_transparency.json");

    // Replay the lazy read sequence on a fresh family; the lazy present set is
    // exactly the read keys (lazy_defers_slots).
    const raw = try readFixtureFile(SPEC_DIR ++ "/observational_transparency.json");
    defer testing.allocator.free(raw);
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const fixture = parsed.value;
    const expected = try jsonFieldRequired(fixture, "expected");

    const val_obj = switch (try jsonFieldRequired(try jsonFieldRequired(fixture, "spec"), "val")) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };
    var lookup = Lookup.init();
    defer lookup.deinit();
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(testing.allocator);
    var it = val_obj.iterator();
    while (it.next()) |entry| {
        try lookup.map.put(entry.key_ptr.*, try jsonAsI64(entry.value_ptr.*));
        try keys.append(testing.allocator, entry.key_ptr.*);
    }

    var lazy_fam = try Family.lazy(ctx, keys.items, lookup.factory());
    defer lazy_fam.deinit();
    for (try arrayItems(try jsonFieldRequired(fixture, "reads"))) |r| {
        _ = try lazy_fam.observe(try jsonAsString(r));
    }
    try expectSameKeySet(try arrayItems(try jsonFieldRequired(expected, "lazy_present_after_reads")), lazy_fam.presentKeys());
}

test "lazily/reactive_family conformance: deferral_not_deallocation" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    try checkValFixture(ctx, "deferral_not_deallocation.json");

    const raw = try readFixtureFile(SPEC_DIR ++ "/deferral_not_deallocation.json");
    defer testing.allocator.free(raw);
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const fixture = parsed.value;
    const expected = try jsonFieldRequired(fixture, "expected");

    const val_obj = switch (try jsonFieldRequired(try jsonFieldRequired(fixture, "spec"), "val")) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };
    var lookup = Lookup.init();
    defer lookup.deinit();
    var keys = std.ArrayList([]const u8).empty;
    defer keys.deinit(testing.allocator);
    var it = val_obj.iterator();
    while (it.next()) |entry| {
        try lookup.map.put(entry.key_ptr.*, try jsonAsI64(entry.value_ptr.*));
        try keys.append(testing.allocator, entry.key_ptr.*);
    }

    var lazy_fam = try Family.lazy(ctx, keys.items, lookup.factory());
    defer lazy_fam.deinit();

    // present_after_each_read: cumulative present-set size, monotone and
    // unchanged by a re-read (materialize_present_monotone).
    const want_sizes = try arrayItems(try jsonFieldRequired(expected, "present_after_each_read"));
    const reads = try arrayItems(try jsonFieldRequired(fixture, "reads"));
    try testing.expectEqual(want_sizes.len, reads.len);
    for (reads, want_sizes) |r, want| {
        _ = try lazy_fam.observe(try jsonAsString(r));
        try testing.expectEqual(@as(usize, @intCast(try jsonAsI64(want))), lazy_fam.presentCount());
    }

    // lazy_present_after_reads is a subset of eager_present.
    const lazy_present = try jsonFieldRequired(expected, "lazy_present_after_reads");
    try expectSameKeySet(try arrayItems(lazy_present), lazy_fam.presentKeys());
    const eager_present = try arrayItems(try jsonFieldRequired(expected, "eager_present"));
    for (lazy_fam.presentKeys()) |k| {
        var in_eager = false;
        for (eager_present) |e| {
            if (std.mem.eql(u8, try jsonAsString(e), k)) {
                in_eager = true;
                break;
            }
        }
        try testing.expect(in_eager);
    }
}

test "lazily/reactive_family conformance: entry_kind_orthogonal_to_mode" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();

    const raw = try readFixtureFile(SPEC_DIR ++ "/entry_kind_orthogonal_to_mode.json");
    defer testing.allocator.free(raw);
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const fixture = parsed.value;
    const expected = try jsonFieldRequired(fixture, "expected");
    try testing.expectEqualStrings("eager", try jsonAsString(try jsonFieldRequired(expected, "default_mode")));

    // Split the family's declared entries by kind: input cells vs derived slots.
    // A single ReactiveFamily fixes one handle kind, so a mixed-kind fixture is
    // modelled by a cell family over the cell entries and a slot family over the
    // slot entries — sharing one logical key space (mirrors lazily-rs).
    const entries_obj = switch (try jsonFieldRequired(try jsonFieldRequired(fixture, "spec"), "entries")) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };
    var lookup = Lookup.init();
    defer lookup.deinit();
    var cell_keys = std.ArrayList([]const u8).empty;
    defer cell_keys.deinit(testing.allocator);
    var slot_keys = std.ArrayList([]const u8).empty;
    defer slot_keys.deinit(testing.allocator);
    var it = entries_obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const kind = try jsonAsString(try jsonFieldRequired(entry.value_ptr.*, "kind"));
        try lookup.map.put(key, try jsonAsI64(try jsonFieldRequired(entry.value_ptr.*, "val")));
        if (std.mem.eql(u8, kind, "cell")) {
            try cell_keys.append(testing.allocator, key);
        } else if (std.mem.eql(u8, kind, "slot")) {
            try slot_keys.append(testing.allocator, key);
        } else return error.UnknownEntryKind;
    }

    // Eager build: every entry present (cells + slots).
    var eager_cells = try CellFam.eager(ctx, cell_keys.items, lookup.factory());
    defer eager_cells.deinit();
    var eager_slots = try Family.eager(ctx, slot_keys.items, lookup.factory());
    defer eager_slots.deinit();
    try testing.expectEqual(EntryKind.cell, eager_cells.entryKind());
    try testing.expectEqual(EntryKind.slot, eager_slots.entryKind());
    try testing.expectEqual(
        eager_cells.presentCount() + eager_slots.presentCount(),
        (try arrayItems(try jsonFieldRequired(expected, "eager_present"))).len,
    );

    // Lazy build: cells present at build, slots deferred.
    var lazy_cells = try CellFam.lazy(ctx, cell_keys.items, lookup.factory());
    defer lazy_cells.deinit();
    var lazy_slots = try Family.lazy(ctx, slot_keys.items, lookup.factory());
    defer lazy_slots.deinit();
    try testing.expectEqual(@as(usize, 0), lazy_slots.presentCount());
    try expectSameKeySet(try arrayItems(try jsonFieldRequired(expected, "lazy_present_at_build")), lazy_cells.presentKeys());

    // Reads (slot pulls) grow only the slot present set.
    for (try arrayItems(try jsonFieldRequired(fixture, "reads"))) |r| {
        const key = try jsonAsString(r);
        if (lazy_cells.isPresent(key)) {
            _ = try lazy_cells.observe(key);
        } else {
            _ = try lazy_slots.observe(key);
        }
    }
    // Combined lazy present set after reads.
    const want_after = try arrayItems(try jsonFieldRequired(expected, "lazy_present_after_reads"));
    try testing.expectEqual(want_after.len, lazy_cells.presentCount() + lazy_slots.presentCount());

    // Observational transparency across kinds.
    const observe_obj = switch (try jsonFieldRequired(expected, "observe")) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };
    var oit = observe_obj.iterator();
    while (oit.next()) |entry| {
        const want = try jsonAsI64(entry.value_ptr.*);
        const key = entry.key_ptr.*;
        if (eager_cells.isPresent(key) or lazy_cells.isPresent(key)) {
            try testing.expectEqual(want, try eager_cells.observe(key));
            try testing.expectEqual(want, try lazy_cells.observe(key));
        } else {
            try testing.expectEqual(want, try eager_slots.observe(key));
            try testing.expectEqual(want, try lazy_slots.observe(key));
        }
    }
}
