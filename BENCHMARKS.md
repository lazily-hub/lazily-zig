# lazily-zig Benchmarks

Two benchmark surfaces for the lazily-zig hot paths:

- a **reactive-core micro-bench** ([`src/benches/bench.zig`](src/benches/bench.zig),
  `zig build bench`) mirroring the lazily-rs `benches/context.rs` scenarios, and
- a **spreadsheet-scale bench** ([`src/benches/scale_bench.zig`](src/benches/scale_bench.zig),
  `zig build bench-scale`) replicating the lazily-rs `scale` group
  ([`scale.rs`][rs-scale]) and lazily-go (`scale_bench_test.go`) on a graph of up
  to 10,000,000 cells (a full Google Sheets workbook).

## A note on measurement

Zig 0.17-dev removed **both** `std.time.Timer` and `std.time.nanoTimestamp`, so
the two benches measure differently and this is called out honestly:

- The **micro-bench is counter-based**: it reports
  `Context.instrumentationSnapshot()` deltas (`node_allocations`,
  `dependency_edges_added`, `slot_recomputes`, `effect_queue_pushes`,
  `max_effect_queue_depth`). For a reactive graph these deterministic
  work-counts are more stable and more meaningful than a wall clock — they
  measure *how much work each operation does*, independent of machine noise.
- The **scale bench is wall-clock**: it reads a monotonic clock directly via
  `std.os.linux.clock_gettime(.MONOTONIC)` (the only portable monotonic source
  left in this toolchain) and reports milliseconds / microseconds.

Treat the absolute wall-clock numbers as indicative; the shapes (relative
costs, the flat viewport curve) are what matter across runs.

### Hardware / environment

| | |
|---|---|
| CPU | AMD Ryzen 9 9950X3D (16 cores / 32 threads) |
| RAM | 186 GiB |
| OS | Linux 7.1.1 (CachyOS), x86-64 |
| Zig | 0.17.0-dev.892+54537285c |

## Reproduce

```bash
zig build bench             # fast reactive-core micro-bench (counter-based)
zig build bench-scale       # spreadsheet-scale bench (wall-clock), default N=1,000,000
zig build bench-contention  # graph-mutex contention: ParkingMutex vs Spinlock
```

## Reactive-core micro-bench (`zig build bench`)

Counter deltas per scenario — lower means less work per op. Built `ReleaseFast`.

| Benchmark | iters | node_allocs | edges_added | recomputes | queue_pushes | max_depth | What it measures |
|-----------|------:|------------:|------------:|-----------:|-------------:|----------:|------------------|
| `cached_reads` | 100,000 | 0 | 0 | 0 | 0 | 0 | Warm-cache slot re-reads — steady state is **zero work**: no allocation, no edge churn, no recompute. |
| `cold_first_get` | 1,000 | 1,000 | — | — | — | — | Fresh `Context` + one slot per iteration: exactly **one node allocation** per cold materialization. |
| `set_cell_invalidation_fan_out_256` | 1,000 | 0 | 0 | 0 | 0 | 0 | Invalidate a cell with 256 lazy dependents — invalidation destroys dependents lazily, so **no eager recompute** work is spent until something is re-read. |
| `memo_equality_suppression` | 1,000 | 0 | 1,000 | 1,000 | 1,000 | 1 | An eager `Signal` whose recomputed value is unchanged: it **does** recompute (1 per set) and re-track its edge, but the memo guard keeps the effect-queue depth at 1 and suppresses the downstream cascade. |

### Notes

- The reactive-core steady state (`cached_reads`) is **zero-allocation,
  zero-recompute** — cached reads only walk the `usize`-keyed slot map.
- `set_cell_invalidation_fan_out_256` shows the lazy model's defining property:
  a `Cell.set` invalidates (destroys) dependent slots but spends **no recompute
  work** — the cost is deferred to the next pull, and off-path dependents that
  are never re-read cost nothing.
- `memo_equality_suppression` is the eager-`Signal` path: it recomputes on every
  source set (`recomputes=1000`) but the memo guard (`std.meta.eql`) keeps the
  effect-queue high-water mark at `1`, i.e. the equal-value result never fans
  out downstream.
- These are single-threaded. The concurrency surfaces (`AsyncContext`,
  `SignalingRoom`, `CrdtPlaneRuntime`) are correctness-tested, not benchmarked
  here.

## Scale (≥1M cells) — spreadsheet-shaped graph

Replicates the lazily-rs `scale` group ([`scale.rs`][rs-scale]) on a
spreadsheet-shaped graph: `N` input cells + `N` formula slots where
`formula[i] = input[i] + input[i-1]` (local fan-in, like a column of
`=A_i + A_{i-1}`). With the default `N = 1,000,000` that is **~2,000,000 reactive
nodes** once every formula has been pulled. Defined in
[`src/benches/scale_bench.zig`](src/benches/scale_bench.zig), gated behind its
own `zig build bench-scale` step so a plain `zig build bench` skips the heavy
build. Size and viewport are env-configurable:

```bash
zig build bench-scale
LAZILY_SCALE_N=1000000 LAZILY_SCALE_VIEWPORT=1000 zig build bench-scale
LAZILY_SCALE_N=5000000 zig build bench-scale   # Google Sheets 10M-cell workbook
```

> **A "cell count" here counts two cells per row** — the graph models a column of
> formulas `=A_i + A_{i-1}`, so each row is **one input cell `A_i` plus one
> formula cell**. `N` rows ⇒ `N` inputs + `N` formulas = `2N` cells. `ns/cell`
> below is always `wall_time / 2N`, matching the lazily-go / lazily-rs reports.

> **How the Zig graph is built.** lazily-zig's reactive graph is
> *comptime-function keyed* — a slot's cache key comes from the address of a
> comptime `valueFn`, and a Zig `valueFn` cannot close over a runtime index. A
> spreadsheet needs `N` *distinct* inputs and `N` *distinct* formulas, so the
> bench uses the keyed escape hatch (`Slot.initKeyed` / `slotKeyed` with a
> runtime cache key) plus a module-global the value functions consult for "which
> index am I". The reactive shape is faithful (real dependency edges, real lazy
> invalidation, real local fan-in); only the closure-capture is simulated.
> One consequence: Zig's slot model computes eagerly on creation (there is no
> "register a formula without computing it"), so `build` materializes the `N`
> **input** nodes only — the other `N` formula nodes are materialized lazily on
> first read, which is exactly what `cold_full_recalc` measures. Total after a
> cold pass = `2N` nodes, matching lazily-rs / lazily-go.

### 1,000,000 rows (~2M cells)

| Benchmark | Time | Per cell | What it measures |
|-----------|-----:|---------:|------------------|
| `build` | 120 ms | ~60 ns | Construct the N input nodes (formulas lazy, not yet materialized). |
| `cold_full_recalc` | 275 ms | ~138 ns | First read of every formula — materializes all N formula slots + edges and computes them. |
| `viewport_recalc` | **10.4 µs** | — | Edit one input, read only a 1,000-cell viewport. ~38,000× cheaper than a full recalc. |
| `full_recalc_invalidate_all` | 403 ms | ~202 ns | Touch every input, then read every formula (worst-case full-sheet edit). |

### 5,000,000 rows (10M cells — a full Google Sheets workbook)

Google Sheets caps a workbook at **10,000,000 cells**. Modeled as 5,000,000
input cells + 5,000,000 formula cells (`LAZILY_SCALE_N=5000000`, measured with
`heavy reps = 1` since each heavy pass rebuilds the whole sheet):

| Benchmark | Time | Per cell | What it measures |
|-----------|-----:|---------:|------------------|
| `build` | 862 ms | ~86 ns | Build the 5M input nodes of a full 10M-cell workbook. |
| `cold_full_recalc` | 2.29 s | ~229 ns | Materialize + compute all 5M formulas cold. |
| `viewport_recalc` | **10.6 µs** | — | Edit one input, read a 1,000-cell viewport. ~297,000× cheaper than a full recalc. |
| `full_recalc_invalidate_all` | 3.15 s | ~315 ns | Re-edit every input, recompute the whole workbook. |

So lazily-zig backs a **full-capacity Google Sheets workbook**: build ~0.86 s,
full cold recompute ~2.3 s, and a one-cell edit + bounded-viewport read stays in
the **~10-11 µs** range — because the lazy pull-based model leaves off-viewport
formulas dirty and never recomputes them (only ~2 formulas actually recompute
per edit, regardless of sheet size — the property a viewport-rendered
spreadsheet needs).

### Spreadsheet cell-count context

| Spreadsheet | Documented limit | Cells |
|-------------|------------------|------:|
| Google Sheets | 10,000,000 cells per workbook (18,278 columns max) | 10,000,000 |
| Microsoft Excel | 1,048,576 rows × 16,384 columns per worksheet | 17,179,869,184 |

The `LAZILY_SCALE_N=5000000` run above covers a full Google Sheets workbook. A
grid-complete Excel worksheet (17 billion cells) is unrepresentative — real
sheets populate a tiny fraction of the grid, and lazily stores only the cells
you create, so the `scale` group measures the populated-cell path that matters.

### A note on viewport scaling

lazily-zig's viewport recalc is **effectively size-independent** — ~10.4 µs at
2M cells and ~10.6 µs at 10M cells. This matches lazily-rs's flat curve (and is
*better* than lazily-go, whose viewport grows from ~25 µs to ~103 µs with sheet
size). Two reasons:

1. **Recompute count is viewport-bounded, not sheet-bounded.** Editing one input
   destroys only the ~2 formulas that read it; the viewport read re-materializes
   just those, and every other formula in the viewport is a warm-cache hit. The
   number of actual recomputes per edit is ~2 regardless of `N`.
2. **The value cache is a single `AutoHashMap(usize, *Slot)` keyed by an integer
   cache key**, so a viewport read does ~1,000 O(1) integer-keyed lookups whose
   latency does not grow meaningfully with total sheet size — no per-node
   identity hashing over a multi-GB structure.

The `~38,000×` / `~297,000×` speedups above are `full_recalc / viewport` for the
respective sizes: a bounded-viewport edit never pays for the off-viewport sheet.

### Honest caveats

- **Micro-bench vs. scale bench measure different things** (counter deltas vs.
  wall clock) — see *A note on measurement* above. The micro-bench numbers are
  exact and reproducible; the scale wall-clock numbers carry normal
  machine-level variance (build/cold/full are reported as the best of the heavy
  reps; viewport is the average of 1,000 edits).
- **The scale graph uses the runtime-keyed `Slot` escape hatch**, not the
  idiomatic comptime-keyed `cell()`/`slot()` (which cannot model `N` distinct
  runtime-indexed nodes). The reactive semantics exercised — dependency
  tracking, invalidate-in-place (`#lzinplace`, v1.0.0), local fan-in, memoized
  warm reads — are the real library paths.
- **Allocator:** the scale bench uses an `ArenaAllocator` over `page_allocator`,
  fresh per scenario (`cold_full_recalc` allocates a new arena **per rep**, so
  its number is churn-free). Since `#lzinplace` (v1.0.0) invalidation recomputes
  values in place rather than destroying and re-creating slots, the churn
  scenarios (`viewport_recalc`, `full_recalc_invalidate_all`) no longer
  re-allocate slots per rep — arena growth is bounded to the one-time
  materialization, and `full_recalc_invalidate_all` takes the min over reps.
  Rep counts are still kept small for large `N` to bound peak memory, and the
  arena is torn down between scenarios.
- **`build` materializes N nodes, not 2N**, because Zig has no
  register-without-compute; the remaining N formula nodes appear in
  `cold_full_recalc`. Per-cell figures still divide by `2N` for cross-language
  comparability.

## Thread-safe contention — graph mutex under load (`#lzcontentionbench`)

`zig build bench-contention` — N worker threads hammer `lock + counter++ + unlock`
on a shared lock for a fixed 100 ms window; completed ops are counted and reported
as throughput (Mops/s) and latency (ns/op). Head-to-head: the new `ParkingMutex`
(`#lzparkingmutex`, Linux futex-backed) vs the previous busy-wait spinlock over
`std.atomic.Mutex`. Both vendored in-binary for a controlled before/after comparison.

Built `ReleaseFast`, window = 100 ms per (policy × thread count), warmup pass before
each measurement.

| Threads | ParkingMutex (Mops/s) | ParkingMutex (ns/op) | Spinlock (Mops/s) | Spinlock (ns/op) | ParkingMutex speedup |
|---:|---:|---:|---:|---:|---:|
| 1 | 85.8 | 11.7 | 127.1 | 7.9 | 0.67× |
| 2 | 23.4 | 42.7 | 24.9 | 40.1 | 0.94× |
| 4 | 13.8 | 72.3 | 9.3 | 107.8 | **1.49×** |
| 8 | 13.6 | 73.3 | 5.3 | 187.4 | **2.55×** |
| 16 | 13.0 | 76.9 | 2.8 | 356.5 | **4.63×** |

### What the numbers say

- **N=1 (uncontended):** the spinlock's fast path is a single `tryLock` cmpxchg
  with no function-call overhead (~7.9 ns); the parking mutex pays ~3.8 ns for
  its slightly larger fast path + the `lockSlow` plumbing. This is the
  deliberate trade — ~4 ns slower per uncontended acquire, in exchange for the
  scaling wins below.
- **N=4–16 (contended):** this is the load cliff the spinlock hit. Its
  busy-wait (`while (!tryLock()) {}`) means N−1 spinning cores hammer the cache
  line holding the lock word, stealing memory bandwidth from whichever thread
  actually holds the lock — so latency balloons from 108 → 187 → 357 ns as N
  grows 4 → 8 → 16, and throughput collapses 9.3 → 5.3 → 2.8 Mops/s. The parking
  mutex parks contended threads in the kernel via the Linux `futex` syscall, so
  the lock holder runs unimpeded: latency stays **bounded** (72 → 73 → 77 ns
  across N=4 → 8 → 16) and throughput stays **flat** (~13–14 Mops/s).
- **The 16-thread headline:** 4.63× higher throughput, 4.63× lower latency.
  This is the property that matters for a high-load system — the lock stops
  being the bottleneck once contention exceeds a couple of threads.

### Why direct lock measurement (not `slot.get()`)

The ideal workload — N threads doing `slot.get()` on a shared Context — cannot
currently run on lazily-zig: the `slot()` / `Slot.initKeyed` materialization
path has a pre-existing concurrency bug where 4+ threads concurrently calling
`slot()` on the same Context cause the process to exit (root cause not yet
isolated; appears to be in the slot materialization path, not the lock). That
is tracked as a separate follow-up — it is **orthogonal** to the parking mutex
itself, which is proven correct by the 8-thread × 100k-iteration soak test in
`parking_mutex.zig` (zero lost updates). Measuring the lock directly isolates
exactly the code this optimization changed, with no contribution from the
orthogonal slot-path bug.

## Optimizations Applied (v0.8.0)

v0.8.0 ships **the parking mutex** — the first high-load lever from the
optimization plan, targeting the graph-mutex contention cliff rather than
micro-benchmark gaming.

1. **`ParkingMutex` (`src/lazily/parking_mutex.zig`, `#lzparkingmutex`) —**
   replaces the busy-wait spinlock over `std.atomic.Mutex` (the Zig ≥0.16
   fallback after `std.Thread.Mutex` was removed in the stdlib's Io rework).
   Classic 3-state futex mutex (Drepper, "Futexes are tricky"): fast path is
   one `cmpxchg` (uncontended — no syscall); contended threads spin a bounded
   64 iterations, then arm a CONTESTED bit and park on `FUTEX_WAIT`. The
   load-bearing property: an unlocker only issues `FUTEX_WAKE` when a waiter
   has actually parked, so the uncontended path never enters the kernel.

2. **Linux futex syscall (`std.os.linux.futex_4arg` / `futex_3arg`) —** the
   primary platform (per the hardware/environment above) gets a real parking
   mutex. Other targets fall back to `std.Thread.yield()` — correct but less
   efficient under heavy contention; documented as the non-Linux limitation.
   This is the same honest scoping the rest of the benches do (e.g.
   `clock_gettime(.MONOTONIC)` for timing).

3. **`bench-contention` step (`src/benches/contention_bench.zig`,
   `#lzcontentionbench`) —** the contention baseline that gates and proves the
   win. Mirrors lazily-cpp v0.3.0's `ts_contention_for` shape: N threads ×
   fixed window, counts completed ops, reports Mops/s + ns/op. Runs both
   mutex policies in one binary for a controlled comparison.

### What v0.8.0 deliberately does NOT do

To avoid over-optimizing at the expense of real-world system performance
(matching the explicit stance in lazily-cpp v0.3.0's BENCHMARKS.md):

- **Does not** tune the spin count (64) further — the curve above shows the
  spin-then-park balance is already in the right neighborhood; tuning it
  further would be micro-bench gaming.
- **Does not** add a read/write lock policy (optimization A from lazily-cpp
  v0.4.0). That is the sequenced next step: now that the contention baseline
  exists and the parking mutex is proven, the opt-in RW policy can be measured
  against it.
- **Does not** fix the pre-existing `slot()`-under-contention bug or the
  destroy-on-invalidate UAF (item #6 of the optimization plan). Both are real
  but orthogonal — they need their own investigation and would conflate the
  parking-mutex measurement if bundled here.

## Optimizations Applied (v0.9.0)

v0.9.0 ships **three concurrency fixes** uncovered by writing the v0.8.0
contention bench, plus the **opt-in RwLock policy** and a richer bench that
measures read-scaling.

1. **`ReentrantMutex` (`#lzreentrant`) —** wraps `ParkingMutex` with
   owner-thread tracking + depth counter so the same thread can re-acquire the
   graph lock without deadlock. This lets `Slot.initKeyed` hold the lock across
   subscribe → valueFn → cache-put, closing the use-after-free race window
   (`#lzuafix`): a concurrent `Cell.set → emitChange` previously freed a slot
   that the materializing thread hadn't yet published to the cache. The
   reentrant lock is the new `GraphMutex` on Zig ≥0.16.

2. **`destroySelf` snapshot fix (`#lziterfix`) —** both edge maps (`parents`
   and `change_subscribers`) were iterated while `unsubscribeChangeUnlocked`
   and the recursive `destroyUnlocked` mutated them — iteration-during-mutation
   that corrupted the hashmap into an infinite loop under contention. Now
   snapshotted into allocator-backed slices and cleared BEFORE iteration (same
   pattern `emitChangeUnlocked` already used).

3. **`slotKeyed` lock-leak fix —** the cached-read path could error on
   `subscribeChangeUnlocked` (OutOfMemory from `getOrPut`) without releasing
   the lock. With the reentrant mutex, this left `depth` un-decremented →
   `inner` never released → permanent deadlock. Fixed by scoping the lock with
   `defer ctx.mutex.unlock()`.

4. **`RwLock` (`#lzrwlock`) —** opt-in read/write lock (mirrors lazily-cpp
   v0.4.0's `RwThreadSafeContext`). Shared reads (`lockShared`/`unlockShared`)
   allow concurrent readers; exclusive writes (`lockExclusive`/
   `unlockExclusive`) serialize mutations. Classic reader-count-gates-writer
   pattern over two `ParkingMutex`es. Reader-preferring (steady reads starve
   writers — the right default for UI/editor/CRDT workloads).

### Mixed-optimize root cause

The v0.8.0 contention bench hung under the slot() workload. Root cause: the
bench imported `lazily` as a Debug module (no `.optimize` set on `addModule`)
while the bench root was ReleaseFast. Inlined functions like
`ReentrantMutex.lock` expanded with mismatched assumptions across the
optimize boundary, causing subtle UB under the mixed binary. Fix: the bench
now creates a ReleaseFast lazily module matching its own optimize mode
(`bench_lazily_mod` in `build.zig`). All consumers should set `.optimize`
on their lazily module import to match their own build.

### Contention results (v0.9.0) — write workload

`zig build bench-contention` — N threads × {lock; counter++; unlock}, 20 ms
window per run, ReleaseFast, matching optimize modes.

| Threads | ParkingMutex (Mops/s) | Spinlock (Mops/s) | RwLock-exclusive (Mops/s) |
|---:|---:|---:|---:|
| 1 | 89.3 | 136.1 | 86.4 |
| 2 | 28.9 | 25.9 | 26.6 |
| 4 | 14.7 | 10.0 | 16.1 |
| 8 | 13.3 | 5.2 | 13.5 |
| 16 | 13.7 | 3.8 | 12.6 |

All three serialize under the exclusive lock. ParkingMutex and RwLock-
exclusive both park contended threads (bounded latency ~68–80 ns at N=4–16);
the spinlock's busy-wait collapses (latency balloons to 266 ns at N=16).

### Contention results (v0.9.0) — read workload

N threads × {lock; read counter; unlock}. RwLock uses `lockShared` (concurrent
readers); ParkingMutex and Spinlock use exclusive lock (serialized reads).
Read section = 8 spin iterations (~simulated cached read).

| Threads | ParkingMutex-excl (Mops/s) | Spinlock-excl (Mops/s) | RwLock-shared (Mops/s) |
|---:|---:|---:|---:|
| 1 | 10.3 | 10.2 | 10.1 |
| 2 | 7.7 | 10.4 | **11.9** |
| 4 | 6.6 | 8.4 | **10.2** |

**The read-scaling headline:** RwLock throughput *increases* from N=1→2
(10.1→11.9 Mops/s) because two readers hold the lock concurrently, while
ParkingMutex-excl *decreases* (10.3→7.7) because every read serializes. The
RwLock's reader-gate (a second ParkingMutex) limits scaling beyond N≈2 — a
single-atomic rwsem design would scale further, sequenced as future work
(matching lazily-cpp v0.4.0's `ScalableThreadSafeContext`).

### ~~Remaining concurrency issue~~ — FIXED in v1.0.0

The destroy-on-invalidate UAF that caused SEGV under concurrent same-cell
writes is **fixed** by invalidate-in-place (`#lzinplace`, v1.0.0). See the
v1.0.0 optimizations section below.

## Optimizations Applied (v1.0.0)

v1.0.0 ships **invalidate-in-place** (`#lzinplace`) — the final concurrency
fix that eliminates the destroy-on-invalidate UAF root cause. This is item #6
of the optimization plan, completing the high-load concurrency story started
in v0.8.0.

1. **`Slot.invalidateSlotUnlocked()` (`context.zig`, `#lzinplace`) —**
   replaces `destroyUnlocked(true)` in `emitChangeUnlocked` and
   `touchUnlocked`. Marks the slot `stale = true` and cascades to all
   transitive dependents (same snapshot + clear + iterate pattern). Does NOT
   free the slot, does NOT remove it from the cache. The slot's storage
   pointer stays valid for readers on other threads — eliminating the UAF
   that caused SEGV when `emitChange` freed a slot whose `*T` pointer another
   thread held.

2. **Stale-slot refresh in `slotKeyed` (`slot.zig`) —** the cached-read path
   now checks `cached_slot.stale`. If stale, the slot is removed from the
   cache and appended to `ctx.orphaned_slots` (a zombie list). The caller
   falls through to `initKeyed`, which creates a fresh slot. The orphaned
   slot's memory is NOT freed (its storage pointer may be held by a reader);
   it is freed at `Context.deinit`.

3. **`Context.orphaned_slots` zombie list —** tracks stale-removed slots so
   they can be safely freed at deinit. Bounded by the number of invalidation
   cycles between deinits. For workloads with heavy churn (many invalidations
   between deinits), a periodic compaction or arena-reset would reduce memory
   growth — sequenced as future work.

### Soak test — concurrent set+get (4 threads × 5000 iterations)

The test `lazily/slot: concurrent set+get soak — invalidate-in-place` in
`slot.zig` runs 4 threads each doing `Cell.set(i); slot.get()` for 5000
iterations on a shared cell. Before `#lzinplace`, this SEGV'd after ~50–200
iterations (the UAF). With invalidate-in-place, it completes all 20,000 ops
with zero errors.

This aligns lazily-zig's invalidation model with lazily-rs and lazily-py,
which have always used invalidate-in-place (mark dirty, recompute on next
read) rather than destroy-on-invalidate.

## Cross-language comparison (lazily-rs / lazily-cpp / lazily-zig)

Head-to-head on the same spreadsheet-shaped workload (`N` input cells + `N`
formula slots, `formula[i] = input[i] + input[i-1]`). lazily-rs uses criterion;
lazily-cpp uses its `std::chrono` harness; lazily-zig uses
`clock_gettime(.MONOTONIC)` for the scale bench. The scale tables below were
**re-measured together on one reference machine** (AMD Ryzen 9 9950X3D, Linux),
each bench pinned to a single core (`taskset -c 4`) and run **serially** so no
run contends for L3 / memory bandwidth. rs reports the criterion median of 10
samples; zig reports its internal min-of-8; cpp is a single clean run (±~15%
run-to-run, per its convention). "Rows" = formula count `N`, so cells = `2N` and
the two scale points are `N = 1,000,000` (2M cells) and `N = 5,000,000` (10M
cells) — **the same 10M-cell workload for all three** (an earlier table compared
cpp at 20M cells against rs/zig at 10M; that is corrected here).

### Micro-benchmarks (single-threaded `Context` unless noted)

| Metric | lazily-rs | lazily-cpp | lazily-zig |
|---|---:|---:|---:|
| cached read (Context) | 5.7 ns | 23 ns | — † |
| cached read (ThreadSafeContext) | 68 ns | 22 ns | — † |
| cold first get (Context) | 129 ns | 97 ns | — † |
| cold first get (ThreadSafeContext) | 1.17 µs | 107 ns | — † |
| fan-out 256 (Context) | 58.4 µs | 1.12 µs | — † |
| fan-out 256 (ThreadSafeContext) | 182 µs | 1.68 µs | — |
| set_cell high_fan_out 512 | 139 µs | 3.26 µs | — † |
| memo equality suppression (Context) | 3.3 µs | 34 ns | — † |
| effect flushing (Context) | 90 ns | 87 ns | — |
| batch storms 64 (Context) | 3.1 µs | 1.55 µs | — |

† lazily-zig 0.17-dev removed `std.time.Timer`, so its reactive-core
micro-bench is **counter-based** (deterministic work-counts: allocations,
edges, recomputes — not wall-clock). The counters confirm the same zero-work
steady state (cached reads = 0 allocs / 0 recomputes) but are not directly
comparable on a wall-clock axis — see the *Reactive-core micro-bench*
section above.

### Scale — 1M rows (~2M cells)

| Metric | lazily-rs | lazily-cpp | lazily-zig |
|---|---:|---:|---:|
| build (2N nodes) | 124 ms | **97 ms** | 120 ms |
| cold full recalc | 105 ms | **28 ms** | 275 ms |
| full recalc (invalidate all) | 80 ms | **49 ms** | 403 ms |
| viewport recalc (edit 1, read 1k) | **3.7 µs** | 23.2 µs | 10.4 µs |

### Scale — 10M cells (full Google Sheets workbook capacity)

`N = 5,000,000` (5M inputs + 5M formulas = 10M cells) for all three.

| Metric | lazily-rs | lazily-cpp | lazily-zig |
|---|---:|---:|---:|
| build | 718 ms | **520 ms** | 862 ms |
| cold full recalc | 544 ms | **137 ms** | 2.29 s |
| full recalc (invalidate all) | 398 ms | **243 ms** | 3.15 s |
| viewport recalc | **3.8 µs** | 22.5 µs | 10.6 µs |

> For reference, lazily-cpp also measures `N = 10,000,000` (20M cells): build
> 1.02 s, cold full recalc 303 ms, full recalc 628 ms, viewport 24.7 µs. The old
> cross-language table listed cpp's cold "415 ms" under "10M cells" — that was
> actually this 20M-cell run; the true 10M-cell (5M-row) figure is **137 ms**.

**Honest read:** lazily-cpp's v0.6.0 `SmallAny` inline value storage owns the
**cold/full-recalc** wall clock (28 ms vs rs 105 ms @ 1M; 137 ms vs rs 544 ms @
10M cells) and now also the leanest **build**. lazily-rs — after its v0.22.2
`#lzslotfastpath` refresh fast path — delivers the **cheapest viewport reads** of
the three (3.7 µs @ 1M, 3.8 µs @ 10M), because its pointer-referenced `Rc<T>`
slots read by chase, not by hash probe; lazily-zig's integer-keyed cache pays a
hash probe per read (10.4/10.6 µs). lazily-zig's cold/full recalc trails for two
**definitional** reasons, not an efficiency bug: (1) its keyed-escape-hatch graph
materializes formula slots lazily on first read, so `cold_full_recalc` pays
*allocation + compute* together — work that lazily-cpp/rs already charged to
`build`; and (2) every read hash-probes a global `2N`-entry integer cache, whose
miss rate grows with `N` — which is why zig's v1.1.0 node-layout wins show up
strongly at 1M (cold 381 → 275 ms, ~28% faster) but wash out at 10M cells (2.26 →
2.29 s), where cache probing dominates the alloc savings. All three still exhibit
the microsecond, size-independent **viewport** property — the property a
viewport-rendered spreadsheet actually needs.

> **Node-layout optimizations (`#lzinline` / `#lzedgeinline` / `#lzcachegop`).**
> Profiling `cold_full_recalc` (Linux `perf`, ReleaseFast) put ~38% of
> wall-clock in `ArenaAllocator.alloc`, of which ~21–25% was *growing the two
> per-node `AutoHashMap` edge sets* (`change_subscribers` + `parents`) — the
> engine paid O(N) heap allocations just to record dependency edges. Three
> changes close most of that gap, matching the `SmallVec`/`SmallAny` layout
> lazily-cpp uses:
>
> - **`#lzinline`** — small `.indirect` values (`i64`, `f64`, pointers, ≤16-byte
>   PODs) are stored inline in the slot instead of a separate heap box, removing
>   one allocation and one pointer chase per node.
> - **`#lzedgeinline`** — `SlotEdgeSet` stores the first 4 edges per direction
>   inline and only spills to an `AutoHashMap` for genuinely high-fan-out nodes,
>   so the low-degree common case (a spreadsheet formula reads 2–3 cells)
>   allocates **zero** edge maps.
> - **`#lzcachegop`** — the global-cache dedup + publish collapses from a
>   `get` + `put` (two hashes of the 2N-entry map per node) into one `getOrPut`.
>
> Effect: cold-recalc `ArenaAllocator.alloc` self-time drops from ~38% to ~17%
> of samples (the edge-map `getOrPut → grow → allocate` chain falls from ~25% to
> ~3%). The scale tables above are **re-measured post-v1.1.0** on the reference
> machine: cold recalc improved 381 → 275 ms at 1M (~28%), but is flat at 10M
> cells (2.26 → 2.29 s), where the global keyed-cache hash-probing — not
> allocation — is the dominant cost and grows with `N`.

lazily-cpp wins the high-fan-out micro-benchmarks via
its `SmallFn`/`SmallVec` node layout. The **shared headline** across all three:
they back a full-capacity Google Sheets workbook and all exhibit the
**lazy-pull viewport property** — a one-cell edit + bounded-viewport read stays
in the **microsecond** range, independent of sheet size, because off-viewport
formulas are left dirty and never recomputed (~5,000–650,000× cheaper than a
full recalc).

[rs-scale]: https://github.com/lazily-hub/lazily-rs/blob/main/benches/scale.rs
