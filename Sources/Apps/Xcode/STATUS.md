# Xcode

- Bundle id: com.apple.dt.Xcode
- Support: Partial
- Effort: None
- Being worked on: Unclaimed
- Checked: 30 October 2026; developer build of 22.4 source 0ed2ab4; Mac and Windows keyboard styles. Setup limits are in the evidence.

## Findings

Six of seven navigation checks passed in each style; the first key produced no accepted response. Earlier checks identify the welcome/recent-projects window. Editor, project navigation and debugger tasks remain untested; reset starting focus before comparing styles.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[Historical checks and limits](Experiments/2026-10-historical-checks.md).
