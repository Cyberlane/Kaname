#!/bin/zsh
set -euo pipefail

if [[ -z "${KANAME_TASK_BUILD_DIR:-}" ]]; then
  print -u2 "KANAME_TASK_BUILD_DIR must name this task worktree's private build directory."
  exit 2
fi

if [[ $# -ne 1 || "$1" != /* || "$1" == "/" ]]; then
  print -u2 "usage: $0 /absolute/output/directory"
  exit 2
fi

output_directory="$1"
mkdir -p "$output_directory"

Scripts/verify-kaname-design-tokens.py
swift build --scratch-path "$KANAME_TASK_BUILD_DIR" --product KanameDesignCatalog
catalog_binary="$KANAME_TASK_BUILD_DIR/debug/KanameDesignCatalog"
scenario_manifest="Fixtures/design-system/catalog-scenarios.json"

while IFS=$'\t' read -r scenario_id catalog_page output_file viewport appearance differentiate reduce_motion text_scale active_window locale; do
  "$catalog_binary" \
    --page "$catalog_page" \
    --viewport "$viewport" \
    --appearance "$appearance" \
    --differentiate-without-color "$differentiate" \
    --reduce-motion "$reduce_motion" \
    --text-scale "$text_scale" \
    --active-window "$active_window" \
    --locale "$locale" \
    --snapshot "$output_directory/$output_file"
  Scripts/write-kaname-design-screenshot-receipt.py \
    --manifest "$scenario_manifest" \
    --scenario "$scenario_id" \
    --image "$output_directory/$output_file" \
    --capture-method "offscreen SwiftUI ImageRenderer" \
    --renderer "KanameDesignCatalog" \
    --target-runtime "macOS"
done < <(python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)
if document.get("privacyClass") != "synthetic-public":
    raise SystemExit("Catalog manifest must be synthetic-public")
for scenario in document["scenarios"]:
    if scenario["fixture"] == "design-system.catalog":
        if scenario["privacyClass"] != "synthetic-public":
            raise SystemExit("Catalog scenario is not synthetic-public: " + scenario["id"])
        values = [
            scenario["id"],
            scenario["captureVariant"],
            scenario["outputFile"],
            scenario["viewport"],
            scenario["appearance"],
            str(scenario["differentiateWithoutColor"]).lower(),
            str(scenario["reduceMotion"]).lower(),
            scenario["textScale"],
            str(scenario["activeWindow"]).lower(),
            scenario["locale"],
        ]
        print("\t".join(values))
' "$scenario_manifest")

print "Captured 7 synthetic-public catalog screenshots in $output_directory"
