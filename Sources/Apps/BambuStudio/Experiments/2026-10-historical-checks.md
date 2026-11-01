# Bambu Studio: historical checks

Recovered on 1 November 2026. These are sanitized historical investigation notes, not new test results or a current-build sign-off.

## Recorded results

- 11 October: masked probes and a home recording identified unnamed pressable home images and release-note reading issues. Shared fixes addressed numbered-list noise, repeated headings and an icon-font glyph used as a button name.
- The initial Mac run passed 5/5; the Windows half stopped before any key because the runner mistook its style switch for user activity. After the runner fix, both keyboard styles passed 5/5. The 12 October valid regression pass also records Days 4–5 passing both styles.
- The home icons remained unnamed. The stress checklist also notes inaccessible Download/Skip controls in the update offer. The sample `bambustudio-profile` supplies labels and project keys, but its existence is not a deployed fix; plugins were off for testers in the historical note.

## Limits and setup

Project opening, Prepare/Preview, printer status and printing were not established by the five item-navigation checks. The sample profile still needs its own validation; its presence does not establish sufficient adaptation or automatic activation.

Unless a result above specifies otherwise, the source sections do not record exact app/macOS versions, a uniquely identified TurnOver binary or a complete VoiceOver on/off and leader-state matrix. Mac and Windows refer to TurnOver keyboard styles on macOS. Historical driver checks report what TurnOver emitted; they do not substitute for Oliver listening to the current installed build. No app was opened, keys sent, code changed or build installed during this recovery.

## Provenance

Recovered from the retained local checkout’s historical testing notes, plus the local application-library note where named. These source filenames identify the original evidence; they are not claims that the historical testing directory was migrated or that its scripts run in today’s harness. The notes describe AI-assisted investigations and separately identify user observations where recorded. Private document, account, file, server and message contents have been omitted.

- `testing/2026-10-11-notes.md — “Day 4 apps” and “Days 4 and 5 in the Windows style”`.
- `testing/2026-10-12-notes.md — “Regression pass before build 17”`.
- `testing/STRESS-TEST.md — Bambu Studio checklist`.

## Retained repository evidence

- [Retained masked home fixture](../../../../Tests/Fixtures/bambu-home.json).
- [Sample profile manifest](../../../../plugins/examples/bambustudio-profile/manifest.json).
- [Sample labels and keys](../../../../plugins/examples/bambustudio-profile/profile.json).

The fixture/sample remains in the repository for reference. No direct references from the current test harness were found; this record does not claim the harness exercises it.
