# Byword: historical checks

Recovered on 1 November 2026. These are sanitized historical investigation notes, not new test results or a current-build sign-off.

## Recorded results

- 10 October: the Day 2 run used an authored public Markdown sample and ran both keyboard styles. The retained Byword scenario presses Down three times and Up once, without typing keys. The note reports a pass.
- A shared symbol fix changed a dot between words in the status line into a pause; Markdown heading markers remained spoken at the selected symbol level.
- A test-runner pass-next-key mistake inserted a control character into the public sample. The pristine copy was restored and the runner changed to stop on that state; this incident is not editing coverage.
- 12 October: the valid second regression run records Byword as passing.

## Limits and setup

The stress-test request to type a line and undo it is an unfinished checklist item, not evidence of editing. The notes do not establish a complete Markdown-authoring workflow.

Unless a result above specifies otherwise, the source sections do not record exact app/macOS versions, a uniquely identified TurnOver binary or a complete VoiceOver on/off and leader-state matrix. Mac and Windows refer to TurnOver keyboard styles on macOS. Historical driver checks report what TurnOver emitted; they do not substitute for Oliver listening to the current installed build. No app was opened, keys sent, code changed or build installed during this recovery.

## Provenance

Recovered from the retained local checkout’s historical testing notes, plus the local application-library note where named. These source filenames identify the original evidence; they are not claims that the historical testing directory was migrated or that its scripts run in today’s harness. The notes describe AI-assisted investigations and separately identify user observations where recorded. Private document, account, file, server and message contents have been omitted.

- `testing/2026-10-10-notes.md — “Day 2 apps”`.
- `testing/scenarios/day2/byword.txt`.
- `testing/2026-10-12-notes.md — “Regression pass before build 17”`.
- `testing/STRESS-TEST.md — Byword checklist`.

## Retained repository evidence

- [Shared symbol handling](../../../TurnOverCore/Symbols.swift).
- [Retained Markdown fixture](../../../../Tests/Fixtures/byword-markdown.json).

The fixture/sample remains in the repository for reference. No direct references from the current test harness were found; this record does not claim the harness exercises it.
