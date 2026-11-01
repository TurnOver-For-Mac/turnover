# PDFsam Basic

- Bundle id: Not recorded
- Support: Partial
- Effort: None
- Being worked on: Unclaimed
- Checked: 14 October 2026; setup details are in the linked evidence.

## Findings

PDFsam Basic 6 used JavaFX and reported focused buttons as disabled. Shared focus-aware speech stopped calling those controls unavailable. Driver checks read card text, action buttons and help links in order. No PDF operation was performed.

Next check: With a public sample PDF, check module selection and controls before a disposable split/merge task. Confirm the app’s bundle identifier.

## Evidence

[Dated observations and limits](Experiments/2026-10-historical-checks.md). [Shared enabled-state speech](../../Core/Objects/TurnOverObject.swift)
