const std = @import("std");
const json = std.json;
const testing = std.testing;
const cell = @import("cell.zig");
const Context = @import("context.zig").Context;
const Compute = @import("context.zig").Compute;
const ThreadSafeContext = @import("thread_safe_context.zig").ThreadSafeContext;
const dependency = @import("dependency_map.zig");
const cj = @import("conformance_json.zig");

/// Corpus-relative. The root resolves at RUNTIME (`#lzzigingressspecdir`); the
/// full path is built per read so `LAZILY_SPEC_CONFORMANCE_DIR` moves this replay.
const fixture_rel = "collections/dependency_reactive_availability.json";

fn required(value: json.Value, name: []const u8) !json.Value {
    return cj.required(value, name);
}

fn string(value: json.Value) ![]const u8 {
    return cj.asStr(value);
}

fn integer(value: json.Value) !i64 {
    return cj.asI64(value);
}

test "dependency availability replays the exact-key fixture" {
    const fixture_path = try @import("conformance_manifest.zig").specPath(testing.allocator, fixture_rel);
    defer testing.allocator.free(fixture_path);
    const raw = try @import("conformance_manifest.zig").specReadFile(fixture_path);
    defer testing.allocator.free(raw);
    var parsed = try json.parseFromSlice(json.Value, testing.allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const Availability = dependency.DependencyAvailability(i64);
    const Map = dependency.DependencyMap([]const u8, i64);
    const Probe = struct {
        var map: *Map = undefined;
        var key: []const u8 = undefined;
        var runs: usize = 0;

        fn read(compute: *Compute) !Availability {
            runs += 1;
            return map.observeDependency(compute, key);
        }
    };

    const ctx = try Context.init(testing.allocator);
    defer ctx.deinit();
    var map = try Map.init(ctx);
    defer map.deinit();
    Probe.map = &map;
    Probe.key = try string(try required(parsed.value, "key"));
    Probe.runs = 0;

    const reader = try cell.computed(Availability, ctx, Probe.read, null);
    defer ctx.allocator.destroy(reader);
    defer reader.dispose();
    var identity: ?u64 = null;

    const steps = try cj.asArray(try required(parsed.value, "steps"));
    try testing.expect(steps.len > 0);
    for (steps, 0..) |step, index| {
        const op = try required(step, "op");
        const op_type = try string(try required(op, "type"));
        if (std.mem.eql(u8, op_type, "observe_dependency")) {
            _ = reader.get().*;
        } else if (std.mem.eql(u8, op_type, "publish")) {
            try map.publish(
                try string(try required(op, "key")),
                try integer(try required(op, "value")),
            );
        } else if (std.mem.eql(u8, op_type, "unpublish")) {
            try map.unpublish(try string(try required(op, "key")));
        } else {
            return error.UnknownDependencyOperation;
        }

        const state = reader.get().*;
        identity = identity orelse map.handle(Probe.key).?.id;
        var expected = cj.AssertionKeys.init(fixture_rel, try required(step, "expected"));
        switch (state) {
            .unavailable => try expected.assertKey("state", "Unavailable"),
            .available => |value| {
                var state_expected = try expected.sub("state");
                try state_expected.assertKey("Available", value);
                try state_expected.finish();
            },
        }
        try expected.assertKey("recomputes", Probe.runs);
        try expected.assertKey("present_count", map.presentCount());
        try testing.expectEqual(identity.?, map.handle(Probe.key).?.id);
        try expected.assertKey("identity", "wanted-1");
        try expected.finish();
        _ = index;
    }
}

test "thread-safe and async dependency maps preserve exact-key identity" {
    var tsctx = ThreadSafeContext.init(testing.allocator);
    defer tsctx.deinit();
    var thread = dependency.ThreadSafeDependencyMap([]const u8, i64).init(&tsctx);
    defer thread.deinit();
    try testing.expectEqual(
        dependency.DependencyAvailability(i64).unavailable,
        try thread.observeDependency("wanted"),
    );
    const thread_id = thread.handle("wanted").?.id;
    try thread.publish("wanted", 7);
    try testing.expectEqual(thread_id, thread.handle("wanted").?.id);

    const AsyncMap = dependency.AsyncDependencyMap([]const u8, i64);
    var actx = AsyncMap.ContextType.init(testing.allocator);
    defer actx.deinit();
    var async_dep = try AsyncMap.init(&actx);
    defer async_dep.deinit();
    try testing.expectEqual(
        dependency.DependencyAvailability(i64).unavailable,
        try async_dep.observeDependency("wanted"),
    );
    const async_id = async_dep.handle("wanted").?.id;
    try async_dep.publish("wanted", 8);
    try testing.expectEqual(async_id, async_dep.handle("wanted").?.id);
}
