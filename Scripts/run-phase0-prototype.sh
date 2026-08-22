#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: Scripts/run-phase0-prototype.sh [--replace] [--receipt PATH] [-- APP_ARGUMENTS...]

Build and launch exactly one Kaname development app. The launcher fails closed
when stable, candidate, unknown, or existing development UI processes are
running. Use --replace to stop existing development UI processes explicitly.
EOF
}

replace_existing=false
receipt_path=""
app_arguments=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --replace)
            replace_existing=true
            shift
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
contents_path="$app_path/Contents"
binary_path="$project_dir/.build/debug/KanamePrototype"
executable_path="$contents_path/MacOS/KanamePrototype"
info_plist="$contents_path/Info.plist"
app_identifier="com.cyberlane.kaname.desktop.dev"
display_name="Kaname - Dev"
stable_executable="$HOME/Applications/Kaname.app/Contents/MacOS/KanamePrototype"
candidate_executable="$HOME/Applications/Kaname Candidate.app/Contents/MacOS/KanamePrototype"
codesign_identity_path="${KANAME_CODESIGN_IDENTITY_FILE:-$HOME/Library/Application Support/Kaname/Build/codesign-identity}"
codesign_identity="${KANAME_CODESIGN_IDENTITY:-}"
receipt_path="${receipt_path:-$project_dir/.build/kaname-dev-launch-receipt.json}"

if [[ -z "$codesign_identity" && -f "$codesign_identity_path" ]]; then
    IFS= read -r codesign_identity < "$codesign_identity_path"
fi
codesign_identity="${codesign_identity:--}"

dev_pids=()
protected_processes=()
unknown_processes=()

process_executable() {
    local pid="$1"
    lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1
}

scan_kaname_ui_processes() {
    local pid executable
    dev_pids=()
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
            "$project_dir"/.build/*/KanamePrototype)
                dev_pids+=("$pid")
                ;;
            *)
                unknown_processes+=("$pid:$executable")
                ;;
        esac
    done < <(pgrep -x KanamePrototype || true)
}

assert_no_protected_or_unknown_processes() {
    if [[ ${#protected_processes[@]} -gt 0 ]]; then
        printf 'Refusing to touch or launch alongside installed Kaname UI: %s\n' \
            "${protected_processes[*]}" >&2
        exit 1
    fi
    if [[ ${#unknown_processes[@]} -gt 0 ]]; then
        printf 'Refusing to launch with unclassified Kaname UI processes: %s\n' \
            "${unknown_processes[*]}" >&2
        exit 1
    fi
}

scan_kaname_ui_processes
assert_no_protected_or_unknown_processes
if [[ ${#dev_pids[@]} -gt 0 && "$replace_existing" != true ]]; then
    printf 'Kaname development UI already running with PID(s) %s; refusing to create another.\n' \
        "${dev_pids[*]}" >&2
    echo 'Use --replace only when replacing the existing dev instance is explicitly intended.' >&2
    exit 2
fi

if [[ "$replace_existing" == true ]]; then
    for pid in "${dev_pids[@]}"; do
        kill -TERM "$pid"
    done
    for _ in {1..100}; do
        scan_kaname_ui_processes
        assert_no_protected_or_unknown_processes
        [[ ${#dev_pids[@]} -eq 0 ]] && break
        sleep 0.05
    done
    if [[ ${#dev_pids[@]} -ne 0 ]]; then
        printf 'Kaname development UI did not stop: %s\n' "${dev_pids[*]}" >&2
        exit 1
    fi
fi

cd "$project_dir"
swift build --product KanamePrototype

mkdir -p "$contents_path/MacOS"
if [[ ! -f "$info_plist" ]]; then
    plutil -create xml1 "$info_plist"
fi

plutil -replace CFBundleDevelopmentRegion -string en "$info_plist"
plutil -replace CFBundleExecutable -string KanamePrototype "$info_plist"
plutil -replace CFBundleIdentifier -string "$app_identifier" "$info_plist"
plutil -replace CFBundleInfoDictionaryVersion -string 6.0 "$info_plist"
plutil -replace CFBundleName -string "$display_name" "$info_plist"
plutil -replace CFBundleDisplayName -string "$display_name" "$info_plist"
plutil -replace CFBundlePackageType -string APPL "$info_plist"
plutil -replace CFBundleShortVersionString -string 0.0.0 "$info_plist"
plutil -replace CFBundleVersion -string 1 "$info_plist"
plutil -replace LSMinimumSystemVersion -string 26.0 "$info_plist"
plutil -replace NSHighResolutionCapable -bool YES "$info_plist"
plutil -replace KanameDesktopChannel -string development "$info_plist"

cp "$binary_path" "$executable_path"
codesign --force --sign "$codesign_identity" --identifier "$app_identifier" "$app_path"

scan_kaname_ui_processes
assert_no_protected_or_unknown_processes
if [[ ${#dev_pids[@]} -ne 0 ]]; then
    printf 'A Kaname development UI appeared during the build: %s\n' "${dev_pids[*]}" >&2
    exit 1
fi

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
health_path="$application_support_base/Kaname Dev/Runtime/ui-health.json"
launch_nonce="$(uuidgen)"

launched_pid=""
cleanup_failed_launch() {
    local status=$?
    if [[ $status -ne 0 && -n "$launched_pid" ]] && kill -0 "$launched_pid" 2>/dev/null; then
        kill -TERM "$launched_pid" 2>/dev/null || true
    fi
    exit "$status"
}
trap cleanup_failed_launch EXIT

if [[ ${#app_arguments[@]} -gt 0 ]]; then
    open -n "$app_path" --args "${app_arguments[@]}" --kaname-update-nonce "$launch_nonce"
else
    open -n "$app_path" --args --kaname-update-nonce "$launch_nonce"
fi

ready=false
for _ in {1..200}; do
    if jq -e \
        --arg nonce "$launch_nonce" \
        --arg bundle "$app_identifier" \
        --arg executable "$executable_path" \
        '.channel == "development"
         and .healthNonce == $nonce
         and .bundleIdentifier == $bundle
         and .executablePath == $executable
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
if [[ ${#dev_pids[@]} -ne 1 || "${dev_pids[0]}" != "$launched_pid" ]]; then
    printf 'Post-launch single-instance check failed; dev PID(s): %s\n' "${dev_pids[*]:-none}" >&2
    exit 1
fi

mkdir -p "$(dirname "$receipt_path")"
temporary_receipt="$receipt_path.tmp.$launched_pid"
jq '{
        schemaVersion: 1,
        channel,
        bundleIdentifier,
        executablePath,
        processID,
        windowID,
        healthyAtUnixMillis
    }' "$health_path" > "$temporary_receipt"
chmod 600 "$temporary_receipt"
mv "$temporary_receipt" "$receipt_path"

"$script_dir/verify-kaname-dev-runtime.sh" "$receipt_path" >/dev/null

trap - EXIT
printf '%s\n' "$receipt_path"
