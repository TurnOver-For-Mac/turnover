# Passwords: regression checks, 30 October 2026

## Result

Five of six navigation checks passed in each style; the first item key produced no accepted response.

[Scenario](../../../../testing/scenarios/utilities/passwords.txt) · [Shared setup and interpretation](../../../../docs/APP-TEST-HISTORY.md#30-october-2026-regression-run).

| Scenario | Keyboard style | Passed | Missed | Local log line |
| --- | --- | ---: | ---: | ---: |
| day-passwords.txt | mac style | 5 | 1 | 107 |
| day-passwords.txt | windows style | 5 | 1 | 115 |

## Scope and remaining checks

Earlier checks covered the locked screen. The release handoff also identifies a silent first key. Vault access, secret fields and editing are not assessed.
