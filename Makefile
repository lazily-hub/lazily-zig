LAKE ?= lake
ZIG ?= zig
LEAN_DIR ?= ../lazily-formal

# Runtime conformance manifest (#lazilyupgradeconformance). ABSOLUTE on purpose:
# `zig build test` runs a dozen separate test binaries and a build runner may
# start them from a working directory other than the repo root, so a relative
# path would scatter partial manifests instead of accumulating one union.
CONFORMANCE_MANIFEST ?= $(CURDIR)/build/conformance-fixtures-loaded.txt

.PHONY: \
	check \
fmt \
fmt-fix \
test \
test-interop-peer \
test-lean-formal \
ci-reach

check: fmt test test-interop-peer test-lean-formal conformance-coverage ci-reach

# The formatting GATE (#lazilydartzig). This binding had no formatting floor at
# all — nothing in `check`, nothing in CI — so drift was invisible until someone
# read a diff.
#
# `zig fmt` is canonical and ships with the toolchain, so adopting it costs no new
# dependency. The one real question was WHICH toolchain's `zig fmt`, because this
# repo pins three (0.15.2 / 0.16.0 / master) and a formatter that disagreed across
# them would make the gate a coin flip. It does not: all three flag exactly the
# same 21 files on the pre-format tree, so `$(ZIG)` needs no pin here. The CI step
# runs inside the existing three-toolchain matrix, which keeps re-proving that
# rather than trusting this comment.
#
# --check is the gate; the rewriting form is `fmt-fix` and is not in `check`.
fmt:
	$(ZIG) fmt --check .

fmt-fix:
	$(ZIG) fmt .

# Truncate once here, then let every test binary APPEND. The recorder is a no-op
# when LAZILY_CONFORMANCE_MANIFEST is unset, so a bare `zig build test` (or
# `mise run test`) is unaffected by any of this.
test:
	@mkdir -p $(dir $(CONFORMANCE_MANIFEST)) && : > $(CONFORMANCE_MANIFEST)
	LAZILY_CONFORMANCE_MANIFEST=$(CONFORMANCE_MANIFEST) $(ZIG) build test \
		-Dconformance-manifest=$(CONFORMANCE_MANIFEST)

test-interop-peer:
	$(ZIG) build interop-peer-check

# Verify the formal model (lazily-formal) builds cleanly. This is the
# executable reference behind the state-chart and collection conformance
# fixtures: its theorems prove the behavioral invariants (guard rejection,
# confluence, memo suppression, stale-completion discard, move-minimization)
# that the Zig tests replay as runtime assertions.
#
# The formal model lives in a sibling repo (lazily-formal) checked out
# side-by-side, just like lazily-spec.
test-lean-formal:
	cd "$(LEAN_DIR)" && $(LAKE) build

# Conformance-coverage guard (#portconformancecoverage). RUNTIME: fails when a
# canonical fixture's bytes were never opened by the suite. Depends on `test`
# having just run with the recorder attached — a missing manifest is missing
# evidence and fails.
conformance-coverage: test
	LAZILY_CONFORMANCE_MANIFEST=$(CONFORMANCE_MANIFEST) ./scripts/check-conformance-coverage.sh

# CI-reachability guard (#lzcheckcireachguard). Fails when a target above runs a
# gate no CI workflow step reaches — the drift that hid #lzinteroppeerci in every
# binding for months. It guards itself: `ci-reach` is in `check`, so CI has to
# run it too or this target reports itself missing.
ci-reach:
	./scripts/check-ci-reach.sh
