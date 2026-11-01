# Terminal: regression checks, 30 October 2026

## Setup and provenance

Claude's release handoff identifies a developer build of 22.4 source `0ed2ab4`. The retained `release-logs/22.4-regression-dev.log` records the counts below; the scenario is `scenarios/regression/core/terminal.txt`. App/macOS versions and VoiceOver state were not recorded per case. Mac and Windows mean TurnOver keyboard styles on macOS, not different operating systems.

These summaries contain only test scope and outcomes, not personal screen content. The source log remains local; the test scripts are historical live-driver scenarios, not registrations in the current unit-test executable.

## Result

After a command was entered in a new terminal window, the previous-line review handler ran and emitted nonempty speech.

| Scenario | Keyboard style | Passed | Missed | Log line |
| --- | --- | ---: | ---: | ---: |
| day-terminal.txt | mac style | 2 | 0 | 27 |
| day-terminal.txt | windows style | 2 | 0 | 41 |

## Scope and remaining checks

This grade covers terminal-line review in the tested setup; the assertion did not compare the spoken line with expected command output. Emoji/combining-character editing, long scrollback and shell-specific erase behavior remain separate checks.

Counts establish the stated assertions. A dispatch assertion checks which TurnOver command ran; a nonempty-speech assertion checks emitted text, not a listening review or exact wording. The release handoff reports 327 passed and 23 missed across the whole suite; those aggregate counts are not this app's score.
