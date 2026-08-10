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
- Personal integrations are explicit refreshes. `zele` supplies every existing Gmail account and its Google calendars, `gh` supplies the current GitHub CLI identity, and Apple Calendar is requested only from the dedicated settings action. Calendar visibility and exact source selection are stored privately on this Mac.
- Recurring schedules retain an IANA anchor time zone. The pinned wall-clock schedule continues in that zone after travel and across daylight-saving changes, while Kaname shows the equivalent time in the viewer's current zone when it differs.
- Research, email, calendar, automations, GitHub, and knowledge workflows create durable local drafts, proposals, approvals, audit records, artifacts, and dry-run evidence without silently acquiring external authority.
- Obsidian and GitHub offer explicit, bounded, read-only refresh actions for the configured project overview and local repository. They reject path traversal, bound output and execution time, and do not use the network.
- Settings is a focused sheet that preserves the current workspace. It exposes safe mode, audit-retention preferences, recovery state, and a copyable redacted diagnostic report that excludes message bodies, recipients, private paths, and secrets.
- Navigation keeps bounded screen and thread history. The toolbar Back button, `Command-[`, and the standard macOS mouse Back side button (other mouse button 3) all use the same action; an unhandled side-button event is left available to other responders.

No screen in this build grants provider, repository, account, credential, notification, or physical-device authority merely by being opened. The public repository contains connector protocols, parsers, schemas, and UI—not personal identities, tokens, calendar IDs, cached mailbox content, or schedules. Those values belong only to private Application Support state and the credential owner (`zele`, `gh`, the provider CLI, or macOS). The packaged qualification build uses ad-hoc signatures and identifier requirements so it can run without an Apple signing credential or Keychain prompt. That is suitable for local dogfooding on this Mac, not a production distribution trust policy. See [Personal integrations](PersonalIntegrations.md) for the full boundary.

## Build, install, and verify

```sh
Scripts/build-kaname-desktop.sh
Scripts/install-kaname-desktop.sh
Scripts/verify-kaname-desktop.sh
```

The installed app is `~/Applications/Kaname.app`. The current dogfood bundle is version `0.5.0` (build `7`). Installation also bootstraps the user-scoped `com.cyberlane.kaname.desktop.localcore.service` LaunchAgent. Verification posts a button-3 event only into Kaname's own AppKit event queue to exercise Back without Accessibility permission or global input injection. The build and installer never call `security`, access the login Keychain, enumerate accounts, request Calendar access, or enumerate physical devices.

For a faster development build:

```sh
KANAME_BUILD_CONFIGURATION=debug Scripts/build-kaname-desktop.sh
```

## Removal

Quit Kaname, then unload `com.cyberlane.kaname.desktop.localcore.service` from the current GUI domain. The app, LaunchAgent plist, desktop workspace, and local-core journals can then be reviewed and removed independently; no mobile state is involved.
