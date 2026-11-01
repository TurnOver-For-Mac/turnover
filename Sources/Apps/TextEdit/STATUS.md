# TextEdit

- Bundle id: com.apple.TextEdit
- Support: Partial
- Effort: Module
- Being worked on: Codex for Oliver, issue 212 (local trial pending)
- Checked: 1 November 2026; installed formatting runtime 8514e13, macOS 27.2, Mac keys, VoiceOver off. Both full build gates passed 463 tests, braille checks and all three helper self-tests; 27 combined TextEdit/Ulysses live metadata checks passed. Audio was not independently heard; Oliver’s listening trial remains pending. Earlier navigation checks retain their dates and limits in the evidence.

## Findings

Command-B/Command-I feedback is installed in local candidate `8514e13`. Its formatting worker uses separate AX references so its short timeouts cannot change the reader’s captured handles. Build and live metadata checks passed; Oliver’s listening trial remains pending. [Probe findings and trial limits](Experiments/2026-11-01-formatting-feedback.md). This does not change the existing support grade.

Review navigation and caret-by-character dispatch passed; after opening and dismissing the spelling menu, Down produced speech. These checks do not exercise File-menu entry. The 29–30 October failure with plain Down and Control–Option–Down remains the known gap; do not infer its repair from the regression pass.

Moving between menu-bar titles worked, but opening File and moving down failed with both plain Down and Control–Option–Down. A visible menu could leave accessibility focus on the document. Repair belongs in shared native menu focus handling; no TextEdit-specific adaptation is required. See [issue 194](https://github.com/TurnOver-For-Mac/turnover/issues/194) for current progress.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[Dated investigation](Experiments/2026-10-29-menu-navigation.md) · [How to check the menus](Tests/README.md).
