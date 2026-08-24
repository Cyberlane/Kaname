# Adoption and release checklist

## Migration order

1. Replace duplicated status pills with `KanameStatusBadge` and the shared status vocabulary.
2. Replace approval and authority-boundary variants with shared components or platform-equivalent adapters.
3. Normalize callouts, empty states, surfaces, section headers, and interactive hit areas.
4. Migrate product patterns one source-backed screen at a time without changing interaction mechanics.
5. Retire the Nord compatibility alias only after no product feature imports primitive roles directly.

## Definition of done for a migrated screen

- Uses semantic roles rather than raw colors and one-off spacing/radius values.
- Names default, hover/pressed, focus, disabled, loading, empty, failure, blocked, and relevant authority states.
- Preserves keyboard, pointer, touch, resizing, and navigation behavior.
- Conveys state without color and exposes useful accessibility semantics.
- Has synthetic-public fixtures and deterministic screenshots for material states.
- Has target-native build/runtime evidence; source conformance alone is labeled as such.
- Documents any intentional platform divergence.

## Screenshot baseline matrix

| Surface | Dark | Light | High contrast | Large text | Reduce motion | Target-native |
| --- | --- | --- | --- | --- | --- | --- |
| Catalog | Required | Planned | Planned | Planned | Planned | macOS |
| Desktop key workflows | Required | Planned | macOS setting | Required | Required | macOS |
| iOS five hubs | Required | Planned | iOS settings | Required | Required | iOS Simulator/device |
| Link macOS | Required | Planned | macOS setting | Required | Required | macOS |
| Link Windows | Required | Required | Required | Required | Required | Windows |
| Link Linux | Required | Required | Desktop theme | Required | Required | Linux |

Screenshots must declare source revision, scenario, viewport, appearance, privacy class, capture method, and whether the displayed state is production-backed, fixture-backed, or a catalog projection.

## Release governance

- Patch changes preserve role meaning and component behavior.
- Minor changes add roles/components/patterns and migration notes.
- Major changes remove, rename, or redefine semantics.
- Never repurpose a role to avoid migration.
- Figma, documentation, and platform adapters are projections of the checked-in token contract.
- Acceptance requires relevant tests, adapter conformance, screenshots, accessibility review, and target-native proof.
