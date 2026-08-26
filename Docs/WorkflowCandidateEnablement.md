# Candidate enablement ladder (WFP-115 / WFP-116)

Kaname’s durable Workflow v2 path now executes the control, review, trigger,
effect, and compute nodes needed to migrate assistant automation off Kimaki.
This note is the **Candidate enablement** checklist. It does not authorize
live Gmail effects, standing grants, or Kimaki cutover by itself.

Private domain packages (gmail-assistant, SimplyKay) stay **out of this
repository**. Install them only as private `.kanameworkflow` /
`.kanamecapability` packages on a Candidate build.

## Comfort bar before flipping any Kimaki path off

All of the following must be true on a **qualified Candidate** channel (not
Development):

1. A schedule or mail-event binding creates a durable v2 run without a manual
   start.
2. Uncertainty stops in Inbox via executable `control.human-review` with a
   frozen proposal digest.
3. An approved mail effect reaches `reconciled_applied` through
   `effect.connector` + `control.reconcile`.
4. One gmail-assistant flow completes observe → shadow → approved-effect with
   zero silent authority.
5. Automations **Run history** shows the same journal as the Rust durable
   projection (see [WorkflowRunInspection](WorkflowRunInspection.md)).
6. Kimaki remains available as rollback until standing grants prove stable for
   that flow.

## Stage ladder

Use `DesktopWorkflowMigrationStage` in order. Do not skip. Do not enable
standing grants on Development.

| Stage | What is allowed | Exit gate |
|---|---|---|
| `observeOnly` | Event/schedule triggers admit durable runs; zero effects | Durable runs appear in Automations Run history; no `workflow.effect.*` |
| `shadow` | Compare Kaname decisions to the legacy Kimaki / watcher path | Zero material policy differences on the fixture suite |
| `draftOnly` | Mail drafts may be proposed; send/archive/label/trash stay blocked | Drafts reconcile; no outbound mutation |
| `approvedEffects` | One-shot owner-approved `effect.connector` kinds | Each kind reaches `reconciled_applied` or explicit reject |
| `standingAuthority` | Narrow reversible standing grants only | Grant scope, last-use, pause, and revoke are inspectable |
| `legacyRetired` | Kimaki path for that flow may be stopped | Shadow still green for one full business cycle; rollback notes retained |

## WFP-115 — gmail-assistant

Enable the private F1–F8 / S1–S7 portfolio **one workflow at a time**:

1. Install the private package on Candidate (definition disabled).
2. Advance migration assessment to `observeOnly`; enable an observe-only Gmail
   binding (history cursor, no backfill).
3. Shadow against the current Kimaki / digest path.
4. `draftOnly` for composition flows; keep send behind exact approval.
5. `approvedEffects` for send / archive / label / trash kinds already covered
   by the durable fixture connector contract.
6. Standing grants only for the two previously identified reversible
   candidates (`smbc-trash`, `npm-publication-cleanup`) after owner review.
7. `legacyRetired` only after Kimaki rollback instructions are written and
   the LaunchAgent path for that flow is confirmed idle.

Protected categories, exact-scope exclusions, and `uncertain → review`
defaults remain in the private policy ledger.

## WFP-116 — SimplyKay

Author SimplyKay only after WFP-115 observe→approved-effect is green for the
mail intake path:

1. Package private xlsx / OOXML scripts as `.kanamecapability` digests
   (WFP-111 bounded process transport plus a separately qualified sandbox).
2. Author routers that stop on uncertainty via `control.human-review`.
3. Bind Gmail read / draft / send / reconcile through `effect.connector`.
4. Keep Soldo MFA / write surfaces human-bound (WFP-117; not part of this
   ladder).
5. Prefer durable case continuity (Gmail thread ↔ workflow case ↔ wait /
   episode) over spawning a new amnesiac agent session per reply.

## Kimaki rollback

Until `legacyRetired` for a given flow:

- Keep the Kimaki LaunchAgent and Discord project channel intact.
- Keep any PM2 / watcher → `kimaki send` path for SimplyKay.
- Record the Candidate workflow id, revision digest, and migration stage in
  the private ops note so a rollback is a disable + re-enable, not an
  archaeology exercise.
- Do not delete Kimaki scheduled tasks or bot tokens as part of Candidate
  enablement.

## Platform proofs this ladder assumes

| Ticket | Proof |
|---|---|
| WFP-109 | `control.human-review`, `control.decision`, `control.reconcile`, `data.register-artifact`, `terminal.cancel`, match `all`, join `named` |
| WFP-112 | `trigger.event` / `trigger.schedule` admission, dedupe, misfire, observe-only fixture |
| WFP-113 | Mail `effect.connector` kinds with propose → authorize → dispatch → reconcile |
| WFP-110 / 111 / 114 | Injectable LLM and capability hosts; bounded agent-grade tool loop |
| Run history seam | Automations Run history reads the durable Rust projection |

Host gaps that remain outside the Rust fixtures (Swift/macOS Candidate
wiring, live Gmail OAuth, real Codex/Claude/OpenCode process hosts) must be
closed on Candidate before stage exit gates that require live evidence.
