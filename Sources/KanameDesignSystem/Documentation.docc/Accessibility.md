# Accessibility

Accessibility is part of component acceptance, not a later visual pass.

## Required behavior

- Convey state with a label and symbol in addition to color.
- Preserve a 44-by-44-point interactive target.
- Use native focus and keyboard traversal; do not hide focus rings.
- Keep reading and focus order consistent with visual order.
- Support system text scaling without clipping essential actions or status.
- Reflow dense regions before truncating primary meaning.
- Honor Reduce Motion and Differentiate Without Color.
- Expose concise labels, values, hints, and headings; group only when the combined announcement is clearer.
- Announce asynchronous outcome changes without stealing focus.
- Keep destructive, approval, external-boundary, and outcome-uncertain language explicit.

## Qualification matrix

Every release-significant screen needs checks for dark appearance, target-native high contrast where available, standard and enlarged text, keyboard or switch traversal, screen-reader labels, Reduce Motion, Differentiate Without Color, empty state, loading, failure, and blocked authority. Light appearance remains unqualified until it passes the same matrix.

## Screenshot evidence

Screenshots are visual evidence, not accessibility proof. Each automated scenario records viewport, appearance, text scale, motion preference, color-differentiation preference, locale, active-window state, expected accessibility labels, and privacy class. Semantic inspection and target-native assistive-technology checks remain required.

On macOS, use ``View/kanameSemanticFont(_:)`` with the capture environment's ``KanameSyntheticTextScale``. SwiftUI's Dynamic Type environment does not resize macOS text, so `accessibility3` is an explicit deterministic simulation while `standard` preserves the production font. Otherwise matching standard and enlarged captures must render different PNG bytes. This is layout-stress evidence only, not proof of a native user setting or assistive-technology behavior.

For Apple-platform guidance, use the current platform documentation for SwiftUI environment values, Human Interface Guidelines, and XCTest screenshots. WinUI and GTK qualification must run on their target operating systems.
