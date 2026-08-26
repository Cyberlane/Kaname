# Durable workflow run inspection

Kaname renders workflow run history from a disposable SQLite projection rebuilt from the authoritative event journal. The signed local service owns both paths; the protobuf query contains only workflow or run identities and a bounded result limit.

Each returned run remains pinned to its published `workflow_id`, `revision_id`, and package digest. Swift loads that exact immutable revision before constructing the historical graph. Publishing a newer revision therefore does not change an older run's diagram, node configuration, or version label. If the revision is unavailable or its identity fails to match the run, the UI explains the missing evidence and does not substitute the current workflow.

The projection exposes separate evidence groups for:

- node attempts and timing;
- admitted input checkpoints;
- output emissions and bounded value references;
- error code and error value;
- Match evaluation traces;
- edge checkpoints;
- durable timer, event, and reply subscriptions with their isolated owner,
  exact correlation digests, expiry, revision/package pin, resolution, and
  resolving signal; and
- raw projected event identities and journal positions.

Inline canonical JSON can be displayed directly. A storage-backed or purged value retains its identity, content type, byte count, and digest while the UI explains that content is unavailable. It is never rendered as an empty value or a successful result.

Wait signals are durable and idempotent even when they arrive before the wait
subscription exists. One signal can resolve at most one subscription. Wrong
owners or correlations remain visible evidence but cannot resume the workflow;
timers resume at their recorded deadline, event/reply waits expire at theirs,
and cancellation records an explicit cancelled wait before settling its node.

The production Automations screen uses a fixed-size graph world inside two-axis scrolling, with explicit zoom controls. Narrow windows drill from the run list into detail instead of compressing the list, canvas, and inspector into one unreadable row.

## One run history

The Automations **Run history** tab is this durable Rust projection and nothing
else. The in-memory desktop snapshot still describes workflow structure for the
Workflows and Builder tabs, but it is a design-time preview rather than a record
of what ran, so it is no longer offered as a parallel timeline. Two run
histories side by side would have left the reader deciding which one to trust.

When the local service that owns the projection is unreachable, the tab says so
and shows nothing in place of the missing evidence. An unavailable projection is
never presented as an empty run history, because "no run has evidence" and "the
evidence could not be read" are different facts and only one of them is safe to
act on.

The inspection transport itself is read-only. It does not dereference scoped
storage, access accounts or credentials, invoke providers, or perform external
effects; wait execution remains inside the typed durable runtime.
