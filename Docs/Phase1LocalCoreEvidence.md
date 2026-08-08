# Phase 1 local-core evidence

Status: gate candidate evaluated on 2026-08-08. This document records only provider-free local evidence. It does not authorize a real provider, credentials, repository/worktree access, external accounts, notifications, or phone synchronization.

## Reproduction

```sh
Scripts/check-schema.sh
Scripts/test-schema-compatibility.sh
Scripts/generate-protocol-fixtures.sh check
Scripts/generate-corpus-manifest.py check
cargo test --manifest-path Rust/KanameCore/Cargo.toml
swift test
Scripts/run-local-core-prototype.sh
Scripts/measure-local-core-xpc.sh
Rust/KanameCore/target/release/kaname-phase1-measure --repetitions 25
```

`run-local-core-prototype.sh` builds a local, signed development app and signed Mach service from the current checkout. It derives its code-signing requirement from the selected local Apple Development identity, installs a per-user launchd job, and passes only bounded `Data` over XPC. Each F fixture has a separate ignored SQLite journal beneath `.build/localcore-journal/`; the service owns the Rust subprocess and the client never invokes it directly.

## Gate results

| Gate | Result | Evidence |
|---|---|---|
| Generated protocol compatibility | pass | Swift/Rust vectors, generated-file check, and intentional breaking-edit rejection pass. |
| Durable recovery and duplicate safety | pass | Journal tests cover pre-commit crash, duplicate command/event handling, tamper-proof cursors, corrupt snapshots, backup/read-only operation, and reopening the same projection. |
| Fake corpus | pass | F-01 through F-14 and deterministic S-01 through S-04 pass in Rust; the native local workspace replays F-01 through F-14 through the signed Mach service. |
| Thread and Inbox consistency | pass | `ProjectProjection` derives thread state and Inbox attention grouping in one rebuild; its restart test passes. The native local workspace presents Dashboard, Threads, and Inbox from one `runs` collection. |
| Approval, queue, scope, and notification policy | pass | Policy tests cover stale approvals, queue revision conflicts, duplicate notification receipts, idempotent queue admission, and scope/egress denial before fake dispatch. |
| Native restart/replay | pass | F-01 was run through the app, the local service was restarted, and the app replayed the persisted F-01 journal as accepted/none/ready with nine events and one fake effect. The persisted-core test independently reopens the same SQLite fixture journal and verifies the same result. |
| Live provider and external authority | not-run by design | Phase 1 does not start a provider, use credentials, read a repository or vault, contact an account, deliver notifications, or synchronize a phone. |
| Full UI frame and cold-launch profiling | not-run | The local workspace performs its XPC work from an async task and has manual accessibility-tree verification, but an Instruments frame trace is intentionally deferred to release packaging work. This does not change the measured core/XPC numbers below. |

## Measured results

Release Rust measurement: 25 repetitions; macOS 26.6; `Mac16,12`; arm64; AC attached at 80%; Rust 1.97.1. The corpus identity is encoded in the measurement output: S-01 (500 events) `cf80d485…f53aae`, S-02 (10,000) `ddeaf90a…77111b`, and S-03 (100,000) `e31357b6…730bcf`.

| Measurement | p50 | p95 | p99 | Target | Result |
|---|---:|---:|---:|---:|---|
| Rust command journal acceptance | 0.008 ms | 0.010 ms | 0.017 ms | 100 ms | pass (core-only boundary) |
| Replay 500 events | 0.267 ms | 0.278 ms | 0.345 ms | 200 ms | pass |
| Rebuild one 10,000-event Thread | 5.483 ms | 5.552 ms | 5.637 ms | 1 s | pass |
| Rebuild selected 100,000-event Project | 65.904 ms | 66.719 ms | 66.844 ms | 5 s | pass |
| Snapshot read and validation | 0.003 ms | 0.006 ms | 0.021 ms | 250 ms | pass |

Authenticated XPC F-01 replay: 25 repetitions, signed native client → signed local Mach service → persisted Rust journal/corpus. p50 **9.231 ms**, p95 **12.471 ms**, p99 **35.949 ms**, zero failures. This is a bounded end-to-end local fixture measurement; it includes the fake scenario replay and is below the 100 ms local-command budget, but it is not a substitute for future foreground-frame tracing.

## Remaining boundary

The next phase still needs explicit authorization before any real provider, account, credential, repository/worktree, integration, notification delivery, or phone work. This evidence deliberately does not infer those permissions.
