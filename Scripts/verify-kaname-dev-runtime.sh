#!/usr/bin/env bash

set -euo pipefail

usage() {
    echo "Usage: $0 [--allow-any-checkout] [RECEIPT]" >&2
}

allow_any_checkout=false
if [[ "${1:-}" == "--allow-any-checkout" ]]; then
    allow_any_checkout=true
    shift
fi
[[ $# -le 1 ]] || { usage; exit 64; }

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_dir="$(cd "$script_dir/.." && pwd -P)"
receipt_path="${1:-$project_dir/.build/kaname-dev-launch-receipt.json}"
expected_bundle_identifier="com.cyberlane.kaname.desktop.dev"
default_executable="$project_dir/.build/Kaname Prototype.app/Contents/MacOS/KanamePrototype"

[[ -f "$receipt_path" ]] || { echo "Missing Kaname dev runtime receipt: $receipt_path" >&2; exit 1; }
jq -e \
    --arg bundle "$expected_bundle_identifier" \
    '(.schemaVersion == 1 or .schemaVersion == 2 or .schemaVersion == 3)
     and .channel == "development"
     and .bundleIdentifier == $bundle
     and (.executablePath | type == "string" and startswith("/"))
     and (.processID | type == "number" and . > 0)
     and (.windowID | type == "number" and . > 0)' \
    "$receipt_path" >/dev/null

schema_version="$(jq -r '.schemaVersion' "$receipt_path")"
expected_executable="$(jq -r '.executablePath' "$receipt_path")"
if [[ "$allow_any_checkout" != true && "$expected_executable" != "$default_executable" ]]; then
    echo "Receipt belongs to another Kaname development checkout: $expected_executable" >&2
    exit 1
fi

executable_suffix="/Contents/MacOS/KanamePrototype"
[[ "$expected_executable" == *"$executable_suffix" ]] || {
    echo "Receipt executable is not a Kaname app executable: $expected_executable" >&2
    exit 1
}
app_path="${expected_executable%"$executable_suffix"}"
info_plist="$app_path/Contents/Info.plist"
[[ -f "$info_plist" ]] || { echo "Missing Kaname dev Info.plist: $info_plist" >&2; exit 1; }
[[ "$(plutil -extract CFBundleIdentifier raw "$info_plist")" == "$expected_bundle_identifier" ]] || {
    echo "Kaname dev bundle identifier mismatch." >&2
    exit 1
}
[[ "$(plutil -extract KanameDesktopChannel raw "$info_plist")" == "development" ]] || {
    echo "Kaname dev channel mismatch." >&2
    exit 1
}

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
if [[ ${#kaname_pids[@]} -ne 1 || "${kaname_pids[0]:-}" != "$pid" ]]; then
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

if [[ "$schema_version" -ge 2 ]]; then
    resources_path="$app_path/Contents/Resources"
    service_path="$resources_path/KanameLocalControlService"
    conversation_worker_path="$resources_path/KanameConversationWorker"
    workflow_worker_path="$resources_path/KanameWorkflowWorker"
    core_path="$resources_path/kaname-local-core"
    service_identifier="$expected_bundle_identifier.localcore.service"
    conversation_worker_identifier="$expected_bundle_identifier.conversation-worker"
    workflow_worker_identifier="$expected_bundle_identifier.workflow-worker"
    launch_agent_plist="$(jq -r '.localCoreLaunchAgentPlistPath' "$receipt_path")"
    service_error_log="$(jq -r '.localCoreStandardErrorPath' "$receipt_path")"

    jq -e \
        --arg service "$service_identifier" \
        --arg servicePath "$service_path" \
        --arg workerPath "$conversation_worker_path" \
        --arg launchAgentSuffix "/Kaname Dev/Runtime/LaunchAgents/$service_identifier.plist" \
        --arg errorLogSuffix "/Kaname Dev/Runtime/LaunchAgents/kaname-local-control-service.stderr.log" \
        --arg journalSuffix "/Kaname Dev/LocalCore/journal" \
        '.localCoreMachService == $service
         and .localCoreServiceExecutablePath == $servicePath
         and .conversationWorkerExecutablePath == $workerPath
         and (.localCoreLaunchAgentPlistPath | type == "string" and endswith($launchAgentSuffix))
         and (.localCoreStandardErrorPath | type == "string" and endswith($errorLogSuffix))
         and (.journalDirectory | type == "string" and endswith($journalSuffix))' \
        "$receipt_path" >/dev/null

    for required_executable in \
        "$service_path" \
        "$conversation_worker_path" \
        "$workflow_worker_path" \
        "$core_path"
    do
        [[ -x "$required_executable" ]] || {
            echo "Missing executable Kaname dev runtime helper: $required_executable" >&2
            exit 1
        }
    done
    codesign --verify --deep --strict "$app_path"
    [[ "$(codesign -dvv "$service_path" 2>&1 | sed -n 's/^Identifier=//p')" == "$service_identifier" ]]
    [[ "$(codesign -dvv "$conversation_worker_path" 2>&1 | sed -n 's/^Identifier=//p')" == "$conversation_worker_identifier" ]]
    [[ "$(codesign -dvv "$workflow_worker_path" 2>&1 | sed -n 's/^Identifier=//p')" == "$workflow_worker_identifier" ]]
    [[ "$(plutil -extract KanameLocalCoreMachService raw "$info_plist")" == "$service_identifier" ]]
    [[ "$(plutil -extract KanameLocalCoreServiceRequirement raw "$info_plist")" == "identifier \"$service_identifier\"" ]]

    if [[ "$schema_version" -ge 3 ]]; then
        link_gateway_path="$resources_path/kaname-link-gateway"
        link_gateway_identifier="$expected_bundle_identifier.link-gateway"
        jq -e --arg linkGatewayPath "$link_gateway_path" \
            '.linkGatewayExecutablePath == $linkGatewayPath' \
            "$receipt_path" >/dev/null
        [[ -x "$link_gateway_path" ]] || {
            echo "Missing executable Kaname dev runtime helper: $link_gateway_path" >&2
            exit 1
        }
        [[ "$(codesign -dvv "$link_gateway_path" 2>&1 | sed -n 's/^Identifier=//p')" == "$link_gateway_identifier" ]]
    fi

    [[ -f "$launch_agent_plist" ]] || { echo "Missing Kaname dev local-core LaunchAgent." >&2; exit 1; }
    [[ "$(plutil -extract Label raw "$launch_agent_plist")" == "$service_identifier" ]]
    [[ "$(plutil -extract ProgramArguments.0 raw "$launch_agent_plist")" == "$service_path" ]]
    [[ "$(plutil -extract ProgramArguments.7 raw "$launch_agent_plist")" == "$core_path" ]]
    [[ "$(plutil -extract ProgramArguments.9 raw "$launch_agent_plist")" == "$(jq -r '.journalDirectory' "$receipt_path")" ]]
    [[ "$(plutil -extract StandardErrorPath raw "$launch_agent_plist")" == "$service_error_log" ]]
    [[ "$(stat -f %Lp "$launch_agent_plist")" == "600" ]]
    [[ "$(stat -f %Lp "$service_error_log")" == "600" ]]

    service_state="$(launchctl print "gui/$(id -u)/$service_identifier")"
    service_pid="$(sed -n 's/^[[:space:]]*pid = //p' <<< "$service_state" | head -n 1)"
    [[ "$service_pid" =~ ^[0-9]+$ ]] || { echo "Kaname dev local-core service has no live PID." >&2; exit 1; }
    kill -0 "$service_pid" 2>/dev/null || { echo "Kaname dev local-core service is not running." >&2; exit 1; }
    actual_service_executable="$(lsof -a -p "$service_pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"
    [[ "$actual_service_executable" == "$service_path" ]] || {
        echo "Kaname dev local-core service has unexpected executable: $actual_service_executable" >&2
        exit 1
    }
fi

printf '%s\n' "$receipt_path"
