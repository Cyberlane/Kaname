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
- Obsidian and GitHub offer explicit, bounded, read-only refresh actions for the configured project overview and local repository. They reject path traversal, bound output and execution time, and do not use the network.
- Settings is a focused, category-based sheet with a persistent rail for General, Integrations, Coding providers, Calendars, Scheduling, Privacy & Safety, and Diagnostics. Changes save automatically. Integration rows use icons, color, health indicators, and expandable details; coding providers show cached version and authentication state without becoming a long configuration form.
- Navigation keeps bounded screen and thread history. The toolbar Back button, `Command-[`, and the standard macOS mouse Back side button (other mouse button 3) all use the same action; an unhandled side-button event is left available to other responders.

No screen in this build grants provider, repository, account, credential, notification, or physical-device authority merely by being opened. The public repository contains connector protocols, parsers, schemas, and UI—not personal OAuth client files, identities, tokens, calendar IDs, cached mailbox content, or schedules. Those values belong only to private Application Support state, device-only secure storage, `gh`, the provider CLI, or macOS. The packaged qualification build uses ad-hoc signatures and identifier requirements so it can build and launch without an Apple signing credential or development-time Keychain access. Native Google secure storage is touched only after an explicit account action. See [Personal integrations](PersonalIntegrations.md) for the full boundary.

## Build, install, and verify

```sh
Scripts/build-kaname-desktop.sh
Scripts/install-kaname-desktop.sh
Scripts/verify-kaname-desktop.sh
```

The installed app is `~/Applications/Kaname.app`. The current dogfood bundle is version `0.6.3` (build `11`). Installation also bootstraps the user-scoped `com.cyberlane.kaname.desktop.localcore.service` LaunchAgent. Verification posts a button-3 event only into Kaname's own AppKit event queue to exercise Back without Accessibility permission or global input injection. Snapshot qualification disables live provider and integration monitoring; the build and installer never call `security`, access the login Keychain, enumerate accounts, request Calendar access, or enumerate physical devices.

For a faster development build:

```sh
KANAME_BUILD_CONFIGURATION=debug Scripts/build-kaname-desktop.sh
```

## Removal

Quit Kaname, then unload `com.cyberlane.kaname.desktop.localcore.service` from the current GUI domain. The app, LaunchAgent plist, desktop workspace, and local-core journals can then be reviewed and removed independently; no mobile state is involved.
