# Finder

- Bundle id: com.apple.finder
- Support: Partial
- Effort: Module
- Being worked on: Unclaimed
- Checked: 30 October 2026; developer build of 22.4 source 0ed2ab4; Mac and Windows keyboard styles. Setup limits are in the evidence.

## Findings

List-arrow and review-navigation dispatch checks passed. Two position-announcement expectations missed in each style. The release handoff attributes the missing positions to the number-in-list setting being off, rather than a new release defect. Repeat position checks with the setting stated; this run did not verify rename or file operations.

The module adapts file navigation and opening keys to the selected keyboard style. Use a sample folder to check selection, opening, renaming and return from a subfolder.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[App implementation](FinderAppModule.swift).
