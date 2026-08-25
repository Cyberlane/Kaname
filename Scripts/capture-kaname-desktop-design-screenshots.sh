#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 || "$1" != /* || "$1" == "/" ]]; then
  print -u2 "usage: $0 /absolute/output-directory"
  exit 2
fi

output_directory="$1"
manifest_path="Fixtures/design-system/product-scenarios.json"
mkdir -p "$output_directory"
mkdir -p "$PWD/.build"
capture_support_base="$(mktemp -d "${TMPDIR:-/tmp}/kaname-design-desktop.XXXXXX")"
capture_receipt_directory="$(mktemp -d "$PWD/.build/kaname-design-desktop-receipts.XXXXXX")"
current_receipt=""
pending_receipt=""

cleanup_desktop_capture() {
  for owned_receipt in "$pending_receipt" "$current_receipt"; do
    if [[ -n "$owned_receipt" && -f "$owned_receipt" ]] \
      && Scripts/verify-kaname-dev-runtime.sh "$owned_receipt" >/dev/null 2>&1; then
      capture_pid="$(jq -r '.processID' "$owned_receipt")"
      service_identifier="$(jq -r '.localCoreMachService // empty' "$owned_receipt")"
      kill -TERM "$capture_pid"
      for _ in {1..100}; do
        kill -0 "$capture_pid" 2>/dev/null || break
        sleep 0.05
      done
      if [[ "$service_identifier" == "com.cyberlane.kaname.desktop.dev.localcore.service" ]]; then
        launchctl bootout "gui/$(id -u)/$service_identifier" >/dev/null 2>&1 || true
      fi
      break
    fi
  done
  if [[ -d "$capture_support_base" && ! -L "$capture_support_base" && "$capture_support_base" == *"/kaname-design-desktop."* ]]; then
    rm -rf -- "$capture_support_base"
  fi
  if [[ -d "$capture_receipt_directory" && ! -L "$capture_receipt_directory" && "$capture_receipt_directory" == "$PWD/.build/kaname-design-desktop-receipts."* ]]; then
    rm -rf -- "$capture_receipt_directory"
  fi
}
trap cleanup_desktop_capture EXIT INT TERM

Scripts/verify-kaname-design-tokens.py

for scenario_id in \
  desktop-link-host \
  desktop-home-statuses \
  desktop-home-statuses-large-text \
  desktop-github-statuses \
  desktop-link-publication-statuses
do
  output_file="$(Scripts/kaname-design-scenario-output.py "$manifest_path" "$scenario_id")"
  pending_receipt="$capture_receipt_directory/$scenario_id.json"
  KANAME_DESIGN_CAPTURE_SUPPORT_BASE="$capture_support_base" \
  KANAME_DESIGN_CAPTURE_RECEIPT="$pending_receipt" \
  KANAME_DESIGN_CAPTURE_REPLACE_RECEIPT="$current_receipt" \
    Scripts/capture-kaname-desktop-design-screenshot.sh \
      "$scenario_id" "$output_directory/$output_file"
  current_receipt="$pending_receipt"
  pending_receipt=""
  if [[ "$scenario_id" == "desktop-home-statuses-large-text" ]]; then
    Scripts/assert-kaname-design-capture-pair-diff.sh \
      "$manifest_path" \
      "$output_directory" \
      desktop-home-statuses \
      desktop-home-statuses-large-text \
      "Desktop standard and accessibility3 captures are byte-identical; synthetic large-text rendering failed."
  fi
done

print "Captured five synthetic-public Kaname Desktop screenshots in $output_directory"
