# Finder: regression checks, 30 October 2026

## Setup and provenance

Claude's release handoff identifies a developer build of 22.4 source `0ed2ab4`. The retained `release-logs/22.4-regression-dev.log` records the counts below; the scenario is `scenarios/regression/core/finder.txt`. App/macOS versions and VoiceOver state were not recorded per case. Mac and Windows mean TurnOver keyboard styles on macOS, not different operating systems.

These summaries contain only test scope and outcomes, not personal screen content. The source log remains local; the test scripts are historical live-driver scenarios, not registrations in the current unit-test executable.

## Result

List-arrow and review-navigation dispatch checks passed. Two position-announcement expectations missed in each style.

| Scenario | Keyboard style | Passed | Missed | Log line |
| --- | --- | ---: | ---: | ---: |
| day-finder.txt | mac style | 4 | 2 | 22 |
| day-finder.txt | windows style | 4 | 2 | 36 |

## Scope and remaining checks

The release handoff attributes the missing positions to the number-in-list setting being off, rather than a new release defect. Repeat position checks with the setting stated; this run did not verify rename or file operations.

Counts establish the stated assertions. A dispatch assertion checks which TurnOver command ran; a nonempty-speech assertion checks emitted text, not a listening review or exact wording. The release handoff reports 327 passed and 23 missed across the whole suite; those aggregate counts are not this app's score.
