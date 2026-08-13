#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
configuration="${KANAME_BUILD_CONFIGURATION:-release}"
channel="${KANAME_DESKTOP_CHANNEL:-stable}"
case "$channel" in
    stable)
        app_name="Kaname"
        identifier="com.cyberlane.kaname.desktop"
        service_identifier="com.cyberlane.kaname.desktop.localcore.service"
        core_identifier="com.cyberlane.kaname.desktop.localcore"
        ;;
    candidate)
        app_name="Kaname Candidate"
        identifier="com.cyberlane.kaname.desktop.candidate"
        service_identifier="com.cyberlane.kaname.desktop.candidate.localcore.service"
        core_identifier="com.cyberlane.kaname.desktop.candidate.localcore"
        ;;
    *)
        echo "KANAME_DESKTOP_CHANNEL must be stable or candidate." >&2
        exit 1
        ;;
esac
app_path="$project_dir/.build/$app_name.app"
contents_path="$app_path/Contents"
resources_path="$contents_path/Resources"
binary_path="$project_dir/.build/$configuration/KanamePrototype"
service_binary_path="$project_dir/.build/$configuration/KanameLocalControlService"
update_helper_path="$project_dir/.build/$configuration/KanameUpdateHelper"
conversation_worker_path="$project_dir/.build/$configuration/KanameConversationWorker"
workflow_worker_path="$project_dir/.build/$configuration/KanameWorkflowWorker"
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
service_requirement="identifier \"$service_identifier\""
app_version="${KANAME_APP_VERSION:-0.23.0}"
app_build="${KANAME_APP_BUILD:-43}"
workspace_schema_version=26
release_notarization="${KANAME_RELEASE_NOTARIZATION:-NO}"
release_notes_path="${KANAME_RELEASE_NOTES_FILE:-$project_dir/Docs/KanameReleaseNotes.md}"
google_oauth_config_path="${KANAME_GOOGLE_OAUTH_CONFIG:-$HOME/Library/Application Support/Kaname/Build/google-oauth-client.json}"
google_oauth_client_id="${KANAME_GOOGLE_OAUTH_CLIENT_ID:-}"
google_oauth_client_secret="${KANAME_GOOGLE_OAUTH_CLIENT_SECRET:-}"
codesign_identity_path="${KANAME_CODESIGN_IDENTITY_FILE:-$HOME/Library/Application Support/Kaname/Build/codesign-identity}"
codesign_identity="${KANAME_CODESIGN_IDENTITY:-}"

if [[ "$release_notarization" != "YES" && "$release_notarization" != "NO" ]]; then
    echo "KANAME_RELEASE_NOTARIZATION must be YES or NO." >&2
    exit 1
fi
if [[ "$release_notarization" == "YES" && ( -n "$google_oauth_client_id" || -n "$google_oauth_client_secret" ) ]]; then
    echo "Public notarized releases cannot embed a private Google OAuth client. Use a personal non-release build for private registration." >&2
    exit 1
fi
if [[ "$release_notarization" != "YES" && -z "$google_oauth_client_id" && -f "$google_oauth_config_path" ]]; then
    google_oauth_client_id="$(plutil -extract installed.client_id raw "$google_oauth_config_path")"
    google_oauth_client_secret="$(plutil -extract installed.client_secret raw "$google_oauth_config_path" 2>/dev/null || true)"
fi

if [[ -z "$codesign_identity" && -f "$codesign_identity_path" ]]; then
    IFS= read -r codesign_identity < "$codesign_identity_path"
fi
codesign_identity="${codesign_identity:--}"
stable_code_signing=NO
codesign_arguments=(--force --sign "$codesign_identity")
if [[ "$release_notarization" == "YES" && ("$channel" != "stable" || "$codesign_identity" == "-") ]]; then
    echo "Notarized release builds require the stable channel and a configured Developer ID identity." >&2
    exit 1
fi
if [[ "$codesign_identity" != "-" ]]; then
    stable_code_signing=YES
    if [[ "$release_notarization" == "YES" ]]; then
        codesign_arguments+=(--options runtime --timestamp)
    else
        codesign_arguments+=(--timestamp=none)
    fi
fi
[[ -s "$release_notes_path" ]] || { echo "Release notes are missing: $release_notes_path" >&2; exit 1; }

cd "$project_dir"
swift build -c "$configuration" --product KanamePrototype
swift build -c "$configuration" --product KanameLocalControlService
swift build -c "$configuration" --product KanameUpdateHelper
swift build -c "$configuration" --product KanameConversationWorker
swift build -c "$configuration" --product KanameWorkflowWorker
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
plutil -replace CFBundleName -string "$app_name" "$info_plist"
plutil -replace CFBundleDisplayName -string "$app_name" "$info_plist"
plutil -replace CFBundlePackageType -string APPL "$info_plist"
plutil -replace CFBundleShortVersionString -string "$app_version" "$info_plist"
plutil -replace CFBundleVersion -string "$app_build" "$info_plist"
plutil -replace LSApplicationCategoryType -string public.app-category.developer-tools "$info_plist"
plutil -replace LSMinimumSystemVersion -string 14.0 "$info_plist"
plutil -replace NSPrincipalClass -string NSApplication "$info_plist"
plutil -replace NSHighResolutionCapable -bool YES "$info_plist"
plutil -replace NSSupportsAutomaticGraphicsSwitching -bool YES "$info_plist"
plutil -insert CFBundleDocumentTypes -json '[{"CFBundleTypeName":"Local text or source files","CFBundleTypeRole":"Viewer","LSHandlerRank":"Alternate","LSItemContentTypes":["public.plain-text","public.source-code","public.json","public.xml","public.yaml"]}]' "$info_plist"
plutil -replace NSCalendarsFullAccessUsageDescription -string "Kaname reads the calendars you select and changes events only after an exact in-app approval." "$info_plist"
plutil -replace KanameLocalCoreMachService -string "$service_identifier" "$info_plist"
plutil -replace KanameLocalCoreServiceRequirement -string "$service_requirement" "$info_plist"
plutil -replace KanameDesktopChannel -string "$channel" "$info_plist"
plutil -replace KanameStableCodeSigning -bool "$stable_code_signing" "$info_plist"
plutil -replace KanameReleaseNotarizationRequired -bool "$release_notarization" "$info_plist"
plutil -replace KanameWorkspaceSchemaVersion -integer "$workspace_schema_version" "$info_plist"
if [[ -n "$google_oauth_client_id" ]]; then
    plutil -replace KanameGoogleOAuthClientID -string "$google_oauth_client_id" "$info_plist"
    if [[ -n "$google_oauth_client_secret" ]]; then
        plutil -replace KanameGoogleOAuthClientSecret -string "$google_oauth_client_secret" "$info_plist"
    fi
fi

cp "$binary_path" "$contents_path/MacOS/KanamePrototype"
cp "$service_binary_path" "$resources_path/KanameLocalControlService"
cp "$update_helper_path" "$resources_path/KanameUpdateHelper"
cp "$conversation_worker_path" "$resources_path/KanameConversationWorker"
cp "$workflow_worker_path" "$resources_path/KanameWorkflowWorker"
cp "$core_binary_path" "$resources_path/kaname-local-core"
cp "$project_dir/LICENSE" "$resources_path/LICENSE"
cp "$release_notes_path" "$resources_path/ReleaseNotes.md"
python3 "$script_dir/generate-release-metadata.py" "$resources_path"
jq -n \
    --arg channel "$channel" \
    --arg bundleIdentifier "$identifier" \
    --arg version "$app_version" \
    --arg build "$app_build" \
    --argjson maximumWorkspaceSchema "$workspace_schema_version" \
    --arg releaseNotes "$(sed -n '2,$p' "$release_notes_path" | sed '/^[[:space:]]*$/d')" \
    '{schemaVersion: 1, channel: $channel, bundleIdentifier: $bundleIdentifier, version: $version, build: $build, minimumWorkspaceSchema: 1, maximumWorkspaceSchema: $maximumWorkspaceSchema, releaseNotes: $releaseNotes}' \
    > "$resources_path/KanameUpdateManifest.json"
chmod 755 "$contents_path/MacOS/KanamePrototype"
chmod 755 "$resources_path/KanameLocalControlService" "$resources_path/KanameUpdateHelper" "$resources_path/KanameConversationWorker" "$resources_path/KanameWorkflowWorker" "$resources_path/kaname-local-core"
codesign "${codesign_arguments[@]}" --identifier "$service_identifier" "$resources_path/KanameLocalControlService"
codesign "${codesign_arguments[@]}" --identifier "$identifier.update-helper" "$resources_path/KanameUpdateHelper"
codesign "${codesign_arguments[@]}" --identifier "$identifier.conversation-worker" "$resources_path/KanameConversationWorker"
codesign "${codesign_arguments[@]}" --identifier "$identifier.workflow-worker" "$resources_path/KanameWorkflowWorker"
codesign "${codesign_arguments[@]}" --identifier "$core_identifier" "$resources_path/kaname-local-core"
codesign "${codesign_arguments[@]}" --identifier "$identifier" "$app_path"
codesign --verify --deep --strict "$app_path"
if [[ "$release_notarization" == "YES" ]]; then
    codesign -dvv "$app_path" 2>&1 | grep -q '^Authority=Developer ID Application:' || {
        echo "Release signing identity is not Developer ID Application." >&2
        exit 1
    }
fi

echo "$app_path"
