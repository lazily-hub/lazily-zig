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

<!-- tsift:code-navigation v=0.1.80 -->
## Code Navigation

Run `tsift status` at session start from the owning repo root. If the task or file lives under a git submodule (for example `src/tsift/...`), switch to that submodule root first so the harness loads the narrower local instructions and repo state instead of the superproject root. If status prints a `run:` recommendation for stale or missing tsift state, run `tsift status --fix` before relying on tsift results; when the harness cannot perform write commands, ask the user to run the printed command instead.

Prefer tsift envelopes over raw reads:
- `tsift --envelope search <query>` instead of `grep`/`rg`
- `tsift --envelope source-read <file>` / `tsift --envelope symbol-read <symbol>` instead of `cat`/`head`
- `tsift --envelope explain <symbol>` and `tsift graph <symbol> --callers` / `--callees` for call graphs
- `tsift diff-digest [path]` instead of `git diff`, `git show`, or patch-style `git log`
- `tsift --envelope session-review <path>` / `tsift --envelope context-pack <path>` instead of replaying long session docs, transcripts, or runtime logs
- `tsift --envelope digest-runner --kind test|log --path . --shell-command '<command>'` instead of raw test/build output

Command detail lives in [`runbooks/code-navigation.md`](runbooks/code-navigation.md) — budgets, `tsift workflow search`, `report.scale_guard` handling, the harness rewrite path for `PreToolUse`-less harnesses, and Codex/OpenCode integration. `tsift init` writes and versions that runbook alongside this block, so it is present in every initialized checkout; read it before broad exploration instead of expanding this block. A repository that also ships a current `.claude/skills/tsift/SKILL.md` should use that skill as the deeper source.

For local verification, run `make check` before committing. After local changes, check the latest GitHub Actions CI run with `gh run list --workflow CI --limit 1` and fix any failing tests before calling the work complete.

Only read full source files when tsift results are insufficient.
<!-- /tsift:code-navigation -->
