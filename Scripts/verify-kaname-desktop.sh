#!/usr/bin/env bash

set -euo pipefail

app_path="${1:-$HOME/Applications/Kaname.app}"
expected_version="${KANAME_APP_VERSION:-0.15.0}"
expected_build="${KANAME_APP_BUILD:-24}"
executable="$app_path/Contents/MacOS/KanamePrototype"
info="$app_path/Contents/Info.plist"
channel="$(plutil -extract KanameDesktopChannel raw "$info")"
case "$channel" in
    stable)
        expected_identifier="com.cyberlane.kaname.desktop"
        support_name="Kaname"
        service_identifier="com.cyberlane.kaname.desktop.localcore.service"
        ;;
    candidate)
        expected_identifier="com.cyberlane.kaname.desktop.candidate"
        support_name="Kaname Candidate"
        service_identifier="com.cyberlane.kaname.desktop.candidate.localcore.service"
        ;;
    *) echo "Unknown Kaname desktop channel: $channel" >&2; exit 1 ;;
esac
journal_directory="$HOME/Library/Application Support/$support_name/LocalCore/journal"
error_log="$HOME/Library/LaunchAgents/kaname-local-control-service.stderr.log"
output_directory="$(cd "$(dirname "$0")/.." && pwd)/.build/desktop-qa/$channel"
qa_application_support_base="$output_directory/ApplicationSupport"
qa_support_root="$qa_application_support_base/$support_name"
state_directory="$qa_support_root/Desktop"
state_file="$state_directory/workspace.json"
instance_lock="$qa_support_root/Runtime/desktop-instance.lock"
restore_running_app=false
qualification_pid=""

run_qualified_app() {
    "$executable" --desktop-qa-application-support-base "$qa_application_support_base" "$@"
}

bundle_pids() {
    pgrep -f "^$executable([[:space:]]|$)" || true
}

restore_desktop_app() {
    if [[ -n "$qualification_pid" ]] && kill -0 "$qualification_pid" 2>/dev/null; then
        kill -TERM "$qualification_pid"
        wait "$qualification_pid" 2>/dev/null || true
    fi
    if [[ "$restore_running_app" == true ]]; then
        open "$app_path"
    fi
}

trap restore_desktop_app EXIT

if [[ -n "$(bundle_pids)" ]]; then
    restore_running_app=true
    while IFS= read -r pid; do [[ -n "$pid" ]] && kill -TERM "$pid"; done < <(bundle_pids)
    for _ in {1..40}; do
        if [[ -z "$(bundle_pids)" ]]; then break; fi
        sleep 0.05
    done
    if [[ -n "$(bundle_pids)" ]]; then
        echo "Kaname did not stop before desktop qualification." >&2
        exit 1
    fi
fi

[[ -x "$executable" ]]
[[ -x "$app_path/Contents/Resources/KanameLocalControlService" ]]
[[ -x "$app_path/Contents/Resources/KanameUpdateHelper" ]]
[[ -x "$app_path/Contents/Resources/KanameConversationWorker" ]]
[[ -x "$app_path/Contents/Resources/kaname-local-core" ]]
[[ "$(plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist")" == "$expected_identifier" ]]
[[ "$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")" == "$expected_version" ]]
[[ "$(plutil -extract CFBundleVersion raw "$app_path/Contents/Info.plist")" == "$expected_build" ]]
[[ -s "$app_path/Contents/Resources/KanameUpdateManifest.json" ]]
[[ -s "$app_path/Contents/Resources/ReleaseNotes.md" ]]
[[ -s "$app_path/Contents/Resources/THIRD_PARTY_NOTICES.md" ]]
[[ -s "$app_path/Contents/Resources/Kaname-SBOM.cdx.json" ]]
codesign --verify --deep --strict "$app_path"
if [[ "$(plutil -extract KanameStableCodeSigning raw "$app_path/Contents/Info.plist")" == "true" ]]; then
    designated_requirement="$(codesign -d -r- "$app_path" 2>&1)"
    [[ "$designated_requirement" == *"identifier \"$expected_identifier\""* ]]
    [[ "$designated_requirement" != *"cdhash "* ]]
    app_team_identifier="$(codesign -dvv "$app_path" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [[ -n "$app_team_identifier" && "$app_team_identifier" != "not set" ]]
    for signed_target in \
        "$app_path/Contents/Resources/KanameLocalControlService" \
        "$app_path/Contents/Resources/KanameUpdateHelper" \
        "$app_path/Contents/Resources/KanameConversationWorker" \
        "$app_path/Contents/Resources/kaname-local-core"
    do
        [[ "$(codesign -dvv "$signed_target" 2>&1 | sed -n 's/^TeamIdentifier=//p')" == "$app_team_identifier" ]]
    done
fi
if [[ "$channel" == stable ]]; then
    launchctl print "gui/$(id -u)/$service_identifier" >/dev/null
fi

mkdir -p "$output_directory"
rm -rf "$qa_application_support_base"
run_qualified_app \
    --desktop-destination home \
    --desktop-window-size 1520x940 \
    --snapshot "$output_directory/home-wide.png"
run_qualified_app \
    --desktop-destination home \
    --desktop-window-size 1080x700 \
    --snapshot "$output_directory/home-compact.png"
run_qualified_app \
    --desktop-destination threads \
    --desktop-window-size 1520x940 \
    --snapshot "$output_directory/threads-wide.png"
run_qualified_app \
    --desktop-destination threads \
    --desktop-window-size 1080x700 \
    --snapshot "$output_directory/threads-compact.png"
run_qualified_app --desktop-destination localCore --load-local-core --snapshot "$output_directory/local-core.png"
run_qualified_app --desktop-destination email --snapshot "$output_directory/email.png"
run_qualified_app \
    --desktop-destination automations \
    --desktop-workflow-fixture "$PWD/Examples/Workflows/generic-case-review.workflow.json" \
    --snapshot "$output_directory/automations-workflows.png"
run_qualified_app \
    --desktop-destination automations \
    --desktop-automation-product-builder \
    --desktop-workflow-fixture "$PWD/Examples/Workflows/generic-case-review.workflow.json" \
    --snapshot "$output_directory/automations-builder.png"
run_qualified_app \
    --desktop-destination automations \
    --desktop-automation-product-runs \
    --desktop-workflow-fixture "$PWD/Examples/Workflows/generic-case-review.workflow.json" \
    --snapshot "$output_directory/automations-runs.png"
run_qualified_app --desktop-destination calendar --snapshot "$output_directory/calendar.png"
run_qualified_app \
    --desktop-destination automations \
    --desktop-automation-product-components \
    --desktop-workflow-fixture "$PWD/Examples/Workflows/generic-case-review.workflow.json" \
    --snapshot "$output_directory/automations-components.png"
run_qualified_app \
    --desktop-destination automations \
    --desktop-automation-product-readiness \
    --desktop-workflow-fixture "$PWD/Examples/Workflows/generic-case-review.workflow.json" \
    --snapshot "$output_directory/automations-readiness.png"
run_qualified_app --desktop-destination projects --snapshot "$output_directory/projects.png"
run_qualified_app --desktop-new-conversation --snapshot "$output_directory/new-conversation.png"
run_qualified_app --desktop-destination projects --desktop-project-id project-kaname --snapshot "$output_directory/project-overview.png"
run_qualified_app --desktop-destination knowledge --snapshot "$output_directory/knowledge.png"
run_qualified_app --desktop-destination liveCodex --snapshot "$output_directory/coding.png"
run_qualified_app \
    --desktop-destination home \
    --desktop-global-search \
    --snapshot "$output_directory/command-center.png"
run_qualified_app \
    --desktop-destination home \
    --desktop-global-search \
    --desktop-search-query Kaname \
    --snapshot "$output_directory/global-search.png"
run_qualified_app \
    --desktop-destination home \
    --desktop-diagnostics \
    --snapshot "$output_directory/diagnostics.png"
run_qualified_app \
    --desktop-destination projects \
    --desktop-large-text \
    --desktop-window-size 1080x700 \
    --snapshot "$output_directory/projects-large-text.png"
run_qualified_app --desktop-destination settings --snapshot "$output_directory/settings.png"
run_qualified_app \
    --desktop-destination settings \
    --desktop-settings-category commands \
    --snapshot "$output_directory/settings-commands.png"
run_qualified_app \
    --desktop-destination settings \
    --desktop-settings-category integrations \
    --snapshot "$output_directory/settings-integrations.png"
run_qualified_app \
    --desktop-destination settings \
    --desktop-settings-category providers \
    --snapshot "$output_directory/settings-providers.png"
run_qualified_app \
    --desktop-destination settings \
    --desktop-settings-category updates \
    --snapshot "$output_directory/settings-updates.png"
run_qualified_app \
    --desktop-destination settings \
    --desktop-settings-category backups \
    --snapshot "$output_directory/settings-backups.png"
run_qualified_app \
    --desktop-destination calendar \
    --desktop-back-target home \
    --post-mouse-back \
    --require-mouse-back-handled \
    --snapshot "$output_directory/mouse-back.png"

for snapshot in \
    "$output_directory/home-wide.png" \
    "$output_directory/home-compact.png" \
    "$output_directory/threads-wide.png" \
    "$output_directory/threads-compact.png" \
    "$output_directory/local-core.png" \
    "$output_directory/email.png" \
    "$output_directory/automations-workflows.png" \
    "$output_directory/automations-builder.png" \
    "$output_directory/automations-runs.png" \
    "$output_directory/calendar.png" \
    "$output_directory/automations-components.png" \
    "$output_directory/automations-readiness.png" \
    "$output_directory/projects.png" \
    "$output_directory/new-conversation.png" \
    "$output_directory/project-overview.png" \
    "$output_directory/knowledge.png" \
    "$output_directory/coding.png" \
    "$output_directory/command-center.png" \
    "$output_directory/global-search.png" \
    "$output_directory/diagnostics.png" \
    "$output_directory/projects-large-text.png" \
    "$output_directory/settings.png" \
    "$output_directory/settings-commands.png" \
    "$output_directory/settings-integrations.png" \
    "$output_directory/settings-providers.png" \
    "$output_directory/settings-updates.png" \
    "$output_directory/settings-backups.png" \
    "$output_directory/mouse-back.png"
do
    [[ -s "$snapshot" ]]
    [[ "$(stat -f %z "$snapshot")" -gt 100000 ]]
done

"$executable" \
    --desktop-qa-application-support-base "$qa_application_support_base" \
    --desktop-destination home >/dev/null 2>&1 &
qualification_pid=$!
for _ in {1..100}; do
    if lsof -a -p "$qualification_pid" "$instance_lock" >/dev/null 2>&1; then break; fi
    if ! kill -0 "$qualification_pid" 2>/dev/null; then
        echo "The primary Kaname qualification instance exited early." >&2
        exit 1
    fi
    sleep 0.05
done
if ! lsof -a -p "$qualification_pid" "$instance_lock" >/dev/null 2>&1; then
    echo "The primary Kaname qualification instance did not acquire its lock." >&2
    exit 1
fi

"$executable" \
    --desktop-qa-application-support-base "$qa_application_support_base" \
    --desktop-destination settings >/dev/null 2>&1 &
second_instance_pid=$!
if ! wait "$second_instance_pid"; then
    echo "The second Kaname launch did not exit cleanly." >&2
    exit 1
fi
[[ "$(bundle_pids | wc -l | tr -d ' ')" == "1" ]]
kill -0 "$qualification_pid"
kill -TERM "$qualification_pid"
wait "$qualification_pid" 2>/dev/null || true
qualification_pid=""

[[ "$(stat -f %Lp "$(dirname "$instance_lock")")" == "700" ]]
[[ "$(stat -f %Lp "$instance_lock")" == "600" ]]

[[ "$(stat -f %Lp "$state_directory")" == "700" ]]
[[ "$(stat -f %Lp "$state_file")" == "600" ]]
if [[ "$channel" == stable ]]; then
    [[ "$(stat -f %Lp "$journal_directory")" == "700" ]]
    journal_count="$(find "$journal_directory" -maxdepth 1 -name 'F-*.sqlite' -type f | wc -l | tr -d ' ')"
    [[ "$journal_count" == "14" ]]
    while IFS= read -r journal; do
        [[ "$(stat -f %Lp "$journal")" == "600" ]]
    done < <(find "$journal_directory" -maxdepth 1 -name 'F-*.sqlite' -type f -print)
fi

if [[ "$channel" == stable && -s "$error_log" ]]; then
    echo "The local service wrote diagnostics to $error_log." >&2
    exit 1
fi

echo "Kaname desktop verification passed."
echo "$output_directory"
