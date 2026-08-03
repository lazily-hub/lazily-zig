//! Shared JSON accessors for the canonical-corpus replays
//! (`#lazilyupgradeconformance`, `#lazilyzigconformance`).
//!
//! Eight fixtures in this binding used to be asserted by INLINE MIRRORS: the
//! expected values were typed into the `.zig` source and the fixture was named
//! only in a comment, so upstream could change the corpus and the mirror stayed
//! green. The runtime manifest catches "nobody opened this file"; it cannot
//! make a runner exist. These accessors are that runner's shared half — kept in
//! one module rather than copied into a sixth conformance file.
//!
//! Everything here is test-only. `load` reads through the manifest recorder, so
//! a replay built on it feeds the coverage guard by construction.

const std = @import("std");

pub const json = std.json;
pub const Value = json.Value;

/// Reads through the runtime conformance manifest recorder: naming a fixture is
/// not replaying it, so the coverage guard is fed by observed reads rather than
/// a source grep.
pub const specReadFile = @import("conformance_manifest.zig").specReadFile;

/// Runtime scenario ledger (`#lzscenariocoverage`). See `Scenarios` below.
pub const recordScenario = @import("conformance_manifest.zig").recordScenario;

pub const CONFORMANCE_ROOT = "../lazily-spec/conformance";

pub const Fixture = json.Parsed(Value);

/// Load and parse `<corpus>/<rel_path>`. `null` means the `lazily-spec` sibling
/// checkout is absent — the same skip every replay in this repo takes locally.
/// CI asserts the directories are present so a skip cannot report green there.
///
/// `alloc_always` copies every string into the parse arena, so the returned
/// fixture outlives the raw bytes and a replay may hold slices into it for the
/// whole test.
pub fn load(rel_path: []const u8) !?Fixture {
    const allocator = std.testing.allocator;
    const path = try std.fmt.allocPrint(allocator, CONFORMANCE_ROOT ++ "/{s}", .{rel_path});
    defer allocator.free(path);
    const raw = specReadFile(path) catch return null;
    defer allocator.free(raw);
    return try json.parseFromSlice(Value, allocator, raw, .{ .allocate = .alloc_always });
}

pub fn field(value: Value, name: []const u8) ?Value {
    return switch (value) {
        .object => |o| o.get(name),
        else => null,
    };
}

pub fn required(value: Value, name: []const u8) !Value {
    return field(value, name) orelse error.MissingField;
}

pub fn asStr(value: Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}

pub fn asI64(value: Value) !i64 {
    return switch (value) {
        .integer => |n| n,
        .number_string => |s| try std.fmt.parseInt(i64, s, 10),
        else => error.ExpectedInteger,
    };
}

pub fn asU64(value: Value) !u64 {
    return switch (value) {
        .integer => |n| if (n < 0) error.ExpectedUnsigned else @intCast(n),
        .number_string => |s| try std.fmt.parseInt(u64, s, 10),
        else => error.ExpectedInteger,
    };
}

pub fn asUsize(value: Value) !usize {
    return @intCast(try asU64(value));
}

pub fn asF64(value: Value) !f64 {
    return switch (value) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        .number_string => |s| try std.fmt.parseFloat(f64, s),
        else => error.ExpectedNumber,
    };
}

pub fn asBool(value: Value) !bool {
    return switch (value) {
        .bool => |b| b,
        else => error.ExpectedBool,
    };
}

pub fn asArray(value: Value) ![]const Value {
    return switch (value) {
        .array => |a| a.items,
        else => error.ExpectedArray,
    };
}

/// `value.name` as an array, or an empty slice when the key is absent.
pub fn arrayOr(value: Value, name: []const u8) ![]const Value {
    const v = field(value, name) orelse return &.{};
    return asArray(v);
}

/// `value.name` as a bool, or `fallback` when the key is absent.
pub fn boolOr(value: Value, name: []const u8, fallback: bool) !bool {
    const v = field(value, name) orelse return fallback;
    return asBool(v);
}

/// `value.name` as a string, or null when the key is absent.
pub fn optStr(value: Value, name: []const u8) !?[]const u8 {
    const v = field(value, name) orelse return null;
    return switch (v) {
        .null => null,
        else => try asStr(v),
    };
}

/// Structural (order-independent for objects) equality. Used to compare a
/// re-encoded wire frame against the canonical fixture bytes without pinning
/// this binding's object-key emission order.
pub fn eql(a: Value, b: Value) bool {
    return switch (a) {
        .null => b == .null,
        .bool => |x| b == .bool and b.bool == x,
        .integer => |x| switch (b) {
            .integer => |y| x == y,
            .float => |y| @as(f64, @floatFromInt(x)) == y,
            else => false,
        },
        .float => |x| switch (b) {
            .float => |y| x == y,
            .integer => |y| x == @as(f64, @floatFromInt(y)),
            else => false,
        },
        .number_string => |x| b == .number_string and std.mem.eql(u8, x, b.number_string),
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (b != .array) break :blk false;
            if (x.items.len != b.array.items.len) break :blk false;
            for (x.items, b.array.items) |i, j| {
                if (!eql(i, j)) break :blk false;
            }
            break :blk true;
        },
        .object => |x| blk: {
            if (b != .object) break :blk false;
            if (x.count() != b.object.count()) break :blk false;
            var it = x.iterator();
            while (it.next()) |entry| {
                const other = b.object.get(entry.key_ptr.*) orelse break :blk false;
                if (!eql(entry.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

/// Assert `actual` matches `expected` structurally, printing both encodings on
/// mismatch — a wire diff is unreadable as a pair of `Value` dumps.
pub fn expectJsonEql(expected: Value, actual: Value) !void {
    if (eql(expected, actual)) return;
    const allocator = std.testing.allocator;
    const want = try json.Stringify.valueAlloc(allocator, expected, .{});
    defer allocator.free(want);
    const got = try json.Stringify.valueAlloc(allocator, actual, .{});
    defer allocator.free(got);
    std.debug.print("wire mismatch\n  want: {s}\n  got:  {s}\n", .{ want, got });
    return error.WireMismatch;
}

/// Re-encode `value` (a typed message) and parse the result back into a
/// `Value`, so it can be compared against a fixture's canonical `wire` block.
/// Caller owns the returned `Parsed`.
pub fn encodeToValue(value: anytype) !Fixture {
    const allocator = std.testing.allocator;
    const encoded = try json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(encoded);
    return json.parseFromSlice(Value, allocator, encoded, .{ .allocate = .alloc_always });
}

test "conformance_json: structural equality ignores object key order" {
    const allocator = std.testing.allocator;
    var a = try json.parseFromSlice(Value, allocator, "{\"x\":1,\"y\":[2,3]}", .{});
    defer a.deinit();
    var b = try json.parseFromSlice(Value, allocator, "{\"y\":[2,3],\"x\":1}", .{});
    defer b.deinit();
    var c = try json.parseFromSlice(Value, allocator, "{\"y\":[2,4],\"x\":1}", .{});
    defer c.deinit();
    try std.testing.expect(eql(a.value, b.value));
    try std.testing.expect(!eql(a.value, c.value));
}

test "conformance_json: an absent corpus loads as null rather than failing" {
    const missing = try load("definitely-not-a-corpus-directory/nope.json");
    try std.testing.expect(missing == null);
}

// ---------------------------------------------------------------------------
// Per-scenario replay accounting (#lzscenariocoverage)
// ---------------------------------------------------------------------------

/// Resolve a scenario's identifier in the order every binding uses:
///
///   1. `id` if present
///   2. else `name` if present
///
/// There is no third step (`#lzspecscenarioids`). The positional `#<n>` fallback
/// let the ledger record a scenario BY POSITION, where inserting one ahead of it
/// silently rebinds that entry — and any excuse naming it — to a different
/// scenario, with nothing turning red: the guard compares "index 1 was replayed"
/// against whatever now sits at index 1 and agrees with itself.
///
/// It was load-bearing for exactly one fixture,
/// `collections/mergecell_algebra.json`, whose scenarios were told apart only by
/// `policy`. They carry ids now, and lazily-spec's `scenario-identity-check`
/// keeps every scenario identified — so this is a hole with no users, which is
/// one waiting to become load-bearing again.
///
/// A blank identifier is refused for the same reason: it would file every
/// blank-id scenario under one ledger entry, which reads as "replayed" the moment
/// any one of them runs. `index` is carried only so the error can name the
/// offending position.
pub fn scenarioId(scenario: Value, index: usize) error{ScenarioUnidentified}![]const u8 {
    if (field(scenario, "id")) |v| {
        if (v == .string and std.mem.trim(u8, v.string, " \t\r\n").len > 0) return v.string;
    }
    if (field(scenario, "name")) |v| {
        if (v == .string and std.mem.trim(u8, v.string, " \t\r\n").len > 0) return v.string;
    }
    std.debug.print(
        "scenario at index {d} carries neither `id` nor `name`. The replay ledger would " ++
            "have to record it by POSITION, where inserting a scenario ahead of it silently " ++
            "rebinds that entry to a different scenario. Give it a stable id upstream in " ++
            "lazily-spec (#lzspecscenarioids).\n",
        .{index},
    );
    return error.ScenarioUnidentified;
}

/// The shared scenario-iteration helper, and the one place a scenario is
/// entered into the runtime ledger.
///
/// `next()` deliberately does NOT record. The runner calls `replaying()` at the
/// top of the loop body — AFTER any `continue` — so a scenario the runner skips
/// does not record itself, which is exactly the case this accounting exists to
/// catch. Forgetting the call is not silent either: the fixture's bytes were
/// still opened, so the guard sees a scenario on disk with no ledger entry and
/// fails naming both. The helper is fail-closed in both directions.
pub const Scenarios = struct {
    /// Corpus-relative fixture id, e.g. `stdlib/timer.json`.
    fixture: []const u8,
    items: []const Value,
    index: usize = 0,

    pub fn len(self: Scenarios) usize {
        return self.items.len;
    }

    /// Yield the next scenario, unbooked.
    ///
    /// Yielding is NOT replaying (`#lzscenariobodyskip`). The returned handle
    /// hands the payload over only through `replay()`, which is what books, so a
    /// body that `continue`s, `break`s, matches no dispatch arm, or returns
    /// before taking the payload books nothing. This used to be a `replaying()`
    /// statement the runner had to remember at the top of the body, which books
    /// a scenario whose body then does nothing.
    pub fn next(self: *Scenarios) ?Scenario {
        if (self.index >= self.items.len) return null;
        self.index += 1;
        return .{ .ledger = self, .index = self.index - 1 };
    }

    /// 0-based index of the scenario `next()` last yielded.
    pub fn at(self: Scenarios) usize {
        return self.index - 1;
    }

    /// The resolved id of the scenario `next()` last yielded, WITHOUT recording
    /// it. For a skip decision that needs to name the scenario it is skipping.
    pub fn currentId(self: *Scenarios) error{ScenarioUnidentified}![]const u8 {
        return scenarioId(self.items[self.index - 1], self.index - 1);
    }
};

/// One scenario, handed over unbooked (`#lzscenariobodyskip`).
///
/// `id()` and `peek()` are LABEL reads and stay silent: a dispatch chain that
/// names the scenario, matches no arm and falls through has replayed nothing.
/// `replay()` is the PAYLOAD handoff, which only a runner about to replay
/// performs, so that is where the ledger books.
pub const Scenario = struct {
    ledger: *Scenarios,
    index: usize,

    /// The resolved id. Silent.
    pub fn id(self: Scenario) error{ScenarioUnidentified}![]const u8 {
        return scenarioId(self.ledger.items[self.index], self.index);
    }

    /// The scenario object WITHOUT booking. For a runner that must inspect a
    /// scenario it is not replaying.
    pub fn peek(self: Scenario) Value {
        return self.ledger.items[self.index];
    }

    /// Book this scenario as REPLAYED and hand over its payload.
    pub fn replay(self: Scenario) error{ScenarioUnidentified}!Value {
        recordScenario(self.ledger.fixture, try self.id());
        return self.ledger.items[self.index];
    }
};

/// Iterate `fx.scenarios`, recording each replay into the runtime ledger.
pub fn scenarios(fixture: []const u8, fx: Value) !Scenarios {
    return .{ .fixture = fixture, .items = try asArray(try required(fx, "scenarios")) };
}

/// Find the scenario whose resolved id is `id`, record it as replayed, and hand
/// it back.
///
/// For the replays that are one hand-written test per scenario rather than a
/// loop. Errors when the fixture carries no such scenario, so an upstream
/// rename breaks the runner instead of quietly dropping it out of the ledger —
/// a bare `recordScenario("...", "some_name")` would keep claiming an id the
/// corpus no longer has.
pub fn replayingScenario(fixture: []const u8, fx: Value, id: []const u8) !Value {
    return replayingScenarioImpl(fixture, fx, id, false);
}

/// `quiet` suppresses the diagnostic. Only for this module's own self-test,
/// which asserts the failure and must not pollute the suite's stderr — the
/// build runner surfaces any stderr from a test binary as a failed command.
fn replayingScenarioImpl(fixture: []const u8, fx: Value, id: []const u8, quiet: bool) !Value {
    var it = try scenarios(fixture, fx);
    while (it.next()) |sc| {
        // Selecting is not replaying (`#lzscenariobodyskip`): `id()` is a label
        // read, and the walk past every scenario ahead of the match must not
        // book those. `replay()` books only the one handed back.
        if (!std.mem.eql(u8, try sc.id(), id)) continue;
        return try sc.replay();
    }
    if (!quiet) std.debug.print(
        "{s}: no scenario resolves to id '{s}' — the corpus renamed or dropped it, " ++
            "and this runner is replaying something that is no longer there " ++
            "(#lzscenariocoverage)\n",
        .{ fixture, id },
    );
    return error.UnknownScenarioId;
}

/// Consumption tracking for a conformance fixture's assertion block
/// (`assertions` / `expected` / `expect`) — `#lzassertunknownkeys`.
///
/// The failure this exists to prevent sits one level below "was the fixture
/// replayed". A runner that reads named keys out of an assertion object and
/// lets anything it does not recognise fall through reports the fixture as
/// replayed while never checking the field the fixture exists for: the wire
/// round-trips, the suite goes green, and the assertion proves nothing.
///
/// The manifest recorder proves the bytes were opened. It cannot prove the keys
/// inside them were consumed. This does.
///
/// Every accessor marks its key consumed whether or not the key is present, so
/// an *optional* assertion is still a declaration that the runner knows about
/// the key. `finish()` then fails, naming the fixture and the offending key,
/// when the block carried one the runner never asked for.
///
/// Reading is not asserting — `#lzconsumednotasserted`. A runner can read a key
/// (marking it consumed) and then drop it on the floor: a named `continue` in a
/// consuming loop, a value bound and never compared, or an arm that gates on the
/// fixture value but asserts against a hardcoded literal. All three satisfy the
/// consumed set while proving nothing, so the fixture could change and the
/// runner would stay green.
///
/// So `asserted` tracks the narrower fact: the key's own fixture value reached a
/// comparison. Only `assertKey` / `assertKeyWith` can put a key there, which is
/// why an arm comparing against a literal never marks it. `excuseKey` is the
/// declared fallback for a key with nothing to compare here, and it is checked
/// in both directions — excusing a key the same run also asserts is a failure,
/// because that excuse has gone stale and is hiding nothing.
///
/// OBJECT-VALUED KEYS — `#lzsubblockkeyset`. A key whose fixture value is a JSON
/// OBJECT carries two obligations, not one: the value of each sub-field, and the
/// sub-field KEY SET. Reading five named sub-fields out of `arena_blob.json`'s
/// `descriptor` and stopping satisfied every rung above — consumed, asserted,
/// bound — while a sixth field planted in the object was compared by nothing.
/// That is the null form one level down, INSIDE an assertion key rather than
/// beside one.
///
/// So the tracker owns it, not the call site. A per-call-site field count is not
/// conformance: it relies on the next author remembering, which is the property
/// this rung removes. Three discharges, and `finish()` fails an object-valued key
/// that reached none of them:
///
///   1. `sub(name)` — DESCEND. Hands back a CHILD tracker bound to the object,
///      which owns the same unconsumed-key teardown, so an unread sub-field fails
///      exactly as an unread top-level key does. Prefer this: the obligation
///      moves down rather than being restated.
///   2. `assertKeySet(name, produced)` — compare the object's KEY SET against the
///      set the run really produced, in BOTH directions. For a key whose
///      sub-fields are a VOCABULARY rather than data —
///      `codec/nodeid_exact_range.json`'s `outcomes` maps outcome tokens to
///      English glosses, and the assertion is which tokens exist.
///   3. `assertKeyStructural(name, actual)` — whole-value structural equality,
///      which already covers the key set at every depth. `assertKey` with a
///      `Value` actual takes this path too, since `eql` compares object sizes.
///
/// `excuseKey` stays available for an object-valued key that genuinely carries no
/// obligation here, and it still requires a reason.
///
/// No allocation: the sets are bounded inline arrays, so a replay can build one
/// per step without touching an allocator.
pub const AssertionKeys = struct {
    pub const MAX_KEYS = 64;

    /// RESERVED ANNOTATION NAMES (`#lzprosekeyconvention`). Exempt BY NAME from
    /// all three checks: unconsumed, read-but-not-asserted, stale excuse.
    ///
    /// The exemption is only safe while these names ANNOTATE. A reserved name is
    /// a place no runner can be made to discharge anything, so an annotation that
    /// states an obligation is invisible by construction — lazily-spec's
    /// `scripts/check-prose-keys.mjs` is the half that keeps new instances out.
    /// A name the corpus DECLARES prose in `assertions.prose` loses the exemption
    /// here: see `finish()`.
    pub const NARRATIVE = [_][]const u8{ "note", "notes", "comment", "description", "why" };

    const Excuse = struct { name: []const u8, reason: []const u8 };

    /// A child tracker handed out by `sub`, and whether it was finished
    /// (`#lzsubblockkeyset`). Tracked here rather than left to the caller: a
    /// descend the call site forgets to `finish()` would move the obligation down
    /// and then drop it, which is the hole this rung closes, not a new one.
    const Sub = struct { name: []const u8, done: bool };

    where: []const u8,
    object: Value,
    /// The fixture-scoped prose ledger this block reports into, when the fixture
    /// declares `assertions.prose` (`#lzprosekeyconvention`). Null for the blocks
    /// of a fixture that declares none — which is every fixture the convention
    /// has not reached, so attaching one is opt-in per fixture and forgetting it
    /// fails as an unconsumed `prose` key rather than passing quietly.
    ledger: ?*ProseLedger = null,
    /// This block carries its own `prose` array. Inside such a block the
    /// reserved-annotation exemption is OFF ENTIRELY: the corpus wins, so a
    /// `note` sitting in a declaring block but absent from its array needs an
    /// assertion or an excuse like any other key.
    declares_prose: bool = false,
    consumed: [MAX_KEYS][]const u8 = undefined,
    len: usize = 0,
    asserted: [MAX_KEYS][]const u8 = undefined,
    asserted_len: usize = 0,
    excused: [MAX_KEYS]Excuse = undefined,
    excused_len: usize = 0,
    /// Object-valued keys whose KEY SET reached a check (`#lzsubblockkeyset`).
    object_checked: [MAX_KEYS][]const u8 = undefined,
    object_checked_len: usize = 0,
    /// Child trackers handed out by `sub`.
    subs: [MAX_KEYS]Sub = undefined,
    subs_len: usize = 0,
    /// Set on a CHILD tracker only: the parent block and the slot to close on
    /// `finish()`, so a descend that is never finished fails the parent.
    parent: ?*AssertionKeys = null,
    parent_slot: usize = 0,
    /// Set on a CHILD tracker only: the parent key whose value this block is, so
    /// a diagnostic names `descriptor` rather than pointing at the whole fixture.
    key_prefix: []const u8 = "",
    /// Suppress the diagnostic print. Only for this module's own self-test,
    /// which asserts the failure and must not pollute the suite's stderr.
    quiet: bool = false,

    pub fn init(where: []const u8, object: Value) AssertionKeys {
        // Rung 0 (`#lznullformblind`): book this block as BOUND, keyed by its
        // CONTENT rather than by `where`. Every other rung is scoped to a block a
        // runner already bound, so a block nothing binds reports nothing at all —
        // its keys are not unread, nothing reads them. Content keying is what
        // stops the ledger inheriting the inconsistent spellings runners give
        // `where`.
        @import("conformance_manifest.zig").recordBlockBind(object);
        var self = AssertionKeys{ .where = where, .object = object };
        for (NARRATIVE) |name| self.mark(name);
        return self;
    }

    /// Every diagnostic goes through here so a CHILD tracker's failures name the
    /// object-valued key they came from — `self.where` alone would point a
    /// sub-field's failure at the whole block.
    fn report(self: *const AssertionKeys, comptime fmt: []const u8, args: anytype) void {
        if (self.quiet) return;
        std.debug.print("{s}: ", .{self.where});
        if (self.key_prefix.len > 0) {
            std.debug.print("inside object-valued key '{s}': ", .{self.key_prefix});
        }
        std.debug.print(fmt, args);
    }

    fn mark(self: *AssertionKeys, name: []const u8) void {
        for (self.consumed[0..self.len]) |seen| {
            if (std.mem.eql(u8, seen, name)) return;
        }
        if (self.len == MAX_KEYS) @panic("AssertionKeys.MAX_KEYS exceeded");
        self.consumed[self.len] = name;
        self.len += 1;
    }

    fn markAsserted(self: *AssertionKeys, name: []const u8) void {
        self.mark(name);
        // The fixture-scoped half. `epoch_disambiguation` is discharged by
        // `expect.frame_epoch` / `expect.blob_epoch`, asserted in a per-scenario
        // block long after the `assertions` block is finished, so rule 6 can only
        // be checked against a set that outlives this block.
        if (self.ledger) |l| l.recordAsserted(name);
        for (self.asserted[0..self.asserted_len]) |seen| {
            if (std.mem.eql(u8, seen, name)) return;
        }
        if (self.asserted_len == MAX_KEYS) @panic("AssertionKeys.MAX_KEYS exceeded");
        self.asserted[self.asserted_len] = name;
        self.asserted_len += 1;
    }

    /// Attach this block to the fixture's prose ledger and fold in whatever the
    /// block has already recorded, so the call site is free to sit anywhere after
    /// `init`.
    ///
    /// Reading `prose` here marks it consumed; it is `verifyProse`'s
    /// discharged-set comparison that ASSERTS it (rule 4), which is why
    /// `finish()` stops short of the read-but-not-asserted check for it.
    pub fn trackProse(self: *AssertionKeys, fixture: *ProseLedger) !void {
        self.ledger = fixture;
        for (self.asserted[0..self.asserted_len]) |name| fixture.recordAsserted(name);
        for (self.excused[0..self.excused_len]) |e| fixture.recordExcused(e.name);
        // Every key this block CARRIES, so a discharge naming one the corpus
        // does not carry at all reads as a rotted claim rather than as an
        // unasserted one.
        switch (self.object) {
            .object => |o| for (o.keys()) |name| fixture.recordPresent(name),
            else => {},
        }
        // The declaration is read off the RAW block, BEFORE any name-based
        // exemption. A tracker that subtracts its reserved-name set first makes
        // a declared `note` invisible — exempt from the unread guard, exempt
        // from the unasserted guard, never discharged — and both
        // `frame_roundtrip_*.json` fixtures would skip the convention entirely
        // while this binding still reported conforming.
        const declaration = switch (self.object) {
            .object => |o| o.get("prose"),
            else => null,
        };
        if (declaration) |v| {
            self.mark("prose");
            self.declares_prose = true;
            try fixture.declare(self.where, v);
        }
    }

    /// Discharge a PROSE key by naming the executable assertion keys that carry
    /// its obligation (`#lzprosekeyconvention`).
    ///
    /// A prose key is discharged, never asserted and never excused. Asserting it
    /// compares a paragraph — or a tally derived from one — to an English string,
    /// which pins wording rather than behaviour: a copy-edit reddens the run and a
    /// library regression does not. Excusing it with free text ("prose: it states
    /// why the fixture is shaped this way") is unfalsifiable, and that is what
    /// this replaces: the named keys are a claim about the run, and
    /// `verifyProse` checks it.
    pub fn proseKey(
        self: *AssertionKeys,
        name: []const u8,
        discharged_by: []const []const u8,
    ) !void {
        const ledger = self.ledger orelse {
            if (!self.quiet) std.debug.print(
                "{s}: proseKey('{s}') without a ledger — call trackProse(&fixture) on this " ++
                    "block first, and verifyProse(&fixture) when the replay finishes " ++
                    "(#lzprosekeyconvention)\n",
                .{ self.where, name },
            );
            return error.ProseKeyWithoutLedger;
        };
        if (discharged_by.len == 0) {
            if (!self.quiet) std.debug.print(
                "{s}: prose key '{s}' is discharged by NOTHING. A discharge that names no " ++
                    "key is the free-text excuse again, with the reason removed " ++
                    "(#lzprosekeyconvention)\n",
                .{ self.where, name },
            );
            return error.ProseDischargeNamesNothing;
        }
        // Discharging a key the block does not carry is a stale claim: the corpus
        // dropped or renamed the paragraph and this runner still speaks for it.
        _ = try self.required(name);
        ledger.discharge(self.where, name, discharged_by);
    }

    fn isNarrative(name: []const u8) bool {
        for (NARRATIVE) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    fn wasAsserted(self: *const AssertionKeys, name: []const u8) bool {
        for (self.asserted[0..self.asserted_len]) |a| {
            if (std.mem.eql(u8, a, name)) return true;
        }
        return false;
    }

    fn excuseFor(self: *const AssertionKeys, name: []const u8) ?[]const u8 {
        for (self.excused[0..self.excused_len]) |e| {
            if (std.mem.eql(u8, e.name, name)) return e.reason;
        }
        return null;
    }

    // -----------------------------------------------------------------------
    // Object-valued assertion keys (#lzsubblockkeyset)
    // -----------------------------------------------------------------------

    fn markObjectChecked(self: *AssertionKeys, name: []const u8) void {
        for (self.object_checked[0..self.object_checked_len]) |seen| {
            if (std.mem.eql(u8, seen, name)) return;
        }
        if (self.object_checked_len == MAX_KEYS) @panic("AssertionKeys.MAX_KEYS exceeded");
        self.object_checked[self.object_checked_len] = name;
        self.object_checked_len += 1;
    }

    fn wasObjectChecked(self: *const AssertionKeys, name: []const u8) bool {
        for (self.object_checked[0..self.object_checked_len]) |c| {
            if (std.mem.eql(u8, c, name)) return true;
        }
        return false;
    }

    /// DISCHARGE 1 — DESCEND. Consume the object-valued key `name` and hand back a
    /// CHILD tracker bound to its value.
    ///
    /// The child owns the same three teardown checks the parent does, so a
    /// sub-field nothing reads fails exactly as an unconsumed top-level key does,
    /// and a sub-field read without a comparison fails as one read and not
    /// asserted. The obligation MOVES DOWN rather than being restated as a field
    /// count — which is the whole difference between this and the stopgap it
    /// replaces.
    ///
    /// The child deliberately does NOT book itself in the rung-0 bind ledger
    /// (`#lznullformblind`). That ledger is two-directional against the blocks
    /// `specReadFile` inventoried at read time, and a sub-object is not one of
    /// them; zig's block digest is content-keyed, so a spurious child bind would
    /// surface as a bind with no matching inventory entry.
    ///
    /// Usage:
    ///
    ///     var descriptor = try keys.sub("descriptor");
    ///     try descriptor.assertKey("offset", observed.offset);
    ///     …
    ///     try descriptor.finish();
    ///
    /// Forgetting the child's `finish()` is not silent: the parent records the
    /// descend and fails when a child was handed out and never closed.
    pub fn sub(self: *AssertionKeys, name: []const u8) !AssertionKeys {
        const value = try self.required(name);
        if (value != .object) {
            self.report(
                "assertion key '{s}' is not an object, so there is nothing to descend into. " ++
                    "sub() is for object-valued keys; assert a scalar with assertKey " ++
                    "(#lzsubblockkeyset)\n",
                .{name},
            );
            return error.SubBlockNotAnObject;
        }
        self.markAsserted(name);
        self.markObjectChecked(name);
        if (self.subs_len == MAX_KEYS) @panic("AssertionKeys.MAX_KEYS exceeded");
        const slot = self.subs_len;
        self.subs[slot] = .{ .name = name, .done = false };
        self.subs_len += 1;
        var child = AssertionKeys{
            .where = self.where,
            .object = value,
            .parent = self,
            .parent_slot = slot,
            .key_prefix = name,
            .quiet = self.quiet,
        };
        for (NARRATIVE) |n| child.mark(n);
        return child;
    }

    /// Descend into an object-valued assertion key, run `check` against the
    /// child tracker, and close the child. Unlike `assertKeyWith`, the callback
    /// can only consume sub-fields through the tracker, so a corpus field the
    /// callback does not recognise is reported by `finish()`.
    pub fn assertObjectWith(
        self: *AssertionKeys,
        name: []const u8,
        actual: anytype,
        comptime check: fn (@TypeOf(actual), *AssertionKeys) anyerror!void,
    ) !void {
        var child = try self.sub(name);
        check(actual, &child) catch |err| {
            child.finish() catch {};
            return err;
        };
        try child.finish();
    }

    /// Optional form of `assertObjectWith`; returns whether the key existed.
    pub fn assertObjectWithOpt(
        self: *AssertionKeys,
        name: []const u8,
        actual: anytype,
        comptime check: fn (@TypeOf(actual), *AssertionKeys) anyerror!void,
    ) !bool {
        if (!self.has(name)) return false;
        try self.assertObjectWith(name, actual, check);
        return true;
    }

    /// DISCHARGE 2 — KEY SET. Consume the object-valued key `name` and compare its
    /// KEY SET against `produced`, the set the run actually produced.
    ///
    /// Both directions: a fixture key nothing produced and a produced key the
    /// fixture omits are each failures. For a key whose sub-fields are a
    /// VOCABULARY rather than data — `codec/nodeid_exact_range.json`'s `outcomes`
    /// maps outcome tokens to English glosses, and the assertion is which tokens
    /// exist, not what the glosses say. Descending would demand a comparison for
    /// each gloss, which pins wording; this pins the vocabulary.
    pub fn assertKeySet(
        self: *AssertionKeys,
        name: []const u8,
        produced: []const []const u8,
    ) !void {
        const expected = try self.required(name);
        const obj = switch (expected) {
            .object => |o| o,
            else => {
                self.report(
                    "assertion key '{s}' is not an object, so it has no key set to compare " ++
                        "(#lzsubblockkeyset)\n",
                    .{name},
                );
                return error.KeySetOnNonObject;
            },
        };
        self.markAsserted(name);
        self.markObjectChecked(name);

        for (obj.keys()) |declared| {
            var found = false;
            for (produced) |p| {
                if (std.mem.eql(u8, p, declared)) {
                    found = true;
                    break;
                }
            }
            if (found) continue;
            self.report(
                "object-valued assertion key '{s}' declares '{s}' and this run produced no " ++
                    "such member. The corpus grew a field nothing here answers for " ++
                    "(#lzsubblockkeyset)\n",
                .{ name, declared },
            );
            return error.ObjectKeySetMismatch;
        }
        for (produced) |p| {
            if (obj.get(p) != null) continue;
            self.report(
                "object-valued assertion key '{s}': this run produced '{s}' and the fixture " ++
                    "does not declare it. A key set is checked in BOTH directions or it is " ++
                    "not checked (#lzsubblockkeyset)\n",
                .{ name, p },
            );
            return error.ObjectKeySetMismatch;
        }
    }

    /// DISCHARGE 3 — WHOLE-VALUE structural equality. `eql` compares object member
    /// counts at every depth, so this already covers the key set; it is a distinct
    /// entry point so the guard can SEE that it happened, rather than the fact
    /// living in a comment beside a generic `assertKeyWith`.
    pub fn assertKeyStructural(self: *AssertionKeys, name: []const u8, actual: Value) !void {
        const expected = try self.required(name);
        self.markAsserted(name);
        self.markObjectChecked(name);
        try expectJsonEql(expected, actual);
    }

    /// Consume `name`; null when the fixture does not carry it.
    pub fn field(self: *AssertionKeys, name: []const u8) ?Value {
        self.mark(name);
        return switch (self.object) {
            .object => |o| o.get(name),
            else => null,
        };
    }

    /// Consume `name`; fails when the fixture does not carry it.
    pub fn required(self: *AssertionKeys, name: []const u8) !Value {
        return self.field(name) orelse error.MissingField;
    }

    /// Consume `name` and report whether the fixture carries it.
    pub fn has(self: *AssertionKeys, name: []const u8) bool {
        return self.field(name) != null;
    }

    /// Read `name`, mark it ASSERTED, and compare the fixture's own value
    /// against `actual`. This is the only path (with `assertKeyWith`) that can
    /// satisfy the read-but-not-asserted check, which is the point: an arm that
    /// compares against a hardcoded literal never reaches here, so editing the
    /// fixture would change nothing and `finish()` says so.
    ///
    /// `actual` is compared by its own Zig type — bool, any integer, any float,
    /// string, enum (by tag name), `Value` (structurally), or an optional of
    /// any of those against a fixture `null`.
    pub fn assertKey(self: *AssertionKeys, name: []const u8, actual: anytype) !void {
        const expected = try self.required(name);
        self.markAsserted(name);
        // A `Value` actual is compared structurally, and `eql` compares object
        // member COUNTS at every depth — so this path really does check the key
        // set and discharges `#lzsubblockkeyset` (see `assertKeyStructural`).
        if (@TypeOf(actual) == Value) self.markObjectChecked(name);
        try self.compare(name, expected, actual);
    }

    /// As `assertKey`, but only when the fixture carries `name`. The key is
    /// consumed either way — an optional assertion is still a declaration that
    /// the runner knows about the key — and marked asserted only when the
    /// fixture's value actually reached the comparison. Reports whether it did.
    pub fn assertKeyOpt(self: *AssertionKeys, name: []const u8, actual: anytype) !bool {
        const expected = self.field(name) orelse return false;
        self.markAsserted(name);
        if (@TypeOf(actual) == Value) self.markObjectChecked(name);
        try self.compare(name, expected, actual);
        return true;
    }

    /// Read `name`, mark it ASSERTED, and hand the fixture's value to the
    /// caller's own check. For comparisons that are not an equality — a
    /// tolerance, a set containment, a per-entry sweep of an object. What
    /// matters is that the fixture's value reaches the comparison, not that the
    /// comparison is `==`.
    pub fn assertKeyWith(
        self: *AssertionKeys,
        name: []const u8,
        context: anytype,
        comptime check: fn (@TypeOf(context), Value) anyerror!void,
    ) !void {
        const expected = try self.required(name);
        self.markAsserted(name);
        try check(context, expected);
    }

    /// As `assertKeyWith`, but a no-op when the fixture omits `name`. Reports
    /// whether the check ran.
    pub fn assertKeyWithOpt(
        self: *AssertionKeys,
        name: []const u8,
        context: anytype,
        comptime check: fn (@TypeOf(context), Value) anyerror!void,
    ) !bool {
        const expected = self.field(name) orelse return false;
        self.markAsserted(name);
        try check(context, expected);
        return true;
    }

    /// Declare that `name` cannot be asserted at this call site, and say why.
    /// The fallback when there is genuinely nothing to compare — the fact is
    /// proven elsewhere, or the field is a discriminator selecting a code path
    /// rather than a value to check. Prefer converting the skip into a real
    /// assertion; an excuse is a promise the reason text has to keep.
    ///
    /// Checked in BOTH directions: `finish()` fails when the same run also
    /// asserts an excused key, because that excuse is stale and hides nothing.
    pub fn excuseKey(self: *AssertionKeys, name: []const u8, reason: []const u8) !void {
        if (reason.len == 0) return error.EmptyExcuseReason;
        self.mark(name);
        // Fixture-scoped, so rule 2 sees an excuse written in ANY block of the
        // fixture for a key the `assertions` block declares prose.
        if (self.ledger) |l| l.recordExcused(name);
        for (self.excused[0..self.excused_len]) |e| {
            if (std.mem.eql(u8, e.name, name)) return;
        }
        if (self.excused_len == MAX_KEYS) @panic("AssertionKeys.MAX_KEYS exceeded");
        self.excused[self.excused_len] = .{ .name = name, .reason = reason };
        self.excused_len += 1;
    }

    fn mismatch(
        self: *const AssertionKeys,
        name: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) error{AssertionValueMismatch} {
        if (!self.quiet) {
            self.report("assertion key '{s}' ", .{name});
            std.debug.print(fmt ++ " (#lzconsumednotasserted)\n", args);
        }
        return error.AssertionValueMismatch;
    }

    fn compare(self: *AssertionKeys, name: []const u8, expected: Value, actual: anytype) !void {
        const T = @TypeOf(actual);
        if (T == Value) return expectJsonEql(expected, actual);
        switch (@typeInfo(T)) {
            .optional => {
                if (actual) |inner| {
                    if (expected == .null) {
                        return self.mismatch(name, "want null, got a value", .{});
                    }
                    return self.compare(name, expected, inner);
                }
                if (expected != .null) {
                    return self.mismatch(name, "want a value, got null", .{});
                }
            },
            .null => {
                if (expected != .null) {
                    return self.mismatch(name, "want a value, got null", .{});
                }
            },
            .bool => {
                const want = try asBool(expected);
                if (want != actual) {
                    return self.mismatch(name, "want {}, got {}", .{ want, actual });
                }
            },
            .comptime_int => return self.compare(name, expected, @as(i64, actual)),
            .comptime_float => return self.compare(name, expected, @as(f64, actual)),
            .int => |int| {
                if (int.signedness == .unsigned) {
                    const want = try asU64(expected);
                    const got: u64 = @intCast(actual);
                    if (want != got) {
                        return self.mismatch(name, "want {d}, got {d}", .{ want, got });
                    }
                } else {
                    const want = try asI64(expected);
                    const got: i64 = @intCast(actual);
                    if (want != got) {
                        return self.mismatch(name, "want {d}, got {d}", .{ want, got });
                    }
                }
            },
            .float => {
                const want = try asF64(expected);
                const got: f64 = @floatCast(actual);
                if (want != got) {
                    return self.mismatch(name, "want {d}, got {d}", .{ want, got });
                }
            },
            .@"enum", .enum_literal => {
                const want = try asStr(expected);
                const got = @tagName(actual);
                if (!std.mem.eql(u8, want, got)) {
                    return self.mismatch(name, "want '{s}', got '{s}'", .{ want, got });
                }
            },
            else => {
                if (comptime isStringLike(T)) {
                    const want = try asStr(expected);
                    const got: []const u8 = actual;
                    if (!std.mem.eql(u8, want, got)) {
                        return self.mismatch(name, "want '{s}', got '{s}'", .{ want, got });
                    }
                } else {
                    @compileError("AssertionKeys.assertKey: unsupported actual type " ++ @typeName(T));
                }
            },
        }
    }

    pub fn arrayOr(self: *AssertionKeys, name: []const u8) ![]const Value {
        const v = self.field(name) orelse return &.{};
        return asArray(v);
    }

    pub fn boolOr(self: *AssertionKeys, name: []const u8, fallback: bool) !bool {
        const v = self.field(name) orelse return fallback;
        return asBool(v);
    }

    pub fn optStr(self: *AssertionKeys, name: []const u8) !?[]const u8 {
        const v = self.field(name) orelse return null;
        return switch (v) {
            .null => null,
            else => try asStr(v),
        };
    }

    /// Five failure modes, all naming the fixture and the key because "some
    /// assertion went unread" is not actionable:
    ///
    /// 1. a key the runner never asked for (`#lzassertunknownkeys`);
    /// 2. a key the runner READ but never asserted or excused
    ///    (`#lzconsumednotasserted`);
    /// 3. an excuse for a key the same run also asserted — stale, hiding
    ///    nothing (`#lzconsumednotasserted`);
    /// 4. an object-valued key consumed WITHOUT a key-set check
    ///    (`#lzsubblockkeyset`);
    /// 5. a `sub()` descend handed out and never finished (`#lzsubblockkeyset`) —
    ///    otherwise the obligation moves down and is then dropped.
    ///
    /// Keys the corpus declares PROSE are none of this block's business and are
    /// skipped here; `verifyProse` owns them (`#lzprosekeyconvention`).
    pub fn finish(self: *const AssertionKeys) !void {
        // Close this block's slot in its parent FIRST, so a child that goes on to
        // fail below still counts as finished and the parent reports the real
        // failure rather than "a descend was never closed".
        if (self.parent) |p| p.subs[self.parent_slot].done = true;

        for (self.excused[0..self.excused_len]) |e| {
            if (!self.wasAsserted(e.name)) continue;
            self.report(
                "assertion key '{s}' is excused (\"{s}\") but this same run asserts " ++
                    "it. The excuse is stale and now hides nothing — drop the excuseKey " ++
                    "call (#lzconsumednotasserted)\n",
                .{ e.name, e.reason },
            );
            return error.StaleAssertionExcuse;
        }

        for (self.subs[0..self.subs_len]) |s| {
            if (s.done) continue;
            self.report(
                "object-valued assertion key '{s}' was descended into with sub() and the " ++
                    "child tracker was never finished. The descend MOVES the unconsumed-key " ++
                    "obligation down; dropping the child drops it entirely — call " ++
                    "child.finish() (#lzsubblockkeyset)\n",
                .{s.name},
            );
            return error.SubBlockNotFinished;
        }

        const obj = switch (self.object) {
            .object => |o| o,
            else => return,
        };
        var it = obj.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            // A key the CORPUS declared prose belongs to the fixture-scoped
            // ledger, not to this block: it is discharged, and the discharge is
            // verified when the replay finishes — which is also where a missing
            // one fails. The declaration itself (`prose`) is consumed by that
            // same comparison. Both checks below would be wrong here: rule 1
            // forbids asserting a paragraph, and rule 2 forbids excusing one.
            //
            // The order matters. This runs BEFORE the narrative exemption, so a
            // declared `note` — `codec/frame_roundtrip_*.json` declares exactly
            // that — stops being exempt by name and has to be discharged.
            if (self.ledger) |l| {
                if (std.mem.eql(u8, name, "prose") or l.isDeclaredBy(self.where, name)) continue;
            }
            if (!self.declares_prose and isNarrative(name)) continue;

            var seen = false;
            for (self.consumed[0..self.len]) |c| {
                if (std.mem.eql(u8, c, name)) {
                    seen = true;
                    break;
                }
            }
            if (!seen) {
                self.report(
                    "assertion key '{s}' is present in the fixture but was never " ++
                        "consumed by this runner. Replaying a fixture without evaluating " ++
                        "its assertion reports green while proving nothing — implement the " ++
                        "assertion rather than ignoring the key (#lzassertunknownkeys)\n",
                    .{name},
                );
                return error.UnconsumedAssertionKey;
            }

            // An excuse is the declared "nothing to compare here" channel and it
            // carries a reason, so it answers for the key set as well as for the
            // value. Checked BEFORE the object guard for that reason.
            if (self.excuseFor(name) != null) continue;

            // Rung `#lzsubblockkeyset`: an OBJECT value carries a key-set
            // obligation on top of its field values. Reaching a plain assertKeyWith
            // that picks five sub-fields by name satisfies every other rung here
            // while a sixth field added upstream is compared by nothing.
            if (entry.value_ptr.* == .object and !self.wasObjectChecked(name)) {
                self.report(
                    "assertion key '{s}' has an OBJECT value and was consumed without a " ++
                        "key-set check. Its sub-fields are checked one by one and its KEY " ++
                        "SET by nothing, so a field the corpus adds later is compared by " ++
                        "nothing and this runner stays green. Descend with sub(\"{s}\") and " ++
                        "finish the child, compare the vocabulary with assertKeySet(\"{s}\", " ++
                        "…), or compare the whole value with assertKeyStructural(\"{s}\", …) " ++
                        "(#lzsubblockkeyset)\n",
                    .{ name, name, name, name },
                );
                return error.ObjectKeyWithoutKeySetCheck;
            }

            if (self.wasAsserted(name)) continue;

            self.report(
                "assertion key '{s}' was READ but its value never reached a " ++
                    "comparison. Reading a key marks it consumed and proves nothing — the " ++
                    "fixture could change and this runner would stay green. Assert it with " ++
                    "assertKey/assertKeyWith, or declare excuseKey(\"{s}\", <reason>) " ++
                    "(#lzconsumednotasserted)\n",
                .{ name, name },
            );
            return error.AssertionKeyReadButNotAsserted;
        }
    }
};

// ---------------------------------------------------------------------------
// Prose assertion keys (#lzprosekeyconvention)
// ---------------------------------------------------------------------------

/// The FIXTURE-SCOPED discharge ledger for prose assertion keys.
///
/// An `assertions` block mixes two kinds of key. Most carry a value a runner can
/// compare against observed behaviour. A few carry an English paragraph that
/// states an obligation and nothing comparable — `clause`, `anti_vacuity`,
/// `null_form`, `theorem`, `note`. Replaying
/// `codec/blob_backend_discriminator.json` v2 produced FOUR different treatments
/// of the same four keys across the nine bindings, and this binding's was the
/// individually-worded excuse: `excuseKey("null_form", "prose: the two null
/// scenarios assert the behaviour it describes")`. That names the discharging
/// assertion, which was the right instinct — and nothing checked it. The reason
/// text could name a key this run never asserted, a key that does not exist, or
/// nothing at all, and `finish()` would still be satisfied.
///
/// So the naming becomes machine-checked. `proseKey` records a CLAIM about the
/// run ("`epoch_disambiguation` is discharged by `frame_epoch` and `blob_epoch`")
/// and `verifyProse` checks it against what the fixture's replay actually
/// asserted.
///
/// WHY FIXTURE-SCOPED. The obligation stated in `assertions` is routinely carried
/// by a per-scenario `expect` key: `frame_epoch` and `blob_epoch` are asserted
/// fourteen scenarios after the `assertions` block is finished. A block-scoped
/// ledger could only ever check a discharge naming a sibling of the paragraph,
/// which is the minority case. A named key is therefore matched BY NAME in any
/// block of the fixture, and verification happens once the replay is done.
///
/// OWNERSHIP. Every name the ledger stores is duplicated into its own allocation.
/// Declared names are slices into the fixture's parse arena, and a ledger torn
/// down after `fixture.deinit()` would read freed memory to report what went
/// wrong — the failure path is exactly where that must not happen.
pub const ProseLedger = struct {
    pub const MAX_DECLARED = 32;
    pub const MAX_ASSERTED = 192;
    pub const MAX_EXCUSED = 64;
    pub const MAX_PRESENT = 192;
    pub const MAX_CLAIMS = 32;
    pub const MAX_DISCHARGED_BY = 8;

    /// A declaration, and the BLOCK that made it. Rules 3 and 4 compare a
    /// block's discharged set against that block's own `prose` array; only the
    /// name matching of rules 6 and 7 is fixture-wide, because that is the half
    /// that has to reach a per-scenario `expect` key.
    const Declared = struct { name: []const u8, block: []const u8 };

    const Claim = struct {
        key: []const u8,
        block: []const u8,
        by: [MAX_DISCHARGED_BY][]const u8 = undefined,
        by_len: usize = 0,
    };

    allocator: std.mem.Allocator,
    /// Corpus-relative fixture id, for the diagnostics and for the runtime
    /// verification ledger. Borrowed, not owned: every call site passes a literal.
    fixture: []const u8,
    declared: [MAX_DECLARED]Declared = undefined,
    declared_len: usize = 0,
    asserted: [MAX_ASSERTED][]const u8 = undefined,
    asserted_len: usize = 0,
    excused: [MAX_EXCUSED][]const u8 = undefined,
    excused_len: usize = 0,
    /// Every key name PRESENT in a tracked block of this fixture. Lets rule 6
    /// tell "carried but never compared" from "the corpus does not carry this at
    /// all" — a rotted discharge, exactly as a stale excuse is.
    present: [MAX_PRESENT][]const u8 = undefined,
    present_len: usize = 0,
    claims: [MAX_CLAIMS]Claim = undefined,
    claims_len: usize = 0,
    verified: bool = false,
    /// Cleared by `disarm()` when an error is already on its way out, so the
    /// teardown check does not mask the real failure with its own.
    armed: bool = true,
    /// Suppress the diagnostics. Only for this module's own self-tests, which
    /// assert the failures and must not pollute the suite's stderr.
    quiet: bool = false,

    pub fn init(fixture: []const u8) ProseLedger {
        return .{ .allocator = std.testing.allocator, .fixture = fixture };
    }

    /// Free the owned names, then FAIL when the replay never verified.
    ///
    /// An unverified discharge claim is as bad as an unconsumed key: the run
    /// wrote down what discharges each paragraph and nothing read it back. A
    /// `defer` cannot return an error, so this aborts — which is the same
    /// "the suite is red" outcome, arrived at loudly.
    ///
    /// The arming pair is:
    ///
    ///     var fixture = cj.ProseLedger.init(FIXTURE);
    ///     defer fixture.deinit();
    ///     errdefer fixture.disarm();
    ///
    /// `errdefer` is declared second, so it runs FIRST on the error path and the
    /// original failure propagates untouched.
    pub fn deinit(self: *ProseLedger) void {
        const unverified = self.armed and !self.verified;
        for (self.declared[0..self.declared_len]) |d| {
            self.allocator.free(d.name);
            self.allocator.free(d.block);
        }
        for (self.asserted[0..self.asserted_len]) |s| self.allocator.free(s);
        for (self.excused[0..self.excused_len]) |s| self.allocator.free(s);
        for (self.present[0..self.present_len]) |s| self.allocator.free(s);
        for (self.claims[0..self.claims_len]) |c| {
            self.allocator.free(c.key);
            self.allocator.free(c.block);
            for (c.by[0..c.by_len]) |s| self.allocator.free(s);
        }
        self.declared_len = 0;
        self.asserted_len = 0;
        self.excused_len = 0;
        self.present_len = 0;
        self.claims_len = 0;
        if (!unverified) return;
        if (!self.quiet) std.debug.print(
            "{s}: the replay finished without calling verifyProse. The discharge claims this " ++
                "run wrote down were never checked against what it asserted, so an obligation " ++
                "could name a key nothing in the fixture proves (#lzprosekeyconvention)\n",
            .{self.fixture},
        );
        @panic("ProseLedger: replay ended without verifyProse (#lzprosekeyconvention)");
    }

    /// Stand the teardown check down. For the error path, where a failure is
    /// already propagating and a second one would only hide it.
    pub fn disarm(self: *ProseLedger) void {
        self.armed = false;
    }

    fn own(self: *ProseLedger, name: []const u8) []const u8 {
        return self.allocator.dupe(u8, name) catch @panic("ProseLedger: out of memory");
    }

    fn contains(haystack: []const []const u8, name: []const u8) bool {
        for (haystack) |item| {
            if (std.mem.eql(u8, item, name)) return true;
        }
        return false;
    }

    /// Fixture-wide. Used by rules 6/7's name matching and by the block-level
    /// exemption, both of which are about "is this name a paragraph anywhere in
    /// this fixture".
    pub fn isDeclared(self: *const ProseLedger, name: []const u8) bool {
        for (self.declared[0..self.declared_len]) |d| {
            if (std.mem.eql(u8, d.name, name)) return true;
        }
        return false;
    }

    /// The prose-name set, SEEDED WITH `prose` ITSELF. Without the seed, rule 7
    /// misses `proseKey(k, &.{"prose"})`: the declaration never lists itself, so
    /// it is not "declared", and a tracker that marked `prose` asserted when it
    /// consumed the declaration would let rule 6 wave the discharge through. A
    /// paragraph discharged by the declaration that it is a paragraph proves
    /// nothing.
    fn isProseName(self: *const ProseLedger, name: []const u8) bool {
        return std.mem.eql(u8, name, "prose") or self.isDeclared(name);
    }

    /// Block-local — rules 3 and 4.
    fn isDeclaredBy(self: *const ProseLedger, block: []const u8, name: []const u8) bool {
        for (self.declared[0..self.declared_len]) |d| {
            if (std.mem.eql(u8, d.block, block) and std.mem.eql(u8, d.name, name)) return true;
        }
        return false;
    }

    fn wasAsserted(self: *const ProseLedger, name: []const u8) bool {
        return contains(self.asserted[0..self.asserted_len], name);
    }

    fn wasExcused(self: *const ProseLedger, name: []const u8) bool {
        return contains(self.excused[0..self.excused_len], name);
    }

    fn isPresent(self: *const ProseLedger, name: []const u8) bool {
        return contains(self.present[0..self.present_len], name);
    }

    fn claimBy(self: *const ProseLedger, block: []const u8, name: []const u8) ?Claim {
        for (self.claims[0..self.claims_len]) |c| {
            if (std.mem.eql(u8, c.block, block) and std.mem.eql(u8, c.key, name)) return c;
        }
        return null;
    }

    /// Record the corpus's own `assertions.prose` declaration, and which block
    /// made it. The BINDING never decides which keys are prose — nine trackers
    /// deciding independently is what produced four answers to one question.
    pub fn declare(self: *ProseLedger, where: []const u8, value: Value) !void {
        const names = asArray(value) catch {
            if (!self.quiet) std.debug.print(
                "{s}: `assertions.prose` must be an array of sibling key names " ++
                    "(#lzprosekeyconvention)\n",
                .{where},
            );
            return error.ProseDeclarationNotAnArray;
        };
        for (names) |item| {
            const name = try asStr(item);
            if (std.mem.eql(u8, name, "prose")) {
                if (!self.quiet) std.debug.print(
                    "{s}: `assertions.prose` lists ITSELF. The declaration is not one of the " ++
                        "paragraphs it declares (#lzprosekeyconvention)\n",
                    .{where},
                );
                return error.ProseDeclarationSelfListed;
            }
            if (self.isDeclaredBy(where, name)) continue;
            if (self.declared_len == MAX_DECLARED) @panic("ProseLedger.MAX_DECLARED exceeded");
            self.declared[self.declared_len] = .{ .name = self.own(name), .block = self.own(where) };
            self.declared_len += 1;
        }
    }

    fn recordPresent(self: *ProseLedger, name: []const u8) void {
        if (self.isPresent(name)) return;
        if (self.present_len == MAX_PRESENT) @panic("ProseLedger.MAX_PRESENT exceeded");
        self.present[self.present_len] = self.own(name);
        self.present_len += 1;
    }

    fn recordAsserted(self: *ProseLedger, name: []const u8) void {
        if (self.wasAsserted(name)) return;
        if (self.asserted_len == MAX_ASSERTED) @panic("ProseLedger.MAX_ASSERTED exceeded");
        self.asserted[self.asserted_len] = self.own(name);
        self.asserted_len += 1;
    }

    fn recordExcused(self: *ProseLedger, name: []const u8) void {
        if (self.wasExcused(name)) return;
        if (self.excused_len == MAX_EXCUSED) @panic("ProseLedger.MAX_EXCUSED exceeded");
        self.excused[self.excused_len] = self.own(name);
        self.excused_len += 1;
    }

    fn discharge(
        self: *ProseLedger,
        block: []const u8,
        name: []const u8,
        by: []const []const u8,
    ) void {
        if (by.len > MAX_DISCHARGED_BY) @panic("ProseLedger.MAX_DISCHARGED_BY exceeded");
        if (self.claimBy(block, name) != null) return;
        if (self.claims_len == MAX_CLAIMS) @panic("ProseLedger.MAX_CLAIMS exceeded");
        var claim = Claim{ .key = self.own(name), .block = self.own(block) };
        for (by) |n| {
            claim.by[claim.by_len] = self.own(n);
            claim.by_len += 1;
        }
        self.claims[self.claims_len] = claim;
        self.claims_len += 1;
    }

    fn fail(
        self: *const ProseLedger,
        comptime fmt: []const u8,
        args: anytype,
        err: anyerror,
    ) anyerror {
        if (self.quiet) return err;
        std.debug.print("{s}: ", .{self.fixture});
        std.debug.print(fmt ++ " (#lzprosekeyconvention)\n", args);
        return err;
    }

    /// The seven rules. See `verifyProse`.
    fn verify(self: *ProseLedger) !void {
        // Set FIRST: a rule below firing is a verified failure, not a missing
        // verification, and the teardown must not turn one into the other.
        self.verified = true;

        for (self.claims[0..self.claims_len]) |claim| {
            // Rule 3, BLOCK-LOCAL: each block owns its own `prose` array, so a
            // declaration in one block cannot license a discharge in another.
            if (!self.isDeclaredBy(claim.block, claim.key)) return self.fail(
                "'{s}' is discharged but `{s}` does not list it in `assertions.prose`. " ++
                    "Only the corpus decides which keys are paragraphs; an executable key " ++
                    "must be ASSERTED",
                .{ claim.key, claim.block },
                error.ProseKeyNotDeclared,
            );
            // Rule 5, again — `proseKey` refuses an empty list, and a ledger
            // built by hand must not be able to route around it.
            if (claim.by_len == 0) return self.fail(
                "prose key '{s}' is discharged by nothing",
                .{claim.key},
                error.ProseDischargeNamesNothing,
            );
            for (claim.by[0..claim.by_len]) |named| {
                // Rule 7, over the SEEDED prose-name set — `prose` included.
                if (self.isProseName(named)) return self.fail(
                    "prose key '{s}' is discharged by '{s}', which is ITSELF a paragraph (or " ++
                        "the declaration that they are). Two prose keys cannot discharge each " ++
                        "other — the obligation has to land on something the run compares",
                    .{ claim.key, named },
                    error.ProseDischargeNamesProse,
                );
                // A discharge naming a key the fixture does not carry AT ALL has
                // rotted, exactly as a stale excuse does — a distinct failure
                // from one naming a key that is carried and never compared.
                if (!self.isPresent(named)) return self.fail(
                    "prose key '{s}' is discharged by '{s}', which no block of this fixture " ++
                        "carries. The corpus renamed or dropped it and the discharge still " ++
                        "speaks for it",
                    .{ claim.key, named },
                    error.ProseDischargeNamesAbsentKey,
                );
                // Rule 6 — the whole convention. The excuse is falsifiable
                // because this is a claim about the run. ASSERTED, not merely
                // satisfied: an excused key discharges nothing, because an excuse
                // is precisely the absence of a comparison.
                if (!self.wasAsserted(named)) return self.fail(
                    "prose key '{s}' is discharged by '{s}', which this fixture's run never " ++
                        "ASSERTED. Either the key is read without reaching a comparison, or " ++
                        "the paragraph is discharged by something else — name that instead",
                    .{ claim.key, named },
                    error.ProseDischargeNamesUnassertedKey,
                );
            }
        }

        for (self.declared[0..self.declared_len]) |declaration| {
            const name = declaration.name;
            // Rule 1.
            if (self.wasAsserted(name)) return self.fail(
                "'{s}' is a paragraph and this run ASSERTS it. Comparing English — or a tally " ++
                    "derived from it — to a fixture string pins wording, not behaviour: a " ++
                    "copy-edit reddens the run and a library regression does not. Discharge " ++
                    "it with proseKey instead",
                .{name},
                error.ProseKeyAsserted,
            );
            // Rule 2.
            if (self.wasExcused(name)) return self.fail(
                "'{s}' is a paragraph and this run EXCUSES it with free text. An unfalsifiable " ++
                    "reason is indistinguishable from the undocumented default this clause " ++
                    "removes — name the assertion keys that discharge it with proseKey",
                .{name},
                error.ProseKeyExcused,
            );
            // Rule 4, BLOCK-LOCAL. This comparison is what CONSUMES and asserts
            // `prose` itself, and it is what makes a forgotten paragraph fail
            // rather than vanish.
            if (self.claimBy(declaration.block, name) == null) return self.fail(
                "'{s}' is listed in `{s}`'s `assertions.prose` and nothing discharged it. " ++
                    "The declaration is the corpus telling this runner the paragraph exists; " ++
                    "a key it never answers for is one the run silently dropped",
                .{ name, declaration.block },
                error.ProseKeyNotDischarged,
            );
        }

        // RULE 8, the vacuity floor. Rules 1-7 are all satisfied over an empty
        // population, so a fixture opened and then never replayed passes every
        // one of them while proving nothing. The required verifications are
        // derived from the CORPUS by `scripts/check-conformance-coverage.sh`,
        // which reads this ledger line back: any fixture whose block declares
        // `prose` and whose bytes the suite opened must appear here.
        // `quiet` is this module's own self-tests, whose fixture ids are not in
        // the corpus. Recording them would make the guard's own evidence channel
        // carry claims about files nothing ever opened.
        if (!self.quiet) @import("conformance_manifest.zig").recordProseVerified(self.fixture);
    }
};

/// Verify a fixture's prose discharges once its replay is finished
/// (`#lzprosekeyconvention`). Fails when:
///
///   1. a key listed in `assertions.prose` is ASSERTED;
///   2. a key listed in `assertions.prose` is EXCUSED with free text;
///   3. a key NOT listed in `assertions.prose` is discharged;
///   4. the discharged set differs from `assertions.prose` — the comparison that
///      consumes `prose` itself;
///   5. a discharge names no keys;
///   6. a discharge names a key this fixture's run did not assert;
///   7. a discharge names a key that is itself prose.
///
/// A run that never gets here fails from `ProseLedger.deinit`.
pub fn verifyProse(fixture: *ProseLedger) !void {
    return fixture.verify();
}

/// `[]const u8`, `[]u8`, and string literals (`*const [N:0]u8`).
fn isStringLike(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| a.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

/// Assert `expected.invalidates[reader]` against an observed version bump.
///
/// The per-reader invalidation flag is nested one level down, so `reader` picks
/// the sub-key rather than being a value to compare — but the flag itself is a
/// real fact about the library and goes through the tracker as an ASSERTION,
/// not a bare read (`#lzconsumednotasserted`).
pub fn assertInvalidates(
    keys: *AssertionKeys,
    comptime reader: []const u8,
    changed: bool,
) !void {
    try keys.assertObjectWith("invalidates", changed, struct {
        fn check(observed: bool, inv: *AssertionKeys) !void {
            try inv.assertKey(reader, observed);
        }
    }.check);
}

/// Build a consumption-tracking view over `value.name` (the fixture's assertion
/// block), or null when the fixture carries no such block.
pub fn assertionKeys(where: []const u8, value: Value, name: []const u8) ?AssertionKeys {
    const block = field(value, name) orelse return null;
    return AssertionKeys.init(where, block);
}

test "conformance_json: scenario ids resolve id -> name, and refuse an unidentified scenario" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(
        Value,
        allocator,
        \\{"scenarios":[
        \\  {"id":"by_id","name":"ignored"},
        \\  {"name":"by_name"},
        \\  {"policy":"Sum"}
        \\]}
    ,
        .{},
    );
    defer parsed.deinit();

    var it = try scenarios("fake/fixture.json", parsed.value);
    try std.testing.expectEqual(@as(usize, 3), it.len());

    var seen: [2][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |sc| {
        if (n < 2) {
            seen[n] = try sc.id();
            n += 1;
            continue;
        }
        // The third scenario carries neither `id` nor `name`. There is no
        // positional fallback (#lzspecscenarioids): a ledger entry recorded BY
        // POSITION silently rebinds to a different scenario on a corpus reorder,
        // so resolution refuses rather than inventing an id.
        try std.testing.expectError(error.ScenarioUnidentified, sc.id());
    }
    try std.testing.expectEqualStrings("by_id", seen[0]);
    try std.testing.expectEqualStrings("by_name", seen[1]);

    // A blank identifier is not an identifier: accepting it would file every
    // blank-id scenario under one ledger entry.
    var blank = try json.parseFromSlice(
        Value,
        allocator,
        "{\"scenarios\":[{\"id\":\"  \",\"name\":\"\"}]}",
        .{},
    );
    defer blank.deinit();
    var blank_it = try scenarios("fake/blank.json", blank.value);
    const first = blank_it.next().?;
    try std.testing.expectError(error.ScenarioUnidentified, first.id());
}

test "conformance_json: replayingScenario refuses an id the fixture does not carry" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(
        Value,
        allocator,
        "{\"scenarios\":[{\"name\":\"present\"}]}",
        .{},
    );
    defer parsed.deinit();
    // No ledger write reaches disk here: the recorder is a no-op unless
    // LAZILY_CONFORMANCE_MANIFEST is set, and `fake/fixture.json` is not in the
    // corpus, so the guard would flag it if it ever were.
    try std.testing.expectError(
        error.UnknownScenarioId,
        replayingScenarioImpl("fake/fixture.json", parsed.value, "absent", true),
    );
}

test "conformance_json: an unconsumed assertion key fails, an asserted one does not" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(Value, allocator, "{\"a\":1,\"note\":\"x\",\"b\":2}", .{});
    defer parsed.deinit();

    var all = AssertionKeys.init("fixture", parsed.value);
    try all.assertKey("a", @as(i64, 1));
    try all.assertKey("b", @as(i64, 2));
    try all.finish();

    var partial = AssertionKeys.init("fixture", parsed.value);
    partial.quiet = true;
    try partial.assertKey("a", @as(i64, 1));
    try std.testing.expectError(error.UnconsumedAssertionKey, partial.finish());
}

test "conformance_json: reading a key without asserting it fails" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(Value, allocator, "{\"a\":1,\"b\":2}", .{});
    defer parsed.deinit();

    // Both keys READ — the `#lzassertunknownkeys` consumed set is satisfied —
    // but only one of them reached a comparison.
    var keys = AssertionKeys.init("fixture", parsed.value);
    keys.quiet = true;
    try keys.assertKey("a", @as(i64, 1));
    _ = keys.field("b");
    try std.testing.expectError(error.AssertionKeyReadButNotAsserted, keys.finish());

    // An excuse satisfies it; the reason must be non-empty.
    var excused = AssertionKeys.init("fixture", parsed.value);
    try excused.assertKey("a", @as(i64, 1));
    try excused.excuseKey("b", "asserted by the sibling replay in this module");
    try excused.finish();

    var empty = AssertionKeys.init("fixture", parsed.value);
    try std.testing.expectError(error.EmptyExcuseReason, empty.excuseKey("b", ""));
}

test "conformance_json: an excuse for a key the same run asserts is stale" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(Value, allocator, "{\"a\":1}", .{});
    defer parsed.deinit();

    var keys = AssertionKeys.init("fixture", parsed.value);
    keys.quiet = true;
    try keys.excuseKey("a", "proven elsewhere");
    try keys.assertKey("a", @as(i64, 1));
    try std.testing.expectError(error.StaleAssertionExcuse, keys.finish());
}

// ---------------------------------------------------------------------------
// Prose assertion keys — the seven rules (#lzprosekeyconvention)
// ---------------------------------------------------------------------------

/// `{"prose":["clause"],"clause":"…a paragraph…","backends":["shm"]}` plus
/// whatever the caller adds, parsed. The block always carries a non-prose key:
/// a block that is entirely prose has nothing that could discharge it.
fn proseFixtureJson(comptime extra: []const u8) []const u8 {
    return "{\"prose\":[\"clause\"],\"clause\":\"a paragraph\",\"backends\":[\"shm\"]" ++ extra ++ "}";
}

fn checkAnything(_: void, _: Value) anyerror!void {}

test "conformance_json: a discharged prose key satisfies both the block and the ledger" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(Value, allocator, proseFixtureJson(""), .{});
    defer parsed.deinit();

    var fixture = ProseLedger.init("fake/prose.json");
    defer fixture.deinit();
    errdefer fixture.disarm();
    fixture.quiet = true;

    var keys = AssertionKeys.init("fake/prose.json assertions", parsed.value);
    keys.quiet = true;
    try keys.trackProse(&fixture);
    try keys.assertKeyWith("backends", {}, checkAnything);
    try keys.proseKey("clause", &.{"backends"});
    // `prose` and `clause` are both consumed without being asserted or excused
    // here: the ledger owns them.
    try keys.finish();
    try verifyProse(&fixture);
}

test "conformance_json: rule 1 — asserting a declared prose key fails" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(Value, allocator, proseFixtureJson(""), .{});
    defer parsed.deinit();

    var fixture = ProseLedger.init("fake/prose.json");
    defer fixture.deinit();
    errdefer fixture.disarm();
    fixture.quiet = true;

    var keys = AssertionKeys.init("fake/prose.json assertions", parsed.value);
    keys.quiet = true;
    try keys.trackProse(&fixture);
    try keys.assertKeyWith("backends", {}, checkAnything);
    try keys.proseKey("clause", &.{"backends"});
    // A tally compared to the paragraph's own text pins wording, not behaviour.
    try keys.assertKey("clause", "a paragraph");
    try std.testing.expectError(error.ProseKeyAsserted, verifyProse(&fixture));
}

test "conformance_json: rule 2 — excusing a declared prose key with free text fails" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(Value, allocator, proseFixtureJson(""), .{});
    defer parsed.deinit();

    var fixture = ProseLedger.init("fake/prose.json");
    defer fixture.deinit();
    errdefer fixture.disarm();
    fixture.quiet = true;

    var keys = AssertionKeys.init("fake/prose.json assertions", parsed.value);
    keys.quiet = true;
    try keys.trackProse(&fixture);
    try keys.assertKeyWith("backends", {}, checkAnything);
    try keys.proseKey("clause", &.{"backends"});
    try keys.excuseKey("clause", "prose: the scenarios below assert what it describes");
    try std.testing.expectError(error.ProseKeyExcused, verifyProse(&fixture));
}

test "conformance_json: rule 3 — discharging a key the corpus did not declare fails" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(Value, allocator, proseFixtureJson(""), .{});
    defer parsed.deinit();

    var fixture = ProseLedger.init("fake/prose.json");
    defer fixture.deinit();
    errdefer fixture.disarm();
    fixture.quiet = true;

    var keys = AssertionKeys.init("fake/prose.json assertions", parsed.value);
    keys.quiet = true;
    try keys.trackProse(&fixture);
    try keys.assertKeyWith("backends", {}, checkAnything);
    try keys.proseKey("clause", &.{"backends"});
    // `backends` carries a comparable value; a binding does not get to reclassify
    // it as a paragraph.
    try keys.proseKey("backends", &.{"clause"});
    try std.testing.expectError(error.ProseKeyNotDeclared, verifyProse(&fixture));
}

test "conformance_json: rule 4 — a declared prose key nothing discharges fails" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(
        Value,
        allocator,
        "{\"prose\":[\"clause\",\"theorem\"],\"clause\":\"a\",\"theorem\":\"b\",\"backends\":[\"shm\"]}",
        .{},
    );
    defer parsed.deinit();

    var fixture = ProseLedger.init("fake/prose.json");
    defer fixture.deinit();
    errdefer fixture.disarm();
    fixture.quiet = true;

    var keys = AssertionKeys.init("fake/prose.json assertions", parsed.value);
    keys.quiet = true;
    try keys.trackProse(&fixture);
    try keys.assertKeyWith("backends", {}, checkAnything);
    try keys.proseKey("clause", &.{"backends"});
    // `theorem` is declared and forgotten. The block's own `finish()` cannot see
    // it — the ledger skipped it there — so this comparison is what makes a
    // forgotten paragraph fail rather than vanish.
    try keys.finish();
    try std.testing.expectError(error.ProseKeyNotDischarged, verifyProse(&fixture));
}

test "conformance_json: rule 5 — a discharge naming nothing fails at the call site" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(Value, allocator, proseFixtureJson(""), .{});
    defer parsed.deinit();

    var fixture = ProseLedger.init("fake/prose.json");
    defer fixture.deinit();
    errdefer fixture.disarm();
    fixture.quiet = true;

    var keys = AssertionKeys.init("fake/prose.json assertions", parsed.value);
    keys.quiet = true;
    try keys.trackProse(&fixture);
    const empty: []const []const u8 = &.{};
    try std.testing.expectError(error.ProseDischargeNamesNothing, keys.proseKey("clause", empty));
    // The ledger still has to be answered for, or this test's own teardown fails.
    try keys.assertKeyWith("backends", {}, checkAnything);
    try keys.proseKey("clause", &.{"backends"});
    try verifyProse(&fixture);
}

test "conformance_json: rule 6 — a discharge naming a never-asserted key fails" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(Value, allocator, proseFixtureJson(""), .{});
    defer parsed.deinit();

    var fixture = ProseLedger.init("fake/prose.json");
    defer fixture.deinit();
    errdefer fixture.disarm();
    fixture.quiet = true;

    var keys = AssertionKeys.init("fake/prose.json assertions", parsed.value);
    keys.quiet = true;
    try keys.trackProse(&fixture);
    // `backends` is READ, never compared — the `#lzconsumednotasserted` hole,
    // which is exactly the state a discharge must not be able to name.
    _ = keys.field("backends");
    try keys.proseKey("clause", &.{"backends"});
    try std.testing.expectError(error.ProseDischargeNamesUnassertedKey, verifyProse(&fixture));
}

test "conformance_json: rule 6 — a discharge is satisfied from ANOTHER block of the fixture" {
    const allocator = std.testing.allocator;
    var block = try json.parseFromSlice(Value, allocator, proseFixtureJson(""), .{});
    defer block.deinit();
    // The per-scenario `expect`, asserted long after the `assertions` block is
    // finished. Block-scoped verification could not see this.
    var expect = try json.parseFromSlice(Value, allocator, "{\"frame_epoch\":9}", .{});
    defer expect.deinit();

    var fixture = ProseLedger.init("fake/prose.json");
    defer fixture.deinit();
    errdefer fixture.disarm();
    fixture.quiet = true;

    var meta = AssertionKeys.init("fake/prose.json assertions", block.value);
    meta.quiet = true;
    try meta.trackProse(&fixture);
    try meta.assertKeyWith("backends", {}, checkAnything);
    try meta.proseKey("clause", &.{"frame_epoch"});
    try meta.finish();

    var keys = AssertionKeys.init("fake/prose.json", expect.value);
    keys.quiet = true;
    try keys.trackProse(&fixture);
    try keys.assertKey("frame_epoch", @as(i64, 9));
    try keys.finish();

    try verifyProse(&fixture);
}

test "conformance_json: rule 7 — a discharge naming another prose key fails" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(
        Value,
        allocator,
        "{\"prose\":[\"clause\",\"theorem\"],\"clause\":\"a\",\"theorem\":\"b\",\"backends\":[\"shm\"]}",
        .{},
    );
    defer parsed.deinit();

    var fixture = ProseLedger.init("fake/prose.json");
    defer fixture.deinit();
    errdefer fixture.disarm();
    fixture.quiet = true;

    var keys = AssertionKeys.init("fake/prose.json assertions", parsed.value);
    keys.quiet = true;
    try keys.trackProse(&fixture);
    try keys.assertKeyWith("backends", {}, checkAnything);
    try keys.proseKey("theorem", &.{"backends"});
    try keys.proseKey("clause", &.{"theorem"});
    try std.testing.expectError(error.ProseDischargeNamesProse, verifyProse(&fixture));
}

test "conformance_json: an untracked block still fails on the unconsumed `prose` key" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(Value, allocator, proseFixtureJson(""), .{});
    defer parsed.deinit();

    // No ledger. This is the rollout's self-enforcing half: the declaration is a
    // key of the block, so the existing consumption guard sees it.
    var keys = AssertionKeys.init("fake/prose.json assertions", parsed.value);
    keys.quiet = true;
    try keys.assertKeyWith("backends", {}, checkAnything);
    try keys.excuseKey("clause", "prose");
    try std.testing.expectError(error.UnconsumedAssertionKey, keys.finish());

    // And `proseKey` without a ledger refuses rather than recording into thin air.
    var untracked = AssertionKeys.init("fake/prose.json assertions", parsed.value);
    untracked.quiet = true;
    try std.testing.expectError(
        error.ProseKeyWithoutLedger,
        untracked.proseKey("clause", &.{"backends"}),
    );
}

test "conformance_json: a declared `note` loses the reserved-annotation exemption" {
    const allocator = std.testing.allocator;
    // `codec/frame_roundtrip_json.json` declares exactly this: `note` is a
    // reserved annotation name everywhere else and a paragraph here.
    var parsed = try json.parseFromSlice(
        Value,
        allocator,
        "{\"prose\":[\"note\"],\"note\":\"a paragraph\",\"role\":\"reference\"}",
        .{},
    );
    defer parsed.deinit();

    var forgotten = ProseLedger.init("fake/note.json");
    defer forgotten.deinit();
    errdefer forgotten.disarm();
    forgotten.quiet = true;

    var keys = AssertionKeys.init("fake/note.json assertions", parsed.value);
    keys.quiet = true;
    try keys.trackProse(&forgotten);
    try keys.assertKey("role", "reference");
    try keys.finish();
    // Exempt by name would have let this pass silently.
    try std.testing.expectError(error.ProseKeyNotDischarged, verifyProse(&forgotten));

    var fixture = ProseLedger.init("fake/note.json");
    defer fixture.deinit();
    errdefer fixture.disarm();
    fixture.quiet = true;

    var ok = AssertionKeys.init("fake/note.json assertions", parsed.value);
    ok.quiet = true;
    try ok.trackProse(&fixture);
    try ok.assertKey("role", "reference");
    try ok.proseKey("note", &.{"role"});
    try ok.finish();
    try verifyProse(&fixture);
}

test "conformance_json: rule 7 — a discharge naming `prose` itself fails" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(Value, allocator, proseFixtureJson(""), .{});
    defer parsed.deinit();

    var fixture = ProseLedger.init("fake/prose.json");
    defer fixture.deinit();
    errdefer fixture.disarm();
    fixture.quiet = true;

    var keys = AssertionKeys.init("fake/prose.json assertions", parsed.value);
    keys.quiet = true;
    try keys.trackProse(&fixture);
    try keys.assertKeyWith("backends", {}, checkAnything);
    // `prose` never lists itself, so it is not "declared" — without seeding the
    // prose-name set with it, rule 7 misses this and rule 6 waves it through on
    // the strength of the declaration having been consumed. A paragraph
    // discharged by the declaration that it IS a paragraph proves nothing.
    try keys.proseKey("clause", &.{"prose"});
    try std.testing.expectError(error.ProseDischargeNamesProse, verifyProse(&fixture));
}

test "conformance_json: a discharge naming a key the fixture does not carry has rotted" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(Value, allocator, proseFixtureJson(""), .{});
    defer parsed.deinit();

    var fixture = ProseLedger.init("fake/prose.json");
    defer fixture.deinit();
    errdefer fixture.disarm();
    fixture.quiet = true;

    var keys = AssertionKeys.init("fake/prose.json assertions", parsed.value);
    keys.quiet = true;
    try keys.trackProse(&fixture);
    try keys.assertKeyWith("backends", {}, checkAnything);
    // Distinct from rule 6: this key is not merely unasserted, it is gone.
    try keys.proseKey("clause", &.{"backends_renamed_upstream"});
    try std.testing.expectError(error.ProseDischargeNamesAbsentKey, verifyProse(&fixture));
}

test "conformance_json: rules 3 and 4 are BLOCK-local, rules 6 and 7 are fixture-wide" {
    const allocator = std.testing.allocator;
    var declaring = try json.parseFromSlice(Value, allocator, proseFixtureJson(""), .{});
    defer declaring.deinit();
    // A second block carrying the same key NAME and no declaration of its own.
    var other = try json.parseFromSlice(Value, allocator, "{\"clause\":\"a paragraph\"}", .{});
    defer other.deinit();

    var fixture = ProseLedger.init("fake/prose.json");
    defer fixture.deinit();
    errdefer fixture.disarm();
    fixture.quiet = true;

    var meta = AssertionKeys.init("fake/prose.json assertions", declaring.value);
    meta.quiet = true;
    try meta.trackProse(&fixture);
    try meta.assertKeyWith("backends", {}, checkAnything);

    var expect = AssertionKeys.init("fake/prose.json expect", other.value);
    expect.quiet = true;
    try expect.trackProse(&fixture);
    // Each block owns its own `prose` array. This block declared nothing, so it
    // cannot discharge on the strength of a sibling block's declaration.
    try expect.proseKey("clause", &.{"backends"});
    try std.testing.expectError(error.ProseKeyNotDeclared, verifyProse(&fixture));
}

test "conformance_json: inside a declaring block the annotation exemption is off entirely" {
    const allocator = std.testing.allocator;
    // `note` is NOT in this block's array — but the block declares `prose`, so
    // the corpus wins and the reserved name buys nothing.
    var parsed = try json.parseFromSlice(
        Value,
        allocator,
        "{\"prose\":[\"clause\"],\"clause\":\"a\",\"backends\":[\"shm\"],\"note\":\"x\"}",
        .{},
    );
    defer parsed.deinit();

    var fixture = ProseLedger.init("fake/prose.json");
    defer fixture.deinit();
    errdefer fixture.disarm();
    fixture.quiet = true;

    var keys = AssertionKeys.init("fake/prose.json assertions", parsed.value);
    keys.quiet = true;
    try keys.trackProse(&fixture);
    try keys.assertKeyWith("backends", {}, checkAnything);
    try keys.proseKey("clause", &.{"backends"});
    try std.testing.expectError(error.AssertionKeyReadButNotAsserted, keys.finish());
    try verifyProse(&fixture);

    // Everywhere else the exemption stands as-is: a block with no declaration
    // keeps skipping its annotations.
    var plain = try json.parseFromSlice(Value, allocator, "{\"a\":1,\"note\":\"x\"}", .{});
    defer plain.deinit();
    var annotated = AssertionKeys.init("fake/plain.json expect", plain.value);
    annotated.quiet = true;
    try annotated.assertKey("a", @as(i64, 1));
    try annotated.finish();
}

test "conformance_json: a prose declaration that lists itself is refused" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(
        Value,
        allocator,
        "{\"prose\":[\"prose\"],\"backends\":[\"shm\"]}",
        .{},
    );
    defer parsed.deinit();

    var fixture = ProseLedger.init("fake/prose.json");
    defer fixture.deinit();
    fixture.disarm();
    fixture.quiet = true;

    var keys = AssertionKeys.init("fake/prose.json assertions", parsed.value);
    keys.quiet = true;
    try std.testing.expectError(error.ProseDeclarationSelfListed, keys.trackProse(&fixture));
}

test "conformance_json: assertKey compares against the fixture's own value" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(
        Value,
        allocator,
        "{\"s\":\"x\",\"b\":true,\"i\":-3,\"u\":7,\"f\":1.5,\"n\":null,\"o\":{\"k\":1}}",
        .{},
    );
    defer parsed.deinit();

    var keys = AssertionKeys.init("fixture", parsed.value);
    keys.quiet = true;
    try keys.assertKey("s", "x");
    try keys.assertKey("b", true);
    try keys.assertKey("i", @as(i64, -3));
    try keys.assertKey("u", @as(usize, 7));
    try keys.assertKey("f", @as(f64, 1.5));
    try keys.assertKey("n", @as(?[]const u8, null));
    try keys.assertObjectWith("o", @as(i64, 1), struct {
        fn check(want_k: i64, object: *AssertionKeys) !void {
            try object.assertKey("k", want_k);
        }
    }.check);
    try keys.finish();

    var wrong = AssertionKeys.init("fixture", parsed.value);
    wrong.quiet = true;
    try std.testing.expectError(error.AssertionValueMismatch, wrong.assertKey("s", "y"));
    try std.testing.expectError(error.AssertionValueMismatch, wrong.assertKey("b", false));
    try std.testing.expectError(error.AssertionValueMismatch, wrong.assertKey("u", @as(usize, 8)));
    try std.testing.expectError(
        error.AssertionValueMismatch,
        wrong.assertKey("n", @as(?[]const u8, "x")),
    );
}

test "conformance_json: object callbacks fail on an unrecognised sub-field" {
    const allocator = std.testing.allocator;
    var parsed = try json.parseFromSlice(
        Value,
        allocator,
        "{\"o\":{\"k\":1,\"planted_subfield\":0}}",
        .{},
    );
    defer parsed.deinit();

    var keys = AssertionKeys.init("fixture", parsed.value);
    keys.quiet = true;
    try std.testing.expectError(
        error.UnconsumedAssertionKey,
        keys.assertObjectWith("o", @as(i64, 1), struct {
            fn check(want_k: i64, object: *AssertionKeys) !void {
                try object.assertKey("k", want_k);
            }
        }.check),
    );
    try keys.finish();
}
