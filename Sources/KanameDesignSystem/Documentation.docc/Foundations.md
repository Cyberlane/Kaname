# Foundations

Use semantic roles in product code. Primitive Nord values exist for compatibility and adapter generation, not for feature-level decisions.

## Color

The semantic surface stack is `canvas` → `sidebar`/`surface` → `raised`, with `selected` for current selection and `separator` for structure. Text uses primary, secondary, or tertiary roles. Actions use `accent`; statuses use success, warning, danger, blocked, or external.

Dark and light values are adaptive on Apple platforms. Both palettes pass the token-level contrast verifier and the catalog includes a light scenario. Dark is the currently qualified product appearance; each shipping product still needs complete light-mode layout, interaction, and accessibility qualification before light appearance is declared product-ready.

Do not:

- name a token after a visual value such as “blue button”;
- use status color as the only carrier of meaning;
- use `external` to mean “warning”—it specifically marks an external-principal or authority boundary;
- infer successful delivery from a local receipt.

## Typography

Use system fonts and Dynamic Type-compatible styles. `display` is reserved for catalog or hero hierarchy; product screens normally start with `screenTitle`. Use `technical` for identifiers, receipts, hashes, command names, and other machine-shaped text—not for long prose.

## Spacing and shape

Spacing follows a compact 2/4/8/12/16/20/24/32/40 scale. Prefer the named role that expresses hierarchy rather than introducing a new literal. Controls, cards, panels, and hero regions use 8/12/16/20-point radii respectively.

The 44-point `minimumInteractiveTarget` is the cross-platform accessibility floor. A compact visual control may remain 28 or 36 points tall if its interactive hit area is expanded to 44 points.

## Motion

Use quick (0.12 s), standard (0.20 s), or deliberate (0.32 s) motion. Animation must explain state or spatial continuity. Disable or simplify non-essential motion when Reduce Motion is active, and never delay an authority or approval action for decoration.

## Status vocabulary

| Tone | Meaning | Typical examples |
| --- | --- | --- |
| neutral | Known but inactive | Draft, idle, not configured |
| informational | Context, no action required | Local receipt, source-backed |
| active | Work or connection in progress | Running, connected, syncing |
| attention | User decision required | Approval required, unread |
| success | Observed success at the named boundary | Local tests passed |
| warning | Risk, uncertainty, or degraded state | Provider unavailable |
| danger | Observed failure | Build failed, rejected |
| blocked | Policy or dependency prevents progress | Permission denied |
| external | External principal or trust boundary | Collaborator content |

Labels remain domain-specific, but their meaning must fit the tone. Always pair tone with explicit text and the stable symbol supplied by ``KanameStatusTone``.
