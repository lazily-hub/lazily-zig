#!/usr/bin/env bash
# Multi-toolchain formatting gate (#lzzigfmttoolchains).
#
# WHY THIS IS NOT `zig fmt --check .`
#
#   `zig fmt` is not one formatter. The toolchains this repo pins do not all
#   produce the same bytes, and the disagreement is per-CONSTRUCT rather than
#   universal, so a tree can be clean under the toolchain on your PATH and dirty
#   under the one CI happens to run. Measured 2026-08-11 on the construct
#   `threeOpScenario` used before 5bea17c — a multiline string literal spliced
#   inline with `++` inside a `return`:
#
#     0.15.2  rewrites `return` to `return ` (trailing space) and de-indents the
#             `++` continuation lines to column 0
#     0.16.0  leaves `return` bare and keeps the continuations indented
#
#   Neither output is a fixed point of the other: 0.16.0 `--check` rejects
#   0.15.2's output and 0.15.2 `--check` rejects 0.16.0's. There is no formatting
#   of that construct both accept, so `fmt-fix` cannot resolve it and the source
#   has to be restructured — which is what 5bea17c did, for that one construct.
#
#   5bea17c fixed the instance. This script fixes the class: the disagreement is
#   now visible on the machine that wrote the code instead of in a CI job.
#
# WHAT IT GUARANTEES
#
#   The tree is accepted, byte for byte, by EVERY pinned RELEASE toolchain in the
#   CI matrix. Not "by the formatter that happened to be on PATH".
#
# WHAT IT DOES NOT GUARANTEE
#
#   Anything about `master`. `master` is a moving nightly: `mlugg/setup-zig`
#   resolves it to whatever shipped today and a local mise install resolves it to
#   whatever you last upgraded to, so those are simply different compilers. A gate
#   on it reddens on upstream's schedule rather than on anything a contributor
#   did, which is how a gate teaches everyone to ignore it. It is reported here as
#   ADVISORY and never affects the exit status — the same call ci.yml makes by
#   skipping the format step on `master`.
#
# FAILING CLOSED
#
#   The gated set is derived from the CI matrix in the workflow, so it cannot
#   drift from what CI runs. A toolchain in that set which cannot be resolved on
#   this machine is NAMED and fails the run. "Checked 1 of 2" never reports OK —
#   a gate that quietly checks fewer things than it claims is the same vacuity as
#   a suite that reports green having tested nothing.
#
#   Every resolved binary is asked its own version and must answer with the
#   version it was resolved FOR. Otherwise `ZIG_FMT_0_15_2` pointing at a 0.16.0
#   binary would run the same compiler twice and report two toolchains agreeing.
#
# RESOLVING A TOOLCHAIN, in order:
#
#   1. $ZIG_FMT_<version with non-alphanumerics as underscores>, e.g.
#      ZIG_FMT_0_15_2=/path/to/zig. This is how CI passes the two binaries
#      `mlugg/setup-zig` installed.
#   2. `zig` on PATH, if it reports exactly this version.
#   3. `mise where zig@<version>`, which is how .mise.toml pins them locally.
set -euo pipefail

WORKFLOW="${ZIG_FMT_WORKFLOW:-.github/workflows/ci.yml}"
TARGET="${ZIG_FMT_TARGET:-.}"

# Pins that cannot be pinned. Everything else in the matrix is gated.
NON_GATED="master"

if [ ! -f "$WORKFLOW" ]; then
	echo "check-fmt: workflow '$WORKFLOW' not found — the gated toolchain set is derived from its matrix" >&2
	exit 1
fi

# ------------------------------------------------------- the gated toolchain set

# `        zig: ['0.15.2', '0.16.0', 'master']`
matrix_line="$(grep -E "^[[:space:]]*zig:[[:space:]]*\[" "$WORKFLOW" | head -n 1 || true)"
if [ -z "$matrix_line" ]; then
	echo "check-fmt: no \`zig: [...]\` matrix found in $WORKFLOW — refusing to guess which toolchains gate" >&2
	exit 1
fi

matrix_versions="$(printf '%s' "$matrix_line" |
	sed -e 's/^[^[]*\[//' -e 's/\].*$//' -e "s/['\"]//g" -e 's/,/ /g')"

gated=()
advisory=()
for v in $matrix_versions; do
	[ -n "$v" ] || continue
	if [ "$v" = "$NON_GATED" ]; then
		advisory+=("$v")
	else
		gated+=("$v")
	fi
done

if [ "${#gated[@]}" -lt 2 ]; then
	echo "check-fmt: parsed ${#gated[@]} gated toolchain(s) from $WORKFLOW — this gate exists because the pinned" >&2
	echo "           releases disagree with each other, so fewer than two cross-checks nothing" >&2
	exit 1
fi

# The workflow must actually install every gated toolchain in the job that runs
# this script. The matrix job installs `${{ matrix.zig }}`, so a literal
# `version: '<v>'` line can only come from the format job — which is the point.
for v in "${gated[@]}"; do
	v_re="$(printf '%s' "$v" | sed -e 's/[.]/\\./g')"
	if ! grep -qE "version:[[:space:]]*['\"]?${v_re}['\"]?[[:space:]]*\$" "$WORKFLOW"; then
		echo "check-fmt: $WORKFLOW gates formatting on '$v' but never installs it with a literal version:" >&2
		echo "           the format job must set up every gated toolchain, or CI checks fewer than it claims" >&2
		exit 1
	fi
done

# ------------------------------------------------------------------- resolution

# Echo a zig binary that reports exactly $1, or nothing.
resolve() {
	local want="$1" env_name candidate
	env_name="ZIG_FMT_${want//[^A-Za-z0-9]/_}"

	if [ -n "${!env_name:-}" ]; then
		# An explicit override that points at the wrong compiler is a
		# misconfiguration, not a fallback: say so rather than silently
		# resolving something else.
		if [ "$(reported_version "${!env_name}")" = "$want" ]; then
			printf '%s' "${!env_name}"
		fi
		return
	fi

	if candidate="$(command -v zig 2>/dev/null)" && [ "$(reported_version "$candidate")" = "$want" ]; then
		printf '%s' "$candidate"
		return
	fi

	if command -v mise >/dev/null 2>&1; then
		local dir
		if dir="$(mise where "zig@$want" 2>/dev/null)" && [ -x "$dir/zig" ] &&
			[ "$(reported_version "$dir/zig")" = "$want" ]; then
			printf '%s' "$dir/zig"
			return
		fi
	fi
}

# A moving pin cannot be resolved by version equality — `master` never reports
# "master". Resolve it only through the channel that names the pin itself, never
# through PATH: the zig on PATH is some pinned release far more often than it is
# a nightly, and reporting that release's result under the master line would be a
# lie in the direction of comfort.
resolve_moving() {
	local want="$1" env_name dir
	env_name="ZIG_FMT_${want//[^A-Za-z0-9]/_}"
	if [ -n "${!env_name:-}" ] && [ -x "${!env_name}" ]; then
		printf '%s' "${!env_name}"
		return
	fi
	if command -v mise >/dev/null 2>&1 &&
		dir="$(mise where "zig@$want" 2>/dev/null)" && [ -x "$dir/zig" ]; then
		printf '%s' "$dir/zig"
	fi
}

reported_version() {
	[ -x "$1" ] || return 0
	"$1" version 2>/dev/null | head -n 1 | tr -d '[:space:]'
}

# ----------------------------------------------------------------------- the gate

status=0
ran=()
dirty=()

for v in "${gated[@]}"; do
	bin="$(resolve "$v")"
	if [ -z "$bin" ]; then
		printf 'check-fmt: %-8s MISSING — no zig reporting version %s (set ZIG_FMT_%s, or `mise install zig@%s`)\n' \
			"$v" "$v" "${v//[^A-Za-z0-9]/_}" "$v" >&2
		status=1
		continue
	fi

	if out="$("$bin" fmt --check "$TARGET" 2>&1)"; then
		printf 'check-fmt: %-8s clean    %s\n' "$v" "$bin"
		ran+=("$v")
	else
		printf 'check-fmt: %-8s DIRTY    %s\n' "$v" "$bin" >&2
		printf '%s\n' "$out" | sed 's/^/             /' >&2
		ran+=("$v")
		dirty+=("$v")
		status=1
	fi
done

for v in "${advisory[@]-}"; do
	[ -n "$v" ] || continue
	bin="$(resolve_moving "$v")"
	if [ -z "$bin" ]; then
		# `master` resolves to a different compiler in every environment, so its
		# absence is information, not a failure.
		printf 'check-fmt: %-8s advisory — not resolved here, not gated\n' "$v"
		continue
	fi
	if "$bin" fmt --check "$TARGET" >/dev/null 2>&1; then
		printf 'check-fmt: %-8s advisory — clean (%s), NOT gated\n' "$v" "$(reported_version "$bin")"
	else
		printf 'check-fmt: %-8s advisory — DIRTY (%s), NOT gated: a moving nightly is not a pin\n' \
			"$v" "$(reported_version "$bin")"
	fi
done

if [ "$status" -ne 0 ]; then
	echo >&2
	echo "check-fmt: FAILED — ran ${#ran[@]} of ${#gated[@]} gated toolchain(s)" >&2
	echo "           required: ${gated[*]}" >&2
	echo "           ran:      ${ran[*]-(none)}" >&2
	if [ "${#ran[@]}" -lt "${#gated[@]}" ]; then
		echo "           A gated toolchain that is not installed does not reduce this gate to the ones" >&2
		echo "           that are — install it, or point ZIG_FMT_<version> at it." >&2
	fi
	if [ "${#dirty[@]}" -gt 0 ] && [ "${#dirty[@]}" -lt "${#ran[@]}" ]; then
		echo "           DISAGREEMENT: ${dirty[*]} rejected files the other gated toolchain(s) accepted." >&2
		echo "           'make fmt-fix' cannot resolve this — for such a construct there is no formatting" >&2
		echo "           every pinned release accepts. Restructure it, as 5bea17c did for a multiline string" >&2
		echo "           literal spliced inline with '++' inside a 'return'." >&2
	fi
	exit 1
fi

echo "check-fmt: OK — ${#ran[@]} of ${#gated[@]} pinned release toolchains agree on this tree: ${ran[*]-}"
