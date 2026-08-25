# Screenshot and visual QA matrix

`Fixtures/design-system/catalog-scenarios.json` and `Fixtures/design-system/product-scenarios.json` are the executable contracts for seven native macOS catalog pages and ten product scenarios. Every row declares platform, surface, fixture, viewport, appearance, color differentiation, motion preference, text scale, active-window state, locale, expected labels, output, and privacy class.

The six standard catalog pages use a 1280x860-point viewport. The accessibility page uses 1280x1120 so its deterministic 1.6x semantic-font simulation retains the complete qualification grid and non-color state proof without reducing the stress scale.

## Baseline coverage

| Family | Required states and axes | Current proof |
| --- | --- | --- |
| Catalog foundations/components | default, long content, inactive controls, non-color status, approval, empty/error callouts | seven macOS pages cover dark, light, high-contrast, accessibility-3 text, Differentiate Without Color, Reduce Motion, and inactive-window inputs |
| Desktop | Link host, home status language, accessibility-3 text, GitHub approval, Link publication receipts | five deterministic capture routes implemented; fresh clean-`main` 0.2 evidence batch pending |
| iOS | home status language, GitHub approval, accessibility-3 text | three deterministic clean-simulator routes implemented; fresh clean-`main` 0.2 evidence batch pending |
| Link macOS | connection, discussion action, participant identity, host verification, receipts, restricted trust boundary, accessibility-3 text | two deterministic native routes implemented; fresh clean-`main` 0.2 evidence batch pending |
| Link Windows | typed connection/discussion/receipt/verification contract; dark, light, high contrast; keyboard focus; Narrator | source conformance implemented; target-native proof pending |
| Link Linux | typed connection/discussion/receipt/verification contract; desktop theme variants; keyboard focus; Orca | headless logic qualified; target-native GTK proof pending |

## Provenance

Each retained screenshot records source revision and one working-source snapshot, design-system version, scenario and fixture, manifest digest, capture method, OS/device/runtime, viewport, locale, privacy class, and evidence class. Desktop receipts additionally bind the historical Development executable, PID, window, launcher receipt hash, and successful pre/post verification. Product scenarios must be synthetic-public fixture projections; catalog rows retain their truthful `implemented`, `fixture-projection`, or `scaffolded-gap` classification. Prohibited/private data must fail closed.

The complete-batch verifier requires exactly the expected 17 PNGs and 17 receipt sidecars from one source snapshot, with no extra PNG/receipt files. Capture only from final clean `main` into an external or ignored directory. Any later HEAD, branch, tracked-content, or untracked-content change requires a fresh batch before that source can claim current visual evidence.

For macOS, an `accessibility3` scenario injects ``KanameSyntheticTextScale`` through the shared semantic-font adapter because the native SwiftUI Dynamic Type environment does not resize macOS text. The standard scenario keeps production defaults. Capture wrappers and the batch verifier fail closed when otherwise matching standard and enlarged-text scenarios produce identical PNG bytes. This deterministic simulation proves only that the fixture can withstand enlarged text; native preferences, screen readers, and target-platform qualification remain separate.

## Review rule

Image dimensions, size, and checksum show that an artifact was produced. Distinct hashes show that a declared text-scale axis affected rendering. Neither establishes that layout, hierarchy, contrast, focus, text scaling, or platform behavior is acceptable. A human visual review plus relevant semantic/accessibility checks is required before a baseline is approved.
