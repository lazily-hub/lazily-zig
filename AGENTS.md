# lazily-zig

Zig port of the lazily reactive-signals family — lazy evaluation with context
caching, reactive graphs, state machines, and the full lazily-spec wire
protocol.

## Reactive-value vocabulary — the Cell kernel (`#lzcellkernel`)

The reactive values are two concrete handles (in `src/lazily/cell.zig`) — there
is no `Cell(T, K)` genus (`Cell` is the value-node *concept* only):
`Source(T[, M])` (written from outside; `set`/`merge` under merge policy `M`, or
`SourceCellWith(T, M)` for an explicit policy — subsumes the former plain `Cell`
and `MergeCell`) and `Computed(T)` (computed from upstream; guarded + lazy;
`computed().eager()` is the eager form that retires the former `Signal`). All
cells are guarded — `Source` suppresses an equal write, `Computed` suppresses an
equal recompute (matching TC39 `Signal.Computed`); there is no separate `memo`.
`set`/`merge` are comptime-guarded to the source handle, so `computed.set(…)`
does not compile (design §3/§4). `Effect` stays the value-less sink outside the
hierarchy. Constructors: `source` / `sourceWith` / `computed` / `.eager()` /
`.lazy()`; `cell` / `signal` survive as deprecated aliases. `slot()` remains the
deliberately non-guarded storage-value primitive (returns `*T`, for
non-equatable values). `Slot` keeps its **storage** meaning (the arena position
that holds a node) — `SlotId`/`SlotValue`/wire types are unchanged. See
`tasks/software/lazily-cell-kernel-design.md`.

## Commit & Push

Commit and push completed work at the end of every turn that changed code,
tests, docs, or fixtures — do not leave finished work uncommitted. Run `make
check` first and ensure it is green; stage only the files that belong to the
change (never secrets or private customer names — see the workspace
`runbooks/private-name-hygiene.md`); write a concise commit message in the
repo's existing style; push to the current branch on `origin`. This standing
rule overrides the harness default of "commit only when explicitly asked" for
this repo.

<!-- tsift:code-navigation v=0.1.110 -->
## Code Navigation

Use the repository tsift skill at [`.agents/skills/tsift/SKILL.md`](.agents/skills/tsift/SKILL.md) for code search, source reading, call graphs, diffs, logs, and test output.
<!-- /tsift:code-navigation -->
