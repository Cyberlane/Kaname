#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
verifier="$repo_root/Scripts/verify-kaname-release-private-metadata.sh"
temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/kaname-release-privacy.XXXXXX")"
trap 'rm -r "$temporary_directory"' EXIT
info="$temporary_directory/Info.plist"

plutil -create xml1 "$info"
"$verifier" "$info"

plutil -insert KanameGoogleOAuthClientID -string fixture-client-id-not-a-real-credential "$info"
if "$verifier" "$info"; then
    echo "Release privacy verification accepted an OAuth client ID." >&2
    exit 1
fi
plutil -remove KanameGoogleOAuthClientID "$info"

plutil -insert KanameGoogleOAuthClientSecret -string fixture-client-secret-not-a-real-credential "$info"
if "$verifier" "$info"; then
    echo "Release privacy verification accepted an OAuth client secret." >&2
    exit 1
fi

echo "Kaname release private-metadata fixtures passed."
