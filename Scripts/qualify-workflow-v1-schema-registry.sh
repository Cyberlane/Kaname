#!/usr/bin/env bash

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
schema_dir="$project_dir/Schema/Workflow/v1"
registry="$schema_dir/registry.json"
node_goldens="$project_dir/Fixtures/workflow-v2/schema-v1-node-goldens.json"
common_goldens="$project_dir/Fixtures/workflow-v2/schema-v1-common-goldens.json"
receipt="$project_dir/.build/workflow-v1-schema-registry.json"

find "$schema_dir" -type f -name '*.json' -print0 | xargs -0 -n1 jq -e . >/dev/null
cargo test \
    --locked \
    --offline \
    --manifest-path "$project_dir/Rust/KanameCore/Cargo.toml" \
    --test workflow_schema_registry_tests

schema_count="$(find "$schema_dir" -type f -name '*.schema.json' | wc -l | tr -d ' ')"
node_type_count="$(jq '.nodeTypes | length' "$registry")"
node_golden_count="$(jq 'keys | length' "$node_goldens")"
common_golden_count="$(jq 'length' "$common_goldens")"
executable_count="$(jq '[.nodeTypes[] | select(.executable)] | length' "$registry")"

jq -n \
    --argjson schema_count "$schema_count" \
    --argjson node_type_count "$node_type_count" \
    --argjson node_golden_count "$node_golden_count" \
    --argjson common_golden_count "$common_golden_count" \
    --argjson executable_count "$executable_count" \
    '{
        registry_version: 1,
        draft: "2020-12",
        schema_count: $schema_count,
        node_type_count: $node_type_count,
        node_golden_count: $node_golden_count,
        common_golden_count: $common_golden_count,
        executable_node_count: $executable_count,
        offline_resolution_passed: true,
        unknown_type_version_rejected: true,
        closed_object_goldens_passed: true
    }' > "$receipt"

jq -e '
    .schema_count == 49 and
    .node_type_count == 25 and
    .node_golden_count == 25 and
    .common_golden_count == 17 and
    .executable_node_count == 0 and
    .offline_resolution_passed and
    .unknown_type_version_rejected and
    .closed_object_goldens_passed
' "$receipt" >/dev/null

cat "$receipt"
