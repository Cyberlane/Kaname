#!/usr/bin/env bash

set -euo pipefail

if [[ "$#" -ne 0 ]]; then
    echo "usage: $0" >&2
    echo "This drill accepts no backup destination, credentials, or remote configuration." >&2
    exit 64
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${KANAME_TASK_BUILD_DIR:-$repo_root/.build}"
case "$build_dir" in
    /*) ;;
    *) echo "KANAME_TASK_BUILD_DIR must be an absolute path." >&2; exit 64 ;;
esac

temporary_parent="${TMPDIR:-/tmp}"
[[ -d "$temporary_parent" ]] || { echo "Temporary parent does not exist: $temporary_parent" >&2; exit 1; }
drill_root="$(mktemp -d "$temporary_parent/kaname-backup-drill.XXXXXX")"
cleanup() {
    case "$(basename "$drill_root")" in
        kaname-backup-drill.*) rm -r -- "$drill_root" ;;
        *) echo "Refusing to remove unexpected drill root: $drill_root" >&2; return 1 ;;
    esac
}
trap cleanup EXIT

cd "$repo_root"
swift test \
    --scratch-path "$build_dir" \
    --filter '__KanameSyntheticBackupDrillBuildOnly__'
TMPDIR="$drill_root" swift test \
    --scratch-path "$build_dir" \
    --skip-build \
    --filter 'Desktop(AutomaticBackup|RecoveryFoundation)Tests'

echo "Synthetic backup drill passed without a configured or real destination."
