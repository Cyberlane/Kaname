#!/bin/zsh
set -euo pipefail

if [[ $# -ne 2 || "$2" != /* || "$2" == "/" ]]; then
  print -u2 "usage: $0 SCENARIO_ID /absolute/output.png"
  exit 2
fi

scenario_id="$1"
output_path="$2"
manifest_path="Fixtures/design-system/product-scenarios.json"
receipt_path="${KANAME_DESIGN_CAPTURE_RECEIPT:-$PWD/.build/kaname-design-desktop-launch-receipt.json}"
support_base="${KANAME_DESIGN_CAPTURE_SUPPORT_BASE:-}"
replace_receipt="${KANAME_DESIGN_CAPTURE_REPLACE_RECEIPT:-}"

[[ -n "$support_base" && "$support_base" == /* && "$support_base" != "/" ]] || {
  print -u2 "KANAME_DESIGN_CAPTURE_SUPPORT_BASE must be a safe absolute temporary directory."
  exit 2
}

python3 - "$manifest_path" "$scenario_id" "${output_path:t}" <<'PY'
import json
import sys

manifest, identifier, output = sys.argv[1:]
expected_scenarios = {
    "desktop-link-host": {
        "captureVariant": "links",
        "outputFile": "kaname-desktop-link-host.png",
        "platform": "macOS",
        "surface": "desktop.link-host",
        "fixture": "desktop-link-synthetic-fixture",
        "viewport": "1520x940",
        "appearance": "dark",
        "differentiateWithoutColor": False,
        "reduceMotion": False,
        "textScale": "standard",
        "activeWindow": True,
        "locale": "en_US",
        "expectedAccessibilityLabels": [
            "Kaname Link",
            "Gateway status: Ready",
            "Approval required: external device",
            "Trust boundary: external, untrusted",
        ],
        "privacyClass": "synthetic-public",
        "evidenceClass": "fixture-projection",
    },
    "desktop-home-statuses": {
        "captureVariant": "home-statuses",
        "outputFile": "kaname-desktop-home-statuses.png",
        "platform": "macOS",
        "surface": "desktop.home.statuses",
        "fixture": "desktop-status-synthetic-fixture",
        "viewport": "1520x940",
        "appearance": "dark",
        "differentiateWithoutColor": True,
        "reduceMotion": False,
        "textScale": "standard",
        "activeWindow": True,
        "locale": "en_US",
        "expectedAccessibilityLabels": [
            "Environment: Desktop dogfood, local-first",
            "Attention: Needs response",
            "Attention: Needs approval",
            "Attention: Failed",
        ],
        "privacyClass": "synthetic-public",
        "evidenceClass": "fixture-projection",
    },
    "desktop-home-statuses-large-text": {
        "captureVariant": "home-statuses",
        "outputFile": "kaname-desktop-home-statuses-large-text.png",
        "platform": "macOS",
        "surface": "desktop.home.statuses",
        "fixture": "desktop-status-synthetic-fixture",
        "viewport": "1520x940",
        "appearance": "dark",
        "differentiateWithoutColor": True,
        "reduceMotion": False,
        "textScale": "accessibility3",
        "activeWindow": True,
        "locale": "en_US",
        "expectedAccessibilityLabels": [
            "Environment: Desktop dogfood, local-first",
            "Attention: Needs response",
            "Attention: Needs approval",
            "Attention: Failed",
        ],
        "privacyClass": "synthetic-public",
        "evidenceClass": "fixture-projection",
    },
    "desktop-github-statuses": {
        "captureVariant": "github-statuses",
        "outputFile": "kaname-desktop-github-statuses.png",
        "platform": "macOS",
        "surface": "desktop.github.statuses",
        "fixture": "desktop-status-synthetic-fixture",
        "viewport": "1520x940",
        "appearance": "dark",
        "differentiateWithoutColor": False,
        "reduceMotion": False,
        "textScale": "standard",
        "activeWindow": True,
        "locale": "en_US",
        "expectedAccessibilityLabels": ["Status: Ready", "Action status: Awaiting approval"],
        "privacyClass": "synthetic-public",
        "evidenceClass": "fixture-projection",
    },
    "desktop-link-publication-statuses": {
        "captureVariant": "links-publication-statuses",
        "outputFile": "kaname-desktop-link-publication-statuses.png",
        "platform": "macOS",
        "surface": "desktop.link-host.publication",
        "fixture": "desktop-link-synthetic-fixture",
        "viewport": "1520x940",
        "appearance": "dark",
        "differentiateWithoutColor": False,
        "reduceMotion": False,
        "textScale": "standard",
        "activeWindow": True,
        "locale": "en_US",
        "expectedAccessibilityLabels": [
            "Scope: Link only",
            "Publication status: Preview",
            "Delivery receipts",
            "Receipt status: Gateway accepted",
            "Receipt status: Delivered",
        ],
        "privacyClass": "synthetic-public",
        "evidenceClass": "fixture-projection",
    },
}

expected = expected_scenarios.get(identifier)
if expected is None:
    raise SystemExit(f"Unsupported Desktop design scenario: {identifier}")

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
PY

Scripts/verify-kaname-design-tokens.py

mkdir -p "${output_path:h}" "${receipt_path:h}"
if [[ -e "$receipt_path" ]]; then
  print -u2 "Desktop capture receipt path must be fresh: $receipt_path"
  exit 2
fi
launcher_arguments=(--receipt "$receipt_path")
if [[ -n "$replace_receipt" ]]; then
  [[ "$replace_receipt" == /* && -f "$replace_receipt" ]] || {
    print -u2 "KANAME_DESIGN_CAPTURE_REPLACE_RECEIPT must name the exact live Dev receipt."
    exit 2
  }
  launcher_arguments+=(--replace-receipt "$replace_receipt")
fi

Scripts/run-phase0-prototype.sh "${launcher_arguments[@]}" -- \
  --desktop-design-scenario "$scenario_id" \
  --desktop-window-size 1520x940 \
  --desktop-qa-application-support-base "$support_base" >/dev/null

Scripts/verify-kaname-dev-runtime.sh "$receipt_path"
window_id="$(jq -er '.windowID' "$receipt_path")"
sleep 2
screencapture -x -l "$window_id" "$output_path"
[[ -s "$output_path" ]] || {
  print -u2 "Desktop screenshot was not produced: $output_path"
  exit 1
}
Scripts/verify-kaname-dev-runtime.sh "$receipt_path"

Scripts/write-kaname-design-screenshot-receipt.py \
  --manifest "$manifest_path" \
  --scenario "$scenario_id" \
  --image "$output_path" \
  --capture-method "screencapture bound to verified Development receipt window" \
  --renderer "Kaname Desktop synthetic status fixture" \
  --target-runtime "macOS" \
  --desktop-launcher-receipt "$receipt_path" \
  --desktop-preverified \
  --desktop-postverified

print "Captured synthetic-public Desktop scenario $scenario_id at $output_path"
