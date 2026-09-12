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
# THREE THINGS ARE PINNED, AND THE FIRST IS LOAD-BEARING (#pinreachclosure)
#
#   1. THE ORACLE. The closure below is awk-derived from Makefile SOURCE TEXT, so
#      it never asks make and cannot see a make CONDITIONAL. Every target in that
#      closure must therefore be proved against `make -n <root>`: each anchor of
#      the target's own recipe has to be an anchor of a command make really runs
#      for the root. Without this, the two pins below are set-equal to a set that
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
#   OUT OF SCOPE, said plainly: swapping a target's recipe for a DIFFERENT gate CI
#   already runs defeats all three, with every count unchanged and the verdict
#   byte-identical. Closing it needs a per-target recipe anchor — a second
#   spelling of every recipe inside this guard — which is the mistake the variable
#   note above records as having already cost lazily-cpp. It also bounds the
#   honest claim here: a pin turns an invisible drop into a reviewable edit, and
#   that swap is an equally reviewable edit that stays equally undetected.
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

# Command lines from every `run:` step. Comment lines inside a run body are
# stripped here — the whole reason this guard is a script.
ci_commands() {
	awk '
		function flush() { if (buf != "") { print buf; buf = "" } }
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
					if (buf != "") { print buf " " line; buf = "" } else print line
					next
				}
			}

			if (line ~ /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*[|>][-+]?[[:space:]]*$/) {
				inblock = 1
				block_indent = indent
				buf = ""
				next
			}
			if (line ~ /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*[^|>[:space:]]/) {
				sub(/^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*/, "", line)
				print line
			}
		}
		END { flush() }
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
trap 'rm -f "$ci_raw" "$ci_anchor" "$root_anchor"' EXIT
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
	echo "check-ci-reach: OK — $reached target(s) reached by CI, $excused_ok excused, $nogate_count carrying no gate"
fi
exit "$status"
