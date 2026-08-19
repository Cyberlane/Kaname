#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
app_path="$project_dir/.build/Kaname Prototype.app"
contents_path="$app_path/Contents"
binary_path="$project_dir/.build/debug/KanamePrototype"
core_path="$project_dir/Rust/KanameCore/target/debug/kaname-local-core"
service_path="$project_dir/.build/debug/KanameLocalControlService"
info_plist="$contents_path/Info.plist"
launch_agent_plist="$project_dir/.build/kaname-local-control-service.plist"
journal_directory="$project_dir/.build/localcore-journal"
app_identifier="com.cyberlane.kaname.local-core-prototype"
service_identifier="com.cyberlane.kaname.localcore.service"
display_name="Kaname - Dev"

cd "$project_dir"
cargo build --manifest-path Rust/KanameCore/Cargo.toml --bin kaname-local-core
swift build --product KanamePrototype
swift build --product KanameLocalControlService

signing_identity="${KANAME_XPC_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -n 1)}"
if [[ -z "$signing_identity" ]]; then
    echo "A local Apple Development signing identity is required for the local XPC validation surface." >&2
    exit 1
fi

codesign --force --sign "$signing_identity" --identifier "$service_identifier" "$service_path"
team_identifier="$(codesign -dvv "$service_path" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [[ -z "$team_identifier" ]]; then
    echo "The local XPC service did not produce a TeamIdentifier." >&2
    exit 1
fi
service_requirement="anchor apple generic and certificate leaf[subject.OU] = \"$team_identifier\" and identifier \"$service_identifier\""
client_requirement="anchor apple generic and certificate leaf[subject.OU] = \"$team_identifier\" and identifier \"$app_identifier\""

mkdir -p "$contents_path/MacOS" "$contents_path/Resources"
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
plutil -replace CFBundleShortVersionString -string 0.1.0 "$info_plist"
plutil -replace CFBundleVersion -string 1 "$info_plist"
plutil -replace LSMinimumSystemVersion -string 13.0 "$info_plist"
plutil -replace NSHighResolutionCapable -bool YES "$info_plist"
plutil -replace KanameLocalCoreMachService -string "$service_identifier" "$info_plist"
plutil -replace KanameLocalCoreServiceRequirement -string "$service_requirement" "$info_plist"
plutil -replace KanameDesktopChannel -string development "$info_plist"

cp "$binary_path" "$contents_path/MacOS/KanamePrototype"
cp "$core_path" "$contents_path/Resources/kaname-local-core"
codesign --force --sign "$signing_identity" --identifier "$app_identifier" "$app_path"

"$service_path" --install \
    --mach-service "$service_identifier" \
    --requirement "$client_requirement" \
    --core-executable "$core_path" \
    --journal-directory "$journal_directory" \
    --local-device-id "mac-authority" \
    --local-key-id "mac-key-1" \
    --launch-agent-plist "$launch_agent_plist"
open -n "$app_path"
