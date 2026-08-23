#!/usr/bin/env python3
"""Regression tests for Kaname's task-worktree commit-readiness helper."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest
from typing import Optional


SCRIPT = Path(__file__).with_name("kaname-commit-ready.py").resolve()


class CommitReadinessTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="kaname-readiness-test-")
        self.root = Path(self.temporary.name).resolve()
        self.repository = self.root / "repository"
        self.repository.mkdir()
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Kaname Test")
        self.git("config", "user.email", "kaname-test@invalid.example")
        (self.repository / ".gitignore").write_text(".build/\n", encoding="utf-8")
        (self.repository / ".mori-version").write_text("v0.31.0\n", encoding="utf-8")
        (self.repository / ".mori-project.json").write_text("{}\n", encoding="utf-8")
        (self.repository / "source.py").write_text("def value():\n    return 1\n", encoding="utf-8")
        (self.repository / "other.py").write_text("def other():\n    return 1\n", encoding="utf-8")
        self.git("add", ".")
        self.git("commit", "-m", "fixture")
        (self.repository / ".git" / "info" / "exclude").write_text("/AGENTS.md\n", encoding="utf-8")
        (self.repository / "AGENTS.md").write_text("# Local instructions\n", encoding="utf-8")

        self.binary_directory = self.root / "bin"
        self.binary_directory.mkdir()
        self.fake_mori = self.binary_directory / "mori"
        self.fake_mori.write_text(self.fake_mori_source(), encoding="utf-8")
        self.fake_mori.chmod(0o700)
        self.environment = os.environ.copy()
        self.environment["PATH"] = str(self.binary_directory) + os.pathsep + self.environment["PATH"]

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def git(self, *arguments: str, cwd: Optional[Path] = None) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["git", *arguments],
            cwd=str(cwd or self.repository),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

    def helper(self, *arguments: str, cwd: Path, check: bool = False) -> subprocess.CompletedProcess:
        result = subprocess.run(
            ["python3", str(SCRIPT), *arguments],
            cwd=str(cwd),
            env=self.environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if check and result.returncode != 0:
            self.fail(f"helper failed:\nstdout:\n{result.stdout}\nstderr:\n{result.stderr}")
        return result

    def new_worktree(self, slug: str) -> Path:
        target = self.root / "worktrees" / slug
        self.helper(
            "new-worktree",
            slug,
            "--branch",
            f"test/{slug}",
            "--target",
            str(target),
            cwd=self.repository,
            check=True,
        )
        return target.resolve()

    def changed_worktree(self, slug: str) -> Path:
        worktree = self.new_worktree(slug)
        (worktree / "source.py").write_text("def value():\n    return 2\n", encoding="utf-8")
        return worktree

    def prepare_source(
        self,
        worktree: Path,
        *options: str,
        check: bool = True,
    ) -> subprocess.CompletedProcess:
        return self.helper("prepare", *options, "--", "source.py", cwd=worktree, check=check)

    def assert_prepare_rejected(self, worktree: Path, expected: str, *options: str) -> None:
        result = self.prepare_source(worktree, *options, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn(expected, result.stderr)

    def assert_ready(self, worktree: Path) -> None:
        verified = self.helper("verify", cwd=worktree, check=True)
        self.assertIn("receipt is current", verified.stdout)

    def test_prepare_and_verify_exact_snapshot_then_reject_index_drift(self) -> None:
        worktree = self.changed_worktree("ready")
        self.assertEqual((worktree / "AGENTS.md").read_text(encoding="utf-8"), "# Local instructions\n")
        prepared = self.prepare_source(
            worktree,
            "--test",
            'test "$KANAME_TASK_WORKTREE" = "$(pwd -P)" && test -d "$(dirname "$KANAME_TASK_BUILD_DIR")"',
        )
        self.assertIn("Commit-ready receipt created", prepared.stdout)
        self.assert_ready(worktree)

        self.git("switch", "-c", "test/receipt-branch-drift", cwd=worktree)
        drifted_branch = self.helper("verify", cwd=worktree)
        self.assertEqual(drifted_branch.returncode, 2)
        self.assertIn("snapshot changed (branch)", drifted_branch.stderr)
        self.git("switch", "test/ready", cwd=worktree)
        self.assert_ready(worktree)

        (worktree / "source.py").write_text("def value():\n    return 3\n", encoding="utf-8")
        self.git("add", "source.py", cwd=worktree)
        drifted = self.helper("verify", cwd=worktree)
        self.assertEqual(drifted.returncode, 2)
        self.assertIn("snapshot changed", drifted.stderr)

    def test_prepare_rejects_primary_checkout_and_mixed_task_index(self) -> None:
        (self.repository / "source.py").write_text("def value():\n    return 2\n", encoding="utf-8")
        self.assert_prepare_rejected(
            self.repository,
            "task-owned linked worktree",
            "--no-tests",
            "fixture",
        )
        self.assertEqual(self.git("diff", "--cached", "--name-only").stdout, "")

        worktree = self.changed_worktree("mixed-index")
        (worktree / "other.py").write_text("def other():\n    return 2\n", encoding="utf-8")
        self.git("add", "other.py", cwd=worktree)

        self.assert_prepare_rejected(
            worktree,
            "outside this task: other.py",
            "--no-tests",
            "fixture",
        )

    def test_failed_test_does_not_create_a_ready_receipt(self) -> None:
        worktree = self.changed_worktree("failed-test")
        result = self.helper(
            "prepare",
            "--test",
            "false",
            "--",
            "source.py",
            cwd=worktree,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("Verification failed", result.stderr)
        git_directory = Path(self.git("rev-parse", "--git-dir", cwd=worktree).stdout.strip())
        self.assertFalse((git_directory / "kaname" / "commit-ready" / "receipt.json").exists())

    def test_authorized_mori_receipt_is_hashed_into_readiness(self) -> None:
        worktree = self.changed_worktree("authorized-finding")
        git_directory = Path(self.git("rev-parse", "--git-dir", cwd=worktree).stdout.strip())
        mori_directory = git_directory / "mori"
        mori_directory.mkdir()
        mori_receipt = mori_directory / "staged-review.json"
        mori_receipt.write_text(json.dumps({"schema_version": 2, "decision": "accept-focused"}), encoding="utf-8")
        self.environment["MORI_STAGED_REVIEW_RECEIPT"] = "1"

        self.prepare_source(
            worktree,
            "--no-tests",
            "fixture",
        )
        self.assert_ready(worktree)

        mori_receipt.write_text("{}\n", encoding="utf-8")
        result = self.helper("verify", cwd=worktree)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Mori staged-review receipt is missing or changed", result.stderr)

    @staticmethod
    def fake_mori_source() -> str:
        return textwrap.dedent(
            r'''#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
import sys

arguments = sys.argv[1:]
if arguments == ["version"]:
    print("mori 0.31.0 (fixture, 2026-08-22T00:00:00Z, test/fixture)")
    raise SystemExit(0)
if arguments[:3] == ["project", "upgrade", "--check"]:
    raise SystemExit(0)

output = Path(arguments[arguments.index("--output") + 1])
head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
paths = subprocess.check_output(
    ["git", "diff", "--cached", "--name-only", "-z", "HEAD"]
).split(b"\0")
changed_paths = sorted(path.decode("utf-8") for path in paths if path)
staged = arguments[:3] == ["review", "staged", "check"]
report = {
    "schema_version": 20,
    "tool": {"name": "mori", "version": "0.31.0"},
    "configuration": {
        "input": {
            "mode": "git-index" if staged else "working-tree",
            "head_commit": head,
            "index_digest": "fixture-index-digest",
            "working_tree_included": not staged,
            "untracked_included": not staged,
        },
        "focus": {
            "mode": "git-index" if staged else "git-changed",
            "changed_paths": changed_paths,
        },
    },
    "coverage": {"warning_count": 0, "parse_diagnostic_count": 0},
    "groups": [],
    "warnings": [],
    "truncated": False,
}
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(report), encoding="utf-8")
print("Mori fixture review passed.")
raise SystemExit(0)
'''
        )


if __name__ == "__main__":
    unittest.main()
