# TurnOver's shape (26 Oct 2026)

TurnOver is a screen reader for the Mac: NVDA's design rebuilt in Swift 6 (main-actor default isolation), reading
every app while it is on. One reader speaks at a time: TurnOver while it is on, VoiceOver while it is off, and by
default each comes on as the other goes (the swap, Settings, Screen reader behaviour; CoExist, VoiceOver running
alongside and silenced by an audio tap, went on 24 Oct 2026, docs/DECISIONS.md). Three keyboard styles, VoiceOver's,
NVDA's and JAWS's, over one reader. The NVDA source in `reference/nvda` is still the specification where TurnOver has
an NVDA counterpart.

This is a map of the mechanisms, each with its files, its test (or "none"), and where PATTERNS.md or the testing
notes explain its rules. Read it top to bottom once; then PATTERNS.md for how Mac apps misbehave and TurnOver's answers.

## The targets (Package.swift)

| Target | What it is |
|---|---|
| `TurnOverCore` (libTurnOverCore.dylib) | Everything that reads: objects, text, speech, browse mode, app modules, views, plugins, settings. 30,000 lines. |
| `TurnOver` (the app) | What is Mac-specific and stays: the key tap, who leads (LeadWatcher), VoiceOver's silencing (VoiceOverTap and its helper), the export through VoiceOver Utility (ActivityFlow), the watchdog, the menu-bar item, the Command Control Comma menu (MenuAnywhere), the updater, the uninstaller. |
| `TurnOverSpeech` | The audio engine: AVSpeechSynthesizer as a renderer, our own player for cancellation, volume, pitch and device changes. |
| `TurnOverAX` | A thin wrapper over HIServices with timeouts, health and call counting (`AXHealth`, `AXStats`). |
| `TurnOverKey` | The login-item helper: Command Control Period starts and quits TurnOver. Needs no permissions. |
| `TurnOverPlugin` | `turnover-plugin`: the plugin maker's tool. Parked; not built into the product. |
| `TurnOverTests`, `AXFixtures`, `AXReplayShim`, `PluginTestKit`, `TurnOverCoreTest`, `TurnOverProbe` | The tests, the recorded-window replay, a plugin's own screens, the recorder and the probes. TESTING.md. |

## The mechanisms that can leave a blind user with no reader

These five decide whether anyone is speaking. Each has a named rule, and since 16 Oct a test where the logic is pure.

| Mechanism | Files | Rule | Test |
|---|---|---|---|
| **Who leads** | `TurnOver/LeadWatcher.swift`, `TurnOverCore/LeadPolicy.swift` | `LeadPolicy.leads`: the product leads in its tuned apps and games, each unless given to VoiceOver by hand (the menu's This app, saved). LeadWatcher gathers the inputs, waits out secure input, and switches TurnOver active and inactive; VoiceOver is never toggled, except for a game (the Steam exception). | `PolicyTests: lead policy` (a table) |
| **The control channel** | `TurnOverControl/ControlChannel.swift`, `TurnOverCore/SettingsBridge.swift` | A Unix socket in TurnOver's folder (mode 600); each connecting process checked by its audit token against "signed through Apple, TurnOver's Team ID" before a line is read. JSON lines: subscribe, ask, patch (Settings), toggle (Key), try (plugin tool), say (Windy). | tested by hand, 18 Oct 2026 (an unsigned client refused) |
| **VoiceOver silenced** | `TurnOver/VoiceOverTap.swift`, `Helpers/voiceover-quiet` (open, MIT), `TurnOverCore/Coexist.swift` | A Core Audio process tap on VoiceOver, set to mute, in a separate helper: "on" and "off" down a pipe, "still" every second (3 s without it and VoiceOver is heard); the pipe closing ends it. The Activity way (16 to 18 Oct) is gone; `ActivityFlow` and `VoiceOverActivity` remain to take an old Activity out once, and for Copy VoiceOver settings' export. | `PolicyTests: VoiceOver Activity` (an archive, and a real export) |
| **The key tap** | `TurnOver/KeyboardHandler.swift`, `TurnOverCore/InputManager.swift`, `ScriptHandler.swift`, `KeySettings.swift` | A session tap on its own thread; the decision (script or pass) is made on main within 150 ms, late answers replayed in order; the tap never touches settings (a snapshot per key). Stopped first on both quit paths (`TurnOverApp.shutDown`). | `PureTests: keys: the keyboard thread's question` |
| **The watchdog** | `TurnOver/Watchdog.swift`, the start deadline in `TurnOverApp.swift` | Main stalled 4 s: keys through, and the system's own `say` tells the user; 24 s: relaunch. Watched always while coexisting. A start not finished in 20 s ends itself (the Key helper restarts it); three in five minutes are told and stop. | none |
| **The caret wait** | `TurnOverCore/EditableText.swift` (`EditableText.caretMovement`) | Send the key on with TurnOver's marker, wait for the caret (events within 60 ms, polling to 100 ms), speak the unit. | `textedit-guide` fixture (reading), none for the wait |

## How a key becomes speech

1. The tap sees a key down on the keyboard thread. `InputManager.handleKeyDown` cancels speech and asks
   `ScriptHandler.findScript` on main: the user's own keys, global plugins, the app module, the document (browse
   mode), the focus object and its ancestors, then `GlobalCommands`. `findScript(named:)` asks in the same order.
2. Script found: the key is swallowed, the script queued. No script: the key passes through; if it types, the focus
   object gets a `typedCharacter` event (echo by character and word).
3. A caret script sends the key on and waits for the caret (above). Selection changes come from the caret event.
4. Focus changes arrive from `AXHandler` (`AXHandlerApplications`, `AXHandlerNotifications`, `FocusChanges`) as
   events (`Events.swift`): `loseFocus`, `focusEntered` for each new presentable ancestor, then `gainFocus`, which
   goes through global plugins → the app module (`AppModule.handleEvent`; `ignoresFocus` is asked first) → the
   document → the object, and is spoken by `Speech.speakObject`: name, role, value, states, description, shortcut,
   position, then its line. A focus within 0.4 s of the last drops the earlier focus's speech only once the new one
   has words of its own (`Speech.focusMoving`, `dropForFocusUntil`).

## Speech

| Part | Files | Test |
|---|---|---|
| The queue and the words | `TurnOverCore/Speech.swift` (`enqueue`, `speakObject`, `textInfoSpeech`, the history kept in memory for a consented report), `Symbols.swift`, `Languages.swift`, `Hints.swift` | `PureTests` (symbols, languages, capitals), `PolicyTests` (the pitch and drop rules) |
| Say all | `SayAll.swift` (three chunks ahead; the caret follows each as it starts; tones at the chunk's start) | none |
| The player | `TurnOverSpeech/SpeechPlayer.swift` (100% is the voice as rendered, measured 15 Oct; pitch 0.5–2; the soft knee; device following by UID; the silent-voice fallback to the system language's voice) | `PureTests` (devices, frames) |
| Kokoro, ducking, tones | `KokoroVoice.swift`, `Ducking.swift`, `Tones.swift` | `PureTests` (pipe cuts) |
| Braille | `TurnOverCore/Braille/*` (output, input with contracted words, the display's keys, history with its private flag) | `PureTests` (short forms) |

## Reading

| Part | Files | Rule | Test |
|---|---|---|---|
| Objects | `TurnOverObject.swift`, `ControlTypes.swift`, `EditableText.swift`, `Dialog.swift`, `PreferenceTab.swift`, `SelectableList.swift`, `Slider.swift` (the behaviours every app shares, one class a file since 21 Oct 2026), `ObjectNavigation.swift` (VO Left and Right, interact) | NVDA's object model; a nameless group is silent; names from neighbours (PATTERNS.md, Names) | fixtures |
| Text | `TextInfo.swift` (`AXTextInfo`: offsets, units, formatting, misspellings by range), `TextTables.swift`, `VoiceOverText.swift` | | `PureTests` (tables, spelling at the edge) |
| Browse mode (pages) | `BrowseMode*.swift`, `WebBuffer.swift` (the virtual buffer: a 2 s deadline, `isPartial`), `WebTextInfo.swift`, `FocusModePolicy.swift` | `rebuildIfCheap` for the arrows, letters and container keys; `reachForMore` at the end of a page that loads as it scrolls; focus mode on editable and player elements, honouring the automatic-focus-mode setting | `PureTests` (wrap, find, comma keys) |
| Views (data over a window) | `ChatView.swift` (Messages, WhatsApp, Discord: the transcript, loading more at both ends), `MediaView.swift` (Music, Podcasts, TV), `AppStoreView.swift`, `PanesView.swift`; `Recipes.swift` and `Resources/recipes/*.json` describe each app; `TurnOverParts.swift` names the parts a plugin can ask for | a recipe gone unregisters its module | `PureTests` (recipes), `FixtureTests` (panes on a big window) |
| App modules | `Modules/*` (Word 1,465 lines, the Code health milestone's first split, Excel, Mail, Finder, Terminal, Safari, Claude, Dock, the recipe-driven Chat, Media, Panes, App Store) | narrow exceptions per app, never a shared-rule change (the project's working rules; "keep what works") | scenarios (live) |
| The Mac around the apps | `SystemPrompts.swift`, `NotificationBanners.swift`, `ApplicationChooser.swift`, `ForceQuit.swift`, `MenuNavigation.swift`, `StatusMenus.swift` | TurnOver reads the tuned app and whatever appears over it; VoiceOver reads the rest | none |
| Games | `Games.swift` (Steam: Big Picture and Electron games through the open helper `helpers/steam-speech` in the public repo, started without TurnOver's permissions by `DisclaimedSpawn`; the CrossOver bridge on one Mac) | GAMES.md | `GamesTests` |

## Keys

| Part | Files |
|---|---|
| The VoiceOver keys | `VoiceOverKeys.swift`, `VoiceOverParity.swift`, `VoiceOverDecisions.swift` (the rulings), `QuickRotor.swift` (VO-Command with the arrows) |
| The NVDA and JAWS keys | `NVDAParity.swift`, `Keypad.swift`, `TurnOver/WindowsKeys.swift`, `GlobalCommands.swift` (the Windows keys: Option as the Windows key) |
| The menu: Command Control Comma | `TurnOver/MenuAnywhere.swift` (where VoiceOver leads TurnOver steps in for its menu and hands back on close) |
| The trackpad | `Trackpad.swift` (VoiceOver's gestures where TurnOver reads; the open helper `helpers/trackpad-gestures`) |
| The rule | PATTERNS.md: Mac keys do what VoiceOver's do, Windows keys what NVDA's do; TurnOver's own features live under the layer |

## Settings, plugins, distribution

| Part | Files | Test |
|---|---|---|
| Settings | `Config.swift` (`settings.json`, a daily copy, `settings-previous.json`); no settings of TurnOver's own in the product: `TurnOverMenu.swift` has six items (This app, Keys, Copy my VoiceOver settings, Send feedback, About and updates, Quit) | `PureTests` (config) |
| What this build is | `Edition.swift` (the supported apps, the experimental ones, the version and build number, the guide's name, the developer-build switches), `build.sh` (the product's guide, no plugin tool); releases are made by the maintainer with private release tooling | `PolicyTests` (one app) |
| VoiceOver's settings copied | `VoiceOverSettings.swift` (VoiceOver Utility's export by accessibility, read and applied: voice, rate, pitch, volume, verbosity, typing echo, how links and misspellings are marked; undo under About). docs/TOC-PREFERENCES.md is the map. | `PureTests` (the export) |
| Plugins (parked) | `PluginFormat.swift` and the rest stay in the code, off | `PluginTests` |
| Updates | `TurnOver/Updater.swift` (Sparkle: https, EdDSA from the keychain), `TurnOver/Uninstaller.swift` | by hand |
| Feedback and the log | `Feedback.swift` (the report: logs with lengths, the last 15 minutes of speech and 5 minutes around each marked moment, settings without the apps list), `Log.swift` (words only with the `logSpeech` default) | `PureTests` (redaction) |

## Where things live on a Mac

- `~/Library/Application Support/TurnOver`: settings, logs (30 days), VoiceOver exports and an old Activity's marker (`voiceover/`),
  reading positions, marked moments.
- `~/Library/Developer/TurnOver`: the build folders, the tools (sources in `Tools/drivers`), the scenarios (copied
  to `testing/scenarios`), and the
  symbols of a stripped build. Releases are made by the maintainer with private release tooling.

## Where to start tidying

The Code health milestone on GitHub lists the seams: the four biggest files (Word's module, MediaView, AppStoreView,
ObjectNavigation) split along their MARKs; every app quirk out of shared code into its module (issue 2); every
accessibility walk on the main thread given a deadline (the audit issue); the reader's state made testable (issue 3).
None of it changes behaviour, each is one pull request, and each is the best first contribution for anyone who finds
the code untidy: the tidying is the help.
