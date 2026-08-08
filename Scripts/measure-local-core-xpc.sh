#!/usr/bin/env bash

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$project_dir/.build/Kaname Prototype.app"
info_plist="$app_path/Contents/Info.plist"
measure_path="$project_dir/.build/debug/KanameLocalCoreXPCMeasure"
app_identifier="com.cyberlane.kaname.local-core-prototype"

if [[ ! -f "$info_plist" ]]; then
    echo "Run Scripts/run-local-core-prototype.sh first to install the signed local service." >&2
    exit 1
fi

mach_service="$(plutil -extract KanameLocalCoreMachService raw "$info_plist")"
service_requirement="$(plutil -extract KanameLocalCoreServiceRequirement raw "$info_plist")"
signing_identity="${KANAME_XPC_SIGNING_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -n 1)}"
if [[ -z "$signing_identity" ]]; then
    echo "A local Apple Development signing identity is required for this authenticated XPC measurement." >&2
    exit 1
fi

cd "$project_dir"
swift build --product KanameLocalCoreXPCMeasure
codesign --force --sign "$signing_identity" --identifier "$app_identifier" "$measure_path"
exec "$measure_path" --mach-service "$mach_service" --service-requirement "$service_requirement" --repetitions 25
