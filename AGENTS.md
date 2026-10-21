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

Match surrounding Swift: four-space indentation, `UpperCamelCase` types, and `lowerCamelCase` functions/properties. Name files for their primary type or responsibility. No formatter or linter configuration is checked in. Preserve target-specific main-actor isolation. Comments should explain reasons or observed behavior. Keep app-specific exceptions in their modules; discuss new dependencies first.

Edit resource JSON rather than generated `EmbeddedResources.swift`; `build.sh` regenerates it. Follow `TESTING.md` when regenerating key-reference guides.

## Testing Guidelines

Tests use a custom harness, not XCTest or `swift test`. Add regression cases to the relevant `*Tests.swift`, using descriptive `test("feature: behavior")` names and `check`/`expect`. No percentage coverage threshold is configured. Run the full build before submitting; check speech changes by ear. Record only public sample content in fixtures, never private mail, chats, or documents.

## Commit & Pull Request Guidelines

History uses descriptive subjects, often prefixed by an area, such as `CI: checkout v5`. Sign off every commit for the DCO: `git commit -s`.

Keep each PR to one change; describe the fix and verification. Link a relevant issue. Open an issue before larger features or changes to focus, speech, keys, or VoiceOver handover. Follow `CONTRIBUTING.md`.
