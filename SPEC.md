# lazily-zig Specification

Zig library for lazy evaluation with context caching, dependency tracking, and FFI support.

## Core Concepts

### Context

A container for all slots and their cached values. Manages memory via a passed-in allocator.

- `Context.init(allocator)` — Create a new context
- `Context.deinit()` — Destroy all slots and deallocate
- `Context.getSlot(fnc)` — Retrieve a cached slot by function pointer

Thread-safe by default via mutex (disable with `-Dthread_safe=false`).

### Slot

Lazily-computed cached value with dependency tracking. Slots are keyed by function address (or custom key via `slotKeyed`).

**Creation:**

| Function | Purpose |
|----------|---------|
| `slot(T, ctx, valueFn, deinitPayload)` | Create/retrieve a slot |
| `slotKeyed(T, ctx, cache_key, valueFn, deinitPayload)` | Slot with custom cache key |
| `initSlotFn(T, valueFn, deinitPayload)` | Factory returning `fn(*Context) !Slot.Result(T)` |

**Value access:**

| Method | Purpose |
|--------|---------|
| `Slot.get(T)` | Retrieve cached value (pointer for indirect mode) |
| `Slot.getPtr(T)` | Get pointer to value (indirect mode only) |

**Lifecycle:**

| Method | Purpose |
|--------|---------|
| `Slot.destroy(recurse)` | Destroy slot (optionally recursive) |
| `Slot.touch()` | Expire slot and all dependents |
| `Slot.emitChange()` | Invalidate all dependent slots (not self) |

**Storage modes:**

- `.direct` — `T` is a pointer/slice; stored without allocation. `Result(T) = T`
- `.indirect` — `T` is a struct/primitive; allocated via context. `Result(T) = *T`

### Cell

Mutable value container stored in a Slot. Changing a Cell invalidates all dependent slots.

**Creation:**

| Function | Purpose |
|----------|---------|
| `Cell(T).init(ctx, valueFn, deinitCellValue)` | Create a cell |
| `cell(T, ctx, valueFn, deinitFn)` | Convenience: create/retrieve cell |
| `initCellFn(T, valueFn, deinitCellValue)` | Factory returning `fn(*Context) !*Cell(T)` |

**Operations:**

| Method | Purpose |
|--------|---------|
| `Cell.get()` | Read current value |
| `Cell.set(new_value)` | Update value, invalidate dependents |
| `Cell.subscribe(callback)` | Register change callback (deduplicated) |
| `Cell.unsubscribe(callback)` | Remove change callback |

### Owned

Wrapper distinguishing owned vs borrowed values for memory management.

- `Owned.managed(value)` — Owned, will be freed
- `Owned.literal(value)` — Borrowed, won't be freed
- `OwnedString = Owned([]const u8)`

## Dependency Tracking

Uses a thread-local tracking stack (`TrackingFrame` linked list).

1. When a slot computes, it pushes a frame onto the stack
2. Any nested `slot()` call sees the parent frame via `currentSlotFor(ctx)`
3. The child subscribes the parent as a dependent (`subscribeChange`)
4. When a dependency changes (`emitChange`), all dependents are destroyed and removed from cache
5. Next access recomputes the slot, re-establishing dependencies

## Invalidation Semantics

- `Cell.set()` → `Slot.emitChange()` → destroys all dependent slots (not the cell slot itself)
- `Slot.touch()` → destroys the slot AND all dependents recursively
- Destroyed slots are removed from the context cache; they recompute on next access

## FFI Support

`StringView` provides a C-compatible string type:

```zig
pub const StringView = extern struct {
    ptr: [*]const u8,
    len: usize,
    errno: c_uint,
    errmsg: ?[*]const u8,
};
```

Export functions via `@export` with `.c` calling convention.

## Build

```bash
zig build        # Build library
zig build test   # Run tests
```

Build options: `-Dthread_safe=false` to disable mutex locking.
