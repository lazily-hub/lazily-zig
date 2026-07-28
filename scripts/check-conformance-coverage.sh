#!/usr/bin/env bash
# Conformance-coverage guard (#portconformancecoverage).
#
# Fails the build when a fixture in the canonical corpus (../lazily-spec/conformance/)
# is not replayed by this repo. That is the drift this guard exists for: a fixture
# lands upstream, every binding stays green, and nobody learns that one of them is
# not replaying it.
#
# This binding uses the RUNTIME manifest (#lazilyupgradeconformance), not the
# static grep it started with. The test run records every file it actually reads
# from the conformance corpus, so a fixture named in a comment and
# hand-transcribed — the drift found in lazily-cpp's queue tests, and in
# lazily-rs's own topic tests — is caught here. A source grep cannot see that
# case at all: it counts the mention.
#
# The upgrade dropped this binding from 94 "named" to 72 "opened". Of the 22 that
# fell out, 14 were vendored @embedFile copies (a compile-time embed opens
# nothing; conformance_manifest.zig asserts them byte-identical to canonical
# instead) and 8 were inline mirrors, since replaced by real runners. What is
# left in KNOWN_UNCOVERED below is fixtures with no runner in this binding at
# all — each entry a claim that someone looked.
#
# A missing manifest is missing EVIDENCE and fails. It does not mean "no fixtures
# were read"; it means the suite ran without the recorder attached, and passing in
# that state is the vacuous green this guard exists to prevent.
#
# Reading is still not asserting. The manifest proves the bytes were opened; it
# cannot prove the assertions replayed against them mean anything.
set -euo pipefail

SPEC_DIR="${LAZILY_SPEC_CONFORMANCE_DIR:-../lazily-spec/conformance}"
if [ ! -d "$SPEC_DIR" ]; then
  echo "SKIP: canonical corpus not found at $SPEC_DIR (clone the lazily-spec sibling)" >&2
  exit 0
fi

# Fixtures deliberately not covered by this binding yet. Each entry is a claim that
# someone looked; shrinking this list is the work. Adding to it silently is how the
# guard rots, so keep a reason with any new entry.
KNOWN_UNCOVERED=(
  # No runner at all in this binding.
  "agent-doc/delta_agent_doc_state.json"
  "agent-doc/snapshot_agent_doc_state.json"
  "collections/seqcrdt_convergence.json"
  "collections/textcrdt_convergence.json"
  "collections/textcrdt_delta_sync.json"
  "collections/topiccell_broadcast_cursor_isolation.json"
  "collections/topiccell_durable_replay_gc.json"
  "collections/topiccell_ephemeral_lifecycle.json"
  "collections/topiccell_offline_tail_bounds.json"
  "collections/workqueue_competing_delivery.json"
  "collections/workqueue_lease_deadletter.json"
  "lossless-tree/concurrent_conflict_preserves_text.json"
  "lossless-tree/concurrent_insert_same_parent.json"
  "lossless-tree/concurrent_reorder_and_leaf_edit.json"
  "lossless-tree/exact_roundtrip.json"
  "lossless-tree/invalid_source_roundtrip.json"
  "lossless-tree/non_contiguous_anti_entropy.json"
  "lossless-tree/one_leaf_edit_delta.json"
  "lossless-tree/split_merge.json"
  "lossless-tree/token_trivia_preservation.json"
  "message-passing/accepted_then_applied_receipt.json"
  "message-passing/cancel_preempts_nonterminal.json"
  "message-passing/editor_route_submit.json"
  "message-passing/reconnect_command_projection.json"
  "message-passing/rpc_call_waits_for_terminal.json"
  "message-passing/stale_generation_ignored.json"
  "message-passing/sync_tmux_layout_submit.json"
  "message-passing/terminal_conflict_fail_closed.json"
  "reliable-sync/coalesce_bounds_outbox.json"
  "reliable-sync/liveness_lease_eviction.json"
  # Portable stdlib APIs and their production fixture runners are staged.
  "stdlib/revision_barrier.json"
  "stdlib/timeout.json"
  "stdlib/timer.json"
)

# The eight inline-mirror fixtures this list used to carry are GONE from it: they
# are replayed for real by src/lazily/{collections,distributed,signaling}_conformance.zig
# and now show up as OPENED. Retiring them found three wire defects the mirrors
# could not see, because each mirror was transcribed from this implementation
# rather than from the corpus:
#
#   - the stamp frontier was encoded as `{peer, stamp}` where the schema pins a
#     2-element `[peer, stamp]` tuple (ipc.zig, both directions);
#   - `CrdtOp.key` was omitted when null and rejected when explicitly null,
#     though the schema lists it as required-and-nullable (ipc.zig);
#   - `welcome.peers` came out in hash-map order against an explicit
#     `roster_sorted_ascending` assertion, and the unknown-target error text did
#     not match the transcript (signaling.zig).

# ABSOLUTE by contract — test binaries may run from a working directory other
# than the repo root, so the recorder cannot resolve a relative path the same way
# this script would. The Makefile exports $(CURDIR)/...; the fallback here is for
# running the script by hand right after `make test`.
MANIFEST="${LAZILY_CONFORMANCE_MANIFEST:-build/conformance-fixtures-loaded.txt}"

if [ ! -s "$MANIFEST" ]; then
  echo "FAIL: no conformance manifest at $MANIFEST." >&2
  echo "      Run the suite with LAZILY_CONFORMANCE_MANIFEST set to an ABSOLUTE" >&2
  echo "      path (\`make test\` does) so the recorder attaches. An absent" >&2
  echo "      manifest is missing evidence, not evidence of absence." >&2
  exit 1
fi
OPENED="$(sort -u "$MANIFEST")"

missing=0
total=0
covered=0
while IFS= read -r fixture; do
  total=$((total + 1))
  # Here-string, NOT a pipe. With `set -o pipefail`, `printf ... | grep -q` reports
  # FAILURE when grep matches: grep -q exits immediately on the first hit, printf
  # takes SIGPIPE writing the rest, and pipefail surfaces printf's death as the
  # pipeline's status. The check then inverts — every covered fixture is reported
  # missing. That is exactly how it behaved before this line changed.
  if grep -qxF "$fixture" <<< "$OPENED"; then
    covered=$((covered + 1))
    continue
  fi
  excused=0
  for known in "${KNOWN_UNCOVERED[@]:-}"; do
    if [ "$known" = "$fixture" ]; then excused=1; break; fi
  done
  if [ "$excused" -eq 0 ]; then
    echo "ERROR: canonical fixture '$fixture' was NOT opened by the suite." >&2
    echo "       A runner may still name it in source while no longer reading it —" >&2
    echo "       that is the drift this manifest exists to catch. Replay it, or add" >&2
    echo "       it to KNOWN_UNCOVERED with a reason." >&2
    missing=$((missing + 1))
  fi
done < <(cd "$SPEC_DIR" && find . -name '*.json' | sed 's|^\./||' | sort)

# The evidence channel guards itself. Every recorded id must resolve against the
# corpus root; otherwise the manifest was truncated or interleaved in transit,
# and coverage computed from it cannot be trusted.
while IFS= read -r id; do
  [ -n "$id" ] || continue
  if [ ! -f "$SPEC_DIR/$id" ]; then
    echo "ERROR: manifest records '$id', which names no file in $SPEC_DIR." >&2
    echo "       The recorder is dropping or interleaving writes; coverage computed" >&2
    echo "       from this manifest cannot be trusted." >&2
    missing=$((missing + 1))
  fi
done <<< "$OPENED"

# A stale allowlist is its own drift: an entry naming a fixture that no longer
# exists means the corpus moved and nobody updated the excuse.
for known in "${KNOWN_UNCOVERED[@]:-}"; do
  if [ ! -f "$SPEC_DIR/$known" ]; then
    echo "ERROR: KNOWN_UNCOVERED lists '$known', which is not in the canonical corpus." >&2
    missing=$((missing + 1))
  fi
done

if [ "$missing" -gt 0 ]; then
  echo "conformance coverage FAILED: $missing problem(s)" >&2
  exit 1
fi

echo "conformance coverage OK: $covered/$total canonical fixtures OPENED by the suite" \
     "(${#KNOWN_UNCOVERED[@]} listed as known-uncovered; runtime manifest — these bytes were really read)"
