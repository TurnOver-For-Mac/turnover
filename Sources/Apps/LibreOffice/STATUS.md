# LibreOffice

- Bundle id: Not recorded
- Support: Partial
- Effort: None
- Being worked on: Unclaimed
- Checked: 14 October 2026; setup details are in the linked evidence.

## Findings

LibreOffice 26.8: Start Center and Welcome controls read by Tab, but Welcome text was exposed only as an image. Writer character, word and line reading worked in driver checks after shared paragraph-transition fixes. Calc cell values and addresses read once after shared no-caret and duplicate-event fixes. Cells still announced the edit role. Home and End followed LibreOffice’s document navigation, not line navigation.

Next check: Verify Writer across paragraph boundaries and Calc value/address/selection announcements on public sample documents. Record the bundle identifier before attaching a fixture or app-specific rule.

## Evidence

[Dated observations and limits](Experiments/2026-10-historical-checks.md). [Shared editable-text behavior](../../Core/Text/EditableText.swift) · [Shared object announcements](../../Core/Objects/TurnOverObject.swift)
