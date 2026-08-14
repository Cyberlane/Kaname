#!/usr/bin/env bash

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
rust_manifest="$project_dir/Rust/KanameCore/Cargo.toml"
core="$project_dir/Rust/KanameCore/target/debug/kaname-local-core"
qualification="$project_dir/.build/debug/KanameWorkflowSchemaQualification"
receipt="$project_dir/.build/workflow-v2-schema-qualification.json"

cd "$project_dir"
cargo build --locked --offline --manifest-path "$rust_manifest" --bin kaname-local-core
swift build --product KanameWorkflowSchemaQualification
"$qualification" \
    --core "$core" \
    --corpus "$project_dir/Fixtures/workflow-v2/scenarios.json" \
    > "$receipt"

jq -e '
    .validator == "jsonschema-rs 0.49.9" and
    .draft == "2020-12" and
    .corpus_scenario_count == 25 and
    .valid_call_passed and
    .invalid_call_passed and
    .deterministic_errors_passed and
    .diagnostics_masked and
    .core_binary_bytes > 0
' "$receipt" >/dev/null

cat "$receipt"
