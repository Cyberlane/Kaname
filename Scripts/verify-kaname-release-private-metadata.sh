#!/usr/bin/env bash

set -euo pipefail

info="${1:-}"
[[ -n "$info" && -f "$info" ]] || {
    echo "Release Info.plist is missing." >&2
    exit 1
}

for key in KanameGoogleOAuthClientID KanameGoogleOAuthClientSecret; do
    if plutil -extract "$key" raw "$info" >/dev/null 2>&1; then
        echo "Public release metadata contains private Google OAuth configuration: $key" >&2
        exit 1
    fi
done
