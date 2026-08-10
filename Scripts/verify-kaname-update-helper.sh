#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
helper="$repo_root/.build/release/KanameUpdateHelper"
swift build -c release --product KanameUpdateHelper --package-path "$repo_root"

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/kaname-update-helper.XXXXXX")"
trap 'rm -rf "$fixture_root"' EXIT
installed="$fixture_root/Installed/Kaname.app"
staged="$fixture_root/Updates/Staged/Kaname.app"
backup="$fixture_root/Updates/Previous/Kaname.app"
health="$fixture_root/ui-health.json"
receipt="$fixture_root/Updates/receipt.json"
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
  if [[ "$health_behavior" == "healthy" || "$health_behavior" == "wrong-nonce" ]]; then
    printf '%s\n' '#!/bin/sh' \
      "health_path='$health'" \
      'nonce=""' \
      'digest=""' \
      'while [ "$#" -gt 0 ]; do' \
      '  case "$1" in' \
      '    --kaname-update-nonce) nonce="$2"; shift 2 ;;' \
      '    --kaname-update-bundle-digest) digest="$2"; shift 2 ;;' \
      '    *) shift ;;' \
      '  esac' \
      'done' \
      'app_root="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"' \
      'version="$(plutil -extract CFBundleShortVersionString raw "$app_root/Contents/Info.plist")"' \
      'build="$(plutil -extract CFBundleVersion raw "$app_root/Contents/Info.plist")"' \
      'healthy_at="$(/usr/bin/python3 -c '\''import time; print(int(time.time() * 1000))'\'')"' \
      '/usr/bin/printf '\''{"channel":"stable","version":"%s","build":"%s","processID":%s,"healthyAtUnixMillis":%s,"workspaceSchemaVersion":13,"healthNonce":"%s","bundleDigest":"%s"}'\'' "$version" "$build" "$$" "$healthy_at" "$nonce" "$digest" > "$health_path"' \
      '/bin/chmod 600 "$health_path"' \
      '/bin/sleep 2' > "$app_path/Contents/MacOS/Fixture"
    if [[ "$health_behavior" == "wrong-nonce" ]]; then
      sed -i '' '/^done$/a\
nonce="unexpected-nonce"' "$app_path/Contents/MacOS/Fixture"
    fi
  else
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$app_path/Contents/MacOS/Fixture"
  fi
  chmod 755 "$app_path/Contents/MacOS/Fixture"
  codesign --force --sign - "$app_path"
}

bundle_digest() {
  local app_path="$1"
  (
    cd "$app_path"
    while IFS= read -r relative; do
      printf 'file\0%s\0' "$relative"
      /bin/cat "$relative"
    done < <(find . -type f -print | sed 's#^\./##' | LC_ALL=C sort)
  ) | shasum -a 256 | awk '{print $1}'
}

signer_digest() {
  local app_path="$1"
  local identity
  identity="$(codesign -d -r- "$app_path" 2>&1 | sed -n '/designated =>/p')"
  printf '%s' "$identity" | shasum -a 256 | awk '{print $1}'
}

mkdir -p "$(dirname "$installed")" "$(dirname "$staged")" "$(dirname "$backup")"
make_fixture_app "$installed" 1.0 1 healthy
make_fixture_app "$staged" 2.0 2 healthy
rollback_bundle_digest="$(bundle_digest "$installed")"
rollback_signer_digest="$(signer_digest "$installed")"
printf '%s' "{\"status\":\"switching\",\"version\":\"2.0\",\"build\":\"2\",\"bundleDigest\":\"fixture-bundle-digest\",\"signerDigest\":\"fixture-signer-digest\",\"rollbackBundleDigest\":\"$rollback_bundle_digest\",\"rollbackSignerDigest\":\"$rollback_signer_digest\",\"rollbackVersion\":\"1.0\",\"rollbackBuild\":\"1\",\"releaseNotes\":\"Fixture release notes\",\"detail\":\"Switching\",\"updatedAtUnixMillis\":1}" > "$receipt"
/bin/sleep 0.2 &
parent_pid=$!
"$helper" --switch \
  --installed "$installed" --staged "$staged" --backup "$backup" \
  --health "$health" --receipt "$receipt" --pid "$parent_pid" \
  --version 2.0 --build 2 \
  --bundle-digest "$(bundle_digest "$staged")" \
  --signer-digest "$(signer_digest "$staged")" \
  --health-nonce fixture-switch-2 \
  --channel stable --workspace-schema 13 \
  --rollback-version 1.0 --rollback-build 1 \
  --rollback-bundle-digest "$rollback_bundle_digest" \
  --rollback-signer-digest "$rollback_signer_digest" \
  --timeout 5
[[ "$(plutil -extract CFBundleShortVersionString raw "$installed/Contents/Info.plist")" == 2.0 ]]
[[ "$(jq -r .status "$receipt")" == healthy ]]
[[ "$(jq -r .version "$receipt")" == 2.0 ]]
[[ "$(jq -r .build "$receipt")" == 2 ]]
[[ "$(jq -r .releaseNotes "$receipt")" == 'Fixture release notes' ]]
[[ "$(plutil -extract CFBundleShortVersionString raw "$backup/Contents/Info.plist")" == 1.0 ]]

current_bundle_digest="$(bundle_digest "$installed")"
current_signer_digest="$(signer_digest "$installed")"
collision="$fixture_root/Updates/Replaced/$current_bundle_digest.app"
mkdir -p "$collision"
printf '%s' 'unowned collision' > "$collision/do-not-delete.txt"
/bin/sleep 0.2 &
parent_pid=$!
if "$helper" --rollback \
  --installed "$installed" --backup "$backup" \
  --health "$health" --receipt "$receipt" --pid "$parent_pid" \
  --version 2.0 --build 2 \
  --bundle-digest "$current_bundle_digest" \
  --signer-digest "$current_signer_digest" \
  --rollback-version 1.0 --rollback-build 1 \
  --rollback-bundle-digest "$rollback_bundle_digest" \
  --rollback-signer-digest "$rollback_signer_digest" \
  --channel stable --workspace-schema 13 --timeout 5; then
  printf '%s\n' 'pre-existing private rollback path unexpectedly passed helper validation' >&2
  exit 1
fi
[[ "$(cat "$collision/do-not-delete.txt")" == 'unowned collision' ]]
[[ "$(plutil -extract CFBundleShortVersionString raw "$installed/Contents/Info.plist")" == 2.0 ]]
rm -r "$collision"

if "$helper" --rollback \
  --installed "$backup" --backup "$backup" \
  --health "$health" --receipt "$receipt" --pid "$$" \
  --version 2.0 --build 2 \
  --bundle-digest "$current_bundle_digest" \
  --signer-digest "$current_signer_digest" \
  --rollback-version 1.0 --rollback-build 1 \
  --rollback-bundle-digest "$rollback_bundle_digest" \
  --rollback-signer-digest "$rollback_signer_digest" \
  --channel stable --workspace-schema 13 --timeout 0.1; then
  printf '%s\n' 'colliding rollback paths unexpectedly passed helper validation' >&2
  exit 1
fi
[[ -d "$backup" ]]

expected_rollback_digest="$(bundle_digest "$backup")"
expected_rollback_signer="$(signer_digest "$backup")"
printf '\n# tampered retained rollback\n' >> "$backup/Contents/MacOS/Fixture"
/bin/sleep 0.2 &
parent_pid=$!
if "$helper" --rollback \
  --installed "$installed" --backup "$backup" \
  --health "$health" --receipt "$receipt" --pid "$parent_pid" \
  --version 2.0 --build 2 \
  --bundle-digest "$current_bundle_digest" \
  --signer-digest "$current_signer_digest" \
  --rollback-version 1.0 --rollback-build 1 \
  --rollback-bundle-digest "$expected_rollback_digest" \
  --rollback-signer-digest "$expected_rollback_signer" \
  --channel stable --workspace-schema 13 \
  --timeout 5; then
  printf '%s\n' 'tampered rollback unexpectedly passed helper trust checks' >&2
  exit 1
fi
[[ "$(plutil -extract CFBundleShortVersionString raw "$installed/Contents/Info.plist")" == 2.0 ]]

rm -r "$backup"
make_fixture_app "$backup" 1.0 1 broken
failed_target_digest="$(bundle_digest "$backup")"
failed_target_signer="$(signer_digest "$backup")"
/bin/sleep 0.2 &
parent_pid=$!
if "$helper" --rollback \
  --installed "$installed" --backup "$backup" \
  --health "$health" --receipt "$receipt" --pid "$parent_pid" \
  --version 2.0 --build 2 \
  --bundle-digest "$current_bundle_digest" \
  --signer-digest "$current_signer_digest" \
  --rollback-version 1.0 --rollback-build 1 \
  --rollback-bundle-digest "$failed_target_digest" \
  --rollback-signer-digest "$failed_target_signer" \
  --channel stable --workspace-schema 13 --timeout 1; then
  printf '%s\n' 'unhealthy manual rollback unexpectedly passed' >&2
  exit 1
fi
[[ "$(plutil -extract CFBundleShortVersionString raw "$installed/Contents/Info.plist")" == 2.0 ]]
[[ "$(plutil -extract CFBundleShortVersionString raw "$backup/Contents/Info.plist")" == 1.0 ]]
[[ "$(jq -r .status "$receipt")" == healthy ]]

rm -r "$backup"
make_fixture_app "$backup" 1.0 1 healthy

rm -f "$health"
make_fixture_app "$staged" 3.0 3 broken
rollback_bundle_digest="$(bundle_digest "$installed")"
rollback_signer_digest="$(signer_digest "$installed")"
/bin/sleep 0.2 &
parent_pid=$!
if "$helper" --switch \
  --installed "$installed" --staged "$staged" --backup "$backup" \
  --health "$health" --receipt "$receipt" --pid "$parent_pid" \
  --version 3.0 --build 3 \
  --bundle-digest "$(bundle_digest "$staged")" \
  --signer-digest "$(signer_digest "$staged")" \
  --health-nonce fixture-switch-3 \
  --channel stable --workspace-schema 13 \
  --rollback-version 2.0 --rollback-build 2 \
  --rollback-bundle-digest "$rollback_bundle_digest" \
  --rollback-signer-digest "$rollback_signer_digest" \
  --timeout 1; then
  printf '%s\n' 'broken update unexpectedly passed its health check' >&2
  exit 1
fi
[[ "$(plutil -extract CFBundleShortVersionString raw "$installed/Contents/Info.plist")" == 2.0 ]]
[[ "$(jq -r .status "$receipt")" == rolledBack ]]
[[ "$(jq -r .version "$health")" == 2.0 ]]

rm -f "$health"
make_fixture_app "$staged" 3.5 35 wrong-nonce
rollback_bundle_digest="$(bundle_digest "$installed")"
rollback_signer_digest="$(signer_digest "$installed")"
/bin/sleep 0.2 &
parent_pid=$!
if "$helper" --switch \
  --installed "$installed" --staged "$staged" --backup "$backup" \
  --health "$health" --receipt "$receipt" --pid "$parent_pid" \
  --version 3.5 --build 35 \
  --bundle-digest "$(bundle_digest "$staged")" \
  --signer-digest "$(signer_digest "$staged")" \
  --health-nonce expected-nonce \
  --channel stable --workspace-schema 13 \
  --rollback-version 2.0 --rollback-build 2 \
  --rollback-bundle-digest "$rollback_bundle_digest" \
  --rollback-signer-digest "$rollback_signer_digest" \
  --timeout 1; then
  printf '%s\n' 'wrong health nonce unexpectedly passed the handshake' >&2
  exit 1
fi
[[ "$(plutil -extract CFBundleShortVersionString raw "$installed/Contents/Info.plist")" == 2.0 ]]
[[ "$(jq -r .status "$receipt")" == rolledBack ]]

make_fixture_app "$staged" 4.0 4 healthy
expected_bundle_digest="$(bundle_digest "$staged")"
expected_signer_digest="$(signer_digest "$staged")"
rollback_bundle_digest="$(bundle_digest "$installed")"
rollback_signer_digest="$(signer_digest "$installed")"
printf '\n# tampered after approval\n' >> "$staged/Contents/MacOS/Fixture"
/bin/sleep 0.2 &
parent_pid=$!
if "$helper" --switch \
  --installed "$installed" --staged "$staged" --backup "$backup" \
  --health "$health" --receipt "$receipt" --pid "$parent_pid" \
  --version 4.0 --build 4 \
  --bundle-digest "$expected_bundle_digest" \
  --signer-digest "$expected_signer_digest" \
  --health-nonce fixture-switch-4 \
  --channel stable --workspace-schema 13 \
  --rollback-version 2.0 --rollback-build 2 \
  --rollback-bundle-digest "$rollback_bundle_digest" \
  --rollback-signer-digest "$rollback_signer_digest" \
  --timeout 5; then
  printf '%s\n' 'tampered staged update unexpectedly passed helper trust checks' >&2
  exit 1
fi
[[ "$(plutil -extract CFBundleShortVersionString raw "$installed/Contents/Info.plist")" == 2.0 ]]
[[ -d "$staged" ]]

make_fixture_app "$backup" 1.0 1 healthy
rollback_bundle_digest="$(bundle_digest "$backup")"
rollback_signer_digest="$(signer_digest "$backup")"
current_bundle_digest="$(bundle_digest "$installed")"
current_signer_digest="$(signer_digest "$installed")"
/bin/sleep 0.2 &
parent_pid=$!
"$helper" --rollback \
  --installed "$installed" --backup "$backup" \
  --health "$health" --receipt "$receipt" --pid "$parent_pid" \
  --version 2.0 --build 2 \
  --bundle-digest "$current_bundle_digest" \
  --signer-digest "$current_signer_digest" \
  --rollback-version 1.0 --rollback-build 1 \
  --rollback-bundle-digest "$rollback_bundle_digest" \
  --rollback-signer-digest "$rollback_signer_digest" \
  --channel stable --workspace-schema 13 --timeout 5
[[ "$(plutil -extract CFBundleShortVersionString raw "$installed/Contents/Info.plist")" == 1.0 ]]
[[ -d "$fixture_root/Updates/Replaced/$current_bundle_digest.app" ]]
[[ ! -e "$fixture_root/Installed/Kaname Replaced.app" ]]
[[ "$(jq -r .status "$receipt")" == rolledBack ]]

printf '%s\n' 'Kaname update helper switch and automatic rollback passed.'
