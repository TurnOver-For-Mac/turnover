# Mail: regression checks, 30 October 2026

## Setup and provenance

Claude's release handoff identifies a developer build of 22.4 source `0ed2ab4`. The retained `release-logs/22.4-regression-dev.log` records the counts below; the scenario is `scenarios/regression/core/mail.txt`. App/macOS versions and VoiceOver state were not recorded per case. Mac and Windows mean TurnOver keyboard styles on macOS, not different operating systems.

These summaries contain only test scope and outcomes, not personal screen content. The source log remains local; the test scripts are historical live-driver scenarios, not registrations in the current unit-test executable.

## Result

Down/Up and movement to the mailbox and message lists reached the expected Mail handlers. All four assertions are command-dispatch checks.

| Scenario | Keyboard style | Passed | Missed | Log line |
| --- | --- | ---: | ---: | ---: |
| day-mail.txt | mac style | 4 | 0 | 23 |
| day-mail.txt | windows style | 4 | 0 | 37 |

## Scope and remaining checks

Message text, useful spoken list output and composing were not asserted by this scenario. The 29 October public-message probe established provider structure, not a listening result.

Counts establish the stated assertions. A dispatch assertion checks which TurnOver command ran; a nonempty-speech assertion checks emitted text, not a listening review or exact wording. The release handoff reports 327 passed and 23 missed across the whole suite; those aggregate counts are not this app's score.

The earlier structural observation is recorded in `TurnOver Notes/Application library.txt`, 29 October 2026; it is provider evidence, separate from the driver assertions above.
