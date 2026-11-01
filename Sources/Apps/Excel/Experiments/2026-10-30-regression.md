# Microsoft Excel: regression checks, 30 October 2026

## Result

All seven cell/address expectations missed in each keyboard style; the release handoff says a Microsoft 365 offer stopped the test before the workbook task.

[Scenario](../../../../testing/scenarios/day2/excel.txt) · [Shared setup and interpretation](../../../../docs/APP-TEST-HISTORY.md#30-october-2026-regression-run).

| Scenario | Keyboard style | Passed | Missed | Local log line |
| --- | --- | ---: | ---: | ---: |
| day-excel.txt | mac style | 0 | 7 | 71 |
| day-excel.txt | windows style | 0 | 7 | 82 |

## Scope and remaining checks

The failed setup supplies no new cell-reading result. [Earlier cell-reading and selection checks](2026-10-historical-checks.md) remain the basis for Partial support; a ready workbook is needed to repeat them.
