# Messages: regression checks, 30 October 2026

## Result

Moving to conversations produced a numbered response; previous-message and next-part commands reached their expected handlers.

[Scenario](../../../../testing/scenarios/regression/core/messages.txt) · [Shared setup and interpretation](../../../../docs/APP-TEST-HISTORY.md#30-october-2026-regression-run).

| Scenario | Keyboard style | Passed | Missed | Local log line |
| --- | --- | ---: | ---: | ---: |
| day-messages.txt | mac style | 4 | 0 | 25 |
| day-messages.txt | windows style | 4 | 0 | 39 |

## Scope and remaining checks

The 12 October record also reports latest-message reading checks. Sending and new incoming-message announcements were not established by this regression. The later chat-key phase stopped for user activity before completing.
