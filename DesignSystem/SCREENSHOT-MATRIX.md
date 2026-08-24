# Screenshot and visual QA matrix

`Fixtures/design-system/catalog-scenarios.json` is the executable baseline for the seven native macOS catalog pages. Every row declares platform, surface, fixture, viewport, appearance, color differentiation, motion preference, text scale, active-window state, locale, expected labels, output, and privacy class.

## Baseline coverage

| Family | Required states and axes | Current proof |
| --- | --- | --- |
| Catalog foundations/components | default, long content, inactive controls, non-color status, approval, empty/error callouts | seven macOS pages cover dark, light, high-contrast, accessibility-3 text, Differentiate Without Color, Reduce Motion, and inactive-window inputs |
| Desktop | content, empty, attention, running, failure, blocked, approval, external boundary; 1520×940 and compact | Link host captured in exact verified Dev runtime; broader matrix pending |
| iOS | five hubs; offline/queued/approval; Dynamic Type; Reduce Motion; Differentiate Without Color | pinned iPhone 15/iOS 26.3 clean-simulator screenshot qualified locally; broader axes pending |
| Link macOS | enrollment, connecting, online, offline, revoked, discussion, receipt | deterministic synthetic discussion snapshot qualified locally; remaining states pending |
| Link Windows | dark, light, high contrast; keyboard focus; Narrator | target-native proof pending |
| Link Linux | desktop theme variants; keyboard focus; Orca | target-native proof pending |

## Provenance

Each retained screenshot records source revision or dirty snapshot, design-system version, scenario and fixture, manifest digest, capture method, OS/device/runtime, viewport, locale, privacy class, and evidence label (`implemented`, `fixture/projection`, or `scaffolded/gap`). Synthetic-public is the default; prohibited/private data must fail closed.

## Review rule

Image dimensions, size, and checksum show that an artifact was produced; they do not establish that its layout, hierarchy, contrast, focus, text scaling, or platform behavior is acceptable. A human visual review plus relevant semantic/accessibility checks is required before a baseline is approved.
