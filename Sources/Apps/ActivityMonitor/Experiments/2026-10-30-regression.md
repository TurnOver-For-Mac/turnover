# Activity Monitor: regression checks, 30 October 2026

## Result

Arrow movement, review-item movement and Tab/Shift-Tab in the opened window produced speech or the expected boundary response.

[Scenario](../../../../testing/scenarios/utilities/activitymonitor.txt) · [Shared setup and interpretation](../../../../docs/APP-TEST-HISTORY.md#30-october-2026-regression-run).

| Scenario | Keyboard style | Passed | Missed | Local log line |
| --- | --- | ---: | ---: | ---: |
| day-activitymonitor.txt | mac style | 9 | 0 | 103 |
| day-activitymonitor.txt | windows style | 9 | 0 | 111 |

## Scope and remaining checks

This grade covers read-only navigation of the tested window. Inspecting detailed process data and stopping a process were not checked.
