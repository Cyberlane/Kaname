# Governance

## Source of truth

`DesignSystem/kaname.tokens.json` owns portable values. Platform adapters are generated or checked projections. A token change is incomplete until the SwiftUI, WinUI, GTK, catalog, documentation, and screenshot expectations agree.

## Change classes

- **Patch:** documentation correction or implementation fix that preserves semantics and appearance.
- **Minor:** additive token, component, state, or pattern with migration guidance.
- **Major:** removed or renamed role, changed semantic meaning, or intentionally incompatible component behavior.

Do not repurpose an existing token to avoid a major change. Deprecate it, document the replacement, and migrate consumers deliberately.

## Acceptance gates

1. Explain the user or product problem and why an existing role or component does not fit.
2. Update the portable token contract and native adapters when applicable.
3. Add component and token tests, including non-color meaning and target sizing.
4. Update deterministic synthetic scenarios and the screenshot matrix.
5. Run source conformance plus target-native builds and visual/accessibility review for affected platforms.
6. Record migration status and known gaps without calling source presence runtime proof.

## Adoption

Version 0.2.0 production-adopts the shared status language across Desktop, iOS project/GitHub status surfaces, the Desktop Link host, and all three standalone Link clients. Common Desktop panels, section headers, callouts, and empty states also delegate to shared roles. This remains a bounded migration rather than a silent product-wide rewrite: approvals, specialized diagrams, remaining primitive consumers, light appearance, and target-native accessibility qualification continue screen by screen.

Figma may later mirror tokens and map reviewed components through Variables and Code Connect. It is a projection, not a competing source of truth. Storybook is not the primary catalog because Kaname's product surfaces are native rather than web components.
