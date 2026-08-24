#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_dir/.." && pwd -P)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/kaname-link-schema.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT

cp -R "$repository_root/proto-link/kaname/link/v1" "$temporary_root/v1"
cp "$repository_root/Schema/kaname-link-compatibility-baseline.json" "$temporary_root/baseline.json"

python3 "$repository_root/Scripts/check-schema-compatibility.py" \
  --proto-root "$temporary_root/v1" \
  --baseline "$temporary_root/baseline.json"

python3 - "$temporary_root/v1/link.proto" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
path.write_text(
    source.replace("string message_id = 2;", "string message_id = 20;", 1),
    encoding="utf-8",
)
PY

if python3 "$repository_root/Scripts/check-schema-compatibility.py" \
  --proto-root "$temporary_root/v1" \
  --baseline "$temporary_root/baseline.json"; then
  echo "Link compatibility checker accepted a breaking field-number change" >&2
  exit 1
fi

echo "Kaname Link compatibility checker rejected the breaking fixture as expected."
