# Passwords: historical checks

Recovered on 1 November 2026. These are sanitized historical investigation notes, not new test results or a current-build sign-off.

## Recorded results

- 12 October: `day-test.sh`, `scenarios/utilities`, live movement keys only, with private words masked, in both Mac and Windows keyboard styles. The surface for Passwords was the locked screen only.
- Across Activity Monitor, Console, Disk Utility, Passwords, Script Editor and Xcode, the suite reported 42/44 Mac and 39/44 Windows. The note attributed the misses to intentional silence/edge handling or starting focus carried between runs, not a demonstrated app-wide pass.
- Tab in both styles landed on an unnamed SwiftUI hosting group that TurnOver intentionally kept silent; Shift-Tab read the password-unlock control. A VoiceOver comparison was left open.
- The valid later regression pass reproduced the same utility limitations; no corrected complete utility rerun is recorded. Up in an empty single-line field being silent was a further suite-wide observation, without a specific app assignment.

## Limits and setup

No unlock, password list, credential inspection, autofill or editing was tested. Masked driver output supports only the named navigation surface; no private process, log, disk, credential, file or project contents are copied.

Unless a result above specifies otherwise, the source sections do not record exact app/macOS versions, a uniquely identified TurnOver binary or a complete VoiceOver on/off and leader-state matrix. Mac and Windows refer to TurnOver keyboard styles on macOS. Historical driver checks report what TurnOver emitted; they do not substitute for Oliver listening to the current installed build. No app was opened, keys sent, code changed or build installed during this recovery.

## Provenance

Recovered from the retained local checkout’s historical testing notes, plus the local application-library note where named. These source filenames identify the original evidence; they are not claims that the historical testing directory was migrated or that its scripts run in today’s harness. The notes describe AI-assisted investigations and separately identify user observations where recorded. Private document, account, file, server and message contents have been omitted.

- `testing/2026-10-12-notes.md — “Utility apps, live” and “Regression pass before build 17”`.
