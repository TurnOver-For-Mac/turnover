# Audacity: recovered observations

Observation date: 14–15 October 2026. Evidence type: Historical live observation. Recovered on 1 November 2026.

## Provenance

Source: `testing/2026-10-14-parts-sweep.md` in the retained project records. This summary preserves the outcome without copying personal screen contents. See [how recovered app evidence is recorded](../../../../docs/APP-TEST-HISTORY.md).

The bundle identifier was not retained in the recovered evidence and has not been verified here. Do not guess it or use this record to register an app rule.

App version is given below only where the source states it. Other missing app/macOS/build/VoiceOver or keyboard-style details are unknown; they must not be filled from today’s installed versions.

## Recorded outcome

Audacity 4 used Qt Quick. A microphone prompt initially prevented accessibility replies; after Oliver answered it, observer registration succeeded. A shared fix removed duplicate or foreign-window children. The plugin-validation question still did not move focus on Tab, even when the key bypassed TurnOver, and its buttons offered no Press action. The attempted activation produced no visible result. Audio editing was not tested.

## Limits and next check

Confirm startup prompts, window ownership and the application’s panel-navigation keys before attempting an audio task. Recheck the validation dialog and record a verified bundle identifier.

These observations were not rerun during record recovery. A snapshot, driver transcript, source comment, format test or unfinished checklist is not an audible current-build trial.
