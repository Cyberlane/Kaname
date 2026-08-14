# Workflow Canonical JSON Decision

Kaname workflow identity uses the JSON Canonicalization Scheme defined by RFC 8785. The Rust core is the sole canonicalization authority; Swift verifies returned canonical bytes and SHA-256 digests but does not implement a second canonicalizer.

The canonicalizer:

- sorts object properties by UTF-16 code units;
- uses ECMAScript-compatible number serialization;
- preserves Unicode text without normalization;
- rejects duplicate keys, lone surrogates, non-finite values, trailing data, empty input, and integers outside the interoperable range from `-9007199254740991` through `9007199254740991`;
- accepts no more than 512 KiB per value;
- returns canonical bytes as hexadecimal plus a `sha256:` digest without echoing invalid input.

The shared vectors cover the semantic graph, editor layout, schema lock, dependency lock, configuration contract, and compiled artifact. Swift independently hashes the exact expected UTF-8 bytes and proves the Rust result remains identical across separate core process invocations.

`DesktopWorkflowCanonicalJSON` remains unchanged in this ticket. It is a legacy sorted-key serializer, not the workflow-v2 identity contract. Production transport moves from this bounded qualification process to the Protobuf/XPC contract in WFP-001D.

Run `Scripts/qualify-workflow-toolchain.sh canonical` to reproduce the cross-language receipt.

References:

- [RFC 8785: JSON Canonicalization Scheme](https://www.rfc-editor.org/rfc/rfc8785.html)
- [serde_json_canonicalizer 0.3.2](https://docs.rs/serde_json_canonicalizer/0.3.2/serde_json_canonicalizer/)
