# TextEdit

- Bundle id: com.apple.TextEdit
- Support: Partial
- Effort: None
- Being worked on: Unclaimed
- Checked: 29–30 October 2026; TextEdit 1.21 (419), macOS 27.2 (26B118), Mac keyboard style, VoiceOver off.

## Findings

Moving between menu-bar titles worked, but opening File and moving down failed with both plain Down and Control–Option–Down. A visible menu could leave accessibility focus on the document. Repair belongs in shared native menu focus handling; no TextEdit-specific adaptation is required. See [issue 194](https://github.com/TurnOver-For-Mac/turnover/issues/194) for current progress.

## Evidence

[Dated investigation](Experiments/2026-10-29-menu-navigation.md) · [How to check the menus](Tests/README.md).
