# Workflow run projection

`WorkflowRunProjection` is a disposable SQLite read model built only from the
authoritative local journal. It does not execute workflow nodes, resolve stored
values, call a provider, or grant an effect.

## Persisted read model

The projection schema records:

- runs pinned to workflow, revision, and package digest;
- attempt and per-node lifecycle state with start/settlement timing;
- emitted ports and their immutable value references;
- admitted or skipped edge checkpoints;
- Match evaluation references and routed case/port identities;
- cancellation and run settlement outcomes; and
- the exact journal event identities and global high-water checkpoint used to
  build the state.

Value rows retain only the bounded `WorkflowValueReference` admitted by the
runtime contract. They contain canonical inline JSON or an opaque storage
reference, never a host path, credential, provider binding, or dereferenced
file.

## Replay contract

The journal exposes bounded pages in global store order and verifies each
stored wire digest before decoding it. A projection batch applies every
workflow event and advances the global checkpoint in one immediate SQLite
transaction. Interruption before commit leaves both state and checkpoint
unchanged. Re-reading an already projected event is a no-op only when its event
identity, store position, and kind are identical.

Lifecycle application fails closed for missing or reused run identities,
token mismatches, overlapping node attempts, emissions without an active
attempt, edges without an emission, settlement with active attempts, or a
declared emission set that differs from recorded emissions.

## Disposable recovery

Every committed batch stores a SHA-256 digest of a deterministic, sorted JSON
representation of all projection tables and the checkpoint. SQLite quick-check,
foreign-key validation, and that logical digest must all pass.

A logical mismatch resets the supported schema and replays from zero. A
physically corrupt supported database is renamed beside the private database as
`*.corrupt-NN`, including WAL/SHM sidecars when present, before a clean database
is rebuilt. Unsafe paths and newer schema versions are never replaced.

This recovery is safe because the projection is not an authority: immutable
runtime events remain in the journal.
