#!/bin/zsh
set -euo pipefail

if [[ -z "${KANAME_TASK_BUILD_DIR:-}" ]]; then
  print -u2 "KANAME_TASK_BUILD_DIR must name this task worktree's private build directory."
  exit 2
fi

if [[ $# -ne 1 || "$1" != /* || "$1" == "/" ]]; then
  print -u2 "usage: $0 /absolute/output.png"
  exit 2
fi

output_path="$1"
mkdir -p "${output_path:h}"
Scripts/verify-kaname-design-tokens.py
swift build --scratch-path "$KANAME_TASK_BUILD_DIR" --product KanameLink
"$KANAME_TASK_BUILD_DIR/debug/KanameLink" \
  --synthetic-preview \
  --snapshot "$output_path"

if [[ ! -s "$output_path" ]]; then
  print -u2 "Kaname Link screenshot was not produced: $output_path"
  exit 1
fi

Scripts/write-kaname-design-screenshot-receipt.py \
  --manifest "Fixtures/design-system/product-scenarios.json" \
  --scenario "link-macos-synthetic" \
  --image "$output_path" \
  --capture-method "offscreen SwiftUI ImageRenderer" \
  --renderer "KanameLink macOS synthetic preview" \
  --target-runtime "macOS"

print "Captured one synthetic-public Kaname Link macOS screenshot at $output_path"
