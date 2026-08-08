#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
app_path="$project_dir/.build/Kaname Prototype.app"
contents_path="$app_path/Contents"
binary_path="$project_dir/.build/debug/KanamePrototype"
info_plist="$contents_path/Info.plist"

cd "$project_dir"
swift build --product KanamePrototype

mkdir -p "$contents_path/MacOS"
if [[ ! -f "$info_plist" ]]; then
    plutil -create xml1 "$info_plist"
fi

plutil -replace CFBundleDevelopmentRegion -string en "$info_plist"
plutil -replace CFBundleExecutable -string KanamePrototype "$info_plist"
plutil -replace CFBundleIdentifier -string com.cyberlane.kaname.phase0-prototype "$info_plist"
plutil -replace CFBundleInfoDictionaryVersion -string 6.0 "$info_plist"
plutil -replace CFBundleName -string "Kaname Prototype" "$info_plist"
plutil -replace CFBundlePackageType -string APPL "$info_plist"
plutil -replace CFBundleShortVersionString -string 0.0.0 "$info_plist"
plutil -replace CFBundleVersion -string 1 "$info_plist"
plutil -replace LSMinimumSystemVersion -string 13.0 "$info_plist"
plutil -replace NSHighResolutionCapable -bool YES "$info_plist"

cp "$binary_path" "$contents_path/MacOS/KanamePrototype"
open -n "$app_path"
