# Minimal durable workflow executor

WFP-004C introduces the first deliberately narrow executable workflow slice:

`manual input → Draft 2020-12 validation → first/unique Match → complete/fail`

It consumes the immutable, manifest-verified `compiled.json` and schema bundle
from a published revision. A run request must pin the exact workflow identity,
revision identity, and package digest before the command is admitted or a run
token can exist.

## Executable subset

The compiler marks only these v1 nodes executable:

- `trigger.manual` with empty configuration;
- `data.validate` with a schema present in the immutable runtime schema bundle;
- `control.match` with `first` or `unique` hit policy;
- `terminal.complete` with empty configuration; and
- `terminal.fail` with empty configuration.

The graph must have one manual entrypoint, one ready node at a time, and
whole-value edges. The executor rejects storage-backed values, mappings,
resources, policies, dependencies, parallel Match fan-out, capabilities, LLMs,
connectors, and all effects before it records a run token.

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

Manual input must be one bounded canonical inline JSON value. Validation errors
contain only the schema checker's masked diagnostics. Match records its existing
bounded explanation tree as a separate trace value and forwards the original
input unchanged on the selected stable case port. Errors use a distinct typed
error value and error port.

Cancellation is a typed idempotent command/event. It settles an active attempt
as cancelled, then records terminal run cancellation. The run projection can
rebuild every resulting attempt, node, value, edge, trace, and final outcome.

This ticket grants no provider, account, credential, storage, model, connector,
or effect authority.
