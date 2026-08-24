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
output_directory="${output_path:h}"
mkdir -p "$output_directory"
capture_path="$output_directory/.kaname-ios-capture-$$.png"

booted_simulator_count="$(xcrun simctl list devices booted --json | python3 -c '
import json, sys
document = json.load(sys.stdin)
print(sum(len(devices) for devices in document["devices"].values()))
')"
if [[ "$booted_simulator_count" != "0" ]]; then
  print -u2 "iPhone screenshot capture requires no pre-existing booted simulator so UI dismissal is bound to the task device."
  exit 2
fi

runtime_identifier="${KANAME_IOS_SCREENSHOT_RUNTIME:-com.apple.CoreSimulator.SimRuntime.iOS-26-3}"
xcrun simctl list runtimes --json | python3 -c '
import json, sys
identifier = sys.argv[1]
runtimes = json.load(sys.stdin)["runtimes"]
if not any(r.get("isAvailable") and r["identifier"] == identifier for r in runtimes):
    raise SystemExit(f"Pinned iOS screenshot runtime is unavailable: {identifier}")
' "$runtime_identifier"

device_type_name="${KANAME_IOS_SCREENSHOT_DEVICE:-iPhone 15}"
device_type_identifier="$(xcrun simctl list devicetypes --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devicetypes"]
selected = next((d for d in devices if d["name"] == sys.argv[1]), None)
if selected is None:
    raise SystemExit(f"Pinned iPhone screenshot device is unavailable: {sys.argv[1]}")
print(selected["identifier"])
' "$device_type_name")"

simulator_name="Kaname Design System $$"
simulator_id="$(xcrun simctl create "$simulator_name" "$device_type_identifier" "$runtime_identifier")"

cleanup() {
  rm -f "$capture_path"
  xcrun simctl shutdown "$simulator_id" >/dev/null 2>&1 || true
  xcrun simctl delete "$simulator_id" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

capture_has_clear_synthetic_banner() {
  xcrun swift - "$1" <<'SWIFT'
import AppKit
import Darwin

guard CommandLine.arguments.count == 2,
      let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let data = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: data),
      bitmap.pixelsWide > 900,
      bitmap.pixelsHigh > 200 else {
    fputs("Could not inspect the iPhone screenshot for system overlays.\n", stderr)
    exit(EXIT_FAILURE)
}

let colors = [20, 500, 900].compactMap {
  bitmap.colorAt(x: $0, y: 200)?.usingColorSpace(.deviceRGB)
}
guard colors.count == 3 else {
  fputs("Could not sample the iPhone synthetic banner.\n", stderr)
  exit(EXIT_FAILURE)
}

let channels = [
  colors.map(\.redComponent),
  colors.map(\.greenComponent),
  colors.map(\.blueComponent),
]
let maximumSpread = channels.map { ($0.max() ?? 1) - ($0.min() ?? 0) }.max() ?? 1
if maximumSpread > (3.0 / 255.0) {
  fputs("A system overlay obscures the iPhone synthetic banner.\n", stderr)
  exit(EXIT_FAILURE)
}
SWIFT
}

xcrun simctl boot "$simulator_id"
xcrun simctl bootstatus "$simulator_id" -b
xcrun simctl ui "$simulator_id" appearance dark
xcrun simctl status_bar "$simulator_id" override \
  --time "9:41" \
  --operatorName "Kaname" \
  --wifiBars 3 \
  --cellularBars 4 \
  --batteryLevel 100 \
  --batteryState charged

derived_data="$KANAME_TASK_BUILD_DIR/ios-design-screenshot"
build_log="$KANAME_TASK_BUILD_DIR/ios-design-screenshot-build.log"
if ! xcodebuild \
  -project iOS/KanameIPhonePrototype.xcodeproj \
  -scheme KanameIPhonePrototype \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$derived_data" \
  -clonedSourcePackagesDirPath "$KANAME_TASK_BUILD_DIR/ios-source-packages" \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  build >"$build_log" 2>&1; then
  print -u2 "iPhone screenshot build failed; the final build log follows."
  tail -n 120 "$build_log" >&2
  exit 1
fi

application_path="$derived_data/Build/Products/Debug-iphonesimulator/KanameIPhonePrototype.app"
if [[ ! -d "$application_path" ]]; then
  print -u2 "Built iPhone app was not found at $application_path"
  exit 1
fi

xcrun simctl install "$simulator_id" "$application_path"
SIMCTL_CHILD_KANAME_SYNTHETIC_SCREENSHOT=1 \
  xcrun simctl launch --terminate-running-process \
    "$simulator_id" \
    com.cyberlane.kaname.iphoneprototype
# Keep Simulator headless: activating its host window can itself trigger a
# first-run system notification that contaminates an otherwise clean capture.
sleep 12

capture_ready=false
for capture_attempt in 1 2 3 4; do
  rm -f "$capture_path"
  xcrun simctl io "$simulator_id" screenshot --type=png "$capture_path"
  file_ready=false
  for readiness_attempt in {1..10}; do
    if [[ -s "$capture_path" ]]; then
      file_ready=true
      break
    fi
    sleep 0.5
  done
  if [[ "$file_ready" == "true" ]] && capture_has_clear_synthetic_banner "$capture_path"; then
    capture_ready=true
    break
  fi
  sleep 8
done

if [[ "$capture_ready" != "true" || ! -s "$capture_path" ]]; then
  print -u2 "iPhone screenshot is missing, unreadable, or obscured by a system overlay: $output_path"
  exit 1
fi

capture_size="$(stat -f %z "$capture_path")"
if [[ "$capture_size" -lt 100000 ]]; then
  print -u2 "iPhone screenshot is unexpectedly small ($capture_size bytes): $output_path"
  exit 1
fi

mv -f "$capture_path" "$output_path"
Scripts/write-kaname-design-screenshot-receipt.py \
  --manifest "Fixtures/design-system/product-scenarios.json" \
  --scenario "ios-home-synthetic" \
  --image "$output_path" \
  --capture-method "simctl io screenshot on task-owned clean simulator" \
  --renderer "KanameIPhonePrototype memory-only synthetic root" \
  --target-runtime "$device_type_name · $runtime_identifier"

print "Captured one synthetic-public Kaname iOS screenshot at $output_path"
