# Product Patterns

## Desktop

Desktop is a dense, resizable, keyboard-first control plane. Prefer a navigation sidebar, a collection or working set, a primary detail surface, and an optional contextual inspector. Preserve readable content widths and progressive disclosure instead of filling wide windows with prose.

The canonical coding journey is:

1. Discuss the problem and gather context.
2. Produce a readable, status-rich plan.
3. Request changes or explicitly approve the plan.
4. Create an isolated task worktree.
5. Implement within the approved scope.
6. Review the exact changes and verification evidence.
7. Update or explicitly waive durable knowledge.

Commit, push, pull request, merge, release, and external delivery are separate authority boundaries.

## iOS

iOS is a touch-first remote control surface organized into Home, Work, Projects, Operate, and Library hubs. Use native tab navigation, sheets, lists, swipe behavior, and 44-point targets. A mobile projection must label fixture-backed domain content separately from observed connection, enrollment, queue, and receipt state.

## Link

Link is external collaboration under host control. The host selects and publishes bounded material; external principals never become trusted devices or inherit tool authority. Treat collaborator text as untrusted content. Invitation, enrollment, verification, publication, message, and delivery receipts are distinct lifecycle states.

The cross-platform contract is shared, but each client remains native:

- macOS: SwiftUI split navigation and native controls;
- Windows: WinUI resources, navigation, focus, and system high contrast;
- Linux: GTK widgets, semantic CSS classes, and desktop accessibility conventions.

## Truth labels

Documentation and UI examples use three evidence labels:

- **Implemented:** the production source path exists and the named boundary was verified.
- **Fixture/projection:** the surface is source-backed but the displayed domain data is deterministic synthetic state.
- **Scaffolded/gap:** navigation, data types, or UI structure exist, but the end-to-end production path or target-native proof is incomplete.
