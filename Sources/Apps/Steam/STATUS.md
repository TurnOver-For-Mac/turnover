# Steam

- Bundle id: com.valvesoftware.steam
- Support: Partial
- Effort: Module
- Being worked on: Unclaimed
- Checked: 30 October 2026; source inventory and Oliver's report of existing Steam speech; version and task details not recorded.

## Findings

Partial scope: Oliver reports existing Steam speech. Task-by-task Big Picture coverage and the test setup have not yet been recorded.

TurnOver already has built-in Steam reading through its Games integration and bundled steam-speech helper. Big Picture reading uses the existing “Read Steam’s Big Picture” opt-in. No separate plugin is required. The helper also supports speech from some Electron games; this does not establish support for every game or the whole Steam client.

Check Big Picture library navigation, a game's detail page, opening and closing its menu, interruption of speech, and switching to another Mac app while the menu is open. Record the working tasks and gaps to refine this assessment.

## Evidence

[Shared Games implementation](../Games/README.md), [Games.swift](../Games/Games.swift), [bundled helper](../../../Helpers/steam-speech) and [existing tests](../../TurnOverTests/GamesTests.swift). Record Steam and macOS versions, TurnOver build, keyboard style and VoiceOver state for each live result. Use public sample content.
