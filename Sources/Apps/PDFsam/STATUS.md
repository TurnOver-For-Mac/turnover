# PDFsam Basic

- Bundle id: Not recorded
- Support: Not assessed
- Effort: None
- Being worked on: Unclaimed
- Checked: 14 October 2026; record recovered 1 November 2026. No fresh live test of the current build.

## Findings

PDFsam Basic 6 used JavaFX and reported focused buttons as disabled. Shared focus-aware speech stopped calling those controls unavailable. Driver checks read card text, action buttons and help links in order. No PDF operation was performed.

Current-build task coverage remains unassessed. Next: With a public sample PDF, check module selection and controls before a disposable split/merge task. Confirm the app’s bundle identifier.

## Evidence

[Dated observations and limits](Experiments/2026-10-historical-checks.md). [Shared enabled-state speech](../../TurnOverCore/TurnOverObject.swift)
