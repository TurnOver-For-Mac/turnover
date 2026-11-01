# Microsoft Word: regression checks, 30 October 2026

## Setup and provenance

Claude's release handoff identifies a developer build of 22.4 source `0ed2ab4`. The retained `release-logs/22.4-regression-dev.log` records the counts below; the scenario is `scenarios/regression/core/word.txt`. App/macOS versions and VoiceOver state were not recorded per case. Mac and Windows mean TurnOver keyboard styles on macOS, not different operating systems.

These summaries contain only test scope and outcomes, not personal screen content. The source log remains local; the test scripts are historical live-driver scenarios, not registrations in the current unit-test executable.

## Result

The scenario sent sample typing keys in a scratch document, then verified character/review-command dispatch. A separate Windows-style scenario verified previous-sentence dispatch with nonempty speech, next-sentence dispatch and a comment response.

| Scenario | Keyboard style | Passed | Missed | Log line |
| --- | --- | ---: | ---: | ---: |
| day-word.txt | mac style | 3 | 0 | 30 |
| day-word.txt | windows style | 3 | 0 | 44 |
| word.txt | windows style | 6 | 0 | 218 |

## Scope and remaining checks

This grade covers the stated document-navigation checks. Exact spoken text, page-boundary reading, reflow, selection and the boundary-sound change were not validated by these assertions.

Counts establish the stated assertions. A dispatch assertion checks which TurnOver command ran; a nonempty-speech assertion checks emitted text, not a listening review or exact wording. The release handoff reports 327 passed and 23 missed across the whole suite; those aggregate counts are not this app's score.

The separate sentence/comment scenario is `scenarios/keys-apps/word.txt`. The preceding chat-key phase stopped when user activity was detected; no additional chat result is inferred.
