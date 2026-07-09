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
//! The reactive shell owns the reader-kind version counters (`head` / `len` /
//! `is_empty` / `is_full` / `closed`) and the invalidation logic; it is
//! storage-agnostic. The storage backend owns the actual FIFO data structure and
//! is pluggable via the [`QueueStorage`] comptime contract. The default
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
//! This reader-kind independence is implemented for free by the `PartialEq`
//! guard: after each op the shell re-derives each reader-kind value from the
//! storage and bumps that reader-kind's version counter **only** when the value
//! genuinely changed — a cell whose value did not change is not invalidated.
//! This mirrors the single-threaded `Context` kernel's `setCell_equal_preserves`
//! theorem (`lazily-formal/LazilyFormal/Reactive.lean`), the same law the Rust
//! shell gets from `Context::set_cell`'s `PartialEq` guard. The Zig port's
//! collection (`collection.zig`) expresses the analogous independence via
//! `membership_version` / `order_version`; the queue uses five per-reader-kind
//! counters.
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

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Failure modes for [`QueueStorage.tryPush`] / [`QueueCell.tryPush`].
///
/// `Full` and `Closed` are the two observable rejection reasons distinguished by
/// the shell's contract (`lazily-spec/cell-model.md` § "Storage backend
/// contract"). Neither changes queue state, so neither invalidates any reader.
pub const QueuePushError = error{
    /// The backend is bounded and at capacity. The overflow policy (block /
    /// drop-oldest / drop-newest / reject) is a backend property; the reference
    /// [`VecDequeStorage`] rejects. Distinct from `Closed`.
    Full,
    /// The queue is closed; push is rejected regardless of capacity. Terminal —
    /// once closed, a queue cannot be reopened.
    Closed,
};

/// Failure modes for [`QueueStorage.tryPop`] / [`QueueCell.tryPop`].
///
/// `Empty` and `Closed` are distinct observable signals: `Empty` means "try
/// again later," `Closed` means "the producer is done and the queue is drained."
pub const QueuePopError = error{
    /// The queue is open but contains no elements.
    Empty,
    /// The queue is closed and empty — the producer is done and all buffered
    /// elements have been consumed. Pop on a closed *non-empty* queue still
    /// drains (returns the next element); only closed+empty yields `Closed`.
    Closed,
};

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
/// Required method signatures on `S`:
/// ```text
/// pub fn tryPush(self: *S, value: T) QueuePushError!void;
/// pub fn tryPop(self: *S) QueuePopError!T;
/// pub fn peek(self: *const S) ?T;
/// pub fn len(self: *const S) usize;
/// pub fn capacity(self: *const S) ?usize;
/// pub fn isClosed(self: *const S) bool;
/// pub fn close(self: *S) void;
/// ```

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
        /// reactivity is the domain of `CellMap`, not `QueueCell`.
        pub fn items(self: *const Self) []const T {
            return self.buf.items;
        }
    };
}

// ---------------------------------------------------------------------------
// Equality helpers — PartialEq guard for the reader-kind counters
// ---------------------------------------------------------------------------

/// Value equality used by the reader-kind `PartialEq` guard. For string element
/// types, compare contents (so two equal strings at different addresses are
/// considered the same head value); for everything else, `std.meta.eql`. This
/// mirrors lazily-rs `PartialEq` on `T` (Rust `String: PartialEq` compares
/// content, not identity).
fn valuesEqual(comptime T: type, a: T, b: T) bool {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return std.mem.eql(u8, a, b);
            return a == b;
        },
        else => return std.meta.eql(a, b),
    }
}

/// Optional-aware equality for the `head` reader kind (`null` when empty).
fn headEqual(comptime T: type, a: ?T, b: ?T) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return valuesEqual(T, a.?, b.?);
}

// ---------------------------------------------------------------------------
// QueueCell — the reactive shell
// ---------------------------------------------------------------------------

/// A snapshot of all five reader-kind version counters. Two snapshots diffed
/// across an op yield exactly which reader kinds the op invalidated — the
/// `invalidates` matrix asserted by
/// `lazily-spec/conformance/collections/queuecell_*.json`.
pub const QueueVersions = struct {
    head: u64,
    len: u64,
    is_empty: u64,
    is_full: u64,
    closed: u64,
};

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
        storage: S,

        // Cached reader-kind values — re-derived from storage after each op.
        head_val: ?T = null,
        len_val: usize = 0,
        is_empty_val: bool = true,
        is_full_val: bool = false,
        closed_val: bool = false,

        // Reader-kind version counters — bumped ONLY when the corresponding
        // cached value genuinely changes. This is the reader-kind independence
        // law: a push to non-empty does not bump head; a pop always does (head
        // value changes); close only bumps closed.
        head_version: u64 = 0,
        len_version: u64 = 0,
        is_empty_version: u64 = 0,
        is_full_version: u64 = 0,
        closed_version: u64 = 0,

        const Self = @This();

        /// Build a queue over an arbitrary `QueueStorage` backend. The shell
        /// initializes its reader-kind values from the backend's current state.
        pub fn init(ctx: *Context, storage: S) Self {
            var self = Self{ .ctx = ctx, .storage = storage };
            // Derive the initial reader-kind values WITHOUT recording them as
            // invalidations (an initial derivation is not a transition). Counter
            // baseline is the post-init state, so the first op's invalidation is
            // measured from this baseline.
            self.syncContent();
            return self;
        }

        /// Re-derive the reader-kind values from storage, bumping a counter only
        /// when the value genuinely changed. This is the reader-kind
        /// independence law. `closed` is intentionally NOT touched here: it only
        /// changes via [`close`](Self.close).
        fn syncContent(self: *Self) void {
            const new_head = self.storage.peek();
            const new_len = self.storage.len();
            const new_is_empty = new_len == 0;
            const new_is_full = if (self.storage.capacity()) |c| new_len >= c else false;

            if (!headEqual(T, self.head_val, new_head)) {
                self.head_val = new_head;
                self.head_version += 1;
            }
            if (self.len_val != new_len) {
                self.len_val = new_len;
                self.len_version += 1;
            }
            if (self.is_empty_val != new_is_empty) {
                self.is_empty_val = new_is_empty;
                self.is_empty_version += 1;
            }
            if (self.is_full_val != new_is_full) {
                self.is_full_val = new_is_full;
                self.is_full_version += 1;
            }
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
            try self.storage.tryPush(value);
            self.syncContent();
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
            const v = try self.storage.tryPop();
            self.syncContent();
            return v;
        }

        /// Close the queue. Idempotent — closing an already-closed queue is a
        /// no-op (no invalidation). Terminal — once closed, a queue cannot be
        /// reopened. After close, [`tryPush`](Self.tryPush) returns `Closed`;
        /// [`tryPop`](Self.tryPop) continues to drain and returns `Closed` only
        /// once empty.
        ///
        /// Invalidates the `closed` reader only on the false → true transition.
        pub fn close(self: *Self) void {
            if (self.storage.isClosed()) return;
            self.storage.close();
            if (!self.closed_val) {
                self.closed_val = true;
                self.closed_version += 1;
            }
        }

        // -- reactive reader-kind reads --

        /// Reactive read of the current head value. `null` when the queue is
        /// empty. A reader is invalidated when the head value *changes* — every
        /// pop, and a push only when transitioning from empty.
        pub fn head(self: *const Self) ?T {
            return self.head_val;
        }

        /// Reactive read of the number of buffered elements. Invalidated
        /// whenever the count changes (every successful push/pop).
        pub fn len(self: *const Self) usize {
            return self.len_val;
        }

        /// Reactive emptiness check. Invalidated only on the empty ↔ non-empty
        /// transition.
        pub fn isEmpty(self: *const Self) bool {
            return self.is_empty_val;
        }

        /// Reactive fullness check (only meaningful when the backend is
        /// bounded). Invalidated on the full ↔ not-full transition — this is the
        /// backpressure signal: a producer observes `is_full` and backs off; a
        /// consumer's pop that transitions full → not-full bumps the `is_full`
        /// version and the producer observes capacity recovery. For an unbounded
        /// backend this is always `false` and never invalidates.
        pub fn isFull(self: *const Self) bool {
            return self.is_full_val;
        }

        /// Reactive read of the closed flag. Invalidated only on the open →
        /// closed transition.
        pub fn isClosed(self: *const Self) bool {
            return self.closed_val;
        }

        // -- reader-kind version counters (conformance observation) --

        /// Snapshot all five reader-kind version counters. Diff two snapshots
        /// across an op to observe exactly which reader kinds it invalidated.
        pub fn versions(self: *const Self) QueueVersions {
            return .{
                .head = self.head_version,
                .len = self.len_version,
                .is_empty = self.is_empty_version,
                .is_full = self.is_full_version,
                .closed = self.closed_version,
            };
        }

        pub fn headVersion(self: *const Self) u64 {
            return self.head_version;
        }
        pub fn lenVersion(self: *const Self) u64 {
            return self.len_version;
        }
        pub fn isEmptyVersion(self: *const Self) u64 {
            return self.is_empty_version;
        }
        pub fn isFullVersion(self: *const Self) u64 {
            return self.is_full_version;
        }
        pub fn closedVersion(self: *const Self) u64 {
            return self.closed_version;
        }

        // -- non-reactive storage access --

        /// The backend's capacity, or `null` if unbounded.
        pub fn capacity(self: *const Self) ?usize {
            return self.storage.capacity();
        }
    };
}

// ---------------------------------------------------------------------------
// Convenience: default shell over VecDequeStorage
// ---------------------------------------------------------------------------

/// Create an unbounded `QueueCell(T, VecDequeStorage(T))` (the default reference
/// backend) and return it by value.
pub fn newUnbounded(comptime T: type, ctx: *Context) QueueCell(T, VecDequeStorage(T)) {
    return QueueCell(T, VecDequeStorage(T)).init(
        ctx,
        VecDequeStorage(T).initUnbounded(ctx.allocator),
    );
}

/// Create a bounded `QueueCell(T, VecDequeStorage(T))` with `capacity`. Asserts
/// `capacity > 0`.
pub fn newBounded(comptime T: type, ctx: *Context, capacity: usize) QueueCell(T, VecDequeStorage(T)) {
    return QueueCell(T, VecDequeStorage(T)).init(
        ctx,
        VecDequeStorage(T).initBounded(ctx.allocator, capacity),
    );
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

test "lazily/queue: SPSC FIFO basic" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var q = newUnbounded(i32, ctx);
    defer q.storage.deinit();

    try std.testing.expect(q.isEmpty());
    try std.testing.expectEqual(@as(?i32, null), q.head());

    try q.tryPush(1);
    try q.tryPush(2);
    try q.tryPush(3);

    try std.testing.expectEqual(@as(usize, 3), q.len());
    try std.testing.expectEqual(@as(?i32, 1), q.head());
    try std.testing.expectEqualSlices(i32, &[_]i32{ 1, 2, 3 }, q.storage.items());

    try std.testing.expectEqual(@as(i32, 1), try q.tryPop());
    try std.testing.expectEqual(@as(i32, 2), try q.tryPop());
    try std.testing.expectEqual(@as(i32, 3), try q.tryPop());
    try std.testing.expectError(error.Empty, q.tryPop());
}

test "lazily/queue: bounded rejects at capacity (reactive backpressure)" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var q = newBounded(i32, ctx, 2);
    defer q.storage.deinit();

    try std.testing.expectEqual(@as(?usize, 2), q.capacity());
    try std.testing.expect(!q.isFull());

    try q.tryPush(1);
    try q.tryPush(2);
    try std.testing.expect(q.isFull());
    try std.testing.expectError(error.Full, q.tryPush(3));

    // pop frees a slot → is_full flips → reactive backpressure signal.
    try std.testing.expectEqual(@as(i32, 1), try q.tryPop());
    try std.testing.expect(!q.isFull());
    try q.tryPush(3);
    try std.testing.expect(q.isFull());
}

test "lazily/queue: closure lifecycle" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var q = newUnbounded([]const u8, ctx);
    defer q.storage.deinit();

    try q.tryPush("a");
    try q.tryPush("b");

    q.close();
    try std.testing.expect(q.isClosed());

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
    try std.testing.expect(q.isClosed());
    try std.testing.expectEqual(closed_before, q.closedVersion());
}

test "lazily/queue: reader-kind independence — head not invalidated on push to non-empty" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var q = newUnbounded(i32, ctx);
    defer q.storage.deinit();

    try std.testing.expectEqual(@as(?i32, null), q.head());

    try q.tryPush(1);
    // push to empty changes head → invalidated.
    try std.testing.expectEqual(@as(?i32, 1), q.head());
    const head_after_first = q.headVersion();

    try q.tryPush(2);
    try q.tryPush(3);
    // head reader still cached (head unchanged) — reader-kind independence.
    try std.testing.expectEqual(head_after_first, q.headVersion());
    try std.testing.expectEqual(@as(?i32, 1), q.head());

    _ = try q.tryPop();
    // pop changes head → invalidated.
    try std.testing.expect(q.headVersion() > head_after_first);
    try std.testing.expectEqual(@as(?i32, 2), q.head());
}

test "lazily/queue: MPSC via batch is one observable transition" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var q = newUnbounded(i32, ctx);
    defer q.storage.deinit();

    try std.testing.expectEqual(@as(usize, 0), q.len());

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

    try std.testing.expectEqual(@as(usize, 3), q.len());
    try std.testing.expectEqualSlices(i32, &[_]i32{ 10, 20, 30 }, q.storage.items());
}

test "lazily/queue: same shell, shared by reference (producer/consumer)" {
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    var q = newUnbounded(i32, ctx);
    defer q.storage.deinit();

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
        fn deinit(self: *@This()) void {
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
    var q = QueueCell(i32, Ring).init(ctx, storage);
    defer q.storage.deinit();

    try q.tryPush(1);
    try q.tryPush(2);
    try std.testing.expect(q.isFull());
    try std.testing.expectError(error.Full, q.tryPush(3));
    try std.testing.expectEqual(@as(i32, 1), try q.tryPop());
    try std.testing.expect(!q.isFull());
    try std.testing.expectEqual(@as(usize, 1), q.len());
    try std.testing.expectEqual(@as(?i32, 2), q.head());
}

// ---------------------------------------------------------------------------
// lazily-spec conformance fixture replay
// ---------------------------------------------------------------------------

const json = std.json;

fn readFixtureFile(path: []const u8) ![]u8 {
    if (comptime builtin.zig_version.minor >= 16) {
        return std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            path,
            std.testing.allocator,
            .limited(1024 * 1024),
        );
    }
    return std.fs.cwd().readFileAlloc(std.testing.allocator, path, 1024 * 1024);
}

fn jsonField(value: json.Value, name: []const u8) ?json.Value {
    return switch (value) {
        .object => |object| object.get(name),
        else => null,
    };
}

fn jsonFieldRequired(value: json.Value, name: []const u8) !json.Value {
    return jsonField(value, name) orelse error.MissingField;
}

fn jsonAsString(value: json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.ExpectedString,
    };
}

fn jsonAsU64(value: json.Value) !u64 {
    return switch (value) {
        .integer => |n| if (n >= 0) @as(u64, @intCast(n)) else error.ExpectedUnsignedInteger,
        .number_string => |s| try std.fmt.parseInt(u64, s, 10),
        else => error.ExpectedUnsignedInteger,
    };
}

fn jsonAsBool(value: json.Value) !bool {
    return switch (value) {
        .bool => |b| b,
        else => error.ExpectedBool,
    };
}

const Q = QueueCell([]const u8, VecDequeStorage([]const u8));

fn specFixturesPresent() bool {
    const path = "../lazily-spec/conformance/collections/queuecell_spsc_push_pop.json";
    const raw = readFixtureFile(path) catch return false;
    std.testing.allocator.free(raw);
    return true;
}

fn buildInitial(ctx: *Context, initial: json.Value) !Q {
    const cap: ?u64 = if (jsonField(initial, "capacity")) |c| switch (c) {
        .null => null,
        else => try jsonAsU64(c),
    } else null;
    var q = if (cap) |c| newBounded([]const u8, ctx, @intCast(c)) else newUnbounded([]const u8, ctx);
    if (jsonField(initial, "elements")) |elems| {
        switch (elems) {
            .array => |arr| {
                for (arr.items) |e| try q.tryPush(try jsonAsString(e));
            },
            else => {},
        }
    }
    // `closed` in initial is rare but supported: honor it.
    if (jsonField(initial, "closed")) |c| {
        if (try jsonAsBool(c)) q.close();
    }
    return q;
}

/// Assert the per-reader-kind invalidation matrix for one step. Only reader
/// kinds the fixture explicitly declares are asserted (mirrors lazily-rs
/// `assert_invalidation`); an absent kind means "don't check."
fn assertInvalidation(
    q: *Q,
    pre: QueueVersions,
    invalidates: ?json.Value,
) !void {
    const node = invalidates orelse return;
    const check = struct {
        fn ok(name: []const u8, before: u64, after: u64, inv_obj: json.Value) !void {
            const present = jsonField(inv_obj, name) orelse return;
            const expected_inv = try jsonAsBool(present);
            const changed = after != before;
            if (expected_inv) {
                try std.testing.expect(changed);
            } else {
                try std.testing.expect(!changed);
            }
        }
    };
    const post = q.versions();
    try check.ok("head", pre.head, post.head, node);
    try check.ok("len", pre.len, post.len, node);
    try check.ok("is_empty", pre.is_empty, post.is_empty, node);
    try check.ok("is_full", pre.is_full, post.is_full, node);
    try check.ok("closed", pre.closed, post.closed, node);
}

fn assertState(q: *Q, expected: json.Value) !void {
    if (jsonField(expected, "elements")) |elems| {
        switch (elems) {
            .array => |arr| {
                try std.testing.expectEqual(arr.items.len, q.storage.items().len);
                for (arr.items, q.storage.items()) |want, got| {
                    try std.testing.expectEqualStrings(try jsonAsString(want), got);
                }
            },
            else => {},
        }
    }
    if (jsonField(expected, "head")) |head_val| {
        const want: ?[]const u8 = switch (head_val) {
            .null => null,
            else => try jsonAsString(head_val),
        };
        try expectEqualStringsOpt(want, q.head());
    }
    if (jsonField(expected, "len")) |l| {
        try std.testing.expectEqual(@as(usize, @intCast(try jsonAsU64(l))), q.len());
    }
    if (jsonField(expected, "is_empty")) |b| {
        try std.testing.expectEqual(try jsonAsBool(b), q.isEmpty());
    }
    if (jsonField(expected, "is_full")) |b| {
        try std.testing.expectEqual(try jsonAsBool(b), q.isFull());
    }
    if (jsonField(expected, "closed")) |b| {
        try std.testing.expectEqual(try jsonAsBool(b), q.isClosed());
    }
}

/// expectEqualStringsOpt: compare two optional strings.
fn expectEqualStringsOpt(expected: ?[]const u8, actual: ?[]const u8) !void {
    if (expected == null and actual == null) return;
    try std.testing.expect(expected != null);
    try std.testing.expect(actual != null);
    try std.testing.expectEqualStrings(expected.?, actual.?);
}

/// Returns label for an op (an element string, or an error label) — `null` when
/// the fixture declares no `returns`.
fn returnsLabel(step: json.Value) ?[]const u8 {
    const r = jsonField(step, "returns") orelse return null;
    return switch (r) {
        .null => null,
        else => jsonAsString(r) catch null,
    };
}

fn runFixture(ctx: *Context, fixture: json.Value) !void {
    var q = try buildInitial(ctx, try jsonFieldRequired(fixture, "initial"));
    defer q.storage.deinit();

    const steps = switch (try jsonFieldRequired(fixture, "steps")) {
        .array => |a| a.items,
        else => return error.ExpectedArray,
    };

    for (steps, 0..) |step, i| {
        const op = try jsonFieldRequired(step, "op");
        const op_type = try jsonAsString(try jsonFieldRequired(op, "type"));
        const expected = jsonField(step, "expected") orelse json.Value.null;
        const invalidates = jsonField(expected, "invalidates");

        const pre = q.versions();

        var got_label: ?[]const u8 = null;
        if (std.mem.eql(u8, op_type, "push")) {
            const val = try jsonAsString(try jsonFieldRequired(op, "value"));
            try q.tryPush(val);
        } else if (std.mem.eql(u8, op_type, "try_push")) {
            const val = try jsonAsString(try jsonFieldRequired(op, "value"));
            q.tryPush(val) catch |err| {
                got_label = switch (err) {
                    error.Full => "Full",
                    error.Closed => "Closed",
                };
            };
        } else if (std.mem.eql(u8, op_type, "pop") or std.mem.eql(u8, op_type, "try_pop")) {
            got_label = q.tryPop() catch |err| switch (err) {
                error.Empty => "Empty",
                error.Closed => "Closed",
            };
        } else if (std.mem.eql(u8, op_type, "close")) {
            q.close();
        } else if (std.mem.eql(u8, op_type, "batch")) {
            // MPSC: per-producer pushes inside one batch() boundary. In the
            // version-counter model the per-op bumps already coalesce into a
            // single observable transition (the fixture asserts changed-or-not,
            // not how many times), so sequential replay yields the exact
            // `invalidates` matrix. Wrap in ctx.batch to honor the boundary.
            const Batch = struct {
                var q_ptr: *Q = undefined;
                var ops_ptr: []const json.Value = undefined;
                fn run(c: *Context) void {
                    _ = c;
                    for (ops_ptr) |inner| {
                        const ty = jsonAsString(jsonFieldRequired(inner, "type") catch json.Value.null) catch return;
                        if (!std.mem.eql(u8, ty, "push")) continue;
                        const val = jsonAsString(jsonFieldRequired(inner, "value") catch json.Value.null) catch return;
                        q_ptr.tryPush(val) catch {};
                    }
                }
            };
            Batch.q_ptr = &q;
            Batch.ops_ptr = switch (try jsonFieldRequired(op, "ops")) {
                .array => |a| a.items,
                else => return error.ExpectedArray,
            };
            ctx.batch(Batch.run);
        } else {
            std.debug.print("unknown queue op type: {s}\n", .{op_type});
            return error.UnknownOpType;
        }

        try assertState(&q, expected);

        if (returnsLabel(step)) |want| {
            try std.testing.expect(want.len > 0);
            const got = got_label orelse "";
            try std.testing.expectEqualStrings(want, got);
        }

        try assertInvalidation(&q, pre, invalidates);

        _ = i;
    }
}

test "lazily/queue conformance: queuecell_spsc_push_pop" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const raw = try readFixtureFile(
        "../lazily-spec/conformance/collections/queuecell_spsc_push_pop.json",
    );
    defer allocator.free(raw);

    var parsed = try json.parseFromSlice(json.Value, allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    try runFixture(ctx, parsed.value);
}

test "lazily/queue conformance: queuecell_popped_head_observation" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const raw = try readFixtureFile(
        "../lazily-spec/conformance/collections/queuecell_popped_head_observation.json",
    );
    defer allocator.free(raw);

    var parsed = try json.parseFromSlice(json.Value, allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    try runFixture(ctx, parsed.value);
}

test "lazily/queue conformance: queuecell_mpsc_multi_writer" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const raw = try readFixtureFile(
        "../lazily-spec/conformance/collections/queuecell_mpsc_multi_writer.json",
    );
    defer allocator.free(raw);

    var parsed = try json.parseFromSlice(json.Value, allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    try runFixture(ctx, parsed.value);
}

test "lazily/queue conformance: queuecell_bounded_backpressure" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const raw = try readFixtureFile(
        "../lazily-spec/conformance/collections/queuecell_bounded_backpressure.json",
    );
    defer allocator.free(raw);

    var parsed = try json.parseFromSlice(json.Value, allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    try runFixture(ctx, parsed.value);
}

test "lazily/queue conformance: queuecell_closure_lifecycle" {
    if (!specFixturesPresent()) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const ctx = try Context.init(allocator);
    defer ctx.deinit();

    const raw = try readFixtureFile(
        "../lazily-spec/conformance/collections/queuecell_closure_lifecycle.json",
    );
    defer allocator.free(raw);

    var parsed = try json.parseFromSlice(json.Value, allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    try runFixture(ctx, parsed.value);
}
