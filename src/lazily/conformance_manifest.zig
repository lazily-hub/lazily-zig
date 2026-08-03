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

var mutex: ParkingMutex = .{};
var manifest_path_buf: [4096]u8 = undefined;
var manifest_path: ?[:0]const u8 = null;
var manifest_resolved: bool = false;

/// Read a conformance fixture and record the fact that its bytes were opened.
///
/// Drop-in for the `readFixtureFile` helper each conformance file used to define
/// for itself.
pub fn specReadFile(path: []const u8) ![]u8 {
    const bytes = if (comptime builtin.zig_version.minor >= 16)
        try std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            path,
            std.testing.allocator,
            .limited(1024 * 1024),
        )
    else
        try std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024 * 1024);
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

/// Inventory every `assertions` block a freshly read fixture carries: the
/// top-level one plus any carried per-frame, per-scenario or per-reject.
///
/// Parsing the bytes here rather than asking a runner is the whole point — a
/// block no runner looks at is exactly the one this rung exists to find. Bad
/// JSON is silently skipped: bookkeeping never fails a suite, and a fixture that
/// contributes no declaration shows up downstream as an inventory below the
/// guard's floor.
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
    const root = parsed.value.object;

    if (root.get("assertions")) |block| declareBlock(id, "assertions", block);
    for ([_][]const u8{ "frames", "scenarios", "rejects" }) |container| {
        const items = root.get(container) orelse continue;
        if (items != .array) continue;
        for (items.array.items, 0..) |item, index| {
            if (item != .object) continue;
            const block = item.object.get("assertions") orelse continue;
            var where_buf: [128]u8 = undefined;
            const where = std.fmt.bufPrint(
                &where_buf,
                "{s}[{d}].assertions",
                .{ container, index },
            ) catch continue;
            declareBlock(id, where, block);
        }
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

    // One write per read. An exit hook would be tidier, but Zig's test runner
    // gives no reliable per-binary teardown, and a lost flush is a false "not
    // opened" — the one failure mode this guard must not produce.
    var line_buf: [4096]u8 = undefined;
    if (id.len + 1 > line_buf.len) return;
    @memcpy(line_buf[0..id.len], id);
    line_buf[id.len] = '\n';
    var written: usize = 0;
    const total = id.len + 1;
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
    "reliable-sync/outbox_replay_after_crash.json",
    "reliable-sync/outbox_store_protocol.json",
    "reliable-sync/resync_gap_converge.json",
    "statechart/entry_exit_actions.json",
    "statechart/flat_cycle.json",
    "statechart/guarded_door.json",
    "statechart/hierarchical_player.json",
    "statechart/history_deep.json",
    "statechart/history_shallow.json",
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
