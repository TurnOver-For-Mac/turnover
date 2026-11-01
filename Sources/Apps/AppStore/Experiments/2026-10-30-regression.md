# App Store: regression checks, 30 October 2026

## Setup and provenance

Claude's release handoff identifies a developer build of 22.4 source `0ed2ab4`. The retained `release-logs/22.4-regression-dev.log` records the counts below; the scenario is `scenarios/regression/core/appstore.txt`. App/macOS versions and VoiceOver state were not recorded per case. Mac and Windows mean TurnOver keyboard styles on macOS, not different operating systems.

These summaries contain only test scope and outcomes, not personal screen content. The source log remains local; the test scripts are historical live-driver scenarios, not registrations in the current unit-test executable.

## Result

Down, End and Up reached the expected App Store navigation handlers. These four checks assert command dispatch, not the content spoken or a successful page opening.

| Scenario | Keyboard style | Passed | Missed | Log line |
| --- | --- | ---: | ---: | ---: |
| day-appstore.txt | mac style | 4 | 0 | 17 |
| day-appstore.txt | windows style | 4 | 0 | 31 |

## Scope and remaining checks

The 29 October application-library note records Oliver reporting App Store use with VoiceOver both on and off, and a successful download. Initial reading speed, More/End ordering and offer-action safety need separate checks.

Counts establish the stated assertions. A dispatch assertion checks which TurnOver command ran; a nonempty-speech assertion checks emitted text, not a listening review or exact wording. The release handoff reports 327 passed and 23 missed across the whole suite; those aggregate counts are not this app's score.

The user download result is from `TurnOver Notes/Application library.txt`, recorded 29 October 2026: App Store 3.0 (1027.1.24), macOS 27.2 (26B118). The exact earlier baseline binary used for that user trial is not identified.
