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
test \
test-interop-peer \
test-lean-formal

check: test test-interop-peer test-lean-formal conformance-coverage

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
