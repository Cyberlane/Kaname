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
PRODUCT_SCENARIO_CONTRACT = {
    "desktop-link-host": ("macOS", "links", "desktop-link-synthetic-fixture"),
    "ios-home-synthetic": ("iOS", "home", "iphone-phase0-fixtures-and-memory-only-shell"),
    "link-macos-synthetic": ("macOS", "discussion", "kaname-link-synthetic-preview"),
    "desktop-home-statuses": ("macOS", "home-statuses", "desktop-status-synthetic-fixture"),
    "desktop-home-statuses-large-text": ("macOS", "home-statuses", "desktop-status-synthetic-fixture"),
    "desktop-github-statuses": ("macOS", "github-statuses", "desktop-status-synthetic-fixture"),
    "desktop-link-publication-statuses": ("macOS", "links-publication-statuses", "desktop-link-synthetic-fixture"),
    "ios-project-github-statuses": ("iOS", "project-github-statuses", "iphone-status-synthetic-kaname-project"),
    "ios-project-github-statuses-large-text": ("iOS", "project-github-statuses", "iphone-status-synthetic-kaname-project"),
    "link-macos-synthetic-large-text": ("macOS", "discussion", "kaname-link-synthetic-preview"),
}


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
    expected_routes = {
        "catalog-overview": ("overview", "catalog-overview.png"),
        "catalog-foundations": ("foundations", "catalog-foundations.png"),
        "catalog-components": ("components", "catalog-components.png"),
        "catalog-desktop": ("desktop", "catalog-desktop.png"),
        "catalog-ios": ("ios", "catalog-ios.png"),
        "catalog-link": ("link", "catalog-link.png"),
        "catalog-accessibility": ("accessibility", "catalog-accessibility.png"),
    }
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
        expected_route = expected_routes.get(identifier)
        require(expected_route is not None, f"unsupported catalog scenario id: {identifier}", failures)
        if expected_route is not None:
            require(
                (scenario["captureVariant"], output) == expected_route,
                f"catalog scenario {identifier} route/output drifted",
                failures,
            )
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
    require(identifiers == set(expected_routes), "catalog scenario identifiers are incomplete or unsupported", failures)


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

    product_sources = "\n".join(
        path.read_text(encoding="utf-8")
        for root in (
            ROOT / "Sources" / "KanamePrototype",
            ROOT / "Sources" / "KanamePrototypeUI",
        )
        for path in root.rglob("*.swift")
    )
    for legacy_component in (
        "RecordStatusPill",
        "ActionStatePill",
        "ProductStatusPill",
        "AttentionPill",
        "IPhonePill",
        "LinkStatusPill",
        "WorkflowStatePill",
        "AttentionBadge",
        "DesktopUpdateNotificationPill",
    ):
        require(
            legacy_component not in product_sources,
            f"legacy status component remains in product source: {legacy_component}",
            failures,
        )

    package_source = (ROOT / "Package.swift").read_text(encoding="utf-8")
    require('name: "KanameDesktopUI"' in package_source, "Desktop semantic adapters are not packaged", failures)
    require('"KanameDesignSystem"' in package_source, "product targets do not declare the design-system dependency", failures)

    iphone_source = (ROOT / "Sources" / "KanamePrototypeUI" / "IPhoneControlSurface.swift").read_text(encoding="utf-8")
    require(
        re.search(r"private struct IPhoneCheckRow: View\s*\{[^}]*let result: String", iphone_source, re.DOTALL) is None,
        "iOS check rows still accept untyped result strings",
        failures,
    )
    require(
        re.search(r"private struct IPhoneSessionRow: View\s*\{[^}]*let state: String", iphone_source, re.DOTALL) is None,
        "iOS session rows still accept untyped state strings",
        failures,
    )


def verify_product_scenarios(document: dict[str, Any], failures: list[str]) -> None:
    require(document.get("schemaVersion") == 1, "product scenario schemaVersion must be 1", failures)
    require(document.get("privacyClass") == "synthetic-public", "product scenarios must be synthetic-public", failures)
    scenarios = document.get("scenarios", [])
    require(len(scenarios) == len(PRODUCT_SCENARIO_CONTRACT), "product screenshot matrix must define exactly ten scenarios", failures)
    require({scenario.get("id") for scenario in scenarios} == set(PRODUCT_SCENARIO_CONTRACT), "product screenshot baseline IDs are incomplete", failures)
    required = {
        "id", "captureVariant", "outputFile", "platform", "surface", "fixture", "viewport",
        "appearance", "differentiateWithoutColor", "reduceMotion", "textScale", "activeWindow",
        "locale", "expectedAccessibilityLabels", "privacyClass", "evidenceClass",
    }
    outputs: set[str] = set()
    for scenario in scenarios:
        identifier = scenario.get("id", "<unknown>")
        missing = required - set(scenario)
        require(not missing, f"product scenario {identifier} misses {sorted(missing)}", failures)
        if missing:
            continue
        require(scenario.get("privacyClass") == "synthetic-public", f"product scenario {identifier} is not synthetic-public", failures)
        require(scenario.get("evidenceClass") == "fixture-projection", f"product scenario {identifier} overstates its evidence", failures)
        require(bool(scenario.get("expectedAccessibilityLabels")), f"product scenario {identifier} has no expected labels", failures)
        output = str(scenario.get("outputFile", ""))
        require(bool(re.fullmatch(r"[a-z0-9-]+\.png", output)), f"product scenario {identifier} has an unsafe output", failures)
        require(output not in outputs, f"duplicate product scenario output: {output}", failures)
        outputs.add(output)
        expected_route = PRODUCT_SCENARIO_CONTRACT.get(identifier)
        if expected_route is not None:
            actual_route = (scenario.get("platform"), scenario.get("captureVariant"), scenario.get("fixture"))
            require(actual_route == expected_route, f"product scenario {identifier} is not bound to its accepted renderer route", failures)
        require(scenario.get("appearance") in {"dark", "light", "highContrast"}, f"product scenario {identifier} has invalid appearance", failures)
        require(scenario.get("textScale") in {"standard", "accessibility3"}, f"product scenario {identifier} has invalid text scale", failures)

    all_labels = [
        label
        for scenario in scenarios
        for label in scenario.get("expectedAccessibilityLabels", [])
    ]
    for prefix in (
        "Status:",
        "Action status:",
        "Attention:",
        "Gateway status:",
        "Publication status:",
        "Receipt status:",
        "Connection status:",
        "Discussion status:",
        "Message status:",
        "Host verification:",
        "Participant:",
        "Scope:",
        "Trust boundary:",
        "Approval required:",
    ):
        require(any(label.startswith(prefix) for label in all_labels), f"product matrix does not cover semantic prefix {prefix}", failures)

    link_contract = json.loads(
        (ROOT / "Fixtures" / "kaname-link" / "status-presentation-v1.json").read_text(encoding="utf-8")
    )
    link_contract_labels = {
        entry["accessibilityLabel"]
        for family in ("connections", "discussions", "receipts", "hostVerifications", "participants")
        for entry in link_contract.get(family, [])
    }
    link_fixed_labels = {
        "Kaname Link",
        "Action status: Response actions pending",
        "Trust boundary: Restricted collaborator",
    }
    for scenario in scenarios:
        if scenario.get("surface") != "link.macos.discussion":
            continue
        for label in scenario.get("expectedAccessibilityLabels", []):
            require(
                label in link_contract_labels | link_fixed_labels,
                f"Link scenario {scenario.get('id')} expects a label outside the status/UI contract: {label}",
                failures,
            )


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
