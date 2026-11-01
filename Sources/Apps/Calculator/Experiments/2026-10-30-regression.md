# Calculator: regression checks, 30 October 2026

## Setup and provenance

Claude's release handoff identifies a developer build of 22.4 source `0ed2ab4`. The retained `release-logs/22.4-regression-dev.log` records the counts below; the scenario is `scenarios/layer/calculator.txt`. The scenario comment intends VoiceOver to lead, but `scenarios/layer/run.sh` runs the Calculator check before changing the reading mode. The log later records the mode being restored from apps to everywhere (line 197). Neither establishes which reader led during the Calculator check. App/macOS versions and keyboard style were not recorded per case. Mac and Windows mean TurnOver keyboard styles on macOS, not different operating systems.

These summaries contain only test scope and outcomes, not personal screen content. The source log remains local; the test scripts are historical live-driver scenarios, not registrations in the current unit-test executable.

## Result

The TurnOver menu-open and menu-close response checks passed while Calculator was frontmost. Reader leadership was unverified.

| Scenario | Keyboard style | Passed | Missed | Log line |
| --- | --- | ---: | ---: | ---: |
| calculator.txt | not recorded | 2 | 0 | 194 |

## Scope and remaining checks

These two assertions check menu-open and menu-close responses. They do not verify reader handover, Calculator digits, operators, display reading or arithmetic.

Counts establish the stated assertions. A dispatch assertion checks which TurnOver command ran; a nonempty-speech assertion checks emitted text, not a listening review or exact wording. The release handoff reports 327 passed and 23 missed across the whole suite; those aggregate counts are not this app's score.
