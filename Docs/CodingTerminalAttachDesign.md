# Coding terminal attach — design

Status: proposed · 2026-08-27

## Problem

Kaname orchestrates bounded subprocesses (`git`, `rg`, `swift test`) but offers no attachable shell in coding threads. T3 Code runs PTY terminals on the server and lets the composer attach terminal output as context ([terminal.ts](https://github.com/pingdotgg/t3code/blob/main/packages/contracts/src/terminal.ts)).

Agents and humans lose shared context when commands run only inside provider CLIs.

## Goals

- One or more labeled terminals per coding thread (optionally scoped to an active worktree cwd).
- Bounded scrollback persisted in workspace snapshot metadata.
- Composer can attach terminal excerpt as untrusted context (same injection warnings as Obsidian excerpts).
- Terminal subprocess PID linked to dev-server discovery for a future preview panel.

## Non-goals

- Workflow automation terminal nodes (already exist in the workflow graph).
- Remote terminal streaming over Kaname Link in v1.
- Granting network or write authority via terminal attach.

## Model

```swift
public struct DesktopCodingTerminalRecord: Codable, Equatable, Identifiable, Sendable {
    public let id: String           // e.g. term-1
    public var threadID: String
    public var worktreeID: String?
    public var label: String
    public var cwd: String
    public var scrollbackDigest: String
    public var scrollbackExcerpt: String  // bounded, e.g. 16 KiB
    public var activeCommand: String?
    public var state: DesktopCodingTerminalState
    public var updatedAtUnixMillis: Int64
}
```

States: `idle`, `running`, `exited`, `closed`.

## Authority

- Opening a terminal requires no inbox approval (read-only observation of local shell).
- Attaching scrollback to a provider turn includes SHA256 digest + untrusted-data warning in the prompt builder.
- Running commands inside the Kaname-hosted PTY is **human-only** in v1; providers continue to use their own shell tools.

## Execution boundary

- PTY lives in `KanameConversationWorker` or a dedicated `KanameTerminalHost` helper process (same pattern as conversation worker isolation).
- UI streams via file-backed or XPC channel; no raw socket from SwiftUI to shell.
- Scrollback capped (default 256 KiB total, 16 KiB excerpt for prompts).

## UI

- Bottom panel tab **Terminal** on coding threads (mirrors T3 split layout without replacing Kaname's 3-column shell).
- Composer `$` remains skills; `@` mentions files (future); **Attach terminal** chip when a terminal has fresh output.

## Persistence

- Store terminal metadata + bounded excerpt in `snapshot.operations.codingTerminals`.
- Full scrollback optional encrypted sidecar under Application Support keyed by terminal ID.

## Phased delivery

1. **Phase A:** read-only attach of last N lines from a single default terminal (`term-1`).
2. **Phase B:** multi-terminal, resize, restart, worktree cwd binding.
3. **Phase C:** port scanner hooks terminal PID → preview URL proposals.

## References

- T3 terminal RPC: https://github.com/pingdotgg/t3code/blob/main/packages/contracts/src/terminal.ts
- Kaname subprocess wrapper: [`Sources/KanameConnectivity/LocalProcess.swift`](../Sources/KanameConnectivity/LocalProcess.swift)
- Comparison note: [`Docs/Research/KanameVsT3Code.md`](Research/KanameVsT3Code.md)
