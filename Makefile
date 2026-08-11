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
assertion-ordering-check \
ci-reach

check: fmt test test-interop-peer test-lean-formal conformance-coverage assertion-ordering-check ci-reach

assertion-ordering-check:
	python3 ../lazily-spec/scripts/check-assertion-ordering.py --binding zig --root .

# The formatting GATE (#lazilydartzig, #lzzigfmttoolchains). This binding had no
# formatting floor at all — nothing in `check`, nothing in CI — so drift was
# invisible until someone read a diff.
#
# `zig fmt` is canonical and ships with the toolchain, so adopting it costs no new
# dependency. The real question is WHICH toolchain's `zig fmt`, because this repo
# pins three (0.15.2 / 0.16.0 / master) and they DO NOT all produce the same
# bytes. The claim that used to sit here — "all three flag exactly the same 21
# files" — was an observation on ONE tree, not a property of the formatters, and
# it is false as a general statement: 0.15.2 and 0.16.0 disagree about a multiline
# string literal spliced inline with `++` inside a `return`, and neither output is
# a fixed point of the other. 5bea17c restructured the one construct that tripped
# it; this target is what stops the next one reaching CI.
#
# So the gate is not `$(ZIG) fmt --check .`. It is every pinned RELEASE toolchain
# in the CI matrix, resolved and version-verified, with any that is missing NAMED
# and fatal — "checked 1 of 2" must never report OK. `master` is advisory only: it
# is a moving nightly, so a local `master` and CI's `master` are different
# compilers and a gate on it is a coin flip. CI runs this same script over both
# pinned releases in one job.
#
# GUARANTEED by a green `make fmt`: this tree is accepted byte-for-byte by zig fmt
# 0.15.2 AND 0.16.0. NOT guaranteed: anything about master, or about any zig
# release this repo does not pin.
#
# --check is the gate; the rewriting form is `fmt-fix` and is not in `check`.
fmt:
	./scripts/check-fmt.sh

# Rewrites with $(ZIG) — ONE toolchain, by construction. It cannot fix a
# cross-toolchain disagreement, because for such a construct there is no
# formatting all pinned releases accept: run `make fmt` afterwards and restructure
# whatever it still names.
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
