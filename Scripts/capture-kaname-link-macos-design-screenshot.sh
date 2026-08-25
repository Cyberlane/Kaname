#!/bin/zsh
set -euo pipefail

if [[ -z "${KANAME_TASK_BUILD_DIR:-}" ]]; then
  print -u2 "KANAME_TASK_BUILD_DIR must name this task worktree's private build directory."
  exit 2
fi

if [[ $# -ne 2 || "$2" != /* || "$2" == "/" ]]; then
  print -u2 "usage: $0 SCENARIO_ID /absolute/output.png"
  exit 2
fi

scenario_id="$1"
output_path="$2"
manifest_path="Fixtures/design-system/product-scenarios.json"

scenario_contract="$(python3 - "$manifest_path" "$scenario_id" "${output_path:t}" <<'PY'
import json
import sys

manifest, identifier, output = sys.argv[1:]
expected_scenarios = {
    "link-macos-synthetic": {
        "captureVariant": "discussion",
        "outputFile": "kaname-link-macos.png",
        "platform": "macOS",
        "surface": "link.macos.discussion",
        "fixture": "kaname-link-synthetic-preview",
        "viewport": "1180x760",
        "appearance": "dark",
        "differentiateWithoutColor": False,
        "reduceMotion": False,
        "textScale": "standard",
        "activeWindow": True,
        "locale": "en_US",
        "expectedAccessibilityLabels": [
            "Kaname Link",
            "Connection status: Host online",
            "Host verification: Verified",
            "Discussion status: Waiting for you. Action required.",
            "Action status: Response actions pending",
            "Participant: External collaborator",
            "Message status: Received by host",
            "Participant: Host",
            "Message status: Published by host",
            "Trust boundary: Restricted collaborator",
        ],
        "privacyClass": "synthetic-public",
        "evidenceClass": "fixture-projection",
    },
    "link-macos-synthetic-large-text": {
        "captureVariant": "discussion",
        "outputFile": "kaname-link-macos-large-text.png",
        "platform": "macOS",
        "surface": "link.macos.discussion",
        "fixture": "kaname-link-synthetic-preview",
        "viewport": "1180x760",
        "appearance": "dark",
        "differentiateWithoutColor": False,
        "reduceMotion": False,
        "textScale": "accessibility3",
        "activeWindow": True,
        "locale": "en_US",
        "expectedAccessibilityLabels": [
            "Kaname Link",
            "Connection status: Host online",
            "Host verification: Verified",
            "Discussion status: Waiting for you. Action required.",
            "Action status: Response actions pending",
            "Participant: External collaborator",
            "Message status: Received by host",
            "Participant: Host",
            "Message status: Published by host",
            "Trust boundary: Restricted collaborator",
        ],
        "privacyClass": "synthetic-public",
        "evidenceClass": "fixture-projection",
    },
}

expected = expected_scenarios.get(identifier)
if expected is None:
    raise SystemExit(f"Unsupported Kaname Link macOS design scenario: {identifier}")

with open(manifest, encoding="utf-8") as manifest_file:
    document = json.load(manifest_file)
if document.get("schemaVersion") != 1 or document.get("privacyClass") != "synthetic-public":
    raise SystemExit("The product scenario manifest is not the accepted synthetic-public schema")
scenarios = document.get("scenarios")
if not isinstance(scenarios, list):
    raise SystemExit("The product scenario manifest has no scenario list")
matches = [item for item in scenarios if isinstance(item, dict) and item.get("id") == identifier]
if len(matches) != 1:
    raise SystemExit(f"Expected exactly one product scenario named {identifier}")
scenario = matches[0]
for field, expected_value in expected.items():
    if scenario.get(field) != expected_value:
        raise SystemExit(
            f"Scenario {identifier} has invalid {field}: "
            f"expected {expected_value!r}, found {scenario.get(field)!r}"
        )
if scenario["outputFile"] != output:
    raise SystemExit(f"Output filename must be {scenario['outputFile']}")
print("\t".join([
    scenario["appearance"],
    "true" if scenario["differentiateWithoutColor"] else "false",
    "true" if scenario["reduceMotion"] else "false",
    scenario["textScale"],
    scenario["locale"],
]))
PY
)"
IFS=$'\t' read -r appearance differentiate_without_color reduce_motion text_scale locale_identifier \
  <<< "$scenario_contract"
if [[ -z "$appearance" || -z "$differentiate_without_color" || -z "$reduce_motion" || -z "$text_scale" || -z "$locale_identifier" ]]; then
  print -u2 "Could not load the five renderer axes for Kaname Link scenario $scenario_id"
  exit 2
fi

mkdir -p "${output_path:h}"
Scripts/verify-kaname-design-tokens.py
swift build --scratch-path "$KANAME_TASK_BUILD_DIR" --product KanameLink
KANAME_DESIGN_SCENARIO_ID="$scenario_id" \
KANAME_DESIGN_APPEARANCE="$appearance" \
KANAME_DESIGN_DIFFERENTIATE_WITHOUT_COLOR="$differentiate_without_color" \
KANAME_DESIGN_REDUCE_MOTION="$reduce_motion" \
KANAME_DESIGN_TEXT_SCALE="$text_scale" \
KANAME_DESIGN_LOCALE="$locale_identifier" \
  "$KANAME_TASK_BUILD_DIR/debug/KanameLink" \
  --synthetic-preview \
  --snapshot "$output_path"

if [[ ! -s "$output_path" ]]; then
  print -u2 "Kaname Link screenshot was not produced: $output_path"
  exit 1
fi

Scripts/write-kaname-design-screenshot-receipt.py \
  --manifest "$manifest_path" \
  --scenario "$scenario_id" \
  --image "$output_path" \
  --capture-method "offscreen SwiftUI ImageRenderer" \
  --renderer "KanameLink macOS synthetic preview" \
  --target-runtime "macOS"

print "Captured synthetic-public Kaname Link macOS scenario $scenario_id at $output_path"
