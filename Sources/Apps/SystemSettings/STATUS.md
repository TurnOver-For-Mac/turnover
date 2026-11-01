# System Settings

- Bundle id: com.apple.systempreferences
- Support: Partial
- Effort: Module
- Being worked on: Unclaimed
- Checked: 30 October 2026; developer build of 22.4 source 0ed2ab4; Mac and Windows keyboard styles. Setup limits are in the evidence.

## Findings

Three review-item movements produced nonempty speech in the opened window. The 29 October probe identified sidebar/search/detail structure and General-button labels. Neither that probe nor this scenario establishes native focus writes, every pane or changing a setting.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[App implementation](SystemSettingsAppModule.swift).
