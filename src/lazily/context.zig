const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const FfiResult = @import("ffi.zig").FfiResult;
const AllocatorMode = @import("ffi.zig").AllocatorMode;
const AllocatorHandle = @import("ffi.zig").AllocatorHandle;

/// Version-agnostic graph mutex:
/// - Zig < 0.16 uses `std.Thread.Mutex` (a real parking mutex in the stdlib).
/// - Zig >= 0.16 uses the vendored `ParkingMutex` (`parking_mutex.zig`,
///   `#lzparkingmutex`). Zig 0.16 removed `std.Thread.Mutex` and pushed
///   synchronization onto the new `std.Io` runtime, which the lazily graph
///   lock cannot host portably. The previous fallback was a busy-wait
///   spinlock over `std.atomic.Mutex` — a high-load cliff under N-writer
///   contention. `ParkingMutex` parks contended threads via the Linux futex
///   syscall (and yields on other targets). See `parking_mutex.zig` and
///   BENCHMARKS.md § Thread-safe contention.
const GraphMutex = if (builtin.zig_version.minor < 16)
    std.Thread.Mutex
else
    @import("parking_mutex.zig").ParkingMutex;

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
    // `batch` boundary depth (0 == not batching). While > 0, `Cell.set` queues
    // the eager-recompute drain until the outermost `finishBatch` exit, so N
    // writes inside one `batch(run)` produce a single effect/Signal flush
    // (`lazily-spec/docs/reactive-graph.md` § batch, conformance clause #6).
    batch_depth: usize = 0,
    // Instrumentation counters (sync surface). Mirrors lazily-rs
    // `InstrumentationCounters` (`instrumentation.rs:66-97`). Always-on: 6 u64
    // fields, bumped under `mutex` (no extra atomics). Use
    // `instrumentationSnapshot()` / `resetInstrumentation()`.
    instrumentation: Instrumentation = .{},
    // Optional hook invoked AFTER `deinit` frees the Context struct, so it may
    // release a stateful allocator state that backed `allocator`. Used by the
    // FFI `init_context_with_mode` to own arena/debug/smp allocators. Native
    // callers leave these null (they own their allocator themselves).
    post_deinit_fn: ?*const fn (state: *anyopaque) void = null,
    post_deinit_state: ?*anyopaque = null,

    /// Copyable instrumentation snapshot. Fields mirror lazily-rs
    /// `InstrumentationCounters` (`instrumentation.rs:66-97`). Always-on: 6 u64
    /// fields, bumped under `mutex` (no extra atomics).
    pub const Instrumentation = struct {
        node_allocations: u64 = 0,
        slot_recomputes: u64 = 0,
        dependency_edges_added: u64 = 0,
        dependency_edges_removed: u64 = 0,
        effect_queue_pushes: u64 = 0,
        max_effect_queue_depth: u64 = 0,
    };

    pub fn instrumentationSnapshot(self: *Context) Instrumentation {
        return self.instrumentation;
    }

    pub fn resetInstrumentation(self: *Context) void {
        self.instrumentation = .{};
    }

    fn bump(self: *Context, comptime field: []const u8) void {
        @field(self.instrumentation, field) += 1;
    }

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

        // Capture the post-deinit hook before freeing self: `destroy(self)`
        // deallocates the Context struct via `allocator`, and the hook owns
        // (and may free) the stateful allocator state that backs `allocator`,
        // so it must run AFTER self is released. Locals stay valid across the
        // free because they live on the caller's stack, not in self.
        const post_fn = self.post_deinit_fn;
        const post_state = self.post_deinit_state;

        self.allocator.destroy(self);

        // post_state is non-null whenever post_fn is (the only setter,
        // init_context_with_mode, installs both together).
        if (post_fn) |f| f(post_state.?);
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

        // Track the high-water mark of the effect queue depth.
        if (@as(u64, @intCast(self.pending_recompute.items.len)) > self.instrumentation.max_effect_queue_depth) {
            self.instrumentation.max_effect_queue_depth = @intCast(self.pending_recompute.items.len);
        }

        self.draining_recompute = true;
        defer self.draining_recompute = false;

        while (self.pending_recompute.pop()) |slot| {
            slot.stale = false;
            if (slot.recompute) |recompute_fn| {
                self.instrumentation.slot_recomputes += 1;
                recompute_fn(slot);
            }
        }
    }

    /// True when inside a `batch(run)` boundary. `Cell.set` checks this to
    /// defer the eager-recompute drain to the outermost batch exit.
    pub fn isBatching(self: *const Context) bool {
        return self.batch_depth > 0;
    }

    /// Coalesce several `Cell.set` updates into one Signal/Effect flush at the
    /// outermost batch exit (`lazily-spec/docs/reactive-graph.md` § batch).
    ///
    /// Mutation is synchronous — `run`'s `Cell.set` calls commit their values
    /// and propagate invalidation to dependent slots immediately; only the
    /// eager-recompute flush (`drainPendingRecompute`) is deferred, so eager
    /// Signals and Effects rerun once at exit, not once per `set`.
    pub fn batch(
        self: *Context,
        comptime run: anytype,
    ) void {
        self.batch_depth += 1;
        defer self.finishBatch();
        run(self);
    }

    fn finishBatch(self: *Context) void {
        std.debug.assert(self.batch_depth > 0);
        self.batch_depth -= 1;
        if (self.batch_depth == 0) {
            // Outermost exit: flush coalesced eager recomputes.
            self.drainPendingRecompute();
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
        ctx.instrumentation.node_allocations += 1;
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
                .literal => switch (comptime Slot.PtrSize(T)) {
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
            .literal => switch (comptime Slot.PtrSize(T)) {
                .slice => blk: {
                    const slice_storage = payload.slice;
                    break :blk slice_storage.toSlice(T);
                },
                .one, .many, .c => @as(T, @ptrCast(@alignCast(payload.single_ptr))),
            },
            .indirect => @as(*T, @ptrCast(@alignCast(payload.single_ptr))),
        };
    }

    pub const GetPtrError = error{ LiteralHasNoPtr, SlotMissingPtr };

    pub fn getPtr(self: Slot, comptime T: type) GetPtrError!*T {
        const payload = if (self.storage) |storage| storage.payload else return error.SlotMissingPtr;
        return switch (comptime Mode(T)) {
            .literal => return error.LiteralHasNoPtr,
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
        self.ctx.bump("dependency_edges_added");
    }

    pub fn unsubscribeChange(self: *Slot, child: *Slot) void {
        self.ctx.mutex.lock();
        defer self.ctx.mutex.unlock();
        try self.unsubscribeChangeUnlocked(child);
    }

    pub fn unsubscribeChangeUnlocked(self: *Slot, child: *Slot) void {
        _ = self.change_subscribers.remove(child);
        _ = child.parents.remove(self);
        self.ctx.bump("dependency_edges_removed");
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

    pub const Modes = enum { literal, indirect };
    pub fn Mode(comptime T: type) Modes {
        const type_info = @typeInfo(T);
        const is_pointer = type_info == .pointer;
        // Storage strategy: .literal for pointers/slices, .indirect others
        return if (is_pointer) .literal else .indirect;
    }

    pub fn Result(comptime T: type) type {
        return switch (comptime Mode(T)) {
            .literal => T,
            .indirect => *T,
        };
    }

    pub fn PtrSize(comptime T: type) std.builtin.Type.Pointer.Size {
        return @typeInfo(Slot.Result(T)).pointer.size;
    }

    pub fn StorageKind(comptime T: type) enum { single_ptr, slice } {
        return switch (comptime Mode(T)) {
            .literal => switch (comptime PtrSize(T)) {
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
        /// - `.literal`: no allocation, returns the value as-is
        /// - `.indirect`: allocates `T` in `ctx.allocator` and returns `*T`
        pub fn toStoredType(comptime T: type, ctx: *Context, value: T) !Result(T) {
            return switch (comptime Mode(T)) {
                .literal => value,
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
            .literal => null,
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
    // Default allocator: c_allocator when libc is linked (max throughput /
    // multi-thread scaling / long-running-process stability), else raw pages.
    // Callers that want a different backing allocator (debug/arena/smp/c/page/
    // wasm) use `init_context_with_mode` instead.
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

/// FFI entry: create a Context backed by the requested `AllocatorMode`.
///
/// Stateless modes (page/wasm/c) resolve directly to an allocator with no
/// state to own. Stateful modes (debug/arena/smp) are hosted in an
/// `AllocatorHandle` (allocated by a stateless bootstrap allocator) and wired
/// as a Context post-deinit hook so the state is released only after the
/// Context struct has been freed.
export fn initContextWithMode(mode: AllocatorMode) FfiResult {
    if (statelessAllocatorFor(mode)) |a| {
        const ctx = Context.init(a) catch {
            return FfiResult.initError(
                @intFromError(error.OutOfMemory),
                "Failed to initialize Context",
            );
        };
        return FfiResult.initSuccess(ctx);
    }

    const handle = AllocatorHandle.create(mode) catch {
        return FfiResult.initError(
            @intFromError(error.OutOfMemory),
            "Failed to create allocator handle",
        );
    };
    const ctx = Context.init(handle.allocator()) catch {
        handle.destroy();
        return FfiResult.initError(
            @intFromError(error.OutOfMemory),
            "Failed to initialize Context",
        );
    };
    ctx.post_deinit_fn = AllocatorHandle.destroyFromHook;
    ctx.post_deinit_state = handle;
    return FfiResult.initSuccess(ctx);
}
comptime {
    @export(&initContextWithMode, .{ .name = "init_context_with_mode" });
}

/// Resolve a stateless `AllocatorMode` to its allocator, or null for stateful
/// modes. Comptime-guarded so libc/wasm-only allocators are never referenced
/// on targets that lack them.
fn statelessAllocatorFor(mode: AllocatorMode) ?std.mem.Allocator {
    const c_alloc: ?std.mem.Allocator = if (build_options.link_libc)
        std.heap.c_allocator
    else
        null;
    const is_wasm = builtin.target.cpu.arch == .wasm32 or
        builtin.target.cpu.arch == .wasm64;
    const wasm_alloc: ?std.mem.Allocator = if (is_wasm)
        std.heap.wasm_allocator
    else
        null;

    return switch (mode) {
        .page => std.heap.page_allocator,
        .smp => std.heap.smp_allocator,
        .c => c_alloc,
        .wasm => wasm_alloc,
        // Stateful modes own state via an AllocatorHandle instead.
        .debug, .arena => null,
    };
}

export fn deinitContext(ctx: *Context) void {
    ctx.deinit();
}
comptime {
    @export(&deinitContext, .{ .name = "deinit_context" });
}

test "lazily/context.Context: post-deinit hook fires after free" {
    const allocator = std.testing.allocator;
    const HookState = struct {
        var fired = std.atomic.Value(bool).init(false);
        fn hook(state: *anyopaque) void {
            _ = state;
            fired.store(true, .seq_cst);
        }
    };
    HookState.fired.store(false, .seq_cst);

    const ctx = try Context.init(allocator);
    ctx.post_deinit_fn = HookState.hook;
    ctx.post_deinit_state = @ptrCast(ctx);
    ctx.deinit();

    // Hook ran only after the Context struct was released.
    try std.testing.expect(HookState.fired.load(.seq_cst));
}

test "lazily/context.initContextWithMode: stateless page-backed context" {
    const result = initContextWithMode(.page);
    try std.testing.expect(result.isSuccess());
    const ctx: *Context = @ptrCast(@alignCast(result.ptr.?));
    // No post-deinit hook for stateless modes.
    try std.testing.expect(ctx.post_deinit_fn == null);

    const buf = try ctx.allocator.alloc(u8, 64);
    ctx.allocator.free(buf);

    deinitContext(ctx);
}

test "lazily/context.initContextWithMode: arena-backed context soak" {
    // iteration allocates the Context + cache through the arena, exercises the
    // backing allocator, then deinits (Context freed via arena, hook tears the
    // arena down only after).
    const iterations = 50;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const result = initContextWithMode(.arena);
        try std.testing.expect(result.isSuccess());
        const ctx: *Context = @ptrCast(@alignCast(result.ptr.?));
        try std.testing.expect(ctx.post_deinit_fn != null);

        const buf = try ctx.allocator.alloc(u8, 128);
        ctx.allocator.free(buf);

        deinitContext(ctx);
    }
}

test "lazily/context: instrumentation counters track allocations, edges, and recomputes" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const CellMod = @import("cell.zig");
    const sig_mod = @import("signal.zig");

    const getSource = struct {
        fn call(_: *Context) anyerror!u32 {
            return 0;
        }
    }.call;
    const source = try CellMod.cell(u32, ctx, getSource, null);

    const before = ctx.instrumentationSnapshot();
    // A signal that reads the cell establishes a dependency edge.
    const getDerived = struct {
        fn call(c: *Context) anyerror!u32 {
            const src = try CellMod.cell(u32, c, getSource, null);
            return src.get() + 1;
        }
    }.call;
    const sig = try sig_mod.signal(u32, ctx, getDerived, null);
    defer ctx.allocator.destroy(sig);
    const after_setup = ctx.instrumentationSnapshot();
    try std.testing.expect(after_setup.node_allocations > before.node_allocations);
    try std.testing.expect(after_setup.dependency_edges_added > before.dependency_edges_added);

    // Setting the source triggers an eager recompute (Signal).
    source.set(7);
    const after_set = ctx.instrumentationSnapshot();
    try std.testing.expect(after_set.slot_recomputes > after_setup.slot_recomputes);

    ctx.resetInstrumentation();
    try std.testing.expectEqual(@as(u64, 0), ctx.instrumentationSnapshot().node_allocations);
}
