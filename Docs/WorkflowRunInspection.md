# Durable workflow run inspection

Kaname renders workflow run history from a disposable SQLite projection rebuilt from the authoritative event journal. The signed local service owns both paths; the protobuf query contains only workflow or run identities and a bounded result limit.

Each returned run remains pinned to its published `workflow_id`, `revision_id`, and package digest. Swift loads that exact immutable revision before constructing the historical graph. Publishing a newer revision therefore does not change an older run's diagram, node configuration, or version label. If the revision is unavailable or its identity fails to match the run, the UI explains the missing evidence and does not substitute the current workflow.

The projection exposes separate evidence groups for:

- node attempts and timing;
- admitted input checkpoints;
- output emissions and bounded value references;
- error code and error value;
- Match evaluation traces;
- edge checkpoints; and
- raw projected event identities and journal positions.

Inline canonical JSON can be displayed directly. A storage-backed or purged value retains its identity, content type, byte count, and digest while the UI explains that content is unavailable. It is never rendered as an empty value or a successful result.

The production Automations screen uses a fixed-size graph world inside two-axis scrolling, with explicit zoom controls. Narrow windows drill from the run list into detail instead of compressing the list, canvas, and inspector into one unreadable row.

This slice is read-only. It does not execute workflows, dereference future object storage, access accounts or credentials, invoke providers, or perform external effects.
