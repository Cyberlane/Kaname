#!/usr/bin/env python3
"""Create isolated Kaname task worktrees and immutable commit-ready receipts."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any, Dict, Iterable, List, Optional, Sequence


RECEIPT_SCHEMA_VERSION = 1
SLUG_PATTERN = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")


class WorkflowError(RuntimeError):
    """A user-actionable readiness failure."""


def command_text(arguments: Sequence[str]) -> str:
    return " ".join(shlex.quote(value) for value in arguments)


def run(
    arguments: Sequence[str],
    *,
    cwd: Path,
    env: Optional[Dict[str, str]] = None,
    check: bool = True,
    text: bool = True,
) -> subprocess.CompletedProcess:
    result = subprocess.run(
        list(arguments),
        cwd=str(cwd),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=text,
        check=False,
    )
    if check and result.returncode != 0:
        standard_error = result.stderr if text else result.stderr.decode("utf-8", "replace")
        standard_output = result.stdout if text else result.stdout.decode("utf-8", "replace")
        detail = (standard_error or standard_output).strip()
        raise WorkflowError(
            f"Command failed ({result.returncode}): {command_text(arguments)}"
            + (f"\n{detail}" if detail else "")
        )
    return result


def git(root: Path, *arguments: str, check: bool = True, text: bool = True) -> subprocess.CompletedProcess:
    return run(["git", *arguments], cwd=root, check=check, text=text)


def discover_root() -> Path:
    result = run(["git", "rev-parse", "--show-toplevel"], cwd=Path.cwd())
    return Path(result.stdout.strip()).resolve()


def absolute_git_path(root: Path, relative: str) -> Path:
    result = git(root, "rev-parse", "--path-format=absolute", "--git-path", relative)
    return Path(result.stdout.strip()).resolve()


def require_isolated_worktree(root: Path) -> None:
    git_directory = resolved_git_directory(root, git(root, "rev-parse", "--git-dir").stdout.strip())
    common_directory = resolved_git_directory(root, git(root, "rev-parse", "--git-common-dir").stdout.strip())
    if git_directory == common_directory:
        raise WorkflowError(
            "Commit preparation requires a task-owned linked worktree. "
            "Run Scripts/kaname-commit-ready.py new-worktree <task-slug> from the primary checkout first."
        )


def resolved_git_directory(root: Path, value: str) -> Path:
    path = Path(value)
    return (path if path.is_absolute() else root / path).resolve()


def nul_paths(result: subprocess.CompletedProcess) -> List[str]:
    output = result.stdout if isinstance(result.stdout, bytes) else result.stdout.encode()
    return sorted(value.decode("utf-8", "surrogateescape") for value in output.split(b"\0") if value)


def staged_paths(root: Path) -> List[str]:
    return nul_paths(
        git(
            root,
            "diff",
            "--cached",
            "--name-only",
            "--no-renames",
            "-z",
            "--diff-filter=ACDMRTUXB",
            "HEAD",
            text=False,
        )
    )


def unstaged_paths(root: Path) -> List[str]:
    return nul_paths(git(root, "diff", "--name-only", "-z", text=False))


def untracked_paths(root: Path) -> List[str]:
    return nul_paths(git(root, "ls-files", "--others", "--exclude-standard", "-z", text=False))


def normalize_pathspec(value: str) -> str:
    normalized = value[2:] if value.startswith("./") else value
    normalized = normalized.rstrip("/")
    path = PurePosixPath(normalized)
    if normalized in {"", "."} or path.is_absolute() or ".." in path.parts or "\\" in normalized:
        raise WorkflowError(f"Commit paths must be safe repository-relative paths: {value}")
    return path.as_posix()


def path_is_covered(path: str, pathspecs: Iterable[str]) -> bool:
    return any(path == pathspec or path.startswith(pathspec + "/") for pathspec in pathspecs)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def snapshot(root: Path) -> Dict[str, Any]:
    head = git(root, "rev-parse", "HEAD").stdout.strip()
    branch = git(root, "branch", "--show-current").stdout.strip()
    index_tree = git(root, "write-tree").stdout.strip()
    paths = staged_paths(root)
    indexed = set(nul_paths(git(root, "ls-files", "-z", text=False)))
    # Mori focuses surviving index paths; deleted files and rename sources
    # remain bound by staged_paths and the complete index tree below.
    live_paths = [path for path in paths if path in indexed]
    digest_input = "\0".join([head, branch, index_tree, *paths]).encode("utf-8", "surrogateescape")
    return {
        "head": head,
        "branch": branch,
        "index_tree": index_tree,
        "staged_paths": paths,
        "staged_live_paths": live_paths,
        "digest": hashlib.sha256(digest_input).hexdigest(),
    }


def ensure_exact_worktree(root: Path, expected: Dict[str, Any]) -> None:
    current = snapshot(root)
    for key in ("head", "branch", "index_tree", "staged_paths", "staged_live_paths", "digest"):
        if current[key] != expected.get(key):
            raise WorkflowError(
                f"The commit-ready snapshot changed ({key}). Run commit preparation again."
            )
    unstaged = unstaged_paths(root)
    untracked = untracked_paths(root)
    if unstaged or untracked:
        paths = sorted(set(unstaged + untracked))
        raise WorkflowError(
            "The task worktree contains changes outside the staged snapshot: " + ", ".join(paths)
        )
    diff_check = git(root, "diff", "--cached", "--check", check=False)
    if diff_check.returncode != 0:
        raise WorkflowError(diff_check.stdout.strip() or diff_check.stderr.strip() or "git diff --cached --check failed.")


def private_directory(root: Path) -> Path:
    directory = absolute_git_path(root, "kaname/commit-ready")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    return directory


def receipt_path(root: Path) -> Path:
    return private_directory(root) / "receipt.json"


def task_environment(root: Path) -> Dict[str, str]:
    environment = os.environ.copy()
    temporary_root = Path(environment.get("TMPDIR", tempfile.gettempdir())).resolve()
    environment["TMPDIR"] = str(temporary_root) + "/"
    environment["KANAME_TASK_WORKTREE"] = str(root)
    environment["KANAME_TASK_BUILD_DIR"] = str((root / ".build").resolve())
    return environment


def run_logged(
    arguments: Sequence[str],
    *,
    root: Path,
    log_path: Path,
    environment: Dict[str, str],
) -> Dict[str, Any]:
    started = time.monotonic()
    with log_path.open("wb") as log:
        os.chmod(log_path, 0o600)
        process = subprocess.Popen(
            list(arguments),
            cwd=str(root),
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
        assert process.stdout is not None
        while True:
            chunk = process.stdout.readline()
            if not chunk:
                break
            log.write(chunk)
            log.flush()
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
        status = process.wait()
    return {
        "command": command_text(arguments),
        "exit_status": status,
        "duration_seconds": round(time.monotonic() - started, 3),
        "log_path": str(log_path),
        "log_sha256": sha256_file(log_path),
    }


def load_json(path: Path) -> Dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise WorkflowError(f"Could not read JSON evidence at {path}: {error}") from error
    if not isinstance(value, dict):
        raise WorkflowError(f"Expected a JSON object at {path}.")
    return value


def mori_version(root: Path, executable: str) -> str:
    pin = (root / ".mori-version").read_text(encoding="utf-8").strip()
    result = run([executable, "version"], cwd=root)
    fields = result.stdout.split()
    if len(fields) < 2:
        raise WorkflowError(f"Could not parse Mori version output: {result.stdout.strip()}")
    reported = fields[1] if fields[1].startswith("v") else "v" + fields[1]
    if reported != pin:
        raise WorkflowError(f"Mori version mismatch: project requires {pin}, active binary reports {reported}.")
    return reported


def validate_staged_report(
    report: Dict[str, Any],
    expected: Dict[str, Any],
    version: str,
    *,
    allow_authorized_findings: bool = False,
) -> None:
    configuration = report.get("configuration")
    input_evidence = configuration.get("input") if isinstance(configuration, dict) else None
    focus = configuration.get("focus") if isinstance(configuration, dict) else None
    tool = report.get("tool")
    coverage = report.get("coverage")
    if not isinstance(input_evidence, dict) or input_evidence.get("mode") != "git-index":
        raise WorkflowError("Mori staged evidence did not use the immutable Git index.")
    if input_evidence.get("head_commit") != expected["head"]:
        raise WorkflowError("Mori staged evidence was produced for a different HEAD.")
    if input_evidence.get("working_tree_included") is not False or input_evidence.get("untracked_included") is not False:
        raise WorkflowError("Mori staged evidence unexpectedly included working-tree content.")
    if not isinstance(focus, dict) or sorted(focus.get("changed_paths", [])) != expected["staged_live_paths"]:
        raise WorkflowError("Mori staged evidence paths do not match the exact staged snapshot.")
    if (report.get("groups") and not allow_authorized_findings) or report.get("warnings") or report.get("truncated") is not False:
        raise WorkflowError("Mori staged evidence contains findings, warnings, or truncation.")
    if not isinstance(coverage, dict) or coverage.get("warning_count", 0) != 0 or coverage.get("parse_diagnostic_count", 0) != 0:
        raise WorkflowError("Mori staged coverage contains warnings or parse diagnostics.")
    tool_version = tool.get("version") if isinstance(tool, dict) else None
    if tool_version and (tool_version if str(tool_version).startswith("v") else "v" + str(tool_version)) != version:
        raise WorkflowError("Mori staged evidence was produced by a different tool version.")


def write_json_atomic(path: Path, value: Dict[str, Any]) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)
    os.chmod(path, 0o600)


def prepare(arguments: argparse.Namespace) -> None:
    root = discover_root()
    require_isolated_worktree(root)
    pathspecs = sorted(set(normalize_pathspec(value) for value in arguments.paths))
    if not pathspecs:
        raise WorkflowError("Pass the exact task paths after --.")
    if not arguments.tests and not arguments.no_tests:
        raise WorkflowError("Provide at least one --test command or an explicit --no-tests reason.")
    if arguments.tests and arguments.no_tests:
        raise WorkflowError("Use test commands or --no-tests, not both.")

    output_directory = private_directory(root)
    current_receipt = receipt_path(root)
    if current_receipt.exists():
        current_receipt.unlink()

    existing = staged_paths(root)
    unexpected = [path for path in existing if not path_is_covered(path, pathspecs)]
    if unexpected:
        raise WorkflowError(
            "The index already contains paths outside this task: " + ", ".join(unexpected)
        )

    # An already staged deletion has neither a worktree file nor an index
    # entry. It is still task evidence, but passing it to git add fails. Keep
    # it in the exact snapshot and only refresh paths that Git can stage.
    indexed = set(nul_paths(git(root, "ls-files", "-z", text=False)))
    stageable = [path for path in pathspecs if (root / path).exists() or path in indexed]
    if stageable:
        stage_result = git(root, "--literal-pathspecs", "add", "-A", "--", *stageable, check=False)
        if stage_result.returncode != 0:
            raise WorkflowError(stage_result.stderr.strip() or stage_result.stdout.strip() or "git add failed.")
    paths = staged_paths(root)
    if not paths:
        raise WorkflowError("The selected paths contain no staged changes.")
    unexpected = [path for path in paths if not path_is_covered(path, pathspecs)]
    unmatched = [pathspec for pathspec in pathspecs if not path_is_covered_by_staged(pathspec, paths)]
    if unexpected or unmatched:
        details = []
        if unexpected:
            details.append("outside task: " + ", ".join(unexpected))
        if unmatched:
            details.append("no staged change: " + ", ".join(unmatched))
        raise WorkflowError("Exact-path staging failed (" + "; ".join(details) + ").")

    prepared_snapshot = snapshot(root)
    ensure_exact_worktree(root, prepared_snapshot)
    environment = task_environment(root)
    test_records: List[Dict[str, Any]] = []
    for index, test_command in enumerate(arguments.tests, start=1):
        record = run_logged(
            ["/bin/zsh", "-lc", test_command],
            root=root,
            log_path=output_directory / f"test-{index}.log",
            environment=environment,
        )
        test_records.append(record)
        if record["exit_status"] != 0:
            raise WorkflowError(f"Verification failed: {test_command}")
        ensure_exact_worktree(root, prepared_snapshot)

    executable = shutil.which("mori")
    if executable is None:
        raise WorkflowError("Mori is required; install the version pinned in .mori-version.")
    version = mori_version(root, executable)
    upgrade = run([executable, "project", "upgrade", "--check", "."], cwd=root, check=False)
    if upgrade.returncode != 0:
        detail = (upgrade.stdout + upgrade.stderr).strip()
        raise WorkflowError("Mori project compatibility check failed.\n" + detail)

    staged_report = output_directory / "mori-staged.json"
    staged_log = output_directory / "mori-staged.log"
    staged_command = [
        executable,
        "review",
        "staged",
        "check",
        "--format",
        "agent",
        "--output",
        str(staged_report),
        ".",
    ]
    authorized_review_receipt: Optional[Path] = None
    receipt_mode = os.environ.get("MORI_STAGED_REVIEW_RECEIPT", "")
    if receipt_mode:
        if receipt_mode != "1":
            raise WorkflowError("MORI_STAGED_REVIEW_RECEIPT must be exactly 1 when explicitly authorized.")
        authorized_review_receipt = absolute_git_path(root, "mori/staged-review.json")
        if not authorized_review_receipt.is_file():
            raise WorkflowError("The explicitly authorized Mori staged-review receipt is missing.")
        staged_command[-1:-1] = ["--review-receipt", str(authorized_review_receipt)]
    staged_record = run_logged(
        staged_command,
        root=root,
        log_path=staged_log,
        environment=environment,
    )
    if staged_record["exit_status"] != 0:
        raise WorkflowError(
            f"Mori staged review requires inspection (exit {staged_record['exit_status']}). "
            f"Use the saved report at {staged_report}; do not rerun it blindly."
        )
    ensure_exact_worktree(root, prepared_snapshot)
    staged_json = load_json(staged_report)
    validate_staged_report(
        staged_json,
        prepared_snapshot,
        version,
        allow_authorized_findings=authorized_review_receipt is not None,
    )

    receipt = {
        "schema_version": RECEIPT_SCHEMA_VERSION,
        "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "repository_root": str(root),
        "branch": prepared_snapshot["branch"],
        "snapshot": prepared_snapshot,
        "tests": test_records,
        "no_tests_reason": arguments.no_tests,
        "mori": {
            "binary": executable,
            "version": version,
            "staged": {
                **staged_record,
                "report_path": str(staged_report),
                "report_sha256": sha256_file(staged_report),
                "index_digest": staged_json["configuration"]["input"]["index_digest"],
                "authorized_review_receipt_path": str(authorized_review_receipt) if authorized_review_receipt else None,
                "authorized_review_receipt_sha256": sha256_file(authorized_review_receipt) if authorized_review_receipt else None,
            },
        },
    }
    write_json_atomic(current_receipt, receipt)
    print(f"Commit-ready receipt created: {current_receipt}")
    print(f"Snapshot: {prepared_snapshot['digest']} ({len(paths)} staged path(s))")


def path_is_covered_by_staged(pathspec: str, paths: Iterable[str]) -> bool:
    return any(path == pathspec or path.startswith(pathspec + "/") for path in paths)


def verify(arguments: argparse.Namespace) -> None:
    root = discover_root()
    require_isolated_worktree(root)
    path = Path(arguments.receipt).expanduser().resolve() if arguments.receipt else receipt_path(root)
    if not path.is_file():
        raise WorkflowError(
            "No commit-ready receipt exists for this worktree. "
            "Run Scripts/kaname-commit-ready.py prepare before requesting or creating the commit."
        )
    receipt = load_json(path)
    if receipt.get("schema_version") != RECEIPT_SCHEMA_VERSION:
        raise WorkflowError("The commit-ready receipt schema is unsupported; prepare the snapshot again.")
    if receipt.get("repository_root") != str(root):
        raise WorkflowError("The commit-ready receipt belongs to a different worktree.")
    expected = receipt.get("snapshot")
    if not isinstance(expected, dict):
        raise WorkflowError("The commit-ready receipt has no snapshot evidence.")
    ensure_exact_worktree(root, expected)

    tests = receipt.get("tests")
    no_tests_reason = receipt.get("no_tests_reason")
    if not tests and not no_tests_reason:
        raise WorkflowError("The commit-ready receipt contains no test evidence or explicit no-test reason.")
    for record in tests or []:
        if record.get("exit_status") != 0:
            raise WorkflowError("The commit-ready receipt contains failed verification evidence.")
        log_path = Path(record.get("log_path", ""))
        if not log_path.is_file() or sha256_file(log_path) != record.get("log_sha256"):
            raise WorkflowError("A verification log is missing or changed; prepare the snapshot again.")

    mori = receipt.get("mori")
    if not isinstance(mori, dict):
        raise WorkflowError("The commit-ready receipt contains no Mori evidence.")
    version = mori.get("version")
    if version != (root / ".mori-version").read_text(encoding="utf-8").strip():
        raise WorkflowError("The Mori version pin changed after preparation.")
    evidence = mori.get("staged")
    if not isinstance(evidence, dict) or evidence.get("exit_status") != 0:
        raise WorkflowError("The receipt contains no passing Mori staged evidence.")
    report_path = Path(evidence.get("report_path", ""))
    if not report_path.is_file() or sha256_file(report_path) != evidence.get("report_sha256"):
        raise WorkflowError("The Mori staged report is missing or changed.")
    authorized_path_value = evidence.get("authorized_review_receipt_path")
    authorized_review_receipt = Path(authorized_path_value) if authorized_path_value else None
    if authorized_review_receipt is not None:
        if not authorized_review_receipt.is_file() or sha256_file(authorized_review_receipt) != evidence.get("authorized_review_receipt_sha256"):
            raise WorkflowError("The authorized Mori staged-review receipt is missing or changed.")
    staged_report = load_json(Path(mori["staged"]["report_path"]))
    validate_staged_report(
        staged_report,
        expected,
        str(version),
        allow_authorized_findings=authorized_review_receipt is not None,
    )

    print(f"Commit-ready receipt is current: {path}")
    print(f"Snapshot: {expected['digest']} ({len(expected['staged_paths'])} staged path(s))")


def primary_worktree(root: Path) -> Path:
    result = git(root, "worktree", "list", "--porcelain")
    for line in result.stdout.splitlines():
        if line.startswith("worktree "):
            return Path(line[len("worktree ") :]).resolve()
    raise WorkflowError("Git did not report a primary worktree.")


def create_task_worktree(arguments: argparse.Namespace) -> None:
    current = discover_root()
    primary = primary_worktree(current)
    if current != primary:
        raise WorkflowError(f"This checkout is already a linked worktree: {current}")
    if not SLUG_PATTERN.fullmatch(arguments.slug):
        raise WorkflowError("Task slugs use lowercase letters, digits, and hyphens (maximum 63 characters).")
    branch = arguments.branch or f"kaname/task/{arguments.slug}"
    branch_validation = git(primary, "check-ref-format", "--branch", branch, check=False)
    if branch_validation.returncode != 0:
        raise WorkflowError(f"Git rejected the task branch name: {branch}")
    target = (
        Path(arguments.target).expanduser()
        if arguments.target
        else primary.parent / f"{primary.name}-worktrees" / arguments.slug
    ).resolve()
    if target.exists():
        raise WorkflowError(f"Task worktree target already exists: {target}")
    branch_check = git(primary, "show-ref", "--verify", "--quiet", f"refs/heads/{branch}", check=False)
    if branch_check.returncode == 0:
        raise WorkflowError(f"Task branch already exists: {branch}")
    base = git(primary, "rev-parse", "--verify", f"{arguments.base}^{{commit}}").stdout.strip()
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    git(primary, "worktree", "add", "-b", branch, str(target), base)

    local_instructions = primary / "AGENTS.md"
    target_instructions = target / "AGENTS.md"
    if local_instructions.is_file() and not target_instructions.exists():
        shutil.copy2(local_instructions, target_instructions)
        os.chmod(target_instructions, 0o600)

    hook_installer = target / "Scripts" / "install-mori-git-hook.sh"
    if hook_installer.is_file():
        run([str(hook_installer)], cwd=target)

    print(f"Task worktree created: {target}")
    print(f"Branch: {branch}")
    print(f"Base: {base}")
    print(f"Continue with: cd {shlex.quote(str(target))}")


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    subcommands = root.add_subparsers(dest="command", required=True)

    create = subcommands.add_parser("new-worktree", help="create one task-owned linked worktree")
    create.add_argument("slug")
    create.add_argument("--base", default="HEAD", help="local commit to branch from (default: HEAD)")
    create.add_argument("--branch", help="explicit local branch name")
    create.add_argument("--target", help="explicit worktree path")
    create.set_defaults(operation=create_task_worktree)

    prepare_parser = subcommands.add_parser("prepare", help="stage and qualify an exact commit snapshot")
    prepare_parser.add_argument("--test", dest="tests", action="append", default=[], help="verification command; repeatable")
    prepare_parser.add_argument("--no-tests", metavar="REASON", help="explicit reason that tests do not apply")
    prepare_parser.add_argument("paths", nargs="*", help="exact repository-relative task paths")
    prepare_parser.set_defaults(operation=prepare)

    verify_parser = subcommands.add_parser("verify", help="fail if a commit-ready receipt or snapshot drifted")
    verify_parser.add_argument("--receipt", help="explicit receipt path (defaults to this worktree's Git metadata)")
    verify_parser.set_defaults(operation=verify)
    return root


def main() -> int:
    arguments = parser().parse_args()
    try:
        arguments.operation(arguments)
    except (WorkflowError, OSError) as error:
        print(f"kaname commit readiness: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
