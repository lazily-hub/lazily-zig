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
| `build` | 132 ms | ~66 ns | Construct the N input nodes (formulas lazy, not yet materialized). |
| `cold_full_recalc` | 381 ms | ~190 ns | First read of every formula — materializes all N formula slots + edges and computes them. |
| `viewport_recalc` | **6.4 µs** | — | Edit one input, read only a 1,000-cell viewport. ~59,000× cheaper than a full recalc. |
| `full_recalc_invalidate_all` | 603 ms | ~301 ns | Touch every input, then read every formula (worst-case full-sheet edit). |

### 5,000,000 rows (10M cells — a full Google Sheets workbook)

Google Sheets caps a workbook at **10,000,000 cells**. Modeled as 5,000,000
input cells + 5,000,000 formula cells (`LAZILY_SCALE_N=5000000`, measured with
`heavy reps = 1` since each heavy pass rebuilds the whole sheet):

| Benchmark | Time | Per cell | What it measures |
|-----------|-----:|---------:|------------------|
| `build` | 1.13 s | ~113 ns | Build the 5M input nodes of a full 10M-cell workbook. |
| `cold_full_recalc` | 2.26 s | ~226 ns | Materialize + compute all 5M formulas cold. |
| `viewport_recalc` | **6.6 µs** | — | Edit one input, read a 1,000-cell viewport. ~647,000× cheaper than a full recalc. |
| `full_recalc_invalidate_all` | 4.25 s | ~425 ns | Re-edit every input, recompute the whole workbook. |

So lazily-zig backs a **full-capacity Google Sheets workbook**: build ~1.1 s,
full cold recompute ~2.3 s, and a one-cell edit + bounded-viewport read stays in
the **~6-7 µs** range — because the lazy pull-based model leaves off-viewport
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

lazily-zig's viewport recalc is **effectively size-independent** — ~6.4 µs at
2M cells and ~6.6 µs at 10M cells. This matches lazily-rs's flat curve (and is
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

The `~59,000×` / `~647,000×` speedups above are `full_recalc / viewport` for the
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
  tracking, lazy destroy-on-invalidate, local fan-in, memoized warm reads — are
  the real library paths.
- **Allocator:** the scale bench uses an `ArenaAllocator` over
  `page_allocator`, fresh per scenario. The library's `destroy`/`free` calls are
  arena no-ops, so the churn scenarios (`viewport_recalc`,
  `full_recalc_invalidate_all`) accumulate re-materialized slots into the arena;
  rep counts are kept small for large `N` to stay within memory, and the arena
  is torn down between scenarios.
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

## Cross-language comparison (lazily-rs / lazily-cpp / lazily-zig)

Head-to-head on the same spreadsheet-shaped workload (`N` input cells + `N`
formula slots, `formula[i] = input[i] + input[i-1]`), measured on `x86_64`
Linux. lazily-rs uses criterion; lazily-cpp uses its `std::chrono` harness;
lazily-zig uses `clock_gettime(.MONOTONIC)` for the scale bench. Numbers are
the current published results from each repo's `BENCHMARKS.md`.

### Micro-benchmarks (single-threaded `Context` unless noted)

| Metric | lazily-rs | lazily-cpp | lazily-zig |
|---|---:|---:|---:|
| cached read (Context) | 10.5 ns | 19 ns | — † |
| cached read (ThreadSafeContext) | 67 ns | 22 ns | — † |
| cold first get (Context) | 93 ns | 88 ns | — † |
| cold first get (ThreadSafeContext) | 1.13 µs | 98 ns | — † |
| fan-out 256 (Context) | 72.5 µs | 1.05 µs | — † |
| fan-out 256 (ThreadSafeContext) | 219 µs | 1.68 µs | — |
| set_cell high_fan_out 512 | 145 µs | 3.08 µs | — † |
| memo equality suppression (Context) | 3.29 µs | 34 ns | — † |
| effect flushing (Context) | 99 ns | 127 ns | — |
| batch storms 64 (Context) | 3.85 µs | 4.45 µs | — |

† lazily-zig 0.17-dev removed `std.time.Timer`, so its reactive-core
micro-bench is **counter-based** (deterministic work-counts: allocations,
edges, recomputes — not wall-clock). The counters confirm the same zero-work
steady state (cached reads = 0 allocs / 0 recomputes) but are not directly
comparable on a wall-clock axis — see the *Reactive-core micro-bench*
section above.

### Scale — 1M rows (~2M cells)

| Metric | lazily-rs | lazily-cpp | lazily-zig |
|---|---:|---:|---:|
| build (2N nodes) | 105 ms | 143 ms | 132 ms |
| cold full recalc | 106 ms | 102 ms | 381 ms |
| viewport recalc (edit 1, read 1k) | 15.6 µs | 47.7 µs | 6.4 µs |

### Scale — 10M cells (full Google Sheets workbook capacity)

| Metric | lazily-rs | lazily-cpp | lazily-zig |
|---|---:|---:|---:|
| build | 706 ms | 1.33 s | 1.13 s |
| cold full recalc | 518 ms | 1.12 s | 2.26 s |
| viewport recalc | 11.4 µs | 71.7 µs | 6.6 µs |

**Honest read:** lazily-zig's integer-keyed `AutoHashMap(usize, *Slot)`
cache delivers the **cheapest viewport reads** of the three (6.4–6.6 µs,
size-independent), and its build time is competitive with lazily-cpp.
lazily-zig's cold/full recalc is slower because its keyed-escape-hatch graph
materializes formula slots lazily on first read (so `cold_full_recalc` pays
both allocation and compute) and the `ArenaAllocator` does not free churned
slots between scenarios. lazily-rs leads build/cold-recalc via its leaner
monomorphized per-node storage, and lazily-cpp wins the high-fan-out
micro-benchmarks via its `SmallFn`/`SmallVec` node layout. The **shared
headline** across all three: they back a full-capacity Google Sheets workbook
and all exhibit the **lazy-pull viewport property** — a one-cell edit +
bounded-viewport read stays in the **microsecond** range, independent of
sheet size, because off-viewport formulas are left dirty and never
recomputed (~5,000–650,000× cheaper than a full recalc).

[rs-scale]: https://github.com/lazily-hub/lazily-rs/blob/main/benches/scale.rs
