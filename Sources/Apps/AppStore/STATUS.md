# App Store

- Bundle id: com.apple.AppStore
- Support: Partial
- Effort: Module
- Being worked on: Unclaimed
- Checked: 30 October 2026; developer build of 22.4 source 0ed2ab4; Mac and Windows keyboard styles. Setup limits are in the evidence.

## Findings

Down, End and Up reached the expected App Store navigation handlers. These four checks assert command dispatch, not the content spoken or a successful page opening. The 29 October application-library note records Oliver reporting App Store use with VoiceOver both on and off, and a successful download. Initial reading speed, More/End ordering and offer-action safety need separate checks.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[App implementation](AppStoreAppModule.swift).
