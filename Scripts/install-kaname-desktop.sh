#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
built_app="$project_dir/.build/Kaname.app"
applications_directory="$HOME/Applications"
installed_app="$applications_directory/Kaname.app"
service_identifier="com.cyberlane.kaname.desktop.localcore.service"
launch_agent_plist="$HOME/Library/LaunchAgents/$service_identifier.plist"
journal_directory="$HOME/Library/Application Support/Kaname/LocalCore/journal"
client_requirement='identifier "com.cyberlane.kaname.desktop"'

if [[ ! -d "$built_app" ]]; then
    echo "Build Kaname first with Scripts/build-kaname-desktop.sh." >&2
    exit 1
fi

mkdir -p "$applications_directory" "$(dirname "$launch_agent_plist")" "$journal_directory"
chmod 700 "$journal_directory"

if [[ -e "$installed_app" ]]; then
    existing_identifier="$(plutil -extract CFBundleIdentifier raw "$installed_app/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$existing_identifier" != "com.cyberlane.kaname.desktop" ]]; then
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
    --local-device-id "mac-authority" \
    --local-key-id "mac-key-1" \
    --launch-agent-plist "$launch_agent_plist"

echo "$installed_app"
