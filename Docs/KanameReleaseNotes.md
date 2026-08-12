# Kaname 0.21.0 build 41

- Add a generic workflow workspace under Email with calm Work, Definitions, and Simple rules views while leaving ordinary email threads uncluttered.
- Model correction-heavy work as durable work items, conversation bindings, episodes, frozen runs, ordered step attempts, and provider-run links instead of treating one email thread as one run.
- Compile bounded, digest-addressed context snapshots from active facts and source references, with superseded material retained as evidence but explicitly excluded from current truth.
- Install immutable JSON workflow revisions disabled by default, accept only registered capabilities, surface exact permission receipts, and prevent silent authority broadening.
- Require separate account-scoped email trigger bindings with durable cursors; disabling a definition also disables all of its observation scopes.
- Gate external effects on deterministic validation and exact approval, preserve idempotency keys and reconciliation receipts, and never retry a non-idempotent send with an unknown outcome.
- Add a privacy-safe synthetic workflow package, package author documentation, schema-17 migration coverage, and fixture-backed workflow UI qualification.
- Bind installer health verification to the staged app's declared target workspace schema so schema migrations can complete without a false rollback.
- Isolate packaged-app visual and single-instance qualification from the real Stable workspace so QA cannot migrate user state.
