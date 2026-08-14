# Workflow Schema Validator Decision

Status: accepted for WFP-001A on 2026-08-14.

## Decision

Kaname workflow v2 uses the Rust [`jsonschema`](https://docs.rs/jsonschema/0.49.9/jsonschema/) crate, locked to `0.49.9`, as its JSON Schema Draft 2020-12 validation engine.

The dependency is compiled with default features disabled. Kaname therefore does not include HTTP, file-reference, or TLS retrieval in the checker. Workflow schemas may use local `$defs`, `$ref`, recursion, and Draft 2020-12 evaluation features, but an unresolved external reference fails closed. Formats are explicitly enabled, and unknown formats fail until registered. Diagnostics are sorted by stable JSON Pointer locations and use the library's masked display so instance values are not copied into error text.

The crate is MIT-licensed, supports Rust 1.85 or newer, builds on the repository's macOS toolchain, and the public [Bowtie Draft 2020-12 report](https://bowtie.report/#/dialects/draft2020-12) currently lists the Rust implementation with zero official-suite issues. Its documentation exposes Draft 2020-12 selection, meta-schema validation, `unevaluatedProperties`, recursive references, custom formats, complete error iteration, instance/schema locations, and masked diagnostics.

## Qualification result

`Scripts/qualify-workflow-toolchain.sh schema` performs a locked offline Cargo build, builds the Swift qualification client, and sends every WFP-000 acceptance scenario through bounded JSON stdin/stdout into the Rust checker. It also sends an invalid instance twice and requires the structured diagnostic reports to be identical and masked.

The final local debug qualification passed all 25 scenarios. The deliberate invalid call was rejected. Median one-process-per-call latency was about 73 ms and p95 about 74 ms. The unoptimized `kaname-local-core` binary was 21,834,928 bytes; the optimized release binary was 8,885,440 bytes. These are spike baselines; the production signed-XPC service will keep a stable boundary and WFP-001D will replace this temporary JSON qualification envelope with versioned Protobuf.

## Rejected alternatives

- The existing Swift `DesktopWorkflowJSONSchema` validator remains a deliberately partial subset. Extending it would create a second semantic implementation and would not satisfy the complete Draft 2020-12 requirement.
- `boon` 0.6.1 is Apache-2.0, passes the official validation suite, and remains the fallback if `jsonschema` regresses. It was not selected because `jsonschema` provides the error-location, format, masked-diagnostic, and structured-output APIs needed by the inspector with less adapter work.
- JavaScript/Ajv, Python `jsonschema`, and a Java validator would add another runtime and distribution boundary to a native Swift/Rust application.
- A hosted validation service would violate offline operation and unnecessarily expose workflow definitions.

## Constraints carried forward

- The Rust checker is the sole workflow v2 validation authority.
- Unknown contract majors and malformed or over-512 KiB requests fail closed.
- External schema retrieval remains disabled. Dependencies must be registered and bundled explicitly in a later schema-lock ticket.
- Diagnostics contain locations and masked explanations, never input values.
- WFP-001A does not install the XPC service, grant connector authority, persist workflows, or execute a workflow.
