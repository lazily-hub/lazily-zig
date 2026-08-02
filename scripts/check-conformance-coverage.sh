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
# that state is the vacuous green this guard exists to prevent. Under CI a missing
# CORPUS is read the same way (#lzvacuousrun), and the run has to clear an explicit
# fixture/scenario floor before it may print OK — see the two blocks so marked.
#
# Reading is still not asserting. The manifest proves the bytes were opened; it
# cannot prove the assertions replayed against them mean anything.
set -euo pipefail

SPEC_DIR="${LAZILY_SPEC_CONFORMANCE_DIR:-../lazily-spec/conformance}"

# A missing corpus is a legitimate LOCAL state (no sibling checkout) and an
# illegitimate CI state (#lzvacuousrun). Skipping under CI is the vacuous green
# this guard exists to prevent: every rung below reasons about fixtures the run
# OPENED, so an absent corpus reports OK over nothing at all — and nothing else
# in this script can contradict it, because zero opened fixtures also means zero
# uncovered fixtures and zero stale excuses. Locally it stays a skip, because a
# contributor without the sibling is not making a false claim. This mirrors how
# a missing manifest is already handled below: missing EVIDENCE, not evidence of
# absence.
if [ ! -d "$SPEC_DIR" ]; then
  if [ -n "${CI:-}" ]; then
    echo "ERROR: canonical corpus not found at $SPEC_DIR, and CI is set." >&2
    echo "       Under CI this is missing EVIDENCE, not evidence of absence: the" >&2
    echo "       checkout is wrong, not the corpus. Exiting 0 here would report" >&2
    echo "       conformance OK having examined zero fixtures (#lzvacuousrun)." >&2
    exit 1
  fi
  echo "SKIP: canonical corpus not found at $SPEC_DIR (clone the lazily-spec sibling)" >&2
  echo "      Local checkout only — this would be a hard failure under CI." >&2
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

# ---------------------------------------------------------------------------
# Per-scenario replay accounting (#lzscenariocoverage).
#
# Rung 4. A fixture carrying several named scenarios can be PARTIALLY replayed
# and nothing above notices: the coverage guard asks only whether the FILE was
# opened, and one scenario is enough for that. The key trackers in
# src/lazily/conformance_json.zig are blind for the mirror-image reason — they
# bind only the blocks a runner reaches, so a scenario nobody replayed
# contributes no unconsumed key and no unasserted key. Skipping a whole scenario
# is invisible to a guard that only inspects the scenarios you ran.
#
# The evidence is the RUNTIME ledger the suite writes into the same manifest,
# prefixed `@scenario<TAB>`, one line per scenario actually replayed. Like the
# fixture manifest and unlike a hand-authored "scenarios this runner covers"
# list, it records what happened rather than what someone claimed.
#
# SCOPE: only fixtures the manifest says were OPENED. A fixture in
# KNOWN_UNCOVERED above has no runner at all in this binding, and re-stating
# each of its scenarios here would say nothing the fixture entry does not
# already say — it would just be the same excuse, N times.
#
# Excuses live here, next to KNOWN_UNCOVERED, so there is ONE place to read what
# this binding does not prove.
SCENARIO_EXCUSES=()

# excuseScenario <fixture> <scenario-id> <reason>
#
# Declare that this binding does not replay one scenario of a fixture it DOES
# open, and say why. Prefer implementing the scenario; an excuse is a promise
# the reason text has to keep. Checked in both directions below, exactly like
# KNOWN_UNCOVERED.
excuseScenario() {
  if [ -z "${3:-}" ]; then
    echo "ERROR: excuseScenario('${1:-}', '${2:-}') has an empty reason." >&2
    echo "       An excuse with no reason is an unexplained gap wearing a" >&2
    echo "       guard's uniform." >&2
    exit 1
  fi
  SCENARIO_EXCUSES+=("$1|$2|$3")
}

# No scenario of an opened fixture is currently unreplayed in this binding.
#
# One was, and is now implemented rather than excused: `outbox_store_protocol`'s
# `stale handle cannot regress serialized cursor` was reachable only through
# `FileOutboxStore`, whose tests skip on Zig 0.15.2 (no `std.Io`) — a whole
# scenario silently unreplayed on a GATING toolchain. `StoredOutbox` folds the
# cursor with `max` in the protocol rather than the journal, so the scenario now
# replays against `InMemoryStore` on every toolchain, with the file-backed test
# kept as the durable variant.


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
# Two evidence channels share one file. A corpus-relative fixture id can never
# begin with `@`, so the split is a single grep and needs no second manifest,
# no second environment variable, and no second build.zig wiring.
TAB=$'\t'
SCENARIO_MARK="@scenario$TAB"
OPENED="$({ grep -v "^$SCENARIO_MARK" "$MANIFEST" || true; } | sort -u)"
# `fixture<TAB>scenario-id`, one line per scenario the suite actually replayed.
SCENARIO_LEDGER="$({ grep "^$SCENARIO_MARK" "$MANIFEST" || true; } \
  | sed "s|^$SCENARIO_MARK||" | sort -u)"

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

# A stale allowlist is its own drift, in two directions.
#
#   1. An entry naming a fixture that no longer exists means the corpus moved and
#      nobody updated the excuse.
#   2. An entry naming a fixture the suite DOES open means the excuse outlived the
#      gap it described. Nothing above catches this: the covered-check `continue`s
#      on an opened fixture and never consults the allowlist, so a stale excuse
#      costs nothing and accumulates silently. That understates the gap in the
#      SAME direction as an under-counted ledger — the guard reports fewer
#      fixtures covered than the suite actually replays, and each dead entry makes
#      the remaining list less credible as "someone looked".
#
# The opened-set test below is byte-for-byte the covered-check's comparison
# (`grep -qxF ... <<< "$OPENED"`) so the two can never disagree about what
# "opened" means.
for known in "${KNOWN_UNCOVERED[@]:-}"; do
  if [ ! -f "$SPEC_DIR/$known" ]; then
    echo "ERROR: KNOWN_UNCOVERED lists '$known', which is not in the canonical corpus." >&2
    missing=$((missing + 1))
    continue
  fi
  if grep -qxF "$known" <<< "$OPENED"; then
    echo "ERROR: KNOWN_UNCOVERED lists '$known', but the suite DID open it." >&2
    echo "       The excuse is stale — the gap it described has been closed. Delete" >&2
    echo "       the entry from KNOWN_UNCOVERED. Leaving it there understates this" >&2
    echo "       binding's real coverage and rots the list into noise." >&2
    missing=$((missing + 1))
  fi
done

# ---------------------------------------------------------------------------
# Per-scenario replay accounting (#lzscenariocoverage).
# ---------------------------------------------------------------------------

if ! command -v jq >/dev/null 2>&1; then
  echo "FAIL: jq is required to resolve scenario ids out of the corpus." >&2
  echo "      Skipping this check would report green while proving nothing —" >&2
  echo "      the exact failure mode the scenario ledger exists to close." >&2
  exit 1
fi

# Resolve a fixture's scenario ids in the order EVERY binding uses:
#   1. `id` if present, 2. else `name` if present.
# Prints nothing for a fixture with no `scenarios` array.
#
# There is no positional fallback (#lzspecscenarioids): an id derived from a
# POSITION silently rebinds to a different scenario when the corpus array is
# reordered, so an unidentified scenario is marked and reported rather than
# given an invented id.
scenario_ids_on_disk() {
  jq -r '
    def identifier: if type == "string" and (gsub("\\s"; "") != "") then . else null end;
    (.scenarios // [])
    | to_entries[]
    | ((.value.id? | identifier) // (.value.name? | identifier) // "!UNIDENTIFIED!\(.key)")' \
    "$SPEC_DIR/$1"
}

scenario_total=0
scenario_replayed=0
scenario_excused=0

# --- forward: every scenario of an OPENED fixture must be in the ledger ------
while IFS= read -r fixture; do
  [ -n "$fixture" ] || continue
  while IFS= read -r sid; do
    [ -n "$sid" ] || continue
    scenario_total=$((scenario_total + 1))
    # An unidentified scenario is a corpus defect, not an id to invent
    # (#lzspecscenarioids). Booking it by POSITION would silently rebind that
    # ledger entry to a different scenario on any corpus reorder.
    case "$sid" in
      '!UNIDENTIFIED!'*)
        echo "ERROR: '$fixture' scenario at index ${sid#!UNIDENTIFIED!} carries neither" >&2
        echo "       \`id\` nor \`name\`. The ledger would record it by POSITION, which" >&2
        echo "       silently rebinds on a corpus reorder. Give it a stable id upstream" >&2
        echo "       in lazily-spec (#lzspecscenarioids)." >&2
        missing=$((missing + 1))
        continue
        ;;
    esac
    if grep -qxF "$fixture$TAB$sid" <<< "$SCENARIO_LEDGER"; then
      scenario_replayed=$((scenario_replayed + 1))
      continue
    fi
    excused=0
    for entry in "${SCENARIO_EXCUSES[@]:-}"; do
      [ -n "$entry" ] || continue
      if [ "${entry%%|*}" = "$fixture" ]; then
        rest="${entry#*|}"
        [ "${rest%%|*}" = "$sid" ] && { excused=1; break; }
      fi
    done
    if [ "$excused" -eq 1 ]; then
      scenario_excused=$((scenario_excused + 1))
      continue
    fi
    echo "ERROR: '$fixture' scenario '$sid' was NEVER REPLAYED." >&2
    echo "       The fixture's bytes were opened, so the coverage guard counts it" >&2
    echo "       covered and the key trackers see nothing — an unreplayed scenario" >&2
    echo "       contributes no unconsumed key and no unasserted key. Replay it, or" >&2
    echo "       declare excuseScenario \"$fixture\" \"$sid\" \"<reason>\"." >&2
    missing=$((missing + 1))
  done < <(scenario_ids_on_disk "$fixture")
done <<< "$OPENED"

# --- the evidence channel guards itself -------------------------------------
# A ledger line naming a fixture the manifest never opened, or an id the fixture
# does not carry, means the recorder is writing claims rather than observations.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  led_fixture="${line%%$TAB*}"
  led_id="${line#*$TAB}"
  if ! grep -qxF "$led_fixture" <<< "$OPENED"; then
    echo "ERROR: scenario ledger records '$led_fixture' ('$led_id'), which the" >&2
    echo "       fixture manifest says was never opened. Coverage computed from" >&2
    echo "       this ledger cannot be trusted." >&2
    missing=$((missing + 1))
    continue
  fi
  if ! scenario_ids_on_disk "$led_fixture" | grep -qxF "$led_id"; then
    echo "ERROR: scenario ledger records '$led_fixture' scenario '$led_id', which" >&2
    echo "       the fixture does not carry. The runner is replaying an id the" >&2
    echo "       corpus renamed or dropped." >&2
    missing=$((missing + 1))
  fi
done <<< "$SCENARIO_LEDGER"

# --- a stale excuse is its own drift, in both directions ---------------------
for entry in "${SCENARIO_EXCUSES[@]:-}"; do
  [ -n "$entry" ] || continue
  ex_fixture="${entry%%|*}"
  ex_rest="${entry#*|}"
  ex_id="${ex_rest%%|*}"
  if [ ! -f "$SPEC_DIR/$ex_fixture" ]; then
    echo "ERROR: excuseScenario names '$ex_fixture', which is not in the canonical corpus." >&2
    missing=$((missing + 1))
    continue
  fi
  if ! scenario_ids_on_disk "$ex_fixture" | grep -qxF "$ex_id"; then
    echo "ERROR: excuseScenario names '$ex_fixture' scenario '$ex_id', which the" >&2
    echo "       fixture does not carry. The excuse outlived the scenario it" >&2
    echo "       described — delete it." >&2
    missing=$((missing + 1))
    continue
  fi
  if grep -qxF "$ex_fixture$TAB$ex_id" <<< "$SCENARIO_LEDGER"; then
    echo "ERROR: excuseScenario lists '$ex_fixture' scenario '$ex_id', but this run" >&2
    echo "       DID replay it. The excuse is stale and now hides nothing — delete" >&2
    echo "       it. Leaving it there understates this binding's real coverage and" >&2
    echo "       rots the list into noise." >&2
    missing=$((missing + 1))
  fi
done

if [ "$missing" -gt 0 ]; then
  echo "conformance coverage FAILED: $missing problem(s)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Positive-evidence floor (#lzvacuousrun).
# ---------------------------------------------------------------------------
#
# Everything above reasons about fixtures this run OPENED, so all of it is
# vacuously satisfied by an empty population: zero opened fixtures means zero
# uncovered fixtures, zero unresolvable manifest ids, zero stale excuses and
# zero unreplayed scenarios. The loops cannot distinguish "nothing is wrong"
# from "nothing was examined", so assert the MAGNITUDE explicitly before
# printing OK.
#
# Calibrated from a real `make test` run: 114/138 fixtures OPENED and 86/86
# scenarios REPLAYED. The floors sit just below those, low enough not to trip on
# a single upstream fixture landing without a runner, high enough that a
# detached recorder or a short-circuited dispatch cannot slip through. Do NOT
# lower them to fix a red run — a drop here means the corpus or the recorder
# shrank, and that is the finding.
MIN_FIXTURES="${MIN_FIXTURES:-110}"
MIN_SCENARIOS="${MIN_SCENARIOS:-80}"

if [ "$total" -eq 0 ]; then
  echo "ERROR: the corpus at $SPEC_DIR listed ZERO fixtures." >&2
  echo "       Every check above is vacuously green over an empty population." >&2
  exit 1
fi
if [ "$covered" -lt "$MIN_FIXTURES" ]; then
  echo "ERROR: only $covered distinct canonical fixtures were OPENED, expected >= $MIN_FIXTURES." >&2
  echo "       A replay was removed, renamed, or short-circuited, or the recorder" >&2
  echo "       detached mid-run. Do not lower MIN_FIXTURES to fix this." >&2
  exit 1
fi
if [ "$scenario_total" -eq 0 ]; then
  echo "ERROR: ZERO scenarios were found across the opened fixtures." >&2
  echo "       The per-scenario rung is vacuously green over an empty population." >&2
  exit 1
fi
if [ "$scenario_replayed" -lt "$MIN_SCENARIOS" ]; then
  echo "ERROR: only $scenario_replayed distinct scenarios were REPLAYED, expected >= $MIN_SCENARIOS." >&2
  echo "       A scenario dispatch stopped matching, or the ledger detached." >&2
  echo "       Do not lower MIN_SCENARIOS to fix this." >&2
  exit 1
fi

echo "conformance coverage OK: $covered/$total canonical fixtures OPENED by the suite" \
     "(${#KNOWN_UNCOVERED[@]} listed as known-uncovered; runtime manifest — these bytes were really read)"
echo "scenario coverage OK: $scenario_replayed/$scenario_total scenarios of those fixtures REPLAYED" \
     "($scenario_excused excused; runtime ledger — these scenarios really ran)"
