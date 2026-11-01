# Terminal: regression checks, 30 October 2026

## Result

After a command was entered in a new terminal window, the previous-line review handler ran and emitted nonempty speech.

[Scenario](../../../../testing/scenarios/regression/core/terminal.txt) · [Shared setup and interpretation](../../../../docs/APP-TEST-HISTORY.md#30-october-2026-regression-run).

| Scenario | Keyboard style | Passed | Missed | Local log line |
| --- | --- | ---: | ---: | ---: |
| day-terminal.txt | mac style | 2 | 0 | 27 |
| day-terminal.txt | windows style | 2 | 0 | 41 |

## Scope and remaining checks

This grade covers terminal-line review in the tested setup; the assertion did not compare the spoken line with expected command output. Emoji/combining-character editing, long scrollback and shell-specific erase behavior remain separate checks.
