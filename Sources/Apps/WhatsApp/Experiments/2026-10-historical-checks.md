# WhatsApp: historical checks

Recovered on 1 November 2026. These are sanitized historical investigation notes, not new test results or a current-build sign-off.

## Recorded results

- 12 October: masked live Command-Control-1/2 reads (`chat_latest1`, `chat_latest2`) passed 4/4 in each Mac and Windows keyboard style. The valid regression run also reports core WhatsApp checks passing in both styles and the combined chats suite 16/16. The earlier invalid welcome-screen run is excluded. Oliver’s report that behavior was still odd remained open in the day’s follow-up list.
- 15 October: masked driver checks moved beyond the previous end of the Archived list into newly loaded rows. Because WhatsApp drops rows from the top while loading, an offset was added to maintain numbering; the note explicitly says that numbering change had not yet been heard afterward.
- The same note records repeated whole-window searches and unnecessary loading at the real top. After changes, driver timing for Tab between parts was 15–30 ms after one initial 174 ms entry; the cited load was about 0.2 s instead of 0.5 s. These are historical driver measurements, not a current latency guarantee.

## Limits and setup

The two latest-message commands and the narrow paging/performance checks do not establish sending, new-message announcements, attachments or every list boundary. Post-change row numbering and the earlier user-reported odd behavior require separate verification. No contacts, message bodies or account details are retained.

Unless a result above specifies otherwise, the source sections do not record exact app/macOS versions, a uniquely identified TurnOver binary or a complete VoiceOver on/off and leader-state matrix. Mac and Windows refer to TurnOver keyboard styles on macOS. Historical driver checks report what TurnOver emitted; they do not substitute for Oliver listening to the current installed build. No app was opened, keys sent, code changed or build installed during this recovery.

## Provenance

Recovered from the retained local checkout’s historical testing notes, plus the local application-library note where named. These source filenames identify the original evidence; they are not claims that the historical testing directory was migrated or that its scripts run in today’s harness. The notes describe AI-assisted investigations and separately identify user observations where recorded. Private document, account, file, server and message contents have been omitted.

- `testing/2026-10-12-notes.md — “Command Control 1 and 2 in chats”, valid regression pass and follow-up list`.
- `testing/2026-10-14-parts-sweep.md — 15 October “Discord, signed in” shared-chat and WhatsApp notes`.

## Retained repository evidence

- [Shared chat implementation](../../Chat/ChatAppModule.swift).
- [Shared chat reading model](../../Chat/ChatView.swift).
- [WhatsApp recipe](../../../../Resources/recipes/net.whatsapp.WhatsApp.json).
