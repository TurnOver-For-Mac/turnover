# Steam

- Bundle id: com.valvesoftware.steam
- Support: Not assessed
- Effort: Module
- Being worked on: Unclaimed
- Checked: Source inventory, 30 October 2026; Oliver reports existing Steam speech. No task-level Steam assessment was performed for this folder migration.

## Findings

TurnOver already has built-in Steam reading through its Games integration and bundled steam-speech helper. Big Picture reading uses the existing “Read Steam’s Big Picture” opt-in. No separate plugin is required. The helper also supports speech from some Electron games; this does not establish support for every game or the whole Steam client.

Check Big Picture library navigation, a game's detail page, opening and closing its menu, interruption of speech, and switching to another Mac app while the menu is open. Record which tasks work and any gaps before assigning a support grade. “Not assessed” describes the missing task-level record, not the absence of an implementation.

## Evidence

[Shared Games implementation](../Games/README.md), [Games.swift](../Games/Games.swift), [bundled helper](../../../Helpers/steam-speech) and [existing tests](../../TurnOverTests/GamesTests.swift). Record Steam and macOS versions, TurnOver build, keyboard style and VoiceOver state for each live result. Use public sample content.
