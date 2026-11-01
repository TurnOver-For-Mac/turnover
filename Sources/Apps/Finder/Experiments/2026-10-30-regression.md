# Finder: regression checks, 30 October 2026

## Result

List-arrow and review-navigation dispatch checks passed. Two position-announcement expectations missed in each style.

[Scenario](../../../../testing/scenarios/regression/core/finder.txt) · [Shared setup and interpretation](../../../../docs/APP-TEST-HISTORY.md#30-october-2026-regression-run).

| Scenario | Keyboard style | Passed | Missed | Local log line |
| --- | --- | ---: | ---: | ---: |
| day-finder.txt | mac style | 4 | 2 | 22 |
| day-finder.txt | windows style | 4 | 2 | 36 |

## Scope and remaining checks

The release handoff attributes the missing positions to the number-in-list setting being off, rather than a new release defect. Repeat position checks with the setting stated; this run did not verify rename or file operations.
