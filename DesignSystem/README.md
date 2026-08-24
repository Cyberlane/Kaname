# Kaname Design System

This directory is the portable source of truth for the Kaname design language. It covers Kaname Desktop, Kaname iOS, and Kaname Link while keeping each platform's native interaction conventions.

## Architecture

| Layer | Source | Responsibility |
| --- | --- | --- |
| Portable contract | `kaname.tokens.json` | Primitive values, semantic roles, status mapping, dimensions, version |
| Apple adapter | `Sources/KanameDesignSystem` | Adaptive SwiftUI tokens, components, scenario schema, DocC guidance |
| Windows adapter | `Clients/KanameLink/Windows/App.xaml` | WinUI default, light, and high-contrast resources |
| Linux adapter | `Clients/KanameLink/Linux/src/kaname-theme.css` + `kaname-components.css` | Generated GTK semantic variables/icons plus hand-authored widget classes |
| Reference catalog | `Sources/KanameDesignCatalog` | Interactive synthetic catalog and deterministic page capture |
| Scenario manifest | `Fixtures/design-system/catalog-scenarios.json` | Named screenshot inputs and privacy boundary |
| Durable product atlas | Obsidian `Projects/Coding ADE/Product/Design System/` | Workflows, features, screenshots, evidence, decisions, adoption ledger |

## Commands

Use this task worktree's canonical private build directory:

```sh
export KANAME_TASK_BUILD_DIR="$(pwd -P)/.build"
Scripts/generate-kaname-design-tokens.py --check
Scripts/verify-kaname-design-tokens.py
swift test --scratch-path "$KANAME_TASK_BUILD_DIR" --filter KanameDesignSystemTests
Scripts/capture-kaname-design-catalog.sh /absolute/output-directory
Scripts/capture-kaname-ios-design-screenshot.sh /absolute/output.png
Scripts/capture-kaname-link-macos-design-screenshot.sh /absolute/output.png
```

The catalog and capture fixtures are synthetic-public and initialize no account, provider, repository, collaborator, credential, or network state.

## Adoption status

- Shared semantic tokens and reusable Apple components: implemented; token/schema/state-model tests pass, while rendered component and assistive-technology qualification remains pending.
- Native macOS catalog and deterministic catalog captures: implemented and visually reviewed.
- Kaname Link macOS token/component adoption: implemented.
- Kaname Link Windows and Linux semantic adapters: source-conformance verified; target-native build and screenshot proof remain pending.
- Existing Desktop/iOS palette compatibility: implemented through the shared module.
- Existing Desktop/iOS feature-by-feature component migration: deliberate follow-up work, not claimed complete.
- Light appearance: token contract exists; full product qualification remains pending.

See the module's DocC catalog for foundations, component contracts, product patterns, accessibility, and governance.
