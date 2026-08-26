# Executable effect.connector

WFP-113 makes `effect.connector` the first node family that can leave the
executor's own bookkeeping and ask something outside to act. Nothing here
reaches a real provider: the only connector the durable executor can talk to is
one the caller injects, and the only implementation this repository ships is a
deterministic in-process fixture. There is no network client, credential store,
account binding, or provider SDK behind it.

## Mail effect kinds

`WorkflowMailEffectClass` names every mail effect the durable authority admits:
`send`, `draft`, `archive`, `label`, `trash`, and `mark-read`. Each kind builds
its own intent, preview, and approval request, so the digests an owner approves
cover the exact action rather than a family of them.

Two properties separate the kinds, and both travel into the approval the owner
sees:

| Kind | Egress class | Reversible |
|---|---|---|
| `send` | `external_communication` | no |
| `draft` | `mailbox_draft` | yes |
| `archive`, `label`, `trash`, `mark-read` | `mailbox_mutation` | yes |

`send` delivers content to a recipient and cannot be undone from the same
mailbox afterwards. `draft` is still a remote mailbox write, but it does not
deliver content to a recipient and remains reversible. It therefore earns its
own egress class rather than sharing either neighbour's.

The effect identity and idempotency key are derived from the kind, the run, the
account binding, the destination fingerprint, and the input digest. Two kinds in
the same run therefore never collide, and the same kind replayed in the same run
resolves to the same key.

## Executable configuration

The compiler marks `effect.connector` executable only when its configuration
declares the whole contract:

- `connectorClass` — the connector package the dependency lock must also pin;
- `action` — the exact action, which must name one admitted mail kind;
- `input` — an executable mapping producing the effect's input value;
- `previewContract` and `reconciliationContract` — bounded contract names; and
- `idempotency` — `required` or `reconcile-only`.

Dropping any one of these leaves the node describable but `schema-only`, so the
executor can never reach a connector for a node that did not declare how it
would be reconciled. Those two idempotency values are also the only ones the
configuration schema admits, and for the same reason: the executor re-offers a
dispatch after an interruption, which is safe only when the provider
deduplicates by key.

The node's ports come from the compiler: `input`, `success`, and `error`. There
is no separate still-unknown port. An unknown outcome leaves on `error` carrying
the effect identity, the projection status, and the number of reconciliation
checks already spent, which is exactly what a downstream `control.reconcile`
node reads to continue the same unknown outcome instead of starting a new one.

## The mapped input

The executor derives the effect's identity from the value the `input` mapping
produces, so that value must be an object carrying:

- `accountBindingId` — the account the connector registration binds; and
- `destinationFingerprint` — a 64-character lowercase hexadecimal digest of the
  destination, never the destination itself.

The input digest is the canonical digest of the whole mapped value. A run
carrying an `effect.connector` node must also pin an `installation_id`, because
the approval scope has no project to name without one.

## Durable phases

One attempt walks the effect through the phases below, appending exactly one
event per executor transition and re-deriving its next action by replaying the
run stream:

| Phase | Event | Recorded fact |
|---|---|---|
| propose | `workflow.effect.proposed` | the intent, preview, and approval request the owner would see |
| authorize | `workflow.effect.authorized` | the resolution the host returned for that exact approval request |
| dispatch | `workflow.effect.dispatch-started` | the registration and deadline the effect may cross under |
| settle | `workflow.effect.dispatch-settled` | the outcome the connector reported |
| reconcile | `workflow.effect.reconciled` | what a later check observed at the provider |

Authority stays outside the executor. `WorkflowEffectHost::authorize` returns
the resolution an owner recorded for one approval request, or nothing; the
executor verifies the returned approval identity and fingerprint against the
request it proposed before it trusts it. When no resolution exists the attempt
fails on `error` with `effect.not-authorized` and no dispatch is ever journaled.

Every timestamp is derived from durable facts rather than a wall clock, so a
replay proposes byte-identical candidates. Proposal and authorization occur at
the attempt's start; the dispatch deadline is the earlier of the authorization
expiry and the dispatch start plus 60 seconds; the authority window is 900
seconds.

## Reconciliation and the idempotency boundary

A dispatch whose outcome is unknown is reconciled rather than repeated. The
executor spends at most three checks inside one attempt. A check that observes
the applied state routes `success` with status `reconciled_applied`; one that
proves the effect never landed routes `error` with `effect.not-applied`; three
checks that all remain unknown route `error` with `effect.outcome-unknown` and
the check count, which hands the outcome to a `control.reconcile` node.

An interruption between `dispatch-started` and `dispatch-settled` is genuinely
ambiguous, and the executor resolves it by re-offering the same dispatch record
under the same idempotency key. That is safe only because a registration must
declare itself `idempotent` and `supportsReconciliation` before any intent may
cross the boundary at all, so the duplicate collapses at the provider instead of
producing a second effect. This reliance on provider-side idempotency is
deliberate; it is the reason `idempotency: none` is not executable.

## Fixture connectors only

`DeterministicWorkflowEffectConnector` answers dispatch and reconciliation from
a per-registration plan, covering the applied, not-applied, and still-unknown
outcomes plus the ambiguous dispatch that only a later check resolves.
`AutoApprovedWorkflowEffectHost` wraps it and approves every proposal, which is
what lets a test prove the reconcile path end to end without an owner in the
loop. `UnavailableWorkflowEffectHost` is the default: it holds no registration
and authorizes nothing, so an executor the caller did not explicitly hand a host
cannot reach a provider.

Compiled policies are admitted only as `authority` policies whose approval is
`always` or `standing-grant-eligible`, and a standing grant additionally
requires the policy to be reversible, because an irreversible effect must not be
pre-approved. The compiled artifact does not carry the node-to-policy link, so
the executor validates the shape of the policies a revision declares rather than
the policy a particular node named.
