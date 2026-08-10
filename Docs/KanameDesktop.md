# Kaname desktop dogfood build

Kaname is a local-first macOS workspace for project-aware agent threads, attention triage, review evidence, and bounded execution surfaces. The desktop build is the primary dogfood client; the physical iPhone remains a separate qualification lane.

## What is usable

- Home, Threads, Inbox, Projects, Devices & Remote, Codex Workspace, Local Core, and Settings are integrated in one three-column desktop shell.
- Projects, threads, messages, attention, archive state, and preferences survive restart in `~/Library/Application Support/Kaname/Desktop/workspace.json`.
- The workspace directory is mode `0700` and its state file is mode `0600`.
- Local Core replays the deterministic F-01 through F-14 corpus through a user-scoped Mach service and persists its journals beneath `~/Library/Application Support/Kaname/LocalCore/journal`.
- The Codex Workspace keeps inspection separate from planning, approval, implementation, evidence review, acceptance, and knowledge updates.
- Navigation keeps bounded screen and thread history. The toolbar Back button, `Command-[`, and the standard macOS mouse Back side button (other mouse button 3) all use the same action; an unhandled side-button event is left available to other responders.

No screen in this build grants provider, repository, account, credential, notification, or physical-device authority merely by being opened. The packaged qualification build uses ad-hoc signatures and identifier requirements so it can run without an Apple signing credential or Keychain prompt. That is suitable for local dogfooding on this Mac, not a production distribution trust policy.

## Build, install, and verify

```sh
Scripts/build-kaname-desktop.sh
Scripts/install-kaname-desktop.sh
Scripts/verify-kaname-desktop.sh
```

The installed app is `~/Applications/Kaname.app`. Installation also bootstraps the user-scoped `com.cyberlane.kaname.desktop.localcore.service` LaunchAgent. Verification posts a button-3 event only into Kaname's own AppKit event queue to exercise Back without Accessibility permission or global input injection. The build and installer never call `security`, access the login Keychain, or enumerate physical devices.

For a faster development build:

```sh
KANAME_BUILD_CONFIGURATION=debug Scripts/build-kaname-desktop.sh
```

## Removal

Quit Kaname, then unload `com.cyberlane.kaname.desktop.localcore.service` from the current GUI domain. The app, LaunchAgent plist, desktop workspace, and local-core journals can then be reviewed and removed independently; no mobile state is involved.
