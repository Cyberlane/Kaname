#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d "${TMPDIR:-/tmp}/kaname-schema-compatibility.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT

cp -R "$repo_root/proto" "$temporary/proto"
cp "$repo_root/Schema/compatibility-baseline.json" "$temporary/baseline.json"

python3 "$repo_root/Scripts/check-schema-compatibility.py" \
  --proto-root "$temporary/proto/kaname/v1" \
  --baseline "$temporary/baseline.json"

python3 - "$temporary/proto/kaname/v1/event.proto" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
content = path.read_text()
path.write_text(content.replace("string kind = 7;", "string kind = 70;", 1))
PY

if python3 "$repo_root/Scripts/check-schema-compatibility.py" \
  --proto-root "$temporary/proto/kaname/v1" \
  --baseline "$temporary/baseline.json"; then
  echo "compatibility checker accepted a breaking field-number change" >&2
  exit 1
fi
