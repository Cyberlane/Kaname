# Kaname Design System

This directory is the portable source of truth for the Kaname design language. It covers Kaname Desktop, Kaname iOS, and Kaname Link while keeping each platform's native interaction conventions.

## Architecture

| Layer | Source | Responsibility |
| --- | --- | --- |
| Portable contract | `kaname.tokens.json` | Primitive values, semantic roles, status mapping, dimensions, version |
| Apple adapter | `Sources/KanameDesignSystem` | Adaptive SwiftUI tokens, components, scenario schema, DocC guidance |
| Desktop product adapter | `Sources/KanameDesktopUI` | Exhaustive Desktop and Link-host domain-to-semantic status mapping |
| Windows adapter | `Clients/KanameLink/Windows/App.xaml` | WinUI default, light, and high-contrast resources |
| Linux adapter | `Clients/KanameLink/Linux/src/kaname-theme.css` + `kaname-components.css` | Generated GTK semantic variables/icons plus hand-authored widget classes |
| Reference catalog | `Sources/KanameDesignCatalog` | Interactive synthetic catalog and deterministic page capture |
| Scenario manifests | `Fixtures/design-system/catalog-scenarios.json` + `Fixtures/design-system/product-scenarios.json` | Named catalog/product screenshot inputs, renderer axes, evidence classes, and privacy boundary |
| Durable product atlas | Obsidian `Projects/Coding ADE/Product/Design System/` | Workflows, features, screenshots, evidence, decisions, adoption ledger |

## Commands

Use this task worktree's canonical private build directory:

```sh
export KANAME_TASK_BUILD_DIR="$(pwd -P)/.build"
Scripts/generate-kaname-design-tokens.py --check
Scripts/verify-kaname-design-tokens.py
swift test --scratch-path "$KANAME_TASK_BUILD_DIR" --filter KanameDesignSystemTests
python3 Scripts/test-kaname-design-screenshot-receipts.py
Scripts/capture-kaname-design-catalog.sh /absolute/output-directory
Scripts/capture-kaname-desktop-design-screenshots.sh /absolute/output-directory
Scripts/capture-kaname-ios-design-screenshots.sh /absolute/output-directory
Scripts/capture-kaname-link-macos-design-screenshots.sh /absolute/output-directory
Scripts/verify-kaname-design-screenshot-receipts.py \
  --catalog-manifest Fixtures/design-system/catalog-scenarios.json \
  --product-manifest Fixtures/design-system/product-scenarios.json \
  --directory /absolute/output-directory \
  --require-complete-batch
```

The catalog and capture fixtures are synthetic-public and initialize no account, provider, repository, collaborator, credential, or network state.
Run the complete batch only from final clean `main`, and write it to an external or ignored directory so evidence files cannot enter their own working-source digest.
On macOS, `accessibility3` capture scenarios use Kaname's explicit semantic-font simulation because SwiftUI's native Dynamic Type environment does not resize macOS text. Standard scenarios retain production font defaults. The simulation is deterministic layout-stress evidence, not proof of a native user preference or assistive-technology qualification.

## Adoption status

- Shared semantic tokens and reusable Apple components: implemented at `0.2.0`; typed presentations, compact/regular badge density, metadata chips, and deterministic contrast resolution are tested.
- Native macOS catalog and deterministic catalog captures: implemented and visually reviewed.
- Desktop migrated status families, workflow work-state badges, common panels, section headers, callouts, update notice surface, and empty states: production source adopted through shared components and `KanameDesktopUI` mappings.
- iOS project delivery/check/CI/retry badges, session/check rows, and metadata chips: production source adopted through typed mappings; broader screen migration remains deliberate follow-up work.
- Kaname Link macOS status/component adoption: implemented with typed connection, discussion, receipt, participant, and verification semantics.
- Kaname Link Windows and Linux semantic status adapters: source-conformance implemented; target-native runtime, screenshot, Narrator, and Orca proof remain pending.
- Existing Desktop/iOS palette compatibility: retained through the shared module while remaining primitive consumers migrate by category.
- Light appearance: token contract exists; full product qualification remains pending.

See the module's DocC catalog for foundations, component contracts, product patterns, accessibility, and governance.
