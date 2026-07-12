//! Cross-process zero-copy transport — pluggable blob backends (`#lzzcpy`).
//!
//! Spec:   ../../../lazily-spec/docs/zero-copy-transport.md
//! Formal: ../../../lazily-formal/LazilyFormal/ZeroCopyTransport.lean
//! Rust reference: ../../../lazily-rs/src/transport.rs
//! Go reference:   ../../../lazily-go/transport.go, transport_shm.go
//!
//! A large `Snapshot` / `Delta` / `CrdtSync` payload is not copied through the
//! wire codec. The producer **spills** it to a blob backend (the backend mints a
//! `ShmBlobRef` descriptor) and ships only the descriptor; the receiver
//! **resolves** the descriptor against the same backend and reads the bytes in
//! place — zero copy. `BlobBackend` is the adapter seam:
//!
//!   - `InProcessBackend` wraps a `ShmBlobArena` — single address space (the FFI
//!     host / a binding loaded in the same process, an editor plugin).
//!   - `ArrowBackend` holds Apache Arrow IPC stream bytes — the descriptor's
//!     bytes *are* an Arrow IPC stream a columnar consumer imports zero-copy
//!     (bring your own Arrow reader around the resolved `[]const u8`).
//!   - `ShmBackend` (Linux) is a POSIX `shm_open` + `mmap` region — the genuine
//!     cross-process backend (same host).
//!
//! Because the formal laws (spill-then-resolve identity, backend isolation, ABA
//! generation safety, checksum integrity) are stated only over a backend's
//! issued-blob table, they hold uniformly for every backend that maintains the
//! `BlobBackend` contract.

const std = @import("std");
const builtin = @import("builtin");
const ipc = @import("./ipc.zig");

const ShmBlobRef = ipc.ShmBlobRef;
const ShmBlobArena = ipc.ShmBlobArena;
const ShmBlobArenaError = ipc.ShmBlobArenaError;
const BlobBackendKind = ipc.BlobBackendKind;
const IpcValue = ipc.IpcValue;
const NodeState = ipc.NodeState;
const IpcMessage = ipc.IpcMessage;
const NodeSnapshot = ipc.NodeSnapshot;
const DeltaOp = ipc.DeltaOp;
const CrdtOp = ipc.CrdtOp;

/// A zero-copy view into a backend's resolved bytes.
///
/// `null` (not `&.{}`) when the descriptor did not resolve (unknown /
/// stale-generation / corrupt-checksum / wrong-backend). An empty payload that
/// resolves correctly is a non-null zero-length slice.
pub const BlobView = ?[]const u8;

/// Default byte size at or above which the `spill*` helpers spill an inline
/// payload to a backend. A deployment knob, not a protocol constant: payloads
/// below the threshold stay inline (copying a tiny value through the codec is
/// cheaper than a backend round-trip).
pub const default_spill_threshold: usize = 512;

/// The adapter seam: a backend mints descriptors via `write` and resolves them
/// zero-copy via `readView`. Modeled as an explicit vtable so a `BlobRouter` can
/// hold heterogeneous backends (Zig has no trait objects).
///
/// Entries are immutable + stable-addressed for any descriptor's lifetime, so
/// the transport laws (`resolve_write` identity, backend isolation, ABA
/// generation safety, checksum rejection) hold for every backend by construction.
pub const BlobBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        kind: *const fn (ptr: *anyopaque) BlobBackendKind,
        write: *const fn (ptr: *anyopaque, bytes: []const u8) ShmBlobArenaError!ShmBlobRef,
        readView: *const fn (ptr: *anyopaque, descriptor: ShmBlobRef) BlobView,
        advanceEpoch: *const fn (ptr: *anyopaque) void,
    };

    /// Which backend discriminator this adapter serves.
    pub fn kind(self: BlobBackend) BlobBackendKind {
        return self.vtable.kind(self.ptr);
    }

    /// Mint a fresh descriptor for `bytes`: store them immutably and return a
    /// descriptor whose checksum is the bytes' FNV-1a-64, tagged with this
    /// backend's kind.
    pub fn write(self: BlobBackend, bytes: []const u8) ShmBlobArenaError!ShmBlobRef {
        return self.vtable.write(self.ptr, bytes);
    }

    /// Resolve `descriptor` zero-copy — return the stored bytes iff
    /// `generation + epoch + len + checksum` all match; `null` otherwise. No
    /// copy, no checksum recompute.
    pub fn readView(self: BlobBackend, descriptor: ShmBlobRef) BlobView {
        return self.vtable.readView(self.ptr, descriptor);
    }

    /// Advance the validity epoch. Descriptors minted before an epoch advance no
    /// longer resolve (models compaction / restart).
    pub fn advanceEpoch(self: BlobBackend) void {
        self.vtable.advanceEpoch(self.ptr);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// InProcessBackend — wraps a ShmBlobArena (single address space).
// ─────────────────────────────────────────────────────────────────────────────

/// Default backing capacity (1 MiB).
pub const in_process_default_capacity: usize = 1 << 20;

/// In-process backend: wraps a `ShmBlobArena` for the single-address-space case
/// (the FFI host ↔ a same-process binding, an editor plugin). Descriptors carry
/// `backend = .in_process`. For a genuine cross-process store, spill to a
/// `ShmBackend` (Linux) instead.
pub const InProcessBackend = struct {
    arena: ShmBlobArena,
    epoch: u64 = 0,

    /// Create an in-process backend with the default 1 MiB capacity.
    pub fn init(allocator: std.mem.Allocator) (ShmBlobArenaError || error{OutOfMemory})!InProcessBackend {
        return initCapacity(allocator, in_process_default_capacity);
    }

    /// Create an in-process backend backed by a `capacity`-byte arena.
    pub fn initCapacity(
        allocator: std.mem.Allocator,
        capacity: usize,
    ) (ShmBlobArenaError || error{OutOfMemory})!InProcessBackend {
        return .{ .arena = try ShmBlobArena.withCapacity(allocator, capacity) };
    }

    /// Wrap an existing arena at epoch 0. The arena is moved in; the backend
    /// owns it iff the arena did.
    pub fn fromArena(arena: ShmBlobArena) InProcessBackend {
        return .{ .arena = arena };
    }

    pub fn deinit(self: *InProcessBackend) void {
        self.arena.deinit();
    }

    /// The vtable-erased backend handle. Borrows `self`; `self` must outlive it.
    pub fn backend(self: *InProcessBackend) BlobBackend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn vtKind(_: *anyopaque) BlobBackendKind {
        return .in_process;
    }
    fn vtWrite(ptr: *anyopaque, bytes: []const u8) ShmBlobArenaError!ShmBlobRef {
        const self: *InProcessBackend = @ptrCast(@alignCast(ptr));
        var descriptor = try self.arena.writeBlob(self.epoch, bytes);
        descriptor.backend = .in_process;
        return descriptor;
    }
    fn vtReadView(ptr: *anyopaque, descriptor: ShmBlobRef) BlobView {
        const self: *InProcessBackend = @ptrCast(@alignCast(ptr));
        // Immediate epoch invalidation: a descriptor minted before an epoch
        // advance does not resolve even if its slot bytes are still intact.
        if (descriptor.epoch != self.epoch) return null;
        return self.arena.readBlob(descriptor) catch null;
    }
    fn vtAdvanceEpoch(ptr: *anyopaque) void {
        const self: *InProcessBackend = @ptrCast(@alignCast(ptr));
        self.epoch +|= 1;
    }

    const vtable = BlobBackend.VTable{
        .kind = vtKind,
        .write = vtWrite,
        .readView = vtReadView,
        .advanceEpoch = vtAdvanceEpoch,
    };
};

// ─────────────────────────────────────────────────────────────────────────────
// ArrowBackend — holds Apache Arrow IPC stream bytes (bring your own arrow).
// ─────────────────────────────────────────────────────────────────────────────

/// Default Arrow backing capacity (4 MiB — analytics payloads tend to be larger).
pub const arrow_default_capacity: usize = 1 << 22;

/// Apache Arrow blob backend: holds spilled payloads as Arrow IPC stream bytes
/// and resolves a descriptor to the buffer's raw bytes with no copy. The
/// descriptor's bytes *are* an Arrow IPC stream — a columnar consumer imports
/// them as an `Array` / `RecordBatch` zero-copy. Descriptors carry
/// `backend = .arrow`.
///
/// Because Arrow's IPC format is zero-copy over a shared buffer, `shm` and
/// `arrow` compose: an Arrow batch can live in a `ShmBackend` region and be
/// resolved by either backend. New backends (RDMA/verbs, CUDA IPC) plug in by
/// implementing `BlobBackend` and adding a `BlobBackendKind` value.
pub const ArrowBackend = struct {
    arena: ShmBlobArena,
    epoch: u64 = 0,

    /// Create an Arrow backend with the default 4 MiB capacity.
    pub fn init(allocator: std.mem.Allocator) (ShmBlobArenaError || error{OutOfMemory})!ArrowBackend {
        return initCapacity(allocator, arrow_default_capacity);
    }

    /// Create an Arrow backend backed by a `capacity`-byte arena.
    pub fn initCapacity(
        allocator: std.mem.Allocator,
        capacity: usize,
    ) (ShmBlobArenaError || error{OutOfMemory})!ArrowBackend {
        return .{ .arena = try ShmBlobArena.withCapacity(allocator, capacity) };
    }

    pub fn deinit(self: *ArrowBackend) void {
        self.arena.deinit();
    }

    /// The vtable-erased backend handle. Borrows `self`; `self` must outlive it.
    pub fn backend(self: *ArrowBackend) BlobBackend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn vtKind(_: *anyopaque) BlobBackendKind {
        return .arrow;
    }
    fn vtWrite(ptr: *anyopaque, bytes: []const u8) ShmBlobArenaError!ShmBlobRef {
        const self: *ArrowBackend = @ptrCast(@alignCast(ptr));
        var descriptor = try self.arena.writeBlob(self.epoch, bytes);
        descriptor.backend = .arrow;
        return descriptor;
    }
    fn vtReadView(ptr: *anyopaque, descriptor: ShmBlobRef) BlobView {
        const self: *ArrowBackend = @ptrCast(@alignCast(ptr));
        if (descriptor.epoch != self.epoch) return null;
        return self.arena.readBlob(descriptor) catch null;
    }
    fn vtAdvanceEpoch(ptr: *anyopaque) void {
        const self: *ArrowBackend = @ptrCast(@alignCast(ptr));
        self.epoch +|= 1;
    }

    const vtable = BlobBackend.VTable{
        .kind = vtKind,
        .write = vtWrite,
        .readView = vtReadView,
        .advanceEpoch = vtAdvanceEpoch,
    };
};

// ─────────────────────────────────────────────────────────────────────────────
// ShmBackend — POSIX shared-memory backend (Linux). The genuine cross-process
// backend: a distinct process opens the same named region and resolves a
// descriptor zero-copy against its own mapping. Rust/Go references: the `shm`
// module in transport.rs / transport_shm.go.
// ─────────────────────────────────────────────────────────────────────────────

pub const ShmBackendError = error{
    CapacityTooSmall,
    BlobTooLarge,
    BadMagic,
    BackendIo,
};

const shm_magic: u64 = 0x4c5a_5348_424c_4f42; // "LZSHBLOB"
const shm_header_len: usize = 40; // magic, capacity, bump, generation, epoch (5 × u64)
const shm_slot_len: usize = 24; // per-slot header: generation, len, checksum (3 × u64)
const shm_off_magic: usize = 0;
const shm_off_capacity: usize = 8;
const shm_off_bump: usize = 16;
const shm_off_generation: usize = 24;
const shm_off_epoch: usize = 32;

/// POSIX shared-memory blob backend, backed by a named `/dev/shm` region mapped
/// `MAP_SHARED`. A fixed-capacity `shm_open` + `mmap` region with an atomic bump
/// allocator: the header counters (bump / generation / epoch) live inside the
/// mapped region and are advanced with address-free atomics, so concurrent
/// multi-writer use across mappings is lock-free. Entries are immutable once
/// published (write never rewrites a slot), satisfying the `BlobBackend`
/// stable-address contract.
///
/// Limitations: no reclamation (bumps until capacity, then `BlobTooLarge`);
/// Linux only. A managed region with reclamation plugs in behind the same
/// `BlobBackend` interface.
pub const ShmBackend = struct {
    fd: std.posix.fd_t,
    region: []align(std.heap.page_size_min) u8,

    // A POSIX shm object is a file under `/dev/shm/<name>`; the low-level
    // `std.os.linux` syscall wrappers are used directly (the higher-level
    // `std.posix`/`std.fs` file API surface has drifted across Zig dev builds,
    // but the raw linux syscalls are stable). mmap/munmap still come from
    // `std.posix`, which is the portable seam.
    fn shmPathZ(allocator: std.mem.Allocator, name: []const u8) ![:0]u8 {
        var start: usize = 0;
        while (start < name.len and name[start] == '/') start += 1;
        return std.fmt.allocPrintSentinel(allocator, "/dev/shm/{s}", .{name[start..]}, 0);
    }

    fn headerPtr(region: []u8, off: usize) *std.atomic.Value(u64) {
        return @ptrCast(@alignCast(region.ptr + off));
    }

    fn sysOpen(pathz: [*:0]const u8, create_flag: bool) ShmBackendError!std.posix.fd_t {
        const flags: std.os.linux.O = if (create_flag)
            .{ .ACCMODE = .RDWR, .CREAT = true }
        else
            .{ .ACCMODE = .RDWR };
        const rc = std.os.linux.open(pathz, flags, 0o600);
        return switch (std.posix.errno(rc)) {
            .SUCCESS => @intCast(rc),
            else => error.BackendIo,
        };
    }

    fn mapShared(fd: std.posix.fd_t, len: usize) ShmBackendError![]align(std.heap.page_size_min) u8 {
        return std.posix.mmap(
            null,
            len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        ) catch error.BackendIo;
    }

    /// Create (or truncate) a named POSIX shared-memory region of `cap` bytes and
    /// map it `MAP_SHARED`. The caller owns unlink timing — call `unlink(name)`
    /// once no further readers/writers remain.
    pub fn create(allocator: std.mem.Allocator, name: []const u8, cap: usize) ShmBackendError!ShmBackend {
        if (cap <= shm_header_len + shm_slot_len) return error.CapacityTooSmall;
        const pathz = shmPathZ(allocator, name) catch return error.BackendIo;
        defer allocator.free(pathz);
        const fd = try sysOpen(pathz.ptr, true);
        errdefer _ = std.os.linux.close(fd);
        if (std.posix.errno(std.os.linux.ftruncate(fd, @intCast(cap))) != .SUCCESS) {
            return error.BackendIo;
        }
        const region = try mapShared(fd, cap);
        headerPtr(region, shm_off_magic).store(shm_magic, .seq_cst);
        headerPtr(region, shm_off_capacity).store(cap, .seq_cst);
        headerPtr(region, shm_off_bump).store(shm_header_len, .seq_cst);
        headerPtr(region, shm_off_generation).store(0, .seq_cst);
        headerPtr(region, shm_off_epoch).store(0, .seq_cst);
        return .{ .fd = fd, .region = region };
    }

    /// Open (without creating) an existing named region and map it at the
    /// capacity recorded in its header. A distinct process uses this to resolve
    /// descriptors minted by the creator.
    pub fn open(allocator: std.mem.Allocator, name: []const u8) ShmBackendError!ShmBackend {
        const pathz = shmPathZ(allocator, name) catch return error.BackendIo;
        defer allocator.free(pathz);
        const fd = try sysOpen(pathz.ptr, false);
        errdefer _ = std.os.linux.close(fd);
        // Map the header first to read the real capacity, then map the whole region.
        const probe = try mapShared(fd, shm_header_len);
        const magic = headerPtr(probe, shm_off_magic).load(.seq_cst);
        const cap: usize = @intCast(headerPtr(probe, shm_off_capacity).load(.seq_cst));
        std.posix.munmap(probe);
        if (magic != shm_magic) return error.BadMagic;
        if (cap <= shm_header_len) return error.CapacityTooSmall;
        const region = try mapShared(fd, cap);
        return .{ .fd = fd, .region = region };
    }

    /// Remove the named region so it is reclaimed once all mappings unmap.
    pub fn unlink(allocator: std.mem.Allocator, name: []const u8) void {
        const pathz = shmPathZ(allocator, name) catch return;
        defer allocator.free(pathz);
        _ = std.os.linux.unlink(pathz.ptr);
    }

    /// Unmap the region and close the descriptor. Does not unlink the name.
    pub fn deinit(self: *ShmBackend) void {
        if (self.region.len != 0) {
            std.posix.munmap(self.region);
            self.region = self.region[0..0];
        }
        if (self.fd >= 0) {
            _ = std.os.linux.close(self.fd);
            self.fd = -1;
        }
    }

    pub fn capacity(self: *const ShmBackend) usize {
        return self.region.len;
    }

    pub fn epoch(self: *const ShmBackend) u64 {
        return headerPtr(@constCast(self.region), shm_off_epoch).load(.seq_cst);
    }

    /// The vtable-erased backend handle. Borrows `self`; `self` must outlive it.
    pub fn backend(self: *ShmBackend) BlobBackend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn vtKind(_: *anyopaque) BlobBackendKind {
        return .shm;
    }
    fn vtWrite(ptr: *anyopaque, bytes: []const u8) ShmBlobArenaError!ShmBlobRef {
        const self: *ShmBackend = @ptrCast(@alignCast(ptr));
        const need = shm_slot_len + bytes.len;
        const bump = headerPtr(self.region, shm_off_bump);
        const off: usize = @intCast(bump.fetchAdd(need, .seq_cst));
        if (off + need > self.region.len) {
            // Roll the bump back so a later smaller write can still succeed.
            _ = bump.fetchSub(need, .seq_cst);
            return error.BlobTooLarge;
        }
        const generation = headerPtr(self.region, shm_off_generation).fetchAdd(1, .seq_cst) + 1;
        const ep = headerPtr(self.region, shm_off_epoch).load(.seq_cst);
        const csum = ipc.checksumFnv(bytes);
        const slot = self.region[off .. off + shm_slot_len];
        std.mem.writeInt(u64, slot[0..8], generation, .little);
        std.mem.writeInt(u64, slot[8..16], @intCast(bytes.len), .little);
        std.mem.writeInt(u64, slot[16..24], csum, .little);
        @memcpy(self.region[off + shm_slot_len .. off + shm_slot_len + bytes.len], bytes);
        return .{
            .offset = @intCast(off + shm_slot_len),
            .len = @intCast(bytes.len),
            .generation = generation,
            .epoch = ep,
            .checksum = csum,
            .backend = .shm,
        };
    }
    fn vtReadView(ptr: *anyopaque, descriptor: ShmBlobRef) BlobView {
        const self: *ShmBackend = @ptrCast(@alignCast(ptr));
        const off: usize = @intCast(descriptor.offset);
        const len: usize = @intCast(descriptor.len);
        if (off < shm_slot_len) return null;
        const slot_off = off - shm_slot_len;
        if (slot_off < shm_header_len or off + len > self.region.len) return null;
        const slot = self.region[slot_off..off];
        if (std.mem.readInt(u64, slot[0..8], .little) != descriptor.generation) return null;
        if (std.mem.readInt(u64, slot[8..16], .little) != descriptor.len) return null;
        if (std.mem.readInt(u64, slot[16..24], .little) != descriptor.checksum) return null;
        if (headerPtr(self.region, shm_off_epoch).load(.seq_cst) != descriptor.epoch) return null;
        return self.region[off .. off + len];
    }
    fn vtAdvanceEpoch(ptr: *anyopaque) void {
        const self: *ShmBackend = @ptrCast(@alignCast(ptr));
        _ = headerPtr(self.region, shm_off_epoch).fetchAdd(1, .seq_cst);
    }

    const vtable = BlobBackend.VTable{
        .kind = vtKind,
        .write = vtWrite,
        .readView = vtReadView,
        .advanceEpoch = vtAdvanceEpoch,
    };
};

// ─────────────────────────────────────────────────────────────────────────────
// Spill policy: replace large Inline payloads with a SharedBlob descriptor.
// ─────────────────────────────────────────────────────────────────────────────

/// The outcome of spilling a single value: the (possibly rewritten) value and
/// the number of bytes spilled (`0` if left inline).
pub fn SpillOne(comptime T: type) type {
    return struct { value: T, spilled: usize };
}

/// If `value` is `Inline` and `>= threshold` bytes, write it to `backend` and
/// return a `SharedBlob` descriptor value plus the bytes spilled. Otherwise
/// return the value unchanged and `0`. A backend write failure leaves the value
/// inline (returns `0`). Payloads below the threshold stay inline — cheaper than
/// a backend round-trip for tiny values.
pub fn spillValue(value: IpcValue, backend: BlobBackend, threshold: usize) SpillOne(IpcValue) {
    switch (value) {
        .Inline => |bytes| {
            if (bytes.len < threshold) return .{ .value = value, .spilled = 0 };
            const descriptor = backend.write(bytes) catch return .{ .value = value, .spilled = 0 };
            return .{ .value = IpcValue.sharedBlob(descriptor), .spilled = bytes.len };
        },
        else => return .{ .value = value, .spilled = 0 },
    }
}

/// Spill a `NodeState.Payload` above `threshold` to a `SharedBlob` descriptor.
pub fn spillState(state: NodeState, backend: BlobBackend, threshold: usize) SpillOne(NodeState) {
    switch (state) {
        .Payload => |bytes| {
            if (bytes.len < threshold) return .{ .value = state, .spilled = 0 };
            const descriptor = backend.write(bytes) catch return .{ .value = state, .spilled = 0 };
            return .{ .value = NodeState.sharedBlob(descriptor), .spilled = bytes.len };
        },
        else => return .{ .value = state, .spilled = 0 },
    }
}

/// A message whose oversized payloads have been replaced by `SharedBlob`
/// descriptors, plus the total bytes spilled. The returned message owns a fresh
/// op/node array (`deinit` frees it); every other substructure is shared with
/// the input, which is left unmutated.
pub const SpilledMessage = struct {
    message: IpcMessage,
    spilled: usize,
    allocator: std.mem.Allocator,
    owns: bool = true, // whether the op/node array below was freshly allocated

    /// Free the freshly-allocated op/node array (the correctly-typed slice on the
    /// returned message). Every other substructure is shared with the input and
    /// is not freed here.
    pub fn deinit(self: *SpilledMessage) void {
        if (!self.owns) return;
        switch (self.message) {
            .Snapshot => |s| self.allocator.free(s.nodes),
            .Delta => |d| self.allocator.free(d.ops),
            .CrdtSync => |c| self.allocator.free(c.ops),
            // Reliable-sync control frames carry no node content — nothing owned.
            .ResyncRequest, .OutboxAck => {},
        }
        self.owns = false;
    }
};

/// Spill large payloads across an `IpcMessage`'s value/state sites — `Snapshot`
/// node states, `Delta` `CellSet`/`SlotValue` payloads + `NodeAdd` states, and
/// `CrdtSync` op states. The message stays small on the wire; sites already
/// carrying a descriptor are left untouched. The input is not mutated; the
/// returned message shares unspilled substructure and owns one fresh array (free
/// via `SpilledMessage.deinit`).
pub fn spillMessage(
    allocator: std.mem.Allocator,
    message: IpcMessage,
    backend: BlobBackend,
    threshold: usize,
) error{OutOfMemory}!SpilledMessage {
    var total: usize = 0;
    switch (message) {
        .Snapshot => |snap| {
            const nodes = try allocator.dupe(NodeSnapshot, snap.nodes);
            for (nodes) |*node| {
                const r = spillState(node.state, backend, threshold);
                node.state = r.value;
                total += r.spilled;
            }
            var out = snap;
            out.nodes = nodes;
            return .{
                .message = .{ .Snapshot = out },
                .spilled = total,
                .allocator = allocator,
            };
        },
        .Delta => |delta| {
            const ops = try allocator.dupe(DeltaOp, delta.ops);
            for (ops) |*op| {
                switch (op.*) {
                    .CellSet => |*v| {
                        const r = spillValue(v.payload, backend, threshold);
                        v.payload = r.value;
                        total += r.spilled;
                    },
                    .SlotValue => |*v| {
                        const r = spillValue(v.payload, backend, threshold);
                        v.payload = r.value;
                        total += r.spilled;
                    },
                    .NodeAdd => |*v| {
                        const r = spillState(v.state, backend, threshold);
                        v.state = r.value;
                        total += r.spilled;
                    },
                    else => {},
                }
            }
            var out = delta;
            out.ops = ops;
            return .{
                .message = .{ .Delta = out },
                .spilled = total,
                .allocator = allocator,
            };
        },
        .CrdtSync => |sync| {
            const ops = try allocator.dupe(CrdtOp, sync.ops);
            for (ops) |*op| {
                const r = spillValue(op.state, backend, threshold);
                op.state = r.value;
                total += r.spilled;
            }
            var out = sync;
            out.ops = ops;
            return .{
                .message = .{ .CrdtSync = out },
                .spilled = total,
                .allocator = allocator,
            };
        },
        // Reliable-sync control frames have no value/state sites: spilling is the
        // identity. Return the message as-is, owning nothing.
        .ResyncRequest, .OutboxAck => return .{
            .message = message,
            .spilled = 0,
            .allocator = allocator,
            .owns = false,
        },
    }
}

/// Resolve an `IpcValue` against a single backend: `Inline` bytes are returned
/// directly, a `SharedBlob` is resolved zero-copy against `backend`. `null` when
/// a `SharedBlob` fails to resolve (unknown / stale / corrupt).
pub fn resolveValue(value: IpcValue, backend: BlobBackend) BlobView {
    return switch (value) {
        .Inline => |bytes| bytes,
        .SharedBlob => |descriptor| backend.readView(descriptor),
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// BlobRouter — receiver-side multi-backend resolver.
// ─────────────────────────────────────────────────────────────────────────────

/// Receiver-side multi-backend resolver. Holds backends by `BlobBackendKind` and
/// resolves any descriptor by its `backend` discriminator — a `shm` descriptor
/// routes to the shm backend, an `arrow` descriptor to the arrow backend, etc.
/// This is the `resolve_wrong_backend` theorem in practice: a descriptor never
/// resolves against a backend of the wrong kind (an unregistered kind resolves
/// to `null`).
pub const BlobRouter = struct {
    backends: [3]?BlobBackend = .{ null, null, null },

    pub fn init() BlobRouter {
        return .{};
    }

    /// Install `backend` for its kind, replacing any previously-registered
    /// backend of the same kind. Returns `self` for chaining.
    pub fn register(self: *BlobRouter, backend: BlobBackend) *BlobRouter {
        self.backends[backend.kind().routerIndex()] = backend;
        return self;
    }

    /// Resolve a descriptor by routing to its `backend` kind. `null` if no
    /// backend is registered for this kind, or the descriptor did not resolve.
    pub fn readView(self: *const BlobRouter, descriptor: ShmBlobRef) BlobView {
        const backend = self.backends[descriptor.backend.routerIndex()] orelse return null;
        return backend.readView(descriptor);
    }

    /// Resolve an `IpcValue`: `Inline` bytes returned directly, a `SharedBlob`
    /// routed by its `backend` discriminator and resolved zero-copy.
    pub fn resolve(self: *const BlobRouter, value: IpcValue) BlobView {
        return switch (value) {
            .Inline => |bytes| bytes,
            .SharedBlob => |descriptor| self.readView(descriptor),
        };
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests — the backend-agnostic transport invariants proven in
// lazily-formal/LazilyFormal/ZeroCopyTransport.lean.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn viewEql(view: BlobView, expected: []const u8) bool {
    return if (view) |b| std.mem.eql(u8, b, expected) else false;
}

test "transport: resolve_write identity — spilled bytes resolve zero-copy" {
    var b = try InProcessBackend.initCapacity(testing.allocator, 4096);
    defer b.deinit();
    const backend = b.backend();

    const payload = "the quick brown fox jumps over the lazy dog";
    const value = spillValue(IpcValue.fromInline(payload), backend, 8);
    try testing.expect(value.spilled == payload.len);
    try testing.expect(value.value == .SharedBlob);
    try testing.expectEqual(BlobBackendKind.in_process, value.value.SharedBlob.backend);

    // resolve returns the backend's own bytes — no copy, no recompute.
    try testing.expect(viewEql(resolveValue(value.value, backend), payload));
}

test "transport: below-threshold payloads stay inline" {
    var b = try InProcessBackend.initCapacity(testing.allocator, 4096);
    defer b.deinit();
    const backend = b.backend();

    const value = spillValue(IpcValue.fromInline("tiny"), backend, 512);
    try testing.expectEqual(@as(usize, 0), value.spilled);
    try testing.expect(value.value == .Inline);
    try testing.expect(viewEql(resolveValue(value.value, backend), "tiny"));
}

test "transport: resolve_wrong_backend — router routes by kind" {
    var inproc = try InProcessBackend.initCapacity(testing.allocator, 4096);
    defer inproc.deinit();
    var arrow = try ArrowBackend.initCapacity(testing.allocator, 4096);
    defer arrow.deinit();

    var router = BlobRouter.init();
    _ = router.register(inproc.backend()).register(arrow.backend());

    const in_desc = try inproc.backend().write("in-process payload");
    const arrow_desc = try arrow.backend().write("arrow columnar payload");
    try testing.expectEqual(BlobBackendKind.in_process, in_desc.backend);
    try testing.expectEqual(BlobBackendKind.arrow, arrow_desc.backend);

    // Each descriptor resolves against the backend of its own kind …
    try testing.expect(viewEql(router.readView(in_desc), "in-process payload"));
    try testing.expect(viewEql(router.readView(arrow_desc), "arrow columnar payload"));

    // … and NOT against a backend of the wrong kind: retag the arrow descriptor
    // as in_process and it must not resolve against the in-process arena.
    try testing.expect(router.readView(arrow_desc.withBackend(.in_process)) == null);
}

test "transport: unregistered backend resolves to null" {
    var arrow = try ArrowBackend.initCapacity(testing.allocator, 4096);
    defer arrow.deinit();
    const arrow_desc = try arrow.backend().write("payload");

    var router = BlobRouter.init(); // no backends registered
    try testing.expect(router.readView(arrow_desc) == null);
}

test "transport: resolve_stale_generation — epoch advance invalidates prior descriptors" {
    var b = try InProcessBackend.initCapacity(testing.allocator, 4096);
    defer b.deinit();
    const backend = b.backend();

    const desc = try backend.write("payload before epoch advance");
    try testing.expect(viewEql(backend.readView(desc), "payload before epoch advance"));

    backend.advanceEpoch();
    // The stale descriptor (minted at the prior epoch) no longer resolves.
    try testing.expect(backend.readView(desc) == null);

    // A fresh write at the new epoch resolves.
    const desc2 = try backend.write("payload after epoch advance");
    try testing.expect(viewEql(backend.readView(desc2), "payload after epoch advance"));
}

test "transport: resolve_corrupt_checksum — a corrupted descriptor is rejected" {
    var b = try InProcessBackend.initCapacity(testing.allocator, 4096);
    defer b.deinit();
    const backend = b.backend();

    const desc = try backend.write("integrity-checked payload");
    var corrupt = desc;
    corrupt.checksum ^= 0xdead_beef;
    try testing.expect(backend.readView(corrupt) == null);
}

test "transport: spillMessage spills oversized Delta payloads to descriptors" {
    var b = try InProcessBackend.initCapacity(testing.allocator, 1 << 16);
    defer b.deinit();
    const backend = b.backend();

    const big: [1024]u8 = @splat('x'); // 1 KiB payload, above the 512-byte threshold
    const ops = [_]DeltaOp{
        DeltaOp.slotValue(7, IpcValue.fromInline(&big)),
        DeltaOp.cellSet(8, IpcValue.fromInline("small")),
    };
    const delta = ipc.Delta.init(0, 1, &ops);
    const message = IpcMessage{ .Delta = delta };

    var spilled = try spillMessage(testing.allocator, message, backend, 512);
    defer spilled.deinit();

    try testing.expectEqual(@as(usize, big.len), spilled.spilled);
    const out = spilled.message.Delta;
    try testing.expect(out.ops[0].SlotValue.payload == .SharedBlob); // big → spilled
    try testing.expect(out.ops[1].CellSet.payload == .Inline); // small → inline
    // The spilled descriptor resolves back to the original bytes.
    try testing.expect(viewEql(resolveValue(out.ops[0].SlotValue.payload, backend), &big));
    // Input message untouched.
    try testing.expect(message.Delta.ops[0].SlotValue.payload == .Inline);
}

test "transport: arrow backend descriptor round-trips through IpcValue JSON" {
    var arrow = try ArrowBackend.initCapacity(testing.allocator, 4096);
    defer arrow.deinit();
    const desc = try arrow.backend().write("arrow ipc stream bytes");

    const value = IpcValue.sharedBlob(desc);
    const json = try std.json.Stringify.valueAlloc(testing.allocator, value, .{});
    defer testing.allocator.free(json);
    // The arrow discriminator is present on the wire.
    try testing.expect(std.mem.indexOf(u8, json, "\"backend\":\"arrow\"") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    const round = try IpcValue.fromJson(testing.allocator, parsed.value);
    try testing.expectEqual(desc, round.SharedBlob);
}

test "transport: ShmBackend cross-mapping resolves descriptors zero-copy" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    const name = "lazily_zig_transport_test";
    ShmBackend.unlink(testing.allocator, name);
    var creator = ShmBackend.create(testing.allocator, name, 1 << 16) catch |err| {
        // /dev/shm may be unavailable in a sandbox — skip rather than fail.
        if (err == error.BackendIo) return error.SkipZigTest;
        return err;
    };
    defer {
        creator.deinit();
        ShmBackend.unlink(testing.allocator, name);
    }

    const payload = "hello, shared world";
    const desc = try creator.backend().write(payload);
    try testing.expectEqual(BlobBackendKind.shm, desc.backend);
    try testing.expect(viewEql(creator.backend().readView(desc), payload));

    // A distinct handle opening the same named region resolves the descriptor
    // against its OWN mapping — the cross-process zero-copy guarantee.
    var opener = try ShmBackend.open(testing.allocator, name);
    defer opener.deinit();
    try testing.expect(viewEql(opener.backend().readView(desc), payload));
}
