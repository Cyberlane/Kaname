# Kaname 0.22.0 build 42

- Export a workflow either as a reusable behavior-only `.kanameworkflow` package or as a passphrase-encrypted private `.kanameinstallation` containing its durable history and available referenced artifacts.
- Review imports locally and remove inherited authority: definitions and triggers arrive disabled, cursors are cleared, active work needs attention, pending runs are cancelled, and unexecuted effects lose approval.
- Add opt-in automatic encrypted backups to a local folder, Cloudflare R2, or S3-compatible object storage, with device-only Keychain credentials and exact-destination verification before enablement.
- Seal workspace, provider/runtime state, and workflow-installation artifacts as one coherent recovery generation; verify upload metadata, authenticated encryption, packed-file digests, and the existing recovery manifest.
- Add paginated remote retention, keep-at-least-three generation safety, latest-generation verification and download, and a quiet Backup & Restore settings surface with concise health and failure state.

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
