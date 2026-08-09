#!/usr/bin/env bash
set -euo pipefail

repository_root=$(git rev-parse --show-toplevel)
cd "$repository_root"

if ! command -v mori >/dev/null 2>&1; then
  echo "Mori is required before committing source changes; install the version in .mori-version." >&2
  exit 1
fi

required_version=$(tr -d '[:space:]' < .mori-version)
reported_version=$(mori version)
installed_version="v$(awk '{print $2}' <<<"$reported_version")"
if [[ "$installed_version" != "$required_version" ]]; then
  echo "Mori version mismatch: project requires $required_version, but '$reported_version' is active." >&2
  exit 1
fi

staged_sources=()
while IFS= read -r -d '' path; do
  case "$path" in
    *.go|*.js|*.jsx|*.ts|*.tsx|*.py|*.rs|*.swift|*.sql|*.sh|*.bash|*.zsh)
      staged_sources+=("$path")
      ;;
  esac
done < <(git diff --cached --name-only --diff-filter=ACMR -z)

if (( ${#staged_sources[@]} == 0 )); then
  exit 0
fi

report=$(mktemp "${TMPDIR:-/tmp}/kaname-mori.XXXXXX")
trap 'rm -f "$report"' EXIT

arguments=(scan --format text --max-groups 25 --fail-on-focused-match)
for path in "${staged_sources[@]}"; do
  arguments+=(--focus-path "$path")
done

set +e
mori "${arguments[@]}" . >"$report" 2>&1
status=$?
set -e

if (( status == 0 )); then
  echo "Mori pre-commit review passed for ${#staged_sources[@]} staged source file(s)."
  exit 0
fi

cat "$report" >&2
if (( status == 3 )); then
  echo "Mori found focused structural matches. Inspect both locations and reuse, refactor, or document why the similarity is intentional." >&2
fi
exit "$status"
