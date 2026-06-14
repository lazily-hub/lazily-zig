# lazily-zig

A Zig library for lazy evaluation with context caching...With FFI to use with other languages.

This project is still in early stages. Will use similar semantics as [lazily-py](https://github.com/btakita/lazily-py).

The main use case is Zig libraries for cross-platform logic via FFI. Building dynamic libraries for Native Apps/Flutter + servers and WASM for browsers.

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
