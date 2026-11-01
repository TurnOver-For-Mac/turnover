# Activity Monitor: regression checks, 30 October 2026

## Setup and provenance

Claude's release handoff identifies a developer build of 22.4 source `0ed2ab4`. The retained `release-logs/22.4-regression-dev.log` records the counts below; the scenario is `scenarios/utilities/activitymonitor.txt`. App/macOS versions and VoiceOver state were not recorded per case. Mac and Windows mean TurnOver keyboard styles on macOS, not different operating systems.

These summaries contain only test scope and outcomes, not personal screen content. The source log remains local; the test scripts are historical live-driver scenarios, not registrations in the current unit-test executable.

## Result

Arrow movement, review-item movement and Tab/Shift-Tab in the opened window produced speech or the expected boundary response.

| Scenario | Keyboard style | Passed | Missed | Log line |
| --- | --- | ---: | ---: | ---: |
| day-activitymonitor.txt | mac style | 9 | 0 | 103 |
| day-activitymonitor.txt | windows style | 9 | 0 | 111 |

## Scope and remaining checks

This grade covers read-only navigation of the tested window. Inspecting detailed process data and stopping a process were not checked.

Counts establish the stated assertions. A dispatch assertion checks which TurnOver command ran; a nonempty-speech assertion checks emitted text, not a listening review or exact wording. The release handoff reports 327 passed and 23 missed across the whole suite; those aggregate counts are not this app's score.
