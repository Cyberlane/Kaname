#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
app_path="$project_dir/.build/Kaname Prototype.app"
contents_path="$app_path/Contents"
binary_path="$project_dir/.build/debug/KanamePrototype"
info_plist="$contents_path/Info.plist"
app_identifier="com.cyberlane.kaname.phase0-prototype"
display_name="Kaname - Dev"
codesign_identity_path="${KANAME_CODESIGN_IDENTITY_FILE:-$HOME/Library/Application Support/Kaname/Build/codesign-identity}"
codesign_identity="${KANAME_CODESIGN_IDENTITY:-}"

if [[ -z "$codesign_identity" && -f "$codesign_identity_path" ]]; then
    IFS= read -r codesign_identity < "$codesign_identity_path"
fi
codesign_identity="${codesign_identity:--}"

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

cp "$binary_path" "$contents_path/MacOS/KanamePrototype"
codesign --force --sign "$codesign_identity" --identifier "$app_identifier" "$app_path"
open -n "$app_path"
