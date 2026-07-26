LAKE ?= lake
ZIG ?= zig
LEAN_DIR ?= ../lazily-formal

.PHONY: \
	check \
	test \
	test-lean-formal

check: test test-lean-formal conformance-coverage

test:
	$(ZIG) build test

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

# Conformance-coverage guard (#portconformancecoverage). Static: fails when the
# canonical corpus grows a fixture no test in this repo even names. Naming is not
# replaying — see the script header for what this does and does not prove.
conformance-coverage:
	./scripts/check-conformance-coverage.sh
