#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 || "$1" != /* || "$1" == "/" ]]; then
  print -u2 "usage: $0 /absolute/output-directory"
  exit 2
fi

output_directory="$1"
manifest_path="Fixtures/design-system/product-scenarios.json"
scenario_ids=(
  ios-home-synthetic
  ios-project-github-statuses
  ios-project-github-statuses-large-text
)

mkdir -p "$output_directory"
captured_count=0
for scenario_id in "${scenario_ids[@]}"; do
  output_file="$(Scripts/kaname-design-scenario-output.py "$manifest_path" "$scenario_id")"
  Scripts/capture-kaname-ios-design-screenshot.sh \
    "$scenario_id" "$output_directory/$output_file"
  (( captured_count += 1 ))
  if [[ "$scenario_id" == "ios-project-github-statuses-large-text" ]]; then
    Scripts/assert-kaname-design-capture-pair-diff.sh \
      "$manifest_path" \
      "$output_directory" \
      ios-project-github-statuses \
      ios-project-github-statuses-large-text \
      "Kaname iOS standard and accessibility3 captures are byte-identical; large-text rendering failed."
  fi
done

print "Captured $captured_count synthetic-public Kaname iOS screenshots in $output_directory"
