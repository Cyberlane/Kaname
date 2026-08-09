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

[[ -x "$executable" ]]
[[ -x "$app_path/Contents/Resources/KanameLocalControlService" ]]
[[ -x "$app_path/Contents/Resources/kaname-local-core" ]]
[[ "$(plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist")" == "com.cyberlane.kaname.desktop" ]]
codesign --verify --deep --strict "$app_path"
launchctl print "gui/$(id -u)/$service_identifier" >/dev/null

mkdir -p "$output_directory"
"$executable" --desktop-destination home --snapshot "$output_directory/home.png"
"$executable" --desktop-destination localCore --load-local-core --snapshot "$output_directory/local-core.png"

for snapshot in "$output_directory/home.png" "$output_directory/local-core.png"; do
    [[ -s "$snapshot" ]]
    [[ "$(stat -f %z "$snapshot")" -gt 100000 ]]
done

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
