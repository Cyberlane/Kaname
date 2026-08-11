# Kaname 0.17.4 build 34

- Keep long provider command-output bursts within the bounded live event stream without losing sealed raw evidence.
- Group repeated timeline activity and page large histories so an active conversation remains responsive.
- Preserve questions, approvals, errors, active-run state, and exact message reconstruction across event coalescing.
- Compact completed legacy provider-event histories during the schema-15 workspace migration.
