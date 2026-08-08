#!/usr/bin/env python3
"""Generate/check deterministic fake-corpus checksums without private data."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCENARIOS = ROOT / "Fixtures" / "scenarios"
EXPECTED = ROOT / "Fixtures" / "expected" / "v1"
MANIFEST = ROOT / "Fixtures" / "corpus-manifest.json"

def entry(path: Path, category: str) -> dict[str, str]:
    return {
        "category": category,
        "path": str(path.relative_to(ROOT)),
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }

def generate() -> bytes:
    manifest = {
        "corpusVersion": 1,
        "scenarioCount": 14,
        "scaleFixtures": {
            "S-01": 500,
            "S-02": 10000,
            "S-03": 100000,
            "S-04": 1000,
        },
        "entries": [
            *(entry(path, "scenario") for path in sorted(SCENARIOS.glob("F-*.json"))),
            *(entry(path, "expected") for path in sorted(EXPECTED.glob("F-*.json"))),
        ],
    }
    return (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()

parser = argparse.ArgumentParser()
parser.add_argument("mode", choices=("generate", "check"), nargs="?", default="check")
arguments = parser.parse_args()
payload = generate()
if arguments.mode == "generate":
    MANIFEST.write_bytes(payload)
elif MANIFEST.read_bytes() != payload:
    raise SystemExit("corpus manifest is stale; run Scripts/generate-corpus-manifest.py generate")
