#!/usr/bin/env bash

set -euo pipefail

script_directory="$(cd "$(dirname "$0")" && pwd)"
repository_root="$(cd "$script_directory/.." && pwd)"
executable="${KANAME_WORKFLOW_PREVIEW_EXECUTABLE:-$repository_root/.build/debug/KanamePrototype}"
qa_base="$(mktemp -d "${TMPDIR:-/tmp}/kaname-resize-cursor-qa.XXXXXX")"
receipt="$qa_base/resize-cursors.json"

cleanup() {
    case "$qa_base" in
        "${TMPDIR:-/tmp}"/kaname-resize-cursor-qa.*) rm -rf "$qa_base" ;;
        *) echo "Refusing to remove unexpected QA directory: $qa_base" >&2 ;;
    esac
}
trap cleanup EXIT

command -v jq >/dev/null
if [[ ! -x "$executable" ]]; then
    swift build --package-path "$repository_root" --product KanamePrototype
fi

"$executable" \
    --desktop-qa-application-support-base "$qa_base" \
    --desktop-destination automations \
    --desktop-automation-workflows-prototype \
    --desktop-window-size 1080x700 \
    --desktop-verify-resize-cursors "$receipt"

jq -e '
    .schemaVersion == 1
    and .resizable == true
    and (.checks | length == 21)
    and ([.checks[]] | all)
' "$receipt" >/dev/null

echo "Resize cursor qualification passed: 21/21 checks"
