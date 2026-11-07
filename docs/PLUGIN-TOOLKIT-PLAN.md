# The plugin toolkit: hardened before plugins go to testers (10 Oct 2026)

> **Read first (13 Oct 2026).** The plugin design decisions of 13 Oct (the plugin design notes, "Plugin design decisions", 1 to
> 15, and its code review) supersede older text here where they differ. In particular: community plugins are profiles
> (scripted ones later); capability plugins (their own programs) are official only for now, never signed with
> the maintainer's Developer ID, and started without TurnOver's permissions; a plugin with network access names its sites and
> the user agrees at install; plugins never change the user's settings (a plugin's apps are handed to TurnOver only
> if the user says yes); one plugin per app in the library. Levels, everywhere: **Draft** (its maker's Mac only),
> **Community** (passed every automatic check), **Verified** (reviewed by a person), **Official** (made by TurnOver:
> official plugins, open, and official modules, the built-in app support, closed). One version field per plugin:
> `formatVersion` (the plugin format, which is the Plugin Interface version) plus `minimumTurnOver`.


The brief: "harden the toolkit first before the plugins"; "people can create them by hand rather than using the AI";
"it has to be as good if not better than" NVDA. Plugins stay off for testers (Edition.pluginsInBeta) until the
items marked **gate** below are done.

## What loads (10 Oct 2026)

"Maybe I should allow people to do whatever they want on their own computer, but you can only load in the safe
plugins for now to avoid any dangers." So: people may make and edit anything they like for themselves, but TurnOver
loads only safe plugins, the data kind described here (no code, no files, no network, no other apps). Anything more
powerful waits for a later decision, and if it comes it is the user's own choice on their own Mac, never something a
shared plugin can bring in.

## What NVDA has, and where TurnOver should be better

| | NVDA add-ons | TurnOver plugins (aim) |
|---|---|---|
| Made in | Python, with the whole of NVDA's internals | Data (JSON), no code; or by pointing at things in the app, no file at all |
| Who can make one | Programmers | Anyone: by hand in the app, by hand in a file, or with an AI |
| Power | Anything: app modules, global plugins, overlay classes, events, scripts, drivers, settings panels | Labels, keys, watches, silence, layouts (chat, media, panes, more), and the items below |
| Safety | Full access to the computer; the Add-on Store's review is the only guard | Cannot run code, read files, use the network or touch other apps |
| Breakage | NVDA's yearly API break disables add-ons until their authors update them | The format is versioned and kept: an old plugin keeps working |
| Developer tools | Python console, scratchpad folder with reload (NVDA+Control+F3), log viewer, speech viewer, developer info (NVDA+F1) | Matched below, plus tests that travel with the plugin and a checker that runs without a person listening |
| Sharing | Add-on Store: versions, compatibility, community review | Later: signing, catalogue, revocation. The format carries author, id and version now |

Where NVDA's add-ons win and ours will not, by design: native code (speech and braille drivers, deep hooks).
Those stay TurnOver's own. Scripts in a sandbox (the plugin design notes, phase 3) wait until real plugins show what the data
format cannot say.

## Where it stands (11 Oct 2026)

Items 1 to 5 (the gate) are built and tested in the developer build; the plugins stay off for testers until
the maintainer switches Edition.pluginsInBeta.
- 1: VO-Slash, or This app in the menu (PluginMaker; written TurnOver Shift Slash until 7 Nov 2026, which is the guide): what is this, label, key, watch, silence, undo, my changes, share. Tested
  on Bambu Studio's unnamed home icons (turnover-coretest --maker-test): matched "unnamed graphic inside the document
  homepage, number 1 of 11", read as "…, button", the other ten untouched, the plugin loads with no warnings, undo
  removes it. Labels, silence and watch now respect nth (they did not: one label named all eleven).
- 2: PluginFormat: comments, trailing commas, file and line in every problem, unknown-field warnings with "did you
  mean", choices, formatVersion, minimumTurnOver; JSON Schemas in the app (Resources/plugin-schema).
- 3: the plugins folder is looked at every second, a saved plugin reloads and is said; turnover-plugin listen and
  explain.
- 4: turnover-plugin record <app> <folder>: each new screen into tests/, masked by default.
- 5: tests/expect.json, turnover-plugin test, and turnover-tests runs every carried plugin's tests (sample-textedit).
- Open: the test command inside TurnOver.app needs the replay library shipped beside it and the
  allow-dyld-environment-variables entitlement for that one tool; a signing change, the maintainer's call. Until then it
  runs from a developer build.

## The work, in order

### 1. Make one by hand, in the app (gate)

VoiceOver lets users label an item (VO Shift /); NVDA needs Python for anything. TurnOver should let anyone do it
where they are, with nothing to write:

- **What is this?** A TurnOver key (NVDA's developer info): the item's role, name, identifier, where it sits, and
  the match TurnOver would use for it. Said, and copied.
- **Label this item.** Type a name; the item is called that from now on.
- **Give this item a key.** Press the key: it presses, focuses or reads the item.
- **Read this when it changes.** For a status line or progress bar.
- **Don't announce this.**
- Each one is saved into a plugin of the user's own for that app ("My changes for Bambu Studio"), with the match
  chosen and checked by TurnOver (identifier first; otherwise role with the text beside it, inside its panel).
  Undo, and a list of the changes made, with Return to remove one.
- **Share my changes**: the same plugin as a file, to send or submit.

Done when: Bambu Studio's unnamed home-page buttons are labelled and given keys in a few minutes without opening a
file, and the result passes `turnover-plugin check`.

### 2. A format that stays put and is easy to write by hand (gate)

- `formatVersion` and `minimumTurnOver` in the manifest; TurnOver reads every older version.
- A published schema (JSON Schema) so any editor or AI can validate it.
- Comments allowed (`//` lines) and a trailing comma forgiven: hand-written files fail on less.
- Errors give the file, the line and what was expected, in words ("line 12: `nameFrom` must be one of …").

### 3. The authoring loop (gate)

- A plugin being written lives in a "drafts" folder that TurnOver watches: save the file and TurnOver reloads it and
  says "reloaded", or says the first error. NVDA's scratchpad, without the key press.
- `turnover-plugin listen`: what TurnOver says, live, while the user tries the app, for the author or their AI.
- `turnover-plugin explain <key> <app>`: what a key does there and which rule or command answers it.

### 4. Seeing every screen of the app (gate)

- `turnover-plugin record <app>`: while the user moves through the app, each new window, sheet, tab and pane is
  recorded (content masked, as the brief does). The brief and the checker then see screens the snapshot never
  reached (today it sees only the screen showing).

### 5. Tests that travel with a plugin (gate)

- A plugin may carry `tests/`: recorded screens and, for each, the item focused and what TurnOver should say.
- `turnover-plugin test <folder>` runs them without the app. TurnOver's own build runs the tests of every built-in
  plugin, so a change to TurnOver that breaks a plugin is caught before it ships.

### 6. Packaging and settings

- One file per plugin (`.turnoverplugin`): double-click, the consent summary is spoken, Install.
- A plugin can declare a few options (on/off, a choice); they appear under the plugin in the TurnOver menu.
- The feedback report lists the plugins installed; the checker warns when two plugins claim the same app.

### 7. Saying more (after the gate, driven by the app list)

- **Websites**: a plugin for a site (docs.google.com) as well as an app, with web rules: focus mode for an area,
  how to treat its live announcements, quick keys of its own.
- **Triggers**: when a dialog or element appears, say something; when focus lands on an item, also read another;
  keys that only work in one part.
- **Names from the picture**: an icon button with no name is named from its icon (Vision and the on-device model,
  as image descriptions), cached per app. Also what TurnOver does by itself, item 8.
- **More layouts**: grid (spreadsheets), form, document editor, timeline (audio and video editors).

### 8. TurnOver by itself, in apps nobody has written for

- **Layout found automatically**: a window that is a split of sidebar, list and detail gets the panes layout
  without a recipe ("sidebar, list, detail; Tab moves between them"). A recipe only for the exceptions.
- **Unnamed icon buttons named on the fly** (item 7), so every app gains.
- **Fixes by toolkit, not by app**: Chromium and Electron, Catalyst, SwiftUI, Office. One fix, every app of that kind.
- **Every change checked against every recorded app** (APP-RECIPES-PLAN.md, item 3), so a fix for one app cannot
  quietly change another. The app list (testing/APP-TEST-LIST.md) is what fills that library.

## Next: plugins that can do more (12 Oct 2026)

"I don't want them to be restrictive", but safe for users. Agreed shape (the plugin design notes to be updated with it): plugins
ask for abilities, each listed and agreed at install; they run apart from TurnOver, never with its Accessibility or
Input Monitoring; signed, with Draft, Community tested and Verified levels and a revocation list; TurnOver can always
start with plugins off.

Abilities the first two need, which set the list:
- **Settings and menu items** of their own in the TurnOver menu (Settings, a section per plugin), with on/off,
  choices and numbers, as Games and Kokoro have now. "Such plug ins would have to allow for menus to be added".
- **A local helper process** the plugin brings (Kokoro's speech engine), started and stopped by TurnOver.
- **A voice**: audio buffers into TurnOver's speech player for chosen kinds of speech (say all), with TurnOver's
  fallback to the Mac voice on failure or delay (SpeechPlayer.externalRenderer).
- **Listening on a local port** (Games: the CrossOver speech bridge on 127.0.0.1:52134) and **attaching to a local
  debugging port** (Steam's Big Picture, Electron games).
- **One file in a named folder** (Steam's switch file).
- **Claiming apps to read** (Games: Steam and Wine processes).

The two worked examples to publish, as official plugins: **Steam and CrossOver games** (Games.swift, GAMES.md) and
**Kokoro natural voices** (KokoroVoice.swift; a native Swift engine wanted, no Python, no GPL parts). The work then
goes to TurnOver's spine: stability, app modules people can hook into.
