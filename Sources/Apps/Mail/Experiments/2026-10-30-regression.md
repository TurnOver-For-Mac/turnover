# Mail: regression checks, 30 October 2026

## Result

Down/Up and movement to the mailbox and message lists reached the expected Mail handlers. All four assertions are command-dispatch checks.

[Scenario](../../../../testing/scenarios/regression/core/mail.txt) · [Shared setup and interpretation](../../../../docs/APP-TEST-HISTORY.md#30-october-2026-regression-run).

| Scenario | Keyboard style | Passed | Missed | Local log line |
| --- | --- | ---: | ---: | ---: |
| day-mail.txt | mac style | 4 | 0 | 23 |
| day-mail.txt | windows style | 4 | 0 | 37 |

## Scope and remaining checks

Message text, useful spoken list output and composing were not asserted by this scenario. The 29 October public-message probe established provider structure, not a listening result.


The earlier structural observation is summarized above; its 29 October source note is [kept locally](../../../../docs/APP-TEST-HISTORY.md#local-application-library-notes). It is provider evidence, separate from the driver assertions.
