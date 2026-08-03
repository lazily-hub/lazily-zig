const std = @import("std");
const builtin = @import("builtin");

pub const NodeId = u64;
pub const PeerId = u64;

pub const protocol_id = "lazily-ipc";
pub const protocol_major_version: u64 = 1;
pub const max_js_safe_integer: u64 = 9_007_199_254_740_991;

pub const Codec = enum {
    json,
    binary,
};

pub const CapabilityHandshake = struct {
    protocol_id: []const u8 = protocol_id,
    protocol_major_version: u64 = protocol_major_version,
    codec: Codec = .json,
    max_frame_size: u64,
    fragmentation_supported: bool = false,
    ordered_reliable: bool = true,
    peer_id: PeerId,
    session_id: []const u8,
    features: []const []const u8 = &.{},

    pub fn isCompatibleWith(self: CapabilityHandshake, other: CapabilityHandshake) bool {
        return std.mem.eql(u8, self.protocol_id, protocol_id) and
            std.mem.eql(u8, other.protocol_id, protocol_id) and
            self.protocol_major_version == other.protocol_major_version and
            self.protocol_major_version == protocol_major_version and
            self.codec == other.codec and
            self.ordered_reliable and
            other.ordered_reliable;
    }
};

/// Longest backend token `BlobBackendKind`'s diagnostic slot keeps verbatim.
/// Comfortably longer than any spelled backend name; see `takeUnknownToken` for
/// why a longer token is truncated rather than dropped.
const MAX_BLOB_BACKEND_TOKEN: usize = 64;

/// Thread-local so two decoders on two threads never read each other's token.
/// `null` length means "no refusal outstanding", which is what makes a stale
/// token impossible to mistake for a fresh one.
threadlocal var unknown_blob_backend_buf: [MAX_BLOB_BACKEND_TOKEN]u8 = undefined;
threadlocal var unknown_blob_backend_len: ?usize = null;

/// Which pluggable blob backend resolves a descriptor (zero-copy transport,
/// `#lzzcpy`). Mirrors lazily-rs `BlobBackendKind` and lazily-go
/// `BlobBackendKind`. The discriminant order (`shm=0`, `arrow=1`, `in_process=2`)
/// is the `BlobRouter` slot index — a receiver routes resolution by this kind
/// (the `resolve_wrong_backend` theorem). `shm` is the default so every legacy
/// descriptor (no `backend` field on the wire) validates unchanged. The enum is
/// CLOSED on the wire (`#lzblobbackendstrict`): a present token outside it is
/// refused rather than normalized — see `fromString`.
pub const BlobBackendKind = enum(u2) {
    /// POSIX shared-memory region (`shm_open` + `mmap`) — the default,
    /// cross-process on one host.
    shm = 0,
    /// Apache Arrow IPC stream bytes — columnar/analytics payloads.
    arrow = 1,
    /// In-process arena (single address space — FFI host ↔ same-process binding).
    in_process = 2,

    /// The wire discriminator string (`schemas/defs.json#/$defs/ShmBlobRef`).
    pub fn toString(self: BlobBackendKind) []const u8 {
        return switch (self) {
            .shm => "shm",
            .arrow => "arrow",
            .in_process => "in_process",
        };
    }

    /// Park `text` as the token that made this thread's most recent
    /// `fromString` fail. A Zig error value carries no payload, so this slot is
    /// the channel the offending token travels on; without it
    /// `error.UnknownBlobBackend` would name nothing, which is the defect
    /// `unreachable` has and this must not repeat.
    fn recordUnknownToken(text: []const u8) void {
        const n = @min(text.len, MAX_BLOB_BACKEND_TOKEN);
        @memcpy(unknown_blob_backend_buf[0..n], text[0..n]);
        unknown_blob_backend_len = n;
    }

    /// Take the token that made the most recent `fromString` fail ON THIS
    /// THREAD, clearing the slot.
    ///
    /// `null` means nothing has failed since the last take, so a reporter can
    /// never mistake a stale token for a fresh one. The backing buffer is
    /// static and thread-local: use the slice before this thread parses another
    /// bad token. A token longer than `MAX_BLOB_BACKEND_TOKEN` arrives
    /// truncated rather than dropped — a truncated name still identifies the
    /// producer, an absent one does not.
    pub fn takeUnknownToken() ?[]const u8 {
        const n = unknown_blob_backend_len orelse return null;
        unknown_blob_backend_len = null;
        return unknown_blob_backend_buf[0..n];
    }

    pub const FromStringError = error{UnknownBlobBackend};

    /// Parse a wire discriminator string (`#lzblobbackendstrict`).
    ///
    /// A token outside the enum is REFUSED and parked in this thread's
    /// diagnostic slot (`takeUnknownToken`). ABSENCE is the forward-compatible
    /// channel, and the only one: `backend` is optional on
    /// `schemas/defs.json#/$defs/ShmBlobRef`, an omitted field decodes as
    /// `.shm` at the call site, and `jsonStringify` omits it again for `.shm`,
    /// so a pre-field descriptor round-trips byte-identically.
    ///
    /// This used to normalize an unknown token to `.shm`, on the argument that
    /// `.shm` is a routing slot rather than a claim about bytes: the shm
    /// backend would reject the foreign generation/len/checksum/epoch words and
    /// resolution would return null. That argument INVERTS the
    /// `resolve_wrong_backend` theorem instead of resting on it. The theorem
    /// says a descriptor of one kind never resolves against another backend's
    /// table BECAUSE receivers route by kind — and reading an unknown kind as
    /// `shm` is exactly routing a non-shm descriptor into the shm table. What
    /// the theorem discharges structurally the normalization downgrades to a
    /// 64-bit checksum's word, taken against a backend this build genuinely
    /// resolves: a collision hands back BYTES, where a refusal is a visible
    /// protocol error the peer recovers from by resync.
    ///
    /// Nor is the enum open on the wire. `docs/zero-copy-transport.md` plugs a
    /// new backend in by ADDING an enum value — a spec change that arrives with
    /// a fixture — so an unrecognised token is a corrupt or non-conforming
    /// producer, never a newer peer.
    ///
    /// Never `unreachable` here: it is unchecked UB under ReleaseFast and names
    /// nothing when it fires.
    pub fn fromString(text: []const u8) FromStringError!BlobBackendKind {
        if (std.mem.eql(u8, text, "shm")) return .shm;
        if (std.mem.eql(u8, text, "arrow")) return .arrow;
        if (std.mem.eql(u8, text, "in_process")) return .in_process;
        recordUnknownToken(text);
        return error.UnknownBlobBackend;
    }

    /// Whether this is the default backend (`shm`) — omitted from the wire.
    pub fn isDefault(self: BlobBackendKind) bool {
        return self == .shm;
    }

    /// The `BlobRouter` slot index for this kind.
    pub fn routerIndex(self: BlobBackendKind) usize {
        return @intFromEnum(self);
    }
};

/// Descriptor into a blob backend (zero-copy transport). The standard fields
/// locate and integrity-check a byte range within the backend's resolved
/// buffer; `backend` selects which pluggable backend resolves it. `backend` is
/// optional on the wire and defaults to `.shm`, so legacy descriptors round-trip
/// unchanged and the shared-memory blob path is a strict subset of the transport.
pub const ShmBlobRef = struct {
    offset: u64,
    len: u64,
    generation: u64,
    epoch: u64,
    checksum: u64,
    backend: BlobBackendKind = .shm,

    /// Return a copy of this descriptor tagged with `kind`.
    pub fn withBackend(self: ShmBlobRef, kind: BlobBackendKind) ShmBlobRef {
        var out = self;
        out.backend = kind;
        return out;
    }

    /// Serialize as `{ offset, len, generation, epoch, checksum[, backend] }`.
    /// `backend` is emitted only when non-default (`!= .shm`) so descriptors on
    /// the shared-memory path serialize identically to the pre-transport form.
    pub fn jsonStringify(self: ShmBlobRef, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("offset");
        try jw.write(self.offset);
        try jw.objectField("len");
        try jw.write(self.len);
        try jw.objectField("generation");
        try jw.write(self.generation);
        try jw.objectField("epoch");
        try jw.write(self.epoch);
        try jw.objectField("checksum");
        try jw.write(self.checksum);
        if (!self.backend.isDefault()) {
            try jw.objectField("backend");
            try jw.write(self.backend.toString());
        }
        try jw.endObject();
    }
};

/// Bytes reserved before every shared-memory blob payload (matches lazily-rs).
pub const SHM_BLOB_HEADER_LEN: usize = 40;

const SHM_BLOB_MAGIC: u32 = 0x4c5a5348; // "LZSH"
const SHM_BLOB_VERSION: u16 = 1;
const FNV_OFFSET_BASIS: u64 = 0xcbf2_9ce4_8422_2325;
const FNV_PRIME: u64 = 0x0000_0100_0000_01b3;

pub const ShmBlobArenaError = error{
    CapacityTooSmall,
    BlobTooLarge,
    DescriptorOutOfBounds,
    DescriptorMismatch,
    ChecksumMismatch,
    GenerationOverflow,
};

/// Fixed-size blob arena suitable for a shared-memory transport.
///
/// Mirrors lazily-rs `ShmBlobArena<B>` (`src/lazily-rs/src/ipc.rs`). Writes a
/// 40-byte header before each payload; readers validate the header, generation,
/// epoch, length, and FNV-1a checksum before returning a slice. Append-only
/// with wraparound; `next_generation` rejects stale descriptors after a wrap.
///
/// The backing buffer is owned + freed when allocated via `withCapacity`; an
/// externally-owned buffer (e.g. an OS mmap region) can be wrapped via
/// `fromBuffer` and is NOT freed on `deinit`.
pub const ShmBlobArena = struct {
    bytes: []u8,
    write_offset: usize,
    next_generation: u64,
    owns_buffer: bool,
    allocator: std.mem.Allocator,

    pub const min_capacity: usize = SHM_BLOB_HEADER_LEN + 1;

    /// Wrap an externally-owned buffer. The arena will NOT free `buffer`.
    pub fn fromBuffer(allocator: std.mem.Allocator, buffer: []u8) ShmBlobArenaError!ShmBlobArena {
        if (buffer.len < min_capacity) return error.CapacityTooSmall;
        return .{
            .bytes = buffer,
            .write_offset = 0,
            .next_generation = 1,
            .owns_buffer = false,
            .allocator = allocator,
        };
    }

    /// Allocate a fresh zeroed buffer of `cap_bytes` bytes (arena owns it).
    pub fn withCapacity(
        allocator: std.mem.Allocator,
        cap_bytes: usize,
    ) (ShmBlobArenaError || error{OutOfMemory})!ShmBlobArena {
        if (cap_bytes < min_capacity) return error.CapacityTooSmall;
        const bytes = try allocator.alloc(u8, cap_bytes);
        @memset(bytes, 0);
        var arena = try fromBuffer(allocator, bytes);
        arena.owns_buffer = true;
        return arena;
    }

    pub fn deinit(self: *ShmBlobArena) void {
        if (self.owns_buffer) {
            self.allocator.free(self.bytes);
            self.owns_buffer = false;
        }
    }

    pub fn capacity(self: *const ShmBlobArena) usize {
        return self.bytes.len;
    }

    /// Maximum payload length this arena can hold in one blob.
    pub fn maxBlobLen(self: *const ShmBlobArena) usize {
        return self.capacity() - SHM_BLOB_HEADER_LEN;
    }

    /// Current write cursor offset.
    pub fn writeOffset(self: *const ShmBlobArena) usize {
        return self.write_offset;
    }

    /// Write a payload and return a descriptor suitable for an IPC message.
    pub fn writeBlob(
        self: *ShmBlobArena,
        epoch: u64,
        payload: []const u8,
    ) ShmBlobArenaError!ShmBlobRef {
        const cap = self.capacity();
        const max_len = self.maxBlobLen();
        if (payload.len > max_len) return error.BlobTooLarge;

        const total_len = SHM_BLOB_HEADER_LEN + payload.len;
        if (self.write_offset + total_len > cap) {
            self.write_offset = 0;
        }

        const generation = self.next_generation;
        self.next_generation = std.math.add(u64, self.next_generation, 1) catch
            return error.GenerationOverflow;

        const offset = self.write_offset;
        const descriptor = ShmBlobRef{
            .offset = @intCast(offset),
            .len = @intCast(payload.len),
            .generation = generation,
            .epoch = epoch,
            .checksum = checksum(payload),
        };

        const payload_offset = offset + SHM_BLOB_HEADER_LEN;
        writeHeader(self.bytes, offset, descriptor);
        @memcpy(self.bytes[payload_offset .. payload_offset + payload.len], payload);

        self.write_offset += total_len;
        if (self.write_offset == cap) self.write_offset = 0;

        return descriptor;
    }

    /// Read and validate a previously written blob.
    pub fn readBlob(
        self: *const ShmBlobArena,
        descriptor: ShmBlobRef,
    ) ShmBlobArenaError![]const u8 {
        const cap = self.capacity();
        const offset: usize = @intCast(descriptor.offset);
        const len: usize = @intCast(descriptor.len);
        const total_len = SHM_BLOB_HEADER_LEN + len;
        // Safe OOB check (no overflow): offset + total_len <= cap.
        if (offset > cap or total_len > cap or offset > cap - total_len) {
            return error.DescriptorOutOfBounds;
        }

        const header = try readHeader(self.bytes, offset);
        // The `backend` discriminator is a wire-only routing tag — the arena
        // stores only the shared-memory header fields, so normalize it out of
        // the descriptor before comparing against the reconstructed header.
        var want = descriptor;
        want.backend = .shm;
        if (!std.meta.eql(header, want)) return error.DescriptorMismatch;

        const payload_offset = offset + SHM_BLOB_HEADER_LEN;
        const payload = self.bytes[payload_offset .. payload_offset + len];
        if (checksum(payload) != descriptor.checksum) return error.ChecksumMismatch;
        return payload;
    }
};

fn writeHeader(bytes: []u8, offset: usize, descriptor: ShmBlobRef) void {
    const header = bytes[offset .. offset + SHM_BLOB_HEADER_LEN];
    writeU32(header, 0, SHM_BLOB_MAGIC);
    writeU16(header, 4, SHM_BLOB_VERSION);
    writeU16(header, 6, @intCast(SHM_BLOB_HEADER_LEN));
    writeU64(header, 8, descriptor.generation);
    writeU64(header, 16, descriptor.epoch);
    writeU64(header, 24, descriptor.len);
    writeU64(header, 32, descriptor.checksum);
}

fn readHeader(bytes: []const u8, offset: usize) ShmBlobArenaError!ShmBlobRef {
    const header = bytes[offset .. offset + SHM_BLOB_HEADER_LEN];
    if (readU32(header, 0) != SHM_BLOB_MAGIC) return error.DescriptorMismatch;
    if (readU16(header, 4) != SHM_BLOB_VERSION) return error.DescriptorMismatch;
    if (@as(usize, readU16(header, 6)) != SHM_BLOB_HEADER_LEN) return error.DescriptorMismatch;
    return ShmBlobRef{
        .offset = @intCast(offset),
        .generation = readU64(header, 8),
        .epoch = readU64(header, 16),
        .len = readU64(header, 24),
        .checksum = readU64(header, 32),
    };
}

/// FNV-1a (64-bit) non-cryptographic checksum, matching lazily-rs.
pub fn checksumFnv(payload: []const u8) u64 {
    var hash: u64 = FNV_OFFSET_BASIS;
    for (payload) |b| hash = (hash ^ @as(u64, b)) *% FNV_PRIME;
    return hash;
}

const checksum = checksumFnv;

fn writeU16(bytes: []u8, off: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[off..][0..2], value, .little);
}
fn writeU32(bytes: []u8, off: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[off..][0..4], value, .little);
}
fn writeU64(bytes: []u8, off: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[off..][0..8], value, .little);
}
fn readU16(bytes: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, bytes[off..][0..2], .little);
}
fn readU32(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}
fn readU64(bytes: []const u8, off: usize) u64 {
    return std.mem.readInt(u64, bytes[off..][0..8], .little);
}

pub const IpcValue = union(enum) {
    Inline: []const u8,
    SharedBlob: ShmBlobRef,

    pub fn fromInline(payload: []const u8) IpcValue {
        return .{ .Inline = payload };
    }

    pub fn sharedBlob(blob: ShmBlobRef) IpcValue {
        return .{ .SharedBlob = blob };
    }

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !IpcValue {
        const tagged = try singleField(value);
        if (std.mem.eql(u8, tagged.name, "Inline")) {
            return .{ .Inline = try parseByteArray(allocator, tagged.value) };
        }
        if (std.mem.eql(u8, tagged.name, "SharedBlob")) {
            return .{ .SharedBlob = try parseShmBlobRef(tagged.value) };
        }
        return error.UnknownIpcValue;
    }

    pub fn jsonStringify(self: IpcValue, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .Inline => |payload| {
                try jw.objectField("Inline");
                try writeByteArray(payload, jw);
            },
            .SharedBlob => |blob| {
                try jw.objectField("SharedBlob");
                try jw.write(blob);
            },
        }
        try jw.endObject();
    }
};

pub const NodeState = union(enum) {
    Payload: []const u8,
    SharedBlob: ShmBlobRef,
    Opaque: void,

    pub fn fromPayload(bytes: []const u8) NodeState {
        return .{ .Payload = bytes };
    }

    pub fn sharedBlob(blob: ShmBlobRef) NodeState {
        return .{ .SharedBlob = blob };
    }

    pub fn fromOpaque() NodeState {
        return .{ .Opaque = {} };
    }

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !NodeState {
        switch (value) {
            .string => |name| {
                if (std.mem.eql(u8, name, "Opaque")) return .{ .Opaque = {} };
                return error.UnknownNodeState;
            },
            .object => {
                const tagged = try singleField(value);
                if (std.mem.eql(u8, tagged.name, "Payload")) {
                    return .{ .Payload = try parseByteArray(allocator, tagged.value) };
                }
                if (std.mem.eql(u8, tagged.name, "SharedBlob")) {
                    return .{ .SharedBlob = try parseShmBlobRef(tagged.value) };
                }
                return error.UnknownNodeState;
            },
            else => return error.ExpectedNodeState,
        }
    }

    pub fn jsonStringify(self: NodeState, jw: anytype) !void {
        switch (self) {
            .Payload => |payload_bytes| {
                try jw.beginObject();
                try jw.objectField("Payload");
                try writeByteArray(payload_bytes, jw);
                try jw.endObject();
            },
            .SharedBlob => |blob| {
                try jw.beginObject();
                try jw.objectField("SharedBlob");
                try jw.write(blob);
                try jw.endObject();
            },
            .Opaque => try jw.write("Opaque"),
        }
    }
};

/// A wire-stable keyed address — a "/"-joined path string.
/// Optional on `NodeSnapshot` and the `NodeAdd` delta op (`protocol.md § NodeKey`).
/// Survives NodeId churn so a peer can subscribe to "entry `scores/alice`"
/// without an out-of-band key→NodeId map (#lzwirekey).
pub const NodeKey = []const u8;

pub const NodeSnapshot = struct {
    node: NodeId,
    type_tag: []const u8,
    state: NodeState,
    key: ?NodeKey = null,

    pub fn fromPayload(node: NodeId, type_tag: []const u8, bytes: []const u8) NodeSnapshot {
        return .{ .node = node, .type_tag = type_tag, .state = NodeState.fromPayload(bytes) };
    }

    pub fn sharedBlob(node: NodeId, type_tag: []const u8, blob: ShmBlobRef) NodeSnapshot {
        return .{ .node = node, .type_tag = type_tag, .state = NodeState.sharedBlob(blob) };
    }

    pub fn fromOpaque(node: NodeId, type_tag: []const u8) NodeSnapshot {
        return .{ .node = node, .type_tag = type_tag, .state = NodeState.fromOpaque() };
    }

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !NodeSnapshot {
        return .{
            .node = try asU64(try field(value, "node")),
            .type_tag = try asString(try field(value, "type_tag")),
            .state = try NodeState.fromJson(allocator, try field(value, "state")),
            // Omit-when-absent is an ENCODER rule (protocol.md § NodeKey,
            // `#lzkeynullstrict`); a conforming peer may still send an explicit
            // `key: null`, and a decoder MUST read both forms as absent. The
            // previous `objectGet(...) |k| asString(k)` saw the JSON null and
            // returned error.ExpectedString. `CrdtOp.fromJson` below already
            // switches on `.null` for exactly this reason.
            .key = try keyFieldOrNull(value),
        };
    }

    pub fn jsonStringify(self: NodeSnapshot, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("node");
        try jw.write(self.node);
        try jw.objectField("type_tag");
        try jw.write(self.type_tag);
        try jw.objectField("state");
        switch (self.state) {
            .Payload => |payload_bytes| {
                try jw.beginObject();
                try jw.objectField("Payload");
                try writeByteArray(payload_bytes, jw);
                try jw.endObject();
            },
            .SharedBlob => |blob| {
                try jw.beginObject();
                try jw.objectField("SharedBlob");
                try jw.write(blob);
                try jw.endObject();
            },
            .Opaque => try jw.write("Opaque"),
        }
        if (self.key) |k| {
            try jw.objectField("key");
            try jw.write(k);
        }
        try jw.endObject();
    }
};

pub const EdgeSnapshot = struct {
    dependent: NodeId,
    dependency: NodeId,

    pub fn init(dependent: NodeId, dependency: NodeId) EdgeSnapshot {
        return .{ .dependent = dependent, .dependency = dependency };
    }

    pub fn fromJson(value: std.json.Value) !EdgeSnapshot {
        return .{
            .dependent = try asU64(try field(value, "dependent")),
            .dependency = try asU64(try field(value, "dependency")),
        };
    }
};

pub const Snapshot = struct {
    epoch: u64,
    nodes: []const NodeSnapshot,
    edges: []const EdgeSnapshot,
    roots: []const NodeId,

    pub fn init(
        epoch: u64,
        nodes: []const NodeSnapshot,
        edges: []const EdgeSnapshot,
        roots: []const NodeId,
    ) Snapshot {
        return .{ .epoch = epoch, .nodes = nodes, .edges = edges, .roots = roots };
    }

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !Snapshot {
        return .{
            .epoch = try asU64(try field(value, "epoch")),
            .nodes = try parseNodeSnapshots(allocator, try field(value, "nodes")),
            .edges = try parseEdgeSnapshots(allocator, try field(value, "edges")),
            .roots = try parseNodeIds(allocator, try field(value, "roots")),
        };
    }
};

pub const DeltaOp = union(enum) {
    CellSet: NodeValueOp,
    SlotValue: NodeValueOp,
    Invalidate: NodeOnlyOp,
    NodeAdd: NodeAddOp,
    NodeRemove: NodeOnlyOp,
    EdgeAdd: EdgeSnapshot,
    EdgeRemove: EdgeSnapshot,

    pub const NodeValueOp = struct {
        node: NodeId,
        payload: IpcValue,
    };

    pub const NodeOnlyOp = struct {
        node: NodeId,
    };

    pub const NodeAddOp = struct {
        node: NodeId,
        type_tag: []const u8,
        state: NodeState,
        key: ?NodeKey = null,
    };

    pub fn cellSet(node: NodeId, payload: IpcValue) DeltaOp {
        return .{ .CellSet = .{ .node = node, .payload = payload } };
    }

    pub fn slotValue(node: NodeId, payload: IpcValue) DeltaOp {
        return .{ .SlotValue = .{ .node = node, .payload = payload } };
    }

    pub fn invalidate(node: NodeId) DeltaOp {
        return .{ .Invalidate = .{ .node = node } };
    }

    pub fn nodeRemove(node: NodeId) DeltaOp {
        return .{ .NodeRemove = .{ .node = node } };
    }

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !DeltaOp {
        const tagged = try singleField(value);
        if (std.mem.eql(u8, tagged.name, "CellSet")) {
            return .{ .CellSet = try parseNodeValueOp(allocator, tagged.value) };
        }
        if (std.mem.eql(u8, tagged.name, "SlotValue")) {
            return .{ .SlotValue = try parseNodeValueOp(allocator, tagged.value) };
        }
        if (std.mem.eql(u8, tagged.name, "Invalidate")) {
            return .{ .Invalidate = try parseNodeOnlyOp(tagged.value) };
        }
        if (std.mem.eql(u8, tagged.name, "NodeAdd")) {
            return .{
                .NodeAdd = .{
                    .node = try asU64(try field(tagged.value, "node")),
                    .type_tag = try asString(try field(tagged.value, "type_tag")),
                    .state = try NodeState.fromJson(allocator, try field(tagged.value, "state")),
                    // Same leniency as NodeSnapshot.fromJson (`#lzkeynullstrict`).
                    .key = try keyFieldOrNull(tagged.value),
                },
            };
        }
        if (std.mem.eql(u8, tagged.name, "NodeRemove")) {
            return .{ .NodeRemove = try parseNodeOnlyOp(tagged.value) };
        }
        if (std.mem.eql(u8, tagged.name, "EdgeAdd")) {
            return .{ .EdgeAdd = try EdgeSnapshot.fromJson(tagged.value) };
        }
        if (std.mem.eql(u8, tagged.name, "EdgeRemove")) {
            return .{ .EdgeRemove = try EdgeSnapshot.fromJson(tagged.value) };
        }
        return error.UnknownDeltaOp;
    }

    pub fn jsonStringify(self: DeltaOp, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .CellSet => |op| {
                try jw.objectField("CellSet");
                try jw.write(op);
            },
            .SlotValue => |op| {
                try jw.objectField("SlotValue");
                try jw.write(op);
            },
            .Invalidate => |op| {
                try jw.objectField("Invalidate");
                try jw.write(op);
            },
            .NodeAdd => |op| {
                try jw.objectField("NodeAdd");
                try jw.beginObject();
                try jw.objectField("node");
                try jw.write(op.node);
                try jw.objectField("type_tag");
                try jw.write(op.type_tag);
                try jw.objectField("state");
                switch (op.state) {
                    .Payload => |payload_bytes| {
                        try jw.beginObject();
                        try jw.objectField("Payload");
                        try writeByteArray(payload_bytes, jw);
                        try jw.endObject();
                    },
                    .SharedBlob => |blob| {
                        try jw.beginObject();
                        try jw.objectField("SharedBlob");
                        try jw.write(blob);
                        try jw.endObject();
                    },
                    .Opaque => try jw.write("Opaque"),
                }
                if (op.key) |k| {
                    try jw.objectField("key");
                    try jw.write(k);
                }
                try jw.endObject();
            },
            .NodeRemove => |op| {
                try jw.objectField("NodeRemove");
                try jw.write(op);
            },
            .EdgeAdd => |edge| {
                try jw.objectField("EdgeAdd");
                try jw.write(edge);
            },
            .EdgeRemove => |edge| {
                try jw.objectField("EdgeRemove");
                try jw.write(edge);
            },
        }
        try jw.endObject();
    }
};

pub const Delta = struct {
    base_epoch: u64,
    epoch: u64,
    ops: []const DeltaOp,

    pub fn init(base_epoch: u64, epoch: u64, ops: []const DeltaOp) Delta {
        return .{ .base_epoch = base_epoch, .epoch = epoch, .ops = ops };
    }

    pub fn next(base_epoch: u64, ops: []const DeltaOp) !Delta {
        return .{
            .base_epoch = base_epoch,
            .epoch = try std.math.add(u64, base_epoch, 1),
            .ops = ops,
        };
    }

    pub fn isNextAfter(self: Delta, last_epoch: u64) bool {
        return self.base_epoch == last_epoch and
            self.base_epoch != std.math.maxInt(u64) and
            self.epoch == self.base_epoch + 1;
    }

    pub fn applyStatus(self: Delta, last_epoch: u64) DeltaApplyStatus {
        if (self.isNextAfter(last_epoch)) return .apply;
        return .{ .resync_required = .{
            .last_epoch = last_epoch,
            .base_epoch = self.base_epoch,
            .epoch = self.epoch,
        } };
    }

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !Delta {
        return .{
            .base_epoch = try asU64(try field(value, "base_epoch")),
            .epoch = try asU64(try field(value, "epoch")),
            .ops = try parseDeltaOps(allocator, try field(value, "ops")),
        };
    }
};

pub const DeltaApplyStatus = union(enum) {
    apply,
    resync_required: struct {
        last_epoch: u64,
        base_epoch: u64,
        epoch: u64,
    },
};

// --- CRDT plane (protocol.md § Distributed: CRDT Cell Plane) ---

/// HLC stamp — total order `(wall_time, logical, peer)`. The wire mirror of
/// the runtime hybrid logical clock. Plain integers so it is codec-stable.
pub const WireStamp = struct {
    wall_time: u64,
    logical: u64,
    peer: u64,

    /// Total order comparison: `(wall_time, logical, peer)` lexicographic.
    pub fn compare(self: WireStamp, other: WireStamp) std.math.Order {
        if (self.wall_time < other.wall_time) return .lt;
        if (self.wall_time > other.wall_time) return .gt;
        if (self.logical < other.logical) return .lt;
        if (self.logical > other.logical) return .gt;
        if (self.peer < other.peer) return .lt;
        if (self.peer > other.peer) return .gt;
        return .eq;
    }

    pub fn fromJson(value: std.json.Value) !WireStamp {
        return .{
            .wall_time = try asU64(try field(value, "wall_time")),
            .logical = try asU64(try field(value, "logical")),
            .peer = try asU64(try field(value, "peer")),
        };
    }
};

/// A single CRDT state-merge op: ships the converged register/sequence/text
/// state for a node, keyed by HLC stamp. State-based (CvRDT): commutative,
/// associative, idempotent merge.
pub const CrdtOp = struct {
    node: NodeId,
    key: ?NodeKey = null,
    stamp: WireStamp,
    state: IpcValue,

    /// `key` is ALWAYS present on a `CrdtOp` — explicitly `null` when unset.
    /// `schemas/distributed.json` lists it in `required` and documents the
    /// difference from `NodeSnapshot`/`NodeAdd`, which omit it; lazily-rs's
    /// derived struct serializes it the same way. This binding used to omit it
    /// when null and to reject an incoming explicit null, so it could neither
    /// produce nor read a keyless op the way the corpus spells one.
    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !CrdtOp {
        return .{
            .node = try asU64(try field(value, "node")),
            .key = try keyFieldOrNull(value),
            .stamp = try WireStamp.fromJson(try field(value, "stamp")),
            .state = try IpcValue.fromJson(allocator, try field(value, "state")),
        };
    }

    pub fn jsonStringify(self: CrdtOp, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("node");
        try jw.write(self.node);
        try jw.objectField("key");
        if (self.key) |k| try jw.write(k) else try jw.write(null);
        try jw.objectField("stamp");
        try jw.write(self.stamp);
        try jw.objectField("state");
        try jw.write(self.state);
        try jw.endObject();
    }
};

/// A per-peer stamp frontier entry — `(peer, WireStamp)`.
///
/// On the wire this is a **2-element tuple** `[peer, stamp]`, not an object:
/// `schemas/distributed.json#/$defs/StampFrontierEntry` pins it with
/// `prefixItems` + `minItems`/`maxItems` of 2, `distributed/crdt_sync_frames.json`
/// ships it that way, and lazily-rs models it as `Vec<(u64, WireStamp)>` (a
/// serde tuple). This binding used to encode and decode `{peer, stamp}`, so its
/// frontier advertisement was unreadable by every other binding — invisible
/// until the frames fixture was actually replayed rather than mirrored.
pub const FrontierEntry = struct {
    peer: u64,
    stamp: WireStamp,

    pub fn fromJson(value: std.json.Value) !FrontierEntry {
        const items = switch (value) {
            .array => |a| a.items,
            else => return error.ExpectedArray,
        };
        if (items.len != 2) return error.MalformedFrontierEntry;
        return .{
            .peer = try asU64(items[0]),
            .stamp = try WireStamp.fromJson(items[1]),
        };
    }

    pub fn jsonStringify(self: FrontierEntry, jw: anytype) !void {
        try jw.beginArray();
        try jw.write(self.peer);
        try jw.write(self.stamp);
        try jw.endArray();
    }
};

/// Anti-entropy wire format for the CRDT plane. Rides the same `lazily-ipc`
/// transport as `Snapshot`/`Delta` as a third `IpcMessage` variant.
pub const CrdtSync = struct {
    frontier: []const FrontierEntry,
    ops: []const CrdtOp,

    pub fn init(frontier: []const FrontierEntry, ops: []const CrdtOp) CrdtSync {
        return .{ .frontier = frontier, .ops = ops };
    }

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !CrdtSync {
        // `frontier` is optional (#lzspecfrontiersuppress): an omitted frontier
        // is equivalent to `[]` and means "unchanged since the last accepted
        // frame" — the receiver reuses its last-merged frontier.
        const frontier: []const FrontierEntry = if (objectGet(value, "frontier")) |raw|
            try parseFrontier(allocator, raw)
        else
            &.{};
        return .{
            .frontier = frontier,
            .ops = try parseCrdtOps(allocator, try field(value, "ops")),
        };
    }

    pub fn jsonStringify(self: CrdtSync, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("frontier");
        try jw.write(self.frontier);
        try jw.objectField("ops");
        try jw.write(self.ops);
        try jw.endObject();
    }

    /// Permission filtering: drops ops for non-readable nodes entirely
    /// (omission, not redaction). The `frontier` is retained in full.
    pub fn filterReadable(self: CrdtSync, allocator: std.mem.Allocator, readable: std.AutoHashMap(NodeId, void)) !CrdtSync {
        var filtered: std.ArrayList(CrdtOp) = .empty;
        for (self.ops) |op| {
            if (readable.contains(op.node)) {
                try filtered.append(allocator, op);
            }
        }
        return .{
            .frontier = self.frontier,
            .ops = try filtered.toOwnedSlice(allocator),
        };
    }
};

fn parseFrontier(allocator: std.mem.Allocator, value: std.json.Value) ![]const FrontierEntry {
    switch (value) {
        .array => |array| {
            const out = try allocator.alloc(FrontierEntry, array.items.len);
            for (array.items, out) |item, *entry| entry.* = try FrontierEntry.fromJson(item);
            return out;
        },
        else => return error.ExpectedArray,
    }
}

fn parseCrdtOps(allocator: std.mem.Allocator, value: std.json.Value) ![]const CrdtOp {
    switch (value) {
        .array => |array| {
            const out = try allocator.alloc(CrdtOp, array.items.len);
            for (array.items, out) |item, *op| op.* = try CrdtOp.fromJson(allocator, item);
            return out;
        },
        else => return error.ExpectedArray,
    }
}

/// Reliable-sync reverse-channel control frame (`#lzsync`, spec § ResyncCoordinator):
/// request a covering `Snapshot` on a detected gap. Carries no node content, so it
/// is permission-filter- and blob-spill-transparent (receiver -> sender).
pub const ResyncRequest = struct {
    /// The requesting receiver's `last_epoch`; the sender replies with a
    /// `Snapshot { epoch >= from_epoch }`.
    from_epoch: u64,

    pub fn fromJson(value: std.json.Value) !ResyncRequest {
        return .{ .from_epoch = try asU64(try field(value, "from_epoch")) };
    }

    pub fn jsonStringify(self: ResyncRequest, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("from_epoch");
        try jw.write(self.from_epoch);
        try jw.endObject();
    }
};

/// Reliable-sync reverse-channel control frame (`#lzsync`, spec § DurableOutbox):
/// prove receipt through `through_epoch`. Advances the sender's outbox retention
/// cursor and doubles as the reconnect resume cursor (receiver -> sender).
pub const OutboxAck = struct {
    /// Highest epoch the receiver has fully applied.
    through_epoch: u64,

    pub fn fromJson(value: std.json.Value) !OutboxAck {
        return .{ .through_epoch = try asU64(try field(value, "through_epoch")) };
    }

    pub fn jsonStringify(self: OutboxAck, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("through_epoch");
        try jw.write(self.through_epoch);
        try jw.endObject();
    }
};

pub const IpcMessage = union(enum) {
    Snapshot: Snapshot,
    Delta: Delta,
    CrdtSync: CrdtSync,
    ResyncRequest: ResyncRequest,
    OutboxAck: OutboxAck,

    /// The [`IpcMessage.ResyncRequest`] control frame for `from_epoch`.
    pub fn resyncRequest(from_epoch: u64) IpcMessage {
        return .{ .ResyncRequest = .{ .from_epoch = from_epoch } };
    }

    /// The [`IpcMessage.OutboxAck`] control frame for `through_epoch`.
    pub fn outboxAck(through_epoch: u64) IpcMessage {
        return .{ .OutboxAck = .{ .through_epoch = through_epoch } };
    }

    /// Whether this is a reliable-sync reverse-channel control frame
    /// (`ResyncRequest` / `OutboxAck`) — no node content, so permission
    /// filtering and blob spilling are the identity on it.
    pub fn isControl(self: IpcMessage) bool {
        return switch (self) {
            .ResyncRequest, .OutboxAck => true,
            else => false,
        };
    }

    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) !IpcMessage {
        const tagged = try singleField(value);
        if (std.mem.eql(u8, tagged.name, "Snapshot")) {
            return .{ .Snapshot = try Snapshot.fromJson(allocator, tagged.value) };
        }
        if (std.mem.eql(u8, tagged.name, "Delta")) {
            return .{ .Delta = try Delta.fromJson(allocator, tagged.value) };
        }
        if (std.mem.eql(u8, tagged.name, "CrdtSync")) {
            return .{ .CrdtSync = try CrdtSync.fromJson(allocator, tagged.value) };
        }
        if (std.mem.eql(u8, tagged.name, "ResyncRequest")) {
            return .{ .ResyncRequest = try ResyncRequest.fromJson(tagged.value) };
        }
        if (std.mem.eql(u8, tagged.name, "OutboxAck")) {
            return .{ .OutboxAck = try OutboxAck.fromJson(tagged.value) };
        }
        return error.UnknownIpcMessage;
    }

    pub fn decodeJson(allocator: std.mem.Allocator, bytes: []const u8) !ParsedMessage {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
            .allocate = .alloc_always,
        });
        errdefer parsed.deinit();
        const message = try IpcMessage.fromJson(parsed.arena.allocator(), parsed.value);
        return .{ .parsed = parsed, .message = message };
    }

    pub fn encodeJsonAlloc(self: IpcMessage, allocator: std.mem.Allocator) ![]u8 {
        return std.json.Stringify.valueAlloc(allocator, self, .{});
    }

    pub fn jsonStringify(self: IpcMessage, jw: anytype) !void {
        try jw.beginObject();
        switch (self) {
            .Snapshot => |snapshot| {
                try jw.objectField("Snapshot");
                try jw.write(snapshot);
            },
            .Delta => |delta| {
                try jw.objectField("Delta");
                try jw.write(delta);
            },
            .CrdtSync => |crdt| {
                try jw.objectField("CrdtSync");
                try jw.write(crdt);
            },
            .ResyncRequest => |req| {
                try jw.objectField("ResyncRequest");
                try jw.write(req);
            },
            .OutboxAck => |ack| {
                try jw.objectField("OutboxAck");
                try jw.write(ack);
            },
        }
        try jw.endObject();
    }
};

pub const ParsedMessage = struct {
    parsed: std.json.Parsed(std.json.Value),
    message: IpcMessage,

    pub fn deinit(self: *@This()) void {
        self.parsed.deinit();
        self.* = undefined;
    }
};

const TaggedValue = struct {
    name: []const u8,
    value: std.json.Value,
};

fn singleField(value: std.json.Value) !TaggedValue {
    switch (value) {
        .object => |object| {
            if (object.count() != 1) return error.ExpectedSingleFieldObject;
            var iter = object.iterator();
            const entry = iter.next() orelse return error.ExpectedSingleFieldObject;
            return .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* };
        },
        else => return error.ExpectedObject,
    }
}

fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    switch (value) {
        .object => |object| return object.get(name) orelse error.MissingField,
        else => return error.ExpectedObject,
    }
}

/// Like `field` but returns `null` when the field is absent (for optional fields).
fn objectGet(value: std.json.Value, name: []const u8) ?std.json.Value {
    return switch (value) {
        .object => |object| object.get(name),
        else => null,
    };
}

fn asString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}

/// Read an optional `NodeKey` field, treating BOTH an omitted field and an
/// explicit JSON `null` as absent (`#lzkeynullstrict`).
///
/// protocol.md § NodeKey makes omit-when-absent an obligation on the ENCODER.
/// It says nothing that lets a decoder refuse the null form, and a peer that
/// simply did not apply `skip_serializing_if` emits it — so refusing made this
/// binding stricter than the reference implementation on a frame the reference
/// implementation produces. Anything other than a string or null is still an
/// error: leniency here is about ABSENCE, not about types.
fn keyFieldOrNull(value: std.json.Value) !?[]const u8 {
    return switch (objectGet(value, "key") orelse std.json.Value{ .null = {} }) {
        .null => null,
        else => |k| try asString(k),
    };
}

fn asU64(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |n| if (n >= 0) @as(u64, @intCast(n)) else error.ExpectedUnsignedInteger,
        .number_string => |s| try std.fmt.parseInt(u64, s, 10),
        else => error.ExpectedUnsignedInteger,
    };
}

fn parseByteArray(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    switch (value) {
        .array => |array| {
            const bytes = try allocator.alloc(u8, array.items.len);
            for (array.items, bytes) |item, *out| {
                const n = try asU64(item);
                if (n > std.math.maxInt(u8)) return error.ByteOutOfRange;
                out.* = @intCast(n);
            }
            return bytes;
        },
        else => return error.ExpectedArray,
    }
}

fn parseNodeIds(allocator: std.mem.Allocator, value: std.json.Value) ![]const NodeId {
    switch (value) {
        .array => |array| {
            const out = try allocator.alloc(NodeId, array.items.len);
            for (array.items, out) |item, *node| node.* = try asU64(item);
            return out;
        },
        else => return error.ExpectedArray,
    }
}

fn parseNodeSnapshots(allocator: std.mem.Allocator, value: std.json.Value) ![]const NodeSnapshot {
    switch (value) {
        .array => |array| {
            const out = try allocator.alloc(NodeSnapshot, array.items.len);
            for (array.items, out) |item, *node| node.* = try NodeSnapshot.fromJson(allocator, item);
            return out;
        },
        else => return error.ExpectedArray,
    }
}

fn parseEdgeSnapshots(allocator: std.mem.Allocator, value: std.json.Value) ![]const EdgeSnapshot {
    switch (value) {
        .array => |array| {
            const out = try allocator.alloc(EdgeSnapshot, array.items.len);
            for (array.items, out) |item, *edge| edge.* = try EdgeSnapshot.fromJson(item);
            return out;
        },
        else => return error.ExpectedArray,
    }
}

fn parseDeltaOps(allocator: std.mem.Allocator, value: std.json.Value) ![]const DeltaOp {
    switch (value) {
        .array => |array| {
            const out = try allocator.alloc(DeltaOp, array.items.len);
            for (array.items, out) |item, *op| op.* = try DeltaOp.fromJson(allocator, item);
            return out;
        },
        else => return error.ExpectedArray,
    }
}

fn parseNodeValueOp(allocator: std.mem.Allocator, value: std.json.Value) !DeltaOp.NodeValueOp {
    return .{
        .node = try asU64(try field(value, "node")),
        .payload = try IpcValue.fromJson(allocator, try field(value, "payload")),
    };
}

fn parseNodeOnlyOp(value: std.json.Value) !DeltaOp.NodeOnlyOp {
    return .{ .node = try asU64(try field(value, "node")) };
}

/// The DOCUMENTED decode-error family for a blob descriptor
/// (`#lzblobbackendstrict`, fixture key `rejection_is_decode_error`).
///
/// Refusing the frame is only half of a refusal. Every caller guards a decode
/// with one `catch` over the codec's errors, so a refusal raised OUTSIDE the
/// family that `catch` enumerates fails PAST the handler: the frame is still
/// rejected and the peer still never learns why. Both refusals the clause
/// requires — a present token outside the enum, and a `backend` that is not a
/// string at all — therefore have to land inside this set, and this is the set
/// they land in.
///
/// It is deliberately the WHOLE descriptor family rather than just the two
/// backend errors: the point of the assertion is that a caller who already
/// handles a malformed `checksum` needs no second handler for a malformed
/// `backend`.
pub const BlobDescriptorDecodeError = error{
    /// The descriptor was not an object.
    ExpectedObject,
    /// A required word (`offset`, `len`, `generation`, `epoch`, `checksum`) is absent.
    MissingField,
    /// `backend` was present and not a string — the `non_string` reject form.
    ExpectedString,
    /// A descriptor word was not a non-negative integer.
    ExpectedUnsignedInteger,
    /// A `number_string` word did not parse as `u64`.
    Overflow,
    /// As `Overflow` — `std.fmt.parseInt`'s other failure.
    InvalidCharacter,
    /// `backend` was a string outside the enum — the `unknown_token` reject
    /// form. The token itself travels on `BlobBackendKind.takeUnknownToken`.
    UnknownBlobBackend,
};

/// The member names of `BlobDescriptorDecodeError`, read off the set itself so
/// the predicate below cannot drift from the declaration above. A hand-copied
/// list would answer `false` for a member added later — the family would grow
/// and the guard would not, which is the same silent-narrowing failure the
/// clause is about.
///
/// `@typeInfo(E).error_set` is `?[]const std.builtin.Type.Error` through 0.16
/// and a struct carrying `error_names` on 0.17-dev. All three toolchains gate
/// CI, so this reads through a version shim rather than pinning one — the same
/// shape as the `Step.tag`/`Step.id` shim in build.zig.
const BLOB_DECODE_ERROR_NAMES: []const [:0]const u8 = names: {
    const info = @typeInfo(BlobDescriptorDecodeError).error_set;
    if (builtin.zig_version.minor >= 17) break :names info.error_names.?;
    var out: [32][:0]const u8 = undefined;
    var n: usize = 0;
    for (info.?) |e| {
        out[n] = e.name;
        n += 1;
    }
    const frozen = out[0..n].*;
    break :names &frozen;
};

/// Whether `err` is a member of `BlobDescriptorDecodeError`.
///
/// `anyerror` in, because the codecs return inferred error sets that a caller
/// (or a conformance runner) has in hand only as a widened value.
pub fn isBlobDescriptorDecodeError(err: anyerror) bool {
    const name = @errorName(err);
    inline for (BLOB_DECODE_ERROR_NAMES) |member| {
        if (std.mem.eql(u8, name, member)) return true;
    }
    return false;
}

fn parseShmBlobRef(value: std.json.Value) !ShmBlobRef {
    // Absence is the forward-compatible channel (`#lzblobbackendstrict`), and
    // an explicit `null` is the ABSENT form, not a present-unknown one — the
    // § NodeKey rule (`#lzkeynullstrict`) applied to this field. A serde-style
    // peer that did not put `skip_serializing_if` on the optional field emits
    // `null` where a conforming encoder omits, so refusing the null would make
    // this binding stricter than the reference implementation on a frame the
    // reference implementation produces.
    //
    // Leniency here is about ABSENCE, not about TYPES: a `backend` that is
    // present and not a string still fails the decode (`error.ExpectedString`),
    // and a present token outside the enum fails it while naming itself through
    // `BlobBackendKind.takeUnknownToken`. Both refusals are members of
    // `BlobDescriptorDecodeError`.
    const backend: BlobBackendKind = switch (objectGet(value, "backend") orelse
        std.json.Value{ .null = {} }) {
        .null => .shm,
        else => |b| try BlobBackendKind.fromString(try asString(b)),
    };
    return .{
        .offset = try asU64(try field(value, "offset")),
        .len = try asU64(try field(value, "len")),
        .generation = try asU64(try field(value, "generation")),
        .epoch = try asU64(try field(value, "epoch")),
        .checksum = try asU64(try field(value, "checksum")),
        .backend = backend,
    };
}

fn writeByteArray(bytes: []const u8, jw: anytype) !void {
    try jw.beginArray();
    for (bytes) |byte| try jw.write(byte);
    try jw.endArray();
}

fn assertFixtureRoundTripFromFile(comptime fixture_name: []const u8) !ParsedMessage {
    const fixture_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "../lazily-spec/conformance/{s}",
        .{fixture_name},
    );
    defer std.testing.allocator.free(fixture_path);

    const fixture = try readFixtureFile(fixture_path);
    defer std.testing.allocator.free(fixture);

    var parsed_fixture = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, fixture, .{
        .allocate = .alloc_always,
    });
    defer parsed_fixture.deinit();

    const wire_json = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        try field(parsed_fixture.value, "wire"),
        .{},
    );
    defer std.testing.allocator.free(wire_json);

    var parsed_message = try IpcMessage.decodeJson(std.testing.allocator, wire_json);
    errdefer parsed_message.deinit();

    const encoded = try parsed_message.message.encodeJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualSlices(u8, wire_json, encoded);

    // The fixture's own `assertions` block. It used to be replayed by nobody:
    // each test below re-typed the same numbers as Zig literals, so upstream
    // could move `epoch` or `op_count` in the corpus and every one of these
    // stayed green (#lzconsumednotasserted).
    if (objectGet(parsed_fixture.value, "assertions")) |block| {
        var keys = cj.AssertionKeys.init(fixture_name ++ " assertions", block);
        try assertDecodedClaims(&keys, parsed_message.message);
        try keys.finish();
    }

    return parsed_message;
}

/// Drive a fixture's `assertions` block against the decoded envelope. Every key
/// the corpus carries for `Snapshot` / `Delta` is asserted here from the
/// fixture's own value; an unrecognised key fails via `finish()`.
fn assertDecodedClaims(keys: *cj.AssertionKeys, message: IpcMessage) !void {
    switch (message) {
        .Snapshot => |snapshot| {
            try keys.assertKey("epoch", snapshot.epoch);
            try keys.assertKey("node_count", snapshot.nodes.len);
            try keys.assertKey("edge_count", snapshot.edges.len);
            try keys.assertKey("root_count", snapshot.roots.len);
            if (snapshot.nodes.len > 0) {
                _ = try keys.assertKeyOpt("first_node_type_tag", snapshot.nodes[0].type_tag);
                _ = try keys.assertKeyOpt(
                    "first_node_state_kind",
                    @tagName(std.meta.activeTag(snapshot.nodes[0].state)),
                );
                if (snapshot.nodes[0].state == .SharedBlob) {
                    const blob = snapshot.nodes[0].state.SharedBlob;
                    _ = try keys.assertKeyOpt("blob_offset", blob.offset);
                    _ = try keys.assertKeyOpt("blob_len", blob.len);
                    _ = try keys.assertKeyOpt("blob_epoch", blob.epoch);
                }
            }
            var opaque_id: ?NodeId = null;
            for (snapshot.nodes) |node| {
                if (node.state == .Opaque) opaque_id = node.node;
            }
            _ = try keys.assertKeyOpt("has_opaque_node", opaque_id != null);
            _ = try keys.assertKeyOpt("opaque_node_id", opaque_id);
        },
        .Delta => |delta| {
            try keys.assertKey("base_epoch", delta.base_epoch);
            try keys.assertKey("epoch", delta.epoch);
            _ = try keys.assertKeyOpt("is_sequential", delta.isNextAfter(delta.base_epoch));
            _ = try keys.assertKeyOpt("op_count", delta.ops.len);
            if (delta.ops.len > 0) {
                _ = try keys.assertKeyOpt(
                    "first_op_kind",
                    @tagName(std.meta.activeTag(delta.ops[0])),
                );
                if (delta.ops[0] == .SlotValue) {
                    const payload = delta.ops[0].SlotValue.payload;
                    _ = try keys.assertKeyOpt(
                        "first_op_payload_kind",
                        @tagName(std.meta.activeTag(payload)),
                    );
                    if (payload == .SharedBlob) {
                        _ = try keys.assertKeyOpt(
                            "first_op_payload_backend",
                            @tagName(payload.SharedBlob.backend),
                        );
                    }
                }
            }
            // Every DeltaOp variant present at least once — the claim the
            // all-variants fixture exists to make. A plain bool-per-tag array
            // rather than `std.EnumSet`, whose constructors moved on master.
            // `@typeInfo(...).@"enum"` renamed `fields` to `field_names` on
            // zig master while 0.15.2 / 0.16.0 still carry `fields`, and
            // `std.meta.fields` is deprecated there — so detect the shape.
            const tag_info = @typeInfo(std.meta.Tag(DeltaOp)).@"enum";
            const variant_count = if (@hasField(@TypeOf(tag_info), "field_names"))
                tag_info.field_names.len
            else
                tag_info.fields.len;
            var seen: [variant_count]bool = @splat(false);
            for (delta.ops) |op| seen[@intFromEnum(std.meta.activeTag(op))] = true;
            var all_variants = true;
            for (seen) |present| {
                if (!present) all_variants = false;
            }
            _ = try keys.assertKeyOpt("has_all_op_variants", all_variants);
            // `resync_after_epoch_10`: applied on top of epoch 10, this delta
            // must demand a resync. The epoch is in the key name, so the value
            // that reaches the comparison is the claim itself.
            _ = try keys.assertKeyOpt(
                "resync_after_epoch_10",
                delta.applyStatus(10) == .resync_required,
            );
        },
        else => {},
    }
}

/// Reads through the runtime conformance manifest recorder
/// (#lazilyupgradeconformance): naming a fixture is not replaying it, so the
/// coverage guard is fed by observed reads rather than a source grep.
const readFixtureFile = @import("conformance_manifest.zig").specReadFile;
const cj = @import("conformance_json.zig");

test "lazily/ipc: snapshot_minimal fixture" {
    var parsed = try assertFixtureRoundTripFromFile("snapshot_minimal.json");
    defer parsed.deinit();
    const message = parsed.message;
    const snapshot = message.Snapshot;
    try std.testing.expectEqual(@as(u64, 1), snapshot.epoch);
    try std.testing.expectEqual(@as(usize, 1), snapshot.nodes.len);
    try std.testing.expectEqualSlices(u8, "i32", snapshot.nodes[0].type_tag);
    try std.testing.expectEqual(@as(NodeId, 1), snapshot.roots[0]);
}

test "lazily/ipc: snapshot_multi_node fixture" {
    var parsed = try assertFixtureRoundTripFromFile("snapshot_multi_node.json");
    defer parsed.deinit();
    const message = parsed.message;
    const snapshot = message.Snapshot;
    try std.testing.expectEqual(@as(usize, 3), snapshot.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), snapshot.edges.len);
    try std.testing.expectEqual(@as(NodeId, 3), snapshot.nodes[2].node);
    try std.testing.expect(snapshot.nodes[2].state == .Opaque);
}

test "lazily/ipc: snapshot_shared_blob fixture" {
    var parsed = try assertFixtureRoundTripFromFile("snapshot_shared_blob.json");
    defer parsed.deinit();
    const message = parsed.message;
    const snapshot = message.Snapshot;
    const blob = snapshot.nodes[0].state.SharedBlob;
    try std.testing.expectEqual(@as(u64, 0), blob.offset);
    try std.testing.expectEqual(@as(u64, 16), blob.len);
    try std.testing.expectEqual(@as(u64, 9), blob.epoch);
}

test "lazily/ipc: delta_sequential fixture" {
    var parsed = try assertFixtureRoundTripFromFile("delta_sequential.json");
    defer parsed.deinit();
    const message = parsed.message;
    const delta = message.Delta;
    try std.testing.expect(delta.isNextAfter(40));
    try std.testing.expect(!delta.isNextAfter(39));
    try std.testing.expectEqual(@as(usize, 7), delta.ops.len);
    try std.testing.expect(delta.ops[0] == .CellSet);
    try std.testing.expect(delta.ops[1] == .SlotValue);
    try std.testing.expect(delta.ops[2] == .Invalidate);
    try std.testing.expect(delta.ops[3] == .NodeAdd);
    try std.testing.expect(delta.ops[4] == .NodeRemove);
    try std.testing.expect(delta.ops[5] == .EdgeAdd);
    try std.testing.expect(delta.ops[6] == .EdgeRemove);
}

test "lazily/ipc: delta_non_sequential fixture requires resync after older epoch" {
    var parsed = try assertFixtureRoundTripFromFile("delta_non_sequential.json");
    defer parsed.deinit();
    const message = parsed.message;
    const delta = message.Delta;
    try std.testing.expect(delta.isNextAfter(12));
    try std.testing.expectEqual(
        DeltaApplyStatus{ .resync_required = .{ .last_epoch = 10, .base_epoch = 12, .epoch = 13 } },
        delta.applyStatus(10),
    );
}

test "lazily/ipc: delta_shared_blob fixture" {
    var parsed = try assertFixtureRoundTripFromFile("delta_shared_blob.json");
    defer parsed.deinit();
    const message = parsed.message;
    const delta = message.Delta;
    const payload = delta.ops[0].SlotValue.payload.SharedBlob;
    try std.testing.expectEqual(@as(u64, 40), payload.offset);
    try std.testing.expectEqual(@as(u64, 17), payload.len);
    try std.testing.expectEqual(@as(u64, 9), payload.epoch);
}

test "lazily/ipc: delta_zero_copy_arrow fixture (backend discriminator)" {
    var parsed = try assertFixtureRoundTripFromFile("delta_zero_copy_arrow.json");
    defer parsed.deinit();
    const message = parsed.message;
    const delta = message.Delta;
    const payload = delta.ops[0].SlotValue.payload.SharedBlob;
    try std.testing.expectEqual(@as(u64, 40), payload.offset);
    try std.testing.expectEqual(@as(u64, 17), payload.len);
    try std.testing.expectEqual(@as(u64, 9), payload.epoch);
    // The optional `backend` discriminator (#lzzcpy) routes this descriptor to
    // the Apache Arrow backend rather than the default shared-memory backend.
    try std.testing.expectEqual(BlobBackendKind.arrow, payload.backend);
}

test "lazily/ipc: ShmBlobRef backend defaults to shm and omits from wire" {
    // A default-backend descriptor serializes without a `backend` field, so the
    // shared-memory blob path is wire-identical to the pre-transport form.
    const default_blob = ShmBlobRef{
        .offset = 0,
        .len = 4,
        .generation = 1,
        .epoch = 0,
        .checksum = 123,
    };
    try std.testing.expectEqual(BlobBackendKind.shm, default_blob.backend);
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, default_blob, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "backend") == null);

    // A non-default descriptor emits the discriminator.
    const arrow_json = try std.json.Stringify.valueAlloc(
        std.testing.allocator,
        default_blob.withBackend(.arrow),
        .{},
    );
    defer std.testing.allocator.free(arrow_json);
    try std.testing.expect(std.mem.indexOf(u8, arrow_json, "\"backend\":\"arrow\"") != null);
}

test "lazily/ipc: a present backend discriminator outside the enum is refused, naming the token" {
    // `#lzblobbackendstrict`. This test asserted the OPPOSITE until the family
    // adjudicated the clause: an unknown token used to normalize to `.shm` on
    // the "routing slot, not a claim about bytes" argument. Normalizing IS
    // routing — a non-shm descriptor lands in the shm table and the
    // `resolve_wrong_backend` guarantee stops being structural. See
    // `BlobBackendKind.fromString`.
    const wire =
        \\{"Delta":{"base_epoch":2,"epoch":3,"ops":[{"CellSet":{"node":1,"payload":
        \\{"SharedBlob":{"offset":32,"len":4,"generation":9,"epoch":3,"checksum":7,
        \\"backend":"rdma"}}}}]}}
    ;
    _ = BlobBackendKind.takeUnknownToken(); // no stale token may satisfy this
    try std.testing.expectError(
        error.UnknownBlobBackend,
        IpcMessage.decodeJson(std.testing.allocator, wire),
    );
    // Refusing is only half the obligation. A decoder that refuses this frame
    // because it mis-parsed `checksum` passes a bare is-error assertion while
    // implementing none of the clause, so the error has to name its input.
    try std.testing.expectEqualStrings("rdma", BlobBackendKind.takeUnknownToken().?);
    // ...and taking it clears the slot, so the next reader cannot be handed
    // this one a second time.
    try std.testing.expect(BlobBackendKind.takeUnknownToken() == null);

    // The bare parser agrees, for the same-named field arriving on any frame.
    try std.testing.expectError(error.UnknownBlobBackend, BlobBackendKind.fromString("rdma"));
    try std.testing.expectEqualStrings("rdma", BlobBackendKind.takeUnknownToken().?);
    // An empty token is a present-but-empty string, not an absent field: the
    // omitted form never reaches `fromString` at all.
    try std.testing.expectError(error.UnknownBlobBackend, BlobBackendKind.fromString(""));
    try std.testing.expectEqualStrings("", BlobBackendKind.takeUnknownToken().?);
    // All three enum spellings parse, including the default one — the omitted
    // form is the only thing `.shm` is inferred from.
    try std.testing.expectEqual(BlobBackendKind.shm, try BlobBackendKind.fromString("shm"));
    try std.testing.expectEqual(BlobBackendKind.arrow, try BlobBackendKind.fromString("arrow"));
    try std.testing.expectEqual(
        BlobBackendKind.in_process,
        try BlobBackendKind.fromString("in_process"),
    );
    // A successful parse leaves no diagnostic behind.
    try std.testing.expect(BlobBackendKind.takeUnknownToken() == null);
}

test "lazily/ipc: an explicit backend null is the ABSENT form and decodes as shm" {
    // `#lzblobbackendstrict` + `#lzkeynullstrict`. A serde-style peer that did
    // not apply `skip_serializing_if` to the optional field emits `null` where
    // a conforming encoder omits, so refusing it would be stricter than the
    // reference implementation ON A FRAME THE REFERENCE IMPLEMENTATION
    // PRODUCES. It is the absent form, not a present-unknown one — the token
    // rule never applies, and no diagnostic is parked.
    const wire =
        \\{"Delta":{"base_epoch":2,"epoch":3,"ops":[{"CellSet":{"node":1,"payload":
        \\{"SharedBlob":{"offset":32,"len":4,"generation":9,"epoch":3,"checksum":7,
        \\"backend":null}}}}]}}
    ;
    _ = BlobBackendKind.takeUnknownToken();
    var parsed = try IpcMessage.decodeJson(std.testing.allocator, wire);
    defer parsed.deinit();
    const blob = parsed.message.Delta.ops[0].CellSet.payload.SharedBlob;
    try std.testing.expectEqual(BlobBackendKind.shm, blob.backend);
    // An accepted frame must leave no token behind, or the refusal assertions
    // above could be satisfied by a decoder that parks one on every descriptor.
    try std.testing.expect(BlobBackendKind.takeUnknownToken() == null);

    // The encoder half: the null does not survive the round trip, because
    // `.shm` is omitted. So the leniency is a DECODER fact only and this
    // binding never emits the non-conforming form it accepts.
    const re = try parsed.message.encodeJsonAlloc(std.testing.allocator);
    defer std.testing.allocator.free(re);
    try std.testing.expect(std.mem.indexOf(u8, re, "backend") == null);
}

test "lazily/ipc: a non-string backend is refused through the documented decode-error family" {
    // The clause is written entirely about TOKENS, so a decoder whose reader
    // coerces rather than refuses on a number in a string position normalizes
    // silently here while passing every token scenario.
    //
    // The second half is the one that is easy to lose: the refusal has to
    // arrive through the family every caller already guards a decode with. A
    // refusal raised outside it fails PAST the handler — the frame is still
    // rejected and the peer still never sees the error.
    const wire =
        \\{"Delta":{"base_epoch":2,"epoch":3,"ops":[{"CellSet":{"node":1,"payload":
        \\{"SharedBlob":{"offset":32,"len":4,"generation":9,"epoch":3,"checksum":7,
        \\"backend":7}}}}]}}
    ;
    _ = BlobBackendKind.takeUnknownToken();
    try std.testing.expectError(
        error.ExpectedString,
        IpcMessage.decodeJson(std.testing.allocator, wire),
    );
    try std.testing.expect(isBlobDescriptorDecodeError(error.ExpectedString));
    // There is no token to name, so nothing may be parked: a decoder that
    // parked the empty string here would satisfy `error_names_token` for the
    // NEXT frame it refused.
    try std.testing.expect(BlobBackendKind.takeUnknownToken() == null);

    // Both refusals the clause requires are in ONE family, which is what makes
    // a single `catch` on the caller's side sufficient.
    try std.testing.expect(isBlobDescriptorDecodeError(error.UnknownBlobBackend));
    // ...and the family is a set, not a synonym for "any error at all".
    try std.testing.expect(!isBlobDescriptorDecodeError(error.OutOfMemory));
    try std.testing.expect(!isBlobDescriptorDecodeError(error.UnknownIpcMessage));
}

test "lazily/ipc: an over-long backend token is truncated into the diagnostic, never dropped" {
    // The slot is fixed-size, so a pathological token has to go somewhere. A
    // truncated name still identifies the producer; a dropped one leaves
    // `error.UnknownBlobBackend` naming nothing, which is the state this whole
    // channel exists to prevent.
    //
    // Built with `@memset` rather than the `"z" ** n` repeat operator: zig
    // master's formatter reads `**` after a string literal as two `*` tokens
    // and demands whitespace 0.15.2/0.16.0 reject, so the literal form cannot
    // satisfy `zig fmt --check` on all three pinned toolchains at once.
    _ = BlobBackendKind.takeUnknownToken();
    var long_buf: [MAX_BLOB_BACKEND_TOKEN + 8]u8 = undefined;
    @memset(&long_buf, 'z');
    const long: []const u8 = &long_buf;
    try std.testing.expectError(error.UnknownBlobBackend, BlobBackendKind.fromString(long));
    const token = BlobBackendKind.takeUnknownToken().?;
    try std.testing.expectEqual(MAX_BLOB_BACKEND_TOKEN, token.len);
    try std.testing.expectEqualStrings(long[0..MAX_BLOB_BACKEND_TOKEN], token);
}

test "lazily/ipc: ShmBlobArena write/read round-trip" {
    const allocator = std.testing.allocator;
    var arena = try ShmBlobArena.withCapacity(allocator, 256);
    defer arena.deinit();

    const payload = "hello lazily";
    const desc = try arena.writeBlob(7, payload);

    try std.testing.expectEqual(@as(u64, 0), desc.offset);
    try std.testing.expectEqual(@as(u64, payload.len), desc.len);
    try std.testing.expectEqual(@as(u64, 7), desc.epoch);
    try std.testing.expectEqual(@as(u64, 1), desc.generation);

    try std.testing.expectEqualStrings(payload, try arena.readBlob(desc));
}

test "lazily/ipc: ShmBlobArena rejects oversized blob and tiny capacity" {
    const allocator = std.testing.allocator;
    var arena = try ShmBlobArena.withCapacity(allocator, SHM_BLOB_HEADER_LEN + 4);
    defer arena.deinit();

    try std.testing.expectError(error.BlobTooLarge, arena.writeBlob(0, "abcdef"));
    try std.testing.expectError(
        error.CapacityTooSmall,
        ShmBlobArena.withCapacity(allocator, SHM_BLOB_HEADER_LEN),
    );
}

test "lazily/ipc: ShmBlobArena fromBuffer wraps externally-owned storage" {
    var backing: [128]u8 = undefined;
    var arena = try ShmBlobArena.fromBuffer(std.testing.allocator, &backing);
    defer arena.deinit(); // must NOT free `backing`

    const desc = try arena.writeBlob(1, "abc");
    try std.testing.expectEqualStrings("abc", try arena.readBlob(desc));
}

test "lazily/ipc: ShmBlobArena wraparound invalidates stale descriptor" {
    const allocator = std.testing.allocator;
    // capacity holds exactly one max-len blob (header + 5)
    var arena = try ShmBlobArena.withCapacity(allocator, SHM_BLOB_HEADER_LEN + 5);
    defer arena.deinit();

    const first = try arena.writeBlob(1, "first");
    try std.testing.expectEqualStrings("first", try arena.readBlob(first));

    // next write wraps to offset 0, bumps generation, overwrites first
    const second = try arena.writeBlob(2, "2nd!!");
    try std.testing.expectEqual(@as(u64, 0), second.offset);
    try std.testing.expect(second.generation > first.generation);

    try std.testing.expectError(error.DescriptorMismatch, arena.readBlob(first));
    try std.testing.expectEqualStrings("2nd!!", try arena.readBlob(second));
}

test "lazily/ipc: ShmBlobArena checksum mismatch on corrupted payload" {
    const allocator = std.testing.allocator;
    var arena = try ShmBlobArena.withCapacity(allocator, 128);
    defer arena.deinit();

    const desc = try arena.writeBlob(0, "payload");
    arena.bytes[SHM_BLOB_HEADER_LEN] ^= 0xff; // corrupt first payload byte
    try std.testing.expectError(error.ChecksumMismatch, arena.readBlob(desc));
}

test "lazily/ipc: ShmBlobArena descriptor flows through IpcValue.sharedBlob" {
    const allocator = std.testing.allocator;
    var arena = try ShmBlobArena.withCapacity(allocator, 128);
    defer arena.deinit();

    const desc = try arena.writeBlob(3, "blob payload");
    const value = IpcValue.sharedBlob(desc);
    try std.testing.expect(value == .SharedBlob);
    try std.testing.expectEqual(desc, value.SharedBlob);
    try std.testing.expectEqualStrings("blob payload", try arena.readBlob(value.SharedBlob));
}

test "lazily/ipc: ShmBlobArena conformance fixture (arena_blob.json)" {
    // Cross-sibling byte contract: the descriptor + 40-byte LZSH header for one
    // write must match the canonical lazily-spec fixture, so rs/py/zig arenas
    // produce interoperable bytes.
    const allocator = std.testing.allocator;
    const fixture_path = try std.fmt.allocPrint(
        allocator,
        "../lazily-spec/conformance/{s}",
        .{"arena_blob.json"},
    );
    defer allocator.free(fixture_path);

    const fixture_raw = try readFixtureFile(fixture_path);
    defer allocator.free(fixture_raw);

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        allocator,
        fixture_raw,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();
    const root = parsed.value;

    const input = try field(root, "input");
    const capacity: usize = @intCast(try asU64(try field(input, "capacity")));
    const epoch = try asU64(try field(input, "epoch"));
    const payload = try parseByteArray(allocator, try field(input, "payload"));
    defer allocator.free(payload);

    var arena = try ShmBlobArena.withCapacity(allocator, capacity);
    defer arena.deinit();
    const desc = try arena.writeBlob(epoch, payload);

    const expected = try field(root, "expected");
    const descriptor = try field(expected, "descriptor");
    try std.testing.expectEqual(try asU64(try field(descriptor, "offset")), desc.offset);
    try std.testing.expectEqual(try asU64(try field(descriptor, "len")), desc.len);
    try std.testing.expectEqual(
        try asU64(try field(descriptor, "generation")),
        desc.generation,
    );
    try std.testing.expectEqual(try asU64(try field(descriptor, "epoch")), desc.epoch);
    try std.testing.expectEqual(
        try asU64(try field(descriptor, "checksum")),
        desc.checksum,
    );

    const header_bytes = try parseByteArray(allocator, try field(expected, "header_bytes"));
    defer allocator.free(header_bytes);
    try std.testing.expectEqualSlices(u8, header_bytes, arena.bytes[0..SHM_BLOB_HEADER_LEN]);

    // round-trip
    try std.testing.expectEqualSlices(u8, payload, try arena.readBlob(desc));

    // The fixture's `assertions` block (#lznullformblind). Everything above
    // replays `input` against `expected`; the block below was carried by the
    // same file and read by NOTHING here — not unread, but unreachable, because
    // no tracker ever saw it. Rung 0's ledger is what turned that up: the
    // unconsumed-key and read-but-unasserted rungs are both scoped to blocks a
    // runner bound, so six silent claims sat here reporting exactly nothing.
    //
    // Binding it through `AssertionKeys` rather than reading the keys by hand is
    // the point — a key the corpus grows later fails as unconsumed instead of
    // falling through.
    var keys = cj.AssertionKeys.init("arena_blob.json assertions", try field(root, "assertions"));
    try keys.assertKey("capacity", arena.capacity());
    try keys.assertKey("epoch", desc.epoch);
    try keys.assertKey("payload_len", desc.len);
    try keys.assertKey("header_len", SHM_BLOB_HEADER_LEN);
    // `magic` is checked against the bytes the arena really wrote, not against
    // the constant: comparing SHM_BLOB_MAGIC to itself would pass over a header
    // writer that stopped emitting it.
    var magic_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &magic_buf, readU32(arena.bytes[0..SHM_BLOB_HEADER_LEN], 0), .big);
    try keys.assertKey("magic", &magic_buf);
    try keys.assertKeyWith("descriptor", desc, struct {
        fn check(want: ShmBlobRef, expected_descriptor: cj.Value) anyerror!void {
            try std.testing.expectEqual(
                try cj.asU64(try cj.required(expected_descriptor, "offset")),
                want.offset,
            );
            try std.testing.expectEqual(
                try cj.asU64(try cj.required(expected_descriptor, "len")),
                want.len,
            );
            try std.testing.expectEqual(
                try cj.asU64(try cj.required(expected_descriptor, "generation")),
                want.generation,
            );
            try std.testing.expectEqual(
                try cj.asU64(try cj.required(expected_descriptor, "epoch")),
                want.epoch,
            );
            try std.testing.expectEqual(
                try cj.asU64(try cj.required(expected_descriptor, "checksum")),
                want.checksum,
            );
            // The KEY SET, not just the five fields. Without it the block is the
            // null form one level down: a sixth field added to `descriptor`
            // upstream would be compared by nothing here, and the corpus
            // perturbation pass found exactly that — a key planted inside this
            // object left the suite green while every scalar sibling reddened.
            const fields = switch (expected_descriptor) {
                .object => |o| o,
                else => return error.ExpectedObject,
            };
            try std.testing.expectEqual(@as(usize, 5), fields.count());
        }
    }.check);
    try keys.finish();
}

// ---------------------------------------------------------------------------
// CRDT plane tests (protocol.md § Distributed: CRDT Cell Plane)
// ---------------------------------------------------------------------------

test "lazily/ipc: WireStamp total order" {
    const a = WireStamp{ .wall_time = 100, .logical = 0, .peer = 1 };
    const b = WireStamp{ .wall_time = 100, .logical = 1, .peer = 1 };
    const c = WireStamp{ .wall_time = 100, .logical = 1, .peer = 2 };
    const d = WireStamp{ .wall_time = 100, .logical = 1, .peer = 1 };
    try std.testing.expectEqual(std.math.Order.lt, a.compare(b));
    try std.testing.expectEqual(std.math.Order.lt, b.compare(c));
    try std.testing.expectEqual(std.math.Order.eq, a.compare(a));
    try std.testing.expectEqual(std.math.Order.eq, b.compare(d));
}

test "lazily/ipc: CrdtSync IpcMessage round-trip" {
    const allocator = std.testing.allocator;

    const crdt_sync = CrdtSync.init(
        &.{
            .{ .peer = 1, .stamp = .{ .wall_time = 100, .logical = 5, .peer = 1 } },
            .{ .peer = 2, .stamp = .{ .wall_time = 99, .logical = 3, .peer = 2 } },
        },
        &.{
            .{
                .node = 10,
                .key = "scores/alice",
                .stamp = .{ .wall_time = 100, .logical = 5, .peer = 1 },
                .state = IpcValue.fromInline(&.{ 1, 2, 3 }),
            },
            .{
                .node = 20,
                .key = null,
                .stamp = .{ .wall_time = 99, .logical = 3, .peer = 2 },
                .state = IpcValue.fromInline(&.{42}),
            },
        },
    );

    const msg = IpcMessage{ .CrdtSync = crdt_sync };

    const encoded = try msg.encodeJsonAlloc(allocator);
    defer allocator.free(encoded);

    var parsed = try IpcMessage.decodeJson(allocator, encoded);
    defer parsed.deinit();

    const re_encoded = try parsed.message.encodeJsonAlloc(allocator);
    defer allocator.free(re_encoded);

    try std.testing.expectEqualSlices(u8, encoded, re_encoded);

    // Verify the decoded CrdtSync fields.
    const decoded = parsed.message.CrdtSync;
    try std.testing.expectEqual(@as(usize, 2), decoded.frontier.len);
    try std.testing.expectEqual(@as(u64, 1), decoded.frontier[0].peer);
    try std.testing.expectEqual(@as(u64, 100), decoded.frontier[0].stamp.wall_time);
    try std.testing.expectEqual(@as(usize, 2), decoded.ops.len);
    try std.testing.expectEqualStrings("scores/alice", decoded.ops[0].key.?);
    try std.testing.expect(decoded.ops[1].key == null);
    try std.testing.expectEqual(@as(u64, 20), decoded.ops[1].node);
}

test "lazily/ipc: CrdtSync decodes an omitted frontier as empty" {
    // #lzspecfrontiersuppress: schemas/distributed.json makes `frontier`
    // optional — omitting it is equivalent to sending `[]` and means
    // "unchanged since the last accepted frame". Mirrors the
    // crdt_sync_frontier_suppressed frame in
    // lazily-spec/conformance/distributed/crdt_sync_frames.json.
    const allocator = std.testing.allocator;

    const wire =
        \\{"CrdtSync":{"ops":[{"node":7,"key":"counter/global",
        \\"stamp":{"wall_time":13,"logical":0,"peer":1},
        \\"state":{"Inline":[7]}}]}}
    ;
    const flat = try std.mem.replaceOwned(u8, allocator, wire, "\n", "");
    defer allocator.free(flat);

    var parsed = try IpcMessage.decodeJson(allocator, flat);
    defer parsed.deinit();

    const decoded = parsed.message.CrdtSync;
    try std.testing.expectEqual(@as(usize, 0), decoded.frontier.len);
    try std.testing.expectEqual(@as(usize, 1), decoded.ops.len);
    try std.testing.expectEqual(@as(u64, 7), decoded.ops[0].node);
    try std.testing.expectEqualStrings("counter/global", decoded.ops[0].key.?);
}

test "lazily/ipc: CrdtSync filter_readable drops non-readable ops" {
    const allocator = std.testing.allocator;

    var readable = std.AutoHashMap(NodeId, void).init(allocator);
    defer readable.deinit();
    try readable.put(10, {});

    const crdt_sync = CrdtSync.init(
        &.{},
        &.{
            .{ .node = 10, .stamp = .{ .wall_time = 1, .logical = 0, .peer = 1 }, .state = IpcValue.fromInline(&.{1}) },
            .{ .node = 20, .stamp = .{ .wall_time = 1, .logical = 0, .peer = 1 }, .state = IpcValue.fromInline(&.{2}) },
        },
    );

    const filtered = try crdt_sync.filterReadable(allocator, readable);
    defer allocator.free(filtered.ops);
    try std.testing.expectEqual(@as(usize, 1), filtered.ops.len);
    try std.testing.expectEqual(@as(NodeId, 10), filtered.ops[0].node);
}
