# From JAWS scripts and NVDA add-ons to TurnOver plugins (15 Nov 2026)

This is for people who have written JAWS scripts or NVDA add-ons. It maps each idea you know to TurnOver's, says
plainly where there is no equivalent and why, and shows two small jobs written all three ways.

Scripts in TurnOver are built (docs/PLUGIN-SCRIPTS-PLAN.md) and are off until the maintainer switches on
`pluginScripts` (15 Nov 2026). The author's guide is [PLUGIN-SCRIPTS.md](PLUGIN-SCRIPTS.md); what a plugin can never do is in
[PLUGIN-SECURITY.md](PLUGIN-SECURITY.md).

## The main difference

JAWS scripts and NVDA add-ons run inside the screen reader, with everything it can reach. A TurnOver script runs in
a separate, sandboxed program with no files, no network and no other programs. It cannot see a key or a typed
character, though with the `read` ability it can read what a field holds, and never a password. It asks TurnOver for things, and TurnOver checks each request against what the user agreed to when
they approved the script on their Mac. Most of what is different below follows from that.

## JAWS, idea by idea

- Per-application script file (`Notepad.jss`, compiled to `.jsb`): a plugin folder for one app, with `apps` naming
  its bundle identifier. The script is `main.js`, one file, in JavaScript, with no compile step. A TurnOver plugin
  can also have no script at all, only rules.
- The default script file underneath: TurnOver's own handling is underneath every plugin. A plugin for an app comes
  first in that app; there is nothing to copy or inherit.
- Key map file (`.jkm`): the manifest's `commands`, each with a `key` and a `letter`. Keys are kept apart from
  code, as in JAWS, and the user can rebind them. The script never sees a key; it is told its command was chosen.
- `Script` with synopsis and description: a command in the manifest with an `id` and a `description`. The
  description is what input help speaks and the shortcuts list shows. There is no synopsis, only the description.
- `FocusChangedEvent`: `turnover.on("focus", handler)`. The handler may replace what is said for the item with
  `event.say`, say nothing with `event.silence`, or do neither and TurnOver reads it as usual. A focus event never
  stops other handling.
- `SayString`: `turnover.say(text)`, needs the `say` ability. It adds to what TurnOver says; to change the words for
  the item in focus, use `event.say`.
- `PerformScript`: no equivalent. One command cannot call another by name, and a script cannot call a key
  command. Put shared steps in an ordinary JavaScript function and call it from both handlers. Reason: a script
  never sees keys, and commands are declared in the manifest.
- Graphics labels file (`.jgf`) and other label data: the plugin's `labels` in `profile.json`, with matches on
  role, identifier, title and so on. Many JAWS label jobs need no script.
- Dictionary files (`.jdf`): no equivalent. TurnOver's pronunciation settings are the user's own, and a plugin cannot
  change TurnOver's settings. Reason: the clear line in PLUGIN-SECURITY.md.
- Script Manager (write, compile, try): a text editor, `turnover-plugin new` to start, `check` and `test` to try it
  without the app, and developer mode in the Plugins menu, where saving `main.js` reloads the script and TurnOver says
  "reloaded" or the first error with its line.
- Scripts that reach every app: no equivalent in this version. A plugin names its apps. Scripts for every app
  at once are listed as not in this version.
- Scripts that call Windows or the system, read files, or use the network: no equivalent, and never. Reason: the
  sandbox.
- Sharing a compiled script without its source: no equivalent. TurnOver reads `main.js` as text, and a reviewer
  must read every line of it. Packed or encoded code is rejected in review.

## NVDA, idea by idea

- App module (`appModules/notepad.py`): a plugin whose `apps` names one bundle identifier.
- Global plugin: no equivalent in this version. Scripts for every app at once are not in this version.
- Add-on manifest (`manifest.ini`: name, version, author, minimum and last tested NVDA): `manifest.json`: `name`,
  `version`, `author`, `minimumTurnOver`, `formatVersion`, `apps`, `abilities`, `script` and `commands`. The format has
  a number, and TurnOver reads every older format.
- `event_gainFocus(self, obj, nextHandler)`: `turnover.on("focus", handler)`. There is no `nextHandler` and no chain
  to pass on. What TurnOver does after the handler is decided by what you call: `event.say(text)`, `event.silence()`
  or nothing. To do something extra and keep the usual words, do the extra thing and call neither.
- `@script(description=…, gesture=…)`: `turnover.command(id, handler)` and the `commands` entry in the manifest. The
  description and the gesture are in the manifest, not on the function.
- Gestures the user can rebind: the same. The command's `key` can be rebound.
- `ui.message(text)`: `turnover.say(text)`.
- `obj.name`, `obj.role`, `obj.value`, `obj.states`, `obj.parent`, `obj.children`: the fields of an item and the calls
  `item.parent()` and `item.children()`. An item is a copy, and the calls need the `read` ability and are
  asynchronous: `await item.parent()`. `item.role` is the word a `profile.json` match uses ("button", "textField"),
  not NVDA's role constant; `item.axRole` is the accessibility role with its `AX`.
- Overlay classes (`chooseNVDAObjectOverlayClasses`): no equivalent. A plugin cannot change what kind of object
  TurnOver makes. A label rule in `profile.json` can name or re-role one.
- Settings panels and `config.conf`: no equivalent in this version. Reason: a plugin never changes TurnOver's
  settings. Plugin options in TurnOver's own menu are listed under Later.
- Drivers (speech, braille): no equivalent. Those stay TurnOver's own.
- Calling Windows or system APIs, files, network, `subprocess`: no equivalent, and never. Reason: the sandbox. A
  script has no `require`, no `fetch` and no file object.
- Scratchpad folder with reload: developer mode. Approve the script once with it on, then save `main.js` and it
  reloads without a question, as long as the apps and abilities do not grow.
- Python console: no equivalent. Use `console.log` to TurnOver's log, and the test runner.
- Developer information (NVDA+F1): "What is this?" in TurnOver's maker (VO-Slash) says and copies an item's role,
  name, identifier and the match TurnOver would use for it. The tool `turnover-plugin snapshot <app>` gives the
  whole window. A script can read the fields of an item with `console.log(JSON.stringify(item))`.
- Log viewer: TurnOver's log, which a script writes to with `console`.
- Add-on Store: no equivalent for scripts yet. The library is paused, and a script reaches it only after a person
  other than its author has read every line of that version. Until then a script arrives as a folder the user
  approves on their own Mac.
- Add-on packaging (`.nvda-addon`): a folder of plain files. A single-file `.turnoverplugin` is in the toolkit plan,
  not here.
- Restarting with add-ons disabled: setting `pluginScripts` off turns every script off. After a hang, TurnOver
  restarts with scripts off and says so.
- A yearly break of the programming interface: the interface has a version, `turnover.api`, and scripts written for
  version 1 are meant to keep working against it.

## Example one: a key that reads a status line

The JAWS and NVDA code is short and conventional, and is an illustration, not tested code. The TurnOver version
is a complete plugin that passes `turnover-plugin check <folder> --listing` (15 Nov 2026); the match in it is an
example, and its fields would be taken from a snapshot of the real app. A plugin kept on your own Mac needs only the
manifest fields down to `commands`; the last five fields are the library's listing.

### JAWS

In the script file:

```
Script ReadStatusLine ()
SayString (GetWindowText (FindDescendantWindow (GetAppMainWindow (GetFocus ()), 1000), true))
EndScript
```

JAWS has several ways to reach a status bar, and the right one depends on the program. The shape is what matters:
a script with a name, bound to a key in the key map (`Insert+Shift+S=ReadStatusLine`) and described in its
documentation file.

### NVDA

```python
import appModuleHandler
from scriptHandler import script
import api, ui

class AppModule(appModuleHandler.AppModule):
    @script(description="Read the status line", gesture="kb:NVDA+shift+s")
    def script_readStatusLine(self, gesture):
        bar = api.getStatusBar()
        ui.message(bar.name if bar else "No status line")
```

### TurnOver

manifest.json:

```json
{
  "formatVersion": 2,
  "id": "example-status-line",
  "name": "Status line",
  "version": "1.0",
  "apps": ["com.example.app"],
  "abilities": ["read", "say"],
  "script": "main.js",
  "commands": [
    { "id": "readStatus", "description": "Read the status line", "key": "turnover+shift+s", "letter": "s" }
  ],
  "description": "Reads the status line of Example on a key.",
  "author": "Example Author",
  "summary": "Reads the status line on a key.",
  "contact": "https://example.org/contact",
  "privacy": "Reads the status line only; nothing leaves your Mac.",
  "license": "MIT",
  "changes": [
    { "version": "1.0", "notes": "First version." }
  ]
}
```

main.js:

```js
turnover.command("readStatus", async () => {
  const found = await turnover.find({ identifier: "statusLine" }, { limit: 1 });
  turnover.say(found.length ? (found[0].value || found[0].name) : "No status line");
});
```

If all you need is to read one element on a key, a rule does it with no script: a key with `"action": "read"` and a
`target` in `profile.json`. A script earns its place when you combine items or decide what to say.

## Example two: an unnamed button said by a better name when it takes the focus

### JAWS

```
Function FocusChangedEvent (handle hwndFocus, handle hwndPrevFocus)
If GetObjectName () == cscNull && GetObjectTypeCode () == WT_BUTTON Then
	SayString ("Clear")
	Return
EndIf
FocusChangedEvent (hwndFocus, hwndPrevFocus)
EndFunction
```

### NVDA

```python
import appModuleHandler
import controlTypes

class AppModule(appModuleHandler.AppModule):
    def event_gainFocus(self, obj, nextHandler):
        if obj.role == controlTypes.Role.BUTTON and not obj.name:
            obj.name = "Clear"
        nextHandler()
```

### TurnOver

```js
turnover.on("focus", (event) => {
  const item = event.item;
  if (item.role === "button" && !item.name && item.identifier === "clearButton") {
    event.say("Clear, button");
  }
});
```

This needs `read` (for the item) and `say` (for `event.say`) in the manifest's `abilities`. A rule does the same
job with no script: a label in `profile.json` such as
`{ "match": { "identifier": "clearButton" }, "name": "Clear" }`. Prefer the rule where it is enough.

## What you cannot do here that you could there

- Work in every app at once (JAWS's default scripts, NVDA's global plugins). Not in this version.
- See typed characters or caret moves, or react to each key. A script is never sent them. This is the price of
  being unable to log what is typed.
- Read the clipboard. A script can only put text on it.
- Read or write files, use the network, start a program, or call the system. Never.
- Change TurnOver's settings, voices, pronunciations or another plugin.
- Add a settings window of your own, or your own windows. Not in this version.
- Make a screen reader for a website. Browsers are closed apps today, and scripts for a website are later.
- Reach into TurnOver's internals: the object model, overlay classes, the speech queue. The interface is small on
  purpose, and has a version number.
- Do slow work in a focus handler: it has 25 ms.
- Run in the background while the app is not in front. A script is paused then.
- Be shared as a compiled file without source.
- Keep running when it misbehaves: three strikes in ten minutes and it is off.
- Be switched on without the user's agreement. The user hears what it can do, and agrees, on their own Mac.
