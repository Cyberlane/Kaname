#!/usr/bin/env bash
set -euo pipefail

channel="${1:-stable}"
case "$channel" in
    stable)
        app_name="Kaname"
        bundle_identifier="com.cyberlane.kaname.desktop"
        support_name="Kaname"
        service_identifier="com.cyberlane.kaname.desktop.localcore.service"
        worker_identifier="com.cyberlane.kaname.desktop.conversation-worker"
        workflow_worker_identifier="com.cyberlane.kaname.desktop.workflow-worker"
        local_device_id="mac-authority"
        local_key_id="mac-key-1"
        build_hint="Scripts/build-kaname-desktop.sh"
        ;;
    candidate)
        app_name="Kaname Candidate"
        bundle_identifier="com.cyberlane.kaname.desktop.candidate"
        support_name="Kaname Candidate"
        service_identifier="com.cyberlane.kaname.desktop.candidate.localcore.service"
        worker_identifier="com.cyberlane.kaname.desktop.candidate.conversation-worker"
        workflow_worker_identifier="com.cyberlane.kaname.desktop.candidate.workflow-worker"
        local_device_id="candidate-mac-authority"
        local_key_id="candidate-mac-key-1"
        build_hint="KANAME_DESKTOP_CHANNEL=candidate Scripts/build-kaname-desktop.sh"
        ;;
    *)
        echo "Usage: $0 [stable|candidate]" >&2
        exit 64
        ;;
esac

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
built_app="$project_dir/.build/$app_name.app"
applications_directory="$HOME/Applications"
installed_app="$applications_directory/$app_name.app"
launch_agent_plist="$HOME/Library/LaunchAgents/$service_identifier.plist"
workflow_launch_agent_plist="$HOME/Library/LaunchAgents/$workflow_worker_identifier.plist"
journal_directory="$HOME/Library/Application Support/$support_name/LocalCore/journal"
client_requirement="identifier \"$bundle_identifier\" or identifier \"$worker_identifier\" or identifier \"$workflow_worker_identifier\""

if [[ ! -d "$built_app" ]]; then
    echo "Build Kaname first with $build_hint." >&2
    exit 1
fi

mkdir -p "$applications_directory" "$(dirname "$launch_agent_plist")" "$journal_directory"
chmod 700 "$journal_directory"

if [[ -e "$installed_app" ]]; then
    existing_identifier="$(plutil -extract CFBundleIdentifier raw "$installed_app/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$existing_identifier" != "$bundle_identifier" ]]; then
        echo "Refusing to replace an unrelated app at $installed_app." >&2
        exit 1
    fi
    rm -r "$installed_app"
fi

cp -R "$built_app" "$installed_app"
codesign --verify --deep --strict "$installed_app"

"$installed_app/Contents/Resources/KanameLocalControlService" --install \
    --mach-service "$service_identifier" \
    --requirement "$client_requirement" \
    --core-executable "$installed_app/Contents/Resources/kaname-local-core" \
    --journal-directory "$journal_directory" \
    --local-device-id "$local_device_id" \
    --local-key-id "$local_key_id" \
    --launch-agent-plist "$launch_agent_plist"

workflow_error_log="$HOME/Library/LaunchAgents/$workflow_worker_identifier.stderr.log"
plutil -create xml1 "$workflow_launch_agent_plist"
plutil -insert Label -string "$workflow_worker_identifier" "$workflow_launch_agent_plist"
plutil -insert ProgramArguments -json "[\"$installed_app/Contents/Resources/KanameWorkflowWorker\",\"--channel\",\"$channel\"]" "$workflow_launch_agent_plist"
plutil -insert RunAtLoad -bool YES "$workflow_launch_agent_plist"
plutil -insert StartInterval -integer 60 "$workflow_launch_agent_plist"
plutil -insert ProcessType -string Background "$workflow_launch_agent_plist"
plutil -insert ThrottleInterval -integer 30 "$workflow_launch_agent_plist"
plutil -insert StandardErrorPath -string "$workflow_error_log" "$workflow_launch_agent_plist"
chmod 600 "$workflow_launch_agent_plist"
launchctl bootout "gui/$(id -u)/$workflow_worker_identifier" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$workflow_launch_agent_plist"

echo "$installed_app"
