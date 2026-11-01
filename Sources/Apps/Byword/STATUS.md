# Byword

- Bundle id: com.metaclassy.byword
- Support: Works
- Effort: None
- Being worked on: Unclaimed
- Checked: 30 October 2026; developer build of 22.4 source 0ed2ab4; Mac and Windows keyboard styles. Setup limits are in the evidence.

## Findings

Down/Up reading in a public Markdown sample produced text, blank-line or expected boundary responses, with four checks in each keyboard style. This grade covers line reading. Typing, undo and a complete authoring workflow were not checked.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[Historical checks and limits](Experiments/2026-10-historical-checks.md). [Shared symbol handling](../../Core/Speech/Symbols.swift). [Retained Markdown fixture](../../../Tests/Fixtures/byword-markdown.json).
