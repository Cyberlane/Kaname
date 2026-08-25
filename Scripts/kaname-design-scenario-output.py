#!/usr/bin/env python3
"""Resolve one safe screenshot filename from a synthetic-public manifest."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {Path(sys.argv[0]).name} MANIFEST SCENARIO_ID")
    manifest = Path(sys.argv[1])
    identifier = sys.argv[2]
    document = json.loads(manifest.read_text(encoding="utf-8"))
    if document.get("schemaVersion") != 1 or document.get("privacyClass") != "synthetic-public":
        raise SystemExit("The screenshot manifest is not the accepted synthetic-public schema")
    scenarios = document.get("scenarios")
    if not isinstance(scenarios, list):
        raise SystemExit("The screenshot manifest has no scenario list")
    matches = [item for item in scenarios if isinstance(item, dict) and item.get("id") == identifier]
    if len(matches) != 1:
        raise SystemExit(f"Expected exactly one screenshot scenario named {identifier}")
    output = matches[0].get("outputFile")
    if not isinstance(output, str) or re.fullmatch(r"[a-z0-9-]+\.png", output) is None:
        raise SystemExit(f"Scenario {identifier} has an unsafe output filename")
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
