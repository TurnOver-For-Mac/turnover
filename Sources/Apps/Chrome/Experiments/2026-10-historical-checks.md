# Google Chrome: historical checks

Recovered on 1 November 2026. These are sanitized historical investigation notes, not new test results or a current-build sign-off.

## Recorded results

- 10 October: a disposable browser copy with an empty profile opened the local synthetic `tools/web/gapps.html` page. Probe buffer lines and simulated quick keys checked table duplication, listbox separation, toggle-button/dialog roles and menu/toolbar names. No live browser keys or clicks were sent; actual Google account workflows were not tested. Edge produced the same probe result.
- 29 October: Chrome 156.0.8078.48 (8078.48), macOS 27.2 (26B118), with the application-library note identifying installed local TurnOver build `280d7bf`. Public local HTML was opened for a live structural accessibility probe. The default prefix missed deep content; an extended sample reached 64 nodes / 219 admissions in 53 ms and was clipped. The WebArea was at depth 8 with 44 parameterized names and shared/visible-range AXValues. No document URL or labels were logged.

## Limits and setup

The 29 October probe was not a listening test. Advertised text markers/attributes do not establish successful full-document reading or actions. Browse quick keys, forms and focus-mode transitions were left for Oliver’s trial. The 10 October stress checklist and Chrome sign-off checklist are not completed sign-offs, and the synthetic Google patterns do not prove Docs, Sheets, Slides or Drive support.

Unless a result above specifies otherwise, the source sections do not record exact app/macOS versions, a uniquely identified TurnOver binary or a complete VoiceOver on/off and leader-state matrix. Mac and Windows refer to TurnOver keyboard styles on macOS. Historical driver checks report what TurnOver emitted; they do not substitute for Oliver listening to the current installed build. No app was opened, keys sent, code changed or build installed during this recovery.

## Provenance

Recovered from the retained local checkout’s historical testing notes, plus the local application-library note where named. These source filenames identify the original evidence; they are not claims that the historical testing directory was migrated or that its scripts run in today’s harness. The notes describe AI-assisted investigations and separately identify user observations where recorded. Private document, account, file, server and message contents have been omitted.

- `testing/2026-10-10-notes.md — “Day 3: Chrome, Google’s apps, Edge (reading only)”`.
- `testing/STRESS-TEST.md — Chrome and Google-app checklists`.
- `testing/chrome-signoff-checklist.md — referenced sign-off checklist`.
- `TurnOver Notes/Application library.txt — “CHROME” and “CONTEXT”, 29 October 2026`.

## Retained repository evidence

- [Retained public browser sample](../../../../Tests/Fixtures/public-browser-capabilities.html).

The fixture/sample remains in the repository for reference. No direct references from the current test harness were found; this record does not claim the harness exercises it.
