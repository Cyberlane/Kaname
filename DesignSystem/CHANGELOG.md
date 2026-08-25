# Changelog

All design-system contract changes are recorded here. Dates mark qualification, not merely source creation.

## 0.2.0 — Adoption candidate

### Added

- Typed `KanameStatusPresentation`, compact/regular badge density, neutral metadata chips, and deterministic increased-contrast resolution.
- Exhaustive Desktop record/action/attention and Link-host lifecycle/publication/receipt adapters in `KanameDesktopUI`.
- Exhaustive iOS project delivery, check, CI, retry, and metadata presentation mappings.
- Cross-platform standalone Link connection, discussion, receipt, participant, and verification adapters that preserve schema-v1 wire values and fail closed for unknown authority states.
- Ten-scenario product screenshot contract, Desktop receipt-bound capture automation, multi-scenario iOS/Link capture routes, and complete-batch receipt verification.

### Adopted

- Removed the six named legacy product pill families, workflow work-state pill, and legacy attention badge; migrated raw iOS check/session states to typed shared badges.
- Routed common Desktop panels, section headers, empty states, and authority callouts through shared semantic roles.
- Added source-conformance tests for macOS, Windows, Linux, Desktop, and iOS status mappings.

### Still pending

- Target-native Windows/Linux runtime screenshots, high-contrast behavior, Narrator, and Orca qualification.
- VoiceOver traversal and complete assistive-technology qualification on Apple targets.
- Product-wide light appearance and migration of remaining specialized or primitive-role consumers.

## 0.1.0 — 2026-08-24

### Added

- Versioned custom Kaname token schema with Nord primitives, adaptive semantic colors, dimensions, motion, and status vocabulary.
- Generated Swift, WinUI, and GTK token projections with an exact stale-output check.
- SwiftUI surfaces, badges, headers, callouts, empty states, synthetic-data banner, authority card, message bubble, approval card, and metric card.
- Native macOS catalog with seven manifest-driven synthetic pages.
- Decodable screenshot scenario contract and privacy-safe capture scripts.
- Initial Link macOS component adoption and Windows/Linux semantic adapters.
- Typed receipt-owned labels and a distinct changes-requested approval state so examples cannot silently relabel evidence boundaries.
- In-memory-only iOS synthetic screenshot shell.
- Contrast, schema, adapter, manifest, and raw-color conformance checks.
- DocC, governance, migration, parity, screenshot, and Obsidian documentation.

### Not yet qualified

- Broad Desktop/iOS component migration.
- Apple and GTK increased-contrast behavior.
- Product-wide light appearance.
- Windows/Linux target-native builds and screenshots.
- Full assistive-technology and perceptual-regression gates.
