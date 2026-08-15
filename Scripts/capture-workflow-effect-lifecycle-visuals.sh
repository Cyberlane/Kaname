#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
output_directory="${1:-$repository_root/.build/workflow-effect-lifecycle-visuals}"
executable="${KANAME_WORKFLOW_PREVIEW_EXECUTABLE:-$repository_root/.build/debug/KanamePrototype}"
qa_base="$(mktemp -d "${TMPDIR:-/tmp}/kaname-workflow-effect-visuals.XXXXXX")"

cleanup() {
    case "$qa_base" in
        "${TMPDIR:-/tmp}"/kaname-workflow-effect-visuals.*) rm -rf "$qa_base" ;;
        *) echo "Refusing to remove unexpected QA directory: $qa_base" >&2 ;;
    esac
}
trap cleanup EXIT

command -v shasum >/dev/null

if [[ ! -x "$executable" ]]; then
    swift build --package-path "$repository_root" --product KanamePrototype
fi

mkdir -p "$output_directory"

capture() {
    local name="$1"
    local size="$2"
    local output="$output_directory/$name.png"
    "$executable" \
        --desktop-qa-application-support-base "$qa_base" \
        --desktop-destination automations \
        --desktop-effect-lifecycle-fixture \
        --desktop-window-size "$size" \
        --snapshot "$output"
    [[ -s "$output" ]]
    [[ "$(stat -f %z "$output")" -gt 50000 ]]
}

capture effect-lifecycle-wide 1520x940
capture effect-lifecycle-compact 1080x700
capture effect-inspector-wide 1520x1120

(
    cd "$output_directory"
    shasum -a 256 \
        ./effect-lifecycle-wide.png \
        ./effect-lifecycle-compact.png \
        ./effect-inspector-wide.png > checksums.sha256
)

echo "Captured 3 synthetic workflow effect lifecycle fixtures in $output_directory"
