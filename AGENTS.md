# Repository Guidelines

## Project Structure & Module Organization

TurnOver is a Swift 6 macOS screen reader that works alongside VoiceOver. `Package.swift` defines its targets:

- `Sources/TurnOver/`: app lifecycle, keyboard handling, menus, and VoiceOver coordination.
- `Sources/TurnOverCore/`: reading, navigation, settings, and app-specific `Modules/`.
- `Sources/TurnOverAX/`, `TurnOverSpeech/`, `TurnOverBraille/`, and `TurnOverControl/`: accessibility, audio, braille, and local communication.
- `Sources/TurnOverTests/`: test executable; `Tests/Fixtures/` and `Tests/Plugins/`: recorded windows and plugin samples.
- `Resources/`: bundle configuration, sounds, recipes, and keymaps. `Helpers/` contains separate Swift packages; `Tools/` contains development utilities.
- `Guides/` contains user documentation; `docs/` contains plans. Consult `ARCHITECTURE.md` and `PATTERNS.md` before changing shared behavior.

## Build, Test, and Development Commands

Use a Mac with full Xcode 27 and the macOS 27 SDK; the app targets macOS 14 onward.

- `./build.sh --no-install`: compile, run tests and helper self-tests, and assemble/sign `~/Library/Developer/TurnOver/build/TurnOver.app`.
- `./build.sh`: additionally replace `/Applications/TurnOver.app` and restart it.
- `~/Library/Developer/TurnOver/build/release/turnover-tests -v`: rerun tests verbosely; add a name substring to filter.

Both build commands compile and run tests; `./build.sh` is not an install-only step. Allow a minute or two, with longer builds possible after larger changes. The last displayed product name can remain unchanged while compilation continues; check compiler activity before treating it as a hang. Running `turnover-tests` directly only reruns tests and does not build anything.

For real app testing, follow the README's Developing loop: `./build.sh --no-install`, then `./build.sh`, then exercise `/Applications/TurnOver.app` and inspect the newest log in `~/Library/Application Support/TurnOver/logs/`. Do not use `swift run turnover` for this: the app needs its bundle configuration, resources, embedded helpers, and the code signature its permissions are tied to. A bare executable does not reproduce the installed app's behavior.

## Coding Style & Naming Conventions

Match surrounding Swift: four-space indentation, `UpperCamelCase` types, and `lowerCamelCase` functions/properties. Name files for their primary type or responsibility. No formatter or linter configuration is checked in.

Edit resource JSON rather than generated `EmbeddedResources.swift`; `build.sh` regenerates it. Follow `TESTING.md` when regenerating key-reference guides.

## Swift House Rules

These rules apply to new work. Improve old code where the change touches it; keep wider cleanup in separate, focused pull requests.

### Concurrency and ownership

Keep app and reader state on the main actor. `TurnOver` and `TurnOverCore` use `.defaultIsolation(MainActor.self)` in `Package.swift`, as do several helper and test targets. This is a per-target setting: `TurnOverSpeech`, `TurnOverAX` and `TurnOverControl` do not inherit it, and `TurnOverBraille` is Objective-C. Check the target's settings and the declaration's isolation before moving work across a boundary. Preserve Swift 6 checking.

Use the existing owners for work that leaves main:

| Mechanism | Ownership and return path |
| --- | --- |
| Speech (`Sources/TurnOverSpeech/SpeechPlayer.swift`) | Playback requests enqueue onto the serial speech queue; renderer and player callbacks return there before touching playback state. Synthesizer calls have their own queue because they can hang; settings shared with main use `settingsLock`. Speech completions run on the speech queue: hop to main before changing reader state, as `Sources/TurnOverCore/SayAll.swift` does. |
| Braille (`Sources/TurnOverBraille/TOAppleBraille.m`) | Bluetooth drivers use a dedicated thread with a run loop for channel callbacks. Detection completes on main; subsequent driver calls use `onThread`, which currently waits for the result. USB drivers currently run on the caller's thread. `Sources/TurnOverCore/Braille/AppleBraille.swift` polls from main. Preserve this thread ownership when touching the bridge. |
| Keyboard (`Sources/TurnOver/KeyboardHandler.swift`) | The tap and HID manager own a thread and run loop. Read the locked `KeySettings.current` snapshot there, never mutable `config`. `Sources/TurnOverCore/ScriptHandler.swift` asks main for the decision with a 150 ms limit and handles late answers; preserve the timeout and replay order. |

For synchronous callbacks, `onMain` in `Sources/TurnOverCore/Locked.swift` accepts a `@MainActor` closure and schedules it on main. Async code can call an actor-isolated function with `await` or use `await MainActor.run`. `MainActor.assumeIsolated` only asserts an existing guarantee; it does not move execution. Use it only where the callback's main-actor execution is established.

`Task {}` created in main-actor-isolated code inherits that isolation; it does not move blocking work off main. Keep slow I/O, driver waits and large accessibility walks out of new main-actor work, with a deadline or cancellation path. Prefer structured concurrency for new async operations; retain the queues and run-loop threads needed by the existing framework bridges. Pass checked `Sendable` values or snapshots across boundaries. Do not hold a lock across `await`; after suspension or a delayed callback, recheck the focus, request generation or cancellation state before applying a result.

Every new `nonisolated(unsafe)` or `@unchecked Sendable` needs an adjacent comment explaining why checked isolation cannot express the boundary and what makes **every** access safe: the named lock, owning serial queue/thread, or exclusive transfer. Include setup, callbacks and teardown in that reasoning. These markers do not provide synchronization. Fix ownership first; do not use them, or `@preconcurrency`, just to silence a diagnostic. Existing uses are not permission to copy an unexplained exception.

### Private APIs

Keep private interfaces in their existing narrow bridges. The current dependencies and their purposes are:

| Interface | Where and why |
| --- | --- |
| VoiceOver braille driver bundles; `ScreenReaderOutput` and `ScreenReaderBrailleDriver` frameworks | `Sources/TurnOverBraille/TOAppleBraille.m` loads Apple's display drivers from `/System/Library/ScreenReader/BrailleDrivers` to exchange cells and keys with supported USB and Bluetooth displays. |
| `BrailleTranslation.framework` (`BRLTTableEnumerator`, `BRLTServiceTranslator`) | The same bridge uses VoiceOver's translation tables for output and braille input. Missing output translation falls back to TurnOver's computer braille; input translation returns no text when its table or translator is unavailable. |
| `MultitouchSupport.framework`, including `MTActuator` | `Helpers/trackpad-gestures/Sources/trackpad-gestures/main.swift` reads finger contacts for VoiceOver-style gestures; `Haptics.swift` plays Force Touch waveforms, with public `NSHapticFeedbackManager` as its fallback. The private interface stays in the helper. |
| `responsibility_spawnattrs_setdisclaim` | `Sources/TurnOverCore/DisclaimedSpawn.swift` asks macOS to separate a helper's permission responsibility from TurnOver's, so it does not borrow Accessibility and Input Monitoring access. Check the returned `disclaimed` flag: the current bridge can still launch when this call is unavailable or fails. |
| `AudioDeviceDuck` | `Sources/TurnOverCore/Ducking.swift` lowers other audio clients while leaving TurnOver's voice at full volume. This avoids recording and replaying system audio, which needed recording permission and extra work. Missing symbols disable ducking; preserve restoration on speech end, handover, device changes and exit. |

`Sources/TurnOverCore/VoiceOverCommands.swift` and `VoiceOverSounds.swift` also read private ScreenReader resources for copied command names and familiar event sounds. Preserve their missing-resource fallbacks.

For any new private API, the pull request must name the public alternatives considered and explain why they cannot provide the required behavior. Document the reason beside the bridge, the macOS versions checked, and what happens when a symbol, class or resource is absent or changes. Keep runtime availability checks and cleanup local to that bridge, and update this inventory.

### Simplicity

- Keep one mechanism per file. Extend the existing owner; keep app-specific exceptions in that app's module and shared behavior in the core.
- Comments explain why a workaround or boundary exists and what was observed. Date the observation or measurement, with the app/macOS version when relevant, so someone can retest it later.
- Use the existing frameworks and helpers. Do not add dependencies as part of a routine change; obtain maintainer agreement first, as required by `CONTRIBUTING.md`.

## Testing Guidelines

Tests use a custom harness, not XCTest or `swift test`. Add regression cases to the relevant `*Tests.swift`, using descriptive `test("feature: behavior")` names and `check`/`expect`. No percentage coverage threshold is configured. Run the full build before submitting; check speech changes by ear. Record only public sample content in fixtures, never private mail, chats, or documents.

## Commit & Pull Request Guidelines

History uses descriptive subjects, often prefixed by an area, such as `CI: checkout v5`. Sign off every commit for the DCO: `git commit -s`.

Keep each PR to one change; describe the fix and verification. Link a relevant issue. Open an issue before larger features or changes to focus, speech, keys, or VoiceOver handover. Follow `CONTRIBUTING.md`.

Say what was checked and the result: build/test commands, named regression tests or recorded windows, and what was heard for speech changes. For live checks, name the apps and macOS version, keyboard style, and relevant modes (for example browse/focus mode or which reader leads with VoiceOver on). Name the display and USB/Bluetooth connection for braille changes. State anything untested; a passing build does not establish how speech sounds or a handover behaves. For documentation-only changes, say so and describe the checks that apply.
