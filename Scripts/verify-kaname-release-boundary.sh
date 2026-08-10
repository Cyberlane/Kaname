#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
verification_mode="final"
if [[ "${1:-}" == "--pre-notarization" ]]; then
    verification_mode="pre-notarization"
    shift
fi
app_path="${1:-$repo_root/.build/Kaname.app}"
expected_team_id="${KANAME_EXPECTED_TEAM_ID:-}"
info="$app_path/Contents/Info.plist"
resources="$app_path/Contents/Resources"
manifest="$resources/KanameUpdateManifest.json"

[[ -d "$app_path" && -f "$info" ]] || { echo "Kaname app bundle not found: $app_path" >&2; exit 1; }
"$repo_root/Scripts/verify-kaname-release-private-metadata.sh" "$info"
for required in LICENSE ReleaseNotes.md THIRD_PARTY_NOTICES.md Kaname-SBOM.cdx.json KanameUpdateManifest.json; do
    [[ -s "$resources/$required" ]] || { echo "Missing release resource: $required" >&2; exit 1; }
done

bundle_id="$(plutil -extract CFBundleIdentifier raw "$info")"
version="$(plutil -extract CFBundleShortVersionString raw "$info")"
build="$(plutil -extract CFBundleVersion raw "$info")"
[[ "$bundle_id" == com.cyberlane.kaname.desktop ]]
[[ "$(plutil -extract KanameReleaseNotarizationRequired raw "$info")" == true ]]
[[ "$(jq -r .channel "$manifest")" == stable ]]
[[ "$(jq -r .bundleIdentifier "$manifest")" == "$bundle_id" ]]
[[ "$(jq -r .version "$manifest")" == "$version" ]]
[[ "$(jq -r .build "$manifest")" == "$build" ]]
[[ "$(jq -r .releaseNotes "$manifest")" != "" ]]
workspace_schema="$(plutil -extract KanameWorkspaceSchemaVersion raw "$info")"
jq -e --argjson schema "$workspace_schema" \
    '.minimumWorkspaceSchema <= $schema and .maximumWorkspaceSchema >= $schema' "$manifest" >/dev/null
sbom="$resources/Kaname-SBOM.cdx.json"
jq -e '
    .bomFormat == "CycloneDX"
    and .specVersion == "1.5"
    and .version == 1
    and any(.metadata.properties[]?; .name == "kaname:cargo-target" and .value == "aarch64-apple-darwin")
    and (.components | length > 1)
    and ([.components[].purl] | length == (unique | length))
    and all(.components[];
        if (.purl | startswith("pkg:cargo/")) then
            .name != "kaname_core"
            and (.licenses | length > 0)
            and (.licenses[0].expression | type == "string" and length > 0)
            and (.hashes | length == 1)
            and (.hashes[0].alg == "SHA-256")
            and (.hashes[0].content | test("^[0-9a-f]{64}$"))
            and any(.properties[]?; .name == "kaname:source" and (.value | type == "string" and length > 0))
        elif .name == "swift-protobuf" then
            any(.properties[]?; .name == "kaname:locked-revision" and (.value | test("^[0-9a-f]{40}$")))
            and any(.properties[]?; .name == "kaname:source" and (.value | type == "string" and length > 0))
        else false
        end
    )
' "$sbom" >/dev/null
if grep -F -q 'Not available in the local locked source cache' "$resources/THIRD_PARTY_NOTICES.md"; then
    echo "Release notices contain unresolved license metadata." >&2
    exit 1
fi
while IFS=$'\t' read -r dependency_name dependency_version; do
    grep -F -q "## $dependency_name $dependency_version" "$resources/THIRD_PARTY_NOTICES.md" || {
        echo "Release notices are missing SBOM component: $dependency_name $dependency_version" >&2
        exit 1
    }
done < <(jq -r '.components[] | [.name, .version] | @tsv' "$sbom")

for prohibited in workspace.json workspace.previous.json google-tokens.json ui-health.json receipt.json codesign-identity google-oauth-client.json; do
    if find "$app_path" -iname "$prohibited" -print -quit | grep -q .; then
        echo "Private runtime/build material was packaged: $prohibited" >&2
        exit 1
    fi
done

private_patterns=("$repo_root" "$HOME/Library/Application Support/Kaname" "justinnel" "1Password")
while IFS= read -r -d '' file; do
    for pattern in "${private_patterns[@]}"; do
        [[ -z "$pattern" ]] && continue
        if LC_ALL=C grep -F -q "$pattern" "$file"; then
            echo "Private local reference found in packaged text: ${file#"$app_path/"}" >&2
            exit 1
        fi
    done
done < <(find "$app_path" -type f \( -name '*.md' -o -name '*.json' -o -name '*.plist' \) -print0)

[[ -n "$expected_team_id" ]] || {
    echo "Set KANAME_EXPECTED_TEAM_ID to the release Developer ID team." >&2
    exit 1
}
signature_detail="$(codesign -dvvv "$app_path" 2>&1)"
grep -q '^Authority=Developer ID Application:' <<< "$signature_detail" || {
    echo "Release bundle is not signed with Developer ID Application." >&2
    exit 1
}
[[ "$(sed -n 's/^TeamIdentifier=//p' <<< "$signature_detail" | head -1)" == "$expected_team_id" ]] || {
    echo "Release bundle team does not match KANAME_EXPECTED_TEAM_ID." >&2
    exit 1
}
grep -Eq 'flags=.*\(.*runtime.*\)' <<< "$signature_detail" || {
    echo "Release bundle is not signed with hardened runtime." >&2
    exit 1
}
codesign --verify --deep --strict "$app_path"
if [[ "$verification_mode" == "final" ]]; then
    xcrun stapler validate "$app_path"
    spctl --assess --type execute --verbose=4 "$app_path"
fi
echo "Kaname release boundary passed for $version ($build)."
