#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
configuration="${KANAME_BUILD_CONFIGURATION:-release}"
app_path="$project_dir/.build/Kaname.app"
contents_path="$app_path/Contents"
resources_path="$contents_path/Resources"
binary_path="$project_dir/.build/$configuration/KanamePrototype"
service_binary_path="$project_dir/.build/$configuration/KanameLocalControlService"
core_configuration="$configuration"
if [[ "$configuration" == "debug" ]]; then
    core_binary_path="$project_dir/Rust/KanameCore/target/debug/kaname-local-core"
else
    core_configuration="release"
    core_binary_path="$project_dir/Rust/KanameCore/target/release/kaname-local-core"
fi
info_plist="$contents_path/Info.plist"
icon_source="$project_dir/.build/KanameIcon-1024.png"
iconset_path="$project_dir/.build/Kaname.iconset"
identifier="com.cyberlane.kaname.desktop"
service_identifier="com.cyberlane.kaname.desktop.localcore.service"
core_identifier="com.cyberlane.kaname.desktop.localcore"
service_requirement="identifier \"$service_identifier\""
google_oauth_config_path="${KANAME_GOOGLE_OAUTH_CONFIG:-$HOME/Library/Application Support/Kaname/Build/google-oauth-client.json}"
google_oauth_client_id="${KANAME_GOOGLE_OAUTH_CLIENT_ID:-}"
google_oauth_client_secret="${KANAME_GOOGLE_OAUTH_CLIENT_SECRET:-}"

if [[ -z "$google_oauth_client_id" && -f "$google_oauth_config_path" ]]; then
    google_oauth_client_id="$(plutil -extract installed.client_id raw "$google_oauth_config_path")"
    google_oauth_client_secret="$(plutil -extract installed.client_secret raw "$google_oauth_config_path" 2>/dev/null || true)"
fi

cd "$project_dir"
swift build -c "$configuration" --product KanamePrototype
swift build -c "$configuration" --product KanameLocalControlService
if [[ "$core_configuration" == "debug" ]]; then
    cargo build --locked --manifest-path Rust/KanameCore/Cargo.toml --bin kaname-local-core
else
    cargo build --locked --release --manifest-path Rust/KanameCore/Cargo.toml --bin kaname-local-core
fi

if [[ -e "$app_path" ]]; then
    rm -r "$app_path"
fi
if [[ -e "$iconset_path" ]]; then
    rm -r "$iconset_path"
fi

mkdir -p "$contents_path/MacOS" "$resources_path" "$iconset_path"
swift "$script_dir/render-kaname-icon.swift" "$icon_source"

for specification in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"
do
    read -r pixels filename <<< "$specification"
    sips -z "$pixels" "$pixels" "$icon_source" --out "$iconset_path/$filename" >/dev/null
done
iconutil -c icns "$iconset_path" -o "$resources_path/Kaname.icns"

plutil -create xml1 "$info_plist"
plutil -replace CFBundleDevelopmentRegion -string en "$info_plist"
plutil -replace CFBundleExecutable -string KanamePrototype "$info_plist"
plutil -replace CFBundleIconFile -string Kaname "$info_plist"
plutil -replace CFBundleIdentifier -string "$identifier" "$info_plist"
plutil -replace CFBundleInfoDictionaryVersion -string 6.0 "$info_plist"
plutil -replace CFBundleName -string Kaname "$info_plist"
plutil -replace CFBundleDisplayName -string Kaname "$info_plist"
plutil -replace CFBundlePackageType -string APPL "$info_plist"
plutil -replace CFBundleShortVersionString -string 0.6.1 "$info_plist"
plutil -replace CFBundleVersion -string 9 "$info_plist"
plutil -replace LSApplicationCategoryType -string public.app-category.developer-tools "$info_plist"
plutil -replace LSMinimumSystemVersion -string 14.0 "$info_plist"
plutil -replace NSPrincipalClass -string NSApplication "$info_plist"
plutil -replace NSHighResolutionCapable -bool YES "$info_plist"
plutil -replace NSSupportsAutomaticGraphicsSwitching -bool YES "$info_plist"
plutil -replace NSCalendarsFullAccessUsageDescription -string "Kaname reads the calendars you select and changes events only after an exact in-app approval." "$info_plist"
plutil -replace KanameLocalCoreMachService -string "$service_identifier" "$info_plist"
plutil -replace KanameLocalCoreServiceRequirement -string "$service_requirement" "$info_plist"
if [[ -n "$google_oauth_client_id" ]]; then
    plutil -replace KanameGoogleOAuthClientID -string "$google_oauth_client_id" "$info_plist"
    if [[ -n "$google_oauth_client_secret" ]]; then
        plutil -replace KanameGoogleOAuthClientSecret -string "$google_oauth_client_secret" "$info_plist"
    fi
fi

cp "$binary_path" "$contents_path/MacOS/KanamePrototype"
cp "$service_binary_path" "$resources_path/KanameLocalControlService"
cp "$core_binary_path" "$resources_path/kaname-local-core"
cp "$project_dir/LICENSE" "$resources_path/LICENSE"
chmod 755 "$contents_path/MacOS/KanamePrototype"
chmod 755 "$resources_path/KanameLocalControlService" "$resources_path/kaname-local-core"
codesign --force --sign - --identifier "$service_identifier" "$resources_path/KanameLocalControlService"
codesign --force --sign - --identifier "$core_identifier" "$resources_path/kaname-local-core"
codesign --force --sign - --identifier "$identifier" "$app_path"
codesign --verify --deep --strict "$app_path"

echo "$app_path"
