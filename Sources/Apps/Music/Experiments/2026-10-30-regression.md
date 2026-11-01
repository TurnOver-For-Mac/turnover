# Music: regression checks, 30 October 2026

## Setup and provenance

Claude's release handoff identifies a developer build of 22.4 source `0ed2ab4`. The retained `release-logs/22.4-regression-dev.log` records the counts below; the scenario is `scenarios/regression/core/music.txt`. App/macOS versions and VoiceOver state were not recorded per case. Mac and Windows mean TurnOver keyboard styles on macOS, not different operating systems.

These summaries contain only test scope and outcomes, not personal screen content. The source log remains local; the test scripts are historical live-driver scenarios, not registrations in the current unit-test executable.

## Result

The first Down, Down and Up keys after launch reached the expected next/previous Media handlers. These three assertions check command dispatch.

| Scenario | Keyboard style | Passed | Missed | Log line |
| --- | --- | ---: | ---: | ---: |
| day-music.txt | mac style | 3 | 0 | 26 |
| day-music.txt | windows style | 3 | 0 | 40 |

## Scope and remaining checks

The scenario does not assert speech, shelf content or playback. The 29 October foreground probe exposed a clipped Browse sample, which does not establish a reading task.

Counts establish the stated assertions. A dispatch assertion checks which TurnOver command ran; a nonempty-speech assertion checks emitted text, not a listening review or exact wording. The release handoff reports 327 passed and 23 missed across the whole suite; those aggregate counts are not this app's score.

The earlier structural observation is recorded in `TurnOver Notes/Application library.txt`, 29 October 2026; it is provider evidence, separate from the driver assertions above.
