# Minimal durable workflow executor

WFP-004C introduced the first deliberately narrow executable workflow slice:

`manual input → Draft 2020-12 validation → first/unique Match → complete/fail`

Later tickets widened that slice one node family at a time. It still consumes
the immutable, manifest-verified `compiled.json` and schema bundle from a
published revision, and a run request must still pin the exact workflow
identity, revision identity, and package digest before the command is admitted
or a run token can exist.

## Executable triggers

Exactly one entrypoint exists, and it must be one of the three executable
triggers. Each one hands its run input straight to its `success` port; the
difference between them is how an occurrence is admitted, not how it executes.

- `trigger.manual` with empty configuration.
- `trigger.event` with an `eventContract` and a `deduplication` mode of
  `event-id` or `contract-key`. Trigger `correlation` binds an event to an
  already running case and is not executable, so the configured array must be
  absent or empty. Kaname offers these contracts through
  `workflow-event-fanout`: `mail.message.received` (Gmail deltas, app open),
  `calendar.event.changed` (Google Calendar sync tokens, app open),
  `github.notification.received` (the `gh` user's inbox, app open), and any
  contract posted to the local control service's webhook
  (`POST http://127.0.0.1:<port>/hook/<contract>` with the bearer token from
  `Workflows/webhook-endpoint.json`), which works with the app closed.
- `trigger.schedule` with a `scheduleKey` and a `misfirePolicy` of `skip` or
  `run-once`. The policy is optional in the schema but required to execute,
  because a misfired occurrence has no safe default.

A run request pins its trigger identity in `RequestWorkflowRun`: an event or
schedule entrypoint requires `trigger_kind` of `event` or `schedule` and a
non-empty `trigger_event_id`. A `trigger.manual` entrypoint keeps whatever kind
the host recorded, because a native mail or calendar signal may still start a
manual graph.

## Trigger admission

`execute_event_trigger` and `execute_schedule_trigger` derive the occurrence
identity, the run identity, the command identity, and the idempotency key from
the compiled trigger configuration and the offered occurrence. Deduplication is
therefore the journal's existing command idempotency rather than a second
mechanism:

- an event deduplicates on the provider event identity under `event-id`, or on
  the caller's contract-scoped key under `contract-key`, so a stream of provider
  events collapses onto one run;
- a schedule deduplicates on its schedule key and the scheduled instant, so a
  repeated catch-up pass over the same missed occurrence resolves to the same
  run; and
- a second admission of an occurrence that already holds a run token appends
  nothing and reports `Duplicate`.

An occurrence has misfired once it is later than its grace window. A `skip`
policy discards it without admitting a command or appending a fact and reports
`Misfired`; `run-once` still admits it exactly once. Advancing the schedule
cursor past a coalesced catch-up window stays with the host.

## Executable nodes

Beyond the triggers, the compiler marks these v1 nodes executable when their
configuration matches the executable subset of their schema: `data.map`,
`data.validate`, `data.case-context`, `data.register-artifact`, `storage.read`,
`storage.write`, `storage.promote`, `compute.capability`, `compute.llm`,
`control.match`, `control.decision`, `control.parallel`, `control.join`,
`control.for-each`, `control.retry`, `control.wait`, `control.reconcile`,
`control.human-review`, `control.subflow`, `effect.connector`,
`terminal.complete`, `terminal.fail`, and `terminal.cancel`.

`effect.connector` executes only against a connector host the caller injects,
and the only host this repository ships is a deterministic in-process fixture.
The executor still rejects resources before it records a run token, and it
admits a revision's policies only as authority policies whose approval it can
honour. No executable graph reads or writes a live provider account: there is no
network client, credential store, or account binding behind the connector
boundary. See [Executable effect.connector](WorkflowEffectConnector.md) for the
mail effect kinds, the executable configuration, and the durable
propose/authorize/dispatch/reconcile phases.

## Durable transition rule

Every token, attempt, trace, emission, edge checkpoint, attempt settlement,
cancellation, and run settlement receives an identifier derived from stable run
and graph identities. The executor appends one new event boundary, then derives
its next action by replaying the run stream. On restart it submits the same
deterministic candidates: the journal accepts exact duplicates and rejects any
identity whose bytes changed.

No mutable executor cursor exists outside the journal. A crash after any event
therefore leaves either no fact or one complete fact; the next invocation starts
from that fact without repeating an attempt or losing a port emission.

## Data and inspection

Trigger input must be one bounded canonical inline JSON value. Validation errors
contain only the schema checker's masked diagnostics. Match records its existing
bounded explanation tree as a separate trace value and forwards the original
input unchanged on the selected stable case port. Errors use a distinct typed
error value and error port.

Cancellation is a typed idempotent command/event. It settles an active attempt
as cancelled, then records terminal run cancellation. The run projection can
rebuild every resulting attempt, node, value, edge, trace, and final outcome.

Nothing here grants provider, account, or credential authority. Scoped storage,
capabilities, models, and connectors reach the executor only through a host the
caller supplies explicitly, and a trigger contributes an identity and a payload,
never an authority. Effect authority likewise stays outside the executor: a host
returns the resolution an owner recorded for one exact approval request, and the
executor verifies that identity and fingerprint before any effect crosses the
boundary.

## Injectable capability and model hosts

`compute.capability` and `compute.llm` reach the outside world only through a
host passed to `execute_with_capabilities`, `execute_with_llm`, or
`execute_with_storage_capabilities_and_llm`. Each family ships three
implementations, and the executor treats all three identically because
availability is decided by registration rather than by the host's kind:

- the unavailable host registers nothing, so a graph that needs it is rejected
  before a run token exists;
- the deterministic host replays a registered plan, which is how fixtures prove
  journal receipts without a live model or a real sandbox; and
- the process host forwards an already compiled invocation to an external
  command named by `KANAME_WORKFLOW_LLM_COMMAND` or
  `KANAME_WORKFLOW_CAPABILITY_COMMAND`. An absent variable, or a command that
  cannot describe itself, leaves the host indistinguishable from the unavailable
  one.

A process host speaks one bounded canonical JSON request on standard input and
reads one bounded JSON response from standard output. It is started with a
cleared environment and a discarded standard error, and a child that outlives
its registered deadline is killed. The serialized request contains no host path
or credential and the child does not inherit environment-provided credentials
or endpoints. This transport is not an operating-system sandbox: it inherits
the current directory and ordinary filesystem and network privileges. Candidate
wiring must add and qualify isolation before using an untrusted executable.
`command describe` runs once at construction. One in-memory host instance caches
and returns the first result for an invocation identity, but that cache is not
durable across a Kaname process restart. `command invoke` therefore carries the
same stable invocation ID on replay, and the external host must honor it as an
idempotency key to prevent duplicate work across restarts.

A described capability registers only when its package digest is a lowercase
64-character SHA-256, and only when that digest appears in
`KANAME_WORKFLOW_CAPABILITY_PACKAGE_DIGESTS` if that allowlist is set. A wrong
or unpinned build therefore cannot claim a trusted capability identity. Every
response, from any host, still crosses the executor's redaction, schema,
trace-bound, and tool-budget checks before it becomes durable evidence.

## Agent-grade prompt context

A `compute.llm` node inherits the artifact references reachable from the inputs
admitted on this attempt and from its case episode. Each one enters the prompt
as an `attachments` context group entry carrying the opaque storage handle, the
content type, the content digest, and the byte count — never a host path and
never the artifact bytes. A prompt can therefore name an artifact that a model
may fetch through a declared tool, while the journal records only the digest.

`maximumToolCalls` bounds one attempt's tool loop. It is optional, so a revision
published before the field existed keeps executing against the global runtime
bound of 128. When present it must be between 1 and 128 and the node must
declare at least one tool, or the graph is rejected as
`llm_execution_contract` before an attempt starts. A trace that reports more
tool calls than the node's recorded budget settles the attempt as
`llm.tool-call-budget-exceeded` and admits no output.
