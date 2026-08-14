# Workflow object storage

WFP-005A adds the physical byte layer for workflow values and files. It is a private content-addressed store; logical job, case, workflow-installation, and account-binding ownership is intentionally not part of this ticket.

## Stable layout

The host supplies only the Kaname Application Support root. `open_workflow_object_store` owns this structure beneath it:

```text
Objects/
  sha256/<first-two-hex>/<full-sha256>
  Manifests/sha256/<first-two-hex>/<full-sha256>.json
  Staging/<write-id>/
  Recovery/Staging/
  Recovery/Objects/
```

No public response or workflow-facing type contains one of these paths. A completed object is identified by its lowercase SHA-256 digest and a canonical, closed manifest containing format version, algorithm, digest, and byte count. Media type, schema, ownership, retention, and artifact role belong to the scoped reference layer in WFP-005B.

## Write transaction

1. A validated write identity creates one private staging directory and a new data file.
2. `write_chunk` hashes and writes each chunk while enforcing the per-object byte limit.
3. Finalization flushes and fsyncs the data and staging directory.
4. An optional expected digest is compared before promotion. A mismatch moves the staged evidence to Recovery.
5. An existing valid object with the same digest is reused and does not consume quota twice.
6. Otherwise, the complete current inventory is verified before total-byte and object-count quota admission.
7. A canonical manifest is staged and fsynced. Data and manifest are renamed into their digest shards, each parent directory is fsynced, and both files become read-only.
8. The promoted pair is read back and verified before the staging directory is removed.

Only the Rust local core owns finalization. Its command admission remains serialized; scoped reference transactions and their database-backed ownership arrive in WFP-005B.

## Recovery and garbage collection

An interrupted staging directory is moved intact into `Recovery/Staging`. An object/manifest pair that is missing, malformed, non-canonical, incorrectly sharded, or checksum-invalid is moved into `Recovery/Objects`. Recovery never silently adopts or deletes partial bytes.

Garbage collection accepts a complete set of live digests from the future scoped-reference layer. It validates the entire object inventory and proves every claimed live digest exists before moving anything. Unreferenced pairs are quarantined rather than destroyed, while live or shared bytes remain in place. Destructive expiry of quarantined evidence is a separate retention operation.

## Qualification

`workflow_object_store_tests.rs` covers all three interruption boundaries, checksum mismatch, content deduplication, a streamed 5 MiB object, per-object/total/count quotas, missing-live-reference fail-closed behavior, garbage-collection safety, read-back, tamper detection, and recovery quarantine.
