#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_dir/.." && pwd -P)"

python3 "$script_dir/check-schema-compatibility.py" \
  --proto-root "$repository_root/proto-link/kaname/link/v1" \
  --baseline "$repository_root/Schema/kaname-link-compatibility-baseline.json"

if git -C "$repository_root" ls-files --error-unmatch \
  'Sources/KanameLinkProtocol/*.pb.swift' >/dev/null 2>&1; then
  echo "generated Kaname Link Swift protobuf sources must not be tracked" >&2
  exit 1
fi

echo "Kaname Link schema compatibility passed."
