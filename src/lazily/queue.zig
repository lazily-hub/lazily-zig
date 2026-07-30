//! Reactive queue: `QueueCell` + pluggable `QueueStorage` backend (`#lzqueue`).
//!
//! A `QueueCell(T, S)` is a FIFO collection composed of reactive cells — **not a
//! new cell kind** — that adds queue semantics (push to tail, pop from head) to
//! the reactive graph. It is specified as a **single-producer, single-consumer
//! (SPSC)** primitive; **MPSC** (multi-producer) is a *usage rule* on the same
//! primitive — multiple producers push inside a `Context.batch` boundary, and
//! the batch serializes the pushes into a deterministic order. There is no
//! separate `MPSCQueueCell` type (`lazily-spec/cell-model.md` § "QueueCell —
//! SPSC primitive with MPSC usage rule"). The formal model
//! (`lazily-formal/LazilyFormal/QueueCell.lean`) pins the universal invariants
//! (reader-kind independence, FIFO order, closure monotonicity); the
//! `lazily-spec/conformance/collections/queuecell_*.json` fixtures are the
//! cross-language parity layer this port replays.
//!
//! ## Shell vs storage
//!
//! The reactive shell owns one graph node per reader kind (`head` / `len` /
//! `is_empty` / `is_full` / `closed`) and the invalidation logic; it is
//! storage-agnostic. `Compute.get(queue.head())` registers a real dependency
//! edge, while `queue.head().get()` is an explicit untracked read. Reader values
//! remain demand-derived from storage rather than being materialized on writes.
//! The storage backend owns the actual FIFO data structure and is pluggable via
//! the [`QueueStorage`] comptime contract. The default
//! [`VecDequeStorage`] is an unbounded ring buffer; a bounded variant exposes
//! reactive backpressure via `is_full`. A distributed backend
//! (`RaftQueueStorage`, future work per the distributed-queue PRD) or an
//! external-broker adapter (`KafkaStorage`, etc.) plugs into the same reactive
//! shell.
//!
//! ## Reader-kind invalidation
//!
//! Invalidation is scoped to **reader kind**, not to individual positions. A
//! push invalidates `len` / `is_empty` readers (and `head` when transitioning
//! from empty, and `is_full` when transitioning to capacity); a pop invalidates
//! `head` / `len` / `is_empty` readers (and `is_full` when transitioning off
//! capacity). The head reader observes the *current* head value — after a pop,
//! the head reader sees the next element (or `null`), not a stale value.
//!
//! The transition `(op, len_before, len_after)` selects the exact changed-kind
//! set without reading any reader value. Those nodes advance under one graph
//! lock and eager dependents drain only after the whole operation is visible.
//! A node whose projected value did not change is not invalidated.
//!
//! ## Closure, bounded backpressure, ordering
//!
//! - **Closure** is an observable contract: pop on closed+non-empty drains;
//!   pop on closed+empty returns [`QueuePopError.Closed`] (distinct from
//!   [`QueuePopError.Empty`]); push on closed is an error; close is idempotent
//!   and terminal.
//! - **Bounded backpressure**: when the backend is bounded, `is_full` is a
//!   reactive read. A consumer's pop that transitions full → not-full bumps the
//!   `is_full` version (true → false), enabling push-side observers to react to
//!   capacity recovery without polling.
//! - **Ordering**: SPSC gives total FIFO (pop order exactly matches push order).
//!   MPSC gives per-producer FIFO; inter-producer interleaving is deterministic
//!   within a `batch()` but the cross-batch order is batch-sequential.

const std = @import("std");
const builtin = @import("builtin");
const Context = @import("context.zig").Context;
const Compute = @import("context.zig").Compute;
const ReaderKind = @import("reader_kind.zig").ReaderKind;
const Slot = @import("context.zig").Slot;
const cell = @import("cell.zig");
const core_mod = @import("queue_core.zig");

// ---------------------------------------------------------------------------
// Errors and the shared algebra
// ---------------------------------------------------------------------------
//
// The state machine moved to `queue_core.zig` when the thread-safe and async
// flavors landed (`#lzqueuefamilyflavors`): three shells over one algebra, so
// there is exactly one place a queue law is written down. Everything re-exported
// here keeps `queue.QueuePushError`, `queue.TopicDurability`, … resolving as
// before.

pub const QueueCore = core_mod.QueueCore;
pub const QueueInvalidates = core_mod.QueueInvalidates;
pub const QueuePushError = core_mod.QueuePushError;
pub const QueuePopError = core_mod.QueuePopError;

// ---------------------------------------------------------------------------
// QueueStorage — pluggable FIFO storage backend (comptime contract)
// ---------------------------------------------------------------------------

/// Pluggable FIFO storage backend for a [`QueueCell`].
///
/// The shell / storage split (`lazily-spec/cell-model.md` § "Reactive shell vs
/// storage backend") keeps the reactive shell storage-agnostic: the shell owns
/// the reader-kind version counters and invalidation logic, the backend owns the
/// actual FIFO data structure. The default backend is [`VecDequeStorage`]
/// (unbounded `ArrayList`-backed deque); future backends include
/// `RaftQueueStorage` (embedded consensus, per the distributed-queue PRD) and
/// `KafkaStorage` / `RedisStreamStorage` / `SqsStorage` (external-broker
/// adapters).
///
/// Zig expresses the adapter as a **comptime contract** on the storage type
/// parameter `S` of `QueueCell(T, S)` (the `"concept (C++)"` form named by the
/// spec; `lazily-rs` uses a `trait`, `lazily-py`/`lazily-js` an interface). A
/// conforming `S` MUST define exactly these methods (signatures below). The
/// reference implementation is [`VecDequeStorage`].
///
/// # Conformance
///
/// A conforming backend MUST:
///
/// 1. **FIFO order** — `tryPop` returns elements in `tryPush` order.
/// 2. **Cardinality compatibility** — its native producer/consumer shape is a
///    superset of the shell's required shape (SPSC shell = any backend; MPSC
///    usage requires a multi-writer backend).
/// 3. **Bounded contract (optional)** — a bounded backend exposes
///    [`capacity`](VecDequeStorage.capacity) as a non-null value and `tryPush`
///    returns [`Full`](QueuePushError.Full) at capacity. The overflow policy is
///    a backend property.
/// 4. **Position identity** — invalidation is phrased over reader kind, not
///    storage indices. A ring-buffer backend whose slot index wraps MUST NOT
///    cause spurious invalidations; the shell layers its own logical version
///    counters (the reader-kind cells) above the storage.
///
/// `is_empty` is deliberately NOT on this contract: emptiness is a shell-level
/// reader kind, not a storage property (the shell derives `is_empty` from
/// `len()`). See `lazily-spec/cell-model.md` § "Storage backend contract".
///
/// Minimal required method signatures on `S` (Phase 0 #relaycell):
/// ```text
/// pub fn tryPush(self: *S, value: T) QueuePushError!void;
/// pub fn tryPop(self: *S) QueuePopError!T;
/// pub fn len(self: *const S) usize;
/// pub fn isClosed(self: *const S) bool;
/// pub fn close(self: *S) void;
/// ```
/// Optional capabilities (detected via `@hasDecl`): a backend MAY also expose
/// `pub fn peek(self: *const S) ?T` to gain a `head` reader, and
/// `pub fn capacity(self: *const S) ?usize` to gain a bounded `is_full` reader.
/// A backend that implements neither (a raw channel) is fully conforming.

// ---------------------------------------------------------------------------
// VecDequeStorage — the reference unbounded/bounded backend
// ---------------------------------------------------------------------------

/// The reference `QueueStorage` backend: an `ArrayList`-backed FIFO, optionally
/// bounded.
///
/// The unbounded form (the default) is what [`QueueCell.init`] consumes when
/// constructed via [`newUnbounded`]; the bounded form
/// ([`initBounded`](VecDequeStorage.initBounded)) exposes reactive backpressure
/// via the shell's `is_full` reader. The overflow policy is **reject** —
/// `tryPush` at capacity returns [`QueuePushError.Full`] (elements are never
/// silently dropped); other backends may choose block / drop-oldest /
/// drop-newest.
///
/// `peek`/`items` expose element order = FIFO order for snapshot and
/// conformance-fixture verification, matching `lazily-spec/cell-model.md` §
/// "Wire and snapshot shape".
pub fn VecDequeStorage(comptime T: type) type {
    return struct {
        buf: std.ArrayList(T),
        cap: ?usize,
        closed: bool,
        allocator: std.mem.Allocator,

        const Self = @This();

        /// Create an unbounded storage (no capacity limit).
        pub fn initUnbounded(allocator: std.mem.Allocator) Self {
            return .{
                .buf = .empty,
                .cap = null,
                .closed = false,
                .allocator = allocator,
            };
        }

        /// Create a bounded storage that rejects pushes once it holds `capacity`
        /// elements.
        ///
        /// asserts `capacity > 0` (a zero-capacity queue can never accept an
        /// element and has no useful semantics).
        pub fn initBounded(allocator: std.mem.Allocator, bound: usize) Self {
            std.debug.assert(bound > 0);
            return .{
                .buf = .empty,
                .cap = bound,
                .closed = false,
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Self) void {
            self.buf.deinit(self.allocator);
        }

        // -- QueueStorage contract --

        pub fn tryPush(self: *Self, value: T) QueuePushError!void {
            if (self.closed) return error.Closed;
            if (self.cap) |c| {
                if (self.buf.items.len >= c) return error.Full;
            }
            self.buf.append(self.allocator, value) catch return;
        }

        pub fn tryPop(self: *Self) QueuePopError!T {
            if (self.buf.items.len == 0) {
                return if (self.closed) error.Closed else error.Empty;
            }
            return self.buf.orderedRemove(0);
        }

        pub fn peek(self: *const Self) ?T {
            if (self.buf.items.len == 0) return null;
            return self.buf.items[0];
        }

        pub fn len(self: *const Self) usize {
            return self.buf.items.len;
        }

        pub fn capacity(self: *const Self) ?usize {
            return self.cap;
        }

        pub fn isClosed(self: *const Self) bool {
            return self.closed;
        }

        pub fn close(self: *Self) void {
            self.closed = true;
        }

        // -- Non-reactive snapshot access --

        /// View the buffered elements in FIFO order. Non-reactive — for
        /// debugging, snapshot/serde, and conformance-fixture verification.
        /// There is no reactive random-access `queue[N]` reader; per-position
        /// reactivity is the domain of `SourceMap`, not `QueueCell`.
        pub fn items(self: *const Self) []const T {
            return self.buf.items;
        }
    };
}

// ---------------------------------------------------------------------------
// QueueCell — the reactive shell
// ---------------------------------------------------------------------------

pub const QueueVersions = core_mod.QueueVersions;

/// A reactive FIFO queue — SPSC primitive with an MPSC usage rule
/// (`#lzqueue`).
///
/// The reactive shell wraps a pluggable `QueueStorage` backend (default
/// [`VecDequeStorage`]); the shell owns the reader-kind version counters
/// (`head` / `len` / `is_empty` / `is_full` / `closed`) and invalidates by
/// reader kind — a push to a non-empty queue does NOT invalidate the `head`
/// reader, a pop does. See the module docs for the full reader-kind independence
/// contract, the formal model (`lazily-formal/LazilyFormal/QueueCell.lean`) for
/// the pinned theorems, and the conformance fixtures for the executable
/// contract.
///
/// `T` is the element type; `S` is the storage backend, which MUST satisfy the
/// [`QueueStorage`] comptime contract. Most callers use
/// `QueueCell(T, VecDequeStorage(T))`.
pub fn QueueCell(comptime T: type, comptime S: type) type {
    return struct {
        ctx: *Context,
        /// The state and the transition algebra, shared verbatim with
        /// `ThreadSafeQueueCell` and `AsyncQueueCell`. `core.storage` is the
        /// backend.
        core: Core,

        // Real graph identities for the five independently-invalidated reader
        // kinds. Values remain demand-derived from storage by the handles below.
        head_reader: ReaderKind,
        len_reader: ReaderKind,
        is_empty_reader: ReaderKind,
        is_full_reader: ReaderKind,
        closed_reader: ReaderKind,

        const Self = @This();

        pub const Core = core_mod.QueueCore(T, S);

        /// Build a queue over an arbitrary `QueueStorage` backend. Reader values
        /// are derived on demand, not at init.
        pub fn init(ctx: *Context, storage: S) !Self {
            const head_reader = try ReaderKind.init(ctx);
            errdefer head_reader.dispose();
            const len_reader = try ReaderKind.init(ctx);
            errdefer len_reader.dispose();
            const is_empty_reader = try ReaderKind.init(ctx);
            errdefer is_empty_reader.dispose();
            const is_full_reader = try ReaderKind.init(ctx);
            errdefer is_full_reader.dispose();
            const closed_reader = try ReaderKind.init(ctx);
            return .{
                .ctx = ctx,
                .core = Core.init(storage),
                .head_reader = head_reader,
                .len_reader = len_reader,
                .is_empty_reader = is_empty_reader,
                .is_full_reader = is_full_reader,
                .closed_reader = closed_reader,
            };
        }

        pub fn deinit(self: *Self) void {
            self.core.deinit();
        }

        /// Publish exactly the reader kinds the core reported. One
        /// `bumpMany` — one frontier walk — so an eager dependent never observes
        /// `len` decremented while `is_full` still reads stale.
        fn publish(self: *Self, changed: core_mod.QueueInvalidates) void {
            var readers: [5]ReaderKind = undefined;
            var count: usize = 0;
            if (changed.len) {
                readers[count] = self.len_reader;
                count += 1;
            }
            if (changed.is_empty) {
                readers[count] = self.is_empty_reader;
                count += 1;
            }
            if (changed.is_full) {
                readers[count] = self.is_full_reader;
                count += 1;
            }
            if (changed.head) {
                readers[count] = self.head_reader;
                count += 1;
            }
            if (changed.closed) {
                readers[count] = self.closed_reader;
                count += 1;
            }
            if (count == 0) return;
            ReaderKind.bumpMany(self.ctx, readers[0..count]);
        }

        // -- mutating ops --

        /// Append `value` to the tail of the queue.
        ///
        /// Returns [`QueuePushError.Full`] if bounded and at capacity (reject
        /// policy — the default `VecDequeStorage` never silently drops), or
        /// [`QueuePushError.Closed`] if the queue is closed. On error the queue
        /// state is unchanged and no reader is invalidated.
        ///
        /// Invalidates `head` (only when transitioning from empty), `len`, and
        /// `is_empty` readers as appropriate; `is_full` when transitioning onto
        /// capacity. Does not touch `closed`.
        pub fn tryPush(self: *Self, value: T) QueuePushError!void {
            self.publish(try self.core.tryPush(value));
        }

        /// Remove and return the head element.
        ///
        /// Returns [`QueuePopError.Empty`] if open and empty, or
        /// [`QueuePopError.Closed`] if closed and empty. Pop on a closed
        /// *non-empty* queue drains (returns the next element).
        ///
        /// Invalidates `head` (always — the head value changes), `len`, and
        /// `is_empty` (when transitioning to empty) readers as appropriate;
        /// `is_full` when transitioning off capacity.
        pub fn tryPop(self: *Self) QueuePopError!T {
            const popped = try self.core.tryPop();
            self.publish(popped.invalidates);
            return popped.value;
        }

        /// Close the queue. Idempotent — closing an already-closed queue is a
        /// no-op (no invalidation). Terminal — once closed, a queue cannot be
        /// reopened. After close, [`tryPush`](Self.tryPush) returns `Closed`;
        /// [`tryPop`](Self.tryPop) continues to drain and returns `Closed` only
        /// once empty.
        ///
        /// Invalidates the `closed` reader only on the false → true transition.
        pub fn close(self: *Self) void {
            self.publish(self.core.close());
        }

        // -- reactive reader-kind reads --

        pub const HeadReader = struct {
            owner: *const Self,
            slot: *Slot,

            pub fn get(reader: @This()) ?T {
                return reader.owner.core.peek();
            }
        };

        pub const LenReader = struct {
            owner: *const Self,
            slot: *Slot,

            pub fn get(reader: @This()) usize {
                return reader.owner.core.len();
            }
        };

        pub const EmptyReader = struct {
            owner: *const Self,
            slot: *Slot,

            pub fn get(reader: @This()) bool {
                return reader.owner.core.isEmpty();
            }
        };

        pub const FullReader = struct {
            owner: *const Self,
            slot: *Slot,

            pub fn get(reader: @This()) bool {
                return reader.owner.core.isFull();
            }
        };

        pub const ClosedReader = struct {
            owner: *const Self,
            slot: *Slot,

            pub fn get(reader: @This()) bool {
                return reader.owner.core.isClosed();
            }
        };

        /// Reactive read of the current head value. `null` when the queue is
        /// empty. A reader is invalidated when the head value *changes* — every
        /// pop, and a push only when transitioning from empty.
        pub fn head(self: *const Self) HeadReader {
            return .{ .owner = self, .slot = self.head_reader.slot() };
        }

        /// Reactive read of the number of buffered elements. Invalidated
        /// whenever the count changes (every successful push/pop).
        pub fn len(self: *const Self) LenReader {
            return .{ .owner = self, .slot = self.len_reader.slot() };
        }

        /// Reactive emptiness check. Invalidated only on the empty ↔ non-empty
        /// transition.
        pub fn isEmpty(self: *const Self) EmptyReader {
            return .{ .owner = self, .slot = self.is_empty_reader.slot() };
        }

        /// Reactive fullness check (only meaningful when the backend is
        /// bounded). Invalidated on the full ↔ not-full transition — this is the
        /// backpressure signal: a producer observes `is_full` and backs off; a
        /// consumer's pop that transitions full → not-full bumps the `is_full`
        /// version and the producer observes capacity recovery. For an unbounded
        /// backend this is always `false` and never invalidates.
        pub fn isFull(self: *const Self) FullReader {
            return .{ .owner = self, .slot = self.is_full_reader.slot() };
        }

        /// Reactive read of the closed flag. Invalidated only on the open →
        /// closed transition.
        pub fn isClosed(self: *const Self) ClosedReader {
            return .{ .owner = self, .slot = self.closed_reader.slot() };
        }

        // -- reader-kind version counters (conformance observation) --

        /// Snapshot all five reader-kind version counters. Diff two snapshots
        /// across an op to observe exactly which reader kinds it invalidated.
        pub fn versions(self: *const Self) QueueVersions {
            return .{
                .head = self.head_reader.version(),
                .len = self.len_reader.version(),
                .is_empty = self.is_empty_reader.version(),
                .is_full = self.is_full_reader.version(),
                .closed = self.closed_reader.version(),
            };
        }

        pub fn headVersion(self: *const Self) u64 {
            return self.head_reader.version();
        }
        pub fn lenVersion(self: *const Self) u64 {
            return self.len_reader.version();
        }
        pub fn isEmptyVersion(self: *const Self) u64 {
            return self.is_empty_reader.version();
        }
        pub fn isFullVersion(self: *const Self) u64 {
            return self.is_full_reader.version();
        }
        pub fn closedVersion(self: *const Self) u64 {
            return self.closed_reader.version();
        }

        // -- non-reactive storage access --

        /// The backend's capacity, or `null` if unbounded. Cached at
        /// construction (capacity is a fixed backend property).
        pub fn capacity(self: *const Self) ?usize {
            return self.core.capacity();
        }

        /// FIFO-ordered view of the buffered elements. Non-reactive — for
        /// debugging, snapshot/serde, and conformance-fixture verification.
        pub fn items(self: *const Self) []const T {
            return self.core.items();
        }
    };
}

// ---------------------------------------------------------------------------
// Convenience: default shell over VecDequeStorage
// ---------------------------------------------------------------------------

/// Create an unbounded `QueueCell(T, VecDequeStorage(T))` (the default reference
/// backend) and return it by value.
pub fn newUnbounded(comptime T: type, ctx: *Context) !QueueCell(T, VecDequeStorage(T)) {
    return try QueueCell(T, VecDequeStorage(T)).init(
        ctx,
        VecDequeStorage(T).initUnbounded(ctx.allocator),
    );
}

/// Create a bounded `QueueCell(T, VecDequeStorage(T))` with `capacity`. Asserts
/// `capacity > 0`.
pub fn newBounded(comptime T: type, ctx: *Context, capacity: usize) !QueueCell(T, VecDequeStorage(T)) {
    return try QueueCell(T, VecDequeStorage(T)).init(
        ctx,
        VecDequeStorage(T).initBounded(ctx.allocator, capacity),
    );
}

// ===========================================================================
// TopicCell — broadcast log with independent absolute cursors (#lztopiccell)
// ===========================================================================

pub const TopicCore = core_mod.TopicCore;
pub const TopicDurability = core_mod.TopicDurability;
pub const TopicSubscribeOutcome = core_mod.TopicSubscribeOutcome;
pub const TopicSubscriptionSnapshot = core_mod.TopicSubscriptionSnapshot;
pub const TopicSnapshot = core_mod.TopicSnapshot;
pub const TopicWake = core_mod.TopicWake;

/// Broadcast topic whose stable subscribers own independent absolute cursors.
/// Durable offline subscriptions retain data; ephemeral subscriptions disappear
/// on disconnect. `gc` drops only the prefix below the slowest durable cursor,
/// so it never increments any subscriber reader version.
///
/// The shell owns one graph identity per subscriber and nothing else: the log,
/// the cursors and every transition live in [`TopicCore`](queue_core.zig), so
/// the thread-safe and async topics are the same algebra with a different
/// publish path.
pub fn TopicCell(comptime T: type) type {
    return struct {
        ctx: *Context,
        allocator: std.mem.Allocator,
        core: Core,
        /// Reader identity per subscriber, keyed by this map's OWN duped id so a
        /// reader survives the core dropping its entry long enough to be
        /// disposed.
        readers: std.StringHashMap(ReaderKind),

        const Self = @This();

        pub const Core = core_mod.TopicCore(T);

        pub fn init(ctx: *Context) Self {
            return .{
                .ctx = ctx,
                .allocator = ctx.allocator,
                .core = Core.init(ctx.allocator),
                .readers = std.StringHashMap(ReaderKind).init(ctx.allocator),
            };
        }

        pub fn initFromSnapshot(ctx: *Context, saved: TopicSnapshot(T)) !Self {
            // Build the core FIRST: it validates cursor bounds and ephemeral
            // connectivity before storing anything, so a rejected snapshot mints
            // no reader and leaves nothing half-built to unwind.
            const core = try Core.initFromSnapshot(ctx.allocator, saved);
            var self = Self{
                .ctx = ctx,
                .allocator = ctx.allocator,
                .core = core,
                .readers = std.StringHashMap(ReaderKind).init(ctx.allocator),
            };
            errdefer self.deinit();
            for (saved.subscriptions) |saved_sub| {
                _ = try self.mintReader(saved_sub.subscriber_id);
            }
            return self;
        }

        pub fn deinit(self: *Self) void {
            var iterator = self.readers.iterator();
            while (iterator.next()) |entry| {
                entry.value_ptr.dispose();
                self.allocator.free(entry.key_ptr.*);
            }
            self.readers.deinit();
            self.core.deinit();
        }

        fn mintReader(self: *Self, subscriber_id: []const u8) !ReaderKind {
            if (self.readers.get(subscriber_id)) |existing| return existing;
            const owned_id = try self.allocator.dupe(u8, subscriber_id);
            errdefer self.allocator.free(owned_id);
            const reader = try ReaderKind.init(self.ctx);
            errdefer reader.dispose();
            try self.readers.put(owned_id, reader);
            return reader;
        }

        fn dropReader(self: *Self, subscriber_id: []const u8) void {
            const removed = self.readers.fetchRemove(subscriber_id) orelse return;
            removed.value.dispose();
            self.allocator.free(removed.key);
        }

        /// Resolve the core's wake set against THIS shell's reader table and bump
        /// exactly those readers, in one frontier walk.
        ///
        /// The source array is heap-allocated rather than a fixed stack buffer:
        /// `ReaderKind.bumpMany` caps at 16 readers and a broadcast topic's
        /// subscriber count has no such bound.
        fn wakeReaders(self: *Self, wake: TopicWake) !void {
            if (wake == .none) return;
            var changed: std.ArrayList(*cell.Source(u64)) = .empty;
            defer changed.deinit(self.allocator);
            try changed.ensureTotalCapacity(self.allocator, self.readers.count());
            var iterator = self.readers.iterator();
            while (iterator.next()) |entry| {
                if (self.core.wakes(wake, entry.key_ptr.*)) {
                    changed.appendAssumeCapacity(entry.value_ptr.source);
                }
            }
            if (changed.items.len == 0) return;
            cell.bumpSources(self.ctx, changed.items);
        }

        /// Start a cursor at the tail, or resume an offline durable subscriber.
        pub fn subscribe(
            self: *Self,
            subscriber_id: []const u8,
            durability: TopicDurability,
        ) !TopicSubscribeOutcome {
            const result = try self.core.subscribe(subscriber_id, durability);
            if (result.change.minted) _ = try self.mintReader(subscriber_id);
            try self.wakeReaders(result.change.wake);
            return result.outcome;
        }

        pub fn reconnect(self: *Self, subscriber_id: []const u8) !void {
            try self.wakeReaders((try self.core.reconnect(subscriber_id)).wake);
        }

        pub fn disconnect(self: *Self, subscriber_id: []const u8) !void {
            const change = try self.core.disconnect(subscriber_id);
            if (change.removed) {
                // Disposal is a strictly stronger observation than a bump: every
                // reader of a removed ephemeral becomes invalid, not merely stale.
                self.dropReader(subscriber_id);
                return;
            }
            try self.wakeReaders(change.wake);
        }

        /// Append a value and invalidate every connected reader independently.
        pub fn publish(self: *Self, value: T) !usize {
            const result = try self.core.publish(value);
            try self.wakeReaders(result.change.wake);
            return result.offset;
        }

        /// Read the retained suffix without advancing this subscriber's cursor.
        pub fn readStream(self: *const Self, subscriber_id: []const u8) ![]const T {
            return self.core.readStream(subscriber_id);
        }

        pub const Reader = struct {
            owner: *const Self,
            subscriber_id: []const u8,
            slot: *Slot,

            pub fn get(reader: @This()) !?T {
                if (reader.slot.disposed) return error.NodeDisposed;
                return reader.owner.core.readValue(reader.subscriber_id);
            }
        };

        pub fn read(self: *const Self, subscriber_id: []const u8) !Reader {
            const entry = self.readers.getEntry(subscriber_id) orelse
                return error.SubscriptionNotFound;
            return .{
                .owner = self,
                .subscriber_id = entry.key_ptr.*,
                .slot = entry.value_ptr.slot(),
            };
        }

        /// Advance only the named subscriber and its reader version.
        pub fn advance(self: *Self, subscriber_id: []const u8, count: usize) !usize {
            const result = try self.core.advance(subscriber_id, count);
            try self.wakeReaders(result.change.wake);
            return result.cursor;
        }

        /// Drop the safe prefix. Cursor offsets stay absolute; no reader changes.
        pub fn gc(self: *Self) usize {
            return self.core.gc();
        }

        pub fn restart(self: *Self) void {
            _ = self.core.restart();
        }

        pub fn baseOffset(self: *const Self) usize {
            return self.core.baseOffset();
        }

        pub fn tailOffset(self: *const Self) usize {
            return self.core.tailOffset();
        }

        pub fn items(self: *const Self) []const T {
            return self.core.items();
        }

        pub fn subscriptionCount(self: *const Self) usize {
            return self.core.subscriptionCount();
        }

        pub fn subscription(
            self: *const Self,
            subscriber_id: []const u8,
        ) ?TopicSubscriptionSnapshot {
            return self.core.subscription(subscriber_id);
        }

        pub fn readerVersion(self: *const Self, subscriber_id: []const u8) ?u64 {
            const found = self.readers.get(subscriber_id) orelse return null;
            return found.version();
        }

        pub fn snapshot(self: *const Self, allocator: std.mem.Allocator) !TopicSnapshot(T) {
            return self.core.snapshot(allocator);
        }
    };
}

// ===========================================================================
// Tests
// ===========================================================================
//
// Inline unit tests mirror lazily-rs `src/queue.rs` (SPSC FIFO, bounded reject,
// closure lifecycle, reader-kind independence, MPSC-via-batch, clone/state
// sharing). The conformance block replays the executable fixtures at
// `../lazily-spec/conformance/collections/queuecell_*.json` — the cross-language
// parity layer — asserting the exact reader-kind `invalidates` matrix.

test "lazily/topic: broadcast cursors are independent" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var topic = TopicCell([]const u8).init(ctx);
    defer topic.deinit();
    try std.testing.expectEqual(TopicSubscribeOutcome.subscribed, try topic.subscribe("alice", .durable));
    _ = try topic.subscribe("bob", .durable);
    try std.testing.expectEqual(@as(usize, 0), try topic.publish("a"));
    try std.testing.expectEqual(@as(usize, 1), try topic.publish("b"));
    _ = try topic.advance("alice", 1);
    try std.testing.expectEqualSlices([]const u8, &[_][]const u8{"b"}, try topic.readStream("alice"));
    try std.testing.expectEqualSlices([]const u8, &[_][]const u8{ "a", "b" }, try topic.readStream("bob"));
}

test "lazily/topic: durable replay and safe GC" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();
    var topic = TopicCell([]const u8).init(ctx);
    defer topic.deinit();
    _ = try topic.subscribe("fast", .durable);
    _ = try topic.subscribe("slow", .durable);
    _ = try topic.publish("a");
    _ = try topic.publish("b");
    _ = try topic.advance("fast", 2);
    _ = try topic.advance("slow", 1);
    try topic.disconnect("slow");
    _ = try topic.publish("c");
    try std.testing.expectEqual(@as(usize, 1), topic.gc());
    try topic.reconnect("slow");
    try std.testing.expectEqualSlices([]const u8, &[_][]const u8{ "b", "c" }, try topic.readStream("slow"));

    var saved = try topic.snapshot(allocator);
    defer saved.deinit();
    var restored = try TopicCell([]const u8).initFromSnapshot(ctx, saved);
    defer restored.deinit();
    try std.testing.expectEqual(topic.baseOffset(), restored.baseOffset());
    try std.testing.expectEqualSlices([]const u8, topic.items(), restored.items());
}

test "lazily/topic: ephemeral disconnect does not hold GC" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var topic = TopicCell([]const u8).init(ctx);
    defer topic.deinit();
    _ = try topic.subscribe("durable", .durable);
    _ = try topic.subscribe("viewer", .ephemeral);
    _ = try topic.publish("a");
    _ = try topic.advance("durable", 1);
    try topic.disconnect("viewer");
    try std.testing.expect(topic.subscription("viewer") == null);
    try std.testing.expectEqual(@as(usize, 1), topic.gc());
    _ = try topic.subscribe("viewer", .ephemeral);
    try std.testing.expectEqual(topic.tailOffset(), topic.subscription("viewer").?.cursor);
}

test "lazily/topic: tail and offline advance are no-ops" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var topic = TopicCell([]const u8).init(ctx);
    defer topic.deinit();
    _ = try topic.subscribe("worker", .durable);
    _ = try topic.publish("a");
    try std.testing.expectEqual(@as(usize, 1), try topic.advance("worker", 1));
    try std.testing.expectEqual(@as(usize, 1), try topic.advance("worker", 1));

    try topic.disconnect("worker");
    _ = try topic.publish("b");
    try std.testing.expectEqual(@as(usize, 0), (try topic.readStream("worker")).len);
    try std.testing.expectEqual(@as(usize, 1), try topic.advance("worker", 1));
    try std.testing.expectEqual(@as(usize, 1), topic.subscription("worker").?.cursor);

    try topic.reconnect("worker");
    try std.testing.expectEqualSlices([]const u8, &[_][]const u8{"b"}, try topic.readStream("worker"));
    try std.testing.expectEqual(@as(usize, 1), topic.gc());
    try std.testing.expectEqual(@as(usize, 1), topic.baseOffset());
    try std.testing.expectEqual(@as(usize, 1), topic.subscription("worker").?.cursor);
}

test "lazily/topic: subscriber readers form real graph edges" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    var topic = TopicCell([]const u8).init(ctx);
    defer topic.deinit();
    _ = try topic.subscribe("alice", .durable);

    const Derived = struct {
        var owner: *TopicCell([]const u8) = undefined;
        var runs: usize = 0;

        fn hasUnread(view: *Compute) !bool {
            runs += 1;
            const reader = try owner.read("alice");
            return (try view.get(reader)) != null;
        }
    };
    Derived.owner = &topic;
    Derived.runs = 0;

    const has_unread = try cell.computed(bool, ctx, Derived.hasUnread, null);
    defer ctx.allocator.destroy(has_unread);
    try std.testing.expect(!has_unread.get().*);

    const before_publish = Derived.runs;
    _ = try topic.publish("message");
    try std.testing.expect(has_unread.get().*);
    try std.testing.expectEqual(before_publish + 1, Derived.runs);

    const before_advance = Derived.runs;
    _ = try topic.advance("alice", 1);
    try std.testing.expect(!has_unread.get().*);
    try std.testing.expectEqual(before_advance + 1, Derived.runs);
}

test "lazily/topic: snapshot rejects disconnected ephemeral subscription" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    const invalid = TopicSnapshot([]const u8){
        .allocator = std.testing.allocator,
        .base_offset = 0,
        .elements = @constCast(&[_][]const u8{}),
        .subscriptions = @constCast(&[_]TopicSubscriptionSnapshot{.{
            .subscriber_id = "viewer",
            .cursor = 0,
            .durability = .ephemeral,
            .connected = false,
        }}),
    };
    try std.testing.expectError(
        error.DisconnectedEphemeralSubscription,
        TopicCell([]const u8).initFromSnapshot(ctx, invalid),
    );
}

test "lazily/queue: SPSC FIFO basic" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var q = try newUnbounded(i32, ctx);
    defer q.deinit();

    try std.testing.expect(q.isEmpty().get());
    try std.testing.expectEqual(@as(?i32, null), q.head().get());

    try q.tryPush(1);
    try q.tryPush(2);
    try q.tryPush(3);

    try std.testing.expectEqual(@as(usize, 3), q.len().get());
    try std.testing.expectEqual(@as(?i32, 1), q.head().get());
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, q.items());

    try std.testing.expectEqual(@as(i32, 1), try q.tryPop());
    try std.testing.expectEqual(@as(i32, 2), try q.tryPop());
    try std.testing.expectEqual(@as(i32, 3), try q.tryPop());
    try std.testing.expectError(error.Empty, q.tryPop());
}

test "lazily/queue: bounded rejects at capacity (reactive backpressure)" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var q = try newBounded(i32, ctx, 2);
    defer q.deinit();

    try std.testing.expectEqual(@as(?usize, 2), q.capacity());
    try std.testing.expect(!q.isFull().get());

    try q.tryPush(1);
    try q.tryPush(2);
    try std.testing.expect(q.isFull().get());
    try std.testing.expectError(error.Full, q.tryPush(3));

    // pop frees a slot → is_full flips → reactive backpressure signal.
    try std.testing.expectEqual(@as(i32, 1), try q.tryPop());
    try std.testing.expect(!q.isFull().get());
    try q.tryPush(3);
    try std.testing.expect(q.isFull().get());
}

test "lazily/queue: closure lifecycle" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var q = try newUnbounded([]const u8, ctx);
    defer q.deinit();

    try q.tryPush("a");
    try q.tryPush("b");

    q.close();
    try std.testing.expect(q.isClosed().get());

    // push on closed is an error.
    try std.testing.expectError(error.Closed, q.tryPush("c"));

    // pop on closed+non-empty drains.
    try std.testing.expectEqualStrings("a", try q.tryPop());
    try std.testing.expectEqualStrings("b", try q.tryPop());

    // pop on closed+empty returns Closed (distinct from Empty).
    try std.testing.expectError(error.Closed, q.tryPop());

    // idempotent close — no-op, no invalidation.
    const closed_before = q.closedVersion();
    q.close();
    try std.testing.expect(q.isClosed().get());
    try std.testing.expectEqual(closed_before, q.closedVersion());
}

test "lazily/queue: reader-kind independence — head not invalidated on push to non-empty" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var q = try newUnbounded(i32, ctx);
    defer q.deinit();

    try std.testing.expectEqual(@as(?i32, null), q.head().get());

    try q.tryPush(1);
    // push to empty changes head → invalidated.
    try std.testing.expectEqual(@as(?i32, 1), q.head().get());
    const head_after_first = q.headVersion();

    try q.tryPush(2);
    try q.tryPush(3);
    // head reader still cached (head unchanged) — reader-kind independence.
    try std.testing.expectEqual(head_after_first, q.headVersion());
    try std.testing.expectEqual(@as(?i32, 1), q.head().get());

    _ = try q.tryPop();
    // pop changes head → invalidated.
    try std.testing.expect(q.headVersion() > head_after_first);
    try std.testing.expectEqual(@as(?i32, 2), q.head().get());
}

test "lazily/queue: reader handles form real graph edges" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var q = try newUnbounded(i32, ctx);
    defer q.deinit();

    const Derived = struct {
        var queue: *QueueCell(i32, VecDequeStorage(i32)) = undefined;
        var head_runs: usize = 0;
        var len_runs: usize = 0;

        fn head(view: *Compute) !?i32 {
            head_runs += 1;
            return view.get(queue.head());
        }

        fn len(view: *Compute) !usize {
            len_runs += 1;
            return view.get(queue.len());
        }
    };
    Derived.queue = &q;
    Derived.head_runs = 0;
    Derived.len_runs = 0;

    const derived_head = try cell.computed(?i32, ctx, Derived.head, null);
    defer ctx.allocator.destroy(derived_head);
    const derived_len = try cell.computed(usize, ctx, Derived.len, null);
    defer ctx.allocator.destroy(derived_len);
    try std.testing.expectEqual(@as(?i32, null), derived_head.get().*);
    try std.testing.expectEqual(@as(usize, 0), derived_len.get().*);

    try q.tryPush(1);
    try std.testing.expectEqual(@as(?i32, 1), derived_head.get().*);
    try std.testing.expectEqual(@as(usize, 1), derived_len.get().*);

    // A push to non-empty changes len but not head. The downstream head
    // computation must remain warm while len recomputes.
    try q.tryPush(2);
    const head_runs = Derived.head_runs;
    const len_runs = Derived.len_runs;
    try std.testing.expectEqual(@as(?i32, 1), derived_head.get().*);
    try std.testing.expectEqual(@as(usize, 2), derived_len.get().*);
    try std.testing.expectEqual(head_runs, Derived.head_runs);
    try std.testing.expectEqual(len_runs + 1, Derived.len_runs);
}

test "lazily/queue: MPSC via batch is one observable transition" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var q = try newUnbounded(i32, ctx);
    defer q.deinit();

    try std.testing.expectEqual(@as(usize, 0), q.len().get());

    // Multiple producers push inside one batch() boundary. Each push bumps the
    // len counter; the fixture asserts len *changed*, not how many times.
    const MPSC = struct {
        var q_ptr: *QueueCell(i32, VecDequeStorage(i32)) = undefined;

        fn run(c: *Context) void {
            _ = c;
            q_ptr.tryPush(10) catch {};
            q_ptr.tryPush(20) catch {};
            q_ptr.tryPush(30) catch {};
        }
    };
    MPSC.q_ptr = &q;
    ctx.batch(MPSC.run);

    try std.testing.expectEqual(@as(usize, 3), q.len().get());
    try std.testing.expectEqualSlices(i32, &[_]i32{ 10, 20, 30 }, q.items());
}

test "lazily/queue: same shell, shared by reference (producer/consumer)" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var q = try newUnbounded(i32, ctx);
    defer q.deinit();

    // A producer borrows the shell by pointer and pushes.
    const producer = &q;
    try producer.tryPush(42);
    try std.testing.expectEqual(@as(i32, 42), try q.tryPop());
}

test "lazily/queue: pluggable storage — custom bounded ring backend" {
    // A minimal custom backend proving the QueueStorage comptime-contract seam
    // works, mirroring lazily-rs `pluggable_storage_via_trait`.
    const Ring = struct {
        buf: std.ArrayList(i32),
        cap: usize,
        closed: bool,
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator, c: usize) @This() {
            return .{ .buf = .empty, .cap = c, .closed = false, .allocator = allocator };
        }
        pub fn deinit(self: *@This()) void {
            self.buf.deinit(self.allocator);
        }
        pub fn tryPush(self: *@This(), v: i32) QueuePushError!void {
            if (self.closed) return error.Closed;
            if (self.buf.items.len >= self.cap) return error.Full;
            self.buf.append(self.allocator, v) catch return;
        }
        pub fn tryPop(self: *@This()) QueuePopError!i32 {
            if (self.buf.items.len == 0) {
                return if (self.closed) error.Closed else error.Empty;
            }
            return self.buf.orderedRemove(0);
        }
        pub fn peek(self: *const @This()) ?i32 {
            return if (self.buf.items.len == 0) null else self.buf.items[0];
        }
        pub fn len(self: *const @This()) usize {
            return self.buf.items.len;
        }
        pub fn capacity(self: *const @This()) ?usize {
            return self.cap;
        }
        pub fn isClosed(self: *const @This()) bool {
            return self.closed;
        }
        pub fn close(self: *@This()) void {
            self.closed = true;
        }
    };

    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const storage = Ring.init(ctx.allocator, 2);
    var q = try QueueCell(i32, Ring).init(ctx, storage);
    defer q.deinit();

    try q.tryPush(1);
    try q.tryPush(2);
    try std.testing.expect(q.isFull().get());
    try std.testing.expectError(error.Full, q.tryPush(3));
    try std.testing.expectEqual(@as(i32, 1), try q.tryPop());
    try std.testing.expect(!q.isFull().get());
    try std.testing.expectEqual(@as(usize, 1), q.len().get());
    try std.testing.expectEqual(@as(?i32, 2), q.head().get());
}

// ---------------------------------------------------------------------------
// Canonical-corpus replay lives in `queue_family_conformance.zig`
// ---------------------------------------------------------------------------
//
// The five `queuecell_*.json` fixtures used to be replayed here, against this
// one flavor, alongside a ledger recording the thread-safe and async flavors as
// unshipped. Both moved to `queue_family_conformance.zig` when those flavors
// landed (`#lzqueuefamilyflavors`): the corpus now runs 3 primitives x 3
// flavors from one runner, and a per-flavor copy of the replay here would be a
// second place for the matrix to drift.

// A raw-channel-style backend implementing ONLY the required contract —
// tryPush / tryPop / len / isClosed / close, no peek, no capacity. It proves the
// minimal contract (Phase 0 #relaycell): fully conforming, with no head reader
// (trivially null) and never full.
const MinimalFifoI32 = struct {
    buf: std.ArrayList(i32),
    closed: bool,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .buf = .empty, .closed = false, .allocator = allocator };
    }
    pub fn deinit(self: *Self) void {
        self.buf.deinit(self.allocator);
    }
    pub fn tryPush(self: *Self, value: i32) QueuePushError!void {
        if (self.closed) return error.Closed;
        self.buf.append(self.allocator, value) catch return;
    }
    pub fn tryPop(self: *Self) QueuePopError!i32 {
        if (self.buf.items.len == 0) return if (self.closed) error.Closed else error.Empty;
        return self.buf.orderedRemove(0);
    }
    pub fn len(self: *const Self) usize {
        return self.buf.items.len;
    }
    pub fn isClosed(self: *const Self) bool {
        return self.closed;
    }
    pub fn close(self: *Self) void {
        self.closed = true;
    }
    // NB: no peek, no capacity.
};

test "lazily/queue: raw-channel backend conforms to minimal contract (#relaycell)" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var q = try QueueCell(i32, MinimalFifoI32).init(ctx, MinimalFifoI32.init(allocator));
    defer q.deinit();

    try std.testing.expect(q.isEmpty().get());

    const len_before = q.lenVersion();
    try q.tryPush(1);
    try q.tryPush(2);
    try std.testing.expectEqual(@as(usize, 2), q.len().get());
    try std.testing.expect(q.lenVersion() > len_before); // reader stays reactive

    // No peek → no head reader (null); no capacity → never full.
    try std.testing.expectEqual(@as(?i32, null), q.head().get());
    try std.testing.expect(!q.isFull().get());
    try std.testing.expectEqual(@as(?usize, null), q.capacity());

    // FIFO drain from tryPop alone.
    try std.testing.expectEqual(@as(i32, 1), try q.tryPop());
    try std.testing.expectEqual(@as(i32, 2), try q.tryPop());
    try std.testing.expect(q.isEmpty().get());

    // Closure lifecycle: Closed distinct from Empty; push-after-close rejected.
    q.close();
    try std.testing.expect(q.isClosed().get());
    try std.testing.expectError(error.Closed, q.tryPush(3));
    try std.testing.expectError(error.Closed, q.tryPop());
}
