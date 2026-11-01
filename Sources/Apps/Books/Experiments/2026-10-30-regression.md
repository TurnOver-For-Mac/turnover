# Books: regression checks, 30 October 2026

## Setup and provenance

Claude's release handoff identifies a developer build of 22.4 source `0ed2ab4`. The retained `release-logs/22.4-regression-dev.log` records the counts below; the scenario is `scenarios/days4-5/books.txt`. App/macOS versions and VoiceOver state were not recorded per case. Mac and Windows mean TurnOver keyboard styles on macOS, not different operating systems.

These summaries contain only test scope and outcomes, not personal screen content. The source log remains local; the test scripts are historical live-driver scenarios, not registrations in the current unit-test executable.

## Result

Four review-item movements produced speech or boundary responses in each style.

| Scenario | Keyboard style | Passed | Missed | Log line |
| --- | --- | ---: | ---: | ---: |
| day-books.txt | mac style | 4 | 0 | 90 |
| day-books.txt | windows style | 4 | 0 | 96 |

## Scope and remaining checks

The log does not identify a book or a reading location. Library/store control navigation does not establish book-text reading or purchase actions.

Counts establish the stated assertions. A dispatch assertion checks which TurnOver command ran; a nonempty-speech assertion checks emitted text, not a listening review or exact wording. The release handoff reports 327 passed and 23 missed across the whole suite; those aggregate counts are not this app's score.
