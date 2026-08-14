# Workflow v2 acceptance corpus

This directory defines provider-neutral, public, synthetic expectations for the
workflow persistence programme. It is deliberately not executable authority:
fixtures cannot bind an account, grant a capability, contact a provider, or
perform an external effect.

`corpus-manifest.json` declares the required behavior surface and binds the
scenario file by SHA-256. `scenarios.json` records the smallest graph, input,
expected result, inspection groups, and visual routes needed to prove each
approved behavior.

Later tickets may add schema and runtime interpretation, but they must preserve
the meaning of these fixtures or explicitly revise the corpus in a separately
reviewed commit.
