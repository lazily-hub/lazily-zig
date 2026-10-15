#!/usr/bin/env python3
"""Build lazily's shared library and invoke its exported Core ABI probe."""

from __future__ import annotations

import ctypes
import json
import os
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parent.parent


def main() -> int:
    evidence_raw = os.environ.get("LAZILY_CORE_EVIDENCE_PATH")
    if not evidence_raw:
        raise SystemExit("LAZILY_CORE_EVIDENCE_PATH is required")
    evidence = Path(evidence_raw).resolve()
    zig = os.environ.get("ZIG", "zig")
    command = [zig, "build", "core-c-abi-artifact", "-Doptimize=ReleaseSafe"]
    subprocess.run(command, cwd=ROOT, check=True)

    candidates = sorted((ROOT / "zig-out" / "lib").glob("*lazily*"))
    libraries = [path for path in candidates if path.suffix in {".so", ".dylib", ".dll"}]
    if len(libraries) != 1:
        raise SystemExit(f"expected one built lazily shared library, found: {libraries}")
    library = libraries[0]
    consumer = ctypes.CDLL(str(library))
    probe = consumer.lazily_core_abi_version
    probe.argtypes = []
    probe.restype = ctypes.c_uint32
    version = int(probe())
    if version != 1:
        raise SystemExit(f"lazily_core_abi_version returned {version}, expected 1")

    evidence.parent.mkdir(parents=True, exist_ok=True)
    evidence.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "claim_id": os.environ.get("LAZILY_CORE_CLAIM_ID"),
                "build_command": command,
                "artifact": str(library.relative_to(ROOT)),
                "consumer": "python ctypes.CDLL",
                "symbol": "lazily_core_abi_version",
                "returned_core_api_generation": version,
                "passed": True,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
