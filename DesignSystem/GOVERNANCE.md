# Governance

This file is normative for the Kaname design-system contract. Product code, generated adapters, the catalog, and Obsidian documentation are consumers of `kaname.tokens.json`; none is an independent token authority.

## Maturity and versioning

The current `0.x` series is an adoption contract. `1.0.0` requires production adoption and target-native visual/accessibility qualification across Kaname Desktop, Kaname iOS, and the three Kaname Link clients.

- Patch: restore documented behavior without deliberately changing meaning or layout.
- Minor: add a backward-compatible token, component, state, or pattern.
- Major: remove or rename a public role, change semantic meaning, break a component initializer, change default interaction, change an accessibility-label contract, or change a layout metric that affects consumers.

Any value change to semantic color, type, spacing, radius, size, or motion is also a product-wide visual change and requires screenshot review, even when SemVer permits a minor release. Deprecate for at least one minor release before removal. Keep temporary Swift, XAML, and CSS aliases during that window.

## Change proposal

Every proposal names:

1. the product problem and why an existing role/component is insufficient;
2. affected consumers and native platform mappings;
3. semantic, authority, privacy, accessibility, and localization effects;
4. expected screenshot changes and scenario updates;
5. migration instructions and version impact;
6. evidence available locally versus target-native or external acceptance still required.

## Required gates

- Regenerate projections with `Scripts/generate-kaname-design-tokens.py`.
- Pass `Scripts/verify-kaname-design-tokens.py` and focused Swift tests.
- Add or update deterministic synthetic scenarios.
- Review actual visual diffs; file existence and hashes are provenance, not visual acceptance.
- Run target-native builds and accessibility checks for affected platforms.
- Update `CHANGELOG.md`, `MIGRATION.md`, `PARITY.md`, `SCREENSHOT-MATRIX.md`, DocC, and Obsidian when their contracts change.

Raw primitives are private implementation inputs. New product code consumes semantic roles. A platform may diverge in density and native interaction, but not in state meaning, authority language, privacy class, or accessibility outcome.
