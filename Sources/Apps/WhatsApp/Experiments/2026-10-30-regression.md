# WhatsApp: regression checks, 30 October 2026

## Setup and provenance

Claude's release handoff identifies a developer build of 22.4 source `0ed2ab4`. The retained `release-logs/22.4-regression-dev.log` records the counts below; the scenario is `scenarios/regression/core/whatsapp.txt`. App/macOS versions and VoiceOver state were not recorded per case. Mac and Windows mean TurnOver keyboard styles on macOS, not different operating systems.

These summaries contain only test scope and outcomes, not personal screen content. The source log remains local; the test scripts are historical live-driver scenarios, not registrations in the current unit-test executable.

## Result

Conversation, previous-message, previous-part, next-item and return-to-composer commands reached their expected handlers. These five assertions check dispatch.

| Scenario | Keyboard style | Passed | Missed | Log line |
| --- | --- | ---: | ---: | ---: |
| day-whatsapp.txt | mac style | 5 | 0 | 29 |
| day-whatsapp.txt | windows style | 5 | 0 | 43 |

## Scope and remaining checks

The 12 and 15 October records separately establish message reading and older/archived-row navigation. The later 30 October chat-key phase stopped for user activity; sending and incoming-message behavior are not covered.

Counts establish the stated assertions. A dispatch assertion checks which TurnOver command ran; a nonempty-speech assertion checks emitted text, not a listening review or exact wording. The release handoff reports 327 passed and 23 missed across the whole suite; those aggregate counts are not this app's score.
