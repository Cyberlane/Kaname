# Scoped workflow storage

WFP-005B adds durable logical ownership above the WFP-005A content-addressed object store. Physical deduplication never grants access: every read, list, usage query, and write first resolves a registered namespace and compares it with a trusted runtime access context.

## Scope ownership

| Product scope | Durable owner | Access requirement |
|---|---|---|
| Job storage | `run` identity plus installation binding | Exact run and installation |
| Case storage | case identity plus installation binding | Exact case and installation |
| Workflow storage | stable installation identity | Exact installation; portable package or workflow identity is insufficient |
| Account-binding storage | configured account-binding identity | Binding must be present in the host-authorized account set |

Job access deliberately contains no node or attempt restriction: every node in the same run can share the job namespace. A different run cannot read the handle even if it guesses the entry, version, or logical key. Case and job namespaces remain bound to their workflow installation, so another installation of the same package cannot share them accidentally.

## Durable catalog

`Objects/workflow-storage.sqlite` is private, schema-versioned, checksum-verified, foreign-key checked, and opened with full SQLite synchronization. Its schema contains:

- immutable namespace identity and persisted item/byte/value quotas;
- one stable entry per `(scope, owner, logical key)`;
- typed immutable versions with inline canonical JSON or a verified object digest;
- one scoped blob reference for every object-backed version;
- exact command request digests and canonical response receipts for idempotent retry.

An entry's schema reference, media type, and classification are stable. Updating a value requires the exact current revision, appends revision `n + 1`, and atomically advances the current pointer. Historical handles continue to resolve after later writes. Reusing a command identity with changed input or reusing an entry while changing its type contract fails closed.

## Values and handles

Canonical JSON is limited to 64 KiB and must arrive in its exact RFC 8785 form. Larger values and files must already exist as a verified WFP-005A object. Scoped storage verifies the digest and byte count before committing a reference.

Callers receive a version handle containing scope kind, logical key, version/revision, schema/media/classification metadata, size, and checksum. It contains no host path. Byte reads are mediated through `copy_value`, which reauthorizes the namespace before copying either inline JSON or verified CAS bytes into the caller's bounded sink.

## Quotas and integrity

Namespace quotas count logical entries and every retained immutable version. Reusing one physical object in two scopes consumes physical storage once but consumes the declared logical byte allowance in each scope. Value, item, and total-byte checks run inside the same immediate transaction as entry/version/reference creation, so rejection leaves no partial row or current-pointer change.

Integrity verification checks SQLite, migrations, current-version pointers, object-reference parity, canonical inline JSON and checksum, and every referenced object manifest and checksum. Missing or altered physical bytes therefore make the scoped store visibly unhealthy rather than producing an empty value.

## Qualification

`workflow_storage_tests.rs` proves job/case/installation/account isolation, same-job sharing, cross-run and cross-installation denial, optimistic conflict behavior, command idempotency, persisted current and historical versions, mediated inline and object reads, one physical object with two isolated logical references, all namespace quota classes, object metadata mismatch, namespace identity immutability, bounded lists, newer-schema rejection, corrupt-current-pointer detection, and absence of host paths in serialized handles and receipts.
