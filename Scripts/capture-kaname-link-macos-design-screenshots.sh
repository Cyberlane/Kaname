#!/bin/zsh
set -euo pipefail

if [[ $# -ne 1 || "$1" != /* || "$1" == "/" ]]; then
  print -u2 "usage: $0 /absolute/output-directory"
  exit 2
fi

output_directory="$1"
manifest_path="Fixtures/design-system/product-scenarios.json"
scenario_ids=(
  link-macos-synthetic
  link-macos-synthetic-large-text
)

mkdir -p "$output_directory"
captured_count=0
for scenario_id in "${scenario_ids[@]}"; do
  output_file="$(Scripts/kaname-design-scenario-output.py "$manifest_path" "$scenario_id")"
  Scripts/capture-kaname-link-macos-design-screenshot.sh \
    "$scenario_id" "$output_directory/$output_file"
  (( captured_count += 1 ))
done

print "Captured $captured_count synthetic-public Kaname Link macOS screenshots in $output_directory"
