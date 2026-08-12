# Kaname 0.19.0 build 37

- Keep the Threads directory fixed while providers stream, with separate Active and Completed sections and stable creation-time ordering.
- Show explicit running, queued, waiting-for-input, approval-required, failed, response-ready, and complete states in fixed-height rows.
- Attach, paste, or drop up to eight images in Codex, Claude, and OpenCode conversations, with previews, draft persistence, private normalized storage, and image-only messages.
- Send provider-specific image inputs without embedding image bytes in workspace or service request JSON.
- Protect schema-changing updates with digest-bound workspace snapshots, migration-aware health timing, and bundle-plus-workspace rollback.
