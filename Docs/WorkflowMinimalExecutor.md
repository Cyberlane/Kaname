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
  absent or empty.
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
`control.human-review`, `control.subflow`, `terminal.complete`, `terminal.fail`,
and `terminal.cancel`.

`effect.connector` remains schema-only. The executor rejects resources,
policies, and every external effect before it records a run token, so no
executable graph can read or write a live provider account.

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

Nothing here grants provider, account, credential, connector, or effect
authority. Scoped storage, capabilities, and models reach the executor only
through a host the caller supplies explicitly, and a trigger contributes an
identity and a payload, never an authority.
