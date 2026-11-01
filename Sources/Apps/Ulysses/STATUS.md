# Ulysses

- Bundle id: com.ulyssesapp.mac
- Support: Partial
- Effort: Module
- Being worked on: Codex for Oliver, issue 212 (local trial pending)
- Checked: 1 November 2026; installed formatting runtime 8514e13, macOS 27.2, Mac keys, VoiceOver off. Both full build gates passed 463 tests, braille checks and all three helper self-tests; 27 combined TextEdit/Ulysses live metadata checks passed. Audio was not independently heard; Oliver’s listening trial remains pending. Earlier navigation checks retain their dates and limits in the evidence.

## Findings

Command-B/Command-I feedback is installed in local candidate `8514e13`. Its formatting worker uses separate AX references so its short timeouts cannot change the reader’s captured handles. Build and live metadata checks passed; Oliver’s listening trial remains pending. [Probe findings and trial limits](Experiments/2026-11-01-formatting-feedback.md). This does not change the existing support grade.

Library/sheet-list review navigation passed four checks in each style, accepting speech or the expected text boundary sound. This repeats the corrected 12 October 8/8 result. Sheets below the fold previously exposed a loading placeholder until scrolled. Whole-sheet reading, Say All, typing and editing have not been established by these item-key checks.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[Historical checks and limits](Experiments/2026-10-historical-checks.md). [Shared navigation](../../Core/Objects/ObjectNavigation.swift). [Retained masked library fixture](../../../Tests/Fixtures/ulysses-library.json).
