# ``KanameDesignSystem``

A shared semantic language for Kaname Desktop, Kaname iOS, and Kaname Link, rendered with native platform controls.

## Overview

Kaname's design system separates meaning from rendering:

- `DesignSystem/kaname.tokens.json` is the portable source of truth for primitive and semantic values.
- ``KanameColor``, ``KanameSpacing``, ``KanameRadius``, ``KanameSize``, ``KanameMotion``, and ``KanameTypography`` expose those values to SwiftUI.
- WinUI resource dictionaries and the GTK stylesheet adapt the same roles to Kaname Link clients.
- Reusable SwiftUI components make status, authority, approval, empty, and evidence states consistent.
- ``KanameDesignScenario`` records deterministic screenshot and accessibility conditions without private data.

The system is native-first. It standardizes semantics, hierarchy, and state language; it does not replace SwiftUI/AppKit, UIKit, WinUI, or GTK interaction conventions.

> Important: Catalog content and automated screenshots are synthetic-public fixtures. They must never initialize providers, credentials, private repositories, messages, collaborators, or network services.

## Design principles

1. **Authority is visible.** Proposed, local, external, accepted, and verified outcomes are distinct states.
2. **Status is language.** A stable term, symbol, and semantic color communicate every status.
3. **Evidence is precise.** Local completion never implies remote delivery or external acceptance.
4. **Native behavior wins.** Keyboard, pointer, touch, focus, navigation, and accessibility follow platform conventions.
5. **Privacy is a test input.** Every capture scenario declares its privacy class and defaults to synthetic-public.

## Topics

### Foundations

- <doc:Foundations>
- ``KanameColor``
- ``KanameSpacing``
- ``KanameRadius``
- ``KanameSize``
- ``KanameMotion``
- ``KanameTypography``
- ``KanameStatusTone``

### Components

- <doc:Components>
- ``KanameSurface``
- ``KanameStatusBadge``
- ``KanameSectionHeader``
- ``KanameCallout``
- ``KanameEmptyState``
- ``KanameSyntheticDataBanner``
- ``KanameAuthorityBoundaryCard``
- ``KanameMessageBubble``
- ``KanameMessageParticipantRole``
- ``KanameMessageReceipt``
- ``KanameReceiptState``
- ``KanameApprovalCard``
- ``KanameApprovalState``
- ``KanameMetricCard``

### Product guidance

- <doc:ProductPatterns>
- <doc:Accessibility>
- <doc:Governance>
- ``KanameDesignScenario``
