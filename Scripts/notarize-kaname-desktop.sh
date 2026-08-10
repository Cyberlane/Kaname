#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
app_path="${1:-$repo_root/.build/Kaname.app}"
profile="${KANAME_NOTARY_KEYCHAIN_PROFILE:-}"
output_directory="${KANAME_RELEASE_OUTPUT_DIRECTORY:-$repo_root/.build/release}"

[[ -n "$profile" ]] || { echo "Set KANAME_NOTARY_KEYCHAIN_PROFILE to a notarytool Keychain profile name." >&2; exit 1; }
[[ -d "$app_path" ]] || { echo "Stable Kaname bundle not found: $app_path" >&2; exit 1; }
[[ "$(plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist")" == com.cyberlane.kaname.desktop ]]
[[ "$(plutil -extract KanameReleaseNotarizationRequired raw "$app_path/Contents/Info.plist")" == true ]]
codesign --verify --deep --strict "$app_path"
codesign -dvv "$app_path" 2>&1 | grep -q '^Authority=Developer ID Application:' || {
    echo "Kaname is not signed with Developer ID Application." >&2
    exit 1
}
"$repo_root/Scripts/verify-kaname-release-boundary.sh" --pre-notarization "$app_path"

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/kaname-notary.XXXXXX")"
trap 'rm -r "$temporary_directory"' EXIT
submission="$temporary_directory/Kaname.zip"
ditto -c -k --keepParent "$app_path" "$submission"
xcrun notarytool submit "$submission" --keychain-profile "$profile" --wait
xcrun stapler staple "$app_path"
xcrun stapler validate "$app_path"
spctl --assess --type execute --verbose=4 "$app_path"
"$repo_root/Scripts/verify-kaname-release-boundary.sh" "$app_path"

mkdir -p "$output_directory"
version="$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")"
build="$(plutil -extract CFBundleVersion raw "$app_path/Contents/Info.plist")"
archive="$output_directory/Kaname-$version-$build-macos.zip"
ditto -c -k --keepParent "$app_path" "$archive"
archive_check="$temporary_directory/archive-check"
mkdir -p "$archive_check"
ditto -x -k "$archive" "$archive_check"
"$repo_root/Scripts/verify-kaname-release-boundary.sh" "$archive_check/Kaname.app"
digest="$(shasum -a 256 "$archive" | awk '{print $1}')"
jq -n --arg version "$version" --arg build "$build" --arg archive "$(basename "$archive")" --arg sha256 "$digest" \
    '{schemaVersion: 1, channel: "stable", version: $version, build: $build, archive: $archive, sha256: $sha256, notarized: true, stapled: true}' \
    > "$output_directory/Kaname-$version-$build-release-receipt.json"
chmod 600 "$output_directory/Kaname-$version-$build-release-receipt.json"
echo "$archive"
