# Kaname desktop dogfood build

Kaname is a local-first macOS workspace for project-aware agent threads, attention triage, review evidence, and bounded execution surfaces. The desktop build is the primary dogfood client; the physical iPhone remains a separate qualification lane.

## What is usable

- Home, Threads, Inbox, Projects, Research, Obsidian, Email, Calendar, Automations, GitHub, Skills & Tools, Coding, Local Core, Devices & Remote, and Settings are integrated in one three-column desktop shell.
- The right context area is an attached trailing inspector: its divider, background, search field, resize behavior, and visibility toggle form one surface. Workspace creation and navigation actions remain grouped in the middle-area header where their effects belong.
- Navigation changes content without changing the outer window frame; only explicit window or divider resizing changes geometry.
- Projects, threads, messages, attention, archive state, domain records, operational evidence, and preferences survive restart in `~/Library/Application Support/Kaname/Desktop/workspace.json`. The previous valid snapshot is retained as `workspace.previous.json` and is used automatically if the primary snapshot cannot be decoded.
- The workspace directory is mode `0700` and its state file is mode `0600`.
- Local Core replays the deterministic F-01 through F-14 corpus through a user-scoped Mach service and persists its journals beneath `~/Library/Application Support/Kaname/LocalCore/journal`.
- Coding keeps provider discovery, inspection, planning, approval, implementation, evidence review, acceptance, and knowledge updates separate. Provider comparisons receive independent run identifiers and preserve the brief digest used for the comparison.
- Coding reuses the installed Codex, Claude, and OpenCode sessions without importing their credentials. Codex retains its approval-gated live workflow; Claude and OpenCode expose bounded plan-mode discussions, with OpenCode auto-approval disabled.
- Kaname automatically checks and caches coding-provider health, refreshes connected integration state on a bounded schedule, and exposes manual refresh controls. It uses native Google OAuth plus direct Gmail and Calendar APIs for any number of accounts, `gh` supplies the current GitHub CLI identity, and Apple Calendar permission is requested only from its dedicated integration action. Background checks never open consent UI or credential dialogs. Calendar visibility and exact source selection are stored privately on this Mac.
- Recurring schedules retain an IANA anchor time zone. The pinned wall-clock schedule continues in that zone after travel and across daylight-saving changes, while Kaname shows the equivalent time in the viewer's current zone when it differs.
- Research, email, calendar, automations, GitHub, and knowledge workflows create durable local drafts, proposals, approvals, audit records, artifacts, and dry-run evidence without silently acquiring external authority.
- Email is an account-scoped Gmail workspace with query search, pagination, complete threads, local summaries, attachments, labels, archive and trash previews, local composition, separate draft/send approvals, remotely verified outcomes, partial-failure reporting, and visible pausable standing rules. Existing Google connections must be reconnected once to grant the new Gmail manage and compose scopes; opening Email never starts that consent flow.
- Obsidian and GitHub offer explicit, bounded, read-only refresh actions for the configured project overview and local repository. They reject path traversal, bound output and execution time, and do not use the network.
- Settings is a focused, category-based sheet with a persistent rail for General, Integrations, Coding providers, Calendars, Scheduling, Privacy & Safety, and Diagnostics. Changes save automatically. Integration rows use icons, color, health indicators, and expandable details; coding providers show cached version and authentication state without becoming a long configuration form.
- Navigation keeps bounded screen and thread history. The toolbar Back button, `Command-[`, and the standard macOS mouse Back side button (other mouse button 3) all use the same modal-aware action. The app-lifetime event monitor survives SwiftUI view reconstruction, closes an open Settings or creation dialog first, and leaves an unhandled side-button event available to other responders.

No screen in this build grants provider, repository, account, credential, notification, or physical-device authority merely by being opened. The public repository contains connector protocols, parsers, schemas, and UI—not personal OAuth client files, signing identities, account identities, tokens, calendar IDs, cached mailbox content, or schedules. Those values belong only to private Application Support state, device-only secure storage, `gh`, the provider CLI, or macOS. Public builds remain ad-hoc by default. A private local signing-identity setting can instead give personal dogfood builds a stable macOS code identity so privacy grants survive updates. Native Google secure storage is touched only after an explicit account action. See [Personal integrations](PersonalIntegrations.md) for the full boundary.

## Build, install, and verify

```sh
Scripts/build-kaname-desktop.sh
Scripts/install-kaname-desktop.sh
Scripts/verify-kaname-desktop.sh
```

The installed app is `~/Applications/Kaname.app`. The current dogfood bundle is version `0.12.0` (build `21`). Projects open into a deliberate context overview with editable purpose, workspace, instructions, knowledge, skills, and conversation defaults; the project-tile compose shortcut remains a separate one-click action. The standard thread composer queues Codex, Claude, and OpenCode through one durable conversation worker, streams provider text and activity into the same timeline, supports native-session resume, interrupt/retry and questions, retains bounded raw event evidence, and asks the active provider for a title after the first successful turn. Coding is a control plane rather than a second transcript: it reconciles provider sessions, explicit equal-context comparisons, approval-gated isolated worktrees, signed local commits, verification evidence, subagents, GitHub pull requests, checks, review state, and stack-safe merge authority. Obsidian is a native scoped workspace with Markdown read/edit modes, search, links, backlinks, properties, attachments, provenance and freshness; writes require an exact diff approval, base-revision check, and post-write reconciliation, while project-memory roles and capability updates remain inspectable local state. Gmail work is isolated per connected account and preserves exact previews, approvals or narrow standing authority, audit evidence, pagination, partial failures, and remote reconciliation for every mutation. The worker and provider history live outside the UI lifetime so a relaunch can reconnect without importing the user's provider configuration or MCP/app servers. Stable and candidate apps have separate identities, state, locks, caches, Keychain service names, provider homes, and local-core endpoints, so a candidate can be qualified beside stable Kaname. Settings exposes verified staging, an explicit health-checked switch, and rollback; composer drafts and selection restore from private checkpoints. Installation also bootstraps the user-scoped local-core LaunchAgent. Snapshot qualification disables live provider and integration monitoring and never enumerates accounts, requests Calendar access, or enumerates physical devices. Ad-hoc builds do not access a signing key; a privately configured stable build asks `codesign` to use its selected local Keychain identity.

To preserve macOS privacy grants between personal builds, place the exact code-signing identity name or certificate hash on one line in the private file `~/Library/Application Support/Kaname/Build/codesign-identity` and set its mode to `0600`. `KANAME_CODESIGN_IDENTITY` or `KANAME_CODESIGN_IDENTITY_FILE` can override that setting. The first transition from ad-hoc signing requires one final privacy grant; later builds signed by the same identity retain a compatible designated requirement. The verifier rejects stable-signing metadata if the resulting requirement is still tied to a build-specific code hash.

For a faster development build:

```sh
KANAME_BUILD_CONFIGURATION=debug Scripts/build-kaname-desktop.sh
```

## Removal

Quit Kaname, then unload `com.cyberlane.kaname.desktop.localcore.service` from the current GUI domain. The app, LaunchAgent plist, desktop workspace, and local-core journals can then be reviewed and removed independently; no mobile state is involved.
