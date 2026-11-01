# OBS Studio

- Bundle id: Not recorded
- Support: Not assessed
- Effort:
- Being worked on: Unclaimed
- Checked: 15 October 2026; record recovered 1 November 2026. No fresh live test of the current build.

## Findings

The permissions review exposed buttons by Tab, but the camera and microphone request buttons had indistinguishable names because their group labels were not included. The note reports the same names with VoiceOver. After Continue, OBS stopped answering; the process had to be terminated. Recording and streaming were not tested.

Current-build task coverage remains unassessed. Next: Confirm identity, check whether startup recovers, and assess permissions labels before a disposable scene. Do not start recording or streaming as part of a navigation-only check.

## Evidence

[Dated observations and limits](Experiments/2026-10-historical-checks.md).
