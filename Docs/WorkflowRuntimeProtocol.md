# Workflow Runtime Protocol

WFP-004A defines the provider-free command and event vocabulary for one durable local workflow run. The canonical messages live in `proto/kaname/v1/workflow_runtime.proto`; commands and events remain wrapped by the existing `CommandEnvelope` and `EventEnvelope`, so the journal keeps its established ordering, exact-wire retention, replay, and idempotency behavior.

## Command payloads

| Envelope kind | Protobuf payload | Purpose |
|---|---|---|
| `workflow.run.request` | `RequestWorkflowRun` | Request a run pinned to an immutable workflow revision and package digest. |
| `workflow.run.cancel` | `CancelWorkflowRun` | Request cancellation of one identified run token. |

Both commands require a project-scoped local actor and an idempotency key. Account IDs, authority grants, egress classes, destination digests, credentials, and paths are rejected at this stage. Admission records intent only; it does not execute a workflow.

## Event payloads

| Envelope kind | Protobuf payload | Durable fact |
|---|---|---|
| `workflow.run.token-created` | `WorkflowRunTokenCreated` | The run is pinned to one revision/package and one execution token. |
| `workflow.execution-token.created` | `WorkflowExecutionTokenCreated` | A root, branch, or post-join path became durable. |
| `workflow.execution-token.settled` | `WorkflowExecutionTokenSettled` | One path completed, failed, was cancelled, forked, or was consumed by a join. |
| `workflow.join.evaluated` | `WorkflowJoinEvaluated` | One all, any, or quorum decision recorded the complete expected/arrived/failed/pending token partition. |
| `workflow.attempt.started` | `WorkflowAttemptStarted` | A numbered node attempt began. |
| `workflow.port.emitted` | `WorkflowPortEmitted` | A named output port emitted one immutable value reference. |
| `workflow.match.trace-recorded` | `WorkflowMatchTraceRecorded` | Match cases evaluated, selected cases, emitted ports, and an inspectable trace were recorded separately. |
| `workflow.edge.checkpointed` | `WorkflowEdgeCheckpointed` | One emission was durably admitted to or skipped by one downstream edge. |
| `workflow.attempt.settled` | `WorkflowAttemptSettled` | A node attempt succeeded, failed, or was cancelled with typed output/error references. |
| `workflow.run.cancellation-requested` | `WorkflowRunCancellationRequested` | An admitted cancellation command became part of run history. |
| `workflow.run.settled` | `WorkflowRunSettled` | The run reached one terminal success, failure, or cancellation outcome. |

Runtime events must use stream `workflow-run:<run-id>`, correlation ID `<run-id>`, a non-empty causation ID, and local `workflow-runtime` provenance. Provider identities, native cursors, raw evidence, and external retention classes fail closed.

## Value references and bounds

`WorkflowValueReference` supports either canonical inline JSON or an opaque storage reference ID, never both. Inline JSON is limited to 32 KiB and must match its byte count and lowercase SHA-256 digest exactly. Typed payloads are limited to 48 KiB inside the existing 64 KiB envelope; inputs and emissions are bounded; attempt numbers and Match trace identifier lists are bounded; identifiers use a small path-free ASCII alphabet.

The storage reference is only a forward-compatible opaque identifier. WFP-004 does not implement object storage or grant storage access. Content-addressed objects, job/workflow isolation, handles, promotion, and deletion remain WFP-005 work.

## Durable control-flow boundary

The journal validates these typed contracts before mutation and retains their exact positioned bytes across restart. Unknown runtime kinds, mismatched payload types, malformed Protobuf, reused idempotency keys, non-canonical JSON, contradictory success/error shapes, invalid join partitions, wrong streams, and live-provider provenance are rejected.

The local executor now creates one root execution token, deterministic child tokens for every `control.parallel` branch, and one resumed token after a settled `control.join`. Attempts, emissions, Match traces, and admitted edges name their execution token. `all`, `any`, and `quorum` joins decide from an immutable partition of the fork's expected tokens; a threshold that can no longer be met routes a typed join error. `cancelRemaining` settles pending tokens without starting them. When it is false, an early successful join may continue downstream while remaining branches finish, but the run itself cannot settle until every token is closed. The disposable projection retains token and join records and can rebuild them entirely from the journal.

This stage still grants no capability, LLM, connector, account, provider, effect, or external-action authority. Named joins, bounded iteration, retry, waits, feedback cases, and effects remain later runtime stages.
