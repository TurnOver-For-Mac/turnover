# Shared game and Steam support

[Games.swift](Games.swift) owns the existing built-in Steam integration and shared game speech coordination. It compiles in TurnOverCore with its existing MainActor default. [Steam's record](../Steam/STATUS.md) describes the app-specific checks.

## Reading path

The bundled [steam-speech helper](../../../Helpers/steam-speech) reads Steam Big Picture and supported Electron games. Games starts the helper, accepts its speech and forwards the menu keys when Steam owns the frontmost window. Big Picture reading requires the user's existing opt-in. The helper remains a separate Swift package, installed in the app's Contents/Helpers directory by build.sh.

The shared [SpeechPort](../../Core/Speech/SpeechPort.swift) remains in Core. Games.swift also currently defines HelperLines, used by [HelperProgram](../../Core/Support/HelperProgram.swift), and DataBox, used by SpeechPort. These existing cross-area dependencies are retained; separating them requires a reviewed code change.

## Checks

[GamesTests.swift](../../TurnOverTests/GamesTests.swift) covers bridge commands, helper line framing and game-process recognition. The helper has its own self-tests in the full build. Live Steam checks belong in the app record; passing these tests does not establish coverage of every Steam page or game.
