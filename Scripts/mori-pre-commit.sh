#!/usr/bin/env bash
set -euo pipefail

repository_root=$(git rev-parse --show-toplevel)
cd "$repository_root"

python3 "$repository_root/Scripts/kaname-commit-ready.py" verify
exec mori hook pre-commit .
