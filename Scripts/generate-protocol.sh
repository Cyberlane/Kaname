#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift_protobuf_root="$repo_root/.build/checkouts/swift-protobuf"
mode="${1:-generate}"

if [[ "$mode" != "generate" && "$mode" != "check" ]]; then
  echo "usage: $0 [generate|check]" >&2
  exit 64
fi

cd "$repo_root"
swift package resolve

if [[ ! -d "$swift_protobuf_root" ]]; then
  echo "SwiftProtobuf checkout is unavailable after resolution" >&2
  exit 1
fi

swift build --package-path "$swift_protobuf_root" -c release --product protoc
swift build --package-path "$swift_protobuf_root" -c release --product protoc-gen-swift
tool_bin="$(swift build --package-path "$swift_protobuf_root" -c release --show-bin-path)"
protoc="$tool_bin/protoc"
plugin="$tool_bin/protoc-gen-swift"

expected_version="libprotoc 35.1"
actual_version="$($protoc --version)"
if [[ "$actual_version" != "$expected_version" ]]; then
  echo "unexpected protoc version: $actual_version" >&2
  exit 1
fi

temporary="$(mktemp -d "${TMPDIR:-/tmp}/kaname-schema.XXXXXX")"
trap 'rm -rf "$temporary"' EXIT
mkdir -p "$temporary/swift"

proto_inputs=(
  kaname/v1/common.proto
  kaname/v1/command.proto
  kaname/v1/event.proto
  kaname/v1/replay.proto
  kaname/v1/approval.proto
  kaname/v1/queue.proto
  kaname/v1/notification.proto
  kaname/v1/sync.proto
)

"$protoc" \
  --plugin="protoc-gen-swift=$plugin" \
  --proto_path="$repo_root/proto" \
  --descriptor_set_out="$temporary/kaname-v1.desc" \
  --include_imports \
  --swift_opt=FileNaming=PathToUnderscores \
  --swift_opt=Visibility=Public \
  --swift_out="$temporary/swift" \
  "${proto_inputs[@]}"

if [[ "$mode" == "check" ]]; then
  diff -ru "$repo_root/Sources/KanameProtocol" "$temporary/swift"
  cmp "$repo_root/Schema/kaname-v1.desc" "$temporary/kaname-v1.desc"
  python3 "$repo_root/Scripts/check-schema-compatibility.py"
  exit 0
fi

rm -rf "$repo_root/Sources/KanameProtocol"
mkdir -p "$repo_root/Sources/KanameProtocol"
cp -R "$temporary/swift/." "$repo_root/Sources/KanameProtocol/"
cp "$temporary/kaname-v1.desc" "$repo_root/Schema/kaname-v1.desc"
python3 "$repo_root/Scripts/check-schema-compatibility.py" --write-baseline
python3 "$repo_root/Scripts/check-schema-compatibility.py"
