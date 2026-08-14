#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "usage: $0 <swift-product> <receipt-path> <qualifier-arguments...>" >&2
    exit 64
fi

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
product="$1"
receipt="$2"
shift 2

cargo build --locked --offline \
    --manifest-path "$project_dir/Rust/KanameCore/Cargo.toml" \
    --bin kaname-local-core
swift build --package-path "$project_dir" --product "$product"
"$project_dir/.build/debug/$product" \
    --core "$project_dir/Rust/KanameCore/target/debug/kaname-local-core" \
    "$@" > "$receipt"
