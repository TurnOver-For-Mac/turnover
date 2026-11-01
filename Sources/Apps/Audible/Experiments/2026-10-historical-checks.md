# Audible: historical checks

Recovered on 1 November 2026. These are sanitized historical investigation notes, not new test results or a current-build sign-off.

## Recorded results

- 11 October: the app opened on a marketing offer. Masked item navigation and an offer recording were taken without accepting or dismissing the offer choice. A shared fix removed a redundant “text” role suffix.
- The initial Mac run passed 4/4; the Windows run stopped before any key. After the runner’s style-switch fix, both styles passed 4/4. The valid 12 October regression pass records Days 4–5 passing both styles.

## Limits and setup

This is coverage of the offer screen, not audiobook access. The stress checklist’s library navigation, opening a book, Play/Pause, chapter list and sleep timer were plans. No account or library contents are included.

Unless a result above specifies otherwise, the source sections do not record exact app/macOS versions, a uniquely identified TurnOver binary or a complete VoiceOver on/off and leader-state matrix. Mac and Windows refer to TurnOver keyboard styles on macOS. Historical driver checks report what TurnOver emitted; they do not substitute for Oliver listening to the current installed build. No app was opened, keys sent, code changed or build installed during this recovery.

## Provenance

Recovered from the retained local checkout’s historical testing notes, plus the local application-library note where named. These source filenames identify the original evidence; they are not claims that the historical testing directory was migrated or that its scripts run in today’s harness. The notes describe AI-assisted investigations and separately identify user observations where recorded. Private document, account, file, server and message contents have been omitted.

- `testing/2026-10-11-notes.md — “Day 5 apps” and “Days 4 and 5 in the Windows style”`.
- `testing/2026-10-12-notes.md — “Regression pass before build 17”`.
- `testing/STRESS-TEST.md — Audible checklist`.

## Retained repository evidence

- [Retained masked offer fixture](../../../../Tests/Fixtures/audible-offer.json).

The fixture/sample remains in the repository for reference. No direct references from the current test harness were found; this record does not claim the harness exercises it.
