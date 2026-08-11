#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: $0 <new-stable.app> <installed-stable.app>" >&2
    exit 64
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
cd "$repo_root"
swift run KanameDogfoodUpdatePublisher "$1" "$2"
