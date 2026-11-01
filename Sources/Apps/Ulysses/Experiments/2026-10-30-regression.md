# Ulysses: regression checks, 30 October 2026

## Setup and provenance

Claude's release handoff identifies a developer build of 22.4 source `0ed2ab4`. The retained `release-logs/22.4-regression-dev.log` records the counts below; the scenario is `scenarios/day2/ulysses.txt`. App/macOS versions and VoiceOver state were not recorded per case. Mac and Windows mean TurnOver keyboard styles on macOS, not different operating systems.

These summaries contain only test scope and outcomes, not personal screen content. The source log remains local; the test scripts are historical live-driver scenarios, not registrations in the current unit-test executable.

## Result

Library/sheet-list review navigation passed four checks in each style, accepting speech or the expected text boundary sound. This repeats the corrected 12 October 8/8 result.

| Scenario | Keyboard style | Passed | Missed | Log line |
| --- | --- | ---: | ---: | ---: |
| day-ulysses.txt | mac style | 4 | 0 | 73 |
| day-ulysses.txt | windows style | 4 | 0 | 84 |

## Scope and remaining checks

Sheets below the fold previously exposed a loading placeholder until scrolled. Whole-sheet reading, Say All, typing and editing have not been established by these item-key checks.

Counts establish the stated assertions. A dispatch assertion checks which TurnOver command ran; a nonempty-speech assertion checks emitted text, not a listening review or exact wording. The release handoff reports 327 passed and 23 missed across the whole suite; those aggregate counts are not this app's score.
