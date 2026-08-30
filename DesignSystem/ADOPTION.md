# Adoption and release checklist

## Migration order

1. **Completed in 0.2.0:** replace the duplicated Desktop/iOS status-pill families, workflow work-state pill, legacy attention badge, and raw iOS check/session status rows with `KanameStatusBadge`, `KanameMetadataChip`, and exhaustive product adapters.
2. **In progress:** replace remaining approval and authority-boundary variants with shared components or platform-equivalent adapters.
3. **In progress:** normalize callouts, empty states, surfaces, section headers, and interactive hit areas; common Desktop wrappers now delegate to shared roles.
4. Migrate remaining product patterns one source-backed screen at a time without changing interaction mechanics.
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
| Catalog | Covered | Covered | Covered | Covered | Covered | macOS |
| Desktop key workflows | Required | Planned | macOS setting | Required | Required | macOS |
| iOS five hubs | Required | Planned | iOS settings | Required | Required | iOS Simulator/device |
| Link macOS | Required | Planned | macOS setting | Required | Required | macOS |
| Link Windows | Required | Required | Required | Required | Required | Windows |
| Link Linux | Required | Required | Desktop theme | Required | Required | Linux |

Screenshots must declare source revision, scenario, viewport, appearance, privacy class, capture method, and whether the displayed state is production-backed, fixture-backed, or a catalog projection.

The macOS `accessibility3` capture axis is a deterministic Kaname semantic-font simulation; the standard axis retains production defaults. Matching standard/enlarged scenarios must keep every other renderer axis equal and produce different PNG bytes. This visual stress check does not replace native preference, VoiceOver, Narrator, Orca, or target-screen qualification.

## Automated accessibility source inventory

Run `python3 Scripts/audit-kaname-accessibility.py --format text` for a compact summary or write the complete deterministic JSON with `--format json --output <path>`. The report binds the audit-tool bytes, its strict configuration, every scanned Swift file, source bytes, sorted findings, and separate tool/config/source/findings SHA-256 identities. By default it reads every `Sources/**/*.swift` file; analyzes files containing a SwiftUI import, a `View` conformance marker, or an advertised actionable API; and inventories Button, Link, Menu, NavigationLink, DisclosureGroup, Toggle, Picker, DatePicker, TextField, SecureField, Slider, and Stepper plus direct and composed tap/long-press gesture forms. Every advertised family reports occurrence, analyzed, and skipped counts; an unparseable occurrence fails the audit instead of appearing as skipped. Source paths are not excluded and findings cannot be allowlisted.

The inventory emits five kinds of review lead: actionable-control semantics, conditional or raw state color, fixed-size risk, motion without a nearby Reduce Motion marker, and presentation without a nearby focus-restoration marker. Actionable controls, including explicit generic constructor forms, are separated into their initializer, family-specific label region, and immediately owned outer modifiers. Only statically nonempty, uninterpolated literal `Text`, `Label`, accessibility-label, and accessibility-hint values satisfy the lexical check: empty, whitespace-only (including whitespace escapes), interpolated, or otherwise dynamic expressions remain described review leads. An owned nonempty explicit label may repair an empty literal initializer title, but an arbitrary positional title remains a lead even when such a fallback exists. Gesture markers are credited only when chained after that gesture by the bounded heuristic. Comments, strings, and Swift regex literals, including escaped extended-regex delimiters, are masked, while incomplete lexical input fails closed. Lexical ownership and proximity are only triage context. A clean report does not prove semantics, contrast, focus behavior, keyboard access, Dynamic Type, or Reduce Motion behavior, and findings do not fail the command. Only exit `0` means that a complete, untruncated inventory was emitted. Invalid arguments and handled configuration, coverage, resource-bound, or output-I/O failures exit `2`; any other nonzero exit is an unexpected failure. Never accept report bytes from a nonzero run as complete.

JSON output must be outside every scanned source root. The tool refuses a destination that aliases or hard-links a scanned source, the selected config, or the audit tool; it also refuses symlink and nonregular destinations. Source, config, and tool bytes are read through no-follow descriptors where the platform supports them and are digest-rechecked, together with the complete discovered source set, before report completion and again after an output write.

Use the report to select one critical journey for a follow-up accessibility ticket. Close that ticket with focused source tests and deterministic large-text/high-contrast/reduce-motion fixtures, then run the separately authorized target-native keyboard and assistive-technology matrix. This source inventory alone is never a Candidate gate and never substitutes for VoiceOver, Narrator, Orca, simulator/device, or owner acceptance evidence.

## Release governance

- Patch changes preserve role meaning and component behavior.
- Minor changes add roles/components/patterns and migration notes.
- Major changes remove, rename, or redefine semantics.
- Never repurpose a role to avoid migration.
- Figma, documentation, and platform adapters are projections of the checked-in token contract.
- Acceptance requires relevant tests, adapter conformance, screenshots, accessibility review, and target-native proof.
