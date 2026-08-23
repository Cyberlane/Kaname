# Development commit readiness

Kaname source tasks use one linked worktree, branch, index, and build directory
per conversation. Tests and structural review finish before the owner is asked
to validate or approve a commit. A later signed-commit request therefore checks
an immutable receipt and creates the commit; it does not reconstruct the task or
rerun the build unless the snapshot changed.

## Start a source-changing task

From the primary checkout:

```sh
Scripts/kaname-commit-ready.py new-worktree <task-slug>
cd ../coding-ade-worktrees/<task-slug>
```

The helper branches from the local `HEAD`, activates the tracked hook, and
copies a local ignored `AGENTS.md` into the linked worktree when one exists.
It never transfers the primary checkout's index or uncommitted changes. Do not
use the primary index as storage for another task.

Each linked worktree uses its own `.build` directory. Verification commands can
refer to its canonical location through `KANAME_TASK_BUILD_DIR`; the helper also
canonicalizes `TMPDIR` before launching checks so `/tmp` aliases do not create
false path comparisons.

## Prepare the exact commit before acceptance

After implementation and source review, pass every intended path explicitly and
run the smallest relevant checks. Repeat `--test` for an additional full gate
when the change warrants it:

```sh
Scripts/kaname-commit-ready.py prepare \
  --test 'swift test --scratch-path "$KANAME_TASK_BUILD_DIR" --filter RelevantTests' \
  -- Sources/Relevant.swift Tests/RelevantTests.swift
```

For a change where executable tests genuinely do not apply, record that
boundary explicitly:

```sh
Scripts/kaname-commit-ready.py prepare \
  --no-tests 'Documentation-only workflow clarification' \
  -- Docs/DevelopmentCommitReadiness.md
```

Preparation fails closed unless:

- the checkout is a linked task worktree;
- the index contains only the named task paths and no unstaged or untracked
  task content remains;
- `git diff --cached --check` passes;
- every requested test passes without changing `HEAD` or the index;
- the canonical staged-index Mori review passes with complete configured
  coverage; and
- the staged Mori report proves it excluded the working tree and untracked
  files.

Test logs, Mori JSON, and the receipt are owner-private files under that
worktree's Git metadata. The receipt records `HEAD`, the Git index tree, exact
paths, test commands and log hashes, Mori versions and report hashes, and the
staged-review index digest. Query the saved exact-staged report rather than
rerunning a broad dirty-tree scan. Deeply inspect only task-hunk-relevant
identities, up to 25, and classify each as likely duplication, intentional
similarity, or false positive.

## Create the signed commit

When the owner requests the commit:

```sh
Scripts/kaname-commit-ready.py verify
git diff --cached --check
git commit -S -m '<one-line subject>'
git verify-commit HEAD
git status --short --branch
```

The verification step is intentionally cheap. Any `HEAD`, index, path, test-log,
Mori-report, version-pin, or staged-input drift invalidates the receipt and
returns the task to preparation. The tracked pre-commit hook requires the same
receipt and then performs Mori's canonical staged-index check once more. It does
not rebuild or rerun tests. A ready signed commit should normally take seconds,
not minutes; pushing remains a separate owner-authorized action.

An intentional staged Mori finding remains an exceptional owner decision. After
the complete report is inspected and the owner explicitly authorizes Mori's
one-commit receipt, run both preparation and the exact commit with
`MORI_STAGED_REVIEW_RECEIPT=1`. Kaname hashes that receipt into its own readiness
evidence; either receipt becomes invalid after any staged snapshot drift.
