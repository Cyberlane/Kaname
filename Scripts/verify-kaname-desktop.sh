#!/usr/bin/env bash

set -euo pipefail

app_path="${1:-$HOME/Applications/Kaname.app}"
executable="$app_path/Contents/MacOS/KanamePrototype"
service_identifier="com.cyberlane.kaname.desktop.localcore.service"
state_directory="$HOME/Library/Application Support/Kaname/Desktop"
state_file="$state_directory/workspace.json"
journal_directory="$HOME/Library/Application Support/Kaname/LocalCore/journal"
error_log="$HOME/Library/LaunchAgents/kaname-local-control-service.stderr.log"
output_directory="$(cd "$(dirname "$0")/.." && pwd)/.build/desktop-qa"
instance_lock="$HOME/Library/Application Support/Kaname/Runtime/desktop-instance.lock"
restore_running_app=false
qualification_pid=""

stable_pids() {
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

if [[ -n "$(stable_pids)" ]]; then
    restore_running_app=true
    while IFS= read -r pid; do [[ -n "$pid" ]] && kill -TERM "$pid"; done < <(stable_pids)
    for _ in {1..40}; do
        if [[ -z "$(stable_pids)" ]]; then break; fi
        sleep 0.05
    done
    if [[ -n "$(stable_pids)" ]]; then
        echo "Kaname did not stop before desktop qualification." >&2
        exit 1
    fi
fi

[[ -x "$executable" ]]
[[ -x "$app_path/Contents/Resources/KanameLocalControlService" ]]
[[ -x "$app_path/Contents/Resources/KanameUpdateHelper" ]]
[[ -x "$app_path/Contents/Resources/KanameConversationWorker" ]]
[[ -x "$app_path/Contents/Resources/kaname-local-core" ]]
[[ "$(plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist")" == "com.cyberlane.kaname.desktop" ]]
[[ "$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")" == "0.9.0" ]]
[[ "$(plutil -extract CFBundleVersion raw "$app_path/Contents/Info.plist")" == "18" ]]
codesign --verify --deep --strict "$app_path"
if [[ "$(plutil -extract KanameStableCodeSigning raw "$app_path/Contents/Info.plist")" == "true" ]]; then
    designated_requirement="$(codesign -d -r- "$app_path" 2>&1)"
    [[ "$designated_requirement" == *'identifier "com.cyberlane.kaname.desktop"'* ]]
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
launchctl print "gui/$(id -u)/$service_identifier" >/dev/null

mkdir -p "$output_directory"
"$executable" \
    --desktop-destination home \
    --desktop-window-size 1520x940 \
    --snapshot "$output_directory/home-wide.png"
"$executable" \
    --desktop-destination home \
    --desktop-window-size 1080x700 \
    --snapshot "$output_directory/home-compact.png"
"$executable" --desktop-destination localCore --load-local-core --snapshot "$output_directory/local-core.png"
"$executable" --desktop-destination email --snapshot "$output_directory/email.png"
"$executable" --desktop-destination calendar --snapshot "$output_directory/calendar.png"
"$executable" --desktop-destination projects --snapshot "$output_directory/projects.png"
"$executable" --desktop-destination projects --desktop-project-id project-kaname --snapshot "$output_directory/project-overview.png"
"$executable" --desktop-destination liveCodex --snapshot "$output_directory/coding.png"
"$executable" --desktop-destination settings --snapshot "$output_directory/settings.png"
"$executable" \
    --desktop-destination settings \
    --desktop-settings-category integrations \
    --snapshot "$output_directory/settings-integrations.png"
"$executable" \
    --desktop-destination settings \
    --desktop-settings-category providers \
    --snapshot "$output_directory/settings-providers.png"
"$executable" \
    --desktop-destination calendar \
    --desktop-back-target home \
    --post-mouse-back \
    --require-mouse-back-handled \
    --snapshot "$output_directory/mouse-back.png"

for snapshot in \
    "$output_directory/home-wide.png" \
    "$output_directory/home-compact.png" \
    "$output_directory/local-core.png" \
    "$output_directory/email.png" \
    "$output_directory/calendar.png" \
    "$output_directory/projects.png" \
    "$output_directory/project-overview.png" \
    "$output_directory/coding.png" \
    "$output_directory/settings.png" \
    "$output_directory/settings-integrations.png" \
    "$output_directory/settings-providers.png" \
    "$output_directory/mouse-back.png"
do
    [[ -s "$snapshot" ]]
    [[ "$(stat -f %z "$snapshot")" -gt 100000 ]]
done

"$executable" --desktop-destination home >/dev/null 2>&1 &
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

"$executable" --desktop-destination settings >/dev/null 2>&1 &
second_instance_pid=$!
if ! wait "$second_instance_pid"; then
    echo "The second Kaname launch did not exit cleanly." >&2
    exit 1
fi
[[ "$(stable_pids | wc -l | tr -d ' ')" == "1" ]]
kill -0 "$qualification_pid"
kill -TERM "$qualification_pid"
wait "$qualification_pid" 2>/dev/null || true
qualification_pid=""

[[ "$(stat -f %Lp "$(dirname "$instance_lock")")" == "700" ]]
[[ "$(stat -f %Lp "$instance_lock")" == "600" ]]

[[ "$(stat -f %Lp "$state_directory")" == "700" ]]
[[ "$(stat -f %Lp "$state_file")" == "600" ]]
[[ "$(stat -f %Lp "$journal_directory")" == "700" ]]

journal_count="$(find "$journal_directory" -maxdepth 1 -name 'F-*.sqlite' -type f | wc -l | tr -d ' ')"
[[ "$journal_count" == "14" ]]
while IFS= read -r journal; do
    [[ "$(stat -f %Lp "$journal")" == "600" ]]
done < <(find "$journal_directory" -maxdepth 1 -name 'F-*.sqlite' -type f -print)

if [[ -s "$error_log" ]]; then
    echo "The local service wrote diagnostics to $error_log." >&2
    exit 1
fi

echo "Kaname desktop verification passed."
echo "$output_directory"
