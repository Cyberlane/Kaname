#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
repository_root="$(cd "$script_dir/.." && pwd -P)"
swift_protobuf_root="$repository_root/.build/checkouts/swift-protobuf"
swift_protobuf_scratch="$repository_root/.build/swift-protobuf-tools"
mode="${1:-generate}"

if [[ "$mode" != "generate" && "$mode" != "check" ]]; then
  echo "usage: $0 [generate|check]" >&2
  exit 64
fi

cd "$repository_root"
if [[ ! -d "$swift_protobuf_root" ]]; then
  swift package resolve
fi
[[ -d "$swift_protobuf_root" ]] || {
  echo "SwiftProtobuf checkout is unavailable after resolution" >&2
  exit 1
}

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
  swift build --package-path "$swift_protobuf_root" --scratch-path "$swift_protobuf_scratch" \
    -c release --product protoc
  swift build --package-path "$swift_protobuf_root" --scratch-path "$swift_protobuf_scratch" \
    -c release --product protoc-gen-swift
  tool_bin="$(swift build --package-path "$swift_protobuf_root" \
    --scratch-path "$swift_protobuf_scratch" -c release --show-bin-path)"
  protoc="$tool_bin/protoc"
  plugin="$tool_bin/protoc-gen-swift"
fi

expected_version="libprotoc 35.1"
actual_version="$($protoc --version)"
if [[ "$actual_version" != "$expected_version" ]]; then
  echo "unexpected protoc version: $actual_version" >&2
  exit 1
fi

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/kaname-link-protocol.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT
mkdir -p "$temporary_root/swift"

"$protoc" \
  --plugin="protoc-gen-swift=$plugin" \
  --proto_path="$repository_root/proto-link" \
  --descriptor_set_out="$temporary_root/kaname-link-v1.desc" \
  --include_imports \
  --swift_opt=FileNaming=PathToUnderscores \
  --swift_opt=Visibility=Public \
  --swift_out="$temporary_root/swift" \
  kaname/link/v1/link.proto

generated_count="$(find "$temporary_root/swift" -type f -name '*.pb.swift' | wc -l | tr -d ' ')"
[[ "$generated_count" == "1" ]] || {
  echo "expected one generated Link Swift binding, found $generated_count" >&2
  exit 1
}

if [[ "$mode" == "check" ]]; then
  cmp "$repository_root/Schema/kaname-link-v1.desc" "$temporary_root/kaname-link-v1.desc"
  "$script_dir/check-link-schema.sh"
else
  cp "$temporary_root/kaname-link-v1.desc" "$repository_root/Schema/kaname-link-v1.desc"
  "$script_dir/check-link-schema.sh"
fi
