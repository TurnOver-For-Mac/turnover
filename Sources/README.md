# Source map

Start with the area you want to improve.

| Folder | What belongs here | Build boundary |
| --- | --- | --- |
| [Core](Core/README.md) | Shared reading, navigation, text, speech policy, keys, settings and plugins | TurnOverCore |
| [Views](Views/README.md) | Reusable window and document reading models | TurnOverCore |
| [Apps](Apps/README.md) | App implementations, support records and app-specific investigations | Explicit production files in TurnOverCore; records excluded |
| [System](System/README.md) | Mac menus, prompts, notifications, app wake and built-in registration | TurnOverCore |
| [Experiments](Experiments/README.md) | Shared investigations | Excluded from every default target |
| [TurnOver](TurnOver/) | App lifecycle, keyboard thread, native VoiceOver handover and watchdog | Separate executable |
| [TurnOverAX](TurnOverAX/) | Accessibility API bridge and query ownership | Separate library |
| [TurnOverSpeech](TurnOverSpeech/) | Speech rendering and playback queues | Separate library |
| [TurnOverBraille](TurnOverBraille/) | Objective-C driver and translation bridges | Separate library |
| [TurnOverControl](TurnOverControl/) | Signed local control channel | Separate library |
| [TurnOverObjC](TurnOverObjC/) | Objective-C exception bridge | Separate library |

## Tools and tests

[TurnOverKey](TurnOverKey/), [TurnOverSettings](TurnOverSettings/) and [TurnOverPlugin](TurnOverPlugin/) are executable targets. [TurnOverProbe](TurnOverProbe/) and [TurnOverCoreTest](TurnOverCoreTest/) are diagnostic tools. [TurnOverTests](TurnOverTests/), [AXFixtures](AXFixtures/), [AXReplayShim](AXReplayShim/) and [PluginTestKit](PluginTestKit/) provide the test runner and recorded-window checks. [Helpers](../Helpers/) are separate packages.

## Adding or changing work

[Package.swift](../Package.swift) discovers Swift sources recursively in Core, Views and System. List app production sources individually in `coreSources`. Run `python3 Tools/build-app-index.py` after changing app records or documentation; it updates the app index and generated Apps exclusions. For documentation in Core, Views or System, add its path to TurnOverCore's exclusions or put it in docs. The [membership checker](../Tools/check-migration.py) rejects omitted or misplaced code and compiled samples.

Read [architecture](../ARCHITECTURE.md), [contributing](../CONTRIBUTING.md) and [app folder rules](../docs/APP-FOLDERS.md) before changing behavior. Core, Views, Apps and System share a target and have dependencies on one another; review those interfaces before separating them. [CODEOWNERS](../.github/CODEOWNERS) identifies review ownership; app records describe current work and provenance.
