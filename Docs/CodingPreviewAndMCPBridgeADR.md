# ADR: Desktop preview panel and curated Kaname MCP bridge

Status: proposed · 2026-08-27

## Context

Kaname **blocks** Codex MCP and apps during coding turns ([`CodexMCPIsolation.swift`](../Sources/KanameConnectivity/CodexMCPIsolation.swift)) to prevent harness credential leakage and unreviewed tool surfaces. T3 Code takes the opposite approach for preview: it hosts an HTTP MCP server and injects it into provider sessions ([`McpHttpServer.ts`](https://github.com/pingdotgg/t3code/blob/main/apps/server/src/mcp/McpHttpServer.ts), [`preview/tools.ts`](https://github.com/pingdotgg/t3code/blob/main/apps/server/src/mcp/toolkits/preview/tools.ts)).

Web/UI coding tasks need visual verification. A blanket deny leaves Kaname at a practical disadvantage versus T3 for frontend work.

## Decision

Adopt a **curated Kaname MCP bridge** and **desktop-only WKWebView preview panel**, both gated by explicit inbox approval per thread/session. Continue blocking arbitrary user-configured MCP servers unless separately approved at project scope.

### 1. Preview panel (desktop-only)

- WKWebView per coding thread, multi-tab metadata in workspace snapshot.
- RPC surface internal to Kaname (Swift), modeled after T3's [`preview.ts`](https://github.com/pingdotgg/t3code/blob/main/packages/contracts/src/preview.ts): open, navigate, resize, refresh, close, status.
- Local dev server discovery: configured URLs + bounded localhost port scan linked to terminal PID (depends on [[Docs/CodingTerminalAttachDesign.md]]).
- No remote content by default; user must navigate explicitly.

### 2. Curated MCP server

- Kaname hosts a localhost MCP HTTP endpoint exporting **only**:
  - Preview automation tools (snapshot, click, type, scroll, evaluate, wait)
  - Read-only Obsidian search/read (scoped vault paths)
  - Structured repo search (`rg` wrapper, same bounds as coding context)
- **Not exported:** write tools, arbitrary shell, user MCP passthrough.

### 3. Injection policy

| State | Codex MCP |
|-------|-----------|
| Default coding turn | Blocked (current behavior) |
| Plan turn | Blocked |
| Implementation turn, no preview grant | Blocked |
| Implementation turn + preview approval | Inject `kaname-preview` MCP only |
| Project-level MCP allowlist (future) | Additional curated servers |

Approval record fields:

- `actionKind`: `coding.preview_mcp_grant`
- `exactTarget`: thread ID + worktree path + tool allowlist digest
- `expiry`: 15 minutes (match Codex write grants)
- Journal fingerprint via Local Core (same as `codex.workspace_write`)

### 4. Environment isolation

- Continue stripping `T3_*` and foreign MCP env vars from provider children.
- Issue per-session bearer token for Kaname MCP; token invalid after turn completes or approval expires.
- Observe MCP startup events; abort if undeclared servers appear.

## Consequences

**Positive**

- Parity with T3 for agent-driven browser verification without opening all MCP config.
- Preview and automation remain auditable and approval-bound.

**Negative**

- Engineering cost: MCP HTTP server in Swift or Rust sidecar, desktop webview broker.
- Two MCP policies to test (blocked vs curated).

**Risks**

- Curated bridge expands attack surface if approval UI is bypassed — mitigate with Local Core fingerprint matching and fail-closed attestation.

## Alternatives considered

1. **Remove MCP block entirely** — rejected; violates Kaname authority model.
2. **External browser only** — rejected; no agent automation path.
3. **Reuse T3 MCP server** — rejected; couples to Node runtime and T3 env vars.

## Implementation sequence

1. Preview panel UI + internal RPC (no MCP).
2. Local Core approval kind for preview MCP grant.
3. Kaname MCP HTTP server + Codex injection path in `CodexLiveSession`.
4. Claude/OpenCode injection when drivers support config override.

## References

- [`CodexMCPIsolation.swift`](../Sources/KanameConnectivity/CodexMCPIsolation.swift)
- T3 preview automation: https://github.com/pingdotgg/t3code/blob/main/packages/contracts/src/previewAutomation.ts
- Comparison: [`Docs/Research/KanameVsT3Code.md`](Research/KanameVsT3Code.md)
