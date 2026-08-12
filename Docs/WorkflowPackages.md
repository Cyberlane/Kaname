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

Packages may reference only capabilities registered by Kaname. They cannot specify arbitrary executable paths. Account, filesystem, network, and model-egress scope is declared in the permission envelope.

Blocking validation failures prevent effect proposals. Consequential effects use Kaname's exact approvals. Non-idempotent effects cannot be configured for automatic retry, and an ambiguous remote outcome enters `outcomeUnknown` for reconciliation instead of being sent again.

## Private migrations

Keep proprietary prompts, matching rules, schemas, private knowledge, paths, and adapters outside this repository. Migrate an existing workflow through observe-only, shadow, draft-only, approved-effect, and finally narrowly scoped standing-authority stages. The package boundary lets Kaname provide the generic infrastructure while private installations remain opinionated.

Use a private installation export to move or preserve one configured workflow. Use Kaname's whole-app backup for disaster recovery of one coherent generation; these formats are not interchangeable.
