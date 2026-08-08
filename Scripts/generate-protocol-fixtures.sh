#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-generate}"

if [[ "$mode" != "generate" && "$mode" != "check" ]]; then
  echo "usage: $0 [generate|check]" >&2
  exit 64
fi

temporary="$(mktemp -d "${TMPDIR:-/tmp}/kaname-fixtures.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT

cd "$repo_root"
swift run KanameProtocolFixtureTool > "$temporary/swift-event-envelope.bin"
cargo run --quiet --manifest-path Rust/KanameCore/Cargo.toml --bin kaname-protocol-fixture-tool > "$temporary/rust-event-envelope.bin"

python3 - "$temporary" "$repo_root" <<'PY'
import hashlib
import json
import pathlib
import sys

generated, root = map(pathlib.Path, sys.argv[1:])
entries = []
for path in sorted(generated.glob("*.bin")):
    data = path.read_bytes()
    entries.append({
        "fixture": path.name,
        "schemaVersion": "v1",
        "sha256": hashlib.sha256(data).hexdigest(),
        "classification": "unknown-outer-event-preservation",
        "containsPrivateData": False,
    })
(generated / "corpus-manifest.json").write_text(json.dumps({"fixtures": entries}, indent=2, sort_keys=True) + "\n")
PY

destination="$repo_root/Fixtures/wire/v1"
if [[ "$mode" == "check" ]]; then
  for file in "$temporary"/*.bin "$temporary"/corpus-manifest.json; do
    cmp "$destination/$(basename "$file")" "$file"
  done
  exit 0
fi

mkdir -p "$destination"
cp "$temporary"/*.bin "$destination/"
cp "$temporary/corpus-manifest.json" "$destination/"
