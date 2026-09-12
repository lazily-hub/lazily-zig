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
  # Register CRDTs (LWW / MV / PnCounter + the CellCrdt projection bit) are
  # implemented here, but this binding has no canonical replay for the new
  # registers corpus yet; the Registers coverage row is `~` until it does.
  "collections/registers_convergence.json"
  # Reactive egress is currently Rust-only; Zig has no egress replay runner.
  "egress/egress_generation_fence.json"
  "egress/egress_inflight_window.json"
  "egress/egress_ordered_ack.json"
  "egress/egress_retry_budget.json"
  # The experimental protobuf-v1 generator pilot is Rust/Kotlin/TypeScript;
  # this binding must negotiate the capability before replaying the typed trace.
  "protobuf/graph_boundary_traces.json"
  # No runner at all in this binding.
  "agent-doc/delta_agent_doc_state.json"
  "agent-doc/snapshot_agent_doc_state.json"
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
# Written open-and-close on separate lines even while empty: lazily-spec's
# check-corpus-floors.mjs finds an array by `NAME=(` and then scans for the next
# line beginning `)`, so a same-line `NAME=()` hands it the CLOSE of whichever
# array comes next and every entry in between reads as a scenario excuse. That is
# what made 25 KNOWN_UNBOUND_BLOCKS entries subtract 25 from this binding's
# derived scenario count (#lzzigblockwalk). The parser is fixed there too; this
# shape is the half that does not depend on which lazily-spec a checkout has.
SCENARIO_EXCUSES=(
)

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
# this script would. The Makefile exports $(CURDIR)/...; the relative fallback
# here is for reading an existing manifest from the repo root.
#
# Running this script by hand is no longer enough on its own: the run-id gate
# below needs the nonce of the invocation that produced the evidence, and that
# nonce is minted per `make` invocation. The by-hand path is `make
# conformance-coverage`, which re-runs the suite and the guard under one id.
# There is deliberately NO opt-out flag: every caller in this repo (the
# Makefile target and the CI step) sets the nonce, so an unstamped path would be
# a hole with an extra step rather than a legitimate use.
MANIFEST="${LAZILY_CONFORMANCE_MANIFEST:-build/conformance-fixtures-loaded.txt}"

if [ ! -e "$MANIFEST" ]; then
  echo "FAIL: no conformance manifest at $MANIFEST." >&2
  echo "      Run the suite with LAZILY_CONFORMANCE_MANIFEST set to an ABSOLUTE" >&2
  echo "      path (\`make test\` does) so the recorder attaches. An absent" >&2
  echo "      manifest is missing evidence, not evidence of absence." >&2
  exit 1
fi
# Zero bytes and absent are different faults and used to share one message.
# Splitting them is not cosmetic: the records check further down needs a file it
# can read, and "the file is there and the suite wrote nothing into it" is the
# state `make test`'s truncation manufactures, which is worth saying out loud.
#
# This is now a check on BYTES only, and bytes are no longer the same question as
# evidence — see the records rung below (#lzstampsatisfiesnonempty).
if [ ! -s "$MANIFEST" ]; then
  echo "FAIL: the conformance manifest at $MANIFEST is EMPTY." >&2
  echo "      \`make test\` truncates it before the suite and the recorder only" >&2
  echo "      appends, so zero bytes means the suite ran with no recorder" >&2
  echo "      attached. That is missing evidence, not evidence of absence." >&2
  exit 1
fi
# ---------------------------------------------------------------------------
# EVIDENCE FRESHNESS: the manifest must be THIS invocation's (#lzstalemanifest)
# ---------------------------------------------------------------------------
#
# Every rung below says "the runtime manifest — these bytes were really read".
# Nothing in it said WHEN. This script reads a file off disk and asserts what a
# run did; with no id to date the file, "really read" meant "read by some run,
# ever", and the entire evidence channel was conditional on a build state
# nobody checked. Proved, not assumed: before this gate landed, pointing
# LAZILY_CONFORMANCE_MANIFEST at a copy of a six-week-old manifest printed all
# four OK rungs at exit 0.
#
# This binding's `make`/CI path is the NARROW case. `make test` truncates the
# manifest before the suite and the recorder only appends, so a run that wrote
# NOTHING leaves a zero-byte file and the `-s` check above fails it. That was the
# whole argument, and stamping cost it half its reach: a file carrying stamps and
# no evidence is not zero bytes, so `-s` waves it through. The records rung below
# is the other half, and it is the check that now carries the claim
# (#lzstampsatisfiesnonempty).
#
# And a zig test Run step cannot be a cache hit in the first place: every
# `zig build` invocation mints a random `--seed=0x...`, the build runner passes
# it in each test Run step's argv (std.Build.Step.Run line ~249), and argv bytes
# are hashed into that step's cache manifest — so `has_side_effects` is belt on
# top of braces, not the only thing running the binaries. Verified by removing
# the flag: a second `zig build test` with nothing changed still reported
# `546 pass` for every run step while every `compile test` reported `cached`.
#
# What was open, and what this closes, is the other half: a guard that trusts a
# file it did not watch being written. Truncation is a property of one recipe
# line; delete it, add a second guard invocation that does not re-run the suite,
# or run the script against a stale path, and the rungs go green on last week's
# run. A positive id is the assertion the truncation was only ever implying.
#
# The stamp is written by the test BINARY, never by the Makefile. A
# Makefile-written stamp would date evidence the suite never produced and would
# turn the empty-manifest failure into a pass, which is strictly worse than no
# gate.
RUN_ID="${LAZILY_CONFORMANCE_RUN_ID:-}"
if [ -z "$RUN_ID" ]; then
  echo "FAIL: LAZILY_CONFORMANCE_RUN_ID is unset, so this run has no identity to" >&2
  echo "      check the evidence in $MANIFEST against." >&2
  echo "      REFUSING rather than skipping: a guard that accepts unstamped" >&2
  echo "      evidence when the nonce is absent is the stale-evidence hole with" >&2
  echo "      an extra step. Run \`make conformance-coverage\`, which mints one" >&2
  echo "      nonce per invocation and passes it to both the suite and this" >&2
  echo "      script (#lzstalemanifest)." >&2
  exit 1
fi
RUN_ID_PREFIX="# lazily-run-id "
STAMPS="$({ grep "^$RUN_ID_PREFIX" "$MANIFEST" || true; } | sed "s|^$RUN_ID_PREFIX||")"
if [ -z "$STAMPS" ]; then
  echo "FAIL: $MANIFEST carries no '$RUN_ID_PREFIX<id>' line." >&2
  echo "      Wanted id: $RUN_ID" >&2
  echo "      The recorder stamps one as the first line it writes, so a manifest" >&2
  echo "      without it was written by a suite that had no nonce — or predates" >&2
  echo "      this gate entirely. Either way it is evidence about some other run" >&2
  echo "      and cannot be read as evidence about this one (#lzstalemanifest)." >&2
  exit 1
fi
# EVERY stamp, not just the first: a dozen test binaries append to one manifest,
# so one of them running under a different id is exactly the partial-staleness
# case a first-line-only check would wave through.
while IFS= read -r stamp; do
  [ -n "$stamp" ] || continue
  if [ "$stamp" != "$RUN_ID" ]; then
    echo "FAIL: $MANIFEST is evidence from a DIFFERENT run." >&2
    echo "      found id:  $stamp" >&2
    echo "      wanted id: $RUN_ID" >&2
    echo "      Every rung below reports what 'the run' did, so reading a" >&2
    echo "      manifest another invocation wrote would report that run's" >&2
    echo "      coverage as this one's. Re-run the suite and the guard under one" >&2
    echo "      invocation: \`make conformance-coverage\` (#lzstalemanifest)." >&2
    exit 1
  fi
done <<< "$STAMPS"
# The FIRST line too, not only the set. The recorder emits its stamp before its
# first evidence line, so the first line of a well-formed manifest is always a
# stamp; anything else means evidence landed ahead of any id — a writer with no
# nonce, which the set check alone cannot see once a later writer supplies one.
FIRST_LINE="$(head -n 1 "$MANIFEST")"
case "$FIRST_LINE" in
"$RUN_ID_PREFIX"*) ;;
*)
  echo "FAIL: the first line of $MANIFEST is not a run-id stamp." >&2
  echo "      first line: $FIRST_LINE" >&2
  echo "      wanted id:  $RUN_ID" >&2
  echo "      Evidence ahead of any stamp means some writer had no nonce, so" >&2
  echo "      part of this manifest is unattributable (#lzstalemanifest)." >&2
  exit 1
  ;;
esac

# ---------------------------------------------------------------------------
# RECORDS, not BYTES: a stamp is not evidence (#lzstampsatisfiesnonempty)
# ---------------------------------------------------------------------------
#
# The `-s` check above WAS the whole "the recorder produced evidence" claim: the
# manifest is truncated before the suite and only appended to, so zero bytes
# meant zero records. Stamping the file broke that implication in the same commit
# that made the evidence datable. A manifest holding nothing but stamps is 42
# bytes for one stamp, and 42 bytes satisfy `-s`.
#
# MEASURED, not reasoned about. A stamp-only file under the matching nonce
# cleared `-s`, cleared both stamp gates, and reached the fixture rung, which
# printed 138 "canonical fixture X was NOT opened" errors — each of them saying
# "a runner may still name it in source while no longer reading it". So nothing
# went green: the guard refused, and the positive-evidence floors would have
# refused again. What was lost is the DIAGNOSIS. A run that recorded nothing at
# all was reported as 138 separate replay regressions, which is the wrong
# investigation to send someone on, and the comment above claimed the `-s` check
# had already handled this case.
#
# So measure the thing the rungs below actually consume: lines that are not
# stamps. Every evidence channel — bare fixture ids, `@scenario`, `@prose`,
# `@block` — is one such line, so this is a floor under all of them at once and
# not a fourth channel-specific count.
#
# `awk` with `index($0, pre) != 1` rather than a grep pipeline: `grep -c` exits 1
# on a zero count, which under `set -o pipefail` aborts this script with no
# message at all — the failure mode reports as a crash rather than as this
# refusal. `index` is a literal search, so the prefix needs no regex quoting, and
# `NF` drops blank lines without a second pass.
RECORD_LINES="$(awk -v pre="$RUN_ID_PREFIX" \
  'index($0, pre) != 1 && NF { n++ } END { print n + 0 }' "$MANIFEST")"
STAMP_LINES="$(awk -v pre="$RUN_ID_PREFIX" \
  'index($0, pre) == 1 { n++ } END { print n + 0 }' "$MANIFEST")"
if [ "$RECORD_LINES" -eq 0 ]; then
  echo "FAIL: $MANIFEST carries $STAMP_LINES run-id stamp(s) and NO evidence lines." >&2
  echo "      wanted id: $RUN_ID" >&2
  echo "      A stamp dates evidence; it is not evidence. Every rung below reads" >&2
  echo "      this file for fixtures OPENED, scenarios REPLAYED, prose VERIFIED" >&2
  echo "      and assertion blocks BOUND, and a stamped file with no records" >&2
  echo "      makes all four populations empty while still satisfying the" >&2
  echo "      byte-size check above. The suite attached the recorder and then" >&2
  echo "      read nothing, or this file is not the one the suite wrote" >&2
  echo "      (#lzstampsatisfiesnonempty)." >&2
  exit 1
fi

# THREE evidence channels share one file, plus the run-id stamp. A
# corpus-relative fixture id can begin with neither `@` nor `#`, so every split
# is a plain grep and needs no second manifest, no second environment variable,
# and no second build.zig wiring.
TAB=$'\t'
SCENARIO_MARK="@scenario$TAB"
PROSE_MARK="@prose$TAB"
# `-e '^#'` as well as `-e '^@'`: a stamp line is not a fixture id, and leaving
# it in OPENED would invent a fixture named after the nonce.
OPENED="$({ grep -v -e "^@" -e "^#" "$MANIFEST" || true; } | sort -u)"
# `fixture<TAB>scenario-id`, one line per scenario the suite actually replayed.
SCENARIO_LEDGER="$({ grep "^$SCENARIO_MARK" "$MANIFEST" || true; } \
  | sed "s|^$SCENARIO_MARK||" | sort -u)"
# One line per fixture whose prose discharges reached verifyProse
# (#lzprosekeyconvention, rule 8).
PROSE_LEDGER="$({ grep "^$PROSE_MARK" "$MANIFEST" || true; } \
  | sed "s|^$PROSE_MARK||" | sort -u)"

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

# ---------------------------------------------------------------------------
# Prose-verification accounting (#lzprosekeyconvention, rule 8).
# ---------------------------------------------------------------------------
#
# Rules 1-7 of the prose-key convention are all satisfied over an EMPTY
# population: a fixture whose bytes are opened and whose blocks are never built
# declares paragraphs that nothing has to discharge, and its tracker never runs.
# That is the same vacuity `anti_vacuity` exists to name, reappearing inside the
# guard meant to enforce it.
#
# So the required set is derived from the CORPUS, never from a hand-kept list:
# every fixture that declares `assertions.prose` and whose bytes this suite
# opened must appear in the prose ledger. A tenth paragraph landing upstream
# reddens here on its own.
prose_required=0
prose_verified=0

declares_prose() {
  jq -e '(.assertions.prose? // []) | type == "array" and length > 0' "$SPEC_DIR/$1" \
    >/dev/null 2>&1
}

while IFS= read -r fixture; do
  [ -n "$fixture" ] || continue
  declares_prose "$fixture" || continue
  prose_required=$((prose_required + 1))
  if grep -qxF "$fixture" <<< "$PROSE_LEDGER"; then
    prose_verified=$((prose_verified + 1))
    continue
  fi
  echo "ERROR: '$fixture' declares \`assertions.prose\` and this run never reached" >&2
  echo "       verifyProse for it. Every prose rule holds vacuously over a fixture" >&2
  echo "       that was opened and not replayed, so a green suite would prove" >&2
  echo "       nothing about its paragraphs (#lzprosekeyconvention, rule 8)." >&2
  missing=$((missing + 1))
done <<< "$OPENED"

# The channel guards itself, in both directions: a verification recorded for a
# fixture the manifest never opened, or for one carrying no declaration, means
# the recorder is writing claims rather than observations.
while IFS= read -r fixture; do
  [ -n "$fixture" ] || continue
  if ! grep -qxF "$fixture" <<< "$OPENED"; then
    echo "ERROR: prose ledger records '$fixture', which the fixture manifest says" >&2
    echo "       was never opened. Verification computed from this ledger cannot be" >&2
    echo "       trusted (#lzprosekeyconvention)." >&2
    missing=$((missing + 1))
    continue
  fi
  if ! declares_prose "$fixture"; then
    echo "ERROR: prose ledger records '$fixture', which declares no" >&2
    echo "       \`assertions.prose\`. The runner is verifying a declaration the" >&2
    echo "       corpus dropped (#lzprosekeyconvention)." >&2
    missing=$((missing + 1))
  fi
done <<< "$PROSE_LEDGER"

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
# These floors track WHAT CI ACTUALLY REPLAYS, exactly — no margin, no slack.
# Re-pinned 2026-09-11 against lazily-spec `f89d865`, which carries the
# `conformance/replay/` area this binding now replays (#lzreplayzig):
# 138/156 fixtures OPENED, 151/151 scenarios REPLAYED. All three pinned
# toolchains (0.15.2 / 0.16.0 / master) report the same two numbers locally —
# 0.15.2 skips four tests and opens the same fixtures. Each is EXACT — 139 and
# 152 both fail.
#
# Re-verified 2026-09-11 against lazily-spec `4010d99` (#lzreplayframing): that
# commit added three STEPS to `replay/canonical_encoding_equality.json` and no
# fixture and no scenario, so both numbers are unmoved and neither was touched.
# The floor that DID move for it is a step count inside the runner
# (`replay_conformance.zig`, 11 -> 14), because a step floor with slack hides new
# rows exactly the way a fixture floor with slack hides new fixtures.
#
# Previously 134/152, pinned 2026-08-11 from CI run 31501252193 against
# lazily-spec `39df4b3`; 132/147 before that.
#
# Do NOT raise a floor "by however many this change adds" and leave the old
# margin in place. That was the convention here, and it is the bug: the floor
# only ever trailed further behind, until MIN_SCENARIOS sat at 91 against 147
# actually replayed and 56 scenarios could have stopped being dispatched with
# this guard still green — the exact failure it exists to prevent. Slack is
# where drift hides.
#
# The number must describe what CI's fresh clone of lazily-spec guarantees, not
# what a working tree happens to hold (#lzspecpushbeforebindings). When a change
# genuinely adds replays, re-read the coverage lines from a completed CI run and
# set the floor to that total. Do NOT lower a floor to fix a red run — a drop
# means the corpus or the recorder shrank, and that is the finding.
#
# An upstream fixture that lands without a zig runner raises `total` and leaves
# `covered` alone, so it does not trip MIN_FIXTURES; only a replay that STOPS
# running does.
MIN_FIXTURES="${MIN_FIXTURES:-138}"
MIN_SCENARIOS="${MIN_SCENARIOS:-151}"

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

if [ "$prose_required" -eq 0 ]; then
  echo "ERROR: NO opened fixture declares \`assertions.prose\`." >&2
  echo "       The corpus carries five that do, so either the manifest detached or" >&2
  echo "       the declaration was dropped upstream — and rule 8 is vacuously green" >&2
  echo "       either way (#lzprosekeyconvention)." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# RUNG 0: the assertion-block BIND ledger (#lznullformblind)
# ---------------------------------------------------------------------------
#
# Every rung above is scoped to a block a runner already BOUND to an
# `AssertionKeys` tracker. The unconsumed-key check fires on a key nothing read;
# the read-but-not-asserted check on a key read and discarded; the prose ledger
# on a discharge naming nothing. NONE of them can fire for a block no runner
# ever bound, because there is no tracker: its keys are not unread, nothing
# reads them, and the fixture reports exactly nothing.
#
# This binding had twenty-two such blocks. `arena_blob.json`'s six-key
# `assertions` block was read by nothing at all — the runner replays `input`
# against `expected` and never opens it. The seventeen `signaling/frames.json`
# and four `distributed/crdt_sync_frames.json` per-frame blocks were checked by
# hand-rolled loops that refuse an unknown key but never bind, so the ledger
# rungs could not see them either. All twenty-two now bind.
#
# An unbindable block belongs HERE, as a documented excuse the guard reads every
# run, not as a runner fabricated to manufacture coverage.
#
# Every entry below is a step of one of the six fixtures in
# reactive_graph_conformance.zig's EXPECTED_SKIPS: the replay stops on an op or
# an assertion key this binding does not implement, so the steps past that point
# never run and their `expect` blocks are unreachable rather than unbound. They
# are written per SITE and not per fixture on purpose — when the op lands, each
# entry fails as STALE and has to be deleted one at a time, which is what stops
# the excuse outliving the gap it describes.
# Format: "fixture|where|reason".
KNOWN_UNBOUND_BLOCKS=(
  "reactive-graph/exact_fold_paths_stay_exact.json|steps[2].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/exact_fold_paths_stay_exact.json|steps[3].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/exact_fold_paths_stay_exact.json|steps[4].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/feedback_drain_bound_reports_exhaustion.json|steps[1].expect|skipped in every context: the fixture asserts the novel drain_exhausted key (parked upstream), so reactive_graph_conformance's replay stops on it (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/feedback_drain_bound_reports_exhaustion.json|steps[2].expect|skipped in every context: the fixture asserts the novel drain_exhausted key (parked upstream), so reactive_graph_conformance's replay stops on it (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/feedback_drain_bound_reports_exhaustion.json|steps[3].expect|skipped in every context: the fixture asserts the novel drain_exhausted key (parked upstream), so reactive_graph_conformance's replay stops on it (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/merge_cell_acquires_no_dependency_edge.json|steps[1].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/merge_cell_acquires_no_dependency_edge.json|steps[2].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/merge_cell_acquires_no_dependency_edge.json|steps[3].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/merge_cell_acquires_no_dependency_edge.json|steps[4].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/merge_feed_through_a_formula_coalesces.json|steps[2].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/merge_feed_through_a_formula_coalesces.json|steps[3].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/merge_feed_through_a_formula_coalesces.json|steps[4].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/merge_feed_through_a_formula_coalesces.json|steps[5].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/merge_feed_through_a_formula_coalesces.json|steps[6].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/merge_feed_through_a_formula_coalesces.json|steps[7].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/merge_folds_synchronously_in_batch.json|steps[1].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/merge_folds_synchronously_in_batch.json|steps[2].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/merge_folds_synchronously_in_batch.json|steps[3].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/merge_per_settled_cone_not_per_write.json|steps[1].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/merge_per_settled_cone_not_per_write.json|steps[2].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/merge_per_settled_cone_not_per_write.json|steps[3].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/merge_per_settled_cone_not_per_write.json|steps[4].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/merge_per_settled_cone_not_per_write.json|steps[5].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
  "reactive-graph/merge_per_settled_cone_not_per_write.json|steps[6].expect|skipped in every context: the fixture drives a merge_cell op and this binding's reactive graph has no merge-feed node kind, so reactive_graph_conformance's replay stops on the op (EXPECTED_SKIPS) and no later step's expect is reached"
)

BLOCK_EXCUSES="$(printf '%s\n' "${KNOWN_UNBOUND_BLOCKS[@]:-}")" \
CORPUS_DIR="$SPEC_DIR" \
UNCOVERED_FIXTURES="$(printf '%s\n' "${KNOWN_UNCOVERED[@]:-}")" \
MANIFEST="$MANIFEST" \
python3 - <<'PY_BLOCKS'
import json
import math
import os
import struct
import sys

ledger_path = os.environ["MANIFEST"]
declared = {}   # digest -> {"fixture|where"}
bound = set()   # digest
for line in open(ledger_path):
    parts = line.rstrip("\n").split("\t")
    if parts[0] != "@block":
        continue
    if parts[1] == "declared" and len(parts) == 5:
        declared.setdefault(parts[3], set()).add("%s|%s" % (parts[2], parts[4]))
    elif parts[1] == "bound" and len(parts) == 3:
        bound.add(parts[2])

excuses = {}
for raw in os.environ.get("BLOCK_EXCUSES", "").splitlines():
    raw = raw.strip()
    if not raw:
        continue
    parts = raw.split("|", 2)
    if len(parts) != 3 or not parts[2].strip():
        sys.stderr.write(
            "ERROR: KNOWN_UNBOUND_BLOCKS entry %r must be 'fixture|where|reason'.\n"
            "       An excuse with no reason is an unexplained gap wearing a green badge.\n"
            % raw
        )
        sys.exit(1)
    excuses["%s|%s" % (parts[0], parts[1])] = parts[2]

declared_sites = {}   # "fixture|where" -> digest
declared_fixtures = set()
for digest, sites in declared.items():
    for site in sites:
        declared_sites[site] = digest
        declared_fixtures.add(site.split("|", 1)[0])

unbound = []
for digest, sites in sorted(declared.items()):
    if digest in bound:
        continue
    for site in sorted(sites):
        if site not in excuses:
            unbound.append(site)

# BOTH the other directions, or the ledger rots into a list nobody can audit.
# An excuse naming a site this run did not inventory describes a block that
# moved or is gone; an excuse naming a site whose digest a runner DID bind hides
# nothing and is the same false green the excuse was written to avoid.
stale = []
for site in sorted(excuses):
    fixture = site.split("|", 1)[0]
    digest = declared_sites.get(site)
    if digest is None:
        # Out of scope rather than stale when the fixture was not opened at all:
        # a `zig build test` filtered to one module would otherwise print a wall
        # of noise for every fixture it did not reach.
        if fixture in declared_fixtures:
            stale.append((site, "the opened fixture no longer carries this block"))
        continue
    if digest in bound:
        stale.append((site, "a runner DOES bind this block now"))

if stale:
    sys.stderr.write(
        "ERROR: %d KNOWN_UNBOUND_BLOCKS entr(ies) are stale — the gap each described\n"
        "       has been closed, so the excuse now hides nothing:\n" % len(stale)
    )
    for site, why in stale:
        sys.stderr.write("         %s: %s\n" % (site, why))
    sys.stderr.write("       Delete each one.\n")
    sys.exit(1)

if unbound:
    sys.stderr.write(
        "ERROR: %d assertion block(s) were carried by an OPENED fixture and bound by\n"
        "       no runner. Every rung above is scoped to blocks a runner bound, so\n"
        "       these report nothing at all rather than reporting a gap:\n" % len(unbound)
    )
    for site in unbound:
        sys.stderr.write("         %s\n" % site)
    sys.stderr.write(
        "       Bind each with `cj.AssertionKeys.init(where, block)` and assert its\n"
        "       keys, or add it to KNOWN_UNBOUND_BLOCKS with a reason so the gap is\n"
        "       visible every run instead of invisible.\n"
    )
    sys.exit(1)

# ---------------------------------------------------------------------------
# The ledger SIZE, pinned as an EQUALITY (#lzledgerceiling, #lzledgerratchet)
# ---------------------------------------------------------------------------
#
# Both directions above are EQUALITIES against the run: a declared block that no
# runner bound and that nothing excuses fails, and an excuse whose site a runner
# DOES bind fails as stale. That pair is strictly stronger than a count — and it
# is still satisfied by ANY CONSISTENT PAIR. A commit that detaches N binds and
# writes the N matching KNOWN_UNBOUND_BLOCKS entries agrees with itself in both
# directions and passes. lazily-rs proved exactly that by dropping one `bound`
# line and adding its matching entry (962923a).
#
# The magnitude rung below cannot see it either, and for a reason worth stating:
# it compares the DECLARED inventory against the corpus, and a detached bind
# leaves the block declared. `declared` does not move; only `bound` does. Every
# derived equality in this file stays green.
#
# So the ledger's SIZE is pinned against a COMMITTED CONSTANT — the one thing in
# this rung that does not move when the run moves. That independence is the
# entire value: the set equalities compare the ledger to the RUN, and under the
# attack both of those sides move together.
#
# #lzledgerratchet — this landed as a CEILING (`len(ledger) > PIN` fails), and
# that operator SELF-DISABLES. A ceiling refuses the detach-and-excuse attack
# only while slack is zero. Migrate one site: the ledger shrinks, the constant
# stays put, and there is now room for one free detach, silently. Accumulate a
# migration's worth of slack per migration and it converges on exactly the
# hand-typed `>=` floor the section below retired — a number with enough slack
# that it never fires, and so never gets updated.
#
# An EQUALITY has no slack by construction. It cannot drift, because a stale
# value FAILS rather than going quiet; a number that fails when stale is a
# ratchet, not drift. Both directions are things a person must see:
#
#   GROWTH — an excuse was added: either a bind was detached (the attack above),
#            or a genuinely unbindable site appeared. Raising this line is the
#            legitimate case and must be DELIBERATE and visible in the diff — a
#            corpus that gains an unreachable fixture is the real one. Do NOT
#            raise it to park a block a runner could bind today; that is the
#            laundering this guard exists to refuse.
#   SHRINK — sites were migrated and this line was not lowered in the same
#            commit. That is the work landing, and the pin has to record it.
#
# This is not the mirroring count that argument warns about, and not a second
# drifting edit site. A count of what IS excused, derived from the ledger, would
# be equal to it by construction and say nothing; the ledger's size is derivable
# from nothing in this script, so an independent committed constant is the only
# way to state it at all. MIN_FIXTURES / MIN_SCENARIOS stay `>=` for a different
# reason: they floor the OPENED and REPLAYED populations, which is a corpus
# SHRINK no set equality in this file can see.
#
# Every one of the 25 entries is a step past an EXPECTED_SKIPS stop in
# reactive_graph_conformance — unreachable rather than unbindable — so the work
# is landing the merge-feed node kind and the `drain_exhausted` key, after which
# this number goes to 0 and needs no maintenance at all.
_ledger_pin = os.environ.get("EXPECTED_LEDGERED_BLOCKS", "25")
# ONE parse for the whole family (#lzpinparsestrict): a NON-EMPTY run of bare
# ASCII digits `0`-`9`, and nothing else. Validated BEFORE any parse runs, and
# deliberately stricter than both `int()` and `str.isdigit()`, because each of
# those silently accepts a number nobody wrote: `int("1_0")` is 10 (PEP 515
# separators), `int(" 7 ")` is 7, and `"\u0663".isdigit()` is true for the
# Arabic-Indic three. This reader used to be `int(_ledger_pin.strip())`, so all
# three got through. Refused now: whitespace around or inside, a leading `+` or
# `-`, separators, a radix prefix, a float or an exponent, and any non-ASCII
# digit. A negative falls out of the same check — no ledger size can equal it, so
# it would make this rung unsatisfiable rather than exact. Leading zeros are fine
# and `0` stays valid; this number goes to 0 when the merge-feed node kind and
# `drain_exhausted` land.
#
# An UNSET variable takes the committed literal above. An EXPLICITLY EMPTY one is
# a REJECTION, not a fall-through to it: `os.environ.get(NAME, DEFAULT)`
# distinguishes the two, and whoever exported the wrong thing is the one person
# who cannot see that it was ignored.
if not _ledger_pin or _ledger_pin.strip("0123456789"):
    sys.stderr.write(
        "ERROR: EXPECTED_LEDGERED_BLOCKS is %r, which is not a count of sites in bare\n"
        "       ASCII digits (#lzpinparsestrict).\n"
        "       This fails CLOSED rather than falling back to the committed default —\n"
        "       not even for an empty value: an override that quietly reverted to the\n"
        "       built-in would report OK against a pin nobody chose, which is the\n"
        "       unexaminable green every rung here refuses (#lzvacuousrun).\n"
        % _ledger_pin
    )
    sys.exit(1)
EXPECTED_LEDGERED_BLOCKS = int(_ledger_pin)

if len(excuses) != EXPECTED_LEDGERED_BLOCKS:
    if len(excuses) > EXPECTED_LEDGERED_BLOCKS:
        sys.stderr.write(
            "ERROR: the KNOWN_UNBOUND_BLOCKS ledger GREW to %d assertion-block site(s);\n"
            "       EXPECTED_LEDGERED_BLOCKS pins it at %d.\n"
            "       The set equality above cannot see this by itself: it only checks that\n"
            "       the ledger and the run AGREE, which ANY CONSISTENT PAIR satisfies. A\n"
            "       commit that detaches binds and writes the matching entries passes it\n"
            "       in BOTH directions, because a detached bind leaves the block DECLARED\n"
            "       — so the magnitude rung below stays green too. This pin is the only\n"
            "       thing in this rung that does not move when the run moves.\n"
            "       Bind the block with `cj.AssertionKeys.init(where, block)`. RAISE this\n"
            "       line only for a block that CANNOT be bound, with a reason in its\n"
            "       ledger entry, and expect to be asked why the capability cannot exist.\n"
            % (len(excuses), EXPECTED_LEDGERED_BLOCKS)
        )
    else:
        sys.stderr.write(
            "ERROR: the KNOWN_UNBOUND_BLOCKS ledger SHRANK to %d assertion-block site(s);\n"
            "       EXPECTED_LEDGERED_BLOCKS still pins it at %d.\n"
            "       Nothing is broken — this is the work landing. LOWER THE PIN TO %d IN\n"
            "       THIS COMMIT, so the diff records that %d site(s) stopped needing an\n"
            "       excuse.\n"
            "       Leaving it high is worse than noise: a pin above the ledger is SLACK,\n"
            "       and slack is a free detach that the set equality above cannot see. It\n"
            "       is exactly how a `>=` floor rots into a number that can no longer\n"
            "       fire (see the section below).\n"
            % (len(excuses), EXPECTED_LEDGERED_BLOCKS, len(excuses),
               EXPECTED_LEDGERED_BLOCKS - len(excuses))
        )
    sys.stderr.write("       The ledger as this run read it:\n")
    _listed = sorted(excuses.items())
    _cap = 40
    for site, reason in _listed[:_cap]:
        sys.stderr.write("         %s: %s\n" % (site, reason))
    if len(_listed) > _cap:
        sys.stderr.write(
            "         ... and %d more not listed. `git diff --\n"
            "         scripts/check-conformance-coverage.sh` shows which entries this\n"
            "         commit actually moved.\n" % (len(_listed) - _cap)
        )
    sys.exit(1)

# ---------------------------------------------------------------------------
# Positive-evidence floor, DERIVED from the corpus (#lzvacuousrun, #lzblockfloorpin).
# ---------------------------------------------------------------------------
#
# Zero declared blocks means zero unbound blocks, which reports OK having
# compared nothing, so the MAGNITUDE has to be asserted before this rung may
# print. Until now it was asserted against a hand-typed constant with a `>=`:
#
#     MIN_BLOCKS = int(os.environ.get("MIN_BLOCKS", "31"))
#     if len(declared) < MIN_BLOCKS: ...
#
# Both halves of that are wrong. A typed number drifts the moment the corpus
# moves and the only signal is a guard that keeps printing OK over a smaller
# inventory; and `>=` cannot see a SHRINK that stays above the floor, which is
# the drift the floor exists to catch. `31` was re-pinned by hand off a CI log
# (run 31343252373, 2026-08-09) — a number nobody could check without running CI.
#
# So compute it, from two things this repo already has to be right about: the
# canonical corpus on disk, and KNOWN_UNCOVERED. The fixture rungs far above
# prove those two compose to exactly the opened set — every corpus fixture the
# suite did not open must appear in KNOWN_UNCOVERED, and every KNOWN_UNCOVERED
# entry must name a real corpus file the suite did NOT open — so
# `corpus \ KNOWN_UNCOVERED` IS the opened set, the same rule MIN_FIXTURES is
# read against, and it currently yields 156 - 18 = 138 fixtures.
#
# It is deliberately NOT derived from the manifest. A manifest-derived
# expectation follows the actual count into the ditch: let the recorder detach
# and `declared` goes to 0 with the expectation right behind it, green over
# nothing — the exact #lzvacuousrun failure this floor exists to prevent. The
# corpus on disk is the independent witness; the manifest is the thing on trial.
#
# SCOPE — the walk mirrored below is recordDeclaredBlocks() in
# src/lazily/conformance_manifest.zig, and the two must stay one rule: every
# name in BLOCK_NAMES (`assertions`, `expect`, `expect_after`, `expect_initial`,
# `expected`) at EVERY depth, OBJECT-VALUED or ONE PLAIN-OBJECT ELEMENT of an
# ARRAY-VALUED one, a block emitted and not descended into.
#
# The two halves are WIDENED IN STEP and pinned against each other by the
# equalities below, which is what makes widening safe to do at all: a site the
# runtime inventories and this walk does not derive fails as MORE than expected,
# and a site this walk derives that the runtime does not enumerate fails as
# FEWER. Neither half can be widened alone and stay green.
#
# It used to be the top-level `assertions` key plus the `assertions` key of each
# OBJECT element of the top-level `frames`/`scenarios`/`rejects` arrays, with no
# recursion (`#lzzigblockwalk`). That inventoried 37 sites / 31 distinct digests
# of the 734 / 625 the same 138 opened fixtures carry — 5.0% — so EVERY
# `expect`/`expected` block in the corpus sat outside the rung that exists to
# catch a block nothing binds, and none of them could be reported unbound. It was
# verbatim the pre-#lzunboundblockguard walk lazily-py had before it widened, and
# widening there surfaced 25 real ones. Widening here surfaced 204 digests over
# 239 sites, every one of them now bound by a tracker or excused below.
#
# An ARRAY-VALUED tracked key contributes one site per PLAIN-OBJECT ELEMENT
# (#lzarrayelementsites). A runner binds the ELEMENTS, never the array, so the
# array itself is still not a site — and the elements are. This clause used to
# read "array-valued tracked keys contribute NO site" on exactly that reasoning,
# which pointed at a site nobody ever emitted: the eight array-valued `expect`
# keys of `signaling/anti_spoof_session.json` carry TWELVE plain-object elements,
# each an expected outbound signaling frame the replay already read and compared,
# and every one of them sat outside rung 0. That is the whole gap, corpus-wide:
# 722 sites / 613 digests before, 734 / 625 after, in one fixture.

# blockDigest() from conformance_manifest.zig, byte for byte: FNV-1a over a
# type-tagged structural rendering, integers and floats folded by their raw
# little-endian bytes rather than any formatted form. Number typing follows
# std.json's parseFromNumberSlice — an integer-formatted literal that overflows
# i64 becomes `.number_string`, and `-0` is a float — because a mis-typed number
# changes the digest and would split one block into two.
FNV_OFFSET = 0xCBF29CE484222325
FNV_PRIME = 0x00000100000001B3
MASK = (1 << 64) - 1
I64_MIN = -(1 << 63)
I64_MAX = (1 << 63) - 1


class Num(object):
    __slots__ = ("tag", "val")

    def __init__(self, tag, val):
        self.tag = tag
        self.val = val


def parse_int(text):
    if text == "-0":          # isNumberFormattedLikeAnInteger() excludes it
        return Num("f", -0.0)
    value = int(text)
    if I64_MIN <= value <= I64_MAX:
        return Num("i", value)
    return Num("N", text)     # overflows i64 -> .number_string


def parse_float(text):
    value = float(text)
    if math.isfinite(value):
        return Num("f", value)
    return Num("N", text)


def feed(h, raw):
    for byte in raw:
        h ^= byte
        h = (h * FNV_PRIME) & MASK
    return h


def hash_value(h, value):
    if value is None:
        return feed(h, b"n")
    if value is True:
        return feed(h, b"b1")
    if value is False:
        return feed(h, b"b0")
    if isinstance(value, Num):
        if value.tag == "i":
            return feed(feed(h, b"i"), value.val.to_bytes(8, "little", signed=True))
        if value.tag == "f":
            return feed(feed(h, b"f"), struct.pack("<d", value.val))
        return feed(feed(h, b"N"), value.val.encode("utf-8"))
    if isinstance(value, str):
        return feed(feed(h, b"s"), value.encode("utf-8"))
    if isinstance(value, list):
        h = feed(h, b"[")
        for item in value:
            h = hash_value(h, item)
        return feed(h, b"]")
    if isinstance(value, dict):
        h = feed(h, b"{")
        for key, item in value.items():
            h = hash_value(feed(feed(h, key.encode("utf-8")), b"="), item)
        return feed(h, b"}")
    raise TypeError(repr(value))


# The walk rule, one definition. `recordDeclaredBlocks()` in
# src/lazily/conformance_manifest.zig is the other half and they must agree
# exactly: a derived expectation that walked the corpus differently from the
# inventory it is compared against would be worse than the typed constant it
# replaced. Only the block VALUES are needed here — the runtime ledger carries
# the `where` labels — but the traversal is the same one, including the
# emit-and-do-not-descend rule, because descending would count a fixture's
# `expect` nested inside its own `assertions` as a second site no tracker can
# reach without unwrapping the first.
BLOCK_NAMES = ("assertions", "expect", "expect_after", "expect_initial", "expected")


def iter_declared_blocks(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key in BLOCK_NAMES:
                if isinstance(value, dict):
                    yield value
                    continue
                # ONE site per PLAIN-OBJECT element of an array-valued tracked
                # key (#lzarrayelementsites). One level only: a non-object
                # element — scalar, null, or a NESTED ARRAY — is not a site and
                # is descended instead, which is what this walk did with every
                # element of such an array before the rule existed. The zig half
                # labels them `<path>[<index>]` by TRUE index; only the COUNT is
                # needed here, which is exactly why the label rule may not depend
                # on anything this half cannot see (a runner's `name`-preferring
                # convention, say).
                if isinstance(value, list):
                    for item in value:
                        if isinstance(item, dict):
                            yield item
                            continue
                        for block in iter_declared_blocks(item):
                            yield block
                    continue
            for block in iter_declared_blocks(value):
                yield block
    elif isinstance(node, list):
        for item in node:
            for block in iter_declared_blocks(item):
                yield block


corpus = os.environ["CORPUS_DIR"]
uncovered = set()
for raw in os.environ.get("UNCOVERED_FIXTURES", "").splitlines():
    raw = raw.strip()
    if raw:
        uncovered.add(raw)

canonical = []
for root, _dirs, files in os.walk(corpus):
    for name in files:
        if name.endswith(".json"):
            canonical.append(
                os.path.relpath(os.path.join(root, name), corpus)
            )
canonical.sort()
opened = [fixture for fixture in canonical if fixture not in uncovered]

expected_sites = 0
expected_digests = set()
for fixture in opened:
    # utf-8 explicitly: the digest is over BYTES, and a C-locale CI runner
    # would otherwise decode non-ASCII fixture text differently than Zig reads it.
    with open(os.path.join(corpus, fixture), encoding="utf-8") as handle:
        try:
            doc = json.load(handle, parse_int=parse_int, parse_float=parse_float)
        except ValueError:
            # Mirrors recordDeclaredBlocks(): bad JSON contributes nothing
            # rather than failing. It then shows up as a mismatch below.
            continue
    if not isinstance(doc, dict):
        continue
    for block in iter_declared_blocks(doc):
        expected_sites += 1
        expected_digests.add(hash_value(FNV_OFFSET, block))

expected = len(expected_digests)
declared_site_count = sum(len(sites) for sites in declared.values())

if len(canonical) == 0:
    sys.stderr.write(
        "ERROR: the corpus at %s listed ZERO fixtures, so the derived assertion-block\n"
        "       expectation is 0 and this rung would pass having compared nothing.\n"
        % corpus
    )
    sys.exit(1)
if expected == 0 or expected_sites == 0:
    sys.stderr.write(
        "ERROR: %d opened fixtures in %s carry ZERO assertion blocks under the walk\n"
        "       in recordDeclaredBlocks(). An expectation of 0 is a green badge over\n"
        "       an empty comparison (#lzvacuousrun).\n" % (len(opened), corpus)
    )
    sys.exit(1)

# TWO dimensions, because a distinct-DIGEST count alone is one short
# (#lzblocksitepin). The digest set is content-keyed, so a block whose content
# recurs elsewhere in the corpus can be deleted outright and the digest count
# does not move: deleting `stdlib/timer.json` scenarios[0].steps[0].expect —
# `{"outcome": "pending", "deadline": 10}`, a shape several stdlib steps share —
# left this rung GREEN when only digests were compared. Only a block with a
# UNIQUE digest was visible. SITES are one per occurrence, so they see it.
#
# Both are derived from the corpus and both are EQUALITIES. A `>=` floor cannot
# see a shrink that stays above it, and a shrink is exactly what a detached
# inventory looks like.
if declared_site_count != expected_sites:
    direction = "FEWER than" if declared_site_count < expected_sites else "MORE than"
    sys.stderr.write(
        "ERROR: the runtime inventory declared %d assertion-block SITES, %s the %d\n"
        "       derived from the corpus (%d of %d canonical fixtures opened). The\n"
        "       distinct-digest count below can agree while this does not: a block\n"
        "       whose content recurs elsewhere leaves the digest set unchanged when\n"
        "       it is deleted, so sites are the dimension that sees it\n"
        "       (#lzblocksitepin).\n"
        % (declared_site_count, direction, expected_sites, len(opened), len(canonical))
    )
    sys.exit(1)

if len(declared) != expected:
    direction = "FEWER than" if len(declared) < expected else "MORE than"
    sys.stderr.write(
        "ERROR: the runtime inventory declared %d distinct assertion blocks, %s the\n"
        "       %d derived from the corpus (%d of %d canonical fixtures opened,\n"
        "       %d block sites under recordDeclaredBlocks()'s walk).\n"
        % (len(declared), direction, expected, len(opened), len(canonical), expected_sites)
    )
    if len(declared) < expected:
        sys.stderr.write(
            "       The corpus carries blocks this run did not inventory: either it\n"
            "       moved and this checkout has not caught up (re-pull lazily-spec and\n"
            "       re-run the suite), or the loader-side inventory detached and\n"
            "       fixtures stopped being read. There is no number to lower here —\n"
            "       the expectation is computed from the corpus, not typed.\n"
        )
    else:
        sys.stderr.write(
            "       This run inventoried blocks the corpus no longer carries, so the\n"
            "       corpus the GUARD walked is not the corpus the RUN read: a manifest\n"
            "       left over from an earlier run, a corpus that shrank underneath it,\n"
            "       or LAZILY_SPEC_CONFORMANCE_DIR pointing the two halves at different\n"
            "       trees. Re-run the suite against THIS corpus.\n"
        )
    sys.exit(1)

print(
    "assertion-block bind OK: %d/%d assertion blocks carried by opened fixtures were"
    " BOUND to a tracker (%d ledgered unbound, EXACTLY the %d pinned — an EQUALITY"
    " against the run in BOTH directions, and the ledger SIZE pinned as an equality"
    " against a committed constant, so neither growing nor shrinking it can be a"
    " side effect; %d distinct digests AND %d sites,"
    " both DERIVED from %d opened of %d canonical fixtures and both asserted EQUAL,"
    " every block name at every depth; content-keyed, so a runner's block NAME"
    " cannot satisfy it)"
    % (
        len(declared),
        len(declared),
        len(excuses),
        EXPECTED_LEDGERED_BLOCKS,
        expected,
        expected_sites,
        len(opened),
        len(canonical),
    )
)
PY_BLOCKS

# ── no replay spells the corpus root itself (#lzzigingressspecdir) ─────────
#
# Every rung above reasons about the corpus the run READ. This one is about
# WHICH corpus that was. Fourteen sites across twelve areas each carried their
# own `const SPEC_DIR = "../lazily-spec/conformance/<area>"` and built paths by
# comptime concatenation, so LAZILY_SPEC_CONFORMANCE_DIR moved some replays and
# not others — and nothing could report it, because a run that reads the DEFAULT
# corpus while believing it was redirected is green either way. Truncating
# fourteen fixtures in a scratch corpus and pointing the suite at it reddened
# ZERO tests before the fix and 26 after.
#
# That silence is what makes this worth a guard rather than a convention: the
# failure mode of a perturbation probe (#lzperturbaudit) is a cell that reads
# "this fixture cannot be made to fail" when in truth the runner never opened the
# bytes. Build corpus paths with specPath/specAreaPath in conformance_manifest.zig
# (or conformance_json.load), which resolve the root at runtime.
#
# conformance_manifest.zig is the one legitimate mention: it DEFINES the default
# and its own tests exercise canonicalisation. The needle is split so this
# script does not match itself.
needle='../lazily-'"spec/conformance"
examined=0
offenders=()
while IFS= read -r f; do
  examined=$((examined + 1))
  case "$f" in */conformance_manifest.zig) continue ;; esac
  # Comments may legitimately quote the old form while explaining it; only code
  # that could BUILD a path counts, so skip `///` and `//!` doc lines.
  #
  # ONE awk, not `grep -v ... | grep -qF ...`. In that pipeline `grep -qF` exits
  # on its first hit, the upstream `grep -v` is killed by SIGPIPE writing the
  # rest, and `set -o pipefail` surfaces that SIGPIPE (141) as the PIPELINE's
  # status — so a file whose non-comment text exceeds the 64KiB pipe buffer
  # reports NO MATCH for a root it does spell. MEASURED: a 134KiB source with
  # `const SPEC_DIR = "../lazily-spec/conformance/collections"` on line 2 gave
  # PIPESTATUS=(141 0) and this rung printed OK and exited 0, deterministically,
  # 40 runs out of 40. EIGHT sources under src/ are over that buffer today and
  # the conformance runners are among them — the files most likely to spell a
  # root. That is a false GREEN in the guard whose whole job is finding these:
  # the same pipefail trap the fixture rung documents above, inverted, and the
  # reason `grep -c` was rejected there too (#lzgrepcpipefail).
  #
  # One process has no pipe to break. `index` is a literal search, so the needle
  # needs no regex quoting, and awk exits 0 only on a hit.
  if awk -v needle="$needle" '
      /^[[:space:]]*\/\// { next }
      index($0, needle) { found = 1; exit }
      END { exit found ? 0 : 1 }
    ' "$f"; then
    offenders+=("$f")
  fi
done < <(find src -name '*.zig' | sort)

# Positive evidence: a walk that examined nothing would report OK over an empty
# set, the vacuous green every other rung here refuses.
if [ "$examined" -lt 20 ]; then
  echo "ERROR: corpus-root scan examined only $examined zig sources — expected the whole tree." >&2
  echo "       Reporting OK here would be a pass over nothing (#lzvacuousrun)." >&2
  exit 1
elif [ "${#offenders[@]}" -gt 0 ]; then
  echo "ERROR: these sources spell the corpus root instead of resolving it at runtime:" >&2
  for f in "${offenders[@]}"; do echo "         $f" >&2; done
  echo "       LAZILY_SPEC_CONFORMANCE_DIR would not reach them, so a perturbation probe" >&2
  echo "       reads their fixtures as unfalsifiable. Build the path with specPath /" >&2
  echo "       specAreaPath (#lzzigingressspecdir)." >&2
  exit 1
fi

echo "conformance coverage OK: $covered/$total canonical fixtures OPENED by the suite" \
     "(${#KNOWN_UNCOVERED[@]} listed as known-uncovered; runtime manifest — these bytes were really read)"
echo "scenario coverage OK: $scenario_replayed/$scenario_total scenarios of those fixtures REPLAYED" \
     "($scenario_excused excused; runtime ledger — these scenarios really ran)"
echo "prose-key coverage OK: $prose_verified/$prose_required fixtures declaring \`assertions.prose\`" \
     "reached verifyProse (runtime ledger — the discharges were really checked)"
