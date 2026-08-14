# Kaname Workflow v1 Schema Registry

This directory is the portable authoring contract for workflow v2. Every JSON Schema uses Draft 2020-12, has a stable HTTPS `$id`, resolves only against files registered from this directory, and fails closed on unknown node types or node type versions.

`registry.json` is the machine-readable inventory. Its node records deliberately say `executable: false`: WFP-001B defines what can be authored and checked but does not claim that the v2 runtime can execute any node. Later runtime tickets change availability only after their execution evidence passes.

Built-in node schemas combine the common node envelope with exactly one closed configuration schema. Portable documents contain no credentials, account bindings, secret values, live authority grants, run history, or workflow storage contents.

Run the registry qualification with:

```sh
cargo test --locked --offline --manifest-path Rust/KanameCore/Cargo.toml --test workflow_schema_registry_tests
```
