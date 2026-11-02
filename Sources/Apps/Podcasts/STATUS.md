# Podcasts

- Bundle id: com.apple.podcasts
- Support: Not assessed
- Effort: Module
- Being worked on: Unclaimed
- Checked: 29 October 2026; Podcasts 1.1.0 (4027.240.1), macOS 27.2 (26B118). Probe and trial boundaries are in the evidence.

## Findings

Search answers from Apple's catalog ([Catalog](../Catalog/README.md)): Return in the search field gives a plain list, Return on one opens its page. On for everyone from build 23, after Oliver used it from 27 October to 2 November 2026 with the developer switch on.

The 29 October probe reached a clipped public Browse sample after bringing the app forward; an initial background request could not complete. No catalogue-navigation, spoken-reading or playback result was recorded.

Use a public catalogue to check sidebar and show/episode navigation, then switch away and back and check that speech describes the current page.

## Evidence

[29 October provider and task evidence](Experiments/2026-10-29-capabilities.md).

[Shared implementation](../Media/MediaAppModule.swift) · [App recipe](../../../Resources/recipes/com.apple.podcasts.json) · [Shared check notes](../Media/README.md).
