#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import stat
import struct
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
TOKENS = ROOT / "DesignSystem" / "kaname.tokens.json"
WORKING_SNAPSHOT_ALGORITHM = "sha256-git-delta-path-mode-content-v1"


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git(*arguments: str, root: Path = ROOT) -> bytes:
    return subprocess.check_output(["git", *arguments], cwd=root)


def working_snapshot_digest(root: Path = ROOT) -> str:
    """Hash working-tree content without depending on the real index state."""
    value = hashlib.sha256()
    value.update(WORKING_SNAPSHOT_ALGORITHM.encode("ascii") + b"\0")
    changed = git(
        "diff", "--name-only", "--no-renames", "-z", "HEAD", "--", root=root
    ).split(b"\0")
    untracked = git(
        "ls-files", "--others", "--exclude-standard", "-z", root=root
    ).split(b"\0")
    for raw_path in sorted(set(path for path in (*changed, *untracked) if path)):
        path = root / os.fsdecode(raw_path)
        value.update(len(raw_path).to_bytes(8, "big"))
        value.update(raw_path)
        try:
            file_stat = path.lstat()
        except FileNotFoundError:
            mode = b"000000"
            content = b""
        else:
            if stat.S_ISREG(file_stat.st_mode):
                mode = b"100755" if file_stat.st_mode & 0o111 else b"100644"
                content = path.read_bytes()
            elif stat.S_ISLNK(file_stat.st_mode):
                mode = b"120000"
                content = os.fsencode(os.readlink(path))
            elif stat.S_ISDIR(file_stat.st_mode):
                mode = b"160000"
                content = git("-C", str(path), "rev-parse", "HEAD", root=root).strip()
            else:
                raise RuntimeError(f"Unsupported working-tree entry: {path}")
        value.update(mode)
        value.update(len(content).to_bytes(8, "big"))
        value.update(content)
    return value.hexdigest()


def png_dimensions(data: bytes) -> tuple[int, int]:
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("Screenshot receipt input is not a PNG")
    return struct.unpack(">II", data[16:24])


def scenario_from(path: Path, identifier: str) -> dict[str, Any]:
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("privacyClass") != "synthetic-public":
        raise SystemExit("Screenshot manifest is not synthetic-public")
    matches = [item for item in document.get("scenarios", []) if item.get("id") == identifier]
    if len(matches) != 1:
        raise SystemExit(f"Expected exactly one screenshot scenario named {identifier}")
    scenario = matches[0]
    if scenario.get("privacyClass") != "synthetic-public":
        raise SystemExit(f"Screenshot scenario is not synthetic-public: {identifier}")
    return scenario


def main() -> int:
    parser = argparse.ArgumentParser(description="Write a provenance sidecar for a Kaname design screenshot.")
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--scenario", required=True)
    parser.add_argument("--image", required=True, type=Path)
    parser.add_argument("--capture-method", required=True)
    parser.add_argument("--renderer", required=True)
    parser.add_argument("--target-runtime")
    arguments = parser.parse_args()

    manifest = arguments.manifest.resolve()
    image = arguments.image.resolve()
    if not manifest.is_file() or not image.is_file() or not image.is_absolute():
        raise SystemExit("Manifest and absolute PNG path must exist")
    scenario = scenario_from(manifest, arguments.scenario)
    image_data = image.read_bytes()
    width, height = png_dimensions(image_data)
    token_document = json.loads(TOKENS.read_text(encoding="utf-8"))
    receipt = {
        "schemaVersion": 1,
        "capturedAt": datetime.now(timezone.utc).isoformat(),
        "source": {
            "head": git("rev-parse", "HEAD").decode().strip(),
            "branch": git("branch", "--show-current").decode().strip(),
            "workingSnapshotAlgorithm": WORKING_SNAPSHOT_ALGORITHM,
            "workingSnapshotSHA256": working_snapshot_digest(),
        },
        "designSystem": {
            "version": token_document["metadata"]["version"],
            "tokenSHA256": digest(TOKENS.read_bytes()),
            "manifestSHA256": digest(manifest.read_bytes()),
        },
        "scenario": scenario,
        "capture": {
            "method": arguments.capture_method,
            "renderer": arguments.renderer,
            "hostOS": platform.mac_ver()[0],
            "targetRuntime": arguments.target_runtime,
        },
        "image": {
            "file": image.name,
            "widthPixels": width,
            "heightPixels": height,
            "bytes": len(image_data),
            "sha256": digest(image_data),
        },
    }
    receipt_path = image.with_suffix(".receipt.json")
    receipt_path.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote screenshot provenance receipt: {receipt_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
