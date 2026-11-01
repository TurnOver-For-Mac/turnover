# TextEdit

- Bundle id: com.apple.TextEdit
- Support: Partial
- Effort: Module
- Being worked on: Codex for Oliver, issue 212
- Checked: 1 November 2026; TurnOver 22.5, combined runtime ddc21cf, TextEdit 1.21, macOS 27.2, Mac keys, VoiceOver off. Oliver confirmed the combined build’s bold/italic feedback and normal reading/navigation work as expected; the earlier formatting build was also confirmed by ear in Claude’s 1 November review. Earlier navigation checks retain their dates and limits in the evidence.

## Findings

Command-B and Command-I announce the resulting bold or italic state in rich-text documents. Native shortcuts retain their normal delivery. Formatting reads use bounded worker queries and separate AX references so their timeouts do not alter normal reader navigation.

The adapter requires English Format and Font menu titles and the enabled, matching shortcuts. Missing, ambiguous or unsupported menu state stays silent; this does not establish formatting feedback in plain-text documents or other editors. [Observed behavior and limits](Experiments/2026-11-01-formatting-feedback.md). This does not change the existing support grade.

Review navigation and caret-by-character dispatch passed; after opening and dismissing the spelling menu, Down produced speech. These checks do not exercise File-menu entry. The 29–30 October failure with plain Down and Control–Option–Down remains the known gap; do not infer its repair from the regression pass.

Moving between menu-bar titles worked, but opening File and moving down failed with both plain Down and Control–Option–Down. A visible menu could leave accessibility focus on the document. Repair belongs in shared native menu focus handling; no TextEdit-specific adaptation is required. See [issue 194](https://github.com/TurnOver-For-Mac/turnover/issues/194) for current progress.

### How to check

Use the four regression groups: [FormattingFeedbackTests](../../TurnOverTests/FormattingFeedbackTests.swift), [TextEditFormattingTests](../../TurnOverTests/TextEditFormattingTests.swift), [UlyssesFormattingTests](../../TurnOverTests/UlyssesFormattingTests.swift) and [UlyssesFormattingProviderTests](../../TurnOverTests/UlyssesFormattingProviderTests.swift). Repeat the [rich-text trial](Experiments/2026-11-01-formatting-feedback.md#repeatable-trial) to assess actual speech.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[Dated investigation](Experiments/2026-10-29-menu-navigation.md) · [How to check the menus](Tests/README.md).
