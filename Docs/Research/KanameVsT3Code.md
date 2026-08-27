---
title: Kaname vs T3 Code
tags:
  - coding-ade
  - kaname
  - t3-code
  - control-plane
aliases:
  - Kaname T3 comparison
obsidian-sync: Projects/Coding ADE/Research/Kaname vs T3 Code.md
status: proposed
date: 2026-08-27
---

# Kaname vs T3 Code

> [!note] Obsidian sync
> Canonical vault path: `Projects/Coding ADE/Research/Kaname vs T3 Code.md`. Linked from [[Projects/Coding ADE/Overview.md]] and [[Projects/Coding ADE/Research Index.md]].

Both products are **control-plane ADEs**: they orchestrate external provider CLIs rather than implementing native Read/Write/Shell tools. This note inventories Kaname's coding surface, compares it to [T3 Code](https://github.com/pingdotgg/t3code), and records prioritized improvements.

## Architecture

| | Kaname | T3 Code |
|---|--------|---------|
| UI | Swift macOS desktop (primary) | Web + Electron desktop + mobile |
| Execution | Conversation worker + Rust Local Core (Mach XPC) | Node server (`npx t3`) + Effect RPC WebSocket |
| Providers | Codex, Claude, OpenCode | Codex, Claude, Cursor, Grok, OpenCode |
| State | `workspace.json` + worker queues | Event-sourced SQLite projections |

**Philosophy:** Kaname optimizes authority, isolation, and a 7-stage coding workflow. T3 optimizes speed, remote multi-surface control, and git-native iteration.

## Kaname coding inventory

### Agent harness

- Multi-provider orchestration: [`Sources/KanameConversationWorker/main.swift`](../../Sources/KanameConversationWorker/main.swift), [`CodexLiveSession.swift`](../../Sources/KanameConnectivity/CodexLiveSession.swift), [`NativeProviderConversationSession.swift`](../../Sources/KanameConnectivity/NativeProviderConversationSession.swift)
- Cached capability probes: [`ProviderProbe.swift`](../../Sources/KanameConnectivity/ProviderProbe.swift)
- 7-stage pipeline: Discuss → Plan → Approve → Implement → Review changes → Review evidence → Update knowledge ([`DesktopCyclicSelection.swift`](../../Sources/KanameDesktop/DesktopCyclicSelection.swift))
- Provider comparison with frozen brief digest ([`DesktopAppModel.swift`](../../Sources/KanameDesktop/DesktopAppModel.swift))

### Browser

**No coding browser.** Codex MCP/apps blocked via [`CodexMCPIsolation.swift`](../../Sources/KanameConnectivity/CodexMCPIsolation.swift). WebKit only for isolated Gmail HTML.

### Tools

- Provider-native tools delegated to CLIs; Kaname streams activity and approvals
- Local subprocess: git, rg, obsidian, gh ([`LocalProcess.swift`](../../Sources/KanameConnectivity/LocalProcess.swift))
- **No interactive terminal** in coding threads
- **No Kaname MCP router** for coding turns (by design)

### Skills

- Workspace catalog in `workspace.json`; project `skillIDs` binding
- Filesystem discovery: `~/.codex/skills`, `~/.agents/skills` ([`CodingVerticalSlice.swift`](../../Sources/KanameConnectivity/CodingVerticalSlice.swift))
- **Improvement (implemented):** [`SkillRegistryLoader.swift`](../../Sources/KanameConnectivity/SkillRegistryLoader.swift) loads `SKILL.md` bodies; composer `$` picker in [`DesktopComposerSkillPicker.swift`](../../Sources/KanameDesktop/DesktopComposerSkillPicker.swift)

### Worktrees & git

- Managed worktrees under Application Support; approval-gated lifecycle
- Signed local commits; Mori quality gates ([`DesktopCodingControlModel.swift`](../../Sources/KanameDesktop/DesktopCodingControlModel.swift))
- **Gap:** no per-turn checkpoint refs / revert (see [[Docs/CodingGitCheckpointsDesign.md]])

### Search

- Command Center (⌘K) over local snapshot corpus ([`DesktopGlobalSearch.swift`](../../Sources/KanameDesktop/DesktopGlobalSearch.swift))
- **Improvement (implemented):** FTS over thread messages and worktree diffs ([`DesktopGlobalSearchFTS.swift`](../../Sources/KanameDesktop/DesktopGlobalSearchFTS.swift))

## T3 Code reference features

Source: [pingdotgg/t3code](https://github.com/pingdotgg/t3code)

| Feature | T3 reference |
|---------|--------------|
| Preview webview | [`packages/contracts/src/preview.ts`](https://github.com/pingdotgg/t3code/blob/main/packages/contracts/src/preview.ts) |
| Preview MCP tools | [`apps/server/src/mcp/toolkits/preview/tools.ts`](https://github.com/pingdotgg/t3code/blob/main/apps/server/src/mcp/toolkits/preview/tools.ts) |
| Terminals | [`packages/contracts/src/terminal.ts`](https://github.com/pingdotgg/t3code/blob/main/packages/contracts/src/terminal.ts) |
| Git checkpoints | `thread.checkpoint.revert` in [`orchestration.ts`](https://github.com/pingdotgg/t3code/blob/main/packages/contracts/src/orchestration.ts) |
| Claude skills | [`ClaudeSkills.ts`](https://github.com/pingdotgg/t3code/blob/main/apps/server/src/provider/Drivers/ClaudeSkills.ts) |
| Remote access | [`docs/user/remote-access.md`](https://github.com/pingdotgg/t3code/blob/main/docs/user/remote-access.md) |
| Project scripts | [`docs/user/project-settings.md`](https://github.com/pingdotgg/t3code/blob/main/docs/user/project-settings.md) |

## Comparison matrix

| Capability | Kaname | T3 | Gap |
|------------|--------|-----|-----|
| Coding browser | None | Desktop webview + MCP | High |
| Terminal attach | Subprocess only | Full PTY | High |
| Git checkpoint revert | Worktree lifecycle | Per-turn hidden refs | High |
| Skills in context | Loaded (post-spike) | Claude `$` picker | Medium |
| Remote coding | Kaname Link (early) | Mature web/mobile | High |
| Staged workflow | 7-stage | Plan mode only | Kaname ahead |
| Signed approvals | Rust Local Core | OAuth scopes | Kaname ahead |
| Obsidian / knowledge | Native | None | Kaname ahead |

## Improvement plan (repo docs)

1. [[Docs/CodingTerminalAttachDesign.md]] — per-thread terminal attach
2. [[Docs/CodingGitCheckpointsDesign.md]] — hidden-ref checkpoints + revert
3. [[Docs/CodingPreviewAndMCPBridgeADR.md]] — preview panel + curated MCP bridge
4. [[Docs/CodingProjectScriptsSchema.md]] — project script manifest
5. [[Docs/CodingProviderExpansionEvaluation.md]] — Cursor CLI + Grok Build probes

## What not to copy from T3

- 7-stage workflow and knowledge lane
- Rust Local Core approval journal
- MCP fail-closed default (evolve to curated bridge, not open import)
- Mori / commit-ready quality gates
- Stable/candidate/dev channel isolation
