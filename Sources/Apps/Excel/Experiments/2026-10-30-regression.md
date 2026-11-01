# Microsoft Excel: regression checks, 30 October 2026

## Setup and provenance

Claude's release handoff identifies a developer build of 22.4 source `0ed2ab4`. The retained `release-logs/22.4-regression-dev.log` records the counts below; the scenario is `scenarios/day2/excel.txt`. App/macOS versions and VoiceOver state were not recorded per case. Mac and Windows mean TurnOver keyboard styles on macOS, not different operating systems.

These summaries contain only test scope and outcomes, not personal screen content. The source log remains local; the test scripts are historical live-driver scenarios, not registrations in the current unit-test executable.

## Result

All seven cell/address expectations missed in each keyboard style; the release handoff says a Microsoft 365 offer stopped the test before the workbook task.

| Scenario | Keyboard style | Passed | Missed | Log line |
| --- | --- | ---: | ---: | ---: |
| day-excel.txt | mac style | 0 | 7 | 71 |
| day-excel.txt | windows style | 0 | 7 | 82 |

## Scope and remaining checks

The failed setup supplies no new cell-reading result. [Earlier cell-reading and selection checks](2026-10-historical-checks.md) remain the basis for Partial support; a ready workbook is needed to repeat them.

Counts establish the stated assertions. A dispatch assertion checks which TurnOver command ran; a nonempty-speech assertion checks emitted text, not a listening review or exact wording. The release handoff reports 327 passed and 23 missed across the whole suite; those aggregate counts are not this app's score.
