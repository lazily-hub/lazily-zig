# lazily-zig

A Zig library for lazy evaluation with context caching, reactive graphs, state
machines, CRDTs, and a distributed state plane — with FFI to use from other
languages.

Uses similar semantics as [lazily-py](https://github.com/btakita/lazily-py) and
mirrors the wire/logic contracts pinned by
[lazily-spec](https://github.com/lazily-hub/lazily-spec) and the Lean formal
model in [lazily-formal](https://github.com/lazily-hub/lazily-formal).

The main use case is Zig libraries for cross-platform logic via FFI. Building dynamic libraries for Native Apps/Flutter + servers and WASM for browsers.

## Feature coverage

The full `lazily` capability set across every binding. Legend: ✅ shipped ·
`~` partial · `—` absent or not applicable. The canonical matrix with per-cell
notes and platform carve-outs lives in
[`lazily-spec` § Cross-Language Coverage](../lazily-spec/docs/coverage.md).

<!-- coverage-table:start -->
| Feature | Rust | Python | Kotlin | JS | Dart | Zig | Go | C++ |
| --------- | :----: | :------: | :------: | :--: | :----: | :---: | :--: | :---: |
| Reactive graph — `Cell` / `Slot` / `Signal` / `Effect` / memo / batch | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Thread-safe context (lock-backed) | ✅ | ✅ | ✅ | — | — | ✅ | ✅ | ✅ |
| Async reactive context | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Flat state machine | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Harel state charts | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Keyed cell collections (`CellMap` / `CellTree`) + reconcile | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Memoized semantic tree (`SemTree`) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Stable-id alignment (manufactured identity) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Reactive queue (`QueueCell` SPSC/MPSC + `QueueStorage` adapter) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Free-text character CRDT (`TextCrdt`) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| `TextCrdt` delta sync (`version_vector` / `delta_since` / `apply_delta`) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Move-aware sequence CRDT (`SeqCrdt`) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Lossless tree CRDT core (`LosslessTreeCrdt`, M1) | ✅ | ✅ | ✅ | ✅ | ✅ | — | ✅ | ✅ |
| Lossless tree — dotted-frontier anti-entropy | ✅ | ✅ | ✅ | ✅ | ✅ | — | ✅ | ✅ |
| Lossless tree — concurrent merge convergence | ✅ | ✅ | ✅ | ✅ | ✅ | — | ✅ | ✅ |
| Registers (LWW / MV) + `PnCounter` + `CellCrdt` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| IPC wire — `Snapshot` + `Delta` + `CrdtSync` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Shared-memory blob path (`ShmBlobArena`) | ✅ | ✅ | ✅ | ~ | ~ | ✅ | ✅ | ✅ |
| Distributed CRDT plane (`CrdtPlaneRuntime` / anti-entropy) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Distributed plane — WebRTC transport + signaling | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| State projection / mirror | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Causal receipts (`CausalReceipts` outcome projection) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Message-passing + RPC command plane (`command-plane-v1`) | ✅ | ✅ | ✅ | ✅ | ✅ | — | ✅ | ✅ |
| C-ABI FFI boundary | ✅ | ✅ | ✅ | — | ✅ | ✅ | ✅ | ✅ |
| Permission boundary (`PeerPermissions` / `RemoteOp`) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Capability negotiation (`SessionHandshake`) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Instrumentation / benchmarks | ✅ | ✅ | ✅ | — | ✅ | ✅ | ✅ | ✅ |
<!-- coverage-table:end -->

## lazily-spec compliance

Every `lazily-spec` feature row is shipped for the Zig column (see the matrix
above). The conformance fixtures under `../lazily-spec/conformance` are
replayed by in-source deterministic tests in each module.

| Module | Surface |
|--------|---------|
| `src/lazily/ipc.zig` | Shared lazily IPC wire types (`IpcMessage`, `Snapshot`, `Delta`, `DeltaOp`, `NodeSnapshot`, `NodeState`, `ShmBlobArena`, `CapabilityHandshake`, `CrdtSync`). Round-trips the canonical fixtures using the same externally-tagged JSON shape as lazily-rs. |
| `src/lazily/context.zig` | Reactive `Context` (lazy cache + mutex), `Slot`, `TrackingFrame`, `Context.batch(run)` boundary, and always-on `Instrumentation` counters (`node_allocations`, `slot_recomputes`, `dependency_edges_*`, `effect_queue_*`). |
| `src/lazily/cell.zig` / `signal.zig` / `effect.zig` | `Cell` / `Signal` (eager, memo-guarded) / `Effect` (scheduled side effect) — the 4 reactive primitives. |
| `src/lazily/collection.zig` | `CellMap` / `CellFamily` with atomic move and three-signal (value/membership/order) independence. |
| `src/lazily/cell_tree.zig` | `CellTree` — ordered keyed tree composing `CellMap` per level (atomic child move, per-level reactivity). |
| `src/lazily/reconcile.zig` | LIS-move-minimized keyed reconciliation op-set (`DiffOp`, `reconcile`, `longestIncreasingSubsequence`). |
| `src/lazily/sem_tree.zig` | `SemTree` — memoized semantic tree; an edit recomputes only the ancestor chain (sibling isolation + memo guard). |
| `src/lazily/stable_id.zig` | Manufactured identity for text (FNV-1a content hashes, in-band anchors, word-LCS similarity alignment). |
| `src/lazily/crdt.zig` | `Hlc`, `LwwRegister`, `MvRegister`, `PnCounter`, `VersionVector`, `StampFrontier`, `OpId`. |
| `src/lazily/text_crdt.zig` | `TextCrdt` — RGA/origin-tree character CRDT with `version_vector` / `delta_since` / `apply_delta`. |
| `src/lazily/seq_crdt.zig` | `SeqCrdt` — move-aware sequence CRDT (fractional-index positions, three independent LWW registers per entry). |
| `src/lazily/crdt_plane.zig` | `CrdtPlane` (HLC + membership + stability watermark), `OpLog` (idempotent dedup), `CrdtPlaneRuntime` (anti-entropy, `syncFrame`/`ingest`). |
| `src/lazily/state_mirror.zig` | `StateGraphMirror` — read-only projection of a remote graph from `Snapshot`/`Delta` messages. |
| `src/lazily/webrtc_transport.zig` | The portable WebRTC seam: `DataChannel` vtable, permission-filtering `WebRtcSink` / verbatim `WebRtcSource`, `InMemoryDataChannel` loopback pair. The concrete native backend is a consumer-provided adapter. |
| `src/lazily/signaling.zig` | Signaling protocol wire types (`ClientMessage`/`ServerMessage`) + in-process `SignalingRoom` (anti-spoof `from` stamping). |
| `src/lazily/async_context.zig` | `AsyncContext` — task-queue + `settle()` drain surface for the async reactive plane (Zig has no language async; revision tracking implements stale-completion discard). |
| `src/lazily/receipt.zig` | `CausalReceipts` outcome projection (`ReceiptOutcome`, `ReceiptProjection`). |
| `src/lazily/permission.zig` | `PeerPermissions` / `RemoteOp` default-deny allowlist. |
| `src/lazily/state_machine.zig` / `statechart.zig` | Flat `StateMachine(S,E)` + Harel `StateChart` (compound, orthogonal, history, actions, guards). |

Signals do not introduce a separate wire type. A producer-side eager Signal is
observed as its backing slot node: snapshots carry a materialized `NodeState`,
and value changes are emitted as `DeltaOp.SlotValue`.

## Test Build

This project uses mise.

[Install mise](https://mise.jdx.dev/getting-started.html)

```sh
mise trust
```

```sh
mise run test
# mise run test_0_15_2
# mise run test_master
```

The default build does not link libc. Use `zig build -Dlink_libc=true` when an
embedding artifact needs libc-backed allocator or C runtime symbols.

## Benchmarks

See [BENCHMARKS.md](BENCHMARKS.md) for measured results, methodology, and a
cross-language comparison with lazily-rs and lazily-cpp. Two surfaces:

- **Reactive-core micro-bench** — counter-based instrumentation deltas for the
  hot paths (cached reads, cold get, fan-out invalidation, memo-guard
  suppression), mirroring the lazily-rs `context` benches. Zig 0.17-dev has no
  `std.time.Timer`, so it measures deterministic work-counts instead of a wall
  clock.

  ```sh
  zig build bench
  ```

- **Spreadsheet-scale bench** — a spreadsheet-shaped graph (`N` input cells +
  `N` formula slots, `formula[i] = input[i] + input[i-1]`) covering build, cold
  full recalc, one-input-edit + bounded-viewport read, and full-sheet
  invalidation. Wall-clock timed via `clock_gettime(.MONOTONIC)`. Scales to a
  full **10,000,000-cell Google Sheets workbook** (`LAZILY_SCALE_N=5000000`); a
  one-cell edit + viewport read stays in the **~6-7 µs** range at both 2M and
  10M cells because off-viewport formulas are never recomputed.

  ```sh
  zig build bench-scale                              # default N=1,000,000 (~2M cells)
  LAZILY_SCALE_N=5000000 zig build bench-scale       # 10M-cell workbook
  ```

## Terminology

### Context

A Context is a container for Slots, providing a way to group related Slots together and manage their evaluation context. A Context manages memory with a passed in allocator.

```zig
const ctx = Context.init(allocator);
```

### Slot

A Slot is the basic building block of lazy evaluation. It stores a lazy function return value in the cache. Slots can have dependencies on other Slots. When a parent Slot changes, the child slots expire.

`Slot.touch()` will expire the current Slot and child Slots. 

### Cell

Cells are mutable containers stored in a Slot. Using `Cell.set()` expires child slots, which can include Child slots containing Cells.

### Signal

A `Signal(T)` is an eager derived value backed by a memoized slot with deferred
recompute. Unlike a lazy Slot (which recomputes on read), a Signal **eagerly**
recomputes the instant any of its dependencies are invalidated. Recompute runs
outside the graph mutex via `Context.drainPendingRecompute`, so user `valueFn`s
may re-lock per-op without deadlock; a memo guard (`std.meta.eql`) suppresses
downstream cascades when the recomputed value is unchanged. Mirrors
`SignalHandle<T>` in lazily-rs and `Signal[T]` in lazily-py.

### StateMachine

A `StateMachine(S, E)` is a finite state machine backed by a reactive `Cell`.
The state lives in a `Cell(S)` so any Slot that reads the machine's state is
automatically invalidated when the machine transitions. The transition function
is pure — `fn(*const S, E) ?S`: returning `null` rejects the event (guard),
returning a value accepts it and sets the cell. A self-transition to an equal
state is accepted but suppressed by the Cell's `std.meta.eql` guard, so no
downstream cascade fires. Mirrors `StateMachine<S, E>` in lazily-rs and
`StateMachine[S, E]` in lazily-py.

### StateChart

A `StateChart` is a full Harel/SCXML hierarchical state machine backed by a
reactive `Cell(Config)`. It is **compute, not protocol** — only its converged
active configuration lives in a cell, so any Slot/Signal reading the
configuration is invalidated on a real transition; a no-op self-transition is
suppressed by the Cell's `std.meta.eql` guard.

Implemented subset (per `lazily-spec`): compound (nested) states, orthogonal
(**parallel**) regions, shallow + deep **history**, entry/exit/transition
**actions**, named **guards** (fail-closed), and external + internal
transitions. Extended-state `{"expr": …}` guards and `run` actions are rejected
explicitly; `final` states are accepted as leaves. `send` returns `true` when a
transition is taken, `false` when rejected. Conforms to the canonical
`lazily-spec/conformance/statechart` fixtures and mirrors `lazily-rs`
`StateChart` / the Lean model in `lazily-formal`. One `StateChart` per
`Context` (the configuration cell is keyed by a comptime value function).

### Batch

`Context.batch(run)` is a public coalescing boundary: multiple `Cell.set`
calls inside `run` commit their values synchronously but defer the eager-
recompute flush to the outermost batch exit, so N writes produce a single
Signal/Effect rerun (`lazily-spec/docs/reactive-graph.md` § batch).

### Keyed collections

`CellMap(K, V)` is a keyed reactive collection with three independent reader
classes (value / membership / order) — a value write never invalidates
membership or order readers, and a pure reorder never invalidates membership or
value readers. `moveTo` / `moveBefore` / `moveAfter` are atomic in-place
reorders (the entry's handle and dependents survive). `CellTree(Id, V)`
composes one `CellMap` per level for an ordered keyed tree. `reconcile(old,
new)` diffs two keyed sequences by stable key and emits the move-minimized
`{insert, remove, move, update}` op-set (LIS over prior indices preserved).

### CRDTs

The CRDT suite is in `src/lazily/crdt.zig`, `text_crdt.zig`, and
`seq_crdt.zig`:

- `LwwRegister(V)` — last-writer-wins by HLC stamp; ties go to the incumbent.
- `MvRegister(V)` — multi-value; concurrent writes surface as a set, a causal
  write collapses them.
- `PnCounter` — per-peer increment/decrement tallies merged by per-peer max.
- `TextCrdt` — RGA/origin-tree character CRDT with sticky-min tombstones;
  `version_vector` / `delta_since` / `apply_delta` for delta sync.
- `SeqCrdt(Id, V)` — move-aware sequence CRDT; each element is three
  independent LWW registers (value, fractional-index position, deleted), so a
  move is a single LWW reassignment (no delete+reinsert duplication) and a
  concurrent move + value-edit both apply.

### Distributed plane

`CrdtPlaneRuntime` (`crdt_plane.zig`) owns the HLC, the per-peer stamp
frontier (whose min-over-membership is the causal-stability watermark), an
idempotent `OpLog`, and the per-node LWW register map. `ingest(CrdtSync)` is
idempotent on re-delivery (state-based CvRDT); `localUpdate` mints a fresh
op; `syncFrame`/`syncFrameSince` produce pull replies.

`webrtc_transport.zig` ships the portable transport seam — `DataChannel`
vtable, permission-filtering `WebRtcSink` (omission, not redaction), verbatim
`WebRtcSource`, and `InMemoryDataChannel` loopback pair. `signaling.zig`
ships the wire types + an in-process `SignalingRoom`. The concrete native
WebRTC backend is a consumer-provided platform adapter (matching Kotlin).

### Async context

`AsyncContext` (`async_context.zig`) is the async reactive plane. Zig removed
language `async` and has no suspendable executor, so this layer is a task-
queue + `settle()` drain — the synchronous graph's `pending_recompute` /
`drainPendingRecompute` generalized with a 4-state slot machine
(`Empty`/`Computing`/`Resolved`/`Error`) and revision tracking that discards
superseded (stale) completions.

### Instrumentation

`Context.instrumentationSnapshot()` / `resetInstrumentation()` expose six
always-on counters (`node_allocations`, `slot_recomputes`,
`dependency_edges_added`/`_removed`, `effect_queue_pushes`,
`max_effect_queue_depth`). `zig build bench` runs the benchmark suite
(`src/benches/bench.zig`).

## Multi-threading

By default, lazily supports multi-threading using
`Context.mutex`. The performance should be ok for most usages. A more efficient implementation will be implemented as needed.

To disable multi-threading, add the `thread_safe` build option. Then set
`-Dthread_safe=false` build option.

To add the `thread_safe` build option, use:

```zig
pub fn build(b: *std.Build) void {
    // ...
    
    const thread_safe = b.option(
    bool,
    "thread_safe",
    "Enable thread-safety features (default: true)",
    ) orelse true;
    const build_options = b.addOptions();
    build_options.addOption(bool, "thread_safe", thread_safe);
    
    // ...
}
```

Also wrap the allocator passed into `Context.init` with `std.heap.ThreadSafeAllocator`. See the [ThreadSafeAllocator source code](https://codeberg.org/ziglang/zig/src/branch/master/lib/std/heap/ThreadSafeAllocator.zig).

## Example Usage

- [auth](./src/examples/auth/root.zig)
- [cells](./src/examples/cells/root.zig)

## See also

- [lazily-spec](https://github.com/lazily-hub/lazily-spec) — language-agnostic wire protocol + conformance fixtures
- [lazily-formal](https://github.com/lazily-hub/lazily-formal) — Lean 4 formal model: the executable reference behind the conformance fixtures (flat FSM kernel + Harel state chart + reactive graph + keyed collections/reconciliation + memoized semantic tree + manufactured identity + text/sequence CRDTs + async lifecycle + distributed signaling)
