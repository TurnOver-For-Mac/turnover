# Music

- Bundle id: com.apple.Music
- Support: Not assessed
- Effort: Module
- Being worked on: Unclaimed
- Checked: 30 October 2026; developer build of 22.4 source 0ed2ab4; Mac and Windows keyboard styles. Setup limits are in the evidence.

## Findings

Search answers from Apple's catalog ([Catalog](../Catalog/README.md)): Return in the search field gives a plain list, Return on one opens its page. On for everyone from build 23, after Oliver used it from 27 October to 2 November 2026 with the developer switch on.

The first Down, Down and Up keys after launch reached the expected next/previous Media handlers. These three assertions check command dispatch. The scenario does not assert speech, shelf content or playback. The 29 October foreground probe exposed a clipped Browse sample, which does not establish a reading task.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[Shared implementation](../Media/MediaAppModule.swift) · [App recipe](../../../Resources/recipes/com.apple.Music.json) · [Shared check notes](../Media/README.md).
