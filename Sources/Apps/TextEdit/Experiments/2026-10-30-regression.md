# TextEdit: regression checks, 30 October 2026

## Setup and provenance

Claude's release handoff identifies a developer build of 22.4 source `0ed2ab4`. The retained `release-logs/22.4-regression-dev.log` records the counts below; the scenario is `scenarios/regression/core/textedit.txt`. App/macOS versions and VoiceOver state were not recorded per case. Mac and Windows mean TurnOver keyboard styles on macOS, not different operating systems.

These summaries contain only test scope and outcomes, not personal screen content. The source log remains local; the test scripts are historical live-driver scenarios, not registrations in the current unit-test executable.

## Result

Review navigation and caret-by-character dispatch passed; after opening and dismissing the spelling menu, Down produced speech.

| Scenario | Keyboard style | Passed | Missed | Log line |
| --- | --- | ---: | ---: | ---: |
| day-textedit.txt | mac style | 3 | 0 | 28 |
| day-textedit.txt | windows style | 3 | 0 | 42 |

## Scope and remaining checks

These checks do not exercise File-menu entry. The 29–30 October failure with plain Down and Control–Option–Down remains the known gap; do not infer its repair from the regression pass.

Counts establish the stated assertions. A dispatch assertion checks which TurnOver command ran; a nonempty-speech assertion checks emitted text, not a listening review or exact wording. The release handoff reports 327 passed and 23 missed across the whole suite; those aggregate counts are not this app's score.
