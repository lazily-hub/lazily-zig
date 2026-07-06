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
zig build bench          # fast reactive-core micro-bench (counter-based)
zig build bench-scale    # spreadsheet-scale bench (wall-clock), default N=1,000,000
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

[rs-scale]: https://github.com/lazily-hub/lazily-rs/blob/main/benches/scale.rs
