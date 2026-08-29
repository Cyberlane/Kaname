# Project script manifest schema

Status: proposed · 2026-08-27

## Purpose

T3 Code defines keybindable project scripts in `t3.json` with icons, commands, optional `previewUrl`, and `runOnWorktreeCreate` ([project-settings.md](https://github.com/pingdotgg/t3code/blob/main/docs/user/project-settings.md)). Kaname already has **quality gates** (`tests`, `diagnostics`, `mori`, `lode`, `context`, `knowledge`) on worktrees. This schema maps project scripts to quality gates and optional preview integration.

## File location

`<project-root>/kaname.json` (version 1). Discovered during project intake alongside `AGENTS.md`.

## JSON Schema (informal)

```json
{
  "schemaVersion": 1,
  "scripts": [
    {
      "id": "test",
      "title": "Run tests",
      "command": "swift test",
      "icon": "test",
      "kind": "tests",
      "keybind": "cmd+shift+t",
      "runOnWorktreeReady": true,
      "previewUrl": null,
      "autoOpenPreview": false,
      "maximumDurationSeconds": 600
    },
    {
      "id": "dev-server",
      "title": "Start dev server",
      "command": "npm run dev",
      "icon": "play",
      "kind": "diagnostics",
      "previewUrl": "http://127.0.0.1:5173",
      "autoOpenPreview": true,
      "runOnWorktreeReady": false
    }
  ]
}
```

## Field definitions

| Field | Required | Description |
|-------|----------|-------------|
| `schemaVersion` | yes | Must be `1` |
| `scripts[].id` | yes | Stable identifier; maps to quality gate record |
| `scripts[].title` | yes | Display name in Coding control and Command Center |
| `scripts[].command` | yes | Shell command run in worktree cwd via bounded subprocess |
| `scripts[].icon` | no | `play`, `test`, `lint`, `build`, `debug`, `configure` (T3-compatible set) |
| `scripts[].kind` | yes | Maps to `DesktopQualityGateKind`: `tests`, `diagnostics`, `mori`, `lode`, `context`, `knowledge` |
| `scripts[].keybind` | no | Local keybinding label (resolved via Settings) |
| `scripts[].runOnWorktreeReady` | no | Auto-run when worktree reaches `ready` (approval still required for mutating side effects) |
| `scripts[].previewUrl` | no | Opens desktop preview panel when script succeeds |
| `scripts[].autoOpenPreview` | no | Requires `previewUrl`; opens preview after success |
| `scripts[].maximumDurationSeconds` | no | Default 600; passed to `LocalProcess` timeout |

## Mapping to quality gates

When a script completes, Kaname appends a `DesktopQualityGateRecord`:

```swift
DesktopQualityGateRecord(
    kind: script.kind,           // from manifest
    command: script.command,
    summary: capturedOutput,     // bounded
    state: exitStatus == 0 ? .completed : .failed,
    artifactIDs: [...]           // optional log artifact
)
```

## Authority

- Manual run: user action from Coding control; no inbox approval for read-only test commands.
- `runOnWorktreeReady`: requires the same implementation approval that created the worktree.
- Scripts never push, commit, or write outside the worktree without existing approval grants.

## Intake

[`DesktopProjectIntakeService.swift`](../Sources/KanameConnectivity/DesktopProjectIntakeService.swift) should detect `kaname.json` and surface script count in project overview.

## Future

- JSON Schema file under `Schema/Project/v1/kaname-project.schema.json`
- UI script picker in composer `/checks` drawer

## References

- Kaname quality gates: [`DesktopCodingControlModel.swift`](../Sources/KanameDesktop/DesktopCodingControlModel.swift)
- T3 project scripts: https://github.com/pingdotgg/t3code/blob/main/docs/user/project-settings.md
