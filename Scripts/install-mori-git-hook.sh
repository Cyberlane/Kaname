#!/usr/bin/env bash
set -euo pipefail

repository_root=$(git rev-parse --show-toplevel)
cd "$repository_root"

git config --local core.hooksPath .githooks

if [[ "$(git config --local --get core.hooksPath)" != ".githooks" ]]; then
  echo "Unable to activate the tracked Mori pre-commit hook." >&2
  exit 1
fi

echo "Activated the tracked Mori pre-commit hook at .githooks/pre-commit."
