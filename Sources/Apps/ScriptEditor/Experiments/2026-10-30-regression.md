# Script Editor: regression checks, 30 October 2026

## Result

All seven navigation checks passed in Mac style; six of seven passed in Windows style, with a silent first key.

[Scenario](../../../../testing/scenarios/utilities/scripteditor.txt) · [Shared setup and interpretation](../../../../docs/APP-TEST-HISTORY.md#30-october-2026-regression-run).

| Scenario | Keyboard style | Passed | Missed | Local log line |
| --- | --- | ---: | ---: | ---: |
| day-scripteditor.txt | mac style | 7 | 0 | 108 |
| day-scripteditor.txt | windows style | 6 | 1 | 117 |

## Scope and remaining checks

Earlier evidence identifies the open-file panel and focus carried between styles. Script editing, execution and debugging are not covered.
