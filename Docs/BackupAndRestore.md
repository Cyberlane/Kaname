# Automatic backup and restore

Kaname can create opt-in encrypted backup generations in a local folder, Cloudflare R2, or an S3-compatible object store. Automatic backup is off by default and cannot be enabled until encryption credentials are saved in the device-only macOS Keychain and the exact destination has passed a connection test.

## Generation boundary

A generation uses the existing verified `.kanamebackup` recovery contract. Kaname takes an exclusive nonblocking recovery lock, waits for provider work to become quiescent, and captures the workspace, local-core journals, conversation-service queues, and workflow-installation artifacts together. It never treats a live SQLite file copied independently as application truth.

The verified bundle is packed and encrypted locally with AES-256-GCM. Its key is derived from the user's passphrase with PBKDF2-HMAC-SHA256 and a random salt. Only the encrypted object is sent to the destination. Upload is followed by an object metadata check; download requires the recorded SHA-256 metadata and then verifies authenticated encryption, every packed file digest, and the recovery manifest.

Credentials and the passphrase stay in this Mac's device-only Keychain. Workspace state and remote objects never contain them. Provider-owned mail, repository contents, vault contents, and credentials are outside the recovery boundary. Keep the passphrase in a separate password manager: loss of both the Mac and passphrase makes remote generations unrecoverable.

## Destinations

- **Local folder** keeps encrypted generations under the configured private prefix and rejects symbolic-link traversal.
- **Cloudflare R2** uses the account S3 endpoint (`https://<account-id>.r2.cloudflarestorage.com`) and signing region `auto`.
- **S3-compatible storage** uses an explicit HTTPS endpoint, bucket, region, and access-key pair.

Remote list operations follow continuation tokens, so retention remains complete for long-running hourly schedules. Kaname retains at least the three newest generations and removes only expired objects beneath its configured prefix.

Litestream is not the primary backup engine. It is excellent for continuously replicating an isolated SQLite database, but Kaname's recoverable state spans JSON workspace state, SQLite/runtime journals, queue files, and workflow artifacts. A Kaname-owned generation gives those components one recovery point and one verification contract. Litestream can remain a future advanced transport for a consolidated database without defining product-level recovery semantics.

## UX and observability

**Settings → Backup & Restore** keeps setup progressive: destination first, secrets second, then schedule and recovery status. The page shows whether the exact destination is verified, last attempt, last success, last full verification, next scheduled run, encrypted size, and one bounded failure summary. Routine success stays quiet; failures become visible without adding per-object log noise.

**Verify latest** downloads, decrypts, and fully validates a generation without touching live state. **Download latest** produces a verified local `.kanamebackup`; restore remains a separate, explicit Recovery Center action with staged validation and rollback handling.
