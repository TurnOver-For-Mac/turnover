# LibreOffice

- Bundle id: Not recorded
- Support: Not assessed
- Effort: None
- Being worked on: Unclaimed
- Checked: 14 October 2026; record recovered 1 November 2026. No fresh live test of the current build.

## Findings

LibreOffice 26.8: Start Center and Welcome controls read by Tab, but Welcome text was exposed only as an image. Writer character, word and line reading worked in driver checks after shared paragraph-transition fixes. Calc cell values and addresses read once after shared no-caret and duplicate-event fixes. Cells still announced the edit role. Home and End followed LibreOffice’s document navigation, not line navigation.

Current-build task coverage remains unassessed. Next: Verify Writer across paragraph boundaries and Calc value/address/selection announcements on public sample documents. Record the bundle identifier before attaching a fixture or app-specific rule.

## Evidence

[Dated observations and limits](Experiments/2026-10-historical-checks.md). [Shared editable-text behavior](../../TurnOverCore/EditableText.swift) · [Shared object announcements](../../TurnOverCore/TurnOverObject.swift)
