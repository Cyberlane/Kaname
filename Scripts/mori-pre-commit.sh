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

report=$(mktemp "${TMPDIR:-/tmp}/kaname-mori.XXXXXX")
trap 'rm -f "$report"' EXIT

arguments=(
  review
  staged
  check
  --format text
)

receipt_mode=${MORI_STAGED_REVIEW_RECEIPT:-}
if [[ -n "$receipt_mode" ]]; then
  if [[ "$receipt_mode" != "1" ]]; then
    echo "MORI_STAGED_REVIEW_RECEIPT must be exactly 1 when explicitly authorized." >&2
    exit 2
  fi
  receipt_path=$(git rev-parse --git-path mori/staged-review.json)
  if [[ ! -f "$receipt_path" ]]; then
    echo "No local staged review receipt exists. Inspect the report, then run 'mori review staged acknowledge --accept-focused .' only with explicit owner authorization." >&2
    exit 1
  fi
  arguments+=(--review-receipt "$receipt_path")
fi

set +e
mori "${arguments[@]}" . >"$report" 2>&1
status=$?
set -e

if (( status == 0 )); then
  echo "Mori pre-commit staged-index review passed."
  exit 0
fi

cat "$report" >&2
if (( status == 3 )); then
  echo "Mori found focused structural matches. Inspect both locations and reuse, refactor, or document why the similarity is intentional." >&2
  echo "For an explicitly authorized one-commit exception, create an exact staged receipt and run the commit with MORI_STAGED_REVIEW_RECEIPT=1; findings remain visible." >&2
fi
exit "$status"
