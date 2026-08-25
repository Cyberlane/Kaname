#!/bin/zsh
set -euo pipefail

if [[ $# -ne 5 ]]; then
  print -u2 "usage: $0 manifest.json /absolute/output-directory standard-scenario scaled-scenario diagnostic"
  exit 2
fi

manifest_path="$1"
output_directory="$2"
standard_scenario="$3"
scaled_scenario="$4"
diagnostic="$5"

if [[ ! -f "$manifest_path" ]]; then
  print -u2 "Kaname capture-pair manifest does not exist: $manifest_path"
  exit 2
fi
if [[ "$output_directory" != /* || "$output_directory" == "/" || ! -d "$output_directory" ]]; then
  print -u2 "Kaname capture-pair output must be an existing absolute directory."
  exit 2
fi
if [[ -z "$standard_scenario" || -z "$scaled_scenario" || -z "$diagnostic" ]]; then
  print -u2 "Kaname capture-pair scenario identifiers and diagnostic must be non-empty."
  exit 2
fi

script_directory="${0:A:h}"
scenario_output_helper="$script_directory/kaname-design-scenario-output.py"
standard_output_file="$("$scenario_output_helper" "$manifest_path" "$standard_scenario")"
scaled_output_file="$("$scenario_output_helper" "$manifest_path" "$scaled_scenario")"
standard_image="$output_directory/$standard_output_file"
scaled_image="$output_directory/$scaled_output_file"

if [[ ! -f "$standard_image" || ! -f "$scaled_image" ]]; then
  print -u2 "Kaname capture-pair images are incomplete: $standard_scenario and $scaled_scenario"
  exit 1
fi
if cmp -s "$standard_image" "$scaled_image"; then
  print -u2 "$diagnostic"
  exit 1
fi
