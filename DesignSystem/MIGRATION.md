# Migration

Adopt the system screen-by-screen without changing established interaction mechanics.

## Current bridge

`KanamePrototypeUI.Nord` is a compatibility alias to `KanameDesignSystem.Nord`. It keeps current Desktop and iOS source building while semantic migration proceeds. Do not add new primitive uses. Remove the alias only in a major design-system release after searches prove that no consumer remains.

## Order

1. **Completed in 0.2.0:** the six named product pill families, `WorkflowStatePill`, and the legacy `AttentionBadge` were removed. Raw iOS check/session status rows now take typed states. These migrated families use exhaustive presentations; native Link clients parse status wire values once and fail closed for unknown authority states.
2. Consolidate approval, request-changes, warning, external-authority, receipt, and outcome-uncertain treatments.
3. Normalize section headers, surfaces, callouts, empty states, focus, and interactive hit areas.
4. Continue beyond the adopted Desktop common surfaces and iOS project/GitHub status screen, verifying layout and interaction before expanding each category.
5. Qualify the implemented native Link adapters on Windows and Linux; do not infer runtime or assistive-technology parity from source conformance.

## Definition of done

A migrated surface uses semantic roles, defines all applicable states, preserves native keyboard/pointer/touch/navigation behavior, carries non-color meaning, reflows at supported sizes, has synthetic fixtures, and has target-native visual/accessibility evidence. Intentional platform differences are documented in `PARITY.md`.
