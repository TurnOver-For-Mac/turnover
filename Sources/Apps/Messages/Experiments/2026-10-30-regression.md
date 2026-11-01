# Messages: regression checks, 30 October 2026

## Setup and provenance

Claude's release handoff identifies a developer build of 22.4 source `0ed2ab4`. The retained `release-logs/22.4-regression-dev.log` records the counts below; the scenario is `scenarios/regression/core/messages.txt`. App/macOS versions and VoiceOver state were not recorded per case. Mac and Windows mean TurnOver keyboard styles on macOS, not different operating systems.

These summaries contain only test scope and outcomes, not personal screen content. The source log remains local; the test scripts are historical live-driver scenarios, not registrations in the current unit-test executable.

## Result

Moving to conversations produced a numbered response; previous-message and next-part commands reached their expected handlers.

| Scenario | Keyboard style | Passed | Missed | Log line |
| --- | --- | ---: | ---: | ---: |
| day-messages.txt | mac style | 4 | 0 | 25 |
| day-messages.txt | windows style | 4 | 0 | 39 |

## Scope and remaining checks

The 12 October record also reports latest-message reading checks. Sending and new incoming-message announcements were not established by this regression. The later chat-key phase stopped for user activity before completing.

Counts establish the stated assertions. A dispatch assertion checks which TurnOver command ran; a nonempty-speech assertion checks emitted text, not a listening review or exact wording. The release handoff reports 327 passed and 23 missed across the whole suite; those aggregate counts are not this app's score.
