# Ulysses

- Bundle id: com.ulyssesapp.mac
- Support: Partial
- Effort: None
- Being worked on: Unclaimed
- Checked: 30 October 2026; developer build of 22.4 source 0ed2ab4; Mac and Windows keyboard styles. Setup limits are in the evidence.

## Findings

Library/sheet-list review navigation passed four checks in each style, accepting speech or the expected text boundary sound. This repeats the corrected 12 October 8/8 result. Sheets below the fold previously exposed a loading placeholder until scrolled. Whole-sheet reading, Say All, typing and editing have not been established by these item-key checks.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[Historical checks and limits](Experiments/2026-10-historical-checks.md). [Shared navigation](../../Core/Objects/ObjectNavigation.swift). [Retained masked library fixture](../../../Tests/Fixtures/ulysses-library.json).
