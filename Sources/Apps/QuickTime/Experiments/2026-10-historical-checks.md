# QuickTime Player: historical checks

Recovered on 1 November 2026. These are sanitized historical investigation notes, not new test results or a current-build sign-off.

## Recorded results

- 11 October: QuickTime played an authored public audio sample, `scenarios/files/harbour-tide.m4a`. The notes report all controls named, timeline expressed in seconds and volume in percent.
- The initial Mac item-key run passed 4/4. The Windows half initially stopped before any key; after the runner fix both styles passed 4/4. A sanitized audio-window recording was retained. The valid 12 October regression pass records Days 4–5 passing both styles.

## Limits and setup

The separate stress checklist asks for Space playback toggling, timeline movement and what is spoken as it moves; it is not a completed check. Video, recording, trimming and exporting are outside this evidence.

Unless a result above specifies otherwise, the source sections do not record exact app/macOS versions, a uniquely identified TurnOver binary or a complete VoiceOver on/off and leader-state matrix. Mac and Windows refer to TurnOver keyboard styles on macOS. Historical driver checks report what TurnOver emitted; they do not substitute for Oliver listening to the current installed build. No app was opened, keys sent, code changed or build installed during this recovery.

## Provenance

Recovered from the retained local checkout’s historical testing notes, plus the local application-library note where named. These source filenames identify the original evidence; they are not claims that the historical testing directory was migrated or that its scripts run in today’s harness. The notes describe AI-assisted investigations and separately identify user observations where recorded. Private document, account, file, server and message contents have been omitted.

- `testing/2026-10-11-notes.md — “Day 5 apps” and completed Windows-style rerun`.
- `testing/2026-10-12-notes.md — valid regression pass`.
- `testing/STRESS-TEST.md — QuickTime Player checklist`.

## Retained repository evidence

- [Retained audio-window fixture](../../../../Tests/Fixtures/quicktime-audio.json).

The fixture/sample remains in the repository for reference. No direct references from the current test harness were found; this record does not claim the harness exercises it.
