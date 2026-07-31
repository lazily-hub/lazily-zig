//! Interop peer entry point for Zig 0.15.x.
//!
//! Same protocol, same self-check, older process/IO plumbing: 0.15 has neither
//! `std.process.Init` nor `std.Io`, so args come from `std.process.argsAlloc`
//! and the streams from `std.fs.File.stdin()/stdout()` with the two-argument
//! reader/writer constructors. `build.zig` picks this root on 0.15 and
//! `interop_peer_main.zig` on 0.16+ (#lzinteroppeerci).
//!
//! This file exists because the peer had quietly stopped building on 0.15.2
//! altogether. It only ever ran from `make check` on a developer's default
//! toolchain, so the other two toolchains in the CI matrix never compiled it —
//! precisely the rot that running the gate on a laptop and nowhere else
//! produces.

const std = @import("std");
const peer_mod = @import("interop_peer.zig");

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var peer = peer_mod.Peer.init(gpa);
    defer peer.deinit();
    if (args.len > 1 and std.mem.eql(u8, args[1], "--self-check")) {
        try peer_mod.selfCheck(&peer);
        std.debug.print("lazily-zig interop peer self-check: ok\n", .{});
        return;
    }

    var stdin_buffer: [1024 * 1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buffer);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
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
