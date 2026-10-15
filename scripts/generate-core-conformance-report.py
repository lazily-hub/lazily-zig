#!/usr/bin/env python3
"""Run the Zig Core corpus replay and emit its observed qualification report."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
BINDING_ID = "zig"
WHOLE_FIXTURE_SKIP = "reactive-graph/feedback_drain_bound_reports_exhaustion.json"
PARTIAL_FIXTURE = "reactive-graph/failed_compute_is_never_cached.json"
ASYNC_DIVERGENCE_FIXTURE = "reactive-graph/dispose_signal_reverts_to_lazy.json"
MODELS = ("Context", "ThreadSafeContext", "AsyncContext")


def required_env(name: str) -> Path:
    value = os.environ.get(name)
    if not value:
        raise SystemExit(f"{name} is required")
    return Path(value).resolve()


def load_json(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def pointer_token(value: str) -> str:
    return value.replace("~", "~0").replace("/", "~1")


def assertion_routes(spec_root: Path, required: set[str]) -> dict[str, list[str]]:
    schema = load_json(spec_root / "schemas" / "assertion-blocks.json")
    routes = {fixture: [] for fixture in required}
    for route in schema["x-fixture-routes"]:
        fixture = route["fixture"]
        if fixture in routes:
            routes[fixture].append(route["pointer"])
    missing = sorted(fixture for fixture, pointers in routes.items() if not pointers)
    if missing:
        raise SystemExit(f"Core fixtures have no assertion routes: {', '.join(missing)}")
    return routes


def evidence_reference(route: str, fixture: str) -> str:
    return (
        f"{BINDING_ID}/core-conformance-evidence.json#/fixtures/"
        f"{pointer_token(fixture)}/assertion_blocks/{pointer_token(route)}"
    )


def route_targets(document: object, route: str) -> list[tuple[object, list[str]]]:
    states: list[tuple[object, list[str]]] = [(document, [])]
    for token in route.removeprefix("/").split("/"):
        next_states: list[tuple[object, list[str]]] = []
        for value, pointer in states:
            if token == "*":
                if isinstance(value, list):
                    next_states.extend((item, pointer + [str(i)]) for i, item in enumerate(value))
                elif isinstance(value, dict):
                    next_states.extend((item, pointer + [key]) for key, item in value.items())
            elif isinstance(value, dict) and token in value:
                next_states.append((value[token], pointer + [token]))
        states = next_states
    return states


NON_ASSERTION_KEYS = {"note", "description", "prose", "op", "observationally_equal"}
MAX_MUTANTS_PER_ROUTE = 8


def assertion_leaves(value: object, pointer: list[str]) -> list[tuple[object, object, list[str]]]:
    """Every mutable leaf beneath an assertion block, in document order."""
    leaves: list[tuple[object, object, list[str]]] = []
    if isinstance(value, dict):
        children = [(key, child) for key, child in value.items() if key not in NON_ASSERTION_KEYS]
    elif isinstance(value, list):
        children = [(i, child) for i, child in enumerate(value)]
    else:
        return leaves
    for key, child in children:
        if mutated_scalar(child) is not None:
            leaves.append((value, key, pointer + [str(key)]))
        else:
            leaves.extend(assertion_leaves(child, pointer + [str(key)]))
    return leaves


def mutated_scalar(value: object) -> object | None:
    if isinstance(value, bool):
        return not value
    if isinstance(value, int):
        return value + 1_000_003
    if isinstance(value, float):
        return value + 1_000_003.25
    if isinstance(value, str):
        return value + "__lazily_negative_control__"
    return None


def run_runner(command: list[str], spec_dir: Path, run_id: str, manifest_path: Path) -> subprocess.CompletedProcess[str]:
    manifest_path.write_text("", encoding="utf-8")
    invocation = command + [
        f"-Dconformance-manifest={manifest_path}",
        f"-Dconformance-run-id={run_id}",
    ]
    env = os.environ.copy()
    env.update(
        {
            "LAZILY_SPEC_CONFORMANCE_DIR": str(spec_dir),
            "LAZILY_CONFORMANCE_MANIFEST": str(manifest_path),
            "LAZILY_CONFORMANCE_RUN_ID": run_id,
            "LAZILY_CONFORMANCE_VERBOSE": "1",
        }
    )
    return subprocess.run(invocation, cwd=ROOT, env=env, text=True, capture_output=True)


# A mutant only counts as killed when the library's observed value disagreed with
# the mutated expectation. Every assertion in the runner compares through
# `Engine.check`, which prints a `DIVERGENCE <model>/<fixture>...#<step>:<key> —
# got X, want Y` line under LAZILY_CONFORMANCE_VERBOSE (and the
# `observationally_equal` comparison prints `— scenarios `a` and `b` differ`)
# before the ledger or the assertion tracker fails the run. A mutant is credited
# only for such a line on the mutated fixture that the pristine baseline run did
# not print, so a documented divergence (dispose_signal_reverts_to_lazy on
# AsyncContext) never counts.
#
# Any other non-zero exit proves the runner READ the leaf, not that the assertion
# over it discriminates: renaming a node-id key aborts on the runner's own lookup
# ("names unknown node"), which still names the fixture, and a renamed scenario
# label aborts with "names unknown scenario". Such a mutant is recorded as
# non-discriminating and the next leaf is tried.
DIVERGENCE_LINE = re.compile(
    r"^[ \t]*DIVERGENCE (?:Context|ThreadSafeContext|AsyncContext)/"
    r"(?P<fixture>[^\s/\[#]+\.json)(?:\[[^\]\s]+\])?#\S+ \u2014 "
    r"(?:got .*, want .*|scenarios `[^`]*` and `[^`]*` differ)$",
    re.MULTILINE,
)


def divergence_lines(output: str, fixture: str, baseline: str = "") -> list[str]:
    """Library-divergence lines on `fixture` that the pristine run did not print."""
    name = Path(fixture).name

    def lines(text: str) -> list[str]:
        return [
            match.group(0).strip()
            for match in DIVERGENCE_LINE.finditer(text)
            if match.group("fixture") == name
        ]

    already = set(lines(baseline))
    return [line for line in lines(output) if line not in already]


def failure_excerpt(output: str, fixture: str) -> list[str]:
    """What a non-discriminating mutant failed on, without the verbose progress lines."""
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    named = [
        line for line in lines
        if Path(fixture).name in line and not line.startswith(("reactive-graph[", "SKIP ", "DIVERGENCE "))
    ]
    return (named or [line for line in lines if line.startswith("error:")] or lines)[:3]


def kill_route(
    command: list[str],
    mutation_root: Path,
    fixture: str,
    route: str,
    canonical: str,
    control_id: str,
    control_manifest: Path,
    baseline: str,
    runner=None,
) -> dict:
    runner = runner or run_runner
    fixture_path = mutation_root / fixture
    pristine = json.loads(canonical)
    targets = route_targets(pristine, route)
    if not targets:
        raise SystemExit(f"negative control route {route} did not resolve in {fixture}")
    leaf_count = sum(len(assertion_leaves(target, pointer)) for target, pointer in targets)
    if leaf_count == 0:
        raise SystemExit(f"negative control route {route} has no comparable leaf in {fixture}")
    not_discriminating: list[dict] = []
    try:
        for attempt in range(min(leaf_count, MAX_MUTANTS_PER_ROUTE)):
            # A fresh parse per attempt: exactly one leaf differs from the corpus.
            document = json.loads(canonical)
            leaves = [
                leaf
                for target, pointer in route_targets(document, route)
                for leaf in assertion_leaves(target, pointer)
            ]
            container, key, leaf_pointer = leaves[attempt]
            original = container[key]
            mutated = mutated_scalar(original)
            container[key] = mutated
            json_pointer = "/" + "/".join(pointer_token(token) for token in leaf_pointer)
            fixture_path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
            rejected = runner(command, mutation_root, f"{control_id}-{attempt}", control_manifest)
            output = rejected.stdout + rejected.stderr
            if rejected.returncode == 0:
                raise SystemExit(f"negative control survived for {fixture} {route} at {json_pointer}")
            findings = divergence_lines(output, fixture, baseline)
            mutant = {
                "mutated_pointer": json_pointer,
                "original": original,
                "mutated": mutated,
                "runner_exit_code": rejected.returncode,
            }
            if findings:
                return {
                    "status": "mutation-killed",
                    "route": route,
                    **mutant,
                    "rejected_by": "divergence",
                    "rejection_excerpt": findings[:3],
                    "non_discriminating_mutants": not_discriminating,
                }
            not_discriminating.append({
                **mutant,
                "rejected_by": "other_failure",
                "rejection_excerpt": failure_excerpt(output, fixture),
            })
    finally:
        fixture_path.write_text(canonical, encoding="utf-8")
    raise SystemExit(
        f"negative control route {route} in {fixture}: no mutated assertion leaf was rejected by a "
        f"library divergence ({len(not_discriminating)} mutant(s) failed for another reason: "
        f"{[item['mutated_pointer'] for item in not_discriminating]})"
    )


def main() -> int:
    profile_path = required_env("LAZILY_CORE_PROFILE_PATH")
    spec_root = required_env("LAZILY_CORE_SPEC_ROOT")
    reports_root = required_env("LAZILY_CORE_REPORTS_ROOT")
    report_path = required_env("LAZILY_CORE_REPORT_PATH")
    binding_id = os.environ.get("LAZILY_CORE_BINDING_ID", BINDING_ID)
    if binding_id != BINDING_ID:
        raise SystemExit(f"expected binding id {BINDING_ID!r}, got {binding_id!r}")

    profile = load_json(profile_path)
    binding = next(item for item in profile["bindings"] if item["id"] == BINDING_ID)
    required = set(binding["required_fixtures"])
    routes = assertion_routes(spec_root, required)
    declaration = load_json(ROOT / "scripts" / "core-conformance.json")
    run_id = f"core-{time.time_ns()}-{os.getpid()}"

    (ROOT / "build").mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="lazily-zig-core-", dir=ROOT / "build") as raw_tmp:
        tmp = Path(raw_tmp)
        manifest_path = tmp / "manifest.txt"
        command = [
            os.environ.get("ZIG", "zig"),
            "build",
            "core-conformance",
        ]
        result = run_runner(command, spec_root / "conformance", run_id, manifest_path)
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        if result.returncode != 0:
            return result.returncode
        manifest = manifest_path.read_text(encoding="utf-8")

        mutation_root = tmp / "negative-control-corpus"
        shutil.copytree(spec_root / "conformance", mutation_root)
        negative_controls: dict[str, dict[str, dict]] = {}
        for fixture in sorted(required - {WHOLE_FIXTURE_SKIP}):
            fixture_path = mutation_root / fixture
            canonical = fixture_path.read_text(encoding="utf-8")
            negative_controls[fixture] = {}
            for index, route in enumerate(routes[fixture]):
                negative_controls[fixture][route] = kill_route(
                    command,
                    mutation_root,
                    fixture,
                    route,
                    canonical,
                    f"{run_id}-negative-{len(negative_controls)}-{index}",
                    tmp / f"negative-{len(negative_controls)}-{index}.txt",
                    result.stdout + result.stderr,
                )

    absent = sorted(path for path in required if path not in manifest)
    if absent:
        raise SystemExit(f"Core runner did not open required fixtures: {', '.join(absent)}")
    combined_output = result.stdout + result.stderr
    for fixture in sorted(required - {WHOLE_FIXTURE_SKIP, PARTIAL_FIXTURE, ASYNC_DIVERGENCE_FIXTURE}):
        name = Path(fixture).name
        for model in MODELS:
            marker = f"reactive-graph[{model}] {name}:"
            if marker not in combined_output:
                raise SystemExit(f"Core runner did not prove {fixture} on {model}")
    partial_name = Path(PARTIAL_FIXTURE).name
    if f"reactive-graph[Context] {partial_name}:" not in combined_output:
        raise SystemExit(f"Core runner did not prove {PARTIAL_FIXTURE} on Context")
    for model in ("ThreadSafeContext", "AsyncContext"):
        if f"SKIP reactive-graph[{model}] {partial_name}:" not in combined_output:
            raise SystemExit(f"Core runner did not report the declared {model} skip for {PARTIAL_FIXTURE}")
    divergence_name = Path(ASYNC_DIVERGENCE_FIXTURE).name
    for model in ("Context", "ThreadSafeContext", "AsyncContext"):
        if f"reactive-graph[{model}] {divergence_name}:" not in combined_output:
            raise SystemExit(f"Core runner did not exercise {ASYNC_DIVERGENCE_FIXTURE} on {model}")
    divergence_marker = f"DIVERGENCE AsyncContext/{divergence_name}#3:computes_of.sig"
    if divergence_marker not in combined_output:
        raise SystemExit(f"Core runner did not report the declared AsyncContext divergence for {ASYNC_DIVERGENCE_FIXTURE}")
    skipped_name = Path(WHOLE_FIXTURE_SKIP).name
    for model in MODELS:
        if f"SKIP reactive-graph[{model}] {skipped_name}:" not in combined_output:
            raise SystemExit(f"Core runner did not report the declared {model} skip for {WHOLE_FIXTURE_SKIP}")

    evidence_path = reports_root / BINDING_ID / "core-conformance-evidence.json"
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    evidence = {
        "schema_version": 1,
        "binding_id": BINDING_ID,
        "run_id": run_id,
        "command": command,
        "exit_code": result.returncode,
        "manifest": manifest.splitlines(),
        "negative_controls": negative_controls,
        "fixtures": {},
    }
    definitions = {item["path"]: item for item in profile["required_fixtures"]}
    fixtures = []
    for fixture in binding["required_fixtures"]:
        definition = definitions[fixture]
        status = (
            "skipped"
            if fixture == WHOLE_FIXTURE_SKIP
            else "partial"
            if fixture in {PARTIAL_FIXTURE, ASYNC_DIVERGENCE_FIXTURE}
            else "passed"
        )
        blocks = (
            {}
            if status == "skipped"
            else {
                route: {
                    "status": "mutation-killed",
                    "mechanism": "runtime comparison to the canonical fixture expectation with unconsumed-key guards",
                    "negative_control": negative_controls[fixture][route],
                    "runner_exit_code": result.returncode,
                    "run_id": run_id,
                }
                for route in routes[fixture]
            }
        )
        evidence["fixtures"][fixture] = {
            "status": status,
            "models": (
                ["Context", "ThreadSafeContext"]
                if fixture == ASYNC_DIVERGENCE_FIXTURE
                else ["Context"]
                if fixture == PARTIAL_FIXTURE
                else []
                if status == "skipped"
                else list(MODELS)
            ),
            "assertion_blocks": blocks,
        }
        fixtures.append(
            {
                "path": fixture,
                "scenario_ids": [] if status == "skipped" else definition["scenario_ids"],
                "proof_classes": definition["proof_classes"],
                "assertion_blocks": []
                if status == "skipped"
                else [
                    {
                        "id": route,
                        "consumed": True,
                        "discriminability_evidence": evidence_reference(route, fixture),
                    }
                    for route in routes[fixture]
                ],
                "status": status,
            }
        )

    evidence_path.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    report = {
        "schema_version": 1,
        "profile_id": profile["profile_id"],
        "binding_id": BINDING_ID,
        "fixture_corpus_digest": profile["fixture_corpus"]["digest"],
        "fixtures": fixtures,
        "runtime_skips": declaration["runtime_skips"],
        "fixtureless_claims": [
            {
                "id": "c_abi_ffi_boundary",
                "proof_classes": ["native_artifact_consumer"],
                "passed": True,
                "evidence": "zig/core-c-abi.json",
            }
        ],
    }
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {report_path} (13 passed, 2 partial, 1 skipped)")
    return 0


def self_test() -> int:
    """Prove a negative control is credited only for a library divergence.

    Runs without zig: the runner is replaced by a fake whose output reproduces the
    runner's real lines, measured against `zig build core-conformance` on
    2026-10-15 with LAZILY_CONFORMANCE_VERBOSE=1.
    """
    documented = (
        "         DIVERGENCE AsyncContext/target.json#3:computes_of.sig \u2014 got 2, want 1\n"
    )

    def bookkeeping(name: str) -> str:
        return (
            documented
            + f"       reactive-graph[Context] {name}: 19 ops, 32 assertions\n"
            + f"  Context/{name}[scope_teardown]: names unknown node `a__lazily_negative_control__`\n"
            + "error: UnknownNodeId\n"
        )

    def divergence(name: str) -> str:
        return (
            documented
            + f"         DIVERGENCE Context/{name}[scope_teardown]#9999:final.readable.topic "
            + "\u2014 got true, want false\n"
            + "       reactive-graph expected tail: inside object-valued key 'readable': "
            + "assertion key 'topic' want false, got true (#lzconsumednotasserted)\n"
        )

    target = "reactive-graph/target.json"
    classifier_cases = [
        (bookkeeping("target.json"), False),
        ("  `observationally_equal` names unknown scenario `s1__lazily_negative_control__`\n", False),
        ("reactive-graph[Context] target.json: 6 ops, 6 assertions\nerror: TestUnexpectedResult\n", False),
        # Present in the pristine run too: a documented divergence is not a kill.
        (documented + "  documented divergence AsyncContext/target.json#3:computes_of.sig no longer reproduces\n", False),
        ("  undocumented divergence Context/target.json#1:value \u2014 got 1, want 2\n", False),
        (divergence("other.json"), False),
        (divergence("target.json"), True),
        ("  DIVERGENCE AsyncContext/target.json#1:dependents_of.topic \u2014 got 8, want 1000011\n", True),
        (
            "  DIVERGENCE Context/target.json#expected:observationally_equal "
            "\u2014 scenarios `s1` and `s2` differ\n    dep[a]=1;\n    dep[a]=2;\n",
            True,
        ),
    ]
    for output, want in classifier_cases:
        got = bool(divergence_lines(output, target, documented))
        if got != want:
            raise SystemExit(f"self-test: divergence_lines({output.strip()!r}) = {got}, want {want}")

    def drive(expected: dict, verdict) -> dict:
        def fake_runner(command, spec_dir, run_id, manifest_path):
            document = json.loads((spec_dir / target).read_text(encoding="utf-8"))
            output = verdict(document["expected"])
            return subprocess.CompletedProcess(command, 0 if output is None else 1, stdout=output or "", stderr="")

        with tempfile.TemporaryDirectory(prefix="core-report-self-test-") as raw:
            root = Path(raw)
            canonical = json.dumps({"expected": expected}, indent=2) + "\n"
            (root / target).parent.mkdir(parents=True)
            (root / target).write_text(canonical, encoding="utf-8")
            try:
                return kill_route(["fake"], root, target, "/expected", canonical, "self-test",
                                  root / "manifest.txt", documented, runner=fake_runner)
            finally:
                if (root / target).read_text(encoding="utf-8") != canonical:
                    raise SystemExit("self-test: kill_route left a mutated fixture behind")

    # Node-id leaves (`cleanup_order`) fail on the runner's own lookup; only a
    # mutated `readable` value is a library divergence.
    def by_leaf(expected: dict) -> str | None:
        if any(item.endswith("__lazily_negative_control__") for item in expected.get("cleanup_order", [])):
            return bookkeeping("target.json")
        return divergence("target.json")

    result = drive({"cleanup_order": ["a", "b"], "readable": {"topic": True}}, by_leaf)
    if result["rejected_by"] != "divergence" or result["mutated_pointer"] != "/expected/readable/topic":
        raise SystemExit(f"self-test: a bookkeeping failure was credited: {result['mutated_pointer']}")
    skipped = [item["mutated_pointer"] for item in result["non_discriminating_mutants"]]
    if skipped != ["/expected/cleanup_order/0", "/expected/cleanup_order/1"]:
        raise SystemExit(f"self-test: non-discriminating mutants not recorded: {skipped}")

    for ids in (["a", "b"], [f"n{i}" for i in range(12)]):
        try:
            drive({"cleanup_order": ids}, by_leaf)
        except SystemExit as error:
            message = str(error)
            if "no mutated assertion leaf was rejected by a library divergence" not in message:
                raise
            if message.count("/expected/cleanup_order/") != min(len(ids), MAX_MUTANTS_PER_ROUTE):
                raise SystemExit(f"self-test: wrong mutant count for {len(ids)} leaves: {message}")
        else:
            raise SystemExit("self-test: a route with no divergence kill was credited")

    try:
        drive({"readable": {"topic": True}}, lambda expected: None)
    except SystemExit as error:
        if "negative control survived" not in str(error):
            raise
    else:
        raise SystemExit("self-test: a surviving mutant was not reported")

    print(f"core report self-test OK ({len(classifier_cases)} classifier cases, 4 routes)")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        raise SystemExit(self_test())
    raise SystemExit(main())
