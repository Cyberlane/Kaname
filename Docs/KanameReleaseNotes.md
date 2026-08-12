# Unreleased

- Add package-v2 typed, acyclic workflow graphs with declarative JSON Pointer decisions, durable selected edges, handled failure routes, and package-v1 compatibility.
- Add schema-driven editable human review, resumable correlated event subscriptions, explicit timeout routes, and a quiet attention-first Workflow Work surface.
- Add trusted connector preview, approval or predicate-bounded standing authority, idempotent execution, reconciliation, and unknown-outcome recovery without exposing credentials to capabilities.
- Add workflow-owned schema-validated datasets with unique-key optimistic upserts, structured validator findings, privacy-filtered execution receipts, bounded agent policies, and complete extension-tree manifests.
- Preserve all new private records in encrypted installation export and coherent backups while cancelling active waits and reviews and revoking inherited authority on import.
- Advance the durable workspace schema to 20 so older builds cannot silently discard the generic workflow host state.
- Add declared cross-step artifact inputs: Kaname materializes immutable role-bound artifacts into a private read-only sandbox area and supplies a provenance manifest without exposing app storage paths.
- Add schema-validated, revision-checked workflow state. Capability mutations and step completion commit together, and stale optimistic revisions fail closed instead of overwriting newer state.
- Add reviewable workflow knowledge with work-item, installation, and account-binding scopes. Capability proposals remain outside model context until verified; rejected, expired, and superseded knowledge becomes an explicit negative constraint.
- Add a bounded capability commit sidecar for state mutations, knowledge proposals, and artifact-role publication while retaining the existing JSON input/output schemas.
- Show verified truth, pending knowledge review, current artifact roles, and collapsed operational-state metadata in the Workflow Work UI.
- Preserve state records, artifact roles, and referenced private artifact bytes through encrypted installation export/import; reusable packages continue to exclude all private installation data.
- Advance the durable workspace schema to 19 so older builds cannot silently discard the workflow data plane.

# Kaname 0.23.0 build 43

- Add immutable, separately installable local capability packages with a complete package-tree digest, executable digest or code-signature trust, JSON input/output contracts, quotas, and an explicit test-before-enable lifecycle.
- Run external adapters in a deny-by-default macOS sandbox with no network access, private scratch space, bounded execution and output, content-addressed artifact ingestion, and durable step receipts.
- Add a resumable workflow interpreter with single-owner leases, bounded dispatch, exact frozen revisions, output chaining, idempotent crash recovery, and review stops for interrupted non-idempotent work.
- Observe enabled account-scoped Gmail workflow bindings with paginated History API cursors, deduplication, filter checks, bounded full-sync recovery, and durable email-to-work-item episode grouping.
- Preserve thread-aware replies and attachment bytes in exact Gmail approval targets, including reply headers, thread ID, multipart MIME, limits, remote reconciliation, and cursor parsing.
- Add private per-workflow JSON state and content-addressed artifact storage, include both capability packages and workflow storage in coherent encrypted backups, and keep them out of reusable behavior packages.
- Add a low-noise capability library and per-definition migration-readiness disclosure so missing, untested, disabled, or permission-incompatible pieces are visible before observe-only migration.
- Route schema-constrained model stages through Kaname's existing Codex, Claude, or OpenCode runtimes while retaining frozen context and validated JSON output.
- Ship a privacy-safe synthetic capability fixture and conformance coverage without adding any legacy-workflow behavior, prompts, data, accounts, or migration adapter.

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
