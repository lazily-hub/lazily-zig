#!/usr/bin/env python3
"""Fail closed when the focused Zig Core surface drifts from its snapshot."""

from __future__ import annotations

import dataclasses
import pathlib
import re
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
SNAPSHOT = ROOT / "api" / "core-v1.tsv"
CORE = ROOT / "src" / "core.zig"
DECLARATION = re.compile(r"^pub const ([A-Za-z_][A-Za-z0-9_]*) = (.+);$")


@dataclasses.dataclass(frozen=True)
class Symbol:
    capability: str
    kind: str
    path: str
    signature: str
    introduced: int
    replacement: str
    window: int | None
    removal: int | None

    @property
    def name(self) -> str:
        return self.path.rsplit(".", 1)[-1]


def optional_generation(value: str) -> int | None:
    return None if value == "-" else int(value)


def parse_snapshot(text: str) -> tuple[int, int, list[Symbol]]:
    lines = [line for line in text.splitlines() if line]
    if not lines or lines[0] != "# lazily-core-api-v1":
        raise ValueError("missing # lazily-core-api-v1 header")
    if len(lines) < 3:
        raise ValueError("snapshot is missing generation metadata")
    generation = int(lines[1].removeprefix("generation\t"))
    window = int(lines[2].removeprefix("deprecation_window_generations\t"))
    symbols: list[Symbol] = []
    for number, line in enumerate(lines[3:], 4):
        fields = line.split("\t")
        if len(fields) != 9 or fields[0] != "symbol":
            raise ValueError(f"line {number}: expected a nine-column symbol record")
        symbol = Symbol(
            capability=fields[1],
            kind=fields[2],
            path=fields[3],
            signature=fields[4],
            introduced=int(fields[5]),
            replacement=fields[6],
            window=optional_generation(fields[7]),
            removal=optional_generation(fields[8]),
        )
        if symbol.introduced > generation:
            raise ValueError(f"{symbol.path}: introduced after current generation")
        deprecated = symbol.replacement != "-" or symbol.window is not None or symbol.removal is not None
        if deprecated:
            if symbol.replacement == "-" or symbol.window is None or symbol.removal is None:
                raise ValueError(f"{symbol.path}: incomplete deprecation lifecycle")
            if symbol.window < window:
                raise ValueError(f"{symbol.path}: deprecation window is shorter than policy")
            if symbol.removal < symbol.introduced + symbol.window:
                raise ValueError(f"{symbol.path}: earliest removal precedes compatibility window")
        symbols.append(symbol)
    names = [symbol.name for symbol in symbols]
    if len(names) != len(set(names)):
        raise ValueError("duplicate Core symbol records")
    return generation, window, symbols


def native_surface(text: str) -> list[tuple[str, str]]:
    declarations: list[tuple[str, str]] = []
    for line in text.splitlines():
        match = DECLARATION.match(line)
        if match:
            declarations.append((match.group(1), match.group(2)))
    return declarations


def validate(snapshot: str, core: str) -> None:
    _, _, symbols = parse_snapshot(snapshot)
    committed = [(symbol.name, symbol.signature) for symbol in symbols]
    actual = native_surface(core)
    if committed != actual:
        raise ValueError(
            "Core API snapshot drift; update api/core-v1.tsv intentionally\n"
            f"committed={committed!r}\nactual={actual!r}"
        )


def negative_self_test(snapshot: str, core: str) -> None:
    mutations = {
        "symbol removal": snapshot.replace("lazily_core.Source", "lazily_core.RemovedSource", 1),
        "incomplete deprecation": snapshot.replace("\t1\t-\t-\t-", "\t1\tlazily_core.source\t-\t-", 1),
    }
    for label, mutation in mutations.items():
        try:
            validate(mutation, core)
        except ValueError:
            continue
        raise AssertionError(f"negative self-test did not reject {label}")


def main() -> int:
    snapshot = SNAPSHOT.read_text(encoding="utf-8")
    core = CORE.read_text(encoding="utf-8")
    try:
        validate(snapshot, core)
        negative_self_test(snapshot, core)
    except (AssertionError, ValueError) as error:
        print(f"core API compatibility check failed: {error}", file=sys.stderr)
        return 1
    print("core API compatibility check passed (snapshot + deprecation schema + negative self-test)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
