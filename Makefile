LAKE ?= lake
ZIG ?= zig
LEAN_DIR ?= ../lazily-formal

.PHONY: \
	check \
	test \
	test-lean-formal

check: test test-lean-formal

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
