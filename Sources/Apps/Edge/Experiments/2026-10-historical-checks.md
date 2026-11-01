# Microsoft Edge: historical checks

Recovered on 1 November 2026. These are sanitized historical investigation notes, not new test results or a current-build sign-off.

## Recorded results

- 10 October: a disposable Edge copy with an empty profile opened the local synthetic `tools/web/gapps.html` page, which modeled Google-app patterns. The probe examined buffer lines and simulated quick keys.
- The notes report the same result as Chrome after shared fixes for repeated tables, joined listbox options, Chromium toggle buttons/dialogs and unnamed menu/tool bars.
- The test copy and profile were removed afterward. Browsers were not sent live keys or clicks in this run.

## Limits and setup

Real Google services, account workflows, navigation from the address bar and audible browse/focus-mode behavior were not established. The later Edge checklist asks for page loading, quick keys and table reading; it is a plan, not a completed trial. Chrome’s 29 October structural sample is not Edge evidence.

Unless a result above specifies otherwise, the source sections do not record exact app/macOS versions, a uniquely identified TurnOver binary or a complete VoiceOver on/off and leader-state matrix. Mac and Windows refer to TurnOver keyboard styles on macOS. Historical driver checks report what TurnOver emitted; they do not substitute for Oliver listening to the current installed build. No app was opened, keys sent, code changed or build installed during this recovery.

## Provenance

Recovered from the retained local checkout’s historical testing notes, plus the local application-library note where named. These source filenames identify the original evidence; they are not claims that the historical testing directory was migrated or that its scripts run in today’s harness. The notes describe AI-assisted investigations and separately identify user observations where recorded. Private document, account, file, server and message contents have been omitted.

- `testing/2026-10-10-notes.md — “Day 3: Chrome, Google’s apps, Edge (reading only)”`.
- `testing/STRESS-TEST.md — Edge checklist`.
