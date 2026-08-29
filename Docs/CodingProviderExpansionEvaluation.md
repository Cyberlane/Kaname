# Provider expansion evaluation: Cursor CLI and Grok Build

Status: implemented · 2026-08-27 · **Probes + session adapters**

## Summary

T3 Code ships five built-in drivers ([`builtInDrivers.ts`](https://github.com/pingdotgg/t3code/blob/main/apps/server/src/provider/builtInDrivers.ts)): Codex, Claude, Cursor (`cursor-agent`), Grok (`grok`), OpenCode. Kaname currently supports three. This evaluation adds **capability probes** for Cursor CLI and Grok Build following the existing T3-style probe pattern.

Session adapters (conversation turns) are **out of scope** for this spike; probes enable Settings health display and future wiring.

## Cursor CLI (`cursorAgent`)

| Item | Value |
|------|-------|
| Driver kind | `cursorAgent` |
| Executable | `cursor-agent` (override via probe config) |
| Probe | `cursor-agent --version` |
| Auth check | `--version` only; auth reported `unknown` (no prompt) |
| T3 adapter | Spawns `cursor-agent` with login via `agent login` |
| Kaname session | **Not implemented** — requires stream-json contract review |

**Implementation:** [`ProviderVersionCapabilityProbe.swift`](../Sources/KanameConnectivity/ProviderVersionCapabilityProbe.swift) (`CursorCapabilityProbe` alias)

**Recommendation:** Add `NativeProviderConversationSession` branch after validating Cursor CLI `--print` / stream-json flags in a follow-up task.

## Grok Build (`grokBuild`)

| Item | Value |
|------|-------|
| Driver kind | `grokBuild` |
| Executable | `grok` |
| Probe | `grok --version` |
| Auth check | `--version` only; auth reported `unknown` |
| T3 adapter | Spawns `grok` with login via `grok login` |
| Kaname session | **Not implemented** |

**Implementation:** [`ProviderVersionCapabilityProbe.swift`](../Sources/KanameConnectivity/ProviderVersionCapabilityProbe.swift) (`GrokCapabilityProbe` alias)

## Domain changes

[`Provider.swift`](../Sources/KanameDomain/Provider.swift):

```swift
public static let cursorAgent = ProviderDriverKind(rawValue: "cursorAgent")!
public static let grokBuild = ProviderDriverKind(rawValue: "grokBuild")!
```

[`ProviderCapabilityProber`](../Sources/KanameConnectivity/ProviderProbe.swift) routes to new probes.

## Settings UI

[`KanameDesktopWorkspace.swift`](../Sources/KanamePrototype/KanameDesktopWorkspace.swift) provider definitions table should include Cursor and Grok rows when probes are wired in product UI (follow-up).

## Risk

- Cursor/Grok CLIs may change flags independently of T3; probes degrade gracefully to `unavailable` with detail string.
- No credentials imported; same boundary as Claude probe.

## Test plan

- Unit tests with mock executable paths (pattern from [`ProviderConnectivityTests.swift`](../Tests/KanameDomainTests/ProviderConnectivityTests.swift))
- Provider probe CLI includes new drivers when requested

## References

- T3 built-in drivers: https://github.com/pingdotgg/t3code/blob/main/apps/server/src/provider/builtInDrivers.ts
- Kaname Claude probe (template): [`ClaudeCapabilityProbe.swift`](../Sources/KanameConnectivity/ClaudeCapabilityProbe.swift)
