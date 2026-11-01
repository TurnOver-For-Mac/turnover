# App Store: regression checks, 30 October 2026

## Result

Down, End and Up reached the expected App Store navigation handlers. These four checks assert command dispatch, not the content spoken or a successful page opening.

[Scenario](../../../../testing/scenarios/regression/core/appstore.txt) · [Shared setup and interpretation](../../../../docs/APP-TEST-HISTORY.md#30-october-2026-regression-run).

| Scenario | Keyboard style | Passed | Missed | Local log line |
| --- | --- | ---: | ---: | ---: |
| day-appstore.txt | mac style | 4 | 0 | 17 |
| day-appstore.txt | windows style | 4 | 0 | 31 |

## Scope and remaining checks

The 29 October application-library note records Oliver reporting App Store use with VoiceOver both on and off, and a successful download. Initial reading speed, More/End ordering and offer-action safety need separate checks.


The user download result is summarized from a [local 29 October note](../../../../docs/APP-TEST-HISTORY.md#local-application-library-notes): App Store 3.0 (1027.1.24), macOS 27.2 (26B118). The exact earlier baseline binary used for that user trial is not identified.
