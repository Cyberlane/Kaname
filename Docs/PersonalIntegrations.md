# Personal integrations

Kaname's live integrations are designed for one person's private desktop installation. The public repository contains reusable adapter code and test fixtures only; it must not contain real account identities, tokens, calendar identifiers, mailbox content, provider conversations, or schedules.

## Credential ownership

Kaname does not become an OAuth or token authority for the desktop integrations:

- Gmail and Google Calendar use every account already available to `zele`. Refreshing account setup imports bounded account and calendar metadata, never a token.
- GitHub uses the identity and host currently available to `gh`.
- Codex, Claude, and OpenCode launch their native local adapters and retain their own authentication state.
- Apple Calendar uses EventKit. Merely opening Kaname or Settings does not request access; the user must choose **Request access** in Personal integrations.

If a native tool's session is missing or expired, Kaname reports that the connector is unavailable and asks the user to repair it in that tool. Kaname does not collect credentials in its own UI.

## Private state

Account references, enabled calendars, exact draft/proposal sources, personal content, and schedule configuration are written beneath `~/Library/Application Support/Kaname/Desktop`. The directory and workspace snapshot use owner-only filesystem modes. Redacted diagnostics contain counts and health states rather than identities, content, tokens, or private paths.

Opening an integration screen performs no account read. The user explicitly chooses refresh before Kaname runs `zele`, `gh`, or a provider adapter. Apple Calendar permission remains a separate explicit action.

## Multiple accounts and calendars

One Google refresh discovers every account exposed by `zele`, so four Gmail accounts can be active simultaneously without four separate Kaname sign-ins. Mail results retain their source identity, and email drafts retain an exact account reference.

Google and Apple calendar sources appear together in Settings. Each calendar can be enabled independently. Event proposals retain both the owning account and the exact calendar source, preventing an approval from drifting to a different calendar.

## Time-zone semantics

New schedule and event forms default to the IANA time zone saved in Settings, initially the Mac's zone at setup. Kaname persists the recurrence intent with that anchor zone and derives execution instants from it. It does not treat the current travel zone as a replacement schedule.

For example, a weekly 09:00 schedule anchored to `Asia/Tokyo` remains 09:00 in Japan after the Mac travels to Germany. The UI displays the pinned Japan time and, when different, the equivalent time in the viewer's current zone. Using an IANA zone rather than a fixed UTC offset preserves the anchor zone's daylight-saving rules.

## Consequential actions

Reading bounded metadata or inbox results is distinct from changing an external system. Sending mail, creating or changing an event, pushing GitHub state, or granting provider write access requires an exact target, an explicit in-app approval, and post-action reconciliation. Local drafts and plan-mode provider discussions do not imply that authority.
