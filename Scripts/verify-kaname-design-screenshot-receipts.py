#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import runpy
import subprocess
from pathlib import Path
from typing import Any

from kaname_design_screenshot_png import png_dimensions


ROOT = Path(__file__).resolve().parent.parent
TOKENS = ROOT / "DesignSystem" / "kaname.tokens.json"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def is_sha256(value: Any) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def git(*arguments: str) -> str:
    return subprocess.check_output(["git", *arguments], cwd=ROOT, text=True).strip()


def read_manifest(path: Path) -> list[dict[str, Any]]:
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("schemaVersion") != 1 or document.get("privacyClass") != "synthetic-public":
        raise SystemExit(f"Unsupported or non-public manifest: {path}")
    return document.get("scenarios", [])


def verify_pair(
    scenario: dict[str, Any],
    manifest: Path,
    directory: Path,
    current_head: str,
    current_branch: str,
    current_snapshot_algorithm: str,
    current_snapshot: str,
    failures: list[str],
) -> tuple[str | None, str | None]:
    identifier = scenario.get("id", "<unknown>")
    image_path = directory / str(scenario.get("outputFile", ""))
    receipt_path = image_path.with_suffix(".receipt.json")
    require(image_path.is_file(), f"missing image for {identifier}: {image_path.name}", failures)
    require(receipt_path.is_file(), f"missing receipt for {identifier}: {receipt_path.name}", failures)
    if not image_path.is_file() or not receipt_path.is_file():
        return None, None

    try:
        image_data = image_path.read_bytes()
        width, height = png_dimensions(image_data)
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
    except (OSError, ValueError, json.JSONDecodeError) as error:
        failures.append(f"unreadable evidence for {identifier}: {error}")
        return None, None

    require(isinstance(receipt, dict), f"{identifier} receipt must be a JSON object", failures)
    if not isinstance(receipt, dict):
        return None, None
    require(receipt.get("schemaVersion") == 2, f"{identifier} receipt must use schema 2", failures)
    require(receipt.get("scenario") == scenario, f"{identifier} receipt scenario drifted from manifest", failures)
    source = receipt.get("source", {})
    if not isinstance(source, dict):
        source = {}
    require(source.get("head") == current_head, f"{identifier} receipt HEAD is stale", failures)
    require(source.get("branch") == current_branch, f"{identifier} receipt branch is stale", failures)
    require(
        source.get("workingSnapshotAlgorithm") == current_snapshot_algorithm,
        f"{identifier} working snapshot algorithm is unsupported",
        failures,
    )
    snapshot = source.get("workingSnapshotSHA256")
    require(snapshot == current_snapshot, f"{identifier} working snapshot does not match current source", failures)
    design_system = receipt.get("designSystem", {})
    if not isinstance(design_system, dict):
        design_system = {}
    require(design_system.get("version") == json.loads(TOKENS.read_text(encoding="utf-8"))["metadata"]["version"], f"{identifier} design-system version drifted", failures)
    require(design_system.get("tokenSHA256") == sha256(TOKENS.read_bytes()), f"{identifier} token hash drifted", failures)
    require(design_system.get("manifestSHA256") == sha256(manifest.read_bytes()), f"{identifier} manifest hash drifted", failures)

    image = receipt.get("image", {})
    if not isinstance(image, dict):
        image = {}
    require(image.get("file") == image_path.name, f"{identifier} image filename drifted", failures)
    require(image.get("bytes") == len(image_data), f"{identifier} image byte count drifted", failures)
    image_hash = sha256(image_data)
    require(image.get("sha256") == image_hash, f"{identifier} image hash drifted", failures)
    require((image.get("widthPixels"), image.get("heightPixels")) == (width, height), f"{identifier} image dimensions drifted", failures)
    require(scenario.get("privacyClass") == "synthetic-public", f"{identifier} is not synthetic-public", failures)
    evidence_class = scenario.get("evidenceClass")
    if str(scenario.get("surface", "")).startswith("catalog."):
        require(
            evidence_class in {"implemented", "fixture-projection", "scaffolded-gap"},
            f"{identifier} has an unsupported catalog evidence class",
            failures,
        )
    else:
        require(evidence_class == "fixture-projection", f"{identifier} overstates product evidence", failures)

    if scenario.get("surface", "").startswith("desktop."):
        runtime = receipt.get("desktopRuntimeEvidence", {})
        if not isinstance(runtime, dict):
            runtime = {}
        require(runtime.get("channel") == "development", f"{identifier} was not captured from Development", failures)
        require(runtime.get("bundleIdentifier") == "com.cyberlane.kaname.desktop.dev", f"{identifier} has the wrong bundle identity", failures)
        require(type(runtime.get("launcherReceiptSchemaVersion")) is int and runtime["launcherReceiptSchemaVersion"] in {1, 2, 3}, f"{identifier} lacks a supported launcher receipt schema version", failures)
        require(type(runtime.get("processID")) is int and runtime["processID"] > 0, f"{identifier} lacks a historical PID", failures)
        require(type(runtime.get("windowID")) is int and runtime["windowID"] > 0, f"{identifier} lacks a historical window ID", failures)
        require(runtime.get("preActionVerificationPassed") is True, f"{identifier} lacks pre-action verification", failures)
        require(runtime.get("postActionVerificationPassed") is True, f"{identifier} lacks post-action verification", failures)
        require(is_sha256(runtime.get("launcherReceiptSHA256")), f"{identifier} lacks a launcher receipt hash", failures)
        executable = str(runtime.get("canonicalExecutablePath", ""))
        require(executable.endswith("/.build/Kaname Prototype.app/Contents/MacOS/KanamePrototype"), f"{identifier} executable path is not task-canonical", failures)
    return (snapshot if isinstance(snapshot, str) else None), image_hash


TEXT_SCALE_COMPARISON_AXES = (
    "platform",
    "surface",
    "captureVariant",
    "fixture",
    "viewport",
    "appearance",
    "differentiateWithoutColor",
    "reduceMotion",
    "activeWindow",
    "locale",
)

TEXT_SCALE_VARIANT_PAIRS = (
    ("desktop-home-statuses", "desktop-home-statuses-large-text"),
    ("ios-project-github-statuses", "ios-project-github-statuses-large-text"),
    ("link-macos-synthetic", "link-macos-synthetic-large-text"),
)


def verify_text_scale_variants(
    scenarios: list[tuple[dict[str, Any], Path]],
    image_hashes: dict[str, str],
    failures: list[str],
    *,
    require_all_pairs: bool,
) -> None:
    """Require Kaname's named text-scale pairs to differ only by text scale."""
    scenarios_by_id: dict[str, dict[str, Any]] = {}
    for scenario, _ in scenarios:
        identifier = scenario.get("id")
        if isinstance(identifier, str):
            scenarios_by_id[identifier] = scenario

    for standard_identifier, accessibility_identifier in TEXT_SCALE_VARIANT_PAIRS:
        standard = scenarios_by_id.get(standard_identifier)
        accessibility = scenarios_by_id.get(accessibility_identifier)
        if standard is None and accessibility is None and not require_all_pairs:
            continue
        require(
            standard is not None and accessibility is not None,
            "missing text-scale variant: "
            f"{standard_identifier} and {accessibility_identifier} must both be present",
            failures,
        )
        if standard is None or accessibility is None:
            continue
        require(
            standard.get("textScale") == "standard",
            f"{standard_identifier} must declare standard textScale",
            failures,
        )
        require(
            accessibility.get("textScale") == "accessibility3",
            f"{accessibility_identifier} must declare accessibility3 textScale",
            failures,
        )
        for field in TEXT_SCALE_COMPARISON_AXES:
            require(
                standard.get(field) == accessibility.get(field),
                "text-scale variant axis drift: "
                f"{standard_identifier} and {accessibility_identifier} differ on {field}",
                failures,
            )
        standard_hash = image_hashes.get(standard_identifier)
        accessibility_hash = image_hashes.get(accessibility_identifier)
        if standard_hash is not None and accessibility_hash is not None:
            require(
                standard_hash != accessibility_hash,
                "text-scale variants are byte-identical: "
                f"{standard_identifier} and {accessibility_identifier}",
                failures,
            )


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify a complete Kaname synthetic design evidence batch.")
    parser.add_argument("--catalog-manifest", type=Path, required=True)
    parser.add_argument("--product-manifest", type=Path, required=True)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--require-complete-batch", action="store_true")
    arguments = parser.parse_args()

    directory = arguments.directory.resolve()
    catalog_manifest = arguments.catalog_manifest.resolve()
    product_manifest = arguments.product_manifest.resolve()
    scenarios = [
        *((scenario, catalog_manifest) for scenario in read_manifest(catalog_manifest)),
        *((scenario, product_manifest) for scenario in read_manifest(product_manifest)),
    ]
    if arguments.require_complete_batch and len(scenarios) != 17:
        raise SystemExit(f"Complete batch must contain 17 scenarios, found {len(scenarios)}")

    receipt_module = runpy.run_path(str(ROOT / "Scripts" / "write-kaname-design-screenshot-receipt.py"))
    current_snapshot_algorithm = receipt_module["WORKING_SNAPSHOT_ALGORITHM"]
    current_snapshot = receipt_module["working_snapshot_digest"]()
    current_head = git("rev-parse", "HEAD")
    current_branch = git("branch", "--show-current")
    failures: list[str] = []
    if arguments.require_complete_batch:
        expected_images = {str(scenario.get("outputFile", "")) for scenario, _ in scenarios}
        expected_receipts = {str(Path(name).with_suffix(".receipt.json")) for name in expected_images}
        require(len(expected_images) == 17, "complete batch manifest output filenames are not unique", failures)
        if directory.is_dir():
            actual_images = {path.name for path in directory.iterdir() if path.is_file() and path.suffix == ".png"}
            actual_receipts = {
                path.name
                for path in directory.iterdir()
                if path.is_file() and path.name.endswith(".receipt.json")
            }
            require(
                actual_images == expected_images,
                f"complete batch PNG set drifted: expected {sorted(expected_images)}, found {sorted(actual_images)}",
                failures,
            )
            require(
                actual_receipts == expected_receipts,
                f"complete batch receipt set drifted: expected {sorted(expected_receipts)}, found {sorted(actual_receipts)}",
                failures,
            )
        else:
            failures.append(f"evidence directory does not exist: {directory}")
    snapshots: set[str] = set()
    image_hashes: dict[str, str] = {}
    for scenario, manifest in scenarios:
        snapshot, image_hash = verify_pair(
            scenario,
            manifest,
            directory,
            current_head,
            current_branch,
            current_snapshot_algorithm,
            current_snapshot,
            failures,
        )
        if snapshot:
            snapshots.add(snapshot)
        identifier = scenario.get("id")
        if isinstance(identifier, str) and image_hash:
            image_hashes[identifier] = image_hash

    require(len(snapshots) == 1, "evidence batch does not share one source snapshot digest", failures)
    verify_text_scale_variants(
        scenarios,
        image_hashes,
        failures,
        require_all_pairs=arguments.require_complete_batch,
    )
    if failures:
        for failure in failures:
            print(f"error: {failure}")
        return 1
    print(f"Verified {len(scenarios)} synthetic-public PNG/receipt pairs for source snapshot {current_snapshot}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
