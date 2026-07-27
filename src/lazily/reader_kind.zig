//! Graph-backed reader-kind identity shared by the synchronous collection
//! shells. A reader derives its value from collection storage on demand, while
//! this node supplies the dependency edge and exact changed-kind invalidation.

const Context = @import("context.zig").Context;
const Slot = @import("context.zig").Slot;
const cell = @import("cell.zig");

pub const ReaderKind = struct {
    source: *cell.Source(u64),

    fn initial(_: *@import("context.zig").Compute) !u64 {
        return 0;
    }

    pub fn init(ctx: *Context) !ReaderKind {
        const key = try ctx.reserveDynamicCacheKey();
        return .{
            .source = try cell.sourceKeyed(u64, ctx, key, initial, null),
        };
    }

    pub fn slot(self: ReaderKind) *Slot {
        return self.source.slot;
    }

    pub fn version(self: ReaderKind) u64 {
        return self.source.get();
    }

    pub fn dispose(self: ReaderKind) void {
        self.source.disposeNode();
    }

    pub fn bump(self: ReaderKind) void {
        var sources = [_]*cell.Source(u64){self.source};
        cell.bumpSources(self.source.ctx, &sources);
    }

    pub fn bumpMany(ctx: *Context, readers: []const ReaderKind) void {
        var sources: [16]*cell.Source(u64) = undefined;
        std.debug.assert(readers.len <= sources.len);
        for (readers, 0..) |reader, index| sources[index] = reader.source;
        cell.bumpSources(ctx, sources[0..readers.len]);
    }
};

const std = @import("std");

test "lazily/reader_kind: runtime nodes have distinct graph identities" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const left = try ReaderKind.init(ctx);
    const right = try ReaderKind.init(ctx);

    try std.testing.expect(left.slot() != right.slot());
    left.bump();
    try std.testing.expectEqual(@as(u64, 1), left.version());
    try std.testing.expectEqual(@as(u64, 0), right.version());
}
