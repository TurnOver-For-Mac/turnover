# Voice Memos

- Bundle id: com.apple.VoiceMemos
- Support: Partial
- Effort: None
- Being worked on: Unclaimed
- Checked: 30 October 2026; developer build of 22.4 source 0ed2ab4; Mac and Windows keyboard styles. Setup limits are in the evidence.

## Findings

Four review-item movements produced speech or boundary responses in each style. The earlier check covered an empty window and found an unnamed blank field after the window-button fix. Recording and playback workflows were not verified.

## Evidence

[30 October regression results and scope](Experiments/2026-10-30-regression.md).

[Historical checks and limits](Experiments/2026-10-historical-checks.md). [Retained masked empty-window fixture](../../../Tests/Fixtures/voicememos-empty.json).
