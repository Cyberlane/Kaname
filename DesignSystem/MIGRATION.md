# Migration

Adopt the system screen-by-screen without changing established interaction mechanics.

## Current bridge

`KanamePrototypeUI.Nord` is a compatibility alias to `KanameDesignSystem.Nord`. It keeps current Desktop and iOS source building while semantic migration proceeds. Do not add new primitive uses. Remove the alias only in a major design-system release after searches prove that no consumer remains.

## Order

1. Consolidate duplicate status pills (`RecordStatusPill`, `ActionStatePill`, `ProductStatusPill`, `AttentionPill`, `IPhonePill`, and `LinkStatusPill`) into the shared status vocabulary or a native adapter.
2. Consolidate approval, request-changes, warning, external-authority, receipt, and outcome-uncertain treatments.
3. Normalize section headers, surfaces, callouts, empty states, focus, and interactive hit areas.
4. Migrate one representative Desktop screen and one real iOS screen; verify layout and interaction before expanding by category.
5. Build native Link component libraries on Windows and Linux; do not infer component parity from token parity.

## Definition of done

A migrated surface uses semantic roles, defines all applicable states, preserves native keyboard/pointer/touch/navigation behavior, carries non-color meaning, reflows at supported sizes, has synthetic fixtures, and has target-native visual/accessibility evidence. Intentional platform differences are documented in `PARITY.md`.
