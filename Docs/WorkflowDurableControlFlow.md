# Durable workflow fork and join

Kaname treats parallel control flow as durable data, not worker memory.

## Token lifecycle

- Every run creates one root execution token after the immutable run pin.
- `control.parallel` creates two to 64 deterministic child tokens. Each child records its parent, fork node, branch identity and port, expected join, and source emission.
- The parent settles as `forked` only after all child-token, emission, and edge facts are durable.
- A branch remains active while its admitted edge advances through ordinary nodes. Replaying the same command cannot create a second token or attempt.
- A terminal node settles its token as completed or failed. Run cancellation settles every still-active token as cancelled.
- A successful or impossible join creates one deterministic resumed token. Arrived branches settle as joined; branches cancelled by policy settle as cancelled.

## Join decision

One `workflow.join.evaluated` event stores the complete partition:

- `expected`: every child token created by the fork;
- `arrived`: tokens with a durable admitted edge into this join;
- `failed`: tokens already settled without reaching the join;
- `pending`: every expected token in neither earlier set.

The sets are bounded, unique, disjoint, and exhaustive. The runtime contract rejects any contradictory partition before journal mutation.

`all` succeeds when every expected token arrived and fails when one can no longer arrive. `any` succeeds on the first arrival and fails only after every token becomes unavailable. `quorum` succeeds at its configured threshold and fails when arrived plus pending tokens are fewer than that threshold. A failed decision always closes pending work because later results cannot change it. A successful decision obeys `cancelRemaining`.

## Determinism and restart

The local worker advances one positioned event boundary at a time. Ready tokens are ordered by durable position and identity, while a newly resumed join token is admitted before unfinished siblings so an early `any` or `quorum` decision is observable. This is logical parallelism with deterministic local scheduling; later effect/capability workers may execute independent tokens concurrently without changing the journal contract.

Event IDs, token IDs, attempt IDs, emissions, and resumed-token IDs are derived from immutable run, node, branch, and parent identities. A process termination at any boundary therefore resumes at the next missing fact, and duplicate delivery resolves to the same stored bytes.

## Inspection

Projection schema v4 records token lineage, state, outcome, terminal/join identity, error, emissions, and journal positions. It records each join's policy, threshold, decision, token partition, resumed token, and cancellation choice. Attempts, emissions, and edges carry their execution token. The run inspector exposes this as a separate **Tokens** group rather than mixing it into input/output or raw-event noise.

Projection v3 is disposable. On upgrade, Kaname resets its checkpoint and rebuilds v4 from the authoritative journal so the attempt key can widen from `(run, node, attempt)` to `(run, execution token, node, attempt)` without retaining an ambiguous intermediate state.
