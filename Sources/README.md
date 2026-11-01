# Source map

Start with the area you want to improve. These folders group the existing code; they do not create new Swift modules or assign new maintainers.

| Folder | What belongs here | Build boundary |
| --- | --- | --- |
| [Core](Core/README.md) | Shared reading, navigation, text, speech policy, keys, settings and plugins | TurnOverCore |
| [Views](Views/README.md) | Reusable window and document reading models | TurnOverCore |
| [Apps](Apps/README.md) | App implementations, support records and app-specific investigations | Explicit production files in TurnOverCore; records excluded |
| [System](System/README.md) | Mac menus, prompts, notifications, app wake and built-in registration | TurnOverCore |
| [Experiments](Experiments/README.md) | Shared investigation index and future research records | Excluded from every default target |
| [TurnOver](TurnOver/) | App lifecycle, keyboard thread, native VoiceOver handover and watchdog | Separate executable |
| [TurnOverAX](TurnOverAX/) | Accessibility API bridge and query ownership | Separate library |
| [TurnOverSpeech](TurnOverSpeech/) | Speech rendering and playback queues | Separate library |
| [TurnOverBraille](TurnOverBraille/) | Objective-C driver and translation bridges | Separate library |
| [TurnOverControl](TurnOverControl/) | Signed local control channel | Separate library |
| [TurnOverObjC](TurnOverObjC/) | Objective-C exception bridge | Separate library |

## Tools and tests

[TurnOverKey](TurnOverKey/), [TurnOverSettings](TurnOverSettings/) and [TurnOverPlugin](TurnOverPlugin/) retain their own executable targets. [TurnOverProbe](TurnOverProbe/) and [TurnOverCoreTest](TurnOverCoreTest/) are diagnostic tools; [TurnOverTests](TurnOverTests/), [AXFixtures](AXFixtures/), [AXReplayShim](AXReplayShim/) and [PluginTestKit](PluginTestKit/) provide the existing test runner and recorded-window checks. Their locations and registrations are unchanged. [Helpers](../Helpers/) retain separate packages.

## Adding or changing work

[Package.swift](../Package.swift) discovers Swift sources recursively in Core, Views and System. App production sources are listed individually. Add exclusions for new documentation, tests and fixtures; never add the whole Sources or Apps tree to a target. The [membership checker](../Tools/check-migration.py) rejects omitted or misplaced code and compiled samples.

Read [architecture](../ARCHITECTURE.md), [contributing](../CONTRIBUTING.md) and [app folder rules](../docs/APP-FOLDERS.md) before changing behavior. Existing dependencies between these areas remain: filing is not dependency isolation. [CODEOWNERS](../.github/CODEOWNERS) identifies review ownership; app records distinguish current work from provenance.
