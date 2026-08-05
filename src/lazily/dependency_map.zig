//! Exact-key reactive dependency publication (`#lzdependencyavailability`).
//!
//! A missing publication is represented by a stable source whose value is
//! `.unavailable`. Publication is a normal transition of that exact source to
//! `.available(value)`; membership epochs and request/ack handshakes are not
//! part of the dependency path.

const Context = @import("context.zig").Context;
const Compute = @import("context.zig").Compute;
const reactive_map = @import("reactive_map.zig");
const thread_safe = @import("thread_safe_reactive_map.zig");
const async_map = @import("async_reactive_map.zig");
const ThreadSafeContext = @import("thread_safe_context.zig").ThreadSafeContext;
const AsyncContext = @import("async_context.zig").AsyncContext;

pub fn DependencyAvailability(comptime V: type) type {
    return union(enum) {
        unavailable,
        available: V,
    };
}

pub fn DependencyMap(comptime K: type, comptime V: type) type {
    const Availability = DependencyAvailability(V);
    const Sources = reactive_map.SourceMap(K, Availability);
    return struct {
        sources: Sources,

        const Self = @This();

        pub fn init(ctx: *Context) !Self {
            return .{ .sources = try Sources.init(ctx) };
        }

        pub fn deinit(self: *Self) void {
            self.sources.deinit();
        }

        pub fn observeDependency(self: *Self, compute: *Compute, key: K) !Availability {
            _ = try self.sources.entry(key, .unavailable);
            return compute.get(self.sources.handle(key).?) orelse unreachable;
        }

        pub fn observeDependencyUntracked(self: *Self, key: K) !Availability {
            _ = try self.sources.entry(key, .unavailable);
            return self.sources.get(key).?;
        }

        pub fn publish(self: *Self, key: K, value: V) !void {
            try self.sources.set(key, .{ .available = value });
        }

        pub fn unpublish(self: *Self, key: K) !void {
            try self.sources.set(key, .unavailable);
        }

        pub fn handle(self: *const Self, key: K) ?Sources.ValueReader {
            return self.sources.handle(key);
        }

        pub fn presentCount(self: *const Self) usize {
            return self.sources.presentCount();
        }
    };
}

pub fn ThreadSafeDependencyMap(comptime K: type, comptime V: type) type {
    const Availability = DependencyAvailability(V);
    const Sources = thread_safe.ThreadSafeSourceMap(K, Availability);
    return struct {
        sources: Sources,

        const Self = @This();

        pub fn init(ctx: *ThreadSafeContext) Self {
            return .{ .sources = Sources.init(ctx) };
        }

        pub fn deinit(self: *Self) void {
            self.sources.deinit();
        }

        pub fn observeDependency(self: *Self, key: K) !Availability {
            if (!self.sources.isPresent(key)) try self.sources.set(key, .unavailable);
            return self.sources.observe(key).?;
        }

        pub fn publish(self: *Self, key: K, value: V) !void {
            try self.sources.set(key, .{ .available = value });
        }

        pub fn unpublish(self: *Self, key: K) !void {
            try self.sources.set(key, .unavailable);
        }

        pub fn handle(self: *Self, key: K) ?@TypeOf(self.sources.handle(key).?) {
            return self.sources.handle(key);
        }

        pub fn presentCount(self: *Self) usize {
            return self.sources.presentCount();
        }
    };
}

pub fn AsyncDependencyMap(comptime K: type, comptime V: type) type {
    const Availability = DependencyAvailability(V);
    const Sources = async_map.AsyncSourceMap(K, Availability);
    return struct {
        sources: Sources,

        const Self = @This();
        pub const ContextType = AsyncContext(Availability);

        pub fn init(ctx: *ContextType) !Self {
            return .{ .sources = try Sources.init(ctx) };
        }

        pub fn deinit(self: *Self) void {
            self.sources.deinit();
        }

        pub fn observeDependency(self: *Self, key: K) !Availability {
            if (!self.sources.isPresent(key)) try self.sources.set(key, .unavailable);
            return self.sources.observe(key).?;
        }

        pub fn publish(self: *Self, key: K, value: V) !void {
            try self.sources.set(key, .{ .available = value });
        }

        pub fn unpublish(self: *Self, key: K) !void {
            try self.sources.set(key, .unavailable);
        }

        pub fn handle(self: *const Self, key: K) ?@TypeOf(self.sources.handle(key).?) {
            return self.sources.handle(key);
        }

        pub fn presentCount(self: *const Self) usize {
            return self.sources.presentCount();
        }
    };
}
