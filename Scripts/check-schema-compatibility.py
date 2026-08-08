#!/usr/bin/env python3
"""Reject incompatible edits to Kaname's checked-in proto surface.

This intentionally small, dependency-free guard protects names/numbers/types
that have shipped in the v1 descriptor. It allows additions; protocol reviews
remain responsible for semantic compatibility.
"""
from __future__ import annotations

import json
import pathlib
import re
import sys
import argparse

ROOT = pathlib.Path(__file__).resolve().parent.parent
MESSAGE = re.compile(r"^message\s+(\w+)\s*\{")
FIELD = re.compile(r"^(?:repeated\s+)?([.\w]+)\s+(\w+)\s*=\s*(\d+)\s*;")
ENUM = re.compile(r"^enum\s+(\w+)\s*\{")
ENUM_VALUE = re.compile(r"^(\w+)\s*=\s*(\d+)\s*;")


def surface(proto_root: pathlib.Path) -> dict[str, dict[str, dict[str, str]]]:
    result: dict[str, dict[str, dict[str, str]]] = {"messages": {}, "enums": {}}
    current: tuple[str, str] | None = None
    for path in sorted(proto_root.glob("*.proto")):
        for line in path.read_text().splitlines():
            stripped = line.split("//", 1)[0].strip()
            found = MESSAGE.match(stripped)
            if found:
                current = ("messages", f"{path.stem}.{found.group(1)}")
                result[current[0]][current[1]] = {}
                continue
            found = ENUM.match(stripped)
            if found:
                current = ("enums", f"{path.stem}.{found.group(1)}")
                result[current[0]][current[1]] = {}
                continue
            if stripped == "}":
                current = None
                continue
            if current is None:
                continue
            match = FIELD.match(stripped) if current[0] == "messages" else ENUM_VALUE.match(stripped)
            if not match:
                continue
            if current[0] == "messages":
                field_type, name, number = match.groups()
                result[current[0]][current[1]][number] = f"{field_type} {name}"
            else:
                name, number = match.groups()
                result[current[0]][current[1]][number] = name
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--proto-root", type=pathlib.Path, default=ROOT / "proto" / "kaname" / "v1")
    parser.add_argument("--baseline", type=pathlib.Path, default=ROOT / "Schema" / "compatibility-baseline.json")
    parser.add_argument("--write-baseline", action="store_true")
    arguments = parser.parse_args()
    current = surface(arguments.proto_root)
    if arguments.write_baseline:
        arguments.baseline.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n")
        return 0
    baseline = json.loads(arguments.baseline.read_text())
    failures: list[str] = []
    for category, definitions in baseline.items():
        for name, members in definitions.items():
            actual = current.get(category, {}).get(name, {})
            for number, value in members.items():
                if actual.get(number) != value:
                    failures.append(f"{category[:-1]} {name} field/value {number} changed from {value!r} to {actual.get(number)!r}")
    if failures:
        print("incompatible schema edit:", *failures, sep="\n- ", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
