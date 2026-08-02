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
const VENDORED_MIRRORS = [_][]const u8{
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
