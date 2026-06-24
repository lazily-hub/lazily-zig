const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const FfiResult = @import("ffi.zig").FfiResult;

/// Version-agnostic Mutex: Zig < 0.16 uses std.Thread.Mutex;
/// Zig >= 0.16 uses a spinlock over std.atomic.Mutex (std.Thread.Mutex was removed).
const GraphMutex = if (builtin.zig_version.minor < 16)
    std.Thread.Mutex
else
    struct {
        inner: std.atomic.Mutex = .unlocked,
        pub fn lock(self: *@This()) void {
            while (!self.inner.tryLock()) {}
        }
        pub fn unlock(self: *@This()) void {
            self.inner.unlock();
        }
    };

/// Context with lazy cache
pub const Context = struct {
    allocator: std.mem.Allocator,
    // Function pointer -> cached result
    cache: std.AutoHashMap(usize, *Slot),
    // Use a real Mutex if thread_safe is true, otherwise use a "no-op" struct
    mutex: if (build_options.thread_safe) GraphMutex else struct {
        pub fn lock(_: *@This()) void {}
        pub fn unlock(_: *@This()) void {}
    } = .{},
    // Deferred-recompute queue for eager Signal slots. Drained outside the mutex
    // so user valueFn can re-acquire the mutex per-slot without deadlock.
    pending_recompute: std.ArrayList(*Slot),
    draining_recompute: bool = false,

    pub fn init(allocator: std.mem.Allocator) !*Context {
        const ctx = try allocator.create(Context);
        ctx.* = .{
            .allocator = allocator,
            .cache = std.AutoHashMap(
                usize,
                *Slot,
            ).init(allocator),
            .pending_recompute = if (builtin.zig_version.minor < 16) .{} else std.ArrayList(*Slot).empty,
        };
        return ctx;
    }

    pub fn deinit(self: *Context) void {
        self.mutex.lock();
        // The mutex is not unlocked due to this being deinit which deallocates self.

        var iter = self.cache.valueIterator();
        while (iter.next()) |ptr| {
            const context_slot = ptr.*;
            context_slot.destroyUnlocked(false);
        }
        self.cache.deinit();
        self.pending_recompute.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Get a Slot. Slot.destroy() will deinit and remove the Slot from the Context.cache.
    pub fn getSlot(self: *Context, fnc: anytype) ?*Slot {
        const cache_key = valueFnCacheKey(fnc);
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.cache.get(cache_key);
    }

    /// Drain the pending-recompute queue. Called outside the graph mutex so that
    /// each slot's `recompute` fn can re-lock per-op (user valueFn re-enters the
    /// graph via slot()/slotKeyed()). LIFO order (deepest-dependency-first).
    pub fn drainPendingRecompute(self: *Context) void {
        if (self.draining_recompute) return;
        if (self.pending_recompute.items.len == 0) return;

        self.draining_recompute = true;
        defer self.draining_recompute = false;

        while (self.pending_recompute.pop()) |slot| {
            slot.stale = false;
            if (slot.recompute) |recompute_fn| {
                recompute_fn(slot);
            }
        }
    }
};

pub fn Owned(comptime T: type) type {
    return struct {
        value: T,
        is_managed: bool,

        pub fn managed(value: T) @This() {
            return .{ .value = value, .is_managed = true };
        }

        pub fn literal(value: T) @This() {
            return .{ .value = value, .is_managed = false };
        }

        pub fn deinit(self: *@This(), ctx: *Context) void {
            if (!self.is_managed) return;

            const type_info = @typeInfo(T);
            if (type_info == .pointer) {
                ctx.allocator.free(self.value);
            } else if (type_info == .@"struct" and @hasDecl(T, "deinit")) {
                self.value.deinit(ctx);
            }
        }
    };
}

pub const String = []const u8;
pub const OwnedString = Owned(String);

pub fn valueFnCacheKey(valueFn: anytype) usize {
    const type_info = @typeInfo(@TypeOf(valueFn));

    return switch (type_info) {
        // If caller passes a function (not a pointer), take its address.
        .@"fn" => @intFromPtr(&valueFn),

        // If caller passes a function pointer, use it directly.
        .pointer => |p| blk: {
            if (@typeInfo(p.child) != .@"fn") {
                @compileError("Expected a function pointer");
            }
            break :blk @intFromPtr(valueFn);
        },

        else => @compileError("expected a function or function pointer"),
    };
}

pub const Slot = struct {
    ctx: *Context,
    value_fn_ptr: ?*anyopaque,
    cache_key: ?usize = null,
    storage: ?Storage,
    mode: Modes,
    /// Pointer classification for the cached value type (std.builtin.Type.Pointer.Size): .one, .many, .slice, .c
    ptr_size: std.builtin.Type.Pointer.Size,
    change_subscribers: std.AutoHashMap(*Slot, void),
    parents: std.AutoHashMap(*Slot, void),
    deinitPayload: ?*const fn (*Slot) void,
    free: ?*const fn (std.mem.Allocator, *anyopaque) void = null,
    // Eager-Signal hooks (default null = lazy/destroy-on-invalidate semantics).
    // on_invalidate: fired instead of destroyUnlocked when a dependency invalidates this slot.
    // recompute: type-erased re-materialize (re-run valueFn, memo guard, swap, emitChange).
    on_invalidate: ?*const fn (*Slot) void = null,
    recompute: ?*const fn (*Slot) void = null,
    stale: bool = false,

    pub fn init(
        comptime T: type,
        ctx: *Context,
        valueFn: *const ValueFn(T),
        deinitPayload: ?DeinitPayloadFn,
    ) !*@This() {
        return initKeyed(
            T,
            ctx,
            valueFnCacheKey(valueFn),
            valueFn,
            deinitPayload,
        );
    }

    pub fn initKeyed(
        comptime T: type,
        ctx: *Context,
        cache_key: usize,
        valueFn: *const ValueFn(T),
        deinitPayload: ?DeinitPayloadFn,
    ) !*@This() {
        const mode = comptime Mode(T);
        const ptr_size = comptime Slot.PtrSize(T);
        const free = comptime Free(T);
        const self = try ctx.allocator.create(Slot);
        self.* = Slot{
            .ctx = ctx,
            .value_fn_ptr = null,
            .cache_key = cache_key,
            .mode = mode,
            .storage = null,
            .ptr_size = ptr_size,
            .change_subscribers = std.AutoHashMap(
                *Slot,
                void,
            ).init(ctx.allocator),
            .parents = std.AutoHashMap(
                *Slot,
                void,
            ).init(ctx.allocator),
            .deinitPayload = deinitPayload,
            .free = if (mode == .indirect) free else null,
        };

        const current_slot: ?*Slot = currentSlotFor(ctx);
        if (current_slot) |child_slot| {
            try self.subscribeChange(child_slot);
            // try child_slot.subscribeChange(self);
        }

        var frame = TrackingFrame{
            .prev = null,
            .ctx = ctx,
            .slot = self,
        };
        pushTracking(&frame);
        defer popTracking(&frame);

        const value = try valueFn(ctx);
        const stored_value = try Storage.toStoredType(
            T,
            ctx,
            value,
        );
        self.value_fn_ptr = @ptrCast(@constCast(valueFn));

        self.storage = Storage.init(
            switch (comptime Mode(T)) {
                // TODO: Rename .direct to .literal
                .direct => switch (comptime Slot.PtrSize(T)) {
                    .slice => Slot.Storage.Payload{
                        .slice = SliceStorage.init(T, stored_value),
                    },
                    .one, .many, .c => Slot.Storage.Payload{
                        .single_ptr = @ptrCast(@constCast(stored_value)),
                    },
                },
                .indirect => Slot.Storage.Payload{
                    .single_ptr = @ptrCast(stored_value),
                },
            },
        );

        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        if (ctx.cache.get(cache_key)) |existing| {
            self.destroySelf(false);
            return existing;
        }

        try ctx.cache.put(cache_key, self);
        return self;
    }

    pub const GetError = error{SlotMissingPtr};

    pub fn get(self: Slot, comptime T: type) GetError!Result(T) {
        const payload = if (self.storage) |storage| blk: {
            break :blk storage.payload;
        } else {
            return error.SlotMissingPtr;
        };

        return switch (comptime Mode(T)) {
            .direct => switch (comptime Slot.PtrSize(T)) {
                .slice => blk: {
                    const slice_storage = payload.slice;
                    break :blk slice_storage.toSlice(T);
                },
                .one, .many, .c => @as(T, @ptrCast(@alignCast(payload.single_ptr))),
            },
            .indirect => @as(*T, @ptrCast(@alignCast(payload.single_ptr))),
        };
    }

    // TODO: Rename CannotGetPtrOfDirectMode to LiteralHasNoPtr
    pub const GetPtrError = error{ CannotGetPtrOfDirectMode, SlotMissingPtr };

    pub fn getPtr(self: Slot, comptime T: type) GetPtrError!*T {
        const payload = if (self.storage) |storage| storage.payload else return error.SlotMissingPtr;
        return switch (comptime Mode(T)) {
            .direct => return error.CannotGetPtrOfDirectMode,
            .indirect => @as(*T, @ptrCast(@alignCast(payload.single_ptr))),
        };
    }

    pub fn subscribeChange(self: *Slot, child: *Slot) !void {
        self.ctx.mutex.lock();
        defer self.ctx.mutex.unlock();
        try self.subscribeChangeUnlocked(child);
    }

    pub fn subscribeChangeUnlocked(self: *Slot, child: *Slot) !void {
        _ = try self.change_subscribers.getOrPut(child);
        _ = try child.parents.getOrPut(self);
    }

    pub fn unsubscribeChange(self: *Slot, child: *Slot) void {
        self.ctx.mutex.lock();
        defer self.ctx.mutex.unlock();
        try self.unsubscribeChangeUnlocked(child);
    }

    pub fn unsubscribeChangeUnlocked(self: *Slot, child: *Slot) void {
        _ = self.change_subscribers.remove(child);
        _ = child.parents.remove(self);
    }

    /// Thread-safe call to Slot.touchUnlocked.
    ///
    /// `ctx` is captured into a local BEFORE `touchUnlocked()` because the
    /// destroy path frees `self` (destroySelf → `allocator.destroy(self)`);
    /// the deferred unlock must not dereference freed `self.ctx`. This was a
    /// latent use-after-free that Zig 0.17's `std.atomic.Mutex.unlock()`
    /// assertion (`state == .locked`) turned into a hard crash.
    pub fn touch(self: *Slot) void {
        const ctx = self.ctx;
        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        self.touchUnlocked();
    }

    /// Slot.touchUnlocked expires self and expires all dependent Slots.
    /// See Slot.subscribeChange and Slot.emitChangeUnlocked.
    pub fn touchUnlocked(self: *Slot) void {
        self.destroyUnlocked(true);
    }

    /// Thread-safe call to Slot.emitChangeUnlocked.
    pub fn emitChange(self: *Slot) void {
        self.ctx.mutex.lock();
        self.emitChangeUnlocked();
        self.ctx.mutex.unlock();
        self.ctx.drainPendingRecompute();
    }

    /// Emits the change event to all change_subscribers. See Slot.subscribeChange.
    ///
    /// Dependents are snapshotted into an allocator-backed slice and the
    /// `change_subscribers` map is cleared BEFORE iterating, fixing the latent
    /// iteration-during-mutation bug (destroyUnlocked → unsubscribeChangeUnlocked
    /// previously removed entries from the map mid-iteration).
    ///
    /// For each dependent:
    /// - If `on_invalidate` is set (Signal-backed slot): call the hook (enqueue
    ///   for deferred recompute, mark stale). The slot is NOT destroyed.
    /// - Otherwise: `destroyUnlocked(true)` as before (lazy invalidate).
    pub fn emitChangeUnlocked(self: *Slot) void {
        const subscriber_count = self.change_subscribers.count();
        if (subscriber_count == 0) return;

        // Snapshot dependents to avoid iteration-during-mutation.
        const subscribers = self.ctx.allocator.alloc(*Slot, subscriber_count) catch return;
        defer self.ctx.allocator.free(subscribers);

        var i: usize = 0;
        var iter = self.change_subscribers.keyIterator();
        while (iter.next()) |ptr| {
            subscribers[i] = ptr.*;
            i += 1;
        }

        // Clear the map first — prevents nested unsubscribeChangeUnlocked from
        // mutating the map during iteration.
        self.change_subscribers.clearRetainingCapacity();

        for (subscribers) |dependent_slot| {
            // Clean up the parent edge on the dependent side.
            _ = dependent_slot.parents.remove(self);

            if (dependent_slot.on_invalidate) |hook| {
                // Signal-backed slot: enqueue for deferred recompute, do NOT destroy.
                hook(dependent_slot);
            } else {
                dependent_slot.destroyUnlocked(true);
            }
        }
    }

    pub fn destroy(self: *Slot, recurse: ?bool) void {
        // Capture ctx before destroyUnlocked: the destroy path frees `self`,
        // so the deferred unlock must not dereference freed `self.ctx`.
        const ctx = self.ctx;
        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        self.destroyUnlocked(recurse);
    }

    pub fn destroyUnlocked(self: *Slot, recurse: ?bool) void {
        // Remove from cache if not already cleared by Context.deinit
        if (self.cache_key) |cache_key| {
            _ = self.ctx.cache.remove(cache_key);
        } else {
            unreachable;
        }

        self.destroySelf(recurse);
    }

    /// Destroys the value and its subscribers recursively.
    /// Internal version: assumes ctx.mutex is ALREADY held.
    pub fn destroySelf(self: *Slot, recurse: ?bool) void {
        if (self.storage) |storage| {
            if (recurse == null or recurse == true) {
                var parents_iter = self.parents.keyIterator();
                while (parents_iter.next()) |ptr| {
                    const parent_slot = ptr.*;
                    parent_slot.unsubscribeChangeUnlocked(self);
                }

                var subscribers_iter = self.change_subscribers.keyIterator();
                while (subscribers_iter.next()) |ptr| {
                    const dependent_slot = ptr.*;
                    dependent_slot.destroyUnlocked(true);
                }
            }

            if (self.deinitPayload) |deinitPayload| {
                deinitPayload(self);
            }
            if (self.mode == .indirect) {
                if (self.free) |free_fn| {
                    free_fn(self.ctx.allocator, storage.payload.single_ptr);
                }
            } else if (self.ptr_size == .slice) {
                // Direct slices also need to be freed if they were allocated in toStoredType
                // However, toStoredType currently only allocates for .indirect.
                // If toStoredType is updated to dupe slices, this would be needed.
            }
            self.storage = null;
        }
        self.change_subscribers.deinit();
        self.parents.deinit();
        self.ctx.allocator.destroy(self);
    }

    pub const Modes = enum { direct, indirect };
    pub fn Mode(comptime T: type) Modes {
        const type_info = @typeInfo(T);
        const is_pointer = type_info == .pointer;
        // Storage strategy: .direct for pointers/slices, .indirect others
        return if (is_pointer) .direct else .indirect;
    }

    pub fn Result(comptime T: type) type {
        return switch (comptime Mode(T)) {
            .direct => T,
            .indirect => *T,
        };
    }

    pub fn PtrSize(comptime T: type) std.builtin.Type.Pointer.Size {
        return @typeInfo(Slot.Result(T)).pointer.size;
    }

    pub fn StorageKind(comptime T: type) enum { single_ptr, slice } {
        return switch (comptime Mode(T)) {
            .direct => switch (comptime PtrSize(T)) {
                .slice => .slice,
                .one, .many, .c => .single_ptr,
            },
            .indirect => .single_ptr,
        };
    }

    pub const Storage = struct {
        pub const Payload = union(enum) {
            single_ptr: *anyopaque,
            slice: SliceStorage,
        };

        payload: Payload,
        pub fn init(payload: Payload) Storage {
            return .{ .payload = payload };
        }

        /// Converts a computed value `T` into the storage representation `StoredType(T)`.
        /// - `.direct`: no allocation, returns the value as-is
        /// - `.indirect`: allocates `T` in `ctx.allocator` and returns `*T`
        pub fn toStoredType(comptime T: type, ctx: *Context, value: T) !Result(T) {
            return switch (comptime Mode(T)) {
                .direct => value,
                .indirect => blk: {
                    const stored_value = try ctx.allocator.create(T);
                    stored_value.* = value;
                    break :blk stored_value;
                },
            };
        }
    };

    /// Type-erased slice handler that works with any element type
    /// TODO: Is this needed with the addition of Owned?
    pub const SliceStorage = struct {
        ptr: *anyopaque,
        len: usize, // Number of elements (not bytes)
        mode: Slot.Modes,
        element_size: usize, // @sizeOf(T)
        free: *const fn (std.mem.Allocator, *anyopaque, usize, usize) void,

        /// Create a `SliceStorage` for any slice type
        pub fn init(comptime T: type, value: T) SliceStorage {
            const type_info = @typeInfo(T);
            if (type_info != .pointer) {
                @compileError("SliceStorage.init requires a pointer/slice type");
            }
            const element_type = type_info.pointer.child;

            return .{
                .ptr = @ptrCast(@constCast(value.ptr)),
                .len = value.len,
                .mode = Mode(element_type),
                .element_size = @sizeOf(element_type),
                .free = struct {
                    fn free(
                        allocator: std.mem.Allocator,
                        ptr: *anyopaque,
                        len: usize,
                        element_size: usize,
                    ) void {
                        _ = element_size; // For debugging/validation
                        const slice: T = @as([*]element_type, @ptrCast(@alignCast(ptr)))[0..len];
                        allocator.free(slice);
                    }
                }.free,
            };
        }

        /// Reconstruct the original slice type `T` from this storage.
        /// `T` must be a slice type (pointer size `.slice`), e.g. `[]u8`, `[]const u8`, `[]MyType`.
        pub fn toSlice(self: SliceStorage, comptime T: type) T {
            const type_info = @typeInfo(T);
            if (type_info != .pointer or type_info.pointer.size != .slice) {
                const message = std.fmt.comptimePrint(
                    "SliceStorage.unpack requires a slice type (e.g. []u8, []const u8). Got {}",
                    .{T},
                );
                @compileError(message);
            }

            const element_type = type_info.pointer.child;

            // Best-effort validation: helps catch mismatched T at runtime in Debug/ReleaseSafe.
            std.debug.assert(self.element_size == @sizeOf(element_type));

            return @as([*]element_type, @ptrCast(@alignCast(self.ptr)))[0..self.len];
        }
    };

    /// Create a free function that knows the type `T`
    pub fn Free(comptime T: type) ?*const fn (std.mem.Allocator, *anyopaque) void {
        return switch (comptime Slot.Mode(T)) {
            .direct => null,
            .indirect => struct {
                fn free(allocator: std.mem.Allocator, ptr: *anyopaque) void {
                    allocator.destroy(@as(*T, @ptrCast(@alignCast(ptr))));
                }
            }.free,
        };
    }

    pub fn DeinitValueFn(comptime T: type) type {
        return *const fn (*Context, *const ValueFn(T), T) void;
    }
    pub const DeinitPayloadFn = *const fn (*Slot) void;
};

pub fn ValueFn(comptime T: type) type {
    return fn (*Context) anyerror!T;
}

pub const SubscriberKey = struct {
    ctx_ptr: usize, // @intFromPtr(ctx) or 0 if null
    cb_ptr: usize, // @intFromPtr(callback)
};

pub fn subscriberKey(ctx: *Context, valueFn: anytype) SubscriberKey {
    return .{
        .ctx_ptr = @intFromPtr(ctx),
        .cb_ptr = @intFromPtr(valueFn),
    };
}

pub const SubscriberSet = std.AutoHashMap(SubscriberKey, void);

const SlotCallback = *const fn (ctx: *Context, slot: *Slot) void;

pub const TrackingFrame = struct {
    prev: ?*TrackingFrame,
    ctx: *Context,
    slot: *Slot,
};

/// The top of the stack for the CURRENT thread.
/// This stack may contain frames from different Contexts if they are interleaved.
threadlocal var tracking_top: ?*TrackingFrame = null;

pub fn pushTracking(frame: *TrackingFrame) void {
    frame.prev = tracking_top;
    tracking_top = frame;
}

pub fn popTracking(frame: *TrackingFrame) void {
    // Basic safety check
    if (tracking_top == frame) {
        tracking_top = frame.prev;
    }
}

/// Finds the most recent slot being computed for the given context ON THIS THREAD.
pub fn currentSlotFor(ctx: *Context) ?*Slot {
    var it = tracking_top;
    while (it) |f| : (it = f.prev) {
        if (f.ctx == ctx) return f.slot;
    }
    return null;
}

export fn initContext() FfiResult {
    // TODO: Option to use c_allocator.
    // - Max throughput
    // - Multi-thread scaling
    // - Long running process stability
    // TODO: Option to use ArenaAllocator
    // - Purely Additive Caching (Immutable Graphs)
    // - Batch Jobs
    const allocator = if (comptime build_options.link_libc)
        std.heap.c_allocator
    else
        std.heap.page_allocator;

    const ctx = Context.init(allocator) catch |err| {
        return FfiResult.initError(
            @intFromError(err),
            "Failed to initialize Context",
        );
    };

    return FfiResult.initSuccess(ctx);
}
comptime {
    @export(&initContext, .{ .name = "init_context" });
}

export fn deinitContext(ctx: *Context) void {
    ctx.deinit();
}
comptime {
    @export(&deinitContext, .{ .name = "deinit_context" });
}
