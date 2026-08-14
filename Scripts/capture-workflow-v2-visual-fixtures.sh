#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
manifest="$repository_root/Fixtures/workflow-v2/visual-manifest.json"
output_directory="${1:-$repository_root/.build/workflow-v2-visuals}"
executable="${KANAME_WORKFLOW_PREVIEW_EXECUTABLE:-$repository_root/.build/debug/KanamePrototype}"
qa_base="$(mktemp -d "${TMPDIR:-/tmp}/kaname-workflow-v2-visuals.XXXXXX")"

cleanup() {
    case "$qa_base" in
        "${TMPDIR:-/tmp}"/kaname-workflow-v2-visuals.*) rm -rf "$qa_base" ;;
        *) echo "Refusing to remove unexpected QA directory: $qa_base" >&2 ;;
    esac
}
trap cleanup EXIT

command -v jq >/dev/null
command -v shasum >/dev/null
jq empty "$manifest"

if [[ ! -x "$executable" ]]; then
    swift build --package-path "$repository_root" --product KanamePrototype
fi

mkdir -p "$output_directory"

while IFS= read -r capture; do
    name="$(jq -r '.name' <<<"$capture")"
    width="$(jq -r '.width' <<<"$capture")"
    height="$(jq -r '.height' <<<"$capture")"
    output="$output_directory/$name.png"
    arguments=(
        "$executable"
        --desktop-qa-application-support-base "$qa_base"
    )
    while IFS= read -r argument; do
        arguments+=("$argument")
    done < <(jq -r '.baseArguments[]' "$manifest")
    arguments+=(
        --desktop-window-size "${width}x${height}"
        --snapshot "$output"
    )
    while IFS= read -r argument; do
        arguments+=("$argument")
    done < <(jq -r '.arguments[]' <<<"$capture")

    "${arguments[@]}"
    [[ -s "$output" ]]
    [[ "$(stat -f %z "$output")" -gt 50000 ]]
done < <(jq -c '.captures[]' "$manifest")

(
    cd "$output_directory"
    shasum -a 256 ./*.png > checksums.sha256
)

expected_count="$(jq '.captures | length' "$manifest")"
actual_count="$(find "$output_directory" -maxdepth 1 -name '*.png' -type f | wc -l | tr -d ' ')"
[[ "$actual_count" == "$expected_count" ]]

echo "Captured $actual_count workflow visual fixtures in $output_directory"
