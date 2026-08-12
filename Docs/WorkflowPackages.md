# Kaname workflow packages

Kaname workflow packages describe reusable orchestration without embedding a private business process in the application. A package is a bounded JSON manifest; Kaname owns durable state, context provenance, validation, approvals, effects, recovery, and presentation.

The synthetic [document revision example](../Examples/Workflows/document-revision.workflow.json) contains no private names, paths, layouts, prompts, or customer data. It is intentionally draft-only.

## Install and activate

1. Open **Email → Workflows → Definitions**.
2. Choose **Install package…** and select a manifest.
3. Inspect the immutable revision, ordered stages, permissions, and manifest digest.
4. Enable the definition only after review.
5. For email triggers, add an exact Gmail account and filter scope. The binding starts disabled and must be enabled separately.

Installing a newer revision never changes prior runs. A permission-broadening revision cannot remain enabled silently. Disabling a definition also disables each of its trigger bindings.

## Export and move

Each installed definition offers two intentionally different exports:

- **Reusable package (`.kanameworkflow`)** — canonical behavior, stages, triggers, and permission declarations only. It excludes accounts, bindings, cursors, work items, prompts assembled at runtime, runs, artifacts, credentials, and private installation data. This is the shareable OSS boundary.
- **Private installation (`.kanameinstallation`)** — the package plus that workflow's durable work history, thread bindings, episodes, facts, frozen contexts, runs, validations, effects, evidence links, and available referenced artifact bytes. It is encrypted locally with AES-GCM using a passphrase-derived key before it is written.

Kaname never stores an installation-export passphrase. Import decrypts and reviews locally, refuses identity collisions, and preserves prior evidence while removing authority: the definition and all triggers arrive disabled, cursors are cleared, active work requires attention, pending runs are cancelled, and unexecuted effects lose approval and are cancelled. Account, capability, context, and effect authority must be reviewed before resuming.

## Runtime identity

Kaname separates the durable identities that make correction-heavy work understandable:

- A definition is reusable behavior and a revision is its immutable contract.
- A work item is one durable unit of work, independent of an email thread.
- A conversation binding connects one or more external threads to that work item.
- An episode captures one meaningful request, correction, clarification, or acceptance event.
- A run and its step attempts preserve exact inputs, workflow revision, context digest, and retry semantics.
- An external effect records exact target, content and attachment digests, approval, idempotency key, and reconciliation outcome.

Provider transcripts are supporting evidence, not canonical memory. Model steps receive a compiled context snapshot containing active facts and explicit exclusions for superseded material.

## Capability and effect rules

Workflow packages may reference only capabilities registered by Kaname. Executable behavior is installed separately as a `.kanamecapability` directory and is never embedded implicitly in a workflow manifest. Each capability has an immutable ID and version, a digest binding every package-relative file, a separately pinned entrypoint digest or reviewed code-signature requirement, JSON input and output schemas, deterministic/idempotent declarations, explicit permissions, and resource limits. Kaname rechecks the complete package digest before every invocation, so a changed helper, rule, or asset invalidates the reviewed receipt.

Open **Email → Workflows → Definitions → Capability library** to install a capability directory. Kaname verifies it, copies it into private app storage disabled, and requires a representative local JSON test before enablement. External capabilities run in a deny-by-default macOS sandbox with no network access, private input/output directories, bounded time and bytes, and content-addressed artifact ingestion. Built-in Gmail, model, context, validation, and artifact services use the same logical routing contract but remain Kaname-signed host behavior.

The privacy-safe [synthetic capability](../Examples/Capabilities/synthetic-document-check.kanamecapability/capability.json) and its [representative input](../Examples/Capabilities/synthetic-document-check.input.json) demonstrate the external package boundary. They contain no legacy-workflow behavior.

Definitions show a collapsed **Migration readiness** checklist. Observe-only migration is ready only when the exact revision, every capability, trigger binding, storage, and crash-recovery contract are available. A configured but disabled or cursorless Gmail trigger remains visibly blocked or needs attention; installing a workflow never starts mailbox observation.

Enabled Gmail bindings establish a current History API cursor before observing new mail, so enabling one does not silently backfill an old mailbox. Subsequent checks page all history before advancing the cursor, deduplicate message observations, re-check the reviewed Gmail filter, and use a bounded full sync when Google reports that a cursor expired. Each matching conversation is grouped into one durable work item with later messages represented as episodes and frozen context snapshots.

Blocking validation failures prevent effect proposals. Consequential effects use Kaname's exact approvals. Non-idempotent effects cannot be configured for automatic retry, and an ambiguous remote outcome enters `outcomeUnknown` for reconciliation instead of being sent again.

Structured model steps accept a generic provider request and schema. Kaname currently routes those requests through its existing Codex, Claude, or OpenCode runtime with read-only workflow authority, then rejects output that does not satisfy the declared JSON schema. Provider transcripts remain evidence; the frozen context and validated result remain the durable workflow inputs.

## Private migrations

Keep proprietary prompts, matching rules, schemas, private knowledge, paths, and adapters outside this repository. Migrate an existing workflow through observe-only, shadow, draft-only, approved-effect, and finally narrowly scoped standing-authority stages. The package boundary lets Kaname provide the generic infrastructure while private installations remain opinionated.

Use a private installation export to move or preserve one configured workflow. Use Kaname's whole-app backup for disaster recovery of one coherent generation; these formats are not interchangeable.
