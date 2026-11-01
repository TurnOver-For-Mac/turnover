# QuickTime Player

- Bundle id: com.apple.QuickTimePlayerX
- Support: Partial
- Effort: None
- Being worked on: Unclaimed
- Checked: 30 October 2026; developer build of 22.4 source 0ed2ab4; Mac and Windows keyboard styles. Setup limits are in the evidence.

## Findings

Four review-item movements produced speech or boundary responses in each style. The earlier audio-sample check found named controls, a timeline in seconds and volume in percent. Playback toggling, timeline changes, recording, trimming and export remain outside the recorded checks.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[Historical checks and limits](Experiments/2026-10-historical-checks.md). [Retained audio-window fixture](../../../Tests/Fixtures/quicktime-audio.json).
