# Screenshot and visual QA matrix

`Fixtures/design-system/catalog-scenarios.json` and `Fixtures/design-system/product-scenarios.json` are the executable contracts for seven native macOS catalog pages and ten product scenarios. Every row declares platform, surface, fixture, viewport, appearance, color differentiation, motion preference, text scale, active-window state, locale, expected labels, output, and privacy class.

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

## Review rule

Image dimensions, size, and checksum show that an artifact was produced; they do not establish that its layout, hierarchy, contrast, focus, text scaling, or platform behavior is acceptable. A human visual review plus relevant semantic/accessibility checks is required before a baseline is approved.
