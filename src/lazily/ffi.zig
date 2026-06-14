const std = @import("std");
const build_options = @import("build_options");

pub const LazilyFfiBytes = extern struct {
    ptr: [*]u8,
    len: usize,
};

pub const LazilyFfiStatus = enum(u32) {
    Ok = 0,
    Empty = 1,
    NullPointer = 2,
    InvalidMessage = 3,
    EncodeFailed = 4,
    Panic = 5,
};

pub const LazilyFfiMessageKind = enum(u32) {
    Unknown = 0,
    Snapshot = 1,
    Delta = 2,
};

pub const AllocatorMode = enum(u32) {
    /// High-performance system allocator (requires linking libc).
    c = 0,
    /// Modern Zig DebugAllocator (formerly GPA). Detects leaks/double-frees.
    debug = 1,
    /// Fast additive-only allocator. Best for one-shot batch tasks.
    arena = 2,
    /// Raw OS pages. Inefficient for many small objects.
    page = 3,
    /// Optimized for WebAssembly environments.
    wasm = 4,
    /// High-concurrency scaling for many-core servers.
    smp = 5,
};

pub const AllocatorState = union(enum) {
    debug: std.heap.DebugAllocator(.{ .thread_safe = build_options.thread_safe }),
    arena: std.heap.ArenaAllocator,
    smp: std.heap.SmpAllocator,
    none: void, // For stateless allocators like page, c, wasm
};

pub const FfiResult = extern struct {
    ptr: ?*anyopaque,
    error_code: u32,
    error_msg: [*:0]const u8,

    pub fn initError(error_code: u32, error_msg: [*:0]const u8) FfiResult {
        return .{
            .ptr = null,
            .error_code = error_code,
            .error_msg = error_msg,
        };
    }
    pub fn initSuccess(ptr: ?*anyopaque) FfiResult {
        return .{
            .ptr = ptr,
            .error_code = 0,
            .error_msg = "",
        };
    }
    pub fn isSuccess(self: FfiResult) bool {
        return self.error_code == 0;
    }
    pub fn isError(self: FfiResult) bool {
        return self.error_code != 0;
    }
    pub fn deinit(_: FfiResult) void {
        // No-op for now, as error_msg is a C string literal.
        // If error_msg were dynamically allocated, it would need to be freed here.
    }
};
