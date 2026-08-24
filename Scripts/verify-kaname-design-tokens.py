#!/usr/bin/env python3
from __future__ import annotations

import json
import math
import re
import runpy
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
TOKENS = ROOT / "DesignSystem" / "kaname.tokens.json"
SCENARIOS = ROOT / "Fixtures" / "design-system" / "catalog-scenarios.json"
PRODUCT_SCENARIOS = ROOT / "Fixtures" / "design-system" / "product-scenarios.json"
CATALOG_SOURCE = ROOT / "Sources" / "KanameDesignCatalog" / "KanameDesignCatalogApp.swift"
COMPONENT_SOURCE = ROOT / "Sources" / "KanameDesignSystem" / "KanameComponents.swift"


def linear_channel(value: int) -> float:
    channel = value / 255
    return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4


def luminance(hex_color: str) -> float:
    value = hex_color.removeprefix("#")
    red, green, blue = (int(value[index:index + 2], 16) for index in (0, 2, 4))
    return 0.2126 * linear_channel(red) + 0.7152 * linear_channel(green) + 0.0722 * linear_channel(blue)


def contrast(first: str, second: str) -> float:
    lighter, darker = sorted((luminance(first), luminance(second)), reverse=True)
    return (lighter + 0.05) / (darker + 0.05)


def require(condition: bool, message: str, failures: list[str]) -> None:
    if not condition:
        failures.append(message)


def verify_tokens(document: dict[str, Any], failures: list[str]) -> None:
    metadata = document.get("metadata", {})
    require(metadata.get("schemaVersion") == 1, "token schemaVersion must be 1", failures)
    require(metadata.get("format") == "kaname-design-tokens", "token format must be explicit", failures)
    require(bool(re.fullmatch(r"0\.\d+\.\d+", str(metadata.get("version", "")))), "adoption version must remain 0.x SemVer", failures)
    require(metadata.get("sourceOfTruth") is True, "token source-of-truth marker is missing", failures)

    colors = document.get("semantic", {}).get("color", {})
    require(set(colors) == {"dark", "light"}, "dark and light semantic color maps are required", failures)
    if set(colors) != {"dark", "light"}:
        return
    require(set(colors["dark"]) == set(colors["light"]), "dark/light semantic color roles differ", failures)

    for appearance in ("dark", "light"):
        palette = colors[appearance]
        for foreground in ("textPrimary", "textSecondary"):
            for background in ("canvas", "sidebar", "surface", "raised"):
                ratio = contrast(palette[foreground], palette[background])
                require(
                    ratio >= 4.5,
                    f"{appearance} {foreground}/{background} contrast is {ratio:.2f}:1, below 4.5:1",
                    failures,
                )
        for background in ("canvas", "sidebar", "surface", "raised"):
            ratio = contrast(palette["textTertiary"], palette[background])
            require(
                ratio >= 4.5,
                f"{appearance} textTertiary/{background} contrast is {ratio:.2f}:1, below 4.5:1",
                failures,
            )

    statuses = document.get("semantic", {}).get("status", {})
    icons = document.get("semantic", {}).get("icon", {})
    expected_statuses = {
        "neutral", "informational", "active", "attention", "success",
        "warning", "danger", "blocked", "external",
    }
    require(set(statuses) == expected_statuses, "status vocabulary is incomplete or changed without migration", failures)
    available_roles = set(colors["dark"])
    for name, status in statuses.items():
        icon_id = status.get("icon")
        require(icon_id in icons, f"status {name} references an unknown semantic icon", failures)
        if icon_id in icons:
            require(
                set(icons[icon_id]) == {"swiftUI", "winUI", "gtk"}
                and all(icons[icon_id].values()),
                f"status {name} does not map its icon on SwiftUI, WinUI, and GTK",
                failures,
            )
        require(status.get("color") in available_roles, f"status {name} references an unknown color role", failures)


def verify_scenarios(document: dict[str, Any], failures: list[str]) -> None:
    require(document.get("schemaVersion") == 1, "scenario schemaVersion must be 1", failures)
    require(document.get("privacyClass") == "synthetic-public", "scenario document must be synthetic-public", failures)
    scenarios = document.get("scenarios", [])
    require(len(scenarios) == 7, "the catalog must define exactly seven baseline pages", failures)
    required = {
        "id", "captureVariant", "outputFile", "platform", "surface", "fixture", "viewport",
        "appearance", "differentiateWithoutColor", "reduceMotion", "textScale", "activeWindow",
        "locale", "expectedAccessibilityLabels", "privacyClass",
        "evidenceClass",
    }
    identifiers: set[str] = set()
    outputs: set[str] = set()
    source = "\n".join(
        path.read_text(encoding="utf-8")
        for path in (CATALOG_SOURCE, COMPONENT_SOURCE)
    )
    for scenario in scenarios:
        missing = required - set(scenario)
        require(not missing, f"scenario {scenario.get('id', '<unknown>')} misses {sorted(missing)}", failures)
        if missing:
            continue
        identifier = scenario["id"]
        output = scenario["outputFile"]
        require(identifier not in identifiers, f"duplicate scenario id: {identifier}", failures)
        require(output not in outputs, f"duplicate scenario output: {output}", failures)
        identifiers.add(identifier)
        outputs.add(output)
        require(scenario["platform"] == "macOS", f"catalog scenario {identifier} must describe its actual macOS renderer", failures)
        require(scenario["fixture"] == "design-system.catalog", f"scenario {identifier} uses an unapproved fixture", failures)
        require(scenario["viewport"] == "1280x860", f"scenario {identifier} differs from the qualified catalog viewport", failures)
        require(scenario["appearance"] in {"dark", "light", "highContrast"}, f"scenario {identifier} has invalid appearance", failures)
        require(scenario["privacyClass"] == "synthetic-public", f"scenario {identifier} is not synthetic-public", failures)
        require(
            scenario["evidenceClass"] in {"implemented", "fixture-projection", "scaffolded-gap"},
            f"scenario {identifier} has an invalid evidence class",
            failures,
        )
        require(bool(re.fullmatch(r"[a-z0-9-]+\.png", output)), f"scenario {identifier} has an unsafe output filename", failures)
        require(bool(scenario["expectedAccessibilityLabels"]), f"scenario {identifier} has no expected labels", failures)
        for label in scenario["expectedAccessibilityLabels"]:
            require(label in source, f"scenario {identifier} expects a label absent from catalog/component source: {label}", failures)


def verify_feature_adapters(failures: list[str]) -> None:
    checks = {
        ROOT / "Clients" / "KanameLink" / "Windows" / "MainWindow.xaml": r"#[0-9a-fA-F]{6}",
        ROOT / "Clients" / "KanameLink" / "Windows" / "MainWindow.xaml.cs": r"ColorHelper\.FromArgb",
        ROOT / "Clients" / "KanameLink" / "Linux" / "src" / "kaname-components.css": r"#[0-9a-fA-F]{6}",
        ROOT / "Sources" / "KanameLinkMac" / "KanameLinkMacApp.swift": r"Color\(red:",
    }
    for path, pattern in checks.items():
        require(
            re.search(pattern, path.read_text(encoding="utf-8")) is None,
            f"feature adapter bypasses semantic tokens: {path.relative_to(ROOT)}",
            failures,
        )
    linux_main = (ROOT / "Clients" / "KanameLink" / "Linux" / "src" / "main.rs").read_text(encoding="utf-8")
    require('include_str!("kaname-theme.css")' in linux_main, "GTK client does not load generated tokens", failures)
    require('include_str!("kaname-components.css")' in linux_main, "GTK client does not load its component adapter", failures)


def verify_product_scenarios(document: dict[str, Any], failures: list[str]) -> None:
    require(document.get("schemaVersion") == 1, "product scenario schemaVersion must be 1", failures)
    require(document.get("privacyClass") == "synthetic-public", "product scenarios must be synthetic-public", failures)
    scenarios = document.get("scenarios", [])
    require(
        {scenario.get("id") for scenario in scenarios}
        == {"desktop-link-host", "ios-home-synthetic", "link-macos-synthetic"},
        "product screenshot baseline IDs are incomplete",
        failures,
    )
    for scenario in scenarios:
        identifier = scenario.get("id", "<unknown>")
        require(scenario.get("privacyClass") == "synthetic-public", f"product scenario {identifier} is not synthetic-public", failures)
        require(scenario.get("evidenceClass") == "fixture-projection", f"product scenario {identifier} overstates its evidence", failures)
        require(bool(scenario.get("expectedAccessibilityLabels")), f"product scenario {identifier} has no expected labels", failures)
        require(bool(re.fullmatch(r"[a-z0-9-]+\.png", str(scenario.get("outputFile", "")))), f"product scenario {identifier} has an unsafe output", failures)


def verify_receipt_snapshot_invariance(failures: list[str]) -> None:
    module = runpy.run_path(str(ROOT / "Scripts" / "write-kaname-design-screenshot-receipt.py"))
    snapshot_digest = module["working_snapshot_digest"]
    with tempfile.TemporaryDirectory(prefix="kaname-design-receipt-test-") as temporary:
        repository = Path(temporary)

        def run_git(*arguments: str) -> None:
            subprocess.run(
                ["git", *arguments],
                cwd=repository,
                text=True,
                capture_output=True,
                check=True,
            )

        run_git("init", "--quiet")
        (repository / "tracked.txt").write_text("base\n", encoding="utf-8")
        run_git("add", "tracked.txt")
        run_git(
            "-c", "user.name=Kaname Design Test",
            "-c", "user.email=design-test@invalid.example",
            "commit", "--quiet", "-m", "base",
        )

        (repository / "new.txt").write_text("new\n", encoding="utf-8")
        untracked_digest = snapshot_digest(repository)
        run_git("add", "new.txt")
        require(
            snapshot_digest(repository) == untracked_digest,
            "screenshot working-snapshot digest changes when an untracked file is staged",
            failures,
        )

        (repository / "tracked.txt").write_text("changed\n", encoding="utf-8")
        unstaged_digest = snapshot_digest(repository)
        run_git("add", "tracked.txt")
        require(
            snapshot_digest(repository) == unstaged_digest,
            "screenshot working-snapshot digest changes when a modified file is staged",
            failures,
        )

        (repository / "tracked.txt").unlink()
        deleted_digest = snapshot_digest(repository)
        run_git("add", "--update")
        require(
            snapshot_digest(repository) == deleted_digest,
            "screenshot working-snapshot digest changes when a deletion is staged",
            failures,
        )


def main() -> int:
    failures: list[str] = []
    generator = subprocess.run(
        [str(ROOT / "Scripts" / "generate-kaname-design-tokens.py"), "--check"],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    if generator.returncode != 0:
        failures.extend(line for line in generator.stderr.splitlines() if line)

    verify_tokens(json.loads(TOKENS.read_text(encoding="utf-8")), failures)
    verify_scenarios(json.loads(SCENARIOS.read_text(encoding="utf-8")), failures)
    verify_product_scenarios(json.loads(PRODUCT_SCENARIOS.read_text(encoding="utf-8")), failures)
    verify_feature_adapters(failures)
    verify_receipt_snapshot_invariance(failures)

    if failures:
        for failure in failures:
            print(f"error: {failure}", file=sys.stderr)
        return 1
    print("Kaname design-system source, projections, contrast, scenarios, and adapters are consistent.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
