# Audacity

- Bundle id: Not recorded
- Support: Not assessed
- Effort:
- Being worked on: Unclaimed
- Checked: 14–15 October 2026; record recovered 1 November 2026. No fresh live test of the current build.

## Findings

Audacity 4 used Qt Quick. A microphone prompt initially prevented accessibility replies; after Oliver answered it, observer registration succeeded. A shared fix removed duplicate or foreign-window children. The plugin-validation question still did not move focus on Tab, even when the key bypassed TurnOver, and its buttons offered no Press action. The attempted activation produced no visible result. Audio editing was not tested.

Current-build task coverage remains unassessed. Next: Confirm startup prompts, window ownership and the application’s panel-navigation keys before attempting an audio task. Recheck the validation dialog and record a verified bundle identifier.

## Evidence

[Dated observations and limits](Experiments/2026-10-historical-checks.md). [Observer recovery](../../TurnOverCore/AXHandlerApplications.swift) · [Window-child filtering](../../TurnOverAX/AX.swift)
