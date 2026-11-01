# Ulysses: historical checks

Recovered on 1 November 2026. These are sanitized historical investigation notes, not new test results or a current-build sign-off.

## Recorded results

- 10 October: offline probes, masked recordings and a live `day-test.sh` run covered library/sheet-list item navigation in both Mac and Windows keyboard styles. Untitled table columns that interrupted review were handled by shared navigation.
- The retained scenario uses Control-Option-Right three times and Control-Option-Left once. It does not type or edit a sheet.
- 12 October: a Mac-style miss was the expected text-edge sound at the end of a sheet; the runner was corrected to accept that response. The corrected rerun reports Ulysses 8/8. The first full regression run that day was invalid because TurnOver’s welcome screen prevented it starting; that run is not counted.

## Limits and setup

The later stress-test instructions to open and read a whole sheet, use Say All, and type/delete a test sentence are plans, not completed results. No private sheet title or text is retained here.

Unless a result above specifies otherwise, the source sections do not record exact app/macOS versions, a uniquely identified TurnOver binary or a complete VoiceOver on/off and leader-state matrix. Mac and Windows refer to TurnOver keyboard styles on macOS. Historical driver checks report what TurnOver emitted; they do not substitute for Oliver listening to the current installed build. No app was opened, keys sent, code changed or build installed during this recovery.

## Provenance

Recovered from the retained local checkout’s historical testing notes, plus the local application-library note where named. These source filenames identify the original evidence; they are not claims that the historical testing directory was migrated or that its scripts run in today’s harness. The notes describe AI-assisted investigations and separately identify user observations where recorded. Private document, account, file, server and message contents have been omitted.

- `testing/2026-10-10-notes.md — “Day 2 apps”`.
- `testing/2026-10-12-notes.md — “Regression pass before build 17”`.
- `testing/scenarios/day2/ulysses.txt and testing/scenarios/rerun/day2/ulysses.txt`.
- `testing/STRESS-TEST.md — Ulysses checklist, not a completed run`.

## Retained repository evidence

- [Shared navigation](../../../TurnOverCore/ObjectNavigation.swift).
- [Retained masked library fixture](../../../../Tests/Fixtures/ulysses-library.json).

The fixture/sample remains in the repository for reference. No direct references from the current test harness were found; this record does not claim the harness exercises it.
