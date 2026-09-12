#!/usr/bin/env bash
# CI-reachability guard (#lzcheckcireachguard).
#
# Fails the build when `make check` runs a gate that CI never reaches. That is the
# drift this guard exists for: someone adds a target to `check`, it passes locally
# forever, and no CI job ever executes it — which is exactly how #lzinteroppeerci
# happened. The interop peer, the single cross-binding wire-compatibility gate, was
# in every binding's `check` and in no binding's workflow, for months.
#
# It also exists because the obvious hand-audit is WRONG. Grepping the workflows
# for "make check" reported all nine bindings as covered; every one of those hits
# was a COMMENT. Comments are the reason this is a script and not a convention:
# only `run:` bodies count here, and comment lines inside them are stripped before
# anything is matched.
#
# WHAT IT PROVES
#
#   For every target in `check`'s prerequisite closure, at least one CI `run:`
#   step invokes the same program with the same distinguishing flags.
#
# WHAT IT DOES NOT PROVE
#
#   That CI runs it against the same inputs, in the same environment, or that the
#   command means the same thing there. Reach is a floor, not equivalence. The
#   sibling guards (conformance-coverage, assertion-keys, scenario-coverage) are
#   what prove a run examined anything.
#
# HOW A TARGET IS MATCHED
#
#   Recipes are read through `make -n`, so make variables are already expanded and
#   we compare real command lines rather than source text. `make -p` is
#   deliberately NOT used: it dumps the entire environment to stdout, which would
#   print every secret in the job's env into the CI log.
#
#   Each command is split on the shell's sequencing operators, redirections are
#   dropped, and the remainder is reduced to an ANCHOR: the program basename plus
#   its subcommands and flag NAMES (values dropped), with path arguments reduced to
#   basenames and bare path globs discarded. A target is reached when EVERY one of
#   its anchors is a subsequence of some CI command's token list, or when CI runs
#   `make <target>` directly. Every, not any: a target that runs two gates and is
#   half-covered by CI is a gap, and "any" would report it green.
#
#   AND, since #reversereachdirection, "some CI command" is narrowed to the command
#   of the one CI STEP that target is pinned to. Asked of the flat union of every
#   `run:` body in the workflow, reach is satisfiable by a step that has nothing to
#   do with the target — which is how a repointed recipe read as reached, and how
#   four of this repo's seven gates survived having their own CI step deleted.
#
#   Keeping flag names in the anchor is what makes the guard falsifiable rather
#   than decorative: `go test -race` does not match a CI step that only runs
#   `go test -count=1`, so dropping the race job reddens this guard instead of
#   being absorbed by the plain test job.
#
#   An argument that is still a VARIABLE reference at this point — `$MANIFEST` in
#   a CI step, or a `$$VAR` a recipe leaves for the shell — names a value the
#   guard cannot resolve, so it becomes a WILDCARD matching exactly one token on
#   the other side (#lzcireachvaranchor). Make and CI routinely spell the same
#   path differently, one through an expanded `$(VAR)` and the other through the
#   environment, and they are the same command. Dropping the token instead, which
#   is what this used to do, lost the argument as well as its value and reported
#   a step that genuinely ran the gate as unreachable — a false RED that cost one
#   binding a hardcoded second spelling of the path plus a hand-written equality
#   assertion, which is a new drift surface invented to satisfy a guard whose job
#   is detecting drift. Arity still counts: `script.sh $A` does not match a CI
#   step that passes no argument at all.
#
#   Commands whose program is a shell builtin or a plain file/text utility carry no
#   gate, so they contribute no anchor. A target with no non-trivial command at all
#   (a mkdir-only reset step, say) is reported as carrying no gate and is not
#   required to appear in CI. It cannot fail a build, so it cannot hide one.
#
# THE EXCUSE LIST IS THE OTHER HALF OF THE DELIVERABLE
#
#   scripts/ci-reach.conf names the workflows that count and the targets that are
#   deliberately local-only, each with a reason. It is the one place a reader can
#   see what this binding does not enforce in CI, in the same spirit as
#   KNOWN_UNCOVERED. Excuses are checked in BOTH directions: an excused target that
#   CI turns out to reach fails too, so the list cannot rot into a list of things
#   that used to be true.
#
# FOUR THINGS ARE PINNED, AND THE FIRST IS LOAD-BEARING (#pinreachclosure)
#
#   1. THE ORACLE. The closure below is awk-derived from Makefile SOURCE TEXT, so
#      it never asks make and cannot see a make CONDITIONAL. Every target in that
#      closure must therefore be proved against `make -n <root>`: each anchor of
#      the target's own recipe has to be an anchor of a command make really runs
#      for the root. Without this, the pins below are set-equal to a set that
#      describes nothing.
#
#   2. MEMBERSHIP. EXPECTED_CLOSURE_TARGETS, by SET EQUALITY in both directions,
#      plus EXPECTED_ROOT_TARGET for the root the closure is taken from. Until
#      this pin, nothing said WHICH targets belong in the closure, so removing a
#      gate from `check`'s prerequisite list was invisible — the verdict simply
#      counted one fewer and still said OK.
#
#   3. CLASSIFICATION. EXPECTED_NO_GATE_TARGETS, also by set equality. "Carrying
#      no gate" is the one verdict exempt from CI reach, so a target that keeps
#      its name and loses its recipe stays in the closure, is silently
#      reclassified, and is no longer required to be anywhere in CI.
#
#   4. THE STEP (#reversereachdirection). EXPECTED_STEP_FOR_TARGET names the CI
#      step that runs each gate and reach is checked INSIDE it, plus
#      EXPECTED_MAKE_INVOKED_TARGETS for the gates CI runs as `make <target>` and
#      which therefore get no step — both by set equality, so every gate is
#      accounted for in exactly one of them. This is the pin that closes the
#      recipe SWAP the three above could not see, and the one that found the live
#      wildcard-superset defect. Both are written up at the pin itself.
#
#   OUT OF SCOPE, said plainly, and it is now a smaller claim than it was. A
#   recipe WEAKENED INSIDE its own pinned step stays green: anchors match as
#   subsequences and extra CI-side tokens are allowed by design, so dropping a
#   flag leaves the remaining anchors present in the same step. Closing THAT needs
#   a per-target recipe anchor — a second spelling of every recipe inside this
#   guard — which is the mistake the variable note above records as having already
#   cost lazily-cpp, and whose churn would be recipe-rate rather than
#   step-name-rate. Separately, a gate in EXPECTED_MAKE_INVOKED_TARGETS has no
#   CI-side spelling at all, so nothing here cross-checks its recipe; that is
#   stated at the pin rather than papered over by mapping it to whichever step
#   happens to run make.
#
#   TWO MORE THINGS A SET PIN STRUCTURALLY CANNOT SEE. Measured here rather than
#   left implied, because an unstated limit reads as a covered case:
#
#     ORDER. A set has no order. Reordering `check:`'s prerequisite list keeps
#     every count and the exit status identical; only the order of this guard's
#     own `reached` lines changes, which gates nothing. In this binding list
#     position is not what carries the ordering anyway: `conformance-coverage:
#     test` is a real prerequisite edge, and MEASURED with `check:`'s list fully
#     REVERSED, make still ran the suite — and its manifest truncation — before
#     check-conformance-coverage.sh.
#
#     EDGES. The closure is a set of NODES, so dropping an edge BETWEEN two
#     members is invisible whenever another member already pulls the dependency
#     into the root's run. MEASURED: turning `conformance-coverage: test` into
#     `conformance-coverage:` left this guard's output BYTE-IDENTICAL to healthy
#     at exit 0. The node set is unchanged, because `test` is also a direct
#     prerequisite of `check`; the oracle stays green, because `zig build test` is
#     still among the commands make runs for the root. `make check` then keeps
#     working by list position alone while `make conformance-coverage` on its own
#     no longer runs the suite at all. What catches that is the evidence nonce
#     rather than anything here, and it fails CLOSED: given an empty manifest, or
#     none, check-conformance-coverage.sh exits 1 naming missing evidence —
#     measured both ways. Reach and dependency correctness are different
#     properties, and this guard only ever claimed the first.
set -euo pipefail

MAKE_BIN="${MAKE:-make}"
ROOT_TARGET="${CI_REACH_ROOT_TARGET:-check}"
CONF="${CI_REACH_CONF:-scripts/ci-reach.conf}"

# ------------------------------------------------------------------ closure pin
#
# The set of targets `make $ROOT_TARGET` is required to run. Everything below
# measures that closure; this is the only thing that says what it must contain.
#
# MEASURED on this tree, pre-pin: deleting `test-interop-peer` from `check`'s
# prerequisite list left the guard printing
#
#   check-ci-reach: OK — 6 target(s) reached by CI, 0 excused, 1 carrying no gate
#
# at exit 0, without naming the target that left. The gate stopped being required
# and the guard approved — the same target and the same silence as
# #lzinteroppeerci, which is the whole reason this script exists.
#
# SET EQUALITY, not a count. A floor passes a SWAP (drop one gate, add one), and a
# ceiling self-disables: it starts with no slack and gains slack with every
# legitimate migration until the original attack passes again. The property wanted
# is fails-when-stale, not passes-when-stale — the reasoning that replaced
# MAX_LEDGERED_BLOCKS with EXPECTED_LEDGERED_BLOCKS in the sibling guard.
#
# NOT env-overridable, unlike EXPECTED_LEDGERED_BLOCKS. A set this small is
# changed in a reviewable diff or not at all; an override would let the commit
# that drops a gate also drop the pin without either edit appearing in this file,
# which is the state this pin exists to make impossible.
#
# MEMBERSHIP IS NOT ENOUGH ON ITS OWN, twice over, both measured on this tree:
#
#   - A target can keep its name and lose its GATE. Replacing
#     `test-interop-peer`'s recipe with an `echo` leaves all eight names in place,
#     so set equality passes, while the target drops to "carrying no gate" — the
#     one verdict exempt from CI reach — and the guard printed
#     `OK — 6 target(s) reached by CI, 0 excused, 2 carrying no gate` at exit 0.
#     EXPECTED_NO_GATE_TARGETS below is what holds that.
#
#   - The closure this pin compares against is read out of Makefile source text
#     and cannot see a make conditional, so it can describe a branch make never
#     takes. `ifeq (0,1)` around the full `check:` line, with a shorter live
#     branch, made `make -n check` run no `interop-peer-check` while this guard's
#     output stayed BYTE-IDENTICAL to healthy — including `pinned 8 closure
#     target(s) match`. No variable, no environment, exit 0. The make-derived
#     ORACLE further down is what holds that, and it is why these pins mean
#     anything at all.
EXPECTED_ROOT_TARGET="check"

# Sorted. `check` is a member of its own closure and reports as carrying no gate.
EXPECTED_CLOSURE_TARGETS=(
	assertion-ordering-check
	check
	ci-reach
	conformance-coverage
	fmt
	test
	test-interop-peer
	test-lean-formal
)

# The targets allowed to report "carrying no gate", by set equality — the
# classification pin. Today that is only the root, which aggregates and runs
# nothing itself. The header's legitimate case (a mkdir-only reset step) would be
# listed here with the same deliberate edit, which is the point: the exemption
# from CI reach becomes a named, reviewable list instead of a side effect of
# whatever a recipe happens to contain.
#
# An EMPTY list here is not vacuous, unlike the closure pin: it is an equality
# against the discovered set, so empty asserts that NO target carries no gate.
EXPECTED_NO_GATE_TARGETS=(
	check
)

# ------------------------------------------------------------ step-mapping pin
#
# 4. THE STEP. Which CI step runs each gate, and reach checked INSIDE that step
#    instead of against the flat union of every `run:` body in the workflow
#    (#reversereachdirection).
#
# The flat union is what made the three pins above defeatable by a recipe SWAP —
# the case the header admits is out of scope: repoint a target's recipe at a
# different gate CI already runs and every count stays put, the verdict stays
# byte-identical, and the gate runs zero times. Pinning the STEP closes it
# directly. A repointed recipe's anchors are no longer in the step that target is
# pinned to, whether the new recipe names another member's gate or a step no
# member runs at all.
#
# CHURN IS STEP-NAME-RATE, NOT RECIPE-RATE, which is why this and not the obvious
# alternative. A per-recipe-content pin would have to be re-spelled every time a
# recipe gained a flag, which is the passes-when-stale shape this family already
# removed once. A recipe gaining a flag moves the recipe and the CI step TOGETHER
# and leaves this mapping untouched.
#
# IT ALSO CLOSES A LIVE DEFECT, which is the bigger finding here. Reach was
# satisfied by "some command in the flat union contains these anchors as an
# in-order subsequence", and the `Test` step's anchor ENDS IN A WILDCARD: the
# normalizer renders `-Dconformance-run-id="$LAZILY_CONFORMANCE_RUN_ID"` as a
# token that matches any one token (#lzcireachvaranchor, and it is right to). A
# trailing wildcard makes that one step a superset of every anchor that is a
# subsequence of its prefix plus one free token — which is FOUR of this repo's
# seven gates. MEASURED, pre-pin, each deletion on its own:
#
#   deleted CI step                                 verdict
#   Interop peer self-check (#lzinteroppeerci)      OK, byte-identical, exit 0
#   CI-reachability guard (#lzcheckcireachguard)    OK, byte-identical, exit 0
#   Conformance coverage guard                      OK, byte-identical, exit 0
#   Format gate (make fmt)                          OK, byte-identical, exit 0
#
# The first is the exact gate this script was written for. The second is this
# script's own CI step: the guard reported itself reached with nothing running it.
# `zig build interop-peer-check` matched `zig build` in the Test command with
# `interop-peer-check` absorbed by the trailing wildcard; the other three are
# single-token anchors (`check-ci-reach.sh`, `check-conformance-coverage.sh`,
# `check-fmt.sh`) that the wildcard swallows whole. Only `Test`, `Build the formal
# model` and `Assertion observation ordering` reddened when deleted.
#
# STEP NAMES ARE NOT GLOBALLY UNIQUE across the family (lazily-rs has 69 run:
# steps and 65 distinct names), so a pin is `target|job|step` and the (job, step)
# pair has to resolve to EXACTLY ONE run: step. Zero matches and two matches are
# both hard failures: zero is the deleted step this pin exists to catch, and two
# would let the guard silently pick one. This repo has 14 run: steps with 14
# distinct names, and the pin asserts that rather than assuming it.
#
# STRICTER THAN THE FLAT CHECK, MEASURED BEFORE COMMITTING: every one of the six
# anchor-reached gates has its FULL anchor set inside its own single step, so
# step-scoping reddened nothing legitimate on this tree. A gate whose anchors
# legitimately spread across two steps would need two entries here, and that is a
# finding to report rather than a check to loosen.
#
# STILL OPEN, said plainly: a recipe weakened INSIDE its own pinned step stays
# green. Anchors match as subsequences and extra CI-side tokens are allowed by
# design, so dropping a flag from a recipe leaves its remaining anchors present
# in the same step. Only a per-recipe-content pin would close that, and the note
# above is why this file does not carry one.
EXPECTED_STEP_FOR_TARGET=(
	"assertion-ordering-check|test|Assertion observation ordering (#lzassertordering)"
	"ci-reach|ci-reach|CI-reachability guard (#lzcheckcireachguard)"
	"conformance-coverage|test|Conformance coverage guard"
	"test|test|Test"
	"test-interop-peer|test|Interop peer self-check (#lzinteroppeerci)"
	"test-lean-formal|lean-formal|Build the formal model"
)

# The gates CI reaches by running `make <target>` rather than by spelling the
# command, by set equality against what the workflow actually does.
#
# THESE DELIBERATELY GET NO STEP PIN. A target CI invokes through make has no
# independent CI-side spelling to cross-check: the workflow's instruction is "run
# the target", so it faithfully runs whatever the recipe became and a repoint is
# undetectable from CI — correctly, because the gate is not missing from CI, the
# recipe changed. Naming the step that happens to run make would assert nothing
# about this target. lazily-gd is excluded from this design entirely for the same
# reason, its whole CI being `Install Godot` plus `make check`.
#
# What IS pinned for them is the REACH MODE, and that is not decoration. Without
# it the mode is inferred from whatever CI happens to contain, so deleting the
# `make fmt` step let `fmt` fall through to the flat anchor check and be rescued
# by the wildcard above — one of the four byte-identical deletions listed there.
# With it, a target listed here must actually be invoked through make, and a
# target that stops being is moved into EXPECTED_STEP_FOR_TARGET by hand.
#
# `fmt` is the whole list: CI's `Format gate (make fmt)` step runs `make fmt`, so
# check-fmt.sh's two-toolchain contract is spelled once, in the Makefile.
EXPECTED_MAKE_INVOKED_TARGETS=(
	fmt
)

# ------------------------------------------------------------- activation pin
#
# 5. ACTIVATION. Everything above pins what a gate's CI step RUNS. Nothing above
#    pins whether that step runs AT ALL. A pinned step can be unique, uniquely
#    named, unconditional, spell its gate exactly — and sit in a job or a
#    workflow that never executes (#verifyworkflowactually). `ci-reach.conf`
#    says listing a workflow "is a claim that it runs on every push/PR"; until
#    now that claim was a COMMENT, and it is the premise the other four pins
#    rest on.
#
# MEASURED on this tree, pre-pin, each mutation on its own, restored between
# runs, exit status read from the process and never through a pipe:
#
#   mutation                                                      verdict
#   job-level `if: false` on ci-reach                             OK, byte-identical, exit 0
#   job-level `if: false` on test                                 OK, byte-identical, exit 0
#   job-level `if: false` on fmt                                  OK, byte-identical, exit 0
#   `if: ${{ github.event_name == 'schedule' }}` on lean-formal   OK, byte-identical, exit 0
#   job-level `continue-on-error: true` on ci-reach               OK, byte-identical, exit 0
#   test's `continue-on-error` widened to plain `true`            OK, byte-identical, exit 0
#   test's `continue-on-error` retargeted at `'0.15.2'`           OK, byte-identical, exit 0
#   `on:` reduced to `workflow_dispatch`                          OK, byte-identical, exit 0
#   `branches: [main]` narrowed to `[release]`                    OK, byte-identical, exit 0
#   `paths: ['src/**']` introduced on push                        OK, byte-identical, exit 0
#   test's matrix reduced to `zig: ['master']`                    OK, byte-identical, exit 0
#   test's `master` leg renamed to `nightly`                      OK, byte-identical, exit 0
#
# Twelve states, twelve byte-identical OKs. The one activation mutation this
# file ALREADY caught is a gate step moved from `test` to `lean-formal`: the step
# pin's first field is the job, so the pin stops resolving and reports the step
# gone. That is #reversereachdirection's, not this commit's, and it is the reason
# the job field was there.
#
# EXACT VALUES, NOT ABSENCES, and this repo is the reason the whole family pins
# it that way. `test`'s job-level `continue-on-error: ${{ matrix.zig ==
# 'master' }}` is CORRECT here: 0.17.0-dev's internal test-runner protocol
# deadlocks, the advisory master leg is documented at the top of this workflow,
# and both pinned releases gate. A rule reading "no job-level
# continue-on-error" would red a healthy config, and a guard that reds on a
# correct tree gets its rule deleted rather than its mutation. So the value is
# pinned as a LITERAL in both directions: absent -> present, present -> absent,
# and present -> a different expression are each named.

# The exact top-level `on:` keys of every workflow `ci-reach.conf` counts,
# comma-joined and sorted. Only the counted workflows: a workflow nothing here
# claims reach for has nothing to pin.
EXPECTED_TRIGGERS=(
	".github/workflows/ci.yml|pull_request,push,workflow_dispatch"
)

# The exact filters under each trigger: every sub-key of that trigger as
# `key=v1,v2`, sorted by key and joined with `;`. An empty field means the
# trigger carries no filters at all.
#
# THE COMPARISON IS AGAINST THE WHOLE STRING, so a sub-key this file never
# anticipated — `paths-ignore:`, `branches-ignore:`, `tags:`, `types:` — is
# named the same way instead of falling outside the pin. That matters more than
# the keys it does anticipate: an absence rule has to enumerate what may not
# appear, and the next filter invented is the one it does not list.
#
# NO BINDING IN THIS FAMILY HAS A `paths:` FILTER TODAY, so this half is
# fails-when-INTRODUCED rather than fails-when-stale, and it is not
# hypothetical. A `paths:` filter that does not list `Makefile` means the very
# edit that retires a gate — deleting it from `check:` — does not trigger the
# workflow that would have caught it. The guard would be green because it never
# ran.
EXPECTED_TRIGGER_FILTERS=(
	".github/workflows/ci.yml|pull_request|"
	".github/workflows/ci.yml|push|branches=main"
	".github/workflows/ci.yml|workflow_dispatch|"
)

# The jobs that carry reach for a gate, by SET EQUALITY against the jobs the
# pins above actually resolved to: the job field of every EXPECTED_STEP_FOR_TARGET
# entry that resolved to exactly one step, plus the job of every step CI invokes
# an EXPECTED_MAKE_INVOKED_TARGETS gate from.
#
# `fmt` is in this list for the second reason, and it is why the list is not
# redundant with the step pins' job fields. A make-invoked gate deliberately
# gets no step pin, so before this NOTHING in this file named the job its
# `make fmt` step lives in: `if: false` on the `fmt` job removed the formatting
# gate for all three pinned toolchains without changing one character of any pin
# above. The step pin's job field covers the other three jobs for free; this
# list is what covers the one it cannot.
EXPECTED_GATE_JOBS=(
	ci-reach
	fmt
	lean-formal
	test
)

# Per gate job, the EXACT job-level activation keys, as
# `continue-on-error=<v>;if=<v>;needs=<v>`. Empty means the key is ABSENT, which
# is the normal case here and is asserted rather than assumed — the whole point
# of pinning values instead of forbidding them.
#
# `needs:` is in the serialization for the same reason `paths:` is in the
# trigger filters: no gate job here has one, and a gate job made to depend on a
# job that can be skipped never runs, with `if:` and `continue-on-error:` both
# still absent. Fails-when-introduced.
EXPECTED_JOB_ACTIVATION=(
	"ci-reach|continue-on-error=;if=;needs="
	"fmt|continue-on-error=;if=;needs="
	"lean-formal|continue-on-error=;if=;needs="
	"test|continue-on-error=\${{ matrix.zig == 'master' }};if=;needs="
)

# Per gate job, the exact matrix axes and legs, as `axis=leg,leg` sorted by axis
# and joined with `;`. Empty means the job has no matrix, which the three
# single-run jobs assert rather than merely happen to have.
#
# THIS IS THE OTHER HALF OF `test`'s ACTIVATION PIN, not decoration, and the
# question it answers is which legs are BLOCKING.
# `continue-on-error: ${{ matrix.zig == 'master' }}` is keyed on a matrix VALUE,
# so the expression is meaningless without the set of values it is evaluated
# over:
#
#   - Reduce the matrix to `zig: ['master']`. The continue-on-error expression
#     is UNCHANGED, so EXPECTED_JOB_ACTIVATION is satisfied, and every leg of
#     the job is now advisory. That is this commit's own defect one level down —
#     the job still runs, still reports, and enforces nothing. MEASURED
#     byte-identical pre-pin. The leg set is the only thing here that catches
#     it; the activation pin cannot, and does not claim to.
#   - Rename the `master` leg to `nightly`, or retarget the expression at
#     `'0.15.2'`, and a BLOCKING toolchain becomes advisory with no other trace.
#     The retarget is caught by EXPECTED_JOB_ACTIVATION (the expression
#     changed); the rename by this pin (the leg set changed). Each is invisible
#     to the other pin.
#
# So neither subsumes the other and both are required: an advisory predicate is
# only meaningful against a known leg set, and a leg set only meaningful against
# a known predicate. "Which legs gate" is a fact about the PAIR, and pinning one
# half of a pair is the passes-when-stale shape this family has already removed
# twice.
#
# STILL OPEN, said plainly rather than implied: this pin does not read
# GitHub's branch protection, so it cannot see a required-checks list that never
# named `Zig 0.15.2` in the first place. A blocking leg here is blocking for the
# workflow's own conclusion; whether a red workflow blocks a MERGE is a
# repository setting no file in this tree can observe. The same limit applies to
# EXPECTED_TRIGGERS: it proves the workflow is triggered, not that anything
# refuses a merge when it fails.
EXPECTED_JOB_MATRIX=(
	"ci-reach|"
	"fmt|"
	"lean-formal|"
	"test|zig=0.15.2,0.16.0,master"
)

# Pin lookups. `|` is the field separator, so a step name containing one is
# refused further down rather than silently splitting.
pinned_step_for() {
	local t="$1" e
	for e in ${EXPECTED_STEP_FOR_TARGET[@]+"${EXPECTED_STEP_FOR_TARGET[@]}"}; do
		case "$e" in
		"$t|"*)
			printf '%s' "${e#*|}"
			return 0
			;;
		esac
	done
	return 1
}

is_make_invoked_pinned() {
	local t="$1" e
	for e in ${EXPECTED_MAKE_INVOKED_TARGETS[@]+"${EXPECTED_MAKE_INVOKED_TARGETS[@]}"}; do
		if [ "$e" = "$t" ]; then
			return 0
		fi
	done
	return 1
}

if [ "${#EXPECTED_CLOSURE_TARGETS[@]}" -eq 0 ]; then
	echo "check-ci-reach: EXPECTED_CLOSURE_TARGETS is empty — an empty pin is set-equal to an" >&2
	echo "                empty closure, so it would approve a \`$ROOT_TARGET\` with no gates at all." >&2
	exit 1
fi

if [ ! -f Makefile ]; then
	echo "check-ci-reach: no Makefile in $(pwd)" >&2
	exit 1
fi

# ---------------------------------------------------------------- configuration

workflows=()
workflow_count=0
excused_targets=()
excused_reasons=()
excuse_count=0

if [ -f "$CONF" ]; then
	while IFS= read -r line || [ -n "$line" ]; do
		line="${line%%$'\r'}"
		case "$line" in
		'#'* | '') continue ;;
		esac
		key="${line%%:*}"
		val="${line#*:}"
		val="$(printf '%s' "$val" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
		case "$key" in
		workflow)
			workflows+=("$val")
			workflow_count=$((workflow_count + 1))
			;;
		excuse)
			tgt="${val%%[[:space:]]*}"
			reason="${val#"$tgt"}"
			reason="$(printf '%s' "$reason" | sed -e 's/^[[:space:]]*//')"
			if [ -z "$reason" ]; then
				echo "check-ci-reach: excuse for '$tgt' has no reason — an excuse without a reason is not an excuse" >&2
				exit 1
			fi
			excused_targets+=("$tgt")
			excused_reasons+=("$reason")
			excuse_count=$((excuse_count + 1))
			;;
		*)
			echo "check-ci-reach: unknown key '$key' in $CONF" >&2
			exit 1
			;;
		esac
	done <"$CONF"
fi

if [ "$workflow_count" -eq 0 ]; then
	workflows=(".github/workflows/ci.yml")
	workflow_count=1
fi

for wf in "${workflows[@]}"; do
	if [ ! -f "$wf" ]; then
		echo "check-ci-reach: workflow '$wf' listed in $CONF does not exist" >&2
		exit 1
	fi
done

# ------------------------------------------------------- make target extraction

# A Makefile may set .RECIPEPREFIX to something other than tab (lazily-rs uses
# `>`), which puts recipe lines at column 0 where a rule line lives. Without this
# a recipe such as `>cargo test --features a:b` reads as a rule named `>cargo`.
RECIPE_PREFIX="$(awk -F= '/^[[:space:]]*\.RECIPEPREFIX[[:space:]]*[:+]?=/ {
	v = $2; gsub(/^[[:space:]]+|[[:space:]]+$/, "", v); if (v != "") print substr(v, 1, 1); exit
}' Makefile)"

# Prerequisites of a target, straight from the Makefile source, with `\`
# continuations joined and trailing comments removed. Order-only prerequisites are
# dropped: they constrain ordering, not what runs.
prereqs_of() {
	awk -v target="$1" -v rp="$RECIPE_PREFIX" '
		BEGIN { pat = "^" target ":([^=]|$)"; if (rp == "") rp = "\t" }
		{
			line = $0
			# Only the ACTUAL recipe prefix marks a recipe line. Treating any
			# leading whitespace as one loses a rule that is merely indented,
			# which under a non-tab .RECIPEPREFIX is perfectly legal make and
			# collapses the whole closure to a single target. A continuation is
			# exempt: under the default tab prefix a wrapped prerequisite list is
			# normally tab-indented.
			if (!cont && substr(line, 1, 1) == rp) next
			sub(/^[[:space:]]+/, "", line)
			if (cont) {
				buf = buf " " line
				if (line ~ /\\[[:space:]]*$/) next
				cont = 0
				emit(buf)
				exit
			}
			if (line !~ pat) next
			buf = line
			if (line ~ /\\[[:space:]]*$/) { cont = 1; next }
			emit(buf)
			exit
		}
		function emit(s,   rest, n, i, parts) {
			gsub(/\\/, " ", s)
			sub(/#.*$/, "", s)
			rest = substr(s, index(s, ":") + 1)
			sub(/\|.*$/, "", rest)
			n = split(rest, parts, /[[:space:]]+/)
			for (i = 1; i <= n; i++) if (parts[i] != "") print parts[i]
		}
	' Makefile
}

# Is this name an explicit rule in the Makefile?
is_makefile_target() {
	awk -v target="$1" -v rp="$RECIPE_PREFIX" '
		BEGIN { pat = "^" target ":([^=]|$)"; if (rp == "") rp = "\t"; found = 0 }
		substr($0, 1, 1) == rp { next }
		{ line = $0; sub(/^[[:space:]]+/, "", line) }
		line ~ pat { found = 1; exit }
		END { exit found ? 0 : 1 }
	' Makefile
}

# Breadth-first closure of ROOT_TARGET's prerequisites, parents before children.
closure=""
queue="$ROOT_TARGET"
seen=" "
while [ -n "$queue" ]; do
	current="${queue%%$'\n'*}"
	if [ "$current" = "$queue" ]; then queue=""; else queue="${queue#*$'\n'}"; fi
	[ -n "$current" ] || continue
	case "$seen" in
	*" $current "*) continue ;;
	esac
	seen="$seen$current "
	closure="$closure$current"$'\n'
	while IFS= read -r dep; do
		[ -n "$dep" ] || continue
		if is_makefile_target "$dep"; then
			queue="$queue$dep"$'\n'
		fi
	done < <(prereqs_of "$current")
done

# ------------------------------------------------------- pinning that closure

# The root first: renaming it does not shrink the closure, it EMPTIES it, and an
# empty closure is a different failure to diagnose than a missing prerequisite.
if [ "$ROOT_TARGET" != "$EXPECTED_ROOT_TARGET" ]; then
	echo "check-ci-reach: the closure was taken from '$ROOT_TARGET', but EXPECTED_ROOT_TARGET pins" >&2
	echo "                it at '$EXPECTED_ROOT_TARGET'. Restore the root target's name, or update" >&2
	echo "                EXPECTED_ROOT_TARGET and EXPECTED_CLOSURE_TARGETS together." >&2
	exit 1
fi

# `seen` is the closure as a space-delimited membership string, built above.
pinned_set=" "
for _t in "${EXPECTED_CLOSURE_TARGETS[@]}"; do
	pinned_set="$pinned_set$_t "
done

pin_missing=""
pin_missing_count=0
pin_extra=""
pin_extra_count=0

# Pinned but absent from the closure: a gate left the root's prerequisites.
for _t in "${EXPECTED_CLOSURE_TARGETS[@]}"; do
	case "$seen" in
	*" $_t "*) continue ;;
	esac
	pin_missing="$pin_missing$_t"$'\n'
	pin_missing_count=$((pin_missing_count + 1))
done

# In the closure but not pinned: a target was added without being pinned.
while IFS= read -r _t; do
	[ -n "$_t" ] || continue
	case "$pinned_set" in
	*" $_t "*) continue ;;
	esac
	pin_extra="$pin_extra$_t"$'\n'
	pin_extra_count=$((pin_extra_count + 1))
done <<<"$closure"

if [ "$pin_missing_count" -gt 0 ] || [ "$pin_extra_count" -gt 0 ]; then
	echo "check-ci-reach: \`$MAKE_BIN $ROOT_TARGET\`'s target closure is not the pinned set." >&2
	if [ "$pin_missing_count" -gt 0 ]; then
		echo >&2
		echo "  $pin_missing_count pinned target(s) that \`$ROOT_TARGET\` no longer runs:" >&2
		while IFS= read -r _t; do
			[ -n "$_t" ] || continue
			echo "    - $_t" >&2
		done <<<"$pin_missing"
	fi
	if [ "$pin_extra_count" -gt 0 ]; then
		echo >&2
		echo "  $pin_extra_count target(s) in the closure that nothing pins:" >&2
		while IFS= read -r _t; do
			[ -n "$_t" ] || continue
			echo "    - $_t" >&2
		done <<<"$pin_extra"
	fi
	echo >&2
	echo "  These are TWO DIFFERENT EDITS, and the pin cannot tell which one you meant:" >&2
	echo "    - a gate was dropped or renamed  -> restore the prerequisite in the Makefile." >&2
	echo "      This is the case the pin exists for: before it, the verdict just counted one" >&2
	echo "      fewer target and still said OK." >&2
	echo "    - the closure really changed      -> update EXPECTED_CLOSURE_TARGETS in this" >&2
	echo "      script, keeping it sorted, in the same commit as the Makefile change." >&2
	echo "  Editing the pin to silence this is only right in the second case." >&2
	exit 1
fi

# An excuse for a target the root does not run is not an excuse for anything.
# Pre-pin it was a silent no-op: an `excuse:` naming a target this Makefile has
# never had printed the healthy verdict byte for byte, `0 excused`, at exit 0 —
# MEASURED. The sibling guard already checks this direction for KNOWN_UNCOVERED
# ("lists 'X', which is not in the canonical corpus"); the excuse list is the same
# kind of ledger and rots the same way, which is exactly what the conf file claims
# it cannot do.
excuse_outside=0
for _i in "${!excused_targets[@]}"; do
	_t="${excused_targets[$_i]}"
	case "$seen" in
	*" $_t "*) continue ;;
	esac
	echo "check-ci-reach: $CONF excuses '$_t', which \`$MAKE_BIN $ROOT_TARGET\` does not run." >&2
	excuse_outside=$((excuse_outside + 1))
done
if [ "$excuse_outside" -gt 0 ]; then
	echo >&2
	echo "  An excuse for a target outside the closure exempts nothing, while reading as" >&2
	echo "  coverage somebody considered. Remove the excuse, or restore the target to" >&2
	echo "  \`$ROOT_TARGET\`'s prerequisites if it is meant to run." >&2
	exit 1
fi

printf 'pinned   %s closure target(s) match EXPECTED_CLOSURE_TARGETS, root `%s`\n' \
	"${#EXPECTED_CLOSURE_TARGETS[@]}" "$ROOT_TARGET"

# `make -n` for a target emits its prerequisites' commands first, then its own.
# Asking make for the prerequisite list alone yields exactly that prefix — make
# applies the same de-duplication to both invocations — so removing it leaves the
# target's own recipe. Diagnostics make writes about targets it has nothing to do
# for are not commands and are dropped.
# A recipe line broken across physical lines with `\` reaches the shell as ONE
# command, and make -n prints it the way the Makefile spells it. Joining here is
# what keeps `VAR=x \` + `go test ./...` from being read as two commands, the
# second of which is where the whole gate lives.
join_continuations() {
	awk '
		{
			line = $0
			if (line ~ /\\[[:space:]]*$/) {
				sub(/\\[[:space:]]*$/, "", line)
				buf = buf line " "
				next
			}
			print buf line
			buf = ""
		}
		END { if (buf != "") print buf }
	'
}

dry_run() {
	"$MAKE_BIN" -n "$@" 2>/dev/null | grep -v -e '^make\[' -e '^make:' | join_continuations || true
}

own_commands() {
	local target="$1"
	local deps=()
	local dep_count=0
	while IFS= read -r dep; do
		[ -n "$dep" ] || continue
		if is_makefile_target "$dep"; then
			deps+=("$dep")
			dep_count=$((dep_count + 1))
		fi
	done < <(prereqs_of "$target")

	if [ "$dep_count" -eq 0 ]; then
		dry_run "$target"
		return
	fi
	local prefix
	prefix="$(dry_run "${deps[@]}" | wc -l)"
	dry_run "$target" | tail -n +"$((prefix + 1))"
}

# ------------------------------------------------------------- workflow scraping

# Command lines from every `run:` step, each ATTRIBUTED to the workflow, job and
# step name it came from. Comment lines inside a run body are stripped here — the
# whole reason this guard is a script.
#
# ONE parser for both the flat union and the per-step view (#reversereachdirection).
# Scraping the workflow twice, once per view, would give the step mapping a second
# reader that can drift from the one the flat check uses — and the two disagreeing
# is exactly a gate that reads as reached by one and unpinned by the other.
#
# Output is `workflow<TAB>job<TAB>ordinal<TAB>step<TAB>command`. Job, ordinal and
# step reset per FILE, because a step name is unique at most within one workflow.
#
# THE ORDINAL IS WHAT MAKES A DUPLICATE VISIBLE. Keyed on (job, step) alone, two
# steps sharing a name COLLAPSE into one entry and their commands union — which
# is the flat union again, in miniature, and the duplicate the pin is supposed to
# refuse instead reads as a single step that runs both. MEASURED: renaming
# `Conformance coverage guard` to `Test` was reported only as the first step
# missing, with `test`s own pin silently matching the merged pair.
ci_step_commands() {
	awk '
		function flush() { if (buf != "") { emit(buf); buf = "" } }
		function emit(c) { print curfile "\t" job "\t" stepno "\t" step "\t" c }
		# flush() first, so a command still buffered at EOF is attributed to the
		# file it came from rather than to the one just opened.
		FNR == 1 { flush(); job = ""; step = ""; stepno = 0; inblock = 0; injobs = 0; curfile = FILENAME }
		{
			line = $0
			indent = match(line, /[^ ]/) - 1
			if (indent < 0) indent = 9999

			if (inblock) {
				if (line ~ /^[[:space:]]*$/) next
				if (indent <= block_indent) { flush(); inblock = 0 }
				else {
					sub(/^[[:space:]]+/, "", line)
					if (substr(line, 1, 1) == "#") next
					if (line ~ /\\[[:space:]]*$/) {
						sub(/\\[[:space:]]*$/, "", line)
						buf = buf " " line
						next
					}
					if (buf != "") { emit(buf " " line); buf = "" } else emit(line)
					next
				}
			}

			# Job IDs are the two-space mapping keys UNDER `jobs:`. Gated on that
			# rather than on indentation alone: `on:`s `push:` and
			# `workflow_dispatch:` sit at the same column and are not jobs.
			if (line ~ /^jobs:[[:space:]]*$/) { injobs = 1; job = ""; step = "" }
			else if (injobs && line ~ /^  [A-Za-z0-9_.-]+:[[:space:]]*$/) {
				j = line
				sub(/^  /, "", j)
				sub(/:[[:space:]]*$/, "", j)
				job = j
				step = ""
			}
			# EVERY list item starts a new step and CLEARS the name, so a step
			# with no `name:` reports as unnamed and is refused. Without the
			# clear it inherited the PREVIOUS step`s name, which is worse than
			# no name: the command was attributed to a step that did not run it,
			# and MEASURED — replacing the interop step with a bare `- run:`
			# credited it to `Mint conformance evidence nonce` and the guard
			# reported the pinned step missing instead of the step unnamed.
			# A stray item (`- main` under `on:`) only burns an ordinal, which
			# is an identity token and not a count.
			if (line ~ /^[[:space:]]*-[[:space:]]/) {
				stepno++
				step = ""
			}
			# The step name is the only `- name:`. A bare `name:` inside a job is
			# the job DISPLAY name — `Zig ${{ matrix.zig }}` here, which names
			# three jobs rather than one — so the mapping keys on the job ID.
			if (line ~ /^[[:space:]]*-[[:space:]]+name:[[:space:]]*/) {
				s = line
				sub(/^[[:space:]]*-[[:space:]]+name:[[:space:]]*/, "", s)
				sub(/[[:space:]]+$/, "", s)
				step = s
			}

			if (line ~ /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*[|>][-+]?[[:space:]]*$/) {
				inblock = 1
				block_indent = indent
				buf = ""
				next
			}
			if (line ~ /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*[^|>[:space:]]/) {
				sub(/^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*/, "", line)
				emit(line)
			}
		}
		END { flush() }
	' "$@"
}

# The flat union the reach check has always used, unchanged: the same lines, with
# the attribution dropped.
ci_commands() { ci_step_commands "$@" | cut -f5-; }

# --------------------------------------------------------- activation scraping
#
# The workflow's `on:` block and each job's activation keys
# (#verifyworkflowactually). Separate readers from ci_step_commands, on purpose:
# that parser deliberately only looks inside `run:` bodies, and these are the
# keys that decide whether a `run:` body runs at all. Folding them in would mean
# one parser with two incompatible notions of what a line is.
#
# Both emit raw TAB rows and are assembled into one canonical string per subject
# in the shell, so each comparison site does string equality against a pin
# rather than re-implementing the shape rules.
#
# ANYTHING THE SHAPE RULES DO NOT COVER IS REFUSED, never skipped. A parser that
# reads nothing out of a shape it did not expect hands its pin an empty value,
# and an empty value compared against an "absent" pin PASSES — the vacuity every
# other refusal in this file exists to stop, with the added insult that the
# vacuous pass looks like a healthy one. So flow-style `on: [push]`, a nested map
# where a filter list belongs, a matrix `include:`/`exclude:` entry, and an
# `if:`/`needs:`/`continue-on-error:` whose value is not a scalar or a flow list
# each emit a sentinel row the shell turns into a hard failure naming the line.
#
# THE INDENTATION CONTRACT IS TWO SPACES PER LEVEL, which is what this workflow
# uses and what the sentinel rows enforce for the lines they cover. It is NOT
# enforced for a line inside a `run:` body, which can be indented any way at
# all — a body line at column 0 would end the `jobs:` block for the reader below
# and silently hide every job after it. That is why the job set this reader
# discovers is cross-checked against the job set ci_step_commands discovers,
# further down: a job with `run:` steps and no activation row is a hard failure,
# not a job with no activation.
wf_triggers() {
	awk '
		function flushsub() {
			if (sk != "") { printf "%s\t%s\t%s=%s\n", curfile, trig, sk, vals; sk = ""; vals = "" }
		}
		function flowlist(v,   n, a, i, out) {
			gsub(/^\[[[:space:]]*|[[:space:]]*\]$/, "", v)
			if (v == "") return ""
			n = split(v, a, /[[:space:]]*,[[:space:]]*/)
			out = ""
			for (i = 1; i <= n; i++) {
				gsub(/^['\''"]|['\''"]$/, "", a[i])
				out = out (out == "" ? "" : ",") a[i]
			}
			return out
		}
		FNR == 1 { flushsub(); curfile = FILENAME; inon = 0; trig = "" }
		{
			line = $0
			sub(/[[:space:]]+$/, "", line)
			if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) next
			indent = match(line, /[^ ]/) - 1

			if (line ~ /^on:[[:space:]]*$/) { flushsub(); inon = 1; trig = ""; next }
			# Flow-style or inline `on:` is refused rather than parsed: the pin
			# would otherwise compare against whatever this reader failed to read.
			if (line ~ /^on:/) { printf "%s\t!SHAPE\t%s\n", curfile, line; inon = 0; next }
			if (indent == 0) { flushsub(); inon = 0; trig = ""; next }
			if (!inon) next

			if (indent == 2) {
				flushsub()
				if (line !~ /^  [A-Za-z0-9_.-]+:[[:space:]]*$/) { printf "%s\t!SHAPE\t%s\n", curfile, line; next }
				trig = line; sub(/^  /, "", trig); sub(/:[[:space:]]*$/, "", trig)
				# Presence row: a trigger with no filters at all still has to
				# appear in EXPECTED_TRIGGERS.
				printf "%s\t%s\t\n", curfile, trig
				next
			}
			if (trig == "") { printf "%s\t!SHAPE\t%s\n", curfile, line; next }

			if (indent == 4) {
				flushsub()
				if (line !~ /^    [A-Za-z0-9_.-]+:/) { printf "%s\t!SHAPE\t%s\n", curfile, line; next }
				k = line; sub(/^    /, "", k); sub(/:.*$/, "", k)
				v = line; sub(/^    [A-Za-z0-9_.-]+:[[:space:]]*/, "", v)
				if (v == "") { sk = k; vals = ""; next }
				if (v ~ /^\[.*\]$/) { printf "%s\t%s\t%s=%s\n", curfile, trig, k, flowlist(v); next }
				gsub(/^['\''"]|['\''"]$/, "", v)
				printf "%s\t%s\t%s=%s\n", curfile, trig, k, v
				next
			}

			if (indent == 6 && line ~ /^      -[[:space:]]/) {
				if (sk == "") { printf "%s\t!SHAPE\t%s\n", curfile, line; next }
				v = line; sub(/^      -[[:space:]]*/, "", v)
				# A `- key: value` item here is a map, not a filter string.
				if (v ~ /:[[:space:]]/) { printf "%s\t!SHAPE\t%s\n", curfile, line; next }
				gsub(/^['\''"]|['\''"]$/, "", v)
				vals = vals (vals == "" ? "" : ",") v
				next
			}

			printf "%s\t!SHAPE\t%s\n", curfile, line
		}
		END { flushsub() }
	' "$@"
}

# Rows are `workflow<TAB>job<TAB>key<TAB>value`, where key is `PRESENT` for the
# job itself, one of the three activation keys, or `matrix`.
wf_job_activation() {
	awk '
		function flushaxis() {
			if (axis != "") { printf "%s\t%s\tmatrix\t%s=%s\n", curfile, job, axis, vals; axis = ""; vals = "" }
		}
		function bad(l) { printf "%s\t!SHAPE\t\t%s\n", curfile, l }
		function flowlist(v,   n, a, i, out) {
			gsub(/^\[[[:space:]]*|[[:space:]]*\]$/, "", v)
			if (v == "") return ""
			n = split(v, a, /[[:space:]]*,[[:space:]]*/)
			out = ""
			for (i = 1; i <= n; i++) {
				gsub(/^['\''"]|['\''"]$/, "", a[i])
				out = out (out == "" ? "" : ",") a[i]
			}
			return out
		}
		FNR == 1 { flushaxis(); curfile = FILENAME; injobs = 0; job = ""; mode = ""; sub2 = "" }
		{
			line = $0
			sub(/[[:space:]]+$/, "", line)
			if (line ~ /^[[:space:]]*#/ || line ~ /^[[:space:]]*$/) next
			indent = match(line, /[^ ]/) - 1

			if (line ~ /^jobs:[[:space:]]*$/) { flushaxis(); injobs = 1; job = ""; mode = ""; sub2 = ""; next }
			if (indent == 0) { flushaxis(); injobs = 0; job = ""; mode = ""; sub2 = ""; next }
			if (!injobs) next

			if (indent == 2) {
				flushaxis()
				if (line !~ /^  [A-Za-z0-9_.-]+:[[:space:]]*$/) { bad(line); next }
				job = line; sub(/^  /, "", job); sub(/:[[:space:]]*$/, "", job)
				mode = ""; sub2 = ""
				printf "%s\t%s\tPRESENT\t\n", curfile, job
				next
			}
			if (job == "") { bad(line); next }

			if (indent == 4) {
				flushaxis()
				sub2 = ""
				if (line !~ /^    [A-Za-z0-9_.-]+:/) { bad(line); next }
				k = line; sub(/^    /, "", k); sub(/:.*$/, "", k)
				mode = (k == "strategy") ? "strategy" : "other"
				if (k == "if" || k == "continue-on-error" || k == "needs") {
					v = line; sub(/^    [A-Za-z0-9_.-]+:[[:space:]]*/, "", v)
					# An empty value means a block list or map follows, and this
					# reader would report the key ABSENT — which is exactly the
					# pinned value for all three keys here, so it would pass.
					if (v == "") { bad(line); next }
					if (v ~ /^\[.*\]$/) { printf "%s\t%s\t%s\t%s\n", curfile, job, k, flowlist(v); next }
					printf "%s\t%s\t%s\t%s\n", curfile, job, k, v
				}
				next
			}

			# Only `strategy:` has a sub-tree this reader looks into. Everything
			# under `steps:` and under any other job key is skipped here and read
			# by ci_step_commands instead.
			if (mode != "strategy") next

			if (indent == 6) {
				flushaxis()
				if (line !~ /^      [A-Za-z0-9_.-]+:/) { bad(line); next }
				k = line; sub(/^      /, "", k); sub(/:.*$/, "", k)
				sub2 = (k == "matrix") ? "matrix" : ""
				next
			}
			if (sub2 != "matrix") next

			if (indent == 8) {
				flushaxis()
				if (line !~ /^        [A-Za-z0-9_.-]+:/) { bad(line); next }
				k = line; sub(/^        /, "", k); sub(/:.*$/, "", k)
				# `include:`/`exclude:` add and remove whole legs, so a matrix
				# carrying one is not described by its axes alone.
				if (k == "include" || k == "exclude") { bad(line); next }
				v = line; sub(/^        [A-Za-z0-9_.-]+:[[:space:]]*/, "", v)
				if (v == "") { axis = k; vals = ""; next }
				if (v ~ /^\[.*\]$/) { printf "%s\t%s\tmatrix\t%s=%s\n", curfile, job, k, flowlist(v); next }
				bad(line); next
			}
			if (indent == 10 && line ~ /^          -[[:space:]]/) {
				if (axis == "") { bad(line); next }
				v = line; sub(/^          -[[:space:]]*/, "", v)
				if (v ~ /:[[:space:]]/) { bad(line); next }
				gsub(/^['\''"]|['\''"]$/, "", v)
				vals = vals (vals == "" ? "" : ",") v
				next
			}

			bad(line)
		}
		END { flushaxis() }
	' "$@"
}

# ------------------------------------------------------------------- normalizing

# Reduce command text to anchors, one per line, each a space-separated token list.
anchors() {
	awk '
		BEGIN {
			# Sentinel for an unresolvable variable reference. Deliberately not a
			# string any real argument can be.
			ANY = "\001any"
			split(": true false echo printf cd pushd popd mkdir rmdir rm cp mv ln touch " \
			      "export unset set local read eval exec trap wait sleep exit return " \
			      "if then else elif fi for while until do done case esac function " \
			      "test [ [[ pwd ls cat head tail sed awk grep egrep fgrep sort uniq " \
			      "wc tr cut paste tee xargs env dirname basename date git", t, / /)
			for (i in t) if (t[i] != "") trivial[t[i]] = 1
		}
		{
			n = split(split_unquoted($0), cmds, /\n/)
			for (i = 1; i <= n; i++) emit(cmds[i])
		}
		# Split on the shell'"'"'s sequencing operators, but ONLY outside quotes. Doing
		# this before quotes are stripped is what stops a `;` inside a message —
		# `echo "missing $(DIR); clone the sibling"` — from being read as a second
		# command and inventing an anchor for a gate that does not exist. That is a
		# false RED, so it costs a real target its verdict.
		function split_unquoted(s,   i, c, nxt, len, inq, q, out) {
			out = ""; inq = 0; q = ""; len = length(s)
			for (i = 1; i <= len; i++) {
				c = substr(s, i, 1)
				if (inq) {
					if (c == q) { inq = 0; q = "" }
					out = out c
					continue
				}
				if (c == "\"" || c == "'"'"'" || c == "`") { inq = 1; q = c; out = out c; continue }
				nxt = substr(s, i + 1, 1)
				if (c == ";") { out = out "\n"; continue }
				if ((c == "&" && nxt == "&") || (c == "|" && nxt == "|")) { out = out "\n"; i++; continue }
				if (c == "|") { out = out "\n"; continue }
				out = out c
			}
			return out
		}
		function emit(cmd,   m, j, tok, out, prog, started, parts) {
			gsub(/[`"'"'"']/, " ", cmd)
			gsub(/\$\(/, " ", cmd)
			gsub(/\$\{/, " ", cmd)
			gsub(/[(){}]/, " ", cmd)
			m = split(cmd, parts, /[[:space:]]+/)
			prog = ""
			out = ""
			started = 0
			for (j = 1; j <= m; j++) {
				tok = parts[j]
				if (tok == "" || tok == "\\") continue
				if (tok ~ /^[0-9]*>>?$/ || tok == "<" || tok ~ /^[0-9]+>&[0-9]+$/) break
				if (!started) {
					if (tok ~ /^[A-Za-z_][A-Za-z0-9_]*=/) continue
					started = 1
					prog = tok
					sub(/.*\//, "", prog)
					if (prog == "" || (prog in trivial)) return
					out = prog
					continue
				}
				if (tok ~ /^-/) {
					sub(/=.*$/, "", tok)
					out = out " " tok
					continue
				}
				if (tok ~ /^\.{1,3}$/ || tok ~ /^\.{1,2}\/\.{0,3}$/) continue
				if (tok ~ /\//) {
					sub(/\/+$/, "", tok)
					sub(/.*\//, "", tok)
					if (tok == "" || tok ~ /^\.{1,3}$/) continue
				}
					# A token that is still a shell/make VARIABLE reference names a
					# value this guard cannot resolve — a CI step spelling a path as
					# "$LAZILY_CONFORMANCE_MANIFEST" and a Makefile recipe spelling the
					# same path through an expanded $(VAR) are the same command. Dropping
					# it (what this used to do) loses the ARGUMENT as well as its value,
					# so `script.sh <path>` no longer matched a CI step that really ran
					# `script.sh "$PATH"` and the target was reported unreachable. That is
					# a false RED, and it cost lazily-cpp a hardcoded second spelling of
					# the path plus a hand-written equality assertion to keep the two in
					# sync — a new drift surface invented to satisfy a guard that exists
					# to detect drift.
					#
					# Emit a WILDCARD instead: one token that matches one token, so arity
					# is preserved. `script.sh $A` still fails against a CI step that
					# passes no argument at all. This is the same looseness the normalizer
					# already applies to paths, which it reduces to basenames — reach is a
					# floor, not equivalence, exactly as the header says.
					if (substr(tok, 1, 1) == "$") { out = out " " ANY; continue }
				out = out " " tok
			}
			if (started && out != "") print out
		}
	'
}

# --------------------------------------------------------------------- matching

ci_raw="$(mktemp)"
ci_anchor="$(mktemp)"
root_anchor="$(mktemp)"
ci_steps="$(mktemp)"
step_index="$(mktemp)"
step_dir="$(mktemp -d)"
wf_trig="$(mktemp)"
wf_act="$(mktemp)"
trap 'rm -rf "$ci_raw" "$ci_anchor" "$root_anchor" "$ci_steps" "$step_index" "$step_dir" "$wf_trig" "$wf_act"' EXIT
ci_commands "${workflows[@]}" >"$ci_raw"
anchors <"$ci_raw" | sort -u >"$ci_anchor"

# The ORACLE's haystack: what make REALLY runs for the root, asked of make rather
# than read out of the Makefile. make's status is asserted here because dry_run's
# `|| true` would swallow it, and an empty haystack would make the oracle approve
# every target in the closure — the same vacuity rule as everything else here.
# `make -n` only; `make -p` would dump the environment into the CI log.
if ! "$MAKE_BIN" -n "$ROOT_TARGET" >/dev/null 2>&1; then
	echo "check-ci-reach: \`$MAKE_BIN -n $ROOT_TARGET\` failed, so the commands make really runs for" >&2
	echo "                '$ROOT_TARGET' could not be read, and the closure below cannot be checked" >&2
	echo "                against them." >&2
	exit 1
fi
dry_run "$ROOT_TARGET" | anchors | sort -u >"$root_anchor"
if [ ! -s "$root_anchor" ]; then
	echo "check-ci-reach: \`$MAKE_BIN -n $ROOT_TARGET\` runs no checkable command at all — an oracle" >&2
	echo "                with an empty haystack approves every target in the closure" >&2
	exit 1
fi

if [ ! -s "$ci_anchor" ]; then
	echo "check-ci-reach: no run: steps found in ${workflows[*]} — a guard with an empty haystack passes everything" >&2
	exit 1
fi

# ------------------------------------------------------ per-step CI anchors
#
# The same scrape, kept per (job, step) instead of unioned, so reach can be asked
# INSIDE the step a gate is pinned to (#reversereachdirection).
ci_step_commands "${workflows[@]}" >"$ci_steps"

# A run: step with no `name:` cannot be pinned, so it is a step a gate can hide
# in. Adding a `name:` is not a behaviour change — Actions treats it as the
# step's display label and nothing else — so this refuses rather than excusing.
unnamed="$(awk -F'\t' '$4 == "" { print "  - " $1 ": " $5 }' "$ci_steps" | sort -u)"
if [ -n "$unnamed" ]; then
	echo "check-ci-reach: an UNNAMED run: step exists, and EXPECTED_STEP_FOR_TARGET addresses steps" >&2
	echo "                by name, so no gate can be pinned to it:" >&2
	printf '%s\n' "$unnamed" >&2
	echo "                Give the step a \`name:\`." >&2
	exit 1
fi

# `|` separates the pin's three fields, so a step name containing one would make
# a pin ambiguous instead of merely wrong-looking.
pipe_named="$(awk -F'\t' '$4 ~ /\|/ { print "  - " $2 " / " $4 }' "$ci_steps" | sort -u)"
if [ -n "$pipe_named" ]; then
	echo "check-ci-reach: a run: step name contains '|', which is EXPECTED_STEP_FOR_TARGET's field" >&2
	echo "                separator, so it cannot be pinned unambiguously:" >&2
	printf '%s\n' "$pipe_named" >&2
	exit 1
fi

# One anchor file per REAL step, identified by (workflow, job, ordinal) and
# labelled with (job, step) for the pin to match against.
step_count=0
: >"$step_index"
while IFS="$(printf '\t')" read -r _wf _job _no _step; do
	[ -n "$_step" ] || continue
	step_count=$((step_count + 1))
	printf '%s\t%s\t%s\n' "$step_count" "$_job" "$_step" >>"$step_index"
	awk -F'\t' -v w="$_wf" -v j="$_job" -v n="$_no" \
		'$1 == w && $2 == j && $3 == n { print $5 }' "$ci_steps" |
		anchors | sort -u >"$step_dir/$step_count"
done < <(cut -f1,2,3,4 "$ci_steps" | sort -u)

if [ "$step_count" -eq 0 ]; then
	echo "check-ci-reach: no named run: step found in ${workflows[*]} — a step mapping over an empty" >&2
	echo "                set of steps pins nothing" >&2
	exit 1
fi

# ---------------------------------------------------- activation scrape
#
# The `on:` block and every job's activation keys (#verifyworkflowactually),
# read once here so every comparison below is equality against a pin.
wf_triggers "${workflows[@]}" >"$wf_trig"
wf_job_activation "${workflows[@]}" >"$wf_act"

# A shape neither reader parses is refused BEFORE any pin is compared. An
# unparsed `if:` reads as absent, absent is the pinned value for three of the
# four gate jobs here, and the comparison would then pass on a value nothing
# read.
bad_shape="$(awk -F'\t' '$2 == "!SHAPE" { print "  - " $1 ": " $NF }' "$wf_trig" "$wf_act" | sort -u)"
if [ -n "$bad_shape" ]; then
	echo "check-ci-reach: a line in an \`on:\` or job-activation position has a shape the activation" >&2
	echo "                readers do not parse, so the pins below would compare against a value" >&2
	echo "                nothing read:" >&2
	printf '%s\n' "$bad_shape" >&2
	echo "                Spell it in the two-space block style the rest of the workflow uses, or" >&2
	echo "                teach wf_triggers/wf_job_activation the shape. Flow-style \`on: [push]\`, a" >&2
	echo "                block list where a scalar is expected, and a matrix \`include:\`/\`exclude:\`" >&2
	echo "                are the three that land here most often." >&2
	exit 1
fi



# Does CI contain a command whose tokens contain this anchor as an in-order
# subsequence? Extra flags and arguments on the CI side are fine; missing ones are
# not.
anchor_present_in() {
	awk -v want="$1" '
		BEGIN { ANY = "\001any"; wn = split(want, w, / /) }
		{
			hn = split($0, h, / /)
			wi = 1
			# A wildcard on EITHER side matches, because either side may be the
			# one that spelled the argument through a variable.
			for (hi = 1; hi <= hn && wi <= wn; hi++)
				if (h[hi] == w[wi] || h[hi] == ANY || w[wi] == ANY) wi++
			if (wi > wn) { found = 1; exit }
		}
		END { exit found ? 0 : 1 }
	' "$2"
}

anchor_reached() { anchor_present_in "$1" "$ci_anchor"; }

# CI invoking the target through make counts as reach without any anchor work.
make_invokes() {
	awk -v target="$1" '
		{
			n = split($0, t, / /)
			if (t[1] != "make") next
			for (i = 2; i <= n; i++) if (t[i] == target) { found = 1; exit }
		}
		END { exit found ? 0 : 1 }
	' "$ci_anchor"
}

# The same question asked of ONE step's anchors instead of the flat union, so a
# make-invoked gate's JOB can be pinned even though its step deliberately is not
# (#verifyworkflowactually). Which job runs `make <target>` is a fact about CI's
# structure, not about what the recipe became, so pinning it asserts nothing
# about the recipe — which is the reason the step itself gets no pin.
step_invokes_make() {
	awk -v target="$2" '
		{
			n = split($0, t, / /)
			if (t[1] != "make") next
			for (i = 2; i <= n; i++) if (t[i] == target) { found = 1; exit }
		}
		END { exit found ? 0 : 1 }
	' "$step_dir/$1"
}

is_excused() {
	local t="$1" i
	for i in "${!excused_targets[@]}"; do
		[ "${excused_targets[$i]}" = "$t" ] && return 0
	done
	return 1
}

excuse_reason() {
	local t="$1" i
	for i in "${!excused_targets[@]}"; do
		if [ "${excused_targets[$i]}" = "$t" ]; then
			printf '%s' "${excused_reasons[$i]}"
			return
		fi
	done
}

unreached=""
unreached_count=0
stale=""
stale_count=0
nogate=""
nogate_set=" "
nogate_count=0
reached=0
excused_ok=0
oracle_bad=""
oracle_bad_count=0
gate_targets=0
stepmap_ok=0
stepmap_seen_set=" "
stepmap_unpinned=""
stepmap_unpinned_count=0
stepmap_gone=""
stepmap_gone_count=0
stepmap_dup=""
stepmap_dup_count=0
stepmap_off=""
stepmap_off_count=0
mi_found=""
mi_found_set=" "
gatejob_found_set=" "

while IFS= read -r target; do
	[ -n "$target" ] || continue

	# `make -n` FAILING and a recipe with no checkable command produce the SAME
	# empty output, and the "no gate" verdict below reads both as "carries no
	# gate" — which exempts the target from CI reach entirely, on the header's
	# reasoning that a recipe running nothing cannot hide a gate. That reasoning
	# does not hold when the emptiness came from make refusing to describe the
	# recipe. MEASURED: giving `test` a prerequisite no rule builds made
	# `make -n test` exit 2, dropped BOTH `test` and `conformance-coverage` to
	# "no gate" — the two targets carrying the whole conformance suite — and this
	# guard still printed OK, over 5 reached targets instead of 7
	# (#lzgrepcpipefail).
	#
	# dry_run's `|| true` is RIGHT for its grep: zero lines surviving the
	# `make[`/`make:` filter is a legitimate measurement. It is WRONG for make,
	# whose nonzero exit is the real signal, and one `|| true` covers both.
	# dry_run cannot refuse there either — it only ever runs inside a command
	# substitution, where `exit` leaves the subshell and the script carries on.
	# So make's status is asserted HERE, in the main shell, where refusing works.
	if ! "$MAKE_BIN" -n "$target" >/dev/null 2>&1; then
		echo "check-ci-reach: \`$MAKE_BIN -n $target\` failed, so this target's recipe could not be read." >&2
		echo "                An unreadable recipe yields zero commands, which reports as 'carrying no" >&2
		echo "                gate' and exempts the target from CI reach — a gate hidden by a make error" >&2
		echo "                rather than by an empty recipe." >&2
		exit 1
	fi

	target_anchors="$(own_commands "$target" | anchors | sort -u || true)"

	if [ -z "$target_anchors" ]; then
		nogate="$nogate$target"$'\n'
		nogate_set="$nogate_set$target "
		nogate_count=$((nogate_count + 1))
		continue
	fi
	gate_targets=$((gate_targets + 1))

	# THE ORACLE (#pinreachclosure). `closure` was read out of Makefile SOURCE
	# TEXT — the first line matching `^<root>:` — so it never asked make and cannot
	# see a make conditional. A target listed in a branch make never takes is in
	# the closure, gets a verdict, satisfies the membership pin, and is not run.
	# MEASURED on this tree: `ifeq (0,1)` around the full `check:` line with a
	# shorter live branch left `make -n check` running no `interop-peer-check`
	# while this guard's whole output was byte-identical to healthy, exit 0.
	#
	# So ask make. Every anchor of this target's OWN recipe must also be an anchor
	# of something `make -n <root>` prints.
	#
	# ANCHORS rather than raw command text, and that is not a shortcut here: this
	# Makefile mints CONFORMANCE_RUN_ID once per make INVOCATION (#lzstalemanifest,
	# `:=` on purpose), so `make -n test` and `make -n check` legitimately print
	# different `-Dconformance-run-id=` values. A literal text comparison therefore
	# reports a MISMATCH on a pristine tree — measured, on `test` and
	# `conformance-coverage`, the two targets carrying the whole conformance suite,
	# which is a false RED in the guard's own oracle. The normalizer already drops
	# flag VALUES and leading `VAR=` assignments, so an anchor is stable across
	# invocations while still carrying the program name and its flag names.
	while IFS= read -r a; do
		[ -n "$a" ] || continue
		if ! anchor_present_in "$a" "$root_anchor"; then
			oracle_bad="$oracle_bad$target	$a"$'\n'
			oracle_bad_count=$((oracle_bad_count + 1))
			break
		fi
	done <<<"$target_anchors"

	hit=1
	missing_anchors=""
	if ! make_invokes "$target"; then
		while IFS= read -r a; do
			[ -n "$a" ] || continue
			if ! anchor_reached "$a"; then
				hit=0
				missing_anchors="$missing_anchors$a"$'\n'
			fi
		done <<<"$target_anchors"
	fi

	if is_excused "$target"; then
		if [ "$hit" -eq 1 ]; then
			stale="$stale$target"$'\n'
			stale_count=$((stale_count + 1))
		else
			excused_ok=$((excused_ok + 1))
			printf 'excused  %-32s %s\n' "$target" "$(excuse_reason "$target")"
		fi
		continue
	fi

	# THE STEP MAPPING (#reversereachdirection). Reach is asked INSIDE the step
	# this target is pinned to, not against the flat union above. The flat check
	# stays as it was — it owns the MISSING verdict and its diagnostics — and this
	# is an additional requirement on top of it, which is what makes it strictly
	# stronger rather than a replacement whose looseness has to be re-argued.
	if make_invokes "$target"; then
		mi_found="$mi_found$target"$'\n'
		mi_found_set="$mi_found_set$target "
	fi

	if is_make_invoked_pinned "$target"; then
		# Verdict for these is the make-invocation pin, checked after the loop.
		# The JOB is recorded here all the same: EXPECTED_GATE_JOBS is what pins
		# whether the step that runs `make <target>` runs at all.
		_i=0
		while [ "$_i" -lt "$step_count" ]; do
			_i=$((_i + 1))
			if step_invokes_make "$_i" "$target"; then
				_j="$(awk -F'\t' -v i="$_i" '$1 == i { print $2; exit }' "$step_index")"
				case "$gatejob_found_set" in
				*" $_j "*) ;;
				*) gatejob_found_set="$gatejob_found_set$_j " ;;
				esac
			fi
		done
	elif pinned_entry="$(pinned_step_for "$target")"; then
		pin_job="${pinned_entry%%|*}"
		pin_step="${pinned_entry#*|}"
		pin_matches="$(awk -F'\t' -v j="$pin_job" -v s="$pin_step" \
			'$2 == j && $3 == s { n++ } END { print n + 0 }' "$step_index")"
		if [ "$pin_matches" -eq 0 ]; then
			stepmap_gone="$stepmap_gone$target	$pin_job / $pin_step"$'\n'
			stepmap_gone_count=$((stepmap_gone_count + 1))
		elif [ "$pin_matches" -gt 1 ]; then
			stepmap_dup="$stepmap_dup$target	$pin_job / $pin_step	$pin_matches"$'\n'
			stepmap_dup_count=$((stepmap_dup_count + 1))
		else
			pin_idx="$(awk -F'\t' -v j="$pin_job" -v s="$pin_step" \
				'$2 == j && $3 == s { print $1; exit }' "$step_index")"
			case "$gatejob_found_set" in
			*" $pin_job "*) ;;
			*) gatejob_found_set="$gatejob_found_set$pin_job " ;;
			esac
			step_hit=1
			while IFS= read -r a; do
				[ -n "$a" ] || continue
				if ! anchor_present_in "$a" "$step_dir/$pin_idx"; then
					step_hit=0
					stepmap_off="$stepmap_off$target	$pin_job / $pin_step	$a"$'\n'
					stepmap_off_count=$((stepmap_off_count + 1))
				fi
			done <<<"$target_anchors"
			if [ "$step_hit" -eq 1 ]; then
				stepmap_ok=$((stepmap_ok + 1))
			fi
		fi
		stepmap_seen_set="$stepmap_seen_set$target "
	else
		stepmap_unpinned="$stepmap_unpinned$target"$'\n'
		stepmap_unpinned_count=$((stepmap_unpinned_count + 1))
	fi

	if [ "$hit" -eq 1 ]; then
		reached=$((reached + 1))
		printf 'reached  %s\n' "$target"
	else
		unreached="$unreached$target"$'\n'
		unreached_count=$((unreached_count + 1))
		printf 'MISSING  %s\n' "$target"
		while IFS= read -r a; do
			[ -n "$a" ] || continue
			printf '           no CI run: step matches `%s`\n' "$a"
		done <<<"$missing_anchors"
	fi
done <<<"$closure"

while IFS= read -r target; do
	[ -n "$target" ] || continue
	printf 'no gate  %-32s recipe runs no checkable command\n' "$target"
done <<<"$nogate"

# A guard that examined nothing must not report OK — the same vacuity rule the
# conformance guards apply (#lzvacuousrun).
if [ "$((reached + excused_ok + unreached_count))" -eq 0 ]; then
	echo "check-ci-reach: '$ROOT_TARGET' has no prerequisite target carrying a gate — nothing was verified" >&2
	exit 1
fi

status=0

if [ "$oracle_bad_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $oracle_bad_count target(s) are in \`$ROOT_TARGET\`'s closure as read from the" >&2
	echo "                Makefile, but \`$MAKE_BIN -n $ROOT_TARGET\` does not run their commands:" >&2
	while IFS="$(printf '\t')" read -r t a; do
		[ -n "$t" ] || continue
		echo "  - $t" >&2
		echo "      nothing make runs for '$ROOT_TARGET' matches \`$a\`" >&2
	done <<<"$oracle_bad"
	echo >&2
	echo "  The closure is read from Makefile SOURCE TEXT and cannot see make conditionals, so a" >&2
	echo "  target listed in a branch make never takes still gets a verdict here and still" >&2
	echo "  satisfies EXPECTED_CLOSURE_TARGETS. Every count this guard printed above is then a" >&2
	echo "  count over a set make does not run." >&2
	echo "  Make the live branch run the target, or remove it from the dead branch AND from" >&2
	echo "  EXPECTED_CLOSURE_TARGETS." >&2
	status=1
fi

# CLASSIFICATION. "Carrying no gate" is the only verdict exempt from CI reach, so
# it is the one an attacker wants a target to have: keep the name, empty the
# recipe, and the target leaves the reach requirement without leaving the closure.
nogate_unpinned=""
nogate_unpinned_count=0
nogate_absent=""
nogate_absent_count=0
pinned_nogate=" "
for _t in ${EXPECTED_NO_GATE_TARGETS[@]+"${EXPECTED_NO_GATE_TARGETS[@]}"}; do
	pinned_nogate="$pinned_nogate$_t "
done
while IFS= read -r _t; do
	[ -n "$_t" ] || continue
	case "$pinned_nogate" in
	*" $_t "*) continue ;;
	esac
	nogate_unpinned="$nogate_unpinned$_t"$'\n'
	nogate_unpinned_count=$((nogate_unpinned_count + 1))
done <<<"$nogate"
for _t in ${EXPECTED_NO_GATE_TARGETS[@]+"${EXPECTED_NO_GATE_TARGETS[@]}"}; do
	case "$nogate_set" in
	*" $_t "*) continue ;;
	esac
	nogate_absent="$nogate_absent$_t"$'\n'
	nogate_absent_count=$((nogate_absent_count + 1))
done

if [ "$nogate_unpinned_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $nogate_unpinned_count target(s) carry no gate and are not in" >&2
	echo "                EXPECTED_NO_GATE_TARGETS:" >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "  - $t" >&2
	done <<<"$nogate_unpinned"
	echo >&2
	echo "  A target whose recipe runs nothing checkable is exempt from CI reach entirely. If its" >&2
	echo "  recipe was emptied or reduced to an \`echo\`, restore the gate — this is the case the" >&2
	echo "  pin exists for, and before it the verdict just moved one target from 'reached' to 'no" >&2
	echo "  gate' and still said OK. If it genuinely runs nothing (a reset step), add it to" >&2
	echo "  EXPECTED_NO_GATE_TARGETS so the exemption is named rather than inferred." >&2
	status=1
fi

if [ "$nogate_absent_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $nogate_absent_count target(s) in EXPECTED_NO_GATE_TARGETS do not carry no gate:" >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "  - $t" >&2
	done <<<"$nogate_absent"
	echo >&2
	echo "  Either the target gained a real recipe — then remove it from EXPECTED_NO_GATE_TARGETS," >&2
	echo "  and it now has to be reached by CI like every other gate — or it left the closure" >&2
	echo "  altogether, which the membership pin above reports separately." >&2
	status=1
fi

# THE STEP MAPPING, by set equality in both directions (#reversereachdirection).
# Every gate CI reaches has to be accounted for exactly once: either pinned to
# the step that runs it, or named as invoked through make and therefore
# deliberately unpinnable. A gate in neither list is a gate whose CI-side
# identity nothing states.
stepmap_extra=""
stepmap_extra_count=0
for _e in ${EXPECTED_STEP_FOR_TARGET[@]+"${EXPECTED_STEP_FOR_TARGET[@]}"}; do
	_t="${_e%%|*}"
	case "$stepmap_seen_set" in
	*" $_t "*) continue ;;
	esac
	stepmap_extra="$stepmap_extra$_t	$_e"$'\n'
	stepmap_extra_count=$((stepmap_extra_count + 1))
done

mi_unpinned=""
mi_unpinned_count=0
mi_absent=""
mi_absent_count=0
pinned_mi=" "
for _t in ${EXPECTED_MAKE_INVOKED_TARGETS[@]+"${EXPECTED_MAKE_INVOKED_TARGETS[@]}"}; do
	pinned_mi="$pinned_mi$_t "
done
while IFS= read -r _t; do
	[ -n "$_t" ] || continue
	case "$pinned_mi" in
	*" $_t "*) continue ;;
	esac
	mi_unpinned="$mi_unpinned$_t"$'\n'
	mi_unpinned_count=$((mi_unpinned_count + 1))
done <<<"$mi_found"
for _t in ${EXPECTED_MAKE_INVOKED_TARGETS[@]+"${EXPECTED_MAKE_INVOKED_TARGETS[@]}"}; do
	case "$mi_found_set" in
	*" $_t "*) continue ;;
	esac
	mi_absent="$mi_absent$_t"$'\n'
	mi_absent_count=$((mi_absent_count + 1))
done

if [ "$stepmap_unpinned_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $stepmap_unpinned_count gate(s) are in neither EXPECTED_STEP_FOR_TARGET nor" >&2
	echo "                EXPECTED_MAKE_INVOKED_TARGETS:" >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "  - $t" >&2
	done <<<"$stepmap_unpinned"
	echo >&2
	echo "  Reach is checked inside the step a gate is pinned to. An unpinned gate falls back to" >&2
	echo "  'some run: body in the whole workflow contains these anchors', which is how a recipe" >&2
	echo "  repointed at another gate's command reads as reached. Add a \`target|job|step\` entry," >&2
	echo "  or add it to EXPECTED_MAKE_INVOKED_TARGETS if CI runs it as \`make <target>\`." >&2
	status=1
fi

if [ "$stepmap_extra_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $stepmap_extra_count EXPECTED_STEP_FOR_TARGET entr(ies) name a target that is not a" >&2
	echo "                gate \`make $ROOT_TARGET\` reaches CI-side:" >&2
	while IFS="$(printf '\t')" read -r t e; do
		[ -n "$t" ] || continue
		echo "  - $t	($e)" >&2
	done <<<"$stepmap_extra"
	echo >&2
	echo "  It left the closure, lost its recipe, gained an excuse, or is ALSO listed in" >&2
	echo "  EXPECTED_MAKE_INVOKED_TARGETS — a gate belongs to exactly one of the two. Remove the" >&2
	echo "  stale entry; the pins above report the first three cases separately." >&2
	status=1
fi

if [ "$stepmap_gone_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $stepmap_gone_count gate(s) are pinned to a run: step that does not exist:" >&2
	while IFS="$(printf '\t')" read -r t s; do
		[ -n "$t" ] || continue
		echo "  - $t	pinned to \`$s\`" >&2
	done <<<"$stepmap_gone"
	echo >&2
	echo "  The step was deleted or renamed. This is the case the flat union could not see: the" >&2
	echo "  \`Test\` step's anchor ends in a wildcard, so four of this repo's gates stayed 'reached'" >&2
	echo "  with their own CI step deleted and the verdict byte-identical. If the step was renamed," >&2
	echo "  update the pin; if it was deleted, the gate is not in CI." >&2
	status=1
fi

if [ "$stepmap_dup_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $stepmap_dup_count gate(s) are pinned to a (job, step) pair that matches more than one" >&2
	echo "                run: step:" >&2
	while IFS="$(printf '\t')" read -r t s n; do
		[ -n "$t" ] || continue
		echo "  - $t	\`$s\` matches $n steps" >&2
	done <<<"$stepmap_dup"
	echo >&2
	echo "  Step names are not unique across the family, so the pin refuses an ambiguous pair" >&2
	echo "  rather than picking one of them. Rename one of the steps." >&2
	status=1
fi

if [ "$stepmap_off_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $stepmap_off_count gate(s) whose PINNED CI step does not run them:" >&2
	while IFS="$(printf '\t')" read -r t s a; do
		[ -n "$t" ] || continue
		echo "  - $t" >&2
		echo "      pinned step \`$s\` has no command matching \`$a\`" >&2
	done <<<"$stepmap_off"
	echo >&2
	echo "  Either the recipe was repointed at a gate some OTHER step runs — the swap the flat" >&2
	echo "  union cannot see, because it only asks whether some command anywhere contains these" >&2
	echo "  anchors — or the step really stopped running it. Reach is a floor per step, so extra" >&2
	echo "  CI-side flags are fine; a missing one is not." >&2
	status=1
fi

if [ "$mi_unpinned_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $mi_unpinned_count gate(s) are reached by CI running \`make <target>\` but are not in" >&2
	echo "                EXPECTED_MAKE_INVOKED_TARGETS:" >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "  - $t" >&2
	done <<<"$mi_unpinned"
	echo >&2
	echo "  A make-invoked gate has no independent CI-side spelling, so it gets no step pin and" >&2
	echo "  nothing here cross-checks its recipe. That exemption has to be named rather than" >&2
	echo "  inferred from whatever CI happens to contain." >&2
	status=1
fi

if [ "$mi_absent_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $mi_absent_count gate(s) in EXPECTED_MAKE_INVOKED_TARGETS that CI does not invoke" >&2
	echo "                through make:" >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "  - $t" >&2
	done <<<"$mi_absent"
	echo >&2
	echo "  MEASURED as the reason this pin exists: with the \`make fmt\` step deleted, \`fmt\` fell" >&2
	echo "  through to the flat anchor check, \`check-fmt.sh\` was swallowed by the \`Test\` step's" >&2
	echo "  trailing wildcard, and the verdict was byte-identical to healthy at exit 0. Either CI" >&2
	echo "  still runs \`make <target>\` and the step came back, or it now spells the command" >&2
	echo "  itself — then move the target into EXPECTED_STEP_FOR_TARGET and pin that step." >&2
	status=1
fi

# THE ACTIVATION PINS (#verifyworkflowactually), each by set equality or exact
# string equality, each naming what changed and in which direction. These are
# the only checks in this file that read something other than `run:` bodies and
# Makefile recipes: everything above asks what a step runs, and these ask whether
# it runs.
trig_bad=""
trig_bad_count=0
for _wf in "${workflows[@]}"; do
	_want="(no EXPECTED_TRIGGERS entry)"
	for _e in ${EXPECTED_TRIGGERS[@]+"${EXPECTED_TRIGGERS[@]}"}; do
		case "$_e" in
		"$_wf|"*) _want="${_e#*|}" ;;
		esac
	done
	_got="$(awk -F'\t' -v w="$_wf" '$1 == w && $2 != "" { print $2 }' "$wf_trig" | sort -u | paste -sd, -)"
	# An empty trigger set is set-equal to an empty pin, so it is refused here
	# rather than compared: a workflow with no `on:` at all runs on nothing, and
	# a pin that approves it is the vacuity this whole section exists to remove.
	if [ -z "$_got" ]; then
		echo "check-ci-reach: no top-level \`on:\` trigger parsed out of '$_wf'. Every gate this guard" >&2
		echo "                reports reached is reached by a workflow that then runs on nothing." >&2
		exit 1
	fi
	if [ "$_got" != "$_want" ]; then
		trig_bad="$trig_bad$_wf	$_want	$_got"$'\n'
		trig_bad_count=$((trig_bad_count + 1))
	fi
done

filt_bad=""
filt_bad_count=0
filt_stale=""
filt_stale_count=0
trig_pairs=" "
trig_total=0
while IFS="$(printf '\t')" read -r _wf _trig; do
	[ -n "$_trig" ] || continue
	trig_pairs="$trig_pairs$_wf|$_trig "
	trig_total=$((trig_total + 1))
	_got="$(awk -F'\t' -v w="$_wf" -v t="$_trig" \
		'$1 == w && $2 == t && $3 != "" { print $3 }' "$wf_trig" | sort -u | paste -sd';' -)"
	_want="(no EXPECTED_TRIGGER_FILTERS entry)"
	for _e in ${EXPECTED_TRIGGER_FILTERS[@]+"${EXPECTED_TRIGGER_FILTERS[@]}"}; do
		case "$_e" in
		"$_wf|$_trig|"*) _want="${_e#*|*|}" ;;
		esac
	done
	if [ "$_got" != "$_want" ]; then
		filt_bad="$filt_bad$_wf	$_trig	$_want	$_got"$'\n'
		filt_bad_count=$((filt_bad_count + 1))
	fi
done < <(awk -F'\t' '$2 != "" { print $1 "\t" $2 }' "$wf_trig" | sort -u)

# The other direction: a pinned filter entry for a trigger that is gone. The
# trigger-set pin above already reports the missing trigger, and this reports the
# pin left behind, so neither a stale pin nor a stale workflow reads as healthy.
for _e in ${EXPECTED_TRIGGER_FILTERS[@]+"${EXPECTED_TRIGGER_FILTERS[@]}"}; do
	# The first TWO fields. `${_e%|*}` strips from the LAST `|`, so a filter value
	# containing one — which the pin format allows on purpose — would shift the key.
	_rest="${_e#*|}"
	_p="${_e%%|*}|${_rest%%|*}"
	case "$trig_pairs" in
	*" $_p "*) continue ;;
	esac
	filt_stale="$filt_stale$_e"$'\n'
	filt_stale_count=$((filt_stale_count + 1))
done

# The job reader is a different parser from ci_step_commands, so a job it fails
# to see would silently have no activation to compare — and "no activation" is
# the pinned value for three of the four gate jobs, so it would PASS. Cross-check
# the two readers against each other before trusting either.
act_job_set=" "
while IFS= read -r _j; do
	[ -n "$_j" ] || continue
	act_job_set="$act_job_set$_j "
done < <(awk -F'\t' '$3 == "PRESENT" { print $2 }' "$wf_act" | sort -u)

reader_skew=""
reader_skew_count=0
while IFS= read -r _j; do
	[ -n "$_j" ] || continue
	case "$act_job_set" in
	*" $_j "*) continue ;;
	esac
	reader_skew="$reader_skew$_j"$'\n'
	reader_skew_count=$((reader_skew_count + 1))
done < <(awk -F'\t' '{ print $2 }' "$ci_steps" | sort -u)

# Two job-level `if:` lines in one job, or two `continue-on-error:` lines, make
# the serialization below depend on which one this reader kept. Refuse instead.
dup_act="$(awk -F'\t' '
	$3 == "if" || $3 == "continue-on-error" || $3 == "needs" { n[$2 "\t" $3]++ }
	END { for (k in n) if (n[k] > 1) print "  - " k " appears " n[k] " times" }
' "$wf_act" | sort)"

# `|` separates a pin's fields and `;` joins the values inside one, so either
# character is refused where it would make a pin AMBIGUOUS — and only there.
#
# A `|` IS ALLOWED INSIDE AN ACTIVATION OR FILTER VALUE, deliberately. A GitHub
# `if:` expression using `||` is ordinary, and every lookup that reads a value
# strips a FIXED number of leading fields (`${_e#*|}` for a job, two steps for a
# trigger) rather than splitting on every `|`, so a value containing one is read
# correctly. Refusing it would red a legitimate config over a character the
# guard does not need — the same mistake as forbidding job-level
# continue-on-error outright, which is the mistake this whole section exists to
# avoid.
#
# What IS refused is a separator in pin STRUCTURE — a job id, a trigger name, a
# filter key, an activation key, a matrix axis or leg — and a `;` inside a
# value, which is the serialization's own joiner and which no GitHub expression,
# branch pattern or matrix leg here needs.
sep_in_value="$(
	awk -F'\t' '$2 != "!SHAPE" && ($2 ~ /[|;]/ || $3 ~ /[|;]/) { print "  - job id or key: " $0 }' "$wf_act"
	awk -F'\t' '$2 != "!SHAPE" && ($2 ~ /[|;]/ || $3 ~ /^[^=]*[|;]/) { print "  - trigger name or filter key: " $0 }' "$wf_trig"
	awk -F'\t' '$2 != "!SHAPE" && $3 == "matrix" && $4 ~ /[|;]/ { print "  - matrix axis or leg: " $0 }' "$wf_act"
	awk -F'\t' '$2 != "!SHAPE" && ($3 == "if" || $3 == "continue-on-error" || $3 == "needs") && $4 ~ /;/ { print "  - activation value: " $0 }' "$wf_act"
	awk -F'\t' '$2 != "!SHAPE" && $3 ~ /=.*;/ { print "  - filter value: " $0 }' "$wf_trig"
)"

# Serialized, one canonical string per job, so the comparison is equality
# against a literal rather than a rule re-implemented per key.
job_activation() {
	awk -F'\t' -v j="$1" '
		$2 == j && $3 == "continue-on-error" { c = $4 }
		$2 == j && $3 == "if" { i = $4 }
		$2 == j && $3 == "needs" { n = $4 }
		END { printf "continue-on-error=%s;if=%s;needs=%s", c, i, n }
	' "$wf_act"
}

job_matrix() {
	awk -F'\t' -v j="$1" '$2 == j && $3 == "matrix" { print $4 }' "$wf_act" |
		sort -u | paste -sd';' -
}

# EXPECTED_GATE_JOBS against the jobs the pins above RESOLVED to, both
# directions. `gatejob_found_set` was filled in the loop: the job field of every
# step pin that resolved to exactly one step, plus the job of every step CI
# invokes a make-invoked gate from.
gatejob_unpinned=""
gatejob_unpinned_count=0
gatejob_absent=""
gatejob_absent_count=0
pinned_gatejobs=" "
for _t in ${EXPECTED_GATE_JOBS[@]+"${EXPECTED_GATE_JOBS[@]}"}; do
	pinned_gatejobs="$pinned_gatejobs$_t "
done
for _j in $gatejob_found_set; do
	case "$pinned_gatejobs" in
	*" $_j "*) continue ;;
	esac
	gatejob_unpinned="$gatejob_unpinned$_j"$'\n'
	gatejob_unpinned_count=$((gatejob_unpinned_count + 1))
done
for _j in ${EXPECTED_GATE_JOBS[@]+"${EXPECTED_GATE_JOBS[@]}"}; do
	case "$gatejob_found_set" in
	*" $_j "*) continue ;;
	esac
	gatejob_absent="$gatejob_absent$_j"$'\n'
	gatejob_absent_count=$((gatejob_absent_count + 1))
done

# EVERY CELL TERMINATES IN A PIN. EXPECTED_JOB_ACTIVATION and
# EXPECTED_JOB_MATRIX are keyed by job, so their key sets are asserted equal to
# EXPECTED_GATE_JOBS rather than merely looked up: without this, adding a gate
# job to EXPECTED_GATE_JOBS and forgetting its activation entry would leave that
# job's `if:` compared against nothing.
pinkey_bad=""
pinkey_bad_count=0
for _name in EXPECTED_JOB_ACTIVATION EXPECTED_JOB_MATRIX; do
	eval '_entries=(${'"$_name"'[@]+"${'"$_name"'[@]}"})'
	_seen=" "
	for _e in ${_entries[@]+"${_entries[@]}"}; do
		_j="${_e%%|*}"
		_seen="$_seen$_j "
		case "$pinned_gatejobs" in
		*" $_j "*) continue ;;
		esac
		pinkey_bad="$pinkey_bad$_name	$_j	names a job that is not in EXPECTED_GATE_JOBS"$'\n'
		pinkey_bad_count=$((pinkey_bad_count + 1))
	done
	for _j in ${EXPECTED_GATE_JOBS[@]+"${EXPECTED_GATE_JOBS[@]}"}; do
		case "$_seen" in
		*" $_j "*) continue ;;
		esac
		pinkey_bad="$pinkey_bad$_name	$_j	is a gate job with no entry, so its value is compared against nothing"$'\n'
		pinkey_bad_count=$((pinkey_bad_count + 1))
	done
done

act_bad=""
act_bad_count=0
mx_bad=""
mx_bad_count=0
for _j in ${EXPECTED_GATE_JOBS[@]+"${EXPECTED_GATE_JOBS[@]}"}; do
	case "$act_job_set" in
	*" $_j "*) ;;
	*)
		act_bad="$act_bad$_j	(job absent from the workflow)	-"$'\n'
		act_bad_count=$((act_bad_count + 1))
		continue
		;;
	esac
	_want="(no EXPECTED_JOB_ACTIVATION entry)"
	for _e in ${EXPECTED_JOB_ACTIVATION[@]+"${EXPECTED_JOB_ACTIVATION[@]}"}; do
		case "$_e" in
		"$_j|"*) _want="${_e#*|}" ;;
		esac
	done
	_got="$(job_activation "$_j")"
	if [ "$_got" != "$_want" ]; then
		act_bad="$act_bad$_j	$_want	$_got"$'\n'
		act_bad_count=$((act_bad_count + 1))
	fi
	_want="(no EXPECTED_JOB_MATRIX entry)"
	for _e in ${EXPECTED_JOB_MATRIX[@]+"${EXPECTED_JOB_MATRIX[@]}"}; do
		case "$_e" in
		"$_j|"*) _want="${_e#*|}" ;;
		esac
	done
	_got="$(job_matrix "$_j")"
	if [ "$_got" != "$_want" ]; then
		mx_bad="$mx_bad$_j	$_want	$_got"$'\n'
		mx_bad_count=$((mx_bad_count + 1))
	fi
done

if [ -n "$dup_act" ]; then
	echo >&2
	echo "check-ci-reach: a job declares the same activation key twice, so which value this guard" >&2
	echo "                pins depends on which one it happened to keep:" >&2
	printf '%s\n' "$dup_act" >&2
	status=1
fi

if [ -n "$sep_in_value" ]; then
	echo >&2
	echo "check-ci-reach: a pin separator appears where a pin's STRUCTURE is, so the pin cannot be" >&2
	echo "                read back unambiguously — a '|' or ';' in a job id, trigger name, filter" >&2
	echo "                key, matrix axis or matrix leg, or a ';' inside a value:" >&2
	printf '%s\n' "$sep_in_value" >&2
	status=1
fi

if [ "$reader_skew_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $reader_skew_count job(s) have run: steps but no job-level activation was parsed for" >&2
	echo "                them:" >&2
	while IFS= read -r j; do
		[ -n "$j" ] || continue
		echo "  - $j" >&2
	done <<<"$reader_skew"
	echo >&2
	echo "  ci_step_commands and wf_job_activation are two readers of the same file and they" >&2
	echo "  disagree about which jobs exist. 'No activation parsed' is the PINNED value for" >&2
	echo "  three of the four gate jobs here, so a job the activation reader cannot see would" >&2
	echo "  pass its \`if:\` pin vacuously. The usual cause is a run: body line at column 0," >&2
	echo "  which ends the \`jobs:\` block for the activation reader and hides every job after" >&2
	echo "  it. Indent the body." >&2
	status=1
fi

if [ "$trig_bad_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $trig_bad_count workflow(s) whose top-level \`on:\` triggers are not the pinned set:" >&2
	while IFS="$(printf '\t')" read -r w want got; do
		[ -n "$w" ] || continue
		echo "  - $w" >&2
		echo "      EXPECTED_TRIGGERS: $want" >&2
		echo "      workflow says:     $got" >&2
	done <<<"$trig_bad"
	echo >&2
	echo "  MEASURED as the reason this pin exists: with \`on:\` reduced to \`workflow_dispatch\`," >&2
	echo "  every gate in this workflow still read as reached and this guard's whole output was" >&2
	echo "  byte-identical to healthy at exit 0 — a workflow that runs on no push and no PR," >&2
	echo "  approved. Listing a workflow in $CONF is a CLAIM that it runs on every push/PR; this" >&2
	echo "  is where that claim stops being a comment. If the trigger set changed on purpose," >&2
	echo "  that is a behaviour change: update EXPECTED_TRIGGERS in the same reviewable diff." >&2
	status=1
fi

if [ "$filt_bad_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $filt_bad_count trigger(s) whose filters are not the pinned set:" >&2
	while IFS="$(printf '\t')" read -r w t want got; do
		[ -n "$w" ] || continue
		echo "  - $w	on: $t" >&2
		echo "      EXPECTED_TRIGGER_FILTERS: $want" >&2
		echo "      workflow says:            $got" >&2
	done <<<"$filt_bad"
	echo >&2
	echo "  A trigger that fires is not a trigger that fires for the change in front of it. A" >&2
	echo "  narrowed \`branches:\` leaves the workflow running on a branch nobody pushes; an" >&2
	echo "  introduced \`paths:\` that does not list Makefile means the edit that RETIRES a gate" >&2
	echo "  does not trigger the workflow that would have caught it. Both were measured" >&2
	echo "  byte-identical at exit 0 before this pin. No binding in this family has a \`paths:\`" >&2
	echo "  filter, so seeing one here is a change to REVIEW, not a pin to update reflexively." >&2
	status=1
fi

if [ "$filt_stale_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $filt_stale_count EXPECTED_TRIGGER_FILTERS entr(ies) name a trigger this workflow does" >&2
	echo "                not have:" >&2
	while IFS= read -r e; do
		[ -n "$e" ] || continue
		echo "  - $e" >&2
	done <<<"$filt_stale"
	echo >&2
	echo "  The trigger pin above reports the trigger that left; this reports the filter pin" >&2
	echo "  left behind, so a half-applied edit cannot read as healthy from either side." >&2
	status=1
fi

if [ "$gatejob_unpinned_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $gatejob_unpinned_count job(s) carry reach for a gate and are not in EXPECTED_GATE_JOBS:" >&2
	while IFS= read -r j; do
		[ -n "$j" ] || continue
		echo "  - $j" >&2
	done <<<"$gatejob_unpinned"
	echo >&2
	echo "  Whether a job runs is pinned per job, so a gate that moved into an unlisted job has" >&2
	echo "  no activation pin at all. Add the job here together with its EXPECTED_JOB_ACTIVATION" >&2
	echo "  and EXPECTED_JOB_MATRIX entries." >&2
	status=1
fi

if [ "$gatejob_absent_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $gatejob_absent_count job(s) in EXPECTED_GATE_JOBS carry reach for no gate:" >&2
	while IFS= read -r j; do
		[ -n "$j" ] || continue
		echo "  - $j" >&2
	done <<<"$gatejob_absent"
	echo >&2
	echo "  The job was renamed or deleted, or every gate it ran moved elsewhere. The step and" >&2
	echo "  make-invocation pins above report the gate side; this reports the job whose" >&2
	echo "  activation is now pinned for nothing." >&2
	status=1
fi

if [ "$pinkey_bad_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $pinkey_bad_count activation pin key(s) do not line up with EXPECTED_GATE_JOBS:" >&2
	while IFS="$(printf '\t')" read -r n j why; do
		[ -n "$n" ] || continue
		echo "  - $n: '$j' $why" >&2
	done <<<"$pinkey_bad"
	echo >&2
	echo "  Every cell of the partition has to terminate in a pin. A gate job with no" >&2
	echo "  EXPECTED_JOB_ACTIVATION entry has its \`if:\` compared against nothing, which passes" >&2
	echo "  for any value it could hold." >&2
	status=1
fi

if [ "$act_bad_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $act_bad_count gate job(s) whose job-level activation is not the pinned value:" >&2
	while IFS="$(printf '\t')" read -r j want got; do
		[ -n "$j" ] || continue
		echo "  - $j" >&2
		echo "      EXPECTED_JOB_ACTIVATION: $want" >&2
		echo "      workflow says:           $got" >&2
	done <<<"$act_bad"
	echo >&2
	echo "  An empty value means the key is ABSENT. This pin is VALUES, not absences, on purpose:" >&2
	echo "  \`test\`'s \`continue-on-error: \${{ matrix.zig == 'master' }}\` is correct here — the" >&2
	echo "  advisory master leg is documented at the top of the workflow — and a rule forbidding" >&2
	echo "  job-level continue-on-error outright would red a healthy tree and get itself deleted." >&2
	echo "  So a change in EITHER direction is named: absent -> present removes a gate, present ->" >&2
	echo "  absent restores one, and present -> a different expression retargets which matrix leg" >&2
	echo "  is advisory. All three were byte-identical at exit 0 before this pin." >&2
	status=1
fi

if [ "$mx_bad_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $mx_bad_count gate job(s) whose matrix legs are not the pinned set:" >&2
	while IFS="$(printf '\t')" read -r j want got; do
		[ -n "$j" ] || continue
		echo "  - $j" >&2
		echo "      EXPECTED_JOB_MATRIX: $want" >&2
		echo "      workflow says:       $got" >&2
	done <<<"$mx_bad"
	echo >&2
	echo "  The leg set is the other half of a continue-on-error keyed on a matrix value, and" >&2
	echo "  neither half is checkable alone. MEASURED byte-identical at exit 0 before this pin:" >&2
	echo "  reducing \`test\`'s matrix to \`zig: ['master']\` left the continue-on-error expression" >&2
	echo "  untouched — so the activation pin was satisfied — while making every leg of the job" >&2
	echo "  advisory. Renaming the \`master\` leg does the converse. Which legs GATE is a fact" >&2
	echo "  about the pair, so both are pinned." >&2
	status=1
fi

if [ "$stale_count" -gt 0 ]; then
	echo >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "check-ci-reach: '$t' is excused in $CONF but CI DOES reach it — remove the excuse" >&2
	done <<<"$stale"
	status=1
fi

if [ "$unreached_count" -gt 0 ]; then
	echo >&2
	echo "check-ci-reach: $unreached_count target(s) run by 'make $ROOT_TARGET' that no CI run: step reaches:" >&2
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		echo "  - $t" >&2
	done <<<"$unreached"
	echo >&2
	echo "Add a CI step that runs it, or add an excuse with a reason to $CONF." >&2
	status=1
fi

if [ "$status" -eq 0 ]; then
	printf 'pinned   %s no-gate target(s) match EXPECTED_NO_GATE_TARGETS; %s gate(s) confirmed run by `%s -n %s`\n' \
		"$nogate_count" "$gate_targets" "$MAKE_BIN" "$ROOT_TARGET"
	printf 'pinned   %s gate(s) reached INSIDE their pinned CI step, %s through `make <target>` and unpinnable, over %s named run: step(s)\n' \
		"$stepmap_ok" "${#EXPECTED_MAKE_INVOKED_TARGETS[@]}" "$step_count"
	printf 'pinned   %s trigger(s) over %s workflow(s) match EXPECTED_TRIGGERS and their filters EXPECTED_TRIGGER_FILTERS\n' \
		"$trig_total" "$workflow_count"
	printf 'pinned   %s gate job(s) match EXPECTED_GATE_JOBS, each with its exact `if:`, `needs:`, `continue-on-error:` and matrix legs\n' \
		"${#EXPECTED_GATE_JOBS[@]}"
	echo "check-ci-reach: OK — $reached target(s) reached by CI, $excused_ok excused, $nogate_count carrying no gate"
fi
exit "$status"
