# Messages: historical checks

Recovered on 1 November 2026. These are sanitized historical investigation notes, not new test results or a current-build sign-off.

## Recorded results

- 12 October: a masked live driver run in both Mac and Windows keyboard styles reported Messages 4/4 in each. Command-Control-1 and Command-Control-2 (`chat_latest1` and `chat_latest2`) ran and read a message.
- The valid second regression run records core Messages checks passing in both styles, alongside a combined chats suite of 16/16. The initial regression run was invalid because TurnOver had not started and VoiceOver was speaking; it is excluded.
- The 15 October parts-sweep note says Messages and WhatsApp retained the existing recipe path when match-based chat support was added for Discord. It also refers to Messages’ existing upward paging action; this is implementation context, not a fresh Messages trial.

## Limits and setup

Do not infer sending, new-message announcements, attachment handling, reactions or full transcript coverage from latest-message reads. No sender, recipient, conversation title or message text is retained.

Unless a result above specifies otherwise, the source sections do not record exact app/macOS versions, a uniquely identified TurnOver binary or a complete VoiceOver on/off and leader-state matrix. Mac and Windows refer to TurnOver keyboard styles on macOS. Historical driver checks report what TurnOver emitted; they do not substitute for Oliver listening to the current installed build. No app was opened, keys sent, code changed or build installed during this recovery.

## Provenance

Recovered from the retained local checkout’s historical testing notes, plus the local application-library note where named. These source filenames identify the original evidence; they are not claims that the historical testing directory was migrated or that its scripts run in today’s harness. The notes describe AI-assisted investigations and separately identify user observations where recorded. Private document, account, file, server and message contents have been omitted.

- `testing/2026-10-12-notes.md — “Command Control 1 and 2 in chats” and valid regression pass`.
- `testing/2026-10-14-parts-sweep.md — 15 October “Discord, signed in” shared-chat notes`.

## Retained repository evidence

- [Shared chat implementation](../../Chat/ChatAppModule.swift).
- [Shared chat reading model](../../Chat/ChatView.swift).
- [Messages recipe](../../../../Resources/recipes/com.apple.MobileSMS.json).
