# Xcode: regression checks, 30 October 2026

## Result

Six of seven navigation checks passed in each style; the first key produced no accepted response.

[Scenario](../../../../testing/scenarios/utilities/xcode.txt) · [Shared setup and interpretation](../../../../docs/APP-TEST-HISTORY.md#30-october-2026-regression-run).

| Scenario | Keyboard style | Passed | Missed | Local log line |
| --- | --- | ---: | ---: | ---: |
| day-xcode.txt | mac style | 6 | 1 | 110 |
| day-xcode.txt | windows style | 6 | 1 | 119 |

## Scope and remaining checks

Earlier checks identify the welcome/recent-projects window. Editor, project navigation and debugger tasks remain untested; reset starting focus before comparing styles.
