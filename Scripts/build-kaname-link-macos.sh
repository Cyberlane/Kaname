#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
project_dir="$(cd "$script_dir/.." && pwd -P)"
configuration="${KANAME_LINK_BUILD_CONFIGURATION:-release}"
app_version="${KANAME_LINK_APP_VERSION:-0.1.0}"
app_build="${KANAME_LINK_APP_BUILD:-1}"
codesign_identity="${KANAME_LINK_CODESIGN_IDENTITY:--}"

case "$configuration" in
    debug|release) ;;
    *)
        echo "KANAME_LINK_BUILD_CONFIGURATION must be debug or release." >&2
        exit 2
        ;;
esac

app_path="$project_dir/.build/Kaname Link.app"
contents_path="$app_path/Contents"
macos_path="$contents_path/MacOS"
resources_path="$contents_path/Resources"
info_plist="$contents_path/Info.plist"
swift_binary="$project_dir/.build/$configuration/KanameLink"
rust_profile="$configuration"
rust_arguments=(build --locked --manifest-path "$project_dir/Rust/KanameLinkCore/Cargo.toml" --bin kaname-link-client)
if [[ "$configuration" == "release" ]]; then
    rust_arguments+=(--release)
fi
rust_binary="$project_dir/Rust/KanameLinkCore/target/$rust_profile/kaname-link-client"

cd "$project_dir"
swift build -c "$configuration" --product KanameLink
cargo "${rust_arguments[@]}"

[[ -x "$swift_binary" ]] || { echo "Missing Kaname Link shell: $swift_binary" >&2; exit 1; }
[[ -x "$rust_binary" ]] || { echo "Missing Kaname Link core: $rust_binary" >&2; exit 1; }

if [[ -e "$app_path" ]]; then
    rm -r "$app_path"
fi
mkdir -p "$macos_path" "$resources_path"

plutil -create xml1 "$info_plist"
plutil -replace CFBundleDevelopmentRegion -string en "$info_plist"
plutil -replace CFBundleExecutable -string KanameLink "$info_plist"
plutil -replace CFBundleIdentifier -string com.cyberlane.kaname.link "$info_plist"
plutil -replace CFBundleInfoDictionaryVersion -string 6.0 "$info_plist"
plutil -replace CFBundleName -string "Kaname Link" "$info_plist"
plutil -replace CFBundleDisplayName -string "Kaname Link" "$info_plist"
plutil -replace CFBundlePackageType -string APPL "$info_plist"
plutil -replace CFBundleShortVersionString -string "$app_version" "$info_plist"
plutil -replace CFBundleVersion -string "$app_build" "$info_plist"
plutil -replace LSApplicationCategoryType -string public.app-category.productivity "$info_plist"
plutil -replace LSMinimumSystemVersion -string 26.0 "$info_plist"
plutil -replace NSPrincipalClass -string NSApplication "$info_plist"
plutil -replace NSHighResolutionCapable -bool YES "$info_plist"

cp "$swift_binary" "$macos_path/KanameLink"
cp "$rust_binary" "$resources_path/kaname-link-client"
cp "$project_dir/LICENSE" "$resources_path/LICENSE"
chmod 755 "$macos_path/KanameLink" "$resources_path/kaname-link-client"

codesign_arguments=(--force --sign "$codesign_identity")
if [[ "$codesign_identity" != "-" ]]; then
    codesign_arguments+=(--timestamp=none)
fi
codesign "${codesign_arguments[@]}" \
    --identifier com.cyberlane.kaname.link.client-core \
    "$resources_path/kaname-link-client"
codesign "${codesign_arguments[@]}" \
    --identifier com.cyberlane.kaname.link \
    "$app_path"
codesign --verify --deep --strict "$app_path"

printf '%s\n' "$app_path"
