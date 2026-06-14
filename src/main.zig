const std = @import("std");
const lazily = @import("lazily");

pub fn main() !void {
    std.debug.print("{s} protocol v{}\n", .{
        lazily.ipc.protocol_id,
        lazily.ipc.protocol_major_version,
    });
}
