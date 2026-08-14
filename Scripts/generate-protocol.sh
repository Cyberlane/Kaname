#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift_protobuf_root="$repo_root/.build/checkouts/swift-protobuf"
swift_protobuf_scratch="$repo_root/.build/swift-protobuf-tools"
mode="${1:-generate}"

if [[ "$mode" != "generate" && "$mode" != "check" ]]; then
  echo "usage: $0 [generate|check]" >&2
  exit 64
fi

cd "$repo_root"
if [[ ! -d "$swift_protobuf_root" ]]; then
  swift package resolve
  if [[ ! -d "$swift_protobuf_root" ]]; then
    echo "SwiftProtobuf checkout is unavailable after resolution" >&2
    exit 1
  fi
fi

protoc=""
plugin=""
for candidate in "$swift_protobuf_scratch"/*/release/protoc; do
  if [[ -x "$candidate" ]]; then
    protoc="$candidate"
    break
  fi
done
for candidate in "$swift_protobuf_scratch"/*/release/protoc-gen-swift; do
  if [[ -x "$candidate" ]]; then
    plugin="$candidate"
    break
  fi
done

if [[ -z "$protoc" || -z "$plugin" ]]; then
  swift build --package-path "$swift_protobuf_root" --scratch-path "$swift_protobuf_scratch" -c release --product protoc
  swift build --package-path "$swift_protobuf_root" --scratch-path "$swift_protobuf_scratch" -c release --product protoc-gen-swift
  tool_bin="$(swift build --package-path "$swift_protobuf_root" --scratch-path "$swift_protobuf_scratch" -c release --show-bin-path)"
  protoc="$tool_bin/protoc"
  plugin="$tool_bin/protoc-gen-swift"
fi

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
  kaname/v1/workflow.proto
  kaname/v1/workflow_runtime.proto
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

generated_swift_count="$(find "$temporary/swift" -type f -name '*.pb.swift' | wc -l | tr -d ' ')"
if [[ "$generated_swift_count" != "${#proto_inputs[@]}" ]]; then
  echo "expected ${#proto_inputs[@]} generated Swift bindings, found $generated_swift_count" >&2
  exit 1
fi

if [[ "$mode" == "check" ]]; then
  cmp "$repo_root/Schema/kaname-v1.desc" "$temporary/kaname-v1.desc"
  python3 "$repo_root/Scripts/check-schema-compatibility.py"
  if git ls-files --error-unmatch 'Sources/KanameProtocol/*.pb.swift' >/dev/null 2>&1; then
    echo "generated Swift protobuf sources must not be tracked" >&2
    exit 1
  fi
  exit 0
fi

cp "$temporary/kaname-v1.desc" "$repo_root/Schema/kaname-v1.desc"
python3 "$repo_root/Scripts/check-schema-compatibility.py" --write-baseline
python3 "$repo_root/Scripts/check-schema-compatibility.py"
