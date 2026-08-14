#!/usr/bin/env bash

set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
kind="${1:-}"

case "$kind" in
    schema)
        product="KanameWorkflowSchemaQualification"
        receipt="$project_dir/.build/workflow-v2-schema-qualification.json"
        qualifier_arguments=(--corpus "$project_dir/Fixtures/workflow-v2/scenarios.json")
        ;;
    canonical)
        product="KanameWorkflowCanonicalQualification"
        receipt="$project_dir/.build/workflow-canonical-digests.json"
        qualifier_arguments=(--vectors "$project_dir/Fixtures/workflow-v2/canonical-vectors.json")
        ;;
    *)
        echo "usage: $0 <schema|canonical>" >&2
        exit 64
        ;;
esac

cd "$project_dir"
./Scripts/run-workflow-toolchain-qualification.sh \
    "$product" \
    "$receipt" \
    "${qualifier_arguments[@]}"

case "$kind" in
    schema)
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
        ;;
    canonical)
        jq -e '
            .contract == "RFC 8785" and
            .vector_count == 6 and
            .rejected_count == 6 and
            (.digest_roles | length) == 6 and
            .canonical_bytes_match and
            .rust_digests_match and
            .swift_digests_match and
            .restart_match and
            .invalid_inputs_rejected and
            .legacy_digest_path_unchanged
        ' "$receipt" >/dev/null
        ;;
esac

cat "$receipt"
