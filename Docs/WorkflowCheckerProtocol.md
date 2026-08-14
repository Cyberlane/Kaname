# Workflow Checker Protocol

Kaname’s workflow checker boundary is defined by `proto/kaname/v1/workflow.proto` and generated into both the Swift `KanameProtocol` module and the Rust core. Swift Package Manager uses the exact-pinned `SwiftProtobufPlugin` dependency and `proto/swift-protobuf-config.json` to generate Swift bindings at build time; generated Swift sources are deliberately not versioned. The first contract version provides distinct Validate and Compile requests and responses, structured masked diagnostics, source spans, and all six workflow artifact digests.

Ingress rules are fail-closed:

- schema major must be `1`;
- encoded requests must be between 1 byte and 2 MiB;
- every JSON document must be between 1 byte and 512 KiB;
- request IDs are 1–128 ASCII letters, numbers, `-`, `_`, `.`, or `:`;
- requested diagnostics must be between 1 and 256;
- malformed Protobuf and unsupported major versions are rejected before checker work.

Source positions are zero-based and measure UTF-8 bytes, lines, and columns. Diagnostics contain stable codes, severity, masked summaries, JSON Pointers, and optional spans; raw values, private context, and stack traces are reserved against accidental reuse.

Unknown Protobuf fields do not grant authority. Swift preserves them during round trips and Rust safely ignores them while continuing to enforce all known authority and size fields. Unknown enum values remain representable by the generated runtimes and must not be interpreted as success.

`WorkflowProtocolClientPreflight` lets Swift callers reject malformed request IDs before serialization. It is convenience only; the Rust decoder remains the authoritative ingress check and repeats the validation without trusting the caller.

`Scripts/generate-protocol.sh check` independently invokes the pinned compiler, requires one generated Swift binding per canonical Proto input, proves the checked-in descriptor is current, checks every previously recorded field number, type, message, enum, and enum value against `Schema/compatibility-baseline.json`, and rejects accidentally tracked Swift bindings. Normal `swift build` and `swift test` commands compile the `KanameProtocol` target through the pinned SwiftPM plugin.

The same versioned workflow contract now carries path-free library queries for Portfolio, revision history, exact revision content, and structural comparison, plus a generation-checked activation-alias command. The signed local service chooses the channel-isolated Application Support root; neither SwiftUI nor the request wire may supply a database or filesystem path. Publication and activation remain separate operations, and the presentation contract reports execution support independently from draft, published, active, and disabled state.

Frozen legacy imports use that same path-free boundary. Swift opens a user-selected copied `workspace.json` as a regular, single-link, non-symlink file, verifies a stable bounded read, migrates it in memory, and sends only sanitized v2 workflow/layout documents plus masked comparison reports. The source path, source bytes, legacy account identifiers, credentials, and permission bindings are not wire fields. Rust canonicalizes and freezes the comparison bundle, creates `unsupported` read-only drafts, records one digest-keyed receipt, and verifies the exact stored evidence on an idempotent repeat. Imported snapshots cannot be edited, published, activated, or executed at this stage.
