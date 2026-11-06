# App Store

- Bundle id: com.apple.AppStore
- Support: Partial
- Effort: Module
- Being worked on: Unclaimed
- Checked: 30 October 2026; developer build of 22.4 source 0ed2ab4; Mac and Windows keyboard styles. Setup limits are in the evidence.

## Findings

Search answers from Apple's catalog ([Catalog](../Catalog/README.md)): Return in the search field gives a plain list, Return on one opens its page. On for everyone from build 23, after Oliver used it from 27 October to 2 November 2026 with the developer switch on.

Down, End and Up reached the expected App Store navigation handlers. These four checks assert command dispatch, not the content spoken or a successful page opening. The 29 October application-library note records Oliver reporting App Store use with VoiceOver both on and off, and a successful download. Initial reading speed, More/End ordering and offer-action safety need separate checks.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[App implementation](AppStoreAppModule.swift).
