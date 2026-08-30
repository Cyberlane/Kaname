#!/usr/bin/env python3
"""Regression tests for the deterministic Kaname accessibility source inventory."""

from __future__ import annotations

import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from typing import Any
import unittest


SCRIPT = Path(__file__).with_name("audit-kaname-accessibility.py").resolve()
MODULE_SPEC = importlib.util.spec_from_file_location("kaname_accessibility_audit", SCRIPT)
assert MODULE_SPEC is not None and MODULE_SPEC.loader is not None
AUDIT_MODULE = importlib.util.module_from_spec(MODULE_SPEC)
sys.modules[MODULE_SPEC.name] = AUDIT_MODULE
MODULE_SPEC.loader.exec_module(AUDIT_MODULE)
ALL_CATEGORIES = [
    "actionable-control-semantics",
    "color-only-state",
    "fixed-size-risk",
    "reduce-motion",
    "focus-restoration",
]


class AccessibilityAuditTests(unittest.TestCase):
    temporary: tempfile.TemporaryDirectory[str] | None = None
    root = Path()

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="kaname-accessibility-audit-")
        self.root = Path(self.temporary.name).resolve()
        (self.root / "Sources").mkdir()

    def tearDown(self) -> None:
        assert self.temporary is not None
        self.temporary.cleanup()

    def write_source(self, relative: str, source: str) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source, encoding="utf-8")
        return path

    def config(self, **overrides: object) -> Path:
        value: dict[str, object] = {
            "schemaVersion": 1,
            "includeRoots": ["Sources"],
            "categories": list(ALL_CATEGORIES),
            "maxFiles": 100,
            "maxFileBytes": 1_000_000,
            "maxFindings": 1_000,
        }
        value.update(overrides)
        path = self.root / "audit-config.json"
        path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
        return path

    def run_audit(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["python3", str(SCRIPT), "--root", str(self.root), *arguments],
            check=False,
            capture_output=True,
            text=True,
        )

    def parse_success(self, result: subprocess.CompletedProcess[str]) -> dict[str, Any]:
        self.assertEqual(result.returncode, 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}")
        return json.loads(result.stdout)

    def assert_failure(self, result: subprocess.CompletedProcess[str], message: str) -> None:
        self.assertEqual(result.returncode, 2, f"command unexpectedly returned {result.returncode}:\n{result.stdout}")
        self.assertIn(message, result.stderr)
        self.assertEqual(result.stdout, "")

    def assert_swift_typechecks(self, source: str) -> None:
        compiler = shutil.which("swiftc")
        if compiler is None:
            self.skipTest("swiftc is required for adversarial Swift fixture validation")
        path = self.root / "AdversarialFixture.swift"
        path.write_text(source, encoding="utf-8")
        result = subprocess.run(
            [compiler, "-typecheck", "-module-cache-path", str(self.root / "ModuleCache"), str(path)],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}")

    def test_reports_each_requested_category_as_a_review_lead(self) -> None:
        self.write_source(
            "Sources/Risky.swift",
            '''import SwiftUI

struct Risky: View {
    @State private var active = false
    @State private var showing = false

    var body: some View {
        VStack {
            Button { active.toggle() } label: {
                Image(systemName: "trash")
            }
            Text("State")
                .foregroundStyle(active ? Color.green : Color.red)
                .frame(width: 180, height: 32)
                .font(.system(size: 11))
            Button("Animate") {
                withAnimation { active.toggle() }
            }
        }
        .sheet(isPresented: $showing) { Text("Presented") }
    }
}
''',
        )
        report = self.parse_success(self.run_audit("--config", str(self.config())))
        self.assertEqual(report["evidenceClass"], "static-source-review-leads")
        self.assertIn("not proof of VoiceOver", report["proofBoundary"])
        self.assertEqual(report["toolIdentity"]["version"], 2)
        self.assertRegex(report["toolIdentity"]["sha256"], r"^[0-9a-f]{64}$")
        self.assertTrue(report["coverage"]["complete"])
        self.assertFalse(report["truncated"])
        categories = {finding["category"] for finding in report["findings"]}
        self.assertEqual(categories, set(ALL_CATEGORIES))
        self.assertEqual(report["exitPolicy"]["acceptedExitCode"], 0)
        self.assertEqual(report["exitPolicy"]["findings"], "success-review-leads")
        self.assertEqual(report["exitPolicy"]["outputIO"], "failure")

    def test_owned_semantics_distinguish_reviewed_source_from_review_leads(self) -> None:
        self.write_source(
            "Sources/Reviewed.swift",
            '''import SwiftUI

struct Reviewed: View {
    @AccessibilityFocusState private var restoredField: Bool
    @State private var showing = false
    let reduceMotion = true

    var body: some View {
        VStack {
            Button { showing = true } label: {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityHint("Deletes the selected item after confirmation")
            Button("Add", systemImage: "plus") { showing = true }
            Button("Animate") {
                if reduceMotion {
                    showing.toggle()
                } else {
                    withAnimation { showing.toggle() }
                }
            }
            Text("Scales naturally")
                .focused($restoredField)
        }
        .sheet(isPresented: $showing) { Text("Presented") }
    }
}

// Button { Image(systemName: "comment-only") }
// Toggle("", isOn: .constant(true))
let harmless = ".frame(width: 10) withAnimation .sheet(isPresented:) TextField(\"\", text:)"
''',
        )
        self.write_source(
            "Sources/Signals.swift",
            '''import SwiftUI
struct Signals: View {
    let title: String
    @State private var enabled = false
    @State private var value = 0.5
    var body: some View {
        VStack {
            Toggle("", isOn: $enabled)
            Circle().fill(Color.red)
            Button(title, action: {})
            Slider(value: $value)
        }
    }
}
''',
        )
        report = self.parse_success(self.run_audit("--config", str(self.config())))
        categories = {finding["category"] for finding in report["findings"]}
        self.assertNotIn("fixed-size-risk", categories)
        self.assertNotIn("reduce-motion", categories)
        self.assertNotIn("focus-restoration", categories)
        self.assertEqual({finding["path"] for finding in report["findings"]}, {"Sources/Signals.swift"})
        rules = {item["ruleId"] for item in report["findings"]}
        self.assertIn("swiftui.empty-control-title", rules)
        self.assertIn("swiftui.state-color-signal", rules)
        self.assertIn("swiftui.indeterminate-control-title", rules)
        self.assertIn("swiftui.actionable-control-semantics", rules)

    def test_conditional_color_context_does_not_taint_adjacent_plain_style(self) -> None:
        self.write_source(
            "Sources/Color.swift",
            '''import SwiftUI
struct ColorReview: View {
    let active: Bool
    var body: some View {
        VStack {
            Text(active ? "Active" : "Inactive")
                .background(Color.clear)
            Text("State")
                .foregroundStyle(active ? Color.green : Color.red)
        }
    }
}
''',
        )
        report = self.parse_success(self.run_audit("--config", str(self.config())))
        color_findings = [item for item in report["findings"] if item["category"] == "color-only-state"]
        self.assertEqual(len(color_findings), 1)
        self.assertIn("foregroundStyle", color_findings[0]["evidence"])

    def test_additional_actionable_families_inspect_the_actual_label_region(self) -> None:
        self.write_source(
            "Sources/Controls.swift",
            '''import SwiftUI
struct Controls: View {
    @State private var date = Date()
    var body: some View {
        VStack {
            NavigationLink(destination: Text("Destination")) {
                Image(systemName: "arrow.right")
            }
            DisclosureGroup {
                Text("Body content is not the control label")
            } label: {
                Image(systemName: "chevron.right")
            }
            DatePicker("", selection: $date)
            NavigationLink("Safe destination", destination: Text("Safe detail"))
            DisclosureGroup("Safe details") { Text("Safe body") }
            DatePicker("Safe date", selection: $date)
        }
    }
}
''',
        )
        report = self.parse_success(self.run_audit("--config", str(self.config())))
        actionable = [
            item for item in report["findings"]
            if item["category"] == "actionable-control-semantics"
        ]
        summaries = "\n".join(str(item["summary"]) for item in actionable)
        self.assertIn("NavigationLink needs review", summaries)
        self.assertIn("DisclosureGroup needs review", summaries)
        self.assertIn("DatePicker uses an empty title", summaries)
        inventory = report["inventory"]["actionableControlCoverage"]
        self.assertEqual(inventory["NavigationLink"], {"occurrences": 2, "analyzed": 2, "skipped": 0})
        self.assertEqual(inventory["DisclosureGroup"], {"occurrences": 2, "analyzed": 2, "skipped": 0})
        self.assertEqual(inventory["DatePicker"], {"occurrences": 2, "analyzed": 2, "skipped": 0})

    def test_file_order_and_source_identity_are_deterministic(self) -> None:
        self.write_source("Sources/Z.swift", "import SwiftUI\nstruct Z: View { var body: some View { Text(\"Z\") } }\n")
        self.write_source("Sources/A.swift", "import SwiftUI\nstruct A: View { var body: some View { Text(\"A\") } }\n")
        configuration = self.config()
        first = self.run_audit("--config", str(configuration))
        second = self.run_audit("--config", str(configuration))
        first_report = self.parse_success(first)
        self.parse_success(second)
        self.assertEqual(first.stdout, second.stdout)
        paths = [entry["path"] for entry in first_report["coverage"]["files"]]
        self.assertEqual(paths, sorted(paths))
        original_digest = first_report["sourceIdentity"]["digest"]

        self.write_source("Sources/A.swift", "import SwiftUI\nstruct A: View { var body: some View { Text(\"Changed\") } }\n")
        changed = self.parse_success(self.run_audit("--config", str(configuration)))
        self.assertNotEqual(original_digest, changed["sourceIdentity"]["digest"])

    def test_invalid_config_and_unknown_category_fail_closed(self) -> None:
        self.write_source("Sources/UI.swift", "import SwiftUI\nstruct UI: View { var body: some View { Text(\"UI\") } }\n")
        unknown_category = self.config(categories=["fixed-size-risk", "runtime-proof"])
        self.assert_failure(
            self.run_audit("--config", str(unknown_category)),
            "unknown categories: runtime-proof",
        )
        invalid = json.loads(unknown_category.read_text(encoding="utf-8"))
        invalid["allowlist"] = []
        unknown_category.write_text(json.dumps(invalid) + "\n", encoding="utf-8")
        self.assert_failure(
            self.run_audit("--config", str(unknown_category)),
            "unknown fields: allowlist",
        )
        boolean_schema = self.config(schemaVersion=True)
        self.assert_failure(
            self.run_audit("--config", str(boolean_schema)),
            "schemaVersion must be an integer",
        )

    def test_missing_or_non_ui_coverage_fails_closed(self) -> None:
        missing = self.config(includeRoots=["Missing"])
        self.assert_failure(self.run_audit("--config", str(missing)), "include root is unavailable")

        non_ui = self.config()
        self.write_source("Sources/Model.swift", "struct Model { let value: Int }\n")
        self.assert_failure(self.run_audit("--config", str(non_ui)), "no SwiftUI source candidates")

    def test_invalid_utf8_source_fails_coverage(self) -> None:
        (self.root / "Sources" / "UI.swift").write_bytes(b"import SwiftUI\n\xff")
        self.assert_failure(
            self.run_audit("--config", str(self.config())),
            "source is not valid UTF-8",
        )

    def test_finding_bound_refuses_truncated_output(self) -> None:
        self.write_source(
            "Sources/Risky.swift",
            '''import SwiftUI
struct Risky: View {
    var body: some View {
        VStack {
            Text("One").frame(width: 10)
            Text("Two").frame(height: 10)
        }
    }
}
''',
        )
        result = self.run_audit("--config", str(self.config(maxFindings=1)))
        self.assert_failure(result, "findings would truncate")

    def test_file_and_byte_bounds_refuse_incomplete_coverage(self) -> None:
        self.write_source("Sources/A.swift", "import SwiftUI\nstruct A: View { var body: some View { Text(\"A\") } }\n")
        self.write_source("Sources/B.swift", "import SwiftUI\nstruct B: View { var body: some View { Text(\"B\") } }\n")
        self.assert_failure(
            self.run_audit("--config", str(self.config(maxFiles=1))),
            "coverage would truncate files",
        )
        self.assert_failure(
            self.run_audit("--config", str(self.config(maxFileBytes=16))),
            "coverage limit exceeded",
        )

    def test_swift_lexer_masks_strings_comments_and_regex_and_rejects_unterminated_input(self) -> None:
        source = self.write_source(
            "Sources/Lexical.swift",
            r'''import SwiftUI
struct Lexical: View {
    let bare = /Button\(|\.onTapGesture|\.frame\(width:/
    let extended = #/Toggle\(""|\.onLongPressGesture/#
    let escapedDelimiter = #/foo\/# Button("")/#
    let raw = #"Picker(\"\") .gesture(TapGesture())"#
    var body: some View { Toggle("Safe", isOn: .constant(true)) }
}
''',
        )
        report = self.parse_success(self.run_audit("--config", str(self.config())))
        controls = report["inventory"]["actionableControlCoverage"]
        gestures = report["inventory"]["actionableGestureCoverage"]
        self.assertEqual(controls["Toggle"], {"occurrences": 1, "analyzed": 1, "skipped": 0})
        self.assertEqual(controls["Button"], {"occurrences": 0, "analyzed": 0, "skipped": 0})
        self.assertEqual(sum(value["occurrences"] for value in gestures.values()), 0)
        self.assert_swift_typechecks(
            'import Foundation\nlet pattern = #/foo\\/# Button("")/#\n'
        )

        source.write_text('import SwiftUI\nlet value = "unterminated\n', encoding="utf-8")
        self.assert_failure(self.run_audit("--config", str(self.config())), "unterminated Swift string literal")
        source.write_text("import SwiftUI\n/* unterminated\n", encoding="utf-8")
        self.assert_failure(self.run_audit("--config", str(self.config())), "unterminated Swift block comment")
        source.write_text("import SwiftUI\nlet pattern = /unterminated\n", encoding="utf-8")
        self.assert_failure(self.run_audit("--config", str(self.config())), "unterminated Swift regex literal")

    def test_every_advertised_control_and_gesture_family_is_fully_reconciled(self) -> None:
        families_source = self.write_source(
            "Sources/Families.swift",
            '''import SwiftUI
struct Families: View {
    @State private var flag = false
    @State private var selection = 0
    @State private var date = Date()
    @State private var text = ""
    @State private var value = 0.5
    var body: some View {
        VStack {
            Button<Text>("Button", action: {})
            Link<Text>("Link", destination: URL(string: "https://example.invalid")!)
            Menu<Text, Text>("Menu") { Text("Item") }
            NavigationLink<Text, Text>("Navigation", destination: Text("Destination"))
            DisclosureGroup<Text, Text>("Disclosure") { Text("Content") }
            Toggle<Text>("Toggle", isOn: $flag)
            Picker<Text, Int, Text>("Picker", selection: $selection) { Text("Option") }
            DatePicker<Text>("Date", selection: $date)
            TextField<Text>("Text", text: $text)
            SecureField<Text>("Secure", text: $text)
            Slider<Text, Text>(value: $value) { Text("Slider") } minimumValueLabel: { Text("Minimum") } maximumValueLabel: { Text("Maximum") }
            Stepper<Text>("Stepper", value: $selection)
            semantic(Text("Tap").onTapGesture {})
            semantic(Text("Long").onLongPressGesture {})
            semantic(Text("Tap").gesture(TapGesture()))
            semantic(Text("Long").gesture(LongPressGesture()))
            semantic(Text("Tap").highPriorityGesture(TapGesture()))
            semantic(Text("Long").highPriorityGesture(LongPressGesture()))
            semantic(Text("Tap").simultaneousGesture(TapGesture()))
            semantic(Text("Long").simultaneousGesture(LongPressGesture()))
        }
    }
    func semantic<V: View>(_ view: V) -> some View {
        view.accessibilityLabel("Action")
            .accessibilityHint("Performs the action")
            .accessibilityAddTraits(.isButton)
    }
}
''',
        )
        report = self.parse_success(self.run_audit(
            "--config",
            str(self.config(categories=["actionable-control-semantics"])),
        ))
        for family, coverage in report["inventory"]["actionableControlCoverage"].items():
            self.assertEqual(coverage, {"occurrences": 1, "analyzed": 1, "skipped": 0}, family)
        for family, coverage in report["inventory"]["actionableGestureCoverage"].items():
            self.assertEqual(coverage, {"occurrences": 1, "analyzed": 1, "skipped": 0}, family)
        self.assert_swift_typechecks(families_source.read_text(encoding="utf-8"))

    def test_empty_and_indeterminate_label_values_remain_explicit_review_leads(self) -> None:
        fixture = '''import SwiftUI
struct LabelValues: View {
    let dynamic = "Dynamic"
    var body: some View {
        VStack {
            Button {} label: { Text("") }
            Button {} label: { Text("   ") }
            Button {} label: { Label("", systemImage: "star") }
            Button {} label: { Text(dynamic) }
            Button("Visible", action: {}).accessibilityLabel("")
            Button("Visible", action: {}).accessibilityLabel("   ")
            Button("Visible", action: {}).accessibilityLabel(dynamic)
            Button(dynamic, action: {}).accessibilityLabel("Owned fallback")
            Button {} label: { Text("Safe"); Text("") }
            Button {} label: { Text("Safe"); Text(dynamic) }
            Button {} label: { Text("\\(dynamic)") }
            Button {} label: { Text("\\n") }
            Button("Visible", action: {}).accessibilityLabel("\\(dynamic)")
            Button {} label: { Text("Safe") }
        }
    }
}
'''
        self.write_source("Sources/LabelValues.swift", fixture)
        report = self.parse_success(self.run_audit(
            "--config",
            str(self.config(categories=["actionable-control-semantics"])),
        ))
        rules = [finding["ruleId"] for finding in report["findings"]]
        self.assertEqual(rules.count("swiftui.empty-control-label"), 5)
        self.assertEqual(rules.count("swiftui.indeterminate-control-label"), 3)
        self.assertEqual(rules.count("swiftui.empty-accessibility-label"), 2)
        self.assertEqual(rules.count("swiftui.indeterminate-accessibility-label"), 2)
        self.assertEqual(rules.count("swiftui.indeterminate-control-title"), 1)
        arbitrary = next(
            finding for finding in report["findings"]
            if finding["ruleId"] == "swiftui.indeterminate-control-title"
        )
        self.assertEqual(arbitrary["details"]["ownedOuterAccessibilityLabelState"], "nonempty-literal")
        self.assertIn("arbitrary-positional-title", arbitrary["details"]["reviewReasons"])
        self.assert_swift_typechecks(fixture)

    def test_accessibility_markers_must_belong_to_the_outer_control_or_gesture_chain(self) -> None:
        self.write_source(
            "Sources/Ownership.swift",
            '''import SwiftUI
struct Ownership: View {
    var body: some View {
        VStack {
            NavigationLink(destination: Text("Destination").accessibilityLabel("Nested")) {
                Image(systemName: "arrow.right")
            }
            Button {} label: {
                Image(systemName: "trash").accessibilityLabel("Nested")
            }
            Button {} label: { Image(systemName: "safe") }
                .accessibilityLabel("Safe")
                .accessibilityHint("Opens safe action")
            Text("Gesture")
                .accessibilityLabel("Before is deliberately not claimed by this bounded heuristic")
                .onTapGesture {}
        }
    }
}
''',
        )
        report = self.parse_success(self.run_audit(
            "--config",
            str(self.config(categories=["actionable-control-semantics"])),
        ))
        actionable = report["findings"]
        summaries = "\n".join(item["summary"] for item in actionable)
        self.assertIn("NavigationLink needs review", summaries)
        self.assertIn("Button needs review", summaries)
        self.assertIn("onTapGesture needs review", summaries)
        self.assertNotIn("safe action", summaries)

    def test_empty_title_with_owned_explicit_semantics_is_not_a_false_positive(self) -> None:
        self.write_source(
            "Sources/Explicit.swift",
            '''import SwiftUI
struct Explicit: View {
    @State private var flag = false
    var body: some View {
        Toggle("", isOn: $flag)
            .accessibilityLabel("Enabled")
    }
}
''',
        )
        report = self.parse_success(self.run_audit(
            "--config",
            str(self.config(categories=["actionable-control-semantics"])),
        ))
        self.assertEqual(report["findings"], [])

    def test_nested_source_symlinks_and_unparseable_controls_fail_closed(self) -> None:
        self.write_source("Sources/UI.swift", "import SwiftUI\nstruct UI: View { var body: some View { Text(\"UI\") } }\n")
        external = self.root / "External"
        external.mkdir()
        (self.root / "Sources" / "Linked").symlink_to(external, target_is_directory=True)
        self.assert_failure(self.run_audit("--config", str(self.config())), "nested symlink entry")
        (self.root / "Sources" / "Linked").unlink()
        self.write_source("Sources/Broken.swift", "import SwiftUI\nlet broken = Button(\n")
        self.assert_failure(self.run_audit("--config", str(self.config())), "unterminated Swift expression")
        self.write_source("Sources/Broken.swift", "import SwiftUI\nlet broken = Button<Text(\n")
        self.assert_failure(self.run_audit("--config", str(self.config())), "unterminated Swift generic arguments")

    def test_stable_recheck_detects_same_identity_content_change_by_hash(self) -> None:
        path = self.write_source("Sources/UI.swift", "import SwiftUI\nlet value = 1\n")
        snapshot = AUDIT_MODULE.read_stable_path(path, "test source", 1_000_000)
        metadata = os.stat(path)
        path.write_text("import SwiftUI\nlet value = 2\n", encoding="utf-8")
        os.utime(path, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
        with self.assertRaisesRegex(AUDIT_MODULE.AuditError, "content changed"):
            AUDIT_MODULE.verify_stable_path(snapshot)

    def test_output_refuses_collisions_links_and_nonregular_destinations(self) -> None:
        source = self.write_source(
            "Sources/UI.swift",
            "import SwiftUI\nstruct UI: View { var body: some View { Text(\"UI\") } }\n",
        )
        configuration = self.config()
        original_source = source.read_bytes()

        self.assert_failure(
            self.run_audit("--config", str(configuration), "--output", str(source)),
            "outside scanned source roots",
        )
        self.assertEqual(source.read_bytes(), original_source)
        original_config = configuration.read_bytes()
        self.assert_failure(
            self.run_audit("--config", str(configuration), "--output", str(configuration)),
            "collides with protected source, config, or tool input",
        )
        self.assertEqual(configuration.read_bytes(), original_config)
        self.assert_failure(
            self.run_audit("--config", str(configuration), "--output", str(SCRIPT)),
            "collides with protected source, config, or tool input",
        )

        linked_output = self.root / "linked-report.json"
        linked_output.symlink_to(self.root / "target-report.json")
        self.assert_failure(
            self.run_audit("--config", str(configuration), "--output", str(linked_output)),
            "must not be a symlink",
        )
        directory_output = self.root / "directory-report"
        directory_output.mkdir()
        self.assert_failure(
            self.run_audit("--config", str(configuration), "--output", str(directory_output)),
            "regular file or absent",
        )
        hardlink_output = self.root / "hardlink-report.json"
        os.link(source, hardlink_output)
        self.assert_failure(
            self.run_audit("--config", str(configuration), "--output", str(hardlink_output)),
            "hard-link collides",
        )

        baseline = self.run_audit("--config", str(configuration))
        baseline_report = self.parse_success(baseline)
        output = self.root / "report.json"
        written = self.run_audit("--config", str(configuration), "--output", str(output))
        self.assertEqual(written.returncode, 0, written.stderr)
        self.assertEqual(written.stdout, "")
        self.assertEqual(output.read_text(encoding="utf-8"), baseline.stdout)
        self.assertEqual(
            baseline_report["coverage"]["files"][0]["sha256"],
            hashlib.sha256(original_source).hexdigest(),
        )

    def test_symlink_aliased_root_cannot_bypass_output_source_boundary(self) -> None:
        actual_parent = self.root / "actual"
        actual_root = actual_parent / "repo"
        source_root = actual_root / "Sources"
        source_root.mkdir(parents=True)
        source = source_root / "UI.swift"
        source_bytes = b'import SwiftUI\nstruct UI: View { var body: some View { Text("UI") } }\n'
        source.write_bytes(source_bytes)
        output = source_root / "inventory.json"
        output_bytes = b'{"sourceOwned":true}\n'
        output.write_bytes(output_bytes)
        alias_parent = self.root / "alias"
        alias_parent.symlink_to(actual_parent, target_is_directory=True)

        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--root",
                str(alias_parent / "repo"),
                "--format",
                "json",
                "--output",
                str(output),
            ],
            check=False,
            capture_output=True,
            text=True,
        )

        self.assert_failure(result, "output must be outside scanned source roots")
        self.assertEqual(source.read_bytes(), source_bytes)
        self.assertEqual(output.read_bytes(), output_bytes)

    def test_text_summary_preserves_review_boundary_and_digest(self) -> None:
        self.write_source(
            "Sources/UI.swift",
            "import SwiftUI\nstruct UI: View { var body: some View { Text(\"UI\").frame(width: 10) } }\n",
        )
        result = self.run_audit("--config", str(self.config()), "--format", "text")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("static-source-review-leads", result.stdout)
        self.assertIn("not proof of VoiceOver", result.stdout)
        self.assertIn("Findings digest:", result.stdout)


if __name__ == "__main__":
    unittest.main()
