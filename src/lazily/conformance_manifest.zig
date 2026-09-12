//! Runtime conformance manifest (#lazilyupgradeconformance).
//!
//! The coverage guard used to grep the test sources for fixture filenames. That
//! catches a fixture nobody mentions, but not one mentioned in a comment and
//! hand-transcribed — the drift found in lazily-cpp's queue tests, and in
//! lazily-rs's own topic tests, where the source named four `topiccell_*.json`
//! fixtures that nothing ever opened. Only observing the read proves the corpus
//! was replayed.
//!
//! Zig has no interception seam for `readFileAlloc`, and this repo has no single
//! shared loader — every conformance file grew its own `readFixtureFile` copy. So
//! the seam is introduced rather than found: this module owns the one read, and
//! each per-file helper is now an alias for `specReadFile`. Every test file can
//! `@import("conformance_manifest.zig")` regardless of which module the build
//! compiles it into, because the import is file-relative.
//!
//! Reads outside the conformance corpus pass straight through unrecorded, so
//! routing every fixture read through this is harmless.
//!
//! The manifest is APPENDED, never truncated: `zig build test` runs a dozen
//! separate test binaries and each must contribute to one union. The Makefile
//! truncates once before the suite. A write failure is swallowed — bookkeeping
//! must never fail a suite; a manifest that never got written surfaces
//! downstream as missing evidence, which is the correct outcome.
//!
//! Zig master gutted much of `std.posix`/`std.fs` and has no stable
//! `std.process.getenv`, so the environment is read from `/proc/self/environ`
//! and the append is done with raw `std.os.linux` syscalls — the same workaround
//! `src/benches/scale_bench.zig` and `src/lazily/transport.zig` already use.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
/// Zig 0.16 removed `std.Thread.Mutex`; this repo already vendors the
/// replacement (see `parking_mutex.zig`).
const ParkingMutex = @import("parking_mutex.zig").ParkingMutex;

/// Everything after this substring becomes the recorded fixture id, so ids match
/// the canonical corpus layout the guard walks (e.g.
/// `collections/queuecell_spsc_push_pop.json`).
const MARKER = "lazily-spec/conformance/";

const ENV_NAME = "LAZILY_CONFORMANCE_MANIFEST";

/// Name of the per-invocation run-id nonce (`#lzstalemanifest`), shared with
/// every sibling binding, with the Makefile, and with
/// `scripts/check-conformance-coverage.sh`.
const RUN_ID_ENV_NAME = "LAZILY_CONFORMANCE_RUN_ID";

/// Prefix of the FIRST line every process writing this manifest emits
/// (`#lzstalemanifest`). Cross-binding fixed shape: `# lazily-run-id <value>`.
///
/// `#` rather than `@`: the three evidence channels already claim `@`, and a
/// corpus-relative fixture id can begin with neither, so the guard still splits
/// the file with plain greps and needs no second file, no second environment
/// variable and no second build.zig wiring.
pub const RUN_ID_LINE_PREFIX = "# lazily-run-id ";

var mutex: ParkingMutex = .{};
var manifest_path_buf: [4096]u8 = undefined;
var manifest_path: ?[:0]const u8 = null;
var manifest_resolved: bool = false;
var run_id_buf: [4096]u8 = undefined;
var run_id: ?[:0]const u8 = null;
var run_id_resolved: bool = false;
/// Per-PROCESS, not per-file: each of the dozen test binaries appends its own
/// stamp to the shared manifest, and the guard demands they all carry the
/// current invocation's id.
var run_id_stamped: bool = false;

/// Read a conformance fixture and record the fact that its bytes were opened.
///
/// The canonical corpus location when nothing overrides it.
pub const DEFAULT_CONFORMANCE_ROOT = "../lazily-spec/conformance";

/// Name of the corpus-directory override, shared with every sibling binding and
/// with `scripts/check-conformance-coverage.sh` (`#lzoverrideallrunners`).
pub const CONFORMANCE_DIR_ENV = "LAZILY_SPEC_CONFORMANCE_DIR";

/// The override, or null when the default applies.
///
/// Resolved ONCE into a file-scope buffer rather than per call: the root is
/// concatenated into a path at every fixture read, and `readEnv` re-opens and
/// re-scans `/proc/self/environ` on each call (there is no stable `getenv` across
/// the three pinned toolchains — see `readEnv`). Caching also means the corpus a
/// run reads cannot change halfway through it.
var root_buf: [4096]u8 = undefined;
var root_slice: ?[]const u8 = null;
var root_resolved: bool = false;

pub fn conformanceRootOverride() ?[]const u8 {
    if (!root_resolved) {
        root_resolved = true;
        if (readEnv(CONFORMANCE_DIR_ENV, &root_buf)) |value| {
            root_slice = value;
        }
    }
    return root_slice;
}

/// The corpus root this process should read.
pub fn conformanceRoot() []const u8 {
    return conformanceRootOverride() orelse DEFAULT_CONFORMANCE_ROOT;
}

/// `<corpus>/<rel>` under the RUNTIME root. Caller frees.
///
/// Exists so no replay builds a corpus path by comptime-concatenating
/// `DEFAULT_CONFORMANCE_ROOT` (`#lzzigingressspecdir`). Eleven runners did, each
/// with its own `const SPEC_DIR = "../lazily-spec/conformance/<area>"`, so
/// `LAZILY_SPEC_CONFORMANCE_DIR` moved some replays and not others — and the
/// difference is invisible, because a run that reads the DEFAULT corpus while
/// believing it was redirected is green either way. That is worse than an
/// unsupported override: a perturbation probe pointed at a scratch corpus gets a
/// partly-redirected suite and reads the unperturbed cell as "this fixture
/// cannot be made to fail", which is the exact false negative the probe exists
/// to rule out.
///
/// A comptime `++` against the default is therefore not a shortcut for this — it
/// is the defect. Route new replays through here or through `conformance_json.load`.
pub fn specPath(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ conformanceRoot(), rel });
}

/// `<corpus>/<area>/<name>` under the RUNTIME root. Caller frees.
pub fn specAreaPath(allocator: std.mem.Allocator, area: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ conformanceRoot(), area, name });
}

/// `<corpus>/<area>` under the RUNTIME root, for diagnostics. Caller frees.
pub fn specAreaDir(allocator: std.mem.Allocator, area: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ conformanceRoot(), area });
}

/// Is an unreadable fixture a SKIP, or a failure?
///
/// This is the whole reason the override is a runtime read rather than an edit
/// to a comptime constant (`#lzzigspecdiroption`). Every replay here guards
/// itself with a presence probe and answers absence with `error.SkipZigTest`,
/// because a contributor without the `lazily-spec` sibling is not making a false
/// claim. But that same skip is a trap for a corpus-perturbation probe: point the
/// tests at a scratch corpus, typo the path, and the suite reports GREEN having
/// replayed nothing — the probe silently converts red into skip, which is
/// precisely the vacuity these guards exist to prevent.
///
/// So absence means different things by provenance. The DEFAULT root may be
/// absent (skip). An EXPLICIT root may not: naming a corpus is a claim that it is
/// there, and if it is not, that is a broken probe and must be loud.
pub fn conformanceAbsenceIsFatal() bool {
    return conformanceRootOverride() != null;
}

/// Self-tests that deliberately read an absent path set this. Nothing else may.
pub var absence_probe_mode: bool = false;

/// Enforce the rule ABOVE the error channel, at the one point every corpus read
/// funnels through.
///
/// Returning an error here would not be enough, and that is the whole lesson of
/// this change. Eleven presence probes in this repo have the shape
/// `fn specFixturesPresent() bool { _ = read(...) catch return false; }`, and
/// every one of them converts any error — including "the corpus you named is not
/// there" — into `error.SkipZigTest`. A per-call error is therefore silently
/// swallowed by the exact code the fail-closed rule exists to protect. A panic
/// cannot be caught into a skip, so the guarantee becomes structural rather than
/// something each of eleven call sites has to remember (`#lzzigspecdiroption`).
fn panicIfExplicitCorpusMissing(path: []const u8, err: anyerror) void {
    if (absence_probe_mode) return;
    const root = conformanceRootOverride() orelse return;
    if (!std.mem.startsWith(u8, path, root)) return;
    std.debug.panic(
        "{s} names `{s}`, but {s} could not be read ({s}).\n" ++
            "An explicitly pointed-at corpus that is not there is a BROKEN PROBE, not a skip: " ++
            "skipping here is how a corpus-perturbation run reports green having replayed " ++
            "nothing (#lzzigspecdiroption).",
        .{ CONFORMANCE_DIR_ENV, root, path, @errorName(err) },
    );
}

/// Drop-in for the `readFixtureFile` helper each conformance file used to define
/// for itself.
pub fn specReadFile(path: []const u8) ![]u8 {
    const bytes = (if (comptime builtin.zig_version.minor >= 16)
        std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            path,
            std.testing.allocator,
            .limited(1024 * 1024),
        )
    else
        std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024 * 1024)) catch |err| {
        panicIfExplicitCorpusMissing(path, err);
        return err;
    };
    // A failed lookup did not open fixture bytes and must not manufacture
    // evidence. Recording after the successful read also keeps negative loader
    // tests from poisoning the runtime manifest with nonexistent ids.
    record(path);
    // Rung 0 (`#lznullformblind`): inventory the assertion blocks these bytes
    // carry, at READ time. Every rung above is scoped to a block a runner bound,
    // so reading the file is the only moment the corpus's full set is in hand.
    recordDeclaredBlocks(path, bytes);
    return bytes;
}

/// Record a read without performing one. For fixtures replayed from bytes that
/// were not obtained through `specReadFile` — see the vendored `@embedFile`
/// mirrors, which are verified byte-for-byte against the canonical file.
pub fn record(path: []const u8) void {
    var abs_buf: [4096]u8 = undefined;
    const abs = toAbsolute(path, &abs_buf) orelse return;
    const idx = std.mem.indexOf(u8, abs, MARKER) orelse return;
    append(abs[idx + MARKER.len ..]);
}

/// Marks a scenario-ledger line so the coverage guard can split the two
/// evidence channels out of one manifest. A corpus-relative fixture id can
/// never begin with `@`, so the split is unambiguous and needs no second file,
/// no second environment variable, and no second build.zig wiring.
pub const SCENARIO_LINE_PREFIX = "@scenario\t";

/// Record that ONE scenario of `fixture` was actually replayed
/// (`#lzscenariocoverage`).
///
/// The fixture manifest proves the file's bytes were opened; a single scenario
/// is enough to satisfy that, so a fixture carrying four scenarios can be a
/// quarter replayed with every existing guard green. The key trackers in
/// `conformance_json.zig` are blind to it for the same reason — an unreplayed
/// scenario contributes no unconsumed key and no unasserted key, because a
/// guard that inspects the blocks you reached cannot see the block you never
/// reached.
///
/// This is a RUNTIME ledger, recorded at the point of replay, for the same
/// reason the fixture manifest is one: a hand-authored list of "scenarios this
/// runner covers" is a claim, and a claim rots.
///
/// `fixture` may be spelled as a corpus-relative id (`stdlib/timer.json`) or as
/// any path containing the conformance root — vendored `@embedFile` replays
/// pass the canonical id directly, since a compile-time embed opens nothing.
pub fn recordScenario(fixture: []const u8, scenario_id: []const u8) void {
    const id = canonicalFixtureId(fixture);
    var buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        SCENARIO_LINE_PREFIX ++ "{s}\t{s}",
        .{ id, scenario_id },
    ) catch return;
    append(line);
}

/// Marks a prose-verification line (`#lzprosekeyconvention`). Same split as
/// `SCENARIO_LINE_PREFIX`: a corpus-relative fixture id can never begin with
/// `@`, so one manifest carries all three evidence channels.
pub const PROSE_LINE_PREFIX = "@prose\t";

/// Record that a fixture's prose discharges were VERIFIED
/// (`#lzprosekeyconvention`, rule 8).
///
/// Rules 1-7 are all satisfied over an empty population: a fixture whose bytes
/// are opened and whose scenarios are never replayed declares paragraphs, and a
/// tracker that never sees a block never fails on one. That is the same vacuity
/// the corpus's own `anti_vacuity` keys exist to name, reappearing inside the
/// guard meant to enforce them.
///
/// So the required set is derived from the CORPUS —
/// `scripts/check-conformance-coverage.sh` walks every fixture declaring
/// `assertions.prose` and demands a line here for each one the suite opened.
/// A hand-kept count would rot the moment lazily-spec declared a tenth
/// paragraph.
pub fn recordProseVerified(fixture: []const u8) void {
    const id = canonicalFixtureId(fixture);
    var buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, PROSE_LINE_PREFIX ++ "{s}", .{id}) catch return;
    append(line);
}

/// Marks an assertion-BLOCK ledger line (`#lznullformblind`). Same `@`-prefixed
/// split as the two channels above, so one manifest still carries every evidence
/// channel with no second file, no second environment variable and no second
/// build.zig wiring.
///
/// Two record shapes:
///   `@block<TAB>declared<TAB><fixture><TAB><digest><TAB><where>`
///   `@block<TAB>bound<TAB><digest>`
pub const BLOCK_LINE_PREFIX = "@block\t";

// ---------------------------------------------------------------------------
// Rung 0: the assertion-block BIND ledger (`#lznullformblind`)
// ---------------------------------------------------------------------------
//
// Every rung above this one is scoped to a block a runner already handed to an
// `AssertionKeys` tracker. The unconsumed-key check fires on a key nothing read;
// the read-but-not-asserted check on a key read and discarded; the prose ledger
// on a discharge naming nothing. None of them can fire for a block NO runner
// ever bound, because there is no tracker — its keys are not unread, nothing
// reads them, and the fixture reports exactly nothing. lazily-dart found two
// such blocks carrying eight silent keys, one of them the anti-spoof invariant
// its fixture exists for; lazily-cpp found a third.
//
// So `specReadFile` inventories every `assertions` block at READ time and
// `AssertionKeys.init` books one as BOUND. The two sides are matched by the
// block's CONTENT digest and never by its `where` label: runners spell those
// inconsistently (`assertions`, `frames[3].assertions`, `scenarios[warn].expect`)
// and a label-keyed ledger would silently miss the mismatch instead of reporting
// it. `scripts/check-conformance-coverage.sh` fails on any inventoried block
// with no bind.

const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

fn feed(hash: *u64, bytes: []const u8) void {
    for (bytes) |byte| {
        hash.* ^= byte;
        hash.* = hash.* *% FNV_PRIME;
    }
}

/// FNV-1a over a structural rendering of `value`.
///
/// Hand-rolled rather than routed through `std.json.stringify` on purpose: the
/// stringify API moved between the three toolchains this repo pins, and a digest
/// that renders differently under one of them would report every block unbound
/// on that toolchain alone. Type tags are folded in so `1` and `"1"` cannot
/// collide, and floats are folded by their exact bits rather than by a formatted
/// form, which is the other thing that drifts across toolchains.
fn hashValue(hash: *u64, value: std.json.Value) void {
    switch (value) {
        .null => feed(hash, "n"),
        .bool => |b| feed(hash, if (b) "b1" else "b0"),
        .integer => |i| {
            feed(hash, "i");
            feed(hash, std.mem.asBytes(&i));
        },
        .float => |f| {
            feed(hash, "f");
            const bits: u64 = @bitCast(f);
            feed(hash, std.mem.asBytes(&bits));
        },
        .number_string => |s| {
            feed(hash, "N");
            feed(hash, s);
        },
        .string => |s| {
            feed(hash, "s");
            feed(hash, s);
        },
        .array => |a| {
            feed(hash, "[");
            for (a.items) |item| hashValue(hash, item);
            feed(hash, "]");
        },
        .object => |o| {
            feed(hash, "{");
            var it = o.iterator();
            while (it.next()) |entry| {
                feed(hash, entry.key_ptr.*);
                feed(hash, "=");
                hashValue(hash, entry.value_ptr.*);
            }
            feed(hash, "}");
        },
    }
}

/// Content key for an assertion block: what it SAYS, not what a runner calls it.
pub fn blockDigest(value: std.json.Value) u64 {
    var hash: u64 = FNV_OFFSET;
    hashValue(&hash, value);
    return hash;
}

/// Book an `assertions` block as BOUND. Called from `AssertionKeys.init`, so
/// every block a runner hands to a tracker is booked whatever it calls it.
pub fn recordBlockBind(value: std.json.Value) void {
    if (value != .object) return;
    var buf: [128]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        BLOCK_LINE_PREFIX ++ "bound\t{x:0>16}",
        .{blockDigest(value)},
    ) catch return;
    append(line);
}

fn declareBlock(fixture: []const u8, where: []const u8, block: std.json.Value) void {
    if (block != .object) return;
    var buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        BLOCK_LINE_PREFIX ++ "declared\t{s}\t{x:0>16}\t{s}",
        .{ fixture, blockDigest(block), where },
    ) catch return;
    append(line);
}

/// Where the inventory walk sends a site.
///
/// Production writes a manifest line. The synthetic probe in this file's tests
/// collects LABELS instead, which is the only way to test the walk on shapes the
/// corpus does not carry: the corpus exercises exactly ONE array-valued tracked
/// key (`signaling/anti_spoof_session.json`, eight of them, all plain-object
/// elements), so a walk that over-widened — counting a scalar element, counting a
/// nested array's contents, renumbering a mixed array — would be green against
/// the corpus and wrong (`#lzarrayelementsites`).
const BlockSink = struct {
    fixture: []const u8 = "",
    capture: ?*CapturedBlocks = null,

    fn emit(self: BlockSink, where: []const u8, block: std.json.Value) void {
        if (self.capture) |c| {
            c.push(where);
            return;
        }
        declareBlock(self.fixture, where, block);
    }
};

/// Test-only collector for `BlockSink`. Bounded inline, so a probe allocates
/// nothing and an over-wide walk overflows into a visible length mismatch rather
/// than into a resize.
const CapturedBlocks = struct {
    labels: [32][]const u8 = undefined,
    len: usize = 0,

    fn push(self: *CapturedBlocks, where: []const u8) void {
        if (self.len == self.labels.len) return;
        self.labels[self.len] = where;
        self.len += 1;
    }

    fn seen(self: *const CapturedBlocks) []const []const u8 {
        return self.labels[0..self.len];
    }
};

/// Key names the canonical corpus uses for an assertion-bearing block
/// (`#lzzigblockwalk`). The whole set, not the one name this walk used to read:
/// the corpus spells a block `assertions`, `expect`, `expected`,
/// `expect_initial` or `expect_after` depending on the fixture family, and a
/// walk that knows only one of them cannot see the other four.
pub const BLOCK_NAMES = [_][]const u8{
    "assertions",
    "expect",
    "expect_after",
    "expect_initial",
    "expected",
};

fn isBlockName(key: []const u8) bool {
    for (BLOCK_NAMES) |name| {
        if (std.mem.eql(u8, key, name)) return true;
    }
    return false;
}

/// Recursion bound for the inventory walk. The corpus nests a handful of levels
/// deep; this exists so a hostile or malformed fixture cannot exhaust the test
/// binary's stack through bookkeeping. Exceeding it contributes no declaration,
/// which then reports downstream as an inventory below the derived expectation
/// rather than as silence.
const MAX_WALK_DEPTH: u8 = 32;

/// Inventory every assertion-bearing block a freshly read fixture carries:
/// every name in `BLOCK_NAMES`, at EVERY depth, object-valued or one
/// plain-object element of an array-valued one.
///
/// Parsing the bytes here rather than asking a runner is the whole point — a
/// block no runner looks at is exactly the one this rung exists to find. Bad
/// JSON is silently skipped: bookkeeping never fails a suite, and a fixture that
/// contributes no declaration shows up downstream as an inventory below the
/// guard's derived expectation.
///
/// This walk used to read the top-level `assertions` key plus the `assertions`
/// key of each element of the top-level `frames`/`scenarios`/`rejects` arrays,
/// and nothing else (`#lzzigblockwalk`). Over the 138 fixtures this suite opens
/// that inventoried 37 sites / 31 distinct digests, while the same fixtures
/// carry 734 sites / 625 distinct digests under the rule below — so every
/// `expect`/`expected` block in the corpus sat outside the rung that exists to
/// catch a block nothing binds. It is verbatim what lazily-py had before it
/// widened, and widening there surfaced 25 blocks no runner bound.
///
/// Two rules make the declaring side and the binding side agree:
///
///   * An ARRAY-VALUED tracked key contributes one site per PLAIN-OBJECT
///     ELEMENT, labelled `<path>[<index>]` (`#lzarrayelementsites`). A runner
///     binds the elements, not the array — so the array itself is still not a
///     site, and the elements now are. This clause used to say array-valued
///     keys contribute NOTHING, on those same grounds, which pointed at a site
///     nobody ever emitted: `signaling/anti_spoof_session.json`'s eight
///     array-valued `expect` keys carry twelve plain-object elements, every one
///     of them an expected outbound signaling frame the replay already read and
///     compared, and all twelve sat outside rung 0. Falsifying one of those
///     values was caught; a runner that stopped asserting them was not.
///   * A block is emitted and NOT descended into, which is what a runner does —
///     it binds the block and stops. Descending would inventory a fixture's
///     `expect` nested inside its own `assertions` as a second, separately
///     bindable site that no tracker can reach without unwrapping the first.
///     An emitted ELEMENT follows the same rule, for the same reason.
///
/// The element rule is deliberately narrow, and identical in all seven bindings
/// that carry it:
///
///   * ONE LEVEL ONLY. `[[{...}]]` emits nothing — the inner array is not an
///     element block, and its contents are reached only by the ordinary
///     descend, which needs a tracked key of its own.
///   * PLAIN OBJECTS ONLY. A scalar, array or null element emits nothing.
///   * TRUE INDEXES. In `[{...}, 3, {...}]` the sites are `expect[0]` and
///     `expect[2]`; numbering the objects consecutively would name the second
///     one `expect[1]`, a label no reader could line up against the fixture.
///
/// List labels prefer an element's own `name` string over its index, so a
/// `where` reported here matches the way the scenario-shaped runners spell the
/// same site and an excuse written against a reported label keeps matching when
/// a scenario moves. That preference applies ONLY to an array reached by
/// DESCENT — that is, held at an UNTRACKED key, where the label names a
/// container the walk is passing through. An element site of a TRACKED key is
/// always `[<index>]`: it names a block, the rule has to be the same byte for
/// byte in every binding, and the guard's python twin computes the site COUNT
/// from the corpus with no access to a runner's naming convention, so a
/// name-preferring element label would be a label only this half can spell.
pub fn recordDeclaredBlocks(path: []const u8, bytes: []const u8) void {
    if (resolveManifestPath() == null) return;
    const id = canonicalFixtureId(path);
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        arena.allocator(),
        bytes,
        .{ .allocate = .alloc_always },
    ) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    walkDeclaredBlocks(arena.allocator(), .{ .fixture = id }, parsed.value, "", 0);
}

fn walkDeclaredBlocks(
    allocator: std.mem.Allocator,
    sink: BlockSink,
    node: std.json.Value,
    path: []const u8,
    depth: u8,
) void {
    if (depth >= MAX_WALK_DEPTH) return;
    switch (node) {
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const value = entry.value_ptr.*;
                const child = if (path.len == 0)
                    key
                else
                    std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, key }) catch continue;
                if (isBlockName(key)) {
                    switch (value) {
                        .object => {
                            sink.emit(child, value);
                            continue;
                        },
                        // ONE site per plain-object element, by TRUE index
                        // (`#lzarrayelementsites`).
                        .array => |arr| {
                            declareArrayElements(allocator, sink, arr, child, depth);
                            continue;
                        },
                        // A tracked key holding a scalar is not a block, and the
                        // descend below is a no-op on one; left to fall through
                        // so this switch says nothing the walk does not do.
                        else => {},
                    }
                }
                walkDeclaredBlocks(allocator, sink, value, child, depth + 1);
            }
        },
        .array => |arr| {
            for (arr.items, 0..) |item, index| {
                const label: ?[]const u8 = label: {
                    if (item != .object) break :label null;
                    const named = item.object.get("name") orelse break :label null;
                    break :label switch (named) {
                        .string => |s| s,
                        else => null,
                    };
                };
                const child = if (label) |l|
                    std.fmt.allocPrint(allocator, "{s}[{s}]", .{ path, l }) catch continue
                else
                    std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, index }) catch continue;
                walkDeclaredBlocks(allocator, sink, item, child, depth + 1);
            }
        },
        else => {},
    }
}

/// The elements of an array held at a TRACKED key (`#lzarrayelementsites`).
///
/// Emitted and not descended into, exactly as an object-valued tracked key is.
/// A non-object element is NOT a site and is descended instead, which is what
/// the walk did with every element of such an array before this rule existed —
/// so a tracked key holding `[[{"expect": {...}}]]` still reaches the inner
/// `expect` by its own tracked key and never as an element block.
///
/// The index is the element's TRUE position, so a mixed array's object elements
/// keep the positions a reader can look up in the fixture.
fn declareArrayElements(
    allocator: std.mem.Allocator,
    sink: BlockSink,
    arr: std.json.Array,
    path: []const u8,
    depth: u8,
) void {
    // The elements sit one level below the array-holding key, the depth the
    // array node itself would have been visited at.
    if (depth + 1 >= MAX_WALK_DEPTH) return;
    for (arr.items, 0..) |item, index| {
        const child = std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, index }) catch continue;
        if (item == .object) {
            sink.emit(child, item);
            continue;
        }
        walkDeclaredBlocks(allocator, sink, item, child, depth + 1);
    }
}

/// `path` reduced to its corpus-relative id, or returned unchanged when it is
/// already one.
fn canonicalFixtureId(path: []const u8) []const u8 {
    if (std.mem.indexOf(u8, path, MARKER)) |idx| return path[idx + MARKER.len ..];
    return path;
}

/// `path` resolved against the process cwd. Test binaries can run from a working
/// directory other than the repo root, so the id must not depend on how the read
/// was spelled. `..` components are left in place: they do not affect the marker
/// search, and normalizing them would need a full path cleaner for no gain.
fn toAbsolute(path: []const u8, buf: []u8) ?[]const u8 {
    if (path.len == 0) return null;
    if (path[0] == '/') {
        if (path.len > buf.len) return null;
        @memcpy(buf[0..path.len], path);
        return buf[0..path.len];
    }
    const rc = linux.getcwd(buf.ptr, buf.len);
    if (@as(isize, @bitCast(rc)) < 0) return null;
    // getcwd returns the length INCLUDING the trailing NUL.
    var len = rc;
    if (len > 0 and buf[len - 1] == 0) len -= 1;
    if (len + 1 + path.len > buf.len) return null;
    buf[len] = '/';
    @memcpy(buf[len + 1 ..][0..path.len], path);
    return buf[0 .. len + 1 + path.len];
}

fn append(id: []const u8) void {
    mutex.lock();
    defer mutex.unlock();

    const out = resolveManifestPath() orelse return;
    const fd_raw = linux.open(out.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .APPEND = true,
    }, 0o644);
    if (@as(isize, @bitCast(fd_raw)) < 0) return;
    const fd: linux.fd_t = @intCast(fd_raw);
    defer _ = linux.close(fd);

    // The run-id stamp goes out BEFORE this process's first evidence line
    // (`#lzstalemanifest`), so the first line of the manifest is always a stamp
    // and no evidence can precede the id that dates it. Written by the test
    // BINARY and never by the Makefile on purpose: a Makefile-written stamp
    // would date a manifest whose evidence a skipped or cached run never
    // produced, which is the hole wearing the fix's uniform — worse than the
    // status quo, because an empty-but-stamped manifest passes the `-s` check
    // that an empty one fails.
    //
    // That last sentence is a hazard this stamp CREATED and not only a reason to
    // keep the writer here (`#lzstampsatisfiesnonempty`). The guard's byte-size
    // check on the manifest was carrying the "the recorder produced evidence"
    // claim, and a stamp satisfies it. The guard now counts non-stamp lines as
    // well, so that claim is asserted rather than implied by the truncation.
    //
    // This writer cannot produce such a file: the stamp is emitted lazily, from
    // inside `append`, immediately before the evidence line that occasioned it,
    // so every stamp it writes is followed by at least one record in the same
    // call. A stamp-only manifest therefore means a stale copy, a hand-made file,
    // or some other writer — which is what the guard's records rung now names.
    //
    // Unset run id writes no stamp. That is not a silent pass: the guard
    // refuses a manifest carrying no stamp, so a suite run without the nonce
    // reports missing evidence rather than green.
    if (!run_id_stamped) {
        run_id_stamped = true;
        if (resolveRunId()) |rid| {
            var stamp_buf: [4096]u8 = undefined;
            const stamp = std.fmt.bufPrint(
                &stamp_buf,
                RUN_ID_LINE_PREFIX ++ "{s}",
                .{rid},
            ) catch null;
            if (stamp) |line| writeLine(fd, line);
        }
    }

    // One write per read. An exit hook would be tidier, but Zig's test runner
    // gives no reliable per-binary teardown, and a lost flush is a false "not
    // opened" — the one failure mode this guard must not produce.
    writeLine(fd, id);
}

/// One `write` of `bytes` plus a newline, retried on a short write.
///
/// O_APPEND plus a single `write` per line is what lets a dozen test binaries
/// share one manifest without interleaving inside a line. A short write is
/// retried rather than abandoned, but the retry is a second syscall and can in
/// principle interleave — the lines are short enough that the kernel does not
/// split them in practice, and a mangled line surfaces downstream as missing
/// evidence, never as a false positive.
fn writeLine(fd: linux.fd_t, bytes: []const u8) void {
    var line_buf: [4096]u8 = undefined;
    if (bytes.len + 1 > line_buf.len) return;
    @memcpy(line_buf[0..bytes.len], bytes);
    line_buf[bytes.len] = '\n';
    var written: usize = 0;
    const total = bytes.len + 1;
    while (written < total) {
        const rc = linux.write(fd, line_buf[written..].ptr, total - written);
        const signed: isize = @bitCast(rc);
        if (signed <= 0) return;
        written += @intCast(rc);
    }
}

/// The manifest path comes from `LAZILY_CONFORMANCE_MANIFEST` and must be
/// ABSOLUTE — the Makefile exports `$(CURDIR)/...` for that reason. Unset means
/// the recorder is a no-op, so a bare `zig build test` is unaffected.
/// The per-invocation nonce from `LAZILY_CONFORMANCE_RUN_ID`
/// (`#lzstalemanifest`). Resolved once, like the manifest path and the corpus
/// root: `readEnv` re-opens and re-scans `/proc/self/environ` on every call,
/// and caching also means the id a run stamps cannot change halfway through it.
///
/// Null means the nonce is unset, which is NOT an excuse — see `append`.
fn resolveRunId() ?[:0]const u8 {
    if (run_id_resolved) return run_id;
    run_id_resolved = true;
    run_id = readEnv(RUN_ID_ENV_NAME, &run_id_buf);
    return run_id;
}

fn resolveManifestPath() ?[:0]const u8 {
    if (manifest_resolved) return manifest_path;
    manifest_resolved = true;
    manifest_path = readEnv(ENV_NAME, &manifest_path_buf);
    return manifest_path;
}

/// True when `name` is present in the environment with a non-empty value.
///
/// Shares `readEnv`'s toolchain-stable `/proc/self/environ` path so callers do
/// not each reinvent it. Used by the conformance runners to gate routine
/// progress output (see `reactive_graph_conformance.zig`, `#lzzigfailedcommand`).
pub fn envFlagSet(name: []const u8) bool {
    var buf: [256]u8 = undefined;
    return readEnv(name, &buf) != null;
}

/// Zig 0.17-dev's std reorganized env access behind the new Io interface (no
/// stable `std.posix.getenv`/`std.process.getenv`), so read `/proc/self/environ`
/// via raw Linux syscalls — the one path that stays stable across the toolchain
/// churn and works without linking libc.
fn readEnv(name: []const u8, buf: []u8) ?[:0]const u8 {
    var environ: [65536]u8 = undefined;
    const fd_raw = linux.open("/proc/self/environ", .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(fd_raw)) < 0) return null;
    const fd: linux.fd_t = @intCast(fd_raw);
    defer _ = linux.close(fd);
    var total: usize = 0;
    while (total < environ.len) {
        const rc = linux.read(fd, environ[total..].ptr, environ.len - total);
        const signed: isize = @bitCast(rc);
        if (signed <= 0) break;
        total += @intCast(rc);
    }
    var it = std.mem.splitScalar(u8, environ[0..total], 0);
    while (it.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (!std.mem.eql(u8, entry[0..eq], name)) continue;
        const value = entry[eq + 1 ..];
        if (value.len == 0 or value.len + 1 > buf.len) return null;
        @memcpy(buf[0..value.len], value);
        buf[value.len] = 0;
        return buf[0..value.len :0];
    }
    return null;
}

/// Fixtures this repo replays from a vendored copy under `src/lazily/test/`
/// rather than from the canonical corpus. They are `@embedFile`d at compile time
/// so CI needs no `lazily-spec` sibling checkout (see the `reliable_sync.zig`
/// and `statechart.zig` headers), which means the runtime recorder can never see
/// them — a compile-time embed opens nothing.
///
/// The test below closes that hole from the other end: it opens the CANONICAL
/// file (recording the read) and asserts the vendored copy is byte-identical. So
/// the coverage guard's claim for these ids is "the canonical bytes were read
/// and are exactly the bytes the suite replays", not "a runner opened them".
/// A vendored copy drifting from upstream now fails here instead of silently
/// replaying yesterday's corpus.
///
/// `codec/blob_backend_discriminator.json` is the one entry NOT replayed from
/// its embed — its runner reads the canonical file like every other
/// `codec/` replay. It is mirrored anyway because lazily-spec's
/// `scripts/sync-conformance-fixtures.mjs` reconciles a fixture change for
/// every binding from the CORPUS side, and it can only reconcile files a mirror
/// actually carries. Listing it here is what makes the copy checked rather than
/// merely present.
const VENDORED_MIRRORS = [_][]const u8{
    "codec/blob_backend_discriminator.json",
    "crdt-tree/algebra.json",
    "reliable-sync/idempotent_redelivery.json",
    "reliable-sync/liveness_orset_lww.json",
    "reliable-sync/multi_epoch_delta.json",
    "reliable-sync/outbox_journal_decode.json",
    "reliable-sync/outbox_replay_after_crash.json",
    "reliable-sync/outbox_store_protocol.json",
    "reliable-sync/resync_gap_converge.json",
    "statechart/entry_exit_actions.json",
    "statechart/flat_cycle.json",
    "statechart/guarded_door.json",
    "statechart/hierarchical_player.json",
    "statechart/history_deep.json",
    "statechart/history_shallow.json",
    "statechart/malformed_rejected.json",
    "statechart/parallel_regions.json",
};

test "conformance manifest: vendored fixture copies match the canonical corpus" {
    inline for (VENDORED_MIRRORS) |rel| {
        const embedded = @embedFile("test/" ++ rel);
        const canonical = specReadFile("../lazily-spec/conformance/" ++ rel) catch {
            // No sibling checkout — the vendored copy is all there is, which is
            // why it is vendored. The coverage guard skips itself in that state
            // too.
            return error.SkipZigTest;
        };
        defer std.testing.allocator.free(canonical);
        std.testing.expectEqualSlices(u8, canonical, embedded) catch |err| {
            std.debug.print(
                "vendored src/lazily/test/{s} has drifted from ../lazily-spec/conformance/{s}\n",
                .{ rel, rel },
            );
            return err;
        };
    }
}

/// Run the REAL inventory walk over `json` and hand back the labels it emitted.
///
/// The walk under test is `walkDeclaredBlocks` itself — not a copy of its rule —
/// because a probe against a re-stated rule tests the copy and nothing else.
fn probeDeclaredBlocks(
    arena: std.mem.Allocator,
    json: []const u8,
    capture: *CapturedBlocks,
) !void {
    const value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        json,
        .{ .allocate = .alloc_always },
    );
    walkDeclaredBlocks(arena, .{ .capture = capture }, value, "", 0);
}

test "conformance manifest: an array-valued tracked key declares its plain-object elements" {
    // The corpus carries exactly ONE array-valued tracked-key shape — eight
    // `expect` arrays in `signaling/anti_spoof_session.json`, every element a
    // plain object — so it cannot catch an OVER-wide rule. These are the shapes
    // it does not carry (`#lzarrayelementsites`).
    const cases = [_]struct {
        what: []const u8,
        json: []const u8,
        want: []const []const u8,
    }{
        .{
            .what = "object-valued: the key itself, unchanged",
            .json = "{\"expect\": {\"a\": 1}}",
            .want = &.{"expect"},
        },
        .{
            .what = "array of 2 objects: one site each",
            .json = "{\"expect\": [{\"a\": 1}, {\"b\": 2}]}",
            .want = &.{ "expect[0]", "expect[1]" },
        },
        .{
            .what = "array of scalars: no site",
            .json = "{\"expect\": [1, 2, 3]}",
            .want = &.{},
        },
        .{
            .what = "mixed array: TRUE indexes, so [0] and [2]",
            .json = "{\"expect\": [{\"a\": 1}, 3, {\"b\": 2}]}",
            .want = &.{ "expect[0]", "expect[2]" },
        },
        .{
            .what = "nested array: one level only, so no site",
            .json = "{\"expect\": [[{\"a\": 1}]]}",
            .want = &.{},
        },
        .{
            .what = "untracked key holding an array of objects: no site",
            .json = "{\"frames\": [{\"a\": 1}, {\"b\": 2}]}",
            .want = &.{},
        },
        .{
            // The other half of the pair: an element is emitted and NOT
            // descended into, exactly as an object-valued tracked key is, so a
            // tracked key nested inside an element is not a second bindable site.
            .what = "an emitted element is not descended into",
            .json = "{\"expect\": [{\"expect\": {\"a\": 1}}]}",
            .want = &.{"expect[0]"},
        },
        .{
            // Element labels are ALWAYS indexes. The name preference belongs to
            // an array reached by DESCENT, and `steps` below shows it still does.
            .what = "a `name` field does not rename an element site",
            .json = "{\"steps\": [{\"name\": \"s\", \"expect\": [{\"name\": \"f\"}]}]}",
            .want = &.{"steps[s].expect[0]"},
        },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var capture = CapturedBlocks{};
        try probeDeclaredBlocks(arena.allocator(), case.json, &capture);
        const got = capture.seen();
        std.testing.expectEqual(case.want.len, got.len) catch |err| {
            std.debug.print("walk case `{s}` emitted {d} site(s):\n", .{ case.what, got.len });
            for (got) |label| std.debug.print("  {s}\n", .{label});
            return err;
        };
        for (case.want, got) |want, label| {
            std.testing.expectEqualStrings(want, label) catch |err| {
                std.debug.print("walk case `{s}`: wanted `{s}`, got `{s}`\n", .{ case.what, want, label });
                return err;
            };
        }
    }
}

test "conformance manifest: same-array element sites are named separately" {
    // Label DISAMBIGUATION, on the corpus shape the rule exists for. A per-array
    // label would collapse a three-frame step's three expected frames into one
    // site, and the bind ledger is a SET — collapsed labels make two detached
    // binds indistinguishable from one, which is the set-identity failure this
    // family cares about. All twelve, in full, so a renumbering is visible too.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const path = try specPath(arena.allocator(), "signaling/anti_spoof_session.json");
    const bytes = specReadFile(path) catch return error.SkipZigTest;
    defer std.testing.allocator.free(bytes);

    var capture = CapturedBlocks{};
    const value = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena.allocator(),
        bytes,
        .{ .allocate = .alloc_always },
    );
    walkDeclaredBlocks(arena.allocator(), .{ .capture = &capture }, value, "", 0);

    const want = [_][]const u8{
        "assertions",
        "steps[0].expect[0]",
        "steps[1].expect[0]",
        "steps[1].expect[1]",
        "steps[2].expect[0]",
        "steps[2].expect[1]",
        "steps[2].expect[2]",
        "steps[3].expect[0]",
        "steps[4].expect[0]",
        "steps[5].expect[0]",
        "steps[6].expect[0]",
        "steps[7].expect[0]",
        "steps[7].expect[1]",
    };
    const got = capture.seen();
    std.testing.expectEqual(want.len, got.len) catch |err| {
        for (got) |label| std.debug.print("  {s}\n", .{label});
        return err;
    };
    for (want, got) |w, label| try std.testing.expectEqualStrings(w, label);
}

test "conformance manifest: ids are relative to the conformance root" {
    var buf: [4096]u8 = undefined;
    const abs = toAbsolute("../lazily-spec/conformance/collections/x.json", &buf).?;
    try std.testing.expect(abs[0] == '/');
    const idx = std.mem.indexOf(u8, abs, MARKER).?;
    try std.testing.expectEqualStrings("collections/x.json", abs[idx + MARKER.len ..]);
}

test "conformance manifest: a scenario line is distinguishable from a fixture id" {
    // The two evidence channels share one file. The prefix is what lets the
    // coverage guard split them, so it must never collide with a corpus id.
    try std.testing.expect(SCENARIO_LINE_PREFIX[0] == '@');
    try std.testing.expectEqualStrings("stdlib/timer.json", canonicalFixtureId("stdlib/timer.json"));
    try std.testing.expectEqualStrings(
        "reliable-sync/liveness_orset_lww.json",
        canonicalFixtureId(
            "../lazily-spec/conformance/reliable-sync/liveness_orset_lww.json",
        ),
    );
}

test "conformance manifest: reads outside the corpus are not recorded" {
    var buf: [4096]u8 = undefined;
    const abs = toAbsolute("src/lazily/test/statechart/flat_cycle.json", &buf).?;
    try std.testing.expect(std.mem.indexOf(u8, abs, MARKER) == null);
}

/// The coverage guard, relative to the repo root (`#lzstampprefixdrift`).
///
/// Relative on purpose, and this is not the manifest's situation: the manifest
/// path has to survive a WRITER started from anywhere, while this is a READ from
/// a test binary, and every conformance replay in this repo already resolves the
/// corpus through a relative `../lazily-spec/conformance`. If cwd were not the
/// repo root, 138 fixtures would not open and nothing here would be green.
const COVERAGE_GUARD_PATH = "scripts/check-conformance-coverage.sh";

/// The guard's own spelling of the stamp prefix, taken from the guard source.
///
/// PARSED, not restated. Restating the literal here would make this test pass
/// against a third copy of the string — one more place to drift rather than a fix
/// for the two that already exist.
///
/// Exactly one assignment is required. Two would let the guard set the prefix
/// twice and let this test agree with whichever it found first, which is the same
/// defect one level down.
/// Hand-rolled because the stdlib spelling is not stable across the three pinned
/// toolchains: `std.mem.trimLeft`/`trimRight` exist on 0.15.2 and are gone on
/// 0.16.0+ in favour of `trimStart`/`trimEnd`. A gate that only compiles on one
/// of the pinned releases is not a gate (`#lzzigfmttoolchains`).
fn trimBlankStart(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return s[i..];
}

fn trimEndByte(s: []const u8, ch: u8) []const u8 {
    var end = s.len;
    while (end > 0 and s[end - 1] == ch) end -= 1;
    return s[0..end];
}

fn guardRunIdPrefix(source: []const u8) ![]const u8 {
    const assign = "RUN_ID_PREFIX=\"";
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = trimBlankStart(raw);
        if (!std.mem.startsWith(u8, line, assign)) continue;
        const rest = line[assign.len..];
        const close = std.mem.indexOfScalar(u8, rest, '"') orelse
            return error.GuardPrefixAssignmentUnterminated;
        if (found != null) return error.GuardPrefixAssignedTwice;
        found = rest[0..close];
    }
    return found orelse error.GuardPrefixAssignmentMissing;
}

test "conformance manifest: the guard and the recorder agree on the stamp prefix" {
    // Two definitions of one string held together by a comment is the shape that
    // drifts (`#lzstampprefixdrift`). This recorder WRITES the prefix; the
    // coverage guard RECOGNISES it from its own `RUN_ID_PREFIX`. A drift between
    // them fails closed — the guard finds no stamp and reports missing evidence —
    // so nothing goes green, but the failure then reads as a stale-evidence bug in
    // a protocol nobody touched instead of as the one-character typo it is. This
    // test is what turns that into a named mismatch.
    //
    // NOT skippable. The guard is in THIS repo, so an unreadable one is a broken
    // test, not an absent sibling checkout.
    const source = (if (comptime builtin.zig_version.minor >= 16)
        std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            COVERAGE_GUARD_PATH,
            std.testing.allocator,
            .limited(1024 * 1024),
        )
    else
        std.fs.cwd().readFileAlloc(
            std.testing.allocator,
            COVERAGE_GUARD_PATH,
            1024 * 1024,
        )) catch |err| {
        std.debug.print(
            "could not read {s} from the test cwd ({s}); the stamp-prefix" ++
                " coupling is then unverifiable, which is a failure and not a skip\n",
            .{ COVERAGE_GUARD_PATH, @errorName(err) },
        );
        return err;
    };
    defer std.testing.allocator.free(source);

    const guard_prefix = try guardRunIdPrefix(source);
    std.testing.expectEqualStrings(RUN_ID_LINE_PREFIX, guard_prefix) catch |err| {
        std.debug.print(
            "the stamp prefix has DRIFTED.\n" ++
                "  recorder RUN_ID_LINE_PREFIX: `{s}`\n" ++
                "  guard    RUN_ID_PREFIX:      `{s}` ({s})\n" ++
                "A manifest stamped with one and read with the other carries no stamp\n" ++
                "the guard can see, so the guard reports missing evidence and the real\n" ++
                "fault — these two strings — is never named (#lzstampprefixdrift).\n",
            .{ RUN_ID_LINE_PREFIX, guard_prefix, COVERAGE_GUARD_PATH },
        );
        return err;
    };

    // The guard's python rung splits the manifest by matching `@block`
    // POSITIVELY, so it never needs to know how a stamp is spelled and holds no
    // copy of the prefix. That is a property to PIN, not a fact to recheck by
    // hand: hand-write the literal into that heredoc — or anywhere else in the
    // guard — and it becomes a third definition this test would not otherwise
    // see. So the prefix's bytes may appear in the guard exactly ONCE, in the
    // assignment compared above. Trailing space trimmed off the needle so the
    // check does not turn on a detail of the guard's quoting.
    const needle = trimEndByte(RUN_ID_LINE_PREFIX, ' ');
    var occurrences: usize = 0;
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, source, at, needle)) |hit| {
        occurrences += 1;
        at = hit + 1;
    }
    std.testing.expectEqual(@as(usize, 1), occurrences) catch |err| {
        std.debug.print(
            "`{s}` appears {d} time(s) in {s}; expected exactly 1, the" ++
                " RUN_ID_PREFIX assignment. Every other use has to go through" ++
                " the variable, or it is a fresh copy free to drift" ++
                " (#lzstampprefixdrift).\n",
            .{ needle, occurrences, COVERAGE_GUARD_PATH },
        );
        return err;
    };
}
