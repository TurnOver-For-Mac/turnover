# TextEdit

- Bundle id: com.apple.TextEdit
- Support: Partial
- Effort: None
- Being worked on: Unclaimed
- Checked: 29–30 October 2026; native-menu investigation and 22.4 developer-build regression. Setups are recorded separately in the evidence.

## Findings

Review navigation and caret-by-character dispatch passed; after opening and dismissing the spelling menu, Down produced speech. These checks do not exercise File-menu entry. The 29–30 October failure with plain Down and Control–Option–Down remains the known gap; do not infer its repair from the regression pass.

Moving between menu-bar titles worked, but opening File and moving down failed with both plain Down and Control–Option–Down. A visible menu could leave accessibility focus on the document. Repair belongs in shared native menu focus handling; no TextEdit-specific adaptation is required. See [issue 194](https://github.com/TurnOver-For-Mac/turnover/issues/194) for current progress.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[Dated investigation](Experiments/2026-10-29-menu-navigation.md) · [How to check the menus](Tests/README.md).
