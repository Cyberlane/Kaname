# Components

Components encode recurring Kaname semantics while preserving native controls and focus behavior.

## Structural primitives

- ``KanameSurface`` groups one concept on a semantic surface with consistent padding, radius, and separation.
- ``KanameSectionHeader`` establishes a section title, optional explanation, and optional trailing action or status.
- ``KanameMetricCard`` summarizes a small, source-backed measure. Its detail must name the measurement boundary.

## State and evidence

- ``KanameStatusBadge`` combines a caller-reviewed label, symbol, and typed tone. It is not an action; the generic badge cannot enforce product vocabulary by itself.
- ``KanameCallout`` explains information, action, risk, failure, or an external boundary.
- ``KanameEmptyState`` states what is absent and the next useful action; an empty collection is not an error by default.
- ``KanameSyntheticDataBanner`` must remain visible in catalogs and screenshots that resemble product state.

## Authority and collaboration

- ``KanameApprovalCard`` presents impact and authority before Approve, Reject, or Request changes. Callers supply all three actions and a typed ``KanameApprovalState``.
- ``KanameAuthorityBoundaryCard`` explains that Link collaborators receive only explicitly shared material.
- ``KanameMessageBubble`` uses ``KanameMessageParticipantRole`` so user, assistant, host, and external collaborator are not conflated. Its optional ``KanameMessageReceipt`` derives a stable label and tone from typed ``KanameReceiptState``; gateway acceptance, publication, delivery, failure, and uncertainty remain distinct.

## State requirements

Every interactive component must define applicable default, hover, pressed, focused, disabled, loading, empty, error, and permission-blocked states. Approval controls additionally define proposed, working, changes-requested, approved, rejected, expired, and outcome-uncertain states. Link controls additionally define local-only, queued, relay-accepted, recipient-delivered when proven, and failed states.

## Native adapters

SwiftUI product code imports `KanameDesignSystem`. WinUI views use `ThemeResource` keys from `Clients/KanameLink/Windows/App.xaml`. GTK views load `kaname-theme.css` and use semantic CSS classes. Adapters may translate platform idioms, but may not silently change a semantic role's meaning.
