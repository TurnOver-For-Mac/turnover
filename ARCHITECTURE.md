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

## Source folders

Shared reading code lives in `Sources/Core`, grouped by responsibility. Reusable window and document models live in
`Sources/Views`. Both retain the TurnOverCore target and its existing dependencies. App modules live under `Sources/Apps`, alongside their records, and still compile in TurnOverCore with its existing
MainActor isolation and dependencies. Shared Mac menus, prompts, notifications, the application chooser,
`BuiltInModules` registration and `AppWake` live in `Sources/System`, also within TurnOverCore. The executable
remains in `Sources/TurnOver`. `Package.swift` discovers the `Core`, `Views` and `System` folders and lists app source files individually; it never
includes the whole Sources tree. App records, Tests, Fixtures and Experiments are excluded. The existing test runner
and fixture locations are unchanged. `Tools/check-migration.py` checks this source boundary.
See the [source map](Sources/README.md), [working with app folders](docs/APP-FOLDERS.md) and [app records](Sources/Apps/README.md).
The shared [experiment index](Sources/Experiments/README.md) links existing investigations; it is excluded from all
default targets. Folder grouping does not remove existing dependencies between Core, Views and app helpers.

## The mechanisms that can leave a blind user with no reader

These five decide whether anyone is speaking. Each has a named rule, and since 16 Oct a test where the logic is pure.

| Mechanism | Files | Rule | Test |
|---|---|---|---|
| **Who leads** | `TurnOver/LeadWatcher.swift`, `Core/Lifecycle/LeadPolicy.swift`, `Core/Lifecycle/WakeRestoration.swift` | LeadPolicy decides per-app ownership when enabled. LeadWatcher owns native reader handover. Lock-owned wake restoration waits for an ordinary foreground app, secure input off and input permission, retains intent until observed success, and bounds retries. Another lock or deliberate reader choice retires stale attempts. | `PolicyTests: lead policy`; `WakeRestorationTests` (delayed readiness, retries, cancellation and ownership); installed sleep/wake trial still required |
| **The control channel** | `TurnOverControl/ControlChannel.swift`, `ControlOutput.swift`, `Core/Settings/SettingsBridge.swift` | A Unix socket in TurnOver's folder (mode 600); each connecting process checked by its audit token against "signed through Apple, TurnOver's Team ID" before a line is read. JSON lines: subscribe, ask, patch (Settings), toggle (Key), try (plugin tool), say (Windy). Replies retain connection identity; partial writes retain their suffix. Server output waits for writability, with at most 4 MB queued and buffered together per client; admission happens before scheduling. Persistent client sends have a one-second deadline including queue waiting, discard expired requests, and close on failure. | `ControlChannelTests` (partial writes, slow readers, disconnects, concurrent sends, descriptor reuse); trust checked by hand, 18 Oct 2026 (an unsigned client refused) |
| **VoiceOver silenced** | `TurnOver/VoiceOverTap.swift`, `Helpers/voiceover-quiet` (open, MIT), `Core/Lifecycle/Coexist.swift` | A Core Audio process tap on VoiceOver, set to mute, in a separate helper: "on" and "off" down a pipe, "still" every second (3 s without it and VoiceOver is heard); the pipe closing ends it. The Activity way (16 to 18 Oct) is gone; `ActivityFlow` and `VoiceOverActivity` remain to take an old Activity out once, and for Copy VoiceOver settings' export. | `PolicyTests: VoiceOver Activity` (an archive, and a real export) |
| **The key tap** | `TurnOver/KeyboardHandler.swift`, `Core/Keys/KeyboardSessionState.swift`, `KeyboardActivation.swift`, `InputManager.swift`, `ScriptHandler.swift`, `KeySettings.swift` | A tap on its own thread; the decision (script or pass) is made on main within 150 ms, late answers replayed in order; settings are snapshots. Activation and Coexist muting await the current worker's run-loop acknowledgement. Cancellation immediately passes keys; a replacement waits for actual teardown without blocking main. VoiceOver-off preflight is still issue161. | `PureTests: keys: the keyboard thread's question`; `KeyboardSessionTests` |
| **The watchdog** | `TurnOver/Watchdog.swift`, the start deadline in `TurnOverApp.swift` | Main stalled 4 s: keys through, and the system's own `say` tells the user; 24 s: relaunch. Watched always while coexisting. A start not finished in 20 s ends itself (the Key helper restarts it); three in five minutes are told and stop. | none |
| **The caret wait** | `Core/Text/EditableText.swift` (`EditableText.caretMovement`) | Send the key on with TurnOver's marker, wait for the caret (events within 60 ms, polling to 100 ms), speak the unit. | `textedit-guide` fixture (reading), none for the wait |

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
| The queue and the words | `Core/Speech/Speech.swift` (`enqueue`, `speakObject`, `textInfoSpeech`, the history kept in memory for a consented report), `Symbols.swift`, `Languages.swift`, `Hints.swift` | `PureTests` (symbols, languages, capitals), `PolicyTests` (the pitch and drop rules) |
| Say all | `SayAll.swift` (three chunks ahead; the caret follows each as it starts; tones at the chunk's start) | none |
| The player | `TurnOverSpeech/SpeechPlayer.swift` (100% is the voice as rendered, measured 15 Oct; pitch 0.5–2; the soft knee; device following by UID; the silent-voice fallback to the system language's voice) | `PureTests` (devices, frames) |
| Kokoro, ducking, tones | `KokoroVoice.swift`, `Ducking.swift`, `Tones.swift` | `PureTests` (pipe cuts) |
| Braille | `Core/Braille/*` (output, input with contracted words, the display's keys, history with its private flag); `TurnOverBraille/TOAppleBraille.m` drives USB, HID and Bluetooth on the braille thread, one driver call at a time. Its additive asynchronous close distinguishes pending, released and failed; production callers still wait synchronously (issue 160). Failed unloads retain ownership without retrying. | `PureTests` (short forms); `Tools/tests/braille-thread-test.sh` (nested callbacks, latest frame, gated poll/write/blank/unload, release states and failure retention) |

Formatting shortcut feedback lives in `Core/Text/FormattingFeedback.swift`: unhandled native Command-B/I keep their normal delivery, then a bounded worker asks a verified app provider for the resulting state. `FormattingQuery.swift` owns bounded AX reads; TextEdit's provider uses native menu state, Ulysses' provider checks Markdown XL and a complete bounded paragraph. Unknown states stay silent. Replies expire after one second and are invalidated by keys, mouse clicks, focus/window changes and deactivation. Word's existing scripts remain the owner of its feedback. `FormattingFeedbackTests`, `TextEditFormattingTests`, `UlyssesFormattingTests` and `UlyssesFormattingProviderTests` cover delivery, stale replies and provider limits.

`AppModule` owns native spelling-menu policy, formatting-shortcut ownership, native-announcement suppression, app
hints, unusual table-cell ancestry and supplemental paragraph formatting. Word implements these hooks in its app
folder; shared Core/Views code does not refer to Word types or select Word behavior by bundle identifier.
See [Word module ownership](docs/WORD-MODULE-ISOLATION.md) for the file split and checks.

## Reading

| Part | Files | Rule | Test |
|---|---|---|---|
| Objects | `TurnOverObject.swift`, `ControlTypes.swift`, `EditableText.swift`, `Dialog.swift`, `PreferenceTab.swift`, `SelectableList.swift`, `Slider.swift` (the behaviours every app shares, one class a file since 21 Oct 2026), `ObjectNavigation.swift` (VO Left and Right, interact); `WindowKindSearch.swift`, `AXWalk.swift`, `TurnOverAX/AXReadScope.swift` (bounded background VO-Command-letter search) | NVDA's object model; a nameless group is silent; names from neighbours (PATTERNS.md, Names). Kind searches admit one executing and one latest pending walk, cancel on keys/focus/cursor/handover, and publish only current results. | fixtures; `AXWalkTests` |
| Text | `TextInfo.swift` (`AXTextInfo`: offsets, units, formatting, misspellings by range), `TextTables.swift`, `VoiceOverText.swift` | | `PureTests` (tables, spelling at the edge) |
| Browse mode (pages) | `BrowseMode*.swift`, `WebBuffer.swift`, `WebBufferCollection.swift`, `TurnOverAX/AXSnapshot.swift` (background collection and atomic document publications), `WebTextInfo.swift`, `FocusModePolicy.swift` | `build` requests bounded worker collection and coalesces refreshes; main interprets only captured AX values through existing overlays. Same-page refreshes retain the last publication; navigation/handover cancels obsolete work. Text ranges retain their publication; incomplete reads never claim a complete-page boundary. See [document snapshots](docs/DOCUMENT-SNAPSHOTS.md). | `WebBufferTests` (held providers, cancellation, scopes, limits, presentation), `FixtureTests`, `PureTests` (wrap, find, comma keys) |
| Reusable reading models | `Views/FlatView.swift`, `Views/FlatScreen.swift`, `Views/WebBuffer.swift`, `Views/PanesView.swift` | existing types and developer switches retained; see [Views](Sources/Views/README.md) | existing pure and fixture tests; no new live result from filing |
| App views (data over a window) | `Apps/Chat/ChatView.swift` (Messages, WhatsApp, Discord: the transcript, loading more at both ends), `Apps/Media/MediaView.swift` (Music, Podcasts, TV), `Apps/AppStore/AppStoreView.swift`, `Views/PanesView.swift`; `Recipes.swift` and `Resources/recipes/*.json` describe each app; `TurnOverParts.swift` names the parts a plugin can ask for | a recipe gone unregisters its module | `PureTests` (recipes), `FixtureTests` (panes on a big window) |
| App Store model | `Apps/AppStore/AppStoreModel.swift`, `Apps/AppStore/AppStorePageBuilder.swift`, `Apps/AppStore/AppStorePurchaseConfirmation.swift` | Main owns the complete committed model and command order. One serial worker builds a local copy; session/request/revision checks reject retired results. A confirmation resolves the captured identity; only its live element patches the current entry. | `AppStoreModelTests` (controlled replies, command ordering, recorded carousel); `AppStorePurchaseConfirmationTests` |
| App modules | `Apps/*` (Word policy, document, tables, spelling, text ranges and scripting in separate files; Excel, Mail, Finder, Terminal, Safari, Claude, Dock, the recipe-driven Chat, Media, Panes, App Store) | narrow exceptions per app, never a shared-rule change (the project's working rules; "keep what works") | Word module/page/caret tests; scenarios (live) |
| Settings parts | `Apps/SystemSettings/SystemSettingsAppModule.swift`, `SystemSettingsParts.swift`, `SystemSettingsLabels.swift` | explicit part commands use a bounded worker; fresh window/focus/dialog checks precede writes and delivery; only verified native focus is reported as such. Optional attributed button labels are confined to Settings. | `SystemSettingsModuleTests` |
| Media work ownership | `Apps/Media/MediaWorkOwner.swift`, `Apps/Media/MediaView.swift` | one serial collection lane; immutable snapshots carry actual native window identity. New intent, handover or another window retires reads, publications and actions. | `MediaWorkTests` |
| TV sidebar selection | `Apps/Media/MediaSidebarSelection.swift`, selected by `Apps/Media/MediaAppModule.swift` | the worker validates captured row/outline/cell/label, writes one selected row and verifies membership under a 500 ms cooperative limit. All snapshot publication rejects unchanged/empty body during the transition; a sidebar-derived title is insufficient. | `MediaWorkTests` TV sidebar cases |
| The Mac around the apps | `System/SystemPrompts.swift`, `System/NotificationBanners.swift`, `System/ApplicationChooser.swift`, `System/ForceQuit.swift`, `System/MenuNavigation.swift`, `System/StatusMenus.swift` | TurnOver reads the tuned app and whatever appears over it; VoiceOver reads the rest | none |
| Games | `Apps/Games/Games.swift` (Steam: Big Picture and Electron games through the open helper `Helpers/steam-speech` in the public repo, started without TurnOver's permissions by `DisclaimedSpawn`; the CrossOver bridge on one Mac) | GAMES.md | `GamesTests` |

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

The Code health milestone on GitHub lists the seams: MediaView, AppStoreView and ObjectNavigation split by
responsibility; Word's module is split and its shared-code decisions use app hooks (issue 116). Other work includes
every app quirk out of shared code into its module (issue 2); every
accessibility walk on the main thread given a deadline (the audit issue); the reader's state made testable (issue 3).
None of it changes behaviour, one item or a few related ones make a pull request, and each is the best first contribution for anyone who finds
the code untidy: the tidying is the help.
