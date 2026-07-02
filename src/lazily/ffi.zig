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
    CrdtSync = 3,
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
    none: void, // For stateless allocators like page, c, wasm, smp (singleton)
};

/// Stateless allocator used to host stateful `AllocatorHandle`s so their
/// state outlives the Context it backs (Context.deinit frees itself via the
/// stateful allocator before the handle is destroyed). Always valid.
pub fn bootstrapAllocator() std.mem.Allocator {
    return if (comptime build_options.link_libc)
        std.heap.c_allocator
    else
        std.heap.page_allocator;
}

/// Owns a stateful allocator state for the FFI `init_context_with_mode` path.
/// Allocated by `bootstrapAllocator()`; installed as a Context post-deinit hook
/// so it is torn down only after the Context struct has been freed.
pub const AllocatorHandle = struct {
    state: AllocatorState,
    bootstrap: std.mem.Allocator,

    pub fn create(mode: AllocatorMode) !*AllocatorHandle {
        const b = bootstrapAllocator();
        const handle = try b.create(AllocatorHandle);
        errdefer b.destroy(handle);
        handle.* = .{
            .state = initStateForMode(mode),
            .bootstrap = b,
        };
        return handle;
    }

    /// The allocator this handle exposes to the Context.
    pub fn allocator(self: *AllocatorHandle) std.mem.Allocator {
        return switch (self.state) {
            .debug => |*d| d.allocator(),
            .arena => |*a| a.allocator(),
            .none => bootstrapAllocator(),
        };
    }

    /// Hook-compatible destroyer (`fn(*anyopaque) void`); installed as
    /// `Context.post_deinit_fn` so the state is released after Context free.
    pub fn destroyFromHook(state: *anyopaque) void {
        const self: *AllocatorHandle = @ptrCast(@alignCast(state));
        self.destroy();
    }

    pub fn destroy(self: *AllocatorHandle) void {
        switch (self.state) {
            .debug => |*d| {
                _ = d.deinit();
            },
            .arena => |*a| a.deinit(),
            .none => {},
        }
        const b = self.bootstrap;
        b.destroy(self);
    }
};

/// Construct the stateful `AllocatorState` for a mode. Only call for stateful
/// modes (debug/arena); stateless modes (c/page/wasm/smp) are handled without
/// a handle.
fn initStateForMode(mode: AllocatorMode) AllocatorState {
    return switch (mode) {
        .debug => .{ .debug = std.heap.DebugAllocator(.{ .thread_safe = build_options.thread_safe }).init },
        .arena => .{ .arena = std.heap.ArenaAllocator.init(bootstrapAllocator()) },
        // Stateless modes never reach here (no handle is created for them),
        // but the switch must be exhaustive.
        .c, .page, .wasm, .smp => .{ .none = {} },
    };
}

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
