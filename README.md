# lazily-zig

A Zig library for lazy evaluation with context caching...With FFI to use with other languages.

This project is still in early stages. Will use similar semantics as [lazily-py](https://github.com/btakita/lazily-py).

The main use case is Zig libraries for cross-platform logic via FFI. Building dynamic libraries for Native Apps/Flutter + servers and WASM for browsers.

## Feature coverage

The full `lazily` capability set across every binding. Legend: ✅ shipped ·
`~` partial · `—` absent or not applicable. The canonical matrix with per-cell
notes and platform carve-outs lives in
[`lazily-spec` § Cross-Language Coverage](../lazily-spec/docs/coverage.md).

<!-- coverage-table:start -->
| Feature | Rust | Python | Kotlin | JS | Dart | Zig |
| --------- | :----: | :------: | :------: | :--: | :----: | :---: |
| Reactive graph — `Cell` / `Slot` / `Signal` / `Effect` / memo / batch | ✅ | ~ | ✅ | ✅ | ~ | ~ |
| Thread-safe context (lock-backed) | ✅ | ✅ | ✅ | — | — | ✅ |
| Async reactive context | ✅ | ✅ | ✅ | ✅ | ✅ | — |
| Flat state machine | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Harel state charts | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Keyed cell collections (`CellMap` / `CellTree`) + reconcile | ✅ | ✅ | ✅ | ✅ | ✅ | ~ |
| Memoized semantic tree (`SemTree`) | ✅ | — | ✅ | ✅ | — | — |
| Stable-id alignment (manufactured identity) | ✅ | — | ✅ | ✅ | — | — |
| Free-text character CRDT (`TextCrdt`) | ✅ | — | ✅ | ✅ | — | — |
| `TextCrdt` delta sync (`version_vector` / `delta_since` / `apply_delta`) | ✅ | — | ✅ | ✅ | — | — |
| Move-aware sequence CRDT (`SeqCrdt`) | ✅ | — | ✅ | ✅ | — | — |
| Registers (LWW / MV) + `PnCounter` + `CellCrdt` | ✅ | — | ✅ | ✅ | — | — |
| IPC wire — `Snapshot` + `Delta` + `CrdtSync` | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Shared-memory blob path (`ShmBlobArena`) | ✅ | ✅ | ✅ | ~ | ~ | ✅ |
| Distributed CRDT plane (`CrdtPlaneRuntime` / anti-entropy) | ✅ | — | ✅ | ✅ | ~ | — |
| Distributed plane — WebRTC transport + signaling | ✅ | — | ✅ | ✅ | — | — |
| State projection / mirror | ✅ | — | ✅ | ✅ | — | — |
| C-ABI FFI boundary | ✅ | ✅ | ✅ | — | ✅ | ✅ |
| Permission boundary (`PeerPermissions` / `RemoteOp`) | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| Capability negotiation (`SessionHandshake`) | ✅ | — | ✅ | ✅ | ✅ | ✅ |
| Instrumentation / benchmarks | ✅ | — | — | — | — | — |
<!-- coverage-table:end -->

## lazily-spec compliance

`src/lazily/ipc.zig` defines the shared lazily IPC wire types (`IpcMessage`,
`Snapshot`, `Delta`, `DeltaOp`, `NodeSnapshot`, `NodeState`, shared-blob
references, and capability handshakes). The module round-trips the canonical
fixtures from `../lazily-spec/conformance`, using the same externally tagged
JSON shape as lazily-rs.

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

### Reactor (TODO)

A Reactor changes in the evaluation context, allowing for automatic recomputation of dependent Slots when the context changes. A recomputation will expire dependent Slots. A dependent Reactor will expire and recompute.

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
