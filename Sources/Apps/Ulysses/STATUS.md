# Ulysses

- Bundle id: com.ulyssesapp.mac
- Support: Partial
- Effort: Module
- Being worked on: Codex for Oliver, issue 212
- Checked: 1 November 2026; TurnOver 22.5, runtime 8514e13, Ulysses 42 (84473), macOS 27.2, Mac keys, VoiceOver off. Oliver confirmed bold and italic shortcut feedback by ear at the typing cursor and with text selected. Earlier navigation checks retain their dates and limits in the evidence.

## Findings

Command-B and Command-I announce the resulting bold or italic state in Markdown XL. Native shortcuts retain their normal delivery; unknown states stay silent. Formatting reads use bounded worker queries and separate AX references so their timeouts do not alter normal reader navigation.

The adapter requires English menu titles and the built-in Markdown XL scheme. Other markup, custom schemes, unsupported syntax, cross-paragraph selections and incomplete provider results stay silent. This does not change the existing support grade. [Observed behavior and limits](Experiments/2026-11-01-formatting-feedback.md).

Library/sheet-list review navigation passed four checks in each style, accepting speech or the expected text boundary sound. This repeats the corrected 12 October 8/8 result. Sheets below the fold previously exposed a loading placeholder until scrolled. Whole-sheet reading, Say All, typing and editing have not been established by these item-key checks.

### How to check

Use the four regression groups: [FormattingFeedbackTests](../../TurnOverTests/FormattingFeedbackTests.swift), [TextEditFormattingTests](../../TurnOverTests/TextEditFormattingTests.swift), [UlyssesFormattingTests](../../TurnOverTests/UlyssesFormattingTests.swift) and [UlyssesFormattingProviderTests](../../TurnOverTests/UlyssesFormattingProviderTests.swift). Repeat the [disposable-sheet trial](Experiments/2026-11-01-formatting-feedback.md#repeatable-trial) to assess actual speech.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[Historical checks and limits](Experiments/2026-10-historical-checks.md). [Shared navigation](../../Core/Objects/ObjectNavigation.swift). [Retained masked library fixture](../../../Tests/Fixtures/ulysses-library.json).
