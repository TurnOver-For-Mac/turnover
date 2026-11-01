# MuseScore Studio

- Bundle id: Not recorded
- Support: Not assessed
- Effort:
- Being worked on: Unclaimed
- Checked: 14 October 2026; record recovered 1 November 2026. No fresh live test of the current build.

## Findings

MuseScore Studio 4.7: Getting Started controls read by Tab. A shared check-state fix stopped announcing a control’s state after focus had left it. Elements reused the same Qt accessibility identifier, limiting identifier-based matching. The score itself was not tried.

Current-build task coverage remains unassessed. Next: Use a public sample score to assess score navigation and editing separately from the introductory dialog. Confirm the app’s bundle identifier.

## Evidence

[Dated observations and limits](Experiments/2026-10-historical-checks.md). [Focus-sensitive state announcements](../../TurnOverCore/TurnOverObject.swift)
