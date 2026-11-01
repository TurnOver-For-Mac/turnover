# Cyberduck: historical checks

Recovered on 1 November 2026. These are sanitized historical investigation notes, not new test results or a current-build sign-off.

## Recorded results

- 11 October: masked probes and a browser recording found nameless Back/Forward and Browser/Bookmarks/History buttons. A shared fallback used their tooltips as names. The notes also report transfer rows exposing their details; this is a reading observation, not execution of a transfer.
- The initial Mac item-key run passed 5/5. The Windows half initially stopped before any key; the corrected runner subsequently passed 5/5 in each style. The valid 12 October regression pass records Days 4–5 passing both styles.

## Limits and setup

Connecting to a server, navigating its files and running transfers were left on the stress-test checklist. The historical checks used masked existing state; no server names, usernames, paths or private file content are reproduced.

Unless a result above specifies otherwise, the source sections do not record exact app/macOS versions, a uniquely identified TurnOver binary or a complete VoiceOver on/off and leader-state matrix. Mac and Windows refer to TurnOver keyboard styles on macOS. Historical driver checks report what TurnOver emitted; they do not substitute for Oliver listening to the current installed build. No app was opened, keys sent, code changed or build installed during this recovery.

## Provenance

Recovered from the retained local checkout’s historical testing notes, plus the local application-library note where named. These source filenames identify the original evidence; they are not claims that the historical testing directory was migrated or that its scripts run in today’s harness. The notes describe AI-assisted investigations and separately identify user observations where recorded. Private document, account, file, server and message contents have been omitted.

- `testing/2026-10-11-notes.md — “Day 4 apps” and “Days 4 and 5 in the Windows style”`.
- `testing/2026-10-12-notes.md — “Regression pass before build 17”`.
- `testing/STRESS-TEST.md — Cyberduck checklist`.

## Retained repository evidence

- [Shared object naming](../../../Core/Objects/TurnOverObject.swift).
- [Retained masked browser fixture](../../../../Tests/Fixtures/cyberduck-browser.json).

The fixture/sample remains in the repository for reference. No direct references from the current test harness were found; this record does not claim the harness exercises it.
