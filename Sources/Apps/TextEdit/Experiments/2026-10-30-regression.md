# TextEdit: regression checks, 30 October 2026

## Result

Review navigation and caret-by-character dispatch passed; after opening and dismissing the spelling menu, Down produced speech.

[Scenario](../../../../testing/scenarios/regression/core/textedit.txt) · [Shared setup and interpretation](../../../../docs/APP-TEST-HISTORY.md#30-october-2026-regression-run).

| Scenario | Keyboard style | Passed | Missed | Local log line |
| --- | --- | ---: | ---: | ---: |
| day-textedit.txt | mac style | 3 | 0 | 28 |
| day-textedit.txt | windows style | 3 | 0 | 42 |

## Scope and remaining checks

These checks do not exercise File-menu entry. The 29–30 October failure with plain Down and Control–Option–Down remains the known gap; do not infer its repair from the regression pass.
