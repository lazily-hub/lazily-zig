//! Interop peer entry point for Zig 0.16+ (`std.process.Init` + `std.Io`).
//!
//! `build.zig` selects this root for 0.16 and master and
//! `interop_peer_main_0_15.zig` for 0.15.x. The peer protocol itself is shared —
//! only the process/IO plumbing differs between toolchains (#lzinteroppeerci).

const std = @import("std");
const peer_mod = @import("interop_peer.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var peer = peer_mod.Peer.init(init.gpa);
    defer peer.deinit();
    if (args.len > 1 and std.mem.eql(u8, args[1], "--self-check")) {
        try peer_mod.selfCheck(&peer);
        std.debug.print("lazily-zig interop peer self-check: ok\n", .{});
        return;
    }

    var stdin_buffer: [1024 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &stdin_buffer);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const input = &stdin_reader.interface;
    const output = &stdout_writer.interface;

    while (try input.takeDelimiter('\n')) |line| {
        const bye = std.mem.indexOf(u8, line, "\"cmd\":\"bye\"") != null or
            std.mem.indexOf(u8, line, "\"cmd\": \"bye\"") != null;
        const response = peer.requestAlloc(line) catch |err|
            try peer.errorAlloc(@errorName(err));
        try output.writeAll(response);
        try output.writeByte('\n');
        try output.flush();
        if (bye) return;
    }
}
