#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
helper="$repo_root/.build/release/KanameUpdateHelper"
if [[ ! -x "$helper" ]]; then
  swift build -c release --product KanameUpdateHelper --package-path "$repo_root"
fi

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/kaname-update-helper.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
installed="$fixture_root/Installed/Kaname.app"
staged="$fixture_root/Staged/Kaname.app"
backup="$fixture_root/Previous/Kaname.app"
health="$fixture_root/ui-health.json"
receipt="$fixture_root/receipt.json"
bundle_id="com.cyberlane.kaname.update-fixture.$PPID.$$"

make_fixture_app() {
  local app_path="$1"
  local version="$2"
  local build="$3"
  local health_behavior="$4"
  mkdir -p "$app_path/Contents/MacOS"
  plutil -create xml1 "$app_path/Contents/Info.plist"
  plutil -insert CFBundleIdentifier -string "$bundle_id" "$app_path/Contents/Info.plist"
  plutil -insert CFBundleExecutable -string Fixture "$app_path/Contents/Info.plist"
  plutil -insert CFBundlePackageType -string APPL "$app_path/Contents/Info.plist"
  plutil -insert CFBundleShortVersionString -string "$version" "$app_path/Contents/Info.plist"
  plutil -insert CFBundleVersion -string "$build" "$app_path/Contents/Info.plist"
  if [[ "$health_behavior" == "healthy" ]]; then
    printf '%s\n' '#!/bin/sh' \
      "/usr/bin/printf '%s' '{\"version\":\"$version\",\"build\":\"$build\"}' > '$health'" \
      "/bin/chmod 600 '$health'" > "$app_path/Contents/MacOS/Fixture"
  else
    printf '%s\n' '#!/bin/sh' '/bin/exit 0' > "$app_path/Contents/MacOS/Fixture"
  fi
  chmod 755 "$app_path/Contents/MacOS/Fixture"
}

mkdir -p "$(dirname "$installed")" "$(dirname "$staged")" "$(dirname "$backup")"
make_fixture_app "$installed" 1.0 1 healthy
make_fixture_app "$staged" 2.0 2 healthy
/bin/sleep 0.2 &
parent_pid=$!
"$helper" --switch \
  --installed "$installed" --staged "$staged" --backup "$backup" \
  --health "$health" --receipt "$receipt" --pid "$parent_pid" \
  --version 2.0 --build 2 --timeout 5
[[ "$(plutil -extract CFBundleShortVersionString raw "$installed/Contents/Info.plist")" == 2.0 ]]
[[ "$(jq -r .status "$receipt")" == healthy ]]
[[ "$(plutil -extract CFBundleShortVersionString raw "$backup/Contents/Info.plist")" == 1.0 ]]

rm -f "$health"
make_fixture_app "$staged" 3.0 3 broken
/bin/sleep 0.2 &
parent_pid=$!
if "$helper" --switch \
  --installed "$installed" --staged "$staged" --backup "$backup" \
  --health "$health" --receipt "$receipt" --pid "$parent_pid" \
  --version 3.0 --build 3 --timeout 1; then
  printf '%s\n' 'broken update unexpectedly passed its health check' >&2
  exit 1
fi
[[ "$(plutil -extract CFBundleShortVersionString raw "$installed/Contents/Info.plist")" == 2.0 ]]
[[ "$(jq -r .status "$receipt")" == rolledBack ]]
[[ "$(jq -r .version "$health")" == 2.0 ]]

printf '%s\n' 'Kaname update helper switch and automatic rollback passed.'
