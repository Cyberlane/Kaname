# Personal integrations

Kaname's live integrations are designed for one person's private desktop installation. The public repository contains reusable adapter code and test fixtures only; it must not contain real account identities, tokens, calendar identifiers, mailbox content, provider conversations, or schedules.

## Credential ownership

Kaname uses provider-native authorization boundaries for desktop integrations:

- Gmail and Google Calendar use Kaname's native OAuth 2.0 desktop flow and direct Google APIs. The personal build receives its Google Desktop client registration from private build configuration. **Connect Google** then opens the system browser, asks for permission, and returns to Kaname through a local callback. Provisioned builds store refresh tokens in the data-protection Keychain with device-only accessibility. The ad-hoc local dogfood build cannot receive Apple-authorized Keychain entitlements, so only `errSecMissingEntitlement` falls back to the encrypted traditional macOS Keychain with authentication UI disabled. Tokens are never written to ordinary files or committed.
- GitHub uses the identity and host currently available to `gh`.
- Codex, Claude, and OpenCode launch their native local adapters and retain their own authentication state.
- Apple Calendar uses EventKit. Merely opening Kaname or Settings does not request access; the user must choose **Request access** in Personal integrations.

Google authorization uses a PKCE-protected loopback callback on `127.0.0.1`, requests offline access, and grants only identity, Gmail read-only, and Calendar read-only scopes. The browser receives a success response only after Kaname has exchanged the code, loaded the Google identity, saved the refresh token, and updated its private account index. Kaname never asks for a Google password. If another native tool's session is missing or expired, Kaname reports that state and asks the user to repair it in that tool.

## Private state

Account references, enabled calendars, exact draft/proposal sources, personal content, and schedule configuration are written beneath `~/Library/Application Support/Kaname/Desktop`. Non-secret Google account metadata lives beneath `~/Library/Application Support/Kaname/Google`. Cached coding-provider health lives beneath `~/Library/Application Support/Kaname/Connectivity`. These directories and files use owner-only filesystem modes. Redacted diagnostics contain counts and health states rather than identities, content, tokens, or private paths.

Settings changes persist automatically; there is no Save or Revert step. Kaname loads cached coding-provider health immediately, refreshes it on launch and every five minutes, and checks connected integrations on launch and every fifteen minutes. A manual **Refresh all status** action is also available. Background Google checks use non-interactive Keychain access, so they fail closed instead of presenting a credential dialog. Automatic checks never open a browser or request Apple Calendar permission. **Connect Google** and **Request access** remain explicit user actions.

## Multiple accounts and calendars

Each Google authorization adds another account to Kaname's local account index, so four Gmail accounts can be active simultaneously. A refresh addresses every selected account directly, mail results retain their source identity, and email drafts retain an exact account reference.

Google and Apple calendar sources appear together in Settings. Each calendar can be enabled independently. Event proposals retain both the owning account and the exact calendar source, preventing an approval from drifting to a different calendar.

## Native Google setup

Create an OAuth client with the **Desktop app** application type in a Google Cloud project where the Gmail API and Google Calendar API are enabled. Keep the downloaded JSON outside the repository at:

```text
~/Library/Application Support/Kaname/Build/google-oauth-client.json
```

The desktop packaging script reads that private file and embeds the registration in the personal app bundle. `KANAME_GOOGLE_OAUTH_CONFIG` can point to a different private JSON path; `KANAME_GOOGLE_OAUTH_CLIENT_ID` and `KANAME_GOOGLE_OAUTH_CLIENT_SECRET` are also supported for ephemeral private builds. None of those values is written to the repository. Once the personal build is installed, choose **Connect Google** once for each account. There is no client-file import in Settings.

The repository contains the reusable OAuth, API, and UI implementation, but no client JSON, client identifier, account identity, access token, refresh token, mailbox result, or calendar identifier.

## Time-zone semantics

New schedule and event forms default to the IANA time zone saved in Settings, initially the Mac's zone at setup. Kaname persists the recurrence intent with that anchor zone and derives execution instants from it. It does not treat the current travel zone as a replacement schedule.

For example, a weekly 09:00 schedule anchored to `Asia/Tokyo` remains 09:00 in Japan after the Mac travels to Germany. The UI displays the pinned Japan time and, when different, the equivalent time in the viewer's current zone. Using an IANA zone rather than a fixed UTC offset preserves the anchor zone's daylight-saving rules.

## Consequential actions

Reading bounded metadata or inbox results is distinct from changing an external system. Sending mail, creating or changing an event, pushing GitHub state, or granting provider write access requires an exact target, an explicit in-app approval, and post-action reconciliation. Local drafts and plan-mode provider discussions do not imply that authority.
