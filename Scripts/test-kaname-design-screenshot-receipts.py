#!/usr/bin/env python3
"""Focused regression tests for schema-2 design screenshot receipts."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
import zlib


SCRIPT_DIRECTORY = Path(__file__).resolve().parent
WRITER = SCRIPT_DIRECTORY / "write-kaname-design-screenshot-receipt.py"
VERIFIER = SCRIPT_DIRECTORY / "verify-kaname-design-screenshot-receipts.py"
PNG_HELPER = SCRIPT_DIRECTORY / "kaname_design_screenshot_png.py"
PAIR_ASSERTION = SCRIPT_DIRECTORY / "assert-kaname-design-capture-pair-diff.sh"
SCENARIO_OUTPUT_HELPER = SCRIPT_DIRECTORY / "kaname-design-scenario-output.py"
SNAPSHOT_ALGORITHM = "sha256-git-delta-path-mode-content-v1"


def png(width: int, height: int, channel: int = 64) -> bytes:
    def chunk(kind: bytes, data: bytes) -> bytes:
        checksum = zlib.crc32(kind + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", checksum)

    header = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    row = b"\0" + bytes((channel, 128, 192, 255)) * width
    pixels = zlib.compress(row * height)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", pixels) + chunk(b"IEND", b"")


class DesignScreenshotReceiptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="kaname-screenshot-receipts-")
        self.workspace = Path(self.temporary.name).resolve()
        self.repository = self.workspace / "repository"
        self.evidence = self.workspace / "evidence"
        (self.repository / "Scripts").mkdir(parents=True)
        (self.repository / "DesignSystem").mkdir()
        self.evidence.mkdir()
        shutil.copy2(WRITER, self.repository / "Scripts" / WRITER.name)
        shutil.copy2(VERIFIER, self.repository / "Scripts" / VERIFIER.name)
        shutil.copy2(PNG_HELPER, self.repository / "Scripts" / PNG_HELPER.name)
        shutil.copy2(PAIR_ASSERTION, self.repository / "Scripts" / PAIR_ASSERTION.name)
        shutil.copy2(SCENARIO_OUTPUT_HELPER, self.repository / "Scripts" / SCENARIO_OUTPUT_HELPER.name)
        self.tokens = self.repository / "DesignSystem" / "kaname.tokens.json"
        self.tokens.write_text('{"metadata":{"version":"0.1.0"}}\n', encoding="utf-8")
        self.source = self.repository / "source.txt"
        self.source.write_text("fixture source\n", encoding="utf-8")
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Kaname Receipt Test")
        self.git("config", "user.email", "kaname-receipt-test@invalid.example")
        self.git("add", ".")
        self.git("commit", "-m", "fixture")
        self.catalog_manifest = self.evidence / "catalog.json"
        self.product_manifest = self.evidence / "product.json"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def git(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["git", *arguments],
            cwd=self.repository,
            check=True,
            capture_output=True,
            text=True,
        )

    @staticmethod
    def scenario(
        identifier: str,
        output_file: str,
        surface: str = "ios.test",
        evidence_class: str = "fixture-projection",
        **overrides: object,
    ) -> dict[str, object]:
        scenario: dict[str, object] = {
            "id": identifier,
            "captureVariant": "receipt-test",
            "surface": surface,
            "outputFile": output_file,
            "privacyClass": "synthetic-public",
            "evidenceClass": evidence_class,
            "fixture": "receipt-test.synthetic",
            "platform": "iOS",
            "viewport": "receipt-test",
            "appearance": "dark",
            "differentiateWithoutColor": False,
            "reduceMotion": False,
            "textScale": "standard",
            "activeWindow": True,
            "locale": "en_US",
        }
        scenario.update(overrides)
        return scenario

    @staticmethod
    def write_json(path: Path, value: object) -> None:
        path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    def write_manifest(self, path: Path, scenarios: list[dict[str, object]]) -> None:
        self.write_json(
            path,
            {
                "schemaVersion": 1,
                "privacyClass": "synthetic-public",
                "scenarios": scenarios,
            },
        )

    def run_cli(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", *arguments],
            cwd=self.repository,
            check=False,
            capture_output=True,
            text=True,
        )

    def write_receipt(
        self,
        manifest: Path,
        identifier: str,
        image: Path,
        *,
        launcher: Path | None = None,
        preverified: bool = True,
        postverified: bool = True,
    ) -> subprocess.CompletedProcess[str]:
        arguments = [
            str(self.repository / "Scripts" / WRITER.name),
            "--manifest", str(manifest),
            "--scenario", identifier,
            "--image", str(image.resolve()),
            "--capture-method", "temporary synthetic renderer",
            "--renderer", "receipt regression fixture",
            "--target-runtime", "test",
        ]
        if launcher is not None:
            arguments.extend(("--desktop-launcher-receipt", str(launcher)))
            if preverified:
                arguments.append("--desktop-preverified")
            if postverified:
                arguments.append("--desktop-postverified")
        return self.run_cli(*arguments)

    def verify(self, *, complete: bool = False) -> subprocess.CompletedProcess[str]:
        arguments = [
            str(self.repository / "Scripts" / VERIFIER.name),
            "--catalog-manifest", str(self.catalog_manifest),
            "--product-manifest", str(self.product_manifest),
            "--directory", str(self.evidence),
        ]
        if complete:
            arguments.append("--require-complete-batch")
        return self.run_cli(*arguments)

    def assert_succeeded(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(result.returncode, 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}")

    def assert_rejected(self, result: subprocess.CompletedProcess[str], message: str) -> None:
        self.assertNotEqual(result.returncode, 0, f"command unexpectedly passed:\n{result.stdout}")
        self.assertIn(message, result.stdout + result.stderr)

    def test_capture_pair_assertion_rejects_identical_bytes(self) -> None:
        standard = self.scenario("pair-standard", "pair-standard.png")
        scaled = self.scenario(
            "pair-accessibility3",
            "pair-accessibility3.png",
            textScale="accessibility3",
        )
        self.write_manifest(self.product_manifest, [standard, scaled])
        standard_image = self.evidence / "pair-standard.png"
        scaled_image = self.evidence / "pair-accessibility3.png"
        standard_image.write_bytes(png(2, 2))
        scaled_image.write_bytes(standard_image.read_bytes())
        command = [
            "zsh",
            str(self.repository / "Scripts" / PAIR_ASSERTION.name),
            str(self.product_manifest),
            str(self.evidence),
            "pair-standard",
            "pair-accessibility3",
            "synthetic pair remained identical",
        ]

        result = subprocess.run(command, cwd=self.repository, check=False, capture_output=True, text=True)
        self.assert_rejected(result, "synthetic pair remained identical")

        scaled_image.write_bytes(png(2, 2, channel=65))
        result = subprocess.run(command, cwd=self.repository, check=False, capture_output=True, text=True)
        self.assert_succeeded(result)

    def test_schema_two_round_trip_binds_png_bytes_dimensions_and_hash(self) -> None:
        scenario = self.scenario("ios-round-trip", "ios-round-trip.png")
        self.write_manifest(self.catalog_manifest, [scenario])
        self.write_manifest(self.product_manifest, [])
        image = self.evidence / "ios-round-trip.png"
        original = png(3, 2)
        image.write_bytes(original)

        self.assert_succeeded(self.write_receipt(self.catalog_manifest, "ios-round-trip", image))
        receipt_path = image.with_suffix(".receipt.json")
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        self.assertEqual(receipt["schemaVersion"], 2)
        self.assertEqual(receipt["source"]["workingSnapshotAlgorithm"], SNAPSHOT_ALGORITHM)
        self.assertEqual(receipt["image"]["file"], image.name)
        self.assertEqual((receipt["image"]["widthPixels"], receipt["image"]["heightPixels"]), (3, 2))
        self.assertEqual(receipt["image"]["bytes"], len(original))
        self.assertEqual(receipt["image"]["sha256"], hashlib.sha256(original).hexdigest())
        self.assert_succeeded(self.verify())

        image.write_bytes(original + b"tamper")
        result = self.verify()
        self.assert_rejected(result, "image byte count drifted")
        self.assertIn("image hash drifted", result.stdout)

        image.write_bytes(png(4, 2, channel=65))
        self.assert_rejected(self.verify(), "image dimensions drifted")

    def test_verifier_rejects_manifest_token_source_and_algorithm_drift(self) -> None:
        scenario = self.scenario("drift", "drift.png")
        self.write_manifest(self.catalog_manifest, [scenario])
        self.write_manifest(self.product_manifest, [])
        image = self.evidence / "drift.png"
        image.write_bytes(png(2, 2))
        self.assert_succeeded(self.write_receipt(self.catalog_manifest, "drift", image))
        receipt_path = image.with_suffix(".receipt.json")
        original_manifest = self.catalog_manifest.read_bytes()
        original_tokens = self.tokens.read_bytes()
        original_source = self.source.read_bytes()
        original_receipt = receipt_path.read_bytes()

        drifted_scenario = dict(scenario)
        drifted_scenario["note"] = "manifest changed"
        self.write_manifest(self.catalog_manifest, [drifted_scenario])
        result = self.verify()
        self.assert_rejected(result, "receipt scenario drifted from manifest")
        self.assertIn("manifest hash drifted", result.stdout)
        self.catalog_manifest.write_bytes(original_manifest)

        self.tokens.write_text('{"metadata":{"version":"0.2.0"}}\n', encoding="utf-8")
        result = self.verify()
        self.assert_rejected(result, "token hash drifted")
        self.assertIn("design-system version drifted", result.stdout)
        self.tokens.write_bytes(original_tokens)

        self.source.write_text("fixture source drift\n", encoding="utf-8")
        self.assert_rejected(self.verify(), "working snapshot does not match current source")
        self.source.write_bytes(original_source)

        receipt = json.loads(original_receipt)
        receipt["source"]["workingSnapshotAlgorithm"] = "sha256-unrelated-algorithm"
        self.write_json(receipt_path, receipt)
        self.assert_rejected(self.verify(), "working snapshot algorithm is unsupported")

    def test_text_scale_variants_require_distinct_rendered_bytes(self) -> None:
        standard = self.scenario(
            "link-macos-synthetic",
            "link-standard.png",
            surface="link.macos.discussion",
            platform="macOS",
        )
        accessibility = self.scenario(
            "link-macos-synthetic-large-text",
            "link-accessibility3.png",
            surface="link.macos.discussion",
            platform="macOS",
            textScale="accessibility3",
        )
        self.write_manifest(self.catalog_manifest, [])
        self.write_manifest(self.product_manifest, [standard, accessibility])
        standard_image = self.evidence / "link-standard.png"
        accessibility_image = self.evidence / "link-accessibility3.png"
        identical_pixels = png(2, 2)
        standard_image.write_bytes(identical_pixels)
        accessibility_image.write_bytes(identical_pixels)
        self.assert_succeeded(self.write_receipt(self.product_manifest, "link-macos-synthetic", standard_image))
        self.assert_succeeded(self.write_receipt(self.product_manifest, "link-macos-synthetic-large-text", accessibility_image))

        self.assert_rejected(
            self.verify(),
            "text-scale variants are byte-identical: link-macos-synthetic and link-macos-synthetic-large-text",
        )

        accessibility_image.write_bytes(png(2, 2, channel=65))
        self.assert_succeeded(self.write_receipt(self.product_manifest, "link-macos-synthetic-large-text", accessibility_image))
        self.assert_succeeded(self.verify())

    def test_text_scale_variants_reject_renderer_axis_drift(self) -> None:
        standard = self.scenario(
            "link-macos-synthetic",
            "link-standard.png",
            surface="link.macos.discussion",
            platform="macOS",
        )
        accessibility = self.scenario(
            "link-macos-synthetic-large-text",
            "link-accessibility3.png",
            surface="link.macos.discussion",
            platform="macOS",
            viewport="drifted-viewport",
            textScale="accessibility3",
        )
        self.write_manifest(self.catalog_manifest, [])
        self.write_manifest(self.product_manifest, [standard, accessibility])
        standard_image = self.evidence / "link-standard.png"
        accessibility_image = self.evidence / "link-accessibility3.png"
        standard_image.write_bytes(png(2, 2))
        accessibility_image.write_bytes(png(2, 2, channel=65))
        self.assert_succeeded(self.write_receipt(self.product_manifest, "link-macos-synthetic", standard_image))
        self.assert_succeeded(self.write_receipt(self.product_manifest, "link-macos-synthetic-large-text", accessibility_image))

        self.assert_rejected(
            self.verify(),
            "text-scale variant axis drift: link-macos-synthetic and "
            "link-macos-synthetic-large-text differ on viewport",
        )

    def test_text_scale_variants_require_named_counterpart(self) -> None:
        standard = self.scenario(
            "link-macos-synthetic",
            "link-standard.png",
            surface="link.macos.discussion",
            platform="macOS",
        )
        self.write_manifest(self.catalog_manifest, [])
        self.write_manifest(self.product_manifest, [standard])
        standard_image = self.evidence / "link-standard.png"
        standard_image.write_bytes(png(2, 2))
        self.assert_succeeded(self.write_receipt(self.product_manifest, "link-macos-synthetic", standard_image))

        self.assert_rejected(
            self.verify(),
            "missing text-scale variant: link-macos-synthetic and "
            "link-macos-synthetic-large-text must both be present",
        )

    def test_complete_batch_requires_exactly_seventeen_pairs(self) -> None:
        catalog_evidence_classes = [
            "implemented",
            "implemented",
            "implemented",
            "fixture-projection",
            "fixture-projection",
            "fixture-projection",
            "scaffolded-gap",
        ]
        catalog = [
            self.scenario(
                f"catalog-{index}",
                f"catalog-{index}.png",
                "catalog.test",
                evidence_class,
            )
            for index, evidence_class in enumerate(catalog_evidence_classes)
        ]
        text_scale_pairs = [
            ("desktop-home-statuses", "desktop-home-statuses-large-text"),
            ("ios-project-github-statuses", "ios-project-github-statuses-large-text"),
            ("link-macos-synthetic", "link-macos-synthetic-large-text"),
        ]
        product = [
            scenario
            for standard_identifier, accessibility_identifier in text_scale_pairs
            for scenario in (
                self.scenario(standard_identifier, f"{standard_identifier}.png"),
                self.scenario(
                    accessibility_identifier,
                    f"{accessibility_identifier}.png",
                    textScale="accessibility3",
                ),
            )
        ]
        product.extend(
            self.scenario(f"product-{index}", f"product-{index}.png")
            for index in range(4)
        )
        self.write_manifest(self.catalog_manifest, catalog)
        self.write_manifest(self.product_manifest, product)
        for scenario, manifest in [*((item, self.catalog_manifest) for item in catalog), *((item, self.product_manifest) for item in product)]:
            image = self.evidence / str(scenario["outputFile"])
            image.write_bytes(
                png(1, 1, channel=65 if scenario.get("textScale") == "accessibility3" else 64)
            )
            self.assert_succeeded(self.write_receipt(manifest, str(scenario["id"]), image))

        result = self.verify(complete=True)
        self.assert_succeeded(result)
        self.assertIn("Verified 17 synthetic-public PNG/receipt pairs", result.stdout)

        unexpected_image = self.evidence / "unexpected.png"
        unexpected_image.write_bytes(png(1, 1))
        self.assert_rejected(self.verify(complete=True), "complete batch PNG set drifted")
        unexpected_image.unlink()

        unexpected_receipt = self.evidence / "unexpected.receipt.json"
        unexpected_receipt.write_text("{}\n", encoding="utf-8")
        self.assert_rejected(self.verify(complete=True), "complete batch receipt set drifted")
        unexpected_receipt.unlink()

        self.write_manifest(self.product_manifest, product[:-1])
        self.assert_rejected(self.verify(complete=True), "Complete batch must contain 17 scenarios, found 16")

    def test_product_receipts_reject_catalog_only_evidence_classes(self) -> None:
        scenario = self.scenario(
            "product-overclaim",
            "product-overclaim.png",
            evidence_class="implemented",
        )
        self.write_manifest(self.catalog_manifest, [])
        self.write_manifest(self.product_manifest, [scenario])
        image = self.evidence / "product-overclaim.png"
        image.write_bytes(png(1, 1))
        self.assert_succeeded(self.write_receipt(self.product_manifest, "product-overclaim", image))
        self.assert_rejected(self.verify(), "product-overclaim overstates product evidence")

    def test_desktop_receipts_require_complete_runtime_identity(self) -> None:
        scenario = self.scenario("desktop-runtime", "desktop-runtime.png", "desktop.home.statuses")
        self.write_manifest(self.catalog_manifest, [])
        self.write_manifest(self.product_manifest, [scenario])
        image = self.evidence / "desktop-runtime.png"
        image.write_bytes(png(2, 1))

        self.assert_rejected(
            self.write_receipt(self.product_manifest, "desktop-runtime", image),
            "Desktop scenarios require a verified Development launcher receipt",
        )

        launcher = self.evidence / "launcher.json"
        launcher_document = {
            "schemaVersion": 3,
            "channel": "development",
            "bundleIdentifier": "com.cyberlane.kaname.desktop.dev",
            "executablePath": str(self.repository / ".build" / "Kaname Prototype.app" / "Contents" / "MacOS" / "KanamePrototype"),
            "processID": 1234,
            "windowID": 5678,
        }
        self.write_json(launcher, launcher_document)
        self.assert_rejected(
            self.write_receipt(self.product_manifest, "desktop-runtime", image, launcher=launcher, postverified=False),
            "Desktop captures require successful pre- and post-action runtime verification",
        )
        invalid_launcher = dict(launcher_document)
        invalid_launcher["processID"] = True
        self.write_json(launcher, invalid_launcher)
        self.assert_rejected(
            self.write_receipt(self.product_manifest, "desktop-runtime", image, launcher=launcher),
            "Desktop launcher receipt has an invalid process ID",
        )
        self.write_json(launcher, launcher_document)

        self.assert_succeeded(self.write_receipt(self.product_manifest, "desktop-runtime", image, launcher=launcher))
        receipt_path = image.with_suffix(".receipt.json")
        baseline = json.loads(receipt_path.read_text(encoding="utf-8"))
        runtime = baseline["desktopRuntimeEvidence"]
        self.assertEqual(runtime["launcherReceiptSchemaVersion"], 3)
        self.assertEqual(runtime["processID"], 1234)
        self.assertEqual(runtime["windowID"], 5678)
        self.assertTrue(runtime["preActionVerificationPassed"])
        self.assertTrue(runtime["postActionVerificationPassed"])
        self.assert_succeeded(self.verify())

        mandatory_fields = {
            "launcherReceiptSHA256": "lacks a launcher receipt hash",
            "launcherReceiptSchemaVersion": "lacks a supported launcher receipt schema version",
            "channel": "was not captured from Development",
            "bundleIdentifier": "has the wrong bundle identity",
            "canonicalExecutablePath": "executable path is not task-canonical",
            "processID": "lacks a historical PID",
            "windowID": "lacks a historical window ID",
            "preActionVerificationPassed": "lacks pre-action verification",
            "postActionVerificationPassed": "lacks post-action verification",
        }
        for field, message in mandatory_fields.items():
            with self.subTest(field=field):
                changed = json.loads(json.dumps(baseline))
                del changed["desktopRuntimeEvidence"][field]
                self.write_json(receipt_path, changed)
                self.assert_rejected(self.verify(), message)

        changed = json.loads(json.dumps(baseline))
        changed["desktopRuntimeEvidence"]["launcherReceiptSHA256"] = "z" * 64
        self.write_json(receipt_path, changed)
        self.assert_rejected(self.verify(), "lacks a launcher receipt hash")

        changed = json.loads(json.dumps(baseline))
        changed["desktopRuntimeEvidence"]["processID"] = True
        self.write_json(receipt_path, changed)
        self.assert_rejected(self.verify(), "lacks a historical PID")


if __name__ == "__main__":
    unittest.main()
