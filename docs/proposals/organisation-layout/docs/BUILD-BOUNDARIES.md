# Build boundaries to settle before migration

This is a proposed contract for a future migration. The demo intentionally has no package manifest and makes no claim that its placeholder sources build.

## Production and tests

Do not point a production target at the whole Sources tree. App Tests folders, fixtures, Markdown records and experiment directories need explicit exclusion from production source discovery and resources.

Until a new arrangement is validated, retain the real Sources/TurnOverTests and Tests/Fixtures locations and link them from app records. To move them later, define test-target source membership, preserve the custom runner calls, update fixture discovery and confirm the same meaningful cases still execute.

## Experiments and probes

Sources/Experiments and each app's Experiments directory are excluded from the default reader build. Standalone diagnostic scripts require no runtime feature switch. A reviewed runtime experiment needs an independent opt-in switch and its own controlled inclusion; do not include all experiments recursively.

turnover-probe remains a separate diagnostic executable. The Tools folder in this demo is a discoverability guide, not a proposal to load probes into the reader.

## Module and runtime boundaries

Define a future Apps target and the interfaces it uses before moving code between modules. Application assembly and the test executables must register the same app implementations. Core must not import Apps; registration and app-specific decisions need interfaces in the appropriate shared layer.

Preserve each existing target's actor isolation and the speech, braille and keyboard owners. The Core folder grouping does not merge TurnOverAX, TurnOverSpeech, TurnOverBraille or TurnOverControl.

## Packaging and validation

Inventory helpers, resources, the Safari extension, dynamic libraries and signing paths. Moving a folder must not silently drop files from the installed app.

Use one representative app as a pilot. Separate file moves from behavioural refactors, run required checks, install with a rollback and get Oliver's trial before publishing reader changes.
