# Writing an app module

An app module is the code that teaches TurnOver one app: which control has the focus when the app reports it wrongly,
what to call a button the app leaves unnamed, what to say when a key changes something the app doesn't announce. This
guide takes you from choosing an app to a pull request. It is written for people and for the AI assistants many of
them work with; `AGENTS.md` has the house rules both follow.

You need a Mac with Xcode 27, a clone of this repository, and an hour or two with the app. You don't need to know
TurnOver's whole codebase: a module talks to TurnOver through one class, `AppModule` (`Sources/Core/AppModule.swift`).

## Before you start

### Pick an app, and claim it

Every app TurnOver has looked at has a record: `Sources/Apps/<App>/STATUS.md`, listed in
[`Sources/Apps/README.md`](Sources/Apps/README.md) by how well it works. Each record says:

- **Support**: Works, Partial, Blocked, or Not assessed.
- **Effort**: what it takes. None, Settings or plugin, Module (app-specific code), Workaround, or No route known.
- **Being worked on**: a person and an issue, or Unclaimed.

To claim an app, open an issue with the **Work on an app** form. Say which app, and what you'll try first. That
stops two people building the same thing. A claim is not ownership: if you stop, say so on the issue and the app goes
back to Unclaimed. Your pull request sets "Being worked on" in the app's `STATUS.md` to you and the issue.

An app with no record yet is fine: your pull request adds one.

### Look before you code

Use the app with VoiceOver first, then with TurnOver, and write down what goes wrong, task by task: "Tab from the
search field says button, with no name", not "it's not accessible". Note what VoiceOver says for the same thing; Mac
keys in TurnOver do what VoiceOver's do.

Then look at what the app reports to accessibility. Accessibility Inspector (in Xcode, Open Developer Tool) shows each
element's role, name, description and value. Most module work is finding the attribute that holds what the user needs.

## What a module can do

A module is a subclass of `AppModule`, one per running copy of the app. You override only what the app needs. The
hooks, roughly in the order you're likely to want them:

### Keys: scripts

`script(name, description, gestures:, category:) { gesture in ... }` binds keys that work anywhere in the app. The
gesture names are like `kb:enter`, `kb:escape`, `kb:numpadEnter`, `kb:command+shift+n`, `kb:turnover+shift+n`.

Call `gesture.send()` to pass the key on to the app, then say what happened. The description is what the key list and
keyboard help say, so write it as a command: "Equals, then the answer".

### Events: what the app does

`handleEvent(_ event: Event, next: () -> Void)` sees every event from the app before TurnOver's own handling. The
kinds are in `EventKind` (`Sources/Core/Accessibility/Events.swift`): `gainFocus`, `valueChange`, `nameChange`,
`stateChange`, `caret`, `selection`, `textChange`, `alert`, `typedCharacter`, `liveRegionChange` and others.

Handle what you need, and call `next()` for everything else, so TurnOver's normal behaviour carries on.
`event_appModuleGainFocus()` and `event_appModuleLoseFocus()` run when the app comes to the front and leaves it.

### Controls: object classes

`objectClass(for:role:subrole:)` returns your own subclass of `TurnOverObject` for some of the app's controls. In it,
override `name`, `role`, `value`, `description` or `states` to say what the app should have reported. Return `nil`
for every other control.

### Focus

- `redirectFocus(_:)`: where the app reports the focus on the wrong element, return the one that really has it.
- `ignoresFocus(_:)`: a focus report the app sends that the user should never hear.

### Reading

- `browseRoot(for:ancestors:)`: read part of a window as a document in browse mode, as Books and Kindle do.
- `sayAllReachedEnd(_:resume:)`: say all can carry on past the end, as Kindle does when it turns the page.

### Other hooks

There are smaller ones: hints, spelling, formatting shortcuts, grids and announcements the app makes itself. Each is
one line of documentation in `AppModule.swift`; read the list before inventing a workaround.

### Settings

`menuItems()` gives the app its own section of the TurnOver menu, for an app setting a user may want to change.

## Two modules to copy

[Calculator](Sources/Apps/Calculator/CalculatorAppModule.swift), 68 lines, is the smallest. Calculator's display
announces nothing, so the module speaks each key as it's typed (`handleEvent` with `typedCharacter`), and reads the
display after Return, Escape or =. Return and Escape have scripts of their own.

[Books](Sources/Apps/Books/BooksAppModule.swift), 35 lines, uses the other two big hooks:

- `browseRoot` reads the window's content as a document.
- `objectClass` names the unnamed arrow buttons at each end of a shelf, by where they sit: "previous" and "next".

Both start with a comment that says what was wrong, what was measured, and when. Keep that habit: the next person to
touch your module needs to know why each line is there.

## Making it

### 1. The folder

Everything about an app lives in `Sources/Apps/<App>/` ([`docs/APP-FOLDERS.md`](docs/APP-FOLDERS.md) has the
details):

- `<App>AppModule.swift`: the module.
- `STATUS.md`: the record. Copy an existing one; the fields are fixed, and `Tools/build-app-index.py --check` checks
  them.
- `Experiments/`: dated notes of what you tried, from [`docs/EXPERIMENT-TEMPLATE.md`](docs/EXPERIMENT-TEMPLATE.md).
  What didn't work is worth keeping too.
- `Tests/README.md`: how to check the app by hand, step by step.

### 2. The skeleton

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
// <App> (<date>): what was wrong, how you found it (Accessibility Inspector, the driver, by ear), and what the
// module changes.
import Foundation
import ApplicationServices

final class ExampleAppModule: AppModule {
    static let bundleID = "com.example.app"

    required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
        script("example_readStatus", String(localized: "Reads the status line", comment: "A command, as the key list and keyboard help say it"),
               gestures: ["kb:turnover+shift+s"], category: "Example") { [weak self] _ in self?.readStatus() }
    }

    override func handleEvent(_ event: Event, next: () -> Void) {
        // Only what this app needs; everything else goes on.
        next()
    }

    private func readStatus() { /* find the element, then Speech.speakMessage(...) */ }
}
```

Find an app's bundle id with `osascript -e 'id of app "Name"'`.

### 3. Register it

- Add a line to `Sources/System/BuiltInModules.swift`:
  `h.register(ExampleAppModule.self, for: ExampleAppModule.bundleID)`.
- Add each new Swift file to `coreSources` in `Package.swift`.
- Run `python3 Tools/build-app-index.py`, which lists your record in `Sources/Apps/README.md` and keeps `Package.swift`'s
  exclusions in step.

### 4. Build and try it

```bash
./build.sh --no-install
```

That compiles, runs every test, and checks the folders and records. Then `./build.sh` installs it to Applications and
restarts TurnOver. Use the app for the tasks you wrote down, and read the newest log in
`~/Library/Application Support/TurnOver/logs/`: it shows each event, each script and everything said.

Where you can, add a test to `Sources/TurnOverTests`. A recorded window (`Tests/Fixtures`, see `TESTING.md`) lets a
test replay the app without it running. Record only public sample content, never your own mail or documents.

## The rules that matter most

- **Keep it in the app's folder.** If the fix seems to need a change to shared code (focus, speech, keys, the
  hand-over, browse mode), don't make it in your module's pull request: ask for a building block (below).
- **Mac keys do what VoiceOver's do.** A module adds what the app lacks; it doesn't change what a VoiceOver key means.
- **Say what you checked, and how.** In the pull request, name the app and macOS versions, the keyboard style, and
  whether VoiceOver was on. Say what you heard, and what you didn't test. A passing build doesn't show how it sounds.
- **One app, one change, per pull request**, signed off (`git commit -s`).

## When you need something TurnOver doesn't have: a building block

Sometimes the module can't do it alone. The app needs something every app could use: a hook `AppModule` doesn't have,
a kind of control TurnOver doesn't read, or a change to how focus or speech works. That's a building block.

Ask for one with the **Building block** issue form. Say:

- the app;
- what it needs, in a sentence;
- what you tried in the module, and why that wasn't enough;
- what it would let the module do.

You don't need to know how to build it. Building blocks go into the core, are reviewed more carefully than modules,
and land between releases. [`docs/BUILDING-BLOCKS.md`](docs/BUILDING-BLOCKS.md) explains how a request is handled,
and lists the blocks that already exist.

## Getting help

Ask on your issue, or in GitHub Discussions. If you work with an AI assistant, point it at this guide, `AGENTS.md`
and the app's `STATUS.md`. Ask it to show you each finding with its evidence before it writes code.
