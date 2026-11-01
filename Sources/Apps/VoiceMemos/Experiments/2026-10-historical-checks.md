# Voice Memos: historical checks

Recovered on 1 November 2026. These are sanitized historical investigation notes, not new test results or a current-build sign-off.

## Recorded results

- 11 October: initial welcome/sync prompts were read; syncing was cancelled. There were no recordings. A masked empty-window recording was retained. The initial Mac run passed 4/4; after the runner fix, the completed rerun passed 4/4 in each style. The valid 12 October regression pass records Days 4–5 passing both styles.
- 14 October: `turnover-plugin try` checked the empty Catalyst/SwiftUI window. Shared naming stopped using the green window button’s tooltip as its label, and the driver reported “full screen, button”. The driver’s rejection of Control-Option arrows as Spaces keys was also corrected.
- Tab reached a separator and a nameless blank edit field. The note only conjectures that this was a recording-title field; a recording was needed to judge it.

## Limits and setup

Record, stop, playback and delete remained checklist-only. Empty-window navigation cannot establish recorder accessibility, and the 14 October note does not resolve the unnamed field. Later driver speech output is not an Oliver listening trial.

Unless a result above specifies otherwise, the source sections do not record exact app/macOS versions, a uniquely identified TurnOver binary or a complete VoiceOver on/off and leader-state matrix. Mac and Windows refer to TurnOver keyboard styles on macOS. Historical driver checks report what TurnOver emitted; they do not substitute for Oliver listening to the current installed build. No app was opened, keys sent, code changed or build installed during this recovery.

## Provenance

Recovered from the retained local checkout’s historical testing notes, plus the local application-library note where named. These source filenames identify the original evidence; they are not claims that the historical testing directory was migrated or that its scripts run in today’s harness. The notes describe AI-assisted investigations and separately identify user observations where recorded. Private document, account, file, server and message contents have been omitted.

- `testing/2026-10-11-notes.md — “Day 5 apps” and completed Windows-style rerun`.
- `testing/2026-10-12-notes.md — valid regression pass`.
- `testing/2026-10-14-parts-sweep.md — “Voice Memos (Catalyst/SwiftUI), no recordings”`.
- `testing/STRESS-TEST.md — Voice Memos checklist`.

## Retained repository evidence

- [Retained masked empty-window fixture](../../../../Tests/Fixtures/voicememos-empty.json).

The fixture/sample remains in the repository for reference. No direct references from the current test harness were found; this record does not claim the harness exercises it.
