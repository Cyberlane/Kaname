#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: Scripts/run-phase0-prototype.sh [--replace] [--replace-receipt PATH] [--receipt PATH] [-- APP_ARGUMENTS...]

Build and launch exactly one complete Kaname development app. The launcher
fails closed when Stable, Candidate, an unknown Kaname UI, or an unverified
development UI is running. --replace-receipt permits an exact verified Dev
process from another task worktree to be replaced.
EOF
}

replace_existing=false
replacement_receipt=""
receipt_path=""
app_arguments=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --replace)
            replace_existing=true
            shift
            ;;
        --replace-receipt)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            replace_existing=true
            replacement_receipt="$2"
            shift 2
            ;;
        --receipt)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            receipt_path="$2"
            shift 2
            ;;
        --)
            shift
            app_arguments=("$@")
            break
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_dir="$(cd "$script_dir/.." && pwd -P)"
app_path="$project_dir/.build/Kaname Prototype.app"
executable_path="$app_path/Contents/MacOS/KanamePrototype"
resources_path="$app_path/Contents/Resources"
service_path="$resources_path/KanameLocalControlService"
conversation_worker_path="$resources_path/KanameConversationWorker"
workflow_worker_path="$resources_path/KanameWorkflowWorker"
core_path="$resources_path/kaname-local-core"
link_gateway_path="$resources_path/kaname-link-gateway"
app_identifier="com.cyberlane.kaname.desktop.dev"
service_identifier="$app_identifier.localcore.service"
conversation_worker_identifier="$app_identifier.conversation-worker"
workflow_worker_identifier="$app_identifier.workflow-worker"
link_gateway_identifier="$app_identifier.link-gateway"
stable_executable="$HOME/Applications/Kaname.app/Contents/MacOS/KanamePrototype"
candidate_executable="$HOME/Applications/Kaname Candidate.app/Contents/MacOS/KanamePrototype"
receipt_path="${receipt_path:-$project_dir/.build/kaname-dev-launch-receipt.json}"

application_support_base="$HOME/Library/Application Support"
for ((index = 0; index < ${#app_arguments[@]}; index++)); do
    if [[ "${app_arguments[$index]}" == "--kaname-update-nonce" ]]; then
        echo 'The launcher reserves --kaname-update-nonce for runtime verification.' >&2
        exit 64
    fi
    if [[ "${app_arguments[$index]}" == "--desktop-qa-application-support-base" ]]; then
        next_index=$((index + 1))
        [[ $next_index -lt ${#app_arguments[@]} ]] || { echo 'Missing QA application-support base.' >&2; exit 64; }
        application_support_base="${app_arguments[$next_index]}"
    fi
done
[[ "$application_support_base" == /* && "$application_support_base" != "/" ]] || {
    echo 'The application-support base must be a safe absolute path.' >&2
    exit 64
}
support_root="$application_support_base/Kaname Dev"
health_path="$support_root/Runtime/ui-health.json"
journal_directory="$support_root/LocalCore/journal"
launch_agent_plist="$support_root/Runtime/LaunchAgents/$service_identifier.plist"
service_error_log="$(dirname "$launch_agent_plist")/kaname-local-control-service.stderr.log"
runtime_logs_root="$support_root/Runtime/Logs"
runtime_log_schema_version=1
runtime_log_maximum_bytes=16777216
runtime_log_retention_sessions=8
google_oauth_config_path="${KANAME_GOOGLE_OAUTH_CONFIG:-$support_root/Google/oauth-client.json}"

replacement_pid=""
replacement_executable=""
if [[ -n "$replacement_receipt" ]]; then
    "$script_dir/verify-kaname-dev-runtime.sh" --allow-any-checkout "$replacement_receipt" >/dev/null
    replacement_pid="$(jq -r '.processID' "$replacement_receipt")"
    replacement_executable="$(jq -r '.executablePath' "$replacement_receipt")"
fi

process_executable() {
    local pid="$1"
    lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1
}

dev_pids=()
replaceable_pids=()
protected_processes=()
unknown_processes=()
scan_kaname_ui_processes() {
    local pid executable
    dev_pids=()
    replaceable_pids=()
    protected_processes=()
    unknown_processes=()
    while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        executable="$(process_executable "$pid" || true)"
        if [[ -z "$executable" ]]; then
            unknown_processes+=("$pid:<unresolved>")
            continue
        fi
        case "$executable" in
            "$stable_executable"|"$candidate_executable")
                protected_processes+=("$pid:$executable")
                ;;
            "$executable_path")
                dev_pids+=("$pid")
                ;;
            "$replacement_executable")
                if [[ -n "$replacement_pid" && "$pid" == "$replacement_pid" ]]; then
                    replaceable_pids+=("$pid")
                else
                    unknown_processes+=("$pid:$executable")
                fi
                ;;
            *)
                unknown_processes+=("$pid:$executable")
                ;;
        esac
    done < <(pgrep -x KanamePrototype || true)
}

assert_no_protected_or_unknown_processes() {
    if [[ ${#protected_processes[@]} -gt 0 ]]; then
        printf 'Refusing to touch or launch alongside installed Kaname UI: %s\n' "${protected_processes[*]}" >&2
        exit 1
    fi
    if [[ ${#unknown_processes[@]} -gt 0 ]]; then
        printf 'Refusing to launch with unclassified Kaname UI processes: %s\n' "${unknown_processes[*]}" >&2
        exit 1
    fi
}

scan_kaname_ui_processes
assert_no_protected_or_unknown_processes
existing_count=$((${#dev_pids[@]} + ${#replaceable_pids[@]}))
if [[ $existing_count -gt 0 && "$replace_existing" != true ]]; then
    printf 'Kaname development UI already running with PID(s) %s %s; refusing to create another.\n' \
        "${dev_pids[*]:-}" "${replaceable_pids[*]:-}" >&2
    echo 'Use --replace only when replacing the exact existing development process is intended.' >&2
    exit 2
fi

if [[ "$replace_existing" == true ]]; then
    for pid in \
        "${dev_pids[@]+"${dev_pids[@]}"}" \
        "${replaceable_pids[@]+"${replaceable_pids[@]}"}"
    do
        [[ -n "$pid" ]] && kill -TERM "$pid"
    done
    for _ in {1..100}; do
        scan_kaname_ui_processes
        assert_no_protected_or_unknown_processes
        [[ ${#dev_pids[@]} -eq 0 && ${#replaceable_pids[@]} -eq 0 ]] && break
        sleep 0.05
    done
    if [[ ${#dev_pids[@]} -ne 0 || ${#replaceable_pids[@]} -ne 0 ]]; then
        printf 'Kaname development UI did not stop: %s %s\n' \
            "${dev_pids[*]:-}" "${replaceable_pids[*]:-}" >&2
        exit 1
    fi
fi

cd "$project_dir"
KANAME_DESKTOP_CHANNEL=development \
KANAME_BUILD_CONFIGURATION=debug \
KANAME_GOOGLE_OAUTH_CONFIG="$google_oauth_config_path" \
    "$script_dir/build-kaname-desktop.sh" >/dev/null

info_plist="$app_path/Contents/Info.plist"
[[ -x "$executable_path" ]]
for required_executable in \
    "$service_path" \
    "$conversation_worker_path" \
    "$workflow_worker_path" \
    "$core_path" \
    "$link_gateway_path"
do
    [[ -x "$required_executable" ]] || {
        echo "The Kaname development bundle is missing a runtime helper: $required_executable" >&2
        exit 1
    }
done
[[ "$(plutil -extract CFBundleIdentifier raw "$info_plist")" == "$app_identifier" ]]
[[ "$(plutil -extract KanameDesktopChannel raw "$info_plist")" == "development" ]]
[[ "$(plutil -extract KanameLocalCoreMachService raw "$info_plist")" == "$service_identifier" ]]
[[ "$(codesign -dvv "$service_path" 2>&1 | sed -n 's/^Identifier=//p')" == "$service_identifier" ]]
[[ "$(codesign -dvv "$conversation_worker_path" 2>&1 | sed -n 's/^Identifier=//p')" == "$conversation_worker_identifier" ]]
[[ "$(codesign -dvv "$workflow_worker_path" 2>&1 | sed -n 's/^Identifier=//p')" == "$workflow_worker_identifier" ]]
[[ "$(codesign -dvv "$link_gateway_path" 2>&1 | sed -n 's/^Identifier=//p')" == "$link_gateway_identifier" ]]
codesign --verify --deep --strict "$app_path"

mkdir -p "$(dirname "$launch_agent_plist")" "$journal_directory" "$runtime_logs_root"
chmod 700 \
    "$support_root/Runtime" \
    "$(dirname "$launch_agent_plist")" \
    "$journal_directory" \
    "$runtime_logs_root"

while IFS=$'\t' read -r _ old_runtime_log_directory; do
    old_runtime_log_name="$(basename "$old_runtime_log_directory")"
    if [[ "$(dirname "$old_runtime_log_directory")" == "$runtime_logs_root" \
          && "$old_runtime_log_name" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ \
          && -d "$old_runtime_log_directory" \
          && ! -L "$old_runtime_log_directory" ]]; then
        rm -rf -- "$old_runtime_log_directory"
    fi
done < <(
    find "$runtime_logs_root" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -exec stat -f '%m%t%N' {} \; \
        | sort -rn \
        | tail -n "+$runtime_log_retention_sessions"
)

runtime_log_session_id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
runtime_log_directory="$runtime_logs_root/$runtime_log_session_id"
ui_standard_output_log="$runtime_log_directory/ui.stdout.log"
ui_standard_error_log="$runtime_log_directory/ui.stderr.log"
mkdir "$runtime_log_directory"
chmod 700 "$runtime_log_directory"
touch "$ui_standard_output_log" "$ui_standard_error_log"
chmod 600 "$ui_standard_output_log" "$ui_standard_error_log"

touch "$service_error_log"
chmod 600 "$service_error_log"
client_requirement="identifier \"$app_identifier\" or identifier \"$conversation_worker_identifier\" or identifier \"$workflow_worker_identifier\""
service_installed=false
launched_pid=""
cleanup_failed_launch() {
    local status=$?
    if [[ $status -ne 0 ]]; then
        if [[ -n "$launched_pid" ]] && kill -0 "$launched_pid" 2>/dev/null; then
            kill -TERM "$launched_pid" 2>/dev/null || true
        fi
        if [[ "$service_installed" == true ]]; then
            launchctl bootout "gui/$(id -u)/$service_identifier" >/dev/null 2>&1 || true
        fi
    fi
    exit "$status"
}
trap cleanup_failed_launch EXIT

"$service_path" --install \
    --mach-service "$service_identifier" \
    --requirement "$client_requirement" \
    --core-executable "$core_path" \
    --journal-directory "$journal_directory" \
    --local-device-id "dev-mac-authority" \
    --local-key-id "dev-mac-key-1" \
    --launch-agent-plist "$launch_agent_plist"
service_installed=true
chmod 600 "$launch_agent_plist"

service_ready=false
for _ in {1..100}; do
    if service_state="$(launchctl print "gui/$(id -u)/$service_identifier" 2>/dev/null)"; then
        service_pid="$(sed -n 's/^[[:space:]]*pid = //p' <<< "$service_state" | head -n 1)"
        if [[ "$service_pid" =~ ^[0-9]+$ ]] && kill -0 "$service_pid" 2>/dev/null; then
            actual_service_executable="$(process_executable "$service_pid" || true)"
            if [[ "$actual_service_executable" == "$service_path" ]]; then
                service_ready=true
                break
            fi
        fi
    fi
    sleep 0.05
done
[[ "$service_ready" == true ]] || { echo 'Kaname development local-core service did not become ready.' >&2; exit 1; }

scan_kaname_ui_processes
assert_no_protected_or_unknown_processes
if [[ ${#dev_pids[@]} -ne 0 || ${#replaceable_pids[@]} -ne 0 ]]; then
    printf 'A Kaname development UI appeared during the build: %s %s\n' \
        "${dev_pids[*]:-}" "${replaceable_pids[*]:-}" >&2
    exit 1
fi

launch_nonce="$(uuidgen)"

open -n \
    --stdout "$ui_standard_output_log" \
    --stderr "$ui_standard_error_log" \
    --env "KANAME_DEV_RUNTIME_SESSION_ID=$runtime_log_session_id" \
    --env "KANAME_DEV_RUNTIME_LOG_SCHEMA_VERSION=$runtime_log_schema_version" \
    --env "KANAME_DEV_RUNTIME_LOG_MAXIMUM_BYTES=$runtime_log_maximum_bytes" \
    "$app_path" --args \
    "${app_arguments[@]+"${app_arguments[@]}"}" \
    --kaname-update-nonce "$launch_nonce"

ready=false
for _ in {1..200}; do
    if jq -e \
        --arg nonce "$launch_nonce" \
        --arg bundle "$app_identifier" \
        --arg executable "$executable_path" \
        --arg runtimeLogSession "$runtime_log_session_id" \
        --argjson runtimeLogSchema "$runtime_log_schema_version" \
        '.channel == "development"
         and .healthNonce == $nonce
         and .bundleIdentifier == $bundle
         and .executablePath == $executable
         and .runtimeLogSessionID == $runtimeLogSession
         and .runtimeLogSchemaVersion == $runtimeLogSchema
         and (.processID | type == "number" and . > 0)
         and (.windowID | type == "number" and . > 0)' \
        "$health_path" >/dev/null 2>&1; then
        launched_pid="$(jq -r '.processID' "$health_path")"
        if kill -0 "$launched_pid" 2>/dev/null; then
            ready=true
            break
        fi
    fi
    sleep 0.05
done
[[ "$ready" == true ]] || { echo 'Kaname development UI did not produce a valid readiness receipt.' >&2; exit 1; }

scan_kaname_ui_processes
assert_no_protected_or_unknown_processes
if [[ ${#dev_pids[@]} -ne 1 || "${dev_pids[0]:-}" != "$launched_pid" || ${#replaceable_pids[@]} -ne 0 ]]; then
    printf 'Post-launch single-instance check failed; task Dev PID(s): %s; replaced PID(s): %s\n' \
        "${dev_pids[*]:-none}" "${replaceable_pids[*]:-none}" >&2
    exit 1
fi

mkdir -p "$(dirname "$receipt_path")"
temporary_receipt="$receipt_path.tmp.$launched_pid"
jq \
    --arg service "$service_identifier" \
    --arg servicePath "$service_path" \
    --arg workerPath "$conversation_worker_path" \
    --arg linkGatewayPath "$link_gateway_path" \
    --arg launchAgentPlist "$launch_agent_plist" \
    --arg serviceErrorLog "$service_error_log" \
    --arg journal "$journal_directory" \
    --arg runtimeLogSession "$runtime_log_session_id" \
    --arg runtimeLogDirectory "$runtime_log_directory" \
    --arg uiStandardOutput "$ui_standard_output_log" \
    --arg uiStandardError "$ui_standard_error_log" \
    --argjson runtimeLogSchema "$runtime_log_schema_version" \
    --argjson runtimeLogMaximumBytes "$runtime_log_maximum_bytes" \
    --argjson runtimeLogRetentionSessions "$runtime_log_retention_sessions" \
    '{
        schemaVersion: 3,
        channel,
        bundleIdentifier,
        executablePath,
        processID,
        windowID,
        healthyAtUnixMillis,
        localCoreMachService: $service,
        localCoreServiceExecutablePath: $servicePath,
        conversationWorkerExecutablePath: $workerPath,
        linkGatewayExecutablePath: $linkGatewayPath,
        localCoreLaunchAgentPlistPath: $launchAgentPlist,
        localCoreStandardErrorPath: $serviceErrorLog,
        journalDirectory: $journal,
        runtimeLogSessionID: $runtimeLogSession,
        runtimeLogSchemaVersion: $runtimeLogSchema,
        runtimeLogMaximumBytes: $runtimeLogMaximumBytes,
        runtimeLogRetentionSessions: $runtimeLogRetentionSessions,
        runtimeLogDirectory: $runtimeLogDirectory,
        uiStandardOutputPath: $uiStandardOutput,
        uiStandardErrorPath: $uiStandardError
    }' "$health_path" > "$temporary_receipt"
chmod 600 "$temporary_receipt"
mv "$temporary_receipt" "$receipt_path"

"$script_dir/verify-kaname-dev-runtime.sh" "$receipt_path" >/dev/null

trap - EXIT
printf '%s\n' "$receipt_path"
