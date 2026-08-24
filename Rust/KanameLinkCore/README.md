# Kaname Link portable core

This crate is the portable, authority-limited Kaname Link endpoint. It owns only Link enrollment, device approval/revocation, one explicitly shared space, text messages, and receipts. It has no Kaname conversation, project, workspace, provider, tool, filesystem, mobile-device, or workflow authority.

## Transport and trust

- Enrollment uses `Noise_IKpsk1_25519_ChaChaPoly_BLAKE2s`. The 256-bit, single-use invite PSK and the pinned host static public key both participate in the handshake.
- Approved sessions use a fresh `Noise_IK_25519_ChaChaPoly_BLAKE2s` handshake. The gateway authorizes the authenticated client static public key against one approved device and one space.
- The HTTP gateway binds only to a loopback address. A separately managed Cloudflare Tunnel can publish that loopback origin; the core never opens a public listener.
- Non-loopback URLs require HTTPS. Loopback HTTP exists only for local integration and tunnel-origin use.
- SQLite stores public Link data, digests, cursors, and opaque secret references. Host/client static private keys and live invite PSKs use the native OS credential store through `keyring` 4.1.6: macOS Keychain, Windows Credential Manager, or Linux Secret Service. There is no production plaintext fallback, and startup fails closed if the native store is unavailable.
- An invite is consumed in SQLite before credential cleanup. If cleanup fails, it remains unusable and its retained reference is retried on the next gateway open. Expired invite secrets are also removed.

The current transport is bounded one-request HTTP, not WebSocket. Noise provides application-layer authentication and encryption; HTTPS still protects routing metadata and supplies the normal public-server boundary.

## Processes and state roots

```text
kaname-link-gateway serve --bind 127.0.0.1:43110 [--state-root PATH]
kaname-link-gateway admin [--json-stdio] [--state-root PATH]
kaname-link-client rpc [--state-root PATH]
```

`admin` and `rpc` read one JSON object of at most 64 KiB from stdin, write one JSON object plus a newline to stdout, and never accept secrets in argv. `--state-root` is an optional test/operations override. Defaults are deterministic:

| Platform | Client state | Gateway state |
| --- | --- | --- |
| macOS | `~/Library/Application Support/Kaname Link/client` | `~/Library/Application Support/Kaname Link/gateway` |
| Windows | `%LOCALAPPDATA%\Kaname Link\client` | `%LOCALAPPDATA%\Kaname Link\gateway` |
| Linux | `${XDG_STATE_HOME:-~/.local/state}/kaname-link/client` | `${XDG_STATE_HOME:-~/.local/state}/kaname-link/gateway` |

Linux production use requires an available Secret Service session. A missing or locked native credential store is an error, never a request to fall back to SQLite.

## Canonical JSON-stdio contract

Both processes accept this envelope. `requestID` is canonical; `requestId` is accepted as a compatibility alias on input.

```json
{
  "schemaVersion": 1,
  "requestID": "request-2db658e3",
  "operation": "snapshot",
  "payload": {}
}
```

Success responses contain `result`. Client responses also contain a UI-shaped top-level `snapshot` compatible with the macOS, Windows, and Linux Link shells.

```json
{
  "schemaVersion": 1,
  "requestID": "request-2db658e3",
  "ok": true,
  "result": {},
  "snapshot": {
    "connection": "enrollmentRequired",
    "lastSyncUnixMillis": null,
    "spaces": [],
    "diagnosticCode": null,
    "verificationCode": null
  }
}
```

Failures expose the same stable code in both the shell-friendly `errorCode` field and the structured `error.code` field.

```json
{
  "schemaVersion": 1,
  "requestID": "request-2db658e3",
  "ok": false,
  "errorCode": "invalid_payload",
  "error": { "code": "invalid_payload" }
}
```

Client operations:

| Operation | Payload | Result |
| --- | --- | --- |
| `snapshot` or `uiSnapshot` | `{}` | local core snapshot; enrolled clients also attempt one bounded sync |
| `enroll` | `{ "invite": INVITE_ARTIFACT, "displayName": "..." }` | pending enrollment |
| `sendMessage` or `send` | `{ "spaceID": "...", "discussionID": "discussion-main", "body": "...", "messageID": "..." }` | exact queued/host-received receipt; IDs are optional where noted |
| `sync` | `{}` | delivered receipts plus the updated snapshot |

Gateway admin operations:

| Operation | Payload | Result |
| --- | --- | --- |
| `status` | `{}` | gateway counts and host-key fingerprint |
| `spaces` | `{}` | scoped spaces |
| `hostSnapshot` | `{}` | bounded status, spaces, pending devices, and external inbox |
| `createInvite` | `{ "spaceID": "...", "spaceName": "...", "gatewayUrl": "https://...", "expiresInSeconds": 3600 }` | the only response that intentionally contains an invite secret |
| `pending` | `{ "spaceID": "..." }` | pending devices; `spaceID` is optional |
| `approve` | `{ "deviceID": "..." }` | approved device |
| `deny` or `revoke` | `{ "deviceID": "..." }` | terminally revoked device |
| `inbox` | `{ "spaceID": "...", "afterPosition": 0, "limit": 50 }` | collaborator messages |
| `publish` or `send` | `{ "spaceID": "...", "body": "...", "messageID": "..." }` | host-published message receipt |

Unknown envelope or payload fields, unsupported schema versions, oversized bodies, cross-space identifiers, and invalid state transitions fail closed.

## Verification

```text
cargo fmt --manifest-path Rust/KanameLinkCore/Cargo.toml -- --check
cargo clippy --manifest-path Rust/KanameLinkCore/Cargo.toml --locked --all-targets -- -D warnings
cargo test --manifest-path Rust/KanameLinkCore/Cargo.toml --locked
```

The local integration suite injects an in-memory test-only secret backend. It proves enrollment, pending approval, exact replay, one-space messaging, host replies, receipt transitions, invite replay rejection, revocation/key deletion, cleanup rollback, response-size bounds, database permissions, and loopback-only binding without writing test secrets to the user's credential store.

Cross-compilation alone does not qualify native credential-store behavior, installers, code signing/notarization, Linux desktop integration, Windows service behavior, or live Cloudflare routing. Those require the platform CI/release and tunnel acceptance gates outside this crate.
