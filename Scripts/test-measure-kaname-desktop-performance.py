#!/usr/bin/env python3
"""Deterministic fixture tests for the desktop performance harness."""

from __future__ import annotations

import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import textwrap
import unittest
import uuid


ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "Scripts/measure-kaname-desktop-performance.sh"


class DesktopPerformanceHarnessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="kaname-performance-test.")
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.state = self.root / "state"
        self.state.mkdir()
        self.dataset = self.root / "dataset.json"
        self.dataset.write_text('{"dataset":"fixture-v1"}\n', encoding="utf-8")
        self.app = self.make_app(channel="candidate")
        self.driver = self.make_driver()
        self.environment = os.environ.copy()
        self.environment["KANAME_PERFORMANCE_FIXTURE_STATE"] = str(self.state)
        self.environment["KANAME_PERFORMANCE_FIXTURE_DATASET"] = str(self.dataset)
        self.environment["KANAME_PERFORMANCE_FIXTURE_EXECUTABLE"] = str(
            (self.app / "Contents/MacOS/KanameFixture").resolve()
        )
        self.environment["KANAME_PERFORMANCE_FIXTURE_APP"] = str(self.app)
        (self.state / "environment.json").write_text(
            json.dumps(
                {
                    "architecture": "fixture-arm64",
                    "operatingSystemVersion": "99.1-fixture",
                    "power": {
                        "source": "AC Power",
                        "batteryState": "charging",
                        "batteryPercentage": 87,
                    },
                    "thermalStateAvailable": True,
                    "thermalState": "nominal",
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def make_app(
        self,
        *,
        channel: str,
        bundle_identifier: str = "com.cyberlane.kaname.desktop.candidate",
    ) -> pathlib.Path:
        suffix = bundle_identifier.rsplit(".", 1)[-1]
        app = self.root / f"Kaname-{channel}-{suffix}.app"
        executable = app / "Contents/MacOS/KanameFixture"
        executable.parent.mkdir(parents=True)
        info = {
            "CFBundleExecutable": "KanameFixture",
            "CFBundleIdentifier": bundle_identifier,
            "CFBundleShortVersionString": "9.9.9",
            "CFBundleVersion": "999",
            "KanameDesktopChannel": channel,
        }
        with (app / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        executable.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import json
                import os
                import pathlib
                import signal
                import sys
                import time

                arguments = sys.argv[1:]
                marker = "--desktop-qa-application-support-base"
                if marker not in arguments or arguments.index(marker) + 1 >= len(arguments):
                    raise SystemExit(64)
                support = pathlib.Path(arguments[arguments.index(marker) + 1])
                health = support / "Kaname Candidate/Runtime/ui-health.json"
                health.parent.mkdir(parents=True, exist_ok=True)
                temporary = health.with_suffix(".tmp")
                temporary.write_text(json.dumps({"processID": os.getpid()}), encoding="utf-8")
                temporary.replace(health)
                state = pathlib.Path(os.environ["KANAME_PERFORMANCE_FIXTURE_STATE"])
                with (state / "launches.jsonl").open("a", encoding="utf-8") as handle:
                    handle.write(json.dumps({"pid": os.getpid(), "support": str(support)}) + "\\n")
                if os.environ.get("KANAME_PERFORMANCE_FIXTURE_IGNORE_TERM") == "1":
                    signal.signal(signal.SIGTERM, lambda _signal, _frame: None)
                while True:
                    time.sleep(0.05)
                """
            ),
            encoding="utf-8",
        )
        executable.chmod(0o755)
        return app

    def make_driver(self) -> pathlib.Path:
        driver = self.root / "fixture-driver.py"
        driver.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import json
                import os
                import pathlib
                import shutil
                import sys

                state = pathlib.Path(os.environ["KANAME_PERFORMANCE_FIXTURE_STATE"])
                action = sys.argv[1]

                def increment(name):
                    path = state / name
                    value = int(path.read_text(encoding="utf-8")) if path.exists() else 0
                    value += 1
                    path.write_text(str(value), encoding="utf-8")
                    return value

                if action == "environment":
                    count = increment("environment-count")
                    if os.environ.get("KANAME_PERFORMANCE_FIXTURE_MALFORMED_ENVIRONMENT") == "1":
                        print('{"architecture":""}')
                        raise SystemExit(0)
                    print((state / "environment.json").read_text(encoding="utf-8"))
                    if count == 2 and os.environ.get("KANAME_PERFORMANCE_FIXTURE_MUTATE_DATASET") == "1":
                        pathlib.Path(os.environ["KANAME_PERFORMANCE_FIXTURE_DATASET"]).write_text(
                            '{"dataset":"mutated"}\\n', encoding="utf-8"
                        )
                    if count == 2 and os.environ.get("KANAME_PERFORMANCE_FIXTURE_REPLACE_DATASET") == "1":
                        dataset = pathlib.Path(os.environ["KANAME_PERFORMANCE_FIXTURE_DATASET"])
                        replacement = dataset.with_suffix(".replacement")
                        replacement.write_bytes(dataset.read_bytes())
                        replacement.replace(dataset)
                    if count == 2 and os.environ.get("KANAME_PERFORMANCE_FIXTURE_REWRITE_DATASET_METADATA") == "1":
                        dataset = pathlib.Path(os.environ["KANAME_PERFORMANCE_FIXTURE_DATASET"])
                        original = dataset.read_bytes()
                        dataset.write_bytes(original)
                        dataset.chmod(0o600)
                    if count == 2 and os.environ.get("KANAME_PERFORMANCE_FIXTURE_REPLACE_BUNDLE") == "1":
                        app = pathlib.Path(os.environ["KANAME_PERFORMANCE_FIXTURE_APP"])
                        moved = app.with_name(app.name + ".moved")
                        app.rename(moved)
                        shutil.copytree(moved, app)
                    if count == 2 and os.environ.get("KANAME_PERFORMANCE_FIXTURE_REPLACE_OUTPUT_PARENT"):
                        parent = pathlib.Path(os.environ["KANAME_PERFORMANCE_FIXTURE_REPLACE_OUTPUT_PARENT"])
                        moved = parent.with_name(parent.name + ".moved")
                        parent.rename(moved)
                        parent.mkdir()
                elif action == "clock":
                    values = json.loads((state / "clock-values.json").read_text(encoding="utf-8"))
                    index = increment("clock-index") - 1
                    if index >= len(values):
                        raise SystemExit(70)
                    print(values[index])
                elif action == "background":
                    (state / "active").write_text("false", encoding="utf-8")
                elif action == "activate":
                    count = increment("activation-count")
                    failure = int(os.environ.get("KANAME_PERFORMANCE_FIXTURE_FAIL_ACTIVATION", "0"))
                    if count == failure:
                        raise SystemExit(71)
                    (state / "active").write_text("true", encoding="utf-8")
                elif action == "is-active":
                    active = state / "active"
                    print(active.read_text(encoding="utf-8") if active.exists() else "false")
                elif action == "ui-applications":
                    injected = os.environ.get("KANAME_PERFORMANCE_FIXTURE_RAW_UI_APPLICATIONS")
                    processes = json.loads(injected) if injected is not None else []
                    launches = state / "launches.jsonl"
                    if launches.exists():
                        for line in launches.read_text(encoding="utf-8").splitlines():
                            launch = json.loads(line)
                            try:
                                os.kill(launch["pid"], 0)
                            except ProcessLookupError:
                                continue
                            processes.append(
                                {
                                    "pid": launch["pid"],
                                    "bundleIdentifier": "com.cyberlane.kaname.desktop.candidate",
                                }
                            )
                    if os.environ.get("KANAME_PERFORMANCE_FIXTURE_EXTRA_UI") == "1":
                        processes.append(
                            {
                                "pid": 99999,
                                "bundleIdentifier": "com.cyberlane.kaname.desktop.unknown",
                            }
                        )
                    print(json.dumps(processes))
                elif action == "ui-executable":
                    pid = int(sys.argv[2])
                    injected = os.environ.get("KANAME_PERFORMANCE_FIXTURE_UI_EXECUTABLES")
                    if injected is not None:
                        injected_paths = json.loads(injected)
                        if str(pid) in injected_paths:
                            print(injected_paths[str(pid)])
                            raise SystemExit(0)
                    launches = state / "launches.jsonl"
                    if launches.exists():
                        for line in launches.read_text(encoding="utf-8").splitlines():
                            launch = json.loads(line)
                            if launch["pid"] == pid:
                                try:
                                    os.kill(pid, 0)
                                except ProcessLookupError:
                                    break
                                print(os.environ["KANAME_PERFORMANCE_FIXTURE_EXECUTABLE"])
                                raise SystemExit(0)
                    if pid == 99999 and os.environ.get("KANAME_PERFORMANCE_FIXTURE_EXTRA_UI") == "1":
                        print(os.environ["KANAME_PERFORMANCE_FIXTURE_EXECUTABLE"])
                        raise SystemExit(0)
                    print("")
                else:
                    raise SystemExit(64)
                """
            ),
            encoding="utf-8",
        )
        driver.chmod(0o755)
        return driver

    def clock_values(self, repetitions: int) -> None:
        values: list[int] = []
        for index in range(1, repetitions + 1):
            start = index * 1_000
            values.extend((start, start + index * 100))
        for index in range(1, repetitions + 1):
            start = 100_000 + index * 1_000
            values.extend((start, start + index * 100))
        (self.state / "clock-values.json").write_text(json.dumps(values), encoding="utf-8")

    def command(
        self,
        *,
        repetitions: str = "5",
        output: pathlib.Path | None = None,
        fixture: bool = True,
        runtime_authorized: bool = False,
        app: pathlib.Path | None = None,
        extra_environment: dict[str, str] | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], pathlib.Path]:
        receipt = output or (self.root / "receipt.json")
        arguments = [
            str(SCRIPT),
            "--app",
            str(app or self.app),
            "--output",
            str(receipt),
            "--dataset",
            str(self.dataset),
            "--repetitions",
            repetitions,
        ]
        if fixture:
            arguments.extend(("--fixture-driver", str(self.driver)))
        if runtime_authorized:
            arguments.append("--runtime-authorized")
        environment = self.environment.copy()
        if extra_environment:
            environment.update(extra_environment)
        completed = subprocess.run(
            arguments,
            cwd=ROOT,
            env=environment,
            capture_output=True,
            text=True,
            timeout=30,
        )
        return completed, receipt

    def assert_preflight_rejected_before_launch(
        self,
        expected_message: str,
        **command_arguments: object,
    ) -> None:
        completed, receipt_path = self.command(**command_arguments)
        self.assertEqual(completed.returncode, 2, completed.stderr)
        self.assertIn(expected_message, completed.stderr)
        self.assertFalse(receipt_path.exists())
        self.assertFalse((self.state / "launches.jsonl").exists())

    def assert_artifact_drift(
        self,
        *,
        environment_flag: str,
        artifact_name: str,
        failure_code: str,
        same_digest: bool,
    ) -> None:
        self.clock_values(1)
        completed, receipt_path = self.command(
            repetitions="1",
            extra_environment={environment_flag: "1"},
        )
        self.assertEqual(completed.returncode, 1, completed.stderr)
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        artifact = receipt["artifacts"][artifact_name]
        digest_key = next(
            key for key in artifact
            if key.endswith("Digest") and key != "completedDigest"
        )
        self.assertEqual(artifact[digest_key] == artifact["completedDigest"], same_digest)
        self.assertFalse(artifact["unchanged"])
        self.assertIn(failure_code, {failure["code"] for failure in receipt["failures"]})
        self.assertFalse(receipt["passed"])

    def assert_injected_ui_blocks_all_launches(
        self,
        *,
        bundle_identifier: str,
        executable: str,
    ) -> None:
        self.clock_values(1)
        completed, receipt_path = self.command(
            repetitions="1",
            extra_environment={
                "KANAME_PERFORMANCE_FIXTURE_RAW_UI_APPLICATIONS": json.dumps(
                    [{"pid": 424242, "bundleIdentifier": bundle_identifier}]
                ),
                "KANAME_PERFORMANCE_FIXTURE_UI_EXECUTABLES": json.dumps(
                    {"424242": executable}
                ),
            },
        )
        self.assertEqual(completed.returncode, 1, completed.stderr)
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        attempts = [
            attempt
            for metric in ("coldLaunch", "warmResume")
            for attempt in receipt["measurements"][metric]["attempts"]
        ]
        self.assertEqual(len(attempts), 2)
        self.assertTrue(all(attempt["status"] == "failure" for attempt in attempts))
        self.assertTrue(
            all(
                attempt["failure"]["code"]
                in {"another-kaname-ui-running", "ui-process-inventory-unavailable"}
                for attempt in attempts
            )
        )
        self.assertFalse((self.state / "launches.jsonl").exists())
        self.assertFalse(receipt["passed"])

    def test_fixture_receipt_retains_samples_percentiles_environment_and_exact_pid_semantics(self) -> None:
        self.clock_values(5)

        completed, receipt_path = self.command()

        self.assertEqual(completed.returncode, 0, completed.stderr)
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        self.assertEqual(receipt["schemaVersion"], 2)
        self.assertEqual(receipt["evidenceLane"], "fixture")
        self.assertFalse(receipt["authority"]["operatorRuntimeAuthorizationAsserted"])
        self.assertIn("not stored owner authority", receipt["authority"]["statement"])
        self.assertEqual(receipt["protocol"]["requestedRepetitionsPerMetric"], 5)
        self.assertEqual(receipt["protocol"]["maximumAllowedRepetitionsPerMetric"], 100)
        self.assertEqual(receipt["protocol"]["percentileMethod"], "nearest-rank")
        self.assertTrue(receipt["protocol"]["warmResumeUsesSameReadyProcess"])
        self.assertTrue(receipt["protocol"]["launchExcludedFromWarmResume"])
        self.assertIn("caches are not purged", receipt["protocol"]["coldLaunchDefinition"])
        self.assertIn("Same already-ready process PID", receipt["protocol"]["warmForegroundResumeDefinition"])
        self.assertEqual(receipt["environment"]["started"], receipt["environment"]["completed"])
        self.assertEqual(receipt["environment"]["started"]["power"]["batteryPercentage"], 87)
        self.assertEqual(receipt["environment"]["started"]["thermalState"], "nominal")
        for artifact in receipt["artifacts"].values():
            digest_key = next(key for key in artifact if key.endswith("Digest") and key != "completedDigest")
            self.assertRegex(artifact[digest_key], r"^[0-9a-f]{64}$")
            self.assertTrue(artifact["unchanged"])
        self.assertFalse(receipt["artifacts"]["source"]["bundleProvenanceAsserted"])

        cold = receipt["measurements"]["coldLaunch"]
        warm = receipt["measurements"]["warmResume"]
        self.assertEqual([attempt["repetition"] for attempt in cold["attempts"]], [1, 2, 3, 4, 5])
        self.assertEqual([attempt["durationNanoseconds"] for attempt in cold["attempts"]], [100, 200, 300, 400, 500])
        self.assertEqual([attempt["durationNanoseconds"] for attempt in warm["attempts"]], [100, 200, 300, 400, 500])
        for lane in (cold, warm):
            self.assertTrue(lane["summary"]["repetitionSetComplete"])
            self.assertEqual(lane["summary"]["attemptCount"], 5)
            self.assertEqual(lane["summary"]["sampleCount"], 5)
            self.assertEqual(lane["summary"]["failureCount"], 0)
            self.assertEqual(lane["summary"]["p50Nanoseconds"], 300)
            self.assertEqual(lane["summary"]["p95Nanoseconds"], 500)
            self.assertEqual(lane["summary"]["p99Nanoseconds"], 500)
            self.assertTrue(lane["summary"]["meetsBudget"])
        warm_pids = {attempt["processID"] for attempt in warm["attempts"]}
        self.assertEqual(len(warm_pids), 1)
        launches = [json.loads(line) for line in (self.state / "launches.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertEqual(len(launches), 6)
        self.assertEqual(len({launch["support"] for launch in launches}), 6)
        self.assertTrue(receipt["passed"])
        self.assertFalse(receipt["evidenceBoundary"]["candidateRuntimeMeasured"])
        self.assertFalse(receipt["evidenceBoundary"]["ownerAccepted"])

    def test_failed_repetition_is_retained_and_cannot_be_masked_by_fast_successes(self) -> None:
        self.clock_values(3)

        completed, receipt_path = self.command(
            repetitions="3",
            extra_environment={"KANAME_PERFORMANCE_FIXTURE_FAIL_ACTIVATION": "2"},
        )

        self.assertEqual(completed.returncode, 1, completed.stderr)
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        attempts = receipt["measurements"]["warmResume"]["attempts"]
        self.assertEqual([attempt["repetition"] for attempt in attempts], [1, 2, 3])
        self.assertEqual([attempt["status"] for attempt in attempts], ["success", "failure", "success"])
        self.assertEqual(attempts[1]["failure"]["code"], "activation-request-failed")
        summary = receipt["measurements"]["warmResume"]["summary"]
        self.assertEqual(summary["attemptCount"], 3)
        self.assertEqual(summary["sampleCount"], 2)
        self.assertEqual(summary["failureCount"], 1)
        self.assertLess(summary["p95Nanoseconds"], summary["budgetNanoseconds"])
        self.assertFalse(summary["meetsBudget"])
        self.assertEqual(len(receipt["failures"]), 1)
        self.assertFalse(receipt["passed"])

    def test_dataset_drift_after_measurement_is_explicit_and_fails_receipt(self) -> None:
        self.assert_artifact_drift(
            environment_flag="KANAME_PERFORMANCE_FIXTURE_MUTATE_DATASET",
            artifact_name="dataset",
            failure_code="dataset-changed",
            same_digest=False,
        )

    def test_same_bytes_dataset_identity_replacement_is_explicit_and_fails_receipt(self) -> None:
        self.assert_artifact_drift(
            environment_flag="KANAME_PERFORMANCE_FIXTURE_REPLACE_DATASET",
            artifact_name="dataset",
            failure_code="dataset-changed",
            same_digest=True,
        )

    def test_same_inode_same_bytes_dataset_metadata_rewrite_fails_identity(self) -> None:
        self.assert_artifact_drift(
            environment_flag="KANAME_PERFORMANCE_FIXTURE_REWRITE_DATASET_METADATA",
            artifact_name="dataset",
            failure_code="dataset-changed",
            same_digest=True,
        )

    def test_same_bytes_bundle_directory_replacement_is_explicit_and_fails_receipt(self) -> None:
        self.assert_artifact_drift(
            environment_flag="KANAME_PERFORMANCE_FIXTURE_REPLACE_BUNDLE",
            artifact_name="bundle",
            failure_code="bundle-changed",
            same_digest=True,
        )

    def test_symlink_ancestors_are_rejected_before_fixture_launch(self) -> None:
        self.clock_values(1)
        real = self.root / "real-inputs"
        real.mkdir()
        linked = self.root / "linked-inputs"
        linked.symlink_to(real, target_is_directory=True)
        linked_dataset = linked / "dataset.json"
        (real / "dataset.json").write_bytes(self.dataset.read_bytes())
        linked_root = self.root / "linked-root"
        linked_root.symlink_to(self.root, target_is_directory=True)
        cases = {
            "dataset": (self.app, linked_dataset, self.root / "dataset-receipt.json"),
            "app": (linked_root / self.app.name, self.dataset, self.root / "app-receipt.json"),
            "output": (self.app, self.dataset, linked / "output-receipt.json"),
        }
        for name, (app, dataset, receipt_path) in cases.items():
            with self.subTest(name=name):
                arguments = [
                    str(SCRIPT), "--app", str(app), "--output", str(receipt_path),
                    "--dataset", str(dataset), "--repetitions", "1",
                    "--fixture-driver", str(self.driver),
                ]
                completed = subprocess.run(
                    arguments, cwd=ROOT, env=self.environment, capture_output=True, text=True, timeout=30
                )
                self.assertNotEqual(completed.returncode, 0)
                self.assertFalse(receipt_path.exists())
        self.assertFalse((self.state / "launches.jsonl").exists())

    def test_output_parent_identity_replacement_is_refused_without_redirected_receipt(self) -> None:
        self.clock_values(1)
        parent = self.root / "bound-output"
        parent.mkdir()
        output = parent / "receipt.json"

        completed, receipt_path = self.command(
            repetitions="1",
            output=output,
            extra_environment={"KANAME_PERFORMANCE_FIXTURE_REPLACE_OUTPUT_PARENT": str(parent)},
        )

        self.assertEqual(completed.returncode, 2, completed.stderr)
        self.assertIn("identity-bound output directory", completed.stderr)
        self.assertFalse(receipt_path.exists())
        self.assertFalse((self.root / "bound-output.moved" / "receipt.json").exists())

    def test_output_parent_swap_between_check_and_replace_removes_installed_receipt(self) -> None:
        self.clock_values(1)
        parent = self.root / "racing-output"
        parent.mkdir()
        output = parent / "receipt.json"

        completed, receipt_path = self.command(
            repetitions="1",
            output=output,
            extra_environment={"KANAME_PERFORMANCE_FIXTURE_SWAP_OUTPUT_DURING_INSTALL": str(parent)},
        )

        self.assertEqual(completed.returncode, 2, completed.stderr)
        self.assertIn("identity-bound output directory", completed.stderr)
        self.assertFalse(receipt_path.exists())
        moved = self.root / "racing-output.moved-during-install"
        self.assertTrue(moved.is_dir())
        self.assertFalse((moved / "receipt.json").exists())
        self.assertEqual(list(moved.glob(".kaname-performance-receipt.*")), [])

    def test_output_mutation_hook_is_structurally_disabled_for_real_mode(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        installer = source.split("install_receipt_atomically() {", 1)[1].split(
            "output_location=", 1
        )[0]
        invocation = source.split('receipt_passed="$(install_receipt_atomically', 1)[1].split(
            ")\"", 1
        )[0]

        self.assertIn('evidence_lane not in {"fixture", "candidate-runtime"}', installer)
        self.assertIn('if evidence_lane != "fixture":', installer)
        self.assertIn('fixture output mutation hook is disabled outside fixture mode', installer)
        self.assertIn('"$evidence_lane"', invocation)

    def test_output_inside_repository_is_excluded_without_claiming_source_drift(self) -> None:
        self.clock_values(1)
        output = ROOT / f".performance-fixture-{uuid.uuid4().hex}.json"
        self.addCleanup(output.unlink, missing_ok=True)

        completed, receipt_path = self.command(repetitions="1", output=output)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        self.assertTrue(receipt["artifacts"]["source"]["exactOutputReceiptExcluded"])
        self.assertEqual(
            receipt["artifacts"]["source"]["digestAlgorithm"],
            "sha256-git-visible-source-excluding-exact-output-v1",
        )
        self.assertTrue(receipt["artifacts"]["source"]["unchanged"])
        self.assertNotIn("source-changed", {failure["code"] for failure in receipt["failures"]})

    def test_existing_in_repository_output_is_excluded_from_repeatable_source_identity(self) -> None:
        output = ROOT / f".performance-existing-{uuid.uuid4().hex}.json"
        self.addCleanup(output.unlink, missing_ok=True)
        output.write_text('{"old":"receipt"}\n', encoding="utf-8")
        self.clock_values(1)

        first_completed, receipt_path = self.command(repetitions="1", output=output)
        self.assertEqual(first_completed.returncode, 0, first_completed.stderr)
        first = json.loads(receipt_path.read_text(encoding="utf-8"))
        for state_file in (
            "active",
            "activation-count",
            "clock-index",
            "environment-count",
            "launches.jsonl",
        ):
            (self.state / state_file).unlink(missing_ok=True)
        self.clock_values(1)

        second_completed, receipt_path = self.command(repetitions="1", output=output)
        self.assertEqual(second_completed.returncode, 0, second_completed.stderr)
        second = json.loads(receipt_path.read_text(encoding="utf-8"))

        self.assertEqual(
            first["artifacts"]["source"]["sourceDigest"],
            second["artifacts"]["source"]["sourceDigest"],
        )
        self.assertTrue(second["artifacts"]["source"]["exactOutputReceiptExcluded"])
        self.assertTrue(second["artifacts"]["source"]["unchanged"])

    def test_source_snapshot_encodes_missing_tracked_parent_as_missing_entry(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        embedded = source.split("source_digest() {", 1)[1].split("<<'PY'\n", 1)[1].split(
            "\nPY\n}", 1
        )[0]
        repository = self.root / "source-fixture"
        repository.mkdir()
        subprocess.run(["git", "init", "-q", str(repository)], check=True)
        tracked = repository / "nested" / "tracked.txt"
        tracked.parent.mkdir()
        tracked.write_text("tracked\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(repository), "add", "nested/tracked.txt"], check=True)
        shutil.rmtree(tracked.parent)

        completed = subprocess.run(
            ["python3", "-", str(repository), str(self.root / "outside-receipt.json")],
            input=embedded,
            capture_output=True,
            text=True,
            timeout=30,
        )

        self.assertEqual(completed.returncode, 0, completed.stderr)
        fields = completed.stdout.strip().split("|")
        self.assertEqual(len(fields), 4)
        self.assertRegex(fields[0], r"^[0-9a-f]{64}$")
        self.assertRegex(fields[3], r"^[0-9a-f]{64}$")

    def test_forced_child_termination_is_bounded_retained_and_fails_the_receipt(self) -> None:
        self.clock_values(1)

        completed, receipt_path = self.command(
            repetitions="1",
            extra_environment={"KANAME_PERFORMANCE_FIXTURE_IGNORE_TERM": "1"},
        )

        self.assertEqual(completed.returncode, 1, completed.stderr)
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        cold_attempt = receipt["measurements"]["coldLaunch"]["attempts"][0]
        self.assertEqual(cold_attempt["status"], "failure")
        self.assertEqual(cold_attempt["failure"]["code"], "forced-termination")
        self.assertEqual(cold_attempt["observedDurationNanoseconds"], 100)
        self.assertGreater(cold_attempt["observedResidentKilobytes"], 0)
        codes = {failure["code"] for failure in receipt["failures"]}
        self.assertIn("forced-termination", codes)
        self.assertIn("warm-process-forced-termination", codes)
        self.assertFalse(receipt["passed"])

    def test_forced_kill_is_guarded_by_spawned_identity_and_real_executable(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        identity_body = source.split("read_process_identity() {", 1)[1].split(
            "active_pid=", 1
        )[0]
        termination_body = source.split("terminate_active_process() {", 1)[1].split(
            "current_health=", 1
        )[0]
        forced_kill = termination_body.index('kill -KILL "$pid"')

        self.assertIn('-o ppid= -o lstart=', identity_body)
        self.assertIn('"$identity" == "$$ "*', identity_body)
        self.assertGreater(
            termination_body.rfind("process_matches_spawned_identity", 0, forced_kill),
            -1,
        )
        self.assertGreater(
            termination_body.rfind("process_matches_expected_executable", 0, forced_kill),
            -1,
        )
        self.assertGreater(
            termination_body.rfind("shell_job_is_running", 0, forced_kill),
            -1,
        )
        self.assertIn("attempts < 100", termination_body)

    def test_spawn_identity_capture_failure_reaps_every_fixture_child(self) -> None:
        mock_bin = self.root / "mock-bin"
        mock_bin.mkdir()
        mock_ps = mock_bin / "ps"
        mock_ps.write_text(
            textwrap.dedent(
                """\
                #!/bin/sh
                case "$*" in
                  *"ppid="*"lstart="*) exit 75 ;;
                esac
                exec /bin/ps "$@"
                """
            ),
            encoding="utf-8",
        )
        mock_ps.chmod(0o755)
        self.clock_values(1)

        completed, receipt_path = self.command(
            repetitions="1",
            extra_environment={"PATH": f"{mock_bin}:{self.environment['PATH']}"},
        )

        self.assertEqual(completed.returncode, 1, completed.stderr)
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        cold_attempt = receipt["measurements"]["coldLaunch"]["attempts"][0]
        warm_attempt = receipt["measurements"]["warmResume"]["attempts"][0]
        self.assertEqual(cold_attempt["failure"]["code"], "spawn-identity-unavailable")
        self.assertEqual(warm_attempt["failure"]["code"], "spawn-identity-unavailable")
        launches = [
            json.loads(line)
            for line in (self.state / "launches.jsonl").read_text(encoding="utf-8").splitlines()
        ]
        self.assertEqual(len(launches), 2)
        for launch in launches:
            with self.assertRaises(ProcessLookupError):
                os.kill(launch["pid"], 0)
        self.assertFalse(receipt["passed"])

    def test_malformed_environment_fails_before_any_fixture_process_launch(self) -> None:
        self.clock_values(1)
        self.assert_preflight_rejected_before_launch(
            "Environment metadata is malformed or unavailable",
            repetitions="1",
            extra_environment={"KANAME_PERFORMANCE_FIXTURE_MALFORMED_ENVIRONMENT": "1"},
        )

    def test_real_mode_requires_explicit_one_run_operator_assertion_before_launch(self) -> None:
        self.clock_values(1)
        self.assert_preflight_rejected_before_launch(
            "one-run --runtime-authorized operator assertion",
            repetitions="1",
            fixture=False,
        )

    def test_renamed_or_unknown_kaname_ui_blocks_every_fixture_repetition_without_launching(self) -> None:
        self.clock_values(2)

        completed, receipt_path = self.command(
            repetitions="2",
            extra_environment={"KANAME_PERFORMANCE_FIXTURE_EXTRA_UI": "1"},
        )

        self.assertEqual(completed.returncode, 1, completed.stderr)
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        for metric in ("coldLaunch", "warmResume"):
            attempts = receipt["measurements"][metric]["attempts"]
            self.assertEqual(len(attempts), 2)
            self.assertTrue(all(attempt["status"] == "failure" for attempt in attempts))
            self.assertTrue(
                all(attempt["failure"]["code"] == "another-kaname-ui-running" for attempt in attempts)
            )
        self.assertFalse((self.state / "launches.jsonl").exists())
        self.assertFalse(receipt["passed"])

    def test_canonical_bundle_with_unresolved_executable_blocks_all_launches(self) -> None:
        self.assert_injected_ui_blocks_all_launches(
            bundle_identifier="com.cyberlane.kaname.desktop.candidate",
            executable="",
        )

    def test_renamed_bundle_with_kaname_channel_metadata_blocks_all_launches(self) -> None:
        original = self.make_app(channel="stable", bundle_identifier="example.renamed.utility")
        renamed = self.root / "Renamed Utility.app"
        original.rename(renamed)
        self.assert_injected_ui_blocks_all_launches(
            bundle_identifier="example.renamed.utility",
            executable=str(renamed / "Contents/MacOS/KanameFixture"),
        )

    def test_direct_kaname_prototype_process_blocks_all_launches(self) -> None:
        prototype = self.root / "KanamePrototype"
        prototype.write_text("fixture", encoding="utf-8")
        self.assert_injected_ui_blocks_all_launches(
            bundle_identifier="",
            executable=str(prototype),
        )

    def test_unknown_kaname_shaped_app_with_unresolved_metadata_blocks_all_launches(self) -> None:
        executable = self.root / "Kaname Mystery.app/Contents/MacOS/Mystery"
        executable.parent.mkdir(parents=True)
        executable.write_text("fixture", encoding="utf-8")
        self.assert_injected_ui_blocks_all_launches(
            bundle_identifier="example.unknown",
            executable=str(executable),
        )

    def test_foreign_non_kaname_process_does_not_block_fixture_launches(self) -> None:
        self.clock_values(1)
        completed, receipt_path = self.command(
            repetitions="1",
            extra_environment={
                "KANAME_PERFORMANCE_FIXTURE_RAW_UI_APPLICATIONS": json.dumps(
                    [{"pid": 424242, "bundleIdentifier": "example.foreign.utility"}]
                ),
                "KANAME_PERFORMANCE_FIXTURE_UI_EXECUTABLES": json.dumps(
                    {"424242": "/usr/bin/foreign-utility"}
                ),
            },
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertTrue(json.loads(receipt_path.read_text(encoding="utf-8"))["passed"])
        self.assertTrue((self.state / "launches.jsonl").exists())

    def test_fixture_and_runtime_assertion_cannot_be_combined(self) -> None:
        self.clock_values(1)

        completed, receipt_path = self.command(repetitions="1", runtime_authorized=True)

        self.assertEqual(completed.returncode, 2)
        self.assertIn("mutually exclusive", completed.stderr)
        self.assertFalse(receipt_path.exists())

    def assert_noncanonical_bundle_rejected(self, expected_error: str, **app_arguments: str) -> None:
        self.clock_values(1)
        invalid_app = self.make_app(**app_arguments)
        self.assert_preflight_rejected_before_launch(
            expected_error,
            repetitions="1",
            app=invalid_app,
        )

    def test_stable_channel_is_rejected_before_launch(self) -> None:
        self.assert_noncanonical_bundle_rejected(
            "accepts the Candidate channel only",
            channel="stable",
        )

    def test_foreign_candidate_shaped_bundle_is_rejected_before_launch(self) -> None:
        self.assert_noncanonical_bundle_rejected(
            "canonical Kaname Candidate bundle identifier",
            channel="candidate",
            bundle_identifier="example.foreign.candidate-shaped",
        )

    def test_relative_app_path_is_canonicalized_before_exact_process_comparison(self) -> None:
        self.clock_values(1)
        relative_app = pathlib.Path(os.path.relpath(self.app, ROOT))

        completed, receipt_path = self.command(repetitions="1", app=relative_app)

        self.assertEqual(completed.returncode, 0, completed.stderr)
        receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
        self.assertTrue(receipt["passed"])
        warm_pids = {
            attempt["processID"] for attempt in receipt["measurements"]["warmResume"]["attempts"]
        }
        self.assertEqual(len(warm_pids), 1)

    def test_repetition_parser_rejects_noncanonical_or_unbounded_values_before_launch(self) -> None:
        for value in ("0", "01", "-1", "101", "999999999999999999999999", "not-a-number"):
            with self.subTest(value=value):
                completed, receipt_path = self.command(repetitions=value)
                self.assertEqual(completed.returncode, 2)
                self.assertIn("--repetitions", completed.stderr)
                self.assertFalse(receipt_path.exists())
        self.assertFalse((self.state / "launches.jsonl").exists())

    def test_tracked_repository_output_is_rejected(self) -> None:
        self.clock_values(1)
        tracked_output = ROOT / "Package.swift"
        before = tracked_output.read_bytes()

        completed, _ = self.command(
            repetitions="1",
            output=tracked_output,
            extra_environment={"KANAME_PERFORMANCE_FIXTURE_MALFORMED_ENVIRONMENT": "1"},
        )

        self.assertEqual(completed.returncode, 2)
        self.assertIn("must not replace a tracked repository file", completed.stderr)
        self.assertEqual(tracked_output.read_bytes(), before)
        self.assertFalse((self.state / "launches.jsonl").exists())


if __name__ == "__main__":
    unittest.main()
