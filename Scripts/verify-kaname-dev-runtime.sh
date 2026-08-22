#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_dir="$(cd "$script_dir/.." && pwd -P)"
receipt_path="${1:-$project_dir/.build/kaname-dev-launch-receipt.json}"
expected_bundle_identifier="com.cyberlane.kaname.desktop.dev"
expected_executable="$project_dir/.build/Kaname Prototype.app/Contents/MacOS/KanamePrototype"

[[ -f "$receipt_path" ]] || { echo "Missing Kaname dev runtime receipt: $receipt_path" >&2; exit 1; }
jq -e \
    --arg bundle "$expected_bundle_identifier" \
    --arg executable "$expected_executable" \
    '.schemaVersion == 1
     and .channel == "development"
     and .bundleIdentifier == $bundle
     and .executablePath == $executable
     and (.processID | type == "number" and . > 0)
     and (.windowID | type == "number" and . > 0)' \
    "$receipt_path" >/dev/null

pid="$(jq -r '.processID' "$receipt_path")"
window_id="$(jq -r '.windowID' "$receipt_path")"
kill -0 "$pid" 2>/dev/null || { echo "Receipted Kaname dev PID is not running: $pid" >&2; exit 1; }

actual_executable="$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
[[ "$actual_executable" == "$expected_executable" ]] || {
    echo "Receipted PID has unexpected executable: $actual_executable" >&2
    exit 1
}

kaname_pids=()
while IFS= read -r candidate_pid; do
    [[ -n "$candidate_pid" ]] && kaname_pids+=("$candidate_pid")
done < <(pgrep -x KanamePrototype || true)
if [[ ${#kaname_pids[@]} -ne 1 || "${kaname_pids[0]}" != "$pid" ]]; then
    printf 'Kaname single-instance invariant failed; PID(s): %s\n' "${kaname_pids[*]:-none}" >&2
    exit 1
fi

swift -e "import Foundation
import CoreGraphics
let expectedPID = Int32($pid)
let expectedWindowID = CGWindowID($window_id)
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let matches = windows.contains { window in
    (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == expectedPID
        && (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value == expectedWindowID
}
if !matches { exit(1) }
" >/dev/null

printf '%s\n' "$receipt_path"
